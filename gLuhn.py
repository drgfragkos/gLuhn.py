#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gLuhn.py v1.0 - Check / generate PAN (Luhn), identify the card scheme (IIN)
                and decode magnetic-stripe / EMV track data.  (c) gfragkos 2013-2026

You may modify, reuse and distribute the code freely as long as it is referenced back
to the author using the following line: ..based on gLuhn.py by @drgfragkos

Modes (chosen automatically from the input):

  PAN            digits only           -> Luhn check + scheme / issuer identification
  PAN with '?'   e.g. 4542109540?18054 -> generate every valid combination
  Track data     4542...=2512101...    -> parse track 1 / track 2 (or EMV tag 57),
                                          validate the PAN and decode the service code
  --scan FILE                          -> find candidate PANs in arbitrary text

Everything here is pure standard-library Python 3 (no numpy any more).
The same functionality is available for Windows PowerShell 5.1 in gLuhn.ps1.
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import re
import sys
from typing import Dict, Iterable, Iterator, List, Optional, Sequence, Tuple

__version__ = "1.0.0"
__author__ = "@drgfragkos"

BANNER = ("gLuhn.py v%s - Check/Generate PAN (Luhn), identify IIN/scheme, decode track data "
          "(c)gfragkos 2013-2026" % __version__)

# A PAN per ISO/IEC 7812-1 is at most 19 digits.  The 2017 edition set the minimum
# at 10 digits (previously 8).  We accept 8..19 so that legacy numbers are still
# recognised; the per-scheme length rules below are what really matter.
PAN_MIN_LEN = 8
PAN_MAX_LEN = 19

# The 2017 edition of ISO/IEC 7812-1 extended the Issuer Identification Number from
# 6 to 8 digits (industry migration date: April 2022).  We report both.
IIN_LEN_LEGACY = 6
IIN_LEN = 8


# ---------------------------------------------------------------------------------
# ISO/IEC 7812 - Major Industry Identifier (first digit of the PAN)
# ---------------------------------------------------------------------------------
MII = {
    "0": "ISO/TC 68 and other industry assignments",
    "1": "Airlines",
    "2": "Airlines, financial and other future industry assignments",
    "3": "Travel and entertainment (Amex, Diners Club, JCB)",
    "4": "Banking and financial (Visa)",
    "5": "Banking and financial (Mastercard, Maestro)",
    "6": "Merchandising and banking/financial (Discover, UnionPay, Maestro)",
    "7": "Petroleum and other future industry assignments",
    "8": "Healthcare, telecommunications and other future industry assignments",
    "9": "National assignment (digits 2-4 are the ISO 3166-1 numeric country code)",
}

# ISO 3166-1 numeric codes used when the MII is 9 (national schemes such as
# Troy 9792 = Turkey, Napas 9704 = Vietnam, Humo 9860 = Uzbekistan).
ISO3166_NUMERIC = {
    "004": "Afghanistan", "012": "Algeria", "031": "Azerbaijan", "032": "Argentina",
    "036": "Australia", "040": "Austria", "048": "Bahrain", "050": "Bangladesh",
    "051": "Armenia", "056": "Belgium", "076": "Brazil", "100": "Bulgaria",
    "112": "Belarus", "124": "Canada", "144": "Sri Lanka", "152": "Chile",
    "156": "China", "158": "Taiwan", "170": "Colombia", "191": "Croatia",
    "196": "Cyprus", "203": "Czechia", "208": "Denmark", "231": "Ethiopia",
    "233": "Estonia", "246": "Finland", "250": "France", "268": "Georgia",
    "276": "Germany", "288": "Ghana", "300": "Greece", "344": "Hong Kong",
    "348": "Hungary", "356": "India", "360": "Indonesia", "364": "Iran",
    "368": "Iraq", "372": "Ireland", "376": "Israel", "380": "Italy",
    "392": "Japan", "398": "Kazakhstan", "400": "Jordan", "404": "Kenya",
    "410": "South Korea", "414": "Kuwait", "428": "Latvia", "440": "Lithuania",
    "458": "Malaysia", "470": "Malta", "484": "Mexico", "504": "Morocco",
    "512": "Oman", "524": "Nepal", "528": "Netherlands", "554": "New Zealand",
    "566": "Nigeria", "578": "Norway", "586": "Pakistan", "604": "Peru",
    "608": "Philippines", "616": "Poland", "620": "Portugal", "634": "Qatar",
    "642": "Romania", "643": "Russia", "682": "Saudi Arabia", "688": "Serbia",
    "702": "Singapore", "703": "Slovakia", "704": "Vietnam", "705": "Slovenia",
    "710": "South Africa", "724": "Spain", "752": "Sweden", "756": "Switzerland",
    "764": "Thailand", "784": "United Arab Emirates", "788": "Tunisia",
    "792": "Turkey", "800": "Uganda", "804": "Ukraine", "818": "Egypt",
    "826": "United Kingdom", "834": "Tanzania", "840": "United States",
    "860": "Uzbekistan",
}

# ---------------------------------------------------------------------------------
# ISO/IEC 7813 - Service code (track 1 / track 2 / EMV tag 57 "Track 2 Equivalent")
# ---------------------------------------------------------------------------------
SERVICE_CODE_1 = {   # interchange and technology
    "1": "International interchange OK",
    "2": "International interchange, use IC (chip) where feasible",
    "5": "National interchange only, except under bilateral agreement",
    "6": "National interchange only, except under bilateral agreement; use IC (chip) where feasible",
    "7": "No interchange except under bilateral agreement (closed loop)",
    "9": "Test",
}
SERVICE_CODE_2 = {   # authorisation processing
    "0": "Normal",
    "2": "Contact issuer via online means",
    "4": "Contact issuer via online means, except under bilateral agreement",
}
SERVICE_CODE_3 = {   # range of services and PIN requirements
    "0": "No restrictions, PIN required",
    "1": "No restrictions",
    "2": "Goods and services only (no cash)",
    "3": "ATM only, PIN required",
    "4": "Cash only",
    "5": "Goods and services only (no cash), PIN required",
    "6": "No restrictions, use PIN where feasible",
    "7": "Goods and services only (no cash), use PIN where feasible",
}


