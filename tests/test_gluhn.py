#!/usr/bin/env python3
"""Unit and command-line tests for gLuhn.py.   Run:  python3 -m unittest discover -s tests -v"""

import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stdout

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, ROOT)

import gLuhn  # noqa: E402

SCRIPT = os.path.join(ROOT, "gLuhn.py")

# Publicly documented test numbers (all Luhn-valid).
TEST_CARDS = {
    "4111111111111111": "visa",
    "4012888888881881": "visa",
    "4222222222222": "visa",                # 13-digit legacy Visa
    "4571000000000001": "dankort",          # co-badged Visa/Dankort
    "5555555555554444": "mastercard",
    "5105105105105100": "mastercard",
    "2223003122003222": "mastercard",       # 2-series
    "378282246310005": "amex",
    "371449635398431": "amex",
    "6011111111111117": "discover",
    "6011000990139424": "discover",
    "6221260000000000": "discover_cup",     # UnionPay range processed by Discover
    "3530111333300000": "jcb",
    "3566002020360505": "jcb",
    "30569309025904": "diners",             # 14-digit Diners 36
    "36148900647913": "diners",
    "6200000000000005": "unionpay",
    "6759649826438453": "maestro_uk",       # 6759 is more specific than Maestro 67
    "6304000000000000": "maestro",          # active Maestro beats defunct Laser
    "2200000000000004": "mir",
    "9792000000000003": "troy",
    "5019717010103742": "dankort",
    "6062825624254001": "hipercard",
    "6362970000457013": "elo",
    "5060990000000008": "verve",
    "5066991111111118": "elo",
    "100000000000009": "uatp",
}


class LuhnTests(unittest.TestCase):
    def test_known_valid(self):
        for pan in TEST_CARDS:
            self.assertTrue(gLuhn.luhn_check(pan), pan)

    def test_invalid(self):
        self.assertFalse(gLuhn.luhn_check("4111111111111112"))
        self.assertFalse(gLuhn.luhn_check(""))
        self.assertFalse(gLuhn.luhn_check("12a4"))

    def test_check_digit(self):
        self.assertEqual(gLuhn.luhn_check_digit("411111111111111"), "1")
        self.assertEqual(gLuhn.luhn_check_digit("37828224631000"), "5")
        self.assertEqual(gLuhn.luhn_check_digit("7992739871"), "3")   # classic Wikipedia example

    def test_solve_any_position(self):
        pan = "4542109540018054"
        for i in range(len(pan)):
            self.assertEqual(gLuhn.luhn_solve(pan, i), pan[i], "position %d" % i)


class IdentifyTests(unittest.TestCase):
    def test_known_schemes(self):
        for pan, key in TEST_CARDS.items():
            matches = gLuhn.identify(pan)
            self.assertTrue(matches, pan)
            self.assertEqual(matches[0].scheme.key, key, "%s -> %s" % (pan, matches[0].scheme.key))
            self.assertTrue(matches[0].length_ok, pan)

    def test_precedence_rules(self):
        # longer range wins
        self.assertEqual(gLuhn.identify("6221261111111111")[0].scheme.key, "discover_cup")
        self.assertEqual(gLuhn.identify("6230001111111115")[0].scheme.key, "unionpay")
        # catch-all loses to a same-length specific range
        self.assertEqual(gLuhn.identify("6011000000000004")[0].scheme.key, "discover")
        self.assertEqual(gLuhn.identify("6500000000000002")[0].scheme.key, "discover")
        self.assertEqual(gLuhn.identify("5612000000000000")[0].scheme.key, "maestro")
        # inactive scheme listed as an alternative only
        keys = [m.scheme.key for m in gLuhn.identify("6304000000000000")]
        self.assertEqual(keys[0], "maestro")
        self.assertIn("laser", keys)

    def test_length_rule_beats_specificity(self):
        # 19-digit number in the co-badged Dankort range: Dankort is 16 digits only, so it is a Visa
        keys = [m.scheme.key for m in gLuhn.identify("4571000000000000009")]
        self.assertEqual(keys[0], "visa")
        self.assertIn("dankort", keys)
        # ...but when nothing fits the length, the most specific range is still reported
        self.assertEqual(gLuhn.identify("3742109545565554")[0].scheme.key, "amex")

    def test_unknown(self):
        self.assertEqual(gLuhn.identify("7000000000000000"), [])

    def test_amex_length(self):
        m = gLuhn.identify("3742109545565554")[0]
        self.assertEqual(m.scheme.key, "amex")
        self.assertFalse(m.length_ok)

    def test_mii(self):
        info = gLuhn.mii_info("9792000000000003")
        self.assertEqual(info["country"], "Turkey")
        self.assertEqual(gLuhn.mii_info("4111")["digit"], "4")

    def test_prefix_can_match(self):
        self.assertTrue(gLuhn.prefix_can_match("22", "2221", "2720"))
        self.assertTrue(gLuhn.prefix_can_match("2", "2221", "2720"))
        self.assertFalse(gLuhn.prefix_can_match("21", "2221", "2720"))
        self.assertFalse(gLuhn.prefix_can_match("28", "2221", "2720"))
        self.assertTrue(gLuhn.prefix_can_match("272011", "2221", "2720"))
        self.assertFalse(gLuhn.prefix_can_match("2721", "2221", "2720"))

    def test_select_schemes(self):
        keys = [s.key for s in gLuhn.select_schemes(["visa,Mastercard"])]
        self.assertIn("visa", keys)
        self.assertIn("mastercard", keys)
        self.assertNotIn("amex", keys)
        with self.assertRaises(ValueError):
            gLuhn.select_schemes(["nosuchbrand"])
        strict = {s.key: s for s in gLuhn.select_schemes(include_catch_all=False)}
        self.assertFalse(any(ca for _, _, ca in strict["maestro"].ranges))
        # the original table object must be untouched
        self.assertTrue(any(ca for _, _, ca in gLuhn.SCHEMES_BY_KEY["maestro"].ranges))

    def test_table_sanity(self):
        for s in gLuhn.SCHEMES:
            for lo, hi, _ in s.ranges:
                self.assertEqual(len(lo), len(hi), s.key)
                self.assertLessEqual(lo, hi, s.key)
            self.assertTrue(all(gLuhn.PAN_MIN_LEN <= n <= gLuhn.PAN_MAX_LEN for n in s.lengths), s.key)


