<#
.SYNOPSIS
    Builds a single-file HTML user guide from a Markdown source.

.DESCRIPTION
    Reads Docs/User-Guide.md (or -Source), the UI strings in Docs/guide/strings.en.json
    (or -Strings) and the favicon files in Docs/guide/favicon, and writes one
    self-contained HTML5 file (Docs/User-Guide.html or -Output) that embeds its own
    CSS, JavaScript, icons and strings. The output has no external references.

    The Markdown conventions the builder recognises are documented in
    Docs/guide/README.md. The script is pure ASCII and runs on Windows PowerShell 5.1
    and on PowerShell 7.

.PARAMETER Source
    Markdown source. Default: Docs/User-Guide.md relative to the repository root
    (the parent folder of Tools).

.PARAMETER Strings
    UI strings JSON. Default: Docs/guide/strings.en.json.

.PARAMETER Output
    HTML output path. Default: Docs/User-Guide.html.

.PARAMETER CollapseAfter
    Code blocks longer than this many lines get a "Show N more lines" toggle. Default 14.

.EXAMPLE
    .\Tools\Build-UserGuide.ps1

.EXAMPLE
    .\Tools\Build-UserGuide.ps1 -Source Docs\User-Guide.ar.md -Strings Docs\guide\strings.ar.json -Output Docs\User-Guide.ar.html
#>
[CmdletBinding()]
param(
    [string]$Source = '',
    [string]$Strings = '',
    [string]$Output = '',
    [int]$CollapseAfter = 14
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
$script:ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:RepoRoot = Split-Path -Parent $script:ToolsDir

function Resolve-GuidePath {
    param([string]$Value, [string]$Default)
    if ([string]::IsNullOrEmpty($Value)) {
        return [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($script:RepoRoot, $Default))
    }
    if ([System.IO.Path]::IsPathRooted($Value)) { return [System.IO.Path]::GetFullPath($Value) }
    return [System.IO.Path]::GetFullPath([System.IO.Path]::Combine((Get-Location).Path, $Value))
}

$SourcePath  = Resolve-GuidePath $Source  'Docs/User-Guide.md'
$StringsPath = Resolve-GuidePath $Strings 'Docs/guide/strings.en.json'
$OutputPath  = Resolve-GuidePath $Output  'Docs/User-Guide.html'
$FaviconDir  = [System.IO.Path]::Combine($script:RepoRoot, 'Docs', 'guide', 'favicon')

if (-not (Test-Path -LiteralPath $SourcePath))  { throw "Source not found: $SourcePath" }
if (-not (Test-Path -LiteralPath $StringsPath)) { throw "Strings file not found: $StringsPath" }
if ($CollapseAfter -lt 1) { $CollapseAfter = 1 }

# ---------------------------------------------------------------------------
# Non-ASCII characters, built from code points so this file stays pure ASCII
# ---------------------------------------------------------------------------
$script:CopyrightSign = [string][char]0x00A9
$script:Year = (Get-Date).Year
$script:DefaultCopyright = $script:CopyrightSign + ' 2004-{year} @drgfragkos'
$script:Placeholder = [string][char]0x0001

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------
function Get-Prop {
    # Safe property read on PSCustomObject / hashtable; returns $Default when absent.
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $Default
    }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p -or $null -eq $p.Value) { return $Default }
    return $p.Value
}

function Get-PropNames {
    param($Object)
    $names = New-Object System.Collections.ArrayList
    if ($null -eq $Object) { return $names }
    if ($Object -is [System.Collections.IDictionary]) {
        foreach ($k in $Object.Keys) { [void]$names.Add([string]$k) }
        return $names
    }
    foreach ($p in $Object.PSObject.Properties) { [void]$names.Add($p.Name) }
    return $names
}

function ConvertTo-HtmlText {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    return $Text.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;')
}

function ConvertTo-AttrText {
    param([string]$Text)
    return (ConvertTo-HtmlText $Text).Replace("'", '&#39;')
}

function Get-Slug {
    # Keeps Latin letters, digits and the Arabic block (U+0600..U+06FF).
    param([string]$Text)
    $t = $Text.ToLowerInvariant()
    $t = [regex]::Replace($t, '[^a-z0-9\u0600-\u06FF]+', '-')
    $t = $t.Trim('-')
    if ($t.Length -eq 0) { $t = 'section' }
    return $t
}

function Format-Template {
    # Replaces {name} placeholders from an IDictionary.
    param([string]$Template, [System.Collections.IDictionary]$Values)
    $result = $Template
    foreach ($k in $Values.Keys) { $result = $result.Replace('{' + $k + '}', [string]$Values[$k]) }
    return $result
}

function ConvertTo-InlineHtml {
    # HTML-escapes the text, then applies `code`, [text](url), **bold** and *italic*.
    param([string]$Text)
    $s = ConvertTo-HtmlText $Text
    $script:InlineCodeStore = New-Object System.Collections.ArrayList
    $s = [regex]::Replace($s, '`([^`]+)`', [System.Text.RegularExpressions.MatchEvaluator]{
        param($m)
        $idx = $script:InlineCodeStore.Add('<code>' + $m.Groups[1].Value + '</code>')
        return $script:Placeholder + [string]$idx + $script:Placeholder
    })
    $s = [regex]::Replace($s, '\[([^\]]+)\]\(([^)\s]+)\)', '<a href="$2">$1</a>')
    $s = [regex]::Replace($s, '\*\*(.+?)\*\*', '<strong>$1</strong>')
    $s = [regex]::Replace($s, '(?<![\w*])\*(?![\s*])([^*]+?)(?<!\s)\*(?![\w*])', '<em>$1</em>')
    $s = [regex]::Replace($s, [regex]::Escape($script:Placeholder) + '(\d+)' + [regex]::Escape($script:Placeholder), [System.Text.RegularExpressions.MatchEvaluator]{
        param($m)
        return [string]$script:InlineCodeStore[[int]$m.Groups[1].Value]
    })
    return $s
}

function Split-HeadingNumber {
    # "5.7 Generate a PAN" -> @{Num='5.7'; Text='Generate a PAN'}
    param([string]$Title)
    $m = [regex]::Match($Title, '^\s*(\d+(?:\.\d+)+)\.?\s+(.*)$')
    if ($m.Success) { return @{ Num = $m.Groups[1].Value; Text = $m.Groups[2].Value.Trim() } }
    return @{ Num = ''; Text = $Title.Trim() }
}

function ConvertTo-SafeJson {
    # JSON safe for inlining inside <script>: escape <, >, & and line separators.
    param($Object)
    $json = ConvertTo-Json -InputObject $Object -Depth 20 -Compress
    $json = $json.Replace('<', '\u003c').Replace('>', '\u003e').Replace('&', '\u0026')
    $json = $json.Replace([string][char]0x2028, '\u2028').Replace([string][char]0x2029, '\u2029')
    return $json
}

# ---------------------------------------------------------------------------
# Read inputs
# ---------------------------------------------------------------------------
$Utf8 = New-Object System.Text.UTF8Encoding $false
$stringsText = [System.IO.File]::ReadAllText($StringsPath, [System.Text.Encoding]::UTF8)
$S = $stringsText | ConvertFrom-Json
$markdown = [System.IO.File]::ReadAllText($SourcePath, [System.Text.Encoding]::UTF8)
$markdown = $markdown.Replace("`r`n", "`n").Replace("`r", "`n")
$allLines = $markdown -split "`n"

$Lang = [string](Get-Prop $S 'lang' 'en')
$Dir = [string](Get-Prop $S 'dir' 'ltr')
if ($Dir -ne 'rtl') { $Dir = 'ltr' }

$Callouts = Get-Prop $S 'callouts' $null
$CodeLabels = Get-Prop $S 'codeLabels' $null
$FlowBadges = Get-Prop $S 'flowBadges' $null
$Categories = Get-Prop $S 'categories' $null
$SkipSections = @(Get-Prop $S 'skipSections' @())
$NavSubsections = @(Get-Prop $S 'navSubsections' @())
$CountSubsections = @(Get-Prop $S 'countSubsections' @())
$Groups = @(Get-Prop $S 'groups' @())
$Emblem = [string](Get-Prop $S 'emblem' '')
$Autolink = Get-Prop $S 'autolink' $null
$CopyrightText = [string](Get-Prop $S 'copyright' $script:DefaultCopyright)
if ([string]::IsNullOrEmpty($CopyrightText)) { $CopyrightText = $script:DefaultCopyright }

function Get-Label {
    param($Table, [string]$Key, [string]$Fallback)
    $v = Get-Prop $Table $Key $null
    if ($null -eq $v) { return $Fallback }
    return [string]$v
}

function Get-CodeLabel {
    param([string]$Fence)
    $key = $Fence.ToLowerInvariant()
    if ($key.Length -eq 0) { $key = 'text' }
    $aliases = @{ 'ps1' = 'powershell'; 'pwsh' = 'powershell'; 'sh' = 'bash'; 'shell' = 'bash'; 'py' = 'python'; 'bat' = 'cmd'; 'batch' = 'cmd'; 'txt' = 'text'; 'plain' = 'text' }
    if ($aliases.ContainsKey($key)) { $key = $aliases[$key] }
    $v = Get-Prop $CodeLabels $key $null
    if ($null -ne $v) { return [string]$v }
    return $Fence
}

# Callout kind detection: Markdown label -> kind key (note / attention / info)
$script:CalloutKinds = @{}
foreach ($kind in @('note', 'attention', 'info')) {
    $script:CalloutKinds[$kind] = $kind
    $label = Get-Label $Callouts $kind $kind
    $script:CalloutKinds[$label.ToLowerInvariant()] = $kind
}
$script:CalloutKinds['attribution'] = 'info'
$script:CalloutKinds['warning'] = 'attention'
$script:CalloutKinds['tip'] = 'note'

function Get-CalloutKind {
    param([string]$Label)
    $k = $Label.Trim().TrimEnd('.', ':').ToLowerInvariant()
    if ($script:CalloutKinds.ContainsKey($k)) { return $script:CalloutKinds[$k] }
    return 'note'
}

# Category normalisation: bracket text -> @{Key; Name}
$script:CategoryByKey = [ordered]@{}
foreach ($name in (Get-PropNames $Categories)) {
    $script:CategoryByKey[[string]$name] = [string](Get-Prop $Categories $name $name)
}
$script:UsedCategories = [ordered]@{}

function Resolve-Category {
    param([string]$Raw)
    $raw = $Raw.Trim()
    if ($raw.Length -eq 0) { $raw = 'general' }
    $key = ''
    foreach ($k in $script:CategoryByKey.Keys) {
        if ($k -ieq $raw -or ([string]$script:CategoryByKey[$k]) -ieq $raw) { $key = $k; break }
    }
    if ($key.Length -eq 0) {
        $key = Get-Slug $raw
        if (-not $script:CategoryByKey.Contains($key)) { $script:CategoryByKey[$key] = $raw }
    }
    if (-not $script:UsedCategories.Contains($key)) { $script:UsedCategories[$key] = $script:CategoryByKey[$key] }
    return @{ Key = $key; Name = [string]$script:CategoryByKey[$key] }
}

