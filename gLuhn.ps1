<#
.SYNOPSIS
    gLuhn.ps1 v1.0 - Check / generate PAN (Luhn), identify the card scheme (IIN) and decode
    magnetic-stripe / EMV track data.  Windows PowerShell 5.1 port of gLuhn.py.
    (c) gfragkos 2013-2026

    You may modify, reuse and distribute the code freely as long as it is referenced back
    to the author using the following line: ..based on gLuhn.py by @drgfragkos

.DESCRIPTION
    Modes (chosen automatically from the input):

      PAN            digits only           -> Luhn check + scheme / issuer identification
      PAN with '?'   e.g. 4542109540?18054 -> generate every valid combination
      Track data     4542...=2512101...    -> parse track 1 / track 2 (or EMV tag 57),
                                              validate the PAN and decode the service code
      -Scan FILE                           -> find candidate PANs in arbitrary text

.PARAMETER PAN
    One or more PANs, PAN patterns (digits and '?') or track strings.
.PARAMETER Iin
    (-i) Validation: also require a known IIN/scheme and a plausible length.
.PARAMETER NoIin
    Generation / scan: do not filter candidates by IIN/scheme (Luhn only).
.PARAMETER IgnoreLength
    Do not treat a scheme length mismatch as a failure.
.PARAMETER Brand
    (-b) Restrict IIN matching to these schemes (comma separated keys or names).
.PARAMETER ActiveOnly
    Ignore defunct schemes.
.PARAMETER NoCatchAll
    Ignore the broad Maestro catch-all ranges (50, 56-69).
.PARAMETER File
    (-f) Read one PAN / pattern / track per line ('-' = stdin).
.PARAMETER Scan
    Scan a text file for candidate PANs ('-' = stdin).
.PARAMETER BinDb
    CSV BIN/IIN database for issuer lookup (e.g. the open binlist-data CSV).
.PARAMETER Max
    Refuse generation when more than N Luhn candidates must be visited (default 1e6).
.PARAMETER Mask
    (-m) Mask PANs in the output (first 6 / last 4).
.PARAMETER Json
    (-j) JSON output.
.PARAMETER Quiet
    (-q) One line per PAN.
.PARAMETER ListSchemes
    Print the built-in IIN table and exit.
.PARAMETER Version
    Print the version banner and exit.
.PARAMETER Piped
    Pipeline input; read it with -File - (e.g. Get-Content pans.txt | .\gLuhn.ps1 -f -).

.EXAMPLE
    .\gLuhn.ps1 4542109540018054
.EXAMPLE
    .\gLuhn.ps1 -i 3742109545565554
.EXAMPLE
    .\gLuhn.ps1 ???2109545565554
.EXAMPLE
    .\gLuhn.ps1 -b visa,mastercard ??42109545565554
.EXAMPLE
    .\gLuhn.ps1 -Scan .\dump.txt -Mask
.EXAMPLE
    .\gLuhn.ps1 -BinDb .\binlist-data.csv 4542109540018054
.EXAMPLE
    '4542109540018054' | .\gLuhn.ps1 -f -
.EXAMPLE
    .\gLuhn.ps1 ';4542109540018054=2512201123456789?'
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$PAN,
    [Alias('i')][switch]$Iin,
    [switch]$NoIin,
    [switch]$IgnoreLength,
    [Alias('b')][string[]]$Brand,
    [switch]$ActiveOnly,
    [switch]$NoCatchAll,
    [Alias('f')][string]$File,
    [string]$Scan,
    [string]$BinDb,
    [long]$Max = 1000000,
    [Alias('m')][switch]$Mask,
    [Alias('j')][switch]$Json,
    [Alias('q')][switch]$Quiet,
    [switch]$ListSchemes,
    [switch]$Version,
    # Lines piped into the script (used with -File -); collected through $input below.
    [Parameter(ValueFromPipeline = $true)]
    [string[]]$Piped
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Anything piped into the script (Get-Content pans.txt | .\gLuhn.ps1 -f -) is captured here.
$script:PipelineInput = @($input | ForEach-Object { [string]$_ })

$script:GLUHN_VERSION = '1.0.0'
$script:BANNER = "gLuhn.ps1 v$($script:GLUHN_VERSION) - Check/Generate PAN (Luhn), identify IIN/scheme, decode track data (c)gfragkos 2013-2026"

# ISO/IEC 7812-1: a PAN is at most 19 digits (the 2017 edition sets the minimum at 10,
# previously 8).  8..19 is accepted so legacy numbers are still recognised.
$script:PAN_MIN_LEN = 8
$script:PAN_MAX_LEN = 19
$script:IIN_LEN_LEGACY = 6     # IIN was 6 digits ...
$script:IIN_LEN = 8            # ... and is 8 digits since ISO/IEC 7812-1:2017 (migration April 2022)

# ---------------------------------------------------------------------------------
# ISO/IEC 7812 - Major Industry Identifier (first digit of the PAN)
# ---------------------------------------------------------------------------------
$script:MII = [ordered]@{
    '0' = 'ISO/TC 68 and other industry assignments'
    '1' = 'Airlines'
    '2' = 'Airlines, financial and other future industry assignments'
    '3' = 'Travel and entertainment (Amex, Diners Club, JCB)'
    '4' = 'Banking and financial (Visa)'
    '5' = 'Banking and financial (Mastercard, Maestro)'
    '6' = 'Merchandising and banking/financial (Discover, UnionPay, Maestro)'
    '7' = 'Petroleum and other future industry assignments'
    '8' = 'Healthcare, telecommunications and other future industry assignments'
    '9' = 'National assignment (digits 2-4 are the ISO 3166-1 numeric country code)'
}

# ISO 3166-1 numeric codes used when the MII is 9 (Troy 9792 = Turkey, Napas 9704 = Vietnam, ...)
$script:ISO3166 = @{
    '004' = 'Afghanistan'; '012' = 'Algeria'; '031' = 'Azerbaijan'; '032' = 'Argentina'
    '036' = 'Australia'; '040' = 'Austria'; '048' = 'Bahrain'; '050' = 'Bangladesh'
    '051' = 'Armenia'; '056' = 'Belgium'; '076' = 'Brazil'; '100' = 'Bulgaria'
    '112' = 'Belarus'; '124' = 'Canada'; '144' = 'Sri Lanka'; '152' = 'Chile'
    '156' = 'China'; '158' = 'Taiwan'; '170' = 'Colombia'; '191' = 'Croatia'
    '196' = 'Cyprus'; '203' = 'Czechia'; '208' = 'Denmark'; '231' = 'Ethiopia'
    '233' = 'Estonia'; '246' = 'Finland'; '250' = 'France'; '268' = 'Georgia'
    '276' = 'Germany'; '288' = 'Ghana'; '300' = 'Greece'; '344' = 'Hong Kong'
    '348' = 'Hungary'; '356' = 'India'; '360' = 'Indonesia'; '364' = 'Iran'
    '368' = 'Iraq'; '372' = 'Ireland'; '376' = 'Israel'; '380' = 'Italy'
    '392' = 'Japan'; '398' = 'Kazakhstan'; '400' = 'Jordan'; '404' = 'Kenya'
    '410' = 'South Korea'; '414' = 'Kuwait'; '428' = 'Latvia'; '440' = 'Lithuania'
    '458' = 'Malaysia'; '470' = 'Malta'; '484' = 'Mexico'; '504' = 'Morocco'
    '512' = 'Oman'; '524' = 'Nepal'; '528' = 'Netherlands'; '554' = 'New Zealand'
    '566' = 'Nigeria'; '578' = 'Norway'; '586' = 'Pakistan'; '604' = 'Peru'
    '608' = 'Philippines'; '616' = 'Poland'; '620' = 'Portugal'; '634' = 'Qatar'
    '642' = 'Romania'; '643' = 'Russia'; '682' = 'Saudi Arabia'; '688' = 'Serbia'
    '702' = 'Singapore'; '703' = 'Slovakia'; '704' = 'Vietnam'; '705' = 'Slovenia'
    '710' = 'South Africa'; '724' = 'Spain'; '752' = 'Sweden'; '756' = 'Switzerland'
    '764' = 'Thailand'; '784' = 'United Arab Emirates'; '788' = 'Tunisia'
    '792' = 'Turkey'; '800' = 'Uganda'; '804' = 'Ukraine'; '818' = 'Egypt'
    '826' = 'United Kingdom'; '834' = 'Tanzania'; '840' = 'United States'
    '860' = 'Uzbekistan'
}

