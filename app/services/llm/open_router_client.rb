# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'

module Llm
  # HTTP client for the OpenRouter API (OpenAI-compatible chat completions).
  # Ported from souschef-flask-server's openrouter_client.py.
  #
  # Usage:
  #   client = Llm::OpenRouterClient.new
  #   result = client.chat_completion(
  #     system_prompt: "You are a helpful assistant.",
  #     user_content: "Extract the recipe from this text...",
  #     model: "google/gemini-2.5-flash-lite",
  #     response_json: true
  #   )
  class OpenRouterClient
    BASE_URL = 'https://openrouter.ai/api/v1/chat/completions'
    MAX_RETRIES = 2
    DEFAULT_MODEL = 'google/gemini-2.5-flash-lite'
    GOOGLE_PROVIDER = { 'order' => ['google'] }.freeze
    LATENCY_PROVIDER = { 'sort' => 'latency', 'order' => ['openai'] }.freeze

    def initialize(api_key: nil)
      @api_key = api_key || ENV.fetch('OPENROUTER_API_KEY') {
        raise 'OPENROUTER_API_KEY is not set. Add it to your .env file.'
      }
    end

    # Send a chat completion request and parse the response.
    #
    # @param system_prompt [String] system message for the model
    # @param user_content [String, Array] plain text or multimodal content blocks
    # @param model [String] OpenRouter model identifier
    # @param max_tokens [Integer] maximum response tokens
    # @param temperature [Float] sampling temperature
    # @param response_json [Boolean] request JSON response format
    # @param provider [Hash, nil] OpenRouter provider routing preferences
    # @param parser [Symbol] :json or :json_with_recovery
    # @return [Hash, Array, nil] parsed response
    def chat_completion(system_prompt:, user_content:, model: DEFAULT_MODEL,
                        max_tokens: 1500, temperature: 0.5, response_json: true,
                        provider: LATENCY_PROVIDER, parser: :json)
      payload = build_payload(
        system_prompt: system_prompt,
        user_content: user_content,
        model: model,
        max_tokens: max_tokens,
        temperature: temperature,
        response_json: response_json,
        provider: provider
      )

      last_error = nil
      (1 + MAX_RETRIES).times do |attempt|
        response_content, finish_reason = execute_request(payload)

        if finish_reason == 'length'
          Rails.logger.warn(
            "[Llm::OpenRouterClient] Response truncated (finish_reason=length, " \
            "max_tokens=#{max_tokens}, content_chars=#{response_content&.length || 0})"
          )
        end

        if finish_reason == 'error' && attempt < MAX_RETRIES
          Rails.logger.warn("[Llm::OpenRouterClient] Provider error (attempt #{attempt + 1}), retrying...")
          next
        end

        begin
          parsed = parse_response(response_content, parser)
          if parsed.nil? && response_content
            Rails.logger.warn(
              "[Llm::OpenRouterClient] Parser returned nil " \
              "(finish_reason=#{finish_reason}, content_chars=#{response_content.length})"
            )
          end
          return parsed
        rescue StandardError => e
          last_error = e
          if attempt < MAX_RETRIES
            Rails.logger.warn("[Llm::OpenRouterClient] Parse failed (attempt #{attempt + 1}), retrying: #{e.message}")
          else
            Rails.logger.error("[Llm::OpenRouterClient] Parse failed after #{attempt + 1} attempts: #{e.message}")
            raise
          end
        end
      end
    end

    private

    def build_payload(system_prompt:, user_content:, model:, max_tokens:,
                      temperature:, response_json:, provider:)
      payload = {
        'model' => model,
        'messages' => [
          { 'role' => 'system', 'content' => system_prompt },
          { 'role' => 'user', 'content' => user_content }
        ],
        'max_tokens' => max_tokens,
        'temperature' => temperature
      }

      payload['response_format'] = { 'type' => 'json_object' } if response_json
      payload['provider'] = provider if provider
      payload
    end

    def execute_request(payload)
      uri = URI(BASE_URL)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.cert_store = ssl_cert_store
      http.open_timeout = 30
      http.read_timeout = 120

      request = Net::HTTP::Post.new(uri)
      request['Content-Type'] = 'application/json'
      request['Authorization'] = "Bearer #{@api_key}"
      request.body = payload.to_json

      response = http.request(request)

      unless response.is_a?(Net::HTTPSuccess)
        raise "OpenRouter API error (#{response.code}): #{response.body.truncate(500)}"
      end

      body = JSON.parse(response.body)
      choice = body.dig('choices', 0)
      content = choice&.dig('message', 'content')
      finish_reason = choice&.fetch('finish_reason', nil)

      [content, finish_reason]
    end

    def ssl_cert_store
      store = OpenSSL::X509::Store.new
      store.set_default_paths
      store
    end

    def parse_response(content, parser)
      case parser
      when :json
        Llm::ResponseParser.parse_json(content)
      when :json_with_recovery
        Llm::ResponseParser.parse_json_with_truncation_recovery(content)
      else
        content
      end
    end
  end
end
