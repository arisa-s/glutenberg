class CreateInstructions < ActiveRecord::Migration[7.1]
  def change
    create_table :instructions do |t|
      t.references :instruction_group, null: false, foreign_key: true
      t.text :step, null: false
      t.integer :order, null: false

      t.timestamps
    end
  end
end
