# frozen_string_literal: true

module Llm
  # Pass 2 of the two-pass multimodal IA pipeline.
  #
  # Sends targeted page images (with optional expected recipe titles from Pass 1)
  # to Gemini to extract fully structured recipes directly from the images.
  #
  # Usage:
  #   recipes = Llm::ExtractRecipesFromPages.call(
  #     image_paths: ["/path/to/leaf_10.jpg", "/path/to/leaf_11.jpg"],
  #     leaf_numbers: [10, 11],
  #     expected_recipes: ["To Roast a Pig", "To Boil a Fowl"]
  #   )
  class ExtractRecipesFromPages
    MODEL = 'google/gemini-2.0-flash-001'
    TOKENS_PER_PAGE = 3000
    MIN_TOKENS = 8000

    def self.call(...)
      new(...).call
    end

    def initialize(image_paths:, leaf_numbers:, expected_recipes: nil,
                   model: MODEL, temperature: 0.3)
      @image_paths      = Array(image_paths)
      @leaf_numbers     = Array(leaf_numbers)
      @expected_recipes = expected_recipes
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

      preamble = Llm::Prompts::ExtractRecipesFromPages::USER_PREAMBLE
      if @expected_recipes.present?
        preamble = preamble + "\n\n**Expected recipes on these pages** " \
          "(from a prior identification pass):\n" +
          @expected_recipes.map { |t| "- #{t}" }.join("\n")
      end

      user_content = Llm::MultimodalContentBuilder.build(
        images_b64: images_b64,
        leaf_numbers: @leaf_numbers,
        text_preamble: preamble
      )

      max_tokens = [@image_paths.size * TOKENS_PER_PAGE, MIN_TOKENS].max

      result = @client.chat_completion(
        system_prompt: Llm::Prompts::ExtractRecipesFromPages::SYSTEM_PROMPT,
        user_content: user_content,
        model: @model,
        temperature: @temperature,
        max_tokens: max_tokens,
        provider: Llm::OpenRouterClient::GOOGLE_PROVIDER,
        parser: :json_with_recovery
      )

      recipes = unwrap_recipes(result)

      recipes.each do |recipe|
        Llm::FdcEnrichment.enrich_ingredient_groups(recipe['ingredient_groups'])
      end

      recipes
    end

    private

    def unwrap_recipes(parsed)
      case parsed
      when Array
        parsed.select { |r| r.is_a?(Hash) }
      when Hash
        %w[recipes results].each do |key|
          return parsed[key].select { |r| r.is_a?(Hash) } if parsed[key].is_a?(Array)
        end
        parsed.key?('title') ? [parsed] : []
      else
        []
      end
    end
  end
end
