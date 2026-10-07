# gLuhn

Check, generate and identify payment card numbers (PAN), name the issuing bank, find
cardholder data in files, and decode magnetic-stripe and EMV chip data. One Python 3 script
and one PowerShell script with the same options and the same output, written for analysts
who investigate PCI DSS scope, incidents and data exposure.

## Contents

1. Overview
2. Quick start
3. Concepts
4. Installation and files
5. Use cases
6. Playbooks
7. Reference
8. Troubleshooting
9. FAQ

---

## 1. Overview

gLuhn answers the questions an analyst asks when a card number, a stripe read or a chip dump
turns up: Is it a real card number (Luhn check digit, known IIN range, length rule)? Which
network and which bank issued it (scheme table plus the bundled issuer repository)? Is it a
published test number or something that only looks like a card, such as an IMEI? Where else
does it appear in this file share, and what sits next to it (expiry dates, CVVs, full track
data)? It also completes partially known numbers, decodes track 1 / track 2 strings and EMV
TLV data, and writes masked CSV or JSON evidence.

The tool was written for four jobs:

- **Cardholder data discovery.** Find PANs in file shares, exports, logs, archives and
  backups, score each hit, and produce a masked report for PCI DSS requirement 3 and scope
  validation work (UC5, UC6).
- **Digital forensics and incident response.** Identify what a recovered number, track string
  or chip dump is, which bank issued it, and whether sensitive authentication data is present
  (UC3, UC7, UC8).
- **OSINT and investigations.** Complete a number of which only some digits are known and
  attribute it to a bank and country (UC2, UC3).
- **Assessment evidence.** Separate developer fixtures from real exposure, keep full numbers
  out of reports, and document what was checked and when (UC6, UC10).

### 1.1 Two implementations, one behaviour

| Script | Runs on | Notes |
|---|---|---|
| `gLuhn.py` | Python 3.6 or later, any OS | Standard library only, no packages to install |
| `gLuhn.ps1` | Windows PowerShell 5.1 and PowerShell 7 or later | One file; detects the engine it runs under |

