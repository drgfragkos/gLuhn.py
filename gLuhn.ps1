<#
.SYNOPSIS
    gLuhn.ps1 v1.0 - Check / generate PAN (Luhn), identify the card scheme (IIN) and decode
    magnetic-stripe / EMV track data.  PowerShell port of gLuhn.py: one script that runs
    on Windows PowerShell 5.1 and on PowerShell 7+ (Windows, Linux, macOS) and detects
    the engine it is running under.
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
    Scan a file, a folder (recursive), ZIP/Office archives, PDFs or '-' (stdin) for candidate PANs.
.PARAMETER Emv
    Decode EMV TLV hex data (tags, AID, track 2 equivalent, CVM list, TVR ...). '@file' reads a file.
.PARAMETER Include
    Scan only file names matching these wildcards (repeatable).
.PARAMETER Exclude
    Skip files / folders matching these wildcards.
.PARAMETER NoRecursive
    Scan only the top level of a folder.
.PARAMETER NoArchives
    Do not look inside ZIP / Office files.
.PARAMETER MaxFileSize
    Skip files larger than this many MB when scanning (default 64).
.PARAMETER MinScore
    Scan: report only hits whose confidence score is at least N (0-100).
.PARAMETER UpdateBinDb
    Download the open binlist-data CSV to the -BinDb path (or the 'auto' path) first.
.PARAMETER Lookup
    Online IIN lookup (binlist.net format). Only the 8/6-digit IIN is sent, never the PAN.
.PARAMETER LookupUrl
    Lookup URL template containing {iin}.
.PARAMETER LookupTimeout
    Lookup timeout in seconds (default 8).
.PARAMETER IinTable
    JSON file that extends or overrides the built-in scheme table.
.PARAMETER MaskStyle
    6-4 (default), 8-4 (PCI DSS v4 for 16+ digit PANs), last4 or full; implies -Mask.
.PARAMETER Format
    text (default), json, jsonl or csv (csv/jsonl are meant for -Scan).
.PARAMETER BinDb
    CSV BIN/IIN database for issuer lookup (e.g. the open binlist-data CSV); 'auto' = the
    file downloaded with -UpdateBinDb (%USERPROFILE%\.gluhn\binlist-data.csv).
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
#Requires -Version 5.1
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
    [string]$Emv,
    [string[]]$Include = @(),
    [string[]]$Exclude = @(),
    [switch]$NoRecursive,
    [switch]$NoArchives,
    [double]$MaxFileSize = 64,
    [int]$MinScore = 0,
    [string]$BinDb,
    [switch]$UpdateBinDb,
    [switch]$Lookup,
    [string]$LookupUrl = 'https://lookup.binlist.net/{iin}',
    [double]$LookupTimeout = 8,
    [string]$IinTable,
    [long]$Max = 1000000,
    [Alias('m')][switch]$Mask,
    [ValidateSet('6-4', '8-4', 'last4', 'full')][string]$MaskStyle,
    [ValidateSet('text', 'json', 'jsonl', 'csv')][string]$Format,
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

# ---------------------------------------------------------------------------------
# Engine detection: the script runs unchanged on Windows PowerShell 5.1 ('Desktop')
# and on PowerShell 7+ ('Core').  The few places where the two engines differ
# (JSON escaping, default text encodings, the version banner) consult these flags.
# ---------------------------------------------------------------------------------
$script:PSMajor = $PSVersionTable.PSVersion.Major
$script:PSEditionName = 'Desktop'
if ($PSVersionTable.ContainsKey('PSEdition') -and $PSVersionTable.PSEdition) { $script:PSEditionName = [string]$PSVersionTable.PSEdition }
$script:IsCoreEngine = ($script:PSEditionName -eq 'Core')          # PowerShell 6/7+
$script:IsDesktopEngine = -not $script:IsCoreEngine                  # Windows PowerShell 5.1
$script:EngineText = "PowerShell $($PSVersionTable.PSVersion) ($($script:PSEditionName))"
if ($script:IsDesktopEngine -and $script:PSMajor -ge 5) { $script:EngineText = "Windows $($script:EngineText)" }

# Anything piped into the script (Get-Content pans.txt | .\gLuhn.ps1 -f -) is read from this
# enumerator, but only when -File - asks for it: enumerating $input eagerly would block
# whenever stdin is an open pipe (CI jobs, scheduled tasks) even if no input is wanted.
$script:PipelineInput = $input