# ---------------------------------------------------------------------------
# Split the Markdown into sections
# ---------------------------------------------------------------------------
$GuideTitle = ''
$Sections = New-Object System.Collections.ArrayList
$currentSection = $null
$inFence = $false
$autoNumber = 0
foreach ($line in $allLines) {
    if ($line -match '^\s*```') { $inFence = -not $inFence }
    if (-not $inFence) {
        if ($GuideTitle.Length -eq 0 -and $line -match '^#\s+(.+?)\s*$') {
            $GuideTitle = $Matches[1]
            continue
        }
        $hm = [regex]::Match($line, '^##\s+(?:(\d+)\.\s*)?(.*?)\s*$')
        if ($hm.Success) {
            $num = $hm.Groups[1].Value
            $title = $hm.Groups[2].Value
            if ($num.Length -eq 0) { $autoNumber++; $num = [string]$autoNumber } else { $autoNumber = [int]$num }
            $skip = $false
            foreach ($sk in $SkipSections) { if (([string]$sk) -ieq $title) { $skip = $true } }
            $currentSection = [ordered]@{
                Number = [int]$num
                Id = 's' + $num
                Title = $title
                Lines = New-Object System.Collections.ArrayList
                Skip = $skip
            }
            [void]$Sections.Add($currentSection)
            continue
        }
    }
    if ($null -ne $currentSection) { [void]$currentSection.Lines.Add($line) }
}
if ($GuideTitle.Length -eq 0) { $GuideTitle = [string](Get-Prop $S 'title' 'Guide') }
$Subtitle = [string](Get-Prop $S 'subtitle' '')

$kept = New-Object System.Collections.ArrayList
foreach ($sec in $Sections) { if (-not $sec.Skip) { [void]$kept.Add($sec) } }
$Sections = $kept
if ($Sections.Count -eq 0) { throw 'No "## N. Title" sections found in the source.' }

# ---------------------------------------------------------------------------
# Rich block renderers
# ---------------------------------------------------------------------------
$script:ArrowSvg = '<svg viewBox="0 0 16 22" width="16" height="22" aria-hidden="true" focusable="false"><path d="M8 1v16M3 13l5 5 5-5" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/></svg>'

function ConvertTo-CodeBlockHtml {
    param([System.Collections.ArrayList]$Lines, [string]$Fence)
    # Drop trailing blank lines
    while ($Lines.Count -gt 0 -and ([string]$Lines[$Lines.Count - 1]).Trim().Length -eq 0) { $Lines.RemoveAt($Lines.Count - 1) }
    $count = $Lines.Count
    $label = ConvertTo-HtmlText (Get-CodeLabel $Fence)
    $code = ConvertTo-HtmlText ($Lines -join "`n")
    $hidden = $count - $CollapseAfter
    $cls = 'code'
    if ($hidden -gt 0) { $cls = 'code collapsed' }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<div class="' + $cls + '" dir="ltr" data-lines="' + $count + '" data-hidden="' + [string][math]::Max($hidden, 0) + '">')
    [void]$sb.Append('<div class="code-bar"><span class="code-lang">' + $label + '</span>')
    [void]$sb.Append('<button type="button" class="copy-btn">' + (ConvertTo-HtmlText (Get-Prop $S 'copy' 'Copy')) + '</button></div>')
    [void]$sb.Append('<pre><code>' + $code + '</code></pre>')
    if ($hidden -gt 0) {
        $more = Format-Template (Get-Prop $S 'showMore' 'Show {n} more lines') @{ n = $hidden }
        [void]$sb.Append('<button type="button" class="code-more" aria-expanded="false">' + (ConvertTo-HtmlText $more) + '</button>')
    }
    [void]$sb.Append('</div>')
    return $sb.ToString()
}

function ConvertTo-FlowHtml {
    param([System.Collections.ArrayList]$Lines)
    $nodes = New-Object System.Collections.ArrayList
    $node = $null
    foreach ($raw in $Lines) {
        $line = [string]$raw
        if ($line.Trim().Length -eq 0) { continue }
        $m = [regex]::Match($line, '^(START|STEP|SEE|DECIDE|END)\s*:\s*(.*)$', 'IgnoreCase')
        if ($m.Success) {
            $kind = $m.Groups[1].Value.ToLowerInvariant()
            $text = $m.Groups[2].Value.Trim()
            $cmd = ''
            $bar = $text.IndexOf(' | ')
            if ($bar -ge 0) { $cmd = $text.Substring($bar + 3).Trim(); $text = $text.Substring(0, $bar).Trim() }
            $node = @{ Kind = $kind; Text = $text; Cmd = $cmd; Branches = (New-Object System.Collections.ArrayList) }
            [void]$nodes.Add($node)
            continue
        }
        if ($null -eq $node) { continue }
        $b = [regex]::Match($line, '^\s+(.+?)\s*->\s*(.+?)\s*$')
        if ($b.Success) {
            [void]$node.Branches.Add(@{ Label = $b.Groups[1].Value; Outcome = $b.Groups[2].Value })
        } else {
            $node.Text = ($node.Text + ' ' + $line.Trim()).Trim()
        }
    }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<div class="flow" role="list">')
    $i = 0
    foreach ($n in $nodes) {
        if ($i -gt 0) { [void]$sb.Append('<div class="flow-arrow" aria-hidden="true">' + $script:ArrowSvg + '</div>') }
        $badge = ConvertTo-HtmlText (Get-Label $FlowBadges $n.Kind ($n.Kind.Substring(0, 1).ToUpperInvariant() + $n.Kind.Substring(1)))
        [void]$sb.Append('<div class="flow-node flow-' + $n.Kind + '" role="listitem"><span class="flow-badge">' + $badge + '</span><div class="flow-body">')
        [void]$sb.Append('<div class="flow-text">' + (ConvertTo-InlineHtml $n.Text) + '</div>')
        if ($n.Cmd.Length -gt 0) { [void]$sb.Append('<code class="flow-cmd" dir="ltr">' + (ConvertTo-HtmlText $n.Cmd) + '</code>') }
        if ($n.Branches.Count -gt 0) {
            [void]$sb.Append('<dl class="flow-branches">')
            foreach ($br in $n.Branches) {
                [void]$sb.Append('<div class="flow-branch"><dt>' + (ConvertTo-InlineHtml $br.Label) + '</dt><dd>' + (ConvertTo-InlineHtml $br.Outcome) + '</dd></div>')
            }
            [void]$sb.Append('</dl>')
        }
        [void]$sb.Append('</div></div>')
        $i++
    }
    [void]$sb.Append('</div>')
    return $sb.ToString()
}

function ConvertTo-CardsHtml {
    param([System.Collections.ArrayList]$Lines)
    $cards = New-Object System.Collections.ArrayList
    $card = $null
    foreach ($raw in $Lines) {
        $line = [string]$raw
        if ($line.Trim().Length -eq 0) { continue }
        $m = [regex]::Match($line, '^CARD\s*:\s*(.+?)\s*(?:->\s*(.*?))?\s*$', 'IgnoreCase')
        if ($m.Success) {
            $card = [ordered]@{ Name = $m.Groups[1].Value; Target = $m.Groups[2].Value; Fields = [ordered]@{} }
            [void]$cards.Add($card)
            continue
        }
        if ($null -eq $card) { continue }
        $f = [regex]::Match($line, '^\s+([A-Za-z_][\w-]*)\s*:\s*(.*)$')
        if ($f.Success) { $card.Fields[$f.Groups[1].Value.ToLowerInvariant()] = $f.Groups[2].Value.Trim() }
    }
    $sorted = @($cards | Sort-Object -Property @{ Expression = { [string]$_.Name } })
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<div class="cards">')
    foreach ($c in $sorted) {
        $href = '#'
        $target = [string]$c.Target
        if ($target.Length -gt 0) {
            if ($target.StartsWith('#')) { $href = $target }
            else {
                $tm = [regex]::Match($target, '^(\d+(?:\.\d+)*)\b')
                if ($tm.Success) { $href = '#ref:' + $tm.Groups[1].Value } else { $href = '#ref:title:' + (Get-Slug $target) }
            }
        }
        [void]$sb.Append('<a class="card" href="' + (ConvertTo-AttrText $href) + '">')
        [void]$sb.Append('<div class="card-name">' + (ConvertTo-InlineHtml ([string]$c.Name)) + '</div>')
        foreach ($k in $c.Fields.Keys) {
            $v = [string]$c.Fields[$k]
            switch ($k) {
                'folder' { [void]$sb.Append('<div class="card-folder" dir="ltr">' + (ConvertTo-HtmlText $v) + '</div>') }
                'for'    { [void]$sb.Append('<p class="card-for">' + (ConvertTo-InlineHtml $v) + '</p>') }
                'needs'  { [void]$sb.Append('<div class="card-needs">' + (ConvertTo-InlineHtml $v) + '</div>') }
                default  { [void]$sb.Append('<div class="card-meta"><span class="card-meta-key">' + (ConvertTo-HtmlText $k) + '</span> ' + (ConvertTo-InlineHtml $v) + '</div>') }
            }
        }
        [void]$sb.Append('</a>')
    }
    [void]$sb.Append('</div>')
    return $sb.ToString()
}

function ConvertTo-TableHtml {
    param([System.Collections.ArrayList]$Rows)
    $parsed = New-Object System.Collections.ArrayList
    foreach ($raw in $Rows) {
        $line = ([string]$raw).Trim()
        if ($line.StartsWith('|')) { $line = $line.Substring(1) }
        if ($line.EndsWith('|') -and -not $line.EndsWith('\|')) { $line = $line.Substring(0, $line.Length - 1) }
        $cells = [regex]::Split($line, '(?<!\\)\|')
        $list = New-Object System.Collections.ArrayList
        foreach ($c in $cells) { [void]$list.Add(([string]$c).Replace('\|', '|').Trim()) }
        [void]$parsed.Add($list)
    }
    $aligns = New-Object System.Collections.ArrayList
    $bodyStart = 1
    if ($parsed.Count -gt 1) {
        $isSep = $true
        foreach ($c in $parsed[1]) { if (-not ([string]$c -match '^:?-{2,}:?$') -and ([string]$c).Length -gt 0) { $isSep = $false } }
        if ($isSep) {
            foreach ($c in $parsed[1]) {
                $cs = [string]$c
                if ($cs.StartsWith(':') -and $cs.EndsWith(':')) { [void]$aligns.Add('center') }
                elseif ($cs.EndsWith(':')) { [void]$aligns.Add('end') }
                else { [void]$aligns.Add('') }
            }
            $bodyStart = 2
        }
    }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<div class="table-wrap"><table><thead><tr>')
    $ci = 0
    foreach ($c in $parsed[0]) {
        $al = ''
        if ($ci -lt $aligns.Count -and ([string]$aligns[$ci]).Length -gt 0) { $al = ' style="text-align:' + $aligns[$ci] + '"' }
        [void]$sb.Append('<th' + $al + '>' + (ConvertTo-InlineHtml ([string]$c)) + '</th>')
        $ci++
    }
    [void]$sb.Append('</tr></thead><tbody>')
    for ($r = $bodyStart; $r -lt $parsed.Count; $r++) {
        [void]$sb.Append('<tr>')
        $ci = 0
        foreach ($c in $parsed[$r]) {
            $al = ''
            if ($ci -lt $aligns.Count -and ([string]$aligns[$ci]).Length -gt 0) { $al = ' style="text-align:' + $aligns[$ci] + '"' }
            [void]$sb.Append('<td' + $al + '>' + (ConvertTo-InlineHtml ([string]$c)) + '</td>')
            $ci++
        }
        [void]$sb.Append('</tr>')
    }
    [void]$sb.Append('</tbody></table></div>')
    return $sb.ToString()
}

