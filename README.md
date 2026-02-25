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

### Internet Archive (OCR text)

```bash
rails "ia:import[IDENTIFIER]"              # import from IA metadata API
rails "ia:fetch[SOURCE_ID]"                # download OCR text
rails "ia:process[SOURCE_ID]"              # split + extract via LLM
```

### Extraction utilities

```bash
rails "extraction:resolve_refs[SOURCE_ID]"  # resolve recipe cross-references
rails "extraction:resolve_all_refs"          # resolve refs for all sources
```

## Split strategies

Each book requires a custom splitter that understands its HTML/text structure. Strategies live in:

- `app/services/gutenberg/splitters/` — HTML-based (Nokogiri)
- `app/services/internet_archive/splitters/` — plain text-based

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
| `OcrSegmentPages` | Multimodal OCR + recipe segmentation |
| `IdentifyRecipeBoundaries` | First pass: find recipe boundaries in page images |
| `ExtractRecipesFromPages` | Second pass: full extraction from page images |
| `FdcEnrichment` | Enrich ingredients with USDA foundation food data |
| `OpenRouterClient` | HTTP client for the OpenRouter API |
| `ResponseParser` | Robust JSON parser for LLM responses |

## Web UI

```bash
bin/rails server
```

Browse sources and recipes at `http://localhost:3000`. The UI uses a retro System 6 window style.
