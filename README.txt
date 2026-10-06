# gLuhn.py / gLuhn.ps1

You may modify, reuse and distribute the code freely as long as it is referenced back
to the author using the following line: ..based on gLuhn.py by @drgfragkos

gLuhn v1.1 - Check/Generate PAN (Luhn), identify IIN/scheme and issuer, scan files, decode track
             and EMV data (c)gfragkos 2013-2026
gLuhn v1.0 - Check/Generate PAN (Luhn), identify IIN/scheme, decode track data (c)gfragkos 2013-2026
gLuhn.py v0.8 - Check/Generate PAN based on Luhn algorithm, validate IIN (c)gfragkos 2020
gLuhn.py v0.7 - Check/Generate PAN based on Luhn algorithm (c)gfragkos 2013

Two implementations with identical behaviour and output:

  gLuhn.py   Python 3.6+  (standard library only; numpy is no longer needed)
  gLuhn.ps1  one script for Windows PowerShell 5.1 and PowerShell 7+ (Windows, Linux, macOS);
             it detects the engine it runs under and adapts (JSON escaping, text encodings)

usage: gLuhn.py  [options] [PAN ...]
       gLuhn.ps1 [options] [PAN ...]

  PAN            digits only           -> Luhn check + scheme identification, test number and
                                          IMEI/ICCID look-alike labels, optional issuer lookup
  PAN with '?'   e.g. 4542109540?18054 -> generate every valid combination (IIN filtered)
  track data     ;4542...=2512201...?  -> parse track 1 / track 2 / EMV tag 57, decode the
                                          service code, expiry sanity, PVKI/PVV/CVV1 layout
  --scan PATH                          -> find candidate PANs in files, folders (recursive),
                                          ZIP/Office archives, PDFs, UTF-16 files; confidence
                                          score per hit; text, CSV or JSON Lines report
  --emv HEX                            -> decode EMV TLV data: tags, AID -> scheme/product,
                                          track 2 equivalent, CVM list, TVR/TSI/AIP/AUC bits

Full documentation: Docs/User-Guide.html (single file, open it in any browser) built from
Docs/User-Guide.md with Tools/Build-UserGuide.ps1 (see Docs/guide/README.md).

Options (Python / PowerShell):
  -i,  --iin / -Iin             validation: also require a known IIN/scheme and a plausible length
       --no-iin / -NoIin        generation and scan: Luhn only, no IIN filtering
       --ignore-length          do not treat a scheme length mismatch as a failure
  -b,  --brand BRANDS / -Brand  restrict matching to these schemes (comma separated, e.g. visa,mastercard)
       --active-only            ignore defunct schemes (Laser, Solo, Switch, Bankcard, enRoute, ...)
       --no-catch-all           ignore the broad Maestro catch-all ranges 50 and 56-69
       --iin-table JSON         extend or override the built-in scheme table (see User Guide UC9)
  -f,  --file FILE / -File      read one PAN / pattern / track per line ('-' = stdin, '#' = comment)
       --scan PATH / -Scan      scan a file, folder, archive or '-' (stdin) for candidate PANs
       --include GLOB, --exclude GLOB, --no-recursive, --no-archives, --max-file-size MB
       --min-score N            scan: report only hits with confidence score >= N
       --emv HEX / -Emv         decode EMV TLV hex data ('@file' reads a file)
       --bin-db CSV / -BinDb    CSV BIN/IIN database for issuing bank lookup ('auto' = downloaded file)
       --update-bin-db          download the open binlist-data CSV (about 25 MB) first
       --lookup                 online IIN lookup (binlist.net format); sends only the 8/6-digit IIN
       --lookup-url URL, --lookup-timeout SEC
       --max N / -Max           refuse generation above N Luhn candidates (default 1e7 / 1e6)
  -m,  --mask / -Mask           mask PANs in the output (first 6 / last 4, PCI DSS style)
       --mask-style STYLE       6-4 (default), 8-4 (PCI DSS v4, 16+ digits), last4, full
       --format FMT             text, json, jsonl, csv
  -j,  --json / -Json           JSON output (one object, or an array for several inputs)
  -q,  --quiet / -Quiet         one line per PAN
       --list-schemes           print the built-in IIN table and the MII table
  -V,  --version / -Version

Exit codes: 0 at least one valid PAN / result, 1 nothing valid, 2 usage error.


Note:
I couldn't find a tool capable of generating all possible combinations of valid card
numbers (PAN) while specific digits in the PAN are known already. The tool can be used
to validate a single PAN or it can generate all valid combinations for a partially
known PAN. This tool is meant to be useful for:
  a) data discovery
  b) digital forensics investigations
  c) OSINT
  d) Penetration Testing assessments related to PCI DSS / PA DSS


