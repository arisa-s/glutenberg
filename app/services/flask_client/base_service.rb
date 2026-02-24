# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'
require 'openssl'

# Simplified Flask API client adapted from souschef-rails-server's
# FlaskServer::BaseService. Removed: distributed locking, Redis caching,
# skip logic, and post-lock polling.
module FlaskClient
  # Raised when the Flask API returns a non-success status.
  # Message is the API's "error" field when present, otherwise a generic message.
  class ApiError < StandardError
    attr_reader :response_code

    def initialize(response_code, message)
      @response_code = response_code
      super(message)
    end
  end

  class BaseService
    BASE_URI = 'https://souscheflask.eu.ngrok.io'
    DEFAULT_TIMEOUT = 120

    def self.call(...)
      new(...).call
    end

    def call
      return nil if skip?

      execute_request
    rescue Net::ReadTimeout => e
      Rails.logger.error("Flask API timeout at #{endpoint_path}: #{e.message}")
      raise "Request to Flask API timed out after #{DEFAULT_TIMEOUT} seconds."
    rescue StandardError => e
      Rails.logger.error("Flask API error at #{endpoint_path}: #{e.message}")
      raise
    end

    private

    def execute_request
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == 'https')
      http.open_timeout = DEFAULT_TIMEOUT
      http.read_timeout = DEFAULT_TIMEOUT

      if http.use_ssl?
        http.verify_mode = if uri.host.include?('ngrok') || Rails.env.development?
                             OpenSSL::SSL::VERIFY_NONE
                           else
                             OpenSSL::SSL::VERIFY_PEER
                           end
      end

      request = Net::HTTP::Post.new(uri)
      request['Content-Type'] = 'application/json'
      request.body = request_body.to_json

      begin
        response = http.request(request)

        unless response.is_a?(Net::HTTPSuccess)
          api_message = parse_error_message(response)
          raise ApiError.new(response.code.to_i, api_message)
        end

        on_success(response)
      ensure
        http&.finish if http&.started?
      end
    end

    def skip?
      false
    end

    def uri
      URI.join(BASE_URI, endpoint_path)
    end

    def endpoint_path
      raise NotImplementedError, 'Subclasses must define endpoint_path.'
    end

    def request_body
      raise NotImplementedError, 'Subclasses must define request_body.'
    end

    def on_success(response)
      JSON.parse(response.body)
    end

    def parse_error_message(response)
      body = response.body
      return "Request to Flask API failed at #{endpoint_path}. Response code: #{response.code}" if body.blank?

      parsed = JSON.parse(body)
      parsed['error'].to_s.presence || "Request to Flask API failed at #{endpoint_path}. Response code: #{response.code}"
    rescue JSON::ParserError
      "Request to Flask API failed at #{endpoint_path}. Response code: #{response.code}"
    end
  end
end
