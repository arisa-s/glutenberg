# frozen_string_literal: true

# Resolves ingredient → recipe cross-references for all recipes within a source.
#
# Run this after all recipes from a book have been extracted so that every
# candidate target recipe exists in the database.
#
# Resolution strategy (in priority order):
#   1. Match by recipe_number (most reliable for numbered books)
#   2. Match by page_number (when a single recipe occupies the referenced page)
#   3. Match by title similarity (case-insensitive exact, then substring)
#
# Usage:
#   resolved = Extraction::ResolveRecipeReferencesService.call(source: source)
#   # => 12  (number of ingredients that were linked to a recipe)
#
module Extraction
  class ResolveRecipeReferencesService
    def self.call(...)
      new(...).call
    end

    def initialize(source:)
      @source = source
    end

    def call
      candidates = @source.recipes.successful
      unresolved = unresolved_ingredients

      resolved_count = 0
      unresolved.find_each do |ingredient|
        match = find_match(ingredient, candidates)
        next unless match

        ingredient.update_columns(referenced_recipe_id: match.id)
        resolved_count += 1
      end
      resolved_count
    end

    private

    def unresolved_ingredients
      Ingredient.unresolved_refs
                .joins(ingredient_group: :recipe)
                .where(recipes: { source_id: @source.id })
    end

    def find_match(ingredient, candidates)
      own_recipe_id = ingredient.ingredient_group&.recipe_id
      scope = candidates.where.not(id: own_recipe_id)
      ref = ingredient.recipe_ref
      return nil unless ref.is_a?(Hash)

      match_by_number(scope, ref) ||
        match_by_page(scope, ref) ||
        match_by_title(scope, ref)
    end

    def match_by_number(scope, ref)
      num = ref['ref_number']
      return nil if num.blank?

      scope.find_by(recipe_number: num)
    end

    def match_by_page(scope, ref)
      page = ref['ref_page']
      return nil if page.blank?

      on_page = scope.where(page_number: page)
      on_page.first if on_page.count == 1
    end

    def match_by_title(scope, ref)
      title = ref['ref_title']
      return nil if title.blank?

      scope.where('LOWER(title) = LOWER(?)', title).first ||
        scope.where('LOWER(title) LIKE LOWER(?)', "%#{sanitize_like(title)}%").first
    end

    def sanitize_like(str)
      str.gsub(/[%_\\]/) { |m| "\\#{m}" }
    end
  end
end
