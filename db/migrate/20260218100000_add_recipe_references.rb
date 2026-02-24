# frozen_string_literal: true

class AddRecipeReferences < ActiveRecord::Migration[7.1]
  def change
    add_column :ingredients, :recipe_ref, :jsonb
    add_reference :ingredients, :referenced_recipe, type: :uuid, foreign_key: { to_table: :recipes }, index: true

    add_column :recipes, :recipe_number, :integer
    add_index :recipes, %i[source_id recipe_number], name: :index_recipes_on_source_id_and_recipe_number
  end
end
