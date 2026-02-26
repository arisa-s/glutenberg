# Dataset v1 Exporter

Reproducible, versioned export of the diachronic British cookbooks corpus for the project analysis. Produces frozen CSV artifacts that Python consumes downstream.

## Quick start

```bash
bundle exec rake datasets:export:v1
```

Output lands in `data/frozen/v1/<timestamp>/` (gitignored). Pass `OUTPUT_DIR` for a fixed path:

```bash
OUTPUT_DIR=data/frozen/v1/release bundle exec rake datasets:export:v1
```

## Output artifacts

| File | Description |
|------|-------------|
| `v1_recipes.csv` | One row per recipe: id, source, year, temporal slice, category, title, structural metrics |
| `v1_recipe_ingredients_long.csv` | One row per (recipe, ingredient token) pair; join to recipes CSV for context |
| `v1_manifest.json` | Selection rules, thresholds, counts, git SHA, tokenization rules |

### v1_recipes.csv columns

`dataset_version`, `recipe_id`, `source_id`, `publication_year`, `slice`, `category`, `title`, `ingredient_count`, `instruction_step_count`, `instruction_char_count`

### v1_recipe_ingredients_long.csv columns

`dataset_version`, `recipe_id`, `ingredient_token`

Join to `v1_recipes.csv` on `recipe_id` to get source, year, slice, and category context:

```python
ingredients = pd.read_csv("v1_recipe_ingredients_long.csv")
recipes = pd.read_csv("v1_recipes.csv")
df = ingredients.merge(recipes[["recipe_id", "source_id", "publication_year", "slice", "category"]], on="recipe_id")
```

## Selection rules (Scope)

All filtering logic lives in `scope.rb`. A recipe enters v1 if **all** of the following hold:

| Rule | Default |
|------|---------|
| Source `included_in_corpus` | `true` |
| `not_a_recipe` | `false` |
| `extraction_status` | `'success'` |
| `extraction_failed_count` | `<= 3` |
| Title (`COALESCE(parsed_title, title)`) | non-blank |
| Category | not `household_misc`, not `other_unknown` (NULL allowed) |
| Ingredient count | `>= 3` |
| Instruction step count | `>= 1` |
| Instruction char count | `>= 80` and `<= 50,000` |

After filtering, at most **200 recipes per source** are kept, selected in deterministic pseudo-random order using `md5(recipe_id \|\| seed)`. This spreads out similar titles (e.g. "beef soup 1", "beef soup 2") rather than taking the first 200 sequentially.

## Temporal slices

| Slice | Year range |
|-------|-----------|
| `early` | 1740--1819 |
| `victorian` | 1820--1869 |
| `late` | 1870--1929 |
| `out_of_range` | anything else or NULL |

## Ingredient tokenization (Tokenizer)

For each ingredient row:

1. **Skip cross-references**: ingredients with `recipe_ref` or `referenced_recipe_id` set are excluded -- these are references to other recipes (e.g. "see No. 487"), not real ingredients.
2. Use `product` if present, otherwise fall back to `original_string`.
3. Normalize: downcase, strip, replace non-Unicode-letter/number characters (except spaces and hyphens) with a space, collapse whitespace, trim.
4. Drop blank results.

Unicode-aware (`\p{L}`, `\p{N}`) so accented characters (e.g. "cafe", "creme") are preserved.

### Deduplication

Tokens are **not** deduplicated per recipe in the export. The same token may appear multiple times for a recipe if it was listed in multiple ingredient groups or repeated in the original text. For bag-of-words or document-term matrix analysis, deduplicate in Python with:

```python
df.drop_duplicates(subset=["recipe_id", "ingredient_token"])
```

## ENV overrides

All thresholds are configurable at export time. Defaults shown below:

| Variable | Default | Description |
|----------|---------|-------------|
| `OUTPUT_DIR` | `data/frozen/v1/<timestamp>` | Output directory |
| `CAP` | `200` | Max recipes per source |
| `SEED` | `42` | Deterministic sampling seed |
| `MAX_FAILED` | `3` | Max `extraction_failed_count` |
| `MIN_ING` | `3` | Min ingredients per recipe |
| `MIN_INST_STEPS` | `1` | Min instruction steps |
| `MIN_INST_CHARS` | `80` | Min total instruction characters |
| `MAX_INST_CHARS` | `50000` | Max total instruction characters |

Example with overrides:

```bash
CAP=100 SEED=7 MIN_ING=5 bundle exec rake datasets:export:v1
```

## Reproducibility

- Running the export twice on the same database with the same ENV produces **identical CSV content**. Only `exported_at` and (if auto-generated) the output directory name will differ.
- The manifest records the git SHA, seed, and all thresholds so any export can be traced back to its exact parameters.
- To freeze a release: export with a fixed `OUTPUT_DIR`, then tag the git commit.

## Architecture

```
app/services/datasets/v1/
  scope.rb       -- single source of truth for recipe selection + metrics
  tokenizer.rb   -- ingredient token normalization
  exporter.rb    -- writes CSVs + manifest, orchestrates scope & tokenizer

lib/tasks/
  datasets.rake  -- rake datasets:export:v1

spec/services/datasets/v1/
  scope_spec.rb     -- selection rules, per-source cap, seed reproducibility
  tokenizer_spec.rb -- normalization, unicode, fallback, blank handling
  exporter_spec.rb  -- temporal slice assignment
```

## Tests

```bash
bundle exec rspec spec/services/datasets/v1/
```