# ---------------------------------------------------------------------------------
# Card scheme / network table (public IIN ranges, ISO/IEC 7812 + scheme publications)
# ---------------------------------------------------------------------------------
# Each range is (low, high, catch_all).  low/high are prefix strings of equal length;
# a PAN matches when its first len(low) digits are between low and high (inclusive).
#
# Matching precedence when several ranges overlap:
#   1. longer (more specific) range wins   e.g. 622126-622925 Discover beats 62 UnionPay
#   2. a "catch-all" range (Maestro 50 / 56-69) loses to any range of the same length
#   3. an active scheme beats a defunct one  e.g. Maestro 6304 beats Laser 6304
#   4. table order
# All matches are reported ("also matches ...") so the ambiguity is never hidden.

class Scheme:
    __slots__ = ("key", "name", "ranges", "lengths", "luhn", "active", "note", "order")

    def __init__(self, key: str, name: str, ranges: Sequence[str], lengths: Iterable[int],
                 luhn: bool = True, active: bool = True, note: str = "",
                 catch_all: Sequence[str] = ()) -> None:
        self.key = key
        self.name = name
        self.ranges: List[Tuple[str, str, bool]] = [_parse_range(r) for r in ranges]
        self.ranges += [_parse_range(r, True) for r in catch_all]
        self.lengths = tuple(sorted(set(lengths)))
        self.luhn = luhn
        self.active = active
        self.note = note
        self.order = 0

    def __repr__(self) -> str:  # pragma: no cover - debugging aid
        return "Scheme(%s)" % self.key


def _parse_range(spec: str, catch_all: bool = False) -> Tuple[str, str, bool]:
    if "-" in spec:
        lo, hi = spec.split("-", 1)
    else:
        lo = hi = spec
    if len(lo) != len(hi) or not lo.isdigit() or not hi.isdigit() or lo > hi:
        raise ValueError("bad IIN range specification: %r" % spec)
    return lo, hi, catch_all


def _lengths(*spec: int) -> Tuple[int, ...]:
    return tuple(spec)


_L16 = _lengths(16)
_L16_19 = _lengths(16, 17, 18, 19)
_L12_19 = tuple(range(12, 20))

SCHEMES: List[Scheme] = [
    # --- global networks -----------------------------------------------------------
    Scheme("visa", "Visa", ["4"], (13, 16, 18, 19),
           note="MII 4; 16 digits is the norm, 13-digit numbers are legacy, 18/19 exist"),
    Scheme("visa_electron", "Visa Electron", ["4026", "417500", "4508", "4844", "4913", "4917"], _L16),
    Scheme("dankort", "Dankort", ["5019", "4571"], _L16,
           note="4571 is the co-badged Visa/Dankort range (Denmark)"),
    Scheme("mastercard", "Mastercard", ["2221-2720", "51-55"], _L16,
           note="2-series (2221-2720) issued since 2017; 54/55 also carries the former "
                "Diners Club US & Canada portfolio"),
    Scheme("maestro", "Maestro",
           ["5018", "5020", "5038", "5893", "6304", "6761", "6762", "6763"], _L12_19,
           catch_all=["50", "56-69"],
           note="debit; 50 and 56-69 are catch-all ranges shared with other schemes"),
    Scheme("maestro_uk", "Maestro UK (formerly Switch)", ["6759", "676770", "676774"], _L12_19),
    Scheme("amex", "American Express", ["34", "37"], (15,)),
    Scheme("diners", "Diners Club International", ["300-305", "3095", "36", "38-39"], (14, 15, 16, 17, 18, 19),
           note="36 is 14-19 digits, the other ranges 16-19; 300-305 was Carte Blanche"),
    Scheme("discover", "Discover", ["6011", "644-649", "65"], _L16_19),
    Scheme("discover_cup", "Discover (UnionPay co-processed)", ["622126-622925"], _L16_19,
           note="UnionPay-issued, routed via Discover network in the US"),
    Scheme("jcb", "JCB", ["3528-3589"], _L16_19),
    Scheme("jcb_legacy", "JCB (legacy 15-digit)", ["1800", "2131"], (15,), active=False),
    Scheme("unionpay", "China UnionPay", ["62", "81"], (14, 15, 16, 17, 18, 19),
           note="older UnionPay cards were issued without a Luhn check digit"),
    Scheme("t_union", "China T-Union", ["31"], (19,)),
    Scheme("uatp", "UATP (Universal Air Travel Plan)", ["1"], (15,), note="airline industry, MII 1"),
    Scheme("mir", "Mir", ["2200-2204"], _L16_19, note="Russia (NSPK)"),
    Scheme("borica", "BORICA", ["2205"], _L16, note="Bulgaria"),
    Scheme("troy", "Troy", ["9792", "650052", "650082-650083", "650092", "650161", "650170",
                            "650173", "650175", "650268", "650271", "650273-650274",
                            "650456-650457", "650836", "650846-650850", "650923", "650987",
                            "650990", "654997", "657366", "657998", "658758", "658767-658768"],
           _L16, note="Turkey; the 65 ranges are co-badged with Discover"),
    Scheme("rupay", "RuPay", ["60", "6521-6522", "81", "82", "508", "353", "356"], _L16,
           note="India (NPCI); 353/356 are RuPay-JCB and 65 RuPay-Discover co-brands"),
    Scheme("verve", "Verve", ["506099-506198", "507865-507964", "650002-650027"], (16, 18, 19),
           note="Nigeria (Interswitch)"),
    Scheme("elo", "Elo", ["401178", "401179", "431274", "438935", "451416", "457393", "457631",
                          "457632", "504175", "506699-506778", "509000-509999", "627780",
                          "636297", "636368", "650031-650033", "650035-650051", "650057-650081",
                          "650405-650439", "650485-650538", "650541-650598", "650700-650718",
                          "650720-650727", "650901-650978", "651652-651704", "655000-655019",
                          "655021-655058"], _L16, note="Brazil"),
    Scheme("hipercard", "Hipercard", ["606282"], (13, 16, 19), note="Brazil"),
    Scheme("hiper", "Hiper", ["637095", "637568", "637599", "637609", "637612",
                              "63737423", "63743358"], _L16, note="Brazil"),
    Scheme("naranja", "Naranja", ["402918", "527572", "589562"], _L16, note="Argentina"),
    Scheme("interpayment", "InterPayment", ["636"], _L16_19),
    Scheme("instapayment", "InstaPayment", ["637-639"], _L16),
    Scheme("ukrcard", "UkrCard", ["6040-6049"], _L16_19, note="Ukraine; precisely 60400100-60420099"),
    Scheme("nps", "NPS Pridnestrovie", ["6054740-6054744"], _L16),
    Scheme("lankapay", "LankaPay", ["357111"], _L16, note="Sri Lanka"),
    Scheme("uzcard", "UzCard", ["8600", "5614"], _L16, note="Uzbekistan"),
    Scheme("humo", "Humo", ["9860"], _L16, note="Uzbekistan"),
    Scheme("napas", "Napas", ["9704"], (16, 19), note="Vietnam"),
    Scheme("gpn", "GPN (Gerbang Pembayaran Nasional)", ["1946"], (16, 18, 19),
           note="Indonesia; GPN also rides on 50/56/58/60-63 which overlap Maestro"),
    # --- defunct schemes, kept so historical data can still be identified ---------
    Scheme("bankcard", "Bankcard", ["5610", "560221-560225"], _L16, active=False,
           note="Australia, withdrawn 2006"),
    Scheme("enroute", "Diners Club enRoute", ["2014", "2149"], (15,), luhn=False, active=False,
           note="withdrawn 1992; no Luhn check digit"),
    Scheme("laser", "Laser", ["6304", "6706", "6709", "6771"], _L16_19, active=False,
           note="Ireland, withdrawn 2014"),
    Scheme("solo", "Solo", ["6334", "6767"], (16, 18, 19), active=False, note="UK, withdrawn 2011"),
    Scheme("switch", "Switch", ["4903", "4905", "4911", "4936", "564182", "633110", "6333", "6759"],
           (16, 18, 19), active=False, note="UK, re-branded Maestro UK in 2002"),
]
for _i, _s in enumerate(SCHEMES):
    _s.order = _i
