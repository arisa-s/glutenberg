# frozen_string_literal: true

require 'base64'

module Llm
  # Builds OpenAI-style multimodal content arrays from page images.
  # Ported from souschef-flask-server's page_extraction_service._build_multimodal_content.
  module MultimodalContentBuilder
    module_function

    # Build a multimodal content array from base64-encoded images.
    #
    # @param images_b64 [Array<String>] base64-encoded image data
    # @param leaf_numbers [Array<Integer>] corresponding leaf numbers
    # @param text_preamble [String] introductory text (the prompt)
    # @return [Array<Hash>] OpenAI-compatible content blocks
    def build(images_b64:, leaf_numbers:, text_preamble: '')
      content = []

      leaf_labels = leaf_numbers.map { |ln| "Leaf #{ln}" }
      label_text = [
        text_preamble,
        '',
        "The following #{images_b64.size} page images are labelled by leaf " \
        "number (our internal image ID, NOT the printed page number): " \
        "#{leaf_labels.join(', ')}."
      ].join("\n").strip

      content << { 'type' => 'text', 'text' => label_text }

      images_b64.each_with_index do |image_b64, i|
        url = if image_b64.start_with?('data:')
                image_b64
              else
                "data:image/jpeg;base64,#{image_b64}"
              end

        content << { 'type' => 'text', 'text' => "--- Leaf #{leaf_numbers[i]} ---" }
        content << { 'type' => 'image_url', 'image_url' => { 'url' => url } }
      end

      content
    end

    # Encode local image files to base64.
    #
    # @param image_paths [Array<String>] paths to image files
    # @return [Array<String>] base64-encoded image data
    def encode_images(image_paths)
      image_paths.map { |path| Base64.strict_encode64(File.binread(path)) }
    end
  end
end
