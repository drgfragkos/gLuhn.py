#!/usr/bin/env python3
"""
gluhn_repository.py - look up the issuing bank of a PAN in repository/bin-repository.json.

The JSON is shared with the PowerShell module GLuhnRepository.psm1; see build_repository.py
for the format ("gluhn-bin-repository/1") and README.md for the sources.

Library use
    from gluhn_repository import BinRepository
    repo = BinRepository()                       # repository/bin-repository.json next to this file
    repo.lookup("4929401234567891")
    -> {'bin': '492940', 'brand': 'VISA', 'type': 'CREDIT', 'category': 'PREMIER',
        'issuer': 'BARCLAYS BANK PLC', 'country_code': 'GB', 'country': 'United Kingdom',
        'url': 'www.barclays.co.uk', 'phone': '...', 'range': '492940-492949', 'prefix_length': 6}
    repo.issuers("visa", "GB")                   # banks issuing Visa cards in the UK
    repo.brands_for_issuer("barclays")           # what Barclays issues, where

Command line
    python3 repository/gluhn_repository.py 4929401234567891 [more PANs]
    python3 repository/gluhn_repository.py --list visa GB
    python3 repository/gluhn_repository.py --issuer barclays
    python3 repository/gluhn_repository.py --info

Only the standard library is used; the file is loaded once per process (about 50 ms).
"""

from __future__ import annotations

import bisect
import json
import os
import re
import sys
from typing import Dict, List, Optional, Tuple

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_PATH = os.path.join(HERE, "bin-repository.json")
SUPPORTED_FORMATS = ("gluhn-bin-repository/1",)


