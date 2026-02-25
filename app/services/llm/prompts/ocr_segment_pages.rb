# frozen_string_literal: true

# Combined OCR + recipe segmentation prompt for the IA image pipeline.
# Ported from souschef-flask-server's constants/prompt/ocr_segment_pages.py.

module Llm
  module Prompts
    module OcrSegmentPages
      SYSTEM_PROMPT = 'You are a helpful assistant that reads cookbook page images and returns JSON.'

      USER_PREAMBLE = <<~PROMPT.freeze
        You are reading page images from a historical cookbook. Your task is to:
        1. Read the text from each page image (OCR).
        2. Segment the text by recipe — identify where each recipe starts and ends.
        3. Return each recipe as a JSON object with its full text.

        Each image is labelled with a leaf number (our internal image ID).
        The leaf number is NOT the same as the page number printed in the book.

        Return a JSON array of recipe segments:

        [
            {
                "title": "<recipe title as printed>",
                "section": "<chapter or section heading this recipe falls under, e.g. 'STOCKS', 'STANDARD SAUCES', or null>",
                "printed_page": "<page number printed on the page, or null>",
                "start_leaf": <leaf number where the recipe title appears>,
                "end_leaf": <leaf number where the recipe text ends (inclusive)>,
                "text": "<the complete recipe text, from title through last instruction>"
            }
        ]

        Rules:
        - Normalize archaic typography: long s ("ſ") → "s", ligatures → modern
          equivalents. Rejoin words broken by hyphens or page boundaries.
        - If a recipe spans pages, merge its text into one "text" field. If it
          continues beyond the last provided image, set "end_leaf" to null.
        - Skip non-recipe content (prefaces, indices, chapter headings, ads).
        - Use leaf numbers from image labels for start/end_leaf. Report the
          printed page number visible on the page in "printed_page".
        - Return ONLY the JSON array, no commentary.
      PROMPT
    end
  end
end
