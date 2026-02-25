# frozen_string_literal: true

# Splits a recipe whose input_text contains multiple recipes into
# individual recipe records, extracts each one, and marks the
# original as not_a_recipe.
#
# Usage:
#   result = Extraction::SplitAndReextractService.call(recipe: recipe)
#   result # => { split: true, original: recipe, new_recipes: [...] }
#   result # => { split: false, reason: "Only one recipe detected" }
module Extraction
  class SplitAndReextractService
    EXTRACTOR_VERSION_PREFIX = "resplit"

    def self.call(...)
      new(...).call
    end

    def initialize(recipe:)
      @recipe = recipe
      @source = recipe.source
    end

    def call
      raise ArgumentError, "Recipe has no input_text" if @recipe.input_text.blank?

      chunks = Llm::SplitMultiRecipeText.call(text: @recipe.input_text)

      if chunks.size <= 1
        return { split: false, reason: "Only one recipe detected" }
      end

      new_recipes = Recipe.transaction do
        created = chunks.map.with_index(1) do |chunk, idx|
          recipe = Extraction::CreateRecipeService.call(
            source: @source,
            text: chunk["text"],
            input_type: @recipe.input_type,
            page_number: @recipe.page_number,
            extractor_version: extractor_version,
            raw_section_header: @recipe.raw_section_header
          )
          recipe.update_column(:notes, "Split from recipe #{@recipe.id}")
          recipe
        end

        @recipe.update!(not_a_recipe: true)

        created
      end

      { split: true, original: @recipe, new_recipes: new_recipes }
    end

    private

    def extractor_version
      base = ENV.fetch("EXTRACTOR_VERSION", Recipe::EXTRACTOR_VERSION)
      "#{EXTRACTOR_VERSION_PREFIX}-#{base}"
    end
  end
end
