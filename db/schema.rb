# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[7.1].define(version: 2026_02_18_110000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pgcrypto"
  enable_extension "plpgsql"

  create_table "ingredient_groups", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "recipe_id", null: false
    t.string "name"
    t.integer "order", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["recipe_id"], name: "index_ingredient_groups_on_recipe_id"
  end

  create_table "ingredients", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "ingredient_group_id", null: false
    t.string "original_string"
    t.string "product"
    t.decimal "quantity"
    t.decimal "quantity_max"
    t.string "unit"
    t.string "preparation"
    t.text "comment"
    t.integer "order", default: 0, null: false
    t.integer "foundation_food_id"
    t.string "foundation_food_name"
    t.string "foundation_food_category"
    t.float "foundation_food_confidence"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.jsonb "recipe_ref"
    t.uuid "referenced_recipe_id"
    t.index ["foundation_food_category"], name: "index_ingredients_on_foundation_food_category"
    t.index ["foundation_food_id"], name: "index_ingredients_on_foundation_food_id"
    t.index ["ingredient_group_id"], name: "index_ingredients_on_ingredient_group_id"
    t.index ["product"], name: "index_ingredients_on_product"
    t.index ["referenced_recipe_id"], name: "index_ingredients_on_referenced_recipe_id"
  end

  create_table "instruction_groups", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "recipe_id", null: false
    t.string "name"
    t.integer "order", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["recipe_id"], name: "index_instruction_groups_on_recipe_id"
  end

  create_table "instructions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "instruction_group_id", null: false
    t.text "step", null: false
    t.integer "order", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["instruction_group_id"], name: "index_instructions_on_instruction_group_id"
  end

  create_table "recipes", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "source_id", null: false
    t.string "title"
    t.integer "prep_time"
    t.integer "cook_time"
    t.integer "ready_in_minutes"
    t.decimal "yield_amount"
    t.decimal "yield_amount_max"
    t.string "yield_unit"
    t.string "language"
    t.string "extraction_status", default: "success", null: false
    t.string "extractor_version"
    t.datetime "extracted_at"
    t.string "input_type"
    t.text "input_text"
    t.integer "page_number"
    t.text "error_message"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "raw_section_header"
    t.string "category"
    t.string "parsed_title"
    t.boolean "not_a_recipe", default: false, null: false
    t.datetime "input_text_edited_at"
    t.text "notes"
    t.integer "recipe_number"
    t.integer "extraction_failed_count", default: 0, null: false
    t.index ["category"], name: "index_recipes_on_category"
    t.index ["extracted_at"], name: "index_recipes_on_extracted_at"
    t.index ["extraction_status"], name: "index_recipes_on_extraction_status"
    t.index ["source_id", "recipe_number"], name: "index_recipes_on_source_id_and_recipe_number"
    t.index ["source_id"], name: "index_recipes_on_source_id"
    t.index ["title"], name: "index_recipes_on_title"
  end

  create_table "sources", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "title", null: false
    t.string "author"
    t.integer "publication_year"
    t.string "provider", default: "gutenberg", null: false
    t.string "external_id"
    t.string "source_url"
    t.string "language", default: "en"
    t.text "notes"
    t.boolean "included_in_corpus", default: true, null: false
    t.string "split_strategy"
    t.string "region_country"
    t.string "region_city"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "image_url"
    t.index ["included_in_corpus"], name: "index_sources_on_included_in_corpus"
    t.index ["provider", "external_id"], name: "index_sources_on_provider_and_external_id", unique: true
    t.index ["provider"], name: "index_sources_on_provider"
    t.index ["publication_year"], name: "index_sources_on_publication_year"
  end

  create_table "substitutions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "ingredient_id", null: false
    t.string "product", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["ingredient_id"], name: "index_substitutions_on_ingredient_id"
    t.index ["product"], name: "index_substitutions_on_product"
  end

  add_foreign_key "ingredient_groups", "recipes"
  add_foreign_key "ingredients", "ingredient_groups"
  add_foreign_key "ingredients", "recipes", column: "referenced_recipe_id"
  add_foreign_key "instruction_groups", "recipes"
  add_foreign_key "instructions", "instruction_groups"
  add_foreign_key "recipes", "sources"
  add_foreign_key "substitutions", "ingredients"
end
