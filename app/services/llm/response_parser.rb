# frozen_string_literal: true

require 'json'

module Llm
  # Robust JSON parser for LLM responses.
  #
  # Handles common LLM quirks: markdown code fences, trailing commas,
  # bare fractions as values, and responses wrapped in extra text.
  # Ported from souschef-flask-server's response_parser_utils.py.
  module ResponseParser
    module_function

    # Parse a JSON object or array from raw LLM output.
    # Returns nil when no valid JSON can be extracted.
    def parse_json(raw)
      return nil if raw.nil? || raw.strip.empty?

      text = raw.strip

      # Strip markdown code fences (```json ... ``` or ``` ... ```)
      if (m = text.match(/\A```(?:json)?\s*\n(.*?)\n?```\s*\z/m))
        text = m[1].strip
      end

      return nil if text.downcase == 'null'

      # Fast path: direct parse
      parsed = try_parse(text)
      return parsed if parsed

      # Fix trailing commas before } or ]
      cleaned = text.gsub(/,\s*([}\]])/, '\1')
      parsed = try_parse(cleaned)
      return parsed if parsed

      # Fix bare fractions used as JSON values (e.g. "quantity": 1/2 → 0.5)
      cleaned = cleaned.gsub(/(:\s*)(\d+)\s*\/\s*(\d+)(?=\s*[,}\]])/) do
        prefix, num, den = Regexp.last_match.values_at(1, 2, 3)
        den_i = den.to_i
        den_i.zero? ? Regexp.last_match[0] : "#{prefix}#{(num.to_f / den_i).round(4)}"
      end
      parsed = try_parse(cleaned)
      return parsed if parsed

      # Extract JSON object or array via regex
      [cleaned, text].each do |source|
        if (m = source.match(/(\[.*\]|\{.*\})/m))
          parsed = try_parse(m[1])
          return parsed if parsed
        end
      end

      Rails.logger.warn("[Llm::ResponseParser] No JSON found in LLM response (#{text.length} chars)")
      nil
    end

    # Attempt JSON parse with truncation recovery for arrays.
    # When the LLM response is cut off mid-array, salvages all
    # complete top-level objects found so far.
    def parse_json_with_truncation_recovery(raw)
      result = parse_json(raw)
      return result unless result.nil?
      return nil if raw.nil? || !raw.strip.start_with?('[')

      salvage_complete_objects(raw)
    end

    # Extract all complete top-level JSON objects from a truncated array.
    def salvage_complete_objects(raw)
      objects = []
      depth = 0
      obj_start = nil

      raw.each_char.with_index do |ch, i|
        if ch == '{'
          obj_start = i if depth.zero?
          depth += 1
        elsif ch == '}'
          depth -= 1
          if depth.zero? && obj_start
            begin
              objects << JSON.parse(raw[obj_start..i])
            rescue JSON::ParserError
              # skip malformed object
            end
            obj_start = nil
          end
        end
      end

      if objects.any?
        Rails.logger.info("[Llm::ResponseParser] Salvaged #{objects.size} object(s) from truncated response")
      end
      objects.presence
    end

    def try_parse(text)
      JSON.parse(text)
    rescue JSON::ParserError
      nil
    end
  end
end
