# frozen_string_literal: true

namespace :datasets do
  namespace :export do
    desc "Export frozen dataset v1 (CSV + manifest) for project analysis"
    task v1: :environment do
      opts = {
        cap_per_source:   Integer(ENV.fetch("CAP", 200)),
        seed:             Integer(ENV.fetch("SEED", 42)),
        max_failed_count: Integer(ENV.fetch("MAX_FAILED", 3)),
        min_ingredients:  Integer(ENV.fetch("MIN_ING", 3)),
        min_inst_steps:   Integer(ENV.fetch("MIN_INST_STEPS", 1)),
        min_inst_chars:   Integer(ENV.fetch("MIN_INST_CHARS", 80)),
        max_inst_chars:   Integer(ENV.fetch("MAX_INST_CHARS", 50_000))
      }

      output_dir = ENV["OUTPUT_DIR"]

      exporter = Datasets::V1::Exporter.new(output_dir: output_dir, **opts)
      result   = exporter.call

      puts "== Dataset v1 export complete =="
      puts "  Output dir:          #{result[:output_dir]}"
      puts "  Total recipes:       #{result[:total_recipes]}"
      puts "  Recipes per slice:   #{result[:recipes_per_slice].sort.to_h}"
      puts "  Ingredient rows:     #{result[:total_ingredient_rows]}"
      puts "  Vocab size:          #{result[:vocab_size]}"
    end
  end
end
