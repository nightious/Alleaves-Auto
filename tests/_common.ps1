<#
.SYNOPSIS
    Shared helpers for the self-checks. NOT a test itself - the runner globs
    Test-*.ps1, so this file is dot-sourced, never executed on its own.
    What each test asserts: docs/ARCHITECTURE.md#tests
#>

# $script:Failures lives in the DOT-SOURCING test's scope, which is where these
# functions are defined, so each test still owns its own counter.
$script:Failures = 0

function Assert-Eq($expected, $actual, $what) {
    if ("$expected" -eq "$actual") { Write-Host "  ok   $what" -ForegroundColor Green }
    else {
        Write-Host "  FAIL $what -- expected '$expected', got '$actual'" -ForegroundColor Red
        $script:Failures++
    }
}

# The installer is PARSED, never run: docs/ARCHITECTURE.md#tests
function Get-InstallerAst {
    $target = Join-Path (Split-Path $PSScriptRoot -Parent) 'alleaves_setup.ps1'
    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($target, [ref]$null, [ref]$errs)
    if ($errs) { Write-Host "parse errors in $target" -ForegroundColor Red; exit 1 }
    return $ast
}

# name -> FunctionDefinitionAst. Dot-source .Extent.Text in the TEST's scope to lift one.
function Get-InstallerFunctions($ast) {
    $funcs = @{}
    foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        $funcs[$f.Name] = $f
    }
    return $funcs
}

function Assert-InstallerHas($funcs, [string[]]$Name) {
    foreach ($n in $Name) {
        if (-not $funcs.ContainsKey($n)) { Write-Host "FAIL: $n not found in the installer" -ForegroundColor Red; exit 1 }
    }
}
