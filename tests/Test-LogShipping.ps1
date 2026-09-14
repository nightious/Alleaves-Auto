<#
.SYNOPSIS
    Self-check: the Slack run summary is a well-formed Block Kit payload, stays
    inside Slack's per-section budget, redacts the license key, and names what
    actually failed. Why: docs/LOG-SHIPPING.md#payload

    Format-RunSummary is lifted and RUN (it is pure by design so this is possible).
    Send-RunSummary is only AST-asserted - it posts.

        PowerShell -ExecutionPolicy Bypass -File .\tests\Test-LogShipping.ps1
    Exits 0 on pass, 1 on failure.
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')

$ast   = Get-InstallerAst
$funcs = Get-InstallerFunctions $ast
Assert-InstallerHas $funcs @('Get-ResultTally', 'Get-FailedRows', 'Format-Elapsed',
                             'Format-RunSummary', 'Send-RunSummary')
foreach ($n in @('Get-ResultTally', 'Get-FailedRows', 'Format-Elapsed', 'Format-RunSummary')) {
    . ([scriptblock]::Create($funcs[$n].Extent.Text))
}

function Get-Json($payload) { $payload | ConvertTo-Json -Depth 10 -Compress }

Write-Host "`nGet-ResultTally counts by result" -ForegroundColor Cyan
$rows = @(@{name='a'; result='ok'}, @{name='b'; result='ok'}, @{name='c'; result='fail-extract'},
          @{name='d'}, $null)
Assert-Eq "1 fail-extract`n2 ok" (Get-ResultTally $rows) 'counts, sorted, one per line'
Assert-Eq '' (Get-ResultTally @()) 'an empty list tallies to nothing'

Write-Host "`nGet-FailedRows names only real failures" -ForegroundColor Cyan
$mixed = @(@{name='Chrome'; result='ok'}, @{name='TeamViewer'; result='fail-extract'},
           @{name='Zebra'; result='skipped:flag'}, @{logicalName='POS_Printer'; result='not-captured'})
Assert-Eq 'TeamViewer (fail-extract), POS_Printer (not-captured)' ((Get-FailedRows $mixed) -join ', ') `
    'ok and skipped:* are not failures; logicalName is used when there is no name'
Assert-Eq '' ((Get-FailedRows @(@{name='VC++'; result='already-present'}) -OkResults @('ok','already-present')) -join ', ') `
    'already-present counts as ok for dependencies'

Write-Host "`nFormat-Elapsed reads as a duration, not a clock" -ForegroundColor Cyan
Assert-Eq '4m 12s' (Format-Elapsed ([timespan]::FromSeconds(252)))  'under an hour'
Assert-Eq '1h 04m' (Format-Elapsed ([timespan]::FromMinutes(64)))   'over an hour'

# A deliberately fat run: more rows and more tail than any real terminal produces.
$fat = @{
    user = 'alleaves'; dryRun = $false
    installed    = @(1..200 | ForEach-Object { @{ name = "product-$_"; result = 'ok' } }) +
                   @(@{ name = 'TeamViewer'; result = 'fail-extract' })
    dependencies = @(1..20  | ForEach-Object { @{ name = "dep-$_";     result = 'already-present' } })
    # Each list carries its own success code next to a real failure: docs/LOG-SHIPPING.md#payload
    scannerConfigured = @(@{ model = 'DS2208'; result = 'already-opos' },
                          @{ model = 'DS9308'; result = 'fail' })
    printerConfigured = @(@{ logicalName = 'POS_Printer';   result = 'already-configured' },
                          @{ logicalName = 'Cash_Drawer';   result = 'not-captured' })
    computerRenamed   = @{ from = 'DESKTOP-8F2K1'; to = 'TILL-03'; applied = $true }
}
$longTail  = (1..2000 | ForEach-Object { "line $_ of transcript output that is reasonably wide" }) -join "`n"
$manyFails = @(1..200 | ForEach-Object { "  [FAIL] step $_ failed for some reasonably wordy reason" })

Write-Host "`nThe payload is shaped the way Slack demands" -ForegroundColor Cyan
$p = Format-RunSummary -ExitCode 1 -Terminal 'TILL-03' -Mode 'install' `
                       -RunLog 'C:\ProgramData\AlleavesAuto\logs\install_20260914_053012.log' `
                       -Elapsed '4m 12s' -RunManifest $fat -FailLines $manyFails -Tail $longTail
$json = Get-Json $p
# A one-element array that serialized as an object would be rejected by Slack and invisible here.
Assert-Eq $true ($json -match '"attachments":\[\{') 'attachments is still an ARRAY, not an object'
Assert-Eq $false ($json -match 'System\.Collections\.Hashtable') 'nothing was flattened by a shallow depth'
# The rail renders for legacy attachment fields and NOT for blocks: docs/LOG-SHIPPING.md#colour
Assert-Eq $false ($json -match '"blocks"') 'no Block Kit blocks - they silently suppress the colour rail'
Assert-Eq $true ($p.attachments[0].fallback.Length -gt 0) 'a fallback is set for the notification'

