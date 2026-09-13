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

$wanted = @('Merge-PriorList', 'Get-PriorManifest', 'Test-PriorInstallFailed')
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
# The consumer that reads 'result':
$failed = @($installed | Where-Object { $_.result -and ($_.result -notin @('ok','dryrun')) })
Assert-Eq 0     $failed.Count 'the exit tally sees no failure'
Assert-Eq 'Chrome' $installed[0].name 'other products are untouched by the drop'

Write-Host "`nTest-PriorInstallFailed treats an msi-fallback row as not-installed" -ForegroundColor Cyan
# Neither fallback MSI carries the shared "Zebra CoreScanner Driver" the .iss install does.
# So a fallback that "succeeded" leaves the product in ARP with result='ok' - the guard in
# Invoke-InstallLoop skips it on every future run while CoreScanner stays absent, the run
# exits 4 (scanner degraded) forever, and exit 4 printed remediation ("re-run the
# installer") can never take effect. The loop stamps note='msi-fallback' for exactly this.
function Warn($m) {}
# Seeding the memo makes Get-PriorManifest return this without touching the disk.
$script:PriorManifest = [pscustomobject]@{ installed = @(
    [pscustomobject]@{ name='Chrome';            result='ok'                             }
    [pscustomobject]@{ name='Zebra Scanner SDK'; result='ok'; note='msi-fallback'         }
    [pscustomobject]@{ name='Zebra 123 Scan';    result='ok'; note='already-installed'    }
    [pscustomobject]@{ name='POS for .NET';      result='fail'                            }
) }
Assert-Eq $false (Test-PriorInstallFailed -Name 'Chrome')            'a plain ok row still short-circuits on ARP'
Assert-Eq $true  (Test-PriorInstallFailed -Name 'Zebra Scanner SDK') 'an msi-fallback ok row forces the .iss to be re-attempted'
Assert-Eq $false (Test-PriorInstallFailed -Name 'Zebra 123 Scan')    'note=already-installed is NOT confused with the fallback stamp'
Assert-Eq $true  (Test-PriorInstallFailed -Name 'POS for .NET')      'a failed row still forces a repair'
Assert-Eq $false (Test-PriorInstallFailed -Name 'NiceLabel')         'no prior row at all = trust the registry'

Write-Host "`nGet-PriorManifest does not read an unreadable manifest as empty" -ForegroundColor Cyan
# The manifest is LOCKED here (AV / a backup agent holding it open), not malformed:
# malformed JSON is statement-terminating and always reached the catch, but Get-Content
# failing is NON-TERMINATING under the installer's $ErrorActionPreference = 'Continue'.
# Without -ErrorAction Stop the pipeline then yields nothing, the assignment lands $null
# over the @{} default, the read-once memo never satisfies (every call re-reads and
# re-errors), and every consumer reads an EMPTY manifest. The one that bites is
# Test-PriorInstallFailed: it returns $false for a product that FAILED last run, bare ARP
# presence skips its repair, and the run reports success forever.
# The preference is flipped here on purpose - under this file's 'Stop' the bug is invisible.
$script:Warned = 0
function Warn($m) { $script:Warned++ }
$ManifestPath = Join-Path $env:TEMP ("alleaves_manifest_test_{0}.json" -f [guid]::NewGuid())
Set-Content -Path $ManifestPath -Value '{"installed":[{"name":"Zebra Scanner SDK","result":"fail"}]}' -Encoding UTF8
$lock = [System.IO.File]::Open($ManifestPath, 'Open', 'Read', 'None')
$script:PriorManifest = $null
$ErrorActionPreference = 'Continue'
try {
    Get-PriorManifest | Out-Null
    Get-PriorManifest | Out-Null      # memo: a second call must not re-read (and not re-Warn)
} finally {
    $ErrorActionPreference = 'Stop'
    $lock.Close()
    Remove-Item -LiteralPath $ManifestPath -Force
}
$state = "warned=$($script:Warned) memo=$(if ($null -eq $script:PriorManifest) { 'null' } else { 'hashtable' })"
Assert-Eq 'warned=1 memo=hashtable' $state 'a locked manifest reaches the catch once and leaves the memo non-null'

