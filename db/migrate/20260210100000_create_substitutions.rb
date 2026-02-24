# frozen_string_literal: true

class CreateSubstitutions < ActiveRecord::Migration[7.1]
  def change
    create_table :substitutions, id: :uuid do |t|
      t.references :ingredient, null: false, foreign_key: true, type: :uuid
      t.string :product, null: false

      t.timestamps
    end

    add_index :substitutions, :product
  end
end