Write-Host "`nThe card stays inside Slack's limits" -ForegroundColor Cyan
Assert-Eq 2 $p.attachments.Count 'a failure renders as summary card + detail card'
Assert-Eq $true ($p.attachments[0].title -match 'TILL-03' -and $p.attachments[0].title -match 'failed') `
    "the title names the terminal and how the run ended (got '$($p.attachments[0].title)')"
$fields = $p.attachments[0].fields
Assert-Eq $true (@($fields | Where-Object { -not $_.short }).Count -eq 0) 'every field is short, so they pair into 2 columns'
Assert-Eq 'Result' $fields[0].title 'the grid leads with the result'
Assert-Eq $true ($p.attachments[1].text.Length -le 9000) "the detail card stays sane (got $($p.attachments[1].text.Length))"
Assert-Eq 1 (Format-RunSummary -ExitCode 0 -Terminal 'T' -RunManifest @{user='x'}).attachments.Count `
    'a clean run with nothing to report is a single card'

Write-Host "`nThe rail colour tracks the outcome" -ForegroundColor Cyan
Assert-Eq 'danger' $p.attachments[0].color 'exit 1 is red'
Assert-Eq 'good'    (Format-RunSummary -ExitCode 0 -Terminal 'T' -RunManifest $fat).attachments[0].color 'exit 0 is green'
Assert-Eq 'warning' (Format-RunSummary -ExitCode 6 -Terminal 'T' -RunManifest $fat).attachments[0].color 'exit 6 is yellow'
Assert-Eq 'danger'  (Format-RunSummary -ExitCode 1 -Terminal 'T' -RunManifest $fat).attachments[0].color 'exit 1 is red'

Write-Host "`nThe failing product is named, not just counted" -ForegroundColor Cyan
Assert-Eq $true ($json -match 'TeamViewer \(fail-extract\)') 'the failed product is called out by name'
# The regression this change exists to fix: a failure only visible EARLY in the log.
$early = Format-RunSummary -ExitCode 1 -Terminal 'TILL-03' -RunManifest $fat `
                           -FailLines @('  [FAIL] download phase failed: mirror unreachable') `
                           -Tail "late line A`nlate line B"
Assert-Eq $true ((Get-Json $early) -match 'mirror unreachable') `
    'a failure early in the log still surfaces, even though the tail has moved past it'

# The detail card is a few blank-line-separated blocks; pull one out by its heading.
$blockOf = { param($payload, $head) ($payload.attachments[1].text -split "`n`n" |
                                     Where-Object { $_.StartsWith($head) }) -join '' }

Write-Host "`nA success code is never named as a failure" -ForegroundColor Cyan
# already-opos and already-configured are how the scanner and printer record 'nothing to do' -
# the same two codes the config-only 'did anything change' check treats as success.
$failed = & $blockOf $p '*Failed*'
Assert-Eq $false ($failed -match 'DS2208')            'a scanner already on USB-OPOS is not a failure'
Assert-Eq $false ($failed -match 'POS_Printer')       'a printer already registered for OPOS is not a failure'
Assert-Eq $true  ($failed -match 'DS9308 \(fail\)')   'a scanner that really failed is still named'
Assert-Eq $true  ($failed -match 'Cash_Drawer \(not-captured\)') 'a printer that really failed is still named'

Write-Host "`nA JSON round-tripped manifest formats the same as a hashtable" -ForegroundColor Cyan
# The run snapshot IS a ConvertTo-Json round trip, so the formatter is handed PSCustomObjects in
# production and hashtables here. docs/ARCHITECTURE.md#tally-snapshot-ordering
$obj = Format-RunSummary -ExitCode 1 -Terminal 'TILL-03' -Mode 'install' `
                         -RunLog 'C:\ProgramData\AlleavesAuto\logs\install_20260914_053012.log' `
                         -Elapsed '4m 12s' -FailLines $manyFails -Tail $longTail `
                         -RunManifest ($fat | ConvertTo-Json -Depth 6 | ConvertFrom-Json)
$grid = { param($payload) (($payload.attachments[0].fields |
                            ForEach-Object { "$($_.title)=$($_.value)" }) -join ' | ') }
Assert-Eq (& $grid $p) (& $grid $obj) 'the field grid is identical on a PSCustomObject manifest'
Assert-Eq $failed (& $blockOf $obj '*Failed*') 'the named failures are identical on a PSCustomObject manifest'

Write-Host "`nThe license key never leaves the terminal" -ForegroundColor Cyan
$key  = 'FXQWA-6CPFD-ST4FB-TWTCZ-HMUMB'
$leak = Get-Json (Format-RunSummary -ExitCode 1 -Terminal 'TILL-03' -RunManifest $fat `
                  -FailLines @("  [FAIL] setup.exe /s LICENSECODE=$key") `
                  -Tail "running: setup.exe /s LICENSECODE=$key`nnext line")
