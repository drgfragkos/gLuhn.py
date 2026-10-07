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
  --scan PATH                          -> find candidate PANs in files, folders, archives
  --emv HEX                            -> decode EMV TLV data (tags, AID, track 2, CVM, TVR)

Everything here is pure standard-library Python 3 (no numpy any more).
The same functionality is available for Windows PowerShell 5.1 in gLuhn.ps1.
"""

from __future__ import annotations

import argparse
import csv
import datetime
import fnmatch
import hashlib
import io
import json
import os
import re
import sys
import zipfile
import zlib
from typing import Dict, Iterable, Iterator, List, Optional, Sequence, Tuple

__version__ = "1.1.0"
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
# Publicly documented test / sandbox card numbers (never real accounts).  Finding one
# in a data set usually means developer fixtures, not cardholder data.
# ---------------------------------------------------------------------------------
TEST_CARD_NUMBERS: Dict[str, str] = {}
for _src, _nums in (
    # numbers published by the schemes themselves (developer / integration documentation)
    ("Visa", ["4111111111111111", "4012888888881881", "4222222222222", "4917610000000000", "4484070000000000",
              "4462030000000000", "4444333322221111", "4012000033330026", "4508750015741019"]),
    ("Mastercard", ["5555555555554444", "5105105105105100", "2223003122003222", "2223000048400011",
                    "5425233430109903", "2222420000001113", "2222630000001125", "5454545454545454",
                    "5123450000000008", "2223000000000007", "5111111111111118", "2223000000000023",
                    "2223000048410010"]),
    ("American Express", ["378282246310005", "371449635398431", "378734493671000", "371881634498004",
                          "371881127160004", "371881245560002", "371881911767006"]),
    ("Discover", ["6011111111111117", "6011000990139424", "6011000991300009", "6011003179988686",
                  "6011963280099774", "6011601160116611"]),
    ("Diners Club", ["30569309025904", "38520000023237", "36227206271667", "36700102000000"]),
    ("JCB", ["3530111333300000", "3566002020360505", "3528000700000000"]),
    ("UnionPay", ["6200000000000005", "6200000000000047", "6205500000000000004"]),
    ("Maestro", ["6304000000000000", "6759649826438453", "6799990100000000019"]),
    ("Dankort", ["5019717010103742"]),
    # payment service providers' sandboxes
    ("Stripe", ["4242424242424242", "4000056655665556", "5200828282828210", "6011981111111113",
                "3056930009020004", "6555900000604105", "4000000000000002", "4000000000009995",
                "4000002500003155", "4000000000003220"]),
    ("Braintree", ["4005519200000004", "4009348888881881", "4012000077777777", "4217651111111119",
                   "4500600000000061", "36259600000004"]),
    ("Adyen", ["4111111145551142", "5555341244441115", "370000000000002", "3569990010095841",
               "4988438843884305", "4166676667666746", "4646464646464644", "5500000000000004",
               "2222400070000005", "5100290029002909", "5577000055770004", "6703444444444449",
               "6771830000000000006"]),
    ("Worldpay", ["4911830000000"]),
    ("Visa", ["4263982640269299", "4917484589897107", "4001919257537193", "4007702835532454"]),
):
    for _n in _nums:
        TEST_CARD_NUMBERS.setdefault(_n, _src)
del _src, _nums, _n

# Type Allocation Code prefixes seen on IMEIs (15-digit Luhn numbers that look like cards).
IMEI_TAC_PREFIXES = ("01", "35", "86", "99", "44", "45", "49", "50", "51", "52", "53", "54", "33")

# ---------------------------------------------------------------------------------
# EMV (chip) reference data: tag dictionary, AID registry and bit maps
# ---------------------------------------------------------------------------------
# tag -> (name, format)   formats: b binary, n numeric BCD, cn compressed numeric (F padded),
# an/ans text, date YYMMDD, amount n12, template (constructed), tags (list of tag/length pairs)
EMV_TAGS: Dict[str, Tuple[str, str]] = {
    "42": ("Issuer Identification Number (IIN)", "n"), "4F": ("Application Identifier (AID)", "b"),
    "50": ("Application Label", "ans"), "56": ("Track 1 Data", "ans"),
    "57": ("Track 2 Equivalent Data", "track2"), "5A": ("Application PAN", "cn"),
    "5F20": ("Cardholder Name", "ans"), "5F24": ("Application Expiration Date", "date"),
    "5F25": ("Application Effective Date", "date"), "5F28": ("Issuer Country Code", "country"),
    "5F2A": ("Transaction Currency Code", "n"), "5F2D": ("Language Preference", "an"),
    "5F30": ("Service Code", "service"), "5F34": ("Application PAN Sequence Number", "n"),
    "5F36": ("Transaction Currency Exponent", "n"), "5F50": ("Issuer URL", "ans"),
    "5F53": ("IBAN", "an"), "5F54": ("Bank Identifier Code (BIC)", "an"), "5F55": ("Issuer Country Code (alpha2)", "an"),
    "5F56": ("Issuer Country Code (alpha3)", "an"), "5F57": ("Account Type", "n"),
    "61": ("Application Template", "template"), "6F": ("FCI Template", "template"),
    "70": ("Record Template", "template"), "71": ("Issuer Script Template 1", "template"),
    "72": ("Issuer Script Template 2", "template"), "73": ("Directory Discretionary Template", "template"),
    "77": ("Response Message Template Format 2", "template"), "80": ("Response Message Template Format 1", "b"),
    "81": ("Amount, Authorised (Binary)", "b"), "82": ("Application Interchange Profile (AIP)", "aip"),
    "83": ("Command Template", "b"), "84": ("Dedicated File (DF) Name / AID", "b"),
    "86": ("Issuer Script Command", "b"), "87": ("Application Priority Indicator", "b"),
    "88": ("Short File Identifier (SFI)", "b"), "89": ("Authorisation Code", "an"),
    "8A": ("Authorisation Response Code", "an"), "8C": ("CDOL1", "tags"), "8D": ("CDOL2", "tags"),
    "8E": ("Cardholder Verification Method (CVM) List", "cvm"), "8F": ("CA Public Key Index", "b"),
    "90": ("Issuer Public Key Certificate", "b"), "91": ("Issuer Authentication Data", "b"),
    "92": ("Issuer Public Key Remainder", "b"), "93": ("Signed Static Application Data", "b"),
    "94": ("Application File Locator (AFL)", "afl"), "95": ("Terminal Verification Results (TVR)", "tvr"),
    "97": ("TDOL", "tags"), "98": ("TC Hash Value", "b"), "99": ("Transaction PIN Data", "b"),
    "9A": ("Transaction Date", "date"), "9B": ("Transaction Status Information (TSI)", "tsi"),
    "9C": ("Transaction Type", "txtype"), "9D": ("DDF Name", "b"),
    "9F01": ("Acquirer Identifier", "n"), "9F02": ("Amount, Authorised", "amount"),
    "9F03": ("Amount, Other", "amount"), "9F04": ("Amount, Other (Binary)", "b"),
    "9F05": ("Application Discretionary Data", "b"), "9F06": ("AID (terminal)", "b"),
    "9F07": ("Application Usage Control (AUC)", "auc"), "9F08": ("Application Version Number (card)", "b"),
    "9F09": ("Application Version Number (terminal)", "b"), "9F0B": ("Cardholder Name Extended", "ans"),
    "9F0D": ("Issuer Action Code - Default", "tvr"), "9F0E": ("Issuer Action Code - Denial", "tvr"),
    "9F0F": ("Issuer Action Code - Online", "tvr"), "9F10": ("Issuer Application Data", "b"),
    "9F11": ("Issuer Code Table Index", "n"), "9F12": ("Application Preferred Name", "ans"),
    "9F13": ("Last Online ATC Register", "b"), "9F14": ("Lower Consecutive Offline Limit", "b"),
    "9F15": ("Merchant Category Code", "n"), "9F16": ("Merchant Identifier", "ans"),
    "9F17": ("PIN Try Counter", "b"), "9F18": ("Issuer Script Identifier", "b"),
    "9F1A": ("Terminal Country Code", "country"), "9F1B": ("Terminal Floor Limit", "b"),
    "9F1C": ("Terminal Identification", "an"), "9F1D": ("Terminal Risk Management Data", "b"),
    "9F1E": ("Interface Device Serial Number", "an"), "9F1F": ("Track 1 Discretionary Data", "ans"),
    "9F20": ("Track 2 Discretionary Data", "cn"), "9F21": ("Transaction Time", "time"),
    "9F22": ("CA Public Key Index (terminal)", "b"), "9F23": ("Upper Consecutive Offline Limit", "b"),
    "9F26": ("Application Cryptogram", "b"), "9F27": ("Cryptogram Information Data (CID)", "cid"),
    "9F2D": ("ICC PIN Encipherment Public Key Certificate", "b"), "9F2E": ("ICC PIN Encipherment Public Key Exponent", "b"),
    "9F2F": ("ICC PIN Encipherment Public Key Remainder", "b"), "9F32": ("Issuer Public Key Exponent", "b"),
    "9F33": ("Terminal Capabilities", "termcap"), "9F34": ("CVM Results", "cvmres"),
    "9F35": ("Terminal Type", "termtype"), "9F36": ("Application Transaction Counter (ATC)", "b"),
    "9F37": ("Unpredictable Number", "b"), "9F38": ("PDOL", "tags"),
    "9F39": ("POS Entry Mode", "posentry"), "9F3A": ("Amount, Reference Currency", "b"),
    "9F3B": ("Application Reference Currency", "n"), "9F3C": ("Transaction Reference Currency Code", "n"),
    "9F3D": ("Transaction Reference Currency Exponent", "n"), "9F40": ("Additional Terminal Capabilities", "b"),
    "9F41": ("Transaction Sequence Counter", "n"), "9F42": ("Application Currency Code", "n"),
    "9F43": ("Application Currency Exponent", "n"), "9F44": ("Application Currency Exponent", "n"),
    "9F45": ("Data Authentication Code", "b"), "9F46": ("ICC Public Key Certificate", "b"),
    "9F47": ("ICC Public Key Exponent", "b"), "9F48": ("ICC Public Key Remainder", "b"),
    "9F49": ("DDOL", "tags"), "9F4A": ("Static Data Authentication Tag List", "b"),
    "9F4B": ("Signed Dynamic Application Data", "b"), "9F4C": ("ICC Dynamic Number", "b"),
    "9F4D": ("Log Entry", "b"), "9F4E": ("Merchant Name and Location", "ans"),
    "9F4F": ("Log Format", "tags"), "9F51": ("Application Currency Code (payment system)", "n"),
    "9F53": ("Transaction Category Code / Consecutive Transaction Limit", "b"),
    "9F5B": ("Issuer Script Results", "b"), "9F66": ("Terminal Transaction Qualifiers (TTQ)", "b"),
    "9F6B": ("Track 2 Data (contactless)", "track2"), "9F6C": ("Card Transaction Qualifiers (CTQ)", "b"),
    "9F6E": ("Form Factor Indicator / Third Party Data", "b"), "9F7C": ("Customer Exclusive Data", "b"),
    "A5": ("FCI Proprietary Template", "template"), "BF0C": ("FCI Issuer Discretionary Data", "template"),
    "DF8129": ("Outcome Parameter Set (kernel)", "b"),
}

# AID prefix -> (scheme, product).  Longest prefix wins.
EMV_AIDS: Dict[str, Tuple[str, str]] = {
    "A0000000031010": ("Visa", "Visa credit / debit"), "A0000000032010": ("Visa", "Visa Electron"),
    "A0000000032020": ("Visa", "V PAY"), "A0000000033010": ("Visa", "Visa Interlink"),
    "A0000000038010": ("Visa", "Visa Plus"), "A0000000980840": ("Visa", "Visa US common debit"),
    "A000000003": ("Visa", "Visa (other product)"),
    "A0000000041010": ("Mastercard", "Mastercard credit / debit"), "A0000000043060": ("Mastercard", "Maestro"),
    "A0000000046000": ("Mastercard", "Cirrus"), "A0000000042203": ("Mastercard", "Mastercard US Maestro common debit"),
    "A0000000045010": ("Mastercard", "Mastercard (test / specific)"), "A000000004": ("Mastercard", "Mastercard (other product)"),
    "A0000000050001": ("Mastercard", "Maestro UK"), "A0000000050002": ("Mastercard", "Solo (UK, defunct)"),
    "A00000002501": ("American Express", "American Express"), "A000000025": ("American Express", "American Express"),
    "A0000001523010": ("Discover", "Discover / Diners Club (D-PAS)"), "A0000001524010": ("Discover", "Discover US common debit"),
    "A0000003241010": ("Discover", "Discover (ZIP contactless)"), "A000000152": ("Discover", "Discover"),
    "A0000000651010": ("JCB", "JCB"), "A000000065": ("JCB", "JCB"),
    "A0000003330101": ("China UnionPay", "UnionPay debit"), "A0000003330102": ("China UnionPay", "UnionPay credit"),
    "A0000003330103": ("China UnionPay", "UnionPay quasi-credit"), "A0000003330106": ("China UnionPay", "UnionPay electronic cash"),
    "A000000333": ("China UnionPay", "UnionPay"),
    "A0000006581010": ("Mir", "Mir"), "A000000658": ("Mir", "Mir"),
    "A0000005241010": ("RuPay", "RuPay"), "A000000524": ("RuPay", "RuPay"),
    "A0000006723010": ("Troy", "Troy credit"), "A0000006723020": ("Troy", "Troy debit"), "A000000672": ("Troy", "Troy"),
    "A0000000421010": ("Cartes Bancaires", "CB credit / debit (France)"), "A0000000422010": ("Cartes Bancaires", "CB debit (France)"),
    "A0000000101030": ("girocard", "girocard (Germany)"), "A0000003591010028001": ("girocard", "girocard (Germany)"),
    "A0000001410001": ("PagoBANCOMAT", "PagoBANCOMAT (Italy)"), "A0000001211010": ("Dankort", "Dankort (Denmark)"),
    "A0000002771010": ("Interac", "Interac (Canada)"), "A0000004540010": ("eftpos", "eftpos savings (Australia)"),
    "A0000004540011": ("eftpos", "eftpos cheque (Australia)"), "A0000006200620": ("DNA", "DNA (Indonesia)"),
    "A0000004951010": ("Elo", "Elo (Brazil)"), "A0000003710001": ("Verve", "Verve (Nigeria)"),
}

TVR_BITS = (  # byte, bit (8..1), meaning
    (1, 8, "Offline data authentication was not performed"), (1, 7, "SDA failed"),
    (1, 6, "ICC data missing"), (1, 5, "Card appears on terminal exception file"),
    (1, 4, "DDA failed"), (1, 3, "CDA failed"), (1, 2, "SDA selected"),
    (2, 8, "ICC and terminal have different application versions"), (2, 7, "Expired application"),
    (2, 6, "Application not yet effective"), (2, 5, "Requested service not allowed for card product"),
    (2, 4, "New card"),
    (3, 8, "Cardholder verification was not successful"), (3, 7, "Unrecognised CVM"),
    (3, 6, "PIN try limit exceeded"), (3, 5, "PIN entry required and PIN pad not present or not working"),
    (3, 4, "PIN entry required, PIN pad present, but PIN was not entered"), (3, 3, "Online PIN entered"),
    (4, 8, "Transaction exceeds floor limit"), (4, 7, "Lower consecutive offline limit exceeded"),
    (4, 6, "Upper consecutive offline limit exceeded"), (4, 5, "Transaction selected randomly for online processing"),
    (4, 4, "Merchant forced transaction online"),
    (5, 8, "Default TDOL used"), (5, 7, "Issuer authentication failed"),
    (5, 6, "Script processing failed before final GENERATE AC"), (5, 5, "Script processing failed after final GENERATE AC"),
)
TSI_BITS = (
    (1, 8, "Offline data authentication was performed"), (1, 7, "Cardholder verification was performed"),
    (1, 6, "Card risk management was performed"), (1, 5, "Issuer authentication was performed"),
    (1, 4, "Terminal risk management was performed"), (1, 3, "Script processing was performed"),
)
AIP_BITS = (
    (1, 7, "SDA supported"), (1, 6, "DDA supported"), (1, 5, "Cardholder verification is supported"),
    (1, 4, "Terminal risk management is to be performed"), (1, 3, "Issuer authentication is supported"),
    (1, 1, "CDA supported"), (2, 8, "Reserved for payment systems (EMV mode / contactless)"),
)
AUC_BITS = (
    (1, 8, "Valid for domestic cash transactions"), (1, 7, "Valid for international cash transactions"),
    (1, 6, "Valid for domestic goods"), (1, 5, "Valid for international goods"),
    (1, 4, "Valid for domestic services"), (1, 3, "Valid for international services"),
    (1, 2, "Valid at ATMs"), (1, 1, "Valid at terminals other than ATMs"),
    (2, 8, "Domestic cashback allowed"), (2, 7, "International cashback allowed"),
)
CVM_CODES = {
    0x00: "Fail CVM processing", 0x01: "Plaintext PIN verified by ICC", 0x02: "Enciphered PIN verified online",
    0x03: "Plaintext PIN by ICC and signature", 0x04: "Enciphered PIN verified by ICC",
    0x05: "Enciphered PIN by ICC and signature", 0x1E: "Signature (paper)", 0x1F: "No CVM required",
}
CVM_CONDITIONS = {
    0x00: "Always", 0x01: "If unattended cash", 0x02: "If not unattended cash, not manual cash, not purchase with cashback",
    0x03: "If terminal supports the CVM", 0x04: "If manual cash", 0x05: "If purchase with cashback",
    0x06: "If transaction is in the application currency and under X", 0x07: "If transaction is in the application currency and over X",
    0x08: "If transaction is in the application currency and under Y", 0x09: "If transaction is in the application currency and over Y",
}
TRANSACTION_TYPES = {"00": "Goods and services (purchase)", "01": "Cash", "09": "Purchase with cashback",
                     "20": "Refund", "30": "Balance inquiry", "40": "Transfer"}
TERMINAL_TYPES = {"11": "Financial institution, attended, online only", "12": "Financial institution, attended, offline with online capability",
                  "13": "Financial institution, attended, offline only", "14": "Financial institution, unattended, online only",
                  "15": "Financial institution, unattended, offline with online capability", "16": "Financial institution, unattended, offline only",
                  "21": "Merchant, attended, online only", "22": "Merchant, attended, offline with online capability",
                  "23": "Merchant, attended, offline only", "24": "Merchant, unattended, online only",
                  "25": "Merchant, unattended, offline with online capability", "26": "Merchant, unattended, offline only",
                  "34": "Cardholder, unattended, online only", "35": "Cardholder, unattended, offline with online capability",
                  "36": "Cardholder, unattended, offline only"}
POS_ENTRY_MODES = {"00": "Unknown", "01": "Manual key entry", "02": "Magnetic stripe", "05": "Integrated circuit card (contact chip)",
                   "07": "Contactless chip (EMV mode)", "80": "Fallback to magnetic stripe", "90": "Magnetic stripe, full track read",
                   "91": "Contactless magnetic stripe mode", "95": "Chip read, CVV may be unreliable"}


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
# External IIN table (JSON) to extend or override the built-in schemes without code changes
# ---------------------------------------------------------------------------------
def load_iin_table(path: str) -> List[Scheme]:
    """
    JSON: {"schemes": [{"key": "...", "name": "...", "ranges": ["4", "51-55"], "lengths": [16],
                        "catch_all": [], "luhn": true, "active": true, "note": ""}], "replace": false}
    A scheme whose key matches a built-in one overrides it; others are appended.
    "replace": true discards the built-in table altogether.
    """
    with open(path, "r", encoding="utf-8-sig") as fh:
        data = json.load(fh)
    entries = data.get("schemes", data if isinstance(data, list) else [])
    extra: List[Scheme] = []
    for e in entries:
        if not e.get("key") or not e.get("ranges"):
            raise ValueError("every scheme needs a key and at least one range: %r" % e)
        extra.append(Scheme(str(e["key"]), str(e.get("name", e["key"])), [str(r) for r in e["ranges"]],
                            [int(n) for n in e.get("lengths", range(PAN_MIN_LEN, PAN_MAX_LEN + 1))],
                            bool(e.get("luhn", True)), bool(e.get("active", True)), str(e.get("note", "")),
                            [str(r) for r in e.get("catch_all", [])]))
    if isinstance(data, dict) and data.get("replace"):
        merged = extra
    else:
        by_key = {s.key: s for s in extra}
        merged = [by_key.pop(s.key, s) for s in SCHEMES] + [s for s in extra if s.key in by_key]
    for i, s in enumerate(merged):
        s.order = i
    return merged


def apply_scheme_table(schemes: Sequence[Scheme]) -> None:
    """Make `schemes` the global table (used by --iin-table before anything else runs)."""
    SCHEMES[:] = list(schemes)
    SCHEMES_BY_KEY.clear()
    SCHEMES_BY_KEY.update({s.key: s for s in SCHEMES})


# ---------------------------------------------------------------------------------
# Online IIN lookup (opt-in).  Only the IIN (6 or 8 digits) ever leaves the machine.
# ---------------------------------------------------------------------------------
DEFAULT_LOOKUP_URL = "https://lookup.binlist.net/{iin}"
BINLIST_DATA_URL = "https://raw.githubusercontent.com/iannuttall/binlist-data/master/binlist-data.csv"
DEFAULT_BIN_DB_PATH = os.path.join(os.path.expanduser("~"), ".gluhn", "binlist-data.csv")


class OnlineLookup:
    """
    Queries a BIN lookup web service (binlist.net format by default) with the IIN only.
    Results are cached per IIN for the lifetime of the process; failures never raise.
    """

    def __init__(self, url_template: str = DEFAULT_LOOKUP_URL, timeout: float = 8.0,
                 digits: Sequence[int] = (8, 6)) -> None:
        if "{iin}" not in url_template:
            raise ValueError("lookup URL must contain {iin}")
        self.url_template = url_template
        self.timeout = timeout
        self.digits = tuple(digits)
        self.cache: Dict[str, Dict] = {}
        self.requests = 0

    def _fetch(self, iin: str) -> Tuple[Optional[Dict], Optional[str]]:
        import urllib.error
        import urllib.request
        url = self.url_template.replace("{iin}", iin)
        req = urllib.request.Request(url, headers={"Accept-Version": "3", "Accept": "application/json",
                                                   "User-Agent": "gLuhn/%s" % __version__})
        self.requests += 1
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                body = resp.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as exc:
            return None, "HTTP %d" % exc.code
        except Exception as exc:                       # network errors, timeouts, bad URLs
            return None, str(exc.__class__.__name__ + ": " + str(exc))
        try:
            return json.loads(body), None
        except ValueError:
            return None, "response is not JSON"

    @staticmethod
    def _flatten(data: Dict) -> Dict:
        """binlist.net v3 layout -> flat summary; unknown layouts are passed through."""
        out: Dict = {}
        if not isinstance(data, dict):
            return {"raw": data}
        for key in ("scheme", "type", "brand", "prepaid"):
            if data.get(key) not in (None, ""):
                out[key] = data[key]
        country = data.get("country") or {}
        if isinstance(country, dict):
            if country.get("name"):
                out["country"] = country["name"]
            if country.get("alpha2"):
                out["country_code"] = country["alpha2"]
            if country.get("currency"):
                out["currency"] = country["currency"]
        elif country:
            out["country"] = country
        bank = data.get("bank") or {}
        if isinstance(bank, dict):
            for key in ("name", "url", "phone", "city"):
                if bank.get(key):
                    out["bank_" + key] = bank[key]
        elif bank:
            out["bank_name"] = bank
        number = data.get("number") or {}
        if isinstance(number, dict) and number.get("length"):
            out["length"] = number["length"]
        if not out:
            out["raw"] = data
        return out

    def lookup(self, pan: str) -> Dict:
        for n in self.digits:
            iin = pan[:n]
            if len(iin) < n:
                continue
            if iin in self.cache:
                return self.cache[iin]
            data, error = self._fetch(iin)
            if data is not None:
                result = dict(self._flatten(data), iin=iin, source=self.url_template.split("/")[2])
                self.cache[iin] = result
                return result
            if error and not error.startswith("HTTP 404"):
                result = {"iin": iin, "error": error}
                self.cache[iin] = result
                return result
        result = {"iin": pan[:min(self.digits)], "error": "not found"}
        self.cache[result["iin"]] = result
        return result


def download_bin_db(path: str = DEFAULT_BIN_DB_PATH, url: str = BINLIST_DATA_URL, timeout: float = 60.0) -> int:
    """Download the open binlist-data CSV to `path`; returns the number of bytes written."""
    import urllib.request
    os.makedirs(os.path.dirname(os.path.abspath(path)) or ".", exist_ok=True)
    req = urllib.request.Request(url, headers={"User-Agent": "gLuhn/%s" % __version__})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        data = resp.read()
    if not data.lstrip().lower().startswith(b"bin"):
        raise ValueError("downloaded file does not look like a BIN CSV (no 'bin' header)")
    tmp = path + ".part"
    with open(tmp, "wb") as fh:
        fh.write(data)
    os.replace(tmp, path)
    return len(data)


# ---------------------------------------------------------------------------------
# Issuer repository (repository/bin-repository.json via repository/gluhn_repository.py)
# ---------------------------------------------------------------------------------
REPOSITORY_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "repository")
DEFAULT_REPOSITORY_PATH = os.path.join(REPOSITORY_DIR, "bin-repository.json")


def load_repository(path: Optional[str] = None):
    """
    Load the shared issuer repository through the gluhn_repository module.  Returns the
    BinRepository object; raises OSError / ValueError / ImportError when it cannot.
    """
    import importlib.util
    module_path = os.path.join(REPOSITORY_DIR, "gluhn_repository.py")
    spec = importlib.util.spec_from_file_location("gluhn_repository", module_path)
    if spec is None or spec.loader is None:
        raise ImportError("repository module not found: %s" % module_path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.BinRepository(path or DEFAULT_REPOSITORY_PATH)


def repository_line(info: Optional[Dict]) -> str:
    bits = [info.get(k) for k in ("issuer", "brand", "type", "category", "country") if info.get(k)]
    return "%s  [BIN %s]" % (" | ".join(bits) if bits else "no issuer name on record", info["range"])


# ---------------------------------------------------------------------------------
# Validation of a single PAN
# ---------------------------------------------------------------------------------
def normalise(text: str) -> str:
    """Strip the separators people type or paste between PAN digits."""
    return re.sub(r"[\s\-\._]", "", text.strip())


MASK_STYLES = ("6-4", "8-4", "last4", "full")


def mask_pan(pan: str, style: str = "6-4") -> str:
    """
    PCI DSS masking.  "6-4": first 6 / last 4 (always allowed).  "8-4": first 8 / last 4,
    which PCI DSS v4 permits for PANs of 16 digits or more (shorter PANs fall back to 6-4).
    "last4": only the last four.  "full": every digit.
    """
    n = len(pan)
    if style == "full":
        return "*" * n
    if style == "last4":
        return ("*" * (n - 4) + pan[-4:]) if n > 4 else "*" * n
    head = 8 if (style == "8-4" and n >= 16) else 6
    if n <= head + 4:
        return "*" * n
    return pan[:head] + "*" * (n - head - 4) + pan[-4:]


def expiry_status(yymm: Optional[str], today: Optional[datetime.date] = None) -> Optional[Dict]:
    """Sanity check of a YYMM expiry: valid / expired / far-future / invalid."""
    if not yymm:
        return None
    if not re.fullmatch(r"\d{4}", yymm):
        return {"status": "invalid", "text": "expiry %r is not YYMM" % yymm}
    yy, mm = int(yymm[:2]), int(yymm[2:])
    if not 1 <= mm <= 12:
        return {"status": "invalid", "text": "month %02d does not exist" % mm}
    today = today or datetime.date.today()
    year = 2000 + yy
    iso = "%04d-%02d" % (year, mm)
    if (year, mm) < (today.year, today.month):
        return {"status": "expired", "text": "expired (%s is in the past)" % iso, "iso": iso}
    if year > today.year + 10:
        return {"status": "far-future", "text": "implausibly far in the future (%s), test or fabricated data?" % iso, "iso": iso}
    return {"status": "valid", "text": "valid until end of %s" % iso, "iso": iso}


def is_test_card(pan: str) -> Optional[str]:
    """Return the source that publishes `pan` as a test number, or None."""
    return TEST_CARD_NUMBERS.get(pan)


def lookalike_hint(pan: str) -> Optional[Dict[str, str]]:
    """Other Luhn-checked identifiers that are easily mistaken for a PAN."""
    if len(pan) == 15 and pan[:2] in IMEI_TAC_PREFIXES and luhn_check(pan):
        return {"kind": "IMEI", "detail": "TAC %s, serial %s" % (pan[:8], pan[8:14]),
                "text": "15-digit Luhn number with a mobile equipment TAC prefix: likely an IMEI, not a card"}
    if len(pan) >= 18 and pan.startswith("89") and luhn_check(pan):
        return {"kind": "ICCID", "detail": "MII 89 telecom, country %s" % pan[2:5],
                "text": "18-20 digit Luhn number starting 89: likely a SIM ICCID, not a card"}
    return None


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
                 schemes: Sequence[Scheme] = SCHEMES, bin_db: Optional[BinDatabase] = None,
                 lookup: Optional["OnlineLookup"] = None, repository=None) -> Dict:
    """
    Full assessment of one PAN.  Returns a dict (JSON-friendly) with:
      pan, length, well_formed, luhn, mii, iin6, iin8, scheme(s), length_ok, issuer,
      repository, test_card, lookalike, lookup, valid, reasons
    """
    pan = normalise(pan)
    # key order matches gLuhn.ps1 so that JSON output is identical on both implementations
    result: Dict = {
        "pan": pan, "length": len(pan), "well_formed": False, "luhn": False, "luhn_expected": True,
        "mii": None, "iin6": None, "iin8": None,
        "scheme": None, "scheme_key": None, "scheme_active": True, "scheme_note": "", "iin_range": None,
        "length_ok": None, "expected_lengths": [], "also_matches": [], "issuer": None, "repository": None,
        "test_card": None, "lookalike": None, "lookup": None, "valid": False, "reasons": [],
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
    if repository is not None:
        result["repository"] = repository.lookup(pan)
    result["test_card"] = is_test_card(pan)
    result["lookalike"] = lookalike_hint(pan)
    if lookup is not None and result["well_formed"]:
        result["lookup"] = lookup.lookup(pan)

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
        out["expiry_status"] = expiry_status(expiry)
    out["service_code"] = decode_service_code(service) if service else None
    out["discretionary"] = disc or None
    out["discretionary_hints"] = discretionary_hints(disc)
    # Any track data carries sensitive authentication data (PCI DSS v4 requirement 3.3.1).
    out["sad_warning"] = ("Full track data is sensitive authentication data: it must not be "
                          "retained after authorisation (PCI DSS v4 req. 3.3.1).")
    return out


def discretionary_hints(disc: Optional[str]) -> Optional[Dict[str, str]]:
    """
    Typical (issuer specific, not standardised) layout of track 2 discretionary data:
    PVKI (1 digit), PVV (4 digits), CVV1 / CVC1 (3 digits), then issuer padding.
    """
    if not disc or len(disc) < 8 or not disc[:8].isdigit():
        return None
    return {"pvki": disc[0], "pvv": disc[1:5], "cvv1": disc[5:8],
            "note": "typical layout only; issuers may place PVKI/PVV/CVV1 differently"}


# ---------------------------------------------------------------------------------
# Scanning files, folders and archives for candidate PANs (data discovery)
# ---------------------------------------------------------------------------------
_SCAN_RE = re.compile(r"(?<![0-9])(?:[0-9][ \-]?){11,18}[0-9](?![0-9])")
_CONTEXT_RE = re.compile(
    r"\b(card|cards|pan|visa|mastercard|master\s*card|amex|american\s+express|discover|diners|jcb|"
    r"maestro|unionpay|cc|ccnum|cc_?number|credit|debit|card_?number|card_?no|acct|account|exp|expiry|"
    r"expires|expiration|valid\s*thru|cvv|cvc|cvv2|cvc2|cid|track|bin|iin|payment|cardholder|"
    r"kartennummer|carte|tarjeta|numero)\b", re.I)
_EXPIRY_NEAR_RE = re.compile(r"(?<!\d)(0[1-9]|1[0-2])\s*[/\-]\s*(\d{2}|20\d{2})(?!\d)")
_CVV_NEAR_RE = re.compile(r"(?<![0-9])[0-9]{3,4}(?![0-9])")
ARCHIVE_EXTENSIONS = (".zip", ".jar", ".war", ".docx", ".xlsx", ".pptx", ".odt", ".ods", ".odp", ".xlsm", ".docm")
CONTEXT_WINDOW = 48
CONFIDENCE_LEVELS = (("HIGH", 70), ("MEDIUM", 45), ("LOW", 0))


def _has_monotone_run(pan: str, length: int = 6) -> bool:
    """True for keyboard-walk numbers: 1234567..., 9876543..., 1111111..."""
    for i in range(len(pan) - length + 1):
        chunk = pan[i:i + length]
        diffs = {ord(b) - ord(a) for a, b in zip(chunk, chunk[1:])}
        if len(diffs) == 1 and diffs.pop() in (-1, 0, 1):
            return True
    return False


def score_hit(line: str, start: int, end: int, result: Dict) -> Tuple[int, str, List[str]]:
    """
    Confidence that the match at line[start:end] is a real cardholder PAN.
    Returns (score 0-100, level, signals).  Signals explain the score.
    """
    pan = result["pan"]
    score = 40
    signals: List[str] = []
    iin_range = result.get("iin_range") or ""
    digits_in_range = len(iin_range.split("-")[0])
    if result.get("scheme") and digits_in_range >= 4:
        score += 15
        signals.append("specific IIN")
    elif result.get("scheme") and digits_in_range <= 2:
        catch_all = any(ca and _prefix_in_range(pan, lo, hi)
                        for sc in SCHEMES if sc.key == result.get("scheme_key") for lo, hi, ca in sc.ranges)
        if catch_all:
            score -= 15
            signals.append("catch-all IIN")
    if not result.get("scheme"):
        score -= 20
        signals.append("unknown IIN")
    raw = line[start:end]
    if re.search(r"\d[ \-]\d", raw) and len(re.findall(r"[ \-]", raw)) >= 2:
        score += 10
        signals.append("grouped digits")
    if _has_monotone_run(pan):
        score -= 25
        signals.append("sequential/repeated digits")
    if result.get("test_card"):
        score -= 25
        signals.append("known test number (%s)" % result["test_card"])
    if result.get("lookalike"):
        score -= 30
        signals.append("looks like %s" % result["lookalike"]["kind"])
    before = line[max(0, start - CONTEXT_WINDOW):start]
    after = line[end:end + CONTEXT_WINDOW]
    context = before + " " + after
    if _CONTEXT_RE.search(context):
        score += 20
        signals.append("card keyword nearby")
    if _EXPIRY_NEAR_RE.search(after) or _EXPIRY_NEAR_RE.search(before):
        score += 10
        signals.append("expiry nearby (possible SAD)")
    elif _CVV_NEAR_RE.search(after) and re.search(r"\b(cvv|cvc|cid|cvv2|cvc2|sec)\b", context, re.I):
        score += 5
        signals.append("CVV-like value nearby (possible SAD)")
    score = max(0, min(100, score))
    level = next(name for name, floor in CONFIDENCE_LEVELS if score >= floor)
    return score, level, signals


def scan_text(lines: Iterable[str], require_iin: bool = True, check_length: bool = True,
              schemes: Sequence[Scheme] = SCHEMES, bin_db: Optional[BinDatabase] = None,
              min_score: int = 0, source: str = "<text>", repository=None) -> Iterator[Dict]:
    """Yield validate_pan() results (plus line, column, score, confidence, signals) for each hit."""
    seen = set()
    for lineno, line in enumerate(lines, 1):
        for m in _SCAN_RE.finditer(line):
            pan = normalise(m.group(0))
            if len(pan) < 12 or len(pan) > PAN_MAX_LEN:
                continue
            if len(set(pan)) == 1:          # 0000000000000000 and friends
                continue
            r = validate_pan(pan, require_iin=require_iin, check_length=check_length,
                             schemes=schemes, bin_db=bin_db, repository=repository)
            if not r["valid"]:
                continue
            score, level, signals = score_hit(line, m.start(), m.end(), r)
            if score < min_score:
                continue
            r["source"] = source
            r["line"] = lineno
            r["column"] = m.start() + 1
            r["duplicate"] = pan in seen
            r["score"] = score
            r["confidence"] = level
            r["signals"] = signals
            seen.add(pan)
            yield r


def decode_bytes(data: bytes) -> str:
    """Decode a file for scanning: BOMs, UTF-16 without BOM (NUL pattern), UTF-8, else Latin-1."""
    if data.startswith(b"\xef\xbb\xbf"):
        return data[3:].decode("utf-8", "replace")
    if data.startswith(b"\xff\xfe"):
        return data[2:].decode("utf-16-le", "replace")
    if data.startswith(b"\xfe\xff"):
        return data[2:].decode("utf-16-be", "replace")
    sample = data[:4096]
    if sample:
        odd_nul = sample[1::2].count(0)
        even_nul = sample[0::2].count(0)
        half = max(1, len(sample) // 2)
        if odd_nul > half * 0.6 and even_nul < half * 0.1:
            return data.decode("utf-16-le", "replace")
        if even_nul > half * 0.6 and odd_nul < half * 0.1:
            return data.decode("utf-16-be", "replace")
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        return data.decode("latin-1")


def pdf_text(data: bytes) -> str:
    """
    Best-effort text recovery from a PDF without external libraries: inflate FlateDecode
    streams and collect the string operands of text operators.  Fragmented or encoded
    fonts can defeat this; it is a triage aid, not a parser.
    """
    chunks: List[str] = []
    for m in re.finditer(rb"stream\r?\n(.*?)\r?\nendstream", data, re.S):
        raw = m.group(1)
        content = None
        for decoder in (lambda b: zlib.decompress(b), lambda b: zlib.decompress(b, -15), lambda b: b):
            try:
                content = decoder(raw)
                break
            except Exception:
                continue
        if not content:
            continue
        text = content.decode("latin-1")
        if "Tj" in text or "TJ" in text:
            line_parts: List[str] = []
            for op in re.finditer(r"\[(.*?)\]\s*TJ|\((.*?)(?<!\\)\)\s*Tj|(T\*|Td|TD|Tm|ET)", text, re.S):
                if op.group(1) is not None:
                    pieces = re.findall(r"\((.*?)(?<!\\)\)", op.group(1), re.S)
                    line_parts.append("".join(pieces))
                elif op.group(2) is not None:
                    line_parts.append(op.group(2))
                else:
                    if line_parts:
                        chunks.append("".join(line_parts))
                        line_parts = []
            if line_parts:
                chunks.append("".join(line_parts))
        else:
            chunks.append(text)
    chunks.append(data.decode("latin-1"))        # uncompressed objects and metadata
    out = "\n".join(chunks)
    return out.replace("\\(", "(").replace("\\)", ")")


class ScanSource:
    __slots__ = ("name", "lines", "sha256")

    def __init__(self, name: str, lines: List[str], sha256: Optional[str]) -> None:
        self.name, self.lines, self.sha256 = name, lines, sha256


def _iter_bytes_source(name: str, data: bytes, archives: bool, depth: int, max_bytes: int) -> Iterator[ScanSource]:
    lower = name.lower()
    if archives and depth < 3 and (lower.endswith(ARCHIVE_EXTENSIONS) or data[:4] == b"PK\x03\x04"):
        try:
            with zipfile.ZipFile(io.BytesIO(data)) as zf:
                for info in zf.infolist():
                    if info.is_dir() or info.file_size > max_bytes:
                        continue
                    try:
                        member = zf.read(info)
                    except Exception:
                        continue
                    yield from _iter_bytes_source("%s!%s" % (name, info.filename), member, archives, depth + 1, max_bytes)
            return
        except zipfile.BadZipFile:
            pass
    if lower.endswith(".gz") and data[:2] == b"\x1f\x8b":
        try:
            data = zlib.decompress(data, 47)
            name = name[:-3]
            lower = name.lower()
        except Exception:
            pass
    if lower.endswith(".pdf") or data[:5] == b"%PDF-":
        text = pdf_text(data)
    else:
        text = decode_bytes(data)
    yield ScanSource(name, text.splitlines(), hashlib.sha256(data).hexdigest())


def iter_scan_sources(path: str, recursive: bool = True, include: Sequence[str] = (),
                      exclude: Sequence[str] = (), max_bytes: int = 64 * 1024 * 1024,
                      archives: bool = True, skipped: Optional[List[str]] = None) -> Iterator[ScanSource]:
    """Yield ScanSource objects for '-' (stdin), a file, or every file under a folder."""
    def wanted(fname: str) -> bool:
        base = os.path.basename(fname)
        if include and not any(fnmatch.fnmatch(base, g) for g in include):
            return False
        return not any(fnmatch.fnmatch(base, g) or fnmatch.fnmatch(fname, g) for g in exclude)

    if path == "-":
        yield ScanSource("<stdin>", sys.stdin.read().splitlines(), None)
        return
    if os.path.isdir(path):
        for root, dirs, files in os.walk(path):
            dirs[:] = sorted(d for d in dirs if not any(fnmatch.fnmatch(d, g) for g in exclude))
            for fname in sorted(files):
                full = os.path.join(root, fname)
                if wanted(full):
                    yield from iter_scan_sources(full, recursive, include, exclude, max_bytes, archives, skipped)
            if not recursive:
                break
        return
    try:
        size = os.path.getsize(path)
        if size > max_bytes:
            if skipped is not None:
                skipped.append("%s (%.1f MB > limit)" % (path, size / 1048576.0))
            return
        with open(path, "rb") as fh:
            data = fh.read()
    except OSError as exc:
        if skipped is not None:
            skipped.append("%s (%s)" % (path, exc.strerror or exc))
        return
    yield from _iter_bytes_source(path, data, archives, 0, max_bytes)


# ---------------------------------------------------------------------------------
# EMV TLV decoding (chip data: ICC records, GPO/GENERATE AC responses, tag dumps)
# ---------------------------------------------------------------------------------
def _clean_hex(text: str) -> str:
    if text.startswith("@"):
        with open(text[1:], "r", encoding="utf-8", errors="replace") as fh:
            text = fh.read()
    text = re.sub(r"0x", "", text, flags=re.I)
    text = re.sub(r"[^0-9A-Fa-f]", "", text)
    if len(text) % 2:
        raise ValueError("odd number of hex digits")
    return text.upper()


def _bits(value: bytes, table: Sequence[Tuple[int, int, str]]) -> List[str]:
    out = []
    for byte_no, bit, meaning in table:
        if len(value) >= byte_no and value[byte_no - 1] & (1 << (bit - 1)):
            out.append(meaning)
    return out


def aid_info(aid_hex: str) -> Optional[Dict[str, str]]:
    aid = aid_hex.upper()
    best = ""
    for prefix in EMV_AIDS:
        if aid.startswith(prefix) and len(prefix) > len(best):
            best = prefix
    if not best:
        return None
    scheme, product = EMV_AIDS[best]
    return {"aid": aid, "rid": aid[:10], "scheme": scheme, "product": product}


def _decode_cvm(value: bytes) -> Dict:
    if len(value) < 8:
        return {"error": "CVM list shorter than 8 bytes"}
    rules = []
    for i in range(8, len(value) - 1, 2):
        b1, b2 = value[i], value[i + 1]
        rules.append({
            "cvm": CVM_CODES.get(b1 & 0x3F, "RFU / proprietary (0x%02X)" % (b1 & 0x3F)),
            "condition": CVM_CONDITIONS.get(b2, "RFU (0x%02X)" % b2),
            "on_failure": "apply next rule" if b1 & 0x40 else "fail cardholder verification",
        })
    return {"amount_x": int.from_bytes(value[0:4], "big"), "amount_y": int.from_bytes(value[4:8], "big"), "rules": rules}


def _decode_tags_list(value: bytes) -> List[str]:
    out, i = [], 0
    while i < len(value):
        start = i
        first = value[i]
        i += 1
        if first & 0x1F == 0x1F:
            while i < len(value) and value[i] & 0x80:
                i += 1
            i += 1
        tag = value[start:i].hex().upper()
        length = value[i] if i < len(value) else 0
        i += 1
        out.append("%s (%s) len %d" % (tag, EMV_TAGS.get(tag, ("?",))[0], length))
    return out


def decode_tag_value(tag: str, value: bytes) -> Dict:
    name, fmt = EMV_TAGS.get(tag, ("Unknown / proprietary tag", "b"))
    hexval = value.hex().upper()
    d: Dict = {"hex": hexval}
    try:
        if fmt in ("n", "cn"):
            digits = hexval.rstrip("F") if fmt == "cn" else hexval
            d["value"] = digits
            if tag == "5A":
                d["pan"] = digits
            if tag == "5F34":
                d["value"] = str(int(hexval or "0"))
        elif fmt in ("an", "ans"):
            d["value"] = value.decode("latin-1").strip()
        elif fmt == "date":
            if len(hexval) == 6 and hexval.isdigit():
                d["value"] = "20%s-%s-%s" % (hexval[0:2], hexval[2:4], hexval[4:6])
                if tag == "5F24":
                    d["expiry_status"] = expiry_status(hexval[:4])
            else:
                d["value"] = hexval
        elif fmt == "time":
            d["value"] = "%s:%s:%s" % (hexval[0:2], hexval[2:4], hexval[4:6]) if len(hexval) == 6 else hexval
        elif fmt == "amount":
            d["value"] = "%d.%02d" % (int(hexval) // 100, int(hexval) % 100) if hexval.isdigit() else hexval
        elif fmt == "country":
            d["value"] = ISO3166_NUMERIC.get(hexval[-3:], "ISO 3166-1 numeric %s" % hexval[-3:])
        elif fmt == "service":
            d["service_code"] = decode_service_code(hexval[-3:])
            d["value"] = hexval[-3:]
        elif fmt == "track2":
            t2 = hexval.rstrip("F")
            d["value"] = t2
            try:
                d["track2"] = parse_track(t2)
            except ValueError:
                pass
        elif fmt == "aip":
            d["flags"] = _bits(value, AIP_BITS)
        elif fmt == "tvr":
            d["flags"] = _bits(value, TVR_BITS)
        elif fmt == "tsi":
            d["flags"] = _bits(value, TSI_BITS)
        elif fmt == "auc":
            d["flags"] = _bits(value, AUC_BITS)
        elif fmt == "cvm":
            d["cvm_list"] = _decode_cvm(value)
        elif fmt == "afl":
            entries = []
            for i in range(0, len(value) - 3, 4):
                entries.append("SFI %d records %d-%d (%d used for offline auth)" % (
                    value[i] >> 3, value[i + 1], value[i + 2], value[i + 3]))
            d["entries"] = entries
        elif fmt == "tags":
            d["entries"] = _decode_tags_list(value)
        elif fmt == "cid":
            kind = {0: "AAC (declined)", 1: "TC (approved offline)", 2: "ARQC (go online)", 3: "RFU"}[value[0] >> 6]
            d["value"] = kind + ("; advice required" if value[0] & 0x08 else "")
        elif fmt == "txtype":
            d["value"] = TRANSACTION_TYPES.get(hexval, "type %s" % hexval)
        elif fmt == "termtype":
            d["value"] = TERMINAL_TYPES.get(hexval, "type %s" % hexval)
        elif fmt == "posentry":
            d["value"] = POS_ENTRY_MODES.get(hexval, "mode %s" % hexval)
        elif fmt == "cvmres":
            if len(value) >= 3:
                d["value"] = "%s; %s; result %s" % (
                    CVM_CODES.get(value[0] & 0x3F, "0x%02X" % value[0]), CVM_CONDITIONS.get(value[1], "0x%02X" % value[1]),
                    {0: "unknown", 1: "failed", 2: "successful"}.get(value[2], "0x%02X" % value[2]))
        elif fmt == "termcap" and len(value) >= 3:
            caps = []
            caps += _bits(value, ((1, 8, "manual key entry"), (1, 7, "magnetic stripe"), (1, 6, "IC with contacts")))
            caps += _bits(value, ((2, 8, "plaintext PIN for ICC verification"), (2, 7, "enciphered PIN for online verification"),
                                  (2, 6, "signature"), (2, 5, "enciphered PIN for offline verification"), (2, 4, "no CVM required")))
            caps += _bits(value, ((3, 8, "SDA"), (3, 7, "DDA"), (3, 6, "card capture"), (3, 4, "CDA")))
            d["flags"] = caps
        if tag in ("4F", "84", "9F06"):
            info = aid_info(hexval)
            if info:
                d["aid"] = info
        if tag == "5F2A" or tag == "9F42":
            d["value"] = hexval[-3:]
    except Exception as exc:                    # never let a malformed value stop the dump
        d["error"] = "could not decode: %s" % exc
    return d


def parse_tlv(data: bytes, depth: int = 0) -> List[Dict]:
    """Parse BER-TLV as used by EMV (multi-byte tags, long-form lengths, nested templates)."""
    out: List[Dict] = []
    i, n = 0, len(data)
    while i < n:
        if data[i] in (0x00, 0xFF):              # padding between objects
            i += 1
            continue
        start = i
        first = data[i]
        i += 1
        if first & 0x1F == 0x1F:
            while i < n and data[i] & 0x80:
                i += 1
            i += 1
        tag = data[start:i].hex().upper()
        if i >= n:
            raise ValueError("truncated tag %s" % tag)
        length = data[i]
        i += 1
        if length & 0x80:
            count = length & 0x7F
            if count == 0 or count > 4 or i + count > n:
                raise ValueError("bad length encoding after tag %s" % tag)
            length = int.from_bytes(data[i:i + count], "big")
            i += count
        value = data[i:i + length]
        i += length
        node: Dict = {"tag": tag, "name": EMV_TAGS.get(tag, ("Unknown / proprietary tag", "b"))[0],
                      "length": length, "truncated": len(value) < length}
        if first & 0x20 and depth < 8:
            try:
                node["children"] = parse_tlv(value, depth + 1)
            except ValueError:
                node["children"] = []
                node["decoded"] = {"hex": value.hex().upper(), "error": "constructed tag without valid TLV content"}
        else:
            node["decoded"] = decode_tag_value(tag, value)
        out.append(node)
    return out


def _walk_tlv(nodes: List[Dict]) -> Iterator[Dict]:
    for node in nodes:
        yield node
        for child in node.get("children", []):
            yield from _walk_tlv([child])


def decode_emv(text: str, schemes: Sequence[Scheme] = SCHEMES, bin_db: Optional[BinDatabase] = None,
               require_iin: bool = False, check_length: bool = True,
               lookup: Optional[OnlineLookup] = None, repository=None) -> Dict:
    """Decode a hex TLV dump and summarise what matters for card identification."""
    data = bytes.fromhex(_clean_hex(text))
    nodes = parse_tlv(data)
    summary: Dict = {"pan": None, "expiry": None, "psn": None, "cardholder": None, "aid": None,
                     "label": None, "issuer_country": None, "service_code": None, "track2": None,
                     "aip": None, "cvm_list": None, "tvr": None, "tsi": None, "auc": None, "cid": None,
                     "warnings": []}
    for node in _walk_tlv(nodes):
        tag, dec = node["tag"], node.get("decoded") or {}
        if tag == "5A" and dec.get("pan"):
            summary["pan"] = dec["pan"]
        elif tag == "5F24":
            summary["expiry"] = dec.get("value")
            summary["expiry_status"] = dec.get("expiry_status")
        elif tag == "5F34":
            summary["psn"] = dec.get("value")
        elif tag == "5F20" and dec.get("value"):
            summary["cardholder"] = dec["value"]
        elif tag in ("4F", "84", "9F06") and dec.get("aid") and not summary["aid"]:
            summary["aid"] = dec["aid"]
        elif tag in ("50", "9F12") and dec.get("value") and not summary["label"]:
            summary["label"] = dec["value"]
        elif tag == "5F28":
            summary["issuer_country"] = dec.get("value")
        elif tag == "5F30":
            summary["service_code"] = dec.get("service_code")
        elif tag in ("57", "9F6B") and dec.get("track2") and not summary["track2"]:
            summary["track2"] = dec["track2"]
        elif tag == "82":
            summary["aip"] = dec.get("flags")
        elif tag == "8E":
            summary["cvm_list"] = dec.get("cvm_list")
        elif tag == "95":
            summary["tvr"] = dec.get("flags")
        elif tag == "9B":
            summary["tsi"] = dec.get("flags")
        elif tag == "9F07":
            summary["auc"] = dec.get("flags")
        elif tag == "9F27":
            summary["cid"] = dec.get("value")
    if not summary["pan"] and summary["track2"]:
        summary["pan"] = summary["track2"]["pan"]
    if summary["track2"] and not summary["service_code"]:
        summary["service_code"] = summary["track2"].get("service_code")
    if summary["pan"]:
        summary["validation"] = validate_pan(summary["pan"], require_iin=require_iin, check_length=check_length,
                                             schemes=schemes, bin_db=bin_db, lookup=lookup, repository=repository)
        v = summary["validation"]
        if summary["aid"] and v.get("scheme") and summary["aid"]["scheme"].split(" ")[0].lower() not in v["scheme"].lower() \
                and not any(summary["aid"]["scheme"].split(" ")[0].lower() in a["scheme"].lower() for a in v.get("also_matches", [])):
            summary["warnings"].append("AID says %s but the PAN prefix says %s" % (summary["aid"]["scheme"], v["scheme"]))
    if summary["track2"] or summary["pan"]:
        summary["warnings"].append("Chip data with PAN / track 2 equivalent is cardholder data; "
                                   "the cryptograms and PIN related tags are sensitive authentication data.")
    return {"tags": nodes, "summary": summary, "bytes": len(data)}


# ---------------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------------
class OutputOptions:
    def __init__(self, masked: bool = False, mask_style: str = "6-4", quiet: bool = False) -> None:
        self.masked, self.mask_style, self.quiet = masked, mask_style, quiet

    def pan(self, pan: str) -> str:
        return mask_pan(pan, self.mask_style) if self.masked else pan


def print_validation(r: Dict, opts: OutputOptions) -> None:
    pan = r["pan"]
    shown = opts.pan(pan)
    if opts.quiet:
        extra = ""
        if r.get("test_card"):
            extra = "  (test number: %s)" % r["test_card"]
        print("%s %s%s" % ("[+] Valid PAN  " if r["valid"] else "[-] Invalid PAN", shown, extra))
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
    rp = r.get("repository")
    if rp:
        print("Issuer (repo): %s" % repository_line(rp))
        if rp.get("url") or rp.get("phone"):
            print("              %s" % " ".join(x for x in (rp.get("url"), rp.get("phone")) if x))
    lk = r.get("lookup")
    if lk:
        if lk.get("error"):
            print("Lookup:       %s (IIN %s): %s" % (lk.get("source", "online"), lk.get("iin"), lk["error"]))
        else:
            bits = [str(lk[k]) for k in ("bank_name", "scheme", "brand", "type", "country") if lk.get(k)]
            if lk.get("prepaid"):
                bits.append("prepaid")
            print("Lookup:       %s  [%s, IIN %s]" % (" | ".join(bits) or "no details", lk.get("source"), lk.get("iin")))
            if lk.get("bank_url") or lk.get("bank_phone"):
                print("              %s" % " ".join(x for x in (lk.get("bank_url"), lk.get("bank_phone")) if x))
    if r.get("test_card"):
        print("Test number:  published test / sandbox card number (%s), not a real account" % r["test_card"])
    if r.get("lookalike"):
        print("Look-alike:   %s (%s)" % (r["lookalike"]["text"], r["lookalike"]["detail"]))
    if r["valid"]:
        print("Result:       [+] Valid PAN")
    else:
        print("Result:       [-] Invalid PAN  (%s)" % "; ".join(r["reasons"]))


def print_track(t: Dict, v: Dict, opts: OutputOptions) -> None:
    print("Track data:   %s" % t["track"])
    if t.get("name"):
        print("Cardholder:   %s" % t["name"])
    if t.get("expiry"):
        st = t.get("expiry_status") or {}
        print("Expiry:       %s%s" % (t["expiry_text"], "  [%s]" % st["text"] if st.get("status") not in (None, "valid") else ""))
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
        print("Discretionary: %s" % ("*" * len(disc) if opts.masked else disc))
        hints = t.get("discretionary_hints")
        if hints and not opts.masked:
            print("              typical layout: PVKI %s, PVV %s, CVV1/CVC1 %s (%s)" % (
                hints["pvki"], hints["pvv"], hints["cvv1"], hints["note"]))
    if t.get("sad_warning"):
        print("Attention:    %s" % t["sad_warning"])
    print_validation(v, opts)


def print_emv(e: Dict, opts: OutputOptions) -> None:
    def show(nodes: List[Dict], indent: int) -> None:
        for node in nodes:
            pad = "  " * indent
            dec = node.get("decoded") or {}
            head = "%s%-8s %-44s len %3d" % (pad, node["tag"], node["name"][:44], node["length"])
            if "children" in node:
                print(head)
                show(node["children"], indent + 1)
                continue
            val = dec.get("value")
            if node["tag"] in ("5A",) and val:
                val = opts.pan(val)
            if node["tag"] in ("57", "9F6B") and val and opts.masked:
                val = "<masked track 2>"
            if val is None:
                val = dec.get("hex", "")
                if opts.masked and node["tag"] in ("9F20", "9F1F", "56"):
                    val = "<masked>"
                if len(val) > 48:
                    val = val[:48] + "..."
            print("%s  %s" % (head, val))
            for key in ("flags", "entries"):
                for item in dec.get(key) or []:
                    print("%s           - %s" % (pad, item))
            if dec.get("aid"):
                print("%s           - %s: %s" % (pad, dec["aid"]["scheme"], dec["aid"]["product"]))
            if dec.get("service_code") and dec["service_code"].get("valid"):
                scd = dec["service_code"]
                print("%s           - %s / %s / %s" % (pad, scd["interchange"], scd["authorisation"], scd["services"]))
            if dec.get("expiry_status") and dec["expiry_status"]["status"] != "valid":
                print("%s           - %s" % (pad, dec["expiry_status"]["text"]))
            if dec.get("cvm_list") and dec["cvm_list"].get("rules"):
                for rule in dec["cvm_list"]["rules"]:
                    print("%s           - %s | %s | else %s" % (pad, rule["cvm"], rule["condition"], rule["on_failure"]))
            if dec.get("error"):
                print("%s           ! %s" % (pad, dec["error"]))

    print("EMV TLV:      %d bytes, %d top-level objects" % (e["bytes"], len(e["tags"])))
    show(e["tags"], 0)
    s = e["summary"]
    print("")
    if s.get("aid"):
        print("Application:  %s - %s  (AID %s)" % (s["aid"]["scheme"], s["aid"]["product"], s["aid"]["aid"]))
    if s.get("label"):
        print("Label:        %s" % s["label"])
    if s.get("cardholder"):
        print("Cardholder:   %s" % s["cardholder"])
    if s.get("expiry"):
        st = s.get("expiry_status") or {}
        print("Expiry:       %s%s" % (s["expiry"], "  [%s]" % st["text"] if st.get("status") not in (None, "valid") else ""))
    if s.get("psn"):
        print("PAN seq. no:  %s" % s["psn"])
    if s.get("issuer_country"):
        print("Issuer ctry:  %s" % s["issuer_country"])
    for w in s.get("warnings", []):
        print("Attention:    %s" % w)
    if s.get("validation"):
        print_validation(s["validation"], opts)
    elif not s.get("pan"):
        print("Result:       no PAN (tag 5A / 57 / 9F6B) in this data")


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


SCAN_CSV_FIELDS = ("source", "line", "column", "pan", "scheme", "iin_range", "confidence", "score",
                   "signals", "test_card", "lookalike", "issuer", "duplicate", "sha256")


def scan_row(r: Dict, opts: OutputOptions) -> Dict:
    iss = r.get("issuer") or {}
    if not iss and r.get("repository"):
        rp = r["repository"]
        iss = {"issuer": rp.get("issuer") or "", "country": rp.get("country") or ""}
    return {
        "source": r.get("source"), "line": r.get("line"), "column": r.get("column"),
        "pan": opts.pan(r["pan"]), "scheme": r.get("scheme") or "", "iin_range": r.get("iin_range") or "",
        "confidence": r.get("confidence"), "score": r.get("score"), "signals": "; ".join(r.get("signals", [])),
        "test_card": r.get("test_card") or "", "lookalike": (r.get("lookalike") or {}).get("kind", ""),
        "issuer": " | ".join(x for x in (iss.get("issuer"), iss.get("country")) if x),
        "duplicate": r.get("duplicate", False), "sha256": r.get("sha256") or "",
    }


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
            "  track data    e.g. ';4542109540018054=25121011234567890?' or EMV tag 57 with 'D'\n"
            "  --scan PATH   find PANs in a file, a folder (recursive), ZIP/Office archives, PDFs\n"
            "  --emv HEX     decode EMV TLV data (hex string or @file)\n"),
        epilog=(
            "examples:\n"
            "  %(prog)s 4542109540018054\n"
            "  %(prog)s -i 3742109545565554\n"
            "  %(prog)s ???2109545565554\n"
            "  %(prog)s -b visa,mastercard ??42109545565554\n"
            "  %(prog)s --scan ./share --format csv --mask > findings.csv\n"
            "  %(prog)s --bin-db auto --update-bin-db 4542109540018054\n"
            "  %(prog)s --lookup 4542109540018054        (sends only the IIN to the lookup service)\n"
            "  %(prog)s --emv 5A0845421095400180545F24032512315F340101\n"
            "  echo 4542109540018054 | %(prog)s -f -\n"
            "\n..based on gLuhn.py by @drgfragkos"))
    p.add_argument("pan", nargs="*", metavar="PAN", help="PAN, PAN pattern with '?', or track data")
    g = p.add_argument_group("validation / generation")
    g.add_argument("-i", "--iin", action="store_true",
                   help="validation: also require a known IIN/scheme and a plausible length")
    g.add_argument("--no-iin", action="store_true",
                   help="generation/scan: do not filter candidates by IIN/scheme (Luhn only)")
    g.add_argument("--ignore-length", action="store_true",
                   help="do not treat a scheme length mismatch as a failure")
    g.add_argument("-b", "--brand", action="append", metavar="BRANDS",
                   help="restrict IIN matching to these schemes (comma separated keys or names)")
    g.add_argument("--active-only", action="store_true", help="ignore defunct schemes")
    g.add_argument("--no-catch-all", action="store_true",
                   help="ignore the broad Maestro catch-all ranges (50, 56-69)")
    g.add_argument("--iin-table", metavar="JSON", help="extend/override the built-in scheme table from a JSON file")
    g.add_argument("--max", dest="max_combinations", type=int, default=10 ** 7, metavar="N",
                   help="refuse generation when more than N Luhn candidates must be visited (default 1e7)")
    g = p.add_argument_group("input")
    g.add_argument("-f", "--file", metavar="FILE", help="read one PAN / pattern / track per line ('-' = stdin)")
    g.add_argument("--scan", metavar="PATH", help="scan a file, folder or archive for candidate PANs ('-' = stdin)")
    g.add_argument("--emv", metavar="HEX", help="decode EMV TLV hex data ('@file' reads it from a file)")
    g.add_argument("--include", action="append", metavar="GLOB", default=[], help="scan only matching file names (repeatable)")
    g.add_argument("--exclude", action="append", metavar="GLOB", default=[], help="skip matching files/folders (repeatable)")
    g.add_argument("--no-recursive", action="store_true", help="scan only the top level of a folder")
    g.add_argument("--no-archives", action="store_true", help="do not look inside ZIP / Office files")
    g.add_argument("--max-file-size", type=float, default=64.0, metavar="MB", help="skip files larger than MB (default 64)")
    g.add_argument("--min-score", type=int, default=0, metavar="N", help="scan: report only hits with confidence score >= N")
    g = p.add_argument_group("issuer information")
    g.add_argument("--repo", metavar="JSON", nargs="?", const=DEFAULT_REPOSITORY_PATH, default=None,
                   help="issuer repository (repository/bin-repository.json); used automatically when present")
    g.add_argument("--no-repo", action="store_true", help="do not use the issuer repository")
    g.add_argument("--repo-list", nargs="+", metavar=("BRAND", "COUNTRY"),
                   help="list the banks that issue BRAND (e.g. visa) [in COUNTRY, ISO alpha-2] and exit")
    g.add_argument("--repo-issuer", metavar="NAME", help="list the brands and countries of a bank (name substring) and exit")
    g.add_argument("--bin-db", metavar="CSV", help="CSV BIN/IIN database for issuer lookup ('auto' = %s)" % DEFAULT_BIN_DB_PATH)
    g.add_argument("--update-bin-db", action="store_true",
                   help="download the open binlist-data CSV to the --bin-db path (or the 'auto' path) first")
    g.add_argument("--lookup", action="store_true", help="online IIN lookup; sends only the 8/6-digit IIN, never the PAN")
    g.add_argument("--lookup-url", default=DEFAULT_LOOKUP_URL, metavar="URL",
                   help="lookup service URL template containing {iin} (default binlist.net)")
    g.add_argument("--lookup-timeout", type=float, default=8.0, metavar="SEC", help="lookup timeout (default 8)")
    g = p.add_argument_group("output")
    g.add_argument("-m", "--mask", action="store_true", help="mask PANs in the output")
    g.add_argument("--mask-style", choices=MASK_STYLES, default=None,
                   help="masking style: 6-4 (default), 8-4 (PCI DSS v4, 16+ digit PANs), last4, full; implies --mask")
    g.add_argument("--format", choices=("text", "json", "jsonl", "csv"), default=None,
                   help="output format (csv/jsonl are meant for --scan)")
    g.add_argument("-j", "--json", action="store_true", help="JSON output (same as --format json)")
    g.add_argument("-q", "--quiet", action="store_true", help="one line per PAN")
    g.add_argument("--list-schemes", action="store_true", help="print the built-in IIN table and exit")
    g.add_argument("-V", "--version", action="version", version=BANNER)
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
    fmt = args.format or ("json" if args.json else "text")
    as_json = fmt in ("json", "jsonl")
    opts = OutputOptions(masked=args.mask or bool(args.mask_style), mask_style=args.mask_style or "6-4",
                         quiet=args.quiet)

    if args.iin_table:
        try:
            apply_scheme_table(load_iin_table(args.iin_table))
        except (OSError, ValueError, KeyError, TypeError) as exc:
            parser.error("cannot load --iin-table: %s" % exc)
    if args.list_schemes:
        print_scheme_table()
        return 0

    try:
        schemes = select_schemes(args.brand, include_inactive=not args.active_only,
                                 include_catch_all=not args.no_catch_all)
    except ValueError as exc:
        parser.error(str(exc))

    bin_db = None
    bin_path = args.bin_db
    if bin_path == "auto" or (args.update_bin_db and not bin_path):
        bin_path = DEFAULT_BIN_DB_PATH
    if args.update_bin_db:
        try:
            size = download_bin_db(bin_path)
            if fmt == "text":
                print("[i] downloaded %.1f MB to %s" % (size / 1048576.0, bin_path))
        except Exception as exc:
            parser.error("cannot download BIN database: %s" % exc)
    if bin_path:
        try:
            bin_db = BinDatabase(bin_path)
        except (OSError, ValueError) as exc:
            parser.error("cannot load BIN database %s: %s%s" % (
                bin_path, exc, "  (run with --update-bin-db to download it)" if bin_path == DEFAULT_BIN_DB_PATH else ""))
        if fmt == "text" and not args.quiet:
            print("[i] BIN database loaded: %d rows from %s" % (bin_db.rows, os.path.basename(bin_path)))
    repository = None
    repo_path = args.repo or (DEFAULT_REPOSITORY_PATH if os.path.exists(DEFAULT_REPOSITORY_PATH) else None)
    if repo_path and not args.no_repo:
        try:
            repository = load_repository(repo_path)
        except (OSError, ValueError, ImportError) as exc:
            if args.repo:
                parser.error("cannot load issuer repository: %s" % exc)
            print("[i] issuer repository not loaded: %s" % exc)
    if args.repo_list or args.repo_issuer:
        if repository is None:
            parser.error("the issuer repository is needed for --repo-list / --repo-issuer "
                         "(build it with repository/build_repository.py)")
        rows = (repository.issuers_for(args.repo_list[0], args.repo_list[1] if len(args.repo_list) > 1 else None)
                if args.repo_list else repository.brands_for_issuer(args.repo_issuer))
        if as_json or fmt == "csv":
            if fmt == "csv":
                w = csv.DictWriter(sys.stdout, fieldnames=list(rows[0].keys()) if rows else ["issuer"], lineterminator="\n")
                w.writeheader()
                w.writerows(rows)
            else:
                print(json.dumps(rows, indent=2, ensure_ascii=False))
        else:
            for row in rows:
                if args.repo_list:
                    print("%-3s %-45s %s" % (row["country_code"], row["issuer"], row.get("url") or ""))
                else:
                    print("%-45s %-18s %s" % (row["issuer"], row["brand"], row["country_code"]))
            print("%d entries" % len(rows))
        return 0 if rows else 1
    lookup = None
    if args.lookup:
        try:
            lookup = OnlineLookup(args.lookup_url, timeout=args.lookup_timeout)
        except ValueError as exc:
            parser.error(str(exc))
        if fmt == "text" and not args.quiet:
            print("[i] online lookup enabled: only the IIN is sent to %s" % args.lookup_url.split("/")[2])
    check_length = not args.ignore_length

    inputs: List[str] = list(args.pan)
    if args.file:
        inputs += [ln for ln in _read_lines(args.file) if ln.strip() and not ln.lstrip().startswith("#")]

    json_out: List[Dict] = []
    any_valid = False
    any_input = False
    csv_writer = None

    def emit(obj: Dict) -> None:
        if fmt == "jsonl":
            print(json.dumps(obj, ensure_ascii=False, separators=(",", ":")))
        else:
            json_out.append(obj)

    # ---- EMV --------------------------------------------------------------------
    if args.emv:
        any_input = True
        try:
            e = decode_emv(args.emv, schemes=schemes, bin_db=bin_db, require_iin=args.iin,
                           check_length=check_length, lookup=lookup, repository=repository)
        except (ValueError, OSError) as exc:
            print("[-] cannot decode EMV data: %s" % exc)
            return 1
        v = e["summary"].get("validation")
        any_valid |= bool(v and v["valid"])
        if as_json:
            if opts.masked:
                _mask_emv(e, opts)
            emit(e)
        else:
            print_emv(e, opts)
            print()

    # ---- scan mode ---------------------------------------------------------------
    if args.scan:
        any_input = True
        hits = 0
        sources = 0
        skipped: List[str] = []
        if fmt == "csv":
            csv_writer = csv.DictWriter(sys.stdout, fieldnames=SCAN_CSV_FIELDS, lineterminator="\n")
            csv_writer.writeheader()
        try:
            for src in iter_scan_sources(args.scan, recursive=not args.no_recursive, include=args.include,
                                         exclude=args.exclude, max_bytes=int(args.max_file_size * 1048576),
                                         archives=not args.no_archives, skipped=skipped):
                sources += 1
                for r in scan_text(src.lines, require_iin=not args.no_iin, check_length=check_length,
                                   schemes=schemes, bin_db=bin_db, min_score=args.min_score, source=src.name,
                                   repository=repository):
                    hits += 1
                    any_valid = True
                    r["sha256"] = src.sha256
                    if lookup is not None:
                        r["lookup"] = lookup.lookup(r["pan"])
                    if fmt == "csv":
                        csv_writer.writerow(scan_row(r, opts))
                    elif as_json:
                        r["pan"] = opts.pan(r["pan"])
                        emit(r)
                    else:
                        dup = "  (duplicate)" if r["duplicate"] else ""
                        where = "%s:%d:%d" % (src.name, r["line"], r["column"]) if src.name != "<stdin>" else "line %d" % r["line"]
                        print("[+] %-6s %3d  %-24s %-28s %s%s" % (r["confidence"], r["score"], opts.pan(r["pan"]),
                                                                  r["scheme"] or "unknown scheme", where, dup))
                        if r["signals"]:
                            print("    %s" % ", ".join(r["signals"]))
        except OSError as exc:
            print("[-] cannot scan %s: %s" % (args.scan, exc))
            return 2
        if fmt == "text":
            print("\nScanned %d source(s); candidate PANs found: %d" % (sources, hits))
            for s_ in skipped[:20]:
                print("[i] skipped %s" % s_)
            if len(skipped) > 20:
                print("[i] ... and %d more skipped" % (len(skipped) - 20))

    if not inputs and not args.scan and not args.emv:
        parser.print_help()
        return 2

    # ---- per input --------------------------------------------------------------
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
                print("[-] %s: %s" % (exc, text if not opts.masked else "<track data>"))
                continue
            v = validate_pan(t["pan"], require_iin=args.iin, check_length=check_length,
                             schemes=schemes, bin_db=bin_db, lookup=lookup, repository=repository)
            any_valid |= v["valid"]
            if as_json:
                if opts.masked:
                    t["pan"] = v["pan"] = opts.pan(v["pan"])
                    t["discretionary"] = None
                    t["discretionary_hints"] = None
                    t["input"] = "<masked>"
                emit({"track": t, "validation": v})
            else:
                print_track(t, v, opts)
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
            if fmt == "text":
                print("Attempting to generate up to %d PAN combinations for: %s%s" % (
                    est, clean, "" if args.no_iin else "  (IIN filtered)"))
            total = 0
            try:
                for pan in generate(clean, iin_check=not args.no_iin, check_length=check_length,
                                    schemes=schemes):
                    total += 1
                    any_valid = True
                    if as_json:
                        r = validate_pan(pan, require_iin=not args.no_iin, check_length=check_length,
                                         schemes=schemes, bin_db=bin_db)
                        r["pan"] = opts.pan(pan)
                        r["pattern"] = clean
                        emit(r)
                    else:
                        matches = identify(pan, schemes)
                        label = matches[0].scheme.name if matches else "unknown scheme"
                        extra = ""
                        iss = bin_db.lookup(pan) if bin_db is not None else None
                        if not iss and repository is not None:
                            iss = repository.lookup(pan)
                        if iss:
                            extra = "  [%s]" % " | ".join(
                                x for x in (iss.get("issuer"), iss.get("country")) if x)
                        if is_test_card(pan):
                            extra += "  (test number)"
                        print("[+] Valid PAN  %-20s %s%s" % (opts.pan(pan), label, extra))
            except ValueError as exc:
                print("[-] %s" % exc)
                continue
            if fmt == "text":
                print("\nTotal valid PAN generated: %d\n" % total)
            continue

        # Plain validation
        r = validate_pan(clean, require_iin=args.iin, check_length=check_length,
                         schemes=schemes, bin_db=bin_db, lookup=lookup, repository=repository)
        any_valid |= r["valid"]
        if as_json:
            r["pan"] = opts.pan(r["pan"])
            emit(r)
        elif fmt == "csv":
            print("%s,%s,%s,%s" % (opts.pan(r["pan"]), r["valid"], r["scheme"] or "", r["iin_range"] or ""))
        else:
            print_validation(r, opts)
            if not opts.quiet:
                print()

    if fmt == "json":
        print(json.dumps(json_out if len(json_out) != 1 else json_out[0], indent=2, ensure_ascii=False))
    if not any_input:
        return 2
    return 0 if any_valid else 1


def _mask_emv(e: Dict, opts: OutputOptions) -> None:
    """Mask PAN bearing values in a decoded EMV structure before JSON output."""
    for node in _walk_tlv(e["tags"]):
        dec = node.get("decoded")
        if not dec:
            continue
        if node["tag"] == "5A":
            dec["pan"] = dec["value"] = opts.pan(dec.get("pan") or "")
        if node["tag"] in ("57", "9F6B", "56", "9F20", "9F1F"):
            dec["hex"] = dec["value"] = "<masked>"
            dec.pop("track2", None)
    s = e["summary"]
    if s.get("pan"):
        s["pan"] = opts.pan(s["pan"])
    if s.get("track2"):
        s["track2"] = {"pan": s["pan"], "masked": True}
    if s.get("validation"):
        s["validation"]["pan"] = s["pan"]


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
