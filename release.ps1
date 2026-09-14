#requires -Version 5.1
<#
.SYNOPSIS
    Cut a GitHub release: rebuild Install-Alleaves.bat, run the tests, tag, publish.

.DESCRIPTION
    The .bat is the whole deliverable, so it is rebuilt here instead of trusted from
    the tree. If the rebuild changes it, the working tree goes dirty and the release
    aborts - that is the "forgot to run build-bat.ps1" guard, caught before anyone
    downloads a .bat built from stale source.

    The tag goes on this (private) repo; the asset is published to the public dist repo,
    landing at the permanent link
    https://github.com/nightious/Alleaves-Install/releases/latest/download/Install-Alleaves.bat

    Needs the gh CLI, authenticated (gh auth status).

        .\release.ps1 -Version v1.2.0
        .\release.ps1 -Version v1.2.0 -Notes 'Printer brand prompt.'

.PARAMETER Version
    Release tag, v<major>.<minor>.<patch>.

.PARAMETER Notes
    Release body. Defaults to the commit subjects since the previous tag.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^v\d+\.\d+\.\d+$')][string]$Version,
    [string]$Notes
)

$ErrorActionPreference = 'Continue'   # native stderr is not a failure; $LASTEXITCODE is
Set-Location $PSScriptRoot

$DistRepo = 'nightious/Alleaves-Install'   # docs/BUILD-BAT.md#dist-repo

function Fail($m) { Write-Host "[FAIL] $m" -ForegroundColor Red; exit 1 }
function Step($m) { Write-Host "`n=== $m ===" -ForegroundColor Cyan }

if (git tag -l $Version) { Fail "tag $Version already exists." }

Step 'Rebuild Install-Alleaves.bat'
& .\build-bat.ps1
if ($LASTEXITCODE -ne 0) { Fail 'build-bat.ps1 failed - not releasing.' }

Step 'Tests'
# Count first: an empty tests\ makes the loop body never run and the gate pass vacuously.
$tests = @(Get-ChildItem .\tests -Filter 'Test-*.ps1' -ErrorAction SilentlyContinue | Sort-Object Name)
if ($tests.Count -lt 5) { Fail "expected 5 tests in tests\, found $($tests.Count) - not releasing." }
foreach ($t in $tests) {
    $LASTEXITCODE = 99   # poison: a test that dies before its own exit must not read as a pass
    & $t.FullName | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail "$($t.Name) failed - not releasing." }
    Write-Host "  ok   $($t.Name)" -ForegroundColor Green
}

$dirty = git status --porcelain
if ($dirty) { Fail "working tree is dirty - commit first. A rebuilt .bat here means the committed one was stale:`n$dirty" }

if (-not $Notes) {
    $prev  = git describe --tags --abbrev=0 2>$null
    $range = if ($LASTEXITCODE -eq 0 -and $prev) { "$prev..HEAD" } else { 'HEAD' }
    $Notes = (git log --no-merges --pretty='- %s' $range) -join "`n"
}
# PS 5.1 drops an empty string from a native command line, so gh would see --notes --title.
if (-not $Notes) { $Notes = $Version }

Step "Publish $Version"
git tag -a $Version -m "Alleaves installer $Version"
if ($LASTEXITCODE -ne 0) { Fail 'git tag failed.' }
git push origin $Version
if ($LASTEXITCODE -ne 0) { git tag -d $Version | Out-Null; Fail 'git push failed - local tag removed.' }

gh release create $Version Install-Alleaves.bat --repo $DistRepo --title $Version --notes $Notes
if ($LASTEXITCODE -ne 0) { Fail "gh release create failed. The tag is pushed; re-run just: gh release create $Version Install-Alleaves.bat --repo $DistRepo" }

Write-Host "`nReleased $Version" -ForegroundColor Green
gh release view $Version --repo $DistRepo --json url --jq .url
