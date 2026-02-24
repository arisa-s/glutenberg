# frozen_string_literal: true

namespace :extraction do
  desc 'Resolve recipe cross-references for a source (run after all recipes are extracted)'
  task :resolve_refs, [:source_id] => :environment do |_t, args|
    abort 'Usage: rails "extraction:resolve_refs[source_id]"' unless args[:source_id]

    source = Source.find(args[:source_id])
    total_refs = source.recipes.joins(:ingredients).merge(Ingredient.with_recipe_ref).count

    puts "Resolving recipe cross-references for: \"#{source.title}\""
    puts "  Ingredients with recipe_ref: #{total_refs}"

    resolved = Extraction::ResolveRecipeReferencesService.call(source: source)
    puts "  Resolved: #{resolved} / #{total_refs}"
  end

  desc 'Resolve recipe cross-references for ALL sources'
  task resolve_all_refs: :environment do
    Source.find_each do |source|
      count = Ingredient.unresolved_refs
                        .joins(ingredient_group: :recipe)
                        .where(recipes: { source_id: source.id })
                        .count
      next if count.zero?

      resolved = Extraction::ResolveRecipeReferencesService.call(source: source)
      puts "#{source.title}: resolved #{resolved} / #{count} references"
    end
  end
end
