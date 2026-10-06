# Building the HTML user guide

The user guide is written in Markdown (`Docs/User-Guide.md`) and compiled into one
self-contained HTML file (`Docs/User-Guide.html`) by `Tools/Build-UserGuide.ps1`.
The HTML embeds its own CSS, JavaScript, icons and UI strings, so it can be opened
from disk, attached to an email or served from anywhere. It contains no external
references.

## Build

```powershell
# from the repository root, Windows PowerShell 5.1 or PowerShell 7
.\Tools\Build-UserGuide.ps1
```

```bash
# Linux / macOS with PowerShell 7
pwsh -NoProfile -File Tools/Build-UserGuide.ps1
```

Parameters (all optional; relative paths are resolved from the current directory,
the defaults from the repository root):

| Parameter | Default | Meaning |
|---|---|---|
| `-Source` | `Docs/User-Guide.md` | Markdown source |
| `-Strings` | `Docs/guide/strings.en.json` | UI strings for one language |
| `-Output` | `Docs/User-Guide.html` | Output file (UTF-8, no BOM) |
| `-CollapseAfter` | `14` | Code blocks longer than this get a "Show N more lines" toggle |

The script prints the output size, the number of sections and the number of FAQ
entries. It is pure ASCII and runs unchanged on Windows PowerShell 5.1 and
PowerShell 7.

To try the builder without the real guide, build the sample:

```bash
pwsh -NoProfile -File Tools/Build-UserGuide.ps1 -Source Docs/guide/sample/Sample-Guide.md -Output Docs/guide/sample/Sample-Guide.html
```

`Docs/guide/sample/Sample-Guide.md` exercises every convention listed below. Do not
commit the sample HTML.

## Files

```
Docs/
  User-Guide.md            the source
  User-Guide.html          the build output (do not edit by hand)
  guide/
    strings.en.json        UI labels, navigation groups, callout names, categories
    README.md              this file
    favicon/favicon.svg    icon source (embedded as a data URI)
    favicon/favicon.ico    16 / 32 / 48 px raster version (made by Tools/Make-Favicon.py)
    sample/Sample-Guide.md a small source that uses every convention
Tools/
  Build-UserGuide.ps1      the builder
  Make-Favicon.py          regenerates favicon.ico (Python 3, standard library only)
```

## Markdown conventions

| Pattern | Result |
|---|---|
| `# Title` | The product name (exactly one, at the top). Used in the rail and the browser title. |
| `## N. Title` | A top-level section, one tab in the rail. The number is part of the title and is used for cross references. |
| `### N.x Title` | A subsection: an entry in the "On this page" column, an anchor `#sN/slug`, and (for sections listed in `navSubsections`) a sub-item in the rail. |
| `#### Title` | A minor heading inside a subsection, no navigation entry. |
| Paragraphs, `**bold**`, `*italic*`, `` `code` ``, `[text](url)` | Rendered as usual. `#sN` links to section N; `#sN/anchor` to a subsection. |
| `> **Note.** text` | Callout, kind "note" (teal). Further `>` lines continue the callout; an empty `>` line starts a new paragraph. |
| `> **Attention.** text` | Callout, kind "attention" (amber). |
| `> **Attribution.** text` | Callout, kind "info" (blue); use it for credits and licences. |
| Pipe tables | Tables with a muted header row and hairline rules. `:---:` and `---:` set the alignment. |
| ```` ```lang ```` fenced code | A dark code card with a label bar (name from `codeLabels`), a Copy button and a "Show N more lines" toggle when longer than `CollapseAfter` lines. Always left-to-right. |
| ```` ```flow ```` | A decision-flow diagram (below). |
| ```` ```cards ```` | A grid of cards sorted by name (below). |
| `**Q: question** `[Category]`` | An FAQ entry: a collapsible question with a category chip. The paragraphs that follow are the answer, until the next question or heading. |
| `- item`, `1. item` | Bullet and numbered lists; indent by two spaces to nest. |
| `---` | Ignored (a visual separator in the source only). |
| `UC7` and similar | Autolinked to the subsection numbered `5.7` (pattern and target come from `autolink` in the strings file). |

Rules worth keeping:

- Exactly one `# Title` at the top; everything else is `##` and below.
- A "Contents" section is skipped (`skipSections`), so the Markdown stays readable
  on its own while the HTML uses the rail.
- No external images. Diagrams come from the `flow` DSL or inline SVG.
- Keep paragraphs short; running text is capped at about 88 characters per line.

### Anchors

The anchor of a subsection is the slug of its heading text: lower case, with runs of
anything other than Latin letters, digits and Arabic letters turned into `-`. The
heading `### 3.2 What the output means` in section 3 gets the id
`s3/3-2-what-the-output-means`, so link to it as `[text](#s3/3-2-what-the-output-means)`.
The router also accepts the bare number, `[text](#s3/3.2)`, and resolves it to the
heading that starts with that number.

