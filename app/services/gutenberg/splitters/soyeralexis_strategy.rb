# frozen_string_literal: true

# Split strategy for:
#   "The Modern Housewife or, Ménagère" by Alexis Soyer (1849)
#   Gutenberg ID: 41899
#   URL: https://www.gutenberg.org/cache/epub/41899/pg41899-images.html
#
# Observed pattern:
#   - Each recipe is preceded by an <hr> element.
#   - Recipe text starts with a number + period, e.g. "1. Toast.—Procure..."
#   - Section headers are <h2> elements like "SOUPS", "FISH", "SAUCES", etc.
#   - Non-recipe narrative (letters, commentary) is interspersed but does NOT
#     start with a numbered pattern, so it is naturally filtered out.
#
module Gutenberg
  module Splitters
    class SoyeralexisStrategy < Base
      # Recipes start with a number followed by a period
      RECIPE_PATTERN = /\A\s*\d+\.\s+/

      # Stop at back matter
      STOP_AT = /\A\s*(INDEX|FOOTNOTES|THE\s+END)\b/i

      SECTION_SELECTOR = 'h2'

      def call(html)
        doc = parse(html)
        chunks = []
        current_section = nil

        hr_nodes = doc.css('hr')

        hr_nodes.each_with_index do |hr_node, idx|
          next_hr = hr_nodes[idx + 1]

          current_section = find_section_header(hr_node, current_section)

          body = collect_recipe_text(hr_node, next_hr)
          next if body.blank?
          break if body.match?(STOP_AT)
          next unless body.match?(RECIPE_PATTERN)

          chunks << {
            text: body,
            section_header: current_section,
            page_number: find_page_number(hr_node)
          }
        end

        chunks
      end

      private

      # Walk backwards from an <hr> to find the nearest <h2> section heading.
      def find_section_header(node, previous_section)
        current = node.previous
        while current
          if current.element? && current.name == SECTION_SELECTOR
            text = extract_text(current)
            return text if text.present? && text.length < 80
          end
          current = current.previous
        end
        previous_section
      end

      # Collect all text from sibling elements between this <hr> and the next,
      # skipping page-number spans, whitespace nodes, and section headings.
      def collect_recipe_text(start_node, end_node)
        texts = []
        current = start_node.next_sibling

        while current && current != end_node
          if current.element?
            break if current.name == SECTION_SELECTOR
            text = extract_text(current)
            texts << text if text.present?
          end
          current = current.next_sibling
        end

        texts.join("\n\n").strip
      end
    end

    Registry.register('soyeralexis', SoyeralexisStrategy)
  end
end