SCHEMES_BY_KEY: Dict[str, Scheme] = {s.key: s for s in SCHEMES}
del _i, _s


# ---------------------------------------------------------------------------------
# Luhn (ISO/IEC 7812-1 Annex B)
# ---------------------------------------------------------------------------------
_DOUBLED = (0, 2, 4, 6, 8, 1, 3, 5, 7, 9)          # digit -> contribution when doubled
_DOUBLED_INV = {v: i for i, v in enumerate(_DOUBLED)}  # contribution -> digit (bijective)


def _is_doubled(index: int, length: int) -> bool:
    """True when the digit at `index` (0-based from the left) is doubled."""
    return (length - index) % 2 == 0


def luhn_sum(pan: str, skip: Optional[int] = None) -> int:
    """Weighted Luhn sum of `pan`; `skip` is an index to leave out (an unknown digit)."""
    total = 0
    length = len(pan)
    for i, ch in enumerate(pan):
        if i == skip:
            continue
        d = ord(ch) - 48
        total += _DOUBLED[d] if _is_doubled(i, length) else d
    return total


def luhn_check(pan: str) -> bool:
    """Return True when `pan` (digits only) satisfies the Luhn formula."""
    if not pan or not pan.isdigit():
        return False
    return luhn_sum(pan) % 10 == 0


def luhn_solve(pan: str, index: int) -> str:
    """Return the single digit that makes `pan` Luhn-valid when placed at `index`."""
    need = (-luhn_sum(pan, skip=index)) % 10
    if _is_doubled(index, len(pan)):
        return str(_DOUBLED_INV[need])
    return str(need)


def luhn_check_digit(partial: str) -> str:
    """Compute the check digit to append to `partial` (digits without the check digit)."""
    return luhn_solve(partial + "0", len(partial))


# ---------------------------------------------------------------------------------
# Scheme identification
# ---------------------------------------------------------------------------------
class Match:
    __slots__ = ("scheme", "lo", "hi", "catch_all", "length_ok")

    def __init__(self, scheme: Scheme, lo: str, hi: str, catch_all: bool, length_ok: bool) -> None:
        self.scheme, self.lo, self.hi, self.catch_all, self.length_ok = scheme, lo, hi, catch_all, length_ok

    @property
    def range_text(self) -> str:
        return self.lo if self.lo == self.hi else "%s-%s" % (self.lo, self.hi)

    def sort_key(self) -> Tuple:
        # A range whose length rule fits always beats one that does not (a 19-digit 4571...
        # is a Visa, not a malformed Dankort); then the most specific range wins.
        return (not self.length_ok, -len(self.lo), self.catch_all, not self.scheme.active, self.scheme.order)


def _prefix_in_range(pan: str, lo: str, hi: str) -> bool:
    n = len(lo)
    return len(pan) >= n and lo <= pan[:n] <= hi


def identify(pan: str, schemes: Sequence[Scheme] = SCHEMES) -> List[Match]:
    """All schemes whose IIN ranges match `pan`, best match first."""
    found: List[Match] = []
    for s in schemes:
        for lo, hi, catch_all in s.ranges:
            if _prefix_in_range(pan, lo, hi):
                found.append(Match(s, lo, hi, catch_all, len(pan) in s.lengths))
                break    # one match per scheme is enough
    found.sort(key=Match.sort_key)
    return found


