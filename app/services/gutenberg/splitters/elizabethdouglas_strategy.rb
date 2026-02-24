# frozen_string_literal: true

# Split strategy for:
#   "The Pudding and Pastry Book" by Elizabeth Douglas
#   Gutenberg ID: 68567
#   URL: https://www.gutenberg.org/cache/epub/68567/pg68567-images.html
#
# Structure observed:
#   - Major sections are <h2> headings (e.g. "Milk Puddings", "Pastry", etc.)
#   - Individual recipes are <h3> headings (e.g. "Apple Tapioca Pudding")
#   - Some <h3> headings are non-recipe (e.g. "Table of Measures") inside "General Directions"
#
# Strategy:
#   - Track current_section from <h2>
#   - For each <h3>, create a chunk until the next <h3> or <h2>
#   - Skip <h3> headings inside non-recipe sections (e.g. "General Directions")
#   - Skip known non-recipe <h3> headings like "Table of Measures"
#
module Gutenberg
  module Splitters
    class ElizabethdouglasStrategy < Base
      NON_RECIPE_SECTIONS = /\A\s*(Preface|Table of Contents|General Directions)\s*\z/i
      NON_RECIPE_H3       = /\A\s*Table of Measures\s*\z/i

      def call(html)
        doc = parse(html)
        chunks = []

        headings = doc.css('h2, h3')
        current_section = nil

        headings.each_with_index do |node, idx|
          heading_text = extract_text(node)
          next if heading_text.blank?

          if node.name == 'h2'
            # Update current section, but we won't emit recipe chunks in non-recipe sections.
            current_section = heading_text
            next
          end

          # node is h3: decide if it's a recipe title
          next if current_section&.match?(NON_RECIPE_SECTIONS)
          next if heading_text.match?(NON_RECIPE_H3)

          next_heading = headings[idx + 1] # next h2 or h3 boundary
          body = collect_text_between(node, next_heading)
          next if body.blank?

          chunks << {
            text: "#{heading_text}\n\n#{body}",
            section_header: current_section,
            page_number: find_page_number(node)
          }
        end

        chunks
      end
    end

    Registry.register('elizabethdouglas', ElizabethdouglasStrategy)
  end
end
