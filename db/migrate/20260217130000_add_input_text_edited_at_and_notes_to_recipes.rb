# frozen_string_literal: true

class AddInputTextEditedAtAndNotesToRecipes < ActiveRecord::Migration[7.1]
  def change
    add_column :recipes, :input_text_edited_at, :datetime
    add_column :recipes, :notes, :text
  end
end