$script:GLUHN_VERSION = '1.1.0'
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
# Test card numbers, IMEI prefixes and EMV reference data (same content as gLuhn.py)
# ---------------------------------------------------------------------------------
# Publicly documented test / sandbox card numbers (generated from gLuhn.py).
$script:TEST_CARD_NUMBERS = @{
    '2222400070000005' = 'Adyen'
    '2222420000001113' = 'Mastercard'
    '2222630000001125' = 'Mastercard'
    '2223000048400011' = 'Braintree'
    '2223003122003222' = 'scheme documentation'
    '3056930009020004' = 'Stripe'
    '30569309025904' = 'scheme documentation'
    '3528000700000000' = 'Worldpay'
    '3530111333300000' = 'scheme documentation'
    '3566002020360505' = 'scheme documentation'
    '3569990010095841' = 'Adyen'
    '36227206271667' = 'Stripe'
    '36259600000004' = 'Braintree'
    '36700102000000' = 'Worldpay'
    '370000000000002' = 'Adyen'
    '371449635398431' = 'scheme documentation'
    '378282246310005' = 'scheme documentation'
    '378734493671000' = 'scheme documentation'
    '38520000023237' = 'scheme documentation'
    '4000000000000002' = 'Stripe'
    '4000000000003220' = 'Stripe'
    '4000000000009995' = 'Stripe'
    '4000002500003155' = 'Stripe'
    '4000056655665556' = 'Stripe'
    '4001919257537193' = 'Visa'
    '4005519200000004' = 'Braintree'
    '4007702835532454' = 'Visa'
    '4009348888881881' = 'Braintree'
    '4012000033330026' = 'Braintree'
    '4012000077777777' = 'Braintree'
    '4012888888881881' = 'scheme documentation'
    '4111111111111111' = 'scheme documentation'
    '4111111145551142' = 'Adyen'
    '4166676667666746' = 'Adyen'
    '4217651111111119' = 'Braintree'
    '4222222222222' = 'scheme documentation'
    '4242424242424242' = 'Stripe'
    '4263982640269299' = 'Visa'
    '4444333322221111' = 'Worldpay'
    '4462030000000000' = 'Worldpay'
    '4484070000000000' = 'Worldpay'
    '4500600000000061' = 'Braintree'
    '4646464646464644' = 'Adyen'
    '4911830000000' = 'Worldpay'
    '4917484589897107' = 'Visa'
    '4917610000000000' = 'Worldpay'
    '4988438843884305' = 'Adyen'
    '5019717010103742' = 'scheme documentation'
    '5100290029002909' = 'Adyen'
    '5105105105105100' = 'scheme documentation'
    '5200828282828210' = 'Stripe'
    '5425233430109903' = 'Mastercard'
    '5454545454545454' = 'Worldpay'
    '5500000000000004' = 'Adyen'
    '5555341244441115' = 'Adyen'
    '5555555555554444' = 'scheme documentation'
    '5577000055770004' = 'Adyen'
    '6011000990139424' = 'scheme documentation'
    '6011111111111117' = 'scheme documentation'
    '6011601160116611' = 'Adyen'
    '6011981111111113' = 'Stripe'
    '6200000000000005' = 'scheme documentation'
    '6304000000000000' = 'scheme documentation'
    '6555900000604105' = 'Stripe'
    '6703444444444449' = 'Adyen'
    '6759649826438453' = 'scheme documentation'
    '6771830000000000006' = 'Adyen'
    '6799990100000000019' = 'Worldpay'
}
$script:IMEI_TAC_PREFIXES = @('01', '35', '86', '99', '44', '45', '49', '50', '51', '52', '53', '54', '33')
# tag -> @(name, format)
$script:EMV_TAGS = @{
    '42' = @('Issuer Identification Number (IIN)', 'n')
    '4F' = @('Application Identifier (AID)', 'b')
    '50' = @('Application Label', 'ans')
    '56' = @('Track 1 Data', 'ans')
    '57' = @('Track 2 Equivalent Data', 'track2')
    '5A' = @('Application PAN', 'cn')
    '5F20' = @('Cardholder Name', 'ans')
    '5F24' = @('Application Expiration Date', 'date')
    '5F25' = @('Application Effective Date', 'date')
    '5F28' = @('Issuer Country Code', 'country')
    '5F2A' = @('Transaction Currency Code', 'n')
    '5F2D' = @('Language Preference', 'an')
    '5F30' = @('Service Code', 'service')
    '5F34' = @('Application PAN Sequence Number', 'n')
    '5F36' = @('Transaction Currency Exponent', 'n')
    '5F50' = @('Issuer URL', 'ans')
    '5F53' = @('IBAN', 'an')
    '5F54' = @('Bank Identifier Code (BIC)', 'an')
    '5F55' = @('Issuer Country Code (alpha2)', 'an')
    '5F56' = @('Issuer Country Code (alpha3)', 'an')
    '5F57' = @('Account Type', 'n')
    '61' = @('Application Template', 'template')
    '6F' = @('FCI Template', 'template')
    '70' = @('Record Template', 'template')
    '71' = @('Issuer Script Template 1', 'template')
    '72' = @('Issuer Script Template 2', 'template')
    '73' = @('Directory Discretionary Template', 'template')
    '77' = @('Response Message Template Format 2', 'template')
    '80' = @('Response Message Template Format 1', 'b')
    '81' = @('Amount, Authorised (Binary)', 'b')
    '82' = @('Application Interchange Profile (AIP)', 'aip')
    '83' = @('Command Template', 'b')
    '84' = @('Dedicated File (DF) Name / AID', 'b')
    '86' = @('Issuer Script Command', 'b')
    '87' = @('Application Priority Indicator', 'b')
    '88' = @('Short File Identifier (SFI)', 'b')
    '89' = @('Authorisation Code', 'an')
    '8A' = @('Authorisation Response Code', 'an')
    '8C' = @('CDOL1', 'tags')
    '8D' = @('CDOL2', 'tags')
    '8E' = @('Cardholder Verification Method (CVM) List', 'cvm')
    '8F' = @('CA Public Key Index', 'b')
    '90' = @('Issuer Public Key Certificate', 'b')
    '91' = @('Issuer Authentication Data', 'b')
    '92' = @('Issuer Public Key Remainder', 'b')
    '93' = @('Signed Static Application Data', 'b')
    '94' = @('Application File Locator (AFL)', 'afl')
    '95' = @('Terminal Verification Results (TVR)', 'tvr')
    '97' = @('TDOL', 'tags')
    '98' = @('TC Hash Value', 'b')
    '99' = @('Transaction PIN Data', 'b')
    '9A' = @('Transaction Date', 'date')
    '9B' = @('Transaction Status Information (TSI)', 'tsi')
    '9C' = @('Transaction Type', 'txtype')
    '9D' = @('DDF Name', 'b')
    '9F01' = @('Acquirer Identifier', 'n')
    '9F02' = @('Amount, Authorised', 'amount')
    '9F03' = @('Amount, Other', 'amount')
    '9F04' = @('Amount, Other (Binary)', 'b')
    '9F05' = @('Application Discretionary Data', 'b')
    '9F06' = @('AID (terminal)', 'b')
    '9F07' = @('Application Usage Control (AUC)', 'auc')
    '9F08' = @('Application Version Number (card)', 'b')
    '9F09' = @('Application Version Number (terminal)', 'b')
    '9F0B' = @('Cardholder Name Extended', 'ans')
    '9F0D' = @('Issuer Action Code - Default', 'tvr')
    '9F0E' = @('Issuer Action Code - Denial', 'tvr')
    '9F0F' = @('Issuer Action Code - Online', 'tvr')
    '9F10' = @('Issuer Application Data', 'b')
    '9F11' = @('Issuer Code Table Index', 'n')
    '9F12' = @('Application Preferred Name', 'ans')
    '9F13' = @('Last Online ATC Register', 'b')
    '9F14' = @('Lower Consecutive Offline Limit', 'b')
    '9F15' = @('Merchant Category Code', 'n')
    '9F16' = @('Merchant Identifier', 'ans')
    '9F17' = @('PIN Try Counter', 'b')
    '9F18' = @('Issuer Script Identifier', 'b')
    '9F1A' = @('Terminal Country Code', 'country')
    '9F1B' = @('Terminal Floor Limit', 'b')
    '9F1C' = @('Terminal Identification', 'an')
    '9F1D' = @('Terminal Risk Management Data', 'b')
    '9F1E' = @('Interface Device Serial Number', 'an')
    '9F1F' = @('Track 1 Discretionary Data', 'ans')
    '9F20' = @('Track 2 Discretionary Data', 'cn')
    '9F21' = @('Transaction Time', 'time')
    '9F22' = @('CA Public Key Index (terminal)', 'b')
    '9F23' = @('Upper Consecutive Offline Limit', 'b')
    '9F26' = @('Application Cryptogram', 'b')
    '9F27' = @('Cryptogram Information Data (CID)', 'cid')
    '9F2D' = @('ICC PIN Encipherment Public Key Certificate', 'b')
    '9F2E' = @('ICC PIN Encipherment Public Key Exponent', 'b')
    '9F2F' = @('ICC PIN Encipherment Public Key Remainder', 'b')
    '9F32' = @('Issuer Public Key Exponent', 'b')
    '9F33' = @('Terminal Capabilities', 'termcap')
    '9F34' = @('CVM Results', 'cvmres')
    '9F35' = @('Terminal Type', 'termtype')
    '9F36' = @('Application Transaction Counter (ATC)', 'b')
    '9F37' = @('Unpredictable Number', 'b')
    '9F38' = @('PDOL', 'tags')
    '9F39' = @('POS Entry Mode', 'posentry')
    '9F3A' = @('Amount, Reference Currency', 'b')
    '9F3B' = @('Application Reference Currency', 'n')
    '9F3C' = @('Transaction Reference Currency Code', 'n')
    '9F3D' = @('Transaction Reference Currency Exponent', 'n')
    '9F40' = @('Additional Terminal Capabilities', 'b')
    '9F41' = @('Transaction Sequence Counter', 'n')
    '9F42' = @('Application Currency Code', 'n')
    '9F43' = @('Application Currency Exponent', 'n')
    '9F44' = @('Application Currency Exponent', 'n')
    '9F45' = @('Data Authentication Code', 'b')
    '9F46' = @('ICC Public Key Certificate', 'b')
    '9F47' = @('ICC Public Key Exponent', 'b')
    '9F48' = @('ICC Public Key Remainder', 'b')
    '9F49' = @('DDOL', 'tags')
    '9F4A' = @('Static Data Authentication Tag List', 'b')
    '9F4B' = @('Signed Dynamic Application Data', 'b')
    '9F4C' = @('ICC Dynamic Number', 'b')
    '9F4D' = @('Log Entry', 'b')
    '9F4E' = @('Merchant Name and Location', 'ans')
    '9F4F' = @('Log Format', 'tags')
    '9F51' = @('Application Currency Code (payment system)', 'n')
    '9F53' = @('Transaction Category Code / Consecutive Transaction Limit', 'b')
    '9F5B' = @('Issuer Script Results', 'b')
    '9F66' = @('Terminal Transaction Qualifiers (TTQ)', 'b')
    '9F6B' = @('Track 2 Data (contactless)', 'track2')
    '9F6C' = @('Card Transaction Qualifiers (CTQ)', 'b')
    '9F6E' = @('Form Factor Indicator / Third Party Data', 'b')
    '9F7C' = @('Customer Exclusive Data', 'b')
    'A5' = @('FCI Proprietary Template', 'template')
    'BF0C' = @('FCI Issuer Discretionary Data', 'template')
    'DF8129' = @('Outcome Parameter Set (kernel)', 'b')
}
$script:EMV_AIDS = @{
    'A000000003' = @('Visa', 'Visa (other product)')
    'A0000000031010' = @('Visa', 'Visa credit / debit')
    'A0000000032010' = @('Visa', 'Visa Electron')
    'A0000000032020' = @('Visa', 'V PAY')
    'A0000000033010' = @('Visa', 'Visa Interlink')
    'A0000000038010' = @('Visa', 'Visa Plus')
    'A000000004' = @('Mastercard', 'Mastercard (other product)')
    'A0000000041010' = @('Mastercard', 'Mastercard credit / debit')
    'A0000000042203' = @('Mastercard', 'Mastercard US Maestro common debit')
    'A0000000043060' = @('Mastercard', 'Maestro')
    'A0000000045010' = @('Mastercard', 'Mastercard (test / specific)')
    'A0000000046000' = @('Mastercard', 'Cirrus')
    'A0000000050001' = @('Mastercard', 'Maestro UK')
    'A0000000050002' = @('Mastercard', 'Solo (UK, defunct)')
    'A0000000101030' = @('girocard', 'girocard (Germany)')
    'A000000025' = @('American Express', 'American Express')
    'A00000002501' = @('American Express', 'American Express')
    'A0000000421010' = @('Cartes Bancaires', 'CB credit / debit (France)')
    'A0000000422010' = @('Cartes Bancaires', 'CB debit (France)')
    'A000000065' = @('JCB', 'JCB')
    'A0000000651010' = @('JCB', 'JCB')
    'A0000000980840' = @('Visa', 'Visa US common debit')
    'A0000001211010' = @('Dankort', 'Dankort (Denmark)')
    'A0000001410001' = @('PagoBANCOMAT', 'PagoBANCOMAT (Italy)')
    'A000000152' = @('Discover', 'Discover')
    'A0000001523010' = @('Discover', 'Discover / Diners Club (D-PAS)')
    'A0000001524010' = @('Discover', 'Discover US common debit')
    'A0000002771010' = @('Interac', 'Interac (Canada)')
    'A0000003241010' = @('Discover', 'Discover (ZIP contactless)')
    'A000000333' = @('China UnionPay', 'UnionPay')
    'A0000003330101' = @('China UnionPay', 'UnionPay debit')
    'A0000003330102' = @('China UnionPay', 'UnionPay credit')
    'A0000003330103' = @('China UnionPay', 'UnionPay quasi-credit')
    'A0000003330106' = @('China UnionPay', 'UnionPay electronic cash')
    'A0000003591010028001' = @('girocard', 'girocard (Germany)')
    'A0000003710001' = @('Verve', 'Verve (Nigeria)')
    'A0000004540010' = @('eftpos', 'eftpos savings (Australia)')
    'A0000004540011' = @('eftpos', 'eftpos cheque (Australia)')
    'A0000004951010' = @('Elo', 'Elo (Brazil)')
    'A000000524' = @('RuPay', 'RuPay')
    'A0000005241010' = @('RuPay', 'RuPay')
    'A0000006200620' = @('DNA', 'DNA (Indonesia)')
    'A000000658' = @('Mir', 'Mir')
    'A0000006581010' = @('Mir', 'Mir')
    'A000000672' = @('Troy', 'Troy')
    'A0000006723010' = @('Troy', 'Troy credit')
    'A0000006723020' = @('Troy', 'Troy debit')
}
$script:TVR_BITS = @(
    ,@(1, 8, 'Offline data authentication was not performed')
    ,@(1, 7, 'SDA failed')
    ,@(1, 6, 'ICC data missing')
    ,@(1, 5, 'Card appears on terminal exception file')
    ,@(1, 4, 'DDA failed')
    ,@(1, 3, 'CDA failed')
    ,@(1, 2, 'SDA selected')
    ,@(2, 8, 'ICC and terminal have different application versions')
    ,@(2, 7, 'Expired application')
    ,@(2, 6, 'Application not yet effective')
    ,@(2, 5, 'Requested service not allowed for card product')
    ,@(2, 4, 'New card')
    ,@(3, 8, 'Cardholder verification was not successful')
    ,@(3, 7, 'Unrecognised CVM')
    ,@(3, 6, 'PIN try limit exceeded')
    ,@(3, 5, 'PIN entry required and PIN pad not present or not working')
    ,@(3, 4, 'PIN entry required, PIN pad present, but PIN was not entered')
    ,@(3, 3, 'Online PIN entered')
    ,@(4, 8, 'Transaction exceeds floor limit')
    ,@(4, 7, 'Lower consecutive offline limit exceeded')
    ,@(4, 6, 'Upper consecutive offline limit exceeded')
    ,@(4, 5, 'Transaction selected randomly for online processing')
    ,@(4, 4, 'Merchant forced transaction online')
    ,@(5, 8, 'Default TDOL used')
    ,@(5, 7, 'Issuer authentication failed')
    ,@(5, 6, 'Script processing failed before final GENERATE AC')
    ,@(5, 5, 'Script processing failed after final GENERATE AC')
)
$script:TSI_BITS = @(
    ,@(1, 8, 'Offline data authentication was performed')
    ,@(1, 7, 'Cardholder verification was performed')
    ,@(1, 6, 'Card risk management was performed')
    ,@(1, 5, 'Issuer authentication was performed')
    ,@(1, 4, 'Terminal risk management was performed')
    ,@(1, 3, 'Script processing was performed')
)
$script:AIP_BITS = @(
    ,@(1, 7, 'SDA supported')
    ,@(1, 6, 'DDA supported')
    ,@(1, 5, 'Cardholder verification is supported')
    ,@(1, 4, 'Terminal risk management is to be performed')
    ,@(1, 3, 'Issuer authentication is supported')
    ,@(1, 1, 'CDA supported')
    ,@(2, 8, 'Reserved for payment systems (EMV mode / contactless)')
)
$script:AUC_BITS = @(
    ,@(1, 8, 'Valid for domestic cash transactions')
    ,@(1, 7, 'Valid for international cash transactions')
    ,@(1, 6, 'Valid for domestic goods')
    ,@(1, 5, 'Valid for international goods')
    ,@(1, 4, 'Valid for domestic services')
    ,@(1, 3, 'Valid for international services')
    ,@(1, 2, 'Valid at ATMs')
    ,@(1, 1, 'Valid at terminals other than ATMs')
    ,@(2, 8, 'Domestic cashback allowed')
    ,@(2, 7, 'International cashback allowed')
)
$script:CVM_CODES = @{
    0 = 'Fail CVM processing'
    1 = 'Plaintext PIN verified by ICC'
    2 = 'Enciphered PIN verified online'
    3 = 'Plaintext PIN by ICC and signature'
    4 = 'Enciphered PIN verified by ICC'
    5 = 'Enciphered PIN by ICC and signature'
    30 = 'Signature (paper)'
    31 = 'No CVM required'
}
$script:CVM_CONDITIONS = @{
    0 = 'Always'
    1 = 'If unattended cash'
    2 = 'If not unattended cash, not manual cash, not purchase with cashback'
    3 = 'If terminal supports the CVM'
    4 = 'If manual cash'
    5 = 'If purchase with cashback'
    6 = 'If transaction is in the application currency and under X'
    7 = 'If transaction is in the application currency and over X'
    8 = 'If transaction is in the application currency and under Y'
    9 = 'If transaction is in the application currency and over Y'
}
$script:TRANSACTION_TYPES = @{
    '00' = 'Goods and services (purchase)'
    '01' = 'Cash'
    '09' = 'Purchase with cashback'
    '20' = 'Refund'
    '30' = 'Balance inquiry'
    '40' = 'Transfer'
}
$script:TERMINAL_TYPES = @{
    '11' = 'Financial institution, attended, online only'
    '12' = 'Financial institution, attended, offline with online capability'
    '13' = 'Financial institution, attended, offline only'
    '14' = 'Financial institution, unattended, online only'
    '15' = 'Financial institution, unattended, offline with online capability'
    '16' = 'Financial institution, unattended, offline only'
    '21' = 'Merchant, attended, online only'
    '22' = 'Merchant, attended, offline with online capability'
    '23' = 'Merchant, attended, offline only'
    '24' = 'Merchant, unattended, online only'
    '25' = 'Merchant, unattended, offline with online capability'
    '26' = 'Merchant, unattended, offline only'
    '34' = 'Cardholder, unattended, online only'
    '35' = 'Cardholder, unattended, offline with online capability'
    '36' = 'Cardholder, unattended, offline only'
}
$script:POS_ENTRY_MODES = @{
    '00' = 'Unknown'
    '01' = 'Manual key entry'
    '02' = 'Magnetic stripe'
    '05' = 'Integrated circuit card (contact chip)'
    '07' = 'Contactless chip (EMV mode)'
    '80' = 'Fallback to magnetic stripe'
    '90' = 'Magnetic stripe, full track read'
    '91' = 'Contactless magnetic stripe mode'
    '95' = 'Chip read, CVV may be unreliable'
}

