# frozen_string_literal: true

# Base class for Internet Archive book-specific splitters.
#
# Unlike the Gutenberg Base (which uses Nokogiri for HTML), this base class
# provides text-based helper methods for working with OCR plain text output.
#
# Contract:
#   - Subclass must implement #call(text) -> Array<Hash>
#   - Each hash has:
#       :text            [String]      — the recipe text chunk (title included)
#       :section_header  [String, nil] — the book section this recipe belongs to
#                                        (e.g. chapter heading). nil if unknown.
#       :page_number     [Integer, nil] — original book page where the recipe starts.
#       :recipe_number   [Integer, nil] — the recipe's number in the book (e.g. "No. 47").
#                                         Only strategies with numbered recipes include this.
#   - The Flask service handles title extraction from the text.
#
module InternetArchive
  module Splitters
    class Base
      def self.call(text)
        new.call(text)
      end

      # @param text [String] raw OCR text of the book
      # @return [Array<Hash>] array of { text:, section_header:, page_number:, recipe_number: } hashes
      def call(text)
        raise NotImplementedError, "#{self.class}#call must be implemented"
      end

      private

      # -----------------------------------------------------------------
      # Line helpers
      # -----------------------------------------------------------------

      # Split text into an array of lines, preserving blank lines.
      def lines(text)
        text.lines.map(&:chomp)
      end

      # Find indices of lines matching a regex pattern.
      # @param text_lines [Array<String>] array of text lines
      # @param pattern [Regexp] pattern to match against each line
      # @return [Array<Integer>] sorted array of matching line indices
      def find_boundaries(text_lines, pattern)
        text_lines.each_with_index.filter_map { |line, idx| idx if line.strip.match?(pattern) }
      end

      # Collect text from lines between two indices (exclusive of boundaries).
      # @param text_lines [Array<String>] array of text lines
      # @param start_idx [Integer] start line index (exclusive)
      # @param end_idx [Integer, nil] end line index (exclusive); nil means to the end
      # @return [String] joined text between the boundaries
      def collect_text_between(text_lines, start_idx, end_idx)
        end_idx ||= text_lines.length
        return '' if start_idx + 1 >= end_idx

        text_lines[(start_idx + 1)...end_idx]
          .reject { |line| line.strip.empty? && false } # keep blank lines for paragraph structure
          .join("\n")
          .strip
      end

      # Collect text from a start index (inclusive) to an end index (exclusive).
      # Useful for including the title line itself in the chunk.
      # @param text_lines [Array<String>] array of text lines
      # @param start_idx [Integer] start line index (inclusive)
      # @param end_idx [Integer, nil] end line index (exclusive); nil means to the end
      # @return [String] joined text
      def collect_chunk(text_lines, start_idx, end_idx)
        end_idx ||= text_lines.length
        return '' if start_idx >= end_idx

        text_lines[start_idx...end_idx].join("\n").strip
      end

      # -----------------------------------------------------------------
      # Pattern detection helpers
      # -----------------------------------------------------------------

      # Check if a line is ALL CAPS (common for headings in OCR'd cookbooks).
      # Requires at least 3 alphabetic characters to avoid matching numbers/punctuation.
      def all_caps_line?(line)
        stripped = line.strip
        return false if stripped.empty?

        alpha_chars = stripped.scan(/[A-Za-z]/)
        return false if alpha_chars.length < 3

        alpha_chars.all? { |c| c == c.upcase }
      end

      # Check if a line looks like a numbered recipe entry.
      # Matches patterns like: "1.", "No. 1.", "RECIPE I.", "I.—", "123."
      NUMBERED_PATTERNS = [
        /\A\d+\.\s/,                      # "1. Roast Beef"
        /\ANo\.\s*\d+/i,                  # "No. 1. Roast Beef" or "NO. 42."
        /\A[IVXLCDM]+\.\s*[—\-\s]/,       # "I.— Roast Beef" (Roman + dash)
        /\A[IVXLCDM]+\.\s+[A-Z]/          # "I. Roast Beef" (Roman + space + capital)
      ].freeze

      def numbered_entry?(line)
        stripped = line.strip
        NUMBERED_PATTERNS.any? { |p| stripped.match?(p) }
      end

      # -----------------------------------------------------------------
      # Text splitting helpers
      # -----------------------------------------------------------------

      # Split text into groups separated by one or more blank lines.
      # Returns an array of text blocks (each block is a string).
      def blank_line_split(text)
        text.split(/\n\s*\n/).map(&:strip).reject(&:empty?)
      end

      # -----------------------------------------------------------------
      # Page number helpers
      # -----------------------------------------------------------------

      # Search backwards from a line index for a page number marker.
      # Internet Archive OCR text sometimes includes page markers like:
      #   "[p. 42]", "— 42 —", or just a standalone number on its own line.
      #
      # This is a best-effort heuristic; subclasses can override for
      # book-specific page marker formats.
      PAGE_MARKER_PATTERNS = [
        /\[p\.?\s*(\d+)\]/i,              # "[p. 42]" or "[p42]"
        /\A\s*[-—]+\s*(\d+)\s*[-—]+\s*\z/, # "— 42 —"
        /\A\s*(\d+)\s*\z/                  # standalone number on its own line
      ].freeze

      def find_page_number(text_lines, idx)
        # Walk backwards up to 5 lines looking for a page marker
        search_start = [idx - 5, 0].max
        (idx - 1).downto(search_start) do |i|
          line = text_lines[i]
          PAGE_MARKER_PATTERNS.each do |pattern|
            match = line.match(pattern)
            return match[1].to_i if match
          end
        end
        nil
      end

      # -----------------------------------------------------------------
      # Text cleaning helpers
      # -----------------------------------------------------------------

      # Clean up common OCR artifacts in 18th-century text.
      # Does NOT normalize long-s (ſ → s) because the Flask LLM service
      # handles historical text well, and normalizing could lose information.
      def clean_ocr_text(text)
        text
          .gsub(/\r\n/, "\n")           # normalize line endings
          .gsub(/[ \t]+/, ' ')          # collapse multiple spaces/tabs
          .gsub(/\n{3,}/, "\n\n")       # collapse 3+ newlines to double
          .strip
      end
    end
  end
end
