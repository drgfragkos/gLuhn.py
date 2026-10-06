# Sample Toolkit

A small guide that exercises every Markdown convention the builder recognises.
Build it with `Tools/Build-UserGuide.ps1 -Source Docs/guide/sample/Sample-Guide.md -Output Docs/guide/sample/Sample-Guide.html`.

## Contents

1. Quick start
2. Installation
3. Concepts
4. Playbook
5. Use cases
6. Tools
7. FAQ

(This section is skipped by the builder: the HTML uses the navigation rail instead.)

---

## 1. Quick start

Get a first result in under a minute. The command below validates one number and
prints the result; the walkthrough in UC2 shows how to generate numbers instead.

### 1.1 Run the check

```powershell
.\sample.ps1 4111111111111111
```

You should see one line with the verdict and the detected scheme, as in
[the output table](#s3/3-2-what-the-output-means).

> **Note.** The script needs no installation when you only want to run it once.
> For a permanent setup, see [Installation](#s2).

### 1.2 Try a second number

Numbers that contain a `?` are treated as patterns: every digit that makes the
number valid is generated, and the result is filtered by scheme. The **first**
run may take a second longer while the scheme table is loaded.

- Digits only: validate the number.
- Digits with `?`: generate every valid completion.
- Track data (starts with `;` or `%`): decode and validate.

#### What is checked

1. The checksum (Luhn mod 10).
2. The issuer range, when `-Iin` is given.
3. The length allowed for the detected scheme.

## 2. Installation

Pick the engine you already have. Nothing else is downloaded.

| Engine | Version | Command |
|---|---|---|
| Python | 3.6 or later | `python3 sample.py` |
| PowerShell | 5.1 or 7+ | `.\sample.ps1` |
| Command Prompt | any | `powershell -File sample.ps1` |

### 2.1 Windows

Copy the script next to your data and run it from a PowerShell window. If the
execution policy blocks the script, allow it for the current process only:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

> **Attention.** Do not loosen the execution policy machine-wide. The process
> scope is enough and resets when the window closes.

### 2.2 Linux and macOS

```bash
chmod +x sample.py
./sample.py --help
```

> **Attribution.** Based on *gLuhn.py* by @drgfragkos. You may reuse the code
> freely as long as the attribution line is kept.

## 3. Concepts

### 3.1 How validation works

The last digit is a check digit computed from the others. A single mistyped digit
or most transpositions change the checksum, which is why the check catches typos
but says nothing about whether an account exists. See UC1 for a worked example.

### 3.2 What the output means

| Column | Meaning |
|---|---|
| `OK` / `FAIL` | Checksum verdict |
| `scheme` | Detected card scheme, or `unknown` |
| `length` | Whether the length matches the scheme |

#### A longer listing

The file below is deliberately longer than the collapse threshold so that the
"Show N more lines" toggle appears.

```python
#!/usr/bin/env python3
"""Luhn checksum in a few lines."""
import sys


def luhn_ok(number: str) -> bool:
    digits = [int(c) for c in number if c.isdigit()]
    total = 0
    parity = len(digits) % 2
    for index, digit in enumerate(digits):
        if index % 2 == parity:
            digit *= 2
            if digit > 9:
                digit -= 9
        total += digit
    return total % 10 == 0


def main(argv):
    if not argv:
        print("usage: sample.py NUMBER [NUMBER ...]")
        return 2
    code = 0
    for arg in argv:
        verdict = "OK" if luhn_ok(arg) else "FAIL"
        print(f"{arg:20} {verdict}")
        if verdict == "FAIL":
            code = 1
    return code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
```

## 4. Playbook

What an experienced reader does when a number arrives from somewhere.

```flow
START: A number arrived in a ticket or a log
STEP: Validate it first | .\sample.ps1 4111111111111111
SEE: One line with OK or FAIL and the detected scheme
DECIDE: Is the verdict OK?
  Yes -> continue with UC3 to decode the rest of the record
  No -> the number is mistyped or truncated; ask for it again
STEP: Record the scheme and the length in the ticket
END: Done; keep the output, not the number
```

## 5. Use cases

Each use case has the same four beats: the situation, the command, what to
expect, and the next step.

### 5.1 Validate one number

**Situation.** Someone pasted a number and asks whether it is plausible.

```powershell
.\sample.ps1 4111111111111111
```

**Expect** one line with `OK` and the scheme. **Next:** UC2 if you need more numbers.

### 5.2 Generate numbers from a pattern

**Situation.** You need test data that passes the checksum.

```powershell
.\sample.ps1 411111111111111?
```

**Expect** one line per valid completion. **Next:** UC3 to decode track data.

### 5.3 Decode track data

**Situation.** A record starts with `;` or `%`.

```text
;4111111111111111=25122011234567890?
```

**Expect** the fields of track 2, the service code decoded, and the PAN validated.
**Next:** [the output table](#s3/3.2).

## 6. Tools

A visual table of contents of the family of scripts; the grid is sorted by name.

```cards
CARD: sample.ps1 -> 5.1 Validate one number
  folder: Tools\sample.ps1
  for: Validates, generates and decodes from a PowerShell window.
  needs: Windows PowerShell 5.1 or PowerShell 7
CARD: sample.py -> 5.2 Generate numbers from a pattern
  folder: Tools/sample.py
  for: The same behaviour for Python, standard library only.
  needs: Python 3.6 or later
CARD: decode-track -> 5.3 Decode track data
  folder: Tools/decode-track.py
  for: Splits track 1 and track 2 records and explains the service code.
  needs: Python 3.6 or later
```

## 7. FAQ

**Q: Does the check prove that an account exists?** `[General]`

No. The checksum only catches typos. See [How validation works](#s3/3-1-how-validation-works).

**Q: Which engines are supported?** `[General]`

Python 3.6 or later and PowerShell 5.1 or 7. The behaviour is the same, see [Installation](#s2).

**Q: Why does a pattern with several `?` take longer?** `[Usage]`

Every combination is generated and filtered. Two question marks mean one hundred candidates, three mean one thousand. UC2 explains the pattern syntax.

**Q: Can I restrict generation to one scheme?** `[Usage]`

Yes, pass `-Brand visa` (or `--brand visa` for Python). Several schemes are separated by commas.

**Q: What does `length` mean in the output?** `[Output]`

Whether the number of digits is one that the detected scheme actually issues. A valid checksum with a wrong length is reported as a mismatch.

**Q: Is anything sent over the network?** `[Output]`

Nothing. All checks run locally against an embedded table.

**Q: Where is the scheme table kept?** `[General]`

Inside the script itself, so a single file is enough.