$script:DEFAULT_LOOKUP_URL = 'https://lookup.binlist.net/{iin}'
$script:BINLIST_DATA_URL = 'https://raw.githubusercontent.com/iannuttall/binlist-data/master/binlist-data.csv'
$script:DEFAULT_BIN_DB_PATH = Join-Path (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.gluhn') 'binlist-data.csv'
$script:ARCHIVE_EXTENSIONS = @('.zip', '.jar', '.war', '.docx', '.xlsx', '.pptx', '.odt', '.ods', '.odp', '.xlsm', '.docm')

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
    $firstLine = Get-Content -LiteralPath $Path -TotalCount 1 -Encoding UTF8
    $delim = ','
    foreach ($cand in @("`t", ';', '|')) { if ($firstLine.Split($cand).Count -gt $firstLine.Split($delim).Count) { $delim = $cand } }
    # -Encoding UTF8 reads BOM-less UTF-8 correctly on both engines (5.1 would otherwise
    # fall back to the ANSI code page and garble non-ASCII bank names).
    $rows = @(Import-Csv -LiteralPath $Path -Delimiter $delim -Encoding UTF8)
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
    # PCI DSS masking. 6-4: first 6 / last 4. 8-4: first 8 / last 4 (PCI DSS v4, PANs of 16+
    # digits; shorter PANs fall back to 6-4). last4: only the last four. full: every digit.
    param([string]$Pan, [string]$Style = '6-4')
    $n = $Pan.Length
    if ($Style -eq 'full') { return ('*' * $n) }
    if ($Style -eq 'last4') { if ($n -gt 4) { return ('*' * ($n - 4)) + $Pan.Substring($n - 4) } return ('*' * $n) }
    $head = 6
    if ($Style -eq '8-4' -and $n -ge 16) { $head = 8 }
    if ($n -le $head + 4) { return ('*' * $n) }
    return $Pan.Substring(0, $head) + ('*' * ($n - $head - 4)) + $Pan.Substring($n - 4)
}

function Get-ExpiryStatus {
    # Sanity check of a YYMM expiry: valid / expired / far-future / invalid.
    param([string]$Yymm, [DateTime]$Today = (Get-Date))
    if (-not $Yymm) { return $null }
    if ($Yymm -notmatch '^\d{4}$') { return [ordered]@{ status = 'invalid'; text = "expiry '$Yymm' is not YYMM" } }
    $yy = [int]$Yymm.Substring(0, 2); $mm = [int]$Yymm.Substring(2, 2)
    if ($mm -lt 1 -or $mm -gt 12) { return [ordered]@{ status = 'invalid'; text = ('month {0:D2} does not exist' -f $mm) } }
    $year = 2000 + $yy
    $iso = '{0:D4}-{1:D2}' -f $year, $mm
    if ($year -lt $Today.Year -or ($year -eq $Today.Year -and $mm -lt $Today.Month)) {
        return [ordered]@{ status = 'expired'; text = "expired ($iso is in the past)"; iso = $iso }
    }
    if ($year -gt $Today.Year + 10) {
        return [ordered]@{ status = 'far-future'; text = "implausibly far in the future ($iso), test or fabricated data?"; iso = $iso }
    }
    return [ordered]@{ status = 'valid'; text = "valid until end of $iso"; iso = $iso }
}

function Test-TestCard {
    # The source that publishes $Pan as a test number, or $null.
    param([string]$Pan)
    if ($script:TEST_CARD_NUMBERS.ContainsKey($Pan)) { return $script:TEST_CARD_NUMBERS[$Pan] }
    return $null
}

function Get-LookalikeHint {
    # Other Luhn-checked identifiers that are easily mistaken for a PAN.
    param([string]$Pan)
    if ($Pan.Length -eq 15 -and ($script:IMEI_TAC_PREFIXES -contains $Pan.Substring(0, 2)) -and (Test-Luhn $Pan)) {
        return [ordered]@{ kind = 'IMEI'; detail = "TAC $($Pan.Substring(0, 8)), serial $($Pan.Substring(8, 6))"
            text = '15-digit Luhn number with a mobile equipment TAC prefix: likely an IMEI, not a card' }
    }
    if ($Pan.Length -ge 18 -and $Pan.StartsWith('89') -and (Test-Luhn $Pan)) {
        return [ordered]@{ kind = 'ICCID'; detail = "MII 89 telecom, country $($Pan.Substring(2, 3))"
            text = '18-20 digit Luhn number starting 89: likely a SIM ICCID, not a card' }
    }
    return $null
}

function Get-DiscretionaryHints {
    # Typical (issuer specific) layout of track 2 discretionary data: PVKI (1), PVV (4), CVV1 (3).
    param([string]$Disc)
    if (-not $Disc -or $Disc.Length -lt 8 -or $Disc.Substring(0, 8) -notmatch '^\d{8}$') { return $null }
    return [ordered]@{ pvki = $Disc.Substring(0, 1); pvv = $Disc.Substring(1, 4); cvv1 = $Disc.Substring(5, 3)
        note = 'typical layout only; issuers may place PVKI/PVV/CVV1 differently' }
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
    param([string]$Pan, [bool]$RequireIin = $false, [bool]$CheckLength = $true, [object[]]$Schemes = $script:SCHEMES, $BinDb = $null, $Lookup = $null)
    $Pan = ConvertTo-NormalisedPan $Pan
    $r = [ordered]@{
        pan = $Pan; length = $Pan.Length; well_formed = $false; luhn = $false; luhn_expected = $true
        mii = $null; iin6 = $null; iin8 = $null
        scheme = $null; scheme_key = $null; scheme_active = $true; scheme_note = ''; iin_range = $null
        length_ok = $null; expected_lengths = @(); also_matches = @(); issuer = $null
        test_card = $null; lookalike = $null; lookup = $null; valid = $false
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
    $r['test_card'] = Test-TestCard $Pan
    $r['lookalike'] = Get-LookalikeHint $Pan
    if ($null -ne $Lookup -and $r['well_formed']) { $r['lookup'] = Invoke-IinLookup -Lookup $Lookup -Pan $Pan }

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
    $out = [ordered]@{ input = $raw; track = $null; pan = $null; expiry = $null; expiry_text = $null; expiry_status = $null
        service_code = $null; discretionary = $null; discretionary_hints = $null; name = $null; sad_warning = $null }
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
    if ($tail['Expiry']) {
        $e = $tail['Expiry']
        $out['expiry_text'] = "20$($e.Substring(0,2))-$($e.Substring(2)) (YYMM $e)"
        $out['expiry_status'] = Get-ExpiryStatus $e
    }
    if ($tail['Service']) { $out['service_code'] = ConvertFrom-ServiceCode $tail['Service'] }
    if ($tail['Discretionary']) { $out['discretionary'] = $tail['Discretionary'] }
    $out['discretionary_hints'] = Get-DiscretionaryHints $tail['Discretionary']
    # Any track data carries sensitive authentication data (PCI DSS v4 requirement 3.3.1).
    $out['sad_warning'] = 'Full track data is sensitive authentication data: it must not be retained after authorisation (PCI DSS v4 req. 3.3.1).'
    return $out
}

# ---------------------------------------------------------------------------------
# External IIN table (JSON) to extend or override the built-in schemes
# ---------------------------------------------------------------------------------
function Get-JsonProperty {
    # $null-safe property access for ConvertFrom-Json objects and hashtables (strict mode friendly).
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) { if ($Object.Contains($Name)) { return $Object[$Name] } return $Default }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -ne $prop -and $null -ne $prop.Value) { return $prop.Value }
    return $Default
}

function Import-IinTable {
    # JSON: {"schemes":[{"key","name","ranges":[],"lengths":[],"catch_all":[],"luhn":true,"active":true,"note":""}],"replace":false}
    param([string]$Path)
    $data = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    $entries = @(Get-JsonProperty $data 'schemes' @())
    if ($data -is [array]) { $entries = @($data) }
    $extra = New-Object System.Collections.ArrayList
    foreach ($e in $entries) {
        $key = Get-JsonProperty $e 'key'
        $ranges = @(Get-JsonProperty $e 'ranges' @())
        if (-not $key -or $ranges.Count -eq 0) { throw "every scheme needs a key and at least one range: $($e | ConvertTo-Json -Compress)" }
        $lengths = @(Get-JsonProperty $e 'lengths' @($script:PAN_MIN_LEN..$script:PAN_MAX_LEN))
        $luhn = Get-JsonProperty $e 'luhn' $true
        $active = Get-JsonProperty $e 'active' $true
        [void]$extra.Add((New-Scheme -Key ([string]$key) -Name ([string](Get-JsonProperty $e 'name' $key)) -Ranges @($ranges | ForEach-Object { [string]$_ }) `
            -Lengths @($lengths | ForEach-Object { [int]$_ }) -Luhn ([bool]$luhn) -Active ([bool]$active) `
            -Note ([string](Get-JsonProperty $e 'note' '')) -CatchAll @(@(Get-JsonProperty $e 'catch_all' @()) | ForEach-Object { [string]$_ })))
    }
    if ((Get-JsonProperty $data 'replace' $false) -eq $true) { $merged = @($extra) }
    else {
        $byKey = @{}
        foreach ($x in $extra) { $byKey[$x['Key']] = $x }
        $merged = New-Object System.Collections.ArrayList
        foreach ($b in $script:SCHEMES) {
            if ($byKey.ContainsKey($b['Key'])) { [void]$merged.Add($byKey[$b['Key']]); $byKey.Remove($b['Key']) } else { [void]$merged.Add($b) }
        }
        foreach ($x in $extra) { if ($byKey.ContainsKey($x['Key'])) { [void]$merged.Add($x) } }
        $merged = @($merged)
    }
    for ($i = 0; $i -lt $merged.Count; $i++) { $merged[$i]['Order'] = $i }
    return $merged
}

function Set-SchemeTable { param([object[]]$Schemes) $script:SCHEMES = @($Schemes) }

# ---------------------------------------------------------------------------------
# Online IIN lookup (opt-in). Only the IIN (8 or 6 digits) ever leaves the machine.
# ---------------------------------------------------------------------------------
function New-OnlineLookup {
    param([string]$UrlTemplate = $script:DEFAULT_LOOKUP_URL, [double]$Timeout = 8)
    if (-not $UrlTemplate.Contains('{iin}')) { throw 'lookup URL must contain {iin}' }
    if ($script:IsDesktopEngine) {
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    }
    return @{ UrlTemplate = $UrlTemplate; Timeout = [int][Math]::Max(1, [Math]::Ceiling($Timeout)); Cache = @{}; Requests = 0
        Source = ($UrlTemplate -split '/')[2] }
}

