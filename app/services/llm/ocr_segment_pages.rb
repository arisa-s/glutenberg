# frozen_string_literal: true

module Llm
  # Combined OCR + recipe segmentation via Gemini multimodal.
  #
  # Sends batched page images to Gemini, which reads the text (OCR) and
  # segments it by recipe. Returns each recipe's title, page metadata,
  # and the full OCR'd text.
  #
  # Usage:
  #   segments = Llm::OcrSegmentPages.call(
  #     image_paths: ["/path/to/leaf_50.jpg", "/path/to/leaf_51.jpg"],
  #     leaf_numbers: [50, 51]
  #   )
  class OcrSegmentPages
    OCR_MODEL = 'google/gemini-2.0-flash-001'
    TOKENS_PER_PAGE = 2000
    MIN_TOKENS = 6000

    def self.call(...)
      new(...).call
    end

    def initialize(image_paths:, leaf_numbers:, model: OCR_MODEL, temperature: 0.2)
      @image_paths  = Array(image_paths)
      @leaf_numbers = Array(leaf_numbers)
      @model = model
      @temperature = temperature
      @client = Llm::OpenRouterClient.new
    end

    def call
      raise ArgumentError, 'At least one page image is required' if @image_paths.empty?
      if @image_paths.size != @leaf_numbers.size
        raise ArgumentError, 'image_paths and leaf_numbers must have the same length'
      end

      images_b64 = Llm::MultimodalContentBuilder.encode_images(@image_paths)
      user_content = Llm::MultimodalContentBuilder.build(
        images_b64: images_b64,
        leaf_numbers: @leaf_numbers,
        text_preamble: Llm::Prompts::OcrSegmentPages::USER_PREAMBLE
      )

      max_tokens = [@image_paths.size * TOKENS_PER_PAGE, MIN_TOKENS].max

      result = @client.chat_completion(
        system_prompt: Llm::Prompts::OcrSegmentPages::SYSTEM_PROMPT,
        user_content: user_content,
        model: @model,
        temperature: @temperature,
        max_tokens: max_tokens,
        provider: Llm::OpenRouterClient::GOOGLE_PROVIDER,
        parser: :json_with_recovery
      )

      segments = unwrap_segments(result)

      if segments.empty?
        Rails.logger.warn(
          "[Llm::OcrSegmentPages] Returned 0 recipes for #{@image_paths.size} pages " \
          "(max_tokens=#{max_tokens})"
        )
      end

      segments
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
