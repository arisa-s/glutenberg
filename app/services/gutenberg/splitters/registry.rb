# frozen_string_literal: true

# Registry for book-specific split strategies.
#
# Each strategy is registered by a name (string) and must respond to
# .call(html) -> Array<{ title:, body: }>.
#
# Usage:
#   # Register (usually done in the strategy file itself):
#   Gutenberg::Splitters::Registry.register('francatelli', Gutenberg::Splitters::FrancatelliStrategy)
#
#   # Look up:
#   splitter = Gutenberg::Splitters::Registry.get('francatelli')
#   chunks = splitter.call(html)
#
#   # List all:
#   Gutenberg::Splitters::Registry.list  # => ['francatelli', 'mollard', ...]
#
#   # Default when none specified (e.g. in rake tasks):
#   Gutenberg::Splitters::Registry.default  # => 'francatelli'
#
module Gutenberg
  module Splitters
    class Registry
      # Used by rake tasks when no strategy is passed and source.split_strategy is blank.
      DEFAULT_STRATEGY = "francatelli"

      class << self
        def register(name, strategy)
          registry[name.to_s] = strategy
        end

        def get(name)
          load_strategies
          strategy = registry[name.to_s]
          raise ArgumentError, "Unknown split strategy: '#{name}'. Available: #{list.join(', ')}" unless strategy

          strategy
        end

        # Returns the default strategy name (for use when none is specified).
        # Prefers DEFAULT_STRATEGY if registered; otherwise the first registered strategy.
        def default
          load_strategies
          return DEFAULT_STRATEGY if registered?(DEFAULT_STRATEGY)
          return list.first if list.any?

          nil
        end

        def get!(name)
          get(name)
        end

        def list
          load_strategies
          registry.keys.sort
        end

        def registered?(name)
          load_strategies
          registry.key?(name.to_s)
        end

        private

        def registry
          @registry ||= {}
        end

        def load_strategies
          return if @strategies_loaded

          @strategies_loaded = true
          Dir[Rails.root.join("app/services/gutenberg/splitters/*_strategy.rb")].sort.each { |f| load f }
        end
      end
    end
  end
end
