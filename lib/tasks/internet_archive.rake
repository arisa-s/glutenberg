# frozen_string_literal: true

# Rake tasks for the Internet Archive image-based extraction pipeline.
#
# The pipeline downloads page images from IA's IIIF API and uses a two-pass
# LLM approach (boundary detection, then targeted extraction), bypassing IA's
# OCR entirely.
#
# Pass 1: Batch page images (~20/batch) → Gemini identifies recipe titles + leaf ranges
# Pass 2: Send exact pages for each recipe → full structured extraction

namespace :ia do
  desc 'Import an Internet Archive source by identifier. ' \
       'Fetches metadata from IA API. Required env: TITLE (if IA metadata unavailable). ' \
       'Optional env: AUTHOR, YEAR, COUNTRY, CITY, LANGUAGE'
  task :import, [:identifier] => :environment do |_t, args|
    abort <<~USAGE unless args[:identifier]
      Usage: rails "ia:import[identifier]"   (quote for zsh)
      Required env: TITLE (if IA metadata is unavailable)
      Optional env: AUTHOR, YEAR, COUNTRY, CITY, LANGUAGE
      Example: TITLE="The Experienced English Housekeeper" AUTHOR="Elizabeth Raffald" YEAR=1784 COUNTRY="Great Britain" rails "ia:import[bim_eighteenth-century_the-experienced-english-_raffald-elizabeth_1784]"
    USAGE

    identifier = args[:identifier]
    source_url = "https://archive.org/details/#{identifier}"

    puts "Importing Internet Archive item: #{identifier}"
    puts

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

    source.publication_year = ENV['YEAR'].to_i if ENV['YEAR'].present?
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
  end

  # ---------------------------------------------------------------------------

  desc 'Fetch page images only (no extraction). Use to cache images before processing.'
  task :fetch_images, [:source_id, :start_leaf, :end_leaf] => :environment do |_t, args|
    abort 'Usage: rails "ia:fetch_images[source_id]" or "ia:fetch_images[source_id,start_leaf,end_leaf]"' unless args[:source_id]

    source = Source.find(args[:source_id])
    start_leaf = args[:start_leaf]&.to_i
    end_leaf   = args[:end_leaf]&.to_i

    puts "Fetching page images: \"#{source.title}\" (external_id: #{source.external_id})"
    log_info 'Leaf range', start_leaf && end_leaf ? "#{start_leaf}–#{end_leaf}" : 'all'

    pages = InternetArchive::FetchPageImagesService.call(
      source: source,
      start_leaf: start_leaf,
      end_leaf: end_leaf
    )
    puts "Done. #{pages.size} page images cached."
  end

  # ---------------------------------------------------------------------------

  desc 'Image-based pipeline: fetch page images → LLM boundary detection → LLM extraction. ' \
       'No splitter strategy needed. Optional: start_leaf, end_leaf to scope to recipe pages.'
  task :process_images, [:source_id, :start_leaf, :end_leaf] => :environment do |_t, args|
    abort 'Usage: rails "ia:process_images[source_id]" or "ia:process_images[source_id,start_leaf,end_leaf]"' unless args[:source_id]

    source = Source.find(args[:source_id])
    start_leaf = args[:start_leaf]&.to_i
    end_leaf   = args[:end_leaf]&.to_i

    existing_count = source.recipes.count

    puts '=' * 60
    puts "Image Pipeline (IA): \"#{source.title}\""
    puts '=' * 60
    log_info 'Source ID',    source.id
    log_info 'External ID',  source.external_id
    log_info 'Leaf range',   start_leaf && end_leaf ? "#{start_leaf}–#{end_leaf}" : 'all'
    log_info 'Existing',     "#{existing_count} recipes already extracted"
    puts

    # Step 1: Fetch page images
    log_step 1, 3, 'Fetching page images from IA...'
    service = InternetArchive::ProcessImagesService.new(
      source: source,
      start_leaf: start_leaf,
      end_leaf: end_leaf
    )
    pages = service.fetch_images
    puts "  #{pages.size} page images ready"

    # Step 2: Boundary detection (Pass 1)
    log_step 2, 3, 'Detecting recipe boundaries (Pass 1)...'
    boundaries = service.detect_boundaries(pages)
    puts "  Found #{boundaries.size} recipes"
    puts

    if boundaries.empty?
      puts "No recipes found. Try adjusting the leaf range."
      next
    end

    # Display boundaries for selection
    puts "  Detected recipes:"
    puts "  #{'-' * 56}"
    boundaries.each_with_index do |b, idx|
      title = (b['title'] || '(untitled)').truncate(55)
      leaves = "leaves #{b['start_leaf']}–#{b['end_leaf'] || '?'}"
      puts "    [#{(idx + 1).to_s.rjust(3)}] #{title}  (#{leaves})"
    end
    puts "  #{'-' * 56}"
    puts

    # Interactive selection
    puts "  Enter recipe numbers to extract (comma-separated, ranges with dashes),"
    puts "  or 'all' to process everything. Example: 1,3,5-10"
    print "  Selection: "
    input = $stdin.gets&.strip&.downcase

    abort "Cancelled." if input.blank?

    if input == 'all'
      selected_indices = (0...boundaries.size).to_a
    else
      selected_indices = parse_selection(input, boundaries.size)
      abort "No valid selections. Aborting." if selected_indices.empty?
    end

    selected = selected_indices.map { |i| boundaries[i] }
    puts
    puts "  Selected #{selected.size} recipe(s):"
    selected.each_with_index do |b, i|
      title = (b['title'] || '(untitled)').truncate(55)
      puts "    [#{(selected_indices[i] + 1).to_s.rjust(3)}] #{title}"
    end

    # Section header prompt
    puts
    puts "  Enter a section header for all selected recipes, or press Enter to leave blank:"
    print "  Section header: "
    header_input = $stdin.gets&.strip
    section_header = header_input.presence

    puts
    confirm!("Send #{selected.size} recipe(s) to LLM for extraction (Pass 2)?")

    # Step 3: Extract (Pass 2)
    log_step 3, 3, "Extracting #{selected.size} recipes via LLM (Pass 2)..."

    extraction_service = InternetArchive::ProcessImagesService.new(
      source: source,
      start_leaf: start_leaf,
      end_leaf: end_leaf,
      selected_indices: selected_indices,
      section_header: section_header
    )
    recipes = extraction_service.extract_recipes(selected, pages)

    # Resolve recipe cross-references
    puts "\nResolving recipe cross-references..."
    resolved = Extraction::ResolveRecipeReferencesService.call(source: source)
    puts "  Resolved #{resolved} ingredient → recipe reference#{'s' unless resolved == 1}"

    # Summary
    success_count = recipes.count { |r| r.extraction_status == 'success' }
    failed_count  = recipes.count { |r| r.extraction_status == 'failed' }
    puts
    puts '=' * 60
    puts 'Summary'
    puts '=' * 60
    log_info 'Source',    "\"#{source.title}\""
    log_info 'Boundaries', "#{boundaries.size} detected (Pass 1)"
    log_info 'Selected',  selected.size
    log_info 'Success',   success_count
    log_info 'Failed',    failed_count
    log_info 'Refs',      "#{resolved} cross-references resolved"
    log_info 'All time',  "#{source.recipes.count} recipes for this source"
    puts '=' * 60
  end

  # ---------------------------------------------------------------------------

  desc 'Import + process_images in one command. ' \
       'Optional env: TITLE, AUTHOR, YEAR, COUNTRY, CITY, LANGUAGE, START_LEAF, END_LEAF'
  task :run, [:identifier] => :environment do |_t, args|
    abort <<~USAGE unless args[:identifier]
      Usage: rails "ia:run[identifier]"   (quote for zsh)
      Optional env: TITLE, AUTHOR, YEAR, COUNTRY, CITY, LANGUAGE, START_LEAF, END_LEAF
      Example: TITLE="The Experienced English Housekeeper" YEAR=1784 START_LEAF=50 END_LEAF=400 rails "ia:run[identifier]"
    USAGE

    puts '=' * 60
    puts "IA Pipeline: #{args[:identifier]}"
    puts '=' * 60
    puts

    log_step 0, 3, 'Importing source metadata...'
    Rake::Task['ia:import'].invoke(args[:identifier])
    puts

    source = Source.find_by!(provider: 'internet_archive', external_id: args[:identifier])

    start_leaf = ENV['START_LEAF']&.to_i
    end_leaf   = ENV['END_LEAF']&.to_i

    Rake::Task['ia:process_images'].invoke(source.id, start_leaf, end_leaf)
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

  title = metadata['title']
  title = title.first if title.is_a?(Array)

  author = metadata['creator']
  author = author.first if author.is_a?(Array)

  language = metadata['language']
  language = language.first if language.is_a?(Array)
  language = 'en' if language&.match?(/\Aen/i)

  {
    title: title,
    author: author,
    language: language
  }
end