# ---------------------------------------------------------------------------------
# ISO/IEC 7813 - Service code (track 1 / track 2 / EMV tag 57 "Track 2 Equivalent")
# ---------------------------------------------------------------------------------
$script:SERVICE_CODE_1 = @{
    '1' = 'International interchange OK'
    '2' = 'International interchange, use IC (chip) where feasible'
    '5' = 'National interchange only, except under bilateral agreement'
    '6' = 'National interchange only, except under bilateral agreement; use IC (chip) where feasible'
    '7' = 'No interchange except under bilateral agreement (closed loop)'
    '9' = 'Test'
}
$script:SERVICE_CODE_2 = @{
    '0' = 'Normal'
    '2' = 'Contact issuer via online means'
    '4' = 'Contact issuer via online means, except under bilateral agreement'
}
$script:SERVICE_CODE_3 = @{
    '0' = 'No restrictions, PIN required'
    '1' = 'No restrictions'
    '2' = 'Goods and services only (no cash)'
    '3' = 'ATM only, PIN required'
    '4' = 'Cash only'
    '5' = 'Goods and services only (no cash), PIN required'
    '6' = 'No restrictions, use PIN where feasible'
    '7' = 'Goods and services only (no cash), use PIN where feasible'
}

# ---------------------------------------------------------------------------------
# Card scheme / network table (public IIN ranges, ISO/IEC 7812 + scheme publications)
# ---------------------------------------------------------------------------------
# Matching precedence when several ranges overlap:
#   1. longer (more specific) range wins   e.g. 622126-622925 Discover beats 62 UnionPay
#   2. a "catch-all" range (Maestro 50 / 56-69) loses to any range of the same length
#   3. an active scheme beats a defunct one  e.g. Maestro 6304 beats Laser 6304
#   4. table order
# All matches are reported ("also matches ...") so the ambiguity is never hidden.

function ConvertTo-IinRange {
    param([string]$Spec, [bool]$CatchAll = $false)
    if ($Spec.Contains('-')) {
        $parts = $Spec.Split('-', 2)
        $lo = $parts[0]; $hi = $parts[1]
    } else {
        $lo = $Spec; $hi = $Spec
    }
    if ($lo.Length -ne $hi.Length -or $lo -notmatch '^\d+$' -or $hi -notmatch '^\d+$' -or
        [string]::CompareOrdinal($lo, $hi) -gt 0) {
        throw "bad IIN range specification: $Spec"
    }
    return @{ Lo = $lo; Hi = $hi; CatchAll = $CatchAll }
}

function New-Scheme {
    param(
        [string]$Key, [string]$Name, [string[]]$Ranges, [int[]]$Lengths,
        [bool]$Luhn = $true, [bool]$Active = $true, [string]$Note = '', [string[]]$CatchAll = @()
    )
    $list = New-Object System.Collections.ArrayList
    foreach ($r in $Ranges)   { [void]$list.Add((ConvertTo-IinRange -Spec $r -CatchAll $false)) }
    foreach ($r in $CatchAll) { [void]$list.Add((ConvertTo-IinRange -Spec $r -CatchAll $true)) }
    return @{
        Key = $Key; Name = $Name; Ranges = $list.ToArray()
        Lengths = @($Lengths | Sort-Object -Unique); Luhn = $Luhn; Active = $Active; Note = $Note; Order = 0
    }
}

$L16 = @(16)
$L16_19 = @(16, 17, 18, 19)
$L12_19 = @(12, 13, 14, 15, 16, 17, 18, 19)

