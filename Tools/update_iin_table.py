#!/usr/bin/env python3
"""
update_iin_table.py - regenerate an IIN table for gLuhn from an open-source range list.

Fetches the card-types definition of the braintree "credit-card-type" project (MIT licensed,
https://github.com/braintree/credit-card-type), converts it into gLuhn's --iin-table JSON
format and writes it next to this script (or to --output).  Keys are mapped onto gLuhn's
built-in keys where they coincide, so the generated table overrides those schemes' ranges
and leaves everything else in the built-in table untouched.

    python3 tools/update_iin_table.py                      # fetch + write tools/iin-table.braintree.json
    python3 tools/update_iin_table.py --source card-types.ts --output my-table.json
    python3 gLuhn.py --iin-table tools/iin-table.braintree.json 4111111111111111

Only the standard library is used.
"""

import argparse
import datetime
import json
import os
import re
import sys
import urllib.request

SOURCE_URL = "https://raw.githubusercontent.com/braintree/credit-card-type/main/src/lib/card-types.ts"
KEY_MAP = {
    "visa": "visa", "mastercard": "mastercard", "american-express": "amex", "diners-club": "diners",
    "discover": "discover", "jcb": "jcb", "unionpay": "unionpay", "maestro": "maestro", "elo": "elo",
    "mir": "mir", "hiper": "hiper", "hipercard": "hipercard", "troy": "troy", "verve": "verve",
    "naranja": "naranja",
}
# braintree lists some ranges as bare prefixes that gLuhn treats as catch-all ranges
CATCH_ALL = {"maestro": {"6", "63", "67"}}


def fetch(source):
    if source and os.path.exists(source):
        with open(source, "r", encoding="utf-8") as fh:
            return fh.read()
    req = urllib.request.Request(source or SOURCE_URL, headers={"User-Agent": "gLuhn-update-iin-table"})
    with urllib.request.urlopen(req, timeout=60) as resp:
        return resp.read().decode("utf-8")


def parse_card_types(text):
    """Very small parser for the TypeScript object literal: niceType, type, patterns, lengths."""
    out = []
    for block in re.finditer(r"niceType:\s*\"([^\"]+)\",\s*type:\s*\"([^\"]+)\",\s*patterns:\s*\[(.*?)\],\s*gaps:.*?lengths:\s*\[([^\]]*)\]",
                             text, re.S):
        nice, key, patterns, lengths = block.groups()
        ranges = []
        for item in re.finditer(r"\[\s*(\d+)\s*,\s*(\d+)\s*\]|(\d+)", patterns):
            if item.group(3):
                ranges.append(item.group(3))
            else:
                lo, hi = item.group(1), item.group(2)
                # pad the shorter bound so both have the same length (gLuhn requirement)
                n = max(len(lo), len(hi))
                ranges.append("%s-%s" % (lo.ljust(n, "0"), hi.ljust(n, "9")))
        out.append({"nice": nice, "type": key, "ranges": ranges,
                    "lengths": [int(x) for x in re.findall(r"\d+", lengths)]})
    return out


def build_table(card_types):
    schemes = []
    for ct in card_types:
        key = KEY_MAP.get(ct["type"], ct["type"].replace("-", "_"))
        catch = CATCH_ALL.get(key, set())
        schemes.append({
            "key": key, "name": ct["nice"],
            "ranges": [r for r in ct["ranges"] if r not in catch],
            "catch_all": [r for r in ct["ranges"] if r in catch],
            "lengths": ct["lengths"], "luhn": True, "active": True,
            "note": "ranges from braintree/credit-card-type",
        })
    return {"generated": datetime.date.today().isoformat(), "source": SOURCE_URL,
            "licence": "braintree/credit-card-type is MIT licensed", "replace": False, "schemes": schemes}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--source", help="local card-types.ts or alternative URL (default: fetch from GitHub)")
    ap.add_argument("--output", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "iin-table.braintree.json"))
    args = ap.parse_args()
    try:
        text = fetch(args.source)
    except Exception as exc:
        print("cannot fetch source: %s" % exc, file=sys.stderr)
        return 1
    card_types = parse_card_types(text)
    if not card_types:
        print("no card types found in the source; has the file format changed?", file=sys.stderr)
        return 1
    table = build_table(card_types)
    with open(args.output, "w", encoding="utf-8") as fh:
        json.dump(table, fh, indent=2)
        fh.write("\n")
    print("wrote %s: %d schemes, %d ranges" % (args.output, len(table["schemes"]),
                                                sum(len(s["ranges"]) + len(s["catch_all"]) for s in table["schemes"])))
    return 0


if __name__ == "__main__":
    sys.exit(main())
