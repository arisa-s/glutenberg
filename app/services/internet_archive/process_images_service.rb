# frozen_string_literal: true

# Orchestrates the two-pass multimodal extraction pipeline for Internet Archive
# books. Downloads page images, identifies recipe boundaries via LLM, then
# extracts full structured recipes from targeted page ranges.
#
# Pass 1 (Boundary Detection):
#   Batches page images (~20 per batch) and asks Gemini to return recipe titles
#   and their leaf ranges. Cheap because output is tiny.
#
# Pass 2 (Targeted Extraction):
#   Groups consecutive recipes into ~10-15 page batches using the boundary map,
#   sends exactly the pages each recipe spans, and extracts full structured data.
#
# Usage:
#   result = InternetArchive::ProcessImagesService.call(
#     source: source,
#     start_leaf: 50,
#     end_leaf: 400
#   )
#   # => { boundaries: [...], recipes: [...], summary: { success: N, ... } }
#
module InternetArchive
  class ProcessImagesService
    BOUNDARY_BATCH_SIZE  = 20
    EXTRACTION_MAX_PAGES = 12

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

    # Returns { boundaries:, recipes:, summary: }
    def call
      pages = fetch_images
      boundaries = detect_boundaries(pages)
      return { boundaries: boundaries, recipes: [], summary: empty_summary } if boundaries.empty?

      boundaries = select_boundaries(boundaries)
      return { boundaries: boundaries, recipes: [], summary: empty_summary } if boundaries.empty?

      recipes = extract_recipes(boundaries, pages)

      {
        boundaries: boundaries,
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

    def detect_boundaries(pages)
      all_boundaries = []

      pages.each_slice(BOUNDARY_BATCH_SIZE).with_index do |batch, batch_idx|
        image_paths  = batch.map { |p| p[:path] }
        leaf_numbers = batch.map { |p| p[:leaf_number] }

        puts "  Pass 1 batch #{batch_idx + 1}: leaves #{leaf_numbers.first}–#{leaf_numbers.last}..."

        batch_boundaries = Llm::IdentifyRecipeBoundaries.call(
          image_paths: image_paths,
          leaf_numbers: leaf_numbers
        )

        all_boundaries.concat(batch_boundaries)
      end

      stitch_boundaries(all_boundaries)
    end

    def extract_recipes(boundaries, pages)
      page_index = build_page_index(pages)
      batches = group_into_extraction_batches(boundaries)
      recipes = []
      success = 0
      failed  = 0

      batches.each_with_index do |batch, batch_idx|
        batch_leaves = leaf_range_for_batch(batch, page_index)
        image_paths  = batch_leaves.filter_map { |l| page_index[l]&.fetch(:path) }
        leaf_numbers = batch_leaves.select { |l| page_index.key?(l) }

        next if image_paths.empty?

        expected_titles = batch.map { |b| b['title'] }.compact
        progress = "[#{batch_idx + 1}/#{batches.size}]"
        puts "  #{progress} Pass 2: leaves #{leaf_numbers.first}–#{leaf_numbers.last} " \
             "(#{expected_titles.size} recipe#{'s' if expected_titles.size != 1})..."

        begin
          extracted = Llm::ExtractRecipesFromPages.call(
            image_paths: image_paths,
            leaf_numbers: leaf_numbers,
            expected_recipes: expected_titles
          )

          extracted.each do |recipe_data|
            boundary = match_boundary(recipe_data, batch)
            start_leaf = boundary&.dig('start_leaf') || leaf_numbers.first

            recipe = Extraction::CreateRecipeService.call(
              source: @source,
              text: recipe_data.to_json,
              input_type: 'image',
              page_number: start_leaf,
              raw_section_header: @section_header,
              historical: true,
              llm_response: recipe_data
            )

            recipes << recipe
            if recipe.extraction_status == 'success'
              success += 1
              puts "    OK: #{recipe.title&.truncate(60)}"
            else
              failed += 1
              puts "    FAILED: #{recipe.error_message.to_s.truncate(80)}"
            end
          end
        rescue StandardError => e
          failed += batch.size
          puts "    ERROR: #{e.message.truncate(100)}"
        end

        sleep(0.5)
      end

      recipes
    end

    private

    # Resolve null end_leaf values by looking at the next boundary's start.
    def stitch_boundaries(boundaries)
      boundaries.each_with_index do |b, i|
        next if b['end_leaf'].present?

        if boundaries[i + 1]
          b['end_leaf'] = boundaries[i + 1]['start_leaf']
        end
      end

      boundaries.select { |b| b['start_leaf'].present? }
    end

    def select_boundaries(boundaries)
      return boundaries unless @selected_indices

      @selected_indices.filter_map { |i| boundaries[i] }
    end

    def build_page_index(pages)
      pages.each_with_object({}) { |p, h| h[p[:leaf_number]] = p }
    end

    # Group consecutive boundaries into extraction batches, keeping each batch
    # under EXTRACTION_MAX_PAGES total pages.
    def group_into_extraction_batches(boundaries)
      batches = []
      current_batch = []
      current_pages = 0

      boundaries.each do |b|
        start_l = b['start_leaf'].to_i
        end_l   = (b['end_leaf'] || start_l).to_i
        span    = [end_l - start_l + 1, 1].max

        if current_batch.any? && (current_pages + span) > EXTRACTION_MAX_PAGES
          batches << current_batch
          current_batch = []
          current_pages = 0
        end

        current_batch << b
        current_pages += span
      end

      batches << current_batch if current_batch.any?
      batches
    end

    def leaf_range_for_batch(batch, page_index)
      min_leaf = batch.map { |b| b['start_leaf'].to_i }.min
      max_leaf = batch.map { |b| (b['end_leaf'] || b['start_leaf']).to_i }.max
      (min_leaf..max_leaf).to_a.select { |l| page_index.key?(l) }
    end

    def match_boundary(recipe_data, batch)
      title = recipe_data['title'].to_s.downcase.strip
      return nil if title.blank?

      batch.min_by do |b|
        levenshtein_ish(b['title'].to_s.downcase.strip, title)
      end
    end

    # Quick approximate string distance for title matching.
    def levenshtein_ish(a, b)
      return a.length if b.empty?
      return b.length if a.empty?

      (a.chars.tally.keys | b.chars.tally.keys).sum do |c|
        (a.count(c) - b.count(c)).abs
      end
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
  end
end