$script:SCHEMES = @(
    # --- global networks -----------------------------------------------------------
    (New-Scheme -Key 'visa' -Name 'Visa' -Ranges @('4') -Lengths @(13, 16, 18, 19) `
        -Note 'MII 4; 16 digits is the norm, 13-digit numbers are legacy, 18/19 exist'),
    (New-Scheme -Key 'visa_electron' -Name 'Visa Electron' -Ranges @('4026', '417500', '4508', '4844', '4913', '4917') -Lengths $L16),
    (New-Scheme -Key 'dankort' -Name 'Dankort' -Ranges @('5019', '4571') -Lengths $L16 `
        -Note '4571 is the co-badged Visa/Dankort range (Denmark)'),
    (New-Scheme -Key 'mastercard' -Name 'Mastercard' -Ranges @('2221-2720', '51-55') -Lengths $L16 `
        -Note '2-series (2221-2720) issued since 2017; 54/55 also carries the former Diners Club US & Canada portfolio'),
    (New-Scheme -Key 'maestro' -Name 'Maestro' `
        -Ranges @('5018', '5020', '5038', '5893', '6304', '6761', '6762', '6763') -Lengths $L12_19 `
        -CatchAll @('50', '56-69') -Note 'debit; 50 and 56-69 are catch-all ranges shared with other schemes'),
    (New-Scheme -Key 'maestro_uk' -Name 'Maestro UK (formerly Switch)' -Ranges @('6759', '676770', '676774') -Lengths $L12_19),
    (New-Scheme -Key 'amex' -Name 'American Express' -Ranges @('34', '37') -Lengths @(15)),
    (New-Scheme -Key 'diners' -Name 'Diners Club International' -Ranges @('300-305', '3095', '36', '38-39') `
        -Lengths @(14, 15, 16, 17, 18, 19) -Note '36 is 14-19 digits, the other ranges 16-19; 300-305 was Carte Blanche'),
    (New-Scheme -Key 'discover' -Name 'Discover' -Ranges @('6011', '644-649', '65') -Lengths $L16_19),
    (New-Scheme -Key 'discover_cup' -Name 'Discover (UnionPay co-processed)' -Ranges @('622126-622925') -Lengths $L16_19 `
        -Note 'UnionPay-issued, routed via Discover network in the US'),
    (New-Scheme -Key 'jcb' -Name 'JCB' -Ranges @('3528-3589') -Lengths $L16_19),
    (New-Scheme -Key 'jcb_legacy' -Name 'JCB (legacy 15-digit)' -Ranges @('1800', '2131') -Lengths @(15) -Active $false),
    (New-Scheme -Key 'unionpay' -Name 'China UnionPay' -Ranges @('62', '81') -Lengths @(14, 15, 16, 17, 18, 19) `
        -Note 'older UnionPay cards were issued without a Luhn check digit'),
    (New-Scheme -Key 't_union' -Name 'China T-Union' -Ranges @('31') -Lengths @(19)),
    (New-Scheme -Key 'uatp' -Name 'UATP (Universal Air Travel Plan)' -Ranges @('1') -Lengths @(15) -Note 'airline industry, MII 1'),
    (New-Scheme -Key 'mir' -Name 'Mir' -Ranges @('2200-2204') -Lengths $L16_19 -Note 'Russia (NSPK)'),
    (New-Scheme -Key 'borica' -Name 'BORICA' -Ranges @('2205') -Lengths $L16 -Note 'Bulgaria'),
    (New-Scheme -Key 'troy' -Name 'Troy' -Ranges @('9792', '650052', '650082-650083', '650092', '650161', '650170',
        '650173', '650175', '650268', '650271', '650273-650274', '650456-650457', '650836', '650846-650850',
        '650923', '650987', '650990', '654997', '657366', '657998', '658758', '658767-658768') -Lengths $L16 `
        -Note 'Turkey; the 65 ranges are co-badged with Discover'),
    (New-Scheme -Key 'rupay' -Name 'RuPay' -Ranges @('60', '6521-6522', '81', '82', '508', '353', '356') -Lengths $L16 `
        -Note 'India (NPCI); 353/356 are RuPay-JCB and 65 RuPay-Discover co-brands'),
    (New-Scheme -Key 'verve' -Name 'Verve' -Ranges @('506099-506198', '507865-507964', '650002-650027') -Lengths @(16, 18, 19) `
        -Note 'Nigeria (Interswitch)'),
    (New-Scheme -Key 'elo' -Name 'Elo' -Ranges @('401178', '401179', '431274', '438935', '451416', '457393', '457631',
        '457632', '504175', '506699-506778', '509000-509999', '627780', '636297', '636368', '650031-650033',
        '650035-650051', '650057-650081', '650405-650439', '650485-650538', '650541-650598', '650700-650718',
        '650720-650727', '650901-650978', '651652-651704', '655000-655019', '655021-655058') -Lengths $L16 -Note 'Brazil'),
    (New-Scheme -Key 'hipercard' -Name 'Hipercard' -Ranges @('606282') -Lengths @(13, 16, 19) -Note 'Brazil'),
    (New-Scheme -Key 'hiper' -Name 'Hiper' -Ranges @('637095', '637568', '637599', '637609', '637612', '63737423', '63743358') `
        -Lengths $L16 -Note 'Brazil'),
    (New-Scheme -Key 'naranja' -Name 'Naranja' -Ranges @('402918', '527572', '589562') -Lengths $L16 -Note 'Argentina'),
    (New-Scheme -Key 'interpayment' -Name 'InterPayment' -Ranges @('636') -Lengths $L16_19),
    (New-Scheme -Key 'instapayment' -Name 'InstaPayment' -Ranges @('637-639') -Lengths $L16),
    (New-Scheme -Key 'ukrcard' -Name 'UkrCard' -Ranges @('6040-6049') -Lengths $L16_19 -Note 'Ukraine; precisely 60400100-60420099'),
    (New-Scheme -Key 'nps' -Name 'NPS Pridnestrovie' -Ranges @('6054740-6054744') -Lengths $L16),
    (New-Scheme -Key 'lankapay' -Name 'LankaPay' -Ranges @('357111') -Lengths $L16 -Note 'Sri Lanka'),
    (New-Scheme -Key 'uzcard' -Name 'UzCard' -Ranges @('8600', '5614') -Lengths $L16 -Note 'Uzbekistan'),
    (New-Scheme -Key 'humo' -Name 'Humo' -Ranges @('9860') -Lengths $L16 -Note 'Uzbekistan'),
    (New-Scheme -Key 'napas' -Name 'Napas' -Ranges @('9704') -Lengths @(16, 19) -Note 'Vietnam'),
    (New-Scheme -Key 'gpn' -Name 'GPN (Gerbang Pembayaran Nasional)' -Ranges @('1946') -Lengths @(16, 18, 19) `
        -Note 'Indonesia; GPN also rides on 50/56/58/60-63 which overlap Maestro'),
    # --- defunct schemes, kept so historical data can still be identified ---------
    (New-Scheme -Key 'bankcard' -Name 'Bankcard' -Ranges @('5610', '560221-560225') -Lengths $L16 -Active $false -Note 'Australia, withdrawn 2006'),
    (New-Scheme -Key 'enroute' -Name 'Diners Club enRoute' -Ranges @('2014', '2149') -Lengths @(15) -Luhn $false -Active $false `
        -Note 'withdrawn 1992; no Luhn check digit'),
    (New-Scheme -Key 'laser' -Name 'Laser' -Ranges @('6304', '6706', '6709', '6771') -Lengths $L16_19 -Active $false -Note 'Ireland, withdrawn 2014'),
    (New-Scheme -Key 'solo' -Name 'Solo' -Ranges @('6334', '6767') -Lengths @(16, 18, 19) -Active $false -Note 'UK, withdrawn 2011'),
    (New-Scheme -Key 'switch' -Name 'Switch' -Ranges @('4903', '4905', '4911', '4936', '564182', '633110', '6333', '6759') `
        -Lengths @(16, 18, 19) -Active $false -Note 'UK, re-branded Maestro UK in 2002')
)
for ($i = 0; $i -lt $script:SCHEMES.Count; $i++) { $script:SCHEMES[$i]['Order'] = $i }

# ---------------------------------------------------------------------------------
# Luhn (ISO/IEC 7812-1 Annex B)
# ---------------------------------------------------------------------------------
$script:DOUBLED = @(0, 2, 4, 6, 8, 1, 3, 5, 7, 9)       # digit -> contribution when doubled
$script:DOUBLED_INV = @{}
for ($i = 0; $i -lt 10; $i++) { $script:DOUBLED_INV[$script:DOUBLED[$i]] = $i }

function Test-DoubledPosition { param([int]$Index, [int]$Length) return ((($Length - $Index) % 2) -eq 0) }

function Get-LuhnSum {
    param([string]$Pan, [int]$Skip = -1)
    $total = 0
    $len = $Pan.Length
    for ($i = 0; $i -lt $len; $i++) {
        if ($i -eq $Skip) { continue }
        $d = [int][char]$Pan[$i] - 48
        if ((($len - $i) % 2) -eq 0) { $total += $script:DOUBLED[$d] } else { $total += $d }
    }
    return $total
}

function Test-Luhn {
    param([string]$Pan)
    if ([string]::IsNullOrEmpty($Pan) -or $Pan -notmatch '^\d+$') { return $false }
    return ((Get-LuhnSum -Pan $Pan) % 10) -eq 0
}

function Resolve-LuhnDigit {
    # The single digit that makes $Pan Luhn-valid when placed at $Index.
    param([string]$Pan, [int]$Index)
    $need = (10 - ((Get-LuhnSum -Pan $Pan -Skip $Index) % 10)) % 10
    if (Test-DoubledPosition -Index $Index -Length $Pan.Length) { return [string]$script:DOUBLED_INV[$need] }
    return [string]$need
}

function Get-LuhnCheckDigit { param([string]$Partial) return (Resolve-LuhnDigit -Pan ($Partial + '0') -Index $Partial.Length) }

# ---------------------------------------------------------------------------------
# Scheme identification
# ---------------------------------------------------------------------------------
function Test-PrefixInRange {
    param([string]$Pan, [string]$Lo, [string]$Hi)
    $n = $Lo.Length
    if ($Pan.Length -lt $n) { return $false }
    $p = $Pan.Substring(0, $n)
    return ([string]::CompareOrdinal($Lo, $p) -le 0 -and [string]::CompareOrdinal($p, $Hi) -le 0)
}

function Test-PrefixCanMatch {
    # Could a PAN starting with $Prefix still fall inside the range Lo..Hi?
    param([string]$Prefix, [string]$Lo, [string]$Hi)
    $n = $Prefix.Length; $m = $Lo.Length
    if ($n -ge $m) { return (Test-PrefixInRange -Pan $Prefix -Lo $Lo -Hi $Hi) }
    $pad = $m - $n
    $low = $Prefix + ('0' * $pad); $high = $Prefix + ('9' * $pad)
    return ([string]::CompareOrdinal($low, $Hi) -le 0 -and [string]::CompareOrdinal($high, $Lo) -ge 0)
}

function Get-RangeText { param($Range) if ($Range['Lo'] -eq $Range['Hi']) { return $Range['Lo'] } return "$($Range['Lo'])-$($Range['Hi'])" }

function Find-Scheme {
    # All schemes whose IIN ranges match $Pan, best match first.
    param([string]$Pan, [object[]]$Schemes = $script:SCHEMES)
    $found = New-Object System.Collections.ArrayList
    foreach ($s in $Schemes) {
        foreach ($r in $s['Ranges']) {
            if (Test-PrefixInRange -Pan $Pan -Lo $r['Lo'] -Hi $r['Hi']) {
                [void]$found.Add(@{
                    Scheme = $s; Lo = $r['Lo']; Hi = $r['Hi']; CatchAll = $r['CatchAll']
                    LengthOk = ($s['Lengths'] -contains $Pan.Length); RangeText = (Get-RangeText $r)
                })
                break
            }
        }
    }
    if ($found.Count -eq 0) { return @() }
    # A range whose length rule fits always beats one that does not (a 19-digit 4571... is a
    # Visa, not a malformed Dankort); then the most specific range wins, catch-all ranges lose
    # to a same-length range, active schemes beat defunct ones, then table order.
    $keys = New-Object string[] $found.Count
    $items = $found.ToArray()
    for ($i = 0; $i -lt $items.Count; $i++) {
        $f = $items[$i]
        $keys[$i] = '{0}{1:D2}{2}{3}{4:D3}' -f [int](-not $f['LengthOk']), (99 - $f['Lo'].Length),
            [int]$f['CatchAll'], [int](-not $f['Scheme']['Active']), $f['Scheme']['Order']
    }
    # insertion sort (a handful of entries at most; avoids Sort-Object overhead in the generator)
    for ($i = 1; $i -lt $items.Count; $i++) {
        $k = $keys[$i]; $v = $items[$i]; $j = $i - 1
        while ($j -ge 0 -and [string]::CompareOrdinal($keys[$j], $k) -gt 0) { $keys[$j + 1] = $keys[$j]; $items[$j + 1] = $items[$j]; $j-- }
        $keys[$j + 1] = $k; $items[$j + 1] = $v
    }
    return @($items)
}

function Select-Scheme {
    # Resolve -Brand / -ActiveOnly / -NoCatchAll into the list of schemes to use.
    param([string[]]$Brands, [bool]$IncludeInactive = $true, [bool]$IncludeCatchAll = $true)
    $wanted = $null
    if ($Brands -and $Brands.Count -gt 0) {
        $wanted = New-Object System.Collections.ArrayList
        foreach ($b in $Brands) { foreach ($part in $b.Split(',')) { $p = $part.Trim().ToLower(); if ($p) { [void]$wanted.Add($p) } } }
    }
    $out = New-Object System.Collections.ArrayList
    foreach ($s in $script:SCHEMES) {
        if (-not $IncludeInactive -and -not $s['Active']) { continue }
        if ($null -ne $wanted) {
            $hit = $false
            $name = $s['Name'].ToLower()
            foreach ($w in $wanted) {
                if ($s['Key'] -eq $w -or $name -eq $w -or $s['Key'].StartsWith($w) -or $name.StartsWith($w)) { $hit = $true; break }
            }
            if (-not $hit) { continue }
        }
        if (-not $IncludeCatchAll) {
            $kept = @($s['Ranges'] | Where-Object { -not $_['CatchAll'] })
            if ($kept.Count -ne $s['Ranges'].Count) {
                if ($kept.Count -eq 0) { continue }
                $copy = @{}
                foreach ($k in $s.Keys) { $copy[$k] = $s[$k] }
                $copy['Ranges'] = $kept
                $s = $copy
            }
        }
        [void]$out.Add($s)
    }
    if ($null -ne $wanted -and $out.Count -eq 0) { throw "no scheme matches -Brand $($wanted -join ',') (try -ListSchemes)" }
    return @($out)
}

# ---------------------------------------------------------------------------------
# Optional external BIN / IIN database (CSV) -> issuing bank, country, card type
# ---------------------------------------------------------------------------------
function Import-BinDatabase {
    # Works with the open "binlist-data" CSV (bin,brand,type,category,issuer,alpha_2,...) and
    # any CSV with a header naming at least a start column; an optional end column gives ranges.
    param([string]$Path)
    $startNames = @('iin_start', 'bin_start', 'range_start', 'bin', 'iin', 'prefix', 'start')
    $endNames = @('iin_end', 'bin_end', 'range_end', 'end')
    $fieldNames = @{
        brand    = @('brand', 'scheme', 'network', 'card_brand', 'vendor')
        type     = @('type', 'card_type', 'debit_credit')
        category = @('category', 'level', 'card_category')
        issuer   = @('issuer', 'bank', 'bank_name', 'issuer_name', 'issuing_bank')
        country  = @('country', 'country_name', 'alpha_2', 'iso_country', 'country_code', 'alpha_3')
    }
    $firstLine = Get-Content -LiteralPath $Path -TotalCount 1
    $delim = ','
    foreach ($cand in @("`t", ';', '|')) { if ($firstLine.Split($cand).Count -gt $firstLine.Split($delim).Count) { $delim = $cand } }
    $rows = @(Import-Csv -LiteralPath $Path -Delimiter $delim)
    if ($rows.Count -eq 0) { throw 'empty BIN database' }
    $header = @($rows[0].PSObject.Properties | ForEach-Object { $_.Name })
    $lower = @{}
    foreach ($h in $header) { $lower[$h.Trim().ToLower()] = $h }
    $pick = { param($cands) foreach ($c in $cands) { if ($lower.ContainsKey($c)) { return $lower[$c] } } return $null }
    $startCol = & $pick $startNames
    if (-not $startCol) { throw "BIN database needs a start column (one of $($startNames -join ', '))" }
    $endCol = & $pick $endNames
    $cols = @{}
    foreach ($k in $fieldNames.Keys) { $cols[$k] = & $pick $fieldNames[$k] }

    $exact = @{}
    $ranges = New-Object System.Collections.ArrayList
    $count = 0
    foreach ($row in $rows) {
        $start = ([string]$row.$startCol) -replace '\D', ''
        if (-not $start) { continue }
        $info = @{}
        foreach ($k in $cols.Keys) { $c = $cols[$k]; if ($c) { $info[$k] = ([string]$row.$c).Trim() } else { $info[$k] = '' } }
        $end = ''
        if ($endCol) { $end = ([string]$row.$endCol) -replace '\D', '' }
        $count++
        if ($end -and $end -ne $start) {
            $n = [Math]::Max($start.Length, $end.Length)
            [void]$ranges.Add(@{ Lo = $start.PadRight($n, '0'); Hi = $end.PadRight($n, '9'); Info = $info })
        } else {
            $exact[$start] = $info
        }
    }
    $sortedRanges = @($ranges | Sort-Object -Property @{ Expression = { -($_['Lo'].Length) } })
    return @{ Path = $Path; Exact = $exact; Ranges = $sortedRanges; Rows = $count }
}

function Find-BinIssuer {
    param($Db, [string]$Pan)
    if ($null -eq $Db) { return $null }
    for ($n = [Math]::Min($Pan.Length, 11); $n -ge 1; $n--) {
        $k = $Pan.Substring(0, $n)
        if ($Db['Exact'].ContainsKey($k)) { $r = @{} + $Db['Exact'][$k]; $r['iin'] = $k; return $r }
    }
    foreach ($rg in $Db['Ranges']) {
        if (Test-PrefixInRange -Pan $Pan -Lo $rg['Lo'] -Hi $rg['Hi']) { $r = @{} + $rg['Info']; $r['iin'] = "$($rg['Lo'])-$($rg['Hi'])"; return $r }
    }
    return $null
}

# ---------------------------------------------------------------------------------
# Validation of a single PAN
# ---------------------------------------------------------------------------------
function ConvertTo-NormalisedPan { param([string]$Text) return ($Text.Trim() -replace '[\s\-\._]', '') }

function Get-MaskedPan {
    # PCI DSS style masking: first 6 and last 4 digits visible.
    param([string]$Pan)
    if ($Pan.Length -le 10) { return ('*' * $Pan.Length) }
    return $Pan.Substring(0, 6) + ('*' * ($Pan.Length - 10)) + $Pan.Substring($Pan.Length - 4)
}

function Get-GroupedPan {
    param([string]$Pan)
    if ($Pan.Length -eq 15 -or $Pan.Length -eq 14) { return "$($Pan.Substring(0,4)) $($Pan.Substring(4,6)) $($Pan.Substring(10))" }
    $parts = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $Pan.Length; $i += 4) { [void]$parts.Add($Pan.Substring($i, [Math]::Min(4, $Pan.Length - $i))) }
    return ($parts -join ' ')
}

