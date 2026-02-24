class CreateRecipes < ActiveRecord::Migration[7.1]
  def change
    create_table :recipes do |t|
      t.references :source, null: false, foreign_key: true

      # Display fields
      t.string :title
      t.integer :prep_time
      t.integer :cook_time
      t.integer :ready_in_minutes
      t.decimal :yield_amount
      t.decimal :yield_amount_max
      t.string :yield_unit
      t.string :language

      # Extraction metadata
      t.string :extraction_status, default: 'success'
      t.string :extractor_version
      t.datetime :extracted_at
      t.string :input_type
      t.text :input_text
      t.integer :page_number
      t.text :error_message

      t.timestamps
    end

    add_index :recipes, :extraction_status
    add_index :recipes, :extracted_at
    add_index :recipes, :title
  end
end