function ConvertTo-CalloutHtml {
    param([System.Collections.ArrayList]$Lines)
    $kind = 'note'
    $paras = New-Object System.Collections.ArrayList
    $buf = New-Object System.Collections.ArrayList
    $first = $true
    foreach ($raw in $Lines) {
        $text = [string]$raw
        if ($first) {
            $first = $false
            $m = [regex]::Match($text, '^\s*\*\*(.+?)\*\*\s*(.*)$')
            if ($m.Success) { $kind = Get-CalloutKind $m.Groups[1].Value; $text = $m.Groups[2].Value }
        }
        if ($text.Trim().Length -eq 0) {
            if ($buf.Count -gt 0) { [void]$paras.Add(($buf -join ' ')); $buf.Clear() }
        } else { [void]$buf.Add($text.Trim()) }
    }
    if ($buf.Count -gt 0) { [void]$paras.Add(($buf -join ' ')) }
    $label = ConvertTo-HtmlText (Get-Label $Callouts $kind $kind)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<div class="callout callout-' + $kind + '"><div class="callout-label">' + $label + '</div><div class="callout-text">')
    foreach ($p in $paras) { [void]$sb.Append('<p>' + (ConvertTo-InlineHtml ([string]$p)) + '</p>') }
    [void]$sb.Append('</div></div>')
    return $sb.ToString()
}

# ---------------------------------------------------------------------------
# Section body renderer
# ---------------------------------------------------------------------------
$script:FaqIndex = 0

function ConvertFrom-SectionBody {
    param($Section)
    $st = @{
        Out = New-Object System.Collections.ArrayList
        Para = New-Object System.Collections.ArrayList
        Lists = New-Object System.Collections.ArrayList
        InFaq = $false
        Toc = New-Object System.Collections.ArrayList
        FaqCount = 0
    }
    $lines = $Section.Lines
    $n = $lines.Count
    $secId = [string]$Section.Id

    function Flush-Para {
        if ($st.Para.Count -gt 0) {
            [void]$st.Out.Add('<p>' + (ConvertTo-InlineHtml ($st.Para -join ' ')) + '</p>')
            $st.Para.Clear()
        }
    }
    function Close-Lists {
        while ($st.Lists.Count -gt 0) {
            $top = $st.Lists[$st.Lists.Count - 1]
            $close = ''
            if ($top.Open) { $close = '</li>' }
            [void]$st.Out.Add($close + '</' + $top.Type + '>')
            $st.Lists.RemoveAt($st.Lists.Count - 1)
        }
    }
    function Close-Block {
        Flush-Para
        Close-Lists
    }
    function Close-Faq {
        Close-Block
        if ($st.InFaq) { [void]$st.Out.Add('</div></details>'); $st.InFaq = $false }
    }

    $i = 0
    while ($i -lt $n) {
        $line = [string]$lines[$i]
        $trim = $line.Trim()

        # Blank lines, separators, comments
        if ($trim.Length -eq 0) {
            Flush-Para
            if ($st.Lists.Count -gt 0) {
                # keep the list open if the next non-blank line is another list item
                $j = $i + 1
                while ($j -lt $n -and ([string]$lines[$j]).Trim().Length -eq 0) { $j++ }
                $keep = $false
                if ($j -lt $n -and ([string]$lines[$j]) -match '^(\s*)(?:[-*+]|\d+[.)])\s+') { $keep = $true }
                if (-not $keep) { Close-Lists }
            }
            $i++; continue
        }
        if ($trim -match '^-{3,}$' -or $trim -match '^\*{3,}$' -or $trim -match '^<!--.*-->$') { Close-Block; $i++; continue }

        # Fenced blocks
        $fm = [regex]::Match($line, '^\s*```\s*([\w+-]*)\s*$')
        if ($fm.Success) {
            Close-Block
            $lang = $fm.Groups[1].Value
            $block = New-Object System.Collections.ArrayList
            $i++
            while ($i -lt $n -and -not (([string]$lines[$i]) -match '^\s*```\s*$')) { [void]$block.Add([string]$lines[$i]); $i++ }
            $i++ # closing fence
            switch ($lang.ToLowerInvariant()) {
                'flow'  { [void]$st.Out.Add((ConvertTo-FlowHtml $block)) }
                'cards' { [void]$st.Out.Add((ConvertTo-CardsHtml $block)) }
                default { [void]$st.Out.Add((ConvertTo-CodeBlockHtml $block $lang)) }
            }
            continue
        }

        # Headings
        $h3 = [regex]::Match($line, '^###\s+(.+?)\s*$')
        if ($h3.Success) {
            Close-Faq
            $title = $h3.Groups[1].Value
            $parts = Split-HeadingNumber $title
            $slug = Get-Slug $title
            $id = $secId + '/' + $slug
            # keep ids unique within the section
            $dup = 1
            $base = $id
            while ($true) {
                $exists = $false
                foreach ($t in $st.Toc) { if ($t.id -eq $id) { $exists = $true } }
                if (-not $exists) { break }
                $dup++; $id = $base + '-' + $dup
            }
            [void]$st.Toc.Add([ordered]@{ id = $id; num = [string]$parts.Num; title = [string]$parts.Text })
            $numHtml = ''
            if (([string]$parts.Num).Length -gt 0) { $numHtml = '<span class="h-num">' + (ConvertTo-HtmlText $parts.Num) + '</span>' }
            [void]$st.Out.Add('<h3 id="' + (ConvertTo-AttrText $id) + '">' + $numHtml + '<span class="h-text">' + (ConvertTo-InlineHtml ([string]$parts.Text)) + '</span></h3>')
            $i++; continue
        }
        $h4 = [regex]::Match($line, '^####\s+(.+?)\s*$')
        if ($h4.Success) {
            Close-Block
            $title = $h4.Groups[1].Value
            [void]$st.Out.Add('<h4 id="' + (ConvertTo-AttrText ($secId + '/' + (Get-Slug $title))) + '">' + (ConvertTo-InlineHtml $title) + '</h4>')
            $i++; continue
        }

        # Callouts
        if ($line -match '^\s*>') {
            Close-Block
            $block = New-Object System.Collections.ArrayList
            while ($i -lt $n -and ([string]$lines[$i]) -match '^\s*>') {
                [void]$block.Add(([string]$lines[$i] -replace '^\s*>\s?', ''))
                $i++
            }
            [void]$st.Out.Add((ConvertTo-CalloutHtml $block))
            continue
        }

        # Tables
        if ($trim.StartsWith('|')) {
            Close-Block
            $rows = New-Object System.Collections.ArrayList
            while ($i -lt $n -and ([string]$lines[$i]).Trim().StartsWith('|')) { [void]$rows.Add([string]$lines[$i]); $i++ }
            [void]$st.Out.Add((ConvertTo-TableHtml $rows))
            continue
        }

        # FAQ questions
        $q = [regex]::Match($trim, '^\*\*Q:\s*(.+?)\*\*\s*(?:`\[([^\]]+)\]`|\[([^\]]+)\])?\s*$')
        if ($q.Success) {
            Close-Faq
            $catRaw = $q.Groups[2].Value
            if ($catRaw.Length -eq 0) { $catRaw = $q.Groups[3].Value }
            $cat = Resolve-Category $catRaw
            $script:FaqIndex++
            $st.FaqCount++
            $st.InFaq = $true
            [void]$st.Out.Add('<details class="faq" id="faq-' + $script:FaqIndex + '" data-cat="' + (ConvertTo-AttrText $cat.Key) + '"><summary><span class="faq-q">' + (ConvertTo-InlineHtml $q.Groups[1].Value) + '</span><span class="faq-cat">' + (ConvertTo-HtmlText $cat.Name) + '</span></summary><div class="faq-body">')
            $i++; continue
        }

        # List items
        $li = [regex]::Match($line, '^(\s*)([-*+]|\d+[.)])\s+(.*)$')
        if ($li.Success) {
            Flush-Para
            $indent = $li.Groups[1].Value.Replace("`t", '    ').Length
            $type = 'ul'
            if ($li.Groups[2].Value -match '^\d') { $type = 'ol' }
            while ($st.Lists.Count -gt 0 -and $st.Lists[$st.Lists.Count - 1].Indent -gt $indent) {
                $top = $st.Lists[$st.Lists.Count - 1]
                $close = ''
                if ($top.Open) { $close = '</li>' }
                [void]$st.Out.Add($close + '</' + $top.Type + '>')
                $st.Lists.RemoveAt($st.Lists.Count - 1)
            }
            if ($st.Lists.Count -gt 0 -and $st.Lists[$st.Lists.Count - 1].Indent -eq $indent -and $st.Lists[$st.Lists.Count - 1].Type -ne $type) {
                $top = $st.Lists[$st.Lists.Count - 1]
                $close = ''
                if ($top.Open) { $close = '</li>' }
                [void]$st.Out.Add($close + '</' + $top.Type + '>')
                $st.Lists.RemoveAt($st.Lists.Count - 1)
            }
            if ($st.Lists.Count -eq 0 -or $st.Lists[$st.Lists.Count - 1].Indent -lt $indent) {
                [void]$st.Lists.Add(@{ Type = $type; Indent = $indent; Open = $false })
                [void]$st.Out.Add('<' + $type + '>')
            }
            $top = $st.Lists[$st.Lists.Count - 1]
            if ($top.Open) { [void]$st.Out.Add('</li>') }
            [void]$st.Out.Add('<li>' + (ConvertTo-InlineHtml $li.Groups[3].Value))
            $top.Open = $true
            $i++; continue
        }
        if ($st.Lists.Count -gt 0) {
            # lazy continuation of the previous list item
            [void]$st.Out.Add(' ' + (ConvertTo-InlineHtml $trim))
            $i++; continue
        }

        # Paragraph text
        [void]$st.Para.Add($trim)
        $i++
    }
    Close-Faq

    return @{ Html = ($st.Out -join "`n"); Toc = $st.Toc; FaqCount = $st.FaqCount }
}

