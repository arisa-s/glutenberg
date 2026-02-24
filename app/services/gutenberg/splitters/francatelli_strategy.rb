# frozen_string_literal: true

# Split strategy for:
#   "A Plain Cookery Book for the Working Classes" by Charles Elmé Francatelli
#   Gutenberg ID: 22114
#   URL: https://www.gutenberg.org/files/22114/22114-h/22114-h.htm
#
# Structure: Recipes are numbered sections with <h3> headings like:
#   ### No. 1. Boiled Beef.
#   ### No. 2. How to Boil Beef.
#
# Strategy: Split on <h3> elements whose text matches "No. \d+."
# Each chunk includes the title heading followed by the recipe body text.
#
module Gutenberg
  module Splitters
    class FrancatelliStrategy < Base
      TITLE_PATTERN = /\ANo\.\s*\d+\./

      def call(html)
        doc = parse(html)
        chunks = []

        # Find all h3 headings that look like recipe titles
        title_nodes = doc.css('h3').select { |h3| h3.text.strip.match?(TITLE_PATTERN) }

        title_nodes.each_with_index do |title_node, idx|
          next_title_node = title_nodes[idx + 1]

          title = extract_text(title_node)
          body = collect_text_between(title_node, next_title_node)

          next if body.blank?

          # Combine title and body into a single text chunk
          chunks << { text: "#{title}\n\n#{body}", section_header: nil, page_number: find_page_number(title_node) }
        end

        chunks
      end
    end

    Registry.register('francatelli', FrancatelliStrategy)
  end
end
