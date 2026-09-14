<#
.SYNOPSIS
    Self-check: the docs/ pointer web still resolves both ways.
    Why: comments in the scripts are pointers only (CLAUDE.md), so a renamed
    anchor silently turns a pointer into a dead end and a deleted pointer
    silently orphans a doc section.

    Asserts:
      1. every docs/<FILE>.md#<anchor> cited anywhere resolves to a real anchor
      2. every anchor declared in docs/ is cited at least once

    A citation may name the anchor in full (docs/<FILE>.md#<a>) or, on a line that
    already names the doc, as a bare #a - both forms are resolved here so the
    comments stay readable.

        PowerShell -ExecutionPolicy Bypass -File .\tests\Test-DocLinks.ps1
    Exits 0 on pass, 1 on failure.
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')

$Root    = Split-Path $PSScriptRoot -Parent
$DocsDir = Join-Path $Root 'docs'
if (-not (Test-Path $DocsDir)) { Write-Host "no docs/ directory at $DocsDir" -ForegroundColor Red; exit 1 }

# GitHub's heading -> anchor slug, after stripping any inline <a id> tag.
function ConvertTo-Slug($heading) {
    $t = $heading -replace '<a\s+id="[^"]*"></a>', ''
    $t = $t -replace '[`*_\[\]()]', ''
    $t = $t.Trim().ToLowerInvariant()
    $t = $t -replace '[^\w\s-]', ''
    return ($t -replace '\s+', '-')
}

# --- what the docs DECLARE -------------------------------------------------
$declared = @{}   # 'docs/<FILE>.md' -> hashtable of anchor -> $true
$explicit = @{}   # same, but only <a id> anchors (these are the ones code cites)
foreach ($f in Get-ChildItem $DocsDir -Filter *.md) {
    $key = "docs/$($f.Name)"
    $declared[$key] = @{}
    $explicit[$key] = @{}
    foreach ($line in [IO.File]::ReadAllLines($f.FullName)) {
        foreach ($m in [regex]::Matches($line, '<a\s+id="([^"]+)"></a>')) {
            $declared[$key][$m.Groups[1].Value.ToLowerInvariant()] = $true
            $explicit[$key][$m.Groups[1].Value.ToLowerInvariant()] = $true
        }
        if ($line -match '^#{1,6}\s+(.*?)\s*$') {
            $slug = ConvertTo-Slug $Matches[1]
            if ($slug) { $declared[$key][$slug] = $true }
        }
    }
}

# --- what the tree CITES ---------------------------------------------------
# Install-Alleaves.bat is skipped: it is generated, and its pointers come from build-bat.ps1.
$sources = @()
$sources += Get-ChildItem $Root -Filter *.ps1
$sources += Get-ChildItem (Join-Path $Root 'tests')   -Filter *.ps1 -ErrorAction SilentlyContinue
$sources += Get-ChildItem (Join-Path $Root 'printer') -Filter *.ps1 -ErrorAction SilentlyContinue
$sources += Get-ChildItem $Root -Filter *.md
$sources += Get-ChildItem $DocsDir -Filter *.md

$cited     = @{}   # "docs/<FILE>.md#<a>" -> $true
$citedByPs = @{}   # same, restricted to .ps1 sources
$broken    = @()
foreach ($f in $sources) {
    $isPs = $f.Extension -eq '.ps1'
    $self = if ($f.DirectoryName -eq $DocsDir) { "docs/$($f.Name)" } else { $null }
    $n = 0
    foreach ($line in [IO.File]::ReadAllLines($f.FullName)) {
        $n++
        # Full refs in .ps1 comments, plus (OTHER.md#a) / (#a) markdown links inside docs/.
        $onLine = @()
        foreach ($m in [regex]::Matches($line, 'docs/([A-Za-z0-9_.\-]+\.md)(?:#([A-Za-z0-9\-_]+))?')) {
            $doc = "docs/$($m.Groups[1].Value)"
            $onLine += $doc
            if ($m.Groups[2].Success) {
                $ref = "$doc#$($m.Groups[2].Value.ToLowerInvariant())"
                $cited[$ref] = $true
                if ($isPs) { $citedByPs[$ref] = $true }
                if (-not $declared.ContainsKey($doc) -or -not $declared[$doc].ContainsKey($m.Groups[2].Value.ToLowerInvariant())) {
                    $broken += "$($f.Name):$n -> $ref"
                }
            } elseif (-not $declared.ContainsKey($doc)) {
                $broken += "$($f.Name):$n -> $doc (no such file)"
            }
        }
        # Markdown links from inside docs/: (OTHER.md#a) or same-file (#a).
        if (-not $isPs) {
            foreach ($m in [regex]::Matches($line, '\(([A-Za-z0-9_.\-]+\.md)?#([A-Za-z0-9\-_]+)\)')) {
                $doc = if ($m.Groups[1].Success) { "docs/$($m.Groups[1].Value)" } else { $self }
                if (-not $doc) { continue }
                $ref = "$doc#$($m.Groups[2].Value.ToLowerInvariant())"
                $cited[$ref] = $true
                if (-not $declared.ContainsKey($doc) -or -not $declared[$doc].ContainsKey($m.Groups[2].Value.ToLowerInvariant())) {
                    $broken += "$($f.Name):$n -> $ref"
                }
            }
        }
        # Shorthand in a .ps1 comment: a bare #anchor on a line that already names a doc.
        if ($isPs -and $onLine.Count) {
            $rest = $line -replace 'docs/[A-Za-z0-9_.\-]+\.md(#[A-Za-z0-9\-_]+)?', ''
            foreach ($m in [regex]::Matches($rest, '(?<![\w/])#([a-z][a-z0-9\-]{2,})')) {
                $ref = "$($onLine[0])#$($m.Groups[1].Value)"
                $cited[$ref] = $true
                $citedByPs[$ref] = $true
                if (-not $declared[$onLine[0]].ContainsKey($m.Groups[1].Value)) {
                    $broken += "$($f.Name):$n -> $ref (shorthand)"
                }
            }
        }
    }
}

Write-Host "`nEvery docs/<FILE>.md#<anchor> reference resolves" -ForegroundColor Cyan
if ($broken.Count) { $broken | ForEach-Object { Write-Host "       $_" -ForegroundColor DarkGray } }
Assert-Eq 0 $broken.Count 'no dangling doc references'

Write-Host "`nEvery declared anchor is cited somewhere" -ForegroundColor Cyan
$orphans = @()
# .get_Keys()/.get_Count(), not .Keys/.Count: a hashtable holding a key named 'keys' (MANIFEST.md
# declares one) shadows the property and hands back that entry's VALUE instead of the collection.
foreach ($doc in $explicit.get_Keys()) {
    foreach ($a in $explicit[$doc].get_Keys()) {
        if (-not $cited.ContainsKey("$doc#$a")) { $orphans += "$doc#$a" }
    }
}
if ($orphans.Count) { $orphans | Sort-Object | ForEach-Object { Write-Host "       $_" -ForegroundColor DarkGray } }
Assert-Eq 0 $orphans.Count 'no orphaned <a id> anchors'

$total = ($explicit.get_Values() | ForEach-Object { $_.get_Count() } | Measure-Object -Sum).Sum
Write-Host ''
Write-Host "  $total explicit anchors, $($citedByPs.get_Count()) cited from a .ps1" -ForegroundColor DarkGray

Write-Host ''
if ($script:Failures) { Write-Host "$($script:Failures) failure(s)" -ForegroundColor Red; exit 1 }
Write-Host 'all checks passed' -ForegroundColor Green
exit 0
