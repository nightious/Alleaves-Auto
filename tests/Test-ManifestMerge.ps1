<#
.SYNOPSIS
    Self-check for the manifest-merge semantics and the .iss fallback's row bookkeeping.

    These three behaviours are pure data, they only bite on the SECOND run (or the
    first uninstall after one), and every one of them fails SILENTLY - the run
    reports success and the damage shows up a reboot later. A full round trip is
    the only other way to catch them, so they get a runnable check.

    Same AST-lift style as Test-AccountPrecheck.ps1: pull the function definitions
    out of alleaves_setup.ps1 rather than loading it (which would run it).

    No framework, no fixtures. Run it directly:
        PowerShell -ExecutionPolicy Bypass -File .\tests\Test-ManifestMerge.ps1
    Exits 0 on pass, 1 on failure.
#>
$ErrorActionPreference = 'Stop'
$script:Failures = 0

function Assert-Eq($expected, $actual, $what) {
    if ("$expected" -eq "$actual") { Write-Host "  ok   $what" -ForegroundColor Green }
    else {
        Write-Host "  FAIL $what -- expected '$expected', got '$actual'" -ForegroundColor Red
        $script:Failures++
    }
}

$target = Join-Path (Split-Path $PSScriptRoot -Parent) 'alleaves_setup.ps1'
$errs = $null
$ast  = [System.Management.Automation.Language.Parser]::ParseFile($target, [ref]$null, [ref]$errs)
if ($errs) { Write-Host "parse errors in $target" -ForegroundColor Red; exit 1 }

$wanted = @('Merge-PriorList')
$found  = @{}
foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if ($wanted -contains $f.Name) { $found[$f.Name] = $f.Extent.Text }
}
foreach ($w in $wanted) {
    if (-not $found.ContainsKey($w)) { Write-Host "FAIL: $w not found in the installer" -ForegroundColor Red; exit 1 }
    . ([scriptblock]::Create($found[$w]))
}

Write-Host "`nMerge-PriorList direction" -ForegroundColor Cyan
# Which side wins on a key conflict is the WHOLE meaning of these lists. For anything
# recording PRE-INSTALL state - filesReplaced, regValuesSet, taskbandBackups - only the
# FIRST run ever saw the original, so the prior row has to win. Everything else is a
# result and the current run wins.
$byPath = { param($e) $e.path }
$new = @(@{ path='X'; prev='ours'   })
$old = @(@{ path='X'; prev='theirs' })
Assert-Eq 'theirs' (Merge-PriorList $old $new $byPath)[0].prev 'prior-wins: args (prior, current) keep the pre-install value'
Assert-Eq 'ours'   (Merge-PriorList $new $old $byPath)[0].prev 'current-wins: args (current, prior) keep this run'

# The regression: taskbandBackups was merged current-wins like a result list. By run 2 the
# logon task has cleared Taskband and Explorer has rewritten it with OUR pins, so the
# "backup" run 2 takes is a copy of our own layout - and -Uninstall then "restores"
# Alleaves pins aimed at exes it has just deleted.
$bySid = { param($e) $e.sid }
$run1  = @(@{ sid='S-1-5-21-1-2-3-1001'; favorites='CASHIER-ORIGINAL' })
$run2  = @(@{ sid='S-1-5-21-1-2-3-1001'; favorites='OUR-PINS'         })
Assert-Eq 'CASHIER-ORIGINAL' (Merge-PriorList $run1 $run2 $bySid)[0].favorites `
    'taskbandBackups keeps the FIRST run backup, not run 2 copy of our own layout'

Write-Host "`nMerge-PriorList drops rows with a falsy key" -ForegroundColor Cyan
# Not a bug in the function - a documented consequence of it. It is why the key selector
# for each list has to be a field that is never blank.
# Current is non-empty on purpose: `return ,$merged` on an empty list still yields one
# wrapper element, so counting an all-empty merge measures PowerShell, not the function.
$byName  = { param($e) $e.name }
$merged  = @(Merge-PriorList @(@{ name='keep' }) @(@{ name=$null; note='lost' }) $byName)
Assert-Eq 1      $merged.Count  'a prior row whose key is null is silently dropped'
Assert-Eq 'keep' $merged[0].name 'and the current row is untouched'

Write-Host "`nscannerConfigured key survives a HID-KB start" -ForegroundColor Cyan
# A scanner in factory HID-KB exposes no asset data, so 'serial' is BLANK up front and
# only 'serialFinal' is populated after the switch. Keying on 'serial' therefore dropped
# run 1 row entirely the moment run 2 had a real serial to report.
$scannerKey = { param($e) if ($e.serialFinal) { $e.serialFinal } else { $e.serial } }
$prior   = @(@{ serial=''; serialFinal='SXUAH20008'; result='ok' })
$current = @()
Assert-Eq 1 @(Merge-PriorList $current $prior $scannerKey).Count 'a blank-serial row is carried forward on serialFinal'
# And the same device seen twice must not duplicate.
$current = @(@{ serial='SXUAH20008'; serialFinal='SXUAH20008'; result='already-opos' })
Assert-Eq 1 @(Merge-PriorList $current $prior $scannerKey).Count 'the same scanner does not double up across runs'

Write-Host "`n.iss fallback leaves ONE row per product" -ForegroundColor Cyan
# Invoke-IssSilent records result='fail' by design, then the fallback appends its own row
# under the same name. Both used to survive: the tally counted the stale fail (exit 1 on a
# run that actually succeeded) and Test-PriorInstallFailed - which treats ANY non-ok row as
# a failure - then returned $true forever, so the 446 MB Zebra install replayed every run
# and could never short-circuit on ARP. This models the loop line that drops it.
$installed = @(
    @{ name='Chrome';            result='ok'   }
    @{ name='Zebra Scanner SDK'; result='fail' }   # the .iss attempt
)
$installed = @($installed | Where-Object { $_.name -ne 'Zebra Scanner SDK' })
$installed += @{ name='Zebra Scanner SDK'; result='ok'; method='wrapper-extract' }

$rows = @($installed | Where-Object { $_.name -eq 'Zebra Scanner SDK' })
Assert-Eq 1  $rows.Count      'exactly one row survives for the fallback product'
Assert-Eq 'ok' $rows[0].result 'and it is the fallback result, not the .iss attempt'
# The two consumers that read it:
$failed = @($installed | Where-Object { $_.result -and ($_.result -notin @('ok','dryrun')) })
Assert-Eq 0     $failed.Count 'the exit tally sees no failure'
$priorFailed = [bool]@($installed | Where-Object { $_.name -eq 'Zebra Scanner SDK' -and $_.result -ne 'ok' }).Count
Assert-Eq $false $priorFailed 'Test-PriorInstallFailed will not force a replay next run'
Assert-Eq 'Chrome' $installed[0].name 'other products are untouched by the drop'

Write-Host ''
if ($script:Failures) { Write-Host "$($script:Failures) FAILED" -ForegroundColor Red; exit 1 }
Write-Host 'all passed' -ForegroundColor Green
exit 0
