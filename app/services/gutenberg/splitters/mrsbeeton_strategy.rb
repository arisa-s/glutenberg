# frozen_string_literal: true

# Split strategy for:
#   "The Book of Household Management" by Mrs. Beeton
#   Gutenberg ID: 10136
#   URL: https://www.gutenberg.org/cache/epub/10136/pg10136-images.html
#
# Observed pattern:
#   - Recipes have a numbered ingredients line like:
#       "1153. INGREDIENTS.—Endive, mustard-and-cress, ..."
#   - The recipe title is typically the closest preceding heading-like line
#     (often h4/h5, sometimes a short standalone paragraph line).
#   - Body continues until the next recipe's title/ingredients block.
#
module Gutenberg
  module Splitters
    class MrsbeetonStrategy < Base
      # Matches: "703. INGREDIENTS.—..." (dash may vary by encoding)
      INGREDIENTS_LINE = /\A\s*\d+\.\s*INGREDIENTS\.\s*[—-]\s*/i

      # Chapter heading (used as section_header)
      CHAPTER_HEADING = /\A\s*CHAPTER\s+[IVXLCDM]+\.\s*\z/i

      # Common non-title lines we should not treat as titles when scanning backwards
      NOT_A_TITLE = /\A\s*(Mode|Time|Average cost|Sufficient|Seasonable|Note)\b/i

      def call(html)
        doc = parse(html)
        chunks = []

        # Scan a broad set of block-ish nodes in document order.
        # (This book is huge; headings/paras carry most meaningful structure.)
        blocks = doc.css('h1,h2,h3,h4,h5,p,div')

        # 1) Identify each recipe by locating its INGREDIENTS line node,
        #    then finding its title node by walking backwards.
        recipe_starts = []

        blocks.each do |node|
          text = extract_text(node)
          next if text.blank?
          next unless text.match?(INGREDIENTS_LINE)

          title_node = find_title_node_for_ingredients(node)
          next unless title_node # skip if we can’t confidently locate a title

          recipe_starts << { title_node: title_node, ingredients_node: node }
        end

        # De-dup starts where multiple ingredients nodes map to the same title node (rare, but possible)
        recipe_starts.uniq! { |h| h[:title_node].object_id }

        # 2) Create chunks by collecting from title_node -> next title_node (exclusive)
        recipe_starts.each_with_index do |start, idx|
          title_node = start[:title_node]
          next_start = recipe_starts[idx + 1]
          next_title_node = next_start && next_start[:title_node]

          title = extract_text(title_node)
          next if title.blank?

          body = collect_text_forward_until(title_node, next_title_node)
          next if body.blank?

          chunks << {
            text: "#{title}\n\n#{body}",
            section_header: current_chapter_for(title_node),
            page_number: find_page_number(title_node)
          }
        end

        chunks
      end

      private

      # Reject ONLY lines that are entirely a parenthetical descriptor:
      # "(Sweet Entremets.)"
      PAREN_DESCRIPTOR_ONLY = /\A\s*\([^)]*\)\.?\s*\z/

      def find_title_node_for_ingredients(ingredients_node)
        current = ingredients_node.previous

        while current
          if current.element?
            text = extract_text(current)

            # Skip descriptor-only lines (but DO NOT skip titles that merely contain parentheses)
            if text.blank? || text.match?(INGREDIENTS_LINE) || text.match?(NOT_A_TITLE) || text.match?(PAREN_DESCRIPTOR_ONLY)
              current = current.previous
              next
            end

            return current if plausible_title_node?(current, text)
          end

          current = current.previous
        end

        nil
      end

      def plausible_title_node?(node, text)
        t = text.to_s.strip
        return false if t.blank?
        return false if t.match?(PAREN_DESCRIPTOR_ONLY) # key: only reject descriptor-only
        return false if t.match?(INGREDIENTS_LINE)
        return false if t.match?(NOT_A_TITLE)
        return false if t.length > 160

        # Prefer actual headings when present
        return true if %w[h4 h5].include?(node.name)

        return false unless node.name == 'p'

        words = t.split
        return false if words.size > 22

        # Avoid sentence-y lines (but allow one trailing period)
        return false if t.match?(/[.!?].+[.!?]/)

        # Evaluate "title-ness" primarily on the part BEFORE any parenthetical commentary
        base = t.split('(').first.to_s.strip
        return false if base.blank?

        letters = base.gsub(/[^A-Za-z]/, '')
        return false if letters.length < 4

        uppercase_ratio = letters.count('A-Z').to_f / letters.length

        # Beeton titles are typically ALL CAPS in the base part (e.g., "VEAL CAKE")
        uppercase_ratio > 0.75
      end


      # Collect text in document order until the next title node.
      # (More robust than sibling-only collection in case of wrapper divs.)
      def collect_text_forward_until(start_node, end_node)
        texts = []
        current = start_node.next

        while current && current != end_node
          if current.element?
            t = extract_text(current)
            texts << t if t.present?
          end
          current = current.next
        end

        texts.join("\n\n").strip
      end

      # Best-effort section header: nearest preceding CHAPTER heading.
      def current_chapter_for(node)
        current = node.previous
        while current
          if current.element?
            t = extract_text(current)
            return t if t.present? && t.match?(CHAPTER_HEADING)
          end
          current = current.previous
        end
        nil
      end
    end

    Registry.register('mrsbeeton', MrsbeetonStrategy)
  end
end
