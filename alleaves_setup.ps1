#requires -Version 5.1
<#
.SYNOPSIS
    Single-file Alleaves POS bootstrap: Google Drive download + silent install +
    manifest-driven uninstall. Install-Alleaves.bat fetches this from the latest
    release on every run.

.DESCRIPTION
    Working root %ProgramData%\AlleavesAuto (downloads\, logs\, manifest), which
    survives a later -Uninstall. Elevation is owned by the .bat; this script never
    relaunches itself.

    Exit codes and the full design: see docs\ in the repo, starting with
    docs\ARCHITECTURE.md. End-user usage: README.md.

.PARAMETER Uninstall
    Reverse a prior install using the persisted manifest.
.PARAMETER DryRun
    Simulate everything; change nothing but the working root and this run's log.
    Allowed without admin, where the working root moves to %TEMP%.
.PARAMETER SkipMasterList
    Don't copy the NiceLabel master list to Documents.
.PARAMETER SkipUninstallTeamViewer
    Don't try to remove existing TeamViewer.
.PARAMETER SkipPrograms
    Regex fragments; matching programs are skipped (download + install).
.PARAMETER ForceReinstall
    Re-download even if a valid file exists; pre-clean installed products.
.PARAMETER ScannerConfigOnly
    Run ONLY the USB-OPOS scanner step. Not with -Uninstall / -SkipScannerConfig.
.PARAMETER ComputerName
    Preset POS name (skips the rename prompt). Not with -SkipRename.
.PARAMETER SkipRename
    Don't prompt for or apply a computer rename.
.PARAMETER SkipChromeTaskbar
    Don't pin Alleaves/Chrome or remove Edge from the taskbar.
.PARAMETER SkipDefaultBrowser
    Don't make Chrome the default browser.
.PARAMETER SkipChromeBookmark
    Don't add the Alleaves bookmark to Chrome.
.PARAMETER SkipScannerConfig
    Don't flip the connected Zebra scanner(s) to USB-OPOS.
.PARAMETER PrinterBrand
    POS-X, StarTSP100 or None. Skips the brand prompt. Only the chosen brand's
    driver is downloaded and installed.
.PARAMETER SkipPrinterConfig
    Don't register the OPOS receipt printer device entry.
.PARAMETER PrinterConfigOnly
    Run ONLY the OPOS printer registration; the driver must already be installed.
    Not with -Uninstall / -ScannerConfigOnly / -SkipPrinterConfig / -PrinterBrand None.
.PARAMETER NiceLabelLicense
    Activation ID for NiceLabel's unattended online activation.
.PARAMETER SkipNiceLabelActivation
    Install NiceLabel with plain /s; the license is then entered by hand.
.PARAMETER ForceFingerprint
    Dump the per-hop scanner fingerprint even for a known model (rig capture).
.PARAMETER IgnoreAccountCheck
    Report the account-precheck verdict but do not block on it (exit 8 waived).
    Recorded in the manifest as accountCheckOverride.
#>

[CmdletBinding(PositionalBinding=$false)]
param(
    [switch]$Uninstall,
    [switch]$DryRun,
    [switch]$SkipMasterList,
    [switch]$SkipUninstallTeamViewer,
    [string[]]$SkipPrograms = @(),
    [switch]$ForceReinstall,
    [switch]$ScannerConfigOnly,
    [switch]$ForceFingerprint,
    [string]$ComputerName,
    [switch]$SkipRename,
    [switch]$SkipChromeTaskbar,
    [switch]$SkipDefaultBrowser,
    [switch]$SkipChromeBookmark,
    [switch]$SkipScannerConfig,
    [ValidateSet('POS-X','StarTSP100','None')]
    [string]$PrinterBrand,
    [switch]$SkipPrinterConfig,
    [switch]$PrinterConfigOnly,
    [string]$NiceLabelLicense = 'FXQWA-6CPFD-ST4FB-TWTCZ-HMUMB',
    [switch]$SkipNiceLabelActivation,
    [switch]$IgnoreAccountCheck,
    # docs/ARCHITECTURE.md#argument-guards-exit-2
    [Parameter(ValueFromRemainingArguments)][string[]]$UnknownArgs
)

# ---------------------------------------------------------------------------
# All design rationale lives in docs/. Comments in this file are pointers only.
#   docs/ARCHITECTURE.md    flow, step isolation, exit codes, config-only modes
#   docs/ACCOUNT-SWAP.md    account precheck (exit 8) + automated swap (exit 9)
#   docs/INSTALL-ENGINE.md  download, install loop, MSI/.iss/raw, uninstall
#   docs/MANIFEST.md        manifest keys, merge rules, -Uninstall replay
#   docs/FINISHING.md       rename, taskbar, default browser, bookmark, logon task
#   docs/SCANNER-OPOS.md    Zebra USB-OPOS switch
#   docs/PRINTER-OPOS.md    receipt printer OPOS registration
#   docs/BUILD-BAT.md       the .bat stub: fetch, elevation probe, arg relay
# Add new rationale THERE and leave a pointer here; do not re-grow the essays.
# ---------------------------------------------------------------------------
$ErrorActionPreference = 'Continue'

function Step($msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }
function Ok($msg)   { Write-Host "  [OK]   $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "  [WARN] $msg" -ForegroundColor Yellow }
function Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red }
function Dry($msg)  { Write-Host "  [DRY]  $msg" -ForegroundColor DarkGray }
function Info($msg) { Write-Host $msg -ForegroundColor White }