# ---------------------------------------------------------------------------
# Render all sections
# ---------------------------------------------------------------------------
$Rendered = New-Object System.Collections.ArrayList
$RefByNumber = @{}
$RefBySlug = @{}
$FaqSectionId = ''
$TotalFaq = 0
foreach ($sec in $Sections) {
    $r = ConvertFrom-SectionBody $sec
    $sec.Html = $r.Html
    $sec.Toc = $r.Toc
    $sec.FaqCount = $r.FaqCount
    if ($r.FaqCount -gt 0 -and $FaqSectionId.Length -eq 0) { $FaqSectionId = $sec.Id }
    $TotalFaq += $r.FaqCount
    $RefByNumber[[string]$sec.Number] = '#' + $sec.Id
    foreach ($t in $r.Toc) {
        $href = '#' + $t.id
        if (([string]$t.num).Length -gt 0 -and -not $RefByNumber.ContainsKey([string]$t.num)) { $RefByNumber[[string]$t.num] = $href }
        $slugKey = Get-Slug ([string]$t.title)
        if (-not $RefBySlug.ContainsKey($slugKey)) { $RefBySlug[$slugKey] = $href }
        $fullSlug = Get-Slug (([string]$t.num + ' ' + [string]$t.title).Trim())
        if (-not $RefBySlug.ContainsKey($fullSlug)) { $RefBySlug[$fullSlug] = $href }
    }
    [void]$Rendered.Add($sec)
}

function Resolve-Ref {
    param([string]$Token)
    if ($Token.StartsWith('title:')) {
        $slug = $Token.Substring(6)
        if ($RefBySlug.ContainsKey($slug)) { return $RefBySlug[$slug] }
        return $null
    }
    if ($RefByNumber.ContainsKey($Token)) { return $RefByNumber[$Token] }
    $dot = $Token.IndexOf('.')
    if ($dot -gt 0) {
        $head = $Token.Substring(0, $dot)
        if ($RefByNumber.ContainsKey($head)) { return $RefByNumber[$head] }
    }
    return $null
}

# Resolve card placeholders and run the autolink pass
$AutoPattern = ''
$AutoTarget = ''
if ($null -ne $Autolink) {
    $AutoPattern = [string](Get-Prop $Autolink 'pattern' '')
    $AutoTarget = [string](Get-Prop $Autolink 'target' '')
}
$script:SkipTags = @{ 'a' = 1; 'h1' = 1; 'h2' = 1; 'h3' = 1; 'h4' = 1; 'code' = 1; 'pre' = 1; 'summary' = 1; 'button' = 1; 'script' = 1; 'style' = 1 }

function Invoke-Autolink {
    param([string]$Html)
    if ($AutoPattern.Length -eq 0 -or $AutoTarget.Length -eq 0) { return $Html }
    $rx = New-Object System.Text.RegularExpressions.Regex($AutoPattern)
    $sb = New-Object System.Text.StringBuilder
    $depth = 0
    $tokens = [regex]::Matches($Html, '<[^>]+>|[^<]+')
    foreach ($tk in $tokens) {
        $v = $tk.Value
        if ($v.StartsWith('<')) {
            $tm = [regex]::Match($v, '^<(/?)([A-Za-z][A-Za-z0-9]*)')
            if ($tm.Success) {
                $name = $tm.Groups[2].Value.ToLowerInvariant()
                if ($script:SkipTags.ContainsKey($name) -and -not $v.EndsWith('/>')) {
                    if ($tm.Groups[1].Value -eq '/') { if ($depth -gt 0) { $depth-- } } else { $depth++ }
                }
            }
            [void]$sb.Append($v)
            continue
        }
        if ($depth -gt 0) { [void]$sb.Append($v); continue }
        $replaced = $rx.Replace($v, [System.Text.RegularExpressions.MatchEvaluator]{
            param($m)
            $num = $AutoTarget
            for ($g = 1; $g -lt $m.Groups.Count; $g++) { $num = $num.Replace('{' + $g + '}', $m.Groups[$g].Value) }
            $href = $null
            if ($RefByNumber.ContainsKey($num)) { $href = $RefByNumber[$num] }
            if ($null -eq $href) { return $m.Value }
            return '<a class="xref" href="' + $href + '">' + $m.Value + '</a>'
        })
        [void]$sb.Append($replaced)
    }
    return $sb.ToString()
}

foreach ($sec in $Rendered) {
    $html = [string]$sec.Html
    $html = [regex]::Replace($html, 'href="#ref:([^"]+)"', [System.Text.RegularExpressions.MatchEvaluator]{
        param($m)
        $target = Resolve-Ref $m.Groups[1].Value
        if ($null -eq $target) {
            Write-Warning ('Unresolved card target: ' + $m.Groups[1].Value)
            return 'href="#"'
        }
        return 'href="' + $target + '"'
    })
    $sec.Html = Invoke-Autolink $html
}

# ---------------------------------------------------------------------------
# Rail, on-this-page, FAQ toolbar, copyright
# ---------------------------------------------------------------------------
$SectionById = @{}
foreach ($sec in $Rendered) { $SectionById[[string]$sec.Number] = $sec }

function Get-RailLink {
    param($Sec)
    $num = ([int]$Sec.Number).ToString('00')
    $badge = ''
    if ($Sec.Id -eq $FaqSectionId) { $badge = [string]$Sec.FaqCount }
    else {
        foreach ($c in $CountSubsections) { if ([int]$c -eq [int]$Sec.Number) { $badge = [string]$Sec.Toc.Count } }
    }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<a class="rail-link" href="#' + $Sec.Id + '" data-section="' + $Sec.Id + '"><span class="rail-num">' + $num + '</span><span class="rail-text">' + (ConvertTo-HtmlText $Sec.Title) + '</span>')
    if ($badge.Length -gt 0) { [void]$sb.Append('<span class="rail-badge">' + $badge + '</span>') }
    [void]$sb.Append('</a>')
    $showSubs = $false
    foreach ($nsx in $NavSubsections) { if ([int]$nsx -eq [int]$Sec.Number) { $showSubs = $true } }
    if ($showSubs -and $Sec.Toc.Count -gt 0) {
        [void]$sb.Append('<div class="rail-sub">')
        foreach ($t in $Sec.Toc) {
            $numHtml = ''
            if (([string]$t.num).Length -gt 0) { $numHtml = '<span class="rail-sub-num">' + (ConvertTo-HtmlText $t.num) + '</span>' }
            [void]$sb.Append('<a href="#' + (ConvertTo-AttrText $t.id) + '" data-id="' + (ConvertTo-AttrText $t.id) + '">' + $numHtml + '<span>' + (ConvertTo-HtmlText $t.title) + '</span></a>')
        }
        [void]$sb.Append('</div>')
    }
    return $sb.ToString()
}

$railSb = New-Object System.Text.StringBuilder
$placed = @{}
foreach ($g in $Groups) {
    $gname = [string](Get-Prop $g 'name' '')
    $members = @(Get-Prop $g 'sections' @())
    $links = New-Object System.Text.StringBuilder
    foreach ($m in $members) {
        $key = [string]([int]$m)
        if ($SectionById.ContainsKey($key) -and -not $placed.ContainsKey($key)) {
            [void]$links.Append((Get-RailLink $SectionById[$key]))
            $placed[$key] = $true
        }
    }
    if ($links.Length -gt 0) {
        [void]$railSb.Append('<div class="rail-group">')
        if ($gname.Length -gt 0) { [void]$railSb.Append('<div class="rail-group-name">' + (ConvertTo-HtmlText $gname) + '</div>') }
        [void]$railSb.Append($links.ToString() + '</div>')
    }
}
$rest = New-Object System.Text.StringBuilder
foreach ($sec in $Rendered) {
    if (-not $placed.ContainsKey([string]$sec.Number)) { [void]$rest.Append((Get-RailLink $sec)) }
}
if ($rest.Length -gt 0) { [void]$railSb.Append('<div class="rail-group">' + $rest.ToString() + '</div>') }
$RailGroupsHtml = $railSb.ToString()

$EmblemHtml = ''
if ($Emblem.Trim().Length -gt 0) { $EmblemHtml = '<div class="rail-emblem">' + $Emblem + '</div>' }

$hintRaw = [string](Get-Prop $S 'keyboardHint' 'Press / to search the FAQ')
$hintHtml = ConvertTo-HtmlText $hintRaw
$slashAt = $hintHtml.IndexOf('/')
if ($slashAt -ge 0) { $hintHtml = $hintHtml.Substring(0, $slashAt) + '<kbd>/</kbd>' + $hintHtml.Substring($slashAt + 1) }

$copySb = New-Object System.Text.StringBuilder
$copyText = $CopyrightText.Replace('{year}', [string]$script:Year).Replace('\n', "`n")
foreach ($cl in ($copyText -split "`n")) {
    if (([string]$cl).Trim().Length -gt 0) { [void]$copySb.Append('<div>' + (ConvertTo-HtmlText ([string]$cl).Trim()) + '</div>') }
}
$CopyrightHtml = $copySb.ToString()

$FaqToolbarHtml = ''
if ($FaqSectionId.Length -gt 0) {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<div class="faq-tools">')
    [void]$sb.Append('<div class="faq-search-row"><svg class="faq-glass" viewBox="0 0 20 20" width="18" height="18" aria-hidden="true" focusable="false"><circle cx="8.5" cy="8.5" r="5.5" fill="none" stroke="currentColor" stroke-width="1.8"/><path d="M12.8 12.8L17 17" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/></svg>')
    [void]$sb.Append('<input id="faq-search" type="search" autocomplete="off" spellcheck="false" placeholder="' + (ConvertTo-AttrText (Get-Prop $S 'searchPlaceholder' 'Search')) + '" aria-label="' + (ConvertTo-AttrText (Get-Prop $S 'searchPlaceholder' 'Search')) + '">')
    [void]$sb.Append('<span id="faq-count" class="faq-count" aria-live="polite"></span></div>')
    [void]$sb.Append('<div class="faq-options">')
    [void]$sb.Append('<label><input type="checkbox" id="faq-opt-all" checked> ' + (ConvertTo-HtmlText (Get-Prop $S 'matchAll' 'Match all words')) + '</label>')
    [void]$sb.Append('<label><input type="checkbox" id="faq-opt-answers" checked> ' + (ConvertTo-HtmlText (Get-Prop $S 'searchAnswers' 'Search answers too')) + '</label>')
    [void]$sb.Append('<label><input type="checkbox" id="faq-opt-whole"> ' + (ConvertTo-HtmlText (Get-Prop $S 'wholeWords' 'Whole words only')) + '</label>')
    [void]$sb.Append('<button type="button" id="faq-expand" class="faq-expand" aria-expanded="false">' + (ConvertTo-HtmlText (Get-Prop $S 'expandAll' 'Expand all')) + '</button>')
    [void]$sb.Append('</div>')
    [void]$sb.Append('<div class="faq-chips" role="group">')
    [void]$sb.Append('<button type="button" class="faq-chip is-active" data-cat="all" aria-pressed="true">' + (ConvertTo-HtmlText (Get-Prop $S 'all' 'All')) + '</button>')
    foreach ($k in $script:UsedCategories.Keys) {
        [void]$sb.Append('<button type="button" class="faq-chip" data-cat="' + (ConvertTo-AttrText $k) + '" aria-pressed="false">' + (ConvertTo-HtmlText ([string]$script:UsedCategories[$k])) + '</button>')
    }
    [void]$sb.Append('</div></div>')
    [void]$sb.Append('<p id="faq-none" class="faq-none" hidden>' + (ConvertTo-HtmlText (Get-Prop $S 'noMatches' 'No entries match.')) + '</p>')
    $FaqToolbarHtml = $sb.ToString()
}

