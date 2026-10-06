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