function Get-MiiInfo {
    param([string]$Pan)
    $d = $Pan.Substring(0, 1)
    $info = [ordered]@{ digit = $d; industry = 'unknown' }
    if ($script:MII.Contains($d)) { $info['industry'] = $script:MII[$d] }
    if ($d -eq '9' -and $Pan.Length -ge 4) {
        $cc = $Pan.Substring(1, 3)
        $info['country_code'] = $cc
        if ($script:ISO3166.ContainsKey($cc)) { $info['country'] = $script:ISO3166[$cc] } else { $info['country'] = "ISO 3166-1 numeric $cc" }
    }
    return $info
}

function Test-Pan {
    # Full assessment of one PAN; returns an ordered hashtable (JSON friendly).
    param([string]$Pan, [bool]$RequireIin = $false, [bool]$CheckLength = $true, [object[]]$Schemes = $script:SCHEMES, $BinDb = $null)
    $Pan = ConvertTo-NormalisedPan $Pan
    $r = [ordered]@{
        pan = $Pan; length = $Pan.Length; well_formed = $false; luhn = $false; luhn_expected = $true
        mii = $null; iin6 = $null; iin8 = $null
        scheme = $null; scheme_key = $null; scheme_active = $true; scheme_note = ''; iin_range = $null
        length_ok = $null; expected_lengths = @(); also_matches = @(); issuer = $null; valid = $false
        reasons = New-Object System.Collections.ArrayList
    }
    if ($Pan -notmatch '^\d+$') { [void]$r['reasons'].Add('contains non-digit characters'); return $r }
    if ($Pan.Length -lt $script:PAN_MIN_LEN -or $Pan.Length -gt $script:PAN_MAX_LEN) {
        [void]$r['reasons'].Add("length $($Pan.Length) outside $($script:PAN_MIN_LEN)-$($script:PAN_MAX_LEN) digits")
    } else { $r['well_formed'] = $true }
    $r['mii'] = Get-MiiInfo $Pan
    $r['iin6'] = $Pan.Substring(0, [Math]::Min($script:IIN_LEN_LEGACY, $Pan.Length))
    if ($Pan.Length -ge $script:IIN_LEN) { $r['iin8'] = $Pan.Substring(0, $script:IIN_LEN) }

    $found = @(Find-Scheme -Pan $Pan -Schemes $Schemes)
    $best = $null
    if ($found.Count -gt 0) { $best = $found[0] }
    $luhnExpected = $true
    if ($best) { $luhnExpected = $best['Scheme']['Luhn'] }
    $r['luhn'] = Test-Luhn $Pan
    $r['luhn_expected'] = $luhnExpected

    if ($best) {
        $r['scheme'] = $best['Scheme']['Name']
        $r['scheme_key'] = $best['Scheme']['Key']
        $r['scheme_active'] = $best['Scheme']['Active']
        $r['scheme_note'] = $best['Scheme']['Note']
        $r['iin_range'] = $best['RangeText']
        $r['length_ok'] = $best['LengthOk']
        $r['expected_lengths'] = @($best['Scheme']['Lengths'])
        $also = New-Object System.Collections.ArrayList
        for ($i = 1; $i -lt $found.Count; $i++) {
            $m = $found[$i]
            [void]$also.Add([ordered]@{ scheme = $m['Scheme']['Name']; scheme_key = $m['Scheme']['Key']; iin_range = $m['RangeText']; length_ok = $m['LengthOk']; active = $m['Scheme']['Active'] })
        }
        $r['also_matches'] = @($also)
    }
    if ($null -ne $BinDb) { $r['issuer'] = Find-BinIssuer -Db $BinDb -Pan $Pan }

    $ok = $r['well_formed']
    if ($luhnExpected -and -not $r['luhn']) { [void]$r['reasons'].Add('Luhn check digit mismatch'); $ok = $false }
    if ($RequireIin) {
        if ($null -eq $best) { [void]$r['reasons'].Add('no known IIN / scheme for this prefix'); $ok = $false }
        elseif ($CheckLength -and -not $best['LengthOk']) {
            [void]$r['reasons'].Add("$($best['Scheme']['Name']) numbers are $($best['Scheme']['Lengths'] -join '/') digits, not $($Pan.Length)")
            $ok = $false
        }
    }
    $r['valid'] = $ok
    $r['reasons'] = @($r['reasons'])
    return $r
}

