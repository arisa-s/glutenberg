# frozen_string_literal: true

# Split strategy for:
#   "Modern cookery for private families" by Eliza Acton
#   Gutenberg ID: 72482
#   URL: https://www.gutenberg.org/cache/epub/72482/pg72482-images.html
#
# Structure: Chapters are under <h3> like "CHAPTER I.", "CHAPTER II.";
# recipe titles are <h3> with class c020 (e.g. "Extract of Beef...", "Mullagatawny").
# Strategy: Split on every <h3 class="c020"> that is NOT a chapter heading (CHAPTER I.–style).
# Each chunk is the recipe title plus body text until the next title <h3>.
#
module Gutenberg
  module Splitters
    class ElizaActonStrategy < Base
      # Chapter headers to skip (e.g. "CHAPTER I.", "CHAPTER II.", "CHAPTER XI.")
      CHAPTER_HEADING = /\A\s*CHAPTER\s+[IVXLCDM]+\.?\s*\z/i

      def call(html)
        doc = parse(html)
        chunks = []

        # Recipe titles are h3 with class c020; skip chapter headings
        title_nodes = doc.css('h3.c020').reject { |h3| h3.text.strip.match?(CHAPTER_HEADING) }

        title_nodes.each_with_index do |title_node, idx|
          next_title_node = title_nodes[idx + 1]

          title = extract_text(title_node)
          body = collect_text_between(title_node, next_title_node)

          next if body.blank?

          chunks << {
            text: "#{title}\n\n#{body}",
            section_header: nil,
            page_number: find_page_number(title_node)
          }
        end

        chunks
      end
    end

    Registry.register('elizaacton', ElizaActonStrategy)
  end
end
