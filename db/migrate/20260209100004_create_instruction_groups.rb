class CreateInstructionGroups < ActiveRecord::Migration[7.1]
  def change
    create_table :instruction_groups do |t|
      t.references :recipe, null: false, foreign_key: true
      t.string :name
      t.integer :order, default: 0, null: false

      t.timestamps
    end
  end
end
