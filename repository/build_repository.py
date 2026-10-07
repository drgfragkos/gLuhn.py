#!/usr/bin/env python3
"""
build_repository.py - build repository/bin-repository.json, the issuer (BIN) repository
shared by gLuhn.py and gLuhn.ps1.

The repository answers "which bank issued this PAN?" (Visa issued by Barclays, Mastercard
issued by Deutsche Bank, ...) and "which banks issue brand X in country Y?".

Sources (all open data; later sources override earlier ones for the same BIN)
  binlistio   binlist.io merged data set, CC BY 4.0, https://github.com/Techbuddie-Solutions/binlist-data
              (458,051 six digit BINs; a merge of iannuttall/binlist-data (2020) and
              venelinkochev/bin-list-data (2025), refreshed 2026).  Default.
  openbiin    OpenBIIN community database, GPL-3.0, https://github.com/Wayproyect/openbiin
              (BIN6 plus two digit sub-ranges = 8 digit precision, split into 100 CSV files). Default.
  venelin     venelinkochev/bin-list-data, CC BY 4.0 (374,788 BINs, February 2025).
  iannuttall  iannuttall/binlist-data, CC BY 4.0 (343,063 BINs, December 2020, archived).
  binlistnet  binlist/data ranges.csv (older binlist.net export, scheme level, 5,805 rows).
  --source    any extra CSV file, for example lists exported from
              https://www.creditcardvalidator.org/<brand> or a commercial BIN table.
  Columns are detected by name: a start column (bin / bin6 / iin / iin_start / prefix), optional
  end column (iin_end / bin_end) or OpenBIIN "Ranges", brand / scheme, type, category,
  issuer / bank / bank_name, alpha_2 / isoCode2 / country, bank_url / issuer_url,
  bank_phone / issuer_phone.

Usage
  python3 repository/build_repository.py                        # binlistio + openbiin, downloaded
  python3 repository/build_repository.py --sources binlistio    # one named source only
  python3 repository/build_repository.py --sources iannuttall,venelin,binlistio,openbiin
  python3 repository/build_repository.py --local binlistio=bins.csv --local openbiin=./openbiin/data
  python3 repository/build_repository.py --source my-bins.csv --source ccv-visa.csv
  python3 repository/build_repository.py --sources none --source only-this.csv

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
FORMAT = "gluhn-bin-repository/1"

RAW = "https://raw.githubusercontent.com/"
NAMED_SOURCES = {
    "binlistnet": {"url": RAW + "binlist/data/master/ranges.csv", "kind": "csv",
                   "licence": "binlist.net open data", "home": "https://github.com/binlist/data"},
    "iannuttall": {"url": RAW + "iannuttall/binlist-data/master/binlist-data.csv", "kind": "csv",
                   "licence": "CC BY 4.0", "home": "https://github.com/iannuttall/binlist-data"},
    "venelin": {"url": RAW + "venelinkochev/bin-list-data/master/bin-list-data.csv", "kind": "csv",
                "licence": "CC BY 4.0", "home": "https://github.com/venelinkochev/bin-list-data"},
    "binlistio": {"url": RAW + "Techbuddie-Solutions/binlist-data/main/bins.csv", "kind": "csv",
                  "licence": "CC BY 4.0", "home": "https://github.com/Techbuddie-Solutions/binlist-data"},
    "openbiin": {"url": RAW + "Wayproyect/openbiin/main/functions/data/{nn}.csv", "kind": "openbiin",
                 "licence": "GPL-3.0", "home": "https://github.com/Wayproyect/openbiin"},
}
DEFAULT_SOURCES = ("binlistio", "openbiin")

# names for alpha-2 codes that appear in a source without a country name column
ISO_COUNTRY_NAMES = {
    "AD": "Andorra", "AE": "United Arab Emirates", "AR": "Argentina", "AT": "Austria", "AU": "Australia",
    "BE": "Belgium", "BG": "Bulgaria", "BR": "Brazil", "CA": "Canada", "CH": "Switzerland", "CL": "Chile",
    "CN": "China", "CO": "Colombia", "CZ": "Czechia", "DE": "Germany", "DK": "Denmark", "EE": "Estonia",
    "EG": "Egypt", "ES": "Spain", "FI": "Finland", "FR": "France", "GB": "United Kingdom", "GR": "Greece",
    "HK": "Hong Kong", "HR": "Croatia", "HU": "Hungary", "ID": "Indonesia", "IE": "Ireland", "IL": "Israel",
    "IN": "India", "IT": "Italy", "JP": "Japan", "KR": "South Korea", "KZ": "Kazakhstan", "LT": "Lithuania",
    "LU": "Luxembourg", "LV": "Latvia", "MA": "Morocco", "MX": "Mexico", "MY": "Malaysia", "NG": "Nigeria",
    "NL": "Netherlands", "NO": "Norway", "NZ": "New Zealand", "PE": "Peru", "PH": "Philippines", "PK": "Pakistan",
    "PL": "Poland", "PT": "Portugal", "QA": "Qatar", "RO": "Romania", "RS": "Serbia", "RU": "Russia",
    "SA": "Saudi Arabia", "SE": "Sweden", "SG": "Singapore", "SI": "Slovenia", "SK": "Slovakia", "TH": "Thailand",
    "TR": "Turkey", "TW": "Taiwan", "UA": "Ukraine", "US": "United States", "UZ": "Uzbekistan", "VN": "Vietnam",
    "ZA": "South Africa",
}

START_COLS = ("iin_start", "bin_start", "range_start", "bin", "bin6", "iin", "prefix", "start")
END_COLS = ("iin_end", "bin_end", "range_end", "end")
COLS = {
    "brand": ("brand", "scheme", "network", "card_brand", "vendor"),
    "type": ("type", "card_type", "debit_credit"),
    "category": ("category", "level", "card_category", "product"),
    "issuer": ("issuer", "bank", "bank_name", "issuer_name", "issuing_bank"),
    "alpha_2": ("alpha_2", "country_code", "iso_country", "alpha2", "isocode2"),
    "country": ("country", "country_name", "countryname"),
    "url": ("bank_url", "issuer_url", "issuerurl", "url", "website"),
    "phone": ("bank_phone", "issuer_phone", "issuerphone", "phone"),
    "ranges": ("ranges",),
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
    "NSPK MIR": "MIR", "HUMOCARD": "HUMO", "TARJETA NARANJA": "NARANJA", "EFTPOS_AUSTRALIA": "EFTPOS",
    "BANKCARD(INACTIVE)": "BANKCARD", "VPAY": "V PAY", "PROP": "PRIVATE LABEL", "LOCAL": "LOCAL BRAND",
    "UNKNOWN": "", "\u4ea4\u901a\u8054\u5408": "CHINA T-UNION", "T-UNION": "CHINA T-UNION",
}


def norm_country_name(text):
    """'UNITED KINGDOM' -> 'United Kingdom' (sources disagree on casing)."""
    t = norm(text)
    if not t or t != t.upper():
        return t
    words = []
    for w in t.lower().split(" "):
        if w in ("and", "of", "the", "da", "de", "du", "et", "la", "y"):
            words.append(w)
        elif w.startswith("(") and len(w) > 1:
            words.append("(" + w[1:].capitalize())
        else:
            words.append("-".join(x.capitalize() for x in w.split("-")))
    words[0] = words[0].capitalize() if words[0].islower() else words[0]
    return " ".join(words)


def norm(text):
    return re.sub(r"\s+", " ", (text or "").strip())


def norm_brand(text):
    t = norm(text).upper()
    if re.fullmatch(r"[A-Z]{2}", t):            # a country code in the brand column is not a brand
        return ""
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
            alpha_2 = norm(cell(row, idx["alpha_2"])).upper()[:2]
            country = cell(row, idx["country"])
            if not alpha_2 and re.fullmatch(r"[A-Za-z]{2}", country or ""):
                alpha_2, country = country.upper(), ""           # OpenBIIN: "Country" holds the code
            attrs = {
                "brand": norm_brand(cell(row, idx["brand"])),
                "type": norm(cell(row, idx["type"])).upper(),
                "category": norm(cell(row, idx["category"])).upper(),
                "issuer": norm(cell(row, idx["issuer"])).upper(),
                "alpha_2": alpha_2,
                "country": norm_country_name(country),
                "url": norm(cell(row, idx["url"])).lower(),
                "phone": norm(cell(row, idx["phone"])),
            }
            sub = cell(row, idx["ranges"]) if idx.get("ranges") is not None else ""
            if sub and len(start) == 6:
                # OpenBIIN: "00-19|50-99" are the 7th and 8th digits issued by this institution
                for part in sub.split("|"):
                    m = re.fullmatch(r"\s*(\d{1,2})\s*(?:-\s*(\d{1,2}))?\s*", part)
                    if not m:
                        continue
                    a = int(m.group(1))
                    b = int(m.group(2) or m.group(1))
                    if a == 0 and b == 99:
                        yield dict(attrs, lo=start, hi=start)          # whole BIN6, keep it 6 digits
                    else:
                        yield dict(attrs, lo="%s%02d" % (start, a), hi="%s%02d" % (start, b))
                continue
            yield dict(attrs, lo=start, hi=end or start)


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

    for cc in {attrs[4] for attrs in bins.values()} - set(countries):
        if cc:
            countries[cc] = ISO_COUNTRY_NAMES.get(cc, cc)
    inv = lambda table: [k for k, _ in sorted(table.items(), key=lambda kv: kv[1])]
    repo = {
        "format": FORMAT,
        "generated": datetime.date.today().isoformat(),
        "sources": [{"name": n, "rows": c} for n, c in source_counts],
        "licences": "see each source; CC BY 4.0 sources require attribution, OpenBIIN is GPL-3.0",
        "counts": {"bins": len(bins), "ranges": sum(len(v) for v in ranges.values()),
                   "issuers": len(issuer_list), "countries": len(countries), "brands": len(brands)},
        "brands": inv(brands), "types": inv(types), "categories": inv(categories),
        "countries": dict(sorted(countries.items())),
        "issuers": issuer_list,
        "ranges": ranges,
        "by_brand": {b: {cc: sorted(ids) for cc, ids in sorted(ccs.items())} for b, ccs in sorted(by_brand.items())},
    }
    return repo


CACHE_DIR = None     # set from --cache; downloaded files are kept there and reused


def download(url, attempts=4):
    """Fetch a URL (through the --cache folder when set); transient errors are retried."""
    import http.client
    import time
    import urllib.error
    cache_file = None
    if CACHE_DIR:
        cache_file = os.path.join(CACHE_DIR, re.sub(r"[^A-Za-z0-9._-]+", "_", url.split("://", 1)[-1]))
        if os.path.exists(cache_file) and os.path.getsize(cache_file) > 0:
            with open(cache_file, "rb") as fh:
                return fh.read()
    req = urllib.request.Request(url, headers={"User-Agent": "gLuhn-build-repository"})
    last = None
    for attempt in range(1, attempts + 1):
        try:
            with urllib.request.urlopen(req, timeout=180) as resp:
                data = resp.read()
            if cache_file:
                os.makedirs(CACHE_DIR, exist_ok=True)
                with open(cache_file, "wb") as fh:
                    fh.write(data)
            return data
        except urllib.error.HTTPError as exc:
            if exc.code < 500:
                raise
            last = exc
        except (urllib.error.URLError, http.client.HTTPException, ConnectionError, TimeoutError) as exc:
            last = exc
        time.sleep(2 * attempt)
    raise last


def read_openbiin(location):
    """OpenBIIN is split into 100 files 00.csv .. 99.csv (a folder, or a URL template with {nn})."""
    for nn in ("%02d" % i for i in range(100)):
        if "{nn}" in location:
            try:
                data = download(location.replace("{nn}", nn))
            except Exception as exc:                 # a missing prefix file is normal
                if "404" not in str(exc):
                    print("  openbiin %s: %s" % (nn, exc), file=sys.stderr)
                continue
            yield from read_source(data, "openbiin %s" % nn)
        else:
            path = os.path.join(location, nn + ".csv")
            if os.path.exists(path):
                yield from read_source(path, path)


def open_named_source(name, local=None):
    spec = NAMED_SOURCES[name]
    label = "%s (%s, %s)" % (name, spec["home"], spec["licence"])
    if spec["kind"] == "openbiin":
        return label, read_openbiin(local or spec["url"])
    if local:
        return label, read_source(local, local)
    print("downloading %s ..." % spec["url"])
    return label, read_source(download(spec["url"]), name)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--sources", default=",".join(DEFAULT_SOURCES), metavar="LIST",
                    help="named sources in priority order, comma separated: %s, or 'none' (default: %s)"
                         % ("/".join(NAMED_SOURCES), ",".join(DEFAULT_SOURCES)))
    ap.add_argument("--local", action="append", default=[], metavar="NAME=PATH",
                    help="use a local copy for a named source (a CSV, or the data folder for openbiin)")
    ap.add_argument("--binlist", metavar="CSV", help="shorthand for --sources iannuttall --local iannuttall=CSV")
    ap.add_argument("--source", action="append", default=[], metavar="CSV",
                    help="extra CSV source (repeatable); later sources override earlier ones")
    ap.add_argument("--output", default=DEFAULT_OUTPUT)
    ap.add_argument("--cache", metavar="DIR", default=os.path.join(os.path.expanduser("~"), ".gluhn", "sources"),
                    help="keep downloaded source files here and reuse them (default ~/.gluhn/sources; '' disables)")
    ap.add_argument("--pretty", action="store_true", help="indent the JSON (bigger file, easier diffs)")
    args = ap.parse_args()

    global CACHE_DIR
    CACHE_DIR = args.cache or None
    locals_ = {}
    for item in args.local:
        if "=" not in item:
            print("--local expects NAME=PATH", file=sys.stderr)
            return 1
        k, v = item.split("=", 1)
        locals_[k.strip()] = v.strip()
    names = [] if args.sources.strip().lower() == "none" else [n.strip() for n in args.sources.split(",") if n.strip()]
    if args.binlist:
        names = ["iannuttall"]
        locals_["iannuttall"] = args.binlist
    sources = []
    for name in names:
        if name not in NAMED_SOURCES:
            print("unknown source %r (choose from %s)" % (name, ", ".join(NAMED_SOURCES)), file=sys.stderr)
            return 1
        try:
            sources.append(open_named_source(name, locals_.get(name)))
        except Exception as exc:
            print("cannot open source %s: %s" % (name, exc), file=sys.stderr)
            return 1
    for path in args.source:
        sources.append((os.path.basename(path), read_source(path, path)))
    if not sources:
        print("no sources: give --sources and/or --source", file=sys.stderr)
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