Examples:
>> PAN validation >>>>>>>>>>>>>>>>>>>>>>>>>>
A plain PAN is checked with the Luhn formula and the issuer identification number (IIN)
is looked up in the built-in scheme table:

$ python3 gLuhn.py 4542109540018054
PAN:          4542 1095 4001 8054  (16 digits)
Luhn:         valid
MII:          4 - Banking and financial (Visa)
IIN:          454210 / 45421095  (6-digit / 8-digit)
Scheme:       Visa  (IIN range 4; length OK)
Result:       [+] Valid PAN

Without -i the verdict is Luhn only (as in v0.8), so 1111222233334444 is still "valid".
With -i the IIN must be known and the length must fit the scheme:

$ python3 gLuhn.py -i 3742109545565554
...
Scheme:       American Express  (IIN range 37; length mismatch, expects 15)
Result:       [-] Invalid PAN  (American Express numbers are 15 digits, not 16)

$ python3 gLuhn.py -q 4111111111111111 4111111111111112
[+] Valid PAN   4111111111111111
[-] Invalid PAN 4111111111111112

>> PAN generation >>>>>>>>>>>>>>>>>>>>>>>>>>
Replace the unknown digits with question marks. Every Luhn-valid completion that also
belongs to a known IIN range with a matching length is printed, with its scheme:

$ python3 gLuhn.py 4542109540?18054
Attempting to generate up to 1 PAN combinations for: 4542109540?18054  (IIN filtered)
[+] Valid PAN  4542109540018054     Visa

Total valid PAN generated: 1

$ python3 gLuhn.py ???2109545565554
Attempting to generate up to 100 PAN combinations for: ???2109545565554  (IIN filtered)
[+] Valid PAN  2272109545565554     Mastercard
[+] Valid PAN  2322109545565554     Mastercard
...
[+] Valid PAN  4542109545565554     Visa
...
[+] Valid PAN  6562109545565554     Discover
...
[+] Valid PAN  8212109545565554     RuPay

Total valid PAN generated: 41

The generator never brute-forces all 10^k combinations: the last unknown digit is solved
directly from the Luhn formula (10x fewer candidates) and, when the IIN filter is on,
prefixes that cannot belong to any eligible scheme are pruned before the remaining digits
are enumerated. Use -b to restrict to given schemes, --no-iin for Luhn only.

>> Track data (magnetic stripe / EMV) >>>>>>>
Track 2 (";PAN=YYMMSSS...?"), track 1 format B ("%B PAN ^ NAME ^ YYMMSSS...?") and the EMV
"Track 2 Equivalent Data" (tag 57, 'D' separator, 'F' padding) are recognised. The PAN is
validated as above and the ISO/IEC 7813 service code is decoded:

$ python3 gLuhn.py ';4542109540018054=2512201123456789?'
Track data:   track2
Expiry:       2025-12 (YYMM 2512)
Service code: 201
              1: International interchange, use IC (chip) where feasible
              2: Normal
              3: No restrictions
Discretionary: 123456789
PAN:          4542 1095 4001 8054  (16 digits)
...

>> Data discovery >>>>>>>>>>>>>>>>>>>>>>>>>>
$ python3 gLuhn.py --scan ./exports --mask
[+] HIGH    80  454210******8054         Visa                         exports/orders.txt:2:7
    grouped digits, card keyword nearby, expiry nearby (possible SAD)
[+] LOW     15  424242******4242         Visa                         exports/dev/notes.log:1:6
    known test number (Stripe)

Scanned 5 source(s); candidate PANs found: 2

$ python3 gLuhn.py --scan ./exports --format csv --mask-style 8-4 --bin-db auto > findings.csv

>> EMV chip data >>>>>>>>>>>>>>>>>>>>>>>>>>>>
$ python3 gLuhn.py --emv 5A0845421095400180545F24032512315F3401014F07A0000000031010
EMV TLV:      26 bytes, 4 top-level objects
5A       Application PAN                              len   8  4542109540018054
5F24     Application Expiration Date                  len   3  2025-12-31
5F34     Application PAN Sequence Number              len   1  1
4F       Application Identifier (AID)                 len   7  A0000000031010
           - Visa: Visa credit / debit
...

>> Issuing bank lookup (optional BIN database) >>
The scheme table identifies the network. To see the issuing bank, country and card type
point --bin-db at any CSV BIN list, e.g. the open "binlist-data" file
(bin,brand,type,category,issuer,alpha_2,alpha_3,country,...). Any CSV with a header that
names a start column (bin / iin / iin_start / prefix) works; an optional end column
(iin_end / bin_end) turns rows into ranges. Longest matching prefix wins.