class ValidateTests(unittest.TestCase):
    def test_plain(self):
        r = gLuhn.validate_pan("4542 1095 4001 8054")
        self.assertTrue(r["valid"])
        self.assertEqual(r["scheme"], "Visa")
        self.assertEqual(r["iin6"], "454210")
        self.assertEqual(r["iin8"], "45421095")

    def test_require_iin(self):
        self.assertTrue(gLuhn.validate_pan("1111222233334444")["valid"])        # Luhn only (v0.8 behaviour)
        r = gLuhn.validate_pan("1111222233334444", require_iin=True)
        self.assertFalse(r["valid"])                                              # UATP is 15 digits
        self.assertFalse(gLuhn.validate_pan("7000000000000000", require_iin=True)["valid"])
        self.assertFalse(gLuhn.validate_pan("3742109545565554", require_iin=True)["valid"])
        self.assertTrue(gLuhn.validate_pan("3742109545565554", require_iin=True, check_length=False)["valid"])

    def test_malformed(self):
        self.assertFalse(gLuhn.validate_pan("12ab")["valid"])
        self.assertFalse(gLuhn.validate_pan("1234567")["valid"])
        self.assertIn("length", gLuhn.validate_pan("1234567")["reasons"][0])

    def test_no_luhn_scheme(self):
        r = gLuhn.validate_pan("201400000000001")      # enRoute: no Luhn check digit
        self.assertEqual(r["scheme_key"], "enroute")
        self.assertFalse(r["luhn_expected"])
        self.assertTrue(r["valid"])

    def test_mask(self):
        self.assertEqual(gLuhn.mask_pan("4542109540018054"), "454210******8054")
        self.assertEqual(gLuhn.mask_pan("378282246310005"), "378282*****0005")
        self.assertEqual(gLuhn.mask_pan("1234567890"), "**********")


