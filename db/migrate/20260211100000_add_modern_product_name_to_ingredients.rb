# frozen_string_literal: true

class AddModernProductNameToIngredients < ActiveRecord::Migration[7.1]
  def change
    add_column :ingredients, :modern_product_name, :string
  end
end
