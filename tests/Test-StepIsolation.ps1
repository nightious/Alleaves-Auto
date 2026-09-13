<#
.SYNOPSIS
    Self-check for "a failing step stops the step, not the run".

    The whole install branch runs inside ONE try in the dispatch tail, so before
    Invoke-Step a throw anywhere in it skipped every remaining step AND the exit
    tally, Save-Manifest, the Done banner and the non-fatal 4/6/7 block. The
    failure mode is invisible in a healthy run - it only appears on the terminal
    where something actually throws, which is the run you can't reproduce - so
    the guard gets a runnable check rather than a comment.

    Same AST-lift style as Test-AccountPrecheck.ps1 / Test-ManifestMerge.ps1: pull
    the definitions out of alleaves_setup.ps1 rather than loading it (which would
    run it).

    No framework, no fixtures. Run it directly:
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

# Invoke-Step calls Fail; lift that too rather than stubbing it, so a change to the
# console helper's signature shows up here instead of passing against a fake.
. ([scriptblock]::Create($funcs['Fail'].Extent.Text))
. ([scriptblock]::Create($funcs['Invoke-Step'].Extent.Text))

Write-Host "`nInvoke-Step: a throwing step must not propagate" -ForegroundColor Cyan
$script:StepFailed = $false
$reached = $false
# Two steps, the first one throwing. The SECOND running is the entire point: this is
# what a terminal does after the printer step blows up - it still reaches Done.
Invoke-Step 'thrower' { throw 'boom' }
Invoke-Step 'later step' { $script:reached = $true }
Assert-Eq $true  $script:StepFailed 'a throw sets $script:StepFailed (-> exit 1)'
Assert-Eq $true  $script:reached    'the step AFTER the throw still runs'

Write-Host "`nInvoke-Step: a clean step is transparent" -ForegroundColor Cyan
$script:StepFailed = $false
$out = Invoke-Step 'value step' { 'POS-X' }
Assert-Eq 'POS-X' $out               'the body''s output passes through'
Assert-Eq $false  $script:StepFailed 'a clean step leaves the flag alone'
# The brand resolve is the one caller that READS the return value, and an empty
# $brand0 skips every printer brand's driver. Invoke-Step must yield nothing on a
# throw so the caller's "if (-not $brand0)" fallback can see it.
$script:StepFailed = $false
$out = Invoke-Step 'throwing value step' { throw 'boom' }
Assert-Eq $null $out 'a throwing body yields nothing (the brand fallback depends on it)'

Write-Host "`nEvery install-branch step is guarded" -ForegroundColor Cyan
# A bare call added back to the install branch silently reintroduces the whole bug,
# and nothing else would catch it. Assert on the SOURCE: no top-level statement in
# the install branch may be a bare call to one of the step functions.
$stepFns = @('Invoke-ComputerRename','Invoke-DownloadPhase','Uninstall-TeamViewer',
             'Install-VcRedist','Invoke-InstallLoop','Invoke-ChromeTaskbar',
             'Invoke-ChromeDefaultBrowser','Invoke-ChromeBookmark',
             'Register-FinishLogonTask','Copy-MasterList','Set-ScannerOpos','Set-PrinterOpos')
$unguarded = @()
foreach ($cmd in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
    $name = $cmd.GetCommandName()
    if ($stepFns -notcontains $name) { continue }
    # Walk up: a guarded call sits inside an Invoke-Step scriptblock argument.
    $p = $cmd.Parent; $guarded = $false
    while ($p) {
        if ($p -is [System.Management.Automation.Language.CommandAst] -and $p.GetCommandName() -eq 'Invoke-Step') { $guarded = $true; break }
        if ($p -is [System.Management.Automation.Language.FunctionDefinitionAst]) { $guarded = $true; break }  # a call from inside another function is not a step call
        $p = $p.Parent
    }
    if (-not $guarded) { $unguarded += "$name (line $($cmd.Extent.StartLineNumber))" }
}
Assert-Eq '' ($unguarded -join ', ') 'no bare step call in the install branch'

Write-Host "`nInvoke-InstallLoop guards each row" -ForegroundColor Cyan
# One bad product must cost exactly one product. The guard is the foreach body's
# own try, so assert on that shape rather than on behaviour we'd have to fake a
# whole $Installers table to exercise.
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
