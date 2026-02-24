# frozen_string_literal: true

# Split strategy for:
#   "The Experienced English Housekeeper" by Elizabeth Raffald (1784, 9th edition)
#   Internet Archive ID: bim_eighteenth-century_the-experienced-english-_raffald-elizabeth_1784
#   URL: https://archive.org/details/bim_eighteenth-century_the-experienced-english-_raffald-elizabeth_1784
#
# Structure: The book is organized into chapters by category (e.g. "SOUPS",
# "FISH", "MADE DISHES"). Within each chapter, recipes have titles that
# typically appear as standalone lines — often in title case or all caps,
# sometimes preceded by a number (e.g. "To make a rich Gravy Soup.").
#
# OCR notes: Scanned from microfilm at 800 PPI. OCR'd with Tesseract using
# Fraktur + Middle English models. The long-s (ſ) may appear as 'f' in some
# words (e.g. "foup" for "soup"). This is handled by the Flask LLM extractor.
#
# HOW TO REFINE THIS STRATEGY:
#   1. Fetch the OCR text:  rails "ia:fetch[SOURCE_ID]"
#   2. Open data/internet_archive/bim_eighteenth-century_the-experienced-english-_raffald-elizabeth_1784.txt
#   3. Identify the actual recipe title pattern (update RECIPE_TITLE regex below)
#   4. Identify chapter heading pattern (update CHAPTER_HEADING regex below)
#   5. Dry-run:  rails "ia:split[SOURCE_ID,raffald]"
#   6. Iterate until the chunks look right
#
module InternetArchive
  module Splitters
    class RaffaldStrategy < Base
      # Chapter/section headings (ALL-CAPS lines like "SOUPS", "FISH", etc.)
      # Adjust this regex after inspecting the actual OCR text.
      CHAPTER_HEADING = /\A\s*(?:CHAP(?:TER|\.)\s+[IVXLCDM]+\.?|[A-Z][A-Z\s,&]{4,})\s*\z/

      # Recipe title pattern. Raffald's recipes typically start with:
      #   "To make ..." or "To dress ..." or "A ... " or numbered entries.
      # The long-s may cause "To" to appear as "To" but "soup" as "foup".
      # Adjust after inspecting the OCR text.
      RECIPE_TITLE = /\A\s*(?:To\s+\w+|A\s+[A-Z]|\d+\.\s*To\s+)/i

      def call(text)
        text_lines = lines(text)
        chunks = []
        current_section = nil

        # Find all lines that look like recipe titles
        title_indices = find_boundaries(text_lines, RECIPE_TITLE)

        # Also track chapter headings for section_header metadata
        chapter_indices = find_boundaries(text_lines, CHAPTER_HEADING)

        title_indices.each_with_index do |title_idx, i|
          # Update current section from any chapter heading that precedes this title
          chapter_indices.each do |ch_idx|
            break if ch_idx >= title_idx
            current_section = text_lines[ch_idx].strip
          end

          # Determine chunk boundary: from this title to the next title (or end of text)
          next_title_idx = title_indices[i + 1]

          # Collect the full chunk (title line + body)
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

    Registry.register('raffald', RaffaldStrategy)
  end
end
