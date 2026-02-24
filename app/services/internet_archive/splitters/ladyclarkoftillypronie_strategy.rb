# frozen_string_literal: true

module InternetArchive
  module Splitters
    # Splitter for:
    # https://archive.org/stream/b21530130/b21530130_djvu.txt
    #
    # Observed patterns in this OCR:
    # - Recipes typically start with a Title Case line ending in "." (often surrounded by blank lines)
    # - Many titles include variants like "No. 1." and/or a provenance note in parentheses:
    #     "Baking- Powder. No. i. (Lady Wensleydale. From Dr. Alfred Taylor.)"
    # - Bodies often begin with "Ingredients :", a quantity, or an instruction verb ("Pare", "Take", etc.)
    # - Running headers / page headers include ALL-CAPS section text and/or page numbers
    #
    class LadyclarkoftillypronieStrategy < Base
      # -----------------------------
      # End-of-content (Index)
      # -----------------------------
      # The TOC includes "INDEX" near the beginning, so we treat the *real* index
      # as the "INDEX" line that is followed (within a few lines) by "PAGE".
      INDEX_LINE = /\A\s*INDEX\s*\z/i
      INDEX_PAGE_LINE = /\A\s*PAGE\s*\z/i

      # -----------------------------
      # Section headings / page headers
      # -----------------------------
      # e.g. "SOUPS  AND  BROTPIS  341" (OCR noise in BROTHS)
      SECTION_WITH_PAGE = /\A\s*([A-Z][A-Z\s,&'’-]{3,}?)\s+(\d{1,4})\s*\z/

      # e.g. "SOUPS  AND  BROTHS" (no page number)
      SECTION_ONLY = /\A\s*[A-Z][A-Z\s,&'’-]{3,}\.?\s*\z/

      # Standalone page number line
      STANDALONE_PAGE = /\A\s*(\d{1,4})\s*\z/

      # Running header (various OCR casings)
      RUNNING_HEADER = /\A\s*THE\s+COOKERY\s+BOOK\s+OF\s+LADY\s+CLARK\s+OF\s+TILLYPRONIE\s*\z/i

      # -----------------------------
      # Recipe title detection
      # -----------------------------
      # Title-case-ish line that ends with a period (optionally includes "No. i." and/or "(...)" note)
      # Examples:
      #   "Artichoke Soup."
      #   "Baking- Powder. No. i. ( Lady Wensleydale. From Dr. Alfred Taylor.)"
      #   "Milk Scones. (Mrs. Wellington. 1877.)"
      TITLE_LINE = /\A\s*
        [A-Z][A-Za-z0-9][A-Za-z0-9\s,&'’"\/\-\(\)\.]{1,180}?
        \.\s*
      \z/x

      # "No." variants are common; allow roman/arabic, OCR "i", etc.
      NO_VARIANT = /\bNo\.\s*(?:\d+|[ivxlcdm]+|[a-z])\b/i

      PAREN_NOTE = /\([^\)]{2,200}\)/

      # Body starts:
      INSTRUCTION_START = /\A\s*(?:To\s+|Take|Put|Add|Mix|Stir|Beat|Boil|Bake|Roast|Fry|Soak|Wash|Peel|Cut|Slice|Chop|Pare|Lay|Place|Prepare|Make|Whip|Serve|Simmer|Strain|Clarify|Pass|Arrange|Season|Rub)\b/i
      INGREDIENTS_LINE = /\A\s*Ingredients?\s*[:\-]/i
      QUANTITY_START = /\A\s*(?:\d+|[¼½¾⅓⅔⅛⅜⅝⅞])\b/

      def call(text)
        text_lines = lines(text)

        chunks = []
        current_section = nil

        index_start = find_real_index_start(text_lines) || text_lines.length

        title_indices = (0...index_start).select { |i| title_line?(text_lines, i) }

        title_indices.each_with_index do |title_idx, i|
          current_section = infer_section_header(text_lines, title_idx, fallback: current_section)

          next_title_idx = title_indices[i + 1]
          chunk_text = collect_chunk(text_lines, title_idx, next_title_idx)
          next if chunk_text.blank?

          chunk_text = strip_running_headers_and_page_noise(chunk_text)

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

      # -----------------------------
      # Index detection
      # -----------------------------
      def find_real_index_start(lines)
        idxs = find_boundaries(lines, INDEX_LINE)
        idxs.each do |idx|
          # accept only if "PAGE" appears shortly after
          (idx...(idx + 10)).each do |j|
            break if j >= lines.length
            return idx if lines[j].to_s.strip.match?(INDEX_PAGE_LINE)
          end
        end
        nil
      end

      # -----------------------------
      # Title detection
      # -----------------------------
      def title_line?(lines, i)
        l1 = lines[i].to_s.strip
        return false if l1.empty?

        # Reject obvious structural noise
        return false if l1.match?(RUNNING_HEADER)
        return false if l1.match?(INDEX_LINE)
        return false if l1.match?(STANDALONE_PAGE)
        return false if l1.match?(SECTION_WITH_PAGE)
        return false if (all_caps_line?(l1) && l1.match?(SECTION_ONLY))

        # Must look like a title line
        return false unless l1.match?(TITLE_LINE)

        # Avoid very short / junky lines that end with a period
        alpha = l1.scan(/[A-Za-z]/).length
        return false if alpha < 4

        # Must contain some lowercase somewhere (titles are not ALL CAPS)
        return false if l1.scan(/[a-z]/).empty?

        # Look ahead for a plausible body start.
        j = i + 1
        j = skip_interstitial_noise(lines, j)

        # Sometimes a provenance note is on its own line; accept and skip it.
        if j < lines.length && lines[j].to_s.strip.match?(/\A\s*#{PAREN_NOTE}\s*\.?\s*\z/)
          j += 1
          j = skip_interstitial_noise(lines, j)
        end

        nxt = lines[j].to_s.strip
        return false if nxt.empty?

        return true if nxt.match?(INGREDIENTS_LINE)
        return true if nxt.match?(INSTRUCTION_START)
        return true if nxt.match?(QUANTITY_START)

        # Many recipes begin with a normal sentence paragraph (capitalized).
        return true if nxt.match?(/\A\s*[A-Z][a-z]/)

        false
      end

      def skip_interstitial_noise(lines, j)
        while j < lines.length
          s = lines[j].to_s.strip
          break unless s.empty? ||
                       s.match?(RUNNING_HEADER) ||
                       s.match?(STANDALONE_PAGE) ||
                       s.match?(SECTION_WITH_PAGE)
          j += 1
        end
        j
      end

      # -----------------------------
      # Section header inference
      # -----------------------------
      def infer_section_header(lines, idx, fallback:)
        # Scan backwards for a likely section heading.
        (idx - 1).downto([idx - 250, 0].max) do |i|
          s = lines[i].to_s.strip
          next if s.empty?

          # Prefer explicit "SECTION ... PAGE" headers.
          if (m = s.match(SECTION_WITH_PAGE))
            heading = m[1].to_s.strip
            return heading unless heading.empty?
          end

          # Otherwise, take a nearby ALL CAPS heading line (but not the running header).
          if s.match?(SECTION_ONLY) && all_caps_line?(s) && !s.match?(RUNNING_HEADER)
            return s.gsub(/\s+/, ' ').strip
          end
        end
        fallback
      end

      # -----------------------------
      # Page number extraction
      # -----------------------------
      def find_page_number_book_specific(text_lines, idx)
        search_start = [idx - 12, 0].max

        (idx - 1).downto(search_start) do |i|
          line = text_lines[i].to_s.strip

          # "SOUPS AND BROTPIS 341"
          if (m = line.match(SECTION_WITH_PAGE))
            return m[2].to_i
          end

          # Standalone page number, likely if near a section header or running header.
          if (m = line.match(STANDALONE_PAGE))
            prev = text_lines[i - 1].to_s.strip
            nxt  = text_lines[i + 1].to_s.strip
            if prev.match?(RUNNING_HEADER) || nxt.match?(RUNNING_HEADER) ||
               prev.match?(SECTION_ONLY) || nxt.match?(SECTION_ONLY)
              return m[1].to_i
            end
          end
        end

        # fallback to Base heuristic
        find_page_number(text_lines, idx)
      end

      # -----------------------------
      # Chunk cleanup
      # -----------------------------
      def strip_running_headers_and_page_noise(chunk_text)
        chunk_text
          .lines
          .reject { |l| l.strip.match?(RUNNING_HEADER) }
          .reject { |l| l.strip.match?(SECTION_WITH_PAGE) }
          .reject { |l| l.strip.match?(STANDALONE_PAGE) }
          .join
      end
    end

    Registry.register('ladyclarkoftillypronie', LadyclarkoftillypronieStrategy)
  end
end