Write-Host "`nUninstall step 4b survives a STALE regValuesSet row" -ForegroundColor Cyan
# Remove-StalePrinterOpos retires a device key but deliberately leaves its rows to merge
# forward, so after any computer rename (or the drawer retirement reaching a deployed
# terminal) all 28 of them point at a path that no longer exists - FOREVER. Both arms used
# to mishandle that: the delete arm threw (Remove-ItemProperty on a missing path, -Stop,
# straight into the counting catch = ~27 "reversal failures" and exit 1 on a decommission
# that actually succeeded), and the restore arm New-Item'd the retired key back, RESURRECTING
# the phantom OPOS device. Lifted as the real loop body, run against a scratch HKCU key.
$uninst = $null
foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if ($f.Name -eq 'Invoke-UninstallPhase') { $uninst = $f }
}
if (-not $uninst) { Write-Host 'FAIL: Invoke-UninstallPhase not found' -ForegroundColor Red; exit 1 }
$rvLoop = @($uninst.FindAll({ param($n)
    $n -is [System.Management.Automation.Language.ForEachStatementAst] -and
    $n.Variable.VariablePath.UserPath -eq 'rv' }, $true))
if ($rvLoop.Count -ne 1) { Write-Host "FAIL: expected one foreach (`$rv), found $($rvLoop.Count)" -ForegroundColor Red; exit 1 }

