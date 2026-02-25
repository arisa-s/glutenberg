# frozen_string_literal: true

module Llm
  # Pass 1 of the two-pass multimodal IA pipeline.
  #
  # Sends a batch of page images to Gemini to identify recipe titles
  # and their page ranges. Output is compact (titles + leaf ranges),
  # keeping this pass cheap.
  #
  # Usage:
  #   boundaries = Llm::IdentifyRecipeBoundaries.call(
  #     image_paths: ["/path/to/leaf_10.jpg", "/path/to/leaf_11.jpg"],
  #     leaf_numbers: [10, 11]
  #   )
  #   # => [{"title" => "To Roast a Pig", "start_leaf" => 10, ...}, ...]
  class IdentifyRecipeBoundaries
    MODEL = 'google/gemini-2.0-flash-001'

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
        text_preamble: Llm::Prompts::IdentifyRecipeBoundaries::USER_PREAMBLE
      )

      result = @client.chat_completion(
        system_prompt: Llm::Prompts::IdentifyRecipeBoundaries::SYSTEM_PROMPT,
        user_content: user_content,
        model: @model,
        temperature: @temperature,
        max_tokens: 4000,
        provider: Llm::OpenRouterClient::GOOGLE_PROVIDER,
        parser: :json_with_recovery
      )

      unwrap_boundaries(result)
    end

    private

    def unwrap_boundaries(parsed)
      case parsed
      when Array
        parsed.select { |b| b.is_a?(Hash) }
      when Hash
        %w[boundaries recipes results].each do |key|
          return parsed[key].select { |b| b.is_a?(Hash) } if parsed[key].is_a?(Array)
        end
        []
      else
        []
      end
    end
  end
end
