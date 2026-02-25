# frozen_string_literal: true

# ---------------------------------------------------------------------------
# Helper for interactive confirmation prompts in Rake tasks.
# ---------------------------------------------------------------------------
def confirm!(message)
  print "\n#{message} [y/N] "
  answer = $stdin.gets&.strip&.downcase
  abort "Cancelled." unless answer == 'y'
end

def log_step(step, total, message)
  puts "\n#{'=' * 60}"
  puts "[#{step}/#{total}] #{message}"
  puts '=' * 60
end

def log_info(label, value, fallback: '(not set)')
  formatted = value.present? ? value : fallback
  puts "  #{label.to_s.ljust(12)} #{formatted}"
end

# Parses user input like "1,3,5-10" into an array of zero-based indices.
# Out-of-range values are silently ignored.
def parse_selection(input, max)
  indices = []
  input.split(',').each do |part|
    part = part.strip
    if part.include?('-')
      bounds = part.split('-', 2).map(&:strip).map(&:to_i)
      next if bounds.any?(&:zero?) && !part.match?(/\b0\b/) # skip non-numeric
      lo, hi = bounds.sort
      (lo..hi).each { |n| indices << (n - 1) }
    else
      n = part.to_i
      next if n.zero? && part != '0'
      indices << (n - 1)
    end
  end
  indices.uniq.select { |i| i >= 0 && i < max }.sort
end