Both scripts accept the same inputs, apply the same scheme table and issuer repository, and
print the same text. Options differ only in spelling: `--scan` in Python is `-Scan` in
PowerShell. The reference tables in [section 7](#s7) list both forms side by side.

> **Attention.** The scripts handle cardholder data. Run them on systems that are in scope
> for that data, keep reports masked (`--mask`), and never paste real numbers into tickets,
> chat or e-mail. The only network features are opt-in and are described in UC4 and 4.3.

### 1.2 What the tool is not

It is not a card validity service: a number that passes every check may still be closed,
blocked or never issued. The scheme table identifies the network from public ranges, and
the issuer repository names the bank according to open BIN data of a stated date. Neither
replaces an authorisation request to the issuer.

## 2. Quick start

A first result takes a minute. These commands work from the repository folder; replace
`python3 gLuhn.py` with `.\gLuhn.ps1` on Windows.

### 2.1 Validate and identify one number

```bash
cd gLuhn.py
python3 gLuhn.py 4929401234567881
```

```text
PAN:          4929 4012 3456 7881  (16 digits)
Luhn:         valid
MII:          4 - Banking and financial (Visa)
IIN:          492940 / 49294012  (6-digit / 8-digit)
Scheme:       Visa  (IIN range 4; length OK)
Issuer (repo): BARCLAYS BANK UK PLC | VISA | CREDIT | GOLD | United Kingdom  [BIN 492940]
Result:       [+] Valid PAN
```

The scheme line says Visa; the issuer line, from the bundled repository, says which bank.

### 2.2 Complete a partially known number

Replace unknown digits with `?`. Every completion that passes the Luhn check and belongs to
a known scheme with a matching length is printed with its scheme and, when known, its bank.

```bash
python3 gLuhn.py '49294012345678?1'
```

```text
Attempting to generate up to 1 PAN combinations for: 49294012345678?1  (IIN filtered)
[+] Valid PAN  4929401234567881     Visa  [BARCLAYS BANK UK PLC | United Kingdom]

Total valid PAN generated: 1
```

### 2.3 Scan a folder and write a masked report

```bash
python3 gLuhn.py --scan ./exports --format csv --mask > findings.csv
```

> **Note.** If the commands above do not run, see [Installation and files](#s4). Windows
> users who get an execution policy error find the one-line fix in [4.2](#s4/4.2).

## 3. Concepts

### 3.1 Anatomy of a PAN

A Primary Account Number follows ISO/IEC 7812. It has up to 19 digits (the 2017 edition
sets the minimum at 10, earlier editions at 8):

```text
4929 4012 3456 788 1
|    |              |
|    |              +-- check digit (Luhn formula, ISO/IEC 7812-1 Annex B)
|    +-- individual account identifier
+-- Issuer Identification Number (IIN, also called BIN)
```

The IIN was six digits for decades. ISO/IEC 7812-1:2017 extended it to eight digits, with
an industry migration date of April 2022. gLuhn prints both the six and the eight digit IIN
because BIN lists and lookup services still exist in both granularities, and the issuer
repository holds eight digit sub-ranges where its sources have them.

### 3.2 Major Industry Identifier

The first digit (MII) says which industry assigned the number.

| Digit | Industry | Typical schemes |
|---|---|---|
| 0 | ISO/TC 68 and other industry assignments | |
| 1 | Airlines | UATP |
| 2 | Airlines, financial and other future industry assignments | Mastercard 2-series, Mir, BORICA |
| 3 | Travel and entertainment | American Express, Diners Club, JCB |
| 4 | Banking and financial | Visa |
| 5 | Banking and financial | Mastercard, Maestro |
| 6 | Merchandising and banking/financial | Discover, UnionPay, Maestro |
| 7 | Petroleum and other future industry assignments | |
| 8 | Healthcare, telecommunications and other future industry assignments | |
| 9 | National assignment: digits 2 to 4 are the ISO 3166-1 numeric country code | Troy (9792, Turkey), Napas (9704, Vietnam), Humo (9860, Uzbekistan) |

### 3.3 The Luhn check

The last digit is a check digit computed from the others: starting from the right, every
second digit is doubled (9 is subtracted when the result exceeds 9), all digits are summed,
and the total must be divisible by ten. The check catches every single-digit error and most
transpositions. It proves nothing about the account: 1111222233334444 passes.

gLuhn uses the formula in three ways: to validate, to compute a missing check digit, and to
solve one unknown digit anywhere in the number directly, which is why a pattern with k
unknown digits costs 10^(k-1) candidates instead of 10^k.

### 3.4 Schemes, ranges and precedence

The built-in table lists 38 networks with their IIN ranges and allowed lengths, from Visa,
Mastercard, American Express, Discover, JCB, UnionPay, Diners Club and Maestro to domestic
schemes such as Mir, Troy, RuPay, Elo, Verve, Dankort and UATP, plus defunct schemes
(Laser, Solo, Switch, Bankcard, enRoute) so that historical data is still identified. Print
it with `--list-schemes`.

When ranges overlap, the winner is decided in this order:

1. A range whose length rule fits beats one that does not. A 19-digit number starting with
   4571 is a Visa, not a malformed Dankort.
2. The longer, more specific range wins: 622126 to 622925 (Discover) beats 62 (UnionPay).
3. A catch-all range (Maestro 50 and 56 to 69) loses to any range of the same length.
4. An active scheme beats a defunct one: Maestro 6304 beats Laser 6304.

Every other match is still printed under "Also matches", so an ambiguous prefix such as 81
(UnionPay and RuPay) is never hidden.

### 3.5 Validation levels

Without options a number only has to be well formed and pass Luhn, which is what version
0.8 of the tool did. With `--iin` (`-i`, PowerShell `-IIN`) the IIN must be known and the
length must fit the scheme. Generation and scanning always apply the IIN filter unless
`--no-iin` (`-NoIIN`) is given.

### 3.6 Issuer repository

The scheme table identifies the network. The issuer repository,
`repository/bin-repository.json`, goes one level deeper: for several hundred thousand BINs
it names the issuing bank, its country, the card type (credit, debit, prepaid) and the
product category (classic, gold, business, corporate). It is built by
`repository/build_repository.py` from open BIN data sets (the binlist.io merged set under
CC BY 4.0 and the OpenBIIN community database, which contributes eight digit sub-ranges)
and can fold in further CSV sources such as per-brand issuer lists you export yourself. One
JSON file is shared by both scripts through two small modules, `gluhn_repository.py` and
`GLuhnRepository.psm1`, so a data refresh needs no code change.

Lookups take the longest matching prefix (eight digit entries beat six digit ones) and are
answered from a sorted index with a binary search, so the cost is in loading the file once
per run, not per number. The repository is used automatically when the file exists;
`--no-repo` switches it off and `--repo PATH` points at another build. Two reverse
questions are answered from the same file: `--repo-list visa GB` lists the banks that issue
Visa cards in the United Kingdom and `--repo-issuer barclaycard` lists the brands and
countries of a bank.

> **Note.** About half of the BINs on record carry no bank name but still give brand, type
> and country. BIN assignments change over time, so quote the repository's `generated` date
> in reports and rebuild it when precision matters.

### 3.7 Test numbers and look-alikes

Card schemes and payment providers publish numbers for sandbox use (4111 1111 1111 1111,
5555 5555 5555 4444, 3782 822463 10005 and about eighty more). gLuhn recognises them and
names the publisher: "Test number: published test / sandbox card number (Mastercard)". In
a data discovery exercise these are developer fixtures, not cardholder data, and their
presence usually points at test data that leaked into a production location rather than at
an exposure of real accounts.

Other Luhn-checked identifiers are easily mistaken for cards. IMEIs are 15-digit Luhn
numbers whose first eight digits (the TAC) begin with 35, 86, 01 and a few other prefixes;
SIM ICCIDs are 18 to 20 digits starting with 89. gLuhn labels both.

### 3.8 Confidence score in scan results

Every scan hit carries a score from 0 to 100 and a level (HIGH at 70 or more, MEDIUM at
45 or more, LOW below). The score starts at 40 and moves with the signals that are printed
next to each hit:

| Signal | Effect | Why |
|---|---|---|
| specific IIN (range of 4 or more digits) | +15 | the prefix is unambiguous |
| catch-all IIN | -15 | Maestro 50 / 56-69 match many non-card numbers |
| unknown IIN (only with `--no-iin`) | -20 | no scheme claims the prefix |
| grouped digits (4-4-4-4 with spaces or dashes) | +10 | people and systems format cards this way |
| sequential or repeated digits | -25 | 4111111111111111 style numbers are fixtures |
| known test number | -25 | published sandbox numbers are not cardholder data |
| looks like IMEI or ICCID | -30 | another Luhn-checked identifier |
| card keyword nearby | +20 | "card", "PAN", "Visa", "CVV", "expiry" within 48 characters |
| expiry nearby | +10 | an MM/YY next to a PAN also means sensitive data |
| CVV-like value nearby | +5 | three or four digits near a "CVV" or "CVC" keyword |

Use `--min-score` to keep only the hits above a threshold, and read the signals before
raising a finding.

### 3.9 Sensitive authentication data

Track 1 and track 2 data, the card verification value and PIN data are sensitive
authentication data (SAD). PCI DSS v4 requirement 3.3.1 forbids storing them after
authorisation, even encrypted. gLuhn prints an attention line whenever it decodes track
data or chip data, shows the typical PVKI / PVV / CVV1 layout of track 2 discretionary data
so investigators recognise it, and flags expiry dates or CVV-like values found next to a
PAN during a scan. A PAN finding becomes a SAD finding the moment one of those is present.

## 4. Installation and files

### 4.1 Python

Any Python 3.6 or newer works. There is nothing to install.

```bash
git clone https://github.com/drgfragkos/gLuhn.py.git
cd gLuhn.py
python3 gLuhn.py --version
python3 -m unittest discover -s tests
```

### 4.2 PowerShell

The script runs unchanged on Windows PowerShell 5.1 (built into Windows) and on PowerShell
7 (Windows, Linux, macOS). If scripts are blocked, allow them for the current process only.

```powershell
cd gLuhn.py
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\gLuhn.ps1 -Version
powershell -ExecutionPolicy Bypass -File tests\gLuhn.Tests.ps1
```

`-Version` prints which engine ran the script. The test script needs no Pester.

> **Note.** When stdin is redirected, the PowerShell host feeds it to the script as pipeline
> input and waits for end of file. Give scheduled or CI runs an explicit `< NUL` (Windows)
> or `< /dev/null` (Linux) unless you really pipe numbers in with `-File -`.

### 4.3 Data and network

| Data | Where it comes from | Network at run time |
|---|---|---|
| Scheme table | built into both scripts; extend with `--iin-table` | none |
| Issuer repository | `repository/bin-repository.json`, bundled; rebuild with `python3 repository/build_repository.py` | none (the rebuild downloads the open sources) |
| Extra BIN list | `--update-bin-db` downloads the open binlist-data CSV once, or any CSV of your own | only during `--update-bin-db` |
| Online lookup | `--lookup` queries binlist.net or any service with a `{iin}` URL | sends the 8/6-digit IIN of each distinct prefix, nothing else |

### 4.4 Files in the repository

```cards
CARD: gLuhn.py -> 5.1 UC1: Triage a number found in a ticket
  folder: repository root
  for: The Python implementation. Validation, generation, scanning, track and EMV decoding, issuer lookup.
  needs: Python 3.6 or later, standard library only
CARD: gLuhn.ps1 -> 5.1 UC1: Triage a number found in a ticket
  folder: repository root
  for: The PowerShell implementation with the same options and output.
  needs: Windows PowerShell 5.1 or PowerShell 7
CARD: bin-repository.json -> 5.3 UC3: Attribute a number to a bank and country
  folder: repository/
  for: The issuer repository shared by both scripts: bank, country, type and category per BIN, plus the brand-to-country-to-bank index.
  needs: nothing; rebuild with build_repository.py when the sources change
CARD: gluhn_repository.py -> 5.3 UC3: Attribute a number to a bank and country
  folder: repository/
  for: Python lookup module and small CLI over bin-repository.json; gLuhn.py imports it by path.
  needs: Python 3
CARD: GLuhnRepository.psm1 -> 5.3 UC3: Attribute a number to a bank and country
  folder: repository/
  for: PowerShell lookup module over the same JSON; gLuhn.ps1 imports it by path. Uses JavaScriptSerializer on 5.1 because ConvertFrom-Json is capped at 2 MB there.
  needs: Windows PowerShell 5.1 or PowerShell 7
CARD: build_repository.py -> 5.3 UC3: Attribute a number to a bank and country
  folder: repository/
  for: Builds bin-repository.json from the open BIN data sets and any extra CSV sources; later sources override earlier ones.
  needs: Python 3, network access for the default sources
CARD: tests -> 5.1 UC1: Triage a number found in a ticket
  folder: tests/
  for: test_gluhn.py and test_repository.py (unittest) and gLuhn.Tests.ps1 (no Pester). Both suites cover every mode.
  needs: Python 3 or PowerShell
CARD: update_iin_table.py -> 5.9 UC9: Extend the scheme table for a private label
  folder: Tools/
  for: Regenerates Tools/iin-table.braintree.json from the open-source braintree range list for use with --iin-table.
  needs: Python 3, network access to GitHub
CARD: Build-UserGuide.ps1 -> 5.1 UC1: Triage a number found in a ticket
  folder: Tools/
  for: Compiles Docs/User-Guide.md into this single-file HTML guide. See Docs/guide/README.md.
  needs: PowerShell 5.1 or 7
```

## 5. Use cases

Ten walkthroughs written the way the work arrives on an analyst's desk. Each has the same
four parts: the situation, the command, what to expect, and the next step. Python commands
are shown; the PowerShell spelling of every option is in [7.1](#s7/7.1).

### 5.1 UC1: Triage a number found in a ticket

**Situation.** A service desk ticket quotes "card 4929 4012 3456 7881 was charged twice".
Before anything else you need to know whether that is a real card number, which bank it
belongs to, and whether the ticket itself is now a PCI DSS problem.

```bash
python3 gLuhn.py -i '4929 4012 3456 7881'
```

**Expect.** One block: Luhn valid, scheme Visa with a fitting length, the issuer line from
the repository, no test number or look-alike label. With `-i` a 16-digit "American Express"
would be rejected outright, because Amex numbers have 15 digits:

```text
Scheme:       American Express  (IIN range 37; length mismatch, expects 15)
Result:       [-] Invalid PAN  (American Express numbers are 15 digits, not 16)
```

**Next.** A valid number in a ticket is cardholder data in a system that is probably out of
scope: mask it in the ticket, record the ticket id, and check whether the ticketing system
is scanned regularly (UC5). Add `-q` for one line per number, `-j` for JSON.

### 5.2 UC2: Complete a partially known number from a receipt

**Situation.** An investigator has a till receipt printing `4929 40** **** 7881` and a
statement showing the last four digits. Which full numbers are possible, and who issued
them?

```bash
python3 gLuhn.py '492940??????7881'
python3 gLuhn.py -b visa '492940??????7881' --max 100000000
```

**Expect.** The first line states the worst case number of candidates (10 to the power of
unknown digits minus one). Six unknowns means up to 100,000 Luhn-valid completions, so the
default limit refuses the pattern; the second command raises the limit and restricts the
search to Visa. Each completion is printed with its scheme and, in brackets, the bank and
country from the repository. Because all candidates share the BIN, the issuer is the same
for every line, which is often the useful answer on its own: the receipt is a Barclays Visa.

**Next.** Fewer unknowns give a short list. With only a check digit missing, the answer is a
single number. `--no-iin` lists every Luhn-valid completion regardless of scheme.

> **Attention.** Generated numbers are candidates, not accounts. Do not attempt
> transactions with them, and treat the list itself as cardholder data.

### 5.3 UC3: Attribute a number to a bank and country

**Situation.** Fraud analysts have a list of PANs from chargebacks and need the issuing
bank and country for each, offline.

```bash
python3 gLuhn.py -q -f chargebacks.txt
python3 gLuhn.py -j -f chargebacks.txt > chargebacks.json
python3 gLuhn.py --repo-list visa GB
python3 gLuhn.py --repo-issuer barclaycard
```

**Expect.** With `-q` one line per number; with `-j` each object carries a `repository`
field with bank, country code, type, category and the matching BIN range:

```text
Issuer (repo): BARCLAYS BANK UK PLC | VISA | CREDIT | GOLD | United Kingdom  [BIN 492940]
              www.barclays.co.uk 0800 151 0900
```

`--repo-list visa GB` prints the banks that issue Visa cards in the United Kingdom with
their websites; `--repo-issuer barclaycard` prints the brands and countries of a bank. Both
accept `-j` and `--format csv`.

An extra CSV BIN list can be layered on top with `--bin-db`: `--update-bin-db` downloads
the open binlist-data CSV once and `--bin-db auto` uses it. Any CSV with a header naming a
start column (`bin`, `iin`, `iin_start`, `prefix`) works; an optional end column turns rows
into ranges. The longest matching prefix wins.

**Next.** Keep the repository's `generated` date next to the attribution. To refresh or
extend the repository run `python3 repository/build_repository.py`, optionally with
`--source your-list.csv`; see `repository/README.md`.

### 5.4 UC4: Online IIN lookup for a handful of numbers

**Situation.** You are on a machine without the repository and need the issuer of two
numbers now.

```bash
python3 gLuhn.py --lookup 4929401234567881
python3 gLuhn.py --lookup --lookup-url 'https://bins.example.internal/api/{iin}' 4929401234567881
```

**Expect.** A notice that only the IIN is sent, then a lookup line with bank, scheme, brand,
type and country as returned by the service. The eight digit IIN is tried first, then the
six digit one. Results are cached per IIN for the run, and errors (rate limit, time-out, no
network) are reported on the lookup line without failing the validation.

**Next.** Public services such as binlist.net are rate limited; for batch work use the
bundled repository or a downloaded list (UC3).

> **Attention.** The lookup transmits the first eight digits of each distinct IIN to the
> service you name, nothing else. Do not point it at a service you do not trust with that
> information, and prefer the offline data in regulated environments.

### 5.5 UC5: Quarterly cardholder data discovery on a file share

**Situation.** The PCI DSS scope says cardholder data lives only in the payment
application. Requirement 12.5.2 asks you to confirm that, so the finance share, the
exports folder and last year's backups must be checked for stray PANs.

```bash
python3 gLuhn.py --scan /mnt/finance --mask --exclude '*.bak' --exclude node_modules
python3 gLuhn.py --scan /mnt/finance --mask --min-score 45
python3 gLuhn.py --scan /mnt/finance --include '*.xlsx' --include '*.csv' --include '*.pdf' --mask
```

**Expect.** One line per hit with confidence level, score, masked number, scheme and
`file:line:column`, followed by the signals that produced the score. Folders are walked
recursively; ZIP, DOCX, XLSX and PPTX archives are opened (nested up to three levels), PDFs
are read best-effort, UTF-16 files are decoded with or without a byte order mark, and other
files are scanned as text. Files over 64 MB are skipped and listed at the end.

```text
[+] HIGH    80  492940******7881         Visa                         /mnt/finance/refunds-2025.xlsx!xl/sharedStrings.xml:1:2210
    grouped digits, card keyword nearby, expiry nearby (possible SAD)
[+] LOW     15  424242******4242         Visa                         /mnt/finance/dev/fixtures.csv:3:6
    known test number (Stripe)

Scanned 1284 source(s); candidate PANs found: 2
```

**Next.** Review HIGH and MEDIUM hits in place, treat LOW hits with a test number signal as
leaked fixtures, then produce the evidence file (UC6). Repeat the run after remediation and
keep both outputs.

### 5.6 UC6: Produce evidence for the assessor

**Situation.** The findings from UC5 must go into the ROC or SAQ evidence pack without
exposing the numbers, and the assessor wants to know which files were reviewed.

```bash
python3 gLuhn.py --scan /mnt/finance --format csv --mask-style 8-4 > findings-2026Q4.csv
python3 gLuhn.py --scan /mnt/finance --format jsonl --mask | tee findings-2026Q4.jsonl
```

**Expect.** The CSV has one row per hit with source, line, column, masked PAN, scheme, IIN
range, confidence, score, signals, test card publisher, look-alike kind, issuer, duplicate
flag and the SHA-256 of the source file. `--mask-style 8-4` shows the first eight and last
four digits, which PCI DSS v4 permits for PANs of 16 digits or more; shorter numbers fall
back to six and four. JSON Lines carries the full result object per hit for SIEM ingestion.

**Next.** Sort by confidence, strip rows with a test card publisher into a separate
"fixtures" tab, and keep the hashes so the reviewed files can be identified after the
remediation run.

### 5.7 UC7: A skimmer dump or a POS log with track data

**Situation.** During an incident a log line or a dump file contains strings like
`;4929401234567881=2512201123456789?`. You need to know what it is and how bad it is.

```bash
python3 gLuhn.py ';4929401234567881=2512201123456789?'
python3 gLuhn.py '%B4929401234567881^DOE/JOHN^25121011234567890?'
python3 gLuhn.py 4929401234567881D25122011234567890F
```

**Expect.** The track type (track 1, track 2, or EMV tag 57 with the `D` separator), the
cardholder name on track 1, the expiry with a sanity verdict (expired, far future, invalid
month), the three digit service code decoded line by line (interchange and chip use,
authorisation processing, allowed services and PIN rule), the discretionary data with the
typical PVKI / PVV / CVV1 layout, an attention line about sensitive authentication data, and
the normal PAN assessment with the issuing bank.

**Next.** Full track data after authorisation is a requirement 3.3.1 failure and, in an
incident, a strong indicator of memory scraping or skimming. Scan the host for more
(`--scan`, UC5), and add `--mask` before pasting any output into the incident record.

### 5.8 UC8: Decode an EMV chip dump

**Situation.** A terminal log, a card reader tool or a forensic extraction gives you TLV hex
such as `70 81 87 5A 08 49 29 ...`, and the question is which card and application it is.

```bash
python3 gLuhn.py --emv 5A0849294012345678815F24032512315F3401014F07A0000000031010
python3 gLuhn.py --emv @record.hex --mask
```

**Expect.** A tree of tags with names and decoded values: application PAN (5A), expiry
(5F24), PAN sequence number (5F34), cardholder name (5F20), track 2 equivalent (57, 9F6B),
AID (4F, 84) mapped to scheme and product, issuer country (5F28), service code (5F30), and
bit by bit decodes of the AIP (82), AUC (9F07), CVM list (8E), TVR (95), TSI (9B), CID
(9F27), terminal capabilities and more. A summary block follows, then the PAN assessment
with the issuer. A warning is printed when the AID names one scheme and the PAN prefix
another.

**Next.** `-j` gives the whole tree as JSON. Hex may contain spaces, colons or `0x`
prefixes; `@file` reads it from a file.

### 5.9 UC9: Extend the scheme table for a private label

**Situation.** A retailer's store card or a new domestic scheme is missing from the
built-in table, so its numbers are reported as "unknown IIN".

```json
{
  "schemes": [
    { "key": "acme", "name": "ACME Store Card", "ranges": ["7001-7002"], "lengths": [16],
      "note": "private label" },
    { "key": "visa", "name": "Visa", "ranges": ["4"], "lengths": [16, 19] }
  ]
}
```

```bash
python3 gLuhn.py --iin-table my-schemes.json --list-schemes
python3 gLuhn.py --iin-table my-schemes.json -i 7001000000000004
python3 Tools/update_iin_table.py
python3 gLuhn.py --iin-table Tools/iin-table.braintree.json 4111111111111111
```

**Expect.** A scheme whose key matches a built-in one replaces it in place; new keys are
appended. `"replace": true` discards the built-in table. `update_iin_table.py` regenerates
a table from the open-source braintree range list so updates become a data refresh.

**Next.** Keep the JSON under version control next to your reports so results are
reproducible.

### 5.10 UC10: Verify that a database export contains only test cards

**Situation.** A developer says the customer table in the UAT export holds test cards
only. The assessor wants proof before UAT is declared out of scope.

```bash
python3 gLuhn.py --scan uat-export.sql --format csv --mask > uat-check.csv
python3 gLuhn.py --scan uat-export.sql --min-score 45 --mask
```

**Expect.** Every PAN in the export is listed with its publisher when it is a known test
number ("known test number (Mastercard)", "(Stripe)", ...) and with a low score. Any row
without a test card publisher, especially a HIGH or MEDIUM one with a real issuer in the
repository column, is a real number in a test system. The second command shows only those.

**Next.** If the second command prints nothing but the summary line, attach the CSV as
evidence. If it prints hits, UAT is in scope until the data is replaced, and the rows tell
the developer exactly which records to fix.

## 6. Playbooks

### 6.1 Something that looks like a card number arrived

```flow
START: A number, a track string or a hex dump arrived
STEP: Validate and identify it | python3 gLuhn.py -i <number>
SEE: Scheme, IIN range, length verdict, issuer line, test number or look-alike labels
DECIDE: Is it a real card number?
  Test number or look-alike -> record it as a fixture or an IMEI/ICCID, no finding
  Luhn fails or unknown IIN -> probably not a PAN; note it and move on
  Valid and identified -> continue
DECIDE: Did it come from a stripe read or a chip dump?
  Track string -> python3 gLuhn.py '<track data>'; the SAD warning makes it a 3.3.1 finding
  TLV hex -> python3 gLuhn.py --emv @dump.hex
  Plain number -> continue
DECIDE: Do you need more than the bundled issuer repository says?
  Yes, offline -> python3 gLuhn.py --bin-db auto <number> after one --update-bin-db
  Yes, online, few numbers -> python3 gLuhn.py --lookup <number> (sends the IIN only)
  No -> continue
DECIDE: Are there more where this came from?
  Yes -> python3 gLuhn.py --scan <folder> --format csv --mask > findings.csv
  No -> write up the single finding with masked output
END: Report with masked numbers, issuer attribution, confidence levels and file hashes
```

### 6.2 Cardholder data discovery for a PCI DSS scope review

```flow
START: Scope review or quarterly discovery is due
STEP: Agree the locations: file shares, exports, backups, ticketing, logs, UAT copies
STEP: Dry run on one folder to tune filters | python3 gLuhn.py --scan <folder> --mask --min-score 45
SEE: Hit counts, noise sources (fixtures, IMEIs, sequential numbers), skipped large files
DECIDE: Is the noise manageable?
  No -> add --exclude for build folders and backups of binaries, raise --min-score, rerun
  Yes -> continue
STEP: Full run with evidence output | python3 gLuhn.py --scan <root> --format csv --mask-style 8-4 > findings.csv
STEP: Triage the CSV: HIGH first, then MEDIUM; move rows with a test card publisher to a fixtures tab
DECIDE: Any hit with an expiry or CVV signal, or any track data?
  Yes -> sensitive authentication data: requirement 3.3.1 finding, incident process if production
  No -> continue
DECIDE: Any real PAN outside the documented cardholder data environment?
  Yes -> scope gap: remediate (delete, truncate, tokenise), rerun, keep both CSVs
  No -> scope confirmed for this cycle
END: Evidence pack: command lines, both CSVs, repository generated date, remediation tickets
```

> **Note.** Keep the three verdicts apart in the write-up: well formed (Luhn), identified
> (scheme and length), attributed (bank). A finding is only as strong as the weakest one you
> actually checked.

## 7. Reference

### 7.1 Options

| Python | PowerShell | Meaning |
|---|---|---|
| `PAN ...` | `PAN ...` | numbers, `?` patterns or track strings; separators (spaces, dashes, dots) are ignored |
| `-i`, `--iin` | `-i`, `-IIN` | validation also requires a known IIN and a fitting length |
| `--no-iin` | `-NoIIN` | generation and scan: Luhn only, no IIN filter |
| `--ignore-length` | `-IgnoreLength` | a length mismatch is not a failure |
| `-b`, `--brand LIST` | `-b`, `-Brand LIST` | restrict matching to these schemes (keys or names, comma separated) |
| `--active-only` | `-ActiveOnly` | ignore defunct schemes |
| `--no-catch-all` | `-NoCatchAll` | ignore the Maestro catch-all ranges 50 and 56-69 |
| `--iin-table JSON` | `-IinTable JSON` | extend or override the scheme table |
| `--max N` | `-Max N` | refuse generation above N Luhn candidates (default 10 million Python, 1 million PowerShell) |
| `-f`, `--file FILE` | `-f`, `-File FILE` | one input per line; `-` reads stdin; `#` starts a comment |
| `--scan PATH` | `-Scan PATH` | scan a file, folder, archive or `-` |
| `--include GLOB` | `-Include GLOB` | scan only matching file names (repeat the option in Python; comma list or array in PowerShell) |
| `--exclude GLOB` | `-Exclude GLOB` | skip matching files and folders |
| `--no-recursive` | `-NoRecursive` | top level of the folder only |
| `--no-archives` | `-NoArchives` | do not open ZIP and Office files |
| `--max-file-size MB` | `-MaxFileSize MB` | skip larger files (default 64) |
| `--min-score N` | `-MinScore N` | report only hits with score N or more |
| `--emv HEX` | `-Emv HEX` | decode EMV TLV data; `@file` reads a file |
| `--repo [JSON]` | `-Repo JSON` | issuer repository to use (default `repository/bin-repository.json`, automatic when present) |
| `--no-repo` | `-NoRepo` | do not use the issuer repository |
| `--repo-list BRAND [CC]` | `-RepoList BRAND[,CC]` | banks issuing a brand, optionally in one country, then exit |
| `--repo-issuer NAME` | `-RepoIssuer NAME` | brands and countries of a bank (name substring), then exit |
| `--bin-db CSV` | `-BinDb CSV` | extra BIN list for issuer lookup; `auto` means the downloaded file |
| `--update-bin-db` | `-UpdateBinDb` | download the open binlist-data CSV first |
| `--lookup` | `-Lookup` | online IIN lookup (IIN only) |
| `--lookup-url URL` | `-LookupUrl URL` | lookup template containing `{iin}` (default binlist.net) |
| `--lookup-timeout SEC` | `-LookupTimeout SEC` | lookup time-out (default 8) |
| `-m`, `--mask` | `-m`, `-Mask` | mask PANs in the output (first 6, last 4) |
| `--mask-style STYLE` | `-MaskStyle STYLE` | `6-4`, `8-4`, `last4`, `full`; implies mask |
| `--format FMT` | `-Format FMT` | `text`, `json`, `jsonl`, `csv` |
| `-j`, `--json` | `-j`, `-Json` | same as `--format json` |
| `-q`, `--quiet` | `-q`, `-Quiet` | one line per number |
| `--list-schemes` | `-ListSchemes` | print the scheme table and the MII legend |
| `-V`, `--version` | `-Version` | version (PowerShell also prints the engine) |

### 7.2 Exit codes

| Code | Meaning |
|---|---|
| 0 | at least one valid number, generated candidate, scan hit or repository row |
| 1 | nothing valid (also: EMV data could not be decoded, or an empty repository listing) |
| 2 | usage error: no input, bad option, unreadable BIN list, IIN table or repository |

### 7.3 Text output fields

| Line | Meaning |
|---|---|
| `Luhn` | valid or INVALID; schemes without a Luhn digit (enRoute) are noted |
| `MII` | first digit and industry; for 9 the country decoded from digits 2 to 4 |
| `IIN` | six and eight digit issuer identification number |
| `Scheme` | best match, its IIN range, the length verdict; defunct schemes are marked |
| `Also matches` | every other scheme whose range matched |
| `Issuer (repo)` | issuer, brand, type, category and country from the bundled repository, with the matching BIN range |
| `Issuer (DB)` | the same from an extra `--bin-db` CSV |
| `Lookup` | the online service result or its error |
| `Test number` | the publisher of the number as a test fixture (a scheme or a payment provider) |
| `Look-alike` | IMEI or ICCID hint |
| `Result` | the verdict and the reasons when invalid |

### 7.4 JSON fields

Validation objects carry `pan`, `length`, `well_formed`, `luhn`, `luhn_expected`, `mii`,
`iin6`, `iin8`, `scheme`, `scheme_key`, `scheme_active`, `scheme_note`, `iin_range`,
`length_ok`, `expected_lengths`, `also_matches`, `issuer`, `repository`, `test_card`,
`lookalike`, `lookup`, `valid` and `reasons`. Scan hits add `source`, `line`, `column`,
`duplicate`, `score`, `confidence`, `signals` and `sha256`. Track results are
`{track, validation}`; EMV results are `{tags, summary, bytes}`. One input gives one
object, several give an array, and `jsonl` gives one object per line.

### 7.5 Scheme table

| Scheme | IIN ranges | Lengths |
|---|---|---|
| Visa | 4 | 13, 16, 18, 19 |
| Visa Electron | 4026, 417500, 4508, 4844, 4913, 4917 | 16 |
| Dankort | 5019, 4571 (Visa/Dankort co-badge) | 16 |
| Mastercard | 2221-2720, 51-55 | 16 |
| Maestro | 5018, 5020, 5038, 5893, 6304, 6761, 6762, 6763; catch-all 50, 56-69 | 12-19 |
| Maestro UK | 6759, 676770, 676774 | 12-19 |
| American Express | 34, 37 | 15 |
| Diners Club International | 300-305, 3095, 36, 38-39 | 14-19 |
| Discover | 6011, 644-649, 65 | 16-19 |
| Discover (UnionPay co-processed) | 622126-622925 | 16-19 |
| JCB | 3528-3589 | 16-19 |
| China UnionPay | 62, 81 | 14-19 |
| China T-Union | 31 | 19 |
| UATP | 1 | 15 |
| Mir | 2200-2204 | 16-19 |
| BORICA | 2205 | 16 |
| Troy | 9792 and 65xxxx co-badges | 16 |
| RuPay | 60, 6521-6522, 81, 82, 508, 353, 356 | 16 |
| Verve | 506099-506198, 507865-507964, 650002-650027 | 16, 18, 19 |
| Elo | 27 ranges from 401178 to 655058 | 16 |
| Hipercard | 606282 | 13, 16, 19 |
| Hiper | 637095, 637568, 637599, 637609, 637612, 63737423, 63743358 | 16 |
| Naranja | 402918, 527572, 589562 | 16 |
| InterPayment | 636 | 16-19 |
| InstaPayment | 637-639 | 16 |
| UkrCard | 6040-6049 | 16-19 |
| NPS Pridnestrovie | 6054740-6054744 | 16 |
| LankaPay | 357111 | 16 |
| UzCard | 8600, 5614 | 16 |
| Humo | 9860 | 16 |
| Napas | 9704 | 16, 19 |
| GPN (Indonesia) | 1946 | 16, 18, 19 |
| Defunct: Bankcard, Diners Club enRoute (no Luhn), JCB legacy, Laser, Solo, Switch | see `--list-schemes` | |

### 7.6 Service code (ISO/IEC 7813)

| Digit | Value | Meaning |
|---|---|---|
| 1 | 1 | international interchange OK |
| 1 | 2 | international interchange, use chip where feasible |
| 1 | 5 | national interchange only, except under bilateral agreement |
| 1 | 6 | national interchange only, use chip where feasible |
| 1 | 7 | no interchange except under bilateral agreement (closed loop) |
| 1 | 9 | test |
| 2 | 0 | normal authorisation |
| 2 | 2 | contact issuer via online means |
| 2 | 4 | contact issuer via online means, except under bilateral agreement |
| 3 | 0 | no restrictions, PIN required |
| 3 | 1 | no restrictions |
| 3 | 2 | goods and services only (no cash) |
| 3 | 3 | ATM only, PIN required |
| 3 | 4 | cash only |
| 3 | 5 | goods and services only, PIN required |
| 3 | 6 | no restrictions, use PIN where feasible |
| 3 | 7 | goods and services only, use PIN where feasible |

### 7.7 EMV tags and AIDs

The decoder names more than a hundred tags and decodes the following beyond hex: 5A, 57,
9F6B (PAN and track 2 equivalent), 5F24, 5F25, 9A (dates), 5F34, 5F20, 50, 9F12, 5F28,
9F1A (issuer and terminal country), 5F2A, 9F42 (currency), 5F30 (service code), 82 (AIP),
8E (CVM list with conditions and failure rules), 94 (AFL), 95 and 9F0D/0E/0F (TVR bits),
9B (TSI), 9F07 (AUC), 9F27 (CID), 9F02 and 9F03 (amounts), 9C, 9F35, 9F39, 9F33, 9F34,
and the DOL tag lists 8C, 8D, 9F38, 9F49, 97. AIDs are mapped by longest prefix for Visa
(credit/debit, Electron, V PAY, Interlink, Plus, US common debit), Mastercard (credit/debit,
Maestro, Cirrus, US Maestro, Maestro UK, Solo), American Express, Discover (D-PAS, US
common debit, ZIP), JCB, UnionPay (debit, credit, quasi-credit, e-cash), Mir, RuPay, Troy,
Cartes Bancaires, girocard, PagoBANCOMAT, Dankort, Interac, eftpos, DNA, Elo and Verve.

### 7.8 Test numbers recognised

More than eighty numbers published for sandbox use by the schemes (Visa, Mastercard,
American Express, Discover, Diners Club, JCB, UnionPay, Maestro, Dankort) and by payment
service providers (Stripe, Braintree, Adyen, Worldpay). They validate normally, are labelled
with their publisher in text and JSON output ("Test number: ... (Mastercard)"), and lower
the scan confidence score. A number that appears in several lists is attributed to the
scheme first.

### 7.9 Issuer repository format

`repository/bin-repository.json` (format `gluhn-bin-repository/1`) holds `brands`,
`types`, `categories`, `countries` and `issuers` tables, `ranges` grouped by BIN prefix
length (each row `[lo, hi, brandId, typeId, categoryId, issuerId, countryCode]`, sorted and
non overlapping), a `by_brand` index of brand to country to issuer ids, and `sources` with
the row counts and licences of the data sets used. The full description and the rebuild
instructions are in `repository/README.md`.

## 8. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `[-] Invalid PAN (American Express numbers are 15 digits, not 16)` | the length rule of the scheme is applied with `-i` | drop `-i`, or add `--ignore-length` if the data source is known to pad numbers |
| A number is "valid" although it is obviously made up | without `-i` only Luhn is checked | add `-i`; read the test number and look-alike lines |
| Generation refuses with "raise --max" | more than seven unknown digits | narrow with `-b`, fix more digits, or raise `--max` deliberately |
| Generation lists many Maestro candidates | Maestro 50 and 56-69 are catch-all ranges | add `--no-catch-all` or `-b` |
| `[i] issuer repository not loaded` | `repository/bin-repository.json` is missing or unreadable | run `python3 repository/build_repository.py`, or ignore it: everything else still works |
| No `Issuer (repo)` line for a valid number | the BIN is not in the open data sets | try `--lookup`, or add a source to the repository and rebuild |
| PowerShell takes a few seconds longer per run | the repository JSON is parsed on every start | use `-NoRepo` for bulk validation runs that do not need the bank, or batch numbers with `-f` |
| `cannot load BIN database ...: No such file` with `--bin-db auto` | the list has not been downloaded | run once with `--update-bin-db` |
| `Lookup: ... HTTP 429` | the public service is rate limited | wait, or use the repository |
| `Lookup: ... URLError` or time-out | no network or a proxy in the way | check connectivity; the validation itself is unaffected |
| PowerShell: "running scripts is disabled" | execution policy | `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass` |
| PowerShell: `-Exclude` "specified more than once" | PowerShell takes one array per option | `-Exclude '*.bak','sub'` or `-Exclude '*.bak,sub'` |
| PowerShell hangs in a scheduled task | stdin is an open pipe and the host waits for end of file | redirect stdin from `NUL` or `/dev/null` |
| Scan finds nothing in a PDF | text is fragmented or stored in an encoded font | export the PDF to text with a dedicated tool and scan that |
| Scan reports digits from inside a binary file | binaries are scanned as text on purpose | review the signals; use `--min-score` or `--exclude` |
| Non-ASCII bank names look garbled on Windows PowerShell 5.1 | console code page | run `chcp 65001` first or write the output to a file |
| EMV: "constructed tag without valid TLV content" | a template contains proprietary data or the dump is truncated | the tag is shown as hex; check the dump length |

## 9. FAQ

**Q: Does a valid result mean the card exists or is active?** `[General]`

No. The Luhn check and the IIN table only say that the number is well formed and that
the prefix belongs to a network. Only the issuer can say whether an account exists.

**Q: What is the difference between validation with and without `-i`?** `[Usage]`

Without `-i` the number only has to pass the Luhn check, as in version 0.8. With `-i` the
IIN must be in the scheme table and the length must fit the scheme. Generation and scans
always apply that filter unless `--no-iin` is given.

**Q: Why does `???2109545565554` now return 41 numbers instead of 21?** `[Usage]`

The scheme table grew (Mastercard 2-series, UnionPay, RuPay, Maestro, UkrCard and more) and
16-digit American Express candidates disappeared because Amex numbers have 15 digits.

**Q: Which digits can I replace with `?`** `[Usage]`

Any, including the check digit and the IIN. One unknown digit is solved directly from the
Luhn formula; the others are enumerated, with prefixes pruned by the scheme table.

**Q: How accurate is the scheme table?** `[General]`

It is compiled from ISO/IEC 7812, the schemes' publications and the widely used open-source
range lists, and cross-checked against the braintree project. It identifies the network, not
the bank. Overlaps are resolved by the rules in [3.4](#s3/3.4) and every alternative is still
printed.

**Q: How do I see the issuing bank?** `[Usage]`

It is shown automatically from the bundled issuer repository ("Issuer (repo)"). For BINs
the repository does not know, add `--bin-db auto` after one `--update-bin-db` (offline) or
`--lookup` (online, IIN only). All three fill the issuer fields in JSON and CSV.

**Q: Which banks issue Visa cards in my country?** `[Usage]`

`--repo-list visa GB` (PowerShell: `-RepoList visa,GB`) lists them with their websites;
`--repo-issuer <name>` answers the reverse question for a bank. Brands accept the usual
aliases: `amex`, `unionpay`, `diners`, `mc`.

**Q: Where does the issuer data come from and how do I update it?** `[General]`

From open BIN data sets (the binlist.io merged list under CC BY 4.0 and the OpenBIIN
community database), compiled into `repository/bin-repository.json` by
`repository/build_repository.py`. Run the builder again to refresh it, and pass
`--source file.csv` to merge issuer lists from other places. Both scripts read the same JSON
through a small module each, so an update is a data change only.

**Q: Is anything sent over the network?** `[Security]`

Only when you ask for it. `--update-bin-db` and the repository builder download open data
files from GitHub. `--lookup` sends the first eight (then six) digits of each distinct IIN
to the service in `--lookup-url`. Nothing else leaves the machine; full PANs never do.

**Q: Which files can `--scan` read?** `[Usage]`

Plain text in UTF-8, UTF-16 (with or without BOM) and single-byte encodings, ZIP and
Office archives (DOCX, XLSX, PPTX, ODT, ODS, nested up to three levels), gzip files, PDFs
(best effort), and any other file as raw text. Folders are walked recursively unless
`--no-recursive` is given.

**Q: What do HIGH, MEDIUM and LOW mean?** `[Output]`

A confidence score from 0 to 100 built from the signals printed under each hit (specific
IIN, grouped digits, nearby card keywords, nearby expiry, test numbers, look-alikes,
repeated digits). HIGH is 70 or more, MEDIUM 45 or more. The score orders your review; it
is not a verdict.

**Q: Why is 4111111111111111 reported with a LOW score?** `[Output]`

It is Visa's best known test number and consists of repeated digits, so two signals lower
the score. It is still a well formed Visa number, which is why it appears at all.

**Q: A number is labelled "Test number (Mastercard)". What does that mean for my finding?** `[Output]`

The number is published by Mastercard for sandbox use and is not linked to a cardholder.
Its presence is evidence of test data in that location, not of a cardholder data exposure;
record it as a fixture and, if the location is production, as a data hygiene issue.

**Q: Can I get the results as CSV or JSON?** `[Output]`

Yes: `--format csv` and `--format jsonl` for scans, `-j` or `--format json` everywhere.
CSV rows include the SHA-256 of the source file so reviewed files can be identified later.

**Q: Which masking should I use in a report?** `[Security]`

`--mask` (first six, last four) is accepted everywhere. `--mask-style 8-4` is permitted by
PCI DSS v4 for PANs of 16 digits or more and keeps the full eight digit IIN visible.
`last4` and `full` are for documents that leave the organisation.

**Q: What is the warning about sensitive authentication data?** `[Security]`

Full track data, CVV values and PIN data must not be stored after authorisation (PCI DSS
v4 requirement 3.3.1). The tool prints the warning whenever it decodes track or chip data
and flags expiry or CVV-like values next to a PAN in scans, because their presence turns a
data finding into a compliance finding.

**Q: What does the EMV decoder need as input?** `[Usage]`

A hex string of BER-TLV data: a record read from the card, a GET PROCESSING OPTIONS or
GENERATE AC response, or a tag dump from a terminal log. Spaces, colons and `0x` prefixes
are ignored; `@file` reads the hex from a file.

**Q: A 15-digit number starting with 35 is reported as a probable IMEI. Why?** `[Output]`

IMEIs are 15-digit Luhn numbers whose first eight digits (the TAC) start with 35, 86, 01
and a few other prefixes. JCB numbers start with 3528 to 3589 but have 16 to 19 digits, so a
15-digit 35 number is far more likely to be a phone identifier. SIM ICCIDs (18 to 20
digits starting with 89) are labelled the same way.

**Q: Can I add my own ranges without editing the code?** `[Usage]`

Yes, with `--iin-table my.json` (see UC9). Keys that match a built-in scheme override it,
other keys are appended, and `"replace": true` starts from an empty table.

**Q: Why does the PowerShell script need `< NUL` in scheduled tasks?** `[Errors]`

When stdin is redirected to an open pipe, the PowerShell host feeds it to the script as
pipeline input and waits for end of file before the script runs. Interactive use is not
affected. Redirect stdin from `NUL` (Windows) or `/dev/null` unless you pipe numbers in.

**Q: The outputs of the Python and PowerShell scripts differ slightly. Is that expected?** `[Errors]`

They are meant to be identical and the test suites compare them. Report a difference with
both outputs; the usual cause is a different scheme table file or repository build on the
two machines.

**Q: How do I run the tests?** `[General]`

`python3 -m unittest discover -s tests` and `powershell -ExecutionPolicy Bypass -File
tests\gLuhn.Tests.ps1`. The PowerShell suite starts a small mock lookup server with Python
when it finds one, and skips those checks otherwise.

**Q: Where do the test numbers come from, and is listing them a problem?** `[Security]`

They are published by the card schemes and payment providers for sandbox use and are not
linked to accounts. Recognising them keeps developer fixtures out of findings.

> **Attribution.** gLuhn is written by @drgfragkos. You may modify, reuse and distribute the
> code freely as long as it is referenced back to the author with the line "..based on
> gLuhn.py by @drgfragkos". The issuer repository is compiled from the binlist.io merged
> BIN data (CC BY 4.0, itself built on iannuttall/binlist-data and
> venelinkochev/bin-list-data) and the OpenBIIN community database (GPL-3.0); the optional
> generated scheme table comes from the MIT licensed braintree credit-card-type project.
