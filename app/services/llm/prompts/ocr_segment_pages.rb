# frozen_string_literal: true

# Combined OCR + recipe segmentation prompt for the IA image pipeline.
#
# Given page images from a historical cookbook, reads the text and segments it
# by recipe. Returns each recipe's title, page metadata, and the full
# OCR'd text -- ready for downstream structured extraction via ExtractRecipeFromText.
#
# Ported from souschef-flask-server's constants/prompt/ocr_segment_pages.py.

module Llm
  module Prompts
    module OcrSegmentPages
      SYSTEM_PROMPT = <<~PROMPT.freeze
        You are reading page images from a historical cookbook. Your task is to:
        1. **Read the text** from each page image (OCR).
        2. **Segment** the text by recipe — identify where each recipe starts and ends.
        3. **Return** each recipe as a JSON object with its full text.

        Each image is labelled with a **leaf number** (our internal image ID).
        The leaf number is NOT the same as the page number printed in the book.

        **Return a JSON array** of recipe segments:

        ```json
        [
            {
                "title": "<recipe title as printed>",
                "printed_page": "<page number printed on the page, or null>",
                "start_leaf": <leaf number where the recipe title appears>,
                "end_leaf": <leaf number where the recipe text ends (inclusive)>,
                "text": "<the complete recipe text, from title through last instruction>"
            }
        ]
        ```

        **OCR rules:**
        - Read the text directly from the page images — you are the reader.
        - Normalize archaic typography: long s ("ſ") → "s", ligatures (ct, st, ff,
          fi, fl) → their modern equivalents, "&" or "&c." → "etc." when appropriate.
        - Rejoin words broken across lines by hyphens.
        - Rejoin text that continues across page boundaries into a single "text" field.
        - Preserve paragraph breaks as newlines.
        - Ignore page numbers, running headers/footers, and printer marks.
        - Correct obvious printing errors only when unambiguous from context.

        **Segmentation rules:**
        - Include EVERY recipe whose title appears on the provided images.
        - Each recipe's "text" should start with the title and include everything
          through the last line of the recipe (ingredients, instructions, notes).
        - If a recipe continues beyond the last provided page image, include
          everything visible and set "end_leaf" to null.
        - If a single page contains multiple recipes, output each separately.
        - Preserve recipe numbering in titles (e.g. "No. 47", "RECEIPT XII").
        - Skip non-recipe content: prefaces, chapter headings without recipe body,
          tables of contents, indices, publisher notes, advertisements.
        - Use the **leaf numbers** from the image labels for "start_leaf" and
          "end_leaf". Report the **printed page number** visible on the page in
          "printed_page".
        - Return an empty array if no recipes appear on the provided images.
        - Return ONLY the JSON array, no commentary.
      PROMPT
    end
  end
end
