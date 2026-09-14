<#
.SYNOPSIS
    Self-check: manifest-merge semantics + the .iss fallback's row bookkeeping.
    Why each rule exists: docs/MANIFEST.md#merge and docs/INSTALL-ENGINE.md#iss-fallback

    These behaviours are pure data, only bite on the SECOND run (or the first
    uninstall after one), and fail SILENTLY. Same AST-lift style as
    Test-AccountPrecheck.ps1. What each file in tests/ asserts: docs/ARCHITECTURE.md#tests

        PowerShell -ExecutionPolicy Bypass -File .\tests\Test-ManifestMerge.ps1
    Exits 0 on pass, 1 on failure.
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')

$ast    = Get-InstallerAst
$funcs  = Get-InstallerFunctions $ast
$wanted = @('Merge-PriorList', 'Get-PriorManifest', 'Test-PriorInstallFailed')
Assert-InstallerHas $funcs $wanted
foreach ($w in $wanted) { . ([scriptblock]::Create($funcs[$w].Extent.Text)) }

Write-Host "`nMerge-PriorList direction" -ForegroundColor Cyan
$byPath = { param($e) $e.path }
$new = @(@{ path='X'; prev='ours'   })
$old = @(@{ path='X'; prev='theirs' })
Assert-Eq 'theirs' (Merge-PriorList $old $new $byPath)[0].prev 'prior-wins: args (prior, current) keep the pre-install value'
Assert-Eq 'ours'   (Merge-PriorList $new $old $byPath)[0].prev 'current-wins: args (current, prior) keep this run'

$bySid = { param($e) $e.sid }
$run1  = @(@{ sid='S-1-5-21-1-2-3-1001'; favorites='CASHIER-ORIGINAL' })
$run2  = @(@{ sid='S-1-5-21-1-2-3-1001'; favorites='OUR-PINS'         })
Assert-Eq 'CASHIER-ORIGINAL' (Merge-PriorList $run1 $run2 $bySid)[0].favorites `
    'taskbandBackups keeps the FIRST run backup, not run 2 copy of our own layout'

Write-Host "`nMerge-PriorList drops rows with a falsy key" -ForegroundColor Cyan
$byName  = { param($e) $e.name }
$merged  = @(Merge-PriorList @(@{ name='keep' }) @(@{ name=$null; note='lost' }) $byName)
Assert-Eq 1      $merged.Count  'a prior row whose key is null is silently dropped'
Assert-Eq 'keep' $merged[0].name 'and the current row is untouched'

Write-Host "`nscannerConfigured key survives a HID-KB start" -ForegroundColor Cyan
$scannerKey = { param($e) if ($e.serialFinal) { $e.serialFinal } else { $e.serial } }
$prior   = @(@{ serial=''; serialFinal='SXUAH20008'; result='ok' })
$current = @()
Assert-Eq 1 @(Merge-PriorList $current $prior $scannerKey).Count 'a blank-serial row is carried forward on serialFinal'
$current = @(@{ serial='SXUAH20008'; serialFinal='SXUAH20008'; result='already-opos' })
Assert-Eq 1 @(Merge-PriorList $current $prior $scannerKey).Count 'the same scanner does not double up across runs'

Write-Host "`n.iss fallback leaves ONE row per product" -ForegroundColor Cyan
$installed = @(
    @{ name='Chrome';            result='ok'   }
    @{ name='Zebra Scanner SDK'; result='fail' }
)
$installed = @($installed | Where-Object { $_.name -ne 'Zebra Scanner SDK' })
$installed += @{ name='Zebra Scanner SDK'; result='ok'; method='wrapper-extract' }

$rows = @($installed | Where-Object { $_.name -eq 'Zebra Scanner SDK' })
Assert-Eq 1  $rows.Count      'exactly one row survives for the fallback product'
Assert-Eq 'ok' $rows[0].result 'and it is the fallback result, not the .iss attempt'
$failed = @($installed | Where-Object { $_.result -and ($_.result -notin @('ok','dryrun')) })
Assert-Eq 0     $failed.Count 'the exit tally sees no failure'
Assert-Eq 'Chrome' $installed[0].name 'other products are untouched by the drop'

Write-Host "`nTest-PriorInstallFailed treats an msi-fallback row as not-installed" -ForegroundColor Cyan
function Warn($m) {}
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
$script:Warned = 0
function Warn($m) { $script:Warned++ }
$ManifestPath = Join-Path $env:TEMP ("alleaves_manifest_test_{0}.json" -f [guid]::NewGuid())
Set-Content -Path $ManifestPath -Value '{"installed":[{"name":"Zebra Scanner SDK","result":"fail"}]}' -Encoding UTF8
$lock = [System.IO.File]::Open($ManifestPath, 'Open', 'Read', 'None')
$script:PriorManifest = $null
$ErrorActionPreference = 'Continue'
try {
    Get-PriorManifest | Out-Null
    Get-PriorManifest | Out-Null
} finally {
    $ErrorActionPreference = 'Stop'
    $lock.Close()
    Remove-Item -LiteralPath $ManifestPath -Force
}
$state = "warned=$($script:Warned) memo=$(if ($null -eq $script:PriorManifest) { 'null' } else { 'hashtable' })"
Assert-Eq 'warned=1 memo=hashtable' $state 'a locked manifest reaches the catch once and leaves the memo non-null'

