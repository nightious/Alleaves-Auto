<#
.SYNOPSIS
    Self-check for Invoke-Installer's exit code actually being readable.

    On Windows PowerShell 5.1, Start-Process -PassThru combined with
    -RedirectStandardOutput/-RedirectStandardError hands back a Process whose
    .ExitCode reads $null after WaitForExit: PowerShell releases the process
    handle and the exit status goes with it. Invoke-Installer is the only launch
    site in alleaves_setup.ps1 that redirects, so EVERY product routed through it
    (raw-exe rows and, via Invoke-Msi, every MSI) recorded exitCode=null ->
    "$okCodes -contains $exit" false -> result='fail' on installs that SUCCEEDED.
    Measured on a live terminal 2026-09-13:
        [FAIL] Google Chrome exited  - see ...
        [FAIL] NiceLabel exited  - see ...
    with {"exitCode": null, "result": "fail"} in the manifest for both.

    Dereferencing $p.Handle before waiting makes .NET cache the handle and the
    exit code survives. That is a ONE-LINE fix with no visible effect in a healthy
    run, which is exactly the kind that gets "cleaned up" later - hence this check.

    Two asserts:
      1. the live platform behaviour, so the reason the line exists is evidence,
         not a comment that can rot;
      2. an AST assert that the line is still there, between the Start-Process and
         the WaitForExit, so deleting it fails here.

    No framework, no fixtures. Run it directly:
        PowerShell -ExecutionPolicy Bypass -File .\tests\Test-InstallerExitCode.ps1
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

# ---------------------------------------------------------------------------
# 1. The platform behaviour this fix exists for.
# ---------------------------------------------------------------------------
Write-Host "`nStart-Process -PassThru + redirection loses the exit code without .Handle" -ForegroundColor Cyan

# cmd.exe /c exit 7 - a code no installer family here treats as success, so a
# stray 0 can't make this pass by accident.
function Start-Probe {
    $o = Join-Path $env:TEMP 'alleaves_exitcode_probe.out'
    $e = Join-Path $env:TEMP 'alleaves_exitcode_probe.err'
    # Byte-identical launch shape to Invoke-Installer's.
    Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', 'exit 7') `
        -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $o -RedirectStandardError $e `
        -ErrorAction Stop
}

$bare = Start-Probe
$null = $bare.WaitForExit(30000)
$bareExit = $bare.ExitCode

$fixed = Start-Probe
$null = $fixed.Handle          # <- the fix
$null = $fixed.WaitForExit(30000)
$fixedExit = $fixed.ExitCode

Assert-Eq 7 $fixedExit 'with $p.Handle dereferenced, ExitCode is the real code'
# If a future PS servicing update repairs the bare case this stops being a bug, but the
# .Handle line is still correct and this assert would need retiring deliberately. Report
# it rather than silently passing on a platform whose behaviour changed underneath us.
if ($null -ne $bareExit) {
    Write-Host "  NOTE without .Handle ExitCode read '$bareExit' on this host (PS $($PSVersionTable.PSVersion))" -ForegroundColor Yellow
    Write-Host "       - the known-bad case did not reproduce here; the fix is still required for 5.1.22621." -ForegroundColor Yellow
} else {
    Write-Host "  ok   without .Handle ExitCode is `$null (the bug this guards)" -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# 2. The line is still in Invoke-Installer, in the right place.
# ---------------------------------------------------------------------------
Write-Host "`nInvoke-Installer still caches the handle before waiting" -ForegroundColor Cyan

$target = Join-Path (Split-Path $PSScriptRoot -Parent) 'alleaves_setup.ps1'
$errs = $null
$ast  = [System.Management.Automation.Language.Parser]::ParseFile($target, [ref]$null, [ref]$errs)
if ($errs) { Write-Host "parse errors in $target" -ForegroundColor Red; exit 1 }

$fn = $ast.FindAll({ param($n)
    $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-Installer'
}, $true) | Select-Object -First 1
if (-not $fn) { Write-Host 'FAIL: Invoke-Installer not found in the installer' -ForegroundColor Red; exit 1 }

# Line numbers, not text order: the point is that the handle is taken while the
# process is still ours to take it from - i.e. after the launch, before the wait.
$startLine = ($fn.Body.FindAll({ param($n)
    $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Start-Process'
}, $true) | Select-Object -First 1).Extent.StartLineNumber

$handleLine = ($fn.Body.FindAll({ param($n)
    $n -is [System.Management.Automation.Language.MemberExpressionAst] -and "$($n.Member)" -eq 'Handle'
}, $true) | Select-Object -First 1).Extent.StartLineNumber

$waitLine = ($fn.Body.FindAll({ param($n)
    $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and "$($n.Member)" -eq 'WaitForExit'
}, $true) | Select-Object -First 1).Extent.StartLineNumber

Assert-Eq $true ($null -ne $handleLine) 'Invoke-Installer dereferences .Handle'
Assert-Eq $true ($null -ne $startLine -and $null -ne $handleLine -and $startLine -lt $handleLine) `
    '.Handle is taken AFTER the Start-Process'
Assert-Eq $true ($null -ne $waitLine -and $null -ne $handleLine -and $handleLine -lt $waitLine) `
    '.Handle is taken BEFORE the WaitForExit'

# ---------------------------------------------------------------------------
# 3. A null exit code must not print a blank failure.
# ---------------------------------------------------------------------------
Write-Host "`nA null exit code falls back to the registry verdict" -ForegroundColor Cyan
# Behaviour-lifting this arm would mean faking $Manifest, $LogDir, Find-InstalledProducts
# and the console helpers for a three-line branch; assert the shape instead, which is what
# Test-StepIsolation does for the row guard.
$body = $fn.Body.Extent.Text
Assert-Eq $true ($body -match '\$null -eq \$exit')                  'there is an explicit null-exit arm'
Assert-Eq $true ($body -match "note\s*=\s*'exit-unknown-but-registered'") `
    "a null exit with the product in ARP records 'exit-unknown-but-registered'"

Write-Host ''
if ($script:Failures) { Write-Host "$($script:Failures) failure(s)" -ForegroundColor Red; exit 1 }
Write-Host 'all checks passed' -ForegroundColor Green
exit 0