# ---------------------------------------------------------------------------------
# Generation of all valid PANs for a partially known number ("?" = unknown digit)
# ---------------------------------------------------------------------------------
function Get-CombinationEstimate {
    # Worst-case Luhn candidates: one unknown is solved directly, the rest enumerated.
    param([string]$Pattern)
    $k = @($Pattern.ToCharArray() | Where-Object { $_ -eq '?' }).Count
    if ($k -eq 0) { return 0 }
    return [long][Math]::Pow(10, [Math]::Max($k - 1, 0))
}

function Get-PanCombination {
    <#
      Emits every Luhn-valid completion of $Pattern (digits and '?').
      The last unknown digit is solved analytically (the Luhn doubling map is a bijection on
      0..9) so only 10^(k-1) candidates are visited, and with the IIN check on, prefixes that
      cannot match any eligible scheme are pruned before their remaining digits are enumerated.
    #>
    param([string]$Pattern, [bool]$IinCheck = $true, [bool]$CheckLength = $true, [object[]]$Schemes = $script:SCHEMES)
    $Pattern = ConvertTo-NormalisedPan $Pattern
    if ($Pattern -notmatch '^[0-9?]+$') { throw "pattern may only contain digits and '?'" }
    if ($Pattern.Length -lt $script:PAN_MIN_LEN -or $Pattern.Length -gt $script:PAN_MAX_LEN) {
        throw "pattern must be $($script:PAN_MIN_LEN)-$($script:PAN_MAX_LEN) characters long"
    }
    $unknown = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $Pattern.Length; $i++) { if ($Pattern[$i] -eq '?') { [void]$unknown.Add($i) } }
    if ($unknown.Count -eq 0) { throw "pattern has no '?' characters" }

    $length = $Pattern.Length
    $eligible = New-Object System.Collections.ArrayList
    $maxIin = 0
    if ($IinCheck) {
        foreach ($s in $Schemes) {
            if ($CheckLength -and -not ($s['Lengths'] -contains $length)) { continue }
            foreach ($rg in $s['Ranges']) { [void]$eligible.Add($rg); if ($rg['Lo'].Length -gt $maxIin) { $maxIin = $rg['Lo'].Length } }
        }
        if ($eligible.Count -eq 0) { return }
    }

    # Flat arrays of the eligible range bounds: the hot loops below avoid function calls.
    $eligLo = New-Object string[] $eligible.Count
    $eligHi = New-Object string[] $eligible.Count
    for ($i = 0; $i -lt $eligible.Count; $i++) { $eligLo[$i] = $eligible[$i]['Lo']; $eligHi[$i] = $eligible[$i]['Hi'] }
    $digits = $Pattern.ToCharArray()
    $last = $unknown[$unknown.Count - 1]

    $feasible = {
        # Is the determined prefix (up to the first remaining '?') still matchable?
        $n = [Array]::IndexOf($digits, [char]'?')
        if ($n -lt 0) { $n = $length }
        $take = [Math]::Min($n, $maxIin)
        $prefix = ''
        if ($take -gt 0) { $prefix = -join $digits[0..($take - 1)] }
        $n = $prefix.Length
        for ($i = 0; $i -lt $eligLo.Length; $i++) {
            $m = $eligLo[$i].Length
            if ($n -ge $m) {
                $p = $prefix.Substring(0, $m)
                if ([string]::CompareOrdinal($eligLo[$i], $p) -le 0 -and [string]::CompareOrdinal($p, $eligHi[$i]) -le 0) { return $true }
            } else {
                $pad = $m - $n
                if ([string]::CompareOrdinal($prefix + ('0' * $pad), $eligHi[$i]) -le 0 -and
                    [string]::CompareOrdinal($prefix + ('9' * $pad), $eligLo[$i]) -ge 0) { return $true }
            }
        }
        return $false
    }
    $accept = {
        # $eligible already honours the length rule, so any hit is a valid scheme match.
        param([string]$Candidate)
        if (-not $IinCheck) { return $true }
        for ($i = 0; $i -lt $eligLo.Length; $i++) {
            $n = $eligLo[$i].Length
            $p = $Candidate.Substring(0, $n)
            if ([string]::CompareOrdinal($eligLo[$i], $p) -le 0 -and [string]::CompareOrdinal($p, $eligHi[$i]) -le 0) { return $true }
        }
        return $false
    }

    # Iterative depth-first search over the unknown positions (no recursion limits).
    if ($IinCheck -and -not (& $feasible)) { return }
    $depth = 0
    $choice = New-Object int[] $unknown.Count     # next digit to try at each depth
    while ($depth -ge 0) {
        $idx = $unknown[$depth]
        if ($idx -eq $last) {
            $total = 0
            for ($i = 0; $i -lt $length; $i++) {
                if ($i -eq $idx) { continue }
                $d = [int]$digits[$i] - 48
                if ((($length - $i) % 2) -eq 0) { $total += $script:DOUBLED[$d] } else { $total += $d }
            }
            $need = (10 - ($total % 10)) % 10
            if ((($length - $idx) % 2) -eq 0) { $need = $script:DOUBLED_INV[$need] }
            $digits[$idx] = [char](48 + $need)
            $candidate = -join $digits
            if (& $accept $candidate) { Write-Output $candidate }
            $digits[$idx] = [char]'?'
            $depth--
            continue
        }
        if ($choice[$depth] -gt 9) {
            $choice[$depth] = 0
            $digits[$idx] = [char]'?'
            $depth--
            continue
        }
        $digits[$idx] = [char]([int][char]'0' + $choice[$depth])
        $choice[$depth]++
        if ($IinCheck -and $idx -lt $maxIin -and -not (& $feasible)) { continue }
        $depth++
    }
}

