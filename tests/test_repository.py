#!/usr/bin/env python3
"""Tests for repository/gluhn_repository.py, repository/build_repository.py and the gLuhn.py integration."""

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
REPO_DIR = os.path.join(ROOT, "repository")
sys.path.insert(0, ROOT)
sys.path.insert(0, REPO_DIR)

import gLuhn  # noqa: E402
import gluhn_repository  # noqa: E402

SCRIPT = os.path.join(ROOT, "gLuhn.py")
JSON_PATH = os.path.join(REPO_DIR, "bin-repository.json")


def load_builder():
    spec = importlib.util.spec_from_file_location("build_repository", os.path.join(REPO_DIR, "build_repository.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class BuilderTests(unittest.TestCase):
    CSV = (
        "bin,brand,type,category,issuer,alpha_2,alpha_3,country,latitude,longitude,bank_phone,bank_url\n"
        "492940,VISA,CREDIT,PREMIER,BARCLAYS BANK PLC,GB,GBR,United Kingdom,0,0,0800 1,www.barclays.co.uk\n"
        "492941,VISA,CREDIT,PREMIER,BARCLAYS BANK PLC,GB,GBR,United Kingdom,0,0,0800 1,www.barclays.co.uk\n"
        "492942,VISA,DEBIT,,BARCLAYS BANK PLC,GB,GBR,United Kingdom,0,0,,\n"
        "555555,MASTER CARD,CREDIT,,,US,USA,United States,0,0,,\n"
        "37828224,AMEX,CREDIT,SMALL CORPORATE,AMERICAN EXPRESS COMPANY,US,USA,United States,0,0,,\n"
        "4111,VISA,,,TOO SHORT,US,USA,United States,0,0,,\n"
    )
    EXTRA = "iin_start;iin_end;scheme;bank;alpha_2;country\n492942;492943;Visa;BARCLAYCARD;GB;United Kingdom\n"

    def build(self, *extra):
        mod = load_builder()
        with tempfile.TemporaryDirectory() as d:
            p1 = os.path.join(d, "binlist.csv")
            with open(p1, "w", encoding="utf-8") as fh:
                fh.write(self.CSV)
            sources = [("binlist", mod.read_source(p1, p1))]
            for i, text in enumerate(extra):
                p = os.path.join(d, "extra%d.csv" % i)
                with open(p, "w", encoding="utf-8") as fh:
                    fh.write(text)
                sources.append(("extra%d" % i, mod.read_source(p, p)))
            return mod.build(sources)

    def test_ranges_merge_and_normalise(self):
        repo = self.build()
        self.assertEqual(repo["format"], "gluhn-bin-repository/1")
        six = repo["ranges"]["6"]
        self.assertEqual([r[:2] for r in six], [[492940, 492941], [492942, 492942], [555555, 555555]])
        self.assertIn("8", repo["ranges"])
        self.assertNotIn("4", repo["ranges"])                        # too short, dropped
        self.assertIn("MASTERCARD", repo["brands"])                   # alias normalised
        self.assertIn("AMERICAN EXPRESS", repo["brands"])
        self.assertEqual(repo["countries"]["GB"], "United Kingdom")
        self.assertEqual(repo["counts"]["issuers"], 2)                # Barclays (one entry, url kept), Amex
        barclays = next(e for e in repo["issuers"] if e["n"] == "BARCLAYS BANK PLC")
        self.assertEqual(barclays["u"], "www.barclays.co.uk")
        self.assertEqual(six[2][5], -1)                               # no issuer -> -1
        self.assertIn("GB", repo["by_brand"]["VISA"])

    def test_later_source_overrides(self):
        repo = self.build(self.EXTRA)
        six = repo["ranges"]["6"]
        names = {repo["issuers"][r[5]]["n"] for r in six if r[5] >= 0}
        self.assertIn("BARCLAYCARD", names)
        def row_for(b):
            return next(r for r in six if r[0] <= b <= r[1])
        self.assertEqual(repo["issuers"][row_for(492943)[5]]["n"], "BARCLAYCARD")
        self.assertEqual(repo["issuers"][row_for(492942)[5]]["n"], "BARCLAYCARD")
        self.assertEqual(repo["issuers"][row_for(492940)[5]]["n"], "BARCLAYS BANK PLC")


class ModuleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        mod = load_builder()
        cls.tmp = tempfile.TemporaryDirectory()
        src = os.path.join(cls.tmp.name, "src.csv")
        with open(src, "w", encoding="utf-8") as fh:
            fh.write(BuilderTests.CSV)
        repo = mod.build([("t", mod.read_source(src, src))])
        cls.path = os.path.join(cls.tmp.name, "repo.json")
        with open(cls.path, "w", encoding="utf-8") as fh:
            json.dump(repo, fh)
        cls.repo = gluhn_repository.BinRepository(cls.path)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_lookup(self):
        r = self.repo.lookup("4929 4012 3456 7891")
        self.assertEqual(r["issuer"], "BARCLAYS BANK PLC")
        self.assertEqual(r["range"], "492940-492941")
        self.assertEqual((r["brand"], r["type"], r["category"], r["country"]), ("VISA", "CREDIT", "PREMIER", "United Kingdom"))
        self.assertEqual(r["url"], "www.barclays.co.uk")
        self.assertEqual(self.repo.lookup("492942")["type"], "DEBIT")             # bare BIN
        self.assertIsNone(self.repo.lookup("4929431234567890")["issuer"] if self.repo.lookup("4929431234567890") else None)
        self.assertIsNone(self.repo.lookup("4000000000000000"))
        self.assertIsNone(self.repo.lookup("12"))
        self.assertIsNone(self.repo.lookup(""))

    def test_longest_prefix_wins(self):
        r = self.repo.lookup("378282246310005")
        self.assertEqual(r["prefix_length"], 8)
        self.assertEqual(r["issuer"], "AMERICAN EXPRESS COMPANY")

    def test_no_issuer_still_has_brand(self):
        r = self.repo.lookup("5555555555554444")
        self.assertIsNone(r["issuer"])
        self.assertEqual(r["brand"], "MASTERCARD")
        self.assertEqual(r["country_code"], "US")

    def test_issuers_for_and_aliases(self):
        rows = self.repo.issuers_for("visa", "gb")
        self.assertEqual({x["issuer"] for x in rows}, {"BARCLAYS BANK PLC"})
        self.assertEqual(self.repo.issuers_for("amex")[0]["issuer"], "AMERICAN EXPRESS COMPANY")
        self.assertEqual(self.repo.issuers_for("MASTER CARD"), [])         # no named issuer on record
        self.assertEqual(self.repo.issuers_for("nosuchbrand"), [])

    def test_brands_for_issuer(self):
        rows = self.repo.brands_for_issuer("barclays")
        self.assertEqual({(x["brand"], x["country_code"]) for x in rows}, {("VISA", "GB")})

    def test_format_check(self):
        bad = os.path.join(self.tmp.name, "bad.json")
        with open(bad, "w") as fh:
            json.dump({"format": "something-else"}, fh)
        with self.assertRaises(ValueError):
            gluhn_repository.BinRepository(bad)
        with self.assertRaises(OSError):
            gluhn_repository.BinRepository(os.path.join(self.tmp.name, "missing.json"))

    def test_format_lookup_line(self):
        self.assertEqual(gluhn_repository.format_lookup(None), "no issuer information")
        self.assertIn("BARCLAYS BANK PLC | VISA | CREDIT | PREMIER | United Kingdom  [BIN 492940-492941]",
                      gluhn_repository.format_lookup(self.repo.lookup("4929401234567891")))

    def test_module_cli(self):
        proc = subprocess.run([sys.executable, os.path.join(REPO_DIR, "gluhn_repository.py"), "--repo", self.path,
                               "4929401234567891", "--list", "visa", "GB"], capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("BARCLAYS BANK PLC", proc.stdout)
        self.assertIn("1 issuer(s)", proc.stdout)


@unittest.skipUnless(os.path.exists(JSON_PATH), "repository/bin-repository.json not built")
class ShippedRepositoryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.repo = gluhn_repository.BinRepository()

    def test_known_issuers(self):
        self.assertEqual(self.repo.lookup("4929401234567891")["issuer"], "BARCLAYS BANK PLC")
        self.assertEqual(self.repo.lookup("378282246310005")["brand"], "AMERICAN EXPRESS")
        self.assertGreater(self.repo.counts["issuers"], 10000)
        self.assertGreater(len(self.repo.issuers_for("visa", "GB")), 50)
        self.assertTrue(any("BARCLAY" in x["issuer"] for x in self.repo.issuers_for("visa", "GB")))

    def test_ranges_are_sorted_and_disjoint(self):
        for length, los, rows in self.repo._index:
            self.assertEqual(los, sorted(los), "length %d not sorted" % length)
            for a, b in zip(rows, rows[1:]):
                self.assertLess(a[1], b[0], "overlap at %s" % a)

    def test_gluhn_integration(self):
        r = gLuhn.validate_pan("4929401234567891", repository=self.repo)
        self.assertEqual(r["repository"]["issuer"], "BARCLAYS BANK PLC")
        hits = list(gLuhn.scan_text(["acct 4929401234567881"], repository=self.repo))
        self.assertEqual(hits[0]["repository"]["issuer"], "BARCLAYS BANK PLC")
        row = gLuhn.scan_row(hits[0], gLuhn.OutputOptions())
        self.assertEqual(row["issuer"], "BARCLAYS BANK PLC | United Kingdom")

    def run_cli(self, *args):
        proc = subprocess.run([sys.executable, SCRIPT] + list(args), capture_output=True, text=True)
        return proc.returncode, proc.stdout

    def test_cli(self):
        code, out = self.run_cli("4929401234567881")
        self.assertIn("Issuer (repo): BARCLAYS BANK PLC | VISA | CREDIT | PREMIER | United Kingdom  [BIN 492940]", out)
        code, out = self.run_cli("--no-repo", "4929401234567881")
        self.assertNotIn("Issuer (repo)", out)
        code, out = self.run_cli("--repo-list", "visa", "GB")
        self.assertEqual(code, 0)
        self.assertIn("BARCLAYS BANK PLC", out)
        code, out = self.run_cli("--repo-issuer", "barclaycard", "-j")
        self.assertEqual(json.loads(out)[0]["brand"], "VISA")
        code, out = self.run_cli("--repo", os.path.join(REPO_DIR, "missing.json"), "4111111111111111")
        self.assertEqual(code, 2)
        code, out = self.run_cli("--repo-list", "nosuchbrand")
        self.assertEqual(code, 1)


if __name__ == "__main__":
    unittest.main()
