<#
.SYNOPSIS
    Self-check: a failing step stops the STEP, not the run.
    Why: docs/ARCHITECTURE.md#step-isolation

    Also AST-asserts that no BARE step call survives in the install branch (a bare
    call silently reintroduces the whole bug) and that the install loop's foreach
    body still opens with a try recording 'fail-exception'.

        PowerShell -ExecutionPolicy Bypass -File .\tests\Test-StepIsolation.ps1
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

$funcs = @{}
foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    $funcs[$f.Name] = $f
}
foreach ($w in @('Invoke-Step', 'Invoke-InstallLoop')) {
    if (-not $funcs.ContainsKey($w)) { Write-Host "FAIL: $w not found in the installer" -ForegroundColor Red; exit 1 }
}

. ([scriptblock]::Create($funcs['Fail'].Extent.Text))
. ([scriptblock]::Create($funcs['Invoke-Step'].Extent.Text))

Write-Host "`nInvoke-Step: a throwing step must not propagate" -ForegroundColor Cyan
$script:StepFailed = $false
$reached = $false
Invoke-Step 'thrower' { throw 'boom' }
Invoke-Step 'later step' { $script:reached = $true }
Assert-Eq $true  $script:StepFailed 'a throw sets $script:StepFailed (-> exit 1)'
Assert-Eq $true  $script:reached    'the step AFTER the throw still runs'

Write-Host "`nInvoke-Step: a clean step is transparent" -ForegroundColor Cyan
$script:StepFailed = $false
$out = Invoke-Step 'value step' { 'POS-X' }
Assert-Eq 'POS-X' $out               'the body''s output passes through'
Assert-Eq $false  $script:StepFailed 'a clean step leaves the flag alone'
$script:StepFailed = $false
$out = Invoke-Step 'throwing value step' { throw 'boom' }
Assert-Eq $null $out 'a throwing body yields nothing (the brand fallback depends on it)'

Write-Host "`nEvery install-branch step is guarded" -ForegroundColor Cyan
$stepFns = @('Invoke-ComputerRename','Invoke-DownloadPhase','Uninstall-TeamViewer',
             'Install-VcRedist','Invoke-InstallLoop','Invoke-ChromeTaskbar',
             'Invoke-ChromeDefaultBrowser','Invoke-ChromeBookmark',
             'Register-FinishLogonTask','Copy-MasterList','Set-ScannerOpos','Set-PrinterOpos')
$unguarded = @()
foreach ($cmd in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
    $name = $cmd.GetCommandName()
    if ($stepFns -notcontains $name) { continue }
    $p = $cmd.Parent; $guarded = $false
    while ($p) {
        if ($p -is [System.Management.Automation.Language.CommandAst] -and $p.GetCommandName() -eq 'Invoke-Step') { $guarded = $true; break }
        if ($p -is [System.Management.Automation.Language.FunctionDefinitionAst]) { $guarded = $true; break }
        $p = $p.Parent
    }
    if (-not $guarded) { $unguarded += "$name (line $($cmd.Extent.StartLineNumber))" }
}
Assert-Eq '' ($unguarded -join ', ') 'no bare step call in the install branch'

Write-Host "`nInvoke-InstallLoop guards each row" -ForegroundColor Cyan
$loop = $funcs['Invoke-InstallLoop'].Body.FindAll(
    { param($n) $n -is [System.Management.Automation.Language.ForEachStatementAst] }, $true) | Select-Object -First 1
$first = if ($loop) { @($loop.Body.Statements)[0] } else { $null }
Assert-Eq 'TryStatementAst' $(if ($first) { $first.GetType().Name } else { '<no foreach>' }) `
    'the row loop body opens with a try'
$catchRecords = $first -and ($first.Extent.Text -match "result='fail-exception'")
Assert-Eq $true $catchRecords 'the per-row catch records a fail-exception manifest row'

Write-Host ''
if ($script:Failures) { Write-Host "$($script:Failures) failure(s)" -ForegroundColor Red; exit 1 }
Write-Host 'all checks passed' -ForegroundColor Green
exit 0
