# frozen_string_literal: true

# Split strategy for:
#   "The Lady’s Own Cookery Book, and New Dinner-Table Directory" (3rd ed.)
#   Gutenberg ID: 29232
#   URL: https://www.gutenberg.org/cache/epub/29232/pg29232-images.html
#
# Strict structure:
#   <h3 class="recipe">
#     <a id="Some_Anchor"></a>
#     <i>Recipe Title.</i>
#     Recipe subtitle (optional)
#   </h3>
#   ... body nodes ...
#   <h3 class="recipe"><i>Next Recipe.</i></h3>
#
# Sections/categories are typically <h2> headings.
#
module Gutenberg
  module Splitters
    class LadyBuryStrategy < Base
      # These are usually *variations* under the same recipe, not new recipes.
      # If a title matches one of these, we DO NOT start a new chunk; we keep it in the body.
      CONTINUATION_TITLES = /\A\s*(Another(\s+way)?|Another\s+one|Ditto|The\s+same)\.?\s*\z/i

      # Front matter / non-category h2 headings we don't want as section headers
      IGNORE_H2 = /\A\s*(PREFACE|CONTENTS|TRANSCRIBER[’']S\s+NOTE)\.?\s*\z/i

      def call(html)
        doc = parse(html)
        chunks = []

        recipe_h3s = doc.css('h3.recipe')

        recipe_h3s.each_with_index do |h3, idx|
          title = extract_recipe_title(h3)
          next if title.blank?

          # If this is a continuation title, do NOT start a new recipe chunk.
          # It will be captured as part of the previous chunk's body (see body collection below).
          next if title.match?(CONTINUATION_TITLES)

          next_h3 = recipe_h3s[idx + 1]
          body = collect_body_until_next_real_recipe(h3, next_h3)

          next if body.blank?

          chunks << {
            text: "#{title}\n\n#{body}",
            section_header: current_section_for(h3),
            page_number: find_page_number(h3)
          }
        end

        chunks
      end

      private

      def extract_recipe_title(h3)
        extract_text(h3)
      end

      # Collect siblings after this recipe heading, but stop at the next *real* recipe heading.
      # If the next heading is a continuation title ("Another."), we keep it as part of the body
      # and continue collecting until the next non-continuation recipe heading.
      def collect_body_until_next_real_recipe(start_h3, initial_next_h3)
        texts = []
        current = start_h3.next_sibling
        boundary = initial_next_h3

        while current
          if current.element? && current.name == 'h3' && current['class'].to_s.split.include?('recipe')
            t = extract_recipe_title(current)

            # Stop at the next real recipe title
            break if t.present? && !t.match?(CONTINUATION_TITLES)

            # Continuation title: keep it inside body and continue
            texts << t if t.present?
            current = current.next_sibling
            next
          end

          t = extract_text(current)
          texts << t if t.present?
          current = current.next_sibling

          # If Gutenberg kept headings as siblings, we’ll naturally encounter them.
          # `boundary` is just an initial hint; continuation headings may push it forward.
        end

        texts.join("\n\n").strip
      end

      # Best-effort section header: nearest preceding <h2> that doesn't look like front matter.
      def current_section_for(node)
        current = node.previous
        while current
          if current.element? && current.name == 'h2'
            t = extract_text(current)
            return t if t.present? && !t.match?(IGNORE_H2)
          end
          current = current.previous
        end
        nil
      end
    end

    Registry.register('ladybury', LadyBuryStrategy)
  end
end
