# frozen_string_literal: true

# Split strategy for:
#   "The Art of Cookery Made Easy and Refined" (PG 41352)
#
# Observed structure:
#   <div class="center"><i>Recipe Title.</i></div>
#   <p>Recipe body...</p>
#   <p>More body...</p>
#   ...
#   <div class="center"><i>Next Recipe.</i></div>
#
module Gutenberg
  module Splitters
    class JohnmollardStrategy < Base
      def call(html)
        doc = parse(html)
        chunks = []

        # All recipe title nodes
        title_divs = doc.css('div.center').select do |div|
          div.at_css('i') && extract_text(div.at_css('i')).present?
        end

        title_divs.each_with_index do |div, idx|
          title_node = div.at_css('i')
          title = extract_text(title_node)
          next if title.blank?

          next_div = title_divs[idx + 1]

          body = collect_text_between(div, next_div)
          next if body.blank?

          chunks << {
            text: "#{title}\n\n#{body}",
            section_header: current_section_for(div),
            page_number: find_page_number(div)
          }
        end

        chunks
      end

      private

      # Optional: detect section headers (ALL CAPS h3/h4)
      def current_section_for(node)
        current = node.previous
        while current
          if current.element?
            text = extract_text(current)
            if %w[h1 h2 h3 h4].include?(current.name) &&
               text.match?(/\A[A-Z\s]+\z/) &&
               text.length > 5
              return text
            end
          end
          current = current.previous
        end
        nil
      end
    end

    Registry.register('johnmollard', JohnmollardStrategy)
  end
end