function Invoke-LookupRequest {
    # Returns @{ Data = <object or $null>; Error = <string or $null> }
    param($Lookup, [string]$Iin)
    $url = $Lookup['UrlTemplate'].Replace('{iin}', $Iin)
    $Lookup['Requests']++
    try {
        $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec $Lookup['Timeout'] `
            -Headers @{ 'Accept-Version' = '3'; 'Accept' = 'application/json' } -UserAgent "gLuhn/$($script:GLUHN_VERSION)"
        $body = [string]$resp.Content
    } catch {
        $code = $null
        try { $code = [int]$_.Exception.Response.StatusCode } catch { }
        if ($code) { return @{ Data = $null; Error = "HTTP $code" } }
        return @{ Data = $null; Error = $_.Exception.GetType().Name + ': ' + $_.Exception.Message }
    }
    try { return @{ Data = ($body | ConvertFrom-Json); Error = $null } }
    catch { return @{ Data = $null; Error = 'response is not JSON' } }
}

function ConvertTo-FlatLookup {
    param($Data)
    $out = [ordered]@{}
    foreach ($k in @('scheme', 'type', 'brand', 'prepaid')) { $v = Get-JsonProperty $Data $k; if ($null -ne $v -and "$v" -ne '') { $out[$k] = $v } }
    $country = Get-JsonProperty $Data 'country'
    if ($country -is [string]) { $out['country'] = $country }
    elseif ($null -ne $country) {
        $v = Get-JsonProperty $country 'name'; if ($v) { $out['country'] = $v }
        $v = Get-JsonProperty $country 'alpha2'; if ($v) { $out['country_code'] = $v }
        $v = Get-JsonProperty $country 'currency'; if ($v) { $out['currency'] = $v }
    }
    $bank = Get-JsonProperty $Data 'bank'
    if ($bank -is [string]) { $out['bank_name'] = $bank }
    elseif ($null -ne $bank) { foreach ($k in @('name', 'url', 'phone', 'city')) { $v = Get-JsonProperty $bank $k; if ($v) { $out["bank_$k"] = $v } } }
    $number = Get-JsonProperty $Data 'number'
    if ($null -ne $number -and -not ($number -is [string])) { $v = Get-JsonProperty $number 'length'; if ($v) { $out['length'] = $v } }
    if ($out.Count -eq 0) { $out['raw'] = $Data }
    return $out
}

function Invoke-IinLookup {
    param($Lookup, [string]$Pan)
    foreach ($n in @(8, 6)) {
        if ($Pan.Length -lt $n) { continue }
        $iin = $Pan.Substring(0, $n)
        if ($Lookup['Cache'].ContainsKey($iin)) { return $Lookup['Cache'][$iin] }
        $resp = Invoke-LookupRequest -Lookup $Lookup -Iin $iin
        if ($null -ne $resp['Data']) {
            $result = ConvertTo-FlatLookup $resp['Data']
            $result['iin'] = $iin; $result['source'] = $Lookup['Source']
            $Lookup['Cache'][$iin] = $result
            return $result
        }
        if ($resp['Error'] -and -not $resp['Error'].StartsWith('HTTP 404')) {
            $result = [ordered]@{ iin = $iin; error = $resp['Error'] }
            $Lookup['Cache'][$iin] = $result
            return $result
        }
    }
    $result = [ordered]@{ iin = $Pan.Substring(0, [Math]::Min(6, $Pan.Length)); error = 'not found' }
    $Lookup['Cache'][$result['iin']] = $result
    return $result
}

function Save-BinDatabase {
    # Download the open binlist-data CSV to $Path; returns the number of bytes written.
    param([string]$Path = $script:DEFAULT_BIN_DB_PATH, [string]$Url = $script:BINLIST_DATA_URL)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if ($script:IsDesktopEngine) {
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    }
    $tmp = "$Path.part"
    Invoke-WebRequest -Uri $Url -OutFile $tmp -UseBasicParsing -TimeoutSec 120 -UserAgent "gLuhn/$($script:GLUHN_VERSION)"
    $head = Get-Content -LiteralPath $tmp -TotalCount 1 -Encoding UTF8
    if (-not $head -or -not $head.Trim().ToLower().StartsWith('bin')) { Remove-Item -LiteralPath $tmp -Force; throw "downloaded file does not look like a BIN CSV (no 'bin' header)" }
    Move-Item -LiteralPath $tmp -Destination $Path -Force
    return (Get-Item -LiteralPath $Path).Length
}

# ---------------------------------------------------------------------------------
# Scanning files, folders and archives for candidate PANs (data discovery)
# ---------------------------------------------------------------------------------
$script:SCAN_RE = '(?<![0-9])(?:[0-9][ \-]?){11,18}[0-9](?![0-9])'
$script:CONTEXT_RE = '\b(card|cards|pan|visa|mastercard|master\s*card|amex|american\s+express|discover|diners|jcb|maestro|unionpay|cc|ccnum|cc_?number|credit|debit|card_?number|card_?no|acct|account|exp|expiry|expires|expiration|valid\s*thru|cvv|cvc|cvv2|cvc2|cid|track|bin|iin|payment|cardholder|kartennummer|carte|tarjeta|numero)\b'
$script:EXPIRY_NEAR_RE = '(?<!\d)(0[1-9]|1[0-2])\s*[/\-]\s*(\d{2}|20\d{2})(?!\d)'
$script:CONTEXT_WINDOW = 48

function Test-MonotoneRun {
    # True for keyboard-walk numbers: 1234567..., 9876543..., 1111111...
    param([string]$Pan, [int]$Length = 6)
    for ($i = 0; $i -le $Pan.Length - $Length; $i++) {
        $chunk = $Pan.Substring($i, $Length)
        $diff = [int][char]$chunk[1] - [int][char]$chunk[0]
        if ($diff -lt -1 -or $diff -gt 1) { continue }
        $ok = $true
        for ($j = 1; $j -lt $Length - 1; $j++) { if (([int][char]$chunk[$j + 1] - [int][char]$chunk[$j]) -ne $diff) { $ok = $false; break } }
        if ($ok) { return $true }
    }
    return $false
}

function Get-HitScore {
    # Confidence that the match at $Line[$Start..$End) is a real cardholder PAN: @{Score;Level;Signals}
    param([string]$Line, [int]$Start, [int]$End, $Result)
    $pan = $Result['pan']
    $score = 40
    $signals = New-Object System.Collections.ArrayList
    $iinRange = [string]$Result['iin_range']
    $digitsInRange = ($iinRange -split '-')[0].Length
    if ($Result['scheme'] -and $digitsInRange -ge 4) { $score += 15; [void]$signals.Add('specific IIN') }
    elseif ($Result['scheme'] -and $digitsInRange -le 2) {
        $catchAll = $false
        foreach ($sc in $script:SCHEMES) {
            if ($sc['Key'] -ne $Result['scheme_key']) { continue }
            foreach ($rg in $sc['Ranges']) { if ($rg['CatchAll'] -and (Test-PrefixInRange -Pan $pan -Lo $rg['Lo'] -Hi $rg['Hi'])) { $catchAll = $true } }
        }
        if ($catchAll) { $score -= 15; [void]$signals.Add('catch-all IIN') }
    }
    if (-not $Result['scheme']) { $score -= 20; [void]$signals.Add('unknown IIN') }
    $raw = $Line.Substring($Start, $End - $Start)
    if ($raw -match '\d[ \-]\d' -and ([regex]::Matches($raw, '[ \-]')).Count -ge 2) { $score += 10; [void]$signals.Add('grouped digits') }
    if (Test-MonotoneRun $pan) { $score -= 25; [void]$signals.Add('sequential/repeated digits') }
    if ($Result['test_card']) { $score -= 25; [void]$signals.Add("known test number ($($Result['test_card']))") }
    if ($Result['lookalike']) { $score -= 30; [void]$signals.Add("looks like $($Result['lookalike']['kind'])") }
    $bStart = [Math]::Max(0, $Start - $script:CONTEXT_WINDOW)
    $before = $Line.Substring($bStart, $Start - $bStart)
    $after = $Line.Substring($End, [Math]::Min($script:CONTEXT_WINDOW, $Line.Length - $End))
    $context = "$before $after"
    if ([regex]::IsMatch($context, $script:CONTEXT_RE, 'IgnoreCase')) { $score += 20; [void]$signals.Add('card keyword nearby') }
    if ([regex]::IsMatch($after, $script:EXPIRY_NEAR_RE) -or [regex]::IsMatch($before, $script:EXPIRY_NEAR_RE)) { $score += 10; [void]$signals.Add('expiry nearby (possible SAD)') }
    elseif ([regex]::IsMatch($after, '(?<![0-9])[0-9]{3,4}(?![0-9])') -and [regex]::IsMatch($context, '\b(cvv|cvc|cid|cvv2|cvc2|sec)\b', 'IgnoreCase')) { $score += 5; [void]$signals.Add('CVV-like value nearby (possible SAD)') }
    $score = [Math]::Max(0, [Math]::Min(100, $score))
    $level = 'LOW'
    if ($score -ge 70) { $level = 'HIGH' } elseif ($score -ge 45) { $level = 'MEDIUM' }
    return @{ Score = $score; Level = $level; Signals = @($signals) }
}

function Search-PanInText {
    param([string[]]$Lines, [bool]$RequireIin = $true, [bool]$CheckLength = $true, [object[]]$Schemes = $script:SCHEMES, $BinDb = $null,
          [int]$MinScore = 0, [string]$Source = '<text>')
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
            if (-not $r['valid']) { continue }
            $sc = Get-HitScore -Line $line -Start $m.Index -End ($m.Index + $m.Length) -Result $r
            if ($sc['Score'] -lt $MinScore) { continue }
            $r['source'] = $Source
            $r['line'] = $lineno
            $r['column'] = $m.Index + 1
            $r['duplicate'] = $seen.ContainsKey($pan)
            $r['score'] = $sc['Score']
            $r['confidence'] = $sc['Level']
            $r['signals'] = $sc['Signals']
            $seen[$pan] = $true
            Write-Output $r
        }
    }
}

function Get-SubBytes {
    param([byte[]]$Bytes, [int]$Start, [int]$Count)
    if ($Count -le 0 -or $Start -ge $Bytes.Length) { return (New-Object byte[] 0) }
    $Count = [Math]::Min($Count, $Bytes.Length - $Start)
    $out = New-Object byte[] $Count
    [Array]::Copy($Bytes, $Start, $out, 0, $Count)
    return , $out
}

function ConvertFrom-ScanBytes {
    # Decode a file for scanning: BOMs, UTF-16 without BOM (NUL pattern), UTF-8, else Latin-1.
    param([byte[]]$Data)
    if ($Data.Length -ge 3 -and $Data[0] -eq 0xEF -and $Data[1] -eq 0xBB -and $Data[2] -eq 0xBF) { return [Text.Encoding]::UTF8.GetString($Data, 3, $Data.Length - 3) }
    if ($Data.Length -ge 2 -and $Data[0] -eq 0xFF -and $Data[1] -eq 0xFE) { return [Text.Encoding]::Unicode.GetString($Data, 2, $Data.Length - 2) }
    if ($Data.Length -ge 2 -and $Data[0] -eq 0xFE -and $Data[1] -eq 0xFF) { return [Text.Encoding]::BigEndianUnicode.GetString($Data, 2, $Data.Length - 2) }
    $n = [Math]::Min(4096, $Data.Length)
    if ($n -gt 1) {
        $odd = 0; $even = 0
        for ($i = 0; $i -lt $n; $i++) { if ($Data[$i] -eq 0) { if ($i % 2 -eq 1) { $odd++ } else { $even++ } } }
        $half = [Math]::Max(1, [int]($n / 2))
        if ($odd -gt $half * 0.6 -and $even -lt $half * 0.1) { return [Text.Encoding]::Unicode.GetString($Data) }
        if ($even -gt $half * 0.6 -and $odd -lt $half * 0.1) { return [Text.Encoding]::BigEndianUnicode.GetString($Data) }
    }
    try { return (New-Object System.Text.UTF8Encoding($false, $true)).GetString($Data) }
    catch { return [Text.Encoding]::GetEncoding(28591).GetString($Data) }
}

function Expand-DeflateBytes {
    # Inflate raw deflate data; $SkipZlibHeader drops the 2-byte zlib header first.
    param([byte[]]$Data, [bool]$SkipZlibHeader)
    $start = 0
    if ($SkipZlibHeader) { $start = 2 }
    $in = New-Object System.IO.MemoryStream(, (Get-SubBytes $Data $start ($Data.Length - $start)))
    $ds = New-Object System.IO.Compression.DeflateStream($in, [System.IO.Compression.CompressionMode]::Decompress)
    $out = New-Object System.IO.MemoryStream
    try { $ds.CopyTo($out) } finally { $ds.Dispose() }
    return , $out.ToArray()
}

function Get-PdfText {
    # Best-effort text recovery from a PDF: inflate FlateDecode streams, collect text operands.
    param([byte[]]$Data)
    $latin = [Text.Encoding]::GetEncoding(28591)
    $text = $latin.GetString($Data)
    $chunks = New-Object System.Collections.ArrayList
    foreach ($m in [regex]::Matches($text, 'stream\r?\n(.*?)\r?\nendstream', 'Singleline')) {
        $raw = $latin.GetBytes($m.Groups[1].Value)
        $content = $null
        try { $content = Expand-DeflateBytes $raw $true } catch {
            try { $content = Expand-DeflateBytes $raw $false } catch { $content = $raw }
        }
        if (-not $content -or $content.Length -eq 0) { continue }
        $ctext = $latin.GetString($content)
        if ($ctext.Contains('Tj') -or $ctext.Contains('TJ')) {
            $parts = New-Object System.Collections.ArrayList
            foreach ($op in [regex]::Matches($ctext, '\[(.*?)\]\s*TJ|\((.*?)(?<!\\)\)\s*Tj|(T\*|Td|TD|Tm|ET)', 'Singleline')) {
                if ($op.Groups[1].Success) {
                    $pieces = foreach ($pm in [regex]::Matches($op.Groups[1].Value, '\((.*?)(?<!\\)\)', 'Singleline')) { $pm.Groups[1].Value }
                    [void]$parts.Add(-join $pieces)
                } elseif ($op.Groups[2].Success) { [void]$parts.Add($op.Groups[2].Value) }
                else { if ($parts.Count -gt 0) { [void]$chunks.Add(-join $parts); $parts.Clear() } }
            }
            if ($parts.Count -gt 0) { [void]$chunks.Add(-join $parts) }
        } else { [void]$chunks.Add($ctext) }
    }
    [void]$chunks.Add($text)
    return (($chunks -join "`n").Replace('\(', '(').Replace('\)', ')'))
}

function Get-BytesSha256 {
    param([byte[]]$Data)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Data)).Replace('-', '').ToLower()) } finally { $sha.Dispose() }
}

