# frozen_string_literal: true

module Datasets
  module V1
    class Tokenizer
      # Tokenize a single ingredient record using only the parsed product.
      # Returns the normalized token string, or nil if product is nil/blank.
      # Ingredients with nil product are excluded (no fallback to original_string).
      def self.call(product:)
        return nil unless product.present?

        normalize(product)
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
