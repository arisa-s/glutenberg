# frozen_string_literal: true

require "csv"
require "json"
require "fileutils"

module Datasets
  module V1
    class Exporter
      DATASET_VERSION = "v1"

      SLICES = {
        "early"     => 1740..1819,
        "victorian" => 1820..1869,
        "late"      => 1870..1929
      }.freeze

      RECIPE_CSV_HEADERS = %w[
        dataset_version recipe_id source_id publication_year slice category title
        ingredient_count ingredient_count_exported instruction_step_count instruction_char_count
      ].freeze

      INGREDIENT_CSV_HEADERS = %w[
        dataset_version recipe_id ingredient_token
        foundation_food_id foundation_food_name foundation_food_category
      ].freeze

      INGREDIENT_BATCH_SIZE = 500

      attr_reader :scope, :output_dir

      def initialize(output_dir: nil, **scope_opts)
        @scope = Scope.new(**scope_opts)
        @output_dir = output_dir || default_output_dir
      end

      def call
        FileUtils.mkdir_p(output_dir)

        ids                 = scope.recipe_ids
        metrics             = scope.recipe_metrics
        exported_ing_counts = compute_exported_ingredient_counts(ids)
        ingredient_stats    = write_recipes_csv(ids, metrics, exported_ing_counts)
        ing_result          = write_ingredients_csv(ids)
        total_per_slice     = total_recipes_per_slice

        write_manifest(
          metrics:               metrics,
          total_ing_rows:        ing_result[:total_rows],
          vocab_size:            ing_result[:vocab_size],
          recipes_per_slice:     ingredient_stats[:recipes_per_slice],
          recipes_per_source:    ingredient_stats[:recipes_per_source],
          total_recipes_per_slice: total_per_slice,
          slice_statistics:      compute_slice_statistics(metrics, exported_ing_counts),
          source_statistics:     compute_source_statistics(metrics, exported_ing_counts, ing_result[:vocab_per_source]),
          pre_cap_per_source:    scope.pre_cap_counts_per_source
        )

        {
          output_dir:          output_dir.to_s,
          total_recipes:       ids.size,
          recipes_per_slice:   ingredient_stats[:recipes_per_slice],
          total_ingredient_rows: ing_result[:total_rows],
          vocab_size:          ing_result[:vocab_size]
        }
      end

      def self.slice_for(publication_year)
        return "out_of_range" if publication_year.nil?

        SLICES.each do |label, range|
          return label if range.cover?(publication_year)
        end
        "out_of_range"
      end

      private

      def default_output_dir
        Rails.root.join("data", "frozen", "v1", Time.now.strftime("%Y%m%d_%H%M%S"))
      end

      # Total recipes per slice from corpus sources only (no scope filters).
      # Used for retention rate: in_export / total_in_slice.
      def total_recipes_per_slice
        years = Recipe.joins(:source).where(sources: { included_in_corpus: true }).pluck("sources.publication_year")
        years.group_by { |y| self.class.slice_for(y) }.transform_values(&:count)
      end

      # ------------------------------------------------------------------
      # Exported ingredient count (after cross-ref filter, nil product, dedup)
      # ------------------------------------------------------------------
      def compute_exported_ingredient_counts(ids)
        counts = Hash.new(0)
        seen_pairs = Set.new

        ids.each_slice(INGREDIENT_BATCH_SIZE) do |batch_ids|
          ingredients = Ingredient.unscoped
            .joins(ingredient_group: :recipe)
            .where(ingredient_groups: { recipe_id: batch_ids })
            .where(recipe_ref: nil, referenced_recipe_id: nil)
            .select(:product, "ingredient_groups.recipe_id AS recipe_id")

          ingredients.each do |ing|
            token = Tokenizer.call(product: ing.product)
            next if token.nil?

            pair = [ing.recipe_id, token]
            next if seen_pairs.include?(pair)

            seen_pairs << pair
            counts[ing.recipe_id] += 1
          end
        end

        counts
      end

      # ------------------------------------------------------------------
      # v1_recipes.csv
      # ------------------------------------------------------------------
      def write_recipes_csv(ids, metrics, exported_ing_counts = {})
        per_slice  = Hash.new(0)
        per_source = Hash.new(0)

        path = File.join(output_dir, "v1_recipes.csv")
        CSV.open(path, "w", write_headers: true, headers: RECIPE_CSV_HEADERS) do |csv|
          ids.each do |rid|
            row = metrics[rid]
            next unless row

            year  = row["publication_year"]
            slice = self.class.slice_for(year)

            per_slice[slice]          += 1
            per_source[row["source_id"]] += 1

            csv << [
              DATASET_VERSION,
              rid,
              row["source_id"],
              year,
              slice,
              row["category"],
              row["title"],
              row["ingredient_count"],
              exported_ing_counts[rid] || 0,
              row["instruction_step_count"],
              row["instruction_char_count"]
            ]
          end
        end

        { recipes_per_slice: per_slice, recipes_per_source: per_source }
      end

      # ------------------------------------------------------------------
      # v1_recipe_ingredients_long.csv
      # ------------------------------------------------------------------
      def write_ingredients_csv(ids)
        total_rows       = 0
        vocab            = Set.new
        vocab_per_source = Hash.new { |h, k| h[k] = Set.new }
        recipe_source    = scope.recipe_metrics.each_with_object({}) { |(rid, row), h| h[rid] = row["source_id"] }
        seen_pairs       = Set.new

        path = File.join(output_dir, "v1_recipe_ingredients_long.csv")
        CSV.open(path, "w", write_headers: true, headers: INGREDIENT_CSV_HEADERS) do |csv|
          ids.each_slice(INGREDIENT_BATCH_SIZE) do |batch_ids|
            ingredients = Ingredient.unscoped
              .joins(ingredient_group: :recipe)
              .where(ingredient_groups: { recipe_id: batch_ids })
              .where(recipe_ref: nil, referenced_recipe_id: nil)
              .select(:id, :product, :foundation_food_id, :foundation_food_name, :foundation_food_category, "ingredient_groups.recipe_id AS recipe_id")

            ingredients.each do |ing|
              token = Tokenizer.call(product: ing.product)
              next if token.nil?

              pair = [ing.recipe_id, token]
              next if seen_pairs.include?(pair)

              seen_pairs << pair
              vocab << token
              vocab_per_source[recipe_source[ing.recipe_id]] << token
              total_rows += 1

              csv << [
                DATASET_VERSION,
                ing.recipe_id,
                token,
                ing.foundation_food_id,
                ing.foundation_food_name.presence,
                ing.foundation_food_category.presence
              ]
            end
          end
        end

        { total_rows: total_rows, vocab_size: vocab.size, vocab_per_source: vocab_per_source }
      end

      def build_retention_by_slice(recipes_per_slice, total_recipes_per_slice)
        all_slices = (recipes_per_slice.keys + total_recipes_per_slice.keys).uniq.sort
        all_slices.each_with_object({}) do |slice, out|
          in_export = recipes_per_slice[slice].to_i
          total = total_recipes_per_slice[slice].to_i
          rate = total.positive? ? (in_export.to_f / total).round(4) : nil
          out[slice] = { in_export: in_export, total_in_slice: total, retention_rate: rate }
        end
      end

      def compute_slice_statistics(metrics, exported_ing_counts = {})
        by_slice = Hash.new { |h, k| h[k] = { ingredient_counts: [], instruction_char_counts: [] } }

        metrics.each_value do |row|
          slice = self.class.slice_for(row["publication_year"])
          ing_count = exported_ing_counts[row["recipe_id"]] || row["ingredient_count"].to_f
          by_slice[slice][:ingredient_counts]      << ing_count.to_f
          by_slice[slice][:instruction_char_counts] << row["instruction_char_count"].to_f
        end

        by_slice.each_with_object({}) do |(slice, data), result|
          n = data[:ingredient_counts].size
          result[slice] = {
            recipe_count:              n,
            avg_ingredient_count:      (data[:ingredient_counts].sum / n).round(2),
            avg_instruction_char_count: (data[:instruction_char_counts].sum / n).round(2)
          }
        end
      end

      def compute_source_statistics(metrics, exported_ing_counts, vocab_per_source)
        by_source = Hash.new { |h, k| h[k] = { ingredient_counts: [], instruction_char_counts: [] } }

        metrics.each_value do |row|
          sid = row["source_id"]
          ing_count = exported_ing_counts[row["recipe_id"]] || row["ingredient_count"].to_f
          by_source[sid][:ingredient_counts]      << ing_count.to_f
          by_source[sid][:instruction_char_counts] << row["instruction_char_count"].to_f
        end

        by_source.each_with_object({}) do |(sid, data), result|
          n = data[:ingredient_counts].size
          result[sid] = {
            recipe_count:               n,
            avg_ingredient_count:       (data[:ingredient_counts].sum / n).round(2),
            avg_instruction_char_count: (data[:instruction_char_counts].sum / n).round(2),
            vocab_size:                 vocab_per_source[sid]&.size || 0
          }
        end
      end

      # ------------------------------------------------------------------
      # v1_manifest.json
      # ------------------------------------------------------------------
      def write_manifest(metrics:, total_ing_rows:, vocab_size:, recipes_per_slice:, recipes_per_source:, total_recipes_per_slice:, slice_statistics:, source_statistics:, pre_cap_per_source:)
        git_sha = begin
          `git rev-parse HEAD 2>/dev/null`.strip.presence
        rescue StandardError
          nil
        end

        retention_by_slice = build_retention_by_slice(recipes_per_slice, total_recipes_per_slice)

        manifest = {
          dataset_version:     DATASET_VERSION,
          exported_at:         Time.now.utc.iso8601,
          git_commit_sha:      git_sha,
          selection_rules:     scope.selection_rules_hash,
          counts: {
            total_recipes:                  metrics.size,
            recipes_per_slice:              recipes_per_slice,
            recipes_per_source:             recipes_per_source,
            valid_recipes_per_source_before_cap: pre_cap_per_source,
            total_ingredient_rows_exported: total_ing_rows,
            vocab_size:                     vocab_size
          },
          retention_by_slice:   retention_by_slice,
          slice_statistics:      slice_statistics,
          source_statistics:     source_statistics,
          tokenization_rules: {
            source_field:  "product only; ingredients with nil/blank product are excluded",
            normalization: "downcase -> strip -> replace non-Unicode-letter/number (except space/hyphen) with space -> collapse whitespace -> trim",
            blank_handling: "blank tokens are dropped",
            cross_ref_filtering: "ingredients with recipe_ref or referenced_recipe_id are excluded (cross-references to other recipes, not real ingredients)",
            deduplication: "tokens are deduplicated per recipe; each (recipe_id, ingredient_token) pair appears at most once",
            fdc_columns: "foundation_food_id, foundation_food_name, foundation_food_category (USDA FDC); blank when ingredient had no FDC match",
            ingredient_count_exported: "per-recipe count after cross-ref filter, nil product exclusion, and dedup; slice/source avg_ingredient_count use this"
          }
        }

        path = File.join(output_dir, "v1_manifest.json")
        File.write(path, JSON.pretty_generate(manifest))
      end
    end
  end
end