class GenerateTests(unittest.TestCase):
    def test_single_unknown(self):
        self.assertEqual(list(gLuhn.generate("4542109540?18054")), ["4542109540018054"])
        self.assertEqual(list(gLuhn.generate("454210954001805?")), ["4542109540018054"])

    def test_readme_example_is_subset_of_luhn_only(self):
        with_iin = list(gLuhn.generate("???2109545565554"))
        luhn_only = list(gLuhn.generate("???2109545565554", iin_check=False))
        self.assertEqual(len(luhn_only), 100)
        self.assertTrue(set(with_iin) <= set(luhn_only))
        for pan in with_iin:
            self.assertTrue(gLuhn.luhn_check(pan))
            self.assertTrue(gLuhn.identify(pan)[0].length_ok)
        self.assertIn("4542109545565554", with_iin)
        self.assertNotIn("3742109545565554", with_iin)      # 16-digit Amex is not a thing

    def test_pruning_matches_brute_force(self):
        pattern = "4?7?1095400180?4"
        fast = set(gLuhn.generate(pattern))
        brute = set()
        for a in "0123456789":
            for b in "0123456789":
                for c in "0123456789":
                    pan = pattern.replace("?", a, 1).replace("?", b, 1).replace("?", c, 1)
                    if gLuhn.luhn_check(pan) and gLuhn.identify(pan) and gLuhn.identify(pan)[0].length_ok:
                        brute.add(pan)
        self.assertEqual(fast, brute)

    def test_brand_filter(self):
        visa = gLuhn.select_schemes(["visa"])
        out = list(gLuhn.generate("??42109545565554", schemes=visa))
        self.assertTrue(out)
        self.assertTrue(all(p.startswith("4") for p in out))

    def test_amex_length_generation(self):
        self.assertTrue(list(gLuhn.generate("37828224631000?")))
        self.assertEqual(list(gLuhn.generate("37828224631000??")), [])

    def test_errors(self):
        with self.assertRaises(ValueError):
            list(gLuhn.generate("4111111111111111"))
        with self.assertRaises(ValueError):
            list(gLuhn.generate("41?"))
        with self.assertRaises(ValueError):
            list(gLuhn.generate("41x?111111111111"))

    def test_estimate(self):
        self.assertEqual(gLuhn.estimate_combinations("4?"), 1)
        self.assertEqual(gLuhn.estimate_combinations("???2109545565554"), 100)


class TrackTests(unittest.TestCase):
    def test_track2(self):
        t = gLuhn.parse_track(";4542109540018054=2512201123456789?")
        self.assertEqual(t["pan"], "4542109540018054")
        self.assertEqual(t["expiry"], "2512")
        self.assertEqual(t["service_code"]["code"], "201")
        self.assertTrue(t["service_code"]["chip"])
        self.assertEqual(t["discretionary"], "123456789")

    def test_emv_tag57(self):
        t = gLuhn.parse_track("4542109540018054D25121011234567890F")
        self.assertEqual(t["track"], "track2/EMV-57")
        self.assertEqual(t["service_code"]["code"], "101")
        self.assertEqual(t["discretionary"], "1234567890")

    def test_track2_without_expiry(self):
        t = gLuhn.parse_track("4542109540018054==101123")
        self.assertIsNone(t["expiry"])
        self.assertEqual(t["service_code"]["code"], "101")

    def test_track1(self):
        t = gLuhn.parse_track("%B4542109540018054^DOE/JOHN^25121011234567890?")
        self.assertEqual(t["name"], "JOHN DOE")
        self.assertEqual(t["pan"], "4542109540018054")
        self.assertEqual(t["expiry_text"], "2025-12 (YYMM 2512)")

    def test_service_code(self):
        sc = gLuhn.decode_service_code("220")
        self.assertTrue(sc["pin_required"])
        self.assertEqual(sc["authorisation"], "Contact issuer via online means")
        self.assertFalse(gLuhn.decode_service_code("12")["valid"])

    def test_looks_like_track(self):
        self.assertTrue(gLuhn.looks_like_track("4542109540018054=2512"))
        self.assertFalse(gLuhn.looks_like_track("4542109540018054"))
        self.assertFalse(gLuhn.looks_like_track("hello"))


class ScanTests(unittest.TestCase):
    TEXT = [
        "order 1: 4111 1111 1111 1111 ok",
        "fake: 1234567890123456",
        "amex 3782-822463-10005 and visa 4111111111111111 again",
        "zeros 0000000000000000",
        "phone +44 1234 567890",
    ]

    def test_scan(self):
        hits = list(gLuhn.scan_text(self.TEXT))
        pans = [(h["line"], h["pan"], h["duplicate"]) for h in hits]
        self.assertEqual(pans, [(1, "4111111111111111", False),
                                (3, "378282246310005", False),
                                (3, "4111111111111111", True)])


