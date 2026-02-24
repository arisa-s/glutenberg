# frozen_string_literal: true

require 'net/http'
require 'fileutils'
require 'json'

# Downloads and caches individual page images from an Internet Archive book.
#
# Uses the IA IIIF Image API to fetch JPEG images of each leaf/page:
#   https://iiif.archive.org/iiif/{identifier}${leaf}/full/{width},/0/default.jpg
#
# Page images are cached to:
#   data/internet_archive/{identifier}/pages/leaf_{n}.jpg
#
# Usage:
#   pages = InternetArchive::FetchPageImagesService.call(
#     source: source,
#     start_leaf: 10,
#     end_leaf: 400,
#     width: 1000
#   )
#   # => [{path: "/abs/path/leaf_10.jpg", leaf_number: 10}, ...]
#
module InternetArchive
  class FetchPageImagesService
    CACHE_DIR  = Rails.root.join('data', 'internet_archive').freeze
    USER_AGENT = 'ProjectGlutenberg/1.0 (research thesis; contact: project-glutenberg@example.com)'
    REQUEST_DELAY = 0.5 # seconds between requests (be polite to IA)
    DOWNLOAD_THREADS = 6 # concurrent downloads
    MAX_REDIRECTS = 5
    DEFAULT_WIDTH = 1000 # pixels — readable for Gemini, low token cost

    class FetchError < StandardError; end

    def self.call(...)
      new(...).call
    end

    # @param source [Source] a Source record with external_id set to the IA identifier
    # @param start_leaf [Integer, nil] first leaf to download (0-indexed); nil = 0
    # @param end_leaf [Integer, nil] last leaf to download (inclusive); nil = last leaf
    # @param width [Integer] image width in pixels (height scales proportionally)
    # @param force [Boolean] re-download even if cached
    def initialize(source:, start_leaf: nil, end_leaf: nil, width: DEFAULT_WIDTH, force: false)
      @source     = source
      @start_leaf = start_leaf
      @end_leaf   = end_leaf
      @width      = width
      @force      = force
    end

    def call
      validate!
      total_leaves = fetch_leaf_count
      first = @start_leaf || 0
      last  = @end_leaf   || (total_leaves - 1)

      raise FetchError, "start_leaf (#{first}) > end_leaf (#{last})" if first > last
      raise FetchError, "end_leaf (#{last}) exceeds total leaves (#{total_leaves})" if last >= total_leaves

      leaves = (first..last).to_a
      cached = leaves.count { |l| leaf_cache_path(l).exist? }
      to_download = leaves.size - cached

      if to_download > 0
        puts "  Downloading #{to_download} pages (#{cached} cached) with #{DOWNLOAD_THREADS} threads..."
        download_leaves_parallel(leaves)
      elsif cached > 0
        puts "  All #{cached} pages cached"
      end

      pages = leaves
        .select { |l| leaf_cache_path(l).exist? }
        .map { |l| { path: leaf_cache_path(l).to_s, leaf_number: l } }
      puts "  Downloaded #{pages.size} page images for '#{identifier}'"
      pages
    end

    private

    def identifier
      @source.external_id
    end

    def validate!
      raise FetchError, "Source has no external_id" if identifier.blank?
    end

    # -----------------------------------------------------------------
    # Metadata: discover total leaf count
    # -----------------------------------------------------------------

    def fetch_leaf_count
      metadata_url = "https://archive.org/metadata/#{identifier}"
      puts "  Fetching metadata from #{metadata_url}..."

      response = fetch_url(URI(metadata_url))
      sleep(REQUEST_DELAY)

      unless response.is_a?(Net::HTTPSuccess)
        raise FetchError, "IA metadata API returned HTTP #{response.code} for '#{identifier}'"
      end

      metadata = JSON.parse(response.body)
      files = metadata['files'] || []

      # Strategy 1: metadata.imagecount (some items have this)
      image_count = metadata.dig('metadata', 'imagecount')&.to_i
      if image_count && image_count > 0
        puts "  Total leaves: #{image_count} (from metadata.imagecount)"
        return image_count
      end

      # Strategy 2: filecount on the JP2 ZIP bundle (most scanned books)
      jp2_zip = files.find { |f| f['name']&.end_with?('_jp2.zip') }
      if jp2_zip && jp2_zip['filecount'].to_i > 0
        count = jp2_zip['filecount'].to_i
        puts "  Total leaves: #{count} (from JP2 ZIP filecount)"
        return count
      end

      # Strategy 3: count individual JP2 files in the manifest
      jp2_count = files.count { |f| f['name']&.end_with?('.jp2') }
      if jp2_count > 0
        puts "  Total leaves: #{jp2_count} (from individual JP2 files)"
        return jp2_count
      end

      # Strategy 4: parse scandata.xml for page count
      scandata_file = files.find { |f| f['name']&.end_with?('_scandata.xml') }
      if scandata_file
        count = fetch_leaf_count_from_scandata(scandata_file['name'])
        if count && count > 0
          puts "  Total leaves: #{count} (from scandata.xml)"
          return count
        end
      end

      raise FetchError, "Could not determine page count for '#{identifier}'. " \
                        "Check that the item has scanned page images."
    end

    def fetch_leaf_count_from_scandata(filename)
      url = "https://archive.org/download/#{identifier}/#{filename}"
      response = fetch_url(URI(url))
      sleep(REQUEST_DELAY)
      return nil unless response.is_a?(Net::HTTPSuccess)

      require 'rexml/document'
      doc = REXML::Document.new(response.body)
      doc.elements.to_a('//page').size
    rescue StandardError
      nil
    end

    # -----------------------------------------------------------------
    # Download leaf images via IIIF (parallel with thread pool)
    # -----------------------------------------------------------------

    def download_leaves_parallel(leaves)
      queue = Queue.new
      leaves.each { |l| queue << l unless leaf_cache_path(l).exist? && !@force }
      return if queue.empty?

      FileUtils.mkdir_p(pages_dir)
      mutex = Mutex.new
      errors = []

      threads = DOWNLOAD_THREADS.times.map do
        Thread.new do
          loop do
            leaf = queue.pop(true) rescue nil
            break if leaf.nil?

            begin
              download_leaf(leaf)
              sleep(REQUEST_DELAY)
            rescue StandardError => e
              mutex.synchronize { errors << "Leaf #{leaf}: #{e.message}" }
            end
          end
        end
      end
      threads.each(&:join)

      if errors.any?
        puts "  WARNING: #{errors.size} leaf(s) failed to download (skipped):"
        errors.each { |e| puts "    - #{e}" }
      end
    end

    def download_leaf(leaf)
      path = leaf_cache_path(leaf)
      return path if path.exist? && !@force

      url = iiif_url(leaf)
      response = fetch_url(URI(url))

      unless response.is_a?(Net::HTTPSuccess)
        raise "HTTP #{response.code} downloading leaf #{leaf} from #{url}"
      end

      File.binwrite(path, response.body)
      path
    end

    def iiif_url(leaf)
      "https://iiif.archive.org/iiif/#{identifier}$#{leaf}/full/#{@width},/0/default.jpg"
    end

    def pages_dir
      @pages_dir ||= CACHE_DIR.join(identifier, 'pages')
    end

    def leaf_cache_path(leaf)
      pages_dir.join("leaf_#{leaf}.jpg")
    end

    # -----------------------------------------------------------------
    # HTTP helper (shared pattern with FetchBookService)
    # -----------------------------------------------------------------

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
        return fetch_url(new_uri, limit - 1)
      end

      response
    end
  end
end