def prefix_can_match(prefix: str, lo: str, hi: str) -> bool:
    """Could a PAN starting with `prefix` still fall inside the range lo..hi?"""
    n, m = len(prefix), len(lo)
    if n >= m:
        return lo <= prefix[:m] <= hi
    pad = m - n
    return prefix + "0" * pad <= hi and prefix + "9" * pad >= lo


def select_schemes(brands: Optional[Iterable[str]] = None, include_inactive: bool = True,
                   include_catch_all: bool = True) -> List[Scheme]:
    """Resolve --brand / --active-only / --no-catch-all into the list of schemes to use."""
    wanted = None
    if brands:
        wanted = set()
        for b in brands:
            for part in b.split(","):
                part = part.strip().lower()
                if part:
                    wanted.add(part)
    out = []
    for s in SCHEMES:
        if not include_inactive and not s.active:
            continue
        if wanted is not None and not (s.key in wanted or s.name.lower() in wanted or any(
                s.key.startswith(w) or s.name.lower().startswith(w) for w in wanted)):
            continue
        if not include_catch_all and any(ca for _, _, ca in s.ranges):
            s = _without_catch_all(s)
            if not s.ranges:
                continue
        out.append(s)
    if wanted is not None and not out:
        raise ValueError("no scheme matches --brand %s (try --list-schemes)" % ",".join(sorted(wanted)))
    return out


def _without_catch_all(s: Scheme) -> Scheme:
    copy = Scheme(s.key, s.name, [], s.lengths, s.luhn, s.active, s.note)
    copy.ranges = [r for r in s.ranges if not r[2]]
    copy.order = s.order
    return copy


# ---------------------------------------------------------------------------------
# Optional external BIN / IIN database (CSV)  -> issuing bank, country, card type
# ---------------------------------------------------------------------------------
class BinDatabase:
    """
    Loads a CSV BIN list.  Works with the open "binlist-data" format
    (bin,brand,type,category,issuer,alpha_2,alpha_3,country,...) and with any CSV that
    has a header naming at least a start column (bin/iin/iin_start/prefix/start).
    Optional end column (iin_end/bin_end/end) turns a row into a range.
    """
    START = ("iin_start", "bin_start", "range_start", "bin", "iin", "prefix", "start")
    END = ("iin_end", "bin_end", "range_end", "end")
    FIELDS = {
        "brand": ("brand", "scheme", "network", "card_brand", "vendor"),
        "type": ("type", "card_type", "debit_credit"),
        "category": ("category", "level", "card_category"),
        "issuer": ("issuer", "bank", "bank_name", "issuer_name", "issuing_bank"),
        "country": ("country", "country_name", "alpha_2", "iso_country", "country_code", "alpha_3"),
    }

    def __init__(self, path: str) -> None:
        self.path = path
        self.exact: Dict[str, Dict[str, str]] = {}
        self.ranges: List[Tuple[str, str, Dict[str, str]]] = []
        self.rows = 0
        self._load()

    @staticmethod
    def _pick(header: Sequence[str], candidates: Sequence[str]) -> Optional[int]:
        lowered = [h.strip().lower() for h in header]
        for c in candidates:
            if c in lowered:
                return lowered.index(c)
        return None

    def _load(self) -> None:
        with open(self.path, newline="", encoding="utf-8-sig", errors="replace") as fh:
            sample = fh.read(4096)
            fh.seek(0)
            try:
                dialect = csv.Sniffer().sniff(sample, delimiters=",;\t|")
            except csv.Error:
                dialect = csv.excel
            reader = csv.reader(fh, dialect)
            header = next(reader, None)
            if header is None:
                raise ValueError("empty BIN database")
            i_start = self._pick(header, self.START)
            if i_start is None:
                raise ValueError("BIN database needs a start column (one of %s)" % ", ".join(self.START))
            i_end = self._pick(header, self.END)
            cols = {name: self._pick(header, cands) for name, cands in self.FIELDS.items()}
            for row in reader:
                if len(row) <= i_start:
                    continue
                start = re.sub(r"\D", "", row[i_start])
                if not start:
                    continue
                info = {name: (row[i].strip() if i is not None and i < len(row) else "")
                        for name, i in cols.items()}
                end = re.sub(r"\D", "", row[i_end]) if i_end is not None and i_end < len(row) else ""
                self.rows += 1
                if end and end != start:
                    n = max(len(start), len(end))
                    self.ranges.append((start.ljust(n, "0"), end.ljust(n, "9"), info))
                else:
                    self.exact[start] = info
        self.ranges.sort(key=lambda r: -len(r[0]))

    def lookup(self, pan: str) -> Optional[Dict[str, str]]:
        for n in range(min(len(pan), 11), 0, -1):          # longest exact prefix first
            info = self.exact.get(pan[:n])
            if info is not None:
                return dict(info, iin=pan[:n])
        for lo, hi, info in self.ranges:
            if _prefix_in_range(pan, lo, hi):
                return dict(info, iin="%s-%s" % (lo, hi))
        return None


# ---------------------------------------------------------------------------------
# Validation of a single PAN
# ---------------------------------------------------------------------------------
def normalise(text: str) -> str:
    """Strip the separators people type or paste between PAN digits."""
    return re.sub(r"[\s\-\._]", "", text.strip())


def mask_pan(pan: str) -> str:
    """PCI DSS style masking: first 6 and last 4 digits visible."""
    if len(pan) <= 10:
        return "*" * len(pan)
    return pan[:6] + "*" * (len(pan) - 10) + pan[-4:]


def group_pan(pan: str) -> str:
    """Print a PAN in readable groups (4-6-5 for 15-digit Amex style, 4-4-4-4.. otherwise)."""
    if len(pan) == 15:
        return "%s %s %s" % (pan[:4], pan[4:10], pan[10:])
    if len(pan) == 14:
        return "%s %s %s" % (pan[:4], pan[4:10], pan[10:])
    return " ".join(pan[i:i + 4] for i in range(0, len(pan), 4))


