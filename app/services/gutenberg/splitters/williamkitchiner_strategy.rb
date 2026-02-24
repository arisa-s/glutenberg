# frozen_string_literal: true

# Split strategy for:
#   "The Cook's Oracle; and Housekeeper's Manual" by William Kitchiner
#   Gutenberg ID: 28681
#   URL: https://www.gutenberg.org/cache/epub/28681/pg28681-images.html
#
# Observed structure:
#   - Chapter and major section headers are <h2> (e.g., "CHAPTER VII.", "BROTHS, GRAVIES, AND SOUPS.")
#   - Individual receipts are headings (usually <h3>) containing "(No. N.)"
#     e.g. "Rabbit.—(No. 67.)", "Beef Broth.—(No. 185.)"
#   - Body text runs until the next receipt heading.
#
module Gutenberg
  module Splitters
    class WilliamkitchinerStrategy < Base
      # Matches recipe titles containing "(No. 185.)" including star suffixes like "69*."
      # and cross-references like "(No. 361. See No. 511.)"
      RECEIPT_NO = /\(\s*No\.\s*\d+[A-Za-z*]*\.[^)]*\)/i

      # Captures the leading integer from the first "(No. NNN...)" in a string.
      RECEIPT_NO_CAPTURE = /\(\s*No\.\s*(\d+)/i

      # Chapter headings like "CHAPTER VII."
      CHAPTER = /\A\s*CHAPTER\s+[IVXLCDM]+\.\s*\z/i

      # Stop once we hit back matter index (best-effort)
      STOP_AT = /\A\s*(INDEX|FINIS)\b/i

      def call(html)
        doc = parse(html)
        chunks = []

        heading_nodes = doc.css('h2, h3, h4')

        current_section = nil
        recipe_titles = heading_nodes.select { |n| recipe_title?(n) }

        heading_nodes.each do |node|
          text = extract_text(node)
          next if text.blank?

          break if text.match?(STOP_AT)

          # update section header
          if section_header?(node, text)
            current_section = text
            next
          end

          next unless recipe_title?(node)

          idx = recipe_titles.index(node)
          next_title_node = recipe_titles[idx + 1] if idx

          title = extract_text(node)
          body  = collect_text_between(node, next_title_node)
          next if body.blank?

          chunks << {
            text: "#{title}\n\n#{body}",
            section_header: current_section,
            page_number: find_page_number(node),
            recipe_number: extract_recipe_number(title)
          }
        end

        chunks
      end

      private

      def recipe_title?(node)
        return false unless %w[h3 h4].include?(node.name)

        t = extract_text(node)
        return false if t.blank?
        t.match?(RECEIPT_NO)
      end

      def extract_recipe_number(title)
        match = title&.match(RECEIPT_NO_CAPTURE)
        match[1].to_i if match
      end

      def section_header?(node, text)
        return false unless node.name == 'h2'
        return true if text.match?(CHAPTER)

        # Many major sections are uppercase-y (e.g. "BROTHS, GRAVIES, AND SOUPS.")
        letters = text.gsub(/[^A-Za-z]/, '')
        return false if letters.length < 6
        (letters.count('A-Z').to_f / letters.length) > 0.75
      end
    end

    Registry.register('williamkitchiner', WilliamkitchinerStrategy)
  end
end