# ---------------------------------------------------------------------------------
# Track 1 / track 2 / EMV tag 57 parsing (ISO/IEC 7813)
# ---------------------------------------------------------------------------------
$script:TRACK2_RE = '^;?(?<pan>\d{8,19})(?<sep>[=D])(?<rest>[0-9=DF]*)\??(?<lrc>.)?$'
$script:TRACK1_RE = '^%?(?<fc>[A-Z])(?<pan>\d{8,19})\^(?<name>[^^]{0,26})\^(?<rest>[^?]*)\??(?<lrc>.)?$'

function ConvertFrom-ServiceCode {
    param([string]$Code)
    $Code = ([string]$Code).Trim()
    if ($Code -notmatch '^\d{3}$') { return [ordered]@{ code = $Code; valid = $false } }
    $d1 = $Code.Substring(0, 1); $d2 = $Code.Substring(1, 1); $d3 = $Code.Substring(2, 1)
    $t1 = 'reserved / unknown'; $t2 = 'reserved / unknown'; $t3 = 'reserved / unknown'
    if ($script:SERVICE_CODE_1.ContainsKey($d1)) { $t1 = $script:SERVICE_CODE_1[$d1] }
    if ($script:SERVICE_CODE_2.ContainsKey($d2)) { $t2 = $script:SERVICE_CODE_2[$d2] }
    if ($script:SERVICE_CODE_3.ContainsKey($d3)) { $t3 = $script:SERVICE_CODE_3[$d3] }
    return [ordered]@{
        code = $Code; valid = $true; interchange = $t1; authorisation = $t2; services = $t3
        chip = ($d1 -eq '2' -or $d1 -eq '6'); international = ($d1 -eq '1' -or $d1 -eq '2')
        pin_required = ($d3 -eq '0' -or $d3 -eq '3' -or $d3 -eq '5')
    }
}

function Split-TrackTail {
    # 'YYMM' + 'SSS' + discretionary data; '=' / 'D' stands for an absent field.
    param([string]$Rest)
    $pos = 0; $expiry = $null; $service = $null
    if ($Rest.Length -gt $pos -and ($Rest[$pos] -eq '=' -or $Rest[$pos] -eq 'D')) { $pos++ }
    elseif ($Rest.Substring($pos) -match '^\d{4}') { $expiry = $Rest.Substring($pos, 4); $pos += 4 }
    if ($Rest.Length -gt $pos -and ($Rest[$pos] -eq '=' -or $Rest[$pos] -eq 'D')) { $pos++ }
    elseif ($Rest.Substring($pos) -match '^\d{3}') { $service = $Rest.Substring($pos, 3); $pos += 3 }
    $disc = $Rest.Substring($pos).TrimEnd('F')
    return @{ Expiry = $expiry; Service = $service; Discretionary = $disc }
}

function Test-TrackData {
    param([string]$Text)
    $t = $Text.Trim().ToUpper()
    return ($t -cmatch $script:TRACK2_RE -or $t -cmatch $script:TRACK1_RE)
}

function ConvertFrom-TrackData {
    param([string]$Text)
    $raw = $Text.Trim()
    $t = $raw.ToUpper()
    $out = [ordered]@{ input = $raw; track = $null; pan = $null; expiry = $null; expiry_text = $null; service_code = $null; discretionary = $null; name = $null }
    $m2 = [regex]::Match($t, $script:TRACK2_RE)
    if ($m2.Success) {
        if ($m2.Groups['sep'].Value -eq 'D') { $out['track'] = 'track2/EMV-57' } else { $out['track'] = 'track2' }
        $out['pan'] = $m2.Groups['pan'].Value
        $tail = Split-TrackTail $m2.Groups['rest'].Value
    } else {
        $m1 = [regex]::Match($t, $script:TRACK1_RE)
        if (-not $m1.Success) { throw 'not recognised as track 1 / track 2 data' }
        $out['track'] = "track1 (format $($m1.Groups['fc'].Value))"
        $out['pan'] = $m1.Groups['pan'].Value
        $name = $m1.Groups['name'].Value.Trim()
        if ($name.Contains('/')) { $np = $name.Split('/', 2); $name = "$($np[1].Trim()) $($np[0].Trim())" }
        if ($name) { $out['name'] = $name }
        $tail = Split-TrackTail $m1.Groups['rest'].Value
    }
    $out['expiry'] = $tail['Expiry']
    if ($tail['Expiry']) { $e = $tail['Expiry']; $out['expiry_text'] = "20$($e.Substring(0,2))-$($e.Substring(2)) (YYMM $e)" }
    if ($tail['Service']) { $out['service_code'] = ConvertFrom-ServiceCode $tail['Service'] }
    if ($tail['Discretionary']) { $out['discretionary'] = $tail['Discretionary'] }
    return $out
}