def mii_info(pan: str) -> Dict[str, str]:
    d = pan[:1]
    info = {"digit": d, "industry": MII.get(d, "unknown")}
    if d == "9" and len(pan) >= 4:
        cc = pan[1:4]
        info["country_code"] = cc
        info["country"] = ISO3166_NUMERIC.get(cc, "ISO 3166-1 numeric %s" % cc)
    return info


def validate_pan(pan: str, require_iin: bool = False, check_length: bool = True,
                 schemes: Sequence[Scheme] = SCHEMES, bin_db: Optional[BinDatabase] = None) -> Dict:
    """
    Full assessment of one PAN.  Returns a dict (JSON-friendly) with:
      pan, length, well_formed, luhn, mii, iin6, iin8, scheme(s), length_ok, issuer, valid, reasons
    """
    pan = normalise(pan)
    result: Dict = {
        "pan": pan, "length": len(pan), "well_formed": False, "luhn": False,
        "scheme": None, "scheme_key": None, "iin_range": None, "length_ok": None,
        "also_matches": [], "issuer": None, "valid": False, "reasons": [],
    }
    if not pan.isdigit():
        result["reasons"].append("contains non-digit characters")
        return result
    if not (PAN_MIN_LEN <= len(pan) <= PAN_MAX_LEN):
        result["reasons"].append("length %d outside %d-%d digits" % (len(pan), PAN_MIN_LEN, PAN_MAX_LEN))
    else:
        result["well_formed"] = True
    result["mii"] = mii_info(pan)
    result["iin6"] = pan[:IIN_LEN_LEGACY]
    result["iin8"] = pan[:IIN_LEN] if len(pan) >= IIN_LEN else None

    matches = identify(pan, schemes)
    best = matches[0] if matches else None
    luhn_expected = best.scheme.luhn if best else True
    result["luhn"] = luhn_check(pan)
    result["luhn_expected"] = luhn_expected

    if best:
        result["scheme"] = best.scheme.name
        result["scheme_key"] = best.scheme.key
        result["scheme_active"] = best.scheme.active
        result["scheme_note"] = best.scheme.note
        result["iin_range"] = best.range_text
        result["length_ok"] = best.length_ok
        result["expected_lengths"] = list(best.scheme.lengths)
        result["also_matches"] = [
            {"scheme": m.scheme.name, "scheme_key": m.scheme.key, "iin_range": m.range_text,
             "length_ok": m.length_ok, "active": m.scheme.active}
            for m in matches[1:]]
    if bin_db is not None:
        result["issuer"] = bin_db.lookup(pan)

    ok = result["well_formed"]
    if luhn_expected and not result["luhn"]:
        result["reasons"].append("Luhn check digit mismatch")
        ok = False
    if require_iin:
        if best is None:
            result["reasons"].append("no known IIN / scheme for this prefix")
            ok = False
        elif check_length and not best.length_ok:
            result["reasons"].append("%s numbers are %s digits, not %d" % (
                best.scheme.name, "/".join(map(str, best.scheme.lengths)), len(pan)))
            ok = False
    result["valid"] = ok
    return result


# ---------------------------------------------------------------------------------
# Generation of all valid PANs for a partially known number ("?" = unknown digit)
# ---------------------------------------------------------------------------------
def estimate_combinations(pattern: str) -> int:
    """Worst-case Luhn candidates: one unknown is solved directly, the rest enumerated."""
    k = pattern.count("?")
    return 10 ** max(k - 1, 0) if k else 0


def generate(pattern: str, iin_check: bool = True, check_length: bool = True,
             schemes: Sequence[Scheme] = SCHEMES) -> Iterator[str]:
    """
    Yield every Luhn-valid completion of `pattern` (digits and '?').

    The last unknown digit is always solved analytically from the Luhn formula
    (the doubling map is a bijection on 0..9) so only 10^(k-1) candidates are visited,
    and when the IIN check is on, prefixes that cannot match any eligible scheme are
    pruned before their remaining digits are enumerated.
    """
    pattern = normalise(pattern)
    if not re.fullmatch(r"[0-9?]+", pattern):
        raise ValueError("pattern may only contain digits and '?'")
    if not (PAN_MIN_LEN <= len(pattern) <= PAN_MAX_LEN):
        raise ValueError("pattern must be %d-%d characters long" % (PAN_MIN_LEN, PAN_MAX_LEN))
    unknown = [i for i, ch in enumerate(pattern) if ch == "?"]
    if not unknown:
        raise ValueError("pattern has no '?' characters")

    length = len(pattern)
    if iin_check:
        eligible = []
        for s in schemes:
            if check_length and length not in s.lengths:
                continue
            eligible.extend(s.ranges)
        if not eligible:
            return
        max_iin = max(len(lo) for lo, _, _ in eligible)
    else:
        eligible, max_iin = [], 0

    digits = list(pattern)
    last = unknown[-1]

    def feasible() -> bool:
        """Is the determined prefix (up to the first remaining '?') still matchable?"""
        try:
            n = digits.index("?")
        except ValueError:
            n = length
        prefix = "".join(digits[:min(n, max_iin)])
        return any(prefix_can_match(prefix, lo, hi) for lo, hi, _ in eligible)

    def accept(candidate: str) -> bool:
        # `eligible` already honours the length rule, so any hit is a valid scheme match.
        return (not iin_check) or any(_prefix_in_range(candidate, lo, hi) for lo, hi, _ in eligible)

    def rec(u: int) -> Iterator[str]:
        idx = unknown[u]
        if idx == last:
            digits[idx] = "0"
            digits[idx] = luhn_solve("".join(digits), idx)
            candidate = "".join(digits)
            if accept(candidate):
                yield candidate
            digits[idx] = "?"
            return
        for d in "0123456789":
            digits[idx] = d
            if iin_check and idx < max_iin and not feasible():
                continue
            yield from rec(u + 1)
        digits[idx] = "?"

    if iin_check and not feasible():
        return
    yield from rec(0)


