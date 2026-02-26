# frozen_string_literal: true

require 'json'
require 'fileutils'

# Orchestrates the image-based extraction pipeline for Internet Archive books.
# Downloads page images, runs combined OCR + segmentation via LLM, then feeds
# each recipe's text through the standard text extraction pipeline.
#
# The pipeline is:
#   1. Fetch page images from IA's IIIF API
#   2. OCR + segment: batch page images (~20/batch) → Gemini reads the text and
#      segments by recipe → returns title, leaf range, and full OCR'd text
#   3. Text extraction: feed each recipe's text through ExtractRecipeFromText
#      for structured parsing (ingredients, instructions, etc.)
#
# Segment results are cached to disk after each batch so a failure mid-way
# can be resumed without re-processing earlier batches.
#
# Usage:
#   result = InternetArchive::ProcessImagesService.call(
#     source: source,
#     start_leaf: 50,
#     end_leaf: 400
#   )
#   # => { segments: [...], recipes: [...], summary: { success: N, ... } }
#
module InternetArchive
  class ProcessImagesService
    OCR_BATCH_SIZE = 20
    CACHE_DIR = Rails.root.join('tmp', 'segment_cache').freeze

    def self.call(...)
      new(...).call
    end

    def initialize(source:, start_leaf: nil, end_leaf: nil, width: nil,
                   selected_indices: nil, section_header: nil)
      @source          = source
      @start_leaf      = start_leaf
      @end_leaf        = end_leaf
      @width           = width || InternetArchive::FetchPageImagesService::DEFAULT_WIDTH
      @selected_indices = selected_indices
      @section_header  = section_header
    end

    def call
      pages = fetch_images
      segments = ocr_and_segment(pages)
      return { segments: segments, recipes: [], summary: empty_summary } if segments.empty?

      segments = select_segments(segments)
      return { segments: segments, recipes: [], summary: empty_summary } if segments.empty?

      recipes = extract_recipes(segments)

      {
        segments: segments,
        recipes: recipes,
        summary: build_summary(recipes)
      }
    end

    # Expose individual phases for the rake task's interactive flow.

    def fetch_images
      InternetArchive::FetchPageImagesService.call(
        source: @source,
        start_leaf: @start_leaf,
        end_leaf: @end_leaf,
        width: @width
      )
    end

    # OCR + segment: sends page images in batches to Gemini, which reads the
    # text and segments it by recipe. Cross-batch recipes are stitched together.
    def ocr_and_segment(pages)
      cache = SegmentCache.new(@source, @start_leaf, @end_leaf)
      batches = pages.each_slice(OCR_BATCH_SIZE).to_a
      all_segments = cache.load

      completed_count = all_segments.any? ? cache.completed_batches : 0
      if completed_count > 0
        puts "  Resuming OCR+segment from batch #{completed_count + 1}/#{batches.size} " \
             "(#{all_segments.size} segments cached)"
      end

      batches.each_with_index do |batch, batch_idx|
        next if batch_idx < completed_count

        image_paths  = batch.map { |p| p[:path] }
        leaf_numbers = batch.map { |p| p[:leaf_number] }

        puts "  OCR batch #{batch_idx + 1}/#{batches.size}: " \
             "leaves #{leaf_numbers.first}–#{leaf_numbers.last}..."

        batch_segments = Llm::OcrSegmentPages.call(
          image_paths: image_paths,
          leaf_numbers: leaf_numbers
        )

        all_segments.concat(batch_segments)
        cache.save(all_segments, batch_idx + 1)

        sleep(0.5)
      end

      result = stitch_segments(all_segments)
      cache.clear
      result
    end

    # Feed each segment's OCR text through the standard text extraction pipeline.
    def extract_recipes(segments)
      recipes = []
      success = 0
      failed  = 0

      segments.each_with_index do |segment, idx|
        title = segment['title'] || '(untitled)'
        text  = segment['text']
        progress = "[#{idx + 1}/#{segments.size}]"

        if text.blank?
          puts "  #{progress} SKIP: #{title.truncate(55)} (no text)"
          next
        end

        puts "  #{progress} Extracting: #{title.truncate(55)}..."

        begin
          recipe = Extraction::CreateRecipeService.call(
            source: @source,
            text: text,
            input_type: 'image',
            page_number: segment['start_leaf'],
            raw_section_header: @section_header
          )

          recipes << recipe
          if recipe.extraction_status == 'success'
            success += 1
            puts "    OK: #{recipe.title&.truncate(60)}"
          else
            failed += 1
            puts "    FAILED: #{recipe.error_message.to_s.truncate(80)}"
          end
        rescue StandardError => e
          failed += 1
          puts "    ERROR: #{e.message.truncate(100)}"
        end

        sleep(0.3)
      end

      recipes
    end

    private

    # When a recipe's text spans two OCR batches, the first batch returns the
    # segment with end_leaf: null. Stitch it with the next segment if the next
    # segment starts on an adjacent leaf and shares a similar title.
    def stitch_segments(segments)
      stitched = []
      skip_next = false

      segments.each_with_index do |seg, i|
        if skip_next
          skip_next = false
          next
        end

        if seg['end_leaf'].nil? && segments[i + 1]
          nxt = segments[i + 1]
          if titles_match?(seg['title'], nxt['title'])
            merged = seg.merge(
              'end_leaf' => nxt['end_leaf'] || nxt['start_leaf'],
              'text' => [seg['text'], nxt['text']].compact.join("\n")
            )
            stitched << merged
            skip_next = true
            next
          else
            seg = seg.merge('end_leaf' => seg['start_leaf'])
          end
        end

        stitched << seg
      end

      stitched.select { |s| s['start_leaf'].present? }
    end

    def titles_match?(a, b)
      return false if a.blank? || b.blank?
      a.to_s.downcase.strip == b.to_s.downcase.strip
    end

    def select_segments(segments)
      return segments unless @selected_indices

      @selected_indices.filter_map { |i| segments[i] }
    end

    def build_summary(recipes)
      {
        success: recipes.count { |r| r.extraction_status == 'success' },
        failed:  recipes.count { |r| r.extraction_status == 'failed' },
        total:   recipes.size
      }
    end

    def empty_summary
      { success: 0, failed: 0, total: 0 }
    end

    # Persists OCR+segment results to disk so processing can resume after
    # a failure without re-processing earlier batches.
    class SegmentCache
      def initialize(source, start_leaf, end_leaf)
        @path = CACHE_DIR.join("#{source.id}_#{start_leaf || 0}_#{end_leaf || 'end'}.json")
      end

      def load
        return [] unless @path.exist?

        data = JSON.parse(File.read(@path))
        data['segments'] || []
      rescue JSON::ParserError
        []
      end

      def completed_batches
        return 0 unless @path.exist?

        data = JSON.parse(File.read(@path))
        data['completed_batches'] || 0
      rescue JSON::ParserError
        0
      end

      def save(segments, completed_batches)
        FileUtils.mkdir_p(CACHE_DIR)
        File.write(@path, JSON.pretty_generate(
          'completed_batches' => completed_batches,
          'saved_at' => Time.current.iso8601,
          'segments' => segments
        ))
      end

      def clear
        File.delete(@path) if @path.exist?
      end
    end
  end
end