Write-Host "`nUninstall step 4b survives a STALE regValuesSet row" -ForegroundColor Cyan
Assert-InstallerHas $funcs @('Invoke-UninstallPhase')
$uninst = $funcs['Invoke-UninstallPhase']
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
$gone  = "$root\Retired"
Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
New-Item -Path $live -Force | Out-Null
New-ItemProperty -Path $live -Name 'DeviceName' -Value 'POS01_Printer' -PropertyType String -Force | Out-Null
New-ItemProperty -Path $live -Name 'PortName'   -Value 'OURS'          -PropertyType String -Force | Out-Null
try {
    $fails = & $Restore4b ([pscustomobject]@{ regValuesSet = @(
        [pscustomobject]@{ path=$gone; name='DeviceName'; prevAbsent=$true                       },
        [pscustomobject]@{ path=$gone; name='(default)';  prevAbsent=$true                       },
        [pscustomobject]@{ path=$gone; name='PortName';   prevAbsent=$false; prev='X'; type='String' },
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
Assert-InstallerHas $funcs @('Test-PrinterOposConfigured')
. ([scriptblock]::Create($funcs['Test-PrinterOposConfigured'].Extent.Text))

$PrinterOposRoot = 'HKCU:\Software\AlleavesAutoTest\ServiceOPOS'
Remove-Item -LiteralPath 'HKCU:\Software\AlleavesAutoTest' -Recurse -Force -ErrorAction SilentlyContinue
try {
    Assert-Eq $false (Test-PrinterOposConfigured -LogicalName 'POS01_Printer' -Class 'POSPrinter') `
        'a device with no key is not configured'
    New-Item -Path "$PrinterOposRoot\POSPrinter\POS01_Printer" -Force | Out-Null
    New-ItemProperty -Path "$PrinterOposRoot\POSPrinter\POS01_Printer" -Name 'DeviceName' `
        -Value 'Thermal' -PropertyType String -Force | Out-Null
    Assert-Eq $false (Test-PrinterOposConfigured -LogicalName 'POS01_Printer' -Class 'POSPrinter') `
        'a key with values but no ProgID (default) is NOT configured'
    New-ItemProperty -Path "$PrinterOposRoot\POSPrinter\POS01_Printer" -Name '(default)' `
        -Value 'RecPrinter.POSPrinter.SOU' -PropertyType String -Force | Out-Null
    Assert-Eq $true (Test-PrinterOposConfigured -LogicalName 'POS01_Printer' -Class 'POSPrinter') `
        'a key whose default holds the ProgID IS configured'
    Assert-Eq $false (Test-PrinterOposConfigured -LogicalName 'POS02_Printer' -Class 'POSPrinter') `
        'a device under another logical name does not count'
    Assert-Eq $false (Test-PrinterOposConfigured -LogicalName 'POS01_Printer' -Class 'CashDrawer') `
        'a device under another class does not count'
} finally {
    Remove-Item -LiteralPath 'HKCU:\Software\AlleavesAutoTest' -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "`nAdd-AlreadyInstalledRow decides removable from the PRIOR manifest" -ForegroundColor Cyan
# This is what keeps -Uninstall off software the installer only ever FOUND:
# docs/INSTALL-ENGINE.md#already-installed
Assert-InstallerHas $funcs @('Add-AlreadyInstalledRow')
. ([scriptblock]::Create($funcs['Add-AlreadyInstalledRow'].Extent.Text))
function Step($m) { }
function Info($m) { }
$Manifest = @{ installed = @() }
$script:PriorManifest = [pscustomobject]@{ installed = @(
    [pscustomobject]@{ name='Chrome';    result='ok'                                          }
    [pscustomobject]@{ name='NiceLabel'; result='ok'; note='already-installed'; removable=$false }
) }
Add-AlreadyInstalledRow -Name 'Chrome'       -Source 'c' -Method 'exe' -Match 'm'
Add-AlreadyInstalledRow -Name 'NiceLabel'    -Source 'c' -Method 'exe' -Match 'm'
Add-AlreadyInstalledRow -Name 'POS for .NET' -Source 'c' -Method 'msi' -Match 'm'
Assert-Eq $true  $Manifest.installed[0].removable 'a product WE installed last run stays removable'
Assert-Eq $false $Manifest.installed[1].removable 'a pre-existing product stays non-removable across re-runs'
Assert-Eq $false $Manifest.installed[2].removable 'no prior row at all = we never installed it'

Write-Host "`nManifest row shapes match docs/MANIFEST.md#keys" -ForegroundColor Cyan
# The key table is the one thing a reader must trust literally, and it drifted six ways before this
# check existed (an invented 'hive', a missing 'serialFinal', ...). docs/MANIFEST.md#keys
$docPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'docs\MANIFEST.md'
$documented = @{}
foreach ($line in [IO.File]::ReadAllLines($docPath)) {
    # | `listName` | `{ a; b; c }` ... |
    if ($line -match '^\|\s*`(\w+)`\s*\|\s*`\{([^}]*)\}`') {
        $documented[$Matches[1]] = @(
            $Matches[2] -split ';' | ForEach-Object {
                ($_ -replace '\(b64\)', '' -replace '=.*$', '').Trim()
            } | Where-Object { $_ }
        )
    }
}
Assert-Eq $true ($documented.get_Count() -ge 8) "parsed the key table ($($documented.get_Count()) fixed-shape rows)"

# Collect the keys the script actually writes, per list: direct @{...} literals plus one level of
# indirection ($entry = @{...} ... $Manifest.<list> += $entry) resolved inside the same function.
function Get-HashKeys($ht) {
    @($ht.KeyValuePairs | ForEach-Object { $_.Item1.Extent.Text.Trim("'", '"', ' ') })
}
$written = @{}
foreach ($asn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
    $left = $asn.Left
    if ($left -isnot [System.Management.Automation.Language.MemberExpressionAst]) { continue }
    if ($left.Expression -isnot [System.Management.Automation.Language.VariableExpressionAst]) { continue }
    if ($left.Expression.VariablePath.UserPath -ne 'Manifest') { continue }
    $list = "$($left.Member.Extent.Text)"
    if (-not $documented.ContainsKey($list)) { continue }
    if (-not $written.ContainsKey($list)) { $written[$list] = @{} }

    $rhs = $asn.Right.Extent.Text
    $hts = @($asn.Right.FindAll({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $true))
    if (-not $hts.Count -and $rhs -match '^\s*\$(\w+)\s*$') {
        # Indirect: resolve $var against hashtable literals assigned to it in the enclosing function.
        $varName = $Matches[1]
        $fn = $asn
        while ($fn -and $fn -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) { $fn = $fn.Parent }
        if ($fn) {
            $hts = @($fn.FindAll({ param($n)
                $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
                $n.Left.VariablePath.UserPath -eq $varName }, $true) |
                ForEach-Object { $_.Right.FindAll({ param($m) $m -is [System.Management.Automation.Language.HashtableAst] }, $true) })
        }
    }
    foreach ($ht in $hts) { foreach ($k in Get-HashKeys $ht) { $written[$list][$k] = $true } }
}

# accountCreated / accountCheckOverride never go through $Manifest.<list> += : New-InstallManifest
# seeds them from a $script: variable, so resolve that variable's own hashtable literal.
foreach ($list in $documented.get_Keys()) {
    if ($written.ContainsKey($list) -and $written[$list].get_Count()) { continue }
    $seed = $ast.Find({ param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'New-InstallManifest' }, $true)
    if (-not $seed) { continue }
    $pair = $seed.Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $true) |
            ForEach-Object { $_.KeyValuePairs } | Where-Object { "$($_.Item1.Extent.Text)" -eq $list } | Select-Object -First 1
    if (-not $pair) { continue }
    foreach ($v in $pair.Item2.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
        $vp = $v.VariablePath.UserPath -replace '^script:', ''
        $written[$list] = @{}
        foreach ($a in $ast.FindAll({ param($n)
                $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
                ($n.Left.VariablePath.UserPath -replace '^script:', '') -eq $vp }, $true)) {
            foreach ($ht in $a.Right.FindAll({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $true)) {
                foreach ($k in Get-HashKeys $ht) { $written[$list][$k] = $true }
            }
        }
    }
}

foreach ($list in ($documented.get_Keys() | Sort-Object)) {
    if (-not $written.ContainsKey($list) -or -not $written[$list].get_Count()) {
        Write-Host "  FAIL $list -- documented, but no @{} literal found in the installer" -ForegroundColor Red
        $script:Failures++
        continue
    }
    $code = @($written[$list].get_Keys() | Sort-Object)
    $doc  = @($documented[$list] | Sort-Object)
    $undocumented = @($code | Where-Object { $doc -notcontains $_ })
    $invented     = @($doc  | Where-Object { $code -notcontains $_ })
    Assert-Eq '' ($undocumented -join ', ') "$list : every key the code writes is documented"
    Assert-Eq '' ($invented     -join ', ') "$list : every documented key is one the code writes"
}

Write-Host ''
if ($script:Failures) { Write-Host "$($script:Failures) FAILED" -ForegroundColor Red; exit 1 }
Write-Host 'all passed' -ForegroundColor Green
exit 0
