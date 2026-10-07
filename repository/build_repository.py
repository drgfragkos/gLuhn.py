#!/usr/bin/env python3
"""
build_repository.py - build repository/bin-repository.json, the issuer (BIN) repository
shared by gLuhn.py and gLuhn.ps1.

The repository answers "which bank issued this PAN?" (Visa issued by Barclays, Mastercard
issued by Deutsche Bank, ...) and "which banks issue brand X in country Y?".

Sources
  1. The open binlist-data CSV (default; downloaded when not given):
     https://github.com/iannuttall/binlist-data   columns: bin,brand,type,category,issuer,
     alpha_2,alpha_3,country,latitude,longitude,bank_phone,bank_url
  2. Any number of extra CSV files (--source), for example lists exported from
     https://www.creditcardvalidator.org/<brand> or a commercial BIN table.  Columns are
     detected by name: a start column (bin / iin / iin_start / prefix), optional end column
     (iin_end / bin_end), brand / scheme, type, category, issuer / bank, alpha_2 / country,
     bank_url, bank_phone.  Later sources override earlier ones for the same BIN.

Usage
  python3 repository/build_repository.py                       # download binlist-data, build
  python3 repository/build_repository.py --binlist binlist.csv # use a local copy
  python3 repository/build_repository.py --source my-bins.csv --source ccv-visa.csv
  python3 repository/build_repository.py --no-binlist --source only-this.csv

Output format (bin-repository.json, "gluhn-bin-repository/1")
  {
    "format": "gluhn-bin-repository/1", "generated": "YYYY-MM-DD", "sources": [...],
    "counts": {...},
    "brands": ["VISA", ...],  "types": ["", "CREDIT", ...],  "categories": ["", "CLASSIC", ...],
    "countries": {"GB": "United Kingdom", ...},
    "issuers": [{"n": "BARCLAYS BANK PLC", "c": "GB", "u": "www.barclays.co.uk", "p": "..."}, ...],
    "ranges": { "6": [[lo, hi, brandId, typeId, categoryId, issuerId, "GB"], ...], "8": [...] },
    "by_brand": { "VISA": { "GB": [issuerId, ...] } }
  }
  ranges[L] holds the ranges whose BIN prefix has L digits, sorted by lo and non overlapping;
  lo/hi are integers of L digits.  A lookup tries the longest prefix length first.
  issuerId -1 means "issuer unknown".  Everything is UTF-8.
"""

import argparse
import csv
import datetime
import io
import json
import os
import re
import sys
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_OUTPUT = os.path.join(HERE, "bin-repository.json")
BINLIST_URL = "https://raw.githubusercontent.com/iannuttall/binlist-data/master/binlist-data.csv"
FORMAT = "gluhn-bin-repository/1"

START_COLS = ("iin_start", "bin_start", "range_start", "bin", "iin", "prefix", "start")
END_COLS = ("iin_end", "bin_end", "range_end", "end")
COLS = {
    "brand": ("brand", "scheme", "network", "card_brand", "vendor"),
    "type": ("type", "card_type", "debit_credit"),
    "category": ("category", "level", "card_category", "product"),
    "issuer": ("issuer", "bank", "bank_name", "issuer_name", "issuing_bank"),
    "alpha_2": ("alpha_2", "country_code", "iso_country", "alpha2"),
    "country": ("country", "country_name"),
    "url": ("bank_url", "url", "website"),
    "phone": ("bank_phone", "phone"),
}

