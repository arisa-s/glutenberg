# frozen_string_literal: true

require "rails_helper"

RSpec.describe Datasets::V1::Scope do
  def create_source!(attrs = {})
    Source.create!({
      title: "Test Book",
      provider: "gutenberg",
      publication_year: 1800,
      included_in_corpus: true
    }.merge(attrs))
  end

  def create_recipe!(source, attrs = {})
    Recipe.unscoped.create!({
      source: source,
      title: "Test Recipe",
      extraction_status: "success",
      not_a_recipe: false,
      extraction_failed_count: 0,
      category: "soup_stew"
    }.merge(attrs))
  end

  def add_ingredients!(recipe, count:)
    group = IngredientGroup.create!(recipe: recipe)
    count.times do |i|
      Ingredient.unscoped.create!(
        ingredient_group: group,
        product: "ingredient #{i}",
        original_string: "1 cup ingredient #{i}"
      )
    end
  end

  def add_instructions!(recipe, steps:)
    group = InstructionGroup.create!(recipe: recipe)
    steps.each do |step_text|
      Instruction.create!(instruction_group: group, step: step_text)
    end
  end

  def build_valid_recipe!(source, title: "Good Recipe", extra_attrs: {})
    recipe = create_recipe!(source, { title: title }.merge(extra_attrs))
    add_ingredients!(recipe, count: 5)
    long_step = "Cook everything together until done. " * 5
    add_instructions!(recipe, steps: [long_step])
    recipe
  end

  describe "#recipe_ids" do
    it "includes a fully valid recipe" do
      source = create_source!
      recipe = build_valid_recipe!(source)
      scope  = described_class.new

      expect(scope.recipe_ids).to include(recipe.id)
    end

    it "excludes recipes from excluded sources" do
      source = create_source!(included_in_corpus: false)
      recipe = build_valid_recipe!(source)
      scope  = described_class.new

      expect(scope.recipe_ids).not_to include(recipe.id)
    end

    it "excludes recipes marked not_a_recipe" do
      source = create_source!
      recipe = build_valid_recipe!(source, extra_attrs: { not_a_recipe: true })
      scope  = described_class.new

      expect(scope.recipe_ids).not_to include(recipe.id)
    end

    it "excludes failed recipes" do
      source = create_source!
      recipe = build_valid_recipe!(source, extra_attrs: { extraction_status: "failed" })
      scope  = described_class.new

      expect(scope.recipe_ids).not_to include(recipe.id)
    end

    it "excludes recipes with extraction_failed_count > max" do
      source = create_source!
      recipe = build_valid_recipe!(source, extra_attrs: { extraction_failed_count: 4 })
      scope  = described_class.new(max_failed_count: 3)

      expect(scope.recipe_ids).not_to include(recipe.id)
    end

    it "excludes recipes with blank title" do
      source = create_source!
      recipe = build_valid_recipe!(source, extra_attrs: { title: "", parsed_title: nil })
      scope  = described_class.new

      expect(scope.recipe_ids).not_to include(recipe.id)
    end

    it "includes recipe with parsed_title when title is blank" do
      source = create_source!
      recipe = build_valid_recipe!(source, extra_attrs: { title: nil, parsed_title: "A Good Soup" })
      scope  = described_class.new

      expect(scope.recipe_ids).to include(recipe.id)
    end

    it "excludes household_misc category" do
      source = create_source!
      recipe = build_valid_recipe!(source, extra_attrs: { category: "household_misc" })
      scope  = described_class.new

      expect(scope.recipe_ids).not_to include(recipe.id)
    end

    it "excludes other_unknown category" do
      source = create_source!
      recipe = build_valid_recipe!(source, extra_attrs: { category: "other_unknown" })
      scope  = described_class.new

      expect(scope.recipe_ids).not_to include(recipe.id)
    end

    it "includes recipes with nil category" do
      source = create_source!
      recipe = build_valid_recipe!(source, extra_attrs: { category: nil })
      scope  = described_class.new

      expect(scope.recipe_ids).to include(recipe.id)
    end

    it "excludes recipes with fewer than min_ingredients" do
      source = create_source!
      recipe = create_recipe!(source)
      add_ingredients!(recipe, count: 2)
      add_instructions!(recipe, steps: ["Cook well. " * 10])
      scope = described_class.new(min_ingredients: 3)

      expect(scope.recipe_ids).not_to include(recipe.id)
    end

    it "excludes recipes with no instructions" do
      source = create_source!
      recipe = create_recipe!(source)
      add_ingredients!(recipe, count: 5)
      scope = described_class.new

      expect(scope.recipe_ids).not_to include(recipe.id)
    end

    it "excludes recipes with instruction_char_count below threshold" do
      source = create_source!
      recipe = create_recipe!(source)
      add_ingredients!(recipe, count: 5)
      add_instructions!(recipe, steps: ["Short."])
      scope = described_class.new(min_inst_chars: 80)

      expect(scope.recipe_ids).not_to include(recipe.id)
    end
  end

  describe "per-source cap and deterministic ordering" do
    it "caps recipes per source" do
      source = create_source!
      5.times { |i| build_valid_recipe!(source, title: "Recipe #{i}") }
      scope = described_class.new(cap_per_source: 3)

      expect(scope.recipe_ids.size).to eq(3)
    end

    it "produces the same ids with the same seed" do
      source = create_source!
      10.times { |i| build_valid_recipe!(source, title: "Recipe #{i}") }

      ids_a = described_class.new(cap_per_source: 5, seed: 42).recipe_ids
      ids_b = described_class.new(cap_per_source: 5, seed: 42).recipe_ids

      expect(ids_a).to eq(ids_b)
    end

    it "produces different ids with different seeds (usually)" do
      source = create_source!
      10.times { |i| build_valid_recipe!(source, title: "Recipe #{i}") }

      ids_a = described_class.new(cap_per_source: 3, seed: 1).recipe_ids.sort
      ids_b = described_class.new(cap_per_source: 3, seed: 999).recipe_ids.sort

      expect(ids_a).not_to eq(ids_b)
    end

    it "caps independently per source" do
      source_a = create_source!(title: "Book A")
      source_b = create_source!(title: "Book B", external_id: "b-1")
      5.times { |i| build_valid_recipe!(source_a, title: "A Recipe #{i}") }
      5.times { |i| build_valid_recipe!(source_b, title: "B Recipe #{i}") }

      scope = described_class.new(cap_per_source: 3)
      ids   = scope.recipe_ids

      a_count = Recipe.unscoped.where(id: ids, source: source_a).count
      b_count = Recipe.unscoped.where(id: ids, source: source_b).count

      expect(a_count).to eq(3)
      expect(b_count).to eq(3)
    end
  end
end
