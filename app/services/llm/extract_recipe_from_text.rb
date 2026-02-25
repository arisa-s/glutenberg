# frozen_string_literal: true

module Llm
  # Extracts a structured recipe from historical cookbook text via LLM.
  #
  # The LLM parses ingredients into structured form, then FdcEnrichment
  # adds foundation food metadata from the ingredient-parser library.
  #
  # Usage:
  #   result = Llm::ExtractRecipeFromText.call(text: ocr_text)
  class ExtractRecipeFromText
    class NoRecipeFoundError < StandardError; end

    SUPERSCRIPT_MAP = { '⁰' => '0', '¹' => '1', '²' => '2', '³' => '3', '⁴' => '4',
                        '⁵' => '5', '⁶' => '6', '⁷' => '7', '⁸' => '8', '⁹' => '9' }.freeze
    SUBSCRIPT_MAP   = { '₀' => '0', '₁' => '1', '₂' => '2', '₃' => '3', '₄' => '4',
                        '₅' => '5', '₆' => '6', '₇' => '7', '₈' => '8', '₉' => '9' }.freeze
    VULGAR_FRACTIONS = { '½' => '1/2', '⅓' => '1/3', '⅔' => '2/3', '¼' => '1/4', '¾' => '3/4',
                         '⅕' => '1/5', '⅖' => '2/5', '⅗' => '3/5', '⅘' => '4/5',
                         '⅙' => '1/6', '⅚' => '5/6',
                         '⅛' => '1/8', '⅜' => '3/8', '⅝' => '5/8', '⅞' => '7/8' }.freeze

    DEFAULT_MODEL = 'google/gemini-2.5-flash-lite'

    def self.call(...)
      new(...).call
    end

    def initialize(text:, model: DEFAULT_MODEL, temperature: 0.4)
      @text = text
      @model = model
      @temperature = temperature
      @client = Llm::OpenRouterClient.new
    end

    def call
      raise ArgumentError, 'Text is required' if @text.blank?

      normalized = normalize_text(@text)

      recipe = @client.chat_completion(
        system_prompt: Llm::Prompts::ExtractRecipe::SYSTEM_PROMPT,
        user_content: "[#{normalized}]",
        model: @model,
        temperature: @temperature,
        max_tokens: 12000
      )

      recipe = normalize_recipe_response(recipe)
      ensure_valid_recipe!(recipe)

      Llm::FdcEnrichment.enrich_ingredient_groups(recipe['ingredient_groups'])

      recipe
    end

    private

    def normalize_text(text)
      result = normalize_unicode_fractions(text)
      result = strip_page_markers(result)
      result.strip
    end

    def normalize_unicode_fractions(text)
      result = text.dup
      result.gsub!(/([⁰¹²³⁴⁵⁶⁷⁸⁹]+)\u2044([₀₁₂₃₄₅₆₇₈₉]+)/) do
        num = Regexp.last_match(1).chars.map { |c| SUPERSCRIPT_MAP[c] || c }.join
        den = Regexp.last_match(2).chars.map { |c| SUBSCRIPT_MAP[c] || c }.join
        "#{num}/#{den}"
      end
      VULGAR_FRACTIONS.each { |char, repl| result.gsub!(char, repl) }
      result
    end

    def strip_page_markers(text)
      text.gsub(/\[Pg\s*\d+\]/, '')
    end

    def normalize_recipe_response(parsed)
      return parsed unless parsed

      parsed = parsed.first if parsed.is_a?(Array) && parsed.first.is_a?(Hash)
      return parsed unless parsed.is_a?(Hash)

      if parsed.size == 1
        val = parsed.values.first
        if val.is_a?(Hash) && (val.key?('title') || val.key?('ingredient_groups'))
          parsed = val
        end
      end

      parsed['title'] = parsed.delete('name') if !parsed.key?('title') && parsed.key?('name')

      if !parsed.key?('ingredient_groups') && parsed.key?('ingredients')
        parsed['ingredient_groups'] = [{ 'purpose' => nil, 'ingredients' => parsed.delete('ingredients') }]
      end

      if !parsed.key?('instruction_groups') && parsed.key?('instructions')
        parsed['instruction_groups'] = [{ 'name' => nil, 'instructions' => parsed.delete('instructions') }]
      end

      if !parsed.key?('instruction_groups') && parsed.key?('steps')
        parsed['instruction_groups'] = [{ 'name' => nil, 'instructions' => parsed.delete('steps') }]
      end

      parsed
    end

    def ensure_valid_recipe!(recipe)
      if recipe.nil? || !recipe.is_a?(Hash) ||
         !recipe.key?('ingredient_groups') || !recipe.key?('title')
        raise NoRecipeFoundError, 'No recipe found in the provided text.'
      end
    end
  end
end
