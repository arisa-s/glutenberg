# frozen_string_literal: true

module InternetArchive
  module Splitters
    class AbmarshallStrategy < Base
      # ------------------------------------------------------------
      # Book-specific structure (Mrs. A. B. Marshall's Cookery Book)
      # ------------------------------------------------------------

      # e.g. "CHAPTER VI."
      CHAPTER_MARKER = /\A\s*CHAPTER\s+[IVXLCDM]+\.\s*\z/i

      # e.g. "FISH." / "STOCKS AND SAUCES."
      CHAPTER_TITLE = /\A\s*[A-Z][A-Z\s,&'’\-\.\(\)]{3,}\.?\s*\z/

      # Stop splitting when we hit the Alphabetical Index at the end.
      INDEX_HEADING = /\A\s*INDEX\.?\s*\z/i

      # Common running header (often preceded/followed by a page number line).
      RUNNING_HEADER = /\A\s*MRS\.?\s*A\.?\s*B\.?\s*MARSHALL[’']?S?\s+COOKERY\s+BOOK\s*\z/i

      # ------------------------------------------------------------
      # Recipe title detection
      # ------------------------------------------------------------

      DASH = /[—-]/

      # One-line recipe pattern that occurs frequently:
      #   "Aspic Jelly. — Two and a half ounces..."
      INLINE_TITLE_WITH_DASH = /\A\s*
        [A-Z][^\n]{2,140}?
        \.?\s*#{DASH}\s*\^?\s*\S
      /x

      # Standalone title line, often followed by:
      #   blank line
      #   "(French subtitle.)" on its own line (optional)
      #   then instructions paragraph.
      #
      # Examples:
      #   "Boiled Salt Fish and Egg Sauce."
      #   "(Morue Salee Bouillie, Sauce aux OEufs.)"
      STANDALONE_TITLE = /\A\s*
        [A-Z][A-Za-z0-9]
        [A-Za-z0-9\s,&'’\-\.\(\)\/]{1,90}
        \.?
        \s*
      \z/x

      SUBTITLE_LINE = /\A\s*\(.{2,140}\)\.?\s*\z/

      # Instruction-ish next line (best-effort, avoids grabbing prose headings)
      INSTRUCTION_NEXT_LINE = /\A\s*(?:To\s+|Take|Put|Add|Mix|Stir|Boil|Bake|Roast|Fry|Soak|Wash|Peel|Cut|Lay|Place|Prepare|Make|Whip|Serve|Simmer|Strain|Clarify|Pass)\b/i

      def call(text)
        text_lines = lines(text)

        chunks = []
        current_section = nil

        # Stop before the end-of-book INDEX.
        index_start = text_lines.find_index { |l| l.match?(INDEX_HEADING) } || text_lines.length

        title_indices = (0...index_start).select { |i| title_line?(text_lines, i) }

        title_indices.each_with_index do |title_idx, i|
          current_section = infer_section_header(text_lines, title_idx, fallback: current_section)

          next_title_idx = title_indices[i + 1]
          chunk_text = collect_chunk(text_lines, title_idx, next_title_idx)
          next if chunk_text.blank?

          chunk_text = strip_running_headers(chunk_text)
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

      # Remove running headers + bare page-number lines inside the chunk.
      def strip_running_headers(chunk_text)
        chunk_text
          .lines
          .reject { |l| l.strip.match?(RUNNING_HEADER) }
          .reject { |l| l.strip.match?(/\A\d{1,4}\z/) } # page number alone
          .join
      end

      # Title detection that supports:
      #  A) Inline "Title. — ..."
      #  B) Standalone title line, optional subtitle line "(...)" then instructions
      def title_line?(lines, i)
        l1 = lines[i].to_s.strip
        return false if l1.empty?

        # reject obvious non-titles
        return false if l1.match?(RUNNING_HEADER)
        return false if l1.match?(INDEX_HEADING)
        return false if l1.match?(CHAPTER_MARKER)
        return false if l1.match?(CHAPTER_TITLE) && all_caps_line?(l1)

        # A) Inline dash style
        return true if l1.match?(INLINE_TITLE_WITH_DASH)

        # B) Standalone title style
        return false unless standalone_title_candidate?(l1)

        # Look ahead for subtitle (optional) and then an instruction-ish line.
        j = i + 1

        # skip immediate blank lines
        j += 1 while j < lines.length && lines[j].to_s.strip.empty?

        # optional subtitle line in parentheses
        if j < lines.length && lines[j].to_s.strip.match?(SUBTITLE_LINE)
          j += 1
          j += 1 while j < lines.length && lines[j].to_s.strip.empty?
        end

        nxt = lines[j].to_s.strip
        return false if nxt.empty?

        # accept if the next line looks like instructions or starts like an inline dash recipe
        return true if nxt.match?(INSTRUCTION_NEXT_LINE)
        return true if nxt.match?(INLINE_TITLE_WITH_DASH) # occasional wrap/merge oddities
        return true if nxt.match?(/\A\s*Ingredients?\s*[:\-]/i)

        false
      end

      def standalone_title_candidate?(line)
        return false unless line.match?(STANDALONE_TITLE)
        return false if all_caps_line?(line) # avoid section headings like "FISH."
        return false if line.length < 4
        return false if line.match?(SUBTITLE_LINE) # don't treat subtitle as a title

        # Avoid “sentence-y” prose that sneaks through.
        # Standalone titles in this book are usually short-ish and nouny.
        return false if line.match?(/[;:]/)

        true
      end

      # Infer section header by scanning backwards for CHAPTER + its title line.
      def infer_section_header(lines, idx, fallback:)
        (idx - 1).downto([idx - 250, 0].max) do |i|
          next unless lines[i].to_s.match?(CHAPTER_MARKER)

          j = i + 1
          j += 1 while j < lines.length && lines[j].to_s.strip.empty?
          candidate = lines[j].to_s.strip

          return candidate if candidate.match?(CHAPTER_TITLE) && all_caps_line?(candidate)
          return fallback
        end
        fallback
      end

      # Page numbers in this OCR often appear as:
      #   "90 MRS. A. B. MARSHALL'S COOKERY BOOK"
      #   "91" (alone) followed/preceded by the running header
      def find_page_number_book_specific(text_lines, idx)
        search_start = [idx - 12, 0].max

        (idx - 1).downto(search_start) do |i|
          line = text_lines[i].to_s.strip

          # "90 MRS. A. B. MARSHALL'S COOKERY BOOK"
          if (m = line.match(/\A(\d{1,4})\s+MRS\.?\s*A\.?\s*B\.?\s*MARSHALL/i))
            return m[1].to_i
          end

          # Standalone page number line.
          if (m = line.match(/\A(\d{1,4})\z/))
            # If near a running header, this is very likely a real page number.
            prev = text_lines[i - 1].to_s.strip
            nxt  = text_lines[i + 1].to_s.strip
            if prev.match?(RUNNING_HEADER) || nxt.match?(RUNNING_HEADER)
              return m[1].to_i
            end
          end
        end

        # fallback to Base heuristics ([p. 42], — 42 —, standalone numbers)
        find_page_number(text_lines, idx)
      end
    end

    Registry.register('abmarshall', AbmarshallStrategy)
  end
end
