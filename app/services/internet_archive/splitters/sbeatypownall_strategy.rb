# frozen_string_literal: true

module InternetArchive
  module Splitters
    class SbeatypownallStrategy < Base
      # -----------------------------
      # Book-specific headings/headers
      # -----------------------------

      # OCR sometimes mangles "CHAPTER" in this file (e.g., CHAPTEE).
      CHAPTER_MARKER = /\A\s*CHAP(?:TER|TEE|TBE|TUE)\s+[IVXLCDM]+\.\s*\z/i

      # Chapter titles are usually ALL-CAPS lines (often with a trailing period).
      CHAPTER_TITLE = /\A\s*[A-Z][A-Z\s,&'-]{3,}\.?\s*\z/

      INDEX_HEADING = /\A\s*INDEX\.?\s*\z/i

      # Page headers commonly look like:
      #   "110 PICKLES AND PRESERVES."
      #   "PICKLES AND PRESERVES. 91"
      PAGE_HEADER = /\A\s*(?:
        \d{1,4}\s+[A-Z][A-Z\s,&'-]{3,}\.?\s* |  # "110 PICKLES AND PRESERVES."
        [A-Z][A-Z\s,&'-]{3,}\.?\s+\d{1,4}\s*   # "PICKLES AND PRESERVES. 91"
      )\z/x

      # -----------------------------
      # Recipe title detection
      # -----------------------------

      DASH = /[—-]/

      # One-line: "Quince Sambal. — Peel and quarter..."
      RECIPE_TITLE_WITH_DASH_1L = /\A\s*
        [A-Z][^\n]{2,140}?
        (?:[.,])?
        \s*#{DASH}\s*\^?\s*\S
      /x

      # Title-only line (for 2-line starts):
      #  - "Quince Sambal."
      #  - "Shallot"
      RECIPE_TITLE_ONLY = /\A\s*
        [A-Z][A-Za-z0-9]
        [A-Za-z0-9\s,&'()-]{0,60}
        \.?
        \s*
      \z/x

      # Next-line lead-in: "— Peel and mince..."
      DASH_LEAD_IN_LINE = /\A\s*#{DASH}\s*\^?\s*\S/

      def call(text)
        text_lines = lines(text)

        chunks = []
        current_section = nil

        # Stop before INDEX
        index_start = text_lines.find_index { |l| l.match?(INDEX_HEADING) } || text_lines.length

        # Find all recipe starts before INDEX
        title_indices = (0...index_start).select { |i| title_line?(text_lines, i) }

        title_indices.each_with_index do |title_idx, i|
          current_section = infer_section_header(text_lines, title_idx, fallback: current_section)

          next_title_idx = title_indices[i + 1]
          chunk_text = collect_chunk(text_lines, title_idx, next_title_idx)
          next if chunk_text.blank?

          chunk_text = strip_page_headers(chunk_text)

          page_number = find_page_number_book_specific(text_lines, title_idx)

          chunks << {
            text: clean_ocr_text(chunk_text),
            section_header: current_section,
            page_number: page_number
          }
        end

        chunks
      end

      private

      def strip_page_headers(chunk_text)
        chunk_text
          .lines
          .reject { |l| l.strip.match?(PAGE_HEADER) }
          .join
      end

      # Detect recipe title boundaries, handling wrapped title / dash.
      #
      # Supports:
      #  A) One-line: "Title. — Lead-in..."
      #  B) Two-line: "Title." + "— Lead-in..."
      #  C) Wrapped:  "Shallot" + "Vinegar. — Lead-in..."
      def title_line?(lines, i)
        l1 = lines[i].to_s.strip
        l2 = lines[i + 1].to_s.strip

        return false if l1.empty?
        return false if l1.match?(PAGE_HEADER)

        # Case A: standard one-line
        return true if l1.match?(RECIPE_TITLE_WITH_DASH_1L)

        # Case B: title line then dash starts next line
        if l1.match?(RECIPE_TITLE_ONLY) && l2.match?(DASH_LEAD_IN_LINE)
          return false if all_caps_line?(l1) # avoid headings
          return true
        end

        # Case C: wrapped title across two lines (join and test)
        if l1.match?(RECIPE_TITLE_ONLY) && l2.match?(RECIPE_TITLE_WITH_DASH_1L)
          return false if all_caps_line?(l1) # avoid headings
          joined = "#{l1} #{l2}"
          return joined.match?(RECIPE_TITLE_WITH_DASH_1L)
        end

        false
      end

      # Try to identify the enclosing chapter title by scanning backwards.
      def infer_section_header(lines, idx, fallback:)
        (idx - 1).downto([idx - 200, 0].max) do |i|
          if lines[i].to_s.match?(CHAPTER_MARKER)
            j = i + 1
            j += 1 while j < lines.length && lines[j].to_s.strip.empty?

            candidate = lines[j].to_s.strip
            return candidate if candidate.match?(CHAPTER_TITLE)
            return fallback
          end
        end

        fallback
      end

      # Book-specific page number extraction from header lines near recipe start.
      def find_page_number_book_specific(text_lines, idx)
        search_start = [idx - 8, 0].max

        (idx - 1).downto(search_start) do |i|
          line = text_lines[i].to_s.strip

          # "PICKLES AND PRESERVES. 91"
          if (m = line.match(/\A[A-Z][A-Z\s,&'-]{3,}\.?\s+(\d{1,4})\z/))
            return m[1].to_i
          end

          # "110 PICKLES AND PRESERVES."
          if (m = line.match(/\A(\d{1,4})\s+[A-Z][A-Z\s,&'-]{3,}\.?\z/))
            return m[1].to_i
          end
        end

        # Fallback to Base heuristic ([p. 42], standalone numbers, etc.)
        find_page_number(text_lines, idx)
      end
    end

    Registry.register('sbeatypownall', SbeatypownallStrategy)
  end
end
