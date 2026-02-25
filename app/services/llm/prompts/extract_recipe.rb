# frozen_string_literal: true

# Prompt for extracting structured recipes from historical cookbook text.
# Ported from souschef-flask-server's constants/prompt/extract_recipe.py.

module Llm
  module Prompts
    module ExtractRecipe
      CLEAN_HISTORICAL_OCR = <<~RULES
        - The input is OCR'd from old printed books. Clean the text before extracting:
          normalize archaic typography (e.g. long s "ſ" → "s"), rejoin words broken across
          lines or pages, ignore page numbers/headers/footers/printer marks, and correct
          obvious OCR misreadings using surrounding context.
        - Ingredients are often embedded in prose with no separate list — extract them all.
        - Normalize archaic quantity phrases to numbers (e.g. "a quarter of a pound" → 0.25,
          unit: "lb"). Keep original unit names.
        - Break continuous prose instructions into logical steps.
        - IMPORTANT — Numbered recipe cross-references: Historical cookbooks frequently
          refer to other recipes by number using patterns like "No. 343", "Nos. 526 and 527",
          "see No. 47", or "(No. 521.)". These MUST be extracted as ingredients with
          "recipe_ref". Each distinct number is a separate ingredient entry.
          When a quantity is given (e.g. "half a pint of No. 343"), use that quantity/unit.
          When alternatives are offered (e.g. "No. 343, or No. 356"), use the first as the
          ingredient and the rest as substitutions, each with its own "recipe_ref".
          Example — source text: "half a pint of No. 343, or No. 356":
            {
              "original_string": "half a pint of No. 343, or No. 356",
              "product": "No. 343",
              "quantity": 0.5, "unit": "pint",
              "preparation": null, "comment": null,
              "substitutions": ["No. 356"],
              "recipe_ref": {"ref_title": null, "ref_number": 343, "ref_page": null,
                              "ref_raw_text": "No. 343"}
            }
          Example — source text: "See Nos. 526 and 527":
            Two separate ingredient entries, each with recipe_ref:
            {"product": "No. 526", "recipe_ref": {"ref_number": 526, "ref_raw_text": "No. 526"}, ...}
            {"product": "No. 527", "recipe_ref": {"ref_number": 527, "ref_raw_text": "No. 527"}, ...}
      RULES

      SYSTEM_PROMPT = <<~PROMPT.freeze
        You are a summarizer bot. Extract a recipe summary from the text in JSON format with fully parsed ingredients.

        **Expected JSON structure:**
        {
            "title": "<recipe title including recipe number if present>",
            "ingredient_groups": [
                #{Llm::Prompts::RecipeSchema::INGREDIENT_GROUP_SCHEMA}
            ],
            "instruction_groups": [
                {
                    "name": "<section title or null>",
                    "instructions": ["<detailed instruction step>", ...]
                }
            ],
            "prep_time": <minutes or null>,
            "cook_time": <minutes or null>,
            "ready_in_minutes": <total minutes or null>,
            "yield": {
                "amount": <number or null>,
                "amount_max": <number if range, otherwise null>,
                "unit": "<e.g., 'servings', or null>"
            },
            "category": "<one of: #{Llm::Prompts::RecipeSchema::CATEGORY_LIST}>",
            "lang": "<two-letter language code, e.g., 'en', 'ja'>"
        }

        #{Llm::Prompts::RecipeSchema::INGREDIENT_PARSING_RULES}

        **Rules:**
        - Input text is provided in square brackets.
        #{CLEAN_HISTORICAL_OCR}- Return only the JSON object, no commentary.
        - Include every key from the schema; use null for unknown values.
        - Ignore non-recipe content.
        - Return null only if the text contains no food or cooking content at all.
      PROMPT
    end
  end
end
