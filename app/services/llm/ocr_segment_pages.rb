# frozen_string_literal: true

module Llm
  # Combined OCR + recipe segmentation for the IA image pipeline.
  #
  # Sends batched page images to Gemini, which reads the text (OCR) and
  # segments it by recipe. Returns each recipe's title, page metadata, and
  # the full OCR'd text -- ready for downstream structured extraction via
  # ExtractRecipeFromText.
  #
  # This replaces the old two-pass (boundary + multimodal extraction) approach
  # with a single multimodal call whose output is plain text per recipe, not
  # structured recipe JSON. Structured extraction happens separately via the
  # existing text pipeline.
  #
  # Ported from souschef-flask-server's page_extraction_service.ocr_and_segment_pages.
  #
  # Usage:
  #   segments = Llm::OcrSegmentPages.call(
  #     image_paths: ["/path/to/leaf_10.jpg", "/path/to/leaf_11.jpg"],
  #     leaf_numbers: [10, 11]
  #   )
  #   # => [{"title" => "To Roast a Pig", "start_leaf" => 10, "end_leaf" => 11,
  #   #       "printed_page" => "42", "text" => "To Roast a Pig.\nTake a young pig..."}, ...]
  class OcrSegmentPages
    MODEL = 'google/gemini-2.5-flash'
    TOKENS_PER_PAGE = 2000
    MIN_TOKENS = 6000

    def self.call(...)
      new(...).call
    end

    def initialize(image_paths:, leaf_numbers:, model: MODEL, temperature: 0.2)
      @image_paths  = Array(image_paths)
      @leaf_numbers = Array(leaf_numbers)
      @model = model
      @temperature = temperature
      @client = Llm::OpenRouterClient.new
    end

    def call
      return [] if @image_paths.blank?
      if @image_paths.size != @leaf_numbers.size
        raise ArgumentError, 'image_paths and leaf_numbers must have the same length'
      end

      images_b64 = Llm::MultimodalContentBuilder.encode_images(@image_paths)
      user_content = Llm::MultimodalContentBuilder.build(
        images_b64: images_b64,
        leaf_numbers: @leaf_numbers,
        text_preamble: Llm::Prompts::OcrSegmentPages::SYSTEM_PROMPT
      )

      max_tokens = [@image_paths.size * TOKENS_PER_PAGE, MIN_TOKENS].max

      result = @client.chat_completion(
        system_prompt: 'You are a helpful assistant that reads cookbook page images and returns JSON.',
        user_content: user_content,
        model: @model,
        temperature: @temperature,
        max_tokens: max_tokens,
        provider: Llm::OpenRouterClient::GOOGLE_PROVIDER,
        parser: :json_with_recovery
      )

      unwrap_segments(result)
    end

    private

    def unwrap_segments(parsed)
      case parsed
      when Array
        parsed.select { |s| s.is_a?(Hash) }
      when Hash
        %w[recipes segments results].each do |key|
          return parsed[key].select { |s| s.is_a?(Hash) } if parsed[key].is_a?(Array)
        end
        parsed.key?('title') && parsed.key?('text') ? [parsed] : []
      else
        []
      end
    end
  end
end