# ---------------------------------------------------------------------------------
# Track 1 / track 2 / EMV tag 57 parsing (ISO/IEC 7813)
# ---------------------------------------------------------------------------------
_TRACK2_RE = re.compile(r"^;?(?P<pan>\d{8,19})(?P<sep>[=D])(?P<rest>[0-9=DF]*)\??(?P<lrc>.)?$")
_TRACK1_RE = re.compile(r"^%?(?P<fc>[A-Z])(?P<pan>\d{8,19})\^(?P<name>[^^]{0,26})\^(?P<rest>[^?]*)\??(?P<lrc>.)?$")


def decode_service_code(code: str) -> Dict[str, str]:
    code = (code or "").strip()
    if not re.fullmatch(r"\d{3}", code):
        return {"code": code, "valid": False}
    return {
        "code": code, "valid": True,
        "interchange": SERVICE_CODE_1.get(code[0], "reserved / unknown"),
        "authorisation": SERVICE_CODE_2.get(code[1], "reserved / unknown"),
        "services": SERVICE_CODE_3.get(code[2], "reserved / unknown"),
        "chip": code[0] in ("2", "6"),
        "international": code[0] in ("1", "2"),
        "pin_required": code[2] in ("0", "3", "5"),
    }


def _split_track_tail(rest: str) -> Tuple[Optional[str], Optional[str], str]:
    """Split 'YYMM' + 'SSS' + discretionary data; '=' / 'D' stands for an absent field."""
    pos = 0
    expiry = service = None
    if rest[pos:pos + 1] in ("=", "D"):
        pos += 1
    elif re.match(r"\d{4}", rest[pos:]):
        expiry = rest[pos:pos + 4]
        pos += 4
    if rest[pos:pos + 1] in ("=", "D"):
        pos += 1
    elif re.match(r"\d{3}", rest[pos:]):
        service = rest[pos:pos + 3]
        pos += 3
    return expiry, service, rest[pos:].rstrip("F")


def looks_like_track(text: str) -> bool:
    t = text.strip().upper()
    return bool(_TRACK2_RE.match(t) or _TRACK1_RE.match(t))


def parse_track(text: str) -> Dict:
    """Parse track 2 (';PAN=YYMMSSS...?'), EMV tag 57 ('PANDYYMMSSS...F') or track 1 format B."""
    raw = text.strip()
    t = raw.upper()
    m2 = _TRACK2_RE.match(t)
    out: Dict = {"input": raw, "track": None, "pan": None, "expiry": None, "service_code": None,
                 "discretionary": None, "name": None}
    if m2:
        out["track"] = "track2/EMV-57" if m2.group("sep") == "D" else "track2"
        out["pan"] = m2.group("pan")
        expiry, service, disc = _split_track_tail(m2.group("rest"))
    else:
        m1 = _TRACK1_RE.match(t)
        if not m1:
            raise ValueError("not recognised as track 1 / track 2 data")
        out["track"] = "track1 (format %s)" % m1.group("fc")
        out["pan"] = m1.group("pan")
        name = m1.group("name").strip()
        if "/" in name:
            surname, given = name.split("/", 1)
            name = "%s %s" % (given.strip(), surname.strip())
        out["name"] = name or None
        expiry, service, disc = _split_track_tail(m1.group("rest"))
    out["expiry"] = expiry
    if expiry:
        out["expiry_text"] = "20%s-%s (YYMM %s)" % (expiry[:2], expiry[2:], expiry)
    out["service_code"] = decode_service_code(service) if service else None
    out["discretionary"] = disc or None
    return out


# ---------------------------------------------------------------------------------
# Scanning arbitrary text for candidate PANs (data discovery)
# ---------------------------------------------------------------------------------
_SCAN_RE = re.compile(r"(?<![0-9])(?:[0-9][ \-]?){11,18}[0-9](?![0-9])")


def scan_text(lines: Iterable[str], require_iin: bool = True, check_length: bool = True,
              schemes: Sequence[Scheme] = SCHEMES, bin_db: Optional[BinDatabase] = None) -> Iterator[Dict]:
    """Yield validate_pan() results for every candidate PAN found in `lines`."""
    seen = set()
    for lineno, line in enumerate(lines, 1):
        for m in _SCAN_RE.finditer(line):
            pan = normalise(m.group(0))
            if len(pan) < 12 or len(pan) > PAN_MAX_LEN:
                continue
            if len(set(pan)) == 1:          # 0000000000000000 and friends
                continue
            r = validate_pan(pan, require_iin=require_iin, check_length=check_length,
                             schemes=schemes, bin_db=bin_db)
            if r["valid"]:
                r["line"] = lineno
                r["column"] = m.start() + 1
                r["duplicate"] = pan in seen
                seen.add(pan)
                yield r


# ---------------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------------
def _p(pan: str, masked: bool) -> str:
    return mask_pan(pan) if masked else pan