function Get-ScanSourceFromBytes {
    # Emits @{Name; Lines; Sha256} for a byte buffer, opening archives / gzip / PDF as needed.
    param([string]$Name, [byte[]]$Data, [bool]$Archives, [int]$Depth, [long]$MaxBytes)
    $lower = $Name.ToLower()
    $isZipExt = $false
    foreach ($ext in $script:ARCHIVE_EXTENSIONS) { if ($lower.EndsWith($ext)) { $isZipExt = $true } }
    $isZipMagic = ($Data.Length -ge 4 -and $Data[0] -eq 0x50 -and $Data[1] -eq 0x4B -and $Data[2] -eq 3 -and $Data[3] -eq 4)
    if ($Archives -and $Depth -lt 3 -and ($isZipExt -or $isZipMagic)) {
        $opened = $false
        try {
            try { Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue } catch { }
            $ms = New-Object System.IO.MemoryStream(, $Data)
            $zip = New-Object System.IO.Compression.ZipArchive($ms, [System.IO.Compression.ZipArchiveMode]::Read)
            $opened = $true
            foreach ($entry in $zip.Entries) {
                if (-not $entry.Name -or $entry.Length -gt $MaxBytes) { continue }
                try {
                    $es = $entry.Open(); $buf = New-Object System.IO.MemoryStream
                    try { $es.CopyTo($buf) } finally { $es.Dispose() }
                    $member = $buf.ToArray()
                } catch { continue }
                Get-ScanSourceFromBytes -Name "$Name!$($entry.FullName)" -Data $member -Archives $Archives -Depth ($Depth + 1) -MaxBytes $MaxBytes
            }
            $zip.Dispose()
            return
        } catch { if ($opened) { return } }
    }
    if ($lower.EndsWith('.gz') -and $Data.Length -ge 2 -and $Data[0] -eq 0x1F -and $Data[1] -eq 0x8B) {
        try {
            $in = New-Object System.IO.MemoryStream(, $Data)
            $gz = New-Object System.IO.Compression.GZipStream($in, [System.IO.Compression.CompressionMode]::Decompress)
            $out = New-Object System.IO.MemoryStream
            try { $gz.CopyTo($out) } finally { $gz.Dispose() }
            $Data = $out.ToArray(); $Name = $Name.Substring(0, $Name.Length - 3); $lower = $Name.ToLower()
        } catch { }
    }
    $isPdf = ($Data.Length -ge 5 -and [Text.Encoding]::ASCII.GetString($Data, 0, 5) -eq '%PDF-')
    if ($lower.EndsWith('.pdf') -or $isPdf) { $text = Get-PdfText $Data } else { $text = ConvertFrom-ScanBytes $Data }
    Write-Output @{ Name = $Name; Lines = @($text -split "`r?`n"); Sha256 = (Get-BytesSha256 $Data) }
}

function Test-GlobMatch { param([string]$Text, [string[]]$Globs) foreach ($g in $Globs) { if ($Text -like $g) { return $true } } return $false }

function Get-ScanSource {
    # Emits @{Name; Lines; Sha256} for '-' (stdin), a file, or every file under a folder.
    param([string]$Path, [bool]$Recursive = $true, [string[]]$Include = @(), [string[]]$Exclude = @(),
          [long]$MaxBytes = 67108864, [bool]$Archives = $true, $Skipped = $null)
    if ($Path -eq '-') { Write-Output @{ Name = '<stdin>'; Lines = (Read-InputLines '-'); Sha256 = $null }; return }
    if (Test-Path -LiteralPath $Path -PathType Container) {
        # Same order as the Python version: the files of a folder (sorted), then its sub folders (sorted).
        $files = @(Get-ChildItem -LiteralPath $Path -File -Force -ErrorAction SilentlyContinue | Sort-Object Name)
        foreach ($f in $files) {
            if ($Exclude.Count -gt 0 -and ((Test-GlobMatch $f.Name $Exclude) -or (Test-GlobMatch $f.FullName $Exclude))) { continue }
            if ($Include.Count -gt 0 -and -not (Test-GlobMatch $f.Name $Include)) { continue }
            Get-ScanSource -Path $f.FullName -Recursive $Recursive -Include @() -Exclude @() -MaxBytes $MaxBytes -Archives $Archives -Skipped $Skipped
        }
        if ($Recursive) {
            $dirs = @(Get-ChildItem -LiteralPath $Path -Directory -Force -ErrorAction SilentlyContinue | Sort-Object Name)
            foreach ($d in $dirs) {
                if ($Exclude.Count -gt 0 -and (Test-GlobMatch $d.Name $Exclude)) { continue }
                Get-ScanSource -Path $d.FullName -Recursive $true -Include $Include -Exclude $Exclude -MaxBytes $MaxBytes -Archives $Archives -Skipped $Skipped
            }
        }
        return
    }
    try {
        $item = Get-Item -LiteralPath $Path -ErrorAction Stop
        if ($item.Length -gt $MaxBytes) { if ($null -ne $Skipped) { [void]$Skipped.Add(('{0} ({1:N1} MB > limit)' -f $Path, ($item.Length / 1MB))) }; return }
        $data = [System.IO.File]::ReadAllBytes($item.FullName)
    } catch { if ($null -ne $Skipped) { [void]$Skipped.Add("$Path ($($_.Exception.Message))") }; return }
    Get-ScanSourceFromBytes -Name $Path -Data $data -Archives $Archives -Depth 0 -MaxBytes $MaxBytes
}

# ---------------------------------------------------------------------------------
# EMV TLV decoding (chip data: ICC records, GPO / GENERATE AC responses, tag dumps)
# ---------------------------------------------------------------------------------
function ConvertTo-CleanHex {
    param([string]$Text)
    if ($Text.StartsWith('@')) { $Text = Get-Content -LiteralPath $Text.Substring(1) -Raw -Encoding UTF8 }
    $Text = [regex]::Replace($Text, '0x', '', 'IgnoreCase')
    $Text = [regex]::Replace($Text, '[^0-9A-Fa-f]', '')
    if ($Text.Length % 2 -ne 0) { throw 'odd number of hex digits' }
    return $Text.ToUpper()
}

function ConvertFrom-HexString {
    param([string]$Hex)
    $bytes = New-Object byte[] ($Hex.Length / 2)
    for ($i = 0; $i -lt $Hex.Length; $i += 2) { $bytes[$i / 2] = [Convert]::ToByte($Hex.Substring($i, 2), 16) }
    return , $bytes
}

function ConvertTo-HexString { param([byte[]]$Bytes) if ($Bytes.Length -eq 0) { return '' } return ([BitConverter]::ToString($Bytes).Replace('-', '')) }

function Get-BitFlags {
    param([byte[]]$Value, $Table)
    $out = New-Object System.Collections.ArrayList
    foreach ($row in $Table) {
        $byteNo = $row[0]; $bit = $row[1]
        if ($Value.Length -ge $byteNo -and ($Value[$byteNo - 1] -band (1 -shl ($bit - 1)))) { [void]$out.Add($row[2]) }
    }
    return @($out)
}

function Get-AidInfo {
    param([string]$AidHex)
    $aid = $AidHex.ToUpper()
    $best = ''
    foreach ($prefix in $script:EMV_AIDS.Keys) { if ($aid.StartsWith($prefix) -and $prefix.Length -gt $best.Length) { $best = $prefix } }
    if (-not $best) { return $null }
    $pair = $script:EMV_AIDS[$best]
    return [ordered]@{ aid = $aid; rid = $aid.Substring(0, [Math]::Min(10, $aid.Length)); scheme = $pair[0]; product = $pair[1] }
}

function ConvertFrom-CvmList {
    param([byte[]]$Value)
    if ($Value.Length -lt 8) { return [ordered]@{ error = 'CVM list shorter than 8 bytes' } }
    $rules = New-Object System.Collections.ArrayList
    for ($i = 8; $i -lt $Value.Length - 1; $i += 2) {
        $b1 = $Value[$i]; $b2 = $Value[$i + 1]
        $code = $b1 -band 0x3F
        $cvm = 'RFU / proprietary (0x{0:X2})' -f $code
        if ($script:CVM_CODES.ContainsKey([int]$code)) { $cvm = $script:CVM_CODES[[int]$code] }
        $cond = 'RFU (0x{0:X2})' -f $b2
        if ($script:CVM_CONDITIONS.ContainsKey([int]$b2)) { $cond = $script:CVM_CONDITIONS[[int]$b2] }
        $onFail = 'fail cardholder verification'
        if ($b1 -band 0x40) { $onFail = 'apply next rule' }
        [void]$rules.Add([ordered]@{ cvm = $cvm; condition = $cond; on_failure = $onFail })
    }
    $x = 0; $y = 0
    for ($i = 0; $i -lt 4; $i++) { $x = $x * 256 + $Value[$i]; $y = $y * 256 + $Value[$i + 4] }
    return [ordered]@{ amount_x = $x; amount_y = $y; rules = @($rules) }
}

function ConvertFrom-TagList {
    param([byte[]]$Value)
    $out = New-Object System.Collections.ArrayList
    $i = 0
    while ($i -lt $Value.Length) {
        $start = $i; $first = $Value[$i]; $i++
        if (($first -band 0x1F) -eq 0x1F) { while ($i -lt $Value.Length -and ($Value[$i] -band 0x80)) { $i++ }; $i++ }
        $tag = ConvertTo-HexString (Get-SubBytes $Value $start ($i - $start))
        $len = 0
        if ($i -lt $Value.Length) { $len = $Value[$i] }
        $i++
        $name = '?'
        if ($script:EMV_TAGS.ContainsKey($tag)) { $name = $script:EMV_TAGS[$tag][0] }
        [void]$out.Add("$tag ($name) len $len")
    }
    return @($out)
}