$ python3 gLuhn.py --bin-db binlist-data.csv 4542109540018054
...
Issuer (DB):  HALIFAX | VISA | DEBIT | CLASSIC | United Kingdom  [454210]

PowerShell examples (same options, PowerShell style):

PS> .\gLuhn.ps1 4542109540018054
PS> .\gLuhn.ps1 -i 3742109545565554
PS> .\gLuhn.ps1 ???2109545565554
PS> .\gLuhn.ps1 -b visa,mastercard ??42109545565554
PS> .\gLuhn.ps1 -Scan .\dump.txt -Mask
PS> .\gLuhn.ps1 -BinDb .\binlist-data.csv 4542109540018054
PS> Get-Content pans.txt | .\gLuhn.ps1 -f - -q
PS> Get-Help .\gLuhn.ps1 -Detailed

(If scripts are blocked: powershell -ExecutionPolicy Bypass -File .\gLuhn.ps1 ...)
.\gLuhn.ps1 -Version prints which engine ran it. Note for automation: when stdin is
redirected, the PowerShell host feeds it to the script as pipeline input and waits for
end-of-file, so give scheduled/CI runs an explicit "< NUL" (or "< /dev/null") unless
you really pipe PANs in with -f -.


=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+

Reference: how a PAN is built (ISO/IEC 7812)

  4542 1095 4001 805 4
  |    |              |
  |    |              +-- check digit (Luhn formula, ISO/IEC 7812-1 Annex B)
  |    +-- individual account identifier
  +-- IIN / BIN: 6 digits historically, 8 digits since ISO/IEC 7812-1:2017
      (industry migration April 2022). The tool prints both the 6- and 8-digit IIN.

  MII (first digit)   0 ISO/TC 68 and other industry assignments
                      1 Airlines (UATP)
                      2 Airlines, financial and other future industry assignments (Mastercard
                        2-series, Mir, BORICA)
                      3 Travel and entertainment (American Express, Diners Club, JCB)
                      4 Banking and financial (Visa)
                      5 Banking and financial (Mastercard, Maestro)
                      6 Merchandising and banking/financial (Discover, UnionPay, Maestro)
                      7 Petroleum and other future industry assignments
                      8 Healthcare, telecommunications and other future industry assignments
                      9 National assignment: digits 2-4 are the ISO 3166-1 numeric country
                        code (9792 Troy = Turkey, 9704 Napas = Vietnam, 9860 Humo = Uzbekistan)

  PAN length: up to 19 digits (ISO/IEC 7812-1:2017 sets the minimum at 10, previously 8).
  The tool accepts 8-19 digits and then applies the per-scheme length rules.

Built-in scheme table (print it with --list-schemes). Ranges are inclusive prefixes:

  Visa                4                          13, 16, 18, 19 (16 is the norm)
  Visa Electron       4026 417500 4508 4844 4913 4917            16
  Dankort             5019, 4571 (Visa/Dankort co-badge)         16
  Mastercard          2221-2720, 51-55                           16
  Maestro             5018 5020 5038 5893 6304 6761 6762 6763    12-19
                      catch-all 50, 56-69 (lowest precedence)
  Maestro UK          6759, 676770, 676774                       12-19
  American Express    34, 37                                     15
  Diners Club Intl    300-305, 3095, 36, 38-39                   14-19 (36), 16-19
  Discover            6011, 644-649, 65                          16-19
  Discover/UnionPay   622126-622925                              16-19
  JCB                 3528-3589                                  16-19
  China UnionPay      62, 81                                     14-19
  China T-Union       31                                         19
  UATP                1                                          15
  Mir                 2200-2204                                  16-19
  BORICA              2205                                       16
  Troy                9792 (+ 65xxxx co-badges)                  16
  RuPay               60, 6521-6522, 81, 82, 508, 353, 356       16
  Verve               506099-506198, 507865-507964, 650002-650027 16, 18, 19
  Elo                 401178 ... 655058 (27 ranges)              16
  Hipercard           606282                                     13, 16, 19
  Hiper               637095 637568 637599 637609 637612 ...     16
  Naranja             402918, 527572, 589562                     16
  InterPayment        636                                        16-19
  InstaPayment        637-639                                    16
  UkrCard             6040-6049                                  16-19
  NPS Pridnestrovie   6054740-6054744                            16
  LankaPay            357111                                     16
  UzCard              8600, 5614                                 16
  Humo                9860                                       16
  Napas               9704                                       16, 19
  GPN (Indonesia)     1946                                       16, 18, 19
  defunct, still identified: Bankcard 5610/560221-560225, Diners enRoute 2014/2149 (no Luhn),
  JCB legacy 1800/2131 (15 digits), Laser 6304/6706/6709/6771, Solo 6334/6767,
  Switch 4903/4905/4911/4936/564182/633110/6333/6759