class BinDbTests(unittest.TestCase):
    def test_csv(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "bins.csv")
            with open(path, "w") as fh:
                fh.write("bin,brand,type,category,issuer,alpha_2,alpha_3,country\n")
                fh.write("454210,VISA,DEBIT,CLASSIC,SOME BANK,GB,GBR,United Kingdom\n")
                fh.write("45421095,VISA,DEBIT,GOLD,SOME BANK GOLD,GB,GBR,United Kingdom\n")
            db = gLuhn.BinDatabase(path)
            self.assertEqual(db.rows, 2)
            self.assertEqual(db.lookup("4542109540018054")["issuer"], "SOME BANK GOLD")
            self.assertEqual(db.lookup("4542101111111111")["issuer"], "SOME BANK")
            self.assertIsNone(db.lookup("5555555555554444"))
            r = gLuhn.validate_pan("4542109540018054", bin_db=db)
            self.assertEqual(r["issuer"]["country"], "United Kingdom")

    def test_range_csv(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "ranges.csv")
            with open(path, "w") as fh:
                fh.write("iin_start;iin_end;scheme;bank;country\n")
                fh.write("222100;272099;MASTERCARD;ACME;US\n")
            db = gLuhn.BinDatabase(path)
            self.assertEqual(db.lookup("2223003122003222")["issuer"], "ACME")
            self.assertIsNone(db.lookup("4111111111111111"))


class CliTests(unittest.TestCase):
    def run_cli(self, *args, stdin=None):
        proc = subprocess.run([sys.executable, SCRIPT] + list(args), input=stdin,
                              capture_output=True, text=True)
        return proc.returncode, proc.stdout, proc.stderr

    def test_validate(self):
        code, out, _ = self.run_cli("4542109540018054")
        self.assertEqual(code, 0)
        self.assertIn("[+] Valid PAN", out)
        self.assertIn("Visa", out)

    def test_invalid_exit_code(self):
        code, out, _ = self.run_cli("4542109540018055")
        self.assertEqual(code, 1)
        self.assertIn("[-] Invalid PAN", out)

    def test_iin_flag(self):
        self.assertEqual(self.run_cli("1111222233334444")[0], 0)
        code, out, _ = self.run_cli("-i", "1111222233334444")
        self.assertEqual(code, 1)

    def test_generate(self):
        code, out, _ = self.run_cli("4542109540?18054")
        self.assertEqual(code, 0)
        self.assertIn("[+] Valid PAN  4542109540018054", out)
        self.assertIn("Total valid PAN generated: 1", out)

    def test_json(self):
        code, out, _ = self.run_cli("-j", "4542109540018054", "5555555555554444")
        data = json.loads(out)
        self.assertEqual([d["scheme"] for d in data], ["Visa", "Mastercard"])

    def test_mask_and_stdin(self):
        code, out, _ = self.run_cli("-f", "-", "-q", "-m", stdin="4542109540018054\n# comment\n\n")
        self.assertEqual(code, 0)
        self.assertIn("454210******8054", out)
        self.assertNotIn("4542109540018054", out)

    def test_track(self):
        code, out, _ = self.run_cli(";4542109540018054=2512201123456789?")
        self.assertEqual(code, 0)
        self.assertIn("Service code: 201", out)

    def test_no_args_shows_help(self):
        code, out, _ = self.run_cli()
        self.assertEqual(code, 2)
        self.assertIn("usage:", out)

    def test_list_schemes(self):
        code, out, _ = self.run_cli("--list-schemes")
        self.assertEqual(code, 0)
        self.assertIn("Mastercard (mastercard)", out)

    def test_max_guard(self):
        code, out, _ = self.run_cli("--max", "10", "????109540018054")
        self.assertEqual(code, 1)
        self.assertIn("raise --max", out)


if __name__ == "__main__":
    unittest.main()


# =====================================================================================
# v1.1 features
# =====================================================================================
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer


class TestCardTests(unittest.TestCase):
    def test_all_luhn_valid_and_identified(self):
        for pan, src in gLuhn.TEST_CARD_NUMBERS.items():
            self.assertTrue(gLuhn.luhn_check(pan), "%s (%s)" % (pan, src))
            m = gLuhn.identify(pan)
            self.assertTrue(m and m[0].length_ok, "%s (%s) -> %s" % (pan, src, [x.scheme.key for x in m]))

    def test_flagged(self):
        self.assertEqual(gLuhn.validate_pan("4242424242424242")["test_card"], "Stripe")
        self.assertIsNone(gLuhn.validate_pan("4542109540018054")["test_card"])


class LookalikeTests(unittest.TestCase):
    def test_imei(self):
        imei = "35362707000000" + gLuhn.luhn_check_digit("35362707000000")
        hint = gLuhn.lookalike_hint(imei)
        self.assertEqual(hint["kind"], "IMEI")
        self.assertEqual(gLuhn.validate_pan(imei, require_iin=True)["valid"], False)   # no 15-digit JCB
        self.assertIsNone(gLuhn.lookalike_hint("378282246310005"))                    # Amex, not an IMEI

    def test_iccid(self):
        iccid = "894400000000000000" + gLuhn.luhn_check_digit("894400000000000000")
        self.assertEqual(gLuhn.lookalike_hint(iccid)["kind"], "ICCID")
        self.assertIsNone(gLuhn.lookalike_hint("4111111111111111"))


