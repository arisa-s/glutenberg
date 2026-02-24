# frozen_string_literal: true

# Orchestrates the full extraction pipeline: calls the Flask service,
# normalizes the response, and persists a Recipe with its associated
# IngredientGroups, Ingredients, InstructionGroups, and Instructions
# using bulk inserts for performance.
#
# Adapted from souschef-rails-server's BaseRecipeScraperService but
# simplified: no background jobs, no product matching, no image processing.
#
# Usage:
#   recipe = Extraction::CreateRecipeService.call(
#     source: source,
#     text: "1 cup flour, 2 eggs..."
#   )
#
# Retry failed extraction (updates existing recipe in place):
#   Extraction::CreateRecipeService.call(
#     source: recipe.source,
#     text: recipe.input_text,
#     recipe: recipe
#   )
module Extraction
  class CreateRecipeService
    # Columns from Flask response that map to the ingredients table.
    INGREDIENT_COLUMNS = %w[original_string product quantity unit preparation comment quantity_max].freeze

    # Foundation food fields from ingredient-parser via Flask.
    FOUNDATION_FOOD_FIELDS = {
      'fdc_id' => :foundation_food_id,
      'text' => :foundation_food_name,
      'category' => :foundation_food_category,
      'confidence' => :foundation_food_confidence
    }.freeze

    def self.call(...)
      new(...).call
    end

    def initialize(source:, text: nil, images: nil, input_type: nil, page_number: nil, extractor_version: nil,
                   raw_section_header: nil, historical: true, recipe: nil, recipe_number: nil)
      @source = source
      @recipe = recipe
      @text = text || (recipe&.input_text)
      @images = images
      @input_type = input_type || (recipe&.input_type) || (images.present? ? 'images' : 'text')
      @page_number = page_number || recipe&.page_number
      @extractor_version = extractor_version || ENV["FLASK_SERVICE_VERSION"] || Recipe::EXTRACTOR_VERSION
      @raw_section_header = raw_section_header || recipe&.raw_section_header
      @historical = historical
      @recipe_number = recipe_number || recipe&.recipe_number
    end

    def call
      if @recipe
        @recipe.ingredient_groups.destroy_all
        @recipe.instruction_groups.destroy_all
      end

      flask_response = extract_from_flask
      return create_failed_recipe("Flask returned nil") if flask_response.nil?

      Recipe.transaction do
        @recipe = create_or_update_recipe(flask_response)
        bulk_insert_ingredient_groups(format_ingredient_groups(flask_response['ingredient_groups']))
        bulk_insert_instruction_groups(format_instruction_groups(flask_response['instruction_groups']))
        @recipe
      end
    rescue StandardError => e
      create_failed_recipe(e.message)
    end

    private

    # ---------------------------------------------------------------
    # Flask API call
    # ---------------------------------------------------------------

    def extract_from_flask
      if @images.present?
        FlaskClient::ExtractFromImages.call(images: @images, language: @source.language || 'en')
      else
        FlaskClient::ExtractFromText.call(
          text: @text,
          language: @source.language || 'en',
          historical: @historical
        )
      end
    end

    # ---------------------------------------------------------------
    # Recipe creation
    # ---------------------------------------------------------------

    def create_or_update_recipe(data)
      category = data['category']
      category = nil unless Recipe::CATEGORIES.include?(category)

      title = sanitize(data['title'])
      title = title_with_recipe_number(title, @recipe_number) if @recipe_number.present? && title.present?

      attrs = {
        title: title,
        recipe_number: @recipe_number,
        prep_time: data['prep_time'],
        cook_time: data['cook_time'],
        ready_in_minutes: data['ready_in_minutes'] || calculate_ready_in_minutes(data),
        yield_amount: data.dig('yield', 'amount'),
        yield_amount_max: data.dig('yield', 'amount_max'),
        yield_unit: data.dig('yield', 'unit'),
        language: data['lang'] || @source.language,
        category: category,
        raw_section_header: @raw_section_header,
        extraction_status: 'success',
        extractor_version: @extractor_version,
        extracted_at: Time.current,
        input_type: @input_type,
        input_text: @text,
        page_number: @page_number,
        error_message: nil
      }

      if @recipe
        @recipe.update!(attrs)
        @recipe
      else
        Recipe.create!(attrs.merge(source: @source))
      end
    end

    def create_failed_recipe(error_message)
      attrs = {
        extraction_status: 'failed',
        extractor_version: @extractor_version,
        extracted_at: Time.current,
        input_type: @input_type,
        input_text: @text,
        page_number: @page_number,
        error_message: error_message
      }

      if @recipe
        @recipe.update!(attrs)
        @recipe
      else
        Recipe.create!(attrs.merge(source: @source))
      end
    end

    def title_with_recipe_number(title, recipe_number)
      num = recipe_number.to_s
      return title if title.match?(/\bNo\.\s*#{Regexp.escape(num)}\b/i)

      "#{title} (No. #{num})"
    end

    def calculate_ready_in_minutes(data)
      prep = data['prep_time'].to_i
      cook = data['cook_time'].to_i
      total = prep + cook
      total.positive? ? total : nil
    end

    # ---------------------------------------------------------------
    # Bulk insert: Ingredient Groups + Ingredients
    # ---------------------------------------------------------------

    def bulk_insert_ingredient_groups(groups_data)
      return if groups_data.blank?

      now = Time.current
      group_rows = []
      ingredient_rows = []
      substitution_rows = []

      groups_data.each do |group|
        group = group.symbolize_keys
        group_id = SecureRandom.uuid

        group_rows << {
          id: group_id,
          recipe_id: @recipe.id,
          name: group[:name],
          order: group[:order],
          created_at: now,
          updated_at: now
        }

        (group[:ingredients] || []).each do |ing|
          ing = ing.stringify_keys
          ff = ing['foundation_foods'].is_a?(Array) && ing['foundation_foods'].first ? ing['foundation_foods'].first : {}

          ingredient_id = SecureRandom.uuid
          row = {
            id: ingredient_id,
            ingredient_group_id: group_id,
            order: ing['order'],
            created_at: now,
            updated_at: now
          }
          INGREDIENT_COLUMNS.each { |col| row[col.to_sym] = sanitize(ing[col]) }
          FOUNDATION_FOOD_FIELDS.each { |source_key, target_key| row[target_key] = ff[source_key] }

          ref = ing['recipe_ref']
          row[:recipe_ref] = ref.is_a?(Hash) ? ref.to_json : nil

          ingredient_rows << row

          # Build substitution rows from the Flask response
          subs = ing['substitutions']
          next unless subs.is_a?(Array)

          subs.each do |sub_product|
            next if sub_product.blank?

            substitution_rows << {
              id: SecureRandom.uuid,
              ingredient_id: ingredient_id,
              product: sanitize(sub_product),
              created_at: now,
              updated_at: now
            }
          end
        end
      end

      IngredientGroup.insert_all!(group_rows) if group_rows.any?
      Ingredient.insert_all!(ingredient_rows) if ingredient_rows.any?
      Substitution.insert_all!(substitution_rows) if substitution_rows.any?
    end

    # ---------------------------------------------------------------
    # Bulk insert: Instruction Groups + Instructions
    # ---------------------------------------------------------------

    def bulk_insert_instruction_groups(groups_data)
      return if groups_data.blank?

      now = Time.current
      group_rows = []
      instruction_rows = []

      groups_data.each do |group|
        group = group.symbolize_keys
        group_id = SecureRandom.uuid

        group_rows << {
          id: group_id,
          recipe_id: @recipe.id,
          name: group[:name],
          order: group[:order],
          created_at: now,
          updated_at: now
        }

        (group[:instructions] || []).each do |inst|
          inst = inst.symbolize_keys
          step_text = sanitize(inst[:step])
          next if step_text.blank?

          instruction_rows << {
            id: SecureRandom.uuid,
            instruction_group_id: group_id,
            step: step_text,
            order: inst[:order],
            created_at: now,
            updated_at: now
          }
        end
      end

      InstructionGroup.insert_all!(group_rows) if group_rows.any?
      Instruction.insert_all!(instruction_rows) if instruction_rows.any?
    end

    # ---------------------------------------------------------------
    # Response formatting (adapted from souschef BaseRecipeScraperService)
    # ---------------------------------------------------------------

    def format_ingredient_groups(groups)
      return [] unless groups

      groups.map.with_index do |group, idx|
        {
          order: idx + 1,
          name: sanitize(group['purpose'] || group['name']),
          ingredients: format_ingredients(group['ingredients'])
        }
      end
    end

    def format_ingredients(ingredients)
      return [] unless ingredients

      ingredients.map.with_index do |ingredient, idx|
        { order: idx + 1, **sanitize_hash(ingredient) }
      end
    end

    def format_instruction_groups(groups)
      return [] unless groups

      groups.map.with_index do |group, idx|
        {
          order: idx + 1,
          name: sanitize(group['name']),
          instructions: format_instructions(group['instructions'])
        }
      end
    end

    def format_instructions(instructions)
      return [] unless instructions

      instructions.map.with_index do |inst, idx|
        step = inst.is_a?(Hash) ? inst['step'] : inst
        { order: idx + 1, step: sanitize(step) }
      end
    end

    # ---------------------------------------------------------------
    # Sanitization (from souschef BaseRecipeScraperService)
    # ---------------------------------------------------------------

    def sanitize_hash(hash)
      return {} unless hash.is_a?(Hash)

      hash.transform_values { |v| sanitize(v) }
    end

    def sanitize(value)
      return value.map { |v| sanitize(v) } if value.is_a?(Array)
      return sanitize_hash(value) if value.is_a?(Hash)
      return value unless value.is_a?(String)

      value.gsub(/[\u0000-\u001F\u007F]/, '')
    end
  end
end
