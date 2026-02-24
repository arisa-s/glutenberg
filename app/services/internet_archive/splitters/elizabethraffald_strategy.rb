# frozen_string_literal: true

module InternetArchive
  module Splitters
    class ElizabethraffaldStrategy < Base
      PAGE_HEADER = /\A\s*(?:
        \d{1,4}\s+THE\s+EXPERIENCED\b.* |
        ENGLISH\s+HOUSE-KEEPER\.?\s+\d{1,4}\s* |
        THE\s+EXPERIENCED\s*\|?\s* |
        ENGLISH\s+HOUSE-KEEPER\.?\s*
      )\z/ix

      INDEX_HEADING = /\A\s*(?:I\s*N\s*D\s*E\s*X\.?|INDEX\.?)\s*\z/i
      CHAPTER_HEADING = /\A\s*[A-Z][A-Z\s,&-]{3,}\.?\s*\z/

      CANDIDATE_TITLE = /\A\s*(?:[A-Z]\s*\d+\s*)?(?:To|A)\s+\S.{2,110}\s*\z/i

      MEASURE_WORDS = /
        \b(?:every|quart|quarts|pint|pints|pound|pounds|ounce|ounces|oz|lb|lbs|
           spoon|spoons|spoonful|spoonfuls|cup|cups|gill|gills|dozen|half|quarter)\b
      /ix
      NUMERIC = /(?:\d|[¼½¾⅓⅔⅛⅜⅝⅞])/

      # Disqualify only very "instruction-fragment-y" verbs for To-lines
      INSTRUCTION_FRAGMENT_VERBS = /\b(?:put|add|mix|stir|beat|pour|set)\b/i

      INSTRUCTION_NEXT_LINE = /\A\s*(?:TAKE|PUT|BOIL|ADD|MIX|STIR|SET|MAKE|LET|CUT|BEAT|POUR|BAKE|ROAST|FRY)\b/i

      # Reject punctuation that appears BEFORE the end of the line.
      # Allows: "... SOUP," or "... SOUP." at the end.
      # Rejects: "..., and put ..." / "..., to them ..."
      PUNCT_MIDLINE = /[,:;].+\S/

      ADJECTIVE_FRAGMENT = /\A\s*A\s+(?:little|few|good|fine|great|large|small|short|long|warm|cold|fresh)\b/i
      FOOD_WORD = /\b(?:PUDDING|PIE|TART|CAKE|BREAD|BISCUIT|SOUP|SAUCE|JELLY|CREAM|CUSTARD|PASTE|PICKLE|WINE|BEER|SYRUP|TANSEY|FRICASSEE|RAGOUT|HASH|COLLAR|SOUR)\b/i

      def call(text)
        text_lines = lines(text)

        chunks = []
        current_section = nil

        index_start = text_lines.find_index { |l| l.match?(INDEX_HEADING) } || text_lines.length
        chapter_indices = find_boundaries(text_lines, CHAPTER_HEADING).select { |i| i < index_start }
        title_indices = (0...index_start).select { |i| title_line?(text_lines, i) }

        title_indices.each_with_index do |title_idx, i|
          chapter_indices.each do |ch_idx|
            break if ch_idx >= title_idx
            current_section = text_lines[ch_idx].strip
          end

          next_title_idx = title_indices[i + 1]
          chunk_text = collect_chunk(text_lines, title_idx, next_title_idx)
          next if chunk_text.blank?

          chunk_text = strip_page_headers(chunk_text)
          page_number = find_page_number(text_lines, title_idx)

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
          .reject { |l| l.match?(PAGE_HEADER) }
          .join
      end

      def title_line?(lines, i)
        line = lines[i].to_s.strip
        return false unless line.match?(CANDIDATE_TITLE)

        prev = lines[i - 1].to_s.strip
        nxt  = lines[i + 1].to_s.strip

        return to_title_line?(line, prev: prev, nxt: nxt) if line.match?(/\A\s*To\b/i)
        return a_title_line?(line, prev: prev, nxt: nxt)  if line.match?(/\A\s*A\b/i)

        false
      end

      def to_title_line?(line, prev:, nxt:)
        # Reject obvious instruction fragments like:
        # "TO every quart of ... put"
        return false if line.match?(MEASURE_WORDS) || line.match?(NUMERIC)
        return false if line.match?(INSTRUCTION_FRAGMENT_VERBS)

        # Allow trailing punctuation, reject mid-line clause punctuation.
        # Accept: "To make a rich VERMICELLE SOUP,"
        # Reject: "To them add..., and stir..."
        return false if line.match?(PUNCT_MIDLINE)

        # Prefer separation, but don't require it (OCR often drops blank lines)
        return true if prev.empty? || nxt.empty?

        # Otherwise accept if next line looks like recipe instructions
        return true if nxt.match?(INSTRUCTION_NEXT_LINE)

        false
      end

      def a_title_line?(line, prev:, nxt:)
        return false if line.match?(ADJECTIVE_FRAGMENT)
        return false if line.match?(MEASURE_WORDS) || line.match?(NUMERIC)

        # Same punctuation rule: allow trailing period/comma, reject mid-line clause punctuation
        return false if line.match?(PUNCT_MIDLINE)

        # Real "A ..." titles are typically ALL-CAPS dish names in this OCR.
        ratio = uppercase_ratio(line)
        return false unless (ratio >= 0.60) || line.match?(FOOD_WORD)

        # Require some separation OR instruction next line
        return true if prev.empty? || nxt.match?(INSTRUCTION_NEXT_LINE)

        false
      end

      def uppercase_ratio(s)
        letters = s.scan(/[A-Za-z]/)
        return 0.0 if letters.empty?

        uppers = s.scan(/[A-Z]/).size
        uppers.to_f / letters.size
      end
    end

    Registry.register('elizabethraffald', ElizabethraffaldStrategy)
  end
end
