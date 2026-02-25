# frozen_string_literal: true

# Orchestrates splitting a cached Gutenberg book's HTML into
# recipe text chunks using a pluggable split strategy.
#
# The splitter can be:
#   1. A registered strategy name (string/symbol), looked up in the Registry
#   2. Any object that responds to .call(html) -> Array<Hash>
#   3. Omitted — falls back to source.split_strategy if set
#
# Each chunk is a Hash with:
#   :text            [String]      — plain text of a single recipe (title included)
#   :section_header  [String, nil] — chapter/section the recipe belongs to
#   :page_number     [Integer, nil] — original book page where the recipe starts
#   :recipe_number   [Integer, nil] — the recipe's number in the book (e.g. "No. 47")
#
# Usage:
#   chunks = Gutenberg::SplitBookService.call(source: source, strategy: 'francatelli')
#
#   source.update!(split_strategy: 'francatelli')
#   chunks = Gutenberg::SplitBookService.call(source: source)
#
module Gutenberg
  class SplitBookService
    class SplitError < StandardError; end

    def self.call(...)
      new(...).call
    end

    # @param source [Source] the source record (must have external_id for cache lookup)
    # @param strategy [String, Symbol, #call, nil] split strategy name, callable, or nil
    # @param html [String, nil] optional HTML override (skips reading from cache)
    def initialize(source:, strategy: nil, html: nil)
      @source = source
      @strategy = strategy
      @html = html
    end

    def call
      html = load_html
      splitter = resolve_splitter
      chunks = splitter.call(html)

      puts "  Split into #{chunks.size} recipe chunks"
      chunks
    end

    private

    def load_html
      return @html if @html.present?

      cached_path = Gutenberg::FetchBookService::CACHE_DIR.join("#{@source.external_id}.htm")

      unless cached_path.exist?
        raise SplitError, "No cached HTML for source '#{@source.external_id}'. " \
                          "Run: rails \"gutenberg:fetch[#{@source.id}]\""
      end

      File.read(cached_path)
    end

    def resolve_splitter
      strategy = @strategy || @source.split_strategy

      if strategy.nil?
        raise SplitError, "No split strategy provided and source.split_strategy is not set. " \
                          "Pass strategy: 'name' or set source.split_strategy. " \
                          "Available: #{Gutenberg::Splitters::Registry.list.join(', ')}"
      end

      if strategy.respond_to?(:call)
        strategy
      else
        Gutenberg::Splitters::Registry.get(strategy)
      end
    end
  end
end
