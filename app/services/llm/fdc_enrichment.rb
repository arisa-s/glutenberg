# frozen_string_literal: true

require 'json'
require 'open3'

module Llm
  # Enriches LLM-parsed ingredients with FDC (Food Data Central) foundation
  # food data by calling the Python ingredient-parser-nlp library.
  #
  # Uses a single subprocess call per batch of ingredients (not per ingredient)
  # for efficiency. The Python script reads product names from stdin and
  # returns foundation food matches as JSON.
  #
  # Usage:
  #   Llm::FdcEnrichment.enrich_ingredient_groups(ingredient_groups)
  module FdcEnrichment
    SCRIPT_PATH = Rails.root.join('bin', 'fdc_lookup.py').to_s
    PYTHON_BIN = ENV.fetch('PYTHON_BIN', 'python3')

    module_function

    # Enrich all ingredients across groups with foundation food data.
    # Modifies ingredient hashes in place by adding "foundation_foods" key.
    #
    # @param ingredient_groups [Array<Hash>] groups with "ingredients" arrays
    def enrich_ingredient_groups(ingredient_groups)
      return if ingredient_groups.blank?

      # Collect all ingredients with their product names
      all_ingredients = []
      product_names = []

      ingredient_groups.each do |group|
        next unless group.is_a?(Hash)

        (group['ingredients'] || []).each do |ingredient|
          next unless ingredient.is_a?(Hash)

          product = ingredient['product']
          all_ingredients << ingredient
          product_names << (product.present? ? product : '')
        end
      end

      return if product_names.empty?

      # Batch lookup via Python subprocess
      fdc_results = call_fdc_script(product_names)

      # Merge results back
      all_ingredients.each_with_index do |ingredient, i|
        ingredient['foundation_foods'] = fdc_results[i] || []
      end
    end

    # Call the Python FDC lookup script with a batch of product names.
    #
    # @param product_names [Array<String>] product names to look up
    # @return [Array<Array<Hash>>] foundation food matches per product
    def call_fdc_script(product_names)
      # Filter out blanks but keep index mapping
      non_blank_indices = []
      non_blank_names = []
      product_names.each_with_index do |name, i|
        if name.present?
          non_blank_indices << i
          non_blank_names << name
        end
      end

      if non_blank_names.empty?
        return Array.new(product_names.size) { [] }
      end

      stdout, stderr, status = Open3.capture3(
        PYTHON_BIN, SCRIPT_PATH,
        stdin_data: non_blank_names.to_json
      )

      unless status.success?
        Rails.logger.warn("[Llm::FdcEnrichment] Python script failed: #{stderr.truncate(500)}")
        return Array.new(product_names.size) { [] }
      end

      results = JSON.parse(stdout)

      # Map results back to original indices
      full_results = Array.new(product_names.size) { [] }
      non_blank_indices.each_with_index do |original_idx, result_idx|
        full_results[original_idx] = results[result_idx] || []
      end

      full_results
    rescue JSON::ParserError => e
      Rails.logger.warn("[Llm::FdcEnrichment] Failed to parse Python output: #{e.message}")
      Array.new(product_names.size) { [] }
    rescue Errno::ENOENT => e
      Rails.logger.error("[Llm::FdcEnrichment] Python not found: #{e.message}. " \
                         "Install Python 3 and run: pip install -r requirements.txt")
      Array.new(product_names.size) { [] }
    end
  end
end