Assert-Eq $false ($leak -match [regex]::Escape($key)) 'the raw LICENSECODE value is gone'
Assert-Eq $true  ($leak -match 'LICENSECODE=\*\*\*')  'it is replaced, not just dropped'
Assert-Eq 2 ([regex]::Matches($leak, 'LICENSECODE=\*\*\*').Count) 'BOTH the tail and the flagged lines are redacted'

Write-Host "`nA tail rides along only on failure" -ForegroundColor Cyan
$clean = Get-Json (Format-RunSummary -ExitCode 0 -Terminal 'TILL-03' -RunManifest $fat -Tail $longTail)
Assert-Eq $false ($clean -match 'line 2000')  'exit 0 carries no tail'
Assert-Eq $true  ($clean -match 'exit 0 - ok') 'exit 0 is spelled out'
Assert-Eq $true  ($clean -match 'white_check_mark') 'exit 0 is green-ticked'
Assert-Eq $true  ($clean -match 'TILL-03') 'the renamed name is used, not the OEM name'
Assert-Eq $true  ($json -match 'line 2000')   'a failure DOES carry the tail'
Assert-Eq $false ($json -match 'line 1 of')   'the tail is trimmed from the TOP - newest output survives'

# One [FAIL] line carrying a full argument dump is plausibly longer than the whole budget, and
# the failure mode of dropping it is silence. 12000 is past the hard ceiling, so it MUST clamp.
$oneLiner = Format-RunSummary -ExitCode 1 -Terminal 'TILL-03' -RunManifest $fat -Tail ('x' * 12000)
$block    = & $blockOf $oneLiner '*Log tail*'
Assert-Eq $true ($block.Length -gt 0) 'a tail of ONE line longer than the budget still ships a tail block'
Assert-Eq $true ($block.Length -lt 12000) "that oversized line is clamped, not sent whole (got $($block.Length))"

# Slack silently truncates legacy attachment text at 8000 chars - MEASURED, not documented.
# Everything maxed at once is the only case that can reach it. docs/LOG-SHIPPING.md#payload
Write-Host "`nThe detail card stays under Slack's 8000-char cliff" -ForegroundColor Cyan
$maxed = Format-RunSummary -ExitCode 1 -Terminal 'TILL-03' -RunManifest $fat `
                           -FailLines $manyFails -Tail $longTail
Assert-Eq $true ($maxed.attachments[1].text.Length -le 7990) `
    "everything maxed at once still fits (got $($maxed.attachments[1].text.Length))"
Assert-Eq $true ((& $blockOf $maxed '*Log tail*').Length -gt 0) `
    'and the tail is not the thing squeezed out to get there'

Write-Host "`nFormat-RunSummary survives a run with no manifest" -ForegroundColor Cyan
$bare = Format-RunSummary -ExitCode 1 -Terminal 'TILL-03'
Assert-Eq $true ((Get-Json $bare) -match 'exit 1') 'a null manifest (threw before assignment) still formats'

Write-Host "`nSend-RunSummary keeps its guards" -ForegroundColor Cyan
$send = $funcs['Send-RunSummary'].Extent.Text
Assert-Eq $true ($send -match '(?s)if \(\$DryRun\).*?return') 'the -DryRun early return is still there'
Assert-Eq $true ($send -match 'Set-Tls12')   'TLS 1.2 is set before the POST'
Assert-Eq $true ($send -match 'TimeoutSec')  'the POST is bounded by a timeout'
Assert-Eq $true ($send -match '-Depth 10')   'the POST serializes deep enough to keep the blocks'
# A CALL, not the word - the body says "Never Warn" in a comment. docs/LOG-SHIPPING.md#fail-soft
$warnCalls = @($funcs['Send-RunSummary'].Body.FindAll(
    { param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Warn' }, $true))
Assert-Eq 0 $warnCalls.Count 'a failed post never goes yellow'

# The tail is read from $RunLog, so the transcript must already be closed.
Write-Host "`nThe hook runs after Stop-Transcript" -ForegroundColor Cyan
$src  = Get-Content (Join-Path (Split-Path $PSScriptRoot -Parent) 'alleaves_setup.ps1') -Raw
$stop = $src.IndexOf('Stop-Transcript')
$hook = $src.IndexOf("Invoke-Step 'Slack run summary'")
Assert-Eq $true ($hook -gt 0 -and $stop -gt 0 -and $hook -gt $stop) 'the send is ordered after Stop-Transcript'

Write-Host ''
if ($script:Failures) { Write-Host "$($script:Failures) failure(s)" -ForegroundColor Red; exit 1 }
Write-Host 'all checks passed' -ForegroundColor Green
exit 0