namespace :gutenberg do
  desc 'Import a Gutenberg source by book ID (fetches metadata from Gutendex API). ' \
       'Optional env vars: YEAR, STRATEGY, COUNTRY, CITY'
  task :import, [:book_id] => :environment do |_t, args|
    abort <<~USAGE unless args[:book_id]
      Usage: rails "gutenberg:import[book_id]"   (quote for zsh)
      Optional env vars: YEAR, STRATEGY, COUNTRY, CITY
      Example: YEAR=1852 STRATEGY=francatelli COUNTRY="Great Britain" rails "gutenberg:import[22114]"
    USAGE

    puts "Fetching metadata for Gutenberg book ##{args[:book_id]}..."
    metadata = Gutenberg::MetadataService.call(args[:book_id])

    source = Source.find_or_initialize_by(
      provider: metadata[:provider],
      external_id: metadata[:external_id]
    )

    is_new = source.new_record?

    source.assign_attributes(
      title: metadata[:title],
      author: metadata[:author],
      source_url: metadata[:source_url],
      image_url: metadata[:image_url],
      language: metadata[:language]
    )

    # Optional manual fields (only override if provided)
    source.publication_year = ENV['YEAR'].to_i if ENV['YEAR'].present?
    source.split_strategy = ENV['STRATEGY'] if ENV['STRATEGY'].present?
    source.region_country = ENV['COUNTRY'] if ENV['COUNTRY'].present?
    source.region_city = ENV['CITY'] if ENV['CITY'].present?

    puts
    puts is_new ? "New source to create:" : "Existing source to update (id: #{source.id}):"
    puts '-' * 50
    log_info 'Title',    source.title
    log_info 'Author',   source.author
    log_info 'URL',      source.source_url
    log_info 'Language', source.language
    log_info 'Year',     source.publication_year
    log_info 'Strategy', source.split_strategy
    log_info 'Country',  source.region_country
    log_info 'City',     source.region_city
    puts '-' * 50

    if source.changed?
      puts "Changed fields: #{source.changes.keys.join(', ')}" unless is_new
      confirm!("Save this source?")
    else
      puts "No changes detected — source is already up to date."
    end

    source.save!

    puts "Source saved. [id: #{source.id}, external_id: #{source.external_id}]"

    # Auto-generate splitter strategy file for new sources with an author
    if is_new && source.author.present?
      slug = generate_gutenberg_strategy(
        author: source.author,
        title: source.title,
        book_id: source.external_id,
        year: source.publication_year,
        url: source.source_url
      )
      if slug && source.split_strategy.blank?
        source.update!(split_strategy: slug)
        puts "  Set source.split_strategy = '#{slug}'"
      end
    end
  end

  # ---------------------------------------------------------------------------

  desc 'Fetch (download and cache) a book HTML for a source'
  task :fetch, [:source_id] => :environment do |_t, args|
    abort 'Usage: rails "gutenberg:fetch[source_id]"' unless args[:source_id]

    source = Source.find(args[:source_id])
    puts "Fetching: \"#{source.title}\" (external_id: #{source.external_id})"

    cache_path = Rails.root.join("data/gutenberg/#{source.external_id}.html")
    if File.exist?(cache_path)
      puts "  Cache already exists at: #{cache_path}"
      puts "  Use gutenberg:refetch to force re-download."
      return
    end

    path = Gutenberg::FetchBookService.call(source: source)
    size_kb = (File.size(path) / 1024.0).round(1)
    puts "Done. Cached at: #{path} (#{size_kb} KB)"
  end

  desc 'Force re-fetch a book HTML'
  task :refetch, [:source_id] => :environment do |_t, args|
    abort 'Usage: rails "gutenberg:refetch[source_id]"' unless args[:source_id]

    source = Source.find(args[:source_id])
    puts "Re-fetching: \"#{source.title}\" (external_id: #{source.external_id})"
    confirm!("This will overwrite the cached HTML. Proceed?")

    path = Gutenberg::FetchBookService.call(source: source, force: true)
    size_kb = (File.size(path) / 1024.0).round(1)
    puts "Done. Cached at: #{path} (#{size_kb} KB)"
  end

  # ---------------------------------------------------------------------------

  desc 'Split a cached book into recipe chunks (dry run — shows chunks, does not extract)'
  task :split, [:source_id, :strategy] => :environment do |_t, args|
    abort 'Usage: rails "gutenberg:split[source_id]" or "gutenberg:split[source_id,strategy]"' unless args[:source_id]

    source = Source.find(args[:source_id])
    strategy = args[:strategy].presence || source.split_strategy.presence
    if strategy.blank?
      abort "No split strategy. Either pass it: rails \"gutenberg:split[#{args[:source_id]},francatelli]\" " \
            "or set on source (e.g. at import with STRATEGY=francatelli). Available: #{Gutenberg::Splitters::Registry.list.join(', ')}"
    end

    puts "Splitting: \"#{source.title}\" (external_id: #{source.external_id})"
    puts "Strategy:  #{strategy}"
    puts '-' * 60

    chunks = Gutenberg::SplitBookService.call(source: source, strategy: strategy)

    chunks.each_with_index do |chunk, idx|
      text = chunk[:text]
      header = chunk[:section_header]
      rno = chunk[:recipe_number]
      title = text.lines.first&.strip&.truncate(80) || '(untitled)'
      prefix = header ? "[#{header}] " : ""
      rno_label = rno ? " ##{rno}" : ""
      puts "[#{idx + 1}] #{prefix}#{title}#{rno_label}"
      puts "    #{text.truncate(140)}"
      puts
    end

    puts '-' * 60
    puts "Total chunks: #{chunks.size}"
    puts "(Dry run — no recipes were extracted. Use gutenberg:process to extract.)"
  end

  # ---------------------------------------------------------------------------

  desc 'List available split strategies'
  task strategies: :environment do
    Dir[Rails.root.join('app/services/gutenberg/splitters/*_strategy.rb')].each { |f| require f }

    strategies = Gutenberg::Splitters::Registry.list
    if strategies.empty?
      puts 'No strategies registered.'
    else
      puts "Available split strategies:"
      strategies.each { |name| puts "  - #{name}" }
    end
  end

  # ---------------------------------------------------------------------------

  desc 'Full pipeline: fetch + split + extract for a source'
  task :process, [:source_id, :strategy, :limit] => :environment do |_t, args|
    abort 'Usage: rails "gutenberg:process[source_id]" or "gutenberg:process[source_id,strategy,limit]"' unless args[:source_id]

    source = Source.find(args[:source_id])
    strategy = args[:strategy].presence || source.split_strategy.presence
    if strategy.blank?
      abort "No split strategy. Either pass it: rails \"gutenberg:process[#{args[:source_id]},francatelli]\" " \
            "or set on source (e.g. at import with STRATEGY=francatelli). Available: #{Gutenberg::Splitters::Registry.list.join(', ')}"
    end
    limit = args[:limit]&.to_i

    existing_count = source.recipes.count

    puts '=' * 60
    puts "Process: \"#{source.title}\""
    puts '=' * 60
    log_info 'Source ID',    source.id
    log_info 'External ID',  source.external_id
    log_info 'Strategy',     strategy
    log_info 'Limit',        limit || 'all'
    log_info 'Existing',     "#{existing_count} recipes already extracted"
    puts

    # Step 1: Fetch
    log_step 1, 3, 'Fetching book HTML...'
    path = Gutenberg::FetchBookService.call(source: source)
    size_kb = (File.size(path) / 1024.0).round(1)
    puts "  Cached at: #{path} (#{size_kb} KB)"

    # Step 2: Split
    log_step 2, 3, 'Splitting into recipe chunks...'
    chunks = Gutenberg::SplitBookService.call(source: source, strategy: strategy)
    puts "  Found #{chunks.size} chunks"

    chunks = chunks.first(limit) if limit
    puts "  Will process: #{chunks.size} chunks#{limit ? " (limited to #{limit})" : ''}"
    puts

    # List all chunks for selection
    puts "  Available recipes:"
    puts "  #{'-' * 56}"
    chunks.each_with_index do |chunk, idx|
      title = chunk[:text].lines.first&.strip&.truncate(60) || '(untitled)'
      header = chunk[:section_header]
      rno = chunk[:recipe_number]
      prefix = header ? " [#{header.truncate(20)}]" : ""
      rno_label = rno ? " ##{rno}" : ""
      puts "    [#{(idx + 1).to_s.rjust(3)}] #{title}#{rno_label}#{prefix}"
    end
    puts "  #{'-' * 56}"
    puts

    # Interactive selection
    puts "  Enter recipe numbers to process (comma-separated, ranges with dashes),"
    puts "  or 'all' to process everything. Example: 1,3,5-10"
    print "  Selection: "
    input = $stdin.gets&.strip&.downcase

    abort "Cancelled." if input.blank?

    if input == 'all'
      selected_indices = (0...chunks.size).to_a
    else
      selected_indices = parse_selection(input, chunks.size)
      abort "No valid selections. Aborting." if selected_indices.empty?
    end

    selected_chunks = selected_indices.map { |i| chunks[i] }
    puts
    puts "  Selected #{selected_chunks.size} recipe(s):"
    selected_chunks.each_with_index do |chunk, i|
      title = chunk[:text].lines.first&.strip&.truncate(60) || '(untitled)'
      header = chunk[:section_header]
      rno = chunk[:recipe_number]
      header_label = header ? " → #{header}" : ""
      rno_label = rno ? " ##{rno}" : ""
      puts "    [#{(selected_indices[i] + 1).to_s.rjust(3)}] #{title}#{rno_label}#{header_label}"
    end

    # Section header prompt
    puts
    detected_any = selected_chunks.any? { |c| c[:section_header].present? }
    if detected_any
      puts "  Section headers were detected from the book structure (shown above with →)."
      puts "  Press Enter to keep detected headers, or type a value to override ALL:"
    else
      puts "  No section headers detected. Enter a section header for all selected"
      puts "  recipes, or press Enter to leave blank:"
    end
    print "  Section header: "
    header_input = $stdin.gets&.strip

    # Apply: if user typed something, override all; otherwise keep per-chunk headers
    if header_input.present?
      selected_chunks.each { |c| c[:section_header] = header_input }
    end

    puts
    confirm!("Send #{selected_chunks.size} chunk(s) to LLM for extraction?")

    # Step 3: Extract
    log_step 3, 3, "Extracting #{selected_chunks.size} recipes via LLM..."

    success = 0
    failed = 0
    skipped = 0

    selected_chunks.each_with_index do |chunk, idx|
      text = chunk[:text]
      section_header = chunk[:section_header]
      page_number = chunk[:page_number]
      recipe_number = chunk[:recipe_number]
      preview = text.lines.first&.strip&.truncate(50) || '(untitled)'
      rno_label = recipe_number ? " ##{recipe_number}" : ""
      progress = "[#{idx + 1}/#{selected_chunks.size}]"

      if text.blank?
        skipped += 1
        puts "#{progress} SKIP (empty chunk)"
        next
      end

      print "#{progress} #{preview}#{rno_label}... "

      begin
        recipe = Extraction::CreateRecipeService.call(
          source: source,
          text: text,
          input_type: 'text',
          raw_section_header: section_header,
          page_number: page_number,
          recipe_number: recipe_number,
          historical: true
        )

        if recipe.extraction_status == 'success'
          success += 1
          ing_count = recipe.ingredients.count
          puts "OK (#{ing_count} ingredient#{ing_count == 1 ? '' : 's'})"
        else
          failed += 1
          puts "FAILED: #{recipe.error_message.to_s.truncate(80)}"
        end
      rescue StandardError => e
        failed += 1
        puts "ERROR: #{e.message.truncate(80)}"
      end

      # Small delay between LLM calls to avoid rate limits
      sleep(0.5)
    end

    # Resolve recipe cross-references
    puts "\nResolving recipe cross-references..."
    resolved = Extraction::ResolveRecipeReferencesService.call(source: source)
    puts "  Resolved #{resolved} ingredient → recipe reference#{'s' unless resolved == 1}"

    # Summary
    puts
    puts '=' * 60
    puts 'Summary'
    puts '=' * 60
    log_info 'Source',    "\"#{source.title}\""
    log_info 'Success',   success
    log_info 'Failed',    failed
    log_info 'Skipped',   skipped
    log_info 'Refs',      "#{resolved} cross-references resolved"
    log_info 'Total',     "#{success + failed + skipped} / #{selected_chunks.size} chunks"
    log_info 'All time',  "#{source.recipes.count} recipes for this source"
    puts '=' * 60
  end

  # ---------------------------------------------------------------------------

  desc 'Import + process in one command. Requires STRATEGY. Optional: YEAR, COUNTRY, CITY, LIMIT'
  task :run, [:book_id] => :environment do |_t, args|
    abort <<~USAGE unless args[:book_id]
      Usage: rails "gutenberg:run[book_id]"   (quote for zsh)
      Requires: STRATEGY (e.g. francatelli). Optional: YEAR, COUNTRY, CITY, LIMIT
      Example: STRATEGY=francatelli rails "gutenberg:run[22114]"
      Example: STRATEGY=elizaacton YEAR=1852 LIMIT=3 rails "gutenberg:run[22114]"
    USAGE

    strategy = ENV['STRATEGY'].presence
    abort 'Error: STRATEGY env var is required (e.g. STRATEGY=francatelli). Available: ' \
          "#{Gutenberg::Splitters::Registry.list.join(', ')}" if strategy.blank?

    puts '=' * 60
    puts "Gutenberg Pipeline: book ##{args[:book_id]}"
    puts '=' * 60
    puts

    # Step 0: Import (fetches metadata from Gutendex)
    log_step 0, 3, 'Importing source metadata...'
    Rake::Task['gutenberg:import'].invoke(args[:book_id])
    puts

    source = Source.find_by!(provider: 'gutenberg', external_id: args[:book_id].to_s)

    # Persist strategy on source so next time you can run gutenberg:process[source_id] without passing strategy
    source.update!(split_strategy: strategy) if source.split_strategy != strategy

    # Delegate to process
    Rake::Task['gutenberg:process'].invoke(source.id, strategy, ENV['LIMIT'])
  end
end

# ---------------------------------------------------------------------------
# Helper: generate a Gutenberg splitter strategy file from author metadata.
# Called automatically during gutenberg:import for new sources.
# ---------------------------------------------------------------------------
def generate_gutenberg_strategy(author:, title: nil, book_id: nil, year: nil, url: nil)
  slug = author.gsub(/[^A-Za-z]/, '').downcase
  class_name = "#{slug.capitalize}Strategy"
  file_name = "#{slug}_strategy.rb"
  file_path = Rails.root.join("app/services/gutenberg/splitters/#{file_name}")

  if File.exist?(file_path)
    puts "\n  Strategy file already exists: #{file_name} (skipped generation)"
    return slug
  end

  title ||= '(Book title here)'
  book_id ||= '(Gutenberg ID)'
  year ||= '(year)'
  url ||= "https://www.gutenberg.org/files/#{book_id}/#{book_id}-h/#{book_id}-h.htm"

  template = <<~RUBY
    # frozen_string_literal: true

    # Split strategy for:
    #   "#{title}" by #{author} (#{year})
    #   Gutenberg ID: #{book_id}
    #   URL: #{url}
    #
    # HOW TO REFINE THIS STRATEGY:
    #   1. Fetch the HTML:  rails "gutenberg:fetch[SOURCE_ID]"
    #   2. Open data/gutenberg/#{book_id}.htm and inspect the HTML structure
    #   3. Identify recipe title elements (update the CSS selector / regex below)
    #   4. Dry-run:  rails "gutenberg:split[SOURCE_ID,#{slug}]"
    #   5. Iterate until the chunks look right
    #
    module Gutenberg
      module Splitters
        class #{class_name} < Base
          # Recipe title pattern — adjust after inspecting the HTML.
          # Common patterns: <h3>, <h4>, <p class="...">, <i> tags for titles.
          TITLE_SELECTOR = 'h3'
          TITLE_PATTERN  = /./  # match all; refine to filter real recipe titles

          def call(html)
            doc = parse(html)
            chunks = []

            title_nodes = doc.css(TITLE_SELECTOR).select { |node| node.text.strip.match?(TITLE_PATTERN) }

            title_nodes.each_with_index do |title_node, idx|
              next_title_node = title_nodes[idx + 1]

              title = extract_text(title_node)
              body = collect_text_between(title_node, next_title_node)

              next if body.blank?

              chunks << {
                text: "\#{title}\\n\\n\#{body}",
                section_header: nil,
                page_number: find_page_number(title_node)
              }
            end

            chunks
          end
        end

        Registry.register('#{slug}', #{class_name})
      end
    end
  RUBY

  File.write(file_path, template)

  puts "\n  Generated strategy file: #{file_name}"
  puts "  Strategy name: #{slug}"
  puts "  Class: Gutenberg::Splitters::#{class_name}"

  slug
end