# docs/ARCHITECTURE.md#step-isolation
function Invoke-Step {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][scriptblock]$Body)
    try { & $Body }
    catch {
        Fail "$Name failed (line $($_.InvocationInfo.ScriptLineNumber)): $($_.Exception.Message)"
        $script:StepFailed = $true
    }
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    ([Security.Principal.WindowsPrincipal]$id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

$IsAdmin = Test-IsAdmin

# docs/ACCOUNT-SWAP.md#why
function Get-SignedInAccount {
    $name = $null
    try { $name = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).UserName } catch { Write-Verbose "Get-SignedInAccount: Win32_ComputerSystem.UserName failed: $($_.Exception.Message)" }
    if (-not $name) {
        try { $name = [Security.Principal.WindowsIdentity]::GetCurrent().Name } catch { Write-Verbose "Get-SignedInAccount: WindowsIdentity fallback failed: $($_.Exception.Message)" }
        if ($name) { Warn "no console session - account precheck is reading the process token ($name)" }
    }
    if (-not $name) { return $null }
    $sid = $null
    try { $sid = ([Security.Principal.NTAccount]$name).Translate([Security.Principal.SecurityIdentifier]).Value } catch { Write-Verbose "Get-SignedInAccount: could not translate '$name' to a SID: $($_.Exception.Message)" }
    [pscustomobject]@{
        Name   = $name
        Sid    = $sid
        Domain = $(if ($name -like '*\*') { $name.Split('\')[0] } else { '' })
    }
}

# docs/ACCOUNT-SWAP.md#msa
function Get-MicrosoftAccountId($sid) {
    if (-not $sid) { return 'unknown' }
    try {
        $ps = (Get-LocalUser -SID $sid -ErrorAction Stop).PrincipalSource
        if ($ps -eq 'Local') { return $null }
        if ($ps -eq 'MicrosoftAccount') {
            $linked = Get-IdentityStoreEmail $sid
            return $(if ($linked) { $linked } else { '(linked email unknown)' })
        }
    } catch { Write-Verbose "Get-MicrosoftAccountId: PrincipalSource probe failed: $($_.Exception.Message)" }
    $email = Get-IdentityStoreEmail $sid
    if ($email) { return $email }
    return 'unknown'
}

function Get-IdentityStoreEmail($sid) {
    try {
        $ic = "HKLM:\SOFTWARE\Microsoft\IdentityStore\Cache\$sid\IdentityCache\$sid"
        $email = (Get-ItemProperty -Path $ic -Name UserName -ErrorAction Stop).UserName
        if ($email) { return $email }
    } catch { Write-Verbose "Get-IdentityStoreEmail: cache read failed: $($_.Exception.Message)" }
    return $null
}

# docs/ACCOUNT-SWAP.md#msa
# ponytail: direct BUILTIN\Administrators members only, no nested groups - an
# admin-via-nested-group reads as not-admin, the safe direction on a POS terminal.
function Test-LocalAdminSid($sid, $name) {
    try {
        foreach ($m in (Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction Stop)) {
            if ($m.SID.Value -eq $sid) { return $true }
        }
        return $false
    } catch {
        $grp = try { (Get-LocalGroup -SID 'S-1-5-32-544' -ErrorAction Stop).Name } catch { Write-Verbose "Test-LocalAdminSid: Get-LocalGroup -SID S-1-5-32-544 failed, assuming 'Administrators': $($_.Exception.Message)"; 'Administrators' }
        $short = $name.Split('\')[-1]
        foreach ($line in (& net localgroup $grp 2>$null)) {
            $t = "$line".Trim()
            if ($t -eq $short -or $t -eq $name) { return $true }
        }
        return $false
    }
}

# docs/ACCOUNT-SWAP.md#verdicts
function Test-InstallAccount {
    $a = Get-SignedInAccount
    if (-not $a) {
        return [pscustomobject]@{ Ok=$false; Reason='no-interactive-user'; Detail='no account resolved' }
    }
    if ($a.Sid -match '^S-1-5-(18|19|20)$') {
        return [pscustomobject]@{ Ok=$false; Reason='service-account'; Detail="$($a.Name) [$($a.Sid)]" }
    }
    if ($a.Domain -and $a.Domain -ne $env:COMPUTERNAME) {
        return [pscustomobject]@{ Ok=$false; Reason='not-local'; Detail=$a.Name }
    }
    if ($a.Sid -match '^S-1-12-1-') {
        return [pscustomobject]@{ Ok=$false; Reason='not-local'; Detail="$($a.Name) [$($a.Sid)]" }
    }
    if (-not $a.Sid -or $a.Sid -notmatch '^S-1-5-21-') {
        return [pscustomobject]@{ Ok=$false; Reason='no-interactive-user'; Detail="$($a.Name) [$($a.Sid)]" }
    }
    $msa = Get-MicrosoftAccountId $a.Sid
    if ($msa -eq 'unknown') {
        return [pscustomobject]@{ Ok=$false; Reason='account-type-unknown'; Detail=$a.Name }
    }
    if ($msa) {
        return [pscustomobject]@{ Ok=$false; Reason='microsoft-account'; Detail="$($a.Name) -> $msa" }
    }
    if (-not (Test-LocalAdminSid $a.Sid $a.Name)) {
        return [pscustomobject]@{ Ok=$false; Reason='not-admin'; Detail=$a.Name; Sid=$a.Sid }
    }
    return [pscustomobject]@{ Ok=$true; Reason='ok'; Detail=$a.Name; Sid=$a.Sid }
}

$WinlogonKey        = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
$AutoLogonValues    = @('AutoAdminLogon','DefaultUserName','DefaultDomainName','DefaultPassword','AutoLogonCount')
$AccountSwapDir     = Join-Path $env:ProgramData 'AlleavesAuto'
$AccountSwapMarker  = Join-Path $AccountSwapDir 'logs\account_swap.json'
$AccountSwapTask    = 'AlleavesAuto-Resume'
$script:AccountSwapAttempted = $false
$script:AccountSwapDone      = $null
$script:AccountCheckOverride = $null

function ConvertFrom-SecureStringPlain([Security.SecureString]$s) {
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
    try   { return [Runtime.InteropServices.Marshal]::PtrToStringUni($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

# docs/ACCOUNT-SWAP.md#swap
function Read-SwapAnswer($prompt) {
    if (-not [Environment]::UserInteractive -or $env:ALLEAVES_NOPAUSE) {
        Write-Verbose "Read-SwapAnswer: unattended run - declining '$prompt'"
        return $null
    }
    try { return ("$(Read-Host $prompt)").Trim() } catch { Write-Verbose "Read-SwapAnswer: Read-Host failed (headless host?): $($_.Exception.Message)"; return $null }
}

function Confirm-Swap($prompt) {
    $a = Read-SwapAnswer "$prompt [y/N]"
    return ($a -and $a -match '^(y|yes)$')
}

# docs/ACCOUNT-SWAP.md#override
function Set-AccountCheckOverride($acct, $via) {
    $script:AccountCheckOverride = @{
        account = $acct.Detail
        reason  = $acct.Reason
        via     = $via
        whenUtc = (Get-Date).ToUniversalTime().ToString('o')
        removable = $false
    }
    Warn "account precheck OVERRIDDEN ($($acct.Reason): $($acct.Detail)) - continuing at the operator's request."
}

function Read-NewAccountName {
    for ($i = 0; $i -lt 3; $i++) {
        $n = Read-SwapAnswer "  New local admin account name [alleavespos]"
        if ($null -eq $n) { return $null }
        if (-not $n) { $n = 'alleavespos' }
        if ($n -eq $env:COMPUTERNAME) { Fail "'$n' is the computer name - pick another."; continue }
        $exists = $false
        try { Get-LocalUser -Name $n -ErrorAction Stop | Out-Null; $exists = $true } catch { Write-Verbose "Read-NewAccountName: '$n' does not exist (expected when the name is free): $($_.Exception.Message)" }
        if ($exists) { Fail "an account named '$n' already exists - pick another."; continue }
        return $n
    }
    return $null
}

function Read-NewAccountPassword($name) {
    for ($i = 0; $i -lt 3; $i++) {
        try {
            $p1 = Read-Host "  Password for '$name'" -AsSecureString
            $p2 = Read-Host "  Confirm password"     -AsSecureString
        } catch { Write-Verbose "Read-NewAccountPassword: prompt failed: $($_.Exception.Message)"; return $null }
        $t1 = ConvertFrom-SecureStringPlain $p1
        $t2 = ConvertFrom-SecureStringPlain $p2
        if (-not $t1)       { Fail 'password cannot be empty.'; continue }
        if ($t1 -ne $t2)    { Fail 'passwords did not match.';  continue }
        return @{ Secure = $p1; Plain = $t1 }
    }
    return $null
}

function Add-ToLocalAdmins($sid) {
    Add-LocalGroupMember -SID 'S-1-5-32-544' -Member $sid -ErrorAction Stop
}

# docs/ACCOUNT-SWAP.md#autologon
function Set-OneShotAutoLogon($name, $plainPassword) {
    $prior = @{}
    foreach ($v in $AutoLogonValues) {
        try {
            $cur = (Get-ItemProperty -Path $WinlogonKey -Name $v -ErrorAction Stop).$v
            $prior[$v] = @{
                present = $true
                value   = $(if ($v -eq 'DefaultPassword') { $null } else { $cur })
                type    = $(try { (Get-Item $WinlogonKey).GetValueKind($v).ToString() } catch { $null })
            }
        } catch { Write-Verbose "Set-OneShotAutoLogon: could not read prior '$v': $($_.Exception.Message)"; $prior[$v] = @{ present = $false; value = $null; type = $null } }
    }
    $script:AutoLogonPrior = $prior
    New-ItemProperty -Path $WinlogonKey -Name 'AutoLogonCount'    -Value 1              -PropertyType DWord  -Force -EA Stop | Out-Null
    New-ItemProperty -Path $WinlogonKey -Name 'AutoAdminLogon'    -Value '1'            -PropertyType String -Force -EA Stop | Out-Null
    New-ItemProperty -Path $WinlogonKey -Name 'DefaultUserName'   -Value $name          -PropertyType String -Force -EA Stop | Out-Null
    New-ItemProperty -Path $WinlogonKey -Name 'DefaultDomainName' -Value $env:COMPUTERNAME -PropertyType String -Force -EA Stop | Out-Null
    New-ItemProperty -Path $WinlogonKey -Name 'DefaultPassword'   -Value $plainPassword -PropertyType String -Force -EA Stop | Out-Null
}

# docs/ACCOUNT-SWAP.md#autologon  (DefaultPassword is REMOVED, never restored; returns a count or $null)
function Restore-AutoLogon($prior) {
    if (-not $prior) { return $null }
    $failed = 0
    foreach ($v in $AutoLogonValues) {
        $p = $prior.$v
        try {
            if ($p -and $p.present -and $v -ne 'DefaultPassword') {
                $type = if ($p.type) { $p.type } elseif ($v -eq 'AutoLogonCount') { 'DWord' } else { 'String' }
                New-ItemProperty -Path $WinlogonKey -Name $v -Value $p.value -PropertyType $type -Force -EA Stop | Out-Null
            } else {
                Remove-ItemProperty -Path $WinlogonKey -Name $v -Force -EA SilentlyContinue
                if ($v -eq 'DefaultPassword' -and (Get-ItemProperty -Path $WinlogonKey -Name $v -EA SilentlyContinue)) {
                    throw 'the value is still present after the removal'
                }
            }
        } catch { Warn "could not restore Winlogon\$v : $($_.Exception.Message)"; $failed++ }
    }
    return $failed
}

# docs/ACCOUNT-SWAP.md#resume-task
function ConvertTo-ResumeArgs($bound) {
    $q = { param($s) "'" + ("$s" -replace "'", "''") + "'" }
    $out = @()
    foreach ($k in $bound.Keys) {
        if ($k -eq 'DryRun') { continue }
        if ($k -eq 'NiceLabelLicense') { Warn 'the resumed run falls back to the built-in NiceLabel license - the key is not persisted to the resume task'; continue }
        $v = $bound[$k]
        if ($v -is [switch]) { if ($v.IsPresent) { $out += "-$k" } }
        elseif ($v -is [array]) {
            if ($v.Count) { $out += "-$k"; $out += (($v | ForEach-Object { & $q $_ }) -join ',') }
        }
        else { $out += "-$k"; $out += (& $q $v) }
    }
    return ($out -join ' ')
}

function Register-ResumeTask($name, $scriptCopy, $argLine) {
    $inner = "& '" + ("$scriptCopy" -replace "'","''") + "'"
    if ($argLine) { $inner += " $argLine" }
    $arg = "-NoProfile -ExecutionPolicy Bypass -Command `"$inner`""
    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
    $trigger   = New-ScheduledTaskTrigger -AtLogOn -User "$env:COMPUTERNAME\$name"
    $principal = New-ScheduledTaskPrincipal -UserId "$env:COMPUTERNAME\$name" -LogonType Interactive -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                                              -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero)
    $def = New-ScheduledTask -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
                             -Description 'AlleavesAuto: resume the install after the account swap.'
    Register-ScheduledTask -TaskName $AccountSwapTask -InputObject $def -Force -EA Stop | Out-Null
}

# docs/ACCOUNT-SWAP.md#clear-state
function Clear-AccountSwapState {
    if (-not (Test-Path $AccountSwapMarker)) { return }
    # docs/ACCOUNT-SWAP.md#loop-guard
    $script:AccountSwapAttempted = $true
    Step 'Account swap: resuming (clearing one-shot state)'
    if ($DryRun) { Dry 'swap marker present - would clear autologon, remove the resume task and delete the marker'; return }
    $m = $null
    try { $m = Get-Content $AccountSwapMarker -Raw -EA Stop | ConvertFrom-Json -EA Stop } catch {
        Warn "account swap marker unreadable: $($_.Exception.Message)"
    }
    try {
        Unregister-ScheduledTask -TaskName $AccountSwapTask -Confirm:$false -EA Stop
        Ok "removed resume task '$AccountSwapTask'"
    } catch { Warn "could not remove resume task '$AccountSwapTask': $($_.Exception.Message)" }
    $taskGone = $true
    try { if (Get-ScheduledTask -TaskName $AccountSwapTask -EA SilentlyContinue) { $taskGone = $false } } catch { Write-Verbose "Clear-AccountSwapState: Get-ScheduledTask readback failed: $($_.Exception.Message)" }
    if ($m) {
        $restoreFailures = Restore-AutoLogon $m.winlogonPrior
        if ($null -ne $restoreFailures) {
            if ($restoreFailures -eq 0) { Ok 'autologon values restored to their pre-swap state' }
            else {
                Fail "$restoreFailures autologon value(s) could not be restored - check Winlogon by hand"
                $script:FinishFailed = $true
            }
        }
        $script:AccountSwapDone = @{ name=$m.account; sid=$m.sid; created=[bool]$m.created; removable=$false }
        Ok "resumed as '$($m.account)'"
    }
    if (-not $taskGone) {
        Fail "resume task '$AccountSwapTask' is STILL registered - keeping the swap marker so the next run retries."
        Fail "Remove it by hand if this persists: Unregister-ScheduledTask -TaskName '$AccountSwapTask' -Confirm:`$false"
        $script:FinishFailed = $true
        return
    }
    try { Remove-Item (Join-Path $AccountSwapDir 'resume') -Recurse -Force -EA SilentlyContinue } catch { Write-Verbose "Clear-AccountSwapState: could not remove the staged resume copy: $($_.Exception.Message)" }
    Remove-Item $AccountSwapMarker -Force -EA SilentlyContinue
    if (Test-Path $AccountSwapMarker) {
        Warn 'could not delete the swap marker - the next run will re-enter the resume path'
        $script:FinishFailed = $true
    }
}

# docs/ACCOUNT-SWAP.md#swap  ($rollback: docs/ACCOUNT-SWAP.md#rollback)
function Invoke-AccountSwapOffer($acct, $bound, $promote) {
    Info ''
    if ($promote) {
        Info "  This script can promote '$($acct.Detail)' to local administrator and"
        Info '  reboot; the install then resumes automatically once you sign back in.'
        if (-not (Confirm-Swap "  Promote '$($acct.Detail)' and reboot to resume?")) { return $false }
    } else {
        Info '  This script can create a local administrator account, sign the terminal'
        Info '  into it automatically on the next boot, and resume the install there.'
        Write-Host '  NOTE: the password is stored in the registry until that one auto sign-in' -ForegroundColor Yellow
        Write-Host '  completes, which clears it. Reboot promptly.' -ForegroundColor Yellow
        if (-not (Confirm-Swap '  Create a local admin account and reboot to resume?')) { return $false }
    }

    $name = $null; $sid = $null; $created = $false; $pw = $null
    if ($promote) {
        $name = $acct.Detail.Split('\')[-1]
        $sid  = $acct.Sid
    } else {
        $name = Read-NewAccountName
        if (-not $name) { Fail 'no account name given - nothing was changed.'; return $false }
        $pw = Read-NewAccountPassword $name
        if (-not $pw) { Fail 'no password given - nothing was changed.'; return $false }
    }

    $resumeDir  = Join-Path $AccountSwapDir 'resume'
    $scriptCopy = Join-Path $resumeDir 'alleaves_setup.ps1'

    $script:AutoLogonPrior = $null
    $rollback = {
        $restoreFailures = Restore-AutoLogon $script:AutoLogonPrior
        if ($restoreFailures) { Fail 'autologon could NOT be fully cleared - check Winlogon by hand' }
        $taskLeft = $false
        try { Unregister-ScheduledTask -TaskName $AccountSwapTask -Confirm:$false -EA Stop } catch { Write-Verbose "swap rollback: Unregister-ScheduledTask threw (may never have been registered): $($_.Exception.Message)" }
        try { if (Get-ScheduledTask -TaskName $AccountSwapTask -EA SilentlyContinue) { $taskLeft = $true } } catch { Write-Verbose "swap rollback: Get-ScheduledTask readback failed: $($_.Exception.Message)" }
        if ($taskLeft) {
            Fail "resume task '$AccountSwapTask' could NOT be removed during the rollback."
            Fail "Remove it by hand: Unregister-ScheduledTask -TaskName '$AccountSwapTask' -Confirm:`$false"
        }
        if ($created) {
            try { Remove-LocalUser -SID $sid -EA Stop; Warn "rolled back: removed '$name'" }
            catch { Warn "could not remove '$name' after the failed swap: $($_.Exception.Message)" }
        }
        try { Remove-Item $resumeDir -Recurse -Force -EA SilentlyContinue } catch { Write-Verbose "swap rollback: could not remove the resume dir: $($_.Exception.Message)" }
        foreach ($d in @((Split-Path $AccountSwapMarker -Parent), $AccountSwapDir)) {
            try {
                if ((Test-Path -LiteralPath $d) -and -not (Get-ChildItem -LiteralPath $d -Force -EA Stop)) {
                    Remove-Item -LiteralPath $d -Force -EA SilentlyContinue
                }
            } catch { Write-Verbose "swap rollback: '$d' unreadable, leaving it: $($_.Exception.Message)" }
        }
    }

    try {
        New-Item -ItemType Directory -Force -Path $resumeDir -EA Stop | Out-Null
        New-Item -ItemType Directory -Force -Path (Split-Path $AccountSwapMarker -Parent) -EA Stop | Out-Null
        Copy-Item -LiteralPath $PSCommandPath -Destination $scriptCopy -Force -EA Stop
    } catch { Fail "could not stage the resume script: $($_.Exception.Message)"; & $rollback; return $false }

    if (-not $promote) {
        try {
            $u = New-LocalUser -Name $name -Password $pw.Secure -PasswordNeverExpires -AccountNeverExpires `
                               -Description 'Alleaves POS terminal administrator' -EA Stop
            $sid = $u.SID.Value; $created = $true
            Ok "created local account '$name'"
        } catch { Fail "could not create '$name': $($_.Exception.Message)"; & $rollback; return $false }
    }
    try { Add-ToLocalAdmins $sid; Ok "'$name' is now a local administrator" }
    catch {
        if ($_.FullyQualifiedErrorId -notlike 'MemberExists*') {
            Fail "could not add '$name' to Administrators: $($_.Exception.Message)"; & $rollback; return $false
        }
        Ok "'$name' was already a member of Administrators"
    }

    if (-not $promote) {
        try { Set-OneShotAutoLogon $name $pw.Plain; Ok 'armed one-shot autologon (clears itself after the next sign-in)' }
        catch { Fail "could not arm autologon: $($_.Exception.Message)"; & $rollback; return $false }
    }

    try { Register-ResumeTask $name $scriptCopy (ConvertTo-ResumeArgs $bound); Ok "registered resume task '$AccountSwapTask'" }
    catch {
        Fail "could not register the resume task: $($_.Exception.Message)"
        & $rollback
        return $false
    }

    $marker = @{
        account = $name; sid = $sid; created = $created
        winlogonPrior = $script:AutoLogonPrior; taskName = $AccountSwapTask; scriptCopy = $scriptCopy
        armedUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
    try { $marker | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $AccountSwapMarker -Encoding UTF8 -EA Stop }
    catch {
        Fail "could not write the swap marker: $($_.Exception.Message)"
        Fail 'rolling back - an armed swap with no marker never turns itself off.'
        & $rollback
        return $false
    }

    Info ''
    if ($promote) {
        Ok "Reboot, sign in as '$name', and the install resumes on its own."
    } else {
        Ok "Reboot and the terminal signs into '$name' automatically; the install resumes there."
    }
    if (Confirm-Swap '  Reboot now?') {
        Warn 'rebooting in 15 seconds...'
        & shutdown /r /t 15 /c 'AlleavesAuto: rebooting to finish the account swap and resume the install.'
    } else {
        Warn 'not rebooting. The install resumes automatically on the next boot.'
    }
    return $true
}

$Mode = if ($Uninstall) { 'Uninstall' } elseif ($ScannerConfigOnly) { 'ScannerConfig' } elseif ($PrinterConfigOnly) { 'PrinterConfig' } else { 'Install' }
Write-Host "Alleaves setup - parsed MODE: $Mode" -ForegroundColor Cyan
Info ("  Args: Uninstall={0} DryRun={1} SkipMasterList={2} SkipUninstallTeamViewer={3} ForceReinstall={4} ScannerConfigOnly={5} ForceFingerprint={6} SkipPrograms='{7}'" -f `
    $Uninstall, $DryRun, $SkipMasterList, $SkipUninstallTeamViewer, $ForceReinstall, $ScannerConfigOnly, $ForceFingerprint, ($SkipPrograms -join ','))
Info ("        ComputerName='{0}' SkipRename={1} SkipChromeTaskbar={2} SkipDefaultBrowser={3} SkipChromeBookmark={4} SkipScannerConfig={5}" -f `
    $ComputerName, $SkipRename, $SkipChromeTaskbar, $SkipDefaultBrowser, $SkipChromeBookmark, $SkipScannerConfig)
Info ("        PrinterBrand='{0}' SkipPrinterConfig={1} PrinterConfigOnly={2} IgnoreAccountCheck={3}" -f `
    $PrinterBrand, $SkipPrinterConfig, $PrinterConfigOnly, $IgnoreAccountCheck)

# docs/ARCHITECTURE.md#argument-guards-exit-2  (#positional)
if ($UnknownArgs) {
    Fail "Unexpected argument(s): $($UnknownArgs -join ' ')"
    Fail "Every option takes a leading dash - see README.md. Did you mean -$($UnknownArgs[0])?"
    exit 2
}
$requested = $env:ALLEAVES_REQUESTED_MODE
if ($requested) {
    Info "  Launcher requested mode: $requested"
    if ($requested -eq 'uninstall' -and -not $Uninstall) {
        Fail "Launcher requested UNINSTALL but -Uninstall did not survive. Refusing to run INSTALL."
        exit 2
    }
}

if ($ScannerConfigOnly -and $Uninstall) {
    Fail "-ScannerConfigOnly and -Uninstall are mutually exclusive."
    exit 2
}
if ($ScannerConfigOnly -and $SkipScannerConfig) {
    Fail "-ScannerConfigOnly and -SkipScannerConfig are mutually exclusive (that run would do nothing)."
    exit 2
}

if ($PrinterConfigOnly -and ($Uninstall -or $ScannerConfigOnly)) {
    Fail "-PrinterConfigOnly cannot be combined with -Uninstall or -ScannerConfigOnly."
    exit 2
}
if ($PrinterConfigOnly -and $SkipPrinterConfig) {
    Fail "-PrinterConfigOnly and -SkipPrinterConfig are mutually exclusive (that run would do nothing)."
    exit 2
}
if ($PrinterConfigOnly -and $PrinterBrand -eq 'None') {
    Fail "-PrinterConfigOnly and -PrinterBrand None are mutually exclusive (that run would do nothing)."
    exit 2
}
if ($ComputerName -and $SkipRename) {
    Fail "-ComputerName and -SkipRename are mutually exclusive (the name would be ignored)."
    exit 2
}
if ($PSBoundParameters.ContainsKey('NiceLabelLicense') -and $SkipNiceLabelActivation) {
    Fail "-NiceLabelLicense and -SkipNiceLabelActivation are mutually exclusive (the license would be ignored)."
    exit 2
}
foreach ($frag in $SkipPrograms) {
    if (-not $frag) { continue }
    try { $null = '' -match $frag }
    catch {
        Fail "-SkipPrograms fragment '$frag' is not a valid regex: $($_.Exception.Message)"
        exit 2
    }
}

# docs/ARCHITECTURE.md#order-of-operations
if (-not $IsAdmin -and -not $DryRun) {
    Fail "Not elevated. This script must be launched by Install-Alleaves.bat (single elevation owner)."
    Fail "Run the .bat (one UAC prompt), or pass -DryRun for a non-elevated plumbing test."
    exit 3
}

# Initialized HERE, not with the other flags below: Clear-AccountSwapState sets it, in every mode.
# docs/ARCHITECTURE.md#what-folds-into-exit-1
$script:FinishFailed = $false
Clear-AccountSwapState

if (-not $Uninstall) {
    $acct = Test-InstallAccount
    if ($acct.Ok) {
        Ok "signed-in account '$($acct.Detail)' is a local administrator"
    } else {
        Fail "Account precheck FAILED - this terminal is not ready for the Alleaves install."
        switch ($acct.Reason) {
            'microsoft-account' {
                Fail "Signed in with a MICROSOFT ACCOUNT: $($acct.Detail)"
                Fail "Alleaves must be installed from a plain LOCAL administrator account."
            }
            'not-local' {
                Fail "Signed in with a DOMAIN / ENTRA ID account: $($acct.Detail)"
                Fail "Alleaves must be installed from a plain LOCAL administrator account."
            }
            'not-admin' {
                Fail "Signed-in account '$($acct.Detail)' is NOT a local administrator."
                Fail "Elevating this run with someone else's credentials is not enough - the"
                Fail "account the terminal is signed into is the one that has to be an admin."
            }
            'service-account' {
                Fail "Ran with NO console session: the precheck could only see this process's"
                Fail "own token ($($acct.Detail))."
                Fail "That is a service identity, not a user - the account the terminal is"
                Fail "actually signed into was never examined, and the install will not guess."
            }
            'account-type-unknown' {
                Fail "Could not determine whether '$($acct.Detail)' is a local or a Microsoft"
                Fail "account - every probe declined to answer. The install will not guess:"
                Fail "a Microsoft account ties this terminal to someone's personal MSA and"
                Fail "OneDrive can redirect Documents, where the master list is copied."
            }
            default {
                Fail "Could not identify an interactive signed-in user ($($acct.Detail))."
                Fail "Run this from the terminal's own signed-in local administrator session."
            }
        }
        Info ''
        if ($acct.Reason -eq 'service-account') {
            Info "  Fix it - run this from the terminal's own signed-in session:"
            Info "    1. Sign into the terminal as its local administrator account"
            Info '    2. Run Install-Alleaves.bat from that session'
            Info '    An RMM running as SYSTEM cannot answer this check - dispatch it to the'
            Info '    logged-on user instead, or run it by hand.'
        }
        elseif ($acct.Reason -eq 'not-admin') {
            Info '  Fix it - promote the signed-in account:'
            Info '    1. Settings > Accounts > Other users > (the account) > Change account type'
            Info '    2. Account type = Administrator'
            Info '    3. Sign out and back in, then re-run Install-Alleaves.bat'
            Info "    CLI:  net localgroup Administrators `"$($acct.Detail.Split('\')[-1])`" /add"
        } else {
            Info '  Fix it - create a local administrator account and sign into it:'
            Info '    1. Settings > Accounts > Other users > Add account'
            Info "    2. Choose 'I don't have this person's sign-in information'"
            Info "    3. Choose 'Add a user without a Microsoft account', set a name + password"
            Info '    4. Change account type > Administrator'
            Info '    5. Sign into that account, then re-run Install-Alleaves.bat'
            Info '    CLI:  net user <name> <password> /add'
            Info '          net localgroup Administrators <name> /add'
        }
        Info ''
        $continueMsg = '  Continue the install anyway on this account (NOT recommended)?'
        # docs/ACCOUNT-SWAP.md#override  (the offer itself: docs/ACCOUNT-SWAP.md#swap)
        $wouldOffer = (-not $script:AccountSwapAttempted -and $acct.Reason -ne 'service-account')
        $wouldPromote = ($acct.Reason -eq 'not-admin' -and $acct.Sid)
        if ($IgnoreAccountCheck) {
            Set-AccountCheckOverride $acct 'IgnoreAccountCheck'
        }
        elseif ($DryRun) {
            if (-not $wouldOffer) {
                Dry $(if ($script:AccountSwapAttempted) { 'a swap was already attempted this cycle - would NOT offer another' }
                      else { 'would NOT offer an account swap - a service identity is fixed by launching from a console session, not by a new account' })
            } else {
                Dry $(if ($wouldPromote) { "would offer to promote '$($acct.Detail)' and reboot to resume" }
                      else                { 'would offer to create a local admin account, arm a one-shot autologon, and reboot to resume' })
            }
            Dry 'would then offer to continue anyway; declining blocks a real run (exit 8)'
            Dry 'account precheck would block a real run (exit 8) - continuing, -DryRun changes nothing'
        }
        elseif ($script:AccountSwapAttempted) {
            Fail 'an account swap was already attempted this cycle; not offering another.'
            if (Confirm-Swap $continueMsg) { Set-AccountCheckOverride $acct 'prompt' }
            else { exit 8 }
        }
        elseif ($wouldOffer -and (Invoke-AccountSwapOffer $acct $PSBoundParameters $wouldPromote)) {
            exit 9
        }
        elseif (Confirm-Swap $continueMsg) { Set-AccountCheckOverride $acct 'prompt' }
        else { exit 8 }
    }
}

# docs/ARCHITECTURE.md#run-shape  (not caller-overridable: docs/INSTALL-ENGINE.md#is5-buffer)
$WorkDir = if ($IsAdmin) { Join-Path $env:ProgramData 'AlleavesAuto' } else { Join-Path $env:TEMP 'AlleavesAuto' }
$DownloadDir  = Join-Path $WorkDir 'downloads'
$LogDir       = Join-Path $WorkDir 'logs'
# Always the REAL manifest, even when $WorkDir fell back: docs/ARCHITECTURE.md#run-shape
$ManifestPath = Join-Path $env:ProgramData 'AlleavesAuto\logs\install_manifest.json'
try {
    New-Item -ItemType Directory -Force -Path $DownloadDir -ErrorAction Stop | Out-Null
    New-Item -ItemType Directory -Force -Path $LogDir      -ErrorAction Stop | Out-Null
    $probe = Join-Path $LogDir '.writeprobe'
    [IO.File]::WriteAllText($probe, 'ok')
    Remove-Item $probe -Force -ErrorAction SilentlyContinue
} catch {
    Fail "could not create or write the working directory '$WorkDir': $($_.Exception.Message)"
    exit 5
}

$script:DownloadFailed  = $false
# Flags feeding the exit tally: docs/ARCHITECTURE.md#exit-codes
$script:StepFailed      = $false
$script:RebootPending   = $false
$script:FinishBrowser   = $false
$script:FinishTaskbar   = $false
$script:TaskbarStamp    = ''
$script:ScannerDegraded = $false
$script:ScannerConfigFailed = $false
$script:PrinterConfigFailed = $false
$script:PrinterBrandResolved = $null
$script:ManifestWriteFailed = $false
$script:UserAgent       = 'Mozilla/5.0 AlleavesAuto/1.0'

$AlleavesUrl = 'https://app.alleaves.com'

$UninstallHives = @(
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
)

# docs/INSTALL-ENGINE.md#uninstall
function Find-InstalledProducts {
    param([Parameter(Mandatory)][string]$Pattern)
    foreach ($h in $UninstallHives) {
        Get-ItemProperty $h -ErrorAction SilentlyContinue |
            Where-Object {
                $_.DisplayName -and $_.DisplayName -match $Pattern -and
                ($_.PSChildName -notlike 'InstallShield_*')
            }
    }
}

# docs/INSTALL-ENGINE.md#nicelabel-uninstall  (msiexec + an explicit Suite-residue sweep)
function Remove-NiceLabel {
    param([string]$DisplayName, [string]$Cmd, [string]$ProductCode)
    if ($DryRun) { Dry "would remove NiceLabel via msiexec /x + Suite residue cleanup: $DisplayName ($ProductCode)"; return $true }
    $nlDir = (Find-InstalledProducts -Pattern '(?i)NiceLabel' |
              Where-Object { $_.PSChildName -eq $ProductCode -and $_.InstallLocation } |
              Select-Object -First 1).InstallLocation
    Get-Service -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'NiceLabel*' -and $_.Status -ne 'Stopped' } |
        ForEach-Object { Stop-Service $_.Name -Force -ErrorAction SilentlyContinue }
    $guid = if ($ProductCode -match '^\{[0-9A-Fa-f-]+\}$') { $ProductCode } else {
        (Find-InstalledProducts -Pattern '(?i)NiceLabel' |
         Where-Object { $_.PSChildName -match '^\{[0-9A-Fa-f-]+\}$' } |
         Select-Object -First 1).PSChildName
    }
    $nlOk = $true
    if ($guid) {
        Info "  NiceLabel: msiexec.exe /x $guid /qn /norestart (Suite MSI)"
        $mp = Start-Process msiexec.exe -ArgumentList "/x $guid /qn /norestart" -Wait -PassThru -WindowStyle Hidden
        $nlOk = ($mp.ExitCode -in @(0,3010,1641,1605))
        if (-not $nlOk) { Warn "NiceLabel msiexec /x $guid exited $($mp.ExitCode)" }
    }
    $residueOk  = $true
    $removedKey = $false
    Find-InstalledProducts -Pattern '(?i)NiceLabel' |
        Where-Object { $_.PSChildName -eq $ProductCode } |
        ForEach-Object {
            $arp = $_.PSChildName
            try { Remove-Item $_.PSPath -Recurse -Force -ErrorAction Stop; $removedKey = $true }
            catch { Warn "could not remove NiceLabel Suite ARP ${arp}: $($_.Exception.Message)"; $residueOk = $false }
        }
    $svcOk = $true
    foreach ($svc in @(Get-Service -ErrorAction SilentlyContinue |
                       Where-Object { $_.Name -like 'NiceLabel*' } | Select-Object -ExpandProperty Name)) {
        & "$env:SystemRoot\System32\sc.exe" delete $svc | Out-Null
        if ($LASTEXITCODE -eq 0) { Info "  removed NiceLabel service: $svc" }
        else { Warn "could not remove NiceLabel service ${svc}: sc.exe exit $LASTEXITCODE"; $svcOk = $false }
    }
    foreach ($p in @(Get-ChildItem 'HKLM:\SOFTWARE\Classes\Installer\Products' -ErrorAction SilentlyContinue |
                     Where-Object { (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).ProductName -match '(?i)NiceLabel' })) {
        $feat = "HKLM:\SOFTWARE\Classes\Installer\Features\$($p.PSChildName)"
        if (Test-Path $feat) {
            try { Remove-Item $feat -Recurse -Force -ErrorAction Stop }
            catch { Warn "could not remove NiceLabel Installer Features key $($p.PSChildName): $($_.Exception.Message)"; $residueOk = $false }
        }
        try { Remove-Item $p.PSPath -Recurse -Force -ErrorAction Stop }
        catch { Warn "could not remove NiceLabel Installer Products key $($p.PSChildName): $($_.Exception.Message)"; $residueOk = $false }
    }
    foreach ($u in @(Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products' -ErrorAction SilentlyContinue |
                     Where-Object { (Get-ItemProperty "$($_.PSPath)\InstallProperties" -ErrorAction SilentlyContinue).DisplayName -match '(?i)NiceLabel' })) {
        try { Remove-Item $u.PSPath -Recurse -Force -ErrorAction Stop }
        catch { Warn "could not remove NiceLabel UserData product key $($u.PSChildName): $($_.Exception.Message)"; $residueOk = $false }
    }
    if ($Cmd -match '([A-Za-z]:\\ProgramData\\\{[0-9A-Fa-f-]+\})') {
        $nlCache = $Matches[1]
        if (Test-Path $nlCache) {
            try { Remove-Item $nlCache -Recurse -Force -ErrorAction Stop }
            catch { Warn "could not remove NiceLabel bootstrapper cache ${nlCache}: $($_.Exception.Message)"; $residueOk = $false }
        }
    }
    if ($nlDir -and $nlDir -match '(?i)NiceLabel' -and (Test-Path $nlDir)) {
        try { Remove-Item $nlDir -Recurse -Force -ErrorAction Stop; Info "  removed NiceLabel program files: $nlDir" }
        catch { Warn "could not fully remove NiceLabel program files ${nlDir}: $($_.Exception.Message)"; $residueOk = $false }
    }
    if (-not $svcOk -or -not $residueOk) {
        Fail "NiceLabel residue survived (service / registry / files - see warnings above) - reboot and re-run -Uninstall: $DisplayName"
        return $false
    }
    if ($guid) {
        if (-not $nlOk) { Fail "NiceLabel not removed (msiexec exit $($mp.ExitCode)): $DisplayName"; return $false }
    } else {
        if (Find-InstalledProducts -Pattern '(?i)NiceLabel') {
            Fail "NiceLabel not fully removed (no product GUID resolved; still in registry): $DisplayName"; return $false
        }
    }
    Ok "removed NiceLabel: $DisplayName$(if ($removedKey) { ' (+ Suite residue)' } else { '' })"
    return $true
}

# docs/INSTALL-ENGINE.md#uninstall-flags
function Invoke-SilentUninstall {
    param([string]$DisplayName, [string]$UninstallString, [string]$QuietUninstallString, [string]$ProductCode)
    $UninstallTimeoutMs = 360000
    $cmd = if ($QuietUninstallString) { $QuietUninstallString } else { $UninstallString }
    if ($cmd -match '(?i)NiceLabel\d*\.exe') { return (Remove-NiceLabel -DisplayName $DisplayName -Cmd $cmd -ProductCode $ProductCode) }
    if (-not $cmd) { Warn "no uninstall command for $DisplayName"; return $false }
    $okCodes = @(0, 3010, 1641, 1605)
    # docs/INSTALL-ENGINE.md#anchoring  (exact entry, both families: #exit0-recheck)
    $escName = '^' + [regex]::Escape($DisplayName) + '$'
    if ($DryRun) { Dry "would uninstall: $cmd"; return $true }
    Info "  $DisplayName"
    Info "    cmd: $cmd"
    try {
        if ($cmd -match '(?i)msiexec') {
            $argstr = ($cmd -replace '(?i)^.*?msiexec(\.exe)?"?\s*','').Trim()
            $argstr = $argstr -replace '(?i)/I\{','/X{' -replace '(?i)/I ','/X '
            if ($argstr -notmatch '/qn|/quiet') { $argstr += ' /qn /norestart' }
            $p = Start-Process -FilePath 'msiexec.exe' -ArgumentList $argstr -Wait -PassThru -WindowStyle Hidden
        } else {
            if ($cmd -match '(?i)^\s*"?(.*?\.exe)"?\s*(.*)$') { $exe=$Matches[1]; $rest=$Matches[2] }
            elseif ($cmd -match '^"([^"]+)"\s*(.*)$') { $exe=$Matches[1]; $rest=$Matches[2] }
            else { $parts = $cmd -split ' ',2; $exe=$parts[0]; $rest = if($parts.Length -gt 1){$parts[1]}else{''} }
            if ($exe -match '(?i)\\Google\\Chrome\\' -or $rest -match '(?i)(^|\s)--uninstall(\s|$)') {
                if ($rest -notmatch '(?i)--force-uninstall') { $rest = ($rest + ' --force-uninstall').Trim() }
                $okCodes = @(0, 19, 29)
            } elseif ($exe -match '(?i)\\(IsUninst|_isdel)\.exe$') {
                if ($rest -notmatch '(?i)(^|\s)-a(\s|$)') { $rest = ('-a ' + $rest).Trim() }
                if ($rest -notmatch '(?i)(^|\s)-y(\s|$)') { $rest = ('-y ' + $rest).Trim() }
            } elseif ($rest -match '(?i)-removeonly|isuninst|InstallShield') {
                if ($rest -notmatch '(?i)(^|\s)-s(\s|$)') { $rest = ($rest + ' -s').Trim() }
            } elseif ($rest -notmatch '/S|/silent|/quiet|--silent') {
                $rest = ($rest + ' /S').Trim()
            }
            $spArgs = @{ FilePath=$exe; PassThru=$true; WindowStyle='Hidden'; ErrorAction='Stop' }
            if ($rest) { $spArgs['ArgumentList'] = $rest }
            $p = Start-Process @spArgs

            $started  = Get-Date
            $deadline = $started.AddMilliseconds($UninstallTimeoutMs)
            # docs/INSTALL-ENGINE.md#hang-heuristic
            # ponytail: flat 60 s floor; per-family floors only if a vendor ever needs one.
            while ($true) {
                if ($p.WaitForExit(5000)) { break }
                if (((Get-Date) - $started).TotalSeconds -ge 60 -and -not (Find-InstalledProducts -Pattern $escName)) {
                    Warn "$DisplayName gone from registry but uninstaller still running - killing orphan"
                    try { $p.Kill(); $p.WaitForExit(10000) | Out-Null } catch { Write-Verbose "Invoke-SilentUninstall: could not kill the hung uninstaller: $($_.Exception.Message)" }
                    Ok "removed $DisplayName (uninstaller hung post-removal; registry confirms gone)"
                    return $true
                }
                if ((Get-Date) -ge $deadline) {
                    Warn "$DisplayName uninstaller exceeded $([int]($UninstallTimeoutMs/1000))s - killing"
                    try { $p.Kill(); $p.WaitForExit(10000) | Out-Null } catch { Write-Verbose "Invoke-SilentUninstall: could not kill the hung uninstaller: $($_.Exception.Message)" }
                    if (-not (Find-InstalledProducts -Pattern $escName)) { Ok "removed $DisplayName (registry confirms gone)"; return $true }
                    Warn "$DisplayName still in registry after timeout - may not be fully removed"; return $false
                }
            }
        }
        if ($p.ExitCode -in $okCodes) {
            # docs/INSTALL-ENGINE.md#exit0-recheck
            # ponytail: flat 60 s ceiling, matching the hang floor above.
            if ($p.ExitCode -notin @(3010,1641)) {
                $arpDeadline = (Get-Date).AddSeconds(60)
                while ((Find-InstalledProducts -Pattern $escName) -and (Get-Date) -lt $arpDeadline) {
                    Start-Sleep -Seconds 3
                }
                if (Find-InstalledProducts -Pattern $escName) {
                    Warn "$DisplayName still in registry 60s after uninstaller exit $($p.ExitCode) - not removed"; return $false
                }
            }
            Ok "removed $DisplayName (exit $($p.ExitCode))"; return $true
        }
        Warn "$DisplayName uninstaller exited $($p.ExitCode)"; return $false
    } catch {
        Warn "uninstall failed: $($_.Exception.Message)"; return $false
    }
}

# docs/INSTALL-ENGINE.md#pre-clean
# Returns a FAILURE COUNT, not a bool: docs/MANIFEST.md#counting
function Remove-InstallShieldOrphans {
    param([Parameter(Mandatory)][string]$Pattern)
    $failed = 0
    foreach ($h in $UninstallHives) {
        Get-ItemProperty $h -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -like 'InstallShield_*' -and $_.DisplayName -and $_.DisplayName -match $Pattern } |
            ForEach-Object {
                $arp  = $_.PSChildName
                $guid = ($arp -replace '^InstallShield_','')
                if ($DryRun) { Dry "would remove orphan ARP $arp ($($_.DisplayName))"; return }
                try { Remove-Item $_.PSPath -Recurse -Force -ErrorAction Stop; Ok "removed orphan ARP entry: $($_.DisplayName)" }
                catch { Warn "could not remove orphan ARP ${arp}: $($_.Exception.Message)"; $failed++ }
                $isf = Join-Path ${env:ProgramFiles(x86)} "InstallShield Installation Information\$guid"
                if (Test-Path $isf) {
                    try { Remove-Item $isf -Recurse -Force -ErrorAction Stop; Ok "removed InstallShield cache folder: $guid" }
                    catch { Warn "could not remove IS cache ${guid}: $($_.Exception.Message)"; $failed++ }
                }
            }
    }
    return $failed
}


# docs/INSTALL-ENGINE.md#download
function Set-Tls12 {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]3072
}

# docs/INSTALL-ENGINE.md#truncation
function Test-RealBinary {
    param([string]$Path)
    try {
        $fs = [IO.File]::OpenRead($Path)
        try {
            $buf = New-Object byte[] 8
            $n = $fs.Read($buf, 0, 8)
        } finally { $fs.Close() }
    } catch { Write-Verbose "Test-RealBinary: cannot read '$Path': $($_.Exception.Message)"; return $false }
    if ($n -lt 8) { return $false }
    if ($buf[0] -eq 0x3C) { return $false }
    if ($buf[0] -eq 0x50 -and $buf[1] -eq 0x4B -and $buf[2] -eq 0x03 -and $buf[3] -eq 0x04) { return $true }
    if ($buf[0] -eq 0xD0 -and $buf[1] -eq 0xCF -and $buf[2] -eq 0x11 -and $buf[3] -eq 0xE0) { return $true }
    if ($buf[0] -eq 0x4D -and $buf[1] -eq 0x5A) { return $true }
    return $false
}

# docs/INSTALL-ENGINE.md#truncation
function Save-FileSizeSidecar {
    param([string]$Path)
    try {
        $size = (Get-Item -LiteralPath $Path -ErrorAction Stop).Length
        Set-Content -LiteralPath "$Path.len" -Value $size -Encoding ASCII -ErrorAction Stop
    } catch { Warn "could not write size sidecar for ${Path}: $($_.Exception.Message)" }
}
# docs/INSTALL-ENGINE.md#truncation
function Test-CachedFileValid {
    param([string]$Path)
    if (-not (Test-RealBinary $Path)) { return $false }
    $lenFile = "$Path.len"
    if (-not (Test-Path -LiteralPath $lenFile)) { return $false }
    $expected = $null
    try { $expected = [int64]((Get-Content -LiteralPath $lenFile -Raw -ErrorAction Stop).Trim()) } catch { Write-Verbose "Test-CachedFileValid: no usable .len sidecar: $($_.Exception.Message)"; return $false }
    if ($expected -le 0) { return $false }
    $actual = (Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue).Length
    return ($actual -eq $expected)
}

# docs/INSTALL-ENGINE.md#truncation
function Get-RemoteLength {
    param([string]$Url)
    $result = [int64](-1)
    foreach ($method in @('HEAD', 'GET')) {
        try {
            $req = [System.Net.HttpWebRequest]::Create($Url)
            $req.UserAgent         = $script:UserAgent
            $req.Method            = $method
            $req.Timeout           = 60000
            $req.AllowAutoRedirect = $true
            if ($method -eq 'GET') { $req.AddRange(0, 0) }
            $resp = $req.GetResponse()
            $len  = [int64]$resp.ContentLength
            if ($method -eq 'GET') {
                $cr = $resp.Headers['Content-Range']
                if ($cr -and $cr -match '/(\d+)\s*$') { $len = [int64]$Matches[1] }
                elseif ($len -le 1) { $len = [int64](-1) }
            }
            $resp.Close()
            if ($len -gt 0) { $result = $len; break }
        } catch {
            if ($_.Exception.Response) { $_.Exception.Response.Close() }
        }
    }
    if ($result -le 0) { Warn "no Content-Length for $Url - the size guard is off for this file" }
    return $result
}

# docs/INSTALL-ENGINE.md#download-retry
function Unblock-FileSafe {
    param([string]$Path)
    for ($k = 0; $k -lt 3; $k++) {
        try { Unblock-File -Path $Path -ErrorAction Stop; return }
        catch { Write-Verbose "Unblock-FileSafe: Unblock-File failed on '$Path': $($_.Exception.Message)"; Start-Sleep -Seconds 2 }
    }
    Warn "Unblock-File did not complete for $Path (continuing)"
}

# docs/INSTALL-ENGINE.md#transport
function Invoke-FileDownload {
    param([string]$Url, [string]$Dest)
    $dir = Split-Path $Dest -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    try {
        if (Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue) {
            Start-BitsTransfer -Source $Url -Destination $Dest -TransferType Download `
                -CustomHeaders "User-Agent: $script:UserAgent" -ErrorAction Stop
            return $true
        }
    } catch {
        Warn "BITS failed ($($_.Exception.Message)); falling back to WebClient"
    }
    $wc = $null
    try {
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add('User-Agent', $script:UserAgent)
        $wc.DownloadFile($Url, $Dest)
        return $true
    } catch {
        Warn "WebClient failed: $($_.Exception.Message)"
        return $false
    } finally {
        if ($wc) { $wc.Dispose() }
    }
}

# docs/INSTALL-ENGINE.md#download-retry
function Get-FileWithRetry {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string[]]$Urls,
        [Parameter(Mandatory)][string]$TargetPath,
        [int]$MaxRetries = 4
    )
    Step "Download: $Label"

    if (-not $ForceReinstall -and (Test-CachedFileValid $TargetPath)) {
        $sz = (Get-Item -LiteralPath $TargetPath).Length
        Ok "already present, valid: $(Split-Path $TargetPath -Leaf) ($sz bytes)"
        return $true
    }
    if ($DryRun) { Dry "would download $Label -> $TargetPath"; return $true }

    # Staged via .part so a failed attempt cannot destroy a valid cached copy:
    # docs/INSTALL-ENGINE.md#download-retry
    $part = "$TargetPath.part"
    for ($i = 0; $i -lt $MaxRetries; $i++) {
        $url = if ($i -ge ($MaxRetries - 1) -and $Urls.Count -gt 1) { $Urls[-1] } else { $Urls[0] }
        Info "  attempt $($i + 1)/$MaxRetries : $url"

        $expected = Get-RemoteLength $url
        if ($expected -gt 0) { Info "  expected Content-Length: $expected bytes" }

        Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
        $got = $false
        try { $got = Invoke-FileDownload -Url $url -Dest $part }
        catch { Warn "download error: $($_.Exception.Message)"; $got = $false }

        if ($got) {
            $size = (Get-Item -LiteralPath $part -ErrorAction SilentlyContinue).Length
            $retryNote = if ($i -lt ($MaxRetries - 1)) { ' - retrying' } else { ' - no attempts left' }
            if ($expected -gt 0 -and $size -ne $expected) {
                Warn "size mismatch: on-disk $size != Content-Length $expected$retryNote"
            } elseif (-not (Test-RealBinary $part)) {
                Warn "magic-byte check failed (HTML interstitial / truncation)$retryNote"
            } else {
                $staged = $false
                try { Move-Item -LiteralPath $part -Destination $TargetPath -Force -ErrorAction Stop; $staged = $true }
                catch { Warn "could not move the staged download into place: $($_.Exception.Message)$retryNote" }
                if ($staged) {
                    Unblock-FileSafe $TargetPath
                    Save-FileSizeSidecar $TargetPath
                    Ok "downloaded $Label ($size bytes)"
                    return $true
                }
            }
        }

        if ($i -lt ($MaxRetries - 1)) {
            $delay = [int][math]::Min(30, [math]::Pow(2, $i))
            Info "  backing off $delay s..."; Start-Sleep -Seconds $delay
        }
    }
    Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
    Fail "could not download $Label after $MaxRetries attempts"
    if (Test-CachedFileValid $TargetPath) {
        Warn "keeping the existing valid cached copy of $Label"
        return $true
    }
    # docs/INSTALL-ENGINE.md#literalpath
    Remove-Item -LiteralPath $TargetPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath "$TargetPath.len" -Force -ErrorAction SilentlyContinue
    return $false
}

# docs/INSTALL-ENGINE.md#download  (confirm=t, alternate host)
function Get-DriveFile {
    param([Parameter(Mandatory)][string]$Label, [Parameter(Mandatory)][string]$FileId,
          [Parameter(Mandatory)][string]$TargetPath)
    $primary  = "https://drive.usercontent.google.com/download?id=$FileId&export=download&confirm=t"
    $fallback = "https://drive.google.com/uc?export=download&id=$FileId&confirm=t"
    return Get-FileWithRetry -Label $Label -Urls @($primary, $fallback) -TargetPath $TargetPath
}

# docs/INSTALL-ENGINE.md#tables  (Label MUST equal the $Installers Name)
$DriveFiles = @(
    @{ Label='Google Chrome';         FileId='1XT7Zc0lU6t1OhI4yM_SpD8TH_N0spUaV'; File='Chrome Setup.exe' }
    @{ Label='Alleaves Terminal';     FileId='1UAqW1zzxj9LJ-Pk0riNsZ8MiYoSQNoxP'; File='Alleaves Terminal App.msi' }
    @{ Label='Zebra 123 Scan';        FileId='1VBCRHD3hyNzlfoOuYsac9LpeHizAkruo'; File='Zebra 123 Scan.exe' }
    @{ Label='Zebra Scanner SDK';     FileId='1K5DR-STIxxtsnwklcbTCpo8cPFCwcIUa'; File='Zebra Scanner SDK.exe' }
    @{ Label='POS for .NET';          FileId='1pYr5skO85h8baFByy9z_ZN1ZPiDnfN_D'; File='POSforDOTNet.msi' }
    @{ Label='NiceLabel';             FileId='1C6eDiJBp1S8aVw9i4iebDbs-JC2ERBZn'; File='Nice Label.exe' }
    @{ Label='OLE POS Setup';         FileId='1y14kZ2g4Bwqhi9M0inszCCi_TREkNaH0'; File='OLE POS Setup.exe' }
    @{ Label='Star TSP100 futurePRNT'; FileId='1lr2x_jQ6NxtCTPwW4E1fGOSN618vs0CD'; File='Star tsp100_v760.zip' }
    @{ Label='Master List';           FileId='1dPktafxPsoumHSKDC5z7Nm-Jl3sgx2PQ'; File='Alleaves Nice Label Master List.nlbl' }
)

# docs/INSTALL-ENGINE.md#tables
function Test-SkipMatch {
    param([string[]]$Names)
    foreach ($n in $Names) {
        if (-not $n) { continue }
        foreach ($s in $SkipPrograms) {
            if (-not $s) { continue }
            try { if ($n -match $s) { return $true } }
            catch { Warn "invalid -SkipPrograms fragment '$s': $($_.Exception.Message)" }
        }
    }
    return $false
}

# docs/INSTALL-ENGINE.md#download
function Invoke-DownloadPhase {
    Step 'Download phase'
    Set-Tls12
    Info "  TLS: $([Net.ServicePointManager]::SecurityProtocol)"
    $results = @()
    foreach ($d in $DriveFiles) {
        $why = if ($SkipMasterList -and $d.Label -eq 'Master List') { '-SkipMasterList' }
               elseif (Test-SkipMatch -Names @($d.Label, $d.File))  { '-SkipPrograms' }
        if ($why) {
            Step "Download: $($d.Label)"; Warn "skipped via $why"
            continue
        }
        $target = Join-Path $DownloadDir $d.File
        $ok = $false
        try { $ok = Get-DriveFile -Label $d.Label -FileId $d.FileId -TargetPath $target }
        catch { Fail "$($d.Label): $($_.Exception.Message)" }
        if (-not $ok) { $script:DownloadFailed = $true }
        $results += [pscustomobject]@{ Label=$d.Label; Ok=$ok }
    }
    if (-not (Test-SkipMatch -Names @('Splashtop','Splashtop SOS','SplashtopSOS.exe'))) {
        $ok = $false
        try {
            $ok = Get-FileWithRetry -Label 'Splashtop SOS' `
                -Urls @('https://download.splashtop.com/sos/SplashtopSOS.exe') `
                -TargetPath (Join-Path $DownloadDir 'SplashtopSOS.exe') -MaxRetries 3
        } catch { Fail "Splashtop SOS: $($_.Exception.Message)" }
        if (-not $ok) { $script:DownloadFailed = $true }
        $results += [pscustomobject]@{ Label='Splashtop SOS'; Ok=$ok }
    }
    Step 'Download summary'
    foreach ($r in $results) {
        if ($r.Ok) { Ok $r.Label } else { Fail $r.Label }
    }
}


# docs/INSTALL-ENGINE.md#anchoring
function Uninstall-TeamViewer {
    Step 'Uninstall existing TeamViewer'
    $found = Find-InstalledProducts -Pattern 'TeamViewer'
    if (-not $found) { Ok 'no TeamViewer installation detected'; return }

    foreach ($m in $found) {
        $name = $m.DisplayName
        $u    = $m.UninstallString
        Info "  found: $name"

        if (Invoke-SilentUninstall -DisplayName $name -UninstallString $u -QuietUninstallString $m.QuietUninstallString -ProductCode $m.PSChildName) {
            $Manifest.teamViewerRemoved += $name
        } else {
            if (Find-InstalledProducts -Pattern ('^' + [regex]::Escape($name) + '$')) {
                Fail "could not remove ${name} - the terminal still has TeamViewer installed"
                $script:FinishFailed = $true
            } else {
                Ok "$name already removed by a sibling entry"
            }
        }
    }
}

# docs/INSTALL-ENGINE.md#invoke-installer  (the $p.Handle trap)
function Invoke-Installer {
    param(
        [Parameter(Mandatory)][string]   $Name,
        [Parameter(Mandatory)][string]   $Path,
        [string[]]                       $ArgList,
        [string]                         $DisplayNameMatch,
        [switch]                         $ConfirmRegistry
    )
    $okCodes = @(0, 3010, 1641)
    $TimeoutSeconds = 1800
    Step $Name

    # docs/INSTALL-ENGINE.md#redaction  ($ArgList itself reaches the installer untouched)
    $safeArgs = @($ArgList | ForEach-Object { $_ -replace '(?i)(LICENSECODE=).*', '$1***' })

    if ($DryRun) {
        Dry "would run: $Path $($safeArgs -join ' ')"
        $Manifest.installed += @{
            name=$Name; source=$Path
            args=$safeArgs
            displayNameMatch=$DisplayNameMatch; result='dryrun'
        }
        return
    }

    $resolved = if ($Path -match '[\\/]') { $Path } else { (Get-Command $Path -ErrorAction SilentlyContinue).Source }
    if (-not $resolved -or ($Path -match '[\\/]' -and -not (Test-Path $Path))) {
        Fail "$Path not found"
        $Manifest.installed += @{ name=$Name; source=$Path; displayNameMatch=$DisplayNameMatch; result='fail-missing' }
        return
    }

    $cmdDisplay = "$resolved $($safeArgs -join ' ')"
    $stdoutLog  = Join-Path $LogDir ("{0}.stdout.log" -f ($Name -replace '\W','_'))
    $stderrLog  = Join-Path $LogDir ("{0}.stderr.log" -f ($Name -replace '\W','_'))

    Info "  running: $cmdDisplay"
    Info "  stdout:  $stdoutLog"

    $exit = $null
    try {
        $p = Start-Process -FilePath $resolved -ArgumentList $ArgList `
            -PassThru -WindowStyle Hidden `
            -RedirectStandardOutput $stdoutLog -RedirectStandardError $stderrLog `
            -ErrorAction Stop
    } catch {
        Fail "launch failed: $($_.Exception.Message)"
        $Manifest.installed += @{ name=$Name; result="launch-failed: $($_.Exception.Message)" }
        return
    }

    try { $null = $p.Handle } catch { Write-Verbose "Invoke-Installer: could not dereference the process handle: $($_.Exception.Message)" }

    # docs/INSTALL-ENGINE.md#invoke-installer-rules  (capped, never -Wait; and never killed)
    if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
        Fail "$Name still running after $TimeoutSeconds s - giving up on it (not killing it; it may still be installing) - see $stdoutLog / $stderrLog"
        $Manifest.installed += @{
            name=$Name; source=$Path
            args=$safeArgs
            displayNameMatch=$DisplayNameMatch; result='fail-timeout'
            stdoutLog=$stdoutLog; stderrLog=$stderrLog
        }
        return
    }
    $exit = $p.ExitCode

    $entry = @{
        name=$Name; source=$Path
        args=$safeArgs
        displayNameMatch=$DisplayNameMatch; exitCode=$exit
        stdoutLog=$stdoutLog; stderrLog=$stderrLog
    }
    if ($null -eq $exit) {
        if ($DisplayNameMatch -and (Find-InstalledProducts -Pattern $DisplayNameMatch)) {
            Ok "$Name reported no exit code, but it IS installed (in Add/Remove Programs) - treating as installed"
            $entry.result = 'ok'
            $entry.note   = 'exit-unknown-but-registered'
        } else {
            Fail "$Name exit code could not be read AND it is not in Add/Remove Programs - see $stdoutLog / $stderrLog"
            $entry.result = 'fail'
            $entry.note   = 'exit-unknown'
        }
    } elseif ($okCodes -contains $exit) {
        if ($ConfirmRegistry -and $DisplayNameMatch -and -not (Find-InstalledProducts -Pattern $DisplayNameMatch)) {
            Fail "$Name exited $exit but is NOT in the registry (Group Policy / AV / wrong stub?) - recording as failed"
            $entry.result = 'fail'
            $entry.note   = 'exit-success-but-not-registered'
        } else {
            Ok "$Name installed (exit $exit)"
            $entry.result = 'ok'
            if ($exit -in 3010, 1641) { $script:RebootPending = $true; Warn "$Name requests a reboot ($exit) - deferred to end of run" }
        }
    } else {
        Fail "$Name exited $exit - see $stdoutLog / $stderrLog"
        $entry.result = 'fail'
    }
    $Manifest.installed += $entry
}

# docs/INSTALL-ENGINE.md#invoke-installer
function Invoke-Msi {
    param([string]$Name, [string]$Msi, [string]$DisplayNameMatch)
    $log = Join-Path $LogDir ("{0}.msi.log" -f ($Name -replace '\W','_'))
    Invoke-Installer -Name $Name -Path 'msiexec.exe' `
        -DisplayNameMatch $DisplayNameMatch `
        -ArgList @('/i', "`"$Msi`"", '/qn', '/norestart', '/L*v', "`"$log`"")
}

# docs/INSTALL-ENGINE.md#vcredist
function Test-VcRedistPresent {
    foreach ($p in @(
        'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\14.0\VC\Runtimes\x64')) {
        $v = Get-ItemProperty -Path $p -ErrorAction SilentlyContinue
        if ($v -and $v.Installed -eq 1) { return $true }
    }
    if (Find-InstalledProducts -Pattern 'Microsoft Visual C\+\+ 201[5-9].*x64|2015-2022.*x64') { return $true }
    return $false
}

# docs/INSTALL-ENGINE.md#vcredist
function Install-VcRedist {
    Set-Tls12

    Step 'Bootstrap: Microsoft Visual C++ 2015-2022 x64 Redistributable'

    $vcBase = @{
        name='Microsoft Visual C++ 2015-2022 x64 Redistributable'
        displayNameMatch='Microsoft Visual C\+\+ 201[5-9].*x64|2015-2022.*x64'
        method='vcredist'; removable=$false
    }
    $vcSrc = @{ source='vc_redist.x64.exe' }

    if (Test-VcRedistPresent) {
        Ok 'Visual C++ x64 runtime already present - skipping'
        $Manifest.dependencies += ($vcBase + @{ result='already-present' })
        return
    }

    if ($DryRun) {
        Dry 'would download + install vc_redist.x64.exe /install /quiet /norestart'
        $Manifest.dependencies += ($vcBase + @{ result='dryrun' })
        return
    }

    $exe      = Join-Path $DownloadDir 'vc_redist.x64.exe'
    $primary  = 'https://aka.ms/vs/17/release/vc_redist.x64.exe'
    $fallback = 'https://aka.ms/vs/16/release/vc_redist.x64.exe'

    $haveExe = Get-FileWithRetry -Label 'Visual C++ x64 redist' -Urls @($primary, $fallback) -TargetPath $exe -MaxRetries 3

    if (-not $haveExe) {
        Fail 'could not obtain a valid vc_redist.x64.exe'
        $Manifest.dependencies += ($vcBase + $vcSrc + @{ result='fail-download' })
        return
    }

    $log = Join-Path $LogDir 'vc_redist.x64.log'
    Info "  running: vc_redist.x64.exe /install /quiet /norestart"
    $exit = $null
    try {
        $p = Start-Process -FilePath $exe `
            -ArgumentList @('/install','/quiet','/norestart','/log',"`"$log`"") `
            -Wait -PassThru -WindowStyle Hidden -ErrorAction Stop
        $exit = $p.ExitCode
    } catch {
        Fail "vc_redist launch failed: $($_.Exception.Message)"
        $Manifest.dependencies += ($vcBase + $vcSrc + @{ result="launch-failed: $($_.Exception.Message)" })
        return
    }

    $entry = $vcBase + $vcSrc + @{ logFile=$log; exitCode=$exit }
    if ($exit -in 0,1638,3010,1641) {
        if ($exit -eq 3010 -or $exit -eq 1641) { $script:RebootPending = $true; Warn 'VC++ requests a reboot (3010/1641) - deferred to end of run' }
        if (Test-VcRedistPresent) {
            Ok "Visual C++ x64 runtime installed (exit $exit)"
            $entry.result = 'ok'
        } else {
            Fail "vc_redist exited $exit but the x64 runtime is STILL absent (Group Policy / AV / blocked child MSI?) - recording as failed; see $log"
            $entry.result = 'fail'
            $entry.note   = 'exit-success-but-not-registered'
        }
    } else {
        Fail "vc_redist exited $exit - see $log"
        $entry.result = 'fail'
    }
    $Manifest.dependencies += $entry
}

# docs/INSTALL-ENGINE.md#wrapped-msi
function Invoke-WrappedMsi {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$WrapperPath,
        [Parameter(Mandatory)][string]$DisplayNameMatch,
        [Parameter(Mandatory)][string]$ConfirmMatch,
        [Parameter(Mandatory)][string]$CacheAs
    )
    $TimeoutSeconds = 600
    Step $Name

    if ($DryRun) {
        Dry "would extract MSI from $WrapperPath via temp-folder watch, then msiexec /i /qn"
        $Manifest.installed += @{
            name=$Name; source=$WrapperPath; method='wrapper-extract'
            displayNameMatch=$DisplayNameMatch; result='dryrun'
        }
        return
    }

    if (-not (Test-Path $WrapperPath)) {
        Fail "$WrapperPath not found"
        $Manifest.installed += @{ name=$Name; source=$WrapperPath; result='fail-missing' }
        return
    }

    $msiLog    = Join-Path $LogDir ("{0}.msi.log"    -f ($Name -replace '\W','_'))

    Info "  launching wrapper to extract embedded MSI..."
    $launchTime = Get-Date
    $before = Get-ChildItem $env:TEMP -Filter '{*}' -Directory -ErrorAction SilentlyContinue | ForEach-Object FullName
    $proc = $null
    try {
        $proc = Start-Process -FilePath $WrapperPath -WindowStyle Hidden -PassThru -ErrorAction Stop
    } catch {
        Fail "could not launch wrapper: $($_.Exception.Message)"
        $Manifest.installed += @{ name=$Name; source=$WrapperPath; result="launch-failed: $($_.Exception.Message)" }
        return
    }
    Info "  wrapper PID: $($proc.Id)"

    $extractedMsi = $null
    $acceptedSize = 0
    $lastSize     = @{}
    $stableCount  = @{}
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline -and -not $extractedMsi) {
        Start-Sleep -Seconds 3
        $candidates = Get-ChildItem $env:TEMP -Filter '{*}' -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notin $before }
        foreach ($c in $candidates) {
            $msi = Get-ChildItem $c.FullName -Filter '*.msi' -ErrorAction SilentlyContinue |
                Sort-Object Length -Descending | Select-Object -First 1
            if (-not $msi -or $msi.Length -le 1MB) { continue }
            $prev = $lastSize[$msi.FullName]
            if ($null -ne $prev -and $prev -eq $msi.Length) { $stableCount[$msi.FullName]++ }
            else { $stableCount[$msi.FullName] = 0 }
            $lastSize[$msi.FullName] = $msi.Length
            if ($stableCount[$msi.FullName] -ge 5) {
                $extractedMsi = $msi.FullName; $acceptedSize = $msi.Length; break
            }
        }
        if ($proc.HasExited -and -not $extractedMsi -and $lastSize.Count -eq 0 -and (Get-Date) -gt $launchTime.AddSeconds(30)) {
            Warn 'wrapper exited without extracting an MSI - not waiting out the timeout'
            break
        }
    }

    try { if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } } catch { Write-Verbose "Invoke-WrappedMsi: could not stop the wrapper: $($_.Exception.Message)" }
    Get-Process -Name 'setup','ISBEW64','ISSetupPrerequisites' -ErrorAction SilentlyContinue |
        Where-Object { try { $_.StartTime -gt $launchTime } catch { $false } } |
        Stop-Process -Force -ErrorAction SilentlyContinue

    if (-not $extractedMsi) {
        Fail "wrapper did not extract an MSI within $TimeoutSeconds s"
        $Manifest.installed += @{
            name=$Name; source=$WrapperPath; method='wrapper-extract'
            displayNameMatch=$DisplayNameMatch; result='fail-extract'
        }
        return
    }
    Info "  extracted MSI: $extractedMsi"

    $stableMsi = Join-Path $LogDir ("{0}.msi" -f ($Name -replace '\W','_'))
    try { Copy-Item $extractedMsi $stableMsi -Force -ErrorAction Stop } catch {
        Warn "could not stage MSI to $stableMsi - using temp path directly: $($_.Exception.Message)"
        $stableMsi = $extractedMsi
    }

    Info "  running: msiexec /i `"$stableMsi`" /qn /norestart"
    $exit = $null
    try {
        $p = Start-Process -FilePath 'msiexec.exe' `
            -ArgumentList @('/i',"`"$stableMsi`"",'/qn','/norestart','/L*v',"`"$msiLog`"") `
            -Wait -PassThru -WindowStyle Hidden -ErrorAction Stop
        $exit = $p.ExitCode
    } catch {
        Fail "could not launch msiexec: $($_.Exception.Message)"
        $Manifest.installed += @{
            name=$Name; source=$WrapperPath; method='wrapper-extract'
            extractedMsi=$stableMsi; msiLog=$msiLog
            displayNameMatch=$DisplayNameMatch; result="launch-failed: $($_.Exception.Message)"
        }
        return
    }

    $entry = @{
        name=$Name; source=$WrapperPath; method='wrapper-extract'
        extractedMsi=$stableMsi; msiLog=$msiLog
        displayNameMatch=$DisplayNameMatch; exitCode=$exit
    }
    if ($exit -in 0,3010,1641 -and -not (Find-InstalledProducts -Pattern $ConfirmMatch)) {
        Fail "$Name msiexec exited $exit but the product is NOT in the registry (wrong MSI harvested from %TEMP%? Group Policy / AV?) - recording as failed; see $msiLog"
        $entry.result = 'fail'
        $entry.note   = 'exit-success-but-not-registered'
    } elseif ($exit -in 0,3010,1641) {
        Ok "$Name installed (exit $exit)"
        $entry.result = 'ok'
        if ($exit -in 3010,1641) { $script:RebootPending = $true; Warn "$Name requests a reboot ($exit) - deferred to end of run" }

        try {
            $srcNow = (Get-Item $stableMsi -ErrorAction Stop).Length
            if ($srcNow -ne $acceptedSize -or -not (Test-RealBinary $stableMsi)) {
                Warn "staged MSI is not stable/valid ($srcNow bytes vs $acceptedSize accepted) - NOT caching it"
            } else {
                # docs/INSTALL-ENGINE.md#msi-cache  (cached only AFTER msiexec succeeded)
                $cacheTarget = Join-Path $DownloadDir $CacheAs
                if (-not (Test-Path $cacheTarget)) {
                    Copy-Item $stableMsi $cacheTarget -Force -ErrorAction Stop
                    Info "  cached MSI to $cacheTarget for future silent runs"
                }
            }
        } catch {
            Warn "could not cache MSI to downloads/: $($_.Exception.Message)"
        }
    } else {
        Fail "$Name msiexec exited $exit - see $msiLog"
        $entry.result = 'fail'
    }
    $Manifest.installed += $entry
}

# docs/INSTALL-ENGINE.md#iss
function Get-EmbeddedIss {
    param(
        [Parameter(Mandatory)][string]$Content,
        [Parameter(Mandatory)][string]$LeafName
    )
    $path = Join-Path $DownloadDir $LeafName
    $crlf = ($Content -replace "`r?`n", "`r`n")
    [IO.File]::WriteAllText($path, $crlf, (New-Object System.Text.ASCIIEncoding))
    if (-not (Test-Path $path)) { throw "could not write $path" }
    return $path
}

# docs/INSTALL-ENGINE.md#iss  (overrides: #registry-shortcircuit)
function Invoke-IssSilent {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$WrapperPath,
        [Parameter(Mandatory)][string]$IssContent,
        [Parameter(Mandatory)][string]$IssLeaf,
        [Parameter(Mandatory)][string]$DisplayNameMatch,
        [Parameter(Mandatory)][string]$RecordMatch,
        [string]   $ArgFormat = '-s -f1"{0}" -f2"{1}"',
        [string[]] $WaitNames = @('setup','ISBEW64','ISSetupPrerequisites'),
        [string[]] $ReapNames = @('setup','ISBEW64','ISSetupPrerequisites'),
        [bool]     $RegistryShortCircuit = $true
    )
    $TimeoutSeconds = 900
    Step $Name

    if ($DryRun) {
        Dry ("would run: `"$WrapperPath`" " + ($ArgFormat -f "<$IssLeaf>", '<log>'))
        $Manifest.installed += @{
            name=$Name; source=$WrapperPath; method='iss-silent'
            displayNameMatch=$RecordMatch; result='dryrun'
        }
        return 'dryrun'
    }

    if (-not (Test-Path $WrapperPath)) {
        Fail "$WrapperPath not found"
        $Manifest.installed += @{
            name=$Name; source=$WrapperPath; method='iss-silent'
            displayNameMatch=$RecordMatch; result='fail-missing'
        }
        return 'fail'
    }

    try { $issPath = Get-EmbeddedIss -Content $IssContent -LeafName $IssLeaf }
    catch {
        Fail "could not materialize the response file: $($_.Exception.Message)"
        $Manifest.installed += @{
            name=$Name; source=$WrapperPath; method='iss-silent'
            displayNameMatch=$RecordMatch; result='fail-iss-write'
        }
        return 'fail'
    }
    $log     = Join-Path $LogDir ("{0}.silent.log" -f ($Name -replace '\W','_'))
    if (Test-Path $log) { Remove-Item $log -Force -ErrorAction SilentlyContinue }

    $argLine = $ArgFormat -f $issPath, $log
    Info "  running: `"$WrapperPath`" $argLine"

    $launchTime = Get-Date
    $msiexecBefore = @(Get-Process -Name 'msiexec' -ErrorAction SilentlyContinue | ForEach-Object Id)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName        = $WrapperPath
    $psi.Arguments       = $argLine
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow  = $true
    $proc = $null
    try { $proc = [System.Diagnostics.Process]::Start($psi) }
    catch {
        Fail "could not launch wrapper: $($_.Exception.Message)"
        $Manifest.installed += @{
            name=$Name; source=$WrapperPath; method='iss-silent'
            displayNameMatch=$RecordMatch; result="launch-failed: $($_.Exception.Message)"
        }
        return 'fail'
    }
    Info "  wrapper PID: $($proc.Id)"

    $launcherExited = $false
    try { $launcherExited = $proc.WaitForExit($TimeoutSeconds * 1000) } catch { Write-Verbose "Invoke-IssSilent: WaitForExit threw, treating the launcher as exited: $($_.Exception.Message)"; $launcherExited = $true }
    if (-not $launcherExited) { Warn "$Name launcher still running after $TimeoutSeconds s - continuing without killing it (it may BE the install engine)" }
    Start-Sleep -Seconds 5

    # docs/INSTALL-ENGINE.md#poll-loop  (deadline anchored AFTER the launcher returns)
    $deadline  = (Get-Date).AddSeconds($TimeoutSeconds)
    $sawWorker = $false
    $idlePolls = 0
    while ((Get-Date) -lt $deadline) {
        $busy = @()
        if ($RegistryShortCircuit) {
            $busy += @(Get-Process -Name 'msiexec' -ErrorAction SilentlyContinue |
                       Where-Object { $_.Id -notin $msiexecBefore })
        }
        $busy += @(Get-Process -Name $WaitNames -ErrorAction SilentlyContinue |
                   Where-Object { try { $_.StartTime -gt $launchTime.AddMinutes(-1) } catch { $false } })
        if ($busy.Count -gt 0) { $sawWorker = $true; $idlePolls = 0 }
        else {
            if ($RegistryShortCircuit -and (Find-InstalledProducts -Pattern $DisplayNameMatch)) { Start-Sleep -Seconds 2; break }
            $idlePolls++
            if (($sawWorker -and $idlePolls -ge 2) -or $idlePolls -ge 10) { break }
        }
        Start-Sleep -Seconds 3
    }

    if ($ReapNames -and $ReapNames.Count) {
        Get-Process -Name $ReapNames -ErrorAction SilentlyContinue |
            Where-Object { try { $_.StartTime -gt $launchTime } catch { $false } } |
            Stop-Process -Force -ErrorAction SilentlyContinue
    }

    $logOk = $false
    if (Test-Path $log) {
        try {
            # docs/INSTALL-ENGINE.md#iss-log  (only a log THIS launch produced counts)
            $logWritten = (Get-Item $log -ErrorAction Stop).LastWriteTime
            if ($logWritten -lt $launchTime) {
                Warn "response log predates this launch ($logWritten < $launchTime) - stale, ignoring it"
            } elseif ((Get-Content $log -Raw -ErrorAction SilentlyContinue) -match 'ResultCode\s*=\s*0') { $logOk = $true }
        } catch { Write-Verbose "Invoke-IssSilent: could not read the response log: $($_.Exception.Message)" }
    }
    $regOk = [bool](Find-InstalledProducts -Pattern $DisplayNameMatch)

    $entry = @{
        name=$Name; source=$WrapperPath; method='iss-silent'
        issFile=$issPath; silentLog=$log
        displayNameMatch=$RecordMatch
        logResultZero=$logOk; registryPresent=$regOk
    }
    if ($logOk -or ($regOk -and $RegistryShortCircuit)) {
        Ok "$Name installed (ResultCode=$(if ($logOk){'0'}else{'n/a'}), registry=$regOk)"
        $entry.result = 'ok'
        $Manifest.installed += $entry
        return 'ok'
    } else {
        Fail "$Name silent install not confirmed (no ResultCode=0$(if (-not $RegistryShortCircuit) { '; registry presence is not proof for this family' } else { ', not in registry' })) - see $log"
        $entry.result = 'fail'
        $Manifest.installed += $entry
        return 'fail'
    }
}

# docs/FINISHING.md#master-list
function Copy-MasterList {
    param([string]$Source)
    Step 'Copy NiceLabel Master List to Documents'

    $dests = @(Get-TargetUserProfiles | ForEach-Object {
        $d = Join-Path $_.Profile 'Documents'
        # docs/FINISHING.md#onedrive
        if (-not (Test-Path -LiteralPath $d)) {
            $kfm = @(Get-ChildItem -LiteralPath $_.Profile -Directory -Filter 'OneDrive*' -ErrorAction SilentlyContinue |
                     ForEach-Object { Join-Path $_.FullName 'Documents' } |
                     Where-Object { Test-Path -LiteralPath $_ })
            if ($kfm.Count) { $d = $kfm[0] }
        }
        $d
    })
    $admin = [Environment]::GetFolderPath('MyDocuments')
    if ($admin) { $dests += $admin }
    $dests = @($dests | Select-Object -Unique)

    if ($DryRun) {
        foreach ($destDir in $dests) {
            Dry "would copy $Source -> $(Join-Path $destDir (Split-Path $Source -Leaf))"
        }
        if (-not $dests) { Dry 'no Documents folder resolved - the real run would fail here' }
        return
    }

    if (-not $dests) { Fail "no Documents folder resolved"; $script:FinishFailed = $true; return }

    if (-not (Test-Path $Source)) { Fail "$Source not found"; $script:FinishFailed = $true; return }

    $placed = 0
    foreach ($destDir in $dests) {
        $target = Join-Path $destDir (Split-Path $Source -Leaf)
        try {
            $madeDir = $false
            if (-not (Test-Path -LiteralPath $destDir)) {
                New-Item -ItemType Directory -Force -Path $destDir -ErrorAction Stop | Out-Null
                $madeDir = $true
            }
            Copy-Item $Source $target -Force -ErrorAction Stop
            Ok "placed $(Split-Path $target -Leaf) in $destDir"
            $Manifest.filesPlaced += $target
            if ($madeDir) { $Manifest.filesPlaced += $destDir }
            $placed++
        } catch {
            Warn "could not copy to ${destDir}: $($_.Exception.Message)"
        }
    }
    if ($placed -eq 0) { Fail 'master list could not be copied to ANY Documents folder'; $script:FinishFailed = $true }
}

$Iss123Scan = @'
[InstallShield Silent]
Version=v7.00
File=Response File
[File Transfer]
OverwriteReadOnly=NoToAll
[{EE16FAD0-1FFA-482B-9875-5A4F429D314E}-DlgOrder]
Dlg0={EE16FAD0-1FFA-482B-9875-5A4F429D314E}-SdWelcome-0
Count=4
Dlg1={EE16FAD0-1FFA-482B-9875-5A4F429D314E}-SdLicenseRtf-0
Dlg2={EE16FAD0-1FFA-482B-9875-5A4F429D314E}-SdStartCopy2-0
Dlg3={EE16FAD0-1FFA-482B-9875-5A4F429D314E}-SdFinish-0
[{EE16FAD0-1FFA-482B-9875-5A4F429D314E}-SdWelcome-0]
Result=1
[{EE16FAD0-1FFA-482B-9875-5A4F429D314E}-SdLicenseRtf-0]
Result=1
[{EE16FAD0-1FFA-482B-9875-5A4F429D314E}-SdStartCopy2-0]
Result=1
[{EE16FAD0-1FFA-482B-9875-5A4F429D314E}-SdFinish-0]
Result=1
bOpt1=0
bOpt2=0
'@

$IssScannerSdk = @'
[InstallShield Silent]
Version=v7.00
File=Response File
[File Transfer]
OverwriteReadOnly=NoToAll
[{70F39636-E76F-4EDA-B1D7-9B4044EE45AE}-DlgOrder]
Dlg0={70F39636-E76F-4EDA-B1D7-9B4044EE45AE}-SdWelcome-0
Count=6
Dlg1={70F39636-E76F-4EDA-B1D7-9B4044EE45AE}-SdLicenseRtf-0
Dlg2={70F39636-E76F-4EDA-B1D7-9B4044EE45AE}-SdSetupType2-0
Dlg3={70F39636-E76F-4EDA-B1D7-9B4044EE45AE}-SdShowInfoList-0
Dlg4={70F39636-E76F-4EDA-B1D7-9B4044EE45AE}-SdStartCopy-0
Dlg5={70F39636-E76F-4EDA-B1D7-9B4044EE45AE}-SdFinish-0
[{70F39636-E76F-4EDA-B1D7-9B4044EE45AE}-SdWelcome-0]
Result=1
[{70F39636-E76F-4EDA-B1D7-9B4044EE45AE}-SdLicenseRtf-0]
Result=1
[{70F39636-E76F-4EDA-B1D7-9B4044EE45AE}-SdSetupType2-0]
szDir=C:\Program Files\Zebra Technologies\Barcode Scanners\Scanner SDK\
Result=304
[{70F39636-E76F-4EDA-B1D7-9B4044EE45AE}-SdShowInfoList-0]
Result=1
[{70F39636-E76F-4EDA-B1D7-9B4044EE45AE}-SdStartCopy-0]
Result=1
[{70F39636-E76F-4EDA-B1D7-9B4044EE45AE}-SdFinish-0]
Result=1
bOpt1=0
bOpt2=0
'@

$IssOlePos = @'
[InstallShield Silent]
Version=v5.00.000
File=Response File
[File Transfer]
OverwriteReadOnly=NoToAll
[DlgOrder]
Dlg0=SdWelcome-0
Count=3
Dlg1=SdAskDestPath-0
Dlg2=SdFinish-0
[SdWelcome-0]
Result=1
[SdAskDestPath-0]
szDir=C:\Program Files (x86)\OPOS\StdOPOS2.84
Result=1
[Application]
Name=OLE POS Setup 2.84
Version=2.84
Company=Company
Lang=0009
[SdFinish-0]
Result=1
bOpt1=0
bOpt2=0
'@

# docs/INSTALL-ENGINE.md#nicelabel-args  (the server auto-populates the rest of the activation)
$NiceLabelArgs = if ($SkipNiceLabelActivation) { @('/s') } else { @('/s', "LICENSECODE=$NiceLabelLicense") }

# docs/INSTALL-ENGINE.md#rows  (Name MUST equal the $DriveFiles Label; per-field meanings: #row-fields)
$Installers = @(
    @{ Name='Google Chrome';     File='Chrome Setup.exe';          Match='Google Chrome';     Args=@('/silent','/install'); ConfirmRegistry=$true; SkipIfInstalled=$true }
    @{ Name='Alleaves Terminal'; File='Alleaves Terminal App.msi'; Match='Alleaves Terminal'; Msi=$true }
    @{ Name='Zebra 123 Scan';    File='Zebra 123 Scan.exe';        Match='123Scan';           UninstallMatch='123Scan|Zebra CoreScanner';           Iss='123scan';    IssContent=$Iss123Scan;    CachedMsi='Zebra 123Scan (64bit).msi' }
    @{ Name='Zebra Scanner SDK'; File='Zebra Scanner SDK.exe';     Match='Zebra Scanner SDK'; UninstallMatch='Zebra Scanner SDK|Zebra CoreScanner'; Iss='scannersdk'; IssContent=$IssScannerSdk; CachedMsi='Zebra Scanner SDK (64bit).msi' }
    @{ Name='POS for .NET';      File='POSforDOTNet.msi';          Match='POS for \.NET';     Msi=$true }
    @{ Name='NiceLabel';         File='Nice Label.exe';            Match='NiceLabel';         Args=$NiceLabelArgs; SkipIfInstalled=$true }
    # docs/INSTALL-ENGINE.md#posx  (PFTW stub over an IS5 InstallScript engine - all four overrides)
    @{ Name='OLE POS Setup';     File='OLE POS Setup.exe';         Match='OLE POS Setup';     Iss='olepos'; IssContent=$IssOlePos
       IssArgFormat='/s /a /s /L0x0409 /f1"{0}" /f2"{1}"'
       IssWaitNames=@('setup','_INS*'); IssReapNames=@(); IssRegistryShortCircuit=$false
       NoMsiFallback=$true }
    # docs/INSTALL-ENGINE.md#star  (raw exe wrapping a Basic MSI - /w or the launcher returns early)
    @{ Name='Star TSP100 futurePRNT'; File='Star tsp100_v760.zip'
       Zip=$true; ZipMember='tsp100_v760/Windows/Installer/setup_x64.exe'
       Match='TSP100 Setup Version'
       Args=@('/s','/w','/v"/qn /norestart"'); ConfirmRegistry=$true; SkipIfInstalled=$true }
)

$script:PriorManifest = $null
# docs/MANIFEST.md#prior
function Get-PriorManifest {
    if ($null -eq $script:PriorManifest) {
        $script:PriorManifest = @{}
        if (Test-Path $ManifestPath) {
            try {
                $raw = Get-Content $ManifestPath -Raw -ErrorAction Stop
                if ([string]::IsNullOrWhiteSpace($raw)) { throw 'the manifest file is empty' }
                $script:PriorManifest = ($raw | ConvertFrom-Json -ErrorAction Stop)
            }
            catch {
                Warn "could not read the prior manifest: $($_.Exception.Message)"
                $script:PriorManifestUnreadable = $true
            }
        }
    }
    return $script:PriorManifest
}
# docs/INSTALL-ENGINE.md#already-installed
function Test-PriorInstallFailed {
    param([Parameter(Mandatory)][string]$Name)
    return [bool](@((Get-PriorManifest).installed | Where-Object {
        $_.name -eq $Name -and (($_.result -and $_.result -ne 'ok') -or $_.note -eq 'msi-fallback')
    }).Count)
}

# docs/INSTALL-ENGINE.md#already-installed  (removable: docs/MANIFEST.md#step-2)
function Add-AlreadyInstalledRow {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Match
    )
    Step $Name
    Ok 'already installed; skipping'
    $weInstalledIt = [bool](@((Get-PriorManifest).installed |
        Where-Object { $_.name -eq $Name -and $_.removable -ne $false }).Count)
    if (-not $weInstalledIt) { Info '  (found pre-installed - -Uninstall will leave it alone)' }
    $Manifest.installed += @{
        name=$Name; source=$Source; method=$Method; displayNameMatch=$Match
        result='ok'; note='already-installed'; removable=$weInstalledIt
    }
}

# docs/INSTALL-ENGINE.md#install-loop
function Invoke-InstallLoop {
    foreach ($i in $Installers) {
        try {
            if (Test-SkipMatch -Names @($i.Name, $i.File)) {
                Step $i.Name
                Warn "skipped via -SkipPrograms"
                continue
            }

            if ($ForceReinstall -and ($i.Msi -or $i.Iss)) {
                $cleanPattern = if ($i.UninstallMatch) { $i.UninstallMatch } else { $i.Match }
                $existing = Find-InstalledProducts -Pattern $cleanPattern
                foreach ($e in $existing) {
                    Step "$($i.Name) - pre-clean (ForceReinstall)"
                    Info "  found existing: $($e.DisplayName)"
                    Invoke-SilentUninstall -DisplayName $e.DisplayName `
                        -UninstallString $e.UninstallString `
                        -QuietUninstallString $e.QuietUninstallString `
                        -ProductCode $e.PSChildName | Out-Null
                }
                if ($i.Iss) { Remove-InstallShieldOrphans -Pattern $cleanPattern | Out-Null }
            }

            $full = Join-Path $DownloadDir $i.File
            # docs/INSTALL-ENGINE.md#skipifinstalled and #zip
            # ponytail: bsdtar extracts ONE member; Expand-Archive would unpack all 471 MB.
            $skipInstalled = ($i.SkipIfInstalled -and -not $ForceReinstall -and
                              -not (Test-PriorInstallFailed -Name $i.Name) -and
                              [bool](Find-InstalledProducts -Pattern $i.Match))
            if ($i.Zip) {
                if ($skipInstalled) { Info "  $($i.Name) already installed - not re-extracting $($i.ZipMember)" }
                elseif ($DryRun) { Dry "would extract $($i.ZipMember) from $($i.File)" }
                else {
                    & "$env:SystemRoot\System32\tar.exe" -xf $full -C $DownloadDir $i.ZipMember
                    if ($LASTEXITCODE -ne 0) {
                        Step $i.Name
                        Fail "could not extract $($i.ZipMember) from $($i.File) (tar exit $LASTEXITCODE) - not installing a possibly partial binary"
                        $Manifest.installed += @{
                            name=$i.Name; source=$full; method='exe'
                            displayNameMatch=$i.Match; result='fail-extract'
                        }
                        continue
                    }
                }
                $full = Join-Path $DownloadDir ($i.ZipMember -replace '/','\')
            }
            if ($i.Msi) {
                if (-not $ForceReinstall -and -not (Test-PriorInstallFailed -Name $i.Name) -and
                    (Find-InstalledProducts -Pattern $i.Match)) {
                    Add-AlreadyInstalledRow -Name $i.Name -Source $full -Method 'msi' -Match $i.Match
                    continue
                }
                Invoke-Msi -Name $i.Name -Msi $full -DisplayNameMatch $i.Match
            } elseif ($i.Iss) {
                $uMatch = if ($i.UninstallMatch) { $i.UninstallMatch } else { $i.Match }
                if (-not $ForceReinstall -and -not (Test-PriorInstallFailed -Name $i.Name) -and
                    (Find-InstalledProducts -Pattern $i.Match)) {
                    Add-AlreadyInstalledRow -Name $i.Name -Source $full -Method 'iss-silent' -Match $uMatch
                    continue
                }
                $issOpt = @{}
                if ($i.IssArgFormat) { $issOpt['ArgFormat'] = $i.IssArgFormat }
                if ($i.IssWaitNames) { $issOpt['WaitNames'] = $i.IssWaitNames }
                if ($i.Keys -contains 'IssReapNames')            { $issOpt['ReapNames'] = @($i.IssReapNames) }
                if ($i.Keys -contains 'IssRegistryShortCircuit') { $issOpt['RegistryShortCircuit'] = [bool]$i.IssRegistryShortCircuit }
                $res = Invoke-IssSilent -Name $i.Name -WrapperPath $full `
                    -IssContent $i.IssContent -IssLeaf ("{0}.iss" -f $i.Iss) `
                    -DisplayNameMatch $i.Match -RecordMatch $uMatch @issOpt
                if ($res -eq 'fail' -and -not $i.NoMsiFallback -and -not (Find-InstalledProducts -Pattern $i.Match)) {
                    $Manifest.installed = @($Manifest.installed | Where-Object { $_.name -ne $i.Name })
                    $cached = if ($i.CachedMsi) { Join-Path $DownloadDir $i.CachedMsi } else { $null }
                    if ($cached -and (Test-Path $cached)) {
                        Step "$($i.Name) - fallback to cached MSI"
                        Info "  iss-silent failed; using cached extracted MSI: $cached"
                        Invoke-Msi -Name $i.Name -Msi $cached -DisplayNameMatch $uMatch
                    } else {
                        Step "$($i.Name) - fallback to wrapper extraction"
                        Warn 'iss-silent failed; falling back to wrapper MSI extraction'
                        Invoke-WrappedMsi -Name $i.Name -WrapperPath $full -DisplayNameMatch $uMatch -ConfirmMatch $i.Match -CacheAs $i.CachedMsi
                    }
                    foreach ($row in $Manifest.installed) {
                        if ($row.name -eq $i.Name) { $row.note = 'msi-fallback' }
                    }
                }
            } else {
                if ($skipInstalled) {
                    Add-AlreadyInstalledRow -Name $i.Name -Source $full -Method 'exe' -Match $i.Match
                    continue
                }
                Invoke-Installer -Name $i.Name -Path $full -DisplayNameMatch $i.Match -ArgList $i.Args -ConfirmRegistry:([bool]$i.ConfirmRegistry)
            }
        } catch {
            Step $i.Name
            Fail "unhandled error: $($_.Exception.Message)"
            $Manifest.installed += @{
                name=$i.Name; source=(Join-Path $DownloadDir $i.File); method='exception'
                displayNameMatch=$i.Match; result='fail-exception'
            }
        }
    }
}

# docs/MANIFEST.md#merge
function Merge-PriorList {
    param($Current, $Prior, [scriptblock]$Key, [string]$Announce)
    $have = @{}
    foreach ($e in @($Current)) { $k = & $Key $e; if ($k) { $have[$k] = $true } }
    $merged = @($Current | Where-Object { $null -ne $_ })
    foreach ($p in @($Prior)) {
        $k = & $Key $p
        if ($k -and -not $have.ContainsKey($k)) {
            if ($Announce) { Info "  manifest: carrying forward prior $Announce '$k'" }
            $merged += $p; $have[$k] = $true
        }
    }
    return ,$merged
}

# docs/MANIFEST.md#save
function Save-Manifest {
    if ($DryRun) { Ok 'dry-run: manifest not persisted (real manifest preserved)'; return }
    if (Test-Path $ManifestPath) {
        try {
            $prior = Get-Content $ManifestPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $Manifest.installed              = Merge-PriorList $Manifest.installed              $prior.installed              { param($e) $e.name }   -Announce 'entry'
            $Manifest.filesPlaced            = Merge-PriorList $Manifest.filesPlaced            $prior.filesPlaced            { param($e) $e }
            # docs/MANIFEST.md#prior-wins  (args swapped here, and for regValuesSet + taskbandBackups)
            $Manifest.filesReplaced          = Merge-PriorList $prior.filesReplaced          $Manifest.filesReplaced       { param($e) $e.path }
            $Manifest.teamViewerRemoved      = Merge-PriorList $Manifest.teamViewerRemoved      $prior.teamViewerRemoved      { param($e) $e }
            $Manifest.dependencies           = Merge-PriorList $Manifest.dependencies           $prior.dependencies           { param($e) $e.name }   -Announce 'dependency'
            $Manifest.regValuesSet           = Merge-PriorList $prior.regValuesSet           $Manifest.regValuesSet        { param($e) if ($e.path) { "$($e.path)|$($e.name)" } }
            $Manifest.scheduledTasksCreated  = Merge-PriorList $Manifest.scheduledTasksCreated  $prior.scheduledTasksCreated  { param($e) $e.name }
            $Manifest.scheduledTasksDisabled = Merge-PriorList $Manifest.scheduledTasksDisabled $prior.scheduledTasksDisabled { param($e) $e.name }
            $Manifest.taskbandBackups        = Merge-PriorList $prior.taskbandBackups        $Manifest.taskbandBackups     { param($e) $e.sid }
            # docs/MANIFEST.md#key-selectors  (serialFinal / logicalName / whenUtc - a falsy prior key is dropped)
            $Manifest.scannerConfigured      = Merge-PriorList $Manifest.scannerConfigured      $prior.scannerConfigured      { param($e) if ($e.serialFinal) { $e.serialFinal } else { $e.serial } }
            $Manifest.printerConfigured      = Merge-PriorList $Manifest.printerConfigured      $prior.printerConfigured      { param($e) $e.logicalName }
            $Manifest.regKeysCreated         = Merge-PriorList $Manifest.regKeysCreated         $prior.regKeysCreated         { param($e) $e }
            $Manifest.accountCreated         = Merge-PriorList $Manifest.accountCreated         $prior.accountCreated         { param($e) $e.name }
            $Manifest.accountCheckOverride   = Merge-PriorList $Manifest.accountCheckOverride   $prior.accountCheckOverride   { param($e) $e.whenUtc }
            if ((-not $Manifest.computerRenamed -or @($Manifest.computerRenamed.Keys).Count -eq 0) -and $prior.computerRenamed -and $prior.computerRenamed.to) {
                $Manifest.computerRenamed = @{}
                foreach ($pn in $prior.computerRenamed.PSObject.Properties) { $Manifest.computerRenamed[$pn.Name] = $pn.Value }
            }
        } catch {
            $keep = "$ManifestPath.unreadable"
            try {
                Move-Item -LiteralPath $ManifestPath -Destination $keep -Force -ErrorAction Stop
                Warn "prior manifest unreadable ($($_.Exception.Message)) - kept as $keep"
            } catch {
                Warn "prior manifest unreadable and could not be preserved: $($_.Exception.Message)"
            }
            Warn 'this run''s manifest will NOT contain earlier runs - check the kept copy before -Uninstall.'
        }
    }
    $tmp = "$ManifestPath.tmp"
    try {
        ($Manifest | ConvertTo-Json -Depth 6) | Set-Content -Path $tmp -Encoding UTF8 -ErrorAction Stop
        Move-Item -LiteralPath $tmp -Destination $ManifestPath -Force -ErrorAction Stop
        Ok "manifest written: $ManifestPath"
    } catch {
        Fail "could not write manifest ${ManifestPath}: $($_.Exception.Message)"
        $script:ManifestWriteFailed = $true
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}


# docs/MANIFEST.md#set-trackedregvalue
function Set-TrackedRegValue {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Value,
        [ValidateSet('String','DWord')][string]$Type='String',
        [string]$WarnIfPresent
    )
    if ($DryRun) { Dry "would set $Path\$Name = $Value ($Type)"; return }

    $prev = $null; $prevAbsent = $true
    try {
        $existing = Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop
        $prev = $existing.$Name; $prevAbsent = $false
    } catch { Write-Verbose "Set-TrackedRegValue: no prior value for '$Name' under '$Path': $($_.Exception.Message)"; $prevAbsent = $true }
    if ($WarnIfPresent -and -not $prevAbsent -and "$prev" -ne "$Value") {
        Warn "$WarnIfPresent - existing value '$prev' is being replaced (restored on -Uninstall)"
    }

    if (-not (Test-Path $Path)) {
        $missing = @()
        $walk = $Path
        while ($walk -and -not (Test-Path $walk)) {
            $missing = @($walk) + $missing
            $parent = Split-Path $walk -Parent
            if ($parent -eq $walk) { break }
            $walk = $parent
        }
        New-Item -Path $Path -Force -ErrorAction Stop | Out-Null
        foreach ($m in $missing) {
            if ($Manifest.regKeysCreated -notcontains $m) { $Manifest.regKeysCreated += $m }
        }
    }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force -ErrorAction Stop | Out-Null
    $Manifest.regValuesSet += @{
        path=$Path; name=$Name; type=$Type
        value      = "$Value"
        prev       = if ($prevAbsent) { $null } else { "$prev" }
        prevAbsent = $prevAbsent
    }
}

# docs/FINISHING.md#rename
function Invoke-ComputerRename {
    Step 'Computer rename (POS name & number)'
    if ($SkipRename) { Ok 'rename skipped (-SkipRename)'; return }
    $current = $env:COMPUTERNAME
    Info "  current name: $current"

    $validate = {
        param($n)
        if ($n.Length -lt 1 -or $n.Length -gt 15) { return 'length must be 1-15 characters' }
        if ($n -notmatch '^[A-Za-z0-9-]+$')        { return 'use only letters, digits and hyphens' }
        if ($n -match '^[0-9]+$')                   { return 'name cannot be all digits' }
        if ($n -eq $current)                        { return 'that is already the current name' }
        return $null
    }

    $name = $null
    if ($ComputerName) {
        if ($ComputerName -eq $current) { Ok "already named '$current' - rename not needed"; return }
        $err = & $validate $ComputerName
        if ($err) { Fail "preset -ComputerName '$ComputerName' invalid: $err"; Warn 'skipping rename'; $script:FinishFailed = $true; return }
        $name = $ComputerName
    } elseif ([Environment]::UserInteractive -and -not $env:ALLEAVES_NOPAUSE) {
        try {
            while ($true) {
                $entry = Read-Host 'Enter new computer name (POS name & number), or press Enter to skip'
                if ([string]::IsNullOrWhiteSpace($entry)) { Ok 'rename skipped (no name entered)'; return }
                $entry = $entry.Trim()
                $err = & $validate $entry
                if (-not $err) { $name = $entry; break }
                Warn "invalid: $err - try again (or Enter to skip)"
            }
        } catch {
            Warn "no console for rename prompt - skipping ($($_.Exception.Message))"; return
        }
    } else {
        Ok 'non-interactive run - rename skipped (pass -ComputerName to set it)'; return
    }

    if ($DryRun) {
        Dry "would rename computer '$current' -> '$name' (effective after reboot)"
        $Manifest.computerRenamed = @{ from=$current; to=$name; applied=$false; dryRun=$true }
        $script:RebootPending = $true
        return
    }
    try {
        Rename-Computer -NewName $name -Force -ErrorAction Stop
        Ok "computer will be renamed '$current' -> '$name' on next reboot"
        $Manifest.computerRenamed = @{ from=$current; to=$name; applied=$true }
        $script:RebootPending = $true
    } catch {
        Fail "rename failed: $($_.Exception.Message)"
        $Manifest.computerRenamed = @{ from=$current; to=$name; applied=$false; error="$($_.Exception.Message)" }
        $script:FinishFailed = $true
    }
}

# docs/FINISHING.md#profiles
function Get-TargetUserProfiles {
    $list = @()
    $pl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
    foreach ($k in (Get-ChildItem $pl -ErrorAction SilentlyContinue)) {
        $sid = $k.PSChildName
        if ($sid -notmatch '^S-1-5-21-[\d-]+-([\d]+)$') { continue }
        if ([int64]$Matches[1] -lt 1000) { continue }
        $pip = (Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue).ProfileImagePath
        if (-not $pip -or -not (Test-Path $pip)) { continue }
        $list += [pscustomobject]@{ Sid=$sid; Profile=$pip }
    }
    return $list
}

# docs/FINISHING.md#backup-loadedtaskbands
function Backup-LoadedTaskbands {
    foreach ($k in (Get-ChildItem 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue)) {
        $sid = $k.PSChildName
        if ($sid -notmatch '^S-1-5-21-' -or $sid -match '_Classes$') { continue }
        $tb = "Registry::HKEY_USERS\$sid\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband"
        if (-not (Test-Path $tb)) { continue }
        if (@($Manifest.taskbandBackups | Where-Object { $_.sid -eq $sid }).Count) { continue }
        try {
            $tp = Get-ItemProperty $tb -ErrorAction SilentlyContinue
            $Manifest.taskbandBackups += @{
                sid              = $sid
                favorites        = if ($tp.Favorites)        { [Convert]::ToBase64String([byte[]]$tp.Favorites) }        else { $null }
                favoritesResolve = if ($tp.FavoritesResolve) { [Convert]::ToBase64String([byte[]]$tp.FavoritesResolve) } else { $null }
            }
            Info "  backed up Taskband for $sid (restorable on uninstall)"
        } catch {
            Warn "could not back up Taskband for ${sid}: $($_.Exception.Message)"
        }
    }
}

# docs/FINISHING.md#taskbar  (NO XML comments in the here-string)
function Get-TaskbarXml {
    param([Parameter(Mandatory)][string[]]$LinkPaths)
    $pins = ($LinkPaths | ForEach-Object {
        "        <taskbar:DesktopApp DesktopApplicationLinkPath=`"$_`" />"
    }) -join "`r`n"
    @"
<?xml version="1.0" encoding="utf-8"?>
<LayoutModificationTemplate
    xmlns="http://schemas.microsoft.com/Start/2014/LayoutModification"
    xmlns:defaultlayout="http://schemas.microsoft.com/Start/2014/FullDefaultLayout"
    xmlns:start="http://schemas.microsoft.com/Start/2014/StartLayout"
    xmlns:taskbar="http://schemas.microsoft.com/Start/2014/TaskbarLayout"
    Version="1">
  <CustomTaskbarLayoutCollection PinListPlacement="Replace">
    <defaultlayout:TaskbarLayout>
      <taskbar:TaskbarPinList>
$pins
        <taskbar:DesktopApp DesktopApplicationID="Microsoft.Windows.Explorer" />
      </taskbar:TaskbarPinList>
    </defaultlayout:TaskbarLayout>
  </CustomTaskbarLayoutCollection>
</LayoutModificationTemplate>
"@
}

# docs/FINISHING.md#write-xmlfile
function Write-XmlFile {
    param([string]$Path, [string]$Xml)
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $prior = Get-PriorManifest
    $ours  = ((@($prior.filesPlaced) -contains $Path) -or
              (@($prior.filesReplaced | Where-Object { $_.path -eq $Path -and $_.backup -and (Test-Path -LiteralPath $_.backup) }).Count -gt 0)) -and
             -not @($prior.filesReplaced | Where-Object { $_.path -eq $Path -and -not (Test-Path -LiteralPath $_.backup) }).Count
    if ((Test-Path -LiteralPath $Path) -and $Manifest -and -not $ours -and
        -not $script:PriorManifestUnreadable -and
        -not @($Manifest.filesReplaced | Where-Object { $_.path -eq $Path })) {
        $bak = "$Path.alleaves-orig"
        try {
            if (-not (Test-Path -LiteralPath $bak)) { Copy-Item -LiteralPath $Path -Destination $bak -Force -ErrorAction Stop }
            $Manifest.filesReplaced += @{ path=$Path; backup=$bak }
            Info "  backed up existing $Path (restored on uninstall)"
        } catch { Warn "could not back up existing ${Path}: $($_.Exception.Message)" }
    }
    [IO.File]::WriteAllText($Path, ($Xml -replace "`r?`n","`r`n"), (New-Object System.Text.UTF8Encoding($false)))
}

# docs/FINISHING.md#no-hardcoded-c
$StartMenuAll    = Join-Path $env:ALLUSERSPROFILE 'Microsoft\Windows\Start Menu\Programs'
$StartMenuAllEnv = '%ALLUSERSPROFILE%\Microsoft\Windows\Start Menu\Programs'

# docs/FINISHING.md#pinned-lnk
$TaskbarPinNames  = @('Alleaves Terminal', 'Alleaves POS')
$UserPinnedRelDir = 'AppData\Roaming\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar'

# docs/FINISHING.md#shortcuts
function New-TrackedShortcut {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Target,
        [string]$Arguments,
        [string]$Description
    )
    if (-not (Test-Path $Target)) { Warn "shortcut target missing ($Target) - skipping '$Name'"; return $null }
    $lnk = Join-Path $StartMenuAll "$Name.lnk"
    try {
        $sc = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
        $sc.TargetPath       = $Target
        $sc.Arguments        = $Arguments
        $sc.WorkingDirectory = Split-Path $Target -Parent
        $sc.Description      = if ($Description) { $Description } else { $Name }
        $sc.Save()
    } catch { Warn "could not create '$lnk': $($_.Exception.Message)"; return $null }
    $Manifest.filesPlaced += $lnk
    Ok "all-users shortcut created: $lnk"
    return $lnk
}

# docs/FINISHING.md#launcher-path
function Get-AlleavesLauncherPath {
    $p = @(Find-InstalledProducts -Pattern 'Alleaves Terminal')[0]
    if (-not $p) { return $null }
    if ($p.InstallLocation) {
        $exe = Join-Path $p.InstallLocation.TrimEnd('\') 'AlleavesLauncher.exe'
        if (Test-Path $exe) { return $exe }
    }
    $icon = ($p.DisplayIcon -replace ',\d+\s*$','').Trim().Trim('"')
    if ($icon -and $icon -match 'AlleavesLauncher\.exe$' -and (Test-Path $icon)) { return $icon }
    foreach ($root in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, "$env:LOCALAPPDATA\Programs")) {
        if (-not $root -or -not (Test-Path $root)) { continue }
        $hit = Get-ChildItem -LiteralPath $root -Filter 'AlleavesLauncher.exe' -Recurse -Depth 3 -File -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    return $null
}

function Get-ChromeExePath {
    $ap = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe' -ErrorAction SilentlyContinue).'(default)'
    if ($ap -and (Test-Path $ap)) { return $ap }
    return $null
}

# docs/FINISHING.md#taskbar  (marker stamp: #stamp)
function Invoke-ChromeTaskbar {
    Step 'Taskbar: pin Alleaves Terminal + Alleaves POS, remove Edge'
    if ($SkipChromeTaskbar) { Ok 'taskbar step skipped (-SkipChromeTaskbar)'; return }

    $terminalPin = $TaskbarPinNames[0]
    $posPin      = $TaskbarPinNames[1]
    $pins = @()
    if ($DryRun) {
        Dry "would create '$StartMenuAll\$terminalPin.lnk' -> AlleavesLauncher.exe"
        Dry "would create '$StartMenuAll\$posPin.lnk' -> chrome.exe $AlleavesUrl"
        $pins = @("$StartMenuAllEnv\$terminalPin.lnk", "$StartMenuAllEnv\$posPin.lnk")
    } else {
        $launcher = Get-AlleavesLauncherPath
        if (-not $launcher) { Warn 'could not locate AlleavesLauncher.exe - not pinning Alleaves Terminal' }
        elseif (New-TrackedShortcut -Name $terminalPin -Target $launcher) {
            $pins += "$StartMenuAllEnv\$terminalPin.lnk"
        }
        $chrome = Get-ChromeExePath
        if (-not $chrome) { Warn 'Google Chrome not installed - not pinning the Alleaves POS shortcut' }
        elseif (New-TrackedShortcut -Name $posPin -Target $chrome -Arguments $AlleavesUrl -Description "Alleaves POS ($AlleavesUrl)") {
            $pins += "$StartMenuAllEnv\$posPin.lnk"
        }
    }
    if (-not $pins.Count) {
        Fail 'no taskbar shortcut could be created (product missing or shortcut write refused - see warnings above) - skipping the taskbar step'
        $script:FinishFailed = $true
        return
    }
    $xml = Get-TaskbarXml -LinkPaths $pins

    # docs/FINISHING.md#where-the-xml-goes  (machine + Default profile + per-user, all three)
    $machineXml = Join-Path $WorkDir 'TaskbarLayoutModification.xml'
    if ($DryRun) {
        Dry "would write taskbar XML -> $machineXml"
        Dry 'would set HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\LayoutXMLPath (new profiles)'
    } else {
        try {
            Write-XmlFile -Path $machineXml -Xml $xml
            $Manifest.filesPlaced += $machineXml
            Set-TrackedRegValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer' -Name 'LayoutXMLPath' -Value $machineXml -Type 'String'
            Ok "LayoutXMLPath set (new profiles): $machineXml"
        } catch { Warn "could not write the machine taskbar XML: $($_.Exception.Message)" }
    }

    $defRoot = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' -ErrorAction SilentlyContinue).Default
    if ($defRoot) { $defRoot = [Environment]::ExpandEnvironmentVariables("$defRoot") }
    if (-not $defRoot) { $defRoot = Join-Path $env:SystemDrive 'Users\Default' }
    $defXml = Join-Path $defRoot 'AppData\Local\Microsoft\Windows\Shell\LayoutModification.xml'
    if ($DryRun) { Dry "would write Default-profile taskbar XML -> $defXml" }
    else {
        try { Write-XmlFile -Path $defXml -Xml $xml; $Manifest.filesPlaced += $defXml; Ok "Default-profile taskbar XML placed: $defXml" }
        catch { Warn "could not write Default-profile XML: $($_.Exception.Message)" }
    }

    $userXmlPlaced = 0
    if (-not $DryRun) { Backup-LoadedTaskbands }
    foreach ($u in (Get-TargetUserProfiles)) {
        $uXml = Join-Path $u.Profile 'AppData\Local\Microsoft\Windows\Shell\LayoutModification.xml'
        if ($DryRun) { Dry "would write per-user taskbar XML -> $uXml (sid $($u.Sid))"; $userXmlPlaced++; continue }
        try { Write-XmlFile -Path $uXml -Xml $xml; $Manifest.filesPlaced += $uXml; $userXmlPlaced++; Ok "per-user taskbar XML placed for $($u.Sid)" }
        catch { Warn "could not write per-user XML for $($u.Sid): $($_.Exception.Message)" }
    }

    if (-not $userXmlPlaced) {
        Fail 'no per-user taskbar layout could be written - not scheduling the per-user taskbar finish'
        Info '  (the pinned shortcuts were still created; pin them by hand or re-run)'
        $script:FinishFailed = $true
        return
    }
    $genRoot = 'HKLM:\SOFTWARE\AlleavesAuto'
    $gen = (Get-ItemProperty -Path $genRoot -Name 'TaskbarGeneration' -ErrorAction SilentlyContinue).TaskbarGeneration
    if (-not $gen) {
        $gen = (Get-Date).ToString('yyyyMMddHHmmss')
        try { Set-TrackedRegValue -Path $genRoot -Name 'TaskbarGeneration' -Value $gen -Type 'String' }
        catch {
            $priorGen = (Get-PriorManifest).regValuesSet | Where-Object { $_.name -eq 'TaskbarGeneration' -and $_.value } | Select-Object -Last 1
            if ($priorGen) {
                $gen = "$($priorGen.value)"
                Warn "could not record the taskbar generation ($($_.Exception.Message)) - reusing the prior run's generation '$gen'"
            } else {
                Warn "could not record the taskbar generation ($($_.Exception.Message)) - the taskbar will re-apply (clearing pins the cashier added) at every logon after every run until this write succeeds"
            }
        }
    }
    $script:TaskbarStamp  = ((@($pins) + $gen) -join '|')
    # docs/FINISHING.md#finish-taskbar-flag  (set only past the no-layout returns above)
    $script:FinishTaskbar = $true
    Info '  (taskbar is applied per user at the next logon by AlleavesAuto-FinishUser)'
}

# docs/FINISHING.md#default-browser
function Invoke-ChromeDefaultBrowser {
    Step 'Default browser: make Google Chrome default (http/https/.htm/.html)'
    if ($SkipDefaultBrowser) { Ok 'default-browser step skipped (-SkipDefaultBrowser)'; return }
    if (-not $DryRun -and -not (Find-InstalledProducts -Pattern 'Google Chrome')) {
        Warn 'Google Chrome not installed - skipping default-browser'; return
    }
    if (-not $DryRun -and -not (Test-Path 'HKLM:\SOFTWARE\Clients\StartMenuInternet\Google Chrome')) {
        Warn 'Chrome StartMenuInternet registration missing - default may not stick'
    }

    $ucpd = 'HKLM:\SYSTEM\CurrentControlSet\Services\UCPD'
    if (Test-Path $ucpd) {
        $cur = (Get-ItemProperty $ucpd -ErrorAction SilentlyContinue).Start
        if ($DryRun) {
            Dry "would set $ucpd\Start = 4 (disable UCPD next boot; current=$cur)"
            Dry "would disable task '\Microsoft\Windows\AppxDeploymentClient\UCPD velocity'"
        } else {
            if ($cur -eq 4) {
                Ok 'UCPD already disabled (Start=4)'
            } else {
                try {
                    Set-TrackedRegValue -Path $ucpd -Name 'Start' -Value 4 -Type 'DWord'
                    $script:RebootPending = $true
                    Ok 'UCPD disabled for next boot (Start=4) - restored on uninstall'
                } catch {
                    Fail "could not disable UCPD: $($_.Exception.Message)"
                    $script:FinishFailed = $true
                }
            }
            Disable-TrackedTask -TaskPath '\Microsoft\Windows\AppxDeploymentClient\' -TaskName 'UCPD velocity'
        }
    } else {
        Info '  UCPD service not present - no driver to disable (UserChoice writes may already work)'
    }
    $script:FinishBrowser = $true
    Info '  (Chrome is set default per user at the next logon by AlleavesAuto-FinishUser)'
}

# docs/FINISHING.md#chrome-policy  (start-page policies are BLOCKED - do not re-add)
function Invoke-ChromeBookmark {
    Step "Chrome: bookmark the Alleaves POS ($AlleavesUrl)"
    if ($SkipChromeBookmark) { Ok 'Chrome bookmark step skipped (-SkipChromeBookmark)'; return }
    if (-not $DryRun -and -not (Find-InstalledProducts -Pattern 'Google Chrome')) {
        Warn 'Google Chrome not installed - skipping the bookmark'; return
    }

    $bookmarks = @(
        @{ toplevel_name = 'Alleaves' }
        @{ name = 'Alleaves POS'; url = $AlleavesUrl }
    ) | ConvertTo-Json -Compress

    $root = 'HKLM:\SOFTWARE\Policies\Google\Chrome'
    try {
        Set-TrackedRegValue -Path $root -Name 'BookmarkBarEnabled' -Value 1 -Type 'DWord' `
            -WarnIfPresent 'Chrome BookmarkBarEnabled policy was already set'
        Set-TrackedRegValue -Path $root -Name 'ManagedBookmarks' -Value $bookmarks -Type 'String' `
            -WarnIfPresent 'another ManagedBookmarks policy is already present (its bookmarks will disappear while this install is in place)'
    } catch {
        Fail "could not write the Chrome bookmark policy: $($_.Exception.Message)"
        $script:FinishFailed = $true
        return
    }
    if (-not $DryRun) { Ok "Chrome policy set: 'Alleaves' bookmark -> $AlleavesUrl" }
    Info '  (applies the next time Chrome starts; verify at chrome://policy)'
}

# docs/FINISHING.md#disable-trackedtask
function Disable-TrackedTask {
    param([Parameter(Mandatory)][string]$TaskPath, [Parameter(Mandatory)][string]$TaskName)
    try {
        $t = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
        if (-not $t) { Ok "task '$TaskName' not present - nothing to disable"; return }
        if ($t.State -eq 'Disabled') { Ok "task '$TaskName' already disabled"; return }
        Disable-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction Stop | Out-Null
        $Manifest.scheduledTasksDisabled += @{ path=$TaskPath; name=$TaskName; prevState="$($t.State)" }
        Ok "disabled scheduled task: $TaskPath$TaskName"
    } catch {
        Fail "could not disable task '$TaskName': $($_.Exception.Message)"
        $script:FinishFailed = $true
    }
}

# docs/FINISHING.md#logon-task  (the here-string below is generated-script payload)
function Get-FinishScriptContent {
    param([bool]$DoBrowser, [bool]$DoTaskbar)
    $body = @'
# AlleavesAuto - per-user finish (set Chrome default browser + apply taskbar pin).
# Auto-generated by alleaves_setup.ps1. Runs at logon in the user's own context.
$ErrorActionPreference = 'SilentlyContinue'
$DoBrowser = __DO_BROWSER__
$DoTaskbar = __DO_TASKBAR__
$logDir = Join-Path $env:ProgramData 'AlleavesAuto\logs'
try { if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null } } catch {}
$log = Join-Path $logDir ("finish_{0}.log" -f $env:USERNAME)
function L($m) { try { Add-Content -Path $log -Value ("[{0}] {1}" -f (Get-Date).ToString('s'), $m) } catch {} }
$markRoot = 'HKCU:\Software\AlleavesAuto'
L "finish start (browser=$DoBrowser taskbar=$DoTaskbar)"
# F15: this task is group-scoped to BUILTIN\Users, so it also fires for the tech/
# admin. The taskbar/browser finishing is for the cashier - skip the account that
# RAN the installer (baked in below). NOTE: an IsInRole(Administrator) check is
# useless here - the task RunLevel is Limited, so the token is always filtered.
# Caveat: a single-account deploy where the installer IS the cashier gets skipped.
$installUser = '__INSTALL_USER__'
if ($installUser -and $env:USERNAME -eq $installUser) { L "running as installer '$installUser' (tech/admin) - skipping finish"; return }
# Chrome's URL-association ProgId, resolved HERE - at logon, in the user's own context -
# and only falling back to the value baked in at install time. A per-user Chrome install
# registers its capabilities under HKCU with a SUFFIXED ProgId (ChromeHTML.XXXXXXXX), which
# the installer's HKLM probe cannot see. Writing a well-formed UserChoice for a ProgId that
# does not exist still verifies OK - the readback below compares the key against what this
# script itself just wrote - while http links keep opening Edge.
$ChromeProgId = '__CHROME_PROGID__'
$userCap = (Get-ItemProperty 'HKCU:\SOFTWARE\Clients\StartMenuInternet\Google Chrome\Capabilities\URLAssociations' -ErrorAction SilentlyContinue).http
if ($userCap) { $ChromeProgId = "$userCap" }
L "chrome progId = $ChromeProgId"

# Algorithm provenance + validation: docs/FINISHING.md#environment
function Get-UserChoiceHash {
    param([string]$BaseInfo)
    function local:Get-ShiftRight([long]$iValue,[int]$iCount){
        if ($iValue -band 0x80000000) { (( $iValue -shr $iCount) -bxor 0xFFFF0000) } else { ($iValue -shr $iCount) }
    }
    function local:Get-Long([byte[]]$Bytes,[int]$Index=0){ [BitConverter]::ToInt32($Bytes,$Index) }
    function local:Convert-Int32([long]$Value){ [byte[]]$b=[BitConverter]::GetBytes($Value); [BitConverter]::ToInt32($b,0) }
    [Byte[]]$bytesBaseInfo=[System.Text.Encoding]::Unicode.GetBytes($BaseInfo); $bytesBaseInfo+=0x00,0x00
    $MD5=New-Object System.Security.Cryptography.MD5CryptoServiceProvider
    [Byte[]]$bytesMD5=$MD5.ComputeHash($bytesBaseInfo)
    $lengthBase=($BaseInfo.Length*2)+2
    $length=(($lengthBase -band 4) -le 1)+(Get-ShiftRight $lengthBase 2)-1
    $base64Hash=''
    if ($length -gt 1) {
        $map=@{PDATA=0;CACHE=0;COUNTER=0;INDEX=0;MD51=0;MD52=0;OUTHASH1=0;OUTHASH2=0;R0=0;R1=@(0,0);R2=@(0,0);R3=0;R4=@(0,0);R5=@(0,0);R6=@(0,0);R7=@(0,0)}
        $map.CACHE=0;$map.OUTHASH1=0;$map.PDATA=0
        $map.MD51=(((Get-Long $bytesMD5) -bor 1)+0x69FB0000L)
        $map.MD52=((Get-Long $bytesMD5 4) -bor 1)+0x13DB0000L
        $map.INDEX=Get-ShiftRight ($length-2) 1; $map.COUNTER=$map.INDEX+1
        while ($map.COUNTER) {
            $map.R0=Convert-Int32 ((Get-Long $bytesBaseInfo $map.PDATA)+[long]$map.OUTHASH1)
            $map.R1[0]=Convert-Int32 (Get-Long $bytesBaseInfo ($map.PDATA+4)); $map.PDATA=$map.PDATA+8
            $map.R2[0]=Convert-Int32 (($map.R0*([long]$map.MD51))-(0x10FA9605L*((Get-ShiftRight $map.R0 16))))
            $map.R2[1]=Convert-Int32 ((0x79F8A395L*([long]$map.R2[0]))+(0x689B6B9FL*(Get-ShiftRight $map.R2[0] 16)))
            $map.R3=Convert-Int32 ((0xEA970001L*$map.R2[1])-(0x3C101569L*(Get-ShiftRight $map.R2[1] 16)))
            $map.R4[0]=Convert-Int32 ($map.R3+$map.R1[0]); $map.R5[0]=Convert-Int32 ($map.CACHE+$map.R3)
            $map.R6[0]=Convert-Int32 (($map.R4[0]*[long]$map.MD52)-(0x3CE8EC25L*(Get-ShiftRight $map.R4[0] 16)))
            $map.R6[1]=Convert-Int32 ((0x59C3AF2DL*$map.R6[0])-(0x2232E0F1L*(Get-ShiftRight $map.R6[0] 16)))
            $map.OUTHASH1=Convert-Int32 ((0x1EC90001L*$map.R6[1])+(0x35BD1EC9L*(Get-ShiftRight $map.R6[1] 16)))
            $map.OUTHASH2=Convert-Int32 ([long]$map.R5[0]+[long]$map.OUTHASH1); $map.CACHE=([long]$map.OUTHASH2)
            $map.COUNTER=$map.COUNTER-1
        }
        [Byte[]]$outHash=@(0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
        [byte[]]$buffer=[BitConverter]::GetBytes($map.OUTHASH1);$buffer.CopyTo($outHash,0)
        $buffer=[BitConverter]::GetBytes($map.OUTHASH2);$buffer.CopyTo($outHash,4)
        $map=@{PDATA=0;CACHE=0;COUNTER=0;INDEX=0;MD51=0;MD52=0;OUTHASH1=0;OUTHASH2=0;R0=0;R1=@(0,0);R2=@(0,0);R3=0;R4=@(0,0);R5=@(0,0);R6=@(0,0);R7=@(0,0)}
        $map.CACHE=0;$map.OUTHASH1=0;$map.PDATA=0
        $map.MD51=((Get-Long $bytesMD5) -bor 1); $map.MD52=((Get-Long $bytesMD5 4) -bor 1)
        $map.INDEX=Get-ShiftRight ($length-2) 1; $map.COUNTER=$map.INDEX+1
        while ($map.COUNTER) {
            $map.R0=Convert-Int32 ((Get-Long $bytesBaseInfo $map.PDATA)+([long]$map.OUTHASH1)); $map.PDATA=$map.PDATA+8
            $map.R1[0]=Convert-Int32 ($map.R0*[long]$map.MD51)
            $map.R1[1]=Convert-Int32 ((0xB1110000L*$map.R1[0])-(0x30674EEFL*(Get-ShiftRight $map.R1[0] 16)))
            $map.R2[0]=Convert-Int32 ((0x5B9F0000L*$map.R1[1])-(0x78F7A461L*(Get-ShiftRight $map.R1[1] 16)))
            $map.R2[1]=Convert-Int32 ((0x12CEB96DL*(Get-ShiftRight $map.R2[0] 16))-(0x46930000L*$map.R2[0]))
            $map.R3=Convert-Int32 ((0x1D830000L*$map.R2[1])+(0x257E1D83L*(Get-ShiftRight $map.R2[1] 16)))
            $map.R4[0]=Convert-Int32 ([long]$map.MD52*([long]$map.R3+(Get-Long $bytesBaseInfo ($map.PDATA-4))))
            $map.R4[1]=Convert-Int32 ((0x16F50000L*$map.R4[0])-(0x5D8BE90BL*(Get-ShiftRight $map.R4[0] 16)))
            $map.R5[0]=Convert-Int32 ((0x96FF0000L*$map.R4[1])-(0x2C7C6901L*(Get-ShiftRight $map.R4[1] 16)))
            $map.R5[1]=Convert-Int32 ((0x2B890000L*$map.R5[0])+(0x7C932B89L*(Get-ShiftRight $map.R5[0] 16)))
            $map.OUTHASH1=Convert-Int32 ((0x9F690000L*$map.R5[1])-(0x405B6097L*(Get-ShiftRight ($map.R5[1]) 16)))
            $map.OUTHASH2=Convert-Int32 ([long]$map.OUTHASH1+$map.CACHE+$map.R3); $map.CACHE=([long]$map.OUTHASH2)
            $map.COUNTER=$map.COUNTER-1
        }
        $buffer=[BitConverter]::GetBytes($map.OUTHASH1);$buffer.CopyTo($outHash,8)
        $buffer=[BitConverter]::GetBytes($map.OUTHASH2);$buffer.CopyTo($outHash,12)
        [Byte[]]$outHashBase=@(0,0,0,0,0,0,0,0)
        $hashValue1=((Get-Long $outHash 8) -bxor (Get-Long $outHash))
        $hashValue2=((Get-Long $outHash 12) -bxor (Get-Long $outHash 4))
        $buffer=[BitConverter]::GetBytes($hashValue1);$buffer.CopyTo($outHashBase,0)
        $buffer=[BitConverter]::GetBytes($hashValue2);$buffer.CopyTo($outHashBase,4)
        $base64Hash=[Convert]::ToBase64String($outHashBase)
    }
    return $base64Hash
}
# Truncated to the MINUTE on purpose - not rounding: docs/FINISHING.md#minute-roll
function Get-HexDateTimeNow {
    $now=[DateTime]::Now
    $dt=[DateTime]::new($now.Year,$now.Month,$now.Day,$now.Hour,$now.Minute,0)
    return $dt.ToFileTime().ToString('x16')
}
$experience='User Choice set via Windows User Experience {D18B6DD5-6124-4341-9318-804003BAFA0B}'
# docs/FINISHING.md#minute-roll  (ProgId resolution: docs/FINISHING.md#progid)
function Set-UserChoiceDefault {
    param([string]$Token,[string]$ProgId)
    $sid=([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
    if ($Token.StartsWith('.')) {
        $kp="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FileExts\$Token\UserChoice"
        $rk="HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FileExts\$Token\UserChoice"
    } else {
        $kp="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell\Associations\UrlAssociations\$Token\UserChoice"
        $rk="HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell\Associations\UrlAssociations\$Token\UserChoice"
    }
    $have=(Get-ItemProperty $kp -ErrorAction SilentlyContinue)
    $cur=$have.ProgId
    # The Hash has to be there too: a ProgId with no hash is one Windows silently ignores.
    if ($cur -eq $ProgId -and $have.Hash) { L "$Token already $ProgId"; return $true }
    # The Remove-Item below destroys this user's prior association and -Uninstall cannot
    # put it back (it runs as the tech, and the cashier's hive is not loaded). Log what it
    # was so the value is at least recoverable by hand from finish_<user>.log.
    if ($cur) { L "$Token prior ProgId was '$cur' (NOT restored by -Uninstall)" }
    for ($try=0; $try -lt 3; $try++) {
        $hex=Get-HexDateTimeNow
        $baseInfo=("$Token$sid$ProgId$hex$experience").ToLower()
        $hash=Get-UserChoiceHash $baseInfo
        try { Remove-Item $kp -Recurse -Force -ErrorAction SilentlyContinue } catch { L "could not clear the prior UserChoice key: $($_.Exception.Message)" }
        try {
            [Microsoft.Win32.Registry]::SetValue($rk,'Hash',$hash)
            [Microsoft.Win32.Registry]::SetValue($rk,'ProgId',$ProgId)
        } catch { L "$Token write threw: $($_.Exception.Message)" }
        # Windows validates the hash against the key's LastWriteTime truncated to the MINUTE, and
        # three registry ops run between $hex and the last SetValue above, so the minute can roll
        # mid-write and the readback below would still report OK. docs/FINISHING.md#minute-roll
        if ((Get-HexDateTimeNow) -ne $hex) { L "$Token minute rolled during the write - rebuilding the hash, attempt $try"; continue }
        $now=Get-ItemProperty $kp -ErrorAction SilentlyContinue
        if ($now.ProgId -eq $ProgId -and $now.Hash -eq $hash) { L "$Token -> $ProgId OK"; return $true }
        L "$Token write not confirmed (UCPD still active?) attempt $try"
        Start-Sleep -Milliseconds 600
    }
    L "$Token FAILED to set $ProgId"
    return $false
}

if ($DoBrowser) {
    foreach ($t in 'http','https','.htm','.html') { Set-UserChoiceDefault -Token $t -ProgId $ChromeProgId | Out-Null }
}

if ($DoTaskbar) {
    # The marker holds the LAYOUT (the pin list), not a bare 1: a terminal deployed by an
    # older build carries TaskbarApplied=1, which never equals a stamp, so a changed pin
    # set re-applies exactly once and then settles. Compared as strings so the old DWORD
    # 1 and the new REG_SZ compare cleanly.
    $stamp='__TASKBAR_STAMP__'
    $applied=(Get-ItemProperty $markRoot -ErrorAction SilentlyContinue).TaskbarApplied
    # This user's own layout has to be on disk before we clear their pins. The installer's
    # $FinishTaskbar guard is GLOBAL - it arms as soon as ONE profile's XML landed - so a
    # profile whose write failed (read-only file on an OEM image) reached here, lost its
    # Taskband, got nothing back, and stamped the marker so it never retried.
    $myXml=Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Shell\LayoutModification.xml'
    if (-not (Test-Path $myXml)) { L "no per-user layout at $myXml - skipping the taskbar reset" }
    elseif ("$applied" -ne $stamp -or -not $stamp) {
        $tb='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband'
        try { Remove-ItemProperty -Path $tb -Name 'Favorites' -ErrorAction SilentlyContinue } catch { L "could not clear Taskband Favorites: $($_.Exception.Message)" }
        try { Remove-ItemProperty -Path $tb -Name 'FavoritesResolve' -ErrorAction SilentlyContinue } catch { L "could not clear Taskband FavoritesResolve: $($_.Exception.Message)" }
        if (-not (Test-Path $markRoot)) { New-Item -Path $markRoot -Force | Out-Null }
        # New-ItemProperty -Force, not Set-ItemProperty: the deployed value is a DWORD and
        # Set-ItemProperty would try to coerce the stamp into it and fail. -Force replaces
        # the value AND its type.
        New-ItemProperty -Path $markRoot -Name 'TaskbarApplied' -Value $stamp -PropertyType String -Force | Out-Null
        L "taskbar reset (cleared Taskband) for layout '$stamp'; restarting explorer"
        Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
        if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
    } else { L 'taskbar already applied for this user' }
}
L 'finish done'
'@
    $body = $body -replace '__DO_BROWSER__', $(if ($DoBrowser) { '$true' } else { '$false' })
    $body = $body -replace '__DO_TASKBAR__', $(if ($DoTaskbar) { '$true' } else { '$false' })
    $body = $body.Replace('__TASKBAR_STAMP__', ("$($script:TaskbarStamp)").Replace("'","''"))
    # docs/FINISHING.md#install-user  (pipeline, not @(): @($null).Count is 1)
    $swapped = @($Manifest.accountCreated | Where-Object { $_ }).Count -or
               @((Get-PriorManifest).accountCreated | Where-Object { $_ }).Count
    $installUser = if ($swapped) { '' } else { ("$env:USERNAME").Replace("'","''") }
    $body = $body.Replace('__INSTALL_USER__', $installUser)
    $chromeProgId = 'ChromeHTML'
    try {
        $cap = (Get-ItemProperty 'HKLM:\SOFTWARE\Clients\StartMenuInternet\Google Chrome\Capabilities\URLAssociations' -ErrorAction Stop).http
        if ($cap) { $chromeProgId = "$cap" }
    } catch { Write-Verbose "Get-FinishScriptContent: no machine-wide Chrome ProgId, using the default: $($_.Exception.Message)" }
    $body = $body.Replace('__CHROME_PROGID__', $chromeProgId.Replace("'","''"))
    return $body
}

# docs/FINISHING.md#logon-task  (#finish-bom, #install-user)
function Register-FinishLogonTask {
    if (-not ($script:FinishBrowser -or $script:FinishTaskbar)) { return }
    $finishPs = Join-Path $WorkDir 'AlleavesFinishUser.ps1'
    $taskName = 'AlleavesAuto-FinishUser'
    if ($DryRun) {
        Dry "would stage per-user finish script -> $finishPs"
        Dry "would register logon task '$taskName' (per user: browser=$($script:FinishBrowser) taskbar=$($script:FinishTaskbar))"
        return
    }
    Step 'Stage per-user finish (logon task)'
    try {
        [IO.File]::WriteAllText($finishPs, (Get-FinishScriptContent -DoBrowser $script:FinishBrowser -DoTaskbar $script:FinishTaskbar), (New-Object System.Text.UTF8Encoding($true)))
        $Manifest.filesPlaced += $finishPs
    } catch {
        Fail "could not stage finish script: $($_.Exception.Message)"
        $script:FinishFailed = $true; $script:FinishTaskbar = $false; $script:FinishBrowser = $false
        return
    }
    try {
        $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$finishPs`"" -ErrorAction Stop
        $trigger   = New-ScheduledTaskTrigger -AtLogOn -ErrorAction Stop
        $principal = New-ScheduledTaskPrincipal -GroupId 'S-1-5-32-545' -RunLevel Limited -ErrorAction Stop
        $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -ErrorAction Stop
        $def       = New-ScheduledTask -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'AlleavesAuto per-user finish: set Chrome default + apply taskbar pin.'
        Register-ScheduledTask -TaskName $taskName -InputObject $def -Force -ErrorAction Stop | Out-Null
        $Manifest.scheduledTasksCreated += @{ path='\'; name=$taskName }
        Ok "registered per-user logon task: $taskName (applies after the post-install reboot)"
    } catch {
        Fail "could not register logon task '$taskName': $($_.Exception.Message)"
        $script:FinishFailed = $true; $script:FinishTaskbar = $false; $script:FinishBrowser = $false
    }
}


# docs/SCANNER-OPOS.md  -- rig-dependent constants, see #open-items
$ScannerOpcodeSwitchHostMode = 6200
$ScannerHostCodeOpos         = 'XUA-45001-8'
$ScannerHostCodeIbmHandheld  = 'XUA-45001-1'

$ScannerTypeOpos     = 'OPOS'
$ScannerTypeIbmSnapi = 'SNAPI|IBMHID|IBMTT|IBM'
$ScannerTypeHidKb    = 'HIDKB|HIDKEYBOARD'
# docs/SCANNER-OPOS.md#known-models  (family regex, never a full SKU; must stay non-empty)
$ScannerKnownModels  = 'DS2208'

$ScannerReenumPollMs     = 1000
# ponytail: 40 s ceiling = the fingerprint script's proven $MaxWaitSec; tune down
# once the slowest real reconnect is known (docs/SCANNER-OPOS.md#open-items).
$ScannerReenumMaxWaitSec = 40

$ScannerStatusDeviceUnavailable = 112
$ScannerServiceNames = @('CoreScanner', 'rsmdriverproviderservice', 'ScnSrvc')
$ScannerServiceSettleSec = 8
$ScannerSwitchMaxRetries = 3
$ScannerRetryWaitSec     = 5

# docs/SCANNER-OPOS.md#two-hop
function Get-ScannerHostMode {
    param($Scanner)
    $t = ("$($Scanner.Type)").Trim()
    if ($t) {
        if ($t -match $ScannerTypeOpos)     { return 'OPOS' }
        if ($t -match $ScannerTypeIbmSnapi) { return 'IBM/SNAPI' }
        if ($t -match $ScannerTypeHidKb)    { return 'HID-KB' }
    }
    return 'unknown'
}

$script:ScannerInventoryStatus = 0
# docs/SCANNER-OPOS.md#inventory
function Get-CoreScannerInventory {
    param($Obj)
    $count  = [int16]0
    $ids    = New-Object int16[] 255
    $outXml = ''
    $st     = 0
    try { $Obj.GetScanners([ref]$count, $ids, [ref]$outXml, [ref]$st) }
    catch { Warn "GetScanners failed: $($_.Exception.Message)"; $script:ScannerInventoryStatus = -1; return @() }
    $script:ScannerInventoryStatus = [int]$st
    $list = @()
    if ($outXml) {
        try {
            [xml]$x = $outXml
            foreach ($n in @($x.scanners.scanner)) {
                if (-not $n) { continue }
                try {
                    $list += [pscustomobject]@{
                        Id       = [int]("$($n.scannerID)".Trim())
                        Model    = "$($n.modelnumber)".Trim()
                        Serial   = "$($n.serialnumber)".Trim()
                        Pid      = "$($n.PID)".Trim()
                        Type     = "$($n.type)".Trim()
                        Vid      = "$($n.VID)".Trim()
                        Firmware = "$($n.firmware)".Trim()
                    }
                } catch { Warn "skipping unparsable scanner node: $($_.Exception.Message)" }
            }
        } catch {
            Warn "could not parse GetScanners XML: $($_.Exception.Message)"
            # Only a still-clean status is overwritten - a real GetScanners code outranks ours
            if ($script:ScannerInventoryStatus -eq 0) { $script:ScannerInventoryStatus = -2 }
        }
    }
    if ($count -gt 0 -and $list.Count -eq 0 -and $script:ScannerInventoryStatus -eq 0) {
        Warn "GetScanners reported $count scanner(s) but none could be parsed"
        $script:ScannerInventoryStatus = -3
    }
    return ,$list
}

# docs/SCANNER-OPOS.md#the-command  (the arg-bool pair is silent+permanent; returns -1 on throw)
function Invoke-ScannerHostSwitch {
    param($Obj, [int]$ScannerId, [string]$HostCode)
    $inXml  = "<inArgs><scannerID>$ScannerId</scannerID><cmdArgs><arg-string>$HostCode</arg-string><arg-bool>TRUE</arg-bool><arg-bool>TRUE</arg-bool></cmdArgs></inArgs>"
    $outXml = ''
    $st     = 0
    try { $Obj.ExecCommand($ScannerOpcodeSwitchHostMode, [ref]$inXml, [ref]$outXml, [ref]$st) }
    catch { Warn "ExecCommand(6200,$HostCode) threw: $($_.Exception.Message)"; return -1 }
    return [int]$st
}

# docs/SCANNER-OPOS.md#rsm
function Confirm-ScannerServicesReady {
    if ($DryRun) { Dry 'would verify/start Zebra CoreScanner + RSM services before the OPOS switch'; return $true }

    $svcs = @()
    foreach ($n in $ScannerServiceNames) {
        $s = Get-Service -Name $n -ErrorAction SilentlyContinue
        if ($s) { $svcs += $s }
    }
    if (-not $svcs) { Warn '  no Zebra scanner services found (CoreScanner absent?)'; return $false }

    $started = $false
    foreach ($s in $svcs) {
        try {
            if ($s.Status -ne 'Running') {
                Info "  starting service '$($s.Name)' ($($s.DisplayName)) [was $($s.Status)]"
                Start-Service -Name $s.Name -ErrorAction Stop
                $started = $true
            }
        } catch { Warn "  could not start service '$($s.Name)': $($_.Exception.Message)" }
    }
    if ($started) { Start-Sleep -Seconds $ScannerServiceSettleSec }

    $core = Get-Service -Name 'CoreScanner' -ErrorAction SilentlyContinue
    return [bool]($core -and $core.Status -eq 'Running')
}

# docs/SCANNER-OPOS.md#rsm  (why 112, and why a not-Running CoreScanner breaks instead of retrying)
function Invoke-ScannerHostSwitchResilient {
    param($Obj, [int]$ScannerId, [string]$HostCode, [string]$HopLabel)
    $st = -1
    for ($try = 1; $try -le $ScannerSwitchMaxRetries; $try++) {
        $st = Invoke-ScannerHostSwitch -Obj $Obj -ScannerId $ScannerId -HostCode $HostCode
        if ($st -ne $ScannerStatusDeviceUnavailable) { break }
        Warn "    $HopLabel returned status 112 (RSM unavailable) - attempt $try/$ScannerSwitchMaxRetries"
        if ($try -lt $ScannerSwitchMaxRetries) {
            if (-not (Confirm-ScannerServicesReady)) {
                Warn '    CoreScanner service is not Running - further 112 retries cannot help'
                break
            }
            Start-Sleep -Seconds $ScannerRetryWaitSec
        }
    }
    return $st
}

# docs/SCANNER-OPOS.md#two-hop
function Get-ReenumeratedScanner {
    param($Obj, [string]$PreHopSerial, [int]$PreHopId, [string]$PreHopMode)
    $all = @(Get-CoreScannerInventory $Obj)
    if ($all.Count -eq 0) { return $null }
    if ($all.Count -eq 1) { return $all[0] }

    if ($PreHopSerial) {
        $bySerial = $all | Where-Object { $_.Serial -eq $PreHopSerial } | Select-Object -First 1
        if ($bySerial) { return $bySerial }
    }
    $moved = $all | Where-Object {
        $_.Id -ne $PreHopId -and (Get-ScannerHostMode $_) -ne $PreHopMode
    } | Select-Object -First 1
    if ($moved) { return $moved }

    Warn '    multiple scanners present and none uniquely re-matched - using first (best-effort)'
    return ($all | Select-Object -First 1)
}

# docs/SCANNER-OPOS.md#two-hop  (adaptive poll, not a fixed sleep; the ceiling only bites on a failed hop)
function Wait-ScannerReenum {
    param($Obj, [string]$PreHopSerial, [int]$PreHopId, [string]$PreHopMode)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $cand = $null
    while ($sw.Elapsed.TotalSeconds -lt $ScannerReenumMaxWaitSec) {
        Start-Sleep -Milliseconds $ScannerReenumPollMs
        # keep the last scanner actually seen - a mid-detach final poll must not erase it
        $seen = Get-ReenumeratedScanner -Obj $Obj -PreHopSerial $PreHopSerial -PreHopId $PreHopId -PreHopMode $PreHopMode
        if ($seen) { $cand = $seen }
        if ($cand -and ($cand.Id -ne $PreHopId -or (Get-ScannerHostMode $cand) -ne $PreHopMode)) { break }
    }
    $sw.Stop()
    return @{ Scanner = $cand; Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1) }
}

# docs/SCANNER-OPOS.md#fallback
function Show-ScannerBarcodeFallback {
    Warn '*********************************************************************'
    Warn '*  AUTOMATED USB-OPOS SWITCH FAILED - 1-SCAN BARCODE FIX AVAILABLE   *'
    Warn '*  1. Open Scanner_OPOS_barcode.pdf (AlleavesAuto repo / tech share) *'
    Warn '*     - the "OPOS (IBM Hand-Held with Full Disable)" host barcode.   *'
    Warn '*  2. Scan it ONCE with the Zebra scanner - it sets OPOS at once.    *'
    Warn '*  3. Reboot, then re-run with -ScannerConfigOnly to confirm/record. *'
    Warn '*********************************************************************'
}

# docs/SCANNER-OPOS.md#fingerprint
function Write-NewScannerFingerprint {
    param([string]$Model, [array]$Hops)
    $safe = ($Model -replace '[^\w.-]', '_')
    $path = Join-Path $LogDir ("scanner_new_model_{0}_{1:yyyyMMdd_HHmmss}.txt" -f $safe, (Get-Date))
    $out = @("NEW SCANNER MODEL fingerprint", "model    : $Model", "computer : $env:COMPUTERNAME",
             "captured : $((Get-Date).ToString('o')) (during USB-OPOS switch)", "")
    foreach ($h in $Hops) {
        $s = $h.s
        if ($s) { $out += ("[{0}] type='{1}' pid={2} vid={3} serial='{4}' model='{5}' id={6} fw='{7}'  | status={8} reconnect={9}s" -f `
                    $h.label,$s.Type,$s.Pid,$s.Vid,$s.Serial,$s.Model,$s.Id,$s.Firmware,$h.status,$h.seconds) }
        else    { $out += ("[{0}] (no scanner re-enumerated)  | status={1} reconnect={2}s" -f $h.label,$h.status,$h.seconds) }
    }
    try { $out | Set-Content -Path $path -Encoding UTF8 -ErrorAction Stop }
    catch {
        Warn "new scanner model '$Model' - could NOT write its fingerprint log: $($_.Exception.Message)"
        return $null
    }
    Warn '*********************************************************************'
    Warn '*  NEW SCANNER MODEL - PLEASE SAVE / SEND THESE LOGS                *'
    Warn '*  No confirmed OPOS timing for this model yet. A per-hop           *'
    Warn '*  fingerprint was written so the switch can be finalized for it.   *'
    Warn '*********************************************************************'
    Warn "    model: $Model"
    Warn "    log:   $path"
    return $path
}

# docs/SCANNER-OPOS.md  (every bail records a row: #bails)
function Set-ScannerOpos {
    Step 'Set Zebra scanner(s) to USB-OPOS'

    # every bail records a row: docs/SCANNER-OPOS.md#bails
    $bail = { param($r) $Manifest.scannerConfigured += @{
        serial=$null; model=$null; hostBefore=$null; target='USB-OPOS'; result=$r; removable=$false } }

    if ($SkipScannerConfig) {
        Ok 'scanner OPOS skipped (-SkipScannerConfig)'
        & $bail 'skipped:flag'
        return
    }
    if ($script:ScannerDegraded) {
        Warn 'CoreScanner missing - skipping scanner OPOS'
        & $bail 'skipped:degraded'
        return
    }

    if ($DryRun) {
        Dry 'would set connected Zebra scanner(s) to USB-OPOS via CoreScanner (opcode 6200, XUA-45001-8)'
        & $bail 'dryrun'
        return
    }

    $interopDll = Join-Path $env:ProgramFiles 'Zebra Technologies\Barcode Scanners\Common\Interop.CoreScanner.dll'
    if (-not (Test-Path $interopDll)) {
        Warn "Interop.CoreScanner.dll not found ($interopDll) - skipping scanner OPOS"
        & $bail 'no-interop'
        $script:ScannerConfigFailed = $true
        return
    }

    $obj = $null
    $status    = 0
    $appHandle = 0
    $opened    = $false
    try {
        [System.Reflection.Assembly]::LoadFile($interopDll) | Out-Null
        $obj = New-Object Interop.CoreScanner.CCoreScannerClass

        $types = New-Object int16[] 1; $types[0] = 1
        $obj.Open($appHandle, $types, [int16]1, [ref]$status)
        if ($status -ne 0) {
            Warn "CoreScanner Open() returned status $status - skipping scanner OPOS"
            & $bail "open-failed:$status"
            $script:ScannerConfigFailed = $true
            return
        }
        $opened = $true

        if (-not (Confirm-ScannerServicesReady)) {
            Fail 'Zebra CoreScanner service is not Running - the RSM channel the OPOS switch rides is unavailable'
            & $bail 'rsm-unavailable'
            $script:ScannerConfigFailed = $true
            return
        }

        $scanners = @(Get-CoreScannerInventory $obj)
        if ($scanners.Count -eq 0 -and $script:ScannerInventoryStatus -ne 0) {
            Fail "GetScanners failed (status $script:ScannerInventoryStatus) - cannot enumerate scanners"
            & $bail "enum-failed:$script:ScannerInventoryStatus"
            $script:ScannerConfigFailed = $true
            return
        }
        if ($scanners.Count -eq 0) {
            Warn 'no Zebra scanner connected - skipping OPOS (re-run with the scanner attached)'
            & $bail 'no-scanner'
            return
        }

        foreach ($s in $scanners) {
            $label = "$($s.Model) [$($s.Serial)]"
            $mode  = $null
            $result = 'fail'
            $entry = $null
            $script:ScannerFinalSerial = $s.Serial
            $script:ScannerFinalModel  = $s.Model
            $script:ScannerHopLog = @( @{ label='initial'; s=$s; status=$null; seconds=$null } )
            try {
            $mode  = Get-ScannerHostMode $s

            if ($mode -eq 'OPOS') {
                Ok "  $label already USB-OPOS - no change"
                $result = 'already-opos'
            }
            else {
                $direct = ($mode -eq 'IBM/SNAPI')
                if ($direct) { Info "  $label : $mode -> USB-OPOS (direct)" }
                else         { Info "  $label : $mode -> IBM Hand-held -> USB-OPOS (two-hop)" }
                $result = Set-OneScannerToOpos -Obj $obj -Scanner $s -DirectFromIbm:$direct
            }

            switch ($result) {
                'ok'           { Ok   "  $label set to USB-OPOS" }
                'already-opos' { }
                default        { Fail "  $label could NOT be set to USB-OPOS (result=$result)"; $script:ScannerConfigFailed = $true }
            }
            # docs/SCANNER-OPOS.md#uninstall  (removable=$false: hardware state, recorded not reversed)
            $entry = @{
                serial=$s.Serial; serialFinal=$script:ScannerFinalSerial; model=$s.Model
                modelFinal=$script:ScannerFinalModel; hostBefore=$mode; target='USB-OPOS'
                result=$result; removable=$false
            }
            $newModel     = $script:ScannerFinalModel
            $unknownModel = [bool]($newModel -and ($newModel -notmatch $ScannerKnownModels))
            if ($unknownModel -or $ForceFingerprint -or (-not $newModel)) {
                if ($unknownModel) { $entry.newModel = $true }
                $dumpModel = if ($newModel) { $newModel } else { 'unknown-model' }
                $entry.fingerprintLog = Write-NewScannerFingerprint -Model $dumpModel -Hops $script:ScannerHopLog
            }
            } catch {
                # A throw PAST the verdict (the fingerprint dump) must not unmake a confirmed
                # switch - it would force exit 6 on a scanner that IS in OPOS.
                if ($entry -and $entry.result -in @('ok','already-opos')) {
                    Warn "  $label is in USB-OPOS, but its bookkeeping threw: $($_.Exception.Message)"
                } else {
                    Fail "  $label threw during the OPOS switch: $($_.Exception.Message)"
                    $script:ScannerConfigFailed = $true
                    if (-not $entry) {
                        $entry = @{ serial=$s.Serial; serialFinal=$script:ScannerFinalSerial; model=$s.Model
                                    modelFinal=$script:ScannerFinalModel; hostBefore=$mode; target='USB-OPOS'
                                    removable=$false }
                    }
                    $entry.result = "fail: $($_.Exception.Message)"
                }
            }
            if ($entry) { $Manifest.scannerConfigured += $entry }
        }
    } catch {
        Fail "scanner OPOS step failed: $($_.Exception.Message)"
        & $bail "error: $($_.Exception.Message)"
        $script:ScannerConfigFailed = $true
    } finally {
        if ($obj) {
            if ($opened) { try { $closeSt = 0; $obj.Close($appHandle, [ref]$closeSt) } catch { Write-Verbose "Set-ScannerOpos: Close() failed: $($_.Exception.Message)" } }
            try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($obj) | Out-Null } catch { Write-Verbose "Set-ScannerOpos: ReleaseComObject failed: $($_.Exception.Message)" }
        }
    }
}

# docs/SCANNER-OPOS.md#two-hop  (#verify)
function Set-OneScannerToOpos {
    param($Obj, $Scanner, [switch]$DirectFromIbm)
    $serial = $Scanner.Serial
    $id     = $Scanner.Id
    $mode0  = Get-ScannerHostMode $Scanner

    if (-not $DirectFromIbm) {
        $st1 = Invoke-ScannerHostSwitchResilient -Obj $Obj -ScannerId $id `
                 -HostCode $ScannerHostCodeIbmHandheld -HopLabel 'hop1 (IBM Hand-held)'
        if ($st1 -ne 0) { Warn "    hop1 (IBM Hand-held) returned status $st1" }
        if ($st1 -eq $ScannerStatusDeviceUnavailable -or $st1 -lt 0) {
            Warn "    hop1 gave status $st1 after $ScannerSwitchMaxRetries attempts - RSM unavailable"
            $script:ScannerHopLog += @{ label='after hop1 (IBM)'; s=$null; status=$st1; seconds=0 }
            return 'fail'
        }
        $w1 = Wait-ScannerReenum -Obj $Obj -PreHopSerial $serial -PreHopId $id -PreHopMode $mode0
        $re = $w1.Scanner
        $script:ScannerHopLog += @{ label='after hop1 (IBM)'; s=$re; status=$st1; seconds=$w1.Seconds }
        Info "    re-enumerated in $($w1.Seconds)s"
        if (-not $re) { Warn '    scanner did not re-enumerate after the IBM Hand-held hop'; return 'fail' }
        $id     = $re.Id
        $serial = $re.Serial
        $mode0  = Get-ScannerHostMode $re
        if ($re.Serial) { $script:ScannerFinalSerial = $re.Serial }
        if ($re.Model)  { $script:ScannerFinalModel  = $re.Model }
        if ($mode0 -eq 'HID-KB') {
            Warn '    hop1 did not move the scanner out of HID-KB - refusing the illegal direct OPOS hop'
            return 'fail'
        }
    }

    $st2 = Invoke-ScannerHostSwitchResilient -Obj $Obj -ScannerId $id `
             -HostCode $ScannerHostCodeOpos -HopLabel 'hop2 (OPOS)'
    if ($st2 -ne 0) { Warn "    hop2 (OPOS) returned status $st2" }
    if ($st2 -eq $ScannerStatusDeviceUnavailable -or $st2 -lt 0) {
        Warn "    hop2 gave status $st2 after $ScannerSwitchMaxRetries attempts - RSM unavailable"
        $script:ScannerHopLog += @{ label='after hop2 (OPOS)'; s=$null; status=$st2; seconds=0 }
        return 'fail'
    }
    $w2 = Wait-ScannerReenum -Obj $Obj -PreHopSerial $serial -PreHopId $id -PreHopMode $mode0
    $after = $w2.Scanner
    $script:ScannerHopLog += @{ label='after hop2 (OPOS)'; s=$after; status=$st2; seconds=$w2.Seconds }
    Info "    re-enumerated in $($w2.Seconds)s"
    if ($after) {
        if ($after.Serial) { $script:ScannerFinalSerial = $after.Serial }
        if ($after.Model)  { $script:ScannerFinalModel  = $after.Model }
        $newMode = Get-ScannerHostMode $after
        if ($newMode -eq 'OPOS') { return 'ok' }
        Warn "    post-switch mode is '$newMode' (status $st2) - OPOS not confirmed"
        return 'fail'
    }
    return 'fail'
}

# docs/MANIFEST.md#uninstall-phase
function Invoke-UninstallPhase {
    if (-not (Test-Path $ManifestPath)) {
        Fail "Manifest not found: $ManifestPath"
        Fail "Cannot proceed - run the installer first."
        return 1
    }
    $man = $null
    try { $man = Get-Content $ManifestPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop } catch {
        Fail "Manifest unreadable ($ManifestPath): $($_.Exception.Message)"
        Fail 'Refusing to run a no-op uninstall - fix or remove the manifest and re-run.'
        return 1
    }
    if (-not $man) { Fail "Manifest is empty: $ManifestPath"; return 1 }
    Write-Host "Manifest from $($man.timestamp) on $($man.machine) by $($man.user)" -ForegroundColor Cyan

    $uninstallFailures = 0

    # docs/MANIFEST.md#step-1
    Step 'Remove placed files'
    if (-not $man.filesPlaced -or @($man.filesPlaced).Count -eq 0) {
        Ok 'manifest records no placed files'
    } else {
        foreach ($f in $man.filesPlaced) {
            if (-not (Test-Path -LiteralPath $f)) { Warn "$f already gone"; continue }
            if ($DryRun) { Dry "would delete $f"; continue }
            if ((Get-Item -LiteralPath $f -ErrorAction SilentlyContinue) -is [IO.DirectoryInfo] -and
                (Get-ChildItem -LiteralPath $f -Force -ErrorAction SilentlyContinue)) {
                Warn "keeping $f (not empty - contains files we did not place)"; continue
            }
            try { Remove-Item -LiteralPath $f -Force -ErrorAction Stop; Ok "deleted $f" }
            catch { Warn "could not delete ${f}: $($_.Exception.Message)"; $uninstallFailures++ }
        }
    }

    # docs/MANIFEST.md#step-1b  (must run AFTER the delete loop)
    foreach ($fr in @($man.filesReplaced)) {
        if (-not $fr.path -or -not $fr.backup) { continue }
        if ($DryRun) { Dry "would restore $($fr.path) from $($fr.backup)"; continue }
        if (-not (Test-Path -LiteralPath $fr.backup)) { Warn "backup $($fr.backup) is gone - cannot restore $($fr.path)"; $uninstallFailures++; continue }
        try {
            Move-Item -LiteralPath $fr.backup -Destination $fr.path -Force -ErrorAction Stop
            Ok "restored original $($fr.path)"
        } catch { Warn "could not restore $($fr.path): $($_.Exception.Message)"; $uninstallFailures++ }
    }

    Step 'Uninstall Alleaves stack'
    # docs/MANIFEST.md#step-2  (every attempt is replayed; removable=false = we never installed it)
    $reverseInstalled = @($man.installed | Where-Object {
        $_.result -and $_.removable -ne $false -and ($DryRun -or $_.result -ne 'dryrun') })
    [Array]::Reverse($reverseInstalled)
    if ($DryRun -and ($man.installed | Where-Object { $_.result -eq 'dryrun' })) {
        Warn "manifest is from a DRY-RUN install; in real-uninstall mode these would be skipped"
    }

    foreach ($entry in $reverseInstalled) {
        $pattern = $entry.displayNameMatch
        if (-not $pattern) { Warn "no displayNameMatch for $($entry.name); skipping"; continue }
        $found = Find-InstalledProducts -Pattern $pattern
        if (-not $found) { Warn "$($entry.name): not found in registry (already removed?)"; continue }
        foreach ($m in $found) {
            if (-not (Invoke-SilentUninstall -DisplayName $m.DisplayName `
                -UninstallString $m.UninstallString `
                -QuietUninstallString $m.QuietUninstallString `
                -ProductCode $m.PSChildName)) { $uninstallFailures++ }
        }
    }

    $hadZebraIss = $false
    foreach ($entry in $reverseInstalled) {
        # docs/INSTALL-ENGINE.md#iss-fallback  (an msi-fallback row was installed by msiexec, not the .iss)
        if (($entry.method -eq 'iss-silent' -or $entry.note -eq 'msi-fallback') -and $entry.displayNameMatch) {
            $hadZebraIss = $true
            $uninstallFailures += Remove-InstallShieldOrphans -Pattern $entry.displayNameMatch
        }
    }
    if ($hadZebraIss) {
        $cs = Get-Service CoreScanner -ErrorAction SilentlyContinue
        if ($cs) {
            $img = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\CoreScanner' -ErrorAction SilentlyContinue).ImagePath
            $bin = if ($img) { [Environment]::ExpandEnvironmentVariables(($img -replace '^"','' -replace '".*$','')) } else { $null }
            if (-not $bin -or -not (Test-Path $bin)) {
                if ($DryRun) {
                    Dry 'would delete orphaned CoreScanner service entry'
                } else {
                    if ($cs.Status -ne 'Stopped') { Stop-Service CoreScanner -Force -ErrorAction SilentlyContinue }
                    & "$env:SystemRoot\System32\sc.exe" delete CoreScanner | Out-Null
                    if ($LASTEXITCODE -eq 0) { Ok 'removed orphaned CoreScanner service entry' }
                    else { Warn "could not remove orphaned CoreScanner service: sc.exe exit $LASTEXITCODE"; $uninstallFailures++ }
                }
            } else {
                Info '  CoreScanner service binary still present - leaving service intact'
            }
        }
    }

    # docs/MANIFEST.md#step-3  (reported, never removed)
    if ($man.dependencies) {
        Step 'Uninstall bootstrap dependencies'
        foreach ($dep in $man.dependencies) { Ok "keeping shared dependency: $($dep.name)" }
    }

    # docs/MANIFEST.md#step-4a  (by name only; the row's path is unused here)
    foreach ($ct in @($man.scheduledTasksCreated)) {
        if (-not $ct.name) { continue }
        if ($DryRun) { Dry "would delete scheduled task: $($ct.name)"; continue }
        try { Unregister-ScheduledTask -TaskName $ct.name -Confirm:$false -ErrorAction Stop; Ok "deleted scheduled task: $($ct.name)" }
        catch { Warn "could not delete task $($ct.name): $($_.Exception.Message)"; $uninstallFailures++ }
    }

    if (@($man.regValuesSet | Where-Object { $_ }).Count) {
        # docs/MANIFEST.md#step-4b  (stale rows are tolerated, not resurrected: #stale-rows)
        Step 'Restore registry values'
        foreach ($rv in @($man.regValuesSet)) {
            if (-not $rv.path -or -not $rv.name) { continue }
            $absent = [bool]$rv.prevAbsent
            if ($DryRun) {
                if ($absent) { Dry "would remove $($rv.path)\$($rv.name)" } else { Dry "would restore $($rv.path)\$($rv.name) = $($rv.prev)" }
                continue
            }
            try {
                if ($absent) {
                    if (-not (Get-ItemProperty -Path $rv.path -Name $rv.name -ErrorAction SilentlyContinue)) {
                        Ok "already gone: $($rv.path)\$($rv.name)"
                        continue
                    }
                    if ($rv.name -eq '(default)') {
                        try {
                            if ($rv.path -notmatch '(?i)^HKLM:\\') {
                                Warn "cannot delete $($rv.path)\(default) - only HKLM paths are supported here"
                                $uninstallFailures++
                                continue
                            }
                            # docs/MANIFEST.md#default-value  (HKLM-only: regValuesSet records no hive)
                            $sub = $rv.path -replace '(?i)^HKLM:\\', ''
                            $h = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($sub, $true)
                            if ($h) {
                                try { $h.DeleteValue('', $false) } finally { $h.Close() }
                                Ok "removed $($rv.path)\(default)"
                            } else {
                                Warn "could not open $($rv.path) for write - (default) left behind"
                                $uninstallFailures++
                            }
                        } catch { Warn "could not remove $($rv.path)\(default): $($_.Exception.Message)"; $uninstallFailures++ }
                    } else {
                        Remove-ItemProperty -Path $rv.path -Name $rv.name -Force -ErrorAction Stop
                        Ok "removed $($rv.path)\$($rv.name)"
                    }
                } else {
                    $val = switch ($rv.type) {
                        'DWord'  { [int]$rv.prev }
                        default  { [string]$rv.prev }
                    }
                    if (-not (Test-Path $rv.path)) { Ok "already gone: $($rv.path) - nothing to restore"; continue }
                    New-ItemProperty -Path $rv.path -Name $rv.name -Value $val -PropertyType $rv.type -Force -ErrorAction Stop | Out-Null
                    Ok "restored $($rv.path)\$($rv.name) = $($rv.prev)"
                }
            } catch { Warn "could not restore $($rv.path)\$($rv.name): $($_.Exception.Message)"; $uninstallFailures++ }
        }
    }

    if (@($man.regKeysCreated | Where-Object { $_ }).Count) {
        # docs/MANIFEST.md#step-4b-ii  (an empty device key is a phantom OPOS device)
        Step 'Remove created registry keys'
        $ordered = @($man.regKeysCreated | Where-Object { $_ } | Sort-Object -Property @{ Expression = { ($_ -split '\\').Count } } -Descending)
        foreach ($rk in $ordered) {
            if (-not (Test-Path $rk)) { Ok "already gone: $rk"; continue }
            if ($DryRun) { Dry "would remove registry key: $rk"; continue }
            try {
                if ((Get-Item $rk -ErrorAction Stop).SubKeyCount -gt 0) { Warn "keeping $rk (has subkeys - another device lives under it)"; continue }
                Remove-Item -Path $rk -Force -ErrorAction Stop
                Ok "removed registry key: $rk"
            } catch { Warn "could not remove key ${rk}: $($_.Exception.Message)"; $uninstallFailures++ }
        }
    }

    # docs/MANIFEST.md#step-4c  (only those recorded enabled; no prevState = enabled)
    foreach ($dt in @($man.scheduledTasksDisabled)) {
        if (-not $dt.name) { continue }
        $wasEnabled = (-not $dt.PSObject.Properties['prevState']) -or ($dt.prevState -and $dt.prevState -ne 'Disabled')
        if (-not $wasEnabled) { Ok "task $($dt.name) was disabled before install - leaving disabled"; continue }
        if ($DryRun) { Dry "would re-enable scheduled task: $($dt.path)$($dt.name)"; continue }
        try { Enable-ScheduledTask -TaskPath $dt.path -TaskName $dt.name -ErrorAction Stop | Out-Null; Ok "re-enabled scheduled task: $($dt.name)" }
        catch { Warn "could not re-enable task $($dt.name): $($_.Exception.Message)"; $uninstallFailures++ }
    }

    # docs/MANIFEST.md#step-4d  (loaded hives only; an unloaded profile is cosmetic)
    foreach ($tb in @($man.taskbandBackups)) {
        if (-not $tb.sid) { continue }
        $hive = "Registry::HKEY_USERS\$($tb.sid)"
        $p    = "$hive\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband"
        if ($DryRun) { Dry "would restore Taskband for sid $($tb.sid)"; continue }
        if (-not (Test-Path $hive)) { Warn "sid $($tb.sid) hive not loaded - taskbar restore skipped (cosmetic)"; continue }
        try {
            if (-not (Test-Path $p)) { New-Item -Path $p -Force -ErrorAction Stop | Out-Null }
            if ($tb.favorites)        { New-ItemProperty -Path $p -Name 'Favorites'        -Value ([Convert]::FromBase64String($tb.favorites))        -PropertyType Binary -Force -ErrorAction Stop | Out-Null }
            if ($tb.favoritesResolve) { New-ItemProperty -Path $p -Name 'FavoritesResolve' -Value ([Convert]::FromBase64String($tb.favoritesResolve)) -PropertyType Binary -Force -ErrorAction Stop | Out-Null }
            Remove-ItemProperty -Path "$hive\Software\AlleavesAuto" -Name 'TaskbarApplied' -ErrorAction SilentlyContinue
            Ok "restored Taskband for sid $($tb.sid) (sign out/in to see the original pins)"
        } catch { Warn "could not restore Taskband for $($tb.sid): $($_.Exception.Message)"; $uninstallFailures++ }
    }

    # docs/MANIFEST.md#step-4e  (Explorer COPIES the .lnk; step 1 only knows the source)
    foreach ($u in (Get-TargetUserProfiles)) {
        foreach ($n in $TaskbarPinNames) {
            $pin = Join-Path $u.Profile (Join-Path $UserPinnedRelDir "$n.lnk")
            if (-not (Test-Path $pin)) { continue }
            if ($DryRun) { Dry "would remove pinned shortcut: $pin"; continue }
            try { Remove-Item $pin -Force -ErrorAction Stop; Ok "removed pinned shortcut: $pin" }
            catch { Warn "could not remove pinned shortcut '$pin': $($_.Exception.Message)"; $uninstallFailures++ }
        }
    }

    # docs/MANIFEST.md#not-reverted
    if ($man.computerRenamed -and $man.computerRenamed.to) {
        Info "  note: computer rename ('$($man.computerRenamed.from)' -> '$($man.computerRenamed.to)') is NOT reverted by design."
    }


    foreach ($ac in @($man.accountCreated)) {
        if (-not $ac -or -not $ac.name) { continue }
        $how = if ($ac.created) { 'created' } else { 'promoted to administrator' }
        Info "  note: local account '$($ac.name)' ($how by the installer) is NOT removed by design."
    }

    if ($uninstallFailures -gt 0) { Fail "$uninstallFailures reversal(s) failed (products, files, registry, tasks or pins)"; return 1 }
    return 0
}

# docs/PRINTER-OPOS.md  (WOW6432Node is deliberate: #why-registry)
$PrinterOposRoot = 'HKLM:\SOFTWARE\WOW6432Node\OLEforRetail\ServiceOPOS'

# CAPTURED from a real SetupPOS run, never authored: docs/PRINTER-OPOS.md#captured
$PosXPrinterStrings = [ordered]@{
    '(default)'='RecPrinter.POSPrinter.SOU'; ADKConfig='Thermal1.0'
    Description='OLE POS Printer OPOS Service Object'
    DeviceDesc='Thermal POS Printer (USB)'; DeviceName='ThermalU'
    Port='USB'; Version='1.0'
    BaudrateSel=''; BitLengthSel=''; HandShakeSel=''; IP=''; ParitySel=''; StopSel=''; XonXoffSel=''
}
$PosXPrinterDWords = [ordered]@{
    Baudrate=0; BitLength=0; DrawerOpen=1; HandShake=0; IdleSleep=10; InputBuf=0
    InputSleep=10; OutputBuf=1024; Parity=0; PortShare=0; Stop=0; Timeout=1000
    USBSerialNumber=0; XonXoff=0
}

# EMPTY until the bench capture - do NOT stub: docs/PRINTER-OPOS.md#uncaptured (#open-items)
$StarPrinterStrings = [ordered]@{}
$StarPrinterDWords  = [ordered]@{}
$StarDrawerStrings  = [ordered]@{}
$StarDrawerDWords   = [ordered]@{}

# docs/PRINTER-OPOS.md#brands  (RowName MUST match the row's Name/Label)
# docs/PRINTER-OPOS.md#device-count  (per brand, not global; a device row carries no Type/ProgId: #no-type-field)
$PrinterBrands = [ordered]@{
    'POS-X' = @{
        RowName='OLE POS Setup'; ArpPattern='OLE POS Setup'
        Devices=@(
            @{ Class='POSPrinter'; Suffix='_Printer'
               Strings=$PosXPrinterStrings; DWords=$PosXPrinterDWords }
        )
    }
    'StarTSP100' = @{
        RowName='Star TSP100 futurePRNT'; ArpPattern='TSP100 Setup Version'
        Devices=@(
            @{ Class='POSPrinter'; Suffix='_Printer'
               Strings=$StarPrinterStrings; DWords=$StarPrinterDWords }
            @{ Class='CashDrawer'; Suffix='_Drawer'
               Strings=$StarDrawerStrings;  DWords=$StarDrawerDWords }
        )
    }
}

# docs/PRINTER-OPOS.md#ldn
function Get-PosNamePrefix {
    if ($Manifest -and $Manifest.computerRenamed -and $Manifest.computerRenamed.to -and
        ($Manifest.computerRenamed.applied -or $Manifest.computerRenamed.dryRun)) {
        return $Manifest.computerRenamed.to
    }
    $pending = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' `
                -Name ComputerName -ErrorAction SilentlyContinue).ComputerName
    if ($pending) { return $pending }
    return $env:COMPUTERNAME
}

# docs/PRINTER-OPOS.md#brand-prompt
function Resolve-PrinterBrand {
    if ($script:PrinterBrandResolved) { return $script:PrinterBrandResolved }
    $brand = 'POS-X'
    if ($PrinterBrand) {
        $brand = $PrinterBrand
    } elseif ([Environment]::UserInteractive -and -not $env:ALLEAVES_NOPAUSE) {
        try {
            Info ''
            Info '  Receipt printer brand:'
            Info '    1) POS-X   (default)'
            Info '    2) None - no receipt printer (skips the driver install too)'
            Info '    3) Star TSP100 (futurePRNT)'
            $sel = Read-Host '  Select 1-3 (Enter for POS-X)'
            switch -Regex ("$sel".Trim()) {
                '^$'            { }
                '^(1|POS-?X)$'  { $brand = 'POS-X' }
                '^(2|None)$'    { $brand = 'None' }
                '^(3|Star.*)$'  { $brand = 'StarTSP100' }
                default         { Warn "unrecognized answer '$sel' - using POS-X" }
            }
        } catch {
            Warn "no console for the printer-brand prompt - defaulting to POS-X ($($_.Exception.Message))"
        }
    }
    $script:PrinterBrandResolved = $brand
    return $brand
}


# docs/PRINTER-OPOS.md#already-configured
# ponytail: the emptied CLASS key is left in place - it enumerates no devices, and
# -Uninstall still removes it via regKeysCreated.
function Test-PrinterOposConfigured {
    param(
        [Parameter(Mandatory)][string]$LogicalName,
        [Parameter(Mandatory)][string]$Class
    )
    $key = "$PrinterOposRoot\$Class\$LogicalName"
    if (-not (Test-Path $key)) { return $false }
    $k = Get-Item $key -ErrorAction SilentlyContinue
    if (-not $k) { return $false }
    return -not [string]::IsNullOrWhiteSpace($k.GetValue(''))
}

# docs/PRINTER-OPOS.md#stale  (#register-then-retire)
function Remove-StalePrinterOpos {
    param(
        [Parameter(Mandatory)][string[]]$Registered
    )
    $prior = Get-PriorManifest
    $failures = 0
    # docs/PRINTER-OPOS.md#stale-rows  (retired rows merge forward forever)
    foreach ($p in @($prior.printerConfigured)) {
        if (-not $p.logicalName -or -not $p.deviceClass) { continue }
        # docs/PRINTER-OPOS.md#removable-guard  (never delete a vendor-created device)
        if ($p.removable -eq $false) { continue }
        if ($Registered -contains $p.logicalName) { continue }
        $stale = "$PrinterOposRoot\$($p.deviceClass)\$($p.logicalName)"
        if (-not (Test-Path $stale)) { continue }
        if ($DryRun) { Dry "would remove stale OPOS device: $($p.logicalName)"; continue }
        try {
            if ((Get-Item $stale -ErrorAction Stop).SubKeyCount -gt 0) {
                Warn "stale OPOS device '$($p.logicalName)' has subkeys - left in place (may hold another vendor's device)"
                $failures++
                continue
            }
            Remove-Item -Path $stale -Force -ErrorAction Stop
            Ok "removed stale OPOS device: $($p.logicalName)"
        } catch {
            Warn "could not remove stale OPOS device '$($p.logicalName)': $($_.Exception.Message)"
            $failures++
        }
    }
    return $failures
}

# docs/PRINTER-OPOS.md  (#readback, #brand-switch, #bails)
function Set-PrinterOpos {
    # every bail records a row: docs/PRINTER-OPOS.md#bails
    $bail = { param($tag, $res, $b) $Manifest.printerConfigured += @{
        logicalName="(none:$tag)"; deviceClass=$null; deviceType=$null
        progId=$null; brand=$b; result=$res; removable=$true } }

    if ($SkipPrinterConfig) {
        Step 'Register receipt printer (OPOS)'
        Ok 'printer OPOS skipped (-SkipPrinterConfig)'
        & $bail 'skipped-flag' 'skipped:flag' $script:PrinterBrandResolved
        return
    }

    $brand = Resolve-PrinterBrand
    Step "Register $brand receipt printer (OPOS)"

    if ($brand -eq 'None') {
        Ok 'no receipt printer selected - skipping OPOS registration'
        & $bail 'None' 'skipped' $brand
        return
    }

    $brandDef = $PrinterBrands[$brand]
    if (-not $brandDef) {
        Fail "no device table for printer brand '$brand' - this is a build error, not a terminal fault"
        & $bail 'unknown-brand' 'fail: unknown brand' $brand
        if (-not $DryRun) { $script:PrinterConfigFailed = $true }
        return
    }

    # docs/PRINTER-OPOS.md#driver-guard  (ARP, not the ProgID - the vendor uninstaller leaves that behind)
    if (-not ($DryRun -and -not $PrinterConfigOnly) -and -not (Find-InstalledProducts -Pattern $brandDef.ArpPattern)) {
        Warn "$brand printer driver ('$($brandDef.RowName)') is not installed - skipping OPOS registration."
        Warn 'Install it (full run, or without -SkipPrograms), then re-run with -PrinterConfigOnly.'
        & $bail 'no-driver' 'no-driver' $brand
        return
    }

    $prefix = Get-PosNamePrefix
    $uncaptured = @($brandDef.Devices | Where-Object { $_.Strings.Count -eq 0 -or $_.DWords.Count -eq 0 -or -not $_.Strings['(default)'] })
    # docs/PRINTER-OPOS.md#no-devices  (an empty pipeline slips past $uncaptured and exits 0)
    $noDevices  = -not @($brandDef.Devices | Where-Object { $_ }).Count
    if ($noDevices -or $uncaptured) {
        $already = @($brandDef.Devices | Where-Object {
            Test-PrinterOposConfigured -LogicalName "$prefix$($_.Suffix)" -Class $_.Class })
        if (-not $noDevices -and $already.Count -eq @($brandDef.Devices).Count) {
            foreach ($dev in $brandDef.Devices) {
                $ldn    = "$prefix$($dev.Suffix)"
                $progId = (Get-Item "$PrinterOposRoot\$($dev.Class)\$ldn" -ErrorAction SilentlyContinue).GetValue('')
                Ok "OPOS $($dev.Class) '$ldn' is already configured -> $progId (nothing to do)"
                $Manifest.printerConfigured += @{
                    logicalName=$ldn; deviceClass=$dev.Class; deviceType=$null
                    progId=$progId; brand=$brand; result='already-configured'; removable=$false
                }
            }
            Warn "$brand OPOS values are still uncaptured in this build, so these entries were left exactly as they are."
            return
        }
        $what = if ($noDevices) { 'no devices defined' } else { ($uncaptured | ForEach-Object { $_.Class }) -join ', ' }
        if ($already.Count) {
            Warn "$($already.Count) of $(@($brandDef.Devices).Count) $brand OPOS device(s) are already configured, but not all of them."
        }
        Warn "$brand OPOS values have not been captured yet ($what)."
        Warn 'Run the bench capture in docs/PRINTER_OPOS_FIELD_RESULTS.md, fill the tables, then re-run with -PrinterConfigOnly.'
        & $bail 'not-captured' 'not-captured' $brand
        if (-not $DryRun) { $script:PrinterConfigFailed = $true }
        return
    }

    $prior = Get-PriorManifest
    # docs/PRINTER-OPOS.md#prior-brand
    $priorBrand = { param($ldn, $cls) $prior.printerConfigured |
        Where-Object { $_.logicalName -eq $ldn -and $_.deviceClass -eq $cls -and
                       $_.brand -and $_.brand -ne $brand } |
        ForEach-Object { $_.brand } }

    if ($DryRun) {
        $null = Remove-StalePrinterOpos -Registered @($brandDef.Devices | ForEach-Object { "$prefix$($_.Suffix)" })
        foreach ($dev in $brandDef.Devices) {
            $ldn = "$prefix$($dev.Suffix)"
            $wasBrand = @(& $priorBrand $ldn $dev.Class)
            if ($wasBrand -and (Test-Path "$PrinterOposRoot\$($dev.Class)\$ldn")) {
                Dry "would clear the $($wasBrand[-1]) OPOS values from '$ldn' before rewriting it as $brand"
            }
            Dry "would register OPOS $($dev.Class) '$ldn' -> $($dev.Strings['(default)']) ($($dev.Strings.Count + $dev.DWords.Count) values)"
            $Manifest.printerConfigured += @{
                logicalName=$ldn; deviceClass=$dev.Class; deviceType=$dev.Strings['DeviceName']
                progId=$dev.Strings['(default)']; brand=$brand; result='dryrun'; removable=$true
            }
        }
        return
    }

    $verified = @()
    $allOk    = $true
    foreach ($dev in $brandDef.Devices) {
        $ldn   = "$prefix$($dev.Suffix)"
        $key   = "$PrinterOposRoot\$($dev.Class)\$ldn"
        $keepBrand = $null

        # $keepBrand stamps the PRIOR brand, or the advised re-run reports ok
        $wasBrand = @(& $priorBrand $ldn $dev.Class)
        if ($wasBrand -and (Test-Path $key)) {
            try {
                if ((Get-Item $key -ErrorAction Stop).SubKeyCount -gt 0) {
                    throw "device key has subkeys (may hold another vendor's device)"
                }
                Remove-Item -Path $key -Force -ErrorAction Stop
                Ok "cleared the $($wasBrand[-1]) OPOS values from '$ldn' before rewriting it as $brand"
            } catch {
                Warn "could not clear the prior $($wasBrand[-1]) values from '$ldn': $($_.Exception.Message)"
                $script:PrinterConfigFailed = $true
                $keepBrand = $wasBrand[-1]
            }
        }
        $progId = $dev.Strings['(default)']
        # docs/PRINTER-OPOS.md#uninstall  (removable=$true: pure registry, reversed via regKeysCreated/regValuesSet)
        $entry = @{
            logicalName=$ldn; deviceClass=$dev.Class; deviceType=$dev.Strings['DeviceName']
            progId=$progId; brand=$(if ($keepBrand) { $keepBrand } else { $brand }); removable=$true
        }
        # docs/PRINTER-OPOS.md#per-device-catch  (a shared catch loses the drawer to the printer's failure)
        try {
            foreach ($n in $dev.Strings.Keys) { Set-TrackedRegValue -Path $key -Name $n -Value $dev.Strings[$n] -Type String }
            foreach ($n in $dev.DWords.Keys)  { Set-TrackedRegValue -Path $key -Name $n -Value ([int]$dev.DWords[$n]) -Type DWord }

            $k = Get-Item $key -ErrorAction Stop
            # docs/PRINTER-OPOS.md#null-vs-empty  ((default) must be read as GetValue(''): #default-alias)
            foreach ($n in $dev.Strings.Keys) {
                $got = $k.GetValue($(if ($n -eq '(default)') { '' } else { $n }))
                if ($null -eq $got -or "$got" -cne "$($dev.Strings[$n])") { throw "readback mismatch: '$n'='$got' expected '$($dev.Strings[$n])'" }
            }
            foreach ($n in $dev.DWords.Keys) {
                $got = $k.GetValue($n)
                if ($null -eq $got -or [int]$got -ne [int]$dev.DWords[$n]) { throw "readback mismatch: '$n'='$got' expected '$($dev.DWords[$n])'" }
            }

            Ok "OPOS $($dev.Class): $ldn -> $progId"
            $entry.result = 'ok'
            $verified += $ldn
        } catch {
            Fail "could not register OPOS $($dev.Class) '$ldn': $($_.Exception.Message)"
            $entry.result = "fail: $($_.Exception.Message)"
            $script:PrinterConfigFailed = $true
            $allOk = $false
        }
        $Manifest.printerConfigured += $entry
    }

    if ($allOk -and $verified.Count) {
        if ((Remove-StalePrinterOpos -Registered $verified) -gt 0) { $script:PrinterConfigFailed = $true }
    }
    elseif ($verified.Count) { Warn 'some devices failed - leaving existing OPOS device entries alone' }
    elseif (-not $allOk) { Warn 'all devices failed - leaving existing OPOS device entries alone' }
    else {
        Warn 'nothing registered - leaving any existing OPOS device entries alone'
        $script:PrinterConfigFailed = $true
    }

    if ($verified.Count) {
        Info "  Alleaves must be configured to open $(if ($verified.Count -gt 1) { 'these exact logical names' } else { 'this exact logical name' }): $($verified -join ', ')"
    }
}

# docs/MANIFEST.md#keys
function New-InstallManifest {
    [ordered]@{
        timestamp         = (Get-Date).ToString('o')
        machine           = $env:COMPUTERNAME
        user              = $env:USERNAME
        dryRun            = [bool]$DryRun
        workDir           = $WorkDir
        downloadDir       = $DownloadDir
        dependencies      = @()
        teamViewerRemoved = @()
        installed         = @()
        filesPlaced       = @()
        filesReplaced     = @()
        computerRenamed        = @{}
        regValuesSet           = @()
        regKeysCreated         = @()
        scheduledTasksCreated  = @()
        scheduledTasksDisabled = @()
        taskbandBackups        = @()
        scannerConfigured      = @()
        printerConfigured      = @()
        # marker -> manifest hop: docs/ACCOUNT-SWAP.md#swap
        accountCreated         = @(if ($script:AccountSwapDone) { $script:AccountSwapDone })
        accountCheckOverride   = @(if ($script:AccountCheckOverride) { $script:AccountCheckOverride })
    }
}

# docs/ARCHITECTURE.md#exit-codes
$exitCode = 0
# One transcript opener for all three modes: docs/ARCHITECTURE.md#run-shape
$ModeBanner = switch ($Mode) {
    'ScannerConfig' { @('scannercfg', 'Alleaves SCANNER-CONFIG ONLY (USB-OPOS)') }
    'PrinterConfig' { @('printercfg', 'Alleaves PRINTER-CONFIG ONLY (OPOS)') }
    'Uninstall'     { @('uninstall',  'Alleaves UNINSTALL') }
    default         { @('install',    'Alleaves bootstrap INSTALL') }
}
$RunLog = Join-Path $LogDir ("{0}_{1:yyyyMMdd_HHmmss}.log" -f $ModeBanner[0], (Get-Date))
try {
    Start-Transcript -Path $RunLog -Append | Out-Null
    Write-Host $ModeBanner[1] -ForegroundColor Cyan
    Info "WorkDir:   $WorkDir"
    Info "Manifest:  $ManifestPath"
    if ($DryRun) { Write-Host "DRY RUN - no system changes will be made" -ForegroundColor Yellow }

    if ($ScannerConfigOnly -or $PrinterConfigOnly) {
        $scan = [bool]$ScannerConfigOnly

        $Manifest = New-InstallManifest
        if ($scan) { Invoke-Step 'Scanner USB-OPOS' { Set-ScannerOpos } }
        else       { Invoke-Step 'Receipt printer OPOS' { Set-PrinterOpos } }

        if (-not $DryRun) {
            $changed = if ($scan) { @($Manifest.scannerConfigured | Where-Object { $_.result -in @('ok','already-opos') }) }
                       else       { @($Manifest.printerConfigured | Where-Object { $_.result -in @('ok','already-configured') }) }
            if (-not $changed) {
                if ($scan) { $script:ScannerConfigFailed = $true } else { $script:PrinterConfigFailed = $true }
            }
        }
        Save-Manifest
        $script:ManifestSaved = -not $script:ManifestWriteFailed
        # docs/ARCHITECTURE.md#what-folds-into-exit-1  (Clear-AccountSwapState runs pre-dispatch in EVERY mode)
        if ($script:ManifestWriteFailed -or $script:FinishFailed -or $script:StepFailed) { $exitCode = 1 }

        Step 'Done'
        Info "Manifest: $ManifestPath"
        Info "Log:      $RunLog"
    } elseif ($Uninstall) {
        $rc = Invoke-UninstallPhase
        # docs/ARCHITECTURE.md#what-folds-into-exit-1  (Clear-AccountSwapState runs pre-dispatch in EVERY mode)
        if ($rc -ne 0) { $exitCode = $rc }
        elseif ($script:FinishFailed -or $script:StepFailed) { $exitCode = 1 }
        Step 'Done'
    } else {
        Info "Downloads: $DownloadDir"
        Info "Logs:      $LogDir"

        $Manifest = New-InstallManifest

        # docs/ARCHITECTURE.md#why-the-two-prompts-are-at-step-0
        Invoke-Step 'Computer rename' { Invoke-ComputerRename }

        # docs/PRINTER-OPOS.md#skip-fallback  (-SkipPrinterConfig suppresses the prompt, so POS-X, never empty)
        $brand0 = if ($SkipPrinterConfig) { if ($PrinterBrand) { $PrinterBrand } else { 'POS-X' } }
                  else { Invoke-Step 'Printer brand' { Resolve-PrinterBrand } }
        if (-not $brand0) { $brand0 = 'POS-X'; Warn 'printer brand unresolved - using POS-X' }
        $script:PrinterBrandResolved = $brand0
        foreach ($b in $PrinterBrands.Keys) {
            if ($b -ne $brand0) { $SkipPrograms += $PrinterBrands[$b].RowName }
        }
        if ($brand0 -eq 'None') { Ok 'no receipt printer - no printer driver will be downloaded or installed' }
        else { Ok "receipt printer: $brand0 - other brands' drivers will not be downloaded or installed" }

        Invoke-Step 'Download phase' { Invoke-DownloadPhase }

        if (-not $SkipUninstallTeamViewer) { Invoke-Step 'TeamViewer removal' { Uninstall-TeamViewer } }

        Invoke-Step 'VC++ bootstrap' { Install-VcRedist | Out-Null }

        Invoke-Step 'Install loop' { Invoke-InstallLoop }

        Invoke-Step 'CoreScanner presence check' {
            if (-not $DryRun -and -not (Test-SkipMatch -Names @('Zebra Scanner SDK','Zebra Scanner SDK.exe'))) {
                if (Get-Service CoreScanner -ErrorAction SilentlyContinue) {
                    Ok 'Zebra CoreScanner service present'
                } else {
                    Warn 'Zebra CoreScanner service NOT present - the scanner may not function.'
                    Warn 'If the Scanner SDK fell back to the extracted MSI, re-run the installer: that fallback row no longer counts as installed, so the .iss path (which DOES install CoreScanner) runs again.'
                    $script:ScannerDegraded = $true
                }
            }
        }

        Invoke-Step 'Taskbar pins'    { Invoke-ChromeTaskbar }
        Invoke-Step 'Default browser' { Invoke-ChromeDefaultBrowser }
        Invoke-Step 'Chrome bookmark' { Invoke-ChromeBookmark }
        Invoke-Step 'Logon task'      { Register-FinishLogonTask }

        Invoke-Step 'Master list copy' {
            if (-not $SkipMasterList -and -not (Test-SkipMatch -Names @('Master List','Alleaves Nice Label Master List.nlbl'))) {
                $source = Join-Path $DownloadDir 'Alleaves Nice Label Master List.nlbl'
                Copy-MasterList -Source $source
            }
        }

        Invoke-Step 'Scanner USB-OPOS' { Set-ScannerOpos }

        Invoke-Step 'Receipt printer OPOS' { Set-PrinterOpos }

        # docs/ARCHITECTURE.md#tally-snapshot-ordering  (snapshot BEFORE Save-Manifest merges prior rows back in)
        $failed    = @($Manifest.installed    | Where-Object { $_.result -and ($_.result -notin @('ok','dryrun')) })
        $depFailed = @($Manifest.dependencies | Where-Object { $_.result -and ($_.result -notin @('ok','already-present','dryrun')) })
        $renamedTo = $Manifest.computerRenamed.to

        Save-Manifest
        $script:ManifestSaved = -not $script:ManifestWriteFailed

        if (-not $DryRun) {
            Get-ChildItem $LogDir -Filter '*.std*.log' -ErrorAction SilentlyContinue |
                Where-Object { $_.Length -eq 0 } |
                Remove-Item -Force -ErrorAction SilentlyContinue
        }

        if ($failed.Count -gt 0 -or $depFailed.Count -gt 0 -or $script:DownloadFailed -or $script:FinishFailed -or $script:StepFailed -or $script:ManifestWriteFailed) {
            $exitCode = 1
            Fail "$($failed.Count) install / $($depFailed.Count) dependency failure(s); download failure=$($script:DownloadFailed); finishing failure=$($script:FinishFailed); step failure=$($script:StepFailed); manifest write failure=$($script:ManifestWriteFailed)"
        }
        Step 'Done'
        Info "Manifest: $ManifestPath"
        Info "Log:      $RunLog"
        Info "To reverse: Install-Alleaves.bat -Uninstall"

        if ($script:RebootPending) {
            Warn '*** REBOOT REQUIRED before this terminal is ready.                    ***'
            if ($renamedTo) { Warn ("*** Computer will be renamed to '{0}' on reboot.{1}***" -f $renamedTo, (' ' * [Math]::Max(1, 21 - $renamedTo.Length))) }
            Warn '*** Reboot before using the Zebra scanner.                           ***'
        } else {
            Write-Host "  Recommended: reboot this terminal once to finalize Zebra CoreScanner." -ForegroundColor Yellow
        }
        if ($script:FinishBrowser -or $script:FinishTaskbar) {
            Info "  After the reboot, sign in: the deferred per-user changes are applied"
            Info "  automatically at logon (AlleavesAuto-FinishUser)."
            if ($script:FinishTaskbar) {
                Info "  Verify 'Alleaves Terminal' and 'Alleaves POS' are pinned and Edge is gone."
                Info "  The Alleaves POS pin should open $AlleavesUrl."
            }
            if ($script:FinishBrowser) {
                Info "  Verify an http link opens in Chrome."
            }
            Info "  Chrome should show an 'Alleaves' bookmark (policy, applied machine-wide)."
        }
    }

    # docs/ARCHITECTURE.md#the-non-fatal-block  (ONE copy, after the branch; gated on $exitCode -eq 0 so 1 is never masked)
    if (-not $Uninstall) {
        if ($script:ScannerDegraded -and $exitCode -eq 0) {
            $exitCode = 4
            Warn 'Scanner degraded (CoreScanner missing) - re-run the installer.'
        }
        if ($script:ScannerConfigFailed -and $exitCode -eq 0) {
            $exitCode = 6
            Warn 'Scanner present but USB-OPOS switch failed - re-run with the scanner attached (or -ScannerConfigOnly).'
            Show-ScannerBarcodeFallback
        }
        if ($script:PrinterConfigFailed -and $exitCode -eq 0) {
            $exitCode = 7
            Warn 'OPOS receipt printer registration failed - re-run (or use -PrinterConfigOnly).'
        }
    }
} catch {
    Fail "unhandled error (line $($_.InvocationInfo.ScriptLineNumber)): $($_.Exception.Message)"
    Fail "  at: $($_.InvocationInfo.Line.Trim())"
    $exitCode = 1
} finally {
    if (-not $Uninstall -and $Manifest -and -not $script:ManifestSaved) { try { Save-Manifest } catch { Write-Verbose "finally: last-resort Save-Manifest failed: $($_.Exception.Message)" } }
    try { Stop-Transcript | Out-Null } catch { Write-Verbose "finally: Stop-Transcript failed: $($_.Exception.Message)" }
}

exit $exitCode
