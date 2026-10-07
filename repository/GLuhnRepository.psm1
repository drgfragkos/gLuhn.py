<#
.SYNOPSIS
    GLuhnRepository.psm1 - look up the issuing bank of a PAN in repository/bin-repository.json.

.DESCRIPTION
    PowerShell counterpart of gluhn_repository.py.  Both read the same JSON file
    ("gluhn-bin-repository/1", see build_repository.py for the format and README.md for the
    sources).  Works on Windows PowerShell 5.1 and PowerShell 7+:

      - PowerShell 7 parses the file with ConvertFrom-Json -AsHashtable.
      - Windows PowerShell 5.1 cannot (ConvertFrom-Json is capped at 2 MB there), so the module
        uses System.Web.Script.Serialization.JavaScriptSerializer with a raised MaxJsonLength.

    Import-Module .\repository\GLuhnRepository.psm1
    $repo = Import-BinRepository                       # repository/bin-repository.json next to the module
    Find-BinRepositoryIssuer -Repository $repo -Pan 4929401234567891
    Get-BinRepositoryIssuers -Repository $repo -Brand visa -CountryCode GB
    Get-BinRepositoryBrandsForIssuer -Repository $repo -Name barclays
#>

Set-StrictMode -Version 2.0

$script:RepoDefaultPath = Join-Path $PSScriptRoot 'bin-repository.json'
$script:RepoSupportedFormats = @('gluhn-bin-repository/1')
$script:RepoBrandAliases = @{
    'AMEX' = 'AMERICAN EXPRESS'; 'UNIONPAY' = 'CHINA UNIONPAY'; 'UNION PAY' = 'CHINA UNIONPAY'; 'CUP' = 'CHINA UNIONPAY'
    'DINERS' = 'DINERS CLUB'; 'MC' = 'MASTERCARD'; 'MASTER CARD' = 'MASTERCARD'
}

function Get-RepoValue {
    # $null-safe access that works for IDictionary and PSCustomObject alike.
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) { if ($Object.Contains($Name)) { return $Object[$Name] } return $Default }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -ne $p -and $null -ne $p.Value) { return $p.Value }
    return $Default
}

function ConvertFrom-LargeJson {
    # Returns nested IDictionary / object[] structures on both engines.
    param([string]$Text)
    $isCore = ($PSVersionTable.ContainsKey('PSEdition') -and $PSVersionTable.PSEdition -eq 'Core')
    if ($isCore) { return (ConvertFrom-Json -InputObject $Text -AsHashtable -Depth 16) }
    Add-Type -AssemblyName System.Web.Extensions
    $serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $serializer.MaxJsonLength = [int]::MaxValue
    $serializer.RecursionLimit = 64
    return $serializer.DeserializeObject($Text)
}

function Import-BinRepository {
    <#
    .SYNOPSIS  Load bin-repository.json once; returns a repository object for the other functions.
    #>
    param([string]$Path = $script:RepoDefaultPath)
    if (-not (Test-Path -LiteralPath $Path)) { throw "repository not found: $Path (build it with repository/build_repository.py)" }
    $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    $data = ConvertFrom-LargeJson -Text $text
    $format = [string](Get-RepoValue $data 'format')
    if ($script:RepoSupportedFormats -notcontains $format) { throw "${Path}: unsupported repository format '$format'" }
    $ranges = Get-RepoValue $data 'ranges' @{}
    $index = New-Object System.Collections.ArrayList
    foreach ($key in @($ranges.Keys)) {
        $rows = @($ranges[$key])
        $los = New-Object int[] $rows.Count
        for ($i = 0; $i -lt $rows.Count; $i++) { $los[$i] = [int]$rows[$i][0] }
        [void]$index.Add(@{ Length = [int]$key; Los = $los; Rows = $rows })
    }
    $sorted = @($index | Sort-Object -Property @{ Expression = { -$_['Length'] } })
    return @{
        Path = $Path; Format = $format; Generated = [string](Get-RepoValue $data 'generated' '')
        Counts = (Get-RepoValue $data 'counts' @{}); Sources = @(Get-RepoValue $data 'sources' @())
        Brands = @(Get-RepoValue $data 'brands' @()); Types = @(Get-RepoValue $data 'types' @())
        Categories = @(Get-RepoValue $data 'categories' @()); Countries = (Get-RepoValue $data 'countries' @{})
        Issuers = @(Get-RepoValue $data 'issuers' @()); ByBrand = (Get-RepoValue $data 'by_brand' @{})
        Index = $sorted
    }
}

function ConvertTo-RepoRow {
    param($Repository, $Row, [int]$Length)
    $lo = [long]$Row[0]; $hi = [long]$Row[1]
    $loText = ([string]$lo).PadLeft($Length, '0'); $hiText = ([string]$hi).PadLeft($Length, '0')
    $range = $loText
    if ($lo -ne $hi) { $range = "$loText-$hiText" }
    $cc = [string]$Row[6]
    $countries = $Repository['Countries']
    $country = $null
    if ($cc -and (Get-RepoValue $countries $cc)) { $country = [string](Get-RepoValue $countries $cc) }
    $out = [ordered]@{
        bin = $loText; prefix_length = $Length; range = $range
        brand = [string]$Repository['Brands'][[int]$Row[2]]; type = [string]$Repository['Types'][[int]$Row[3]]
        category = [string]$Repository['Categories'][[int]$Row[4]]
        issuer = $null; country_code = $null; country = $country; url = $null; phone = $null
    }
    if ($cc) { $out['country_code'] = $cc }
    $issId = [int]$Row[5]
    if ($issId -ge 0) {
        $e = $Repository['Issuers'][$issId]
        $out['issuer'] = [string](Get-RepoValue $e 'n')
        $out['url'] = Get-RepoValue $e 'u'
        $out['phone'] = Get-RepoValue $e 'p'
        $ec = [string](Get-RepoValue $e 'c' '')
        if (-not $out['country_code'] -and $ec) { $out['country_code'] = $ec; $out['country'] = Get-RepoValue $countries $ec }
    }
    return $out
}