# Sections HTML
$mainSb = New-Object System.Text.StringBuilder
$first = $true
$TocJson = New-Object System.Collections.ArrayList
foreach ($sec in $Rendered) {
    $hiddenAttr = ' hidden'
    if ($first) { $hiddenAttr = ''; $first = $false }
    $num = ([int]$sec.Number).ToString('00')
    [void]$mainSb.Append('<section class="guide-section" id="' + $sec.Id + '" aria-labelledby="' + $sec.Id + '-title"' + $hiddenAttr + '>')
    [void]$mainSb.Append('<h2 class="section-title" id="' + $sec.Id + '-title"><span class="num-tile" aria-hidden="true">' + $num + '</span><span>' + (ConvertTo-InlineHtml $sec.Title) + '</span></h2>')
    if ($sec.Id -eq $FaqSectionId) { [void]$mainSb.Append($FaqToolbarHtml) }
    [void]$mainSb.Append("`n" + $sec.Html + "`n")
    [void]$mainSb.Append('</section>' + "`n")
    [void]$TocJson.Add([ordered]@{ id = $sec.Id; num = [string]$sec.Number; title = [string]$sec.Title; items = @($sec.Toc) })
}
$FirstId = [string]$Rendered[0].Id

# ---------------------------------------------------------------------------
# Favicons
# ---------------------------------------------------------------------------
function Get-DataUri {
    param([string]$Path, [string]$Mime)
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    return 'data:' + $Mime + ';base64,' + [Convert]::ToBase64String($bytes)
}
$SvgIcon = Get-DataUri ([System.IO.Path]::Combine($FaviconDir, 'favicon.svg')) 'image/svg+xml'
$IcoIcon = Get-DataUri ([System.IO.Path]::Combine($FaviconDir, 'favicon.ico')) 'image/x-icon'
$IconLinks = ''
if ($SvgIcon.Length -gt 0) { $IconLinks += '<link rel="icon" type="image/svg+xml" href="' + $SvgIcon + '">' + "`n" }
if ($IcoIcon.Length -gt 0) { $IconLinks += '<link rel="icon" type="image/x-icon" sizes="16x16 32x32 48x48" href="' + $IcoIcon + '">' + "`n" }
if ($IconLinks.Length -eq 0) { Write-Warning ('No favicon files found in ' + $FaviconDir) }