### Decision flow

```
START: Something arrived
STEP: Do this first | optional command shown in a code strip
SEE: What the reader should observe
DECIDE: The question to answer
  Yes -> what happens then
  No -> what happens otherwise
END: Where this ends
```

Each node kind gets a coloured badge (Start and End teal, Decide amber, See grey,
Step dark). The text after ` | ` on a line is shown in a small code strip. Indented
`label -> outcome` lines under a Decide node become a two-column list. Badge texts
are translatable (`flowBadges`).

### Cards

```
CARD: Name -> N.x Subsection title
  folder: where it lives
  for: one or two sentences on what it is for
  needs: requirements
```

Cards are sorted by name and link to the subsection whose heading starts with the
given number (any section). A target that starts with `#` is used as is. `folder`
is shown in small monospace, `for` as the description and `needs` on a dashed rule
at the foot; any other `key: value` line is shown as a small meta row.

### FAQ

```
**Q: Does it phone home?** `[Security]`

No. Everything runs locally.
```

The section that contains FAQ entries gets a toolbar: a search box with a live
counter, three options (match all words, search answers too, whole words only), an
Expand all / Collapse all button and one chip per category. Entries are closed by
default; the search opens the matching ones and highlights the words. Press `/`
anywhere in the guide to jump to the search box. The category in brackets is either
a key or a display name from `categories` in the strings file; unknown names are
accepted and shown as written.

## Adding a language

1. Copy `Docs/guide/strings.en.json` to `Docs/guide/strings.<lang>.json` and
   translate every value. Set `lang` and, for right-to-left scripts, `"dir": "rtl"`:
   the CSS uses logical properties throughout, so the whole layout mirrors.
2. Translate the Markdown into `Docs/User-Guide.<lang>.md`. Keep the section numbers,
   the `N.x` subsection numbers, the fence names (`flow`, `cards`) and the `**Q:`
   marker; translate the callout labels to the names you put under `callouts`.
3. Build to a second self-contained file:

```powershell
.\Tools\Build-UserGuide.ps1 -Source Docs\User-Guide.ar.md -Strings Docs\guide\strings.ar.json -Output Docs\User-Guide.ar.html
```

## The strings file

| Key | Purpose |
|---|---|
| `lang`, `dir` | Values for `<html lang dir>`; `dir` is `ltr` or `rtl`. |
| `subtitle` | Shown under the product name in the rail (the product name comes from `# Title`). |
| `groups` | Rail groups: `[{ "name": "Learn", "sections": [1, 2, 3] }, ...]`. Sections not listed are appended in a group of their own. |
| `skipSections` | Section titles to drop, for example `["Contents"]`. |
| `navSubsections` | Numbers of the sections whose `###` subsections also appear as rail sub-items. |
| `countSubsections` | Numbers of the sections that show their subsection count as a badge. The FAQ section always shows its entry count. |
| `callouts` | Display names for `note`, `attention`, `info`. The Markdown label is matched against these names or the keys. |
| `codeLabels` | Fence name to label-bar text. |
| `flowBadges` | Badge texts for `start`, `step`, `see`, `decide`, `end`. |
| `onThisPage`, `searchPlaceholder`, `matchAll`, `searchAnswers`, `wholeWords`, `expandAll`, `collapseAll`, `all`, `noMatches`, `copy`, `copied`, `showFewer`, `backToTop` | UI labels. |
| `resultCounter` | FAQ counter template, `{shown}` and `{total}` are replaced. |
| `showMore` | Code toggle template, `{n}` is replaced. |
| `keyboardHint` | One line at the foot of the rail; the first `/` is rendered as a key cap. |
| `categories` | FAQ category keys and display names. |
| `emblem` | Optional inline SVG shown under the product name. Empty string to hide the row. |
| `autolink` | `{ "pattern": "\\bUC(\\d+)\\b", "target": "5.{1}" }`: identifiers that match the pattern link to the subsection whose heading starts with the target number. Capture groups are available as `{1}`, `{2}`, ... |
| `copyright` | Optional. Defaults to `© 2004-{year} @drgfragkos`; `{year}` is replaced at build time. Override it to add lines separated by `\n`, each rendered on its own line, for example `"© 2004-{year} @drgfragkos\nProductName. Internal tooling."` |

## Regenerating the icons

`favicon.svg` is hand-written. `favicon.ico` is produced from the same drawing by
`python3 Tools/Make-Favicon.py` (16, 32 and 48 px, 32-bpp with alpha). Both are
embedded in the HTML as data URIs; the files beside the HTML are only a convenience.
