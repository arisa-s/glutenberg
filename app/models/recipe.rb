# frozen_string_literal: true

class Recipe < ApplicationRecord
  EXTRACTION_STATUSES = %w[success failed excluded].freeze

  CATEGORIES = %w[
    soup_stew
    meat_fish_main
    vegetable_side
    bread_dough
    dessert_baking
    sweet_confection
    sauce_gravy
    preserve_pickle
    beverage
    breakfast_brunch
    household_misc
    other_unknown
  ].freeze

  # Version of the extraction pipeline (Flask/souschef) that produced this recipe.
  # Stored on each recipe for reproducibility and debugging. Override at runtime
  # with ENV["EXTRACTOR_VERSION"] if needed (e.g. in CI or per deployment).
  EXTRACTOR_VERSION = ENV.fetch("EXTRACTOR_VERSION", "native-llm").freeze

  # Exclude recipes marked "text is not a recipe" from default listing.
  default_scope { where(not_a_recipe: false) }

  belongs_to :source

  has_many :ingredient_groups, dependent: :destroy
  has_many :ingredients, through: :ingredient_groups
  has_many :instruction_groups, dependent: :destroy
  has_many :instructions, through: :instruction_groups
  has_many :referencing_ingredients, class_name: 'Ingredient',
           foreign_key: :referenced_recipe_id, dependent: :nullify, inverse_of: :referenced_recipe

  validates :extraction_status, inclusion: { in: EXTRACTION_STATUSES }
  validates :category, inclusion: { in: CATEGORIES }, allow_nil: true

  before_save :set_input_text_edited_at, if: :input_text_changed?

  # Status scopes
  scope :successful, -> { where(extraction_status: 'success') }
  scope :failed, -> { where(extraction_status: 'failed') }
  scope :excluded, -> { where(extraction_status: 'excluded') }

  # Recipes marked as "text doesn't include a recipe" (excluded by default_scope)
  scope :marked_not_recipe, -> { unscoped.where(not_a_recipe: true) }

  # Category scope
  scope :by_category, ->(cat) { where(category: cat) }

  # Quality scopes
  scope :with_ingredients, -> { joins(:ingredients).distinct }
  scope :with_instructions, -> { joins(:instructions).distinct }
  scope :with_title, -> { where.not(title: [nil, '']) }

  scope :valid_recipes, -> {
    successful.with_title.with_ingredients
  }

  scope :high_quality, -> {
    valid_recipes
      .joins(:ingredients)
      .group('recipes.id')
      .having('COUNT(ingredients.id) >= ?', 5)
  }

  # Temporal scopes (via source)
  scope :by_decade, ->(start_year) {
    joins(:source).where(sources: { publication_year: start_year...(start_year + 10) })
  }

  scope :by_period, ->(start_year, end_year) {
    joins(:source).where(sources: { publication_year: start_year..end_year })
  }

  # Provider scopes (via source)
  scope :from_gutenberg, -> { joins(:source).where(sources: { provider: 'gutenberg' }) }
  scope :from_internet_archive, -> { joins(:source).where(sources: { provider: 'internet_archive' }) }

  def publication_year
    source&.publication_year
  end

  def decade
    source&.decade
  end

  def quality_score
    score = 0
    score += 40 if title.present?
    score += 30 if ingredients.count >= 5
    score += 20 if instructions.any?
    score += 10 if prep_time.present? || cook_time.present?
    score
  end

  def input_text_edited?
    input_text_edited_at.present?
  end

  private

  def set_input_text_edited_at
    self.input_text_edited_at = Time.current
  end
end