def print_validation(r: Dict, masked: bool = False, quiet: bool = False) -> None:
    pan = r["pan"]
    shown = _p(pan, masked)
    if quiet:
        print("%s %s" % ("[+] Valid PAN  " if r["valid"] else "[-] Invalid PAN", shown))
        return
    print("PAN:          %s  (%d digits)" % (group_pan(shown) if pan.isdigit() else shown, r["length"]))
    if not r["well_formed"] and not pan.isdigit():
        print("Result:       [-] Invalid PAN  (%s)" % "; ".join(r["reasons"]))
        return
    luhn_txt = "valid" if r["luhn"] else "INVALID"
    if not r.get("luhn_expected", True):
        luhn_txt += "  (scheme does not use a Luhn check digit)"
    print("Luhn:         %s" % luhn_txt)
    mii = r.get("mii") or {}
    line = "MII:          %s - %s" % (mii.get("digit"), mii.get("industry"))
    if mii.get("country"):
        line += " -> %s (%s)" % (mii["country"], mii["country_code"])
    print(line)
    iin = r["iin6"] + (" / " + r["iin8"] if r.get("iin8") else "")
    print("IIN:          %s  (6-digit / 8-digit)" % iin)
    if r["scheme"]:
        length_txt = "length OK" if r["length_ok"] else "length mismatch, expects %s" % "/".join(
            map(str, r.get("expected_lengths", [])))
        status = "" if r.get("scheme_active", True) else "  [defunct scheme]"
        print("Scheme:       %s  (IIN range %s; %s)%s" % (r["scheme"], r["iin_range"], length_txt, status))
        if r.get("scheme_note"):
            print("              %s" % r["scheme_note"])
        if r["also_matches"]:
            print("Also matches: %s" % ", ".join(
                "%s (%s%s)" % (a["scheme"], a["iin_range"], "" if a["active"] else ", defunct")
                for a in r["also_matches"]))
    else:
        print("Scheme:       unknown IIN (not in the built-in table)")
    iss = r.get("issuer")
    if iss:
        bits = [iss.get(k) for k in ("issuer", "brand", "type", "category", "country") if iss.get(k)]
        print("Issuer (DB):  %s  [%s]" % (" | ".join(bits), iss.get("iin")))
    if r["valid"]:
        print("Result:       [+] Valid PAN")
    else:
        print("Result:       [-] Invalid PAN  (%s)" % "; ".join(r["reasons"]))


def print_track(t: Dict, v: Dict, masked: bool = False) -> None:
    print("Track data:   %s" % t["track"])
    if t.get("name"):
        print("Cardholder:   %s" % t["name"])
    if t.get("expiry"):
        print("Expiry:       %s" % t["expiry_text"])
    sc = t.get("service_code")
    if sc:
        if sc.get("valid"):
            print("Service code: %s" % sc["code"])
            print("              1: %s" % sc["interchange"])
            print("              2: %s" % sc["authorisation"])
            print("              3: %s" % sc["services"])
        else:
            print("Service code: %s (malformed)" % sc["code"])
    if t.get("discretionary"):
        disc = t["discretionary"]
        print("Discretionary: %s" % ("*" * len(disc) if masked else disc))
    print_validation(v, masked=masked)


def print_scheme_table() -> None:
    print("%-42s %-7s %-12s %s" % ("Scheme (key)", "Active", "Lengths", "IIN ranges"))
    print("-" * 100)
    for s in SCHEMES:
        ranges = ", ".join(("%s*" if ca else "%s") % (lo if lo == hi else "%s-%s" % (lo, hi))
                           for lo, hi, ca in s.ranges)
        lengths = _compact_lengths(s.lengths)
        print("%-42s %-7s %-12s %s" % ("%s (%s)" % (s.name, s.key), "yes" if s.active else "no", lengths, ranges))
        if not s.luhn:
            print("%-42s %-7s %-12s %s" % ("", "", "", "(no Luhn check digit)"))
    print("\n* = catch-all range: any other scheme with a range of the same length takes precedence.")
    print("MII (first digit):")
    for d, txt in MII.items():
        print("  %s  %s" % (d, txt))


def _compact_lengths(lengths: Sequence[int]) -> str:
    out, i = [], 0
    while i < len(lengths):
        j = i
        while j + 1 < len(lengths) and lengths[j + 1] == lengths[j] + 1:
            j += 1
        out.append(str(lengths[i]) if i == j else "%d-%d" % (lengths[i], lengths[j]))
        i = j + 1
    return ",".join(out)


# ---------------------------------------------------------------------------------
# Command line
# ---------------------------------------------------------------------------------
def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="gLuhn.py",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        description=BANNER + "\n\n" + (
            "  PAN           Luhn check + scheme identification (add -i to also require a known IIN)\n"
            "  PAN with ?    generate every valid combination, e.g. 4542109540?18054\n"
            "  track data    e.g. ';4542109540018054=25121011234567890?' or EMV tag 57 with 'D'\n"),
        epilog=(
            "examples:\n"
            "  %(prog)s 4542109540018054\n"
            "  %(prog)s -i 3742109545565554\n"
            "  %(prog)s ???2109545565554\n"
            "  %(prog)s -b visa,mastercard ??42109545565554\n"
            "  %(prog)s --scan dump.txt --mask\n"
            "  %(prog)s --bin-db binlist-data.csv 4542109540018054\n"
            "  echo 4542109540018054 | %(prog)s -f -\n"
            "\n..based on gLuhn.py by @drgfragkos"))
    p.add_argument("pan", nargs="*", metavar="PAN", help="PAN, PAN pattern with '?', or track data")
    p.add_argument("-i", "--iin", action="store_true",
                   help="validation: also require a known IIN/scheme and a plausible length")
    p.add_argument("--no-iin", action="store_true",
                   help="generation/scan: do not filter candidates by IIN/scheme (Luhn only)")
    p.add_argument("--ignore-length", action="store_true",
                   help="do not treat a scheme length mismatch as a failure")
    p.add_argument("-b", "--brand", action="append", metavar="BRANDS",
                   help="restrict IIN matching to these schemes (comma separated keys or names)")
    p.add_argument("--active-only", action="store_true", help="ignore defunct schemes")
    p.add_argument("--no-catch-all", action="store_true",
                   help="ignore the broad Maestro catch-all ranges (50, 56-69)")
    p.add_argument("-f", "--file", metavar="FILE", help="read one PAN / pattern / track per line ('-' = stdin)")
    p.add_argument("--scan", metavar="FILE", help="scan a text file for candidate PANs ('-' = stdin)")
    p.add_argument("--bin-db", metavar="CSV", help="CSV BIN/IIN database for issuer lookup (e.g. binlist-data)")
    p.add_argument("--max", dest="max_combinations", type=int, default=10 ** 7, metavar="N",
                   help="refuse generation when more than N Luhn candidates must be visited (default 1e7)")
    p.add_argument("-m", "--mask", action="store_true", help="mask PANs in the output (first 6 / last 4)")
    p.add_argument("-j", "--json", action="store_true", help="JSON output")
    p.add_argument("-q", "--quiet", action="store_true", help="one line per PAN")
    p.add_argument("--list-schemes", action="store_true", help="print the built-in IIN table and exit")
    p.add_argument("-V", "--version", action="version", version=BANNER)
    return p


