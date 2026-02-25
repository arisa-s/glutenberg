# frozen_string_literal: true

# Pass 1 prompt for the two-pass multimodal IA extraction pipeline.
# Identifies recipe boundaries (titles + page ranges) from cookbook page images.
# Ported from souschef-flask-server's constants/prompt/identify_recipe_boundaries.py.

module Llm
  module Prompts
    module IdentifyRecipeBoundaries
      SYSTEM_PROMPT = 'You are a helpful assistant that analyses cookbook page images and returns JSON.'

      USER_PREAMBLE = <<~PROMPT.freeze
        You are analysing page images from a historical cookbook. Your task is to
        identify every recipe that appears on these pages and report its title and
        the leaf range it spans.

        Each image is labelled with a **leaf number** (our internal image ID).
        The leaf number is NOT the same as the page number printed in the book.

        **Return a JSON array** of objects with this structure:

        ```json
        [
            {
                "title": "<recipe title as printed, including any number prefix>",
                "start_leaf": <leaf number of the image where the recipe title appears>,
                "end_leaf": <leaf number of the image where the recipe text ends (inclusive)>,
                "printed_page": "<page number printed on the page where the recipe starts, or null if not visible>"
            }
        ]
        ```

        **Rules:**
        - Include EVERY recipe whose title appears on the provided images.
        - Use the **leaf numbers** from the image labels (e.g. "Leaf 50") for
          "start_leaf" and "end_leaf". These are the numbers we label each image
          with, NOT the page numbers printed in the book.
        - Report the **printed page number** visible on the page (e.g. "42",
          "xii", "102") in "printed_page" as a string. If the page has no visible
          page number, use null.
        - A recipe's text may span multiple images. Set "end_leaf" to the last
          leaf that contains text belonging to that recipe.
        - If a recipe clearly continues beyond the last provided image, set
          "end_leaf" to null.
        - Skip non-recipe content: prefaces, chapter headings without recipe body,
          tables of contents, indices, publisher notes, advertisements.
        - If a single page contains multiple short recipes, list each separately.
        - Preserve the original title text (including archaic spelling, numbering
          like "No. 47", "RECEIPT XII", roman numerals, etc.).
        - Return an empty array if no recipes appear on the provided images.
        - Return ONLY the JSON array, no commentary.
      PROMPT
    end
  end
end
