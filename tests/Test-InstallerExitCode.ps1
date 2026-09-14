<#
.SYNOPSIS
    Self-check: Invoke-Installer's exit code is actually readable.
    Why the $p.Handle line exists: docs/INSTALL-ENGINE.md#invoke-installer

    Asserts the live PS 5.1 behaviour (so the reason is evidence, not a comment
    that can rot) AND that the dereference still sits between the Start-Process
    and the WaitForExit, so deleting it fails here.

        PowerShell -ExecutionPolicy Bypass -File .\tests\Test-InstallerExitCode.ps1
    Exits 0 on pass, 1 on failure.
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')

Write-Host "`nStart-Process -PassThru + redirection loses the exit code without .Handle" -ForegroundColor Cyan

function Start-Probe {
    $o = Join-Path $env:TEMP 'alleaves_exitcode_probe.out'
    $e = Join-Path $env:TEMP 'alleaves_exitcode_probe.err'
    Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', 'exit 7') `
        -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $o -RedirectStandardError $e `
        -ErrorAction Stop
}

$bare = Start-Probe
$null = $bare.WaitForExit(30000)
$bareExit = $bare.ExitCode

$fixed = Start-Probe
$null = $fixed.Handle
$null = $fixed.WaitForExit(30000)
$fixedExit = $fixed.ExitCode

Assert-Eq 7 $fixedExit 'with $p.Handle dereferenced, ExitCode is the real code'
if ($null -ne $bareExit) {
    Write-Host "  NOTE without .Handle ExitCode read '$bareExit' on this host (PS $($PSVersionTable.PSVersion))" -ForegroundColor Yellow
    Write-Host "       - the known-bad case did not reproduce here; the fix is still required for 5.1.22621." -ForegroundColor Yellow
} else {
    Write-Host "  ok   without .Handle ExitCode is `$null (the bug this guards)" -ForegroundColor Green
}

Write-Host "`nInvoke-Installer still caches the handle before waiting" -ForegroundColor Cyan

$funcs = Get-InstallerFunctions (Get-InstallerAst)
Assert-InstallerHas $funcs @('Invoke-Installer')
$fn = $funcs['Invoke-Installer']

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

Write-Host "`nA null exit code falls back to the registry verdict" -ForegroundColor Cyan
$body = $fn.Body.Extent.Text
Assert-Eq $true ($body -match '\$null -eq \$exit')                  'there is an explicit null-exit arm'
Assert-Eq $true ($body -match "note\s*=\s*'exit-unknown-but-registered'") `
    "a null exit with the product in ARP records 'exit-unknown-but-registered'"

Write-Host ''
if ($script:Failures) { Write-Host "$($script:Failures) failure(s)" -ForegroundColor Red; exit 1 }
Write-Host 'all checks passed' -ForegroundColor Green
exit 0