function ConvertFrom-TagValue {
    param([string]$Tag, [byte[]]$Value)
    $fmt = 'b'
    if ($script:EMV_TAGS.ContainsKey($Tag)) { $fmt = $script:EMV_TAGS[$Tag][1] }
    $hex = ConvertTo-HexString $Value
    $d = [ordered]@{ hex = $hex }
    try {
        switch ($fmt) {
            { $_ -eq 'n' -or $_ -eq 'cn' } {
                $digits = $hex
                if ($fmt -eq 'cn') { $digits = $hex.TrimEnd('F') }
                $d['value'] = $digits
                if ($Tag -eq '5A') { $d['pan'] = $digits }
                if ($Tag -eq '5F34' -and $hex) { $d['value'] = [string][int]$hex }
            }
            { $_ -eq 'an' -or $_ -eq 'ans' } { $d['value'] = [Text.Encoding]::GetEncoding(28591).GetString($Value).Trim() }
            'date' {
                if ($hex.Length -eq 6 -and $hex -match '^\d{6}$') {
                    $d['value'] = "20$($hex.Substring(0,2))-$($hex.Substring(2,2))-$($hex.Substring(4,2))"
                    if ($Tag -eq '5F24') { $d['expiry_status'] = Get-ExpiryStatus $hex.Substring(0, 4) }
                } else { $d['value'] = $hex }
            }
            'time' { if ($hex.Length -eq 6) { $d['value'] = "$($hex.Substring(0,2)):$($hex.Substring(2,2)):$($hex.Substring(4,2))" } else { $d['value'] = $hex } }
            'amount' { if ($hex -match '^\d+$') { $v = [long]$hex; $d['value'] = ('{0}.{1:D2}' -f [long][Math]::Floor($v / 100), ($v % 100)) } else { $d['value'] = $hex } }
            'country' { $cc = $hex.Substring([Math]::Max(0, $hex.Length - 3)); if ($script:ISO3166.ContainsKey($cc)) { $d['value'] = $script:ISO3166[$cc] } else { $d['value'] = "ISO 3166-1 numeric $cc" } }
            'service' { $code = $hex.Substring([Math]::Max(0, $hex.Length - 3)); $d['service_code'] = ConvertFrom-ServiceCode $code; $d['value'] = $code }
            'track2' { $t2 = $hex.TrimEnd('F'); $d['value'] = $t2; try { $d['track2'] = ConvertFrom-TrackData $t2 } catch { } }
            'aip' { $d['flags'] = @(Get-BitFlags $Value $script:AIP_BITS) }
            'tvr' { $d['flags'] = @(Get-BitFlags $Value $script:TVR_BITS) }
            'tsi' { $d['flags'] = @(Get-BitFlags $Value $script:TSI_BITS) }
            'auc' { $d['flags'] = @(Get-BitFlags $Value $script:AUC_BITS) }
            'cvm' { $d['cvm_list'] = ConvertFrom-CvmList $Value }
            'afl' {
                $entries = New-Object System.Collections.ArrayList
                for ($i = 0; $i -lt $Value.Length - 3; $i += 4) {
                    [void]$entries.Add(('SFI {0} records {1}-{2} ({3} used for offline auth)' -f ($Value[$i] -shr 3), $Value[$i + 1], $Value[$i + 2], $Value[$i + 3]))
                }
                $d['entries'] = @($entries)
            }
            'tags' { $d['entries'] = @(ConvertFrom-TagList $Value) }
            'cid' {
                $kinds = @('AAC (declined)', 'TC (approved offline)', 'ARQC (go online)', 'RFU')
                $v = $kinds[$Value[0] -shr 6]
                if ($Value[0] -band 0x08) { $v += '; advice required' }
                $d['value'] = $v
            }
            'txtype' { if ($script:TRANSACTION_TYPES.ContainsKey($hex)) { $d['value'] = $script:TRANSACTION_TYPES[$hex] } else { $d['value'] = "type $hex" } }
            'termtype' { if ($script:TERMINAL_TYPES.ContainsKey($hex)) { $d['value'] = $script:TERMINAL_TYPES[$hex] } else { $d['value'] = "type $hex" } }
            'posentry' { if ($script:POS_ENTRY_MODES.ContainsKey($hex)) { $d['value'] = $script:POS_ENTRY_MODES[$hex] } else { $d['value'] = "mode $hex" } }
            'cvmres' {
                if ($Value.Length -ge 3) {
                    $c = $Value[0] -band 0x3F
                    $cvm = ('0x{0:X2}' -f $Value[0]); if ($script:CVM_CODES.ContainsKey([int]$c)) { $cvm = $script:CVM_CODES[[int]$c] }
                    $cond = ('0x{0:X2}' -f $Value[1]); if ($script:CVM_CONDITIONS.ContainsKey([int]$Value[1])) { $cond = $script:CVM_CONDITIONS[[int]$Value[1]] }
                    $res = @{ 0 = 'unknown'; 1 = 'failed'; 2 = 'successful' }
                    $rt = ('0x{0:X2}' -f $Value[2]); if ($res.ContainsKey([int]$Value[2])) { $rt = $res[[int]$Value[2]] }
                    $d['value'] = "$cvm; $cond; result $rt"
                }
            }
            'termcap' {
                if ($Value.Length -ge 3) {
                    $caps = New-Object System.Collections.ArrayList
                    foreach ($f in (Get-BitFlags $Value @(, @(1, 8, 'manual key entry'), @(1, 7, 'magnetic stripe'), @(1, 6, 'IC with contacts')))) { [void]$caps.Add($f) }
                    foreach ($f in (Get-BitFlags $Value @(, @(2, 8, 'plaintext PIN for ICC verification'), @(2, 7, 'enciphered PIN for online verification'), @(2, 6, 'signature'), @(2, 5, 'enciphered PIN for offline verification'), @(2, 4, 'no CVM required')))) { [void]$caps.Add($f) }
                    foreach ($f in (Get-BitFlags $Value @(, @(3, 8, 'SDA'), @(3, 7, 'DDA'), @(3, 6, 'card capture'), @(3, 4, 'CDA')))) { [void]$caps.Add($f) }
                    $d['flags'] = @($caps)
                }
            }
        }
        if ($Tag -eq '4F' -or $Tag -eq '84' -or $Tag -eq '9F06') { $info = Get-AidInfo $hex; if ($info) { $d['aid'] = $info } }
        if ($Tag -eq '5F2A' -or $Tag -eq '9F42') { $d['value'] = $hex.Substring([Math]::Max(0, $hex.Length - 3)) }
    } catch { $d['error'] = "could not decode: $($_.Exception.Message)" }
    return $d
}

function ConvertFrom-Tlv {
    # Parse BER-TLV as used by EMV (multi-byte tags, long-form lengths, nested templates).
    param([byte[]]$Data, [int]$Depth = 0)
    $out = New-Object System.Collections.ArrayList
    $i = 0; $n = $Data.Length
    while ($i -lt $n) {
        if ($Data[$i] -eq 0x00 -or $Data[$i] -eq 0xFF) { $i++; continue }        # padding between objects
        $start = $i; $first = $Data[$i]; $i++
        if (($first -band 0x1F) -eq 0x1F) { while ($i -lt $n -and ($Data[$i] -band 0x80)) { $i++ }; $i++ }
        $tag = ConvertTo-HexString (Get-SubBytes $Data $start ($i - $start))
        if ($i -ge $n) { throw "truncated tag $tag" }
        $length = [int]$Data[$i]; $i++
        if ($length -band 0x80) {
            $count = $length -band 0x7F
            if ($count -eq 0 -or $count -gt 4 -or $i + $count -gt $n) { throw "bad length encoding after tag $tag" }
            $length = 0
            for ($k = 0; $k -lt $count; $k++) { $length = $length * 256 + $Data[$i + $k] }
            $i += $count
        }
        $value = Get-SubBytes $Data $i $length
        $i += $length
        $name = 'Unknown / proprietary tag'
        if ($script:EMV_TAGS.ContainsKey($tag)) { $name = $script:EMV_TAGS[$tag][0] }
        $node = [ordered]@{ tag = $tag; name = $name; length = $length; truncated = ($value.Length -lt $length) }
        if (($first -band 0x20) -and $Depth -lt 8) {
            try { $node['children'] = @(ConvertFrom-Tlv -Data $value -Depth ($Depth + 1)) }
            catch { $node['children'] = @(); $node['decoded'] = [ordered]@{ hex = (ConvertTo-HexString $value); error = 'constructed tag without valid TLV content' } }
        } else { $node['decoded'] = ConvertFrom-TagValue -Tag $tag -Value $value }
        [void]$out.Add($node)
    }
    return @($out)
}

function Get-TlvNodes {
    param($Nodes)
    foreach ($node in $Nodes) {
        Write-Output $node
        if ($node.Contains('children')) { Get-TlvNodes $node['children'] }
    }
}

function ConvertFrom-Emv {
    # Decode a hex TLV dump and summarise what matters for card identification.
    param([string]$Text, [object[]]$Schemes = $script:SCHEMES, $BinDb = $null, [bool]$RequireIin = $false, [bool]$CheckLength = $true, $Lookup = $null)
    $data = ConvertFrom-HexString (ConvertTo-CleanHex $Text)
    $nodes = @(ConvertFrom-Tlv -Data $data)
    $s = [ordered]@{ pan = $null; expiry = $null; expiry_status = $null; psn = $null; cardholder = $null; aid = $null; label = $null
        issuer_country = $null; service_code = $null; track2 = $null; aip = $null; cvm_list = $null; tvr = $null; tsi = $null
        auc = $null; cid = $null; warnings = New-Object System.Collections.ArrayList; validation = $null }
    foreach ($node in @(Get-TlvNodes $nodes)) {
        $tag = $node['tag']
        $dec = $null
        if ($node.Contains('decoded')) { $dec = $node['decoded'] }
        if ($null -eq $dec) { continue }
        switch ($tag) {
            '5A' { if ($dec.Contains('pan') -and $dec['pan']) { $s['pan'] = $dec['pan'] } }
            '5F24' { $s['expiry'] = $dec['value']; if ($dec.Contains('expiry_status')) { $s['expiry_status'] = $dec['expiry_status'] } }
            '5F34' { $s['psn'] = $dec['value'] }
            '5F20' { if ($dec['value']) { $s['cardholder'] = $dec['value'] } }
            { $_ -eq '4F' -or $_ -eq '84' -or $_ -eq '9F06' } { if ($dec.Contains('aid') -and -not $s['aid']) { $s['aid'] = $dec['aid'] } }
            { $_ -eq '50' -or $_ -eq '9F12' } { if ($dec['value'] -and -not $s['label']) { $s['label'] = $dec['value'] } }
            '5F28' { $s['issuer_country'] = $dec['value'] }
            '5F30' { if ($dec.Contains('service_code')) { $s['service_code'] = $dec['service_code'] } }
            { $_ -eq '57' -or $_ -eq '9F6B' } { if ($dec.Contains('track2') -and -not $s['track2']) { $s['track2'] = $dec['track2'] } }
            '82' { $s['aip'] = @($dec['flags']) }
            '8E' { if ($dec.Contains('cvm_list')) { $s['cvm_list'] = $dec['cvm_list'] } }
            '95' { $s['tvr'] = @($dec['flags']) }
            '9B' { $s['tsi'] = @($dec['flags']) }
            '9F07' { $s['auc'] = @($dec['flags']) }
            '9F27' { $s['cid'] = $dec['value'] }
        }
    }
    if (-not $s['pan'] -and $s['track2']) { $s['pan'] = $s['track2']['pan'] }
    if ($s['track2'] -and -not $s['service_code']) { $s['service_code'] = $s['track2']['service_code'] }
    if ($s['pan']) {
        $v = Test-Pan -Pan $s['pan'] -RequireIin $RequireIin -CheckLength $CheckLength -Schemes $Schemes -BinDb $BinDb -Lookup $Lookup
        $s['validation'] = $v
        if ($s['aid'] -and $v['scheme']) {
            $word = ($s['aid']['scheme'] -split ' ')[0].ToLower()
            $hit = $v['scheme'].ToLower().Contains($word)
            foreach ($a in $v['also_matches']) { if ($a['scheme'].ToLower().Contains($word)) { $hit = $true } }
            if (-not $hit) { [void]$s['warnings'].Add("AID says $($s['aid']['scheme']) but the PAN prefix says $($v['scheme'])") }
        }
    }
    if ($s['track2'] -or $s['pan']) {
        [void]$s['warnings'].Add('Chip data with PAN / track 2 equivalent is cardholder data; the cryptograms and PIN related tags are sensitive authentication data.')
    }
    $s['warnings'] = @($s['warnings'])
    return [ordered]@{ tags = $nodes; summary = $s; bytes = $data.Length }
}

