# frozen_string_literal: true

module Datasets
  module V1
    class Tokenizer
      # Tokenize a single ingredient record.
      # Returns the normalized token string, or nil if the result is blank.
      #
      #   product:         the parsed product name (may be nil/blank)
      #   original_string: the raw ingredient text (fallback)
      def self.call(product:, original_string:)
        raw = product.present? ? product : original_string
        normalize(raw)
      end

      # Normalize an arbitrary string into a canonical token.
      # Returns nil if the result is blank after normalization.
      def self.normalize(raw)
        return nil if raw.nil?

        token = raw.dup
        token.downcase!
        token.strip!
        token.gsub!(/[^\p{L}\p{N}\s\-]/, " ")
        token.gsub!(/\s+/, " ")
        token.strip!
        token.empty? ? nil : token
      end
    end
  end
end
