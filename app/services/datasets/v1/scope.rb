# frozen_string_literal: true

module Datasets
  module V1
    class Scope
      EXCLUDED_CATEGORIES = %w[household_misc other_unknown].freeze

      DEFAULTS = {
        cap_per_source:      200,
        seed:                42,
        max_failed_count:    3,
        min_ingredients:     3,
        min_inst_steps:      1,
        min_inst_chars:      80,
        max_inst_chars:      50_000
      }.freeze

      attr_reader :options

      def initialize(**opts)
        @options = DEFAULTS.merge(opts)
      end

      # Returns an Array of recipe UUIDs that form the v1 dataset.
      # Two-phase approach:
      #   1. Build a filtered relation with aggregate metrics (no cap).
      #   2. Apply per-source cap via ROW_NUMBER window ordered by md5(id||seed).
      def recipe_ids
        @recipe_ids ||= capped_ids
      end

      # Returns a hash of { recipe_id => { metric columns } } for every v1 recipe.
      # Keys: ingredient_count, instruction_step_count, instruction_char_count,
      #       source_id, publication_year, category, title (coalesced).
      def recipe_metrics
        @recipe_metrics ||= load_recipe_metrics
      end

      # Valid recipes per source after all filters but BEFORE the per-source cap.
      def pre_cap_counts_per_source
        @pre_cap_counts_per_source ||= load_pre_cap_counts
      end

      def selection_rules_hash
        {
          included_in_corpus:   true,
          not_a_recipe:         false,
          extraction_status:    "success",
          max_failed_count:     options[:max_failed_count],
          excluded_categories:  EXCLUDED_CATEGORIES,
          min_ingredients:      options[:min_ingredients],
          min_inst_steps:       options[:min_inst_steps],
          min_inst_chars:       options[:min_inst_chars],
          max_inst_chars:       options[:max_inst_chars],
          cap_per_source:       options[:cap_per_source],
          selection_seed:       options[:seed],
          title_rule:           "COALESCE(parsed_title, title) must be non-blank"
        }
      end

      private

      # SQL for the filtered set with aggregate metrics (before per-source cap).
      # Returns rows: recipe_id, source_id, publication_year, title,
      #               ingredient_count, instruction_step_count, instruction_char_count
      def filtered_metrics_sql
        <<~SQL.squish
          SELECT
            r.id              AS recipe_id,
            r.source_id,
            s.publication_year,
            COALESCE(NULLIF(r.parsed_title, ''), r.title) AS title,
            COALESCE(ing.cnt, 0)       AS ingredient_count,
            COALESCE(ins.step_cnt, 0)  AS instruction_step_count,
            COALESCE(ins.char_cnt, 0)  AS instruction_char_count
          FROM recipes r
          INNER JOIN sources s ON s.id = r.source_id
          LEFT JOIN (
            SELECT ig.recipe_id, COUNT(i.id) AS cnt
            FROM ingredient_groups ig
            INNER JOIN ingredients i ON i.ingredient_group_id = ig.id
            GROUP BY ig.recipe_id
          ) ing ON ing.recipe_id = r.id
          LEFT JOIN (
            SELECT ig2.recipe_id,
                   COUNT(ins.id)          AS step_cnt,
                   COALESCE(SUM(LENGTH(ins.step)), 0) AS char_cnt
            FROM instruction_groups ig2
            INNER JOIN instructions ins ON ins.instruction_group_id = ig2.id
            GROUP BY ig2.recipe_id
          ) ins ON ins.recipe_id = r.id
          WHERE s.included_in_corpus = TRUE
            AND r.not_a_recipe = FALSE
            AND r.extraction_status = 'success'
            AND r.extraction_failed_count <= :max_failed_count
            AND COALESCE(NULLIF(r.parsed_title, ''), r.title) IS NOT NULL
            AND LENGTH(TRIM(COALESCE(NULLIF(r.parsed_title, ''), r.title, ''))) > 0
            AND (r.category IS NULL OR r.category NOT IN (:excluded_cat_a, :excluded_cat_b))
            AND COALESCE(ing.cnt, 0)       >= :min_ingredients
            AND COALESCE(ins.step_cnt, 0)  >= :min_inst_steps
            AND COALESCE(ins.char_cnt, 0)  >= :min_inst_chars
            AND COALESCE(ins.char_cnt, 0)  <= :max_inst_chars
        SQL
      end

      # Apply per-source cap using ROW_NUMBER with md5-based deterministic ordering.
      def capped_ids
        sql = <<~SQL.squish
          SELECT recipe_id FROM (
            SELECT filtered.recipe_id,
                   ROW_NUMBER() OVER (
                     PARTITION BY filtered.source_id
                     ORDER BY md5(filtered.recipe_id::text || :seed)
                   ) AS rn
            FROM (#{filtered_metrics_sql}) filtered
          ) ranked
          WHERE ranked.rn <= :cap
          ORDER BY recipe_id
        SQL

        binds = bind_params.merge(cap: options[:cap_per_source])
        rows = ActiveRecord::Base.connection.exec_query(
          ActiveRecord::Base.sanitize_sql_array([sql, binds])
        )
        rows.map { |r| r["recipe_id"] }
      end

      def load_recipe_metrics
        ids = recipe_ids
        return {} if ids.empty?

        sql = <<~SQL.squish
          SELECT
            r.id              AS recipe_id,
            r.source_id,
            s.publication_year,
            r.category,
            COALESCE(NULLIF(r.parsed_title, ''), r.title) AS title,
            COALESCE(ing.cnt, 0)       AS ingredient_count,
            COALESCE(ins.step_cnt, 0)  AS instruction_step_count,
            COALESCE(ins.char_cnt, 0)  AS instruction_char_count
          FROM recipes r
          INNER JOIN sources s ON s.id = r.source_id
          LEFT JOIN (
            SELECT ig.recipe_id, COUNT(i.id) AS cnt
            FROM ingredient_groups ig
            INNER JOIN ingredients i ON i.ingredient_group_id = ig.id
            GROUP BY ig.recipe_id
          ) ing ON ing.recipe_id = r.id
          LEFT JOIN (
            SELECT ig2.recipe_id,
                   COUNT(ins.id)          AS step_cnt,
                   COALESCE(SUM(LENGTH(ins.step)), 0) AS char_cnt
            FROM instruction_groups ig2
            INNER JOIN instructions ins ON ins.instruction_group_id = ig2.id
            GROUP BY ig2.recipe_id
          ) ins ON ins.recipe_id = r.id
          WHERE r.id IN (:ids)
          ORDER BY r.id
        SQL

        rows = ActiveRecord::Base.connection.exec_query(
          ActiveRecord::Base.sanitize_sql_array([sql, { ids: ids }])
        )

        rows.each_with_object({}) do |row, hash|
          hash[row["recipe_id"]] = row
        end
      end

      def load_pre_cap_counts
        sql = <<~SQL.squish
          SELECT filtered.source_id, COUNT(*) AS cnt
          FROM (#{filtered_metrics_sql}) filtered
          GROUP BY filtered.source_id
          ORDER BY filtered.source_id
        SQL

        rows = ActiveRecord::Base.connection.exec_query(
          ActiveRecord::Base.sanitize_sql_array([sql, bind_params])
        )
        rows.each_with_object({}) { |r, h| h[r["source_id"]] = r["cnt"] }
      end

      def bind_params
        {
          max_failed_count: options[:max_failed_count],
          excluded_cat_a:   EXCLUDED_CATEGORIES[0],
          excluded_cat_b:   EXCLUDED_CATEGORIES[1],
          min_ingredients:  options[:min_ingredients],
          min_inst_steps:   options[:min_inst_steps],
          min_inst_chars:   options[:min_inst_chars],
          max_inst_chars:   options[:max_inst_chars],
          seed:             options[:seed].to_s
        }
      end
    end
  end
end