# ---------------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------------
function New-OutputOptions { param([bool]$Masked = $false, [string]$MaskStyle = '6-4', [bool]$QuietMode = $false) return @{ Masked = $Masked; MaskStyle = $MaskStyle; Quiet = $QuietMode } }

function Format-PanForOutput { param([string]$Pan, $Opts) if ($Opts['Masked']) { return (Get-MaskedPan -Pan $Pan -Style $Opts['MaskStyle']) } return $Pan }

function Write-Validation {
    param($R, $Opts)
    $pan = $R['pan']
    $shown = Format-PanForOutput -Pan $pan -Opts $Opts
    if ($Opts['Quiet']) {
        $extra = ''
        if ($R['test_card']) { $extra = "  (test number: $($R['test_card']))" }
        if ($R['valid']) { Write-Output "[+] Valid PAN   $shown$extra" } else { Write-Output "[-] Invalid PAN $shown$extra" }
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
    $lk = $R['lookup']
    if ($lk) {
        if ($lk.Contains('error')) {
            $src = 'online'
            if ($lk.Contains('source') -and $lk['source']) { $src = $lk['source'] }
            Write-Output "Lookup:       $src (IIN $($lk['iin'])): $($lk['error'])"
        }
        else {
            $bits = New-Object System.Collections.ArrayList
            foreach ($k in @('bank_name', 'scheme', 'brand', 'type', 'country')) { if ($lk.Contains($k) -and $lk[$k]) { [void]$bits.Add([string]$lk[$k]) } }
            if ($lk.Contains('prepaid') -and $lk['prepaid'] -eq $true) { [void]$bits.Add('prepaid') }
            $txt = $bits -join ' | '
            if (-not $txt) { $txt = 'no details' }
            Write-Output "Lookup:       $txt  [$($lk['source']), IIN $($lk['iin'])]"
            $more = foreach ($k in @('bank_url', 'bank_phone')) { if ($lk.Contains($k) -and $lk[$k]) { $lk[$k] } }
            if ($more) { Write-Output "              $($more -join ' ')" }
        }
    }
    if ($R['test_card']) { Write-Output "Test number:  published test / sandbox card number ($($R['test_card'])), not a real account" }
    if ($R['lookalike']) { Write-Output "Look-alike:   $($R['lookalike']['text']) ($($R['lookalike']['detail']))" }
    if ($R['valid']) { Write-Output 'Result:       [+] Valid PAN' }
    else { Write-Output ("Result:       [-] Invalid PAN  ({0})" -f ($R['reasons'] -join '; ')) }
}

function Write-Track {
    param($T, $V, $Opts)
    Write-Output "Track data:   $($T['track'])"
    if ($T['name']) { Write-Output "Cardholder:   $($T['name'])" }
    if ($T['expiry']) {
        $st = $T['expiry_status']
        $suffix = ''
        if ($null -ne $st -and $st['status'] -ne 'valid') { $suffix = "  [$($st['text'])]" }
        Write-Output "Expiry:       $($T['expiry_text'])$suffix"
    }
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
        if ($Opts['Masked']) { $disc = '*' * $disc.Length }
        Write-Output "Discretionary: $disc"
        $h = $T['discretionary_hints']
        if ($null -ne $h -and -not $Opts['Masked']) { Write-Output "              typical layout: PVKI $($h['pvki']), PVV $($h['pvv']), CVV1/CVC1 $($h['cvv1']) ($($h['note']))" }
    }
    if ($T['sad_warning']) { Write-Output "Attention:    $($T['sad_warning'])" }
    Write-Validation -R $V -Opts $Opts
}

function Write-TlvNodes {
    param($Nodes, [int]$Indent, $Opts)
    foreach ($node in $Nodes) {
        $pad = '  ' * $Indent
        $name = $node['name']
        if ($name.Length -gt 44) { $name = $name.Substring(0, 44) }
        $head = '{0}{1,-8} {2,-44} len {3,3}' -f $pad, $node['tag'], $name, $node['length']
        if ($node.Contains('children')) { Write-Output $head; Write-TlvNodes -Nodes $node['children'] -Indent ($Indent + 1) -Opts $Opts; continue }
        $dec = $node['decoded']
        $val = $null
        if ($dec.Contains('value')) { $val = $dec['value'] }
        if ($node['tag'] -eq '5A' -and $val) { $val = Format-PanForOutput -Pan $val -Opts $Opts }
        if (($node['tag'] -eq '57' -or $node['tag'] -eq '9F6B') -and $val -and $Opts['Masked']) { $val = '<masked track 2>' }
        if ($null -eq $val) {
            $val = $dec['hex']
            if ($Opts['Masked'] -and ($node['tag'] -eq '9F20' -or $node['tag'] -eq '9F1F' -or $node['tag'] -eq '56')) { $val = '<masked>' }
            if ($val.Length -gt 48) { $val = $val.Substring(0, 48) + '...' }
        }
        Write-Output "$head  $val"
        foreach ($key in @('flags', 'entries')) { if ($dec.Contains($key)) { foreach ($item in $dec[$key]) { Write-Output "$pad           - $item" } } }
        if ($dec.Contains('aid')) { Write-Output "$pad           - $($dec['aid']['scheme']): $($dec['aid']['product'])" }
        if ($dec.Contains('service_code') -and $dec['service_code']['valid']) { $scd = $dec['service_code']; Write-Output "$pad           - $($scd['interchange']) / $($scd['authorisation']) / $($scd['services'])" }
        if ($dec.Contains('expiry_status') -and $null -ne $dec['expiry_status'] -and $dec['expiry_status']['status'] -ne 'valid') { Write-Output "$pad           - $($dec['expiry_status']['text'])" }
        if ($dec.Contains('cvm_list') -and $dec['cvm_list'].Contains('rules')) { foreach ($rule in $dec['cvm_list']['rules']) { Write-Output "$pad           - $($rule['cvm']) | $($rule['condition']) | else $($rule['on_failure'])" } }
        if ($dec.Contains('error')) { Write-Output "$pad           ! $($dec['error'])" }
    }
}