Precedence when ranges overlap: a range whose length rule fits beats one that does not,
then the longer (more specific) range wins, a catch-all range loses to any same-length
range, an active scheme beats a defunct one. Every other match is still listed under
"Also matches" so the ambiguity is visible (e.g. 81 is UnionPay and RuPay).

Service code (ISO/IEC 7813, three digits found on track 1/2 and in EMV tag 57):
  1st  1 international OK | 2 international, chip where feasible | 5 national only |
       6 national only, chip where feasible | 7 no interchange (closed loop) | 9 test
  2nd  0 normal | 2 online authorisation | 4 online authorisation except bilateral agreement
  3rd  0 no restrictions, PIN | 1 no restrictions | 2 goods and services only | 3 ATM only, PIN |
       4 cash only | 5 goods and services only, PIN | 6 no restrictions, PIN where feasible |
       7 goods and services only, PIN where feasible

Accuracy notes:
- The scheme table is compiled from public sources (ISO/IEC 7812, the schemes' own
  publications and the widely used open-source range lists). Public IIN tables identify
  the network, not the issuing bank. For bank-level attribution use --bin-db with a BIN
  list you trust; 8-digit IINs are the current standard and the lookup uses the longest
  prefix available.
- Older China UnionPay cards were issued without a Luhn check digit; UnionPay numbers
  that fail Luhn are therefore reported but flagged.
- Maestro's 50 and 56-69 ranges are deliberately broad; use --no-catch-all when they
  create noise in generation or scanning.


Tests:
$ python3 -m unittest discover -s tests -v          (85 tests)
PS> powershell -ExecutionPolicy Bypass -File tests\gLuhn.Tests.ps1   (225 checks, no Pester)
The PowerShell suite starts tests/mock_lookup.py with Python when available to exercise the
online lookup against a local mock; otherwise those checks are skipped.


Download:
$ git clone https://github.com/drgfragkos/gLuhn.py.git


Version:
1.1.0 : 2026/10/06 - Issuer identification: --lookup (online, IIN only), --update-bin-db /
                     --bin-db auto (offline binlist-data), --iin-table JSON plus
                     Tools/update_iin_table.py. Data discovery: --scan walks folders, opens
                     ZIP/Office archives, PDFs (best effort), UTF-16 and binary files; every
                     hit gets a confidence score with signals; --format csv/jsonl with file
                     hashes; --include/--exclude/--min-score. Recognises published test card
                     numbers and IMEI/ICCID look-alikes. EMV TLV decoder (--emv) with tag
                     names, AID registry, CVM/TVR/TSI/AIP/AUC bit decoding. Track data:
                     expiry sanity, PVKI/PVV/CVV1 layout, SAD warning. --mask-style 6-4,
                     8-4, last4, full. Same features in gLuhn.ps1 (5.1 and 7+). Single-file
                     HTML user guide in Docs/.
1.0.0 : 2026/10/06 - Python 3 rewrite, no numpy. Done the to-do items: -i applies the IIN
                     check to plain validation, and every PAN is now identified (scheme,
                     IIN range, MII, length rule, defunct schemes, optional BIN database
                     for the issuing bank). New: up-to-date IIN table (Mastercard 2-series,
                     Discover 644-649/622126-622925, JCB 3528-3589, Mir, Troy, RuPay, Elo,
                     Verve, UnionPay, ...), 8-digit IIN, PANs up to 19 digits, faster
                     generator (Luhn solved analytically + IIN prefix pruning), brand
                     filter, track 1/2 and EMV tag 57 parsing with service code decoding,
                     text scanning, masking, JSON, stdin/file input, exit codes, tests.
                     PowerShell 5.1 port gLuhn.ps1 with the same behaviour and output.
0.8.0 : 2020/05/07 - GitHub update to include IIN checks
0.7.0 : 2015/05/15 - Released on GitHub.
0.6.0 : 2013/02/28 - Initial version not publicly released.


Dependencies:
Python 3.6 or newer, standard library only.    $ python3 --version
Windows PowerShell 5.1 (built into Windows) or PowerShell 7+ (tested on 7.4).


##                                                                                        ##
##                                                                                        ##
############################################################################################