function Find-BinRepositoryIssuer {
    <#
    .SYNOPSIS  Issuer information for a PAN or bare BIN (5-8 digits); $null when unknown.  Longest prefix wins.
    #>
    param($Repository, [string]$Pan)
    $digits = ($Pan -replace '\D', '')
    foreach ($bucket in $Repository['Index']) {
        $len = $bucket['Length']
        if ($digits.Length -lt $len) { continue }
        $x = [int]$digits.Substring(0, $len)
        $los = $bucket['Los']
        $lo = 0; $hi = $los.Length - 1
        while ($lo -le $hi) {                       # binary search: rightmost lo <= x
            $mid = ($lo + $hi) -shr 1
            if ($los[$mid] -le $x) { $lo = $mid + 1 } else { $hi = $mid - 1 }
        }
        if ($hi -ge 0) {
            $row = $bucket['Rows'][$hi]
            if ([long]$row[0] -le $x -and $x -le [long]$row[1]) { return (ConvertTo-RepoRow -Repository $Repository -Row $row -Length $len) }
        }
    }
    return $null
}

function Resolve-RepoBrand {
    param($Repository, [string]$Brand)
    $b = (($Brand -replace '\s+', ' ').Trim()).ToUpper()
    if ($script:RepoBrandAliases.ContainsKey($b)) { $b = $script:RepoBrandAliases[$b] }
    if ($Repository['Brands'] -contains $b) { return $b }
    foreach ($k in $Repository['Brands']) { if (([string]$k).StartsWith($b)) { return $k } }
    return $b
}

function Get-BinRepositoryIssuers {
    <#
    .SYNOPSIS  Banks that issue a brand (e.g. visa, amex, unionpay), optionally in one country (ISO alpha-2).
    #>
    param($Repository, [string]$Brand, [string]$CountryCode = '')
    $key = Resolve-RepoBrand -Repository $Repository -Brand $Brand
    $table = Get-RepoValue $Repository['ByBrand'] $key @{}
    $out = New-Object System.Collections.ArrayList
    foreach ($cc in @($table.Keys)) {
        if ($CountryCode -and $cc.ToUpper() -ne $CountryCode.ToUpper()) { continue }
        foreach ($i in @($table[$cc])) {
            $e = $Repository['Issuers'][[int]$i]
            [void]$out.Add([ordered]@{ issuer = [string](Get-RepoValue $e 'n'); country_code = $cc
                country = (Get-RepoValue $Repository['Countries'] $cc); url = (Get-RepoValue $e 'u'); phone = (Get-RepoValue $e 'p'); brand = $key })
        }
    }
    return @($out | Sort-Object -Property @{ Expression = { $_['country_code'] } }, @{ Expression = { $_['issuer'] } })
}

function Get-BinRepositoryBrandsForIssuer {
    <#
    .SYNOPSIS  Which brands a bank issues and where (substring match on the issuer name).
    #>
    param($Repository, [string]$Name)
    $needle = $Name.Trim().ToUpper()
    $wanted = @{}
    for ($i = 0; $i -lt $Repository['Issuers'].Count; $i++) {
        if (([string](Get-RepoValue $Repository['Issuers'][$i] 'n' '')).Contains($needle)) { $wanted[$i] = $true }
    }
    $out = New-Object System.Collections.ArrayList
    $byBrand = $Repository['ByBrand']
    foreach ($brand in @($byBrand.Keys)) {
        $ccs = $byBrand[$brand]
        foreach ($cc in @($ccs.Keys)) {
            foreach ($i in @($ccs[$cc])) {
                if ($wanted.ContainsKey([int]$i)) {
                    [void]$out.Add([ordered]@{ issuer = [string](Get-RepoValue $Repository['Issuers'][[int]$i] 'n'); brand = $brand
                        country_code = $cc; country = (Get-RepoValue $Repository['Countries'] $cc) })
                }
            }
        }
    }
    return @($out | Sort-Object -Property @{ Expression = { $_['issuer'] } }, @{ Expression = { $_['brand'] } }, @{ Expression = { $_['country_code'] } })
}

function Get-BinRepositoryInfo {
    param($Repository)
    return [ordered]@{ path = $Repository['Path']; format = $Repository['Format']; generated = $Repository['Generated']
        counts = $Repository['Counts']; sources = $Repository['Sources'] }
}

function Format-BinRepositoryLookup {
    <#
    .SYNOPSIS  One line in the style of gLuhn's text output.
    #>
    param($Info)
    if ($null -eq $Info) { return 'no issuer information' }
    $bits = foreach ($k in @('issuer', 'brand', 'type', 'category', 'country')) { if ($Info[$k]) { [string]$Info[$k] } }
    return "$($bits -join ' | ')  [BIN $($Info['range'])]"
}

Export-ModuleMember -Function Import-BinRepository, Find-BinRepositoryIssuer, Get-BinRepositoryIssuers, `
    Get-BinRepositoryBrandsForIssuer, Get-BinRepositoryInfo, Format-BinRepositoryLookup
