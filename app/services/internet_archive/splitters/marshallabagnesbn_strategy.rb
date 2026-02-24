# frozen_string_literal: true

module InternetArchive
  module Splitters
    class MarshallabagnesbnStrategy < Base
      # Page running header appears frequently and must not be treated as a title.
      PAGE_HEADER = /\A\s*MRS\.?\s*A\.?\s*B\.?\s*MARSHALL[’']?S\s+COOKERY\s+BOOK\s*\z/i

      # Index heading (towards the end). We stop generating recipe chunks once index starts.
      INDEX_HEADING = /\A\s*INDEX\.?\s*\z/i

      # Chapter headings often look like:
      # "CHAPTER I." then the next line is an all-caps topic.
      CHAPTER_LINE = /\A\s*CHAPTER\s+[IVXLCDM0-9]+\.\s*\z/i
      ALLCAPS_TOPIC = /\A\s*[A-Z][A-Z\s,&'’\-]{3,}\.?\s*\z/

      # Parenthetical subtitle/translation line patterns.
      # OCR sometimes produces "(. Lapereau ...)" instead of "(Lapereau ...)".
      PAREN_SUBTITLE = /\A\s*\(\.?\s*[^)]+\)\.?\s*\z/

      # Candidate title line:
      # - not blank
      # - not page header
      # - not chapter line
      # - typically Title Case and often ends with "."
      # - allow accents/apostrophes
      #
      # We do NOT require all-caps.
      TITLE_LIKE = /\A\s*["“”']?\s*[A-Z][A-Za-zÀ-ÖØ-öø-ÿ0-9\s’'‘’,\-&\/]+\s*\.?\s*["“”']?\s*\z/

      # Recipe bodies frequently start with imperative verbs.
      BODY_START = /\A\s*(?:Take|Put|Mix|Add|Stir|Boil|Bake|Roast|Fry|Cut|Pour|Set|Let|Serve|Trim|Skin)\b/i

      def call(text)
        text_lines = lines(text)

        chunks = []
        current_section = nil

        index_start = text_lines.find_index { |l| l.to_s.strip.match?(INDEX_HEADING) } || text_lines.length

        i = 0
        while i < index_start
          line = text_lines[i].to_s.strip

          # Track section headers (chapter/topic)
          if line.match?(CHAPTER_LINE)
            topic = text_lines[i + 1].to_s.strip
            current_section = topic if topic.match?(ALLCAPS_TOPIC) && !topic.match?(PAGE_HEADER)
            i += 1
            next
          end

          if title_line?(text_lines, i)
            start_idx = i

            # Include optional parenthetical subtitle line immediately after title.
            j = i + 1
            j += 1 if j < index_start && text_lines[j].to_s.strip.match?(PAREN_SUBTITLE)

            # Collect until next title (or index start)
            while j < index_start && !title_line?(text_lines, j)
              j += 1
            end

            chunk_text = collect_chunk(text_lines, start_idx, j)
            next if chunk_text.blank?

            # Strip page headers inside the chunk
            chunk_text = strip_page_headers(chunk_text)

            chunks << {
              text: clean_ocr_text(chunk_text),
              section_header: current_section,
              page_number: find_page_number(text_lines, start_idx)
            }

            i = j
            next
          end

          i += 1
        end

        chunks
      end

      private

      def strip_page_headers(chunk_text)
        chunk_text
          .lines
          .reject { |l| l.to_s.strip.match?(PAGE_HEADER) }
          .join
      end

      def title_line?(lines, i)
        line = lines[i].to_s
        s = line.strip
        return false if s.empty?
        return false if s.match?(PAGE_HEADER)
        return false if s.match?(INDEX_HEADING)
        return false if s.match?(CHAPTER_LINE)
        return false if s.match?(/\A\d+\z/) # standalone page number
        return false unless s.match?(TITLE_LIKE)

        prev = lines[i - 1].to_s.strip
        nxt  = lines[i + 1].to_s.strip

        # Titles are often separated by blank lines in this OCR.
        # If OCR dropped the blank, accept when the next line is clearly a subtitle or recipe body.
        separated = prev.empty? || nxt.empty?
        next_is_subtitle_or_body = nxt.match?(PAREN_SUBTITLE) || nxt.match?(BODY_START)

        separated || next_is_subtitle_or_body
      end
    end

    Registry.register('marshallabagnesbn', MarshallabagnesbnStrategy)
  end
end
