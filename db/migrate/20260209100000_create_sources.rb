class CreateSources < ActiveRecord::Migration[7.1]
  def change
    create_table :sources do |t|
      t.string :title, null: false
      t.string :author
      t.integer :publication_year
      t.string :provider, default: 'gutenberg'
      t.string :external_id
      t.string :source_url
      t.string :genre
      t.string :region
      t.string :language, default: 'en'
      t.text :notes
      t.boolean :included_in_corpus, default: true

      t.timestamps
    end

    add_index :sources, :publication_year
    add_index :sources, [:provider, :external_id], unique: true
    add_index :sources, :provider
    add_index :sources, :included_in_corpus
  end
end
