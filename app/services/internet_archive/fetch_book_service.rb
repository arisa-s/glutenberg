# frozen_string_literal: true

require 'net/http'
require 'fileutils'
require 'json'

# Downloads and caches an Internet Archive book's OCR full text to disk.
#
# Tries the standard IA file naming convention first:
#   https://archive.org/download/{identifier}/{identifier}_djvu.txt
#
# Falls back to the IA metadata API to discover the correct text filename.
#
# Usage:
#   path = InternetArchive::FetchBookService.call(source: source)
#   # => "data/internet_archive/bim_eighteenth-century_the-experienced-english-_raffald-elizabeth_1784.txt"
#
module InternetArchive
  class FetchBookService
    CACHE_DIR = Rails.root.join('data', 'internet_archive').freeze
    USER_AGENT = 'ProjectGlutenberg/1.0 (research thesis; contact: project-glutenberg@example.com)'
    REQUEST_DELAY = 2 # seconds between requests (be polite to IA)

    class FetchError < StandardError; end

    def self.call(...)
      new(...).call
    end

    # @param source [Source] a Source record with external_id set to the IA identifier
    # @param force [Boolean] re-download even if cached
    def initialize(source:, force: false)
      @source = source
      @force = force
    end

    def call
      validate!
      return cached_path.to_s if cached? && !@force

      text = download
      save(text)
      cached_path.to_s
    end

    private

    def identifier
      @source.external_id
    end

    def validate!
      raise FetchError, "Source has no external_id" if identifier.blank?
    end

    def cached?
      cached_path.exist?
    end

    def cached_path
      @cached_path ||= CACHE_DIR.join("#{identifier}.txt")
    end

    MAX_REDIRECTS = 5

    # Try the standard _djvu.txt URL first, then fall back to metadata lookup.
    def download
      text = try_direct_download
      return text if text

      puts "  Standard _djvu.txt not found, checking IA metadata for text file..."
      text = try_metadata_lookup
      return text if text

      raise FetchError, "Could not find a text file for IA item '#{identifier}'. " \
                        "Check that the item exists and has a FULL TEXT download."
    end

    # Standard IA naming: {identifier}_djvu.txt
    def try_direct_download
      url = "https://archive.org/download/#{identifier}/#{identifier}_djvu.txt"
      puts "  Trying #{url}..."

      response = fetch_url(URI(url))
      sleep(REQUEST_DELAY)

      if response.is_a?(Net::HTTPSuccess)
        response.body.force_encoding('UTF-8')
      else
        puts "  Got HTTP #{response.code}, will try metadata fallback."
        nil
      end
    end

    # Query the IA metadata API to find the text file.
    def try_metadata_lookup
      metadata_url = "https://archive.org/metadata/#{identifier}"
      puts "  Fetching metadata from #{metadata_url}..."

      response = fetch_url(URI(metadata_url))
      sleep(REQUEST_DELAY)

      unless response.is_a?(Net::HTTPSuccess)
        raise FetchError, "IA metadata API returned HTTP #{response.code} for '#{identifier}'"
      end

      metadata = JSON.parse(response.body)
      files = metadata['files'] || []

      # Look for text files in order of preference
      text_file = files.find { |f| f['name']&.end_with?('_djvu.txt') } ||
                  files.find { |f| f['format'] == 'DjVuTXT' } ||
                  files.find { |f| f['name']&.end_with?('.txt') && f['source'] == 'derivative' }

      unless text_file
        available = files.map { |f| f['name'] }.compact.join(', ')
        raise FetchError, "No text file found in IA metadata for '#{identifier}'. " \
                          "Available files: #{available.truncate(200)}"
      end

      file_url = "https://archive.org/download/#{identifier}/#{text_file['name']}"
      puts "  Found text file: #{text_file['name']}, downloading..."

      response = fetch_url(URI(file_url))
      sleep(REQUEST_DELAY)

      unless response.is_a?(Net::HTTPSuccess)
        raise FetchError, "HTTP #{response.code} downloading #{file_url}"
      end

      response.body.force_encoding('UTF-8')
    end

    def fetch_url(uri, limit = MAX_REDIRECTS)
      raise FetchError, "Too many redirects for #{uri}" if limit <= 0

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == 'https')
      store = OpenSSL::X509::Store.new
      store.set_default_paths
      http.cert_store = store
      http.open_timeout = 30
      http.read_timeout = 60

      request = Net::HTTP::Get.new(uri)
      request['User-Agent'] = USER_AGENT
      response = http.request(request)

      if response.is_a?(Net::HTTPRedirection)
        location = response['location']
        new_uri = URI.join(uri, location)
        puts "  Redirected to #{new_uri}..."
        return fetch_url(new_uri, limit - 1)
      end

      response
    end

    def save(text)
      FileUtils.mkdir_p(CACHE_DIR)
      File.write(cached_path, text)
      puts "  Cached to #{cached_path} (#{(text.bytesize / 1024.0).round(1)} KB)"
    end
  end
end