class BinRepository:
    """Lookup object over bin-repository.json.  Longest BIN prefix wins."""

    def __init__(self, path: Optional[str] = None) -> None:
        self.path = path or DEFAULT_PATH
        with open(self.path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
        fmt = data.get("format")
        if fmt not in SUPPORTED_FORMATS:
            raise ValueError("%s: unsupported repository format %r" % (self.path, fmt))
        self.data = data
        self.brands: List[str] = data["brands"]
        self.types: List[str] = data["types"]
        self.categories: List[str] = data["categories"]
        self.countries: Dict[str, str] = data["countries"]
        self.issuers: List[Dict[str, str]] = data["issuers"]
        self.generated: str = data.get("generated", "")
        self.counts: Dict[str, int] = data.get("counts", {})
        # per prefix length: (sorted list of lo values, rows)
        self._index: List[Tuple[int, List[int], List[list]]] = []
        for length, rows in data["ranges"].items():
            self._index.append((int(length), [r[0] for r in rows], rows))
        self._index.sort(key=lambda t: -t[0])          # longest prefix first

    # ------------------------------------------------------------------ lookups
    def _row(self, row: list, length: int) -> Dict:
        lo, hi, b, t, c, iss, cc = row
        out: Dict = {
            "bin": str(lo).zfill(length), "prefix_length": length,
            "range": str(lo).zfill(length) if lo == hi else "%s-%s" % (str(lo).zfill(length), str(hi).zfill(length)),
            "brand": self.brands[b], "type": self.types[t], "category": self.categories[c],
            "issuer": None, "country_code": cc or None, "country": self.countries.get(cc) if cc else None,
            "url": None, "phone": None,
        }
        if iss >= 0:
            entry = self.issuers[iss]
            out["issuer"] = entry.get("n")
            out["url"] = entry.get("u")
            out["phone"] = entry.get("p")
            if not out["country_code"] and entry.get("c"):
                out["country_code"] = entry["c"]
                out["country"] = self.countries.get(entry["c"])
        return out

    def lookup(self, pan: str) -> Optional[Dict]:
        """Issuer information for a PAN (or a bare BIN of 5-8 digits); None when unknown."""
        digits = re.sub(r"\D", "", pan or "")
        for length, los, rows in self._index:
            if len(digits) < length:
                continue
            x = int(digits[:length])
            i = bisect.bisect_right(los, x) - 1
            if i >= 0 and rows[i][0] <= x <= rows[i][1]:
                return self._row(rows[i], length)
        return None

    def issuers_for(self, brand: str, country_code: Optional[str] = None) -> List[Dict]:
        """Banks that issue `brand` (any case, 'amex' and 'unionpay' accepted), optionally in one country."""
        key = _canonical_brand(brand, self.brands)
        table = self.data.get("by_brand", {}).get(key, {})
        out = []
        for cc, ids in table.items():
            if country_code and cc.upper() != country_code.upper():
                continue
            for i in ids:
                e = self.issuers[i]
                out.append({"issuer": e.get("n"), "country_code": cc, "country": self.countries.get(cc),
                            "url": e.get("u"), "phone": e.get("p"), "brand": key})
        out.sort(key=lambda d: ((d["country_code"] or ""), d["issuer"] or ""))
        return out

    # alias with the name used in the documentation
    issuers_for_brand = issuers_for

    def brands_for_issuer(self, name_part: str) -> List[Dict]:
        """Which brands a bank issues and where (substring match on the issuer name)."""
        needle = name_part.strip().upper()
        wanted = {i for i, e in enumerate(self.issuers) if needle in e.get("n", "")}
        out = []
        for brand, ccs in self.data.get("by_brand", {}).items():
            for cc, ids in ccs.items():
                for i in ids:
                    if i in wanted:
                        out.append({"issuer": self.issuers[i]["n"], "brand": brand, "country_code": cc,
                                    "country": self.countries.get(cc)})
        out.sort(key=lambda d: (d["issuer"], d["brand"], d["country_code"]))
        return out

    def info(self) -> Dict:
        return {"path": self.path, "format": self.data.get("format"), "generated": self.generated,
                "counts": self.counts, "sources": self.data.get("sources", [])}


def _canonical_brand(brand: str, known: List[str]) -> str:
    b = re.sub(r"\s+", " ", (brand or "").strip().upper())
    aliases = {"AMEX": "AMERICAN EXPRESS", "UNIONPAY": "CHINA UNIONPAY", "UNION PAY": "CHINA UNIONPAY",
               "CUP": "CHINA UNIONPAY", "DINERS": "DINERS CLUB", "MC": "MASTERCARD", "MASTER CARD": "MASTERCARD"}
    b = aliases.get(b, b)
    if b in known:
        return b
    for k in known:                         # prefix match: "DINERS" -> "DINERS CLUB"
        if k.startswith(b):
            return k
    return b


def format_lookup(info: Optional[Dict]) -> str:
    """One line in the style of gLuhn's text output."""
    if not info:
        return "no issuer information"
    bits = [info.get(k) for k in ("issuer", "brand", "type", "category", "country") if info.get(k)]
    return "%s  [BIN %s]" % (" | ".join(bits), info["range"])


def load_repository(path: Optional[str] = None) -> BinRepository:
    """Convenience wrapper used by gLuhn.py; raises OSError / ValueError on problems."""
    return BinRepository(path)


def main(argv: Optional[List[str]] = None) -> int:
    import argparse
    ap = argparse.ArgumentParser(description="Issuer lookup against bin-repository.json")
    ap.add_argument("pan", nargs="*", help="PAN or BIN")
    ap.add_argument("--repo", default=None, help="path to bin-repository.json")
    ap.add_argument("--list", nargs="+", metavar=("BRAND", "COUNTRY"), help="banks issuing BRAND [in COUNTRY]")
    ap.add_argument("--issuer", metavar="NAME", help="brands and countries for a bank name (substring)")
    ap.add_argument("--info", action="store_true")
    ap.add_argument("-j", "--json", action="store_true")
    args = ap.parse_args(argv)
    try:
        repo = BinRepository(args.repo)
    except (OSError, ValueError) as exc:
        print("cannot load repository: %s" % exc, file=sys.stderr)
        return 2
    results = []
    if args.info:
        results.append(repo.info())
        if not args.json:
            inf = repo.info()
            print("repository: %s" % inf["path"])
            print("format %s, generated %s" % (inf["format"], inf["generated"]))
            print("counts: %s" % ", ".join("%s %s" % (k, v) for k, v in inf["counts"].items()))
            for s in inf["sources"]:
                print("source: %s (%s rows)" % (s.get("name"), s.get("rows")))
    if args.list:
        rows = repo.issuers_for(args.list[0], args.list[1] if len(args.list) > 1 else None)
        results.extend(rows)
        if not args.json:
            for r in rows:
                print("%-3s %-45s %s" % (r["country_code"], r["issuer"], r.get("url") or ""))
            print("%d issuer(s)" % len(rows))
    if args.issuer:
        rows = repo.brands_for_issuer(args.issuer)
        results.extend(rows)
        if not args.json:
            for r in rows:
                print("%-45s %-18s %s" % (r["issuer"], r["brand"], r["country_code"]))
            print("%d entries" % len(rows))
    for pan in args.pan:
        info = repo.lookup(pan)
        results.append({"pan": pan, "lookup": info})
        if not args.json:
            print("%s: %s" % (pan, format_lookup(info)))
    if args.json:
        print(json.dumps(results if len(results) != 1 else results[0], indent=2, ensure_ascii=False))
    if not (args.pan or args.list or args.issuer or args.info):
        ap.print_help()
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
