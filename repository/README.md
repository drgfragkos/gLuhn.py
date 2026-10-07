# Issuer repository

`bin-repository.json` tells gLuhn which bank issued a card: the scheme table says "Visa",
the repository adds "issued by Barclays Bank PLC, United Kingdom, credit, Premier". It also
answers the reverse questions: which banks issue Visa cards in a country, and which brands a
given bank issues where.

The file is shared by both implementations through two small modules in this folder:

| File | Purpose |
|---|---|
| `bin-repository.json` | the data (format `gluhn-bin-repository/1`, about 7.4 MB) |
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

All sources are open data. The builder applies them in the order given; later sources override
earlier ones BIN by BIN, and an eight digit entry always beats a six digit one at lookup time.

| Name | What it is | Licence | Default |
|---|---|---|---|
| `binlistio` | binlist.io merged BIN list, https://github.com/Techbuddie-Solutions/binlist-data : 458,051 six digit BINs, a deterministic merge of iannuttall/binlist-data (2020) and venelinkochev/bin-list-data (February 2025), refreshed September 2026 | CC BY 4.0 | yes |
| `openbiin` | OpenBIIN community database, https://github.com/Wayproyect/openbiin : BIN6 plus two digit sub-ranges, i.e. eight digit precision, split into 100 CSV files | GPL-3.0 | yes |
| `venelin` | venelinkochev/bin-list-data : 374,788 BINs, February 2025 | CC BY 4.0 | no |
| `iannuttall` | iannuttall/binlist-data : 343,063 BINs, December 2020, archived | CC BY 4.0 | no |
| `binlistnet` | binlist/data `ranges.csv` : older binlist.net export, 5,805 scheme level rows | binlist.net open data | no |
| `--source FILE` | any CSV of your own, for example the per-brand issuer lists published at https://www.creditcardvalidator.org/visa (and `/mastercard`, `/amex`, `/unionpay`, `/diners`, `/discover`) exported to CSV, or a commercial table | yours | no |

Columns are detected by name (`bin`/`bin6`/`iin`/`iin_start`/`prefix`, optional `iin_end`/`bin_end`
or OpenBIIN `Ranges`, `brand`/`scheme`, `type`, `category`, `issuer`/`bank`/`bank_name`,
`alpha_2`/`isoCode2`/`country`, `bank_url`/`issuer_url`, `bank_phone`/`issuer_phone`); the delimiter is
sniffed; brand names and country names are normalised so the sources agree with each other.

```bash
python3 repository/build_repository.py                               # binlistio + openbiin, downloaded
python3 repository/build_repository.py --sources iannuttall,venelin,binlistio,openbiin
python3 repository/build_repository.py --local binlistio=bins.csv --local openbiin=./openbiin/functions/data
python3 repository/build_repository.py --source ccv-visa.csv --source ccv-mastercard.csv
python3 repository/build_repository.py --sources none --source only-this.csv
```

The builder merges consecutive BINs with identical attributes into ranges, normalises brand names
(`AMEX`, `MASTER CARD`, `CHINA UNION PAY`, `NSPK MIR` and friends), writes a lookup-ready layout
and records every source with its row count and licence in the JSON. Rebuilding is a data
refresh; no code changes.

Sources that were reviewed and not used: the jQuery-CreditCardValidator project (card-type
prefix patterns only, no banks) and commercial databases such as BinBase (3.3 million records
with 8 to 11 digit precision, licensed, not redistributable). Card schemes do not publish their
BIN tables; the ISO register of IINs is not public either.

## Format

```json
{
  "format": "gluhn-bin-repository/1",
  "generated": "2026-10-07",
  "sources": [{"name": "binlistio (https://github.com/Techbuddie-Solutions/binlist-data, CC BY 4.0)", "rows": 458051},
              {"name": "openbiin (https://github.com/Wayproyect/openbiin, GPL-3.0)", "rows": 381892}],
  "counts": {"bins": 590199, "ranges": 195767, "issuers": 24260, "countries": 226, "brands": 87},
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