class MaskStyleTests(unittest.TestCase):
    def test_styles(self):
        pan = "4542109540018054"
        self.assertEqual(gLuhn.mask_pan(pan, "6-4"), "454210******8054")
        self.assertEqual(gLuhn.mask_pan(pan, "8-4"), "45421095****8054")
        self.assertEqual(gLuhn.mask_pan("378282246310005", "8-4"), "378282*****0005")   # <16 digits: 6-4
        self.assertEqual(gLuhn.mask_pan(pan, "last4"), "************8054")
        self.assertEqual(gLuhn.mask_pan(pan, "full"), "****************")


class ExpiryTests(unittest.TestCase):
    def test_status(self):
        today = __import__("datetime").date(2026, 10, 6)
        self.assertEqual(gLuhn.expiry_status("2512", today)["status"], "expired")
        self.assertEqual(gLuhn.expiry_status("2610", today)["status"], "valid")
        self.assertEqual(gLuhn.expiry_status("2912", today)["status"], "valid")
        self.assertEqual(gLuhn.expiry_status("4001", today)["status"], "far-future")
        self.assertEqual(gLuhn.expiry_status("2613", today)["status"], "invalid")
        self.assertIsNone(gLuhn.expiry_status(None))

    def test_track_carries_status_and_hints(self):
        t = gLuhn.parse_track(";4542109540018054=1312201123456789?")
        self.assertEqual(t["expiry_status"]["status"], "expired")
        self.assertEqual(t["discretionary_hints"]["pvki"], "1")
        self.assertEqual(t["discretionary_hints"]["pvv"], "2345")
        self.assertEqual(t["discretionary_hints"]["cvv1"], "678")
        self.assertIn("3.3.1", t["sad_warning"])
        self.assertIsNone(gLuhn.parse_track("4542109540018054=2512201")["discretionary_hints"])


class ScoringTests(unittest.TestCase):
    def test_context_raises_and_test_numbers_lower(self):
        good = "card: 4542 1095 4001 8054 exp 12/27"
        r = gLuhn.validate_pan("4542109540018054")
        s_good, lvl_good, sig = gLuhn.score_hit(good, 6, 25, r)
        self.assertEqual(lvl_good, "HIGH")
        self.assertIn("card keyword nearby", sig)
        self.assertIn("expiry nearby (possible SAD)", sig)
        bare = "x 4542109540018054 y"
        s_bare, lvl_bare, _ = gLuhn.score_hit(bare, 2, 18, r)
        self.assertLess(s_bare, s_good)
        t = gLuhn.validate_pan("4242424242424242")
        s_test, _, sig = gLuhn.score_hit("card 4242424242424242", 5, 21, t)
        self.assertLess(s_test, s_good)
        self.assertTrue(any(x.startswith("known test number") for x in sig))

    def test_monotone(self):
        self.assertTrue(gLuhn._has_monotone_run("4111111111111111"))
        self.assertTrue(gLuhn._has_monotone_run("5432109545565554"))
        self.assertFalse(gLuhn._has_monotone_run("4542109540018054"))

    def test_scan_text_fields(self):
        hits = list(gLuhn.scan_text(["acct 4542109540018054 cvv 123"], source="x"))
        self.assertEqual(len(hits), 1)
        h = hits[0]
        self.assertEqual((h["source"], h["line"], h["column"]), ("x", 1, 6))
        self.assertIn(h["confidence"], ("HIGH", "MEDIUM", "LOW"))
        self.assertEqual(list(gLuhn.scan_text(["acct 4542109540018054"], min_score=101)), [])