# ---------------------------------------------------------------------------------
# Scanning arbitrary text for candidate PANs (data discovery)
# ---------------------------------------------------------------------------------
$script:SCAN_RE = '(?<![0-9])(?:[0-9][ \-]?){11,18}[0-9](?![0-9])'

function Search-PanInText {
    param([string[]]$Lines, [bool]$RequireIin = $true, [bool]$CheckLength = $true, [object[]]$Schemes = $script:SCHEMES, $BinDb = $null)
    $seen = @{}
    $lineno = 0
    foreach ($line in $Lines) {
        $lineno++
        if ($null -eq $line) { continue }
        foreach ($m in [regex]::Matches($line, $script:SCAN_RE)) {
            $pan = ConvertTo-NormalisedPan $m.Value
            if ($pan.Length -lt 12 -or $pan.Length -gt $script:PAN_MAX_LEN) { continue }
            if (@($pan.ToCharArray() | Sort-Object -Unique).Count -eq 1) { continue }   # 0000000000000000 and friends
            $r = Test-Pan -Pan $pan -RequireIin $RequireIin -CheckLength $CheckLength -Schemes $Schemes -BinDb $BinDb
            if ($r['valid']) {
                $r['line'] = $lineno
                $r['column'] = $m.Index + 1
                $r['duplicate'] = $seen.ContainsKey($pan)
                $seen[$pan] = $true
                Write-Output $r
            }
        }
    }
}

# ---------------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------------
function Format-PanForOutput { param([string]$Pan, [bool]$Masked) if ($Masked) { return (Get-MaskedPan $Pan) } return $Pan }

function Write-Validation {
    param($R, [bool]$Masked = $false, [bool]$QuietMode = $false)
    $pan = $R['pan']
    $shown = Format-PanForOutput -Pan $pan -Masked $Masked
    if ($QuietMode) {
        if ($R['valid']) { Write-Output "[+] Valid PAN   $shown" } else { Write-Output "[-] Invalid PAN $shown" }
        return
    }
    $display = $shown
    if ($pan -match '^\d+$') { $display = Get-GroupedPan $shown }
    Write-Output ("PAN:          {0}  ({1} digits)" -f $display, $R['length'])
    if (-not $R['well_formed'] -and $pan -notmatch '^\d+$') {
        Write-Output ("Result:       [-] Invalid PAN  ({0})" -f ($R['reasons'] -join '; '))
        return
    }
    $luhnTxt = 'INVALID'
    if ($R['luhn']) { $luhnTxt = 'valid' }
    if (-not $R['luhn_expected']) { $luhnTxt += '  (scheme does not use a Luhn check digit)' }
    Write-Output "Luhn:         $luhnTxt"
    $mii = $R['mii']
    $line = "MII:          $($mii['digit']) - $($mii['industry'])"
    if ($mii.Contains('country')) { $line += " -> $($mii['country']) ($($mii['country_code']))" }
    Write-Output $line
    $iin = $R['iin6']
    if ($R['iin8']) { $iin += " / $($R['iin8'])" }
    Write-Output "IIN:          $iin  (6-digit / 8-digit)"
    if ($R['scheme']) {
        if ($R['length_ok']) { $lengthTxt = 'length OK' } else { $lengthTxt = "length mismatch, expects $($R['expected_lengths'] -join '/')" }
        $status = ''
        if (-not $R['scheme_active']) { $status = '  [defunct scheme]' }
        Write-Output ("Scheme:       {0}  (IIN range {1}; {2}){3}" -f $R['scheme'], $R['iin_range'], $lengthTxt, $status)
        if ($R['scheme_note']) { Write-Output "              $($R['scheme_note'])" }
        if ($R['also_matches'].Count -gt 0) {
            $parts = foreach ($a in $R['also_matches']) { $d = ''; if (-not $a['active']) { $d = ', defunct' }; "$($a['scheme']) ($($a['iin_range'])$d)" }
            Write-Output "Also matches: $($parts -join ', ')"
        }
    } else {
        Write-Output 'Scheme:       unknown IIN (not in the built-in table)'
    }
    $iss = $R['issuer']
    if ($iss) {
        $bits = foreach ($k in @('issuer', 'brand', 'type', 'category', 'country')) { if ($iss.ContainsKey($k) -and $iss[$k]) { $iss[$k] } }
        Write-Output "Issuer (DB):  $($bits -join ' | ')  [$($iss['iin'])]"
    }
    if ($R['valid']) { Write-Output 'Result:       [+] Valid PAN' }
    else { Write-Output ("Result:       [-] Invalid PAN  ({0})" -f ($R['reasons'] -join '; ')) }
}

function Write-Track {
    param($T, $V, [bool]$Masked = $false)
    Write-Output "Track data:   $($T['track'])"
    if ($T['name']) { Write-Output "Cardholder:   $($T['name'])" }
    if ($T['expiry']) { Write-Output "Expiry:       $($T['expiry_text'])" }
    $sc = $T['service_code']
    if ($sc) {
        if ($sc['valid']) {
            Write-Output "Service code: $($sc['code'])"
            Write-Output "              1: $($sc['interchange'])"
            Write-Output "              2: $($sc['authorisation'])"
            Write-Output "              3: $($sc['services'])"
        } else { Write-Output "Service code: $($sc['code']) (malformed)" }
    }
    if ($T['discretionary']) {
        $disc = $T['discretionary']
        if ($Masked) { $disc = '*' * $disc.Length }
        Write-Output "Discretionary: $disc"
    }
    Write-Validation -R $V -Masked $Masked
}

function Get-CompactLengths {
    param([int[]]$Lengths)
    $out = New-Object System.Collections.ArrayList
    $i = 0
    while ($i -lt $Lengths.Count) {
        $j = $i
        while ($j + 1 -lt $Lengths.Count -and $Lengths[$j + 1] -eq $Lengths[$j] + 1) { $j++ }
        if ($i -eq $j) { [void]$out.Add([string]$Lengths[$i]) } else { [void]$out.Add("$($Lengths[$i])-$($Lengths[$j])") }
        $i = $j + 1
    }
    return ($out -join ',')
}

function Write-SchemeTable {
    Write-Output ('{0,-42} {1,-7} {2,-12} {3}' -f 'Scheme (key)', 'Active', 'Lengths', 'IIN ranges')
    Write-Output ('-' * 100)
    foreach ($s in $script:SCHEMES) {
        $ranges = foreach ($r in $s['Ranges']) { $txt = Get-RangeText $r; if ($r['CatchAll']) { "$txt*" } else { $txt } }
        $active = 'no'
        if ($s['Active']) { $active = 'yes' }
        Write-Output ('{0,-42} {1,-7} {2,-12} {3}' -f "$($s['Name']) ($($s['Key']))", $active, (Get-CompactLengths $s['Lengths']), ($ranges -join ', '))
        if (-not $s['Luhn']) { Write-Output ('{0,-42} {1,-7} {2,-12} {3}' -f '', '', '', '(no Luhn check digit)') }
    }
    Write-Output ''
    Write-Output '* = catch-all range: any other scheme with a range of the same length takes precedence.'
    Write-Output 'MII (first digit):'
    foreach ($k in $script:MII.Keys) { Write-Output "  $k  $($script:MII[$k])" }
}

# ---------------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------------
function Read-InputLines {
    param([string]$Path)
    if ($Path -eq '-') {
        if ($script:PipelineInput.Count -gt 0) { return $script:PipelineInput }
        $data = [Console]::In.ReadToEnd()
        return @($data -split "`r?`n")
    }
    return @(Get-Content -LiteralPath $Path)
}