function Write-Emv {
    param($E, $Opts)
    Write-Output ("EMV TLV:      {0} bytes, {1} top-level objects" -f $E['bytes'], $E['tags'].Count)
    Write-TlvNodes -Nodes $E['tags'] -Indent 0 -Opts $Opts
    $s = $E['summary']
    Write-Output ''
    if ($s['aid']) { Write-Output "Application:  $($s['aid']['scheme']) - $($s['aid']['product'])  (AID $($s['aid']['aid']))" }
    if ($s['label']) { Write-Output "Label:        $($s['label'])" }
    if ($s['cardholder']) { Write-Output "Cardholder:   $($s['cardholder'])" }
    if ($s['expiry']) {
        $suffix = ''
        if ($null -ne $s['expiry_status'] -and $s['expiry_status']['status'] -ne 'valid') { $suffix = "  [$($s['expiry_status']['text'])]" }
        Write-Output "Expiry:       $($s['expiry'])$suffix"
    }
    if ($s['psn']) { Write-Output "PAN seq. no:  $($s['psn'])" }
    if ($s['issuer_country']) { Write-Output "Issuer ctry:  $($s['issuer_country'])" }
    foreach ($w in $s['warnings']) { Write-Output "Attention:    $w" }
    if ($s['validation']) { Write-Validation -R $s['validation'] -Opts $Opts }
    elseif (-not $s['pan']) { Write-Output 'Result:       no PAN (tag 5A / 57 / 9F6B) in this data' }
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

$script:SCAN_CSV_FIELDS = @('source', 'line', 'column', 'pan', 'scheme', 'iin_range', 'confidence', 'score', 'signals', 'test_card', 'lookalike', 'issuer', 'duplicate', 'sha256')

function Get-ScanRow {
    param($R, $Opts)
    $iss = $R['issuer']
    $issTxt = ''
    if ($iss) { $issTxt = (@(foreach ($k in @('issuer', 'country')) { if ($iss.ContainsKey($k) -and $iss[$k]) { $iss[$k] } }) -join ' | ') }
    $look = ''
    if ($R['lookalike']) { $look = $R['lookalike']['kind'] }
    $sha = ''
    if ($R.Contains('sha256') -and $R['sha256']) { $sha = $R['sha256'] }
    return [ordered]@{
        source = $R['source']; line = $R['line']; column = $R['column']; pan = (Format-PanForOutput -Pan $R['pan'] -Opts $Opts)
        scheme = [string]$R['scheme']; iin_range = [string]$R['iin_range']; confidence = $R['confidence']; score = $R['score']
        signals = ($R['signals'] -join '; '); test_card = [string]$R['test_card']; lookalike = $look; issuer = $issTxt
        duplicate = $R['duplicate']; sha256 = $sha
    }
}

function ConvertTo-CsvLine {
    # Minimal quoting (like Python's csv module): quote only fields containing , " CR or LF.
    param($Values)
    $cells = foreach ($v in $Values) {
        $t = [string]$v
        if ($t -match '[,"\r\n]') { '"' + $t.Replace('"', '""') + '"' } else { $t }
    }
    return ($cells -join ',')
}

function Hide-EmvPan {
    # Mask PAN bearing values in a decoded EMV structure before JSON output.
    param($E, $Opts)
    foreach ($node in @(Get-TlvNodes $E['tags'])) {
        if (-not $node.Contains('decoded')) { continue }
        $dec = $node['decoded']
        if ($node['tag'] -eq '5A') { $m = Format-PanForOutput -Pan ([string]$dec['pan']) -Opts $Opts; $dec['pan'] = $m; $dec['value'] = $m }
        if (@('57', '9F6B', '56', '9F20', '9F1F') -contains $node['tag']) { $dec['hex'] = '<masked>'; $dec['value'] = '<masked>'; if ($dec.Contains('track2')) { $dec.Remove('track2') } }
    }
    $s = $E['summary']
    if ($s['pan']) { $s['pan'] = Format-PanForOutput -Pan $s['pan'] -Opts $Opts }
    if ($s['track2']) { $s['track2'] = [ordered]@{ pan = $s['pan']; masked = $true } }
    if ($s['validation']) { $s['validation']['pan'] = $s['pan'] }
}

# ---------------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------------
function Read-InputLines {
    param([string]$Path)
    if ($Path -eq '-') {
        $piped = @(foreach ($x in $script:PipelineInput) { [string]$x })
        if ($piped.Count -gt 0) { return $piped }
        $data = [Console]::In.ReadToEnd()
        return @($data -split "`r?`n")
    }
    return @(Get-Content -LiteralPath $Path -Encoding UTF8)
}

function ConvertTo-GLuhnJson {
    # Identical JSON on both engines.  Windows PowerShell 5.1 escapes & < > ' as \uXXXX and
    # pads with double spaces after the colon; PowerShell 7 does neither.
    param($InputObject, [switch]$Compress)
    if ($script:IsCoreEngine) {
        return (ConvertTo-Json -InputObject $InputObject -Depth 12 -EscapeHandling Default -Compress:$Compress)
    }
    $json = ConvertTo-Json -InputObject $InputObject -Depth 12 -Compress:$Compress
    $json = $json -replace '\\u0026', '&' -replace '\\u003c', '<' -replace '\\u003e', '>' -replace "\\u0027", "'"
    return ($json -replace '":  ', '": ')
}

function Write-Usage {
    Write-Output $script:BANNER
    Write-Output ''
    Write-Output 'usage: gLuhn.ps1 [-i] [-NoIin] [-IgnoreLength] [-b BRANDS] [-ActiveOnly] [-NoCatchAll] [-IinTable JSON] [-Max N]'
    Write-Output '                 [-f FILE] [-Scan PATH] [-Emv HEX] [-Include GLOB] [-Exclude GLOB] [-NoRecursive] [-NoArchives]'
    Write-Output '                 [-MaxFileSize MB] [-MinScore N] [-BinDb CSV|auto] [-UpdateBinDb] [-Lookup] [-LookupUrl URL]'
    Write-Output '                 [-m] [-MaskStyle 6-4|8-4|last4|full] [-Format text|json|jsonl|csv] [-j] [-q] [-ListSchemes] [-Version] [PAN ...]'
    Write-Output ''
    Write-Output '  PAN           Luhn check + scheme identification (add -i to also require a known IIN)'
    Write-Output '  PAN with ?    generate every valid combination, e.g. 4542109540?18054'
    Write-Output "  track data    e.g. ';4542109540018054=25121011234567890?' or EMV tag 57 with 'D'"
    Write-Output '  -Scan PATH    find PANs in a file, a folder (recursive), ZIP/Office archives, PDFs'
    Write-Output '  -Emv HEX      decode EMV TLV data (hex string or @file)'
    Write-Output ''
    Write-Output 'Run "Get-Help .\gLuhn.ps1 -Detailed" for every option and more examples.'
}

function Invoke-Main {
    Write-Verbose "gLuhn.ps1 $($script:GLUHN_VERSION) on $($script:EngineText)"
    if ($Version) { Write-Output $script:BANNER; Write-Output "running on $($script:EngineText)"; $script:ExitCode = 0; return }

    $fmt = 'text'
    if ($Json) { $fmt = 'json' }
    if ($Format) { $fmt = $Format }
    $asJson = ($fmt -eq 'json' -or $fmt -eq 'jsonl')
    $maskStyleValue = '6-4'
    if ($MaskStyle) { $maskStyleValue = $MaskStyle }
    $opts = New-OutputOptions -Masked ([bool]$Mask -or [bool]$MaskStyle) -MaskStyle $maskStyleValue -QuietMode ([bool]$Quiet)

    if ($IinTable) {
        try { Set-SchemeTable (Import-IinTable -Path $IinTable) }
        catch { Write-Output "[-] cannot load -IinTable: $($_.Exception.Message)"; $script:ExitCode = 2; return }
    }
    if ($ListSchemes) { Write-SchemeTable; $script:ExitCode = 0; return }

    try {
        $schemes = Select-Scheme -Brands $Brand -IncludeInactive (-not $ActiveOnly) -IncludeCatchAll (-not $NoCatchAll)
    } catch { Write-Output "[-] $($_.Exception.Message)"; $script:ExitCode = 2; return }

    $binDatabase = $null
    $binPath = $BinDb
    if ($binPath -eq 'auto' -or ($UpdateBinDb -and -not $binPath)) { $binPath = $script:DEFAULT_BIN_DB_PATH }
    if ($UpdateBinDb) {
        try {
            $size = Save-BinDatabase -Path $binPath
            if ($fmt -eq 'text') { Write-Output ('[i] downloaded {0:N1} MB to {1}' -f ($size / 1MB), $binPath) }
        } catch { Write-Output "[-] cannot download BIN database: $($_.Exception.Message)"; $script:ExitCode = 2; return }
    }
    if ($binPath) {
        try { $binDatabase = Import-BinDatabase -Path $binPath }
        catch {
            $hint = ''
            if ($binPath -eq $script:DEFAULT_BIN_DB_PATH) { $hint = '  (run with -UpdateBinDb to download it)' }
            Write-Output "[-] cannot load BIN database ${binPath}: $($_.Exception.Message)$hint"; $script:ExitCode = 2; return
        }
        if ($fmt -eq 'text' -and -not $Quiet) { Write-Output "[i] BIN database loaded: $($binDatabase['Rows']) rows from $(Split-Path -Leaf $binPath)" }
    }
    $lookupObj = $null
    if ($Lookup) {
        try { $lookupObj = New-OnlineLookup -UrlTemplate $LookupUrl -Timeout $LookupTimeout }
        catch { Write-Output "[-] $($_.Exception.Message)"; $script:ExitCode = 2; return }
        if ($fmt -eq 'text' -and -not $Quiet) { Write-Output "[i] online lookup enabled: only the IIN is sent to $($lookupObj['Source'])" }
    }
    $checkLength = -not $IgnoreLength
    $requireIin = [bool]$Iin
    $iinFilter = -not $NoIin
    # -Include / -Exclude accept PowerShell arrays (-Exclude *.bak,sub) and comma separated strings.
    $includeGlobs = @(foreach ($g in $Include) { foreach ($part in ([string]$g).Split(',')) { if ($part.Trim()) { $part.Trim() } } })
    $excludeGlobs = @(foreach ($g in $Exclude) { foreach ($part in ([string]$g).Split(',')) { if ($part.Trim()) { $part.Trim() } } })

    $inputs = New-Object System.Collections.ArrayList
    if ($PAN) { foreach ($p in $PAN) { [void]$inputs.Add($p) } }
    if ($File) {
        foreach ($ln in (Read-InputLines $File)) { if ($ln -and $ln.Trim() -and -not $ln.TrimStart().StartsWith('#')) { [void]$inputs.Add($ln) } }
    }

    $jsonOut = New-Object System.Collections.ArrayList
    $anyValid = $false
    $anyInput = $false
    $emit = {
        param($obj)
        if ($fmt -eq 'jsonl') { Write-Output (ConvertTo-GLuhnJson -InputObject $obj -Compress) } else { [void]$jsonOut.Add($obj) }
    }

    # ---- EMV ------------------------------------------------------------------------
    if ($Emv) {
        $anyInput = $true
        try { $e = ConvertFrom-Emv -Text $Emv -Schemes $schemes -BinDb $binDatabase -RequireIin $requireIin -CheckLength $checkLength -Lookup $lookupObj }
        catch { Write-Output "[-] cannot decode EMV data: $($_.Exception.Message)"; $script:ExitCode = 1; return }
        $v = $e['summary']['validation']
        if ($v -and $v['valid']) { $anyValid = $true }
        if ($asJson) { if ($opts['Masked']) { Hide-EmvPan -E $e -Opts $opts }; & $emit $e }
        else { Write-Emv -E $e -Opts $opts; Write-Output '' }
    }

    # ---- scan mode --------------------------------------------------------------------
    if ($Scan) {
        $anyInput = $true
        $hits = 0
        $sources = 0
        $skipped = New-Object System.Collections.ArrayList
        if ($fmt -eq 'csv') { Write-Output ($script:SCAN_CSV_FIELDS -join ',') }
        $maxBytes = [long]($MaxFileSize * 1MB)
        Get-ScanSource -Path $Scan -Recursive (-not $NoRecursive) -Include $includeGlobs -Exclude $excludeGlobs -MaxBytes $maxBytes -Archives (-not $NoArchives) -Skipped $skipped | ForEach-Object {
            $src = $_
            $sources++
            Search-PanInText -Lines $src['Lines'] -RequireIin $iinFilter -CheckLength $checkLength -Schemes $schemes -BinDb $binDatabase -MinScore $MinScore -Source $src['Name'] | ForEach-Object {
                $r = $_
                $hits++
                $anyValid = $true
                $r['sha256'] = $src['Sha256']
                if ($null -ne $lookupObj) { $r['lookup'] = Invoke-IinLookup -Lookup $lookupObj -Pan $r['pan'] }
                if ($fmt -eq 'csv') {
                    $row = Get-ScanRow -R $r -Opts $opts
                    Write-Output (ConvertTo-CsvLine @(foreach ($k in $script:SCAN_CSV_FIELDS) { $row[$k] }))
                } elseif ($asJson) { $r['pan'] = Format-PanForOutput -Pan $r['pan'] -Opts $opts; & $emit $r }
                else {
                    $dup = ''
                    if ($r['duplicate']) { $dup = '  (duplicate)' }
                    $sch = $r['scheme']
                    if (-not $sch) { $sch = 'unknown scheme' }
                    $where = "$($src['Name']):$($r['line']):$($r['column'])"
                    if ($src['Name'] -eq '<stdin>') { $where = "line $($r['line'])" }
                    Write-Output ('[+] {0,-6} {1,3}  {2,-24} {3,-28} {4}{5}' -f $r['confidence'], $r['score'], (Format-PanForOutput -Pan $r['pan'] -Opts $opts), $sch, $where, $dup)
                    if ($r['signals'].Count -gt 0) { Write-Output "    $($r['signals'] -join ', ')" }
                }
            }
        }
        if ($fmt -eq 'text') {
            Write-Output ''
            Write-Output "Scanned $sources source(s); candidate PANs found: $hits"
            $shown = 0
            foreach ($s_ in $skipped) { if ($shown -lt 20) { Write-Output "[i] skipped $s_" }; $shown++ }
            if ($skipped.Count -gt 20) { Write-Output "[i] ... and $($skipped.Count - 20) more skipped" }
        }
    }

    if ($inputs.Count -eq 0 -and -not $Scan -and -not $Emv) { Write-Usage; $script:ExitCode = 2; return }

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
                if ($opts['Masked']) { $shownIn = '<track data>' }
                Write-Output "[-] $($_.Exception.Message): $shownIn"; continue
            }
            $v = Test-Pan -Pan $t['pan'] -RequireIin $requireIin -CheckLength $checkLength -Schemes $schemes -BinDb $binDatabase -Lookup $lookupObj
            if ($v['valid']) { $anyValid = $true }
            if ($asJson) {
                if ($opts['Masked']) { $t['pan'] = Format-PanForOutput -Pan $v['pan'] -Opts $opts; $v['pan'] = $t['pan']; $t['discretionary'] = $null; $t['discretionary_hints'] = $null; $t['input'] = '<masked>' }
                & $emit ([ordered]@{ track = $t; validation = $v })
            } else { Write-Track -T $t -V $v -Opts $opts; Write-Output '' }
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
            if ($fmt -eq 'text') {
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
                    if ($asJson) {
                        $r = Test-Pan -Pan $p -RequireIin $iinFilter -CheckLength $checkLength -Schemes $schemes -BinDb $binDatabase
                        $r['pan'] = Format-PanForOutput -Pan $p -Opts $opts
                        $r['pattern'] = $clean
                        & $emit $r
                    } else {
                        $m = @(Find-Scheme -Pan $p -Schemes $schemes)
                        $label = 'unknown scheme'
                        if ($m.Count -gt 0) { $label = $m[0]['Scheme']['Name'] }
                        $extra = ''
                        if ($null -ne $binDatabase) {
                            $iss = Find-BinIssuer -Db $binDatabase -Pan $p
                            if ($iss) { $bits = foreach ($k in @('issuer', 'country')) { if ($iss[$k]) { $iss[$k] } }; $extra = "  [$($bits -join ' | ')]" }
                        }
                        if (Test-TestCard $p) { $extra += '  (test number)' }
                        Write-Output ('[+] Valid PAN  {0,-20} {1}{2}' -f (Format-PanForOutput -Pan $p -Opts $opts), $label, $extra)
                    }
                }
            } catch { Write-Output "[-] $($_.Exception.Message)"; continue }
            if ($fmt -eq 'text') { Write-Output ''; Write-Output "Total valid PAN generated: $total"; Write-Output '' }
            continue
        }

        # Plain validation
        $r = Test-Pan -Pan $clean -RequireIin $requireIin -CheckLength $checkLength -Schemes $schemes -BinDb $binDatabase -Lookup $lookupObj
        if ($r['valid']) { $anyValid = $true }
        if ($asJson) { $r['pan'] = Format-PanForOutput -Pan $r['pan'] -Opts $opts; & $emit $r }
        elseif ($fmt -eq 'csv') { Write-Output ('{0},{1},{2},{3}' -f (Format-PanForOutput -Pan $r['pan'] -Opts $opts), $r['valid'], [string]$r['scheme'], [string]$r['iin_range']) }
        else {
            Write-Validation -R $r -Opts $opts
            if (-not $Quiet) { Write-Output '' }
        }
    }

    if ($fmt -eq 'json') {
        if ($jsonOut.Count -eq 1) { Write-Output (ConvertTo-GLuhnJson -InputObject $jsonOut[0]) }
        else { Write-Output (ConvertTo-GLuhnJson -InputObject $jsonOut.ToArray()) }
    }
    if (-not $anyInput) { $script:ExitCode = 2; return }
    if ($anyValid) { $script:ExitCode = 0; return }
    $script:ExitCode = 1
}

$script:ExitCode = 0
Invoke-Main
exit $script:ExitCode
