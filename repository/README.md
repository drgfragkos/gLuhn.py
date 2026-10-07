# Issuer repository

`bin-repository.json` tells gLuhn which bank issued a card: the scheme table says "Visa",
the repository adds "issued by Barclays Bank PLC, United Kingdom, credit, Premier". It also
answers the reverse questions: which banks issue Visa cards in a country, and which brands a
given bank issues where.

The file is shared by both implementations through two small modules in this folder:

| File | Purpose |
|---|---|
| `bin-repository.json` | the data (format `gluhn-bin-repository/1`, about 4.7 MB) |
| `build_repository.py` | builds the JSON from the sources below (Python 3, standard library) |
| `gluhn_repository.py` | Python lookup module, used by `gLuhn.py`; also a small CLI |
| `GLuhnRepository.psm1` | PowerShell lookup module, used by `gLuhn.ps1` (5.1 and 7+) |

Both `gLuhn.py` and `gLuhn.ps1` use the repository automatically when the file exists; `--no-repo`
(`-NoRepo`) switches it off and `--repo PATH` (`-Repo PATH`) points at another file.

## Using it

```bash
python3 gLuhn.py 4929401234567881
#   Issuer (repo): BARCLAYS BANK PLC | VISA | CREDIT | PREMIER | United Kingdom  [BIN 492940]
python3 gLuhn.py --repo-list visa GB          # banks issuing Visa in the United Kingdom
python3 gLuhn.py --repo-list amex             # Amex issuers everywhere
python3 gLuhn.py --repo-issuer barclaycard    # brands and countries of a bank
python3 repository/gluhn_repository.py --info
```

```powershell
.\gLuhn.ps1 4929401234567881
.\gLuhn.ps1 -RepoList visa,GB
.\gLuhn.ps1 -RepoIssuer barclaycard
Import-Module .\repository\GLuhnRepository.psm1
$repo = Import-BinRepository
Find-BinRepositoryIssuer -Repository $repo -Pan 4929401234567881
```

Scan reports (`--format csv` / `jsonl`) fill their issuer column from the repository when no
`--bin-db` CSV is given, and generated candidates show the issuer in brackets.

## Sources and how to rebuild

1. **binlist-data** (default): the open BIN list at https://github.com/iannuttall/binlist-data,
   343,063 six and eight digit BINs with brand, type, category, issuer, country, bank URL and
   phone. About half of the rows carry no bank name but still give brand, type and country.
2. **Any extra CSV** (`--source`, repeatable): a BIN table you exported yourself, for example
   the per-brand issuer lists published at https://www.creditcardvalidator.org/visa (and
   `/mastercard`, `/amex`, `/unionpay`, `/diners`, `/discover`), or a commercial table. Columns
   are detected by name (`bin`/`iin`/`prefix`, optional `iin_end`, `brand`/`scheme`, `type`,
   `category`, `issuer`/`bank`, `alpha_2`/`country_code`, `country`, `bank_url`, `bank_phone`),
   the delimiter is sniffed, and later sources override earlier ones BIN by BIN.

```bash
python3 repository/build_repository.py                         # download binlist-data, write the JSON
python3 repository/build_repository.py --binlist ~/.gluhn/binlist-data.csv
python3 repository/build_repository.py --source ccv-visa.csv --source ccv-mastercard.csv
```

The builder merges consecutive BINs with identical attributes into ranges (343,063 BINs become
about 122,000 ranges), normalises brand names (`AMEX`, `MASTER CARD`, `CHINA UNION PAY` and
friends), and writes a lookup-ready layout. Rebuilding is a data refresh; no code changes.

The jQuery-CreditCardValidator project was reviewed as a candidate source: it only contains
card-type prefix patterns, no issuing banks, so it is not used.

## Format

```json
{
  "format": "gluhn-bin-repository/1",
  "generated": "2026-10-07",
  "sources": [{"name": "binlist-data (...)", "rows": 343063}],
  "counts": {"bins": 343063, "ranges": 122307, "issuers": 13291, "countries": 199, "brands": 25},
  "brands": ["VISA", "MASTERCARD", "..."],
  "types": ["", "CREDIT", "DEBIT", "..."],
  "categories": ["", "CLASSIC", "GOLD", "..."],
  "countries": {"GB": "United Kingdom", "...": "..."},
  "issuers": [{"n": "BARCLAYS BANK PLC", "c": "GB", "u": "www.barclays.co.uk", "p": "0800 ..."}],
  "ranges": {
    "6": [[492940, 492940, 1, 1, 51, 364, "GB"], "..."],
    "8": ["..."]
  },
  "by_brand": {"VISA": {"GB": [364, "..."]}}
}
```

- `ranges[L]` holds the ranges whose BIN prefix has `L` digits, sorted by `lo`, non overlapping.
  A row is `[lo, hi, brandId, typeId, categoryId, issuerId, countryCode]`; ids index the
  `brands`, `types`, `categories` and `issuers` arrays; `issuerId` is `-1` when the bank is unknown.
- A lookup takes the first `L` digits of the PAN for the longest `L` first and binary-searches
  `ranges[L]`; an 8-digit entry therefore beats a 6-digit one.
- `by_brand` maps brand to country to issuer ids for the "who issues what where" questions.

## Accuracy

BIN assignments change: banks merge, portfolios move, ranges are re-issued. Treat the result as
"issued by X according to the list dated `generated`", keep the date in reports, and rebuild
from fresh sources when precision matters. The scheme (network) is still decided by gLuhn's
built-in table; the repository adds the issuer level.