def _read_lines(path: str) -> List[str]:
    if path == "-":
        data = sys.stdin.read()
    else:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            data = fh.read()
    return data.splitlines()


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    if args.list_schemes:
        print_scheme_table()
        return 0

    try:
        schemes = select_schemes(args.brand, include_inactive=not args.active_only,
                                 include_catch_all=not args.no_catch_all)
    except ValueError as exc:
        parser.error(str(exc))
    bin_db = None
    if args.bin_db:
        try:
            bin_db = BinDatabase(args.bin_db)
        except (OSError, ValueError) as exc:
            parser.error("cannot load BIN database: %s" % exc)
        if not args.json and not args.quiet:
            print("[i] BIN database loaded: %d rows from %s" % (bin_db.rows, os.path.basename(args.bin_db)))
    check_length = not args.ignore_length

    inputs: List[str] = list(args.pan)
    if args.file:
        inputs += [ln for ln in _read_lines(args.file) if ln.strip() and not ln.lstrip().startswith("#")]

    json_out: List[Dict] = []
    any_valid = False
    any_input = False

    # ---- scan mode -----------------------------------------------------------------
    if args.scan:
        any_input = True
        lines = _read_lines(args.scan)
        hits = 0
        for r in scan_text(lines, require_iin=not args.no_iin, check_length=check_length,
                           schemes=schemes, bin_db=bin_db):
            hits += 1
            any_valid = True
            if args.json:
                r["pan"] = _p(r["pan"], args.mask)
                json_out.append(r)
            else:
                dup = "  (duplicate)" if r["duplicate"] else ""
                print("[+] line %-6d %-24s %s%s" % (r["line"], _p(r["pan"], args.mask),
                                                     r["scheme"] or "unknown scheme", dup))
        if not args.json:
            print("\nTotal candidate PANs found: %d" % hits)

    if not inputs and not args.scan:
        parser.print_help()
        return 2

    # ---- per input ------------------------------------------------------------------
    for raw in inputs:
        any_input = True
        text = raw.strip()
        if not text:
            continue
        clean = normalise(text)

        # Track data?
        if looks_like_track(text) and not clean.isdigit():
            try:
                t = parse_track(text)
            except ValueError as exc:
                print("[-] %s: %s" % (exc, text if not args.mask else "<track data>"))
                continue
            v = validate_pan(t["pan"], require_iin=args.iin, check_length=check_length,
                             schemes=schemes, bin_db=bin_db)
            any_valid |= v["valid"]
            if args.json:
                if args.mask:
                    t["pan"] = v["pan"] = mask_pan(v["pan"])
                    t["discretionary"] = None
                    t["input"] = "<masked>"
                json_out.append({"track": t, "validation": v})
            else:
                print_track(t, v, masked=args.mask)
                print()
            continue

        # Generation?
        if "?" in clean:
            if not re.fullmatch(r"[0-9?]+", clean):
                print("[-] Not a PAN pattern (digits and '?' only): %s" % text)
                continue
            est = estimate_combinations(clean)
            if est > args.max_combinations:
                print("[-] %s has %d unknown digits -> up to %d Luhn candidates; raise --max to allow"
                      % (clean, clean.count("?"), est))
                continue
            if not args.json:
                print("Attempting to generate up to %d PAN combinations for: %s%s" % (
                    est, clean, "" if args.no_iin else "  (IIN filtered)"))
            total = 0
            try:
                for pan in generate(clean, iin_check=not args.no_iin, check_length=check_length,
                                    schemes=schemes):
                    total += 1
                    any_valid = True
                    if args.json:
                        r = validate_pan(pan, require_iin=not args.no_iin, check_length=check_length,
                                         schemes=schemes, bin_db=bin_db)
                        r["pan"] = _p(pan, args.mask)
                        r["pattern"] = clean
                        json_out.append(r)
                    else:
                        matches = identify(pan, schemes)
                        label = matches[0].scheme.name if matches else "unknown scheme"
                        extra = ""
                        if bin_db is not None:
                            iss = bin_db.lookup(pan)
                            if iss:
                                extra = "  [%s]" % " | ".join(
                                    x for x in (iss.get("issuer"), iss.get("country")) if x)
                        print("[+] Valid PAN  %-20s %s%s" % (_p(pan, args.mask), label, extra))
            except ValueError as exc:
                print("[-] %s" % exc)
                continue
            if not args.json:
                print("\nTotal valid PAN generated: %d\n" % total)
            continue

        # Plain validation
        r = validate_pan(clean, require_iin=args.iin, check_length=check_length,
                         schemes=schemes, bin_db=bin_db)
        any_valid |= r["valid"]
        if args.json:
            r["pan"] = _p(r["pan"], args.mask)
            json_out.append(r)
        else:
            print_validation(r, masked=args.mask, quiet=args.quiet)
            if not args.quiet:
                print()

    if args.json:
        print(json.dumps(json_out if len(json_out) != 1 else json_out[0], indent=2))
    if not any_input:
        return 2
    return 0 if any_valid else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except BrokenPipeError:          # e.g. "gLuhn.py --list-schemes | head"
        try:
            sys.stdout = open(os.devnull, "w")
        finally:
            sys.exit(0)
    except KeyboardInterrupt:
        sys.exit(130)
