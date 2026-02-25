# frozen_string_literal: true

# Pass 2 prompt for the two-pass multimodal IA extraction pipeline.
# Extracts full structured data for each recipe directly from page images.
# Ported from souschef-flask-server's constants/prompt/extract_recipes_from_pages.py.

module Llm
  module Prompts
    module ExtractRecipesFromPages
      SYSTEM_PROMPT = 'You are a helpful assistant that reads cookbook page images and returns JSON.'

      USER_PREAMBLE = <<~PROMPT.freeze
        You are reading page images from a historical cookbook. Extract every recipe
        visible on these pages into structured JSON.

        Each image is labelled with a **leaf number** (our internal image ID).
        The leaf number is NOT the same as the page number printed in the book.

        **Return a JSON array** where each element is a recipe object:

        ```json
        [
            {
                "title": "<recipe title including recipe number if present>",
                "leaf_number": <leaf number of the image where the recipe title appears>,
                "printed_page": "<page number as printed in the book, or null>",
                "raw_text": "<the complete original text of the recipe as printed on the page, preserving paragraph structure with newlines but normalizing archaic typography>",
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
                "lang": "<two-letter language code, e.g., 'en'>"
            }
        ]
        ```

        #{Llm::Prompts::RecipeSchema::INGREDIENT_PARSING_RULES}

        **Historical text handling:**
        - Read the text directly from the page images. Do NOT rely on any external
          OCR — you are the reader.
        - Normalize archaic typography: long s ("ſ") → "s", ligatures, etc.
        - Rejoin words broken across lines or pages.
        - Ignore page numbers, headers, footers, and printer marks visible on the
          pages.
        - Correct obvious printing errors using surrounding context.
        - Ingredients are often embedded in prose with no separate list — extract
          them all.
        - Normalize archaic quantity phrases to numbers (e.g. "a quarter of a
          pound" → 0.25, unit: "lb"). Keep original unit names.
        - Break continuous prose instructions into logical steps.
        - IMPORTANT — Numbered recipe cross-references: Historical cookbooks
          frequently refer to other recipes by number (e.g. "No. 343",
          "see No. 47"). Extract these as ingredients with "recipe_ref".

        **General rules:**
        - Extract ALL recipes whose titles appear on the provided pages.
        - If a recipe starts on these pages but continues beyond the last provided
          page, extract as much as is visible.
        - Include every key from the schema; use null for unknown values.
        - Skip non-recipe content (prefaces, chapter headings, indices).
        - Return an empty array if no recipes appear on the provided pages.
        - Return ONLY the JSON array, no commentary.
      PROMPT
    end
  end
end