class ScanSourceTests(unittest.TestCase):
    def setUp(self):
        import zipfile
        self.dir = tempfile.TemporaryDirectory()
        d = self.dir.name
        with open(os.path.join(d, "dump.txt"), "w") as fh:
            fh.write("card: 4542 1095 4001 8054 exp 12/27\nphone 12345678901234\n")
        with open(os.path.join(d, "utf16.txt"), "wb") as fh:
            fh.write("visa 4111111111111111\n".encode("utf-16-le"))
        with open(os.path.join(d, "bom16.txt"), "wb") as fh:
            fh.write("﻿mc 5555555555554444\n".encode("utf-16"))
        os.mkdir(os.path.join(d, "sub"))
        with open(os.path.join(d, "sub", "notes.log"), "w") as fh:
            fh.write("stripe 4242424242424242\n")
        with open(os.path.join(d, "sub", "skip.bak"), "w") as fh:
            fh.write("amex 378282246310005\n")
        with zipfile.ZipFile(os.path.join(d, "archive.docx"), "w") as z:
            z.writestr("word/document.xml", "<w:t>Discover 6011111111111117</w:t>")
            inner = io.BytesIO()
            with zipfile.ZipFile(inner, "w") as z2:
                z2.writestr("cards.csv", "pan\n3530111333300000\n")
            z.writestr("nested.zip", inner.getvalue())
        import zlib
        content = b"BT (Card 4012 8888 8888 1881) Tj ET"
        comp = zlib.compress(content)
        with open(os.path.join(d, "doc.pdf"), "wb") as fh:
            fh.write(b"%PDF-1.4\n1 0 obj<</Length " + str(len(comp)).encode() +
                     b"/Filter/FlateDecode>>stream\n" + comp + b"\nendstream\nendobj\n%%EOF")
        with open(os.path.join(d, "big.bin"), "wb") as fh:
            fh.write(b"\x00" * 3000)

    def tearDown(self):
        self.dir.cleanup()

    def all_hits(self, **kw):
        out = []
        for src in gLuhn.iter_scan_sources(self.dir.name, **kw):
            for r in gLuhn.scan_text(src.lines, source=src.name):
                out.append((os.path.relpath(r["source"], self.dir.name) if not r["source"].startswith("<") else r["source"], r["pan"]))
        return out

    def test_everything_found(self):
        hits = self.all_hits()
        pans = {p for _, p in hits}
        self.assertEqual(pans, {"4542109540018054", "4111111111111111", "5555555555554444", "4242424242424242",
                                "378282246310005", "6011111111111117", "3530111333300000", "4012888888881881"})
        names = {n for n, _ in hits}
        self.assertIn("archive.docx!word/document.xml", names)
        self.assertIn("archive.docx!nested.zip!cards.csv", names)
        self.assertIn(os.path.join("sub", "notes.log"), names)

    def test_filters(self):
        pans = {p for _, p in self.all_hits(exclude=["*.bak", "sub"])}
        self.assertNotIn("378282246310005", pans)
        self.assertNotIn("4242424242424242", pans)
        pans = {p for _, p in self.all_hits(include=["*.txt"])}
        self.assertEqual(pans, {"4542109540018054", "4111111111111111", "5555555555554444"})
        names = {n for n, _ in self.all_hits(archives=False)}
        self.assertFalse(any("!" in n for n in names))          # archive members not opened individually
        pans = {p for _, p in self.all_hits(recursive=False)}
        self.assertNotIn("4242424242424242", pans)

    def test_size_limit_and_sha(self):
        skipped = []
        srcs = list(gLuhn.iter_scan_sources(self.dir.name, max_bytes=100, skipped=skipped))
        self.assertTrue(any("big.bin" in s for s in skipped))
        srcs = list(gLuhn.iter_scan_sources(os.path.join(self.dir.name, "dump.txt")))
        self.assertEqual(len(srcs[0].sha256), 64)

    def test_decode_bytes(self):
        self.assertEqual(gLuhn.decode_bytes("abc 123".encode("utf-16-le")), "abc 123")
        self.assertEqual(gLuhn.decode_bytes("abc 123".encode("utf-16-be")), "abc 123")
        self.assertEqual(gLuhn.decode_bytes(b"\xef\xbb\xbfhi"), "hi")
        self.assertEqual(gLuhn.decode_bytes(b"caf\xe9"), "caf\xe9")      # latin-1 fallback


