# frozen_string_literal: true

# Shared JSON schema fragments and ingredient parsing rules for LLM prompts.
# Ported from souschef-flask-server's constants/prompt/recipe_schema.py.

module Llm
  module Prompts
    module RecipeSchema
      PARSED_INGREDIENT = <<~SCHEMA.freeze
        {
            "original_string": "<original ingredient text exactly as written>",
            "product": "<ONE ingredient name, e.g., 'flour', 'chicken'>",
            "quantity": "<number or null>",
            "quantity_max": "<number if range given, otherwise null>",
            "unit": "<unit string, e.g., 'g', 'ml', 'cup', or null>",
            "preparation": "<prep details, e.g., 'sliced', or null>",
            "comment": "<additional notes or null>",
            "substitutions": ["<alternative product name>", ...],
            "recipe_ref": {"ref_title": "...", "ref_number": ..., "ref_page": ..., "ref_raw_text": "..."} or null
        }
      SCHEMA

      PARSED_INGREDIENT_EXAMPLE = <<~EXAMPLE.freeze
        {
            "original_string": "2 large eggs, beaten",
            "product": "eggs",
            "quantity": 2,
            "quantity_max": null,
            "unit": null,
            "preparation": "beaten",
            "comment": "large",
            "substitutions": []
        }
      EXAMPLE

      CATEGORY_LIST = Recipe::CATEGORIES.join(', ').freeze

      INGREDIENT_GROUP_SCHEMA = <<~SCHEMA.freeze
        {
                    "purpose": "<group purpose or null>",
                    "ingredients": [
                        #{PARSED_INGREDIENT.strip.gsub("\n", "\n                        ")}
                    ]
                }
      SCHEMA

      INGREDIENT_PARSING_RULES = <<~RULES.freeze
        **Ingredient Parsing Rules:**
        Parse each ingredient into this structure:
        #{PARSED_INGREDIENT}
        Example:
        #{PARSED_INGREDIENT_EXAMPLE}
        **Splitting and substitution guidelines:**
        - Each entry must describe exactly ONE product.
        - If a string mentions multiple distinct ingredients, create a separate entry for
          each, copying shared quantity/unit/preparation.
        - If a string offers interchangeable alternatives for the same role in the recipe,
          use the first option as "product" and list the others in "substitutions".
          If there are no alternatives, use an empty array.
        - Keep product names in the original language of the input.

        **Recipe cross-reference guidelines:**
        - If an ingredient refers to another recipe in the same book (by title, number,
          page, or description), populate "recipe_ref":
          {"ref_title": "...", "ref_number": ..., "ref_page": ..., "ref_raw_text": "..."}.
          Use null for fields not mentioned. "ref_raw_text" is always required and should
          contain the reference portion of the original text.
        - Set "product" to the name of the referenced recipe if known, otherwise use the
          reference text itself (e.g. "No. 343").
        - If the ingredient is NOT a recipe reference, set "recipe_ref" to null.
      RULES
    end
  end
end
