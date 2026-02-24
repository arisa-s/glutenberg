# frozen_string_literal: true

require 'nokogiri'

# Base class for book-specific splitters.
#
# Contract:
#   - Subclass must implement #call(html) -> Array<Hash>
#   - Each hash has:
#       :text            [String]      — the recipe text chunk (title included)
#       :section_header  [String, nil] — the book section this recipe belongs to
#                                        (e.g. chapter heading). nil if unknown.
#       :page_number     [Integer, nil] — original book page where the recipe starts.
#       :recipe_number   [Integer, nil] — the recipe's number in the book (e.g. "No. 47").
#                                         Only strategies with numbered recipes include this.
#   - The Flask service handles title extraction from the text.
#
# Subclasses can use the Nokogiri helper methods provided here.
#
module Gutenberg
  module Splitters
    class Base
      def self.call(html)
        new.call(html)
      end

      # @param html [String] raw HTML of the book
      # @return [Array<Hash>] array of { text:, section_header:, page_number:, recipe_number: } hashes
      def call(html)
        raise NotImplementedError, "#{self.class}#call must be implemented"
      end

      private

      # Parse HTML into a Nokogiri document.
      def parse(html)
        Nokogiri::HTML(html)
      end

      # Extract visible text from a Nokogiri node, stripping excess whitespace.
      def extract_text(node)
        return '' if node.nil?

        node.text.gsub(/\s+/, ' ').strip
      end

      # Collect text from all sibling nodes between two boundary nodes.
      # Returns the concatenated text content.
      def collect_text_between(start_node, end_node)
        texts = []
        current = start_node.next_sibling

        while current && current != end_node
          text = extract_text(current)
          texts << text if text.present?
          current = current.next_sibling
        end

        texts.join("\n\n")
      end

      # Collect the inner HTML from all sibling nodes between two boundary nodes.
      def collect_html_between(start_node, end_node)
        parts = []
        current = start_node.next_sibling

        while current && current != end_node
          parts << current.to_html
          current = current.next_sibling
        end

        parts.join
      end

      # Find the original book page number for a recipe title node by walking
      # backwards through preceding siblings looking for a Gutenberg page marker.
      #
      # Gutenberg books use two common patterns:
      #   <span class="pagenum"><a id="Page_15">[15]</a></span>   (e.g. Francatelli)
      #   <span class="pageno" id="Page_42">42</span>             (e.g. Eliza Acton)
      #
      # Returns the page number as an Integer, or nil if not found / non-numeric.
      def find_page_number(title_node)
        current = title_node.previous
        while current
          if current.element?
            page = extract_page_from_node(current)
            return page if page
          end
          current = current.previous
        end
        nil
      end

      # Try to extract a numeric page number from a single node (or its children).
      def extract_page_from_node(node)
        # Direct match: the node itself is a page-number span
        span = if node.name == 'span' && node['class']&.match?(/\bpagenum\b|\bpageno\b/)
                 node
               else
                 # Check inside the node (e.g. a wrapper div)
                 node.at_css('span.pagenum, span.pageno')
               end
        return nil unless span

        page_from_span(span)
      end

      # Extract an integer page number from a page-number span, trying multiple
      # patterns used across different Gutenberg books.
      def page_from_span(span)
        # Pattern 1: anchor child with id like "Page_15"
        anchor = span.at_css('a[id]')
        if anchor && (m = anchor['id'].match(/\APage_(\d+)\z/))
          return m[1].to_i
        end

        # Pattern 2: span itself has id like "Page_42"
        if span['id'] && (m = span['id'].match(/\APage_(\d+)\z/))
          return m[1].to_i
        end

        # Pattern 3: text content like "[15]" or bare "42"
        text = span.text.strip
        if (m = text.match(/\[(\d+)\]/))
          return m[1].to_i
        end
        if text.match?(/\A\d+\z/)
          return text.to_i
        end

        # Roman numerals (front matter) — skip, not useful for recipe pages
        nil
      end
    end
  end
end