# Brand names are normalised so that different sources agree with each other and with the
# scheme keys used by gLuhn's built-in table.
BRAND_ALIASES = {
    "VISA": "VISA", "VISA ELECTRON": "VISA", "VISA DEBIT": "VISA", "VISA CREDIT": "VISA",
    "MASTERCARD": "MASTERCARD", "MASTER CARD": "MASTERCARD", "MC": "MASTERCARD",
    "AMERICAN EXPRESS": "AMERICAN EXPRESS", "AMEX": "AMERICAN EXPRESS",
    "DISCOVER": "DISCOVER", "DISCOVER CARD": "DISCOVER",
    "DINERS CLUB": "DINERS CLUB", "DINERS": "DINERS CLUB", "DINERS CLUB INTERNATIONAL": "DINERS CLUB",
    "CHINA UNION PAY": "CHINA UNIONPAY", "CHINA UNIONPAY": "CHINA UNIONPAY", "UNIONPAY": "CHINA UNIONPAY",
    "UNION PAY": "CHINA UNIONPAY", "CUP": "CHINA UNIONPAY",
    "JCB": "JCB", "MAESTRO": "MAESTRO", "MIR": "MIR", "RUPAY": "RUPAY", "ELO": "ELO", "TROY": "TROY",
    "VERVE": "VERVE", "UATP": "UATP", "DANKORT": "DANKORT", "HIPERCARD": "HIPERCARD",
}


def norm(text):
    return re.sub(r"\s+", " ", (text or "").strip())


def norm_brand(text):
    t = norm(text).upper()
    return BRAND_ALIASES.get(t, t)


def pick(header, candidates):
    lowered = [h.strip().lower() for h in header]
    for c in candidates:
        if c in lowered:
            return lowered.index(c)
    return None


def read_source(path_or_bytes, name):
    """Yield normalised dict rows from a CSV source (path or bytes)."""
    if isinstance(path_or_bytes, bytes):
        fh = io.StringIO(path_or_bytes.decode("utf-8-sig", "replace"), newline="")
    else:
        fh = open(path_or_bytes, "r", encoding="utf-8-sig", errors="replace", newline="")
    with fh:
        sample = fh.read(8192)
        fh.seek(0)
        try:
            dialect = csv.Sniffer().sniff(sample, delimiters=",;\t|")
        except csv.Error:
            dialect = csv.excel
        reader = csv.reader(fh, dialect)
        header = next(reader, None)
        if not header:
            raise ValueError("%s: empty file" % name)
        i_start = pick(header, START_COLS)
        if i_start is None:
            raise ValueError("%s: no BIN start column (one of %s)" % (name, ", ".join(START_COLS)))
        i_end = pick(header, END_COLS)
        idx = {k: pick(header, v) for k, v in COLS.items()}

        def cell(row, i):
            return norm(row[i]) if i is not None and i < len(row) else ""

        for row in reader:
            start = re.sub(r"\D", "", cell(row, i_start))
            if not (5 <= len(start) <= 8):
                continue
            end = re.sub(r"\D", "", cell(row, i_end)) if i_end is not None else ""
            if end and len(end) != len(start):
                n = max(len(start), len(end))
                start, end = start.ljust(n, "0"), end.ljust(n, "9")
            yield {
                "lo": start, "hi": end or start,
                "brand": norm_brand(cell(row, idx["brand"])),
                "type": norm(cell(row, idx["type"])).upper(),
                "category": norm(cell(row, idx["category"])).upper(),
                "issuer": norm(cell(row, idx["issuer"])).upper(),
                "alpha_2": norm(cell(row, idx["alpha_2"])).upper()[:2],
                "country": norm(cell(row, idx["country"])),
                "url": norm(cell(row, idx["url"])).lower(),
                "phone": norm(cell(row, idx["phone"])),
            }


