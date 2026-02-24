# frozen_string_literal: true

# Split strategy for:
#   "The Art Of Cookery" by Hannah Glasse (1747)
#   Internet Archive ID: TheArtOfCookery
#   URL: https://archive.org/details/TheArtOfCookery
#
# HOW TO REFINE THIS STRATEGY:
#   1. Fetch the OCR text:  rails "ia:fetch[SOURCE_ID]"
#   2. Open data/internet_archive/TheArtOfCookery.txt
#   3. Identify the actual recipe title pattern (update RECIPE_TITLE below)
#   4. Identify chapter heading pattern (update CHAPTER_HEADING below)
#   5. Dry-run:  rails "ia:split[SOURCE_ID,hannahglasse]"
#   6. Iterate until the chunks look right
#
module InternetArchive
  module Splitters
    class HannahglasseStrategy < Base
      # Chapter/section headings — adjust after inspecting OCR text.
      CHAPTER_HEADING = /\A\s*(?:CHAP(?:TER|\.)\s+[IVXLCDM]+\.?|[A-Z][A-Z\s,&]{4,})\s*\z/

      # Recipe title pattern — adjust after inspecting OCR text.
      RECIPE_TITLE = /\A\s*(?:To\s+\w+|A\s+[A-Z]|\d+\.\s*To\s+)/i

      def call(text)
        text_lines = lines(text)
        chunks = []
        current_section = nil

        title_indices = find_boundaries(text_lines, RECIPE_TITLE)
        chapter_indices = find_boundaries(text_lines, CHAPTER_HEADING)

        title_indices.each_with_index do |title_idx, i|
          chapter_indices.each do |ch_idx|
            break if ch_idx >= title_idx
            current_section = text_lines[ch_idx].strip
          end

          next_title_idx = title_indices[i + 1]
          chunk_text = collect_chunk(text_lines, title_idx, next_title_idx)
          next if chunk_text.blank?

          page_number = find_page_number(text_lines, title_idx)

          chunks << {
            text: clean_ocr_text(chunk_text),
            section_header: current_section,
            page_number: page_number
          }
        end

        chunks
      end
    end

    Registry.register('hannahglasse', HannahglasseStrategy)
  end
end
