# frozen_string_literal: true

# Orchestrates splitting a cached Internet Archive book's OCR text into
# recipe text chunks using a pluggable split strategy.
#
# The splitter can be:
#   1. A registered strategy name (string/symbol), looked up in the Registry
#   2. Any object that responds to .call(text) -> Array<Hash>
#   3. Omitted — falls back to source.split_strategy if set
#
# Each chunk is a Hash with:
#   :text            [String]      — plain text of a single recipe (title included)
#   :section_header  [String, nil] — chapter/section the recipe belongs to
#   :page_number     [Integer, nil] — original book page where the recipe starts
#
# The Flask service handles title extraction from the text.
#
# Usage:
#   # Using a registered strategy name:
#   chunks = InternetArchive::SplitBookService.call(source: source, strategy: 'raffald')
#
#   # Using source.split_strategy (set on the Source record):
#   source.update!(split_strategy: 'raffald')
#   chunks = InternetArchive::SplitBookService.call(source: source)
#
#   # Using a custom callable:
#   chunks = InternetArchive::SplitBookService.call(source: source, strategy: ->(text) { ... })
#
module InternetArchive
  class SplitBookService
    class SplitError < StandardError; end

    def self.call(...)
      new(...).call
    end

    # @param source [Source] the source record (must have external_id for cache lookup)
    # @param strategy [String, Symbol, #call, nil] split strategy name, callable, or nil
    # @param text [String, nil] optional text override (skips reading from cache)
    def initialize(source:, strategy: nil, text: nil)
      @source = source
      @strategy = strategy
      @text = text
    end

    def call
      text = load_text
      splitter = resolve_splitter
      chunks = splitter.call(text)

      puts "  Split into #{chunks.size} recipe chunks"
      chunks
    end

    private

    def load_text
      return @text if @text.present?

      cached_path = InternetArchive::FetchBookService::CACHE_DIR.join("#{@source.external_id}.txt")

      unless cached_path.exist?
        raise SplitError, "No cached text for source '#{@source.external_id}'. " \
                          "Run: rails \"ia:fetch[#{@source.id}]\"" \
                          " (use the source id, not external_id)."
      end

      File.read(cached_path)
    end

    def resolve_splitter
      strategy = @strategy || @source.split_strategy

      if strategy.nil?
        raise SplitError, "No split strategy provided and source.split_strategy is not set. " \
                          "Pass strategy: 'name' or set source.split_strategy. " \
                          "Available: #{InternetArchive::Splitters::Registry.list.join(', ')}"
      end

      if strategy.respond_to?(:call)
        strategy
      else
        InternetArchive::Splitters::Registry.get(strategy)
      end
    end
  end
end
