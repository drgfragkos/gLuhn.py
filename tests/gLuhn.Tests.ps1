<#
    End-to-end tests for gLuhn.ps1 (no Pester needed; Windows PowerShell 5.1 or PowerShell 7).
    Run:  powershell -ExecutionPolicy Bypass -File tests\gLuhn.Tests.ps1
#>
[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:Script = Join-Path (Split-Path -Parent $PSScriptRoot) 'gLuhn.ps1'
$script:Pass = 0
$script:Fail = 0

function Invoke-GLuhn {
    # Returns @{ Out = <string>; Lines = <string[]>; Code = <int> }
    param([string[]]$Arguments, [string]$StdIn = '')
    $global:LASTEXITCODE = 0
    # Build a real command line: switches stay bare, values are single-quoted.
    $parts = foreach ($a in $Arguments) {
        if ($a -match '^-[A-Za-z]') { $a } else { "'" + $a.Replace("'", "''") + "'" }
    }
    $cmd = "& '$($script:Script)' $($parts -join ' ') 2>&1"
    if ($StdIn -ne '') {
        $pipeIn = $StdIn -split "`n"
        $lines = @(Invoke-Expression ('$pipeIn | ' + $cmd))
    } else {
        $lines = @(Invoke-Expression $cmd)
    }
    $code = $LASTEXITCODE
    $text = ($lines | ForEach-Object { [string]$_ }) -join "`n"
    return @{ Out = $text; Lines = @($lines | ForEach-Object { [string]$_ }); Code = $code }
}

function Assert-True { param([bool]$Condition, [string]$Message)
    if ($Condition) { $script:Pass++ } else { $script:Fail++; Write-Output "  FAIL: $Message" }
}
function Assert-Equal { param($Expected, $Actual, [string]$Message)
    Assert-True ("$Expected" -eq "$Actual") "$Message (expected '$Expected', got '$Actual')"
}
function Assert-Contains { param([string]$Haystack, [string]$Needle, [string]$Message)
    Assert-True ($Haystack.Contains($Needle)) "$Message (missing '$Needle')"
}
function Assert-NotContains { param([string]$Haystack, [string]$Needle, [string]$Message)
    Assert-True (-not $Haystack.Contains($Needle)) "$Message (unexpected '$Needle')"
}

# Publicly documented test numbers (all Luhn-valid) and the scheme each must resolve to.
$TestCards = [ordered]@{
    '4111111111111111' = 'Visa'
    '4222222222222'    = 'Visa'
    '4571000000000001' = 'Dankort'
    '5555555555554444' = 'Mastercard'
    '2223003122003222' = 'Mastercard'
    '378282246310005'  = 'American Express'
    '6011111111111117' = 'Discover'
    '6221260000000000' = 'Discover (UnionPay co-processed)'
    '6230001111111115' = 'China UnionPay'
    '3530111333300000' = 'JCB'
    '30569309025904'   = 'Diners Club International'
    '6759649826438453' = 'Maestro UK (formerly Switch)'
    '6304000000000000' = 'Maestro'
    '2200000000000004' = 'Mir'
    '9792000000000003' = 'Troy'
    '6062825624254001' = 'Hipercard'
    '5060990000000008' = 'Verve'
    '100000000000009'  = 'UATP (Universal Air Travel Plan)'
}

$edition = 'Desktop'
if ($PSVersionTable.ContainsKey('PSEdition') -and $PSVersionTable.PSEdition) { $edition = $PSVersionTable.PSEdition }
Write-Output "gLuhn.ps1 tests on PowerShell $($PSVersionTable.PSVersion) ($edition)"

Write-Output '- validation of known test numbers'
foreach ($pan in $TestCards.Keys) {
    $r = Invoke-GLuhn @('-j', $pan)
    Assert-Equal 0 $r.Code "exit code for $pan"
    $j = $r.Out | ConvertFrom-Json
    Assert-True $j.luhn "Luhn for $pan"
    Assert-True $j.valid "valid for $pan"
    Assert-Equal $TestCards[$pan] $j.scheme "scheme for $pan"
    Assert-True $j.length_ok "length for $pan"
}

Write-Output '- invalid numbers and exit codes'
$r = Invoke-GLuhn @('4111111111111112')
Assert-Equal 1 $r.Code 'Luhn failure exits 1'
Assert-Contains $r.Out '[-] Invalid PAN' 'Luhn failure message'
$r = Invoke-GLuhn @('1111222233334444')
Assert-Equal 0 $r.Code 'Luhn-only validation (v0.8 behaviour)'
$r = Invoke-GLuhn @('-i', '1111222233334444')
Assert-Equal 1 $r.Code '-i rejects unknown IIN'
$r = Invoke-GLuhn @('-i', '-q', '3742109545565554')
Assert-Equal 1 $r.Code '-i rejects 16-digit Amex'
$r = Invoke-GLuhn @('-i', '-IgnoreLength', '-q', '3742109545565554')
Assert-Equal 0 $r.Code '-IgnoreLength accepts 16-digit Amex'
$r = Invoke-GLuhn @('12ab')
Assert-Equal 1 $r.Code 'non-digit input'
$r = Invoke-GLuhn @()
Assert-Equal 2 $r.Code 'no arguments shows usage'
Assert-Contains $r.Out 'usage:' 'usage text'

Write-Output '- precedence rules'
$j = (Invoke-GLuhn @('-j', '4571000000000000009')).Out | ConvertFrom-Json
Assert-Equal 'Visa' $j.scheme '19-digit 4571 is a Visa (Dankort is 16 digits only)'
Assert-Equal 'Dankort' $j.also_matches[0].scheme 'Dankort still listed'
$j = (Invoke-GLuhn @('-j', '6304000000000000')).Out | ConvertFrom-Json
Assert-Equal 'Maestro' $j.scheme 'active Maestro beats defunct Laser'
Assert-Equal 'Laser' $j.also_matches[0].scheme 'Laser listed as alternative'
$j = (Invoke-GLuhn @('-j', '6500000000000002')).Out | ConvertFrom-Json
Assert-Equal 'Discover' $j.scheme 'Discover 65 beats Maestro catch-all'
$j = (Invoke-GLuhn @('-j', '-NoCatchAll', '5622109545565554')).Out | ConvertFrom-Json
Assert-True ($null -eq $j.scheme) '-NoCatchAll drops Maestro 56-69'
$j = (Invoke-GLuhn @('-j', '201400000000001')).Out | ConvertFrom-Json
Assert-Equal 'Diners Club enRoute' $j.scheme 'enRoute identified'
Assert-True (-not $j.luhn_expected) 'enRoute has no Luhn'
Assert-True $j.valid 'enRoute valid without Luhn'
$j = (Invoke-GLuhn @('-j', '9792000000000003')).Out | ConvertFrom-Json
Assert-Equal 'Turkey' $j.mii.country 'MII 9 country decoding'

Write-Output '- generation'
$r = Invoke-GLuhn @('4542109540?18054')
Assert-Equal 0 $r.Code 'single unknown exit code'
Assert-Contains $r.Out '[+] Valid PAN  4542109540018054' 'single unknown result'
Assert-Contains $r.Out 'Total valid PAN generated: 1' 'single unknown total'
$r = Invoke-GLuhn @('???2109545565554')
$pans = @($r.Lines | Where-Object { $_ -like '`[+`] Valid PAN*' } | ForEach-Object { ($_ -split '\s+')[3] })
Assert-Equal 41 $pans.Count 'README example count'
Assert-True ($pans -contains '4542109545565554') 'README example contains Visa'
Assert-True (-not ($pans -contains '3742109545565554')) '16-digit Amex excluded'
$r = Invoke-GLuhn @('-NoIin', '???2109545565554')
Assert-Contains $r.Out 'Total valid PAN generated: 100' 'Luhn-only generation count'
$r = Invoke-GLuhn @('-b', 'visa,mastercard', '??42109545565554')
$pans = @($r.Lines | Where-Object { $_ -like '`[+`] Valid PAN*' } | ForEach-Object { ($_ -split '\s+')[3] })
Assert-True ($pans.Count -gt 0) 'brand filter produces output'
Assert-True (@($pans | Where-Object { $_ -notmatch '^(4|5[1-5]|2[2-7])' }).Count -eq 0) 'brand filter respected'
$r = Invoke-GLuhn @('37828224631000??')
Assert-Contains $r.Out 'Total valid PAN generated: 0' '16-digit Amex pattern yields nothing'
$r = Invoke-GLuhn @('-Max', '10', '????109540018054')
Assert-Equal 1 $r.Code 'max guard exit code'
Assert-Contains $r.Out 'raise -Max' 'max guard message'
$r = Invoke-GLuhn @('4111111111111111?x')
Assert-Contains $r.Out 'Not a PAN pattern' 'bad pattern message'

Write-Output '- track data'
$r = Invoke-GLuhn @(';4542109540018054=2512201123456789?')
Assert-Equal 0 $r.Code 'track 2 exit code'
Assert-Contains $r.Out 'Track data:   track2' 'track 2 detected'
Assert-Contains $r.Out 'Expiry:       2025-12' 'expiry'
Assert-Contains $r.Out 'Service code: 201' 'service code'
Assert-Contains $r.Out 'use IC (chip) where feasible' 'service code decoding'
Assert-Contains $r.Out 'Discretionary: 123456789' 'discretionary data'
$r = Invoke-GLuhn @('4542109540018054D25121011234567890F')
Assert-Contains $r.Out 'track2/EMV-57' 'EMV tag 57 detected'
$r = Invoke-GLuhn @('%B4542109540018054^DOE/JOHN^25121011234567890?')
Assert-Contains $r.Out 'track1 (format B)' 'track 1 detected'
Assert-Contains $r.Out 'Cardholder:   JOHN DOE' 'cardholder name'
$j = (Invoke-GLuhn @('-j', '4542109540018054==101123')).Out | ConvertFrom-Json
Assert-True ($null -eq $j.track.expiry) 'track without expiry'
Assert-Equal '101' $j.track.service_code.code 'service code after empty expiry'

Write-Output '- masking, files, stdin, JSON'
$r = Invoke-GLuhn @('-m', '-q', '4542109540018054')
Assert-Contains $r.Out '454210******8054' 'masked output'
Assert-NotContains $r.Out '4542109540018054' 'no clear PAN when masked'
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("gluhn_" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    $listFile = Join-Path $tmp 'pans.txt'
    Set-Content -Path $listFile -Value @('4542109540018054', '# comment', '', '4111111111111112')
    $r = Invoke-GLuhn @('-f', $listFile, '-q')
    Assert-Equal 0 $r.Code 'file input exit code'
    Assert-Contains $r.Out '[+] Valid PAN   4542109540018054' 'file input valid line'
    Assert-Contains $r.Out '[-] Invalid PAN 4111111111111112' 'file input invalid line'

    $r = Invoke-GLuhn @('-f', '-', '-q') -StdIn "4542109540018054`n"
    Assert-Contains $r.Out '[+] Valid PAN   4542109540018054' 'stdin input'

    $scanFile = Join-Path $tmp 'dump.txt'
    Set-Content -Path $scanFile -Value @(
        'order 1: 4111 1111 1111 1111 ok',
        'fake: 1234567890123456',
        'amex 3782-822463-10005 and visa 4111111111111111 again',
        'zeros 0000000000000000',
        'phone +44 1234 567890')
    $r = Invoke-GLuhn @('-Scan', $scanFile)
    Assert-Contains $r.Out 'candidate PANs found: 3' 'scan count'
    Assert-Contains $r.Out '378282246310005          American Express' 'scan amex'
    Assert-Contains $r.Out "$($scanFile):3:" 'scan location'
    Assert-Contains $r.Out '(duplicate)' 'scan duplicate flag'
    Assert-Contains $r.Out 'known test number' 'scan signals'
    $r = Invoke-GLuhn @('-Scan', $scanFile, '-Mask')
    Assert-NotContains $r.Out '4111111111111111' 'scan masked'

    $binFile = Join-Path $tmp 'bins.csv'
    Set-Content -Path $binFile -Value @(
        'bin,brand,type,category,issuer,alpha_2,alpha_3,country',
        '454210,VISA,DEBIT,CLASSIC,SOME BANK,GB,GBR,United Kingdom',
        '45421095,VISA,DEBIT,GOLD,SOME BANK GOLD,GB,GBR,United Kingdom')
    $r = Invoke-GLuhn @('-BinDb', $binFile, '4542109540018054')
    Assert-Contains $r.Out 'BIN database loaded: 2 rows' 'bin db loaded'
    Assert-Contains $r.Out 'Issuer (DB):  SOME BANK GOLD | VISA | DEBIT | GOLD | United Kingdom  [45421095]' 'longest prefix issuer'
    $r = Invoke-GLuhn @('-BinDb', $binFile, '4542101111111111')
    Assert-Contains $r.Out 'Issuer (DB):  SOME BANK | VISA' 'shorter prefix issuer'

    $rangeFile = Join-Path $tmp 'ranges.csv'
    Set-Content -Path $rangeFile -Value @('iin_start;iin_end;scheme;bank;country', '222100;272099;MASTERCARD;ACME;US')
    $j = (Invoke-GLuhn @('-BinDb', $rangeFile, '-j', '2223003122003222')).Out | ConvertFrom-Json
    Assert-Equal 'ACME' $j.issuer.issuer 'range csv issuer'
} finally {
    Remove-Item -Recurse -Force $tmp
}

$j = (Invoke-GLuhn @('-j', '4542109540018054', '5555555555554444')).Out | ConvertFrom-Json
Assert-Equal 2 @($j).Count 'JSON array for several PANs'
Assert-Equal 'Mastercard' $j[1].scheme 'JSON second entry'

$j = (Invoke-GLuhn @('-j', '4542109540018054')).Out
Assert-NotContains $j '\u00' 'JSON is not \u-escaped on either engine'
Assert-NotContains $j '":  ' 'JSON spacing is engine independent'

$r = Invoke-GLuhn @('-ListSchemes')
Assert-Equal 0 $r.Code 'list schemes exit code'
Assert-Contains $r.Out 'Mastercard (mastercard)' 'scheme table'
$r = Invoke-GLuhn @('-Version')
Assert-Contains $r.Out 'gLuhn.ps1 v' 'version banner'
Assert-Contains $r.Out "running on" 'version banner names the engine'
Assert-Contains $r.Out "$($PSVersionTable.PSVersion)" 'version banner shows the engine version'

Write-Output '- v1.1: test numbers, look-alikes, masking styles, expiry, track hints'
$j = (Invoke-GLuhn @('-j', '4242424242424242')).Out | ConvertFrom-Json
Assert-Equal 'Stripe' $j.test_card 'test card source'
$r = Invoke-GLuhn @('4242424242424242')
Assert-Contains $r.Out 'Test number:  published test' 'test card text line'
$imei = '353627070000008'
$j = (Invoke-GLuhn @('-j', $imei)).Out | ConvertFrom-Json
Assert-Equal 'IMEI' $j.lookalike.kind 'IMEI look-alike'
Assert-True (-not $j.length_ok) 'IMEI does not fit a card length rule'
$r = Invoke-GLuhn @('-MaskStyle', '8-4', '-q', '4542109540018054')
Assert-Contains $r.Out '45421095****8054' '8-4 masking'
$r = Invoke-GLuhn @('-MaskStyle', '8-4', '-q', '378282246310005')
Assert-Contains $r.Out '378282*****0005' '8-4 falls back to 6-4 under 16 digits'
$r = Invoke-GLuhn @('-MaskStyle', 'last4', '-q', '4542109540018054')
Assert-Contains $r.Out '************8054' 'last4 masking'
$r = Invoke-GLuhn @('-MaskStyle', 'full', '-q', '4542109540018054')
Assert-Contains $r.Out '****************' 'full masking'
$r = Invoke-GLuhn @(';4542109540018054=1312201123456789?')
Assert-Contains $r.Out '[expired (2013-12 is in the past)]' 'expired track'
Assert-Contains $r.Out 'PVKI 1, PVV 2345, CVV1/CVC1 678' 'discretionary hints'
Assert-Contains $r.Out 'Attention:    Full track data is sensitive authentication data' 'SAD warning'
$j = (Invoke-GLuhn @('-j', ';4542109540018054=4512201123456789?')).Out | ConvertFrom-Json
Assert-Equal 'far-future' $j.track.expiry_status.status 'far-future expiry'
$j = (Invoke-GLuhn @('-j', '4542109540018054=2513201')).Out | ConvertFrom-Json
Assert-Equal 'invalid' $j.track.expiry_status.status 'invalid month'

Write-Output '- v1.1: scanning folders, archives, UTF-16, PDF, formats'
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("gluhn_" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $tmp 'sub') -Force | Out-Null
try {
    [System.IO.File]::WriteAllText((Join-Path $tmp 'dump.txt'), "card: 4542 1095 4001 8054 exp 12/27`nphone 12345678901234`n")
    [System.IO.File]::WriteAllBytes((Join-Path $tmp 'utf16.txt'), [Text.Encoding]::Unicode.GetBytes("visa 4111111111111111`n"))
    [System.IO.File]::WriteAllText((Join-Path $tmp 'sub\notes.log'), "stripe 4242424242424242`n")
    [System.IO.File]::WriteAllText((Join-Path $tmp 'sub\skip.bak'), "amex 378282246310005`n")
    try { Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue } catch { }
    $zipPath = Join-Path $tmp 'archive.docx'
    $fs = [System.IO.File]::Create($zipPath)
    $za = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
    $entry = $za.CreateEntry('word/document.xml'); $w = New-Object System.IO.StreamWriter($entry.Open()); $w.Write('<w:t>Discover 6011111111111117</w:t>'); $w.Dispose()
    $inner = New-Object System.IO.MemoryStream
    $za2 = New-Object System.IO.Compression.ZipArchive($inner, [System.IO.Compression.ZipArchiveMode]::Create, $true)
    $e2 = $za2.CreateEntry('cards.csv'); $w2 = New-Object System.IO.StreamWriter($e2.Open()); $w2.Write("pan`n3530111333300000`n"); $w2.Dispose(); $za2.Dispose()
    $entry = $za.CreateEntry('nested.zip'); $es = $entry.Open(); $bytes = $inner.ToArray(); $es.Write($bytes, 0, $bytes.Length); $es.Dispose()
    $za.Dispose(); $fs.Dispose()
    # minimal PDF with a FlateDecode stream (zlib header + deflate body)
    $content = [Text.Encoding]::ASCII.GetBytes('BT (Card 4012 8888 8888 1881) Tj ET')
    $cms = New-Object System.IO.MemoryStream
    $def = New-Object System.IO.Compression.DeflateStream($cms, [System.IO.Compression.CompressionMode]::Compress, $true)
    $def.Write($content, 0, $content.Length); $def.Dispose()
    $deflated = $cms.ToArray()
    $pdf = New-Object System.IO.MemoryStream
    $head = [Text.Encoding]::ASCII.GetBytes("%PDF-1.4`n1 0 obj<</Length " + ($deflated.Length + 2) + "/Filter/FlateDecode>>stream`n")
    $pdf.Write($head, 0, $head.Length); $pdf.WriteByte(0x78); $pdf.WriteByte(0x9C); $pdf.Write($deflated, 0, $deflated.Length)
    $tail = [Text.Encoding]::ASCII.GetBytes("`nendstream`nendobj`n%%EOF"); $pdf.Write($tail, 0, $tail.Length)
    [System.IO.File]::WriteAllBytes((Join-Path $tmp 'doc.pdf'), $pdf.ToArray())
    [System.IO.File]::WriteAllBytes((Join-Path $tmp 'big.bin'), (New-Object byte[] 3000))

    $r = Invoke-GLuhn @('-Scan', $tmp)
    foreach ($p in @('4542109540018054', '4111111111111111', '4242424242424242', '378282246310005', '6011111111111117', '3530111333300000', '4012888888881881')) {
        Assert-Contains $r.Out $p "folder scan finds $p"
    }
    Assert-Contains $r.Out 'archive.docx!word/document.xml' 'archive member name'
    Assert-Contains $r.Out 'archive.docx!nested.zip!cards.csv' 'nested archive member name'
    Assert-Contains $r.Out 'HIGH    80  4542109540018054' 'confidence and score'
    Assert-Contains $r.Out 'expiry nearby (possible SAD)' 'SAD signal'
    $r = Invoke-GLuhn @('-Scan', $tmp, '-Exclude', '*.bak,sub')
    Assert-NotContains $r.Out '378282246310005' 'exclude pattern'
    Assert-NotContains $r.Out '4242424242424242' 'exclude folder'
    $r = Invoke-GLuhn @('-Scan', $tmp, '-Include', '*.txt')
    Assert-NotContains $r.Out '6011111111111117' 'include pattern'
    Assert-Contains $r.Out '4111111111111111' 'include keeps utf16.txt'
    $r = Invoke-GLuhn @('-Scan', $tmp, '-NoRecursive')
    Assert-NotContains $r.Out '4242424242424242' 'no recursion'
    $r = Invoke-GLuhn @('-Scan', $tmp, '-NoArchives')
    Assert-NotContains $r.Out '!' 'no archives'
    $r = Invoke-GLuhn @('-Scan', $tmp, '-MaxFileSize', '0.001')
    Assert-Contains $r.Out 'skipped' 'size limit reported'
    $r = Invoke-GLuhn @('-Scan', $tmp, '-MinScore', '70')
    Assert-Contains $r.Out 'candidate PANs found: 1' 'min score'
    $r = Invoke-GLuhn @('-Scan', $tmp, '-Format', 'csv', '-MaskStyle', '8-4')
    Assert-True ($r.Lines[0] -eq 'source,line,column,pan,scheme,iin_range,confidence,score,signals,test_card,lookalike,issuer,duplicate,sha256') 'csv header'
    Assert-Contains $r.Out ',45421095****8054,Visa,4,HIGH,80,' 'csv row'
    Assert-True ($r.Lines[1] -notmatch '^"') 'csv minimal quoting'
    $r = Invoke-GLuhn @('-Scan', $tmp, '-Format', 'jsonl')
    $first = $r.Lines[0] | ConvertFrom-Json
    Assert-True ($null -ne $first.score) 'jsonl record has score'
    Assert-Equal 64 $first.sha256.Length 'jsonl sha256'
} finally {
    Remove-Item -Recurse -Force $tmp
}

Write-Output '- v1.1: EMV TLV decoding'
$emv = '7081875A0845421095400180545F24032512315F34010157114542109540018054D2512201123456789F5F2008444F452F4A4F484E820219808E0E000000000000000042031E031F009F0702FF005F280208265F300202014F07A0000000031010500456495341950500000080009F2701809F360200129A032610069F02060000000123455F2A020978'
$r = Invoke-GLuhn @('-Emv', $emv)
Assert-Equal 0 $r.Code 'emv exit code'
Assert-Contains $r.Out 'Application:  Visa - Visa credit / debit  (AID A0000000031010)' 'emv aid'
Assert-Contains $r.Out 'Cardholder:   DOE/JOHN' 'emv cardholder'
Assert-Contains $r.Out 'Expiry:       2025-12-31  [expired' 'emv expiry status'
Assert-Contains $r.Out 'No CVM required | Always' 'emv cvm list'
Assert-Contains $r.Out 'Transaction exceeds floor limit' 'emv tvr'
Assert-Contains $r.Out 'ARQC (go online)' 'emv cid'
Assert-Contains $r.Out 'Amount, Authorised' 'emv amount tag'
Assert-Contains $r.Out '123.45' 'emv amount value'
Assert-Contains $r.Out '[+] Valid PAN' 'emv pan validated'
$j = (Invoke-GLuhn @('-Emv', $emv, '-j', '-m')).Out | ConvertFrom-Json
Assert-Equal '454210******8054' $j.summary.pan 'emv json masked pan'
Assert-Equal 'Visa' $j.summary.aid.scheme 'emv json aid'
Assert-Equal 18 @($j.tags[0].children).Count 'emv json children'
Assert-Equal 3 @($j.summary.cvm_list.rules).Count 'emv json cvm rules'
$r = Invoke-GLuhn @('-Emv', '570D 5555 5555 5555 4444 D251 2201 1F4F 07A0 0000 0003 1010')
Assert-Contains $r.Out 'AID says Visa but the PAN prefix says Mastercard' 'emv mismatch warning'
$r = Invoke-GLuhn @('-Emv', 'ZZ')
Assert-Equal 1 $r.Code 'emv bad hex exit code'
$r = Invoke-GLuhn @('-Emv', ('009F1081C8' + ('41' * 200) + 'FF'))
Assert-Contains $r.Out 'len 200' 'emv long form length'

Write-Output '- v1.1: external IIN table'
$tmpJson = Join-Path ([System.IO.Path]::GetTempPath()) ("gluhn_" + [guid]::NewGuid().ToString('N') + '.json')
try {
    [System.IO.File]::WriteAllText($tmpJson, '{"schemes":[{"key":"acme","name":"ACME Store Card","ranges":["7001-7002"],"lengths":[16]},{"key":"visa","name":"Visa X","ranges":["4"],"lengths":[16]}]}')
    $r = Invoke-GLuhn @('-IinTable', $tmpJson, '-i', '-q', '7001000000000004')
    Assert-Equal 0 $r.Code 'iin table new scheme accepted'
    $j = (Invoke-GLuhn @('-IinTable', $tmpJson, '-j', '4222222222222')).Out | ConvertFrom-Json
    Assert-Equal 'Visa X' $j.scheme 'iin table override'
    Assert-True (-not $j.length_ok) 'iin table override lengths'
    $r = Invoke-GLuhn @('-IinTable', $tmpJson, '-ListSchemes')
    Assert-Contains $r.Out 'ACME Store Card (acme)' 'iin table listed'
    [System.IO.File]::WriteAllText($tmpJson, '{"replace":true,"schemes":[{"key":"only","name":"Only","ranges":["9"]}]}')
    $r = Invoke-GLuhn @('-IinTable', $tmpJson, '-ListSchemes')
    Assert-NotContains $r.Out 'Mastercard (mastercard)' 'iin table replace'
    [System.IO.File]::WriteAllText($tmpJson, '{"schemes":[{"name":"no key"}]}')
    $r = Invoke-GLuhn @('-IinTable', $tmpJson, '4111111111111111')
    Assert-Equal 2 $r.Code 'iin table error exit code'
} finally { Remove-Item -Force $tmpJson }

Write-Output '- v1.1: online lookup (mock server when python3 is available)'
$py = Get-Command python3 -ErrorAction SilentlyContinue
if (-not $py) { $py = Get-Command python -ErrorAction SilentlyContinue }
$mock = Join-Path $PSScriptRoot 'mock_lookup.py'
if ($py -and (Test-Path $mock)) {
    $port = 18000 + (Get-Random -Maximum 1000)
    $proc = Start-Process -FilePath $py.Source -ArgumentList @($mock, $port) -PassThru -NoNewWindow
    try {
        Start-Sleep -Seconds 2
        $url = "http://127.0.0.1:$port/{iin}"
        $r = Invoke-GLuhn @('-Lookup', '-LookupUrl', $url, '4542109540018054')
        Assert-Contains $r.Out 'only the IIN is sent to 127.0.0.1' 'lookup notice'
        Assert-Contains $r.Out 'Lookup:       MOCK BANK PLC | visa | Visa Classic | debit | United Kingdom' 'lookup result'
        $j = (Invoke-GLuhn @('-Lookup', '-LookupUrl', $url, '-j', '5555555555554444')).Out | ConvertFrom-Json
        Assert-Equal '555555' $j.lookup.iin '6-digit fallback'
        Assert-Equal 'MOCK US BANK' $j.lookup.bank_name '6-digit fallback bank'
        $j = (Invoke-GLuhn @('-Lookup', '-LookupUrl', $url, '-j', '6011111111111117')).Out | ConvertFrom-Json
        Assert-Equal 'not found' $j.lookup.error 'lookup miss'
        $r = Invoke-GLuhn @('-Lookup', '-LookupUrl', 'http://127.0.0.1:1/{iin}', '-LookupTimeout', '2', '-q', '6011111111111117')
        Assert-Equal 0 $r.Code 'lookup failure does not break validation'
        $r = Invoke-GLuhn @('-Lookup', '-LookupUrl', 'http://example.invalid/', '4111111111111111')
        Assert-Equal 2 $r.Code 'lookup url without {iin} rejected'
    } finally { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
} else { Write-Output '  (skipped: python not found for the mock lookup server)' }

Write-Output ''
Write-Output "Passed: $script:Pass   Failed: $script:Fail"
if ($script:Fail -gt 0) { exit 1 }
exit 0