function Invoke-Main {
    if ($Version) { Write-Output $script:BANNER; $script:ExitCode = 0; return }
    if ($ListSchemes) { Write-SchemeTable; $script:ExitCode = 0; return }

    try {
        $schemes = Select-Scheme -Brands $Brand -IncludeInactive (-not $ActiveOnly) -IncludeCatchAll (-not $NoCatchAll)
    } catch { Write-Output "[-] $($_.Exception.Message)"; $script:ExitCode = 2; return }
    $binDatabase = $null
    if ($BinDb) {
        try { $binDatabase = Import-BinDatabase -Path $BinDb }
        catch { Write-Output "[-] cannot load BIN database: $($_.Exception.Message)"; $script:ExitCode = 2; return }
        if (-not $Json -and -not $Quiet) { Write-Output "[i] BIN database loaded: $($binDatabase['Rows']) rows from $(Split-Path -Leaf $BinDb)" }
    }
    $checkLength = -not $IgnoreLength
    $requireIin = [bool]$Iin
    $iinFilter = -not $NoIin

    $inputs = New-Object System.Collections.ArrayList
    if ($PAN) { foreach ($p in $PAN) { [void]$inputs.Add($p) } }
    if ($File) {
        foreach ($ln in (Read-InputLines $File)) { if ($ln -and $ln.Trim() -and -not $ln.TrimStart().StartsWith('#')) { [void]$inputs.Add($ln) } }
    }

    $jsonOut = New-Object System.Collections.ArrayList
    $anyValid = $false
    $anyInput = $false

    # ---- scan mode -----------------------------------------------------------------
    if ($Scan) {
        $anyInput = $true
        $lines = Read-InputLines $Scan
        $hits = 0
        Search-PanInText -Lines $lines -RequireIin $iinFilter -CheckLength $checkLength -Schemes $schemes -BinDb $binDatabase | ForEach-Object {
            $r = $_
            $hits++
            $anyValid = $true
            if ($Json) { $r['pan'] = Format-PanForOutput -Pan $r['pan'] -Masked $Mask; [void]$jsonOut.Add($r) }
            else {
                $dup = ''
                if ($r['duplicate']) { $dup = '  (duplicate)' }
                $sch = $r['scheme']
                if (-not $sch) { $sch = 'unknown scheme' }
                Write-Output ('[+] line {0,-6} {1,-24} {2}{3}' -f $r['line'], (Format-PanForOutput -Pan $r['pan'] -Masked $Mask), $sch, $dup)
            }
        }
        if (-not $Json) { Write-Output ''; Write-Output "Total candidate PANs found: $hits" }
    }

    if ($inputs.Count -eq 0 -and -not $Scan) {
        Write-Output $script:BANNER
        Write-Output ''
        Write-Output 'usage: gLuhn.ps1 [-i] [-NoIin] [-IgnoreLength] [-b BRANDS] [-ActiveOnly] [-NoCatchAll] [-f FILE] [-Scan FILE]'
        Write-Output '                 [-BinDb CSV] [-Max N] [-m] [-j] [-q] [-ListSchemes] [-Version] [PAN ...]'
        Write-Output ''
        Write-Output '  PAN           Luhn check + scheme identification (add -i to also require a known IIN)'
        Write-Output '  PAN with ?    generate every valid combination, e.g. 4542109540?18054'
        Write-Output "  track data    e.g. ';4542109540018054=25121011234567890?' or EMV tag 57 with 'D'"
        Write-Output ''
        Write-Output 'Run "Get-Help .\gLuhn.ps1 -Detailed" for every option and more examples.'
        $script:ExitCode = 2; return
    }

    # ---- per input ------------------------------------------------------------------
    foreach ($raw in $inputs) {
        $anyInput = $true
        $text = ([string]$raw).Trim()
        if (-not $text) { continue }
        $clean = ConvertTo-NormalisedPan $text

        # Track data?
        if (($clean -notmatch '^\d+$') -and (Test-TrackData $text)) {
            try { $t = ConvertFrom-TrackData $text }
            catch {
                $shownIn = $text
                if ($Mask) { $shownIn = '<track data>' }
                Write-Output "[-] $($_.Exception.Message): $shownIn"; continue
            }
            $v = Test-Pan -Pan $t['pan'] -RequireIin $requireIin -CheckLength $checkLength -Schemes $schemes -BinDb $binDatabase
            if ($v['valid']) { $anyValid = $true }
            if ($Json) {
                if ($Mask) { $t['pan'] = Get-MaskedPan $v['pan']; $v['pan'] = $t['pan']; $t['discretionary'] = $null; $t['input'] = '<masked>' }
                [void]$jsonOut.Add([ordered]@{ track = $t; validation = $v })
            } else { Write-Track -T $t -V $v -Masked $Mask; Write-Output '' }
            continue
        }

        # Generation?
        if ($clean.Contains('?')) {
            if ($clean -notmatch '^[0-9?]+$') { Write-Output "[-] Not a PAN pattern (digits and '?' only): $text"; continue }
            $est = Get-CombinationEstimate $clean
            if ($est -gt $Max) {
                $k = @($clean.ToCharArray() | Where-Object { $_ -eq '?' }).Count
                Write-Output "[-] $clean has $k unknown digits -> up to $est Luhn candidates; raise -Max to allow"
                continue
            }
            if (-not $Json) {
                $suffix = '  (IIN filtered)'
                if ($NoIin) { $suffix = '' }
                Write-Output "Attempting to generate up to $est PAN combinations for: $clean$suffix"
            }
            $total = 0
            try {
                Get-PanCombination -Pattern $clean -IinCheck $iinFilter -CheckLength $checkLength -Schemes $schemes | ForEach-Object {
                    $p = $_
                    $total++
                    $anyValid = $true
                    if ($Json) {
                        $r = Test-Pan -Pan $p -RequireIin $iinFilter -CheckLength $checkLength -Schemes $schemes -BinDb $binDatabase
                        $r['pan'] = Format-PanForOutput -Pan $p -Masked $Mask
                        $r['pattern'] = $clean
                        [void]$jsonOut.Add($r)
                    } else {
                        $m = @(Find-Scheme -Pan $p -Schemes $schemes)
                        $label = 'unknown scheme'
                        if ($m.Count -gt 0) { $label = $m[0]['Scheme']['Name'] }
                        $extra = ''
                        if ($null -ne $binDatabase) {
                            $iss = Find-BinIssuer -Db $binDatabase -Pan $p
                            if ($iss) { $bits = foreach ($k in @('issuer', 'country')) { if ($iss[$k]) { $iss[$k] } }; $extra = "  [$($bits -join ' | ')]" }
                        }
                        Write-Output ('[+] Valid PAN  {0,-20} {1}{2}' -f (Format-PanForOutput -Pan $p -Masked $Mask), $label, $extra)
                    }
                }
            } catch { Write-Output "[-] $($_.Exception.Message)"; continue }
            if (-not $Json) { Write-Output ''; Write-Output "Total valid PAN generated: $total"; Write-Output '' }
            continue
        }

        # Plain validation
        $r = Test-Pan -Pan $clean -RequireIin $requireIin -CheckLength $checkLength -Schemes $schemes -BinDb $binDatabase
        if ($r['valid']) { $anyValid = $true }
        if ($Json) { $r['pan'] = Format-PanForOutput -Pan $r['pan'] -Masked $Mask; [void]$jsonOut.Add($r) }
        else {
            Write-Validation -R $r -Masked $Mask -QuietMode $Quiet
            if (-not $Quiet) { Write-Output '' }
        }
    }

    if ($Json) {
        if ($jsonOut.Count -eq 1) { Write-Output (ConvertTo-Json -InputObject $jsonOut[0] -Depth 8) }
        else { Write-Output (ConvertTo-Json -InputObject $jsonOut.ToArray() -Depth 8) }
    }
    if (-not $anyInput) { $script:ExitCode = 2; return }
    if ($anyValid) { $script:ExitCode = 0; return }
    $script:ExitCode = 1; return
}

$script:ExitCode = 0
Invoke-Main
exit $script:ExitCode
