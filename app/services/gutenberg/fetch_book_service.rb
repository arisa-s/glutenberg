# frozen_string_literal: true

require 'net/http'
require 'fileutils'

# Downloads and caches a Gutenberg book's HTML to disk.
#
# Respects Project Gutenberg's robot access policy:
# - Custom User-Agent with contact info
# - Rate limiting (configurable delay between requests)
# - Caches locally to avoid repeat downloads
#
# Usage:
#   path = Gutenberg::FetchBookService.call(source)
#   # => "data/gutenberg/41352.htm"
#
module Gutenberg
  class FetchBookService
    CACHE_DIR = Rails.root.join('data', 'gutenberg').freeze
    USER_AGENT = 'ProjectGlutenberg/1.0 (research thesis; contact: project-glutenberg@example.com)'
    REQUEST_DELAY = 2 # seconds between requests (Gutenberg policy)

    class FetchError < StandardError; end

    def self.call(...)
      new(...).call
    end

    # @param source [Source] a Source record with source_url set
    # @param force [Boolean] re-download even if cached
    def initialize(source:, force: false)
      @source = source
      @force = force
    end

    def call
      validate!
      return cached_path.to_s if cached? && !@force

      html = download
      save(html)
      cached_path.to_s
    end

    private

    def validate!
      raise FetchError, "Source has no source_url" if @source.source_url.blank?
      raise FetchError, "Source has no external_id" if @source.external_id.blank?
    end

    def cached?
      cached_path.exist?
    end

    def cached_path
      @cached_path ||= CACHE_DIR.join("#{@source.external_id}.htm")
    end

    MAX_REDIRECTS = 5

    def download
      uri = URI(@source.source_url)
      puts "  Fetching #{uri}..."

      response = follow_redirects(uri)

      unless response.is_a?(Net::HTTPSuccess)
        raise FetchError, "HTTP #{response.code} for #{uri}"
      end

      # Respect rate limiting
      sleep(REQUEST_DELAY)

      response.body.force_encoding('UTF-8')
    end

    def follow_redirects(uri, limit = MAX_REDIRECTS)
      raise FetchError, "Too many redirects for #{uri}" if limit <= 0

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == 'https')
      store = OpenSSL::X509::Store.new
      store.set_default_paths
      http.cert_store = store

      request = Net::HTTP::Get.new(uri)
      request['User-Agent'] = USER_AGENT
      response = http.request(request)

      if response.is_a?(Net::HTTPRedirection)
        location = response['location']
        new_uri = URI.join(uri, location)
        puts "  Redirected to #{new_uri}..."
        return follow_redirects(new_uri, limit - 1)
      end

      response
    end

    def save(html)
      FileUtils.mkdir_p(CACHE_DIR)
      File.write(cached_path, html)
      puts "  Cached to #{cached_path} (#{(html.bytesize / 1024.0).round(1)} KB)"
    end
  end
end
