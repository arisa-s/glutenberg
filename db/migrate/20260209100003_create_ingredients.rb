class CreateIngredients < ActiveRecord::Migration[7.1]
  def change
    create_table :ingredients do |t|
      t.references :ingredient_group, null: false, foreign_key: true

      # Parsed fields (from Flask response)
      t.string :original_string
      t.string :product
      t.decimal :quantity
      t.decimal :quantity_max
      t.string :unit
      t.string :preparation
      t.text :comment
      t.integer :order, null: false

      # Foundation food fields (from ingredient-parser)
      t.integer :foundation_food_id
      t.string :foundation_food_name
      t.string :foundation_food_category
      t.float :foundation_food_confidence

      t.timestamps
    end

    add_index :ingredients, :product
    add_index :ingredients, :foundation_food_id
    add_index :ingredients, :foundation_food_category
  end
end
