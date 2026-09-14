#requires -Version 5.1
<#
.SYNOPSIS
    Cut a GitHub release: run the tests, tag, publish BOTH assets.

.DESCRIPTION
    Publishing is a DEPLOYMENT, not just an upload. The shipped .bat carries no payload -
    it downloads alleaves_setup.ps1 from `releases/latest/download` on every run
    (docs/BUILD-BAT.md#fetch), so the .ps1 published here is what every terminal already
    in the field executes on its next run. There is no pin lever; roll back by deleting
    the bad release, which re-points `latest` at the previous one:

        gh release delete vX.Y.Z

    Both files are uploaded. Shipping the .bat without the .ps1 makes every stub 404.

    One public repo serves both the source and the assets (docs/BUILD-BAT.md#dist-repo), so
    `gh` resolves it from `origin` and no --repo flag is needed. The permanent link is
    https://github.com/nightious/Alleaves-Auto/releases/latest/download/Install-Alleaves.bat

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

function Fail($m) { Write-Host "[FAIL] $m" -ForegroundColor Red; exit 1 }
function Step($m) { Write-Host "`n=== $m ===" -ForegroundColor Cyan }

if (git tag -l $Version) { Fail "tag $Version already exists." }

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
if ($dirty) { Fail "working tree is dirty - commit first. The .ps1 uploaded below IS the deployment, so it must be the committed one:`n$dirty" }

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

# No --repo: gh resolves it from origin, which is also where the assets belong.
# This repo must stay PUBLIC or every installer in the field breaks. docs/BUILD-BAT.md#dist-repo
gh release create $Version Install-Alleaves.bat alleaves_setup.ps1 --title $Version --notes $Notes
if ($LASTEXITCODE -ne 0) { Fail "gh release create failed. The tag is pushed; re-run just: gh release create $Version Install-Alleaves.bat alleaves_setup.ps1" }

Write-Host "`nReleased $Version" -ForegroundColor Green
gh release view $Version --json url --jq .url