def build(rows_by_source):
    """rows_by_source: list of (source name, iterable of rows).  Later sources win."""
    bins = {}          # (length, int bin) -> attributes; one entry per single BIN
    countries = {}
    source_counts = []
    for name, rows in rows_by_source:
        count = 0
        for r in rows:
            count += 1
            length = len(r["lo"])
            lo, hi = int(r["lo"]), int(r["hi"])
            if hi - lo > 100000:          # refuse absurd ranges from a malformed row
                continue
            if r["alpha_2"] and r["country"]:
                countries.setdefault(r["alpha_2"], r["country"])
            attrs = (r["brand"], r["type"], r["category"], r["issuer"], r["alpha_2"], r["url"], r["phone"])
            for b in range(lo, hi + 1):
                bins[(length, b)] = attrs
        source_counts.append((name, count))

    brands, types, categories = {}, {}, {}
    issuers = {}
    issuer_list = []

    def intern(table, value):
        if value not in table:
            table[value] = len(table)
        return table[value]

    def issuer_id(name, cc, url, phone):
        # One entry per (bank name, country); URL and phone are filled from the first row
        # that has them, so a bank is listed once even when some of its BINs lack contact data.
        if not name:
            return -1
        key = (name, cc)
        if key not in issuers:
            issuers[key] = len(issuer_list)
            issuer_list.append({"n": name, "c": cc})
        entry = issuer_list[issuers[key]]
        if url and "u" not in entry:
            entry["u"] = url
        if phone and "p" not in entry:
            entry["p"] = phone
        return issuers[key]

    intern(types, "")
    intern(categories, "")
    ranges = {}
    by_brand = {}
    for (length, b) in sorted(bins):
        brand, typ, cat, iss, cc, url, phone = bins[(length, b)]
        row = [b, b, intern(brands, brand or "UNKNOWN"), intern(types, typ), intern(categories, cat),
               issuer_id(iss, cc, url, phone), cc]
        lst = ranges.setdefault(str(length), [])
        if lst and lst[-1][1] == b - 1 and lst[-1][2:] == row[2:]:
            lst[-1][1] = b
        else:
            lst.append(row)
        if row[5] >= 0:
            by_brand.setdefault(brand or "UNKNOWN", {}).setdefault(cc or "ZZ", set()).add(row[5])

    inv = lambda table: [k for k, _ in sorted(table.items(), key=lambda kv: kv[1])]
    repo = {
        "format": FORMAT,
        "generated": datetime.date.today().isoformat(),
        "sources": [{"name": n, "rows": c} for n, c in source_counts],
        "counts": {"bins": len(bins), "ranges": sum(len(v) for v in ranges.values()),
                   "issuers": len(issuer_list), "countries": len(countries), "brands": len(brands)},
        "brands": inv(brands), "types": inv(types), "categories": inv(categories),
        "countries": dict(sorted(countries.items())),
        "issuers": issuer_list,
        "ranges": ranges,
        "by_brand": {b: {cc: sorted(ids) for cc, ids in sorted(ccs.items())} for b, ccs in sorted(by_brand.items())},
    }
    return repo


def download(url):
    req = urllib.request.Request(url, headers={"User-Agent": "gLuhn-build-repository"})
    with urllib.request.urlopen(req, timeout=120) as resp:
        return resp.read()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--binlist", metavar="CSV", help="local copy of binlist-data.csv (default: download)")
    ap.add_argument("--no-binlist", action="store_true", help="do not use binlist-data at all")
    ap.add_argument("--source", action="append", default=[], metavar="CSV",
                    help="extra CSV source (repeatable); later sources override earlier ones")
    ap.add_argument("--output", default=DEFAULT_OUTPUT)
    ap.add_argument("--pretty", action="store_true", help="indent the JSON (bigger file, easier diffs)")
    args = ap.parse_args()

    sources = []
    if not args.no_binlist:
        if args.binlist:
            sources.append(("binlist-data (%s)" % os.path.basename(args.binlist), read_source(args.binlist, args.binlist)))
        else:
            print("downloading %s ..." % BINLIST_URL)
            try:
                data = download(BINLIST_URL)
            except Exception as exc:
                print("cannot download binlist-data: %s" % exc, file=sys.stderr)
                return 1
            sources.append(("binlist-data (%s)" % BINLIST_URL, read_source(data, "binlist-data")))
    for path in args.source:
        sources.append((os.path.basename(path), read_source(path, path)))
    if not sources:
        print("no sources: give --binlist/--source or drop --no-binlist", file=sys.stderr)
        return 1

    repo = build(sources)
    with open(args.output, "w", encoding="utf-8") as fh:
        if args.pretty:
            json.dump(repo, fh, indent=1, ensure_ascii=False)
        else:
            json.dump(repo, fh, separators=(",", ":"), ensure_ascii=False)
        fh.write("\n")
    size = os.path.getsize(args.output)
    c = repo["counts"]
    print("wrote %s (%.1f MB): %d BINs -> %d ranges, %d issuers, %d countries, %d brands" % (
        args.output, size / 1048576.0, c["bins"], c["ranges"], c["issuers"], c["countries"], c["brands"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