class EmvTests(unittest.TestCase):
    @staticmethod
    def tlv(tag, val):
        n = len(val) // 2
        return tag + ("%02X" % n if n < 128 else "81%02X" % n) + val

    def sample(self):
        t = self.tlv
        inner = (t("5A", "4542109540018054") + t("5F24", "251231") + t("5F34", "01") +
                 t("57", "4542109540018054D2512201123456789F") + t("5F20", "444F452F4A4F484E") +
                 t("82", "1980") + t("8E", "000000000000000042031E031F00") + t("9F07", "FF00") +
                 t("5F28", "0826") + t("5F30", "0201") + t("4F", "A0000000031010") + t("50", "56495341") +
                 t("95", "0000008000") + t("9F27", "80") + t("9F02", "000000012345"))
        return t("70", inner)

    def test_decode(self):
        e = gLuhn.decode_emv(self.sample())
        s = e["summary"]
        self.assertEqual(s["pan"], "4542109540018054")
        self.assertEqual(s["aid"]["scheme"], "Visa")
        self.assertEqual(s["cardholder"], "DOE/JOHN")
        self.assertEqual(s["expiry"], "2025-12-31")
        self.assertEqual(s["psn"], "1")
        self.assertEqual(s["issuer_country"], "United Kingdom")
        self.assertEqual(s["service_code"]["code"], "201")
        self.assertIn("CDA supported", s["aip"])
        self.assertEqual(len(s["cvm_list"]["rules"]), 3)
        self.assertEqual(s["cvm_list"]["rules"][2]["cvm"], "No CVM required")
        self.assertIn("Transaction exceeds floor limit", s["tvr"])
        self.assertTrue(s["cid"].startswith("ARQC"))
        self.assertTrue(s["validation"]["valid"])
        self.assertEqual(s["track2"]["pan"], "4542109540018054")
        self.assertEqual(len(s["auc"]), 8)

    def test_pan_from_track2_only_and_mismatch_warning(self):
        e = gLuhn.decode_emv(self.tlv("57", "5555555555554444D25122011F") + self.tlv("4F", "A0000000031010"))
        self.assertEqual(e["summary"]["pan"], "5555555555554444")
        self.assertTrue(any("AID says Visa" in w for w in e["summary"]["warnings"]))

    def test_long_form_length_and_padding(self):
        payload = "41" * 200
        e = gLuhn.decode_emv("00" + self.tlv("9F10", payload) + "FF")
        self.assertEqual(e["tags"][0]["length"], 200)

    def test_hex_cleaning_and_errors(self):
        self.assertEqual(gLuhn._clean_hex("5a 08 45:42-10 95\n40018054"), "5A0845421095400180 54".replace(" ", ""))
        with self.assertRaises(ValueError):
            gLuhn.decode_emv("5A0")
        with self.assertRaises(ValueError):
            gLuhn.decode_emv("5A")           # truncated
        e = gLuhn.decode_emv("5A08")         # length promises 8 bytes, none present
        self.assertTrue(e["tags"][0]["truncated"])

    def test_aid_lookup(self):
        self.assertEqual(gLuhn.aid_info("A0000000041010")["product"], "Mastercard credit / debit")
        self.assertEqual(gLuhn.aid_info("A0000000049999")["product"], "Mastercard (other product)")
        self.assertIsNone(gLuhn.aid_info("B000000000"))


class IinTableTests(unittest.TestCase):
    def tearDown(self):
        gLuhn.apply_scheme_table(gLuhn.load_iin_table.__defaults__ and [] or list(ORIGINAL_SCHEMES))

    def test_merge_and_override(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "t.json")
            with open(path, "w") as fh:
                json.dump({"schemes": [
                    {"key": "acme", "name": "ACME Store Card", "ranges": ["7001-7002"], "lengths": [16]},
                    {"key": "visa", "name": "Visa X", "ranges": ["4"], "lengths": [16]}]}, fh)
            table = gLuhn.load_iin_table(path)
            keys = [s.key for s in table]
            self.assertIn("acme", keys)
            self.assertEqual(keys.index("visa"), 0)                      # override keeps position
            self.assertEqual(table[0].name, "Visa X")
            gLuhn.apply_scheme_table(table)
            self.assertEqual(gLuhn.identify("7001000000000004")[0].scheme.key, "acme")
            self.assertFalse(gLuhn.identify("4222222222222")[0].length_ok)  # 13 no longer allowed

    def test_replace(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "t.json")
            with open(path, "w") as fh:
                json.dump({"replace": True, "schemes": [{"key": "only", "name": "Only", "ranges": ["9"]}]}, fh)
            table = gLuhn.load_iin_table(path)
            self.assertEqual([s.key for s in table], ["only"])
            with open(path, "w") as fh:
                json.dump({"schemes": [{"name": "no key"}]}, fh)
            with self.assertRaises(ValueError):
                gLuhn.load_iin_table(path)


ORIGINAL_SCHEMES = list(gLuhn.SCHEMES)


