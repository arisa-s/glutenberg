# frozen_string_literal: true

# Calls the Flask service to extract a recipe from plain text (e.g., OCR output
# from a vintage cookbook page).
#
# Endpoint: POST /recipe_extractor/text_to_recipe
#
# Usage:
#   result = FlaskClient::ExtractFromText.call(text: ocr_text)
#   result = FlaskClient::ExtractFromText.call(text: ocr_text, language: 'en')
module FlaskClient
  class ExtractFromText < BaseService
    def initialize(text:, language: 'en', historical: false)
      @text = text
      @language = language
      @historical = historical
    end

    private

    def skip?
      @text.blank?
    end

    def endpoint_path
      '/recipe_extractor/text_to_recipe'
    end

    def request_body
      body = { text: @text }
      body[:lang] = @language if @language.present?
      body[:historical] = true if @historical
      body
    end
  end
end
