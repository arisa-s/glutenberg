#!/usr/bin/env python3
"""
Batch FDC (Food Data Central) foundation food lookup via ingredient-parser-nlp.

Reads a JSON array of product names from stdin, returns a JSON array of
foundation food matches for each product. Each element is an array of
matches (usually 0-3), ordered by confidence.

Usage:
    echo '["flour", "butter", "chicken"]' | python3 bin/fdc_lookup.py

Requires:
    pip install ingredient-parser-nlp
"""

import json
import sys

from ingredient_parser import parse_ingredient


def lookup_foundation_foods(product_name):
    try:
        parsed = parse_ingredient(product_name, foundation_foods=True, string_units=True)
        return [
            {
                "fdc_id": ff.fdc_id,
                "text": ff.text,
                "category": ff.category,
                "confidence": ff.confidence,
                "data_type": ff.data_type,
            }
            for ff in parsed.foundation_foods
        ]
    except Exception:
        return []


def main():
    raw = sys.stdin.read().strip()
    if not raw:
        print("[]")
        return

    products = json.loads(raw)
    results = [lookup_foundation_foods(name) for name in products]
    print(json.dumps(results))


if __name__ == "__main__":
    main()