# ---------------------------------------------------------------------------
# CSS
# ---------------------------------------------------------------------------
$Css = @'
:root{
  --paper:#F6F7F5;--panel:#FFFFFF;--text:#1F2933;--muted:#5B6B7A;--rule:#DCE1E6;
  --accent:#0E6B6B;--accent-soft:#E3F1F0;--warn:#A8600E;--warn-soft:#FBF0DF;
  --info:#2B5FA6;--info-soft:#E7EEF8;
  --ink:#1C2733;--ink-2:#2F3D4C;--code-text:#E6ECF2;--rail-text:#D5DEE7;--rail-muted:#8E9DAC;--rail-faint:#5F7080;
  --font-text:"IBM Plex Sans","Segoe UI",Inter,system-ui,sans-serif;
  --font-mono:"IBM Plex Mono","Cascadia Mono",Consolas,monospace;
  --text-size:15px;--text-lh:1.55;--code-size:13px;--code-lh:1.5;
  --rail-w:250px;--onpage-w:220px;--col-gap:56px;--collapse-lines:__COLLAPSE__;
  --radius:10px;--shadow:0 8px 22px rgba(28,39,51,.22);
}
*{box-sizing:border-box}
html{background:var(--paper);scroll-padding-top:16px}
body{margin:0;background:var(--paper);color:var(--text);font-family:var(--font-text);font-size:var(--text-size);line-height:var(--text-lh);text-align:start;-webkit-text-size-adjust:100%;min-height:100vh}
[hidden]{display:none !important}
a{color:var(--accent)}
a:hover{text-decoration-thickness:2px}
code,kbd,pre{font-family:var(--font-mono);font-size:var(--code-size)}
p code,li code,td code,th code,dd code,dt code,.callout code,.flow-text code,.card-for code,.faq-q code{background:var(--accent-soft);color:#0B4F4F;padding:1px 5px;border-radius:4px;font-size:.9em}
kbd{display:inline-block;border:1px solid rgba(255,255,255,.25);border-radius:4px;padding:0 5px;font-size:11px;line-height:1.5;background:rgba(255,255,255,.08);color:inherit}
mark{background:#FFE68F;color:inherit;padding:0 1px;border-radius:2px}
:focus-visible{outline:2px solid var(--accent);outline-offset:2px}

/* Rail */
.rail{position:fixed;inset-block:0;inset-inline-start:0;width:var(--rail-w);background:var(--ink);color:var(--rail-text);display:flex;flex-direction:column;overflow-y:auto;overscroll-behavior:contain;font-size:13.5px;z-index:4}
.rail-head{padding:22px 20px 12px}
.rail-title{font-size:19px;font-weight:700;color:#fff;letter-spacing:-.01em;line-height:1.2}
.rail-subtitle{font-size:12.5px;color:var(--rail-muted);margin-top:3px}
.rail-emblem{padding:6px 20px 12px;color:#9FB0C0}
.rail-emblem svg{display:block;max-width:100%;height:auto}
.rail-group{padding:6px 12px 4px}
.rail-group-name{font-size:10.5px;font-weight:600;letter-spacing:.14em;text-transform:uppercase;color:#7E8E9E;padding:10px 8px 6px}
.rail-link{display:flex;align-items:center;gap:10px;padding:7px 10px;border-radius:8px;color:var(--rail-text);text-decoration:none;line-height:1.3}
.rail-link:hover{background:rgba(255,255,255,.06);color:#fff}
.rail-link.is-active{background:var(--accent);color:#fff}
.rail-num{font-family:var(--font-mono);font-size:11.5px;font-weight:600;color:var(--rail-muted);min-width:20px;text-align:start}
.rail-link.is-active .rail-num{color:rgba(255,255,255,.78)}
.rail-text{flex:1;min-width:0}
.rail-badge{font-family:var(--font-mono);font-size:11px;font-weight:600;line-height:1;background:rgba(255,255,255,.1);color:#C5D0DA;padding:4px 7px;border-radius:999px}
.rail-link.is-active .rail-badge{background:rgba(255,255,255,.22);color:#fff}
.rail-sub{display:flex;flex-direction:column;margin:2px 0 6px;padding-inline-start:22px}
.rail-sub a{position:relative;display:flex;align-items:baseline;gap:8px;padding:4px 10px;border-radius:6px;color:#A8B6C4;font-size:12.5px;line-height:1.35;text-decoration:none}
.rail-sub a:hover{color:#fff;background:rgba(255,255,255,.05)}
.rail-sub a::before{content:"";position:absolute;inset-inline-start:-1px;top:50%;width:6px;height:6px;margin-top:-3px;border-radius:50%;background:transparent}
.rail-sub a.is-current{color:#fff}
.rail-sub a.is-current::before{background:#8FD3CF}
.rail-sub-num{font-family:var(--font-mono);font-size:11px;color:#7E8E9E;min-width:28px;flex:0 0 auto}
.rail-foot{margin-top:auto;padding:14px 20px 18px;border-top:1px solid rgba(255,255,255,.08)}
.rail-hint{font-size:12px;color:var(--rail-muted)}
.rail-copy{margin-top:10px;font-size:11px;line-height:1.5;color:var(--rail-faint)}

/* Layout: start-aligned group of reading column + on-this-page column */
.page{display:flex;justify-content:flex-start;align-items:flex-start;gap:var(--col-gap);margin-inline-start:var(--rail-w);padding-block:36px 96px;padding-inline:48px 32px}
.reading{flex:0 1 calc(88ch * 1.15);min-width:0}
.reading p,.reading ul,.reading ol,.reading h3,.reading h4,.callout,.faq-body{max-width:88ch}
.table-wrap,.code,.flow,.cards,.faq-tools,details.faq{max-width:none}

/* Section title with number tile */
.section-title{display:flex;align-items:center;gap:14px;margin:0 0 22px;font-size:30px;line-height:1.2;font-weight:700;letter-spacing:-.015em}
.num-tile{display:inline-flex;align-items:center;justify-content:center;min-width:46px;height:40px;padding:0 10px;border:1px solid var(--rule);border-radius:9px;background:var(--panel);font-family:var(--font-mono);font-size:15px;font-weight:600;color:var(--muted);letter-spacing:.02em;flex:0 0 auto}
.reading h3{display:flex;flex-wrap:wrap;align-items:baseline;gap:0 8px;font-size:20px;line-height:1.3;font-weight:700;letter-spacing:-.01em;margin:36px 0 10px;padding-top:14px;border-top:1px solid var(--rule);scroll-margin-top:16px}
.reading h3:first-of-type{border-top:0;padding-top:0}
.h-num{color:var(--muted);font-weight:500;font-size:.85em;font-family:var(--font-mono)}
.reading h4{font-size:16px;font-weight:600;margin:22px 0 6px;scroll-margin-top:16px}
.reading p{margin:0 0 12px}
.reading ul,.reading ol{margin:0 0 12px;padding-inline-start:1.6em}
.reading li{margin:3px 0}
.reading li>ul,.reading li>ol{margin:4px 0 0}
.xref{font-family:var(--font-mono);font-size:.92em;text-decoration:none;border-bottom:1px dotted var(--accent)}

/* Callouts */
.callout{display:flex;flex-direction:column;gap:4px;margin:16px 0;padding:12px 16px;border:1px solid var(--rule);border-inline-start:4px solid var(--accent);border-radius:8px;background:var(--panel)}
.callout-label{font-weight:700;font-size:13px;letter-spacing:.02em}
.callout-text p{margin:0 0 6px}
.callout-text p:last-child{margin-bottom:0}
.callout-note{background:var(--accent-soft);border-inline-start-color:var(--accent)}
.callout-note .callout-label{color:var(--accent)}
.callout-attention{background:var(--warn-soft);border-inline-start-color:var(--warn)}
.callout-attention .callout-label{color:var(--warn)}
.callout-info{background:var(--info-soft);border-inline-start-color:var(--info)}
.callout-info .callout-label{color:var(--info)}

/* Tables */
.table-wrap{overflow-x:auto;margin:16px 0;border:1px solid var(--rule);border-radius:8px;background:var(--panel)}
table{border-collapse:collapse;width:100%;font-size:14px}
th{background:var(--paper);color:var(--muted);font-weight:600;text-align:start;padding:9px 12px;border-bottom:1px solid var(--rule);white-space:nowrap}
td{padding:8px 12px;border-bottom:1px solid var(--rule);vertical-align:top}
tr:last-child td{border-bottom:0}

/* Code blocks */
.code{position:relative;margin:16px 0;border-radius:var(--radius);background:var(--ink-2);color:var(--code-text);overflow:hidden;direction:ltr;text-align:left}
.code-bar{display:flex;justify-content:space-between;align-items:center;gap:10px;padding:6px 8px 6px 14px;background:var(--ink);color:#B8C4D0;font-size:12px;letter-spacing:.02em}
.copy-btn{border:1px solid rgba(255,255,255,.18);background:transparent;color:#D5DEE7;border-radius:6px;padding:3px 10px;font-family:var(--font-text);font-size:12px;cursor:pointer}
.copy-btn:hover{background:rgba(255,255,255,.08)}
.copy-btn.is-done{border-color:#8FD3CF;color:#8FD3CF}
.code pre{margin:0;padding:12px 14px;overflow:auto;line-height:var(--code-lh);tab-size:4}
.code pre code{font-size:var(--code-size);color:inherit;background:none;padding:0}
.code.collapsed pre{max-height:calc(var(--collapse-lines) * var(--code-lh) * var(--code-size) + 24px);overflow:hidden}
.code.collapsed pre::after{content:"";position:absolute;left:0;right:0;bottom:30px;height:36px;background:linear-gradient(rgba(47,61,76,0),var(--ink-2));pointer-events:none}
.code-more{display:block;width:100%;border:0;border-top:1px solid rgba(255,255,255,.08);background:var(--ink);color:#B8C4D0;padding:7px 14px;font-family:var(--font-text);font-size:12px;text-align:left;cursor:pointer}
.code-more:hover{color:#fff}

/* Decision flow */
.flow{display:flex;flex-direction:column;margin:18px 0}
.flow-node{display:flex;align-items:flex-start;gap:12px;padding:12px 14px;border:1px solid var(--rule);border-radius:var(--radius);background:var(--panel)}
.flow-badge{flex:0 0 auto;min-width:56px;text-align:center;padding:5px 8px;border-radius:999px;font-size:11px;font-weight:600;line-height:1;letter-spacing:.06em;text-transform:uppercase;margin-top:2px}
.flow-start .flow-badge,.flow-end .flow-badge{background:var(--accent);color:#fff}
.flow-step .flow-badge{background:var(--ink-2);color:#fff}
.flow-see .flow-badge{background:#E4E8EC;color:var(--muted)}
.flow-decide .flow-badge{background:var(--warn);color:#fff}
.flow-decide{border-color:#E8C89A;background:var(--warn-soft)}
.flow-body{flex:1;min-width:0}
.flow-cmd{display:block;margin-top:8px;padding:6px 10px;border-radius:6px;background:var(--ink-2);color:var(--code-text);font-size:12.5px;white-space:pre-wrap;direction:ltr;text-align:left}
.flow-arrow{align-self:center;color:var(--muted);display:flex;height:22px;margin:2px 0}
.flow-branches{display:grid;grid-template-columns:max-content 1fr;gap:4px 14px;margin:10px 0 0;font-size:14px}
.flow-branch{display:contents}
.flow-branches dt{font-weight:600;color:var(--warn)}
.flow-branches dd{margin:0}

/* Cards */
.cards{display:grid;grid-template-columns:repeat(auto-fill,minmax(220px,1fr));gap:14px;margin:18px 0}
.card{display:flex;flex-direction:column;padding:14px 16px;border:1px solid var(--rule);border-radius:var(--radius);background:var(--panel);color:inherit;text-decoration:none;transition:border-color .15s,box-shadow .15s}
.card:hover{border-color:var(--accent);box-shadow:0 4px 14px rgba(14,107,107,.12)}
.card-name{color:var(--accent);font-weight:700;font-size:16px}
.card-folder{font-family:var(--font-mono);font-size:12px;color:var(--muted);margin-top:2px;text-align:start}
.card-for{margin:8px 0 0;font-size:14px;flex:1}
.card-meta{font-size:12.5px;color:var(--muted);margin-top:6px}
.card-meta-key{font-weight:600}
.card-needs{margin-top:12px;padding-top:8px;border-top:1px dashed var(--rule);font-size:12.5px;color:var(--muted)}

/* FAQ */
.faq-tools{margin:16px 0 20px;padding:14px 16px;border:1px solid var(--rule);border-radius:var(--radius);background:var(--panel)}
.faq-search-row{display:flex;align-items:center;gap:10px;padding:6px 12px;border:1px solid var(--rule);border-radius:8px;background:var(--paper);color:var(--muted)}
.faq-search-row:focus-within{border-color:var(--accent);box-shadow:0 0 0 3px var(--accent-soft)}
#faq-search{flex:1;min-width:0;border:0;background:transparent;color:var(--text);font-family:var(--font-text);font-size:15px;padding:4px 0;outline:none}
#faq-search::-webkit-search-cancel-button{cursor:pointer}
.faq-count{font-family:var(--font-mono);font-size:12px;color:var(--muted);white-space:nowrap}
.faq-options{display:flex;flex-wrap:wrap;align-items:center;gap:8px 18px;margin-top:12px;font-size:13.5px;color:var(--muted)}
.faq-options label{display:inline-flex;align-items:center;gap:6px;cursor:pointer}
.faq-options input{accent-color:var(--accent);margin:0}
.faq-expand{margin-inline-start:auto;border:1px solid var(--accent);background:transparent;color:var(--accent);border-radius:6px;padding:4px 11px;font-family:var(--font-text);font-size:12.5px;font-weight:600;cursor:pointer}
.faq-expand:hover{background:var(--accent-soft)}
.faq-expand:disabled{opacity:.5;cursor:default}
.faq-chips{display:flex;flex-wrap:wrap;gap:8px;margin-top:14px;padding-top:14px;border-top:1px solid var(--rule)}
.faq-chip{border:1px solid var(--rule);background:var(--paper);color:var(--text);border-radius:999px;padding:4px 12px;font-family:var(--font-text);font-size:12.5px;cursor:pointer}
.faq-chip:hover{border-color:var(--accent);color:var(--accent)}
.faq-chip.is-active{background:var(--accent);border-color:var(--accent);color:#fff}
.faq-none{color:var(--muted);font-style:italic}
details.faq{margin:8px 0;border:1px solid var(--rule);border-radius:8px;background:var(--panel)}
details.faq summary{display:flex;align-items:baseline;gap:10px;padding:10px 14px;cursor:pointer;font-weight:600;list-style:none;line-height:1.4}
details.faq summary::-webkit-details-marker{display:none}
details.faq summary::before{content:"";flex:0 0 auto;width:0;height:0;border-style:solid;border-width:4px 0 4px 6px;border-color:transparent transparent transparent var(--muted);transform:translateY(-1px);transition:transform .15s}
[dir="rtl"] details.faq summary::before{border-width:4px 6px 4px 0;border-color:transparent var(--muted) transparent transparent}
details.faq[open] summary::before{transform:rotate(90deg) translateX(1px)}
[dir="rtl"] details.faq[open] summary::before{transform:rotate(-90deg) translateX(-1px)}
.faq-q{flex:1;min-width:0}
.faq-cat{margin-inline-start:auto;flex:0 0 auto;font-size:11px;font-weight:600;letter-spacing:.04em;text-transform:uppercase;color:var(--muted);background:var(--paper);border:1px solid var(--rule);border-radius:999px;padding:2px 8px;line-height:1.5}
.faq-body{padding-block:10px 12px;padding-inline:30px 14px;border-top:1px solid var(--rule)}
.faq-body p:last-child{margin-bottom:0}

/* On this page */
.onpage{flex:0 0 var(--onpage-w);width:var(--onpage-w);position:sticky;top:28px;align-self:flex-start;max-height:calc(100vh - 56px);overflow:auto;padding-inline-start:16px;border-inline-start:1px solid var(--rule);font-size:13px}
.onpage-title{font-size:10.5px;font-weight:600;letter-spacing:.14em;text-transform:uppercase;color:var(--muted);margin:4px 0 10px}
.onpage ol{list-style:none;margin:0;padding:0}
.onpage a{display:flex;align-items:baseline;gap:8px;padding:4px 0;padding-inline-start:15px;margin-inline-start:-17px;border-inline-start:2px solid transparent;color:var(--muted);text-decoration:none;line-height:1.4}
.onpage a:hover{color:var(--text)}
.onpage a.is-current{color:var(--accent);border-inline-start-color:var(--accent);font-weight:600}
.onpage-num{font-family:var(--font-mono);font-size:11.5px;min-width:28px;flex:0 0 auto;font-weight:400}

/* Back to top */
#to-top{position:fixed;bottom:28px;width:44px;height:44px;border:0;border-radius:50%;background:var(--ink);color:#fff;box-shadow:var(--shadow);cursor:pointer;display:flex;align-items:center;justify-content:center;opacity:0;transform:translateY(8px);pointer-events:none;transition:opacity .2s,transform .2s;z-index:5}
#to-top.is-visible{opacity:1;transform:none;pointer-events:auto}
#to-top:hover{background:var(--accent)}

/* Narrow screens */
@media (max-width:1180px){.onpage{display:none}}
@media (max-width:820px){
  .rail{position:static;width:auto;inset:auto;flex-direction:row;flex-wrap:wrap;align-items:center;gap:6px;padding:10px 12px;overflow:visible}
  .rail-head{flex:1 1 100%;padding:4px 6px 8px}
  .rail-subtitle,.rail-emblem,.rail-sub,.rail-foot,.rail-group-name{display:none}
  .rail-group{display:contents}
  .rail-link{padding:5px 11px;border-radius:999px;font-size:13px;background:rgba(255,255,255,.06);gap:7px}
  .rail-badge{padding:3px 6px}
  .page{margin-inline-start:0;padding-block:20px 72px;padding-inline:16px;gap:0}
  .reading{flex:1 1 auto;width:100%}
  .section-title{font-size:24px;gap:10px}
  .num-tile{min-width:40px;height:34px;font-size:13px}
  .flow-branches{grid-template-columns:1fr}
}

/* Print */
@media print{
  html,body{background:#fff}
  .rail,.onpage,.faq-tools,#faq-none,#to-top,.copy-btn,.code-more{display:none !important}
  .page{display:block;margin:0;padding:0}
  .reading{max-width:none}
  .guide-section[hidden]{display:block !important}
  .guide-section{break-before:page;page-break-before:always}
  .guide-section:first-of-type{break-before:auto;page-break-before:auto}
  .code{background:#fff;color:#000;border:1px solid #999}
  .code-bar{background:#eee;color:#000}
  .code.collapsed pre{max-height:none}
  .code.collapsed pre::after{display:none}
  .code pre{white-space:pre-wrap;overflow:visible}
  details.faq{break-inside:avoid;page-break-inside:avoid}
  details.faq summary::before{display:none}
  .card,.flow-node,.callout{break-inside:avoid;page-break-inside:avoid}
  a{color:inherit}
}
'@

# ---------------------------------------------------------------------------
# JavaScript
# ---------------------------------------------------------------------------
$Js = @'
(function () {
  'use strict';
  var S = JSON.parse(document.getElementById('guide-strings').textContent);
  var TOC = JSON.parse(document.getElementById('guide-toc').textContent);
  var body = document.body;
  var docEl = document.documentElement;
  var guideTitle = body.getAttribute('data-guide-title') || document.title;
  var firstId = body.getAttribute('data-first');
  var faqSectionId = body.getAttribute('data-faq') || '';
  var isRtl = (docEl.getAttribute('dir') === 'rtl');
  var sections = {};
  TOC.forEach(function (s) { sections[s.id] = s; });

  var reading = document.getElementById('reading');
  var onpage = document.getElementById('onpage');
  var onpageList = document.getElementById('onpage-list');
  var toTop = document.getElementById('to-top');

  var current = '';
  var landing = null;        /* { id, y } after navigating to a subsection */
  var LANDING_TOLERANCE = 40;
  var TOP_THRESHOLD = 600;

  function fmt(str, map) {
    return String(str || '').replace(/\{(\w+)\}/g, function (m, k) {
      return Object.prototype.hasOwnProperty.call(map, k) ? String(map[k]) : m;
    });
  }
  function slug(t) {
    return String(t).toLowerCase().replace(/[^a-z0-9\u0600-\u06FF]+/g, '-').replace(/^-+|-+$/g, '');
  }
  function decodeHash(h) {
    h = String(h || '').replace(/^#/, '');
    try { h = decodeURIComponent(h); } catch (e) { /* keep raw */ }
    return h;
  }
  function parseHash(h) {
    h = decodeHash(h);
    if (!h) { return { section: '', anchor: '' }; }
    var i = h.indexOf('/');
    if (i < 0) { return { section: h, anchor: '' }; }
    return { section: h.slice(0, i), anchor: h.slice(i + 1) };
  }
  function toArray(list) { return Array.prototype.slice.call(list || []); }
  function closest(el, sel) {
    while (el && el.nodeType === 1) {
      if (el.matches(sel)) { return el; }
      el = el.parentNode;
    }
    return null;
  }
  function topOffset() { return 8; }

  /* ---------------- routing ---------------- */
  function findAnchor(sec, anchor) {
    var el = document.getElementById(sec.id + '/' + anchor);
    if (el) { return el; }
    var want = slug(anchor);
    for (var i = 0; i < sec.items.length; i++) {
      var it = sec.items[i];
      if (it.num === anchor || it.id === sec.id + '/' + want || it.id.indexOf(sec.id + '/' + want + '-') === 0 || slug(it.title) === want) {
        return document.getElementById(it.id);
      }
    }
    return document.getElementById(anchor);
  }

  function buildOnPage(sec) {
    if (!onpage || !onpageList) { return; }
    onpageList.innerHTML = '';
    if (!sec.items.length) { onpage.setAttribute('hidden', ''); return; }
    onpage.removeAttribute('hidden');
    sec.items.forEach(function (it) {
      var li = document.createElement('li');
      var a = document.createElement('a');
      a.href = '#' + it.id;
      a.setAttribute('data-id', it.id);
      if (it.num) {
        var n = document.createElement('span');
        n.className = 'onpage-num';
        n.textContent = it.num;
        a.appendChild(n);
      }
      var t = document.createElement('span');
      t.textContent = it.title;
      a.appendChild(t);
      li.appendChild(a);
      onpageList.appendChild(li);
    });
  }

  function setCurrentHeading(id) {
    var links = toArray(document.querySelectorAll('.onpage a[data-id], .rail-sub a[data-id]'));
    links.forEach(function (a) {
      var on = (id && a.getAttribute('data-id') === id);
      a.classList.toggle('is-current', !!on);
      if (on) { a.setAttribute('aria-current', 'true'); } else { a.removeAttribute('aria-current'); }
    });
  }

  function route() {
    var h = parseHash(location.hash);
    var id = h.section;
    if (!sections[id]) { id = firstId; }
    var sec = sections[id];
    if (!sec) { return; }
    TOC.forEach(function (s) {
      var el = document.getElementById(s.id);
      if (!el) { return; }
      if (s.id === id) { el.removeAttribute('hidden'); } else { el.setAttribute('hidden', ''); }
    });
    current = id;
    document.title = sec.title + ' | ' + guideTitle;
    toArray(document.querySelectorAll('.rail-link')).forEach(function (a) {
      var on = (a.getAttribute('data-section') === id);
      a.classList.toggle('is-active', on);
      if (on) { a.setAttribute('aria-current', 'page'); } else { a.removeAttribute('aria-current'); }
    });
    buildOnPage(sec);
    var target = h.anchor ? findAnchor(sec, h.anchor) : null;
    if (target) {
      var y = Math.round(target.getBoundingClientRect().top + window.pageYOffset - topOffset());
      window.scrollTo(0, Math.max(0, y));
      landing = { id: target.id, y: window.pageYOffset };
      setCurrentHeading(target.id);
    } else {
      window.scrollTo(0, 0);
      landing = null;
      spy();
    }
    positionToTop();
    updateToTop();
  }

  /* ---------------- scroll spy ---------------- */
  function headingsOf(sec) {
    return sec.items.map(function (it) { return document.getElementById(it.id); }).filter(function (el) { return !!el; });
  }
  function spy() {
    var sec = sections[current];
    if (!sec) { return; }
    var hs = headingsOf(sec);
    if (!hs.length) { setCurrentHeading(''); return; }
    var y = window.pageYOffset;
    if (landing) {
      if (Math.abs(y - landing.y) <= LANDING_TOLERANCE) { setCurrentHeading(landing.id); return; }
      landing = null;
    }
    var atEnd = (window.innerHeight + y) >= (docEl.scrollHeight - 2);
    var cur = '';
    if (atEnd) {
      cur = hs[hs.length - 1].id;
    } else {
      var off = topOffset() + 4;
      for (var i = 0; i < hs.length; i++) {
        if (hs[i].getBoundingClientRect().top <= off) { cur = hs[i].id; }
      }
    }
    setCurrentHeading(cur);
  }

  /* ---------------- back to top ---------------- */
  function positionToTop() {
    if (!toTop || !reading) { return; }
    var r = reading.getBoundingClientRect();
    var size = 44, gap = 6, vw = docEl.clientWidth, fits = false;
    if (!isRtl) {
      var left = r.right + gap;
      fits = (left + size) <= (vw - 8);
      if (fits) { toTop.style.left = left + 'px'; toTop.style.right = 'auto'; }
    } else {
      var right = vw - r.left + gap;
      fits = (right + size) <= (vw - 8);
      if (fits) { toTop.style.right = right + 'px'; toTop.style.left = 'auto'; }
    }
    if (!fits) {
      if (!isRtl) { toTop.style.right = '16px'; toTop.style.left = 'auto'; }
      else { toTop.style.left = '16px'; toTop.style.right = 'auto'; }
    }
  }
  function updateToTop() {
    if (!toTop) { return; }
    toTop.classList.toggle('is-visible', window.pageYOffset > TOP_THRESHOLD);
  }
  function scrollToTopAnimated() {
    var start = window.pageYOffset;
    if (start <= 0) { return; }
    var duration = Math.min(900, 300 + start * 0.12);
    var t0 = null;
    function step(ts) {
      if (t0 === null) { t0 = ts; }
      var p = Math.min(1, (ts - t0) / duration);
      var e = 1 - Math.pow(1 - p, 3);
      window.scrollTo(0, Math.round(start * (1 - e)));
      if (p < 1) { window.requestAnimationFrame(step); }
    }
    window.requestAnimationFrame(step);
  }

  /* ---------------- clipboard ---------------- */
  function copyFallback(text) {
    var ta = document.createElement('textarea');
    ta.value = text;
    ta.setAttribute('readonly', '');
    ta.style.position = 'fixed';
    ta.style.top = '0';
    ta.style.left = '-9999px';
    ta.style.opacity = '0';
    document.body.appendChild(ta);
    ta.focus();
    ta.select();
    var ok = false;
    try { ok = document.execCommand('copy'); } catch (e) { ok = false; }
    document.body.removeChild(ta);
    return ok;
  }
  function copyText(text, done) {
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(function () { done(true); }, function () { done(copyFallback(text)); });
    } else {
      done(copyFallback(text));
    }
  }

  /* ---------------- FAQ ---------------- */
  var faq = null;
  function initFaq() {
    var input = document.getElementById('faq-search');
    if (!input) { return; }
    faq = {
      input: input,
      count: document.getElementById('faq-count'),
      none: document.getElementById('faq-none'),
      expand: document.getElementById('faq-expand'),
      optAll: document.getElementById('faq-opt-all'),
      optAnswers: document.getElementById('faq-opt-answers'),
      optWhole: document.getElementById('faq-opt-whole'),
      chips: toArray(document.querySelectorAll('.faq-chip')),
      cat: 'all',
      entries: toArray(document.querySelectorAll('details.faq')).map(function (d) {
        var sum = d.querySelector('summary');
        var bodyEl = d.querySelector('.faq-body');
        return { el: d, sum: sum, body: bodyEl, sumHtml: sum.innerHTML, bodyHtml: bodyEl ? bodyEl.innerHTML : '', marked: false, autoOpened: false, cat: d.getAttribute('data-cat') || '' };
      })
    };
    input.addEventListener('input', applyFaq);
    [faq.optAll, faq.optAnswers, faq.optWhole].forEach(function (cb) { if (cb) { cb.addEventListener('change', applyFaq); } });
    faq.chips.forEach(function (chip) {
      chip.addEventListener('click', function () {
        faq.cat = chip.getAttribute('data-cat') || 'all';
        faq.chips.forEach(function (c) {
          var on = (c === chip);
          c.classList.toggle('is-active', on);
          c.setAttribute('aria-pressed', on ? 'true' : 'false');
        });
        applyFaq();
      });
    });
    if (faq.expand) {
      faq.expand.addEventListener('click', function () {
        var v = visibleEntries();
        var all = allOpen(v);
        v.forEach(function (e) { e.el.open = !all; e.autoOpened = false; });
        updateExpandLabel();
      });
    }
    /* toggle does not bubble: listen in the capture phase */
    document.addEventListener('toggle', function (ev) {
      var t = ev.target;
      if (t && t.classList && t.classList.contains('faq')) { updateExpandLabel(); }
    }, true);
    applyFaq();
  }
  function escapeRe(s) { return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); }
  function wordRegex(words, whole) {
    var alt = words.map(escapeRe).join('|');
    var src = whole ? '(?<![\\p{L}\\p{N}_])(?:' + alt + ')(?![\\p{L}\\p{N}_])' : '(?:' + alt + ')';
    try { return new RegExp(src, 'giu'); }
    catch (e) { return new RegExp(whole ? '\\b(?:' + alt + ')\\b' : '(?:' + alt + ')', 'gi'); }
  }
  function visibleEntries() { return faq ? faq.entries.filter(function (e) { return !e.el.hidden; }) : []; }
  function allOpen(list) { return list.length > 0 && list.every(function (e) { return e.el.open; }); }
  function updateExpandLabel() {
    if (!faq || !faq.expand) { return; }
    var v = visibleEntries();
    var all = allOpen(v);
    faq.expand.textContent = all ? S.collapseAll : S.expandAll;
    faq.expand.setAttribute('aria-expanded', all ? 'true' : 'false');
    faq.expand.disabled = (v.length === 0);
  }
  function highlight(root, re) {
    var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, null, false);
    var nodes = [];
    while (walker.nextNode()) { nodes.push(walker.currentNode); }
    nodes.forEach(function (node) {
      var text = node.nodeValue;
      re.lastIndex = 0;
      if (!re.test(text)) { return; }
      re.lastIndex = 0;
      var frag = document.createDocumentFragment();
      var last = 0, m;
      while ((m = re.exec(text)) !== null) {
        if (m.index > last) { frag.appendChild(document.createTextNode(text.slice(last, m.index))); }
        var mark = document.createElement('mark');
        mark.textContent = m[0];
        frag.appendChild(mark);
        last = m.index + m[0].length;
        if (m[0].length === 0) { re.lastIndex++; }
      }
      if (last < text.length) { frag.appendChild(document.createTextNode(text.slice(last))); }
      node.parentNode.replaceChild(frag, node);
    });
  }
  function applyFaq() {
    if (!faq) { return; }
    var query = faq.input.value.trim();
    var words = query ? query.split(/\s+/) : [];
    var matchAll = faq.optAll ? faq.optAll.checked : true;
    var answers = faq.optAnswers ? faq.optAnswers.checked : true;
    var whole = faq.optWhole ? faq.optWhole.checked : false;
    var perWord = words.map(function (w) { return wordRegex([w], whole); });
    var hiRe = words.length ? wordRegex(words, whole) : null;
    var shown = 0;
    faq.entries.forEach(function (e) {
      if (e.marked) { e.sum.innerHTML = e.sumHtml; if (e.body) { e.body.innerHTML = e.bodyHtml; } e.marked = false; }
      var inCat = (faq.cat === 'all' || e.cat === faq.cat);
      var hit = true;
      if (words.length) {
        var text = e.sum.textContent + (answers && e.body ? '\n' + e.body.textContent : '');
        var tests = perWord.map(function (re) { re.lastIndex = 0; return re.test(text); });
        hit = matchAll ? tests.every(Boolean) : tests.some(Boolean);
      }
      var visible = inCat && hit;
      e.el.hidden = !visible;
      if (visible) {
        shown++;
        if (hiRe) {
          highlight(e.sum, hiRe);
          if (answers && e.body) { highlight(e.body, hiRe); }
          e.marked = true;
          if (!e.el.open) { e.el.open = true; e.autoOpened = true; }
        } else if (e.autoOpened) {
          e.el.open = false;
          e.autoOpened = false;
        }
      }
    });
    if (faq.count) { faq.count.textContent = fmt(S.resultCounter, { shown: shown, total: faq.entries.length }); }
    if (faq.none) { faq.none.hidden = (shown > 0); }
    updateExpandLabel();
  }
  function focusFaqSearch() {
    if (!faq) { return; }
    if (current !== faqSectionId && faqSectionId) {
      if (decodeHash(location.hash) === faqSectionId) { route(); } else { location.hash = '#' + faqSectionId; route(); }
    }
    faq.input.focus();
    faq.input.select();
  }

  /* ---------------- events ---------------- */
  document.addEventListener('click', function (ev) {
    var btn = closest(ev.target, '.copy-btn');
    if (btn) {
      var box = closest(btn, '.code');
      var code = box ? box.querySelector('pre code') : null;
      if (code) {
        copyText(code.textContent, function () {
          btn.textContent = S.copied;
          btn.classList.add('is-done');
          window.setTimeout(function () { btn.textContent = S.copy; btn.classList.remove('is-done'); }, 1500);
        });
      }
      return;
    }
    var more = closest(ev.target, '.code-more');
    if (more) {
      var cbox = closest(more, '.code');
      var hidden = parseInt(cbox.getAttribute('data-hidden'), 10) || 0;
      var collapsed = cbox.classList.toggle('collapsed');
      more.textContent = collapsed ? fmt(S.showMore, { n: hidden }) : S.showFewer;
      more.setAttribute('aria-expanded', collapsed ? 'false' : 'true');
      return;
    }
    if (toTop && closest(ev.target, '#to-top')) {
      landing = null;
      scrollToTopAnimated();
      return;
    }
    var a = closest(ev.target, 'a[href]');
    if (!a) { return; }
    var href = a.getAttribute('href') || '';
    if (href.charAt(0) !== '#' || href.length < 2) { return; }
    /* same-hash click: browsers fire no hashchange, so re-run the router */
    if (decodeHash(href) === decodeHash(location.hash)) {
      ev.preventDefault();
      route();
    }
  });

  window.addEventListener('hashchange', route);

  var ticking = false;
  window.addEventListener('scroll', function () {
    if (ticking) { return; }
    ticking = true;
    window.requestAnimationFrame(function () { ticking = false; spy(); updateToTop(); });
  }, { passive: true });

  var resizing = false;
  window.addEventListener('resize', function () {
    if (resizing) { return; }
    resizing = true;
    window.requestAnimationFrame(function () { resizing = false; positionToTop(); });
  });

  document.addEventListener('keydown', function (ev) {
    if (ev.key !== '/' || ev.ctrlKey || ev.metaKey || ev.altKey) { return; }
    var t = ev.target;
    var tag = (t && t.tagName) ? t.tagName.toLowerCase() : '';
    if (tag === 'input' || tag === 'textarea' || tag === 'select' || (t && t.isContentEditable)) { return; }
    if (!faq) { return; }
    ev.preventDefault();
    focusFaqSearch();
  });

  /* print: open every FAQ entry, restore afterwards */
  var printState = null;
  window.addEventListener('beforeprint', function () {
    printState = toArray(document.querySelectorAll('details.faq')).map(function (d) { var was = d.open; d.open = true; return { el: d, open: was }; });
  });
  window.addEventListener('afterprint', function () {
    if (!printState) { return; }
    printState.forEach(function (s) { s.el.open = s.open; });
    printState = null;
  });

  if (toTop && S.backToTop) { toTop.setAttribute('aria-label', S.backToTop); toTop.setAttribute('title', S.backToTop); }
  initFaq();
  route();
  positionToTop();
  updateToTop();
})();
'@

# ---------------------------------------------------------------------------
# Assemble the document
# ---------------------------------------------------------------------------
$Css = $Css.Replace('__COLLAPSE__', [string]$CollapseAfter)
$StringsJson = ConvertTo-SafeJson $S
$TocJsonText = ConvertTo-SafeJson $TocJson
$subtitleHtml = ''
if ($Subtitle.Length -gt 0) { $subtitleHtml = '<div class="rail-subtitle">' + (ConvertTo-HtmlText $Subtitle) + '</div>' }
$onThisPage = ConvertTo-HtmlText (Get-Prop $S 'onThisPage' 'On this page')
$backToTop = ConvertTo-AttrText (Get-Prop $S 'backToTop' 'Back to top')
$upArrow = '<svg viewBox="0 0 20 20" width="20" height="20" aria-hidden="true" focusable="false"><path d="M10 16V4M4 10l6-6 6 6" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>'

$doc = New-Object System.Text.StringBuilder
[void]$doc.Append('<!DOCTYPE html>' + "`n")
[void]$doc.Append('<html lang="' + (ConvertTo-AttrText $Lang) + '" dir="' + $Dir + '">' + "`n<head>`n")
[void]$doc.Append('<meta charset="utf-8">' + "`n")
[void]$doc.Append('<meta name="viewport" content="width=device-width, initial-scale=1">' + "`n")
[void]$doc.Append('<meta name="generator" content="Build-UserGuide.ps1">' + "`n")
[void]$doc.Append('<title>' + (ConvertTo-HtmlText $GuideTitle) + '</title>' + "`n")
[void]$doc.Append($IconLinks)
[void]$doc.Append("<style>`n" + $Css + "`n</style>`n</head>`n")
[void]$doc.Append('<body data-first="' + $FirstId + '" data-faq="' + $FaqSectionId + '" data-guide-title="' + (ConvertTo-AttrText $GuideTitle) + '">' + "`n")
[void]$doc.Append('<nav class="rail" aria-label="' + (ConvertTo-AttrText $GuideTitle) + '">' + "`n")
[void]$doc.Append('<div class="rail-head"><div class="rail-title">' + (ConvertTo-HtmlText $GuideTitle) + '</div>' + $subtitleHtml + '</div>' + "`n")
[void]$doc.Append($EmblemHtml + "`n")
[void]$doc.Append($RailGroupsHtml + "`n")
[void]$doc.Append('<div class="rail-foot"><div class="rail-hint">' + $hintHtml + '</div><div class="rail-copy">' + $CopyrightHtml + '</div></div>' + "`n")
[void]$doc.Append("</nav>`n")
[void]$doc.Append('<div class="page">' + "`n" + '<main class="reading" id="reading">' + "`n")
[void]$doc.Append($mainSb.ToString())
[void]$doc.Append("</main>`n")
[void]$doc.Append('<aside class="onpage" id="onpage" aria-label="' + $onThisPage + '"><div class="onpage-title">' + $onThisPage + '</div><ol id="onpage-list"></ol></aside>' + "`n")
[void]$doc.Append("</div>`n")
[void]$doc.Append('<button type="button" id="to-top" aria-label="' + $backToTop + '" title="' + $backToTop + '">' + $upArrow + '</button>' + "`n")
[void]$doc.Append('<script type="application/json" id="guide-strings">' + $StringsJson + '</script>' + "`n")
[void]$doc.Append('<script type="application/json" id="guide-toc">' + $TocJsonText + '</script>' + "`n")
[void]$doc.Append("<script>`n" + $Js + "`n</script>`n")
[void]$doc.Append("</body>`n</html>`n")

$outDir = Split-Path -Parent $OutputPath
if (-not (Test-Path -LiteralPath $outDir)) { [void](New-Item -ItemType Directory -Path $outDir -Force) }
$html = $doc.ToString()
[System.IO.File]::WriteAllText($OutputPath, $html, $Utf8)

$sizeBytes = (Get-Item -LiteralPath $OutputPath).Length
Write-Host ('Wrote ' + $OutputPath)
Write-Host ('  size:     ' + $sizeBytes.ToString('N0') + ' bytes (' + [math]::Round($sizeBytes / 1024.0, 1) + ' KB)')
Write-Host ('  sections: ' + $Rendered.Count)
Write-Host ('  FAQ:      ' + $TotalFaq + ' entries')
