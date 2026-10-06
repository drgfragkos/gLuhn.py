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
    Assert-Contains $r.Out 'Total candidate PANs found: 3' 'scan count'
    Assert-Contains $r.Out 'line 3      378282246310005          American Express' 'scan amex'
    Assert-Contains $r.Out '(duplicate)' 'scan duplicate flag'
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

Write-Output ''
Write-Output "Passed: $script:Pass   Failed: $script:Fail"
if ($script:Fail -gt 0) { exit 1 }
exit 0
