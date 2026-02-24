# frozen_string_literal: true

# Split strategy for:
#   "A Handbook of Cookery for a Small House" by Jessie Conrad
#   Gutenberg ID: 67482
#   URL: https://www.gutenberg.org/cache/epub/67482/pg67482-images.html
#
# Observed structure in the RECIPES portion:
#   - Category/section headers are <h3> (e.g. "BREAKFAST DISHES, ...")
#   - Recipe titles are <h4> headings that start with a number, e.g. "1. Omelettes"
#   - Non-recipe <h4> like "General Remarks" appear and should be ignored as recipe starts
#
# Strategy:
#   - Track current_section from <h3>
#   - Split on numbered <h4> only: /^\s*\d+\.\s+/
#   - For each recipe <h4>, collect text until the next numbered <h4> OR next <h3>
#   - Strip the leading "N. " from the title for cleaner downstream title extraction
#
module Gutenberg
  module Splitters
    class JessieconradStrategy < Base
      NUMBERED_RECIPE = /\A\s*(\d+)\.\s+(.+)\z/
      NON_RECIPE_H4 = /\A\s*General Remarks\s*\z/i

      def call(html)
        doc = parse(html)
        chunks = []

        headings = doc.css('h3, h4')
        current_section = nil

        # Precompute the “real recipe title nodes” for boundary detection
        recipe_h4_nodes = headings.select do |n|
          n.name == 'h4' && extract_text(n).match?(NUMBERED_RECIPE)
        end

        headings.each do |node|
          text = extract_text(node)
          next if text.blank?

          if node.name == 'h3'
            current_section = text
            next
          end

          # node is h4
          next if text.match?(NON_RECIPE_H4)

          m = text.match(NUMBERED_RECIPE)
          next unless m # only split on numbered h4s

          # Use the next numbered recipe h4, otherwise stop at the next heading (often an h3)
          idx = recipe_h4_nodes.index(node)
          next_recipe = recipe_h4_nodes[idx + 1] if idx

          # If there's an h3 between this recipe and the next numbered recipe, prefer that as the boundary.
          next_heading = node.xpath('following-sibling::*[self::h3 or self::h4]').first
          boundary = next_heading

          # If the next heading is a numbered recipe h4, that's fine; if it's an h3, also fine.
          # But if the next heading is some non-numbered h4 (rare), we'll still use it as the boundary.
          # The collect_text_between helper stops when it hits the boundary node we pass in.
          #
          # If there is a next numbered recipe and it comes before the next h3, boundary should be that recipe.
          if next_recipe
            # Compare document order by checking which appears first as a following sibling.
            first_numbered_after = node.xpath('following-sibling::h4').find do |h4|
              extract_text(h4).match?(NUMBERED_RECIPE)
            end
            boundary = first_numbered_after if first_numbered_after
          end

          title = m[2].strip
          body = collect_text_between(node, boundary)
          next if body.blank?

          chunks << {
            text: "#{title}\n\n#{body}",
            section_header: current_section,
            page_number: find_page_number(node)
          }
        end

        chunks
      end
    end

    Registry.register('jessieconrad', JessieconradStrategy)
  end
end
