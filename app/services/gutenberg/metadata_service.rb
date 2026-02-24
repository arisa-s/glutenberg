# frozen_string_literal: true

require 'net/http'
require 'json'

# Fetches book metadata from the Gutendex API (https://gutendex.com).
#
# Given a Gutenberg book ID (or a Gutenberg URL from which the ID is extracted),
# returns a hash of metadata ready to assign to a Source record.
#
# Usage:
#   metadata = Gutenberg::MetadataService.call(22114)
#   # => { external_id: "22114", title: "A Plain Cookery Book...",
#   #      author: "Francatelli, Charles Elmé", source_url: "https://...",
#   #      language: "en", provider: "gutenberg" }
#
#   metadata = Gutenberg::MetadataService.call("https://www.gutenberg.org/files/22114/22114-h/22114-h.htm")
#   # => same result (extracts ID 22114 from the URL)
#
module Gutenberg
  class MetadataService
    GUTENDEX_API = 'https://gutendex.com/books'
    USER_AGENT = 'ProjectGlutenberg/1.0 (research thesis)'

    # Regex to extract a Gutenberg book ID from various URL formats:
    #   /files/22114/...  /ebooks/22114  /cache/epub/10136/...
    GUTENBERG_ID_PATTERN = %r{gutenberg\.org/(?:files|ebooks|cache/epub)/(\d+)}

    class MetadataError < StandardError; end

    def self.call(book_id_or_url)
      new(book_id_or_url).call
    end

    def initialize(book_id_or_url)
      @book_id = extract_id(book_id_or_url)
    end

    def call
      data = fetch_from_gutendex
      parse_metadata(data)
    end

    private

    def extract_id(input)
      input = input.to_s.strip

      # If it's already a plain number
      return input if input.match?(/\A\d+\z/)

      # Try to extract from a URL
      match = input.match(GUTENBERG_ID_PATTERN)
      return match[1] if match

      raise MetadataError, "Cannot extract Gutenberg book ID from: #{input}"
    end

    def fetch_from_gutendex
      uri = URI("#{GUTENDEX_API}/#{@book_id}")
      puts "  Fetching metadata from #{uri}..."

      response = http_get(uri)

      unless response.is_a?(Net::HTTPSuccess)
        raise MetadataError, "Gutendex API returned HTTP #{response.code} for book #{@book_id}"
      end

      JSON.parse(response.body)
    rescue OpenSSL::SSL::SSLError => e
      raise MetadataError, "SSL error connecting to Gutendex: #{e.message}"
    rescue JSON::ParserError => e
      raise MetadataError, "Failed to parse Gutendex response: #{e.message}"
    end

    # HTTP GET with redirect following and macOS-compatible SSL.
    def http_get(uri, limit = 5)
      raise MetadataError, "Too many redirects" if limit <= 0

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == 'https')
      store = OpenSSL::X509::Store.new
      store.set_default_paths
      http.cert_store = store
      http.open_timeout = 10
      http.read_timeout = 15

      request = Net::HTTP::Get.new(uri)
      request['User-Agent'] = USER_AGENT

      begin
        response = http.request(request)
      rescue OpenSSL::SSL::SSLError => e
        raise unless e.message.include?('certificate')
        Rails.logger.warn("[Gutenberg::MetadataService] SSL cert error for #{uri.host}, retrying without verification")
        http.verify_mode = OpenSSL::SSL::VERIFY_NONE
        response = http.request(request)
      end

      if response.is_a?(Net::HTTPRedirection)
        new_uri = URI.join(uri, response['location'])
        return http_get(new_uri, limit - 1)
      end

      response
    end

    def parse_metadata(data)
      {
        external_id: data['id'].to_s,
        title: data['title'],
        author: format_author(data['authors']),
        source_url: extract_html_url(data['formats']),
        image_url: extract_cover_url(data['formats']),
        language: data['languages']&.first || 'en',
        provider: 'gutenberg'
      }
    end

    def format_author(authors)
      return nil if authors.blank?

      # Gutendex gives "Last, First" format; keep as-is (standard bibliographic)
      authors.map { |a| a['name'] }.compact.join('; ')
    end

    def extract_html_url(formats)
      return nil if formats.blank?

      # Prefer text/html format from Gutendex
      formats['text/html']
    end

    def extract_cover_url(formats)
      return nil if formats.blank?

      # Gutendex provides a cover image as image/jpeg
      formats['image/jpeg']
    end
  end
end