class _MockHandler(BaseHTTPRequestHandler):
    DATA = {"45421095": {"scheme": "visa", "type": "debit", "brand": "Visa Classic",
                         "country": {"alpha2": "GB", "name": "United Kingdom"}, "bank": {"name": "MOCK BANK"}},
            "555555": {"scheme": "mastercard", "bank": "Legacy string bank"}}
    hits = []

    def log_message(self, *a):
        pass

    def do_GET(self):
        iin = self.path.strip("/")
        _MockHandler.hits.append(iin)
        body = json.dumps(self.DATA[iin]).encode() if iin in self.DATA else b"{}"
        self.send_response(200 if iin in self.DATA else 404)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class OnlineLookupTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = HTTPServer(("127.0.0.1", 0), _MockHandler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.url = "http://127.0.0.1:%d/{iin}" % cls.server.server_address[1]

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def test_lookup(self):
        lk = gLuhn.OnlineLookup(self.url, timeout=5)
        r = lk.lookup("4542109540018054")
        self.assertEqual(r["bank_name"], "MOCK BANK")
        self.assertEqual(r["iin"], "45421095")
        r = lk.lookup("5555555555554444")                    # 8-digit miss, 6-digit hit
        self.assertEqual(r["bank_name"], "Legacy string bank")
        r = lk.lookup("6011111111111117")
        self.assertEqual(r["error"], "not found")
        lk.lookup("4542109540018054")
        self.assertEqual(lk.requests, 5)                      # cached: no sixth request
        self.assertTrue(all(len(h) in (6, 8) for h in _MockHandler.hits))   # never the full PAN

    def test_only_iin_leaves(self):
        gLuhn.OnlineLookup(self.url).lookup("4542109540018054")
        self.assertNotIn("4542109540018054", _MockHandler.hits)

    def test_unreachable(self):
        r = gLuhn.OnlineLookup("http://127.0.0.1:1/{iin}", timeout=1).lookup("4542109540018054")
        self.assertIn("error", r)
        with self.assertRaises(ValueError):
            gLuhn.OnlineLookup("http://example.invalid/")

    def test_cli(self):
        proc = subprocess.run([sys.executable, SCRIPT, "--lookup", "--lookup-url", self.url, "-j", "4542109540018054"],
                              capture_output=True, text=True)
        self.assertEqual(json.loads(proc.stdout)["lookup"]["scheme"], "visa")


class CliV11Tests(CliTests):
    def test_scan_formats(self):
        with tempfile.TemporaryDirectory() as d:
            with open(os.path.join(d, "a.txt"), "w") as fh:
                fh.write("card 4542 1095 4001 8054 exp 12/27\n")
            code, out, _ = self.run_cli("--scan", d, "--format", "csv", "--mask-style", "8-4")
            self.assertEqual(code, 0)
            lines = out.strip().splitlines()
            self.assertEqual(lines[0].split(",")[:4], ["source", "line", "column", "pan"])
            self.assertIn("45421095****8054", lines[1])
            code, out, _ = self.run_cli("--scan", d, "--format", "jsonl")
            rec = json.loads(out.strip().splitlines()[0])
            self.assertEqual(rec["confidence"], "HIGH")
            code, out, _ = self.run_cli("--scan", d, "--min-score", "99")
            self.assertEqual(code, 1)
            self.assertIn("candidate PANs found: 0", out)

    def test_emv_cli(self):
        code, out, _ = self.run_cli("--emv", "5A0845421095400180545F24032512315F340101")
        self.assertEqual(code, 0)
        self.assertIn("Application PAN", out)
        self.assertIn("[+] Valid PAN", out)
        code, out, _ = self.run_cli("--emv", "ZZ")
        self.assertEqual(code, 1)

    def test_mask_styles_cli(self):
        code, out, _ = self.run_cli("--mask-style", "last4", "-q", "4542109540018054")
        self.assertIn("************8054", out)

    def test_test_card_and_lookalike_text(self):
        code, out, _ = self.run_cli("4242424242424242")
        self.assertIn("Test number:", out)
        imei = "35362707000000" + gLuhn.luhn_check_digit("35362707000000")
        code, out, _ = self.run_cli(imei)
        self.assertIn("Look-alike:   15-digit Luhn", out)

    def test_iin_table_cli(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "t.json")
            with open(path, "w") as fh:
                json.dump({"schemes": [{"key": "acme", "name": "ACME", "ranges": ["7001"], "lengths": [16]}]}, fh)
            code, out, _ = self.run_cli("--iin-table", path, "-i", "-q", "7001000000000004")
            self.assertEqual(code, 0)
            code, out, _ = self.run_cli("--iin-table", os.path.join(d, "missing.json"), "4111111111111111")
            self.assertEqual(code, 2)

    def test_track_expired_and_hints(self):
        code, out, _ = self.run_cli(";4542109540018054=1312201123456789?")
        self.assertIn("[expired", out)
        self.assertIn("PVKI 1, PVV 2345, CVV1/CVC1 678", out)
        self.assertIn("Attention:", out)
