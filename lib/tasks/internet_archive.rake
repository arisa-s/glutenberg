# frozen_string_literal: true

# Rake tasks for the Internet Archive pipeline.
# Mirrors the Gutenberg pipeline but works with OCR plain text instead of HTML.
#
# Key differences from Gutenberg tasks:
#   - ia:import fetches metadata from the IA metadata API (not Gutendex)
#   - ia:fetch downloads OCR text (not HTML)
#   - Splitter strategies work with plain text (not Nokogiri/HTML)
#
# The extraction step is identical — both pipelines feed text chunks into
# Extraction::CreateRecipeService, which calls the LLM directly via OpenRouter.

namespace :ia do
  desc 'Import an Internet Archive source by identifier. ' \
       'Fetches metadata from IA API. Required env: TITLE (if IA metadata unavailable). ' \
       'Optional env: AUTHOR, YEAR, STRATEGY, COUNTRY, CITY, LANGUAGE'
  task :import, [:identifier] => :environment do |_t, args|
    abort <<~USAGE unless args[:identifier]
      Usage: rails "ia:import[identifier]"   (quote for zsh)
      Required env: TITLE (if IA metadata is unavailable)
      Optional env: AUTHOR, YEAR, STRATEGY, COUNTRY, CITY, LANGUAGE
      Example: TITLE="The Experienced English Housekeeper" AUTHOR="Elizabeth Raffald" YEAR=1784 STRATEGY=raffald COUNTRY="Great Britain" rails "ia:import[bim_eighteenth-century_the-experienced-english-_raffald-elizabeth_1784]"
    USAGE

    identifier = args[:identifier]
    source_url = "https://archive.org/details/#{identifier}"

    puts "Importing Internet Archive item: #{identifier}"
    puts

    # Try to fetch metadata from IA API
    title = ENV['TITLE']
    author = ENV['AUTHOR']
    language = ENV.fetch('LANGUAGE', 'en')

    if title.blank?
      puts "  Attempting to fetch metadata from IA API..."
      begin
        metadata = fetch_ia_metadata(identifier)
        title = metadata[:title] if title.blank?
        author = metadata[:author] if author.blank?
        language = metadata[:language] if metadata[:language].present?
        puts "  Fetched: \"#{title}\" by #{author || '(unknown)'}"
      rescue StandardError => e
        puts "  Could not fetch IA metadata: #{e.message}"
        abort "Error: TITLE env var is required when IA metadata is unavailable. " \
              "Example: TITLE=\"The Experienced English Housekeeper\" rails \"ia:import[#{identifier}]\""
      end
    end

    source = Source.find_or_initialize_by(
      provider: 'internet_archive',
      external_id: identifier
    )

    is_new = source.new_record?

    source.assign_attributes(
      title: title,
      author: author,
      source_url: source_url,
      language: language
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
      generate_ia_strategy(
        author: source.author,
        title: source.title,
        identifier: source.external_id,
        year: source.publication_year
      )
    end
  end

  # ---------------------------------------------------------------------------

  desc 'Fetch (download and cache) OCR text for an Internet Archive source'
  task :fetch, [:source_id] => :environment do |_t, args|
    abort 'Usage: rails "ia:fetch[source_id]"' unless args[:source_id]

    source = Source.find(args[:source_id])
    puts "Fetching: \"#{source.title}\" (external_id: #{source.external_id})"

    cache_path = InternetArchive::FetchBookService::CACHE_DIR.join("#{source.external_id}.txt")
    if File.exist?(cache_path)
      size_kb = (File.size(cache_path) / 1024.0).round(1)
      puts "  Cache already exists at: #{cache_path} (#{size_kb} KB)"
      puts "  Use ia:refetch to force re-download."
      return
    end

    path = InternetArchive::FetchBookService.call(source: source)
    size_kb = (File.size(path) / 1024.0).round(1)
    puts "Done. Cached at: #{path} (#{size_kb} KB)"
  end

  desc 'Force re-fetch OCR text for an Internet Archive source'
  task :refetch, [:source_id] => :environment do |_t, args|
    abort 'Usage: rails "ia:refetch[source_id]"' unless args[:source_id]

    source = Source.find(args[:source_id])
    puts "Re-fetching: \"#{source.title}\" (external_id: #{source.external_id})"
    confirm!("This will overwrite the cached text. Proceed?")

    path = InternetArchive::FetchBookService.call(source: source, force: true)
    size_kb = (File.size(path) / 1024.0).round(1)
    puts "Done. Cached at: #{path} (#{size_kb} KB)"
  end

  # ---------------------------------------------------------------------------

  desc 'Split cached OCR text into recipe chunks (dry run — shows chunks, does not extract)'
  task :split, [:source_id, :strategy] => :environment do |_t, args|
    abort 'Usage: rails "ia:split[source_id]" or "ia:split[source_id,strategy]"' unless args[:source_id]

    source = Source.find(args[:source_id])
    strategy = args[:strategy].presence || source.split_strategy.presence
    if strategy.blank?
      abort "No split strategy. Either pass it: rails \"ia:split[#{args[:source_id]},raffald]\" " \
            "or set on source (e.g. at import with STRATEGY=raffald). Available: #{InternetArchive::Splitters::Registry.list.join(', ')}"
    end

    puts "Splitting: \"#{source.title}\" (external_id: #{source.external_id})"
    puts "Strategy:  #{strategy}"
    puts '-' * 60

    chunks = InternetArchive::SplitBookService.call(source: source, strategy: strategy)

    chunks.each_with_index do |chunk, idx|
      text = chunk[:text]
      header = chunk[:section_header]
      page = chunk[:page_number]
      rno = chunk[:recipe_number]
      title = text.lines.first&.strip&.truncate(80) || '(untitled)'
      prefix = header ? "[#{header}] " : ""
      page_label = page ? " (p. #{page})" : ""
      rno_label = rno ? " ##{rno}" : ""
      puts "[#{idx + 1}] #{prefix}#{title}#{rno_label}#{page_label}"
      puts "    #{text.truncate(140)}"
      puts
    end

    puts '-' * 60
    puts "Total chunks: #{chunks.size}"
    puts "(Dry run — no recipes were extracted. Use ia:process to extract.)"
  end

  # ---------------------------------------------------------------------------

  desc 'List available Internet Archive split strategies'
  task strategies: :environment do
    strategies = InternetArchive::Splitters::Registry.list
    if strategies.empty?
      puts 'No IA strategies registered.'
      puts 'Add strategy files to app/services/internet_archive/splitters/*_strategy.rb'
    else
      puts "Available IA split strategies:"
      strategies.each { |name| puts "  - #{name}" }
    end
  end

  # ---------------------------------------------------------------------------

  desc 'Full pipeline: fetch + split + extract for an Internet Archive source'
  task :process, [:source_id, :strategy, :limit] => :environment do |_t, args|
    abort 'Usage: rails "ia:process[source_id]" or "ia:process[source_id,strategy,limit]"' unless args[:source_id]

    source = Source.find(args[:source_id])
    strategy = args[:strategy].presence || source.split_strategy.presence
    if strategy.blank?
      abort "No split strategy. Either pass it: rails \"ia:process[#{args[:source_id]},raffald]\" " \
            "or set on source (e.g. at import with STRATEGY=raffald). Available: #{InternetArchive::Splitters::Registry.list.join(', ')}"
    end
    limit = args[:limit]&.to_i

    existing_count = source.recipes.count

    puts '=' * 60
    puts "Process (IA): \"#{source.title}\""
    puts '=' * 60
    log_info 'Source ID',    source.id
    log_info 'External ID',  source.external_id
    log_info 'Strategy',     strategy
    log_info 'Limit',        limit || 'all'
    log_info 'Existing',     "#{existing_count} recipes already extracted"
    puts

    # Step 1: Fetch
    log_step 1, 3, 'Fetching OCR text...'
    path = InternetArchive::FetchBookService.call(source: source)
    size_kb = (File.size(path) / 1024.0).round(1)
    puts "  Cached at: #{path} (#{size_kb} KB)"

    # Step 2: Split
    log_step 2, 3, 'Splitting into recipe chunks...'
    chunks = InternetArchive::SplitBookService.call(source: source, strategy: strategy)
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

  desc 'Import + process in one command. Requires: TITLE (or IA metadata), STRATEGY. ' \
       'Optional: AUTHOR, YEAR, COUNTRY, CITY, LANGUAGE, LIMIT'
  task :run, [:identifier] => :environment do |_t, args|
    abort <<~USAGE unless args[:identifier]
      Usage: rails "ia:run[identifier]"   (quote for zsh)
      Requires: STRATEGY. Optional: TITLE, AUTHOR, YEAR, COUNTRY, CITY, LANGUAGE, LIMIT
      Example: STRATEGY=raffald TITLE="The Experienced English Housekeeper" YEAR=1784 rails "ia:run[bim_eighteenth-century_the-experienced-english-_raffald-elizabeth_1784]"
    USAGE

    strategy = ENV['STRATEGY'].presence
    abort 'Error: STRATEGY env var is required (e.g. STRATEGY=raffald). Available: ' \
          "#{InternetArchive::Splitters::Registry.list.join(', ')}" if strategy.blank?

    puts '=' * 60
    puts "IA Pipeline: #{args[:identifier]}"
    puts '=' * 60
    puts

    # Step 0: Import
    log_step 0, 3, 'Importing source metadata...'
    Rake::Task['ia:import'].invoke(args[:identifier])
    puts

    source = Source.find_by!(provider: 'internet_archive', external_id: args[:identifier])

    # Persist strategy on source
    source.update!(split_strategy: strategy) if source.split_strategy != strategy

    # Delegate to process
    Rake::Task['ia:process'].invoke(source.id, strategy, ENV['LIMIT'])
  end
end

# ---------------------------------------------------------------------------
# Helper: fetch metadata from the IA metadata API
# ---------------------------------------------------------------------------
def fetch_ia_metadata(identifier)
  require 'net/http'
  require 'json'

  uri = URI("https://archive.org/metadata/#{identifier}")
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  http.ca_file = ENV.fetch('SSL_CERT_FILE', '/etc/ssl/cert.pem')
  http.open_timeout = 15
  http.read_timeout = 30

  request = Net::HTTP::Get.new(uri)
  request['User-Agent'] = 'ProjectGlutenberg/1.0 (research thesis; contact: project-glutenberg@example.com)'

  response = http.request(request)
  raise "IA API returned HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

  data = JSON.parse(response.body)
  metadata = data['metadata'] || {}

  # IA metadata uses various fields for title and creator
  title = metadata['title']
  title = title.first if title.is_a?(Array)

  author = metadata['creator']
  author = author.first if author.is_a?(Array)

  language = metadata['language']
  language = language.first if language.is_a?(Array)
  # Normalize IA language codes (e.g. 'eng' -> 'en', 'enm' -> 'en')
  language = 'en' if language&.match?(/\Aen/i)

  {
    title: title,
    author: author,
    language: language
  }
end

# ---------------------------------------------------------------------------
# Helper: generate an IA splitter strategy file from author metadata.
# Called automatically during ia:import for new sources.
# ---------------------------------------------------------------------------
def generate_ia_strategy(author:, title: nil, identifier: nil, year: nil)
  slug = author.gsub(/[^A-Za-z]/, '').downcase
  class_name = "#{slug.capitalize}Strategy"
  file_name = "#{slug}_strategy.rb"
  file_path = Rails.root.join("app/services/internet_archive/splitters/#{file_name}")

  if File.exist?(file_path)
    puts "\n  Strategy file already exists: #{file_name} (skipped generation)"
    return
  end

  title ||= '(Book title here)'
  identifier ||= '(IA identifier here)'
  year ||= '(year)'

  template = <<~RUBY
    # frozen_string_literal: true

    # Split strategy for:
    #   "#{title}" by #{author} (#{year})
    #   Internet Archive ID: #{identifier}
    #   URL: https://archive.org/details/#{identifier}
    #
    # HOW TO REFINE THIS STRATEGY:
    #   1. Fetch the OCR text:  rails "ia:fetch[SOURCE_ID]"
    #   2. Open data/internet_archive/#{identifier}.txt
    #   3. Identify the actual recipe title pattern (update RECIPE_TITLE below)
    #   4. Identify chapter heading pattern (update CHAPTER_HEADING below)
    #   5. Dry-run:  rails "ia:split[SOURCE_ID,#{slug}]"
    #   6. Iterate until the chunks look right
    #
    module InternetArchive
      module Splitters
        class #{class_name} < Base
          # Chapter/section headings — adjust after inspecting OCR text.
          CHAPTER_HEADING = /\\A\\s*(?:CHAP(?:TER|\\.)\\s+[IVXLCDM]+\\.?|[A-Z][A-Z\\s,&]{4,})\\s*\\z/

          # Recipe title pattern — adjust after inspecting OCR text.
          RECIPE_TITLE = /\\A\\s*(?:To\\s+\\w+|A\\s+[A-Z]|\\d+\\.\\s*To\\s+)/i

          def call(text)
            text_lines = lines(text)
            chunks = []
            current_section = nil

            title_indices = find_boundaries(text_lines, RECIPE_TITLE)
            chapter_indices = find_boundaries(text_lines, CHAPTER_HEADING)

            title_indices.each_with_index do |title_idx, i|
              chapter_indices.each do |ch_idx|
                break if ch_idx >= title_idx
                current_section = text_lines[ch_idx].strip
              end

              next_title_idx = title_indices[i + 1]
              chunk_text = collect_chunk(text_lines, title_idx, next_title_idx)
              next if chunk_text.blank?

              page_number = find_page_number(text_lines, title_idx)

              chunks << {
                text: clean_ocr_text(chunk_text),
                section_header: current_section,
                page_number: page_number
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
  puts "  Class: InternetArchive::Splitters::#{class_name}"
end
