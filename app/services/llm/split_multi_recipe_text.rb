# frozen_string_literal: true

module Llm
  # Identifies recipe boundaries in a text block that may contain multiple
  # concatenated recipes. Asks the LLM to return only the title strings
  # that start each recipe, then uses Ruby string matching to locate
  # those titles in the original text and split at those positions.
  #
  # This avoids both:
  #   - asking the LLM to echo verbatim text (JSON escaping failures)
  #   - line-number references (breaks on prose-style cookbooks where
  #     recipes start mid-line)
  #
  # Returns an array of hashes:
  #   [{ "title" => "Roast Beef", "text" => "Roast Beef. Take a rib..." }, ...]
  #
  # Returns a single-element array when the text contains only one recipe.
  #
  # Usage:
  #   chunks = Llm::SplitMultiRecipeText.call(text: long_input_text)
  class SplitMultiRecipeText
    DEFAULT_MODEL = "google/gemini-2.5-flash-lite"

    SYSTEM_PROMPT = <<~PROMPT.freeze
      Identify every distinct recipe in the text below. Return ONLY this JSON:
      {"recipes": [{"title": "<exact title as it appears in text>"}, ...]}

      Rules:
      - "title" must be the EXACT substring from the text that names the recipe,
        including punctuation (e.g. "Compôte of green currants.—" or "No. 47.—ROAST BEEF.").
        Copy it character-for-character so it can be found by string search.
      - Order the array by appearance in the text (first recipe first).
      - Boundaries: new recipe title, numbered recipe header, clear topic change.
      - Do NOT split sub-sections of one recipe (e.g. its sauce, its "Obs." note).
      - "Obs." or "Observation" paragraphs belong to the recipe they follow.
      - Chapter introductions or preambles are NOT recipes — skip them.
      - If the text contains only ONE recipe, return a single-element array.
      - If the text contains NO recipes at all, return: {"recipes": []}
      - Return ONLY valid JSON, no commentary.
    PROMPT

    def self.call(...)
      new(...).call
    end

    def initialize(text:, model: DEFAULT_MODEL, temperature: 0.2)
      @text = text
      @model = model
      @temperature = temperature
      @client = Llm::OpenRouterClient.new
    end

    def call
      raise ArgumentError, "Text is required" if @text.blank?

      result = @client.chat_completion(
        system_prompt: SYSTEM_PROMPT,
        user_content: @text,
        model: @model,
        temperature: @temperature,
        max_tokens: 2000,
        provider: Llm::OpenRouterClient::GOOGLE_PROVIDER
      )

      titles = extract_titles(result)
      split_text_by_titles(titles)
    end

    private

    def extract_titles(parsed)
      return [] if parsed.nil?

      recipes = if parsed.is_a?(Hash)
                  parsed["recipes"] || parsed.values.first
                else
                  parsed
                end

      recipes = [recipes] unless recipes.is_a?(Array)

      recipes.filter_map do |r|
        next unless r.is_a?(Hash) && r["title"].is_a?(String) && r["title"].present?
        r["title"]
      end
    end

    def split_text_by_titles(titles)
      return [{ "title" => nil, "text" => @text }] if titles.empty?

      positions = find_title_positions(titles)
      return [{ "title" => nil, "text" => @text }] if positions.empty?

      positions.each_with_index.map do |pos, idx|
        chunk_start = pos[:offset]
        chunk_end = if idx + 1 < positions.size
                      positions[idx + 1][:offset] - 1
                    else
                      @text.length - 1
                    end

        {
          "title" => pos[:title],
          "text" => @text[chunk_start..chunk_end].strip
        }
      end.reject { |r| r["text"].blank? }
    end

    def find_title_positions(titles)
      search_from = 0
      positions = []

      titles.each do |title|
        offset = find_title_in_text(title, search_from)
        next unless offset

        positions << { title: title, offset: offset }
        search_from = offset + title.length
      end

      positions.sort_by { |p| p[:offset] }
    end

    def find_title_in_text(title, search_from)
      offset = @text.index(title, search_from)
      return offset if offset

      normalized_title = title.unicode_normalize(:nfc)
      normalized_text = @text.unicode_normalize(:nfc)
      offset = normalized_text.index(normalized_title, search_from)
      return offset if offset

      escaped = Regexp.escape(title).gsub(/\s+/, '\s+')
      match = @text.match(/#{escaped}/i, search_from)
      match&.begin(0)
    end
  end
end
