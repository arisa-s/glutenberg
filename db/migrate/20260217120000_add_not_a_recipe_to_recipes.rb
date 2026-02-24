# frozen_string_literal: true

class AddNotARecipeToRecipes < ActiveRecord::Migration[7.1]
  def change
    add_column :recipes, :not_a_recipe, :boolean, default: false, null: false
  end
end
