# frozen_string_literal: true

class Ingredient < ApplicationRecord
  belongs_to :ingredient_group
  belongs_to :referenced_recipe, class_name: 'Recipe', optional: true
  has_many :substitutions, dependent: :destroy

  default_scope { order(order: :asc) }

  # Foundation food scopes
  scope :with_foundation_food, -> { where.not(foundation_food_id: nil) }
  scope :without_foundation_food, -> { where(foundation_food_id: nil) }
  scope :by_category, ->(category) { where(foundation_food_category: category) }
  scope :by_product, ->(product) { where(product: product) }

  # Recipe cross-reference scopes
  scope :with_recipe_ref, -> { where.not(recipe_ref: nil) }
  scope :unresolved_refs, -> { with_recipe_ref.where(referenced_recipe_id: nil) }
  scope :resolved_refs, -> { where.not(referenced_recipe_id: nil) }

  def recipe
    ingredient_group&.recipe
  end

  # Returns the ingredient name using the specified normalization strategy.
  #
  # Strategies:
  #   :raw        - parsed product name (e.g., "butter")
  #   :foundation - standardized FDC name (e.g., "Butter, unsalted")
  #   :category   - FDC category (e.g., "Dairy and Egg Products")
  def normalized_name(strategy = :raw)
    case strategy
    when :raw then product
    when :foundation then foundation_food_name
    when :category then foundation_food_category
    else product
    end
  end
end
