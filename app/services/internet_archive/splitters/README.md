# Internet Archive split strategies

Splitters turn a book's cached OCR text into an array of recipe text chunks (title + body per chunk). Each book format needs a strategy; there is no single universal rule.

Unlike Gutenberg strategies (which parse HTML with Nokogiri), IA strategies work with **plain text** from the Internet Archive's OCR output (`_djvu.txt` files).

---

## Order of operations

Split (and process) need **cached OCR text** first:

1. **Import** the source (creates/updates the `Source` record):

   ```bash
   TITLE="The Experienced English Housekeeper" AUTHOR="Elizabeth Raffald" YEAR=1784 STRATEGY=raffald COUNTRY="Great Britain" \
     rails "ia:import[bim_eighteenth-century_the-experienced-english-_raffald-elizabeth_1784]"
   ```

   Note the **source id** (UUID) printed at the end.

2. **Fetch** the OCR text (downloads and caches by `external_id`):

   ```bash
   rails "ia:fetch[<source_id>]"
   ```

3. **Inspect** the cached text to understand recipe structure:

   ```bash
   # The text is cached at:
   # data/internet_archive/<identifier>.txt
   ```

4. **Split** (dry run) or **Process** (split + extract):
   ```bash
   rails "ia:split[<source_id>,raffald]"
   rails "ia:process[<source_id>,raffald]"
   ```

Or run import + process in one go:

```bash
STRATEGY=raffald TITLE="The Experienced English Housekeeper" YEAR=1784 \
  rails "ia:run[bim_eighteenth-century_the-experienced-english-_raffald-elizabeth_1784]"
```

---

## Setting the split strategy

- **At import time** (and stored on the source):

  ```bash
  STRATEGY=raffald rails "ia:import[...]"
  ```

- **On an existing source** (Rails console):

  ```ruby
  source = Source.find_by(provider: 'internet_archive', external_id: '...')
  source.update!(split_strategy: 'raffald')
  ```

- **Per command** (overrides `source.split_strategy`):
  ```bash
  rails "ia:split[<source_id>,raffald]"
  rails "ia:process[<source_id>,raffald]"
  ```

List registered strategies:

```bash
rails ia:strategies
```

---

## Defining a new split strategy

1. **Add a new file** in `app/services/internet_archive/splitters/` named `*_strategy.rb`.

2. **Subclass `InternetArchive::Splitters::Base`** and implement `#call(text)` returning an `Array<Hash>`.

   Each hash must have:
   - `:text` — the recipe text chunk (title + body as a single string)
   - `:section_header` — the book section (e.g. chapter name), or nil
   - `:page_number` — original page number, or nil

3. **Register** the strategy:

   ```ruby
   # app/services/internet_archive/splitters/newbook_strategy.rb
   module InternetArchive
     module Splitters
       class NewbookStrategy < Base
         RECIPE_TITLE = /\A\s*To\s+/i

         def call(text)
           text_lines = lines(text)
           chunks = []
           title_indices = find_boundaries(text_lines, RECIPE_TITLE)

           title_indices.each_with_index do |title_idx, i|
             next_title_idx = title_indices[i + 1]
             chunk_text = collect_chunk(text_lines, title_idx, next_title_idx)
             next if chunk_text.blank?

             chunks << {
               text: clean_ocr_text(chunk_text),
               section_header: nil,
               page_number: find_page_number(text_lines, title_idx)
             }
           end

           chunks
         end
       end

       Registry.register('newbook', NewbookStrategy)
     end
   end
   ```

4. **Helpers from Base**:
   - `lines(text)` — split text into array of lines
   - `find_boundaries(lines, pattern)` — find line indices matching a regex
   - `collect_text_between(lines, start, end)` — text between boundaries (exclusive)
   - `collect_chunk(lines, start, end)` — text between boundaries (inclusive of start)
   - `all_caps_line?(line)` — detect ALL-CAPS headings
   - `numbered_entry?(line)` — detect numbered entries
   - `blank_line_split(text)` — split on blank lines
   - `find_page_number(lines, idx)` — search backwards for page markers
   - `clean_ocr_text(text)` — normalize whitespace and line endings

5. Run `rails ia:strategies` to confirm, then use it in import/split/process.

---

## Working with 18th-century OCR

Common issues in microfilm-scanned 18th-century books:

- **Long-s (ſ)** may appear as 'f' (e.g. "foup" → "soup", "roaft" → "roast")
- **Ligatures** (fi, fl, ff) may be split or merged unpredictably
- **Inconsistent spacing** from variable microfilm quality
- **Page markers** may appear as standalone numbers or bracketed numbers

The Flask LLM extractor handles these artifacts well, so normalization in the
strategy is usually unnecessary. Focus the strategy on finding recipe boundaries.
