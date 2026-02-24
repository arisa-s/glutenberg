# frozen_string_literal: true

# Split strategy for:
#   "New system of domestic cookery" by Maria Eliza Ketelby Rundell (1807)
#   Gutenberg ID: 69519
#   URL: https://www.gutenberg.org/cache/epub/69519/pg69519-images.html
#
# HTML structure:
#   - Section headings: <h2 class="c006"> without <i>  (e.g. "FISH.", "SOUPS.")
#   - Recipe titles:    <h3 class="c013">, <h3 class="c011">,
#                       or <h2 class="c006"> containing <i>  (e.g. "Turkey to Boil.")
#   - Body paragraphs:  <p> with classes c014, c010, c015, or c012
#   - Page numbers:     <span class="pageno" id="Page_N">N</span>
#   - Some titles/headings are wrapped in <div> containers, so we traverse
#     in document order via XPath rather than sibling-walking.
#
module Gutenberg
  module Splitters
    class RundellmariaelizaketelbyStrategy < Base
      STOP_SECTIONS = /\A\s*(INDEX|USEFUL\s+DIRECTIONS)\b/i

      def call(html)
        doc = parse(html)
        chunks = []
        current_section = nil
        current_title   = nil
        current_body    = []
        last_page       = nil
        title_page      = nil

        all_nodes = doc.xpath(
          '//h2[contains(@class, "c006")] | ' \
          '//h3[contains(@class, "c013") or contains(@class, "c011")] | ' \
          '//p | ' \
          '//span[contains(@class, "pageno")]'
        )

        all_nodes.each do |node|
          case node.name
          when 'span'
            last_page = page_from_span(node) || last_page

          when 'h2'
            if node.at_css('i')
              # h2 with italic → recipe title (e.g. "Turkey to Boil.")
              flush_recipe(chunks, current_title, current_body, current_section, title_page)
              current_title = extract_text(node)
              current_body  = []
              title_page    = last_page
            else
              # Plain h2 → section header (e.g. "FISH.", "SOUPS.")
              flush_recipe(chunks, current_title, current_body, current_section, title_page)
              current_section = extract_text(node)
              current_title   = nil
              current_body    = []
              break if current_section&.match?(STOP_SECTIONS)
            end

          when 'h3'
            flush_recipe(chunks, current_title, current_body, current_section, title_page)
            current_title = extract_text(node)
            current_body  = []
            title_page    = last_page

          when 'p'
            if current_title
              text = extract_text(node)
              current_body << text if text.present?
            end
          end
        end

        # Flush the final recipe
        flush_recipe(chunks, current_title, current_body, current_section, title_page)

        chunks
      end

      private

      def flush_recipe(chunks, title, body, section, page)
        return if title.blank? || body.empty?

        chunks << {
          text: "#{title}\n\n#{body.join("\n\n")}",
          section_header: section,
          page_number: page
        }
      end
    end

    Registry.register('rundellmariaelizaketelby', RundellmariaelizaketelbyStrategy)
  end
end
