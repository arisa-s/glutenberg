# Project Glutenberg

A Rails application that extracts structured recipe data from historical cookbooks sourced from [Project Gutenberg](https://www.gutenberg.org/) and the [Internet Archive](https://archive.org/). Books are fetched, split into individual recipe chunks using per-book strategies, then sent through an LLM pipeline to produce structured titles, ingredients, instructions, and metadata. Extracted ingredients are enriched with USDA foundation food data.

## Stack

- **Ruby 3.3** / **Rails 7.1** / **PostgreSQL**
- **Gemini** (via [OpenRouter](https://openrouter.ai/)) for LLM extraction
- **Nokogiri** for HTML parsing (Gutenberg books)
- **Python 3** for USDA FDC ingredient enrichment (`ingredient-parser-nlp`)

## Setup

```bash
# Install Ruby dependencies
bundle install

# Install Python dependency (used by bin/fdc_lookup.py)
pip install -r requirements.txt

# Configure environment
cp .env.example .env
# Edit .env and add your OPENROUTER_API_KEY

# Create and set up the database
bin/rails db:create db:schema:load
```

## Data model

```
Source (cookbook)
├── provider        (gutenberg | internet_archive)
├── split_strategy  (per-book splitter name)
└── has_many Recipes
    ├── title, category, prep_time, cook_time, yield, ...
    ├── extraction_status  (success | failed)
    ├── input_text         (original text sent to LLM)
    ├── has_many IngredientGroups
    │   └── has_many Ingredients
    │       ├── product, quantity, unit, preparation
    │       ├── foundation_food_name, foundation_food_category  (USDA FDC)
    │       └── has_many Substitutions
    └── has_many InstructionGroups
        └── has_many Instructions
```

## Pipelines

### Gutenberg (HTML books)

```bash
# Full pipeline: import → fetch → split → extract
rails "gutenberg:run[BOOK_ID]"
# e.g. STRATEGY=francatelli YEAR=1852 rails "gutenberg:run[22114]"

# Or step by step:
rails "gutenberg:import[BOOK_ID]"          # fetch metadata from Gutendex API
rails "gutenberg:fetch[SOURCE_ID]"          # download and cache HTML
rails "gutenberg:split[SOURCE_ID]"          # dry-run: preview chunks
rails "gutenberg:process[SOURCE_ID]"        # split + extract via LLM
```

### Internet Archive (page images)

The IA pipeline downloads page images and uses Gemini to OCR + segment them by recipe, then feeds each recipe's text through the standard text extraction pipeline:

1. **OCR + Segment**: Batches page images (~20 per batch) and asks Gemini 2.5 Flash to read the text and segment by recipe. Returns each recipe's title, page metadata, and full OCR'd text.
2. **Text Extraction**: Each recipe's OCR'd text is fed through `ExtractRecipeFromText` (the same pipeline used for Gutenberg) for structured parsing with FDC enrichment.

```bash
rails "ia:import[IDENTIFIER]"                          # import from IA metadata API
rails "ia:fetch_images[SOURCE_ID]"                     # download page images only
rails "ia:fetch_images[SOURCE_ID,50,400]"              # download specific leaf range
rails "ia:process_images[SOURCE_ID]"                   # full image pipeline
rails "ia:process_images[SOURCE_ID,50,400]"            # scope to leaf range (skip preface/index)
```

No per-book splitter strategy is needed -- Gemini handles OCR and recipe segmentation directly from the page images.

### Extraction utilities

```bash
rails "extraction:resolve_refs[SOURCE_ID]"  # resolve recipe cross-references
rails "extraction:resolve_all_refs"          # resolve refs for all sources
```

## Split strategies (Gutenberg only)

Each Gutenberg book requires a custom splitter that understands its HTML structure. Strategies live in `app/services/gutenberg/splitters/` and use Nokogiri to parse HTML.

The Internet Archive pipeline does not need splitters -- Gemini handles OCR and segmentation directly from page images.

A new strategy file is auto-generated when importing a Gutenberg source. To list registered strategies:

```bash
rails gutenberg:strategies
```

## LLM services

All LLM interaction lives under `app/services/llm/`:

| Service | Purpose |
|---|---|
| `ExtractRecipeFromText` | Text → structured recipe via LLM |
| `SplitMultiRecipeText` | Split a text chunk containing multiple recipes |
| `OcrSegmentPages` | OCR + segment: read page images and split by recipe (returns text) |
| `FdcEnrichment` | Enrich ingredients with USDA foundation food data |
| `OpenRouterClient` | HTTP client for the OpenRouter API |
| `ResponseParser` | Robust JSON parser for LLM responses |

## Web UI

```bash
bin/rails server
```

Browse sources and recipes at `http://localhost:3000`. The UI uses a retro System 6 window style.
