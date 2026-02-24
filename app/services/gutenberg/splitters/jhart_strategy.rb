# frozen_string_literal: true

# Split strategy for:
#   "High-class cookery made easy" by Mrs. J. Hart
#   Gutenberg ID: 69334
#   URL: https://www.gutenberg.org/cache/epub/69334/pg69334-images.html
#
# Pattern observed:
#   - Major sections are headings like "SOUPS.", "FISH.", etc. (typically <h2>)
#   - Individual recipes are headings like "BROWN SOUP.", "FRIED HADDOCK.", etc. (typically <h3>)
#   - Some sub-headings exist (e.g. "How To Boil Rice...") which we keep inside the recipe body
#
# Strategy:
#   - Track current_section when we encounter an <h2>
#   - Create a recipe chunk for each <h3>, collecting text until the next <h3> or <h2>
#
module Gutenberg
  module Splitters
    class JhartStrategy < Base
      # Front-matter headings we don't want as section headers for recipe chunks.
      FRONT_MATTER_SECTIONS = /\A\s*(PREFATORY NOTE|CONTENTS|THE FULL PROJECT GUTENBERG LICENSE)\.?\s*\z/i

      # Some <h3> headings in these books can be “hint”/editorial rather than a recipe.
      # Keep this conservative; it’s easy to expand if you see more.
      NON_RECIPE_H3 = /\A\s*A Hint\b/i

      def call(html)
        doc = parse(html)
        chunks = []

        # Use all h2/h3 in document order as boundaries.
        headings = doc.css('h2, h3')

        current_section = nil

        headings.each_with_index do |node, idx|
          text = extract_text(node)
          next if text.blank?

          if node.name == 'h2'
            # Update section header, but skip obvious front matter.
            current_section = text unless text.match?(FRONT_MATTER_SECTIONS)
            next
          end

          # node is h3: treat as recipe title unless it looks like a non-recipe hint.
          next if text.match?(NON_RECIPE_H3)

          next_heading = headings[idx + 1] # could be h2 or h3
          body = collect_text_between(node, next_heading)

          # Some recipes are just a short paragraph; keep them if there is any body at all.
          next if body.blank?

          chunks << {
            text: "#{text}\n\n#{body}",
            section_header: current_section,
            page_number: find_page_number(node)
          }
        end

        chunks
      end
    end

    Registry.register('jhart', JhartStrategy)
  end
end