function Ok($m)   { }
function Warn($m) { }
function Dry($m)  { }
$DryRun = $false
$Restore4b = [scriptblock]::Create(@"
param(`$man)
`$uninstallFailures = 0
$($rvLoop[0].Extent.Text)
return `$uninstallFailures
"@)

$root  = 'HKCU:\Software\AlleavesAutoTest'
$live  = "$root\Live"
$gone  = "$root\Retired"          # never created: the retired device key
Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
New-Item -Path $live -Force | Out-Null
New-ItemProperty -Path $live -Name 'DeviceName' -Value 'POS01_Printer' -PropertyType String -Force | Out-Null
New-ItemProperty -Path $live -Name 'PortName'   -Value 'OURS'          -PropertyType String -Force | Out-Null
try {
    $fails = & $Restore4b ([pscustomobject]@{ regValuesSet = @(
        # stale delete rows - the key is gone, so is the goal
        [pscustomobject]@{ path=$gone; name='DeviceName'; prevAbsent=$true                       },
        [pscustomobject]@{ path=$gone; name='(default)';  prevAbsent=$true                       },
        # stale RESTORE row - must not re-create the retired key
        [pscustomobject]@{ path=$gone; name='PortName';   prevAbsent=$false; prev='X'; type='String' },
        # the real work still has to happen
        [pscustomobject]@{ path=$live; name='DeviceName'; prevAbsent=$true                       },
        [pscustomobject]@{ path=$live; name='PortName';   prevAbsent=$false; prev='THEIRS'; type='String' }
    ) })
    Assert-Eq 0        $fails                            'stale rows count as ZERO reversal failures'
    Assert-Eq $false   (Test-Path -LiteralPath $gone)    'the retired device key is NOT resurrected by the restore arm'
    Assert-Eq $null    (Get-ItemProperty -Path $live -Name 'DeviceName' -ErrorAction SilentlyContinue) 'a value that IS there is still deleted'
    Assert-Eq 'THEIRS' (Get-ItemProperty -Path $live -Name 'PortName').PortName 'a value we overwrote is still restored'
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "`nEvery printer brand RowName names a real download AND install row" -ForegroundColor Cyan
# Step 0b feeds every brand's RowName EXCEPT the chosen one to $SkipPrograms, and
# Test-SkipMatch matches that against $DriveFiles Label for the download phase and
# $Installers Name for the install phase. A typo in either place matches nothing and fails
# SILENTLY: a POS-X terminal downloads Star's 471 MB CD image and installs both drivers.
# Same drift class the Label/Name rule already exists for, one level up.
# Read as literals off the AST rather than evaluated: the three tables reference other
# top-level variables ($NiceLabelArgs, $PosXPrinterStrings, ...) that dot-sourcing them
# alone would leave $null.
function Get-KeyLiterals($node, $key) {
    $out = @()
    foreach ($h in $node.FindAll({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $true)) {
        foreach ($kv in $h.KeyValuePairs) {
            if (($kv.Item1.Extent.Text -replace '^[''"]|[''"]$') -ne $key) { continue }
            if ($kv.Item2.Extent.Text -match "^\s*'(.*)'\s*$") { $out += $Matches[1] }
        }
    }
    return $out
}
$assign = @{}
foreach ($a in $ast.FindAll({ param($n)
    $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
    $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
    $assign[$a.Left.VariablePath.UserPath] = $a.Right
}
foreach ($v in @('DriveFiles','Installers','PrinterBrands')) {
    if (-not $assign.ContainsKey($v)) { Write-Host "FAIL: `$$v not found in the installer" -ForegroundColor Red; exit 1 }
}
$labels = Get-KeyLiterals $assign['DriveFiles']    'Label'
$names  = Get-KeyLiterals $assign['Installers']    'Name'
$rows   = Get-KeyLiterals $assign['PrinterBrands'] 'RowName'
Assert-Eq $true ($rows.Count -ge 2) 'the brand table still declares its RowNames as plain literals'
foreach ($r in $rows) {
    Assert-Eq $true ($labels -contains $r) "brand RowName '$r' is a `$DriveFiles Label (download phase)"
    Assert-Eq $true ($names  -contains $r) "brand RowName '$r' is an `$Installers Name (install phase)"
}

Write-Host "`nTest-PrinterOposConfigured" -ForegroundColor Cyan
# This decides whether a terminal whose OPOS device already exists is reported as a
# SUCCESS or as a failure with exit 7. Getting it wrong in either direction is bad: too
# loose and an empty phantom key (a device OPOS enumerates and then cannot open) reads
# as configured and the real registration is skipped; too strict and a working terminal
# is reported broken, which is the bug it was added for. Scratch HKCU key, same approach
# as the step-4b section above - no admin, no HKLM.
$fn = $null
foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if ($f.Name -eq 'Test-PrinterOposConfigured') { $fn = $f }
}
if (-not $fn) { Write-Host 'FAIL: Test-PrinterOposConfigured not found' -ForegroundColor Red; exit 1 }
. ([scriptblock]::Create($fn.Extent.Text))

$PrinterOposRoot = 'HKCU:\Software\AlleavesAutoTest\ServiceOPOS'
Remove-Item -LiteralPath 'HKCU:\Software\AlleavesAutoTest' -Recurse -Force -ErrorAction SilentlyContinue
try {
    # (a) no key at all - a fresh terminal
    Assert-Eq $false (Test-PrinterOposConfigured -LogicalName 'POS01_Printer' -Class 'POSPrinter') `
        'a device with no key is not configured'
    # (b) key present but NO default value - the phantom-device state
    New-Item -Path "$PrinterOposRoot\POSPrinter\POS01_Printer" -Force | Out-Null
    New-ItemProperty -Path "$PrinterOposRoot\POSPrinter\POS01_Printer" -Name 'DeviceName' `
        -Value 'Thermal' -PropertyType String -Force | Out-Null
    Assert-Eq $false (Test-PrinterOposConfigured -LogicalName 'POS01_Printer' -Class 'POSPrinter') `
        'a key with values but no ProgID (default) is NOT configured'
    # (c) the real thing: a default value holding the ProgID
    New-ItemProperty -Path "$PrinterOposRoot\POSPrinter\POS01_Printer" -Name '(default)' `
        -Value 'RecPrinter.POSPrinter.SOU' -PropertyType String -Force | Out-Null
    Assert-Eq $true (Test-PrinterOposConfigured -LogicalName 'POS01_Printer' -Class 'POSPrinter') `
        'a key whose default holds the ProgID IS configured'
    # (d) the name is exact - Alleaves opens one specific logical name, so a device
    #     registered under a DIFFERENT name must not count as this one being configured
    Assert-Eq $false (Test-PrinterOposConfigured -LogicalName 'POS02_Printer' -Class 'POSPrinter') `
        'a device under another logical name does not count'
    Assert-Eq $false (Test-PrinterOposConfigured -LogicalName 'POS01_Printer' -Class 'CashDrawer') `
        'a device under another class does not count'
} finally {
    Remove-Item -LiteralPath 'HKCU:\Software\AlleavesAutoTest' -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:Failures) { Write-Host "$($script:Failures) FAILED" -ForegroundColor Red; exit 1 }
Write-Host 'all passed' -ForegroundColor Green
exit 0
