#requires -Version 5.1
<#
.SYNOPSIS
    Single-file Alleaves POS bootstrap: native-PowerShell Google Drive
    download + silent install + manifest-driven uninstall.

.DESCRIPTION
    Designed to be base64-embedded in Install-Alleaves.bat and dropped onto a
    stock Windows 10/11 terminal. No Python, no gdown, no shipped folder.

    Install order:
        Chrome -> Alleaves Terminal -> Zebra 123 Scan
        -> Zebra Scanner SDK -> POS for .NET -> NiceLabel
    plus NiceLabel master-list (.nlbl) copy and Splashtop SOS download.

    Working root: %ProgramData%\AlleavesAuto  (downloads\, logs\, manifest)
    so state survives a later -Uninstall (the .bat deletes the decoded .ps1).

    SINGLE ELEVATION OWNER = Install-Alleaves.bat. This script NEVER relaunches
    itself; it aborts if not admin (except -DryRun, which falls back to %TEMP%).

    ACCOUNT PRECHECK (exit 8): the terminal must be signed into a plain LOCAL
    account that is a local administrator. A Microsoft account, a domain / Entra
    ID account, an account whose type cannot be determined, or a standard user
    who elevated this run with someone else's credentials is refused before
    anything is downloaded.
    -Uninstall skips the check; -DryRun reports the verdict and continues.
    The block is OVERRIDABLE, never silently: -IgnoreAccountCheck, or a "y" at
    the continue-anyway prompt. Either way it is recorded in the manifest.

    ACCOUNT SWAP (exit 9): on a block, an interactive run OFFERS to fix it -
    promote the signed-in account, or create a new local admin with a one-shot
    autologon - then registers a logon task and reboots so the install resumes
    by itself. Decline it and you are asked whether to continue anyway; a "no"
    there (or a headless host, which reads as no) falls back to exit 8.

.PARAMETER Uninstall
    Reverse a prior install using the persisted manifest.

.PARAMETER DryRun
    Simulate everything; make no system changes. Allowed without admin.

.PARAMETER SkipMasterList
    Don't copy the NiceLabel master list to Documents.

.PARAMETER SkipUninstallTeamViewer
    Don't try to remove existing TeamViewer.

.PARAMETER SkipPrograms
    Regex fragments; matching programs are skipped (download + install).

.PARAMETER ForceReinstall
    Re-download even if a valid file exists; pre-clean installed products.

.PARAMETER ScannerConfigOnly
    Run ONLY the final USB-OPOS scanner step (no downloads, installs, or finishing).
    For iterating the OPOS switch on the rig, or configuring a scanner that was not
    attached during the main install. Mutually exclusive with -Uninstall.

.PARAMETER PrinterBrand
    Receipt printer brand: POS-X, StarTSP100, or None. Supplying it skips the interactive
    brand prompt. Only the chosen brand's driver is downloaded and installed. None = this
    terminal has no receipt printer: no printer driver is downloaded or installed, and the
    OPOS registration is skipped. Single word - see build-bat.ps1's arg double-wrapping.

.PARAMETER SkipPrinterConfig
    Don't register the OPOS receipt printer device entry.

.PARAMETER PrinterConfigOnly
    Run ONLY the OPOS receipt printer registration (no downloads, installs, or
    finishing). Use it to re-apply the entries, or to fix them after a rename. The chosen
    brand's driver must already be installed. Mutually exclusive with -Uninstall and
    -ScannerConfigOnly.

.PARAMETER NiceLabelLicense
    Activation ID (license key) fed to NiceLabel's silent install for unattended online
    activation. Supplying it alone lets the license server auto-populate the owner
    name/company/country/email, so by default ONLY LICENSECODE is sent.
    -SkipNiceLabelActivation falls back to plain /s.

.PARAMETER SkipNiceLabelActivation
    Install NiceLabel with plain /s (no license/activation params) - the license must
    then be entered manually on that site.

.PARAMETER ForceFingerprint
    Write the per-hop scanner fingerprint log even for a model already in
    $ScannerKnownModels. For rig capture - pair with -ScannerConfigOnly.

.PARAMETER IgnoreAccountCheck
    Run the account precheck and print its verdict, but do NOT block on a failure
    (no exit 8, no swap offer). The unattended/RMM half of the override; an
    interactive run can answer the continue-anyway prompt instead. Recorded in the
    manifest as accountCheckOverride either way.
#>

[CmdletBinding()]
param(
    [switch]$Uninstall,
    [switch]$DryRun,
    [switch]$SkipMasterList,
    [switch]$SkipUninstallTeamViewer,
    [string[]]$SkipPrograms = @(),
    [switch]$ForceReinstall,
    [switch]$ScannerConfigOnly,   # run ONLY the final USB-OPOS scanner step (no installs)
    [switch]$ForceFingerprint,    # dump the per-hop scanner fingerprint even for a known model
    # --- Per-terminal finishing (post-install additions) -------------------
    [string]$ComputerName,        # preset POS name/number (skips the rename prompt)
    [switch]$SkipRename,          # don't prompt/apply a computer rename
    [switch]$SkipChromeTaskbar,   # don't pin Alleaves/Chrome / remove Edge from the taskbar
    [switch]$SkipDefaultBrowser,  # don't make Chrome the default browser
    [switch]$SkipChromeBookmark,  # don't add the Alleaves bookmark to Chrome
    [switch]$SkipScannerConfig,   # don't flip the connected Zebra scanner(s) to USB-OPOS
    # --- Receipt printer (OPOS) --------------------------------------------
    # Single word, no spaces/apostrophes: build-bat.ps1 double-wraps args through cmd
    # %* and a PS single-quoted string on the non-elevated relaunch.
    [ValidateSet('POS-X','StarTSP100','None')]
    [string]$PrinterBrand,        # skip the brand prompt; None = no printer at all. Keys $PrinterBrands.
    [switch]$SkipPrinterConfig,   # don't register the OPOS receipt printer entry
    [switch]$PrinterConfigOnly,   # run ONLY the OPOS printer step (no downloads/installs)
    # --- NiceLabel unattended license activation ---------------------------
    [string]$NiceLabelLicense = 'FXQWA-6CPFD-ST4FB-TWTCZ-HMUMB',  # activation ID (server auto-fills the rest)
    [switch]$SkipNiceLabelActivation,    # install with plain /s (manual license entry)
    # --- Account precheck override ------------------------------------------
    # NOT -SkipAccountCheck: the check still runs and still prints its verdict -
    # only the exit-8 block is waived. Named for what it actually does.
    [switch]$IgnoreAccountCheck          # report the precheck verdict but don't block on it
)

$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------------------
# Console helpers (single copy; previously duplicated across the two scripts)
# ---------------------------------------------------------------------------
function Step($msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }
function Ok($msg)   { Write-Host "  [OK]   $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "  [WARN] $msg" -ForegroundColor Yellow }
function Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red }
function Dry($msg)  { Write-Host "  [DRY]  $msg" -ForegroundColor DarkGray }

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    ([Security.Principal.WindowsPrincipal]$id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

$IsAdmin = Test-IsAdmin

# ---------------------------------------------------------------------------
# Account precheck helpers (the blocker itself is below the elevation abort).
#
# "Is this process elevated?" is NOT the same question as "is this terminal
# signed into a local admin account", and two real failures live in the gap:
#   - a MICROSOFT ACCOUNT profile ties the cashier terminal to someone's
#     personal MSA (Store/sync, and OneDrive can redirect Documents - which is
#     exactly where the .nlbl master list is copied); it can't be handed over.
#   - a STANDARD USER can launch the .bat and type someone else's admin
#     credentials at UAC: the process is elevated, Test-IsAdmin passes, exit 3
#     never fires - but the profile that will actually run the POS is not an
#     administrator.
# So read the SIGNED-IN user, never the process token: on that second case the
# token is the wrong answer for exactly the thing being tested.
# ---------------------------------------------------------------------------
function Get-SignedInAccount {
    $name = $null
    try { $name = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).UserName } catch {}
    # Empty = no console session (RDP-only, service/RMM context): fall back to
    # the process token, which is at least a real account. This is the ONE place
    # the "never trust the token" rule is relaxed, so say so out loud - on a
    # terminal that does have a console user this line should never appear, and
    # if it does the verdict below was computed from the wrong account.
    if (-not $name) {
        try { $name = [Security.Principal.WindowsIdentity]::GetCurrent().Name } catch {}
        if ($name) { Warn "no console session - account precheck is reading the process token ($name)" }
    }
    if (-not $name) { return $null }
    $sid = $null
    try { $sid = ([Security.Principal.NTAccount]$name).Translate([Security.Principal.SecurityIdentifier]).Value } catch {}
    [pscustomobject]@{
        Name   = $name
        Sid    = $sid
        Domain = $(if ($name -like '*\*') { $name.Split('\')[0] } else { '' })
    }
}

# MSA-linked accounts still present as COMPUTERNAME\shortname, so the "is it
# local?" test does NOT catch them - only this does.
#
# TRI-STATE, and the third state is the whole point: returns the linked email
# (MSA), $null (PROVEN local), or 'unknown' (undetermined). An earlier version
# returned $null for both "proven local" and "every probe errored", and $null
# means "not MSA" to the caller - so an undetermined account PASSED, which is
# exactly backwards from the doctrine every other branch here follows. This is
# also the least-trusted branch in the function (see the TODO below), so it is
# the last one that should be failing open.
#
# PrincipalSource is the documented answer, so it is asked FIRST and believed in
# both directions; the registry cache is only consulted when it declines to
# answer ($null on some builds) or the cmdlet throws. A missing cache key cannot
# distinguish "absent because local" from "absent because this build does not
# populate it", so on that path the honest answer is 'unknown' -> block.
# TODO[rig]: confirm on a real MSA terminal that PrincipalSource answers, so the
# registry fallback stays the rare path rather than the usual one.
function Get-MicrosoftAccountId($sid) {
    if (-not $sid) { return 'unknown' }
    try {
        $ps = (Get-LocalUser -SID $sid -ErrorAction Stop).PrincipalSource
        if ($ps -eq 'Local') { return $null }
        if ($ps -eq 'MicrosoftAccount') {
            return (Get-MsaLinkedEmail $sid)
        }
        # AzureAD / MicrosoftEntraID here would already have been caught by the
        # domain + SID-shape tests; anything else is a build we do not know.
    } catch {}
    # IdentityStore cache: UserName under the account's own SID is the email.
    try {
        $ic = "HKLM:\SOFTWARE\Microsoft\IdentityStore\Cache\$sid\IdentityCache\$sid"
        $email = (Get-ItemProperty -Path $ic -Name UserName -ErrorAction Stop).UserName
        if ($email) { return $email }
    } catch {}
    return 'unknown'
}

# Best-effort linked email for an account already KNOWN to be MSA-backed. Only
# ever used to make the console message specific, never to decide the verdict.
function Get-MsaLinkedEmail($sid) {
    try {
        $ic = "HKLM:\SOFTWARE\Microsoft\IdentityStore\Cache\$sid\IdentityCache\$sid"
        $email = (Get-ItemProperty -Path $ic -Name UserName -ErrorAction Stop).UserName
        if ($email) { return $email }
    } catch {}
    return '(linked email unknown)'
}

# ponytail: direct members of BUILTIN\Administrators only - no nested-group
# expansion. An admin-via-nested-group therefore reads as not-admin, which is
# the safe direction on a POS terminal (block, don't wave through).
function Test-LocalAdminSid($sid, $name) {
    try {
        foreach ($m in (Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction Stop)) {
            if ($m.SID.Value -eq $sid) { return $true }
        }
        return $false
    } catch {
        # Get-LocalGroupMember throws on builds where the group holds an
        # orphaned SID; fall back to matching the name in the net output.
        # Resolve the group NAME from its well-known SID rather than hardcoding
        # "Administrators": on a non-English Windows (Administrateurs, Administradores)
        # the literal makes `net localgroup` error, the loop sees nothing, and a genuine
        # local-admin terminal is blocked with not-admin -> swap offer -> exit 8/9.
        $grp = try { (Get-LocalGroup -SID 'S-1-5-32-544' -ErrorAction Stop).Name } catch { 'Administrators' }
        $short = $name.Split('\')[-1]
        foreach ($line in (& net localgroup $grp 2>$null)) {
            $t = "$line".Trim()
            if ($t -eq $short -or $t -eq $name) { return $true }
        }
        return $false
    }
}

# Verdict: @{ Ok; Reason; Detail }. Every probe is guarded, and an UNDETERMINED
# result blocks - there is no bypass switch, so failing open would be the bypass.
function Test-InstallAccount {
    $a = Get-SignedInAccount
    if (-not $a) {
        return [pscustomobject]@{ Ok=$false; Reason='no-interactive-user'; Detail='no account resolved' }
    }
    # Well-known SERVICE SIDs, tested BEFORE the domain arm. Get-SignedInAccount falls back
    # to the process token when there is no console session, and under an RMM / service that
    # token is NT AUTHORITY\SYSTEM - which carries a backslash, so Domain 'NT AUTHORITY' is
    # not $env:COMPUTERNAME and the domain arm claimed the terminal was domain-joined. Right
    # block, wrong problem: the tech was handed "create a local admin account" for a run
    # whose only fault was having no console session. Everything below keeps its order
    # (domain/Entra still ahead of the SID-shape test - an Entra SID is S-1-12-1-*).
    if ($a.Sid -match '^S-1-5-(18|19|20)$') {
        return [pscustomobject]@{ Ok=$false; Reason='service-account'; Detail="$($a.Name) [$($a.Sid)]" }
    }
    # Checked before the SID shape: an Entra sign-in has an S-1-12-1-* SID and
    # would otherwise fall out as "no interactive user", which misleads the tech.
    if ($a.Domain -and $a.Domain -ne $env:COMPUTERNAME) {
        return [pscustomobject]@{ Ok=$false; Reason='not-local'; Detail=$a.Name }
    }
    # An Entra sign-in whose UserName carries no DOMAIN\ prefix skips the test
    # above and would fall into the generic SID-shape arm below - which blocks
    # correctly but names the wrong problem ("no interactive user"). Same
    # verdict, accurate message.
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
        # Sid rides along so the promote path can add THIS account to the
        # Administrators group by SID without re-resolving the name.
        return [pscustomobject]@{ Ok=$false; Reason='not-admin'; Detail=$a.Name; Sid=$a.Sid }
    }
    return [pscustomobject]@{ Ok=$true; Reason='ok'; Detail=$a.Name; Sid=$a.Sid }
}

# ===========================================================================
# ACCOUNT SWAP: create (or promote) a local admin account, arm a ONE-SHOT
# autologon, register a logon task that re-runs this installer with the same
# arguments, and reboot. The terminal comes back signed into the right account
# with the install resuming on its own.
#
# Everything here is SELF-CONTAINED on purpose. The precheck runs before
# $WorkDir, before $Manifest, and before Set-TrackedRegValue - PowerShell
# executes top-to-bottom, so none of those exist yet. Raw cmdlets only; the
# facts reach the manifest through the marker file, which the resumed run folds
# in (Clear-AccountSwapState -> $script:AccountSwapDone -> New-InstallManifest).
#
# WHY A ONE-SHOT AUTOLOGON AND NOT AN LSA SECRET: AutoLogonCount is Winlogon's
# native mechanism - it decrements the count and deletes AutoAdminLogon,
# DefaultPassword and AutoLogonCount ITSELF when it hits 0. The cost is that the
# password sits as plaintext DefaultPassword under a Winlogon key that Users can
# read, for one boot. The alternative (an LSA secret via P/Invoke, what
# Sysinternals Autologon does) is unreadable but has NO auto-clear: if the
# resume never runs, that terminal auto-logs-in as an administrator forever. On
# a POS terminal the self-clearing failure mode is the one to have. The resumed
# run ALSO restores the captured prior values explicitly, on top of that.
#
# The PROMOTE path arms no autologon at all: the tech already knows that
# account's password and types it at the logon screen, so no secret is handled.
# ===========================================================================
$WinlogonKey        = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
$AutoLogonValues    = @('AutoAdminLogon','DefaultUserName','DefaultDomainName','DefaultPassword','AutoLogonCount')
$AccountSwapDir     = Join-Path $env:ProgramData 'AlleavesAuto'
$AccountSwapMarker  = Join-Path $AccountSwapDir 'logs\account_swap.json'
$AccountSwapTask    = 'AlleavesAuto-Resume'
$script:AccountSwapAttempted = $false   # loop guard - set when a marker was found
$script:AccountSwapDone      = $null    # { name; sid; created } -> manifest, record only
$script:AccountCheckOverride = $null    # { account; reason; via } -> manifest, record only

function ConvertFrom-SecureStringPlain([Security.SecureString]$s) {
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
    try   { return [Runtime.InteropServices.Marshal]::PtrToStringUni($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

# Every prompt here is try/catch'd for the F14 reason the rename and printer-brand
# prompts are: Read-Host THROWS on a headless host, and an escaping throw would
# turn a clean "blocked, here is how to fix it" into a crash. UserInteractive is
# not a sufficient guard - powershell -NonInteractive still reports $true. On a
# throw (or an empty answer) the caller falls back to the printed remediation.
function Read-SwapAnswer($prompt) {
    try { return ("$(Read-Host $prompt)").Trim() } catch { return $null }
}

# Y/n with a default of NO: an unreadable or empty answer must never be taken as
# consent to create an account and reboot the terminal.
function Confirm-Swap($prompt) {
    $a = Read-SwapAnswer "$prompt [y/N]"
    return ($a -and $a -match '^(y|yes)$')
}

# The precheck override. It is deliberately NOT a silent fail-open: the full
# verdict and the manual remediation have already printed by the time either
# route gets here, and continuing is always an affirmative act (-IgnoreAccountCheck
# on the command line, or a "y" at a prompt that defaults to no).
#
# Recorded because the whole precheck runs BEFORE Start-Transcript - the console
# warning below lands in no log file, so the manifest is the only durable trace
# that a terminal was installed over a failed verdict. Record-only
# (removable=$false), same class as computerRenamed / scannerConfigured: there is
# nothing for -Uninstall to reverse.
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
        if ($null -eq $n) { return $null }                 # headless: give up
        if (-not $n) { $n = 'alleavespos' }
        if ($n -eq $env:COMPUTERNAME) { Fail "'$n' is the computer name - pick another."; continue }
        $exists = $false
        try { Get-LocalUser -Name $n -ErrorAction Stop | Out-Null; $exists = $true } catch {}
        if ($exists) { Fail "an account named '$n' already exists - pick another."; continue }
        return $n
    }
    return $null
}

# Returns @{ Secure; Plain } or $null. The plaintext is needed for
# DefaultPassword; it is never logged and never written anywhere else.
function Read-NewAccountPassword($name) {
    for ($i = 0; $i -lt 3; $i++) {
        try {
            $p1 = Read-Host "  Password for '$name'" -AsSecureString
            $p2 = Read-Host "  Confirm password"     -AsSecureString
        } catch { return $null }
        $t1 = ConvertFrom-SecureStringPlain $p1
        $t2 = ConvertFrom-SecureStringPlain $p2
        if (-not $t1)       { Fail 'password cannot be empty.'; continue }
        if ($t1 -ne $t2)    { Fail 'passwords did not match.';  continue }
        return @{ Secure = $p1; Plain = $t1 }
    }
    return $null
}

# Group membership is added by SID, never by the name 'Administrators' - that
# name is localized and the literal fails on a non-English Windows.
function Add-ToLocalAdmins($sid) {
    Add-LocalGroupMember -SID 'S-1-5-32-544' -Member $sid -ErrorAction Stop
}

# Capture the prior autologon state (value AND present/absent for each), then
# write ours. The captured state is what the resumed run replays, which is why
# autologon needs no manifest tracking at all: it is armed and fully undone
# inside one swap cycle. Recording it in the manifest would be actively wrong -
# a later -Uninstall would then "restore" autologon onto a live terminal.
# The capture lands in $script:AutoLogonPrior BEFORE the first write, so a throw
# partway through still leaves the caller's rollback able to put things back. A
# return value alone could not: the throw would skip it and the prior state - the
# only copy - would be gone with values already changed.
function Set-OneShotAutoLogon($name, $plainPassword) {
    $prior = @{}
    foreach ($v in $AutoLogonValues) {
        try {
            $cur = (Get-ItemProperty -Path $WinlogonKey -Name $v -ErrorAction Stop).$v
            # DefaultPassword is captured as PRESENT but its VALUE is deliberately dropped.
            # This whole hashtable is serialized into the account_swap.json marker under
            # %ProgramData%, whose inherited ACL grants BUILTIN\Users read - so a
            # pre-existing plaintext Winlogon password would land in a world-readable file.
            # The registry copy is a documented one-boot trade (Winlogon clears it itself);
            # a file copy has no such self-clear. Restore-AutoLogon removes the value
            # instead of writing it back - it is the one we KNOW we overwrote.
            $prior[$v] = @{ present = $true; value = $(if ($v -eq 'DefaultPassword') { $null } else { $cur }) }
        } catch { $prior[$v] = @{ present = $false; value = $null } }
    }
    $script:AutoLogonPrior = $prior
    New-ItemProperty -Path $WinlogonKey -Name 'AutoAdminLogon'    -Value '1'            -PropertyType String -Force -EA Stop | Out-Null
    New-ItemProperty -Path $WinlogonKey -Name 'DefaultUserName'   -Value $name          -PropertyType String -Force -EA Stop | Out-Null
    New-ItemProperty -Path $WinlogonKey -Name 'DefaultDomainName' -Value $env:COMPUTERNAME -PropertyType String -Force -EA Stop | Out-Null
    New-ItemProperty -Path $WinlogonKey -Name 'DefaultPassword'   -Value $plainPassword -PropertyType String -Force -EA Stop | Out-Null
    # The self-clearing half. Winlogon decrements this on each autologon and
    # deletes AutoAdminLogon/DefaultPassword/AutoLogonCount when it reaches 0.
    New-ItemProperty -Path $WinlogonKey -Name 'AutoLogonCount'    -Value 1              -PropertyType DWord  -Force -EA Stop | Out-Null
    # No return value on purpose: the caller reads $script:AutoLogonPrior, and
    # returning the hashtable here would dump it to the console.
}

# Returns the COUNT of values that could not be put back, or $null when there was
# nothing to restore. The caller needs both: nothing in here throws (every statement is
# individually caught), so an unconditional "restored" message was green even after a
# WARN, and on the promote path - which arms no autologon at all - it announced a
# restore that never happened.
function Restore-AutoLogon($prior) {
    if (-not $prior) { return $null }
    $failed = 0
    foreach ($v in $AutoLogonValues) {
        $p = $prior.$v
        try {
            # DefaultPassword is never written back: Set-OneShotAutoLogon deliberately keeps
            # no copy of it (see there), and it is the one value we know we overwrote, so
            # removing it IS the correct restore.
            if ($p -and $p.present -and $v -ne 'DefaultPassword') {
                $type = if ($v -eq 'AutoLogonCount') { 'DWord' } else { 'String' }
                New-ItemProperty -Path $WinlogonKey -Name $v -Value $p.value -PropertyType $type -Force -EA Stop | Out-Null
            } else {
                Remove-ItemProperty -Path $WinlogonKey -Name $v -Force -EA SilentlyContinue
                # -EA SilentlyContinue cannot tell "already absent" (normal) from "could not
                # delete", and a surviving DefaultPassword leaves cleartext in a key Users can
                # read - so the one that matters is verified by reading it back.
                if ($v -eq 'DefaultPassword' -and (Get-ItemProperty -Path $WinlogonKey -Name $v -EA SilentlyContinue)) {
                    throw 'the value is still present after the removal'
                }
            }
        } catch { Warn "could not restore Winlogon\$v : $($_.Exception.Message)"; $failed++ }
    }
    return $failed
}

# Re-serialize this run's arguments so the resumed run is the same run. Takes
# $PSBoundParameters explicitly - inside a function the automatic variable would
# be the FUNCTION's bound parameters, not the script's.
function ConvertTo-ResumeArgs($bound) {
    $q = { param($s) "'" + ("$s" -replace "'", "''") + "'" }
    $out = @()
    foreach ($k in $bound.Keys) {
        if ($k -eq 'DryRun') { continue }        # a dry run never arms anything
        $v = $bound[$k]
        if ($v -is [switch]) { if ($v.IsPresent) { $out += "-$k" } }
        elseif ($v -is [array]) {
            if ($v.Count) { $out += "-$k"; $out += (($v | ForEach-Object { & $q $_ }) -join ',') }
        }
        else { $out += "-$k"; $out += (& $q $v) }
    }
    return ($out -join ' ')
}

# Mirrors Register-FinishLogonTask, with two deliberate differences.
#   PRINCIPAL: the target user, Interactive, RunLevel Highest - NOT SYSTEM. A
#     SYSTEM task has no visible console, and step 0 is interactive (the rename
#     prompt and the printer-brand prompt). Those Read-Hosts are try/catch'd, so
#     under SYSTEM they would silently take defaults and the terminal would get
#     the wrong computer name and possibly the wrong printer driver. Highest
#     also means elevation with no UAC prompt, and Interactive needs no stored
#     credential (the task only runs once that user is logged on).
#   TIME LIMIT: zero (unlimited). The 5-minute limit the finish task uses would
#     kill a full install mid-run.
# The action targets a COPY of this script, because the .bat deletes its decoded
# temp copy on exit. Pointing the task at the .bat instead would mean teaching
# the .bat to pass its own path through - more moving parts, no gain.
function Register-ResumeTask($name, $scriptCopy, $argLine) {
    # -Command, NOT -File. ConvertTo-ResumeArgs emits PowerShell EXPRESSION syntax -
    # single-quoted values and comma-joined array literals - and -File does not evaluate
    # any of that: it hands each token through literally. So -SkipPrograms 'Star','NiceLabel'
    # arrived as one bogus element (the resumed run re-downloaded 471 MB the operator had
    # excluded) and -ComputerName 'POS 1' split on the space (wrong terminal name). Only
    # $scriptCopy needs escaping here; every value in $argLine is already single-quoted.
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

# Undo everything the arming wrote. Runs in EVERY mode (a stranded marker must
# be cleaned even under -Uninstall, which skips the precheck itself), and each
# step is guarded on its own: a task that will not unregister must not stop the
# autologon from being cleared, which is the one that matters.
function Clear-AccountSwapState {
    if (-not (Test-Path $AccountSwapMarker)) { return }
    $script:AccountSwapAttempted = $true
    Step 'Account swap: resuming (clearing one-shot state)'
    # -DryRun writes NOTHING (CLAUDE.md), and this function is the one place that broke
    # that. The .bat self-elevates, so a tech who armed a swap (exit 9) and then ran
    # -DryRun to re-check the verdict before rebooting had the dry run succeed at undoing
    # the arming: autologon restored, resume task unregistered, marker deleted. The box
    # rebooted into the old account with nothing left to finish the job.
    if ($DryRun) { Dry 'swap marker present - would clear autologon, remove the resume task and delete the marker'; return }
    $m = $null
    try { $m = Get-Content $AccountSwapMarker -Raw -EA Stop | ConvertFrom-Json -EA Stop } catch {
        Warn "account swap marker unreadable: $($_.Exception.Message)"
    }
    # OUTSIDE the if ($m). The task name is a constant and never needed the marker, but it
    # used to live inside - so a marker truncated by a power-off mid-write skipped the
    # unregister while line "Remove-Item $AccountSwapMarker" below still deleted the marker.
    # The resume task then relaunched the whole installer at EVERY logon of that user,
    # forever, and every later run early-returned above because the marker was gone.
    try {
        Unregister-ScheduledTask -TaskName $AccountSwapTask -Confirm:$false -EA Stop
        Ok "removed resume task '$AccountSwapTask'"
    } catch { Warn "could not remove resume task '$AccountSwapTask': $($_.Exception.Message)" }
    # Same treatment, same reason: the resume directory is a CONSTANT, so it never needed
    # the marker either. It used to be (Split-Path $m.scriptCopy -Parent) inside the if ($m),
    # which recursively deleted whatever the marker happened to name as the parent - for a
    # scriptCopy written into the working root that is the working root itself (manifest,
    # logs, downloads) - and an unreadable marker stranded a full copy of the installer
    # forever while the only pointer to it was deleted below.
    try { Remove-Item (Join-Path $AccountSwapDir 'resume') -Recurse -Force -EA SilentlyContinue } catch {}
    if ($m) {
        # Restore-AutoLogon never throws (every statement in it is individually caught), so
        # the old catch here was dead and the Ok printed green even after a WARN. $null back
        # means there was nothing to restore - the promote path arms no autologon at all, and
        # claiming otherwise was simply false.
        $restoreFailures = Restore-AutoLogon $m.winlogonPrior
        if ($null -ne $restoreFailures) {
            if ($restoreFailures -eq 0) { Ok 'autologon values restored to their pre-swap state' }
            else { Fail "$restoreFailures autologon value(s) could not be restored - check Winlogon by hand" }
        }
        # Held for the manifest; recorded only, never reversed (see below).
        $script:AccountSwapDone = @{ name=$m.account; sid=$m.sid; created=[bool]$m.created; removable=$false }
        Ok "resumed as '$($m.account)'"
    }
    Remove-Item $AccountSwapMarker -Force -EA SilentlyContinue
}

# The offer itself. Returns $true when the swap is armed (caller exits 9).
function Invoke-AccountSwapOffer($acct, $bound) {
    # not-admin means the account is already local and non-MSA (it got past both
    # of those arms), so promoting it in place is the smaller, safer fix: one
    # group add, no new profile, and no password ever handled.
    $promote = ($acct.Reason -eq 'not-admin' -and $acct.Sid)

    Write-Host ''
    if ($promote) {
        Write-Host "  This script can promote '$($acct.Detail)' to local administrator and" -ForegroundColor Cyan
        Write-Host '  reboot; the install then resumes automatically once you sign back in.' -ForegroundColor Cyan
        if (-not (Confirm-Swap "  Promote '$($acct.Detail)' and reboot to resume?")) { return $false }
    } else {
        Write-Host '  This script can create a local administrator account, sign the terminal' -ForegroundColor Cyan
        Write-Host '  into it automatically on the next boot, and resume the install there.' -ForegroundColor Cyan
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

    # First write of the run. Consent above is what authorizes it - the precheck
    # deliberately writes nothing to a box it is about to turn away.
    $resumeDir  = Join-Path $AccountSwapDir 'resume'
    $scriptCopy = Join-Path $resumeDir 'alleaves_setup.ps1'
    try {
        New-Item -ItemType Directory -Force -Path $resumeDir -EA Stop | Out-Null
        New-Item -ItemType Directory -Force -Path (Split-Path $AccountSwapMarker -Parent) -EA Stop | Out-Null
        Copy-Item -LiteralPath $PSCommandPath -Destination $scriptCopy -Force -EA Stop
    } catch { Fail "could not stage the resume script: $($_.Exception.Message)"; return $false }

    # Unwind the swap MACHINERY on any failure from here on - a half-armed swap is
    # worse than no swap, and every piece of it is ours and seconds old (a
    # just-created account has no profile yet, so removing it strands nothing).
    # Defined BEFORE the first destructive step, not after the last one, so the
    # early failures are covered too; it reads $created / $sid / AutoLogonPrior at
    # invoke time, so it always unwinds exactly what got as far as happening. A
    # promotion is deliberately NOT unwound: that is the fix the tech asked for and
    # it stands on its own; only the resume plumbing failed.
    $script:AutoLogonPrior = $null
    $rollback = {
        # $null = : Restore-AutoLogon returns a failure COUNT, and every caller of this
        # scriptblock is "& $rollback; return $false". A bare call would put that int in
        # the function's output next to $false, so `if (Invoke-AccountSwapOffer ...)` at
        # the dispatch would test a 2-element array - always truthy - and a swap that
        # FAILED to arm would exit 9, rebooting a terminal with nothing set up to resume.
        $null = Restore-AutoLogon $script:AutoLogonPrior
        try { Unregister-ScheduledTask -TaskName $AccountSwapTask -Confirm:$false -EA SilentlyContinue } catch {}
        if ($created) {
            try { Remove-LocalUser -SID $sid -EA Stop; Warn "rolled back: removed '$name'" }
            catch { Warn "could not remove '$name' after the failed swap: $($_.Exception.Message)" }
        }
        try { Remove-Item $resumeDir -Recurse -Force -EA SilentlyContinue } catch {}
    }

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
        # Already-a-member is fine; anything else is fatal to the swap.
        if ("$($_.Exception.Message)" -notmatch 'already a member') {
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

    # The marker is written LAST and its failure is FATAL to the swap. It is the
    # only record that lets the resumed run clear the autologon, unregister the
    # task and record the account - without it that task re-runs the installer at
    # EVERY logon of this user, forever, with nothing left to turn it off.
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

    Write-Host ''
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

# ---------------------------------------------------------------------------
# Mode echo + ambiguity guard (Advisor #1B/#3 - destructive if wrong)
# Make the parsed mode unambiguous BEFORE any dispatch, and refuse to run an
# INSTALL when the launcher actually asked for an UNINSTALL (dropped switch).
# ---------------------------------------------------------------------------
$Mode = if ($Uninstall) { 'Uninstall' } elseif ($ScannerConfigOnly) { 'ScannerConfig' } elseif ($PrinterConfigOnly) { 'PrinterConfig' } else { 'Install' }
Write-Host "Alleaves setup - parsed MODE: $Mode" -ForegroundColor Cyan
Write-Host ("  Args: Uninstall={0} DryRun={1} SkipMasterList={2} SkipUninstallTeamViewer={3} ForceReinstall={4} ScannerConfigOnly={5} ForceFingerprint={6} SkipPrograms='{7}'" -f `
    $Uninstall, $DryRun, $SkipMasterList, $SkipUninstallTeamViewer, $ForceReinstall, $ScannerConfigOnly, $ForceFingerprint, ($SkipPrograms -join ','))
Write-Host ("        ComputerName='{0}' SkipRename={1} SkipChromeTaskbar={2} SkipDefaultBrowser={3} SkipChromeBookmark={4} SkipScannerConfig={5}" -f `
    $ComputerName, $SkipRename, $SkipChromeTaskbar, $SkipDefaultBrowser, $SkipChromeBookmark, $SkipScannerConfig)
Write-Host ("        PrinterBrand='{0}' SkipPrinterConfig={1} PrinterConfigOnly={2} IgnoreAccountCheck={3}" -f `
    $PrinterBrand, $SkipPrinterConfig, $PrinterConfigOnly, $IgnoreAccountCheck)

$requested = $env:ALLEAVES_REQUESTED_MODE
if ($requested) {
    Write-Host "  Launcher requested mode: $requested"
    if ($requested -eq 'uninstall' -and -not $Uninstall) {
        Fail "Launcher requested UNINSTALL but -Uninstall did not survive. Refusing to run INSTALL."
        exit 2
    }
    if ($requested -eq 'install' -and $Uninstall) {
        Fail "Launcher requested INSTALL but script parsed UNINSTALL. Aborting ambiguous run."
        exit 2
    }
}

# -ScannerConfigOnly is a sub-mode of install (the .bat reports requested mode
# 'install'); it must never combine with -Uninstall (one reverses, the other
# configures - ambiguous, exit 2 like the guards above).
if ($ScannerConfigOnly -and $Uninstall) {
    Fail "-ScannerConfigOnly and -Uninstall are mutually exclusive."
    exit 2
}
# ...and not with -SkipScannerConfig either: "run ONLY the scanner step" + "skip the
# scanner step" is a run that does nothing and exits 0, which reads as success to RMM.
# (Same contradiction the -PrinterConfigOnly / -SkipPrinterConfig guard below rejects.)
if ($ScannerConfigOnly -and $SkipScannerConfig) {
    Fail "-ScannerConfigOnly and -SkipScannerConfig are mutually exclusive (that run would do nothing)."
    exit 2
}

# -PrinterConfigOnly is the same shape of sub-mode: it must not combine with
# -Uninstall, nor with -ScannerConfigOnly (two different "run only this one step"
# requests in one invocation is ambiguous - exit 2 like the guards above).
if ($PrinterConfigOnly -and ($Uninstall -or $ScannerConfigOnly)) {
    Fail "-PrinterConfigOnly cannot be combined with -Uninstall or -ScannerConfigOnly."
    exit 2
}
# ...and not with -SkipPrinterConfig either: "run ONLY the printer step" + "skip the printer
# step" is a run that does nothing and exits 0, which reads as success to RMM.
if ($PrinterConfigOnly -and $SkipPrinterConfig) {
    Fail "-PrinterConfigOnly and -SkipPrinterConfig are mutually exclusive (that run would do nothing)."
    exit 2
}
# -PrinterBrand None is the same contradiction said a different way. (Answering None at the
# PROMPT under -PrinterConfigOnly needs no guard: the "registered nothing" check in that
# branch already turns it into exit 7.)
if ($PrinterConfigOnly -and $PrinterBrand -eq 'None') {
    Fail "-PrinterConfigOnly and -PrinterBrand None are mutually exclusive (that run would do nothing)."
    exit 2
}
# Invoke-ComputerRename returns on -SkipRename before it ever looks at -ComputerName, so
# this pair silently dropped the name AND left the OPOS logical device names built from the
# old one - a terminal Alleaves cannot open, discovered at the till.
if ($ComputerName -and $SkipRename) {
    Fail "-ComputerName and -SkipRename are mutually exclusive (the name would be ignored)."
    exit 2
}
# Same shape: the license is silently dropped and NiceLabel installs unlicensed. Tested on
# ContainsKey, NOT on the variable - -NiceLabelLicense has a non-empty DEFAULT in param(),
# so a plain -SkipNiceLabelActivation would otherwise exit 2 for everyone.
if ($PSBoundParameters.ContainsKey('NiceLabelLicense') -and $SkipNiceLabelActivation) {
    Fail "-NiceLabelLicense and -SkipNiceLabelActivation are mutually exclusive (the license would be ignored)."
    exit 2
}

# ---------------------------------------------------------------------------
# Single-elevation-owner rule: the .bat elevates once; this script must NOT
# relaunch. Abort cleanly if not admin (DryRun is allowed non-elevated).
# ---------------------------------------------------------------------------
if (-not $IsAdmin -and -not $DryRun) {
    Fail "Not elevated. This script must be launched by Install-Alleaves.bat (single elevation owner)."
    Fail "Run the .bat (one UAC prompt), or pass -DryRun for a non-elevated plumbing test."
    exit 3
}

# ---------------------------------------------------------------------------
# Account precheck (blocker) - see Test-InstallAccount for WHY elevation alone
# is not enough. The terminal must be signed into a plain LOCAL account that is
# a local administrator. Runs before the working dir is created: nothing gets
# written on a box that is about to be turned away.
#   -Uninstall skips it. A blocker there would strand a terminal that later
#     acquired an MSA with no way to run the manifest-driven removal.
#   -DryRun reports and continues. It writes nothing, so it is the diagnostic
#     that gives the tech the verdict BEFORE touching the terminal - not a
#     bypass. The config-only sub-modes DO get the check; they mutate state.
# Console-only (Start-Transcript lives inside the dispatch branches), same as
# the exit 2 / 3 / 5 aborts above.
# ---------------------------------------------------------------------------
# Runs in EVERY mode, before the verdict below is acted on: a stranded marker
# must be cleaned even under -Uninstall, which skips the precheck itself. It also
# sets the loop guard, so a resume that lands on a still-wrong account gets the
# printed remediation instead of a second swap.
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
        Write-Host ''
        if ($acct.Reason -eq 'service-account') {
            # Nothing about the ACCOUNT is broken here, so the create-an-admin steps below
            # would send the tech to fix something that isn't wrong.
            Write-Host "  Fix it - run this from the terminal's own signed-in session:" -ForegroundColor Yellow
            Write-Host "    1. Sign into the terminal as its local administrator account"
            Write-Host '    2. Run Install-Alleaves.bat from that session'
            Write-Host '    An RMM running as SYSTEM cannot answer this check - dispatch it to the'
            Write-Host '    logged-on user instead, or run it by hand.'
        }
        elseif ($acct.Reason -eq 'not-admin') {
            Write-Host '  Fix it - promote the signed-in account:' -ForegroundColor Yellow
            Write-Host '    1. Settings > Accounts > Other users > (the account) > Change account type'
            Write-Host '    2. Account type = Administrator'
            Write-Host '    3. Sign out and back in, then re-run Install-Alleaves.bat'
            Write-Host "    CLI:  net localgroup Administrators `"$($acct.Detail.Split('\')[-1])`" /add"
        } else {
            Write-Host '  Fix it - create a local administrator account and sign into it:' -ForegroundColor Yellow
            Write-Host '    1. Settings > Accounts > Other users > Add account'
            Write-Host "    2. Choose 'I don't have this person's sign-in information'"
            Write-Host "    3. Choose 'Add a user without a Microsoft account', set a name + password"
            Write-Host '    4. Change account type > Administrator'
            Write-Host '    5. Sign into that account, then re-run Install-Alleaves.bat'
            Write-Host '    CLI:  net user <name> <password> /add'
            Write-Host '          net localgroup Administrators <name> /add'
        }
        Write-Host ''
        # The manual remediation above always prints - it is the fallback for a
        # headless host, a declined offer, and the resumed-but-still-wrong case.
        #
        # Every route out of here that is NOT exit 8 is an explicit operator
        # decision, recorded by Set-AccountCheckOverride. Note the ordering:
        # -IgnoreAccountCheck is tested FIRST so an unattended / RMM run never
        # reaches a Read-Host, and so -DryRun -IgnoreAccountCheck reports what the
        # real run would do (continue) rather than an offer it would never make.
        $continueMsg = '  Continue the install anyway on this account (NOT recommended)?'
        if ($IgnoreAccountCheck) {
            Set-AccountCheckOverride $acct 'IgnoreAccountCheck'
        }
        elseif ($DryRun) {
            $wouldPromote = ($acct.Reason -eq 'not-admin' -and $acct.Sid)
            Dry $(if ($wouldPromote) { "would offer to promote '$($acct.Detail)' and reboot to resume" }
                  else                { 'would offer to create a local admin account, arm a one-shot autologon, and reboot to resume' })
            Dry 'would then offer to continue anyway; declining both blocks a real run (exit 8)'
            Dry 'account precheck would block a real run (exit 8) - continuing, -DryRun changes nothing'
        }
        elseif ($script:AccountSwapAttempted) {
            # Loop guard. Without it a resume that lands on a still-wrong account
            # offers another account, arms autologon again, and reboots - forever.
            # The override IS still offered here: a resume stranded on the wrong
            # account is exactly the case with no other way forward, and it is a
            # prompt, not a second reboot, so it cannot loop.
            Fail 'an account swap was already attempted this cycle; not offering another.'
            if (Confirm-Swap $continueMsg) { Set-AccountCheckOverride $acct 'prompt' }
            else { exit 8 }
        }
        elseif (Invoke-AccountSwapOffer $acct $PSBoundParameters) {
            exit 9      # armed; the terminal reboots and resumes on its own
        }
        # Declined the swap (or it failed and rolled itself back) - last chance.
        # Confirm-Swap defaults to NO and its Read-Host is try/catch'd, so a
        # headless host reads as "no" and still lands on exit 8.
        elseif (Confirm-Swap $continueMsg) { Set-AccountCheckOverride $acct 'prompt' }
        else { exit 8 }
    }
}

# ---------------------------------------------------------------------------
# Working directory (machine-wide so state survives for -Uninstall)
# ---------------------------------------------------------------------------
# Not caller-overridable: a deep path overflows the IS5 stub's fixed command-line
# buffer (see the OLE POS Setup row), and nothing ever set it.
$WorkDir = if ($IsAdmin) { Join-Path $env:ProgramData 'AlleavesAuto' } else { Join-Path $env:TEMP 'AlleavesAuto' }   # non-admin = -DryRun fallback
$DownloadDir  = Join-Path $WorkDir 'downloads'
$LogDir       = Join-Path $WorkDir 'logs'
$ManifestPath = Join-Path $LogDir  'install_manifest.json'
# F24: create the working dirs with a hard stop + write-probe so a failed mkdir
# (permissions / locked path) fails fast with a distinct code (5) instead of
# crashing Start-Transcript opaquely later. Code 5 is distinct from F20's exit 4.
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
$script:RebootPending   = $false   # set if VC++ redist returns 3010, or a rename is queued
$script:FinishBrowser   = $false   # taskbar/browser features set these; if either is
$script:FinishTaskbar   = $false   # true, a per-user logon task is registered to finish.
$script:TaskbarStamp    = ''       # the pin list the logon task marks as applied (see Invoke-ChromeTaskbar)
$script:ScannerDegraded = $false   # F20: set if CoreScanner is missing post-install (exit 4)
# Post-install finishing steps (master list, taskbar, bookmark, default browser, the
# logon task) report through Fail/Warn only - none of them writes an $Manifest.installed
# row, so the exit tally could not see them and a run that placed no .nlbl and registered
# no logon task still exited 0. Folds into exit 1, like a failed download; NOT a new code.
$script:FinishFailed    = $false
$script:ScannerConfigFailed = $false   # set if a connected scanner is present but the OPOS switch fails (exit 6)
$script:PrinterConfigFailed = $false   # set if the OPOS printer device entry fails to write (exit 7)
$script:PrinterBrandResolved = $null   # brand answered ONCE up front (see Resolve-PrinterBrand)
# Set if Save-Manifest could not write install_manifest.json (disk full, AV holding the
# file). It used to Fail on the console and exit 0 - the one failure path in the dispatch
# tail that could not reach a non-zero code - while UCPD Start=4, the AlleavesAuto-FinishUser
# task, the OPOS device keys and every placed file now had NO record at all, making a later
# -Uninstall permanently a no-op. Folds into exit 1, like $script:FinishFailed.
$script:ManifestWriteFailed = $false
$script:UserAgent       = 'Mozilla/5.0 AlleavesAuto/1.0'   # F3: one UA for BITS + WebClient + HEAD/GET probe

# The Alleaves web POS: Chrome's start page, home button and bookmark all point here.
$AlleavesUrl = 'https://app.alleaves.com'

# ---------------------------------------------------------------------------
# Registry uninstall lookup (single copy)
# ---------------------------------------------------------------------------
$UninstallHives = @(
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
)

function Find-InstalledProducts {
    param([Parameter(Mandatory)][string]$Pattern)
    foreach ($h in $UninstallHives) {
        Get-ItemProperty $h -ErrorAction SilentlyContinue |
            Where-Object {
                $_.DisplayName -and $_.DisplayName -match $Pattern -and
                # Skip the InstallShield_{GUID} duplicate ARP entries that the
                # Zebra InstallScript installs create alongside the REAL MSI
                # product entry: they share the DisplayName but their
                # UninstallString is an INTERACTIVE "setup.exe ... -removeonly".
                # The real MSI entry (MsiExec /X{GUID}) removes the product
                # silently; the orphaned InstallShield_ key is cleaned up
                # separately (Remove-InstallShieldOrphans).
                ($_.PSChildName -notlike 'InstallShield_*')
            }
    }
}

function Invoke-SilentUninstall {
    param([string]$DisplayName, [string]$UninstallString, [string]$QuietUninstallString, [string]$ProductCode)
    $UninstallTimeoutMs = 360000   # kill-timeout backstop for a /S-ignoring uninstaller; fixed (no caller varies it)
    $cmd = if ($QuietUninstallString) { $QuietUninstallString } else { $UninstallString }
    # NiceLabel is an InstallShield SUITE whose uninstall fights the unattended
    # flow, so it gets a dedicated handler here (never the generic bootstrapper
    # path). The Suite registers TWO ARP entries, BOTH pointing at its bootstrapper
    # (C:\ProgramData\{...}\NiceLabel2019.exe): one keyed by the MSI ProductCode
    # GUID, one by a plain name ("NiceLabel 2019"). The bootstrapper IGNORES /silent
    # and pops a confirm dialog -> the unattended uninstall hangs. We bypass it with
    # msiexec /x <ProductCode>, which silently removes the product files. BUT the
    # bootstrapper is also what removes the Suite's ARP keys, its services, its
    # low-level Installer registration, and its ProgramData cache - msiexec leaves
    # ALL of those behind (verified). So we sweep them explicitly, or -Uninstall
    # leaves running services + a stale product registration behind. Resolve the
    # GUID from this entry, else its GUID-keyed sibling; once a sibling removes the
    # product, later entries find no GUID and just clean up their own leftovers.
    if ($cmd -match '(?i)NiceLabel\d*\.exe') {
        if ($DryRun) { Dry "would remove NiceLabel via msiexec /x + Suite residue cleanup: $DisplayName ($ProductCode)"; return $true }
        # Capture this entry's install dir from its ARP record NOW (msiexec /x clears
        # the registration but leaves the ~900 MB of Suite-installed files on disk,
        # so we delete that directory ourselves afterward). Sourced from the ARP
        # InstallLocation - no hardcoded path.
        $nlDir = $null
        foreach ($h in $UninstallHives) {
            $rec = Get-ItemProperty $h -ErrorAction SilentlyContinue |
                Where-Object { $_.PSChildName -eq $ProductCode -and $_.DisplayName -match '(?i)NiceLabel' -and $_.InstallLocation } |
                Select-Object -First 1
            if ($rec) { $nlDir = $rec.InstallLocation; break }
        }
        # Stop the Suite services first - running services pin files, so msiexec
        # would defer removal to a reboot and leave the registration behind.
        Get-Service -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like 'NiceLabel*' -and $_.Status -ne 'Stopped' } |
            ForEach-Object { Stop-Service $_.Name -Force -ErrorAction SilentlyContinue }
        $guid = if ($ProductCode -match '^\{[0-9A-Fa-f-]+\}$') { $ProductCode } else {
            $sib = $null
            foreach ($h in $UninstallHives) {
                $sib = Get-ItemProperty $h -ErrorAction SilentlyContinue |
                    Where-Object { $_.PSChildName -match '^\{[0-9A-Fa-f-]+\}$' -and $_.DisplayName -match '(?i)NiceLabel' } |
                    Select-Object -First 1
                if ($sib) { break }
            }
            if ($sib) { $sib.PSChildName } else { $null }
        }
        $nlOk = $true   # F13: a hard msiexec failure must NOT be swallowed into a success
        if ($guid) {
            Write-Host "  NiceLabel: msiexec.exe /x $guid /qn /norestart (Suite MSI)"
            $mp = Start-Process msiexec.exe -ArgumentList "/x $guid /qn /norestart" -Wait -PassThru -WindowStyle Hidden
            # 1605 = "product not installed" (a sibling entry removed it first) = fine.
            $nlOk = ($mp.ExitCode -in @(0,3010,1641,1605))
            if (-not $nlOk) { Warn "NiceLabel msiexec /x $guid exited $($mp.ExitCode)" }
        }
        # Delete this entry's leftover Suite ARP orphan key (msiexec never does).
        $removedKey = $false
        foreach ($h in $UninstallHives) {
            Get-ItemProperty $h -ErrorAction SilentlyContinue |
                Where-Object { $_.PSChildName -eq $ProductCode -and $_.DisplayName -match '(?i)NiceLabel' } |
                ForEach-Object {
                    try { Remove-Item $_.PSPath -Recurse -Force -ErrorAction Stop; $removedKey = $true }
                    catch { Warn "could not remove NiceLabel Suite ARP $($_.PSChildName): $($_.Exception.Message)" }
                }
        }
        # Sweep the Suite residue msiexec leaves behind (the bootstrapper's job):
        # its services, its low-level Installer registration, its ProgramData cache.
        Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'NiceLabel*' } |
            ForEach-Object { & "$env:SystemRoot\System32\sc.exe" delete $_.Name 2>$null | Out-Null; Write-Host "  removed NiceLabel service: $($_.Name)" }
        # The low-level registration keys are named by a packed GUID; find them by
        # PRODUCT NAME instead of deriving it (no GUID needed, so this runs on both
        # paths). Features subkeys carry no ProductName, so they are matched by the
        # key name of the Products hit; UserData keeps the name one level down.
        foreach ($p in @(Get-ChildItem 'HKLM:\SOFTWARE\Classes\Installer\Products' -ErrorAction SilentlyContinue |
                         Where-Object { (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).ProductName -match '(?i)NiceLabel' })) {
            Remove-Item "HKLM:\SOFTWARE\Classes\Installer\Features\$($p.PSChildName)" -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item $p.PSPath -Recurse -Force -ErrorAction SilentlyContinue
        }
        Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products' -ErrorAction SilentlyContinue |
            Where-Object { (Get-ItemProperty "$($_.PSPath)\InstallProperties" -ErrorAction SilentlyContinue).DisplayName -match '(?i)NiceLabel' } |
            ForEach-Object { Remove-Item $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue }
        # The bootstrapper's cache path is embedded in the uninstall command.
        if ($cmd -match '([A-Za-z]:\\ProgramData\\\{[0-9A-Fa-f-]+\})') {
            if (Test-Path $Matches[1]) { Remove-Item $Matches[1] -Recurse -Force -ErrorAction SilentlyContinue }
        }
        # Delete the Suite-installed app files msiexec leaves behind. Guarded by a
        # NiceLabel-in-path check + Test-Path so we never touch an unexpected dir.
        if ($nlDir -and $nlDir -match '(?i)NiceLabel' -and (Test-Path $nlDir)) {
            try { Remove-Item $nlDir -Recurse -Force -ErrorAction Stop; Write-Host "  removed NiceLabel program files: $nlDir" }
            catch { Warn "could not fully remove NiceLabel program files ${nlDir}: $($_.Exception.Message)" }
        }
        # F13: report success authoritatively, not unconditionally (the old code
        # only Warned on a bad msiexec exit and a $null GUID skipped removal entirely,
        # yet still returned $true - so a ~900 MB Suite that survived was reported [OK],
        # and with F12 that exits 0). Authority differs by path:
        #  * GUID path: msiexec's exit code says whether the product was removed. The
        #    Suite's SECOND (name-keyed) bootstrapper ARP entry legitimately lingers
        #    until its OWN pass, so a registry re-scan here would false-fail the first
        #    of the two passes a normal NiceLabel uninstall makes.
        #  * No-GUID path: this pass removed no product (msiexec was skipped), so the
        #    registry is authoritative - if any NiceLabel entry survived, it's a real
        #    failure (and a legit sibling-already-removed pass has cleared its own ARP
        #    key just above, so the re-scan correctly finds nothing).
        if ($guid) {
            if (-not $nlOk) { Fail "NiceLabel not removed (msiexec exit $($mp.ExitCode)): $DisplayName"; return $false }
        } else {
            $stillThere = [bool](Find-InstalledProducts -Pattern '(?i)NiceLabel')
            if ($stillThere) { Fail "NiceLabel not fully removed (no product GUID resolved; still in registry): $DisplayName"; return $false }
        }
        Ok "removed NiceLabel: $DisplayName$(if ($removedKey) { ' (+ Suite residue)' } else { '' })"
        return $true
    }
    if (-not $cmd) { Warn "no uninstall command for $DisplayName"; return $false }
    # 1605 = "this action is only valid for products that are currently installed" = fine,
    # same reason the NiceLabel branch above accepts it: a sibling ARP entry already removed
    # the product. Find-InstalledProducts snapshots BOTH entries of a broad displayNameMatch
    # ('Zebra Scanner SDK|Zebra CoreScanner'), and removing the SDK chain also removes
    # CoreScanner - so the second pass ran a stale UninstallString, returned $false, and made
    # -Uninstall exit 1 on a terminal that was actually clean. Every time.
    $okCodes = @(0, 3010, 1641, 1605)   # success exit codes; widened per-installer below
    if ($DryRun) { Dry "would uninstall: $cmd"; return $true }
    Write-Host "  $DisplayName"
    Write-Host "    cmd: $cmd"
    try {
        if ($cmd -match '(?i)msiexec') {
            # ANCHORED, and it eats everything up to and including the exe name. The old
            # unanchored form only removed the word: an ARP UninstallString that carries a
            # path - "C:\WINDOWS\system32\MsiExec.exe /I{GUID}", which is the common shape -
            # became "C:\WINDOWS\system32\/X{GUID}", which msiexec reads as a package path
            # and rejects with 1619. The product could then never be uninstalled or
            # pre-cleaned, on every run. The optional trailing quote handles the quoted form.
            $argstr = ($cmd -replace '(?i)^.*?msiexec(\.exe)?"?\s*','').Trim()
            $argstr = $argstr -replace '(?i)/I\{','/X{' -replace '(?i)/I ','/X '
            if ($argstr -notmatch '/qn|/quiet') { $argstr += ' /qn /norestart' }
            $p = Start-Process -FilePath 'msiexec.exe' -ArgumentList $argstr -Wait -PassThru -WindowStyle Hidden
        } else {
            # Split on the .exe boundary, not on the first space: an UNQUOTED ARP string
            # ("C:\Program Files\Vendor\uninst.exe /S" - common on older InstallScript/NSIS
            # products) used to yield $exe='C:\Program', which Start-Process -Stop threw on,
            # and the catch reported a bare "uninstall failed" with no hint the path was
            # mangled -> $uninstallFailures++ -> exit 1. The optional quotes cover the quoted
            # shape too; the first-space split stays as the fallback for a non-.exe command.
            if ($cmd -match '(?i)^\s*"?(.*?\.exe)"?\s*(.*)$') { $exe=$Matches[1]; $rest=$Matches[2] }
            elseif ($cmd -match '^"([^"]+)"\s*(.*)$') { $exe=$Matches[1]; $rest=$Matches[2] }
            else { $parts = $cmd -split ' ',2; $exe=$parts[0]; $rest = if($parts.Length -gt 1){$parts[1]}else{''} }
            # A blanket "/S" is WRONG (and hangs the unattended uninstall) for two
            # products we actually ship. Pick the silent flag per installer family:
            if ($exe -match '(?i)\\Google\\Chrome\\' -or $rest -match '(?i)(^|\s)--uninstall(\s|$)') {
                # Chrome's setup.exe ignores /S; without --force-uninstall it pops a
                # confirmation dialog that blocks the unattended uninstall forever.
                # (Level flags like --system-level are already in the ARP string.)
                if ($rest -notmatch '(?i)--force-uninstall') { $rest = ($rest + ' --force-uninstall').Trim() }
                # Chrome's installer (InstallStatus enum, util_constants.h) reports
                # success as 19 (UNINSTALL_SUCCESSFUL) or 29 (UNINSTALL_REQUIRES_REBOOT),
                # NOT 0 - accept those. 20 = UNINSTALL_FAILED is deliberately NOT
                # accepted (treating it as success masks a failed uninstall). 3010/1641
                # are MSI codes Chrome's setup.exe never emits.
                $okCodes = @(0, 19, 29)
            # NiceLabel is fully handled by the dedicated handler near the top of
            # Invoke-SilentUninstall (the "if ($cmd -match '(?i)NiceLabel\d*\.exe')"
            # block), which returns first - so no NiceLabel branch is needed here.
            } elseif ($exe -match '(?i)\\(IsUninst|_isdel)\.exe$') {
                # InstallShield 5.x (pure InstallScript, e.g. POS-X "OLE POS Setup 2.84").
                # Its ARP string is  C:\WINDOWS\IsUninst.exe -f"<...>\Uninst.isu"  - note
                # the giveaway ("IsUninst") is in the EXE PATH, not the argument tail, so
                # the $rest-only test below never matches it. Without this branch it falls
                # through to the generic /S, which IS5 does not understand, and hangs to
                # the $UninstallTimeoutMs cap.
                #   -a silent, -y no confirm, -f"<.isu>" (already in $rest).
                # PREPEND so the existing -f"..." and any -c"<dll>" survive verbatim.
                # The .isu filename is machine-dependent (Uninst.isu here, DeIsL#.isu on
                # other builds) - it is read from ARP, never constructed.
                if ($rest -notmatch '(?i)(^|\s)-a(\s|$)') { $rest = ('-a ' + $rest).Trim() }
                if ($rest -notmatch '(?i)(^|\s)-y(\s|$)') { $rest = ('-y ' + $rest).Trim() }
            } elseif ($rest -match '(?i)-removeonly|isuninst|InstallShield') {
                # InstallShield InstallScript maintenance launcher: lowercase -s.
                if ($rest -notmatch '(?i)(^|\s)-s(\s|$)') { $rest = ($rest + ' -s').Trim() }
            } elseif ($rest -notmatch '/S|/silent|/quiet|--silent') {
                $rest = ($rest + ' /S').Trim()
            }
            # Pass the argument tail as ONE verbatim string - do NOT split on
            # whitespace, which shatters quoted "C:\Program Files\..." arguments.
            $spArgs = @{ FilePath=$exe; PassThru=$true; WindowStyle='Hidden'; ErrorAction='Stop' }
            if ($rest) { $spArgs['ArgumentList'] = $rest }
            $p = Start-Process @spArgs

            # Wait with a CAP instead of -Wait. NiceLabel's InstallShield Advanced
            # UI bootstrapper FINISHES the removal, deletes its own exe, then blocks
            # forever waiting on a pending reboot to finalize - it never exits, so a
            # plain -Wait hangs the entire unattended uninstall (seen on the rig
            # when uninstalling shortly after a fresh install). Poll: the moment the
            # product leaves the registry while the process is still alive, that's
            # the hung-post-removal case -> kill the orphan and report success. The
            # registry is authoritative; the exit code is not. Hard cap is a final
            # backstop. (msiexec is never killed - it stays on -Wait above.)
            $escName  = [regex]::Escape($DisplayName)
            $deadline = (Get-Date).AddMilliseconds($UninstallTimeoutMs)
            while ($true) {
                if ($p.WaitForExit(5000)) { break }   # exited on its own
                if (-not (Find-InstalledProducts -Pattern $escName)) {
                    Warn "$DisplayName gone from registry but uninstaller still running - killing orphan"
                    try { $p.Kill(); $p.WaitForExit(10000) | Out-Null } catch {}
                    Ok "removed $DisplayName (uninstaller hung post-removal; registry confirms gone)"
                    return $true
                }
                if ((Get-Date) -ge $deadline) {
                    Warn "$DisplayName uninstaller exceeded $([int]($UninstallTimeoutMs/1000))s - killing"
                    try { $p.Kill(); $p.WaitForExit(10000) | Out-Null } catch {}
                    if (-not (Find-InstalledProducts -Pattern $escName)) { Ok "removed $DisplayName (registry confirms gone)"; return $true }
                    Warn "$DisplayName still in registry after timeout - may not be fully removed"; return $false
                }
            }
        }
        if ($p.ExitCode -in $okCodes) { Ok "removed $DisplayName (exit $($p.ExitCode))"; return $true }
        Warn "$DisplayName uninstaller exited $($p.ExitCode)"; return $false
    } catch {
        Warn "uninstall failed: $($_.Exception.Message)"; return $false
    }
}

function Remove-InstallShieldOrphans {
    # The Zebra InstallScript installs (via setup.exe -s) register an
    # InstallShield_{GUID} ARP entry + an "InstallShield Installation
    # Information\{GUID}" cache folder ALONGSIDE the real MSI product. Removing
    # the product with MsiExec /X leaves these as orphans (a dead Add/Remove
    # entry whose -removeonly command no longer works). Sweep them so -Uninstall
    # leaves nothing behind.
    param([Parameter(Mandatory)][string]$Pattern)
    foreach ($h in $UninstallHives) {
        Get-ItemProperty $h -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -like 'InstallShield_*' -and $_.DisplayName -and $_.DisplayName -match $Pattern } |
            ForEach-Object {
                $guid = ($_.PSChildName -replace '^InstallShield_','')
                if ($DryRun) { Dry "would remove orphan ARP $($_.PSChildName) ($($_.DisplayName))"; return }
                try { Remove-Item $_.PSPath -Recurse -Force -ErrorAction Stop; Ok "removed orphan ARP entry: $($_.DisplayName)" }
                catch { Warn "could not remove orphan ARP $($_.PSChildName): $($_.Exception.Message)" }
                $isf = Join-Path ${env:ProgramFiles(x86)} "InstallShield Installation Information\$guid"
                if (Test-Path $isf) {
                    try { Remove-Item $isf -Recurse -Force -ErrorAction Stop; Ok "removed InstallShield cache folder: $guid" }
                    catch { Warn "could not remove IS cache ${guid}: $($_.Exception.Message)" }
                }
            }
    }
}

# ===========================================================================
# NATIVE DOWNLOAD (replaces download_alleaves.py + gdown)
# ===========================================================================

# Advisor #2: stock unpatched Win10 defaults to TLS1.0 -> every Google/Splashtop
# fetch fails with an SSL error. Set TLS1.2 BEFORE any download. Non-optional.
function Set-Tls12 {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]'Tls12'
    } catch {
        # Enum absent on very old .NET - fall back to the numeric value.
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]3072
    }
}

# Port of download_alleaves.py:65-77 magic-byte sniff, used as a validator.
# Rejects an HTML interstitial saved as an installer (leading '<' = 0x3C).
function Test-RealBinary {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $false }
    try {
        $fs = [IO.File]::OpenRead($Path)
        try {
            $buf = New-Object byte[] 8
            $n = $fs.Read($buf, 0, 8)
        } finally { $fs.Close() }
    } catch { return $false }
    if ($n -lt 2) { return $false }
    if ($buf[0] -eq 0x3C) { return $false }                                              # '<' HTML
    if ($buf[0] -eq 0x50 -and $buf[1] -eq 0x4B -and $buf[2] -eq 0x03 -and $buf[3] -eq 0x04) { return $true }  # PK\x03\x04 zip/nlbl
    if ($buf[0] -eq 0xD0 -and $buf[1] -eq 0xCF -and $buf[2] -eq 0x11 -and $buf[3] -eq 0xE0) { return $true }  # OLE compound (MSI)
    if ($buf[0] -eq 0x4D -and $buf[1] -eq 0x5A) { return $true }                          # MZ exe
    return $false
}

# F2: Test-RealBinary only sniffs 8 magic bytes, so a header-valid but TRUNCATED
# installer (a first run hard-killed mid-write - WebClient.DownloadFile streams
# straight to the final path, and the terminal-failure delete never ran) is
# accepted as "already present, valid" on the next run -> installs corrupt -> 1603
# brick, recoverable only with -ForceReinstall. Persist the byte length in a .len
# sidecar on every successful download and re-verify the on-disk size against it in
# each cache guard; a missing or mismatched sidecar falls through to re-download.
function Save-FileSizeSidecar {
    param([string]$Path)
    try {
        $size = (Get-Item $Path -ErrorAction Stop).Length
        Set-Content -Path "$Path.len" -Value $size -Encoding ASCII -ErrorAction Stop
    } catch { Warn "could not write size sidecar for ${Path}: $($_.Exception.Message)" }
}
function Test-CachedFileValid {
    # $true only if the file passes the magic-byte sniff AND its size matches the
    # .len sidecar recorded at download time. No sidecar => not trustworthy.
    param([string]$Path)
    if (-not (Test-RealBinary $Path)) { return $false }
    $lenFile = "$Path.len"
    if (-not (Test-Path $lenFile)) { return $false }
    $expected = $null
    try { $expected = [int64]((Get-Content $lenFile -Raw -ErrorAction Stop).Trim()) } catch { return $false }
    if ($expected -le 0) { return $false }
    $actual = (Get-Item $Path -ErrorAction SilentlyContinue).Length
    return ($actual -eq $expected)
}

# Best-effort declared Content-Length so we can catch a truncated-but-valid-
# header MSI/EXE (which installs as a corrupt 1603 and bricks the terminal).
$script:RemoteLengthCache = @{}   # F4: per-URL probe cache (skip re-probing on each retry)
function Get-RemoteLength {
    param([string]$Url)
    # Try HEAD first (no body transfer); fall back to GET only if HEAD yields no
    # usable length. The old code always issued a GET and closed the response,
    # which made the server START streaming the whole file just to read one
    # header - wasteful, and this runs on every retry of every file. The GET
    # fallback preserves the truncation guard for endpoints that omit a
    # HEAD Content-Length (some Drive/CDN hosts do).
    # F4: cache a known-good length per URL (a probe failure is NOT cached, so a
    # transient miss can still succeed on a later retry); on the GET pass, request a
    # single byte and read the TOTAL from Content-Range instead of streaming the file.
    if ($script:RemoteLengthCache.ContainsKey($Url)) { return $script:RemoteLengthCache[$Url] }
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
                # A ranged 206 reports ContentLength=1, NOT the file size - take the
                # total from Content-Range (bytes 0-0/<total>). If the server ignored
                # the range it returns the full body length (>1), which is fine; a
                # ranged response with no parseable total is rejected (don't trust 1).
                $cr = $resp.Headers['Content-Range']
                if ($cr -and $cr -match '/(\d+)\s*$') { $len = [int64]$Matches[1] }
                elseif ($len -le 1) { $len = [int64](-1) }
            }
            $resp.Close()
            if ($len -gt 0) { $result = $len; break }
        } catch { }
    }
    if ($result -gt 0) { $script:RemoteLengthCache[$Url] = $result }
    return $result
}

function Unblock-FileSafe {
    # Defender can hold a sharing lock mid-scan; settle-and-retry. (Advisor #4)
    param([string]$Path)
    for ($k = 0; $k -lt 3; $k++) {
        try { Unblock-File -Path $Path -ErrorAction Stop; return }
        catch { Start-Sleep -Seconds 2 }
    }
    Warn "Unblock-File did not complete for $Path (continuing)"
}

# BITS first (free resume + timeout, serves the bad-connection goal), fall back
# to WebClient.DownloadFile. We avoid Invoke-WebRequest -OutFile on PS5.1: it
# buffers large files in memory and cannot resume.
function Invoke-FileDownload {
    param([string]$Url, [string]$Dest)
    $dir = Split-Path $Dest -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    try {
        if (Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue) {
            # F3: send the same UA as the probe + WebClient (some CDNs/filters 403 a
            # blank UA); BITS takes it via -CustomHeaders.
            Start-BitsTransfer -Source $Url -Destination $Dest -TransferType Download `
                -CustomHeaders "User-Agent: $script:UserAgent" -ErrorAction Stop
            return $true
        }
    } catch {
        Warn "BITS failed ($($_.Exception.Message)); falling back to WebClient"
    }
    try {
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add('User-Agent', $script:UserAgent)
        $wc.DownloadFile($Url, $Dest)
        $wc.Dispose()
        return $true
    } catch {
        Warn "WebClient failed: $($_.Exception.Message)"
        return $false
    }
}

function Get-FileWithRetry {
    # Shared download+validate loop for Drive and Splashtop. $Urls[0] is used on every
    # attempt EXCEPT the last, where $Urls[-1] is used (Drive's alt host). A single-entry
    # $Urls means the same URL every attempt (Splashtop). Validation is identical to the
    # old Get-DriveFile: Content-Length size guard (when known) + magic-byte sniff + sidecar.
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string[]]$Urls,
        [Parameter(Mandatory)][string]$TargetPath,
        [int]$MaxRetries = 4
    )
    Step "Download: $Label"

    # Idempotent: skip a valid existing file unless -ForceReinstall. F2: size-verify
    # against the .len sidecar so a truncated-but-header-valid cache re-downloads.
    if ((Test-Path $TargetPath) -and -not $ForceReinstall -and (Test-CachedFileValid $TargetPath)) {
        $sz = (Get-Item $TargetPath).Length
        Ok "already present, valid: $(Split-Path $TargetPath -Leaf) ($sz bytes)"
        return $true
    }
    if ($DryRun) { Dry "would download $Label -> $TargetPath"; return $true }

    for ($i = 0; $i -lt $MaxRetries; $i++) {
        # Advisor #2B: try the alternate host (last entry) on the final attempt.
        $url = if ($i -ge ($MaxRetries - 1) -and $Urls.Count -gt 1) { $Urls[-1] } else { $Urls[0] }
        Write-Host "  attempt $($i + 1)/$MaxRetries : $url"

        $expected = Get-RemoteLength $url
        if ($expected -gt 0) { Write-Host "  expected Content-Length: $expected bytes" }

        $got = $false
        try { $got = Invoke-FileDownload -Url $url -Dest $TargetPath }
        catch { Warn "download error: $($_.Exception.Message)"; $got = $false }

        if ($got) {
            $size = (Get-Item $TargetPath -ErrorAction SilentlyContinue).Length
            $retryNote = if ($i -lt ($MaxRetries - 1)) { ' - retrying' } else { ' - no attempts left' }   # F11
            if ($expected -gt 0 -and $size -ne $expected) {
                Warn "size mismatch: on-disk $size != Content-Length $expected$retryNote"
            } elseif (-not (Test-RealBinary $TargetPath)) {
                Warn "magic-byte check failed (HTML interstitial / truncation)$retryNote"
            } else {
                Unblock-FileSafe $TargetPath
                Save-FileSizeSidecar $TargetPath   # F2: record size for the cache guard
                Ok "downloaded $Label ($size bytes)"
                return $true
            }
        }

        if ($i -lt ($MaxRetries - 1)) {
            $delay = [int][math]::Min(30, [math]::Pow(2, $i))
            Write-Host "  backing off $delay s..."; Start-Sleep -Seconds $delay
        }
    }
    Fail "could not download $Label after $MaxRetries attempts"
    # Delete ONLY a file this call actually broke. The old unconditional delete destroyed a
    # previously VALID cached download: -ForceReinstall bypasses the cache guard at the top,
    # so a tech re-running on a flaky link lost a good 471 MB Star zip (and orphaned its .len
    # sidecar) that was byte-correct a minute earlier. Test-CachedFileValid is the same
    # sniff+sidecar test the cache guard uses - if it still passes, nothing here wrote over it.
    if (Test-CachedFileValid $TargetPath) {
        Warn "keeping the existing valid cached copy of $Label"
    } else {
        Remove-Item $TargetPath -Force -ErrorAction SilentlyContinue
        Remove-Item "$TargetPath.len" -Force -ErrorAction SilentlyContinue   # never leave the sidecar orphaned
    }
    return $false
}

function Get-DriveFile {
    param([Parameter(Mandatory)][string]$Label, [Parameter(Mandatory)][string]$FileId,
          [Parameter(Mandatory)][string]$TargetPath, [int]$MaxRetries = 4)
    # confirm=t bypasses the Drive virus-scan interstitial; alt host tried on the final attempt.
    $primary  = "https://drive.usercontent.google.com/download?id=$FileId&export=download&confirm=t"
    $fallback = "https://drive.google.com/uc?export=download&id=$FileId&confirm=t"
    return Get-FileWithRetry -Label $Label -Urls @($primary, $fallback) -TargetPath $TargetPath -MaxRetries $MaxRetries
}

# Download table (core only; filenames MUST match the installer File= column).
$DriveFiles = @(
    # Every Label MUST equal the matching $Installers Name. Test-SkipMatch tests Label/File
    # for downloads but Name/File for installs, so a Label that drifts makes one
    # -SkipPrograms fragment hit only ONE phase: -SkipPrograms NiceLabel used to download
    # the whole suite and then never install it. Same discipline the printer rows require.
    @{ Label='Google Chrome';         FileId='1XT7Zc0lU6t1OhI4yM_SpD8TH_N0spUaV'; File='Chrome Setup.exe' }
    @{ Label='Alleaves Terminal';     FileId='1UAqW1zzxj9LJ-Pk0riNsZ8MiYoSQNoxP'; File='Alleaves Terminal App.msi' }
    @{ Label='Zebra 123 Scan';        FileId='1VBCRHD3hyNzlfoOuYsac9LpeHizAkruo'; File='Zebra 123 Scan.exe' }
    @{ Label='Zebra Scanner SDK';     FileId='1K5DR-STIxxtsnwklcbTCpo8cPFCwcIUa'; File='Zebra Scanner SDK.exe' }
    @{ Label='POS for .NET';          FileId='1pYr5skO85h8baFByy9z_ZN1ZPiDnfN_D'; File='POSforDOTNet.msi' }   # F7: Label aligned with install Name so one -SkipPrograms fragment hits both phases
    @{ Label='NiceLabel';             FileId='1C6eDiJBp1S8aVw9i4iebDbs-JC2ERBZn'; File='Nice Label.exe' }
    @{ Label='OLE POS Setup';         FileId='1y14kZ2g4Bwqhi9M0inszCCi_TREkNaH0'; File='OLE POS Setup.exe' }   # POS-X receipt printer OPOS driver
    # Star TSP100 receipt printer (futurePRNT 7.6.0). This is the whole vendor CD image -
    # 471 MB of Autorun shell, 20 languages of manuals and Linux/Mac drivers - and the
    # installer is ONE member inside it (see the $Installers row's ZipMember). Re-hosting
    # the bare 111 MB setup_x64.exe was offered and declined, so the install loop extracts.
    # Only downloaded when the tech picks this brand: step 0b skips every brand's row but
    # the chosen one, so a POS-X terminal never pulls this.
    @{ Label='Star TSP100 futurePRNT'; FileId='1lr2x_jQ6NxtCTPwW4E1fGOSN618vs0CD'; File='Star tsp100_v760.zip' }
    @{ Label='Master List';           FileId='1dPktafxPsoumHSKDC5z7Nm-Jl3sgx2PQ'; File='Alleaves Nice Label Master List.nlbl' }
)

function Test-SkipMatch {
    # F7: shared skip-match for BOTH the download and install phases. The install
    # loop used to also match the INTERNAL $i.Match lookup regex, so a skip fragment
    # could accidentally match a product's registry pattern; it now matches only the
    # human Name and the File (the shared key across both tables). A malformed user
    # regex fragment is caught so it can't abort the phase.
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

function Invoke-DownloadPhase {
    Step 'Download phase'
    Set-Tls12
    Write-Host "  TLS: $([Net.ServicePointManager]::SecurityProtocol)"
    $results = @()
    foreach ($d in $DriveFiles) {
        if (Test-SkipMatch -Names @($d.Label, $d.File)) {
            Step "Download: $($d.Label)"; Warn "skipped via -SkipPrograms"
            continue
        }
        $target = Join-Path $DownloadDir $d.File
        $ok = Get-DriveFile -Label $d.Label -FileId $d.FileId -TargetPath $target
        if (-not $ok) { $script:DownloadFailed = $true }
        $results += [pscustomobject]@{ Label=$d.Label; Ok=$ok }
    }
    if (-not (Test-SkipMatch -Names @('Splashtop','Splashtop SOS','SplashtopSOS.exe'))) {
        $ok = Get-FileWithRetry -Label 'Splashtop SOS' `
            -Urls @('https://download.splashtop.com/sos/SplashtopSOS.exe') `
            -TargetPath (Join-Path $DownloadDir 'SplashtopSOS.exe') -MaxRetries 3
        if (-not $ok) { $script:DownloadFailed = $true }
        $results += [pscustomobject]@{ Label='Splashtop SOS'; Ok=$ok }
    }
    Step 'Download summary'
    foreach ($r in $results) {
        if ($r.Ok) { Ok $r.Label } else { Fail $r.Label }
    }
}

# ===========================================================================
# INSTALL (lifted verbatim from install_alleaves.ps1)
# ===========================================================================

function Uninstall-TeamViewer {
    Step 'Uninstall existing TeamViewer'
    $found = Find-InstalledProducts -Pattern 'TeamViewer'
    if (-not $found) { Ok 'no TeamViewer installation detected'; return }

    foreach ($m in $found) {
        $name = $m.DisplayName
        $u    = $m.UninstallString
        Write-Host "  found: $name"

        # Route through the shared silent-uninstall handler: it resolves the
        # quiet/uninstall command, runs msiexec on -Wait, runs a non-msiexec exe
        # with per-family silent flag selection (TeamViewer's NSIS uninstaller
        # falls through to the generic branch and gets /S - same as before), and
        # backstops a /S-ignoring build with a registry-poll + hard timeout cap
        # instead of an uncapped -Wait that could hang the whole flow. It returns
        # $true on success (and ALSO under -DryRun), so recording the removed
        # name on $true preserves the previous DryRun + per-name tracking.
        if (Invoke-SilentUninstall -DisplayName $name -UninstallString $u -QuietUninstallString $m.QuietUninstallString -ProductCode $m.PSChildName) {
            $Manifest.teamViewerRemoved += $name
        }
    }
}

function Invoke-Installer {
    param(
        [Parameter(Mandatory)][string]   $Name,
        [Parameter(Mandatory)][string]   $Path,
        [string[]]                       $ArgList,
        [string]                         $DisplayNameMatch,
        [switch]                         $ConfirmRegistry   # F6: also require ARP presence (raw-exe installers)
    )
    $okCodes = @(0, 3010, 1641)   # success exit codes; fixed (no caller varies them)
    Step $Name

    # DryRun simulates BEFORE the existence check: on a bare machine the real
    # run downloads first, so a not-yet-present installer is not a failure here.
    if ($DryRun) {
        Dry "would run: $Path $($ArgList -join ' ')"
        $Manifest.installed += @{
            name=$Name; source=$Path
            args=$ArgList
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

    $cmdDisplay = "$resolved $($ArgList -join ' ')"
    $stdoutLog  = Join-Path $LogDir ("{0}.stdout.log" -f ($Name -replace '\W','_'))
    $stderrLog  = Join-Path $LogDir ("{0}.stderr.log" -f ($Name -replace '\W','_'))

    Write-Host "  running: $cmdDisplay"
    Write-Host "  stdout:  $stdoutLog"

    $exit = $null
    try {
        $p = Start-Process -FilePath $resolved -ArgumentList $ArgList `
            -Wait -PassThru -WindowStyle Hidden `
            -RedirectStandardOutput $stdoutLog -RedirectStandardError $stderrLog `
            -ErrorAction Stop
        $exit = $p.ExitCode
    } catch {
        Fail "launch failed: $($_.Exception.Message)"
        $Manifest.installed += @{ name=$Name; result="launch-failed: $($_.Exception.Message)" }
        return
    }

    $entry = @{
        name=$Name; source=$Path
        args=$ArgList
        displayNameMatch=$DisplayNameMatch; exitCode=$exit
        stdoutLog=$stdoutLog; stderrLog=$stderrLog
    }
    if ($okCodes -contains $exit) {
        # F6: a raw-exe installer (Chrome) reports success by exit code alone - an
        # exit-0-but-not-installed case (Group Policy block, AV quarantine, wrong
        # stub) would otherwise record 'ok' with no product. When asked, confirm the
        # product actually registered in ARP; if not, record a failure so the run
        # exit code reflects it and the uninstall (which filters on 'ok') correctly
        # skips a product that was never installed.
        if ($ConfirmRegistry -and $DisplayNameMatch -and -not (Find-InstalledProducts -Pattern $DisplayNameMatch)) {
            Fail "$Name exited $exit but is NOT in the registry (Group Policy / AV / wrong stub?) - recording as failed"
            $entry.result = 'fail'
            $entry.note   = 'exit-success-but-not-registered'
        } else {
            Ok "$Name installed (exit $exit)"
            $entry.result = 'ok'
        }
        # 3010/1641 mean "installed, needs a reboot". They were accepted as ok here but
        # only the VC++ bootstrap ever raised the flag, so a 3010 from POS for .NET or the
        # Alleaves MSI left the summary printing the soft "recommended: reboot" line and a
        # tech walked away from a terminal with pending file-rename operations.
        if ($exit -in 3010, 1641) { $script:RebootPending = $true; Warn "$Name requests a reboot ($exit) - deferred to end of run" }
    } else {
        Fail "$Name exited $exit - see $stdoutLog / $stderrLog"
        $entry.result = 'fail'
    }
    $Manifest.installed += $entry
}

function Invoke-Msi {
    param([string]$Name, [string]$Msi, [string]$DisplayNameMatch)
    $log = Join-Path $LogDir ("{0}.msi.log" -f ($Name -replace '\W','_'))
    Invoke-Installer -Name $Name -Path 'msiexec.exe' `
        -DisplayNameMatch $DisplayNameMatch `
        -ArgList @('/i', "`"$Msi`"", '/qn', '/norestart', '/L*v', "`"$log`"")
}

# ---------------------------------------------------------------------------
# Microsoft Visual C++ 2015-2022 x64 Redistributable bootstrap.
# CoreScanner (Zebra Scanner SDK) hard-requires the x64 VC++ runtime; on a
# fresh-from-store box it is ABSENT and the Zebra wrapper would auto-install it
# and force a reboot that derails the silent flow. The dev rig already had it
# (so "it worked here"), the client did not -> failure. We install it ourselves,
# /norestart, BEFORE the Zebra installers. Standalone (NOT routed through
# Invoke-Installer, whose success codes omit 1638 = "newer present").
# ---------------------------------------------------------------------------
function Test-VcRedistPresent {
    # Authoritative: the VC runtime "Installed" flag (either bitness view).
    foreach ($p in @(
        'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\14.0\VC\Runtimes\x64')) {
        try {
            $v = Get-ItemProperty -Path $p -ErrorAction SilentlyContinue
            if ($v -and $v.Installed -eq 1) { return $true }
        } catch {}
    }
    # Secondary: an Add/Remove entry for the 2015-2022 (or 2015-2019) x64 redist.
    if (Find-InstalledProducts -Pattern 'Microsoft Visual C\+\+ 201[5-9].*x64|2015-2022.*x64') { return $true }
    return $false
}

function Install-VcRedist {
    # Advisor C2: stock Win10 negotiates TLS1.0 only; the aka.ms 302 -> CDN
    # handshake fails without TLS1.2. Set it as the FIRST action - do NOT rely
    # on Invoke-DownloadPhase having run.
    Set-Tls12

    Step 'Bootstrap: Microsoft Visual C++ 2015-2022 x64 Redistributable'

    if (Test-VcRedistPresent) {
        Ok 'Visual C++ x64 runtime already present - skipping'
        $Manifest.dependencies += @{
            name='Microsoft Visual C++ 2015-2022 x64 Redistributable'
            displayNameMatch='Microsoft Visual C\+\+ 201[5-9].*x64|2015-2022.*x64'
            method='vcredist'; result='already-present'; removable=$false
        }
        return
    }

    if ($DryRun) {
        Dry 'would download + install vc_redist.x64.exe /install /quiet /norestart'
        $Manifest.dependencies += @{
            name='Microsoft Visual C++ 2015-2022 x64 Redistributable'
            displayNameMatch='Microsoft Visual C\+\+ 201[5-9].*x64|2015-2022.*x64'
            method='vcredist'; result='dryrun'; removable=$false
        }
        return
    }

    # Lazy download (only when absent). aka.ms is the evergreen permalink; both
    # BITS and WebClient follow its 302 to the CDN. Get-FileWithRetry's size guard
    # self-disables when the server omits Content-Length (aka.ms may), so the MZ
    # magic byte + .len sidecar carry the validation here.
    $exe      = Join-Path $DownloadDir 'vc_redist.x64.exe'
    $primary  = 'https://aka.ms/vs/17/release/vc_redist.x64.exe'
    # F5: a DISTINCT working evergreen permalink (VS 16 channel; ships the same
    # ABI-stable 14.x x64 runtime as /17). The old bare /download/pr/ path was
    # fabricated - it returns HTTP 400 / a tiny JSON body that Test-RealBinary
    # rejects, so the "two sources" redundancy was illusory and a blocked/poisoned
    # primary could NEVER fall back to a usable exe. This 302s to a valid MZ.
    $fallback = 'https://aka.ms/vs/16/release/vc_redist.x64.exe'

    $haveExe = Get-FileWithRetry -Label 'Visual C++ x64 redist' -Urls @($primary, $fallback) -TargetPath $exe -MaxRetries 3

    if (-not $haveExe) {
        Fail 'could not obtain a valid vc_redist.x64.exe'
        $Manifest.dependencies += @{
            name='Microsoft Visual C++ 2015-2022 x64 Redistributable'
            source='vc_redist.x64.exe'; method='vcredist'
            displayNameMatch='Microsoft Visual C\+\+ 201[5-9].*x64|2015-2022.*x64'
            result='fail-download'; removable=$false
        }
        return
    }

    $log = Join-Path $LogDir 'vc_redist.x64.log'
    Write-Host "  running: vc_redist.x64.exe /install /quiet /norestart"
    $exit = $null
    try {
        $p = Start-Process -FilePath $exe `
            -ArgumentList @('/install','/quiet','/norestart','/log',"`"$log`"") `
            -Wait -PassThru -WindowStyle Hidden -ErrorAction Stop
        $exit = $p.ExitCode
    } catch {
        Fail "vc_redist launch failed: $($_.Exception.Message)"
        $Manifest.dependencies += @{
            name='Microsoft Visual C++ 2015-2022 x64 Redistributable'
            source='vc_redist.x64.exe'; method='vcredist'
            displayNameMatch='Microsoft Visual C\+\+ 201[5-9].*x64|2015-2022.*x64'
            result="launch-failed: $($_.Exception.Message)"; removable=$false
        }
        return
    }

    # 0 = installed, 1638 = a newer build already present, 3010/1641 = reboot.
    $entry = @{
        name='Microsoft Visual C++ 2015-2022 x64 Redistributable'
        source='vc_redist.x64.exe'; method='vcredist'; logFile=$log
        displayNameMatch='Microsoft Visual C\+\+ 201[5-9].*x64|2015-2022.*x64'
        exitCode=$exit; removable=$false
    }
    if ($exit -in 0,1638,3010,1641) {
        if ($exit -eq 3010 -or $exit -eq 1641) { $script:RebootPending = $true; Warn 'VC++ requests a reboot (3010/1641) - deferred to end of run' }
        Ok "Visual C++ x64 runtime installed (exit $exit)"
        $entry.result = 'ok'
    } else {
        Fail "vc_redist exited $exit - see $log"
        $entry.result = 'fail'
    }
    $Manifest.dependencies += $entry
}

# InstallShield Setup Launcher wrappers (Zebra 123 Scan, Zebra Scanner SDK)
# crash on every documented silent flag but DO extract a usable .msi to
# %TEMP%\{GUID}\ first. Launch, poll TEMP for the new GUID folder, copy the MSI
# out, kill the wrapper, run the MSI via msiexec directly.
function Invoke-WrappedMsi {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$WrapperPath,
        [Parameter(Mandatory)][string]$DisplayNameMatch
    )
    $TimeoutSeconds = 600   # fixed (no caller varies it)
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

    Write-Host "  launching wrapper to extract embedded MSI..."
    $launchTime = Get-Date   # F10: anchor the orphan reap to launch (was a fixed (Get-Date).AddMinutes(-5))
    $before = Get-ChildItem $env:TEMP -Filter '{*}' -Directory -ErrorAction SilentlyContinue | ForEach-Object FullName
    $proc = $null
    try {
        $proc = Start-Process -FilePath $WrapperPath -WindowStyle Hidden -PassThru -ErrorAction Stop
    } catch {
        Fail "could not launch wrapper: $($_.Exception.Message)"
        $Manifest.installed += @{ name=$Name; source=$WrapperPath; result="launch-failed: $($_.Exception.Message)" }
        return
    }
    Write-Host "  wrapper PID: $($proc.Id)"

    $extractedMsi = $null
    $acceptedSize = 0      # the stabilized size we accepted (re-checked before caching)
    $lastSize     = @{}    # MSI path -> size at previous poll (stabilization)
    $stableCount  = @{}    # F9: MSI path -> consecutive polls the size held steady
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline -and -not $extractedMsi) {
        Start-Sleep -Seconds 3
        $candidates = Get-ChildItem $env:TEMP -Filter '{*}' -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notin $before }
        foreach ($c in $candidates) {
            $msi = Get-ChildItem $c.FullName -Filter '*.msi' -ErrorAction SilentlyContinue |
                Sort-Object Length -Descending | Select-Object -First 1
            if (-not $msi -or $msi.Length -le 1MB) { continue }
            # Size-stabilization (was: accept the instant it passed 1 MB, which
            # truncated the 446 MB 123Scan MSI mid-write and bricked the install).
            # F9: a 2-poll OR-accept could still stage a GROWING MSI if two adjacent
            # 3 s polls happened to read the same partial size (Defender pause / slow
            # fresh-box disk on the 446 MB MSI) -> truncated stage -> msiexec 1603.
            # Require a longer steady dwell (5 consecutive equal polls ~= 15 s of no
            # growth), whether or not the writer is still alive.
            $prev = $lastSize[$msi.FullName]
            if ($null -ne $prev -and $prev -eq $msi.Length) { $stableCount[$msi.FullName]++ }
            else { $stableCount[$msi.FullName] = 0 }
            $lastSize[$msi.FullName] = $msi.Length
            # HasExited is NOT a substitute for stabilization: an InstallShield Setup
            # Launcher is exactly "a wrapper that exits fast but leaves a writer behind"
            # (see the early-out below), so accepting the instant the launcher vanished
            # staged a 40 MB fragment of the 446 MB MSI - msiexec 1603, and the same
            # fragment cached into downloads/ forever. The dwell is now mandatory.
            if ($stableCount[$msi.FullName] -ge 5) {
                $extractedMsi = $msi.FullName; $acceptedSize = $msi.Length; break
            }
        }
        # A wrapper that died at t=3 s (bad payload, AV kill, wrong bitness) extracts
        # nothing and nothing will ever appear, yet the loop used to sleep out the full
        # 600 s before saying so. Invoke-IssSilent has this early-out; its sibling didn't.
        # The 30 s floor lets a wrapper that exits fast but leaves a writer behind finish.
        # $lastSize.Count -eq 0 = no candidate MSI has EVER been seen: now that acceptance
        # always waits out the 5-poll dwell (~15 s), a fast-exiting wrapper whose MSI is
        # still stabilizing at t=30 s would otherwise trip this early-out and be reported
        # as "extracted nothing".
        if ($proc.HasExited -and -not $extractedMsi -and $lastSize.Count -eq 0 -and (Get-Date) -gt $launchTime.AddSeconds(30)) {
            Warn 'wrapper exited without extracting an MSI - not waiting out the timeout'
            break
        }
    }

    # Kill the wrapper before it can start the broken UI flow, plus any child
    # setup/ISBEW64/ISSetupPrerequisites it spawned.
    try { if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } } catch {}
    Get-Process -Name 'setup','ISBEW64','ISSetupPrerequisites' -ErrorAction SilentlyContinue |
        Where-Object { try { $_.StartTime -gt $launchTime.AddMinutes(-1) } catch { $false } } |
        Stop-Process -Force -ErrorAction SilentlyContinue

    if (-not $extractedMsi) {
        Fail "wrapper did not extract an MSI within $TimeoutSeconds s"
        $Manifest.installed += @{
            name=$Name; source=$WrapperPath; method='wrapper-extract'
            displayNameMatch=$DisplayNameMatch; result='fail-extract'
        }
        return
    }
    Write-Host "  extracted MSI: $extractedMsi"

    # Stage the MSI to logs/ so it survives the wrapper temp cleanup.
    $stableMsi = Join-Path $LogDir ("{0}.msi" -f ($Name -replace '\W','_'))
    try { Copy-Item $extractedMsi $stableMsi -Force -ErrorAction Stop } catch {
        Warn "could not stage MSI to $stableMsi - using temp path directly: $($_.Exception.Message)"
        $stableMsi = $extractedMsi
    }

    # Cache into downloads/ under the MSI's real filename so future runs skip
    # the wrapper entirely and stay fully silent. Re-validate FIRST: this copy is
    # PERMANENT (the .iss fallback consults it on Test-Path alone), so a fragment that
    # got here would be installed by every future run, -ForceReinstall included, until
    # someone deleted it by hand.
    try {
        $srcNow = (Get-Item $extractedMsi -ErrorAction Stop).Length
        if ($srcNow -ne $acceptedSize -or -not (Test-RealBinary $extractedMsi)) {
            Warn "extracted MSI is not stable/valid ($srcNow bytes vs $acceptedSize accepted) - NOT caching it"
        } else {
            $cacheTarget = Join-Path $DownloadDir (Split-Path $extractedMsi -Leaf)
            if (-not (Test-Path $cacheTarget)) {
                Copy-Item $extractedMsi $cacheTarget -Force -ErrorAction Stop
                Write-Host "  cached MSI to $cacheTarget for future silent runs"
            }
        }
    } catch {
        Warn "could not cache MSI to downloads/: $($_.Exception.Message)"
    }

    Write-Host "  running: msiexec /i `"$stableMsi`" /qn /norestart"
    $p = Start-Process -FilePath 'msiexec.exe' `
        -ArgumentList @('/i',"`"$stableMsi`"",'/qn','/norestart','/L*v',"`"$msiLog`"") `
        -Wait -PassThru -WindowStyle Hidden

    $entry = @{
        name=$Name; source=$WrapperPath; method='wrapper-extract'
        extractedMsi=$stableMsi; msiLog=$msiLog
        displayNameMatch=$DisplayNameMatch; exitCode=$p.ExitCode
    }
    if ($p.ExitCode -in 0,3010,1641) {
        Ok "$Name installed (exit $($p.ExitCode))"
        $entry.result = 'ok'
        # Third writer of the flag (Invoke-Installer and Install-VcRedist are the others,
        # and this one was missed): a 3010 here left the summary printing the soft
        # "recommended: reboot" line, so a tech walked away from pending file-rename ops.
        if ($p.ExitCode -in 3010,1641) { $script:RebootPending = $true; Warn "$Name requests a reboot ($($p.ExitCode)) - deferred to end of run" }
    } else {
        Fail "$Name msiexec exited $($p.ExitCode) - see $msiLog"
        $entry.result = 'fail'
    }
    $Manifest.installed += $entry
}

# ---------------------------------------------------------------------------
# Zebra's DOCUMENTED InstallShield silent method (preferred over the temp-folder
# MSI extraction race): setup.exe -s -f1"<response.iss>" -f2"<log>". The .iss is
# recorded once on the authorized build rig and embedded (here-strings below).
# Get-EmbeddedIss materializes it to an absolute downloads/ path, byte-exact.
# ---------------------------------------------------------------------------
function Get-EmbeddedIss {
    param(
        [Parameter(Mandatory)][string]$Content,
        [Parameter(Mandatory)][string]$LeafName
    )
    $path = Join-Path $DownloadDir $LeafName
    # InstallShield's .iss parser is byte-sensitive: FORCE CRLF (do not trust the
    # embedded EOLs) and write ASCII with NO BOM. The replacement uses real CR/LF
    # chars (backtick escapes) - a literal "\r\n" replacement would write the
    # backslash text, not newlines.
    $crlf = ($Content -replace "`r?`n", "`r`n")
    [IO.File]::WriteAllText($path, $crlf, (New-Object System.Text.ASCIIEncoding))
    return $path
}

function Invoke-IssSilent {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$WrapperPath,
        [Parameter(Mandatory)][string]$IssContent,
        [Parameter(Mandatory)][string]$IssLeaf,
        [Parameter(Mandatory)][string]$DisplayNameMatch,   # narrow: this item's OWN product (success / idempotency)
        [string]               $RecordMatch = '',           # broad: recorded for uninstall (may add shared CoreScanner)
        # --- Installer-family overrides. Every default below reproduces the ORIGINAL
        # --- Zebra/IS7 behaviour byte-for-byte; only a row that opts in changes anything.
        # {0}=.iss path, {1}=log path. One format string rather than a switch prefix,
        # because InstallShield refuses a line that mixes "-" and "/" switch styles -
        # a PFTW-wrapped IS5 package needs the WHOLE line in /-form, not just a prefix.
        [string]   $ArgFormat = '-s -f1"{0}" -f2"{1}"',
        # Processes to WAIT FOR (the install isn't done while one is alive)...
        [string[]] $WaitNames = @('setup','ISBEW64','ISSetupPrerequisites'),
        # ...versus processes safe to REAP afterwards. Two lists, because one literal
        # serving both meanings means telling it about a new worker also tells it to
        # kill that worker. Pass @() for families with no launcher/worker split.
        [string[]] $ReapNames = @('setup','ISBEW64','ISSetupPrerequisites'),
        # $true (MSI-backed InstallScript): the ARP entry appears when msiexec commits,
        # i.e. near the end - so "present in registry" safely means "done".
        # $false (pure InstallScript/IS5): DeinstallStart() writes ARP BEFORE file
        # transfer, so breaking on it would kill the worker mid-copy and call it success.
        [bool]     $RegistryShortCircuit = $true
    )
    $TimeoutSeconds = 900   # F8: backstop only; worker-tracking ends a healthy install early
    Step $Name
    if (-not $RecordMatch) { $RecordMatch = $DisplayNameMatch }

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

    $issPath = Get-EmbeddedIss -Content $IssContent -LeafName $IssLeaf
    $log     = Join-Path $LogDir ("{0}.silent.log" -f ($Name -replace '\W','_'))
    if (Test-Path $log) { Remove-Item $log -Force -ErrorAction SilentlyContinue }

    # InstallShield response-file silent: NO space after -f1/-f2, absolute paths,
    # passed verbatim via ProcessStartInfo.Arguments. $ArgFormat selects the switch
    # dialect (see the parameter block); the default is the original Zebra line.
    $argLine = $ArgFormat -f $issPath, $log
    Write-Host "  running: `"$WrapperPath`" $argLine"

    $launchTime = Get-Date
    # F8: snapshot pre-existing msiexec PIDs so the worker-wait below scopes to the
    # msiexec instance THIS wrapper spawns (a new PID), not an unrelated long-lived
    # msiexec (Windows Update / RMM self-update). Parent-PID scoping is unreliable
    # here because the -s launcher exits early and orphans its msiexec child.
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
    Write-Host "  wrapper PID: $($proc.Id)"

    # The -s launcher can return EARLY, spawning the real msiexec that performs
    # the (446 MB) install. Wait for the launcher, then poll for the worker to
    # finish ON ITS OWN. CRITICAL (advisor C4): never force-kill msiexec -
    # killing it mid-install bricks the product. Only reap orphaned
    # setup/ISBEW64/ISSetupPrerequisites helpers (mirrors Invoke-WrappedMsi).
    # CAPPED wait. An uncapped WaitForExit() made $TimeoutSeconds no backstop at all: for a
    # family whose launcher IS the whole install (OLE POS Setup - PFTW/IS5, $ReapNames empty),
    # a stub blocked on an unexpected dialog on its hidden window hung the ENTIRE unattended
    # run forever, with nothing left to click it. Never KILL it though - for exactly those
    # families the launcher is the install engine (advisor C4).
    $launcherExited = $false
    try { $launcherExited = $proc.WaitForExit($TimeoutSeconds * 1000) } catch { $launcherExited = $true }
    if (-not $launcherExited) { Warn "$Name launcher still running after $TimeoutSeconds s - continuing without killing it (it may BE the install engine)" }
    Start-Sleep -Seconds 5    # let the spawned worker appear before we poll

    # F8: poll only OUR workers - msiexec that appeared after launch (new PID) plus
    # helper processes (setup/ISBEW64/ISSetupPrerequisites) started after launchTime.
    # An inaccessible process is treated as NOT-ours (catch -> $false) so a locked
    # SYSTEM process can't pin the loop. Once our worker has been seen and is gone,
    # finish immediately; if it never appears after a generous grace, fall through so
    # the caller's fallback runs - instead of looping the full timeout on an
    # unrelated/absent msiexec. Registry presence short-circuits as committed.
    # The deadline is anchored HERE, after the launcher returned - not at $launchTime. A
    # launcher that ran 16 minutes left zero worker budget, the loop never executed once,
    # and the verdict was taken while msiexec was still copying 446 MB. (Same shape as
    # Invoke-WrappedMsi / Invoke-SilentUninstall: budget starts when the wait starts.)
    $deadline  = (Get-Date).AddSeconds($TimeoutSeconds)
    $sawWorker = $false
    $idlePolls = 0
    while ((Get-Date) -lt $deadline) {
        $busy = @(@(Get-Process -Name 'msiexec' -ErrorAction SilentlyContinue |
                    Where-Object { $_.Id -notin $msiexecBefore }) +
                  @(Get-Process -Name $WaitNames -ErrorAction SilentlyContinue |
                    Where-Object { try { $_.StartTime -gt $launchTime.AddMinutes(-1) } catch { $false } }))
        if ($busy.Count -gt 0) { $sawWorker = $true; $idlePolls = 0 }
        else {
            # ARP presence is only trustworthy once OUR workers are idle, so this test lives
            # in the no-workers branch. As the FIRST statement of the loop it fired on the
            # very first poll of a REPAIR run - a prior run that failed AFTER InstallShield
            # wrote the ARP entry, which is precisely when Test-PriorInstallFailed declines
            # the ARP skip and re-runs the installer - and the break fell straight into the
            # $ReapNames sweep, force-killing the setup.exe driving the live multi-MSI chain
            # and then recording result='ok'. The one path meant to repair a broken Zebra
            # install was the one guaranteed to break it, silently, exit 0.
            if ($RegistryShortCircuit -and (Find-InstalledProducts -Pattern $DisplayNameMatch)) { Start-Sleep -Seconds 2; break }
            $idlePolls++
            if ($sawWorker -or $idlePolls -ge 10) { break }   # worker done, or never showed (~30 s grace)
        }
        Start-Sleep -Seconds 3
    }

    # Reap ONLY orphaned helpers - never msiexec, and never anything outside $ReapNames
    # (which is EMPTY for families whose only processes ARE the live install engine).
    if ($ReapNames -and $ReapNames.Count) {
        Get-Process -Name $ReapNames -ErrorAction SilentlyContinue |
            Where-Object { try { $_.StartTime -gt $launchTime } catch { $false } } |
            Stop-Process -Force -ErrorAction SilentlyContinue
    }

    # Success detection (exit code is unreliable for -s): the response log's
    # ResultCode=0 AND/OR registry presence (authoritative, so a missing/locked
    # log can't false-fail a genuine install).
    $logOk = $false
    if (Test-Path $log) {
        try { if ((Get-Content $log -Raw -ErrorAction SilentlyContinue) -match 'ResultCode\s*=\s*0') { $logOk = $true } } catch {}
    }
    $regOk = [bool](Find-InstalledProducts -Pattern $DisplayNameMatch)

    $entry = @{
        name=$Name; source=$WrapperPath; method='iss-silent'
        issFile=$issPath; silentLog=$log
        displayNameMatch=$RecordMatch
        logResultZero=$logOk; registryPresent=$regOk
    }
    # Registry presence only COUNTS AS SUCCESS for families where it means "committed"
    # - the same distinction $RegistryShortCircuit already draws for the poll loop. For
    # pure InstallScript (IS5) DeinstallStart() writes ARP BEFORE file transfer, so an
    # install that died mid-copy is in the registry and would otherwise be recorded 'ok'
    # (and Set-PrinterOpos would then register a device aimed at a DLL never copied).
    # Those families must show ResultCode=0; the log is reachable - /f2 forwarding is
    # proven (measured).
    if ($logOk -or ($regOk -and $RegistryShortCircuit)) {
        Ok "$Name installed (ResultCode=$(if ($logOk){'0'}else{'n/a'}), registry=$regOk)"
        $entry.result = 'ok'
        $Manifest.installed += $entry
        return 'ok'
    } else {
        Fail "$Name silent install not confirmed (no ResultCode=0$(if (-not $RegistryShortCircuit) { '; registry presence is not proof for this family' } else { ', not in registry' })) - see $log"
        $entry.result = 'fail'   # advisor S2: record the failed attempt so the uninstall @('ok') filter skips it
        $Manifest.installed += $entry
        return 'fail'
    }
}

# ---------------------------------------------------------------------------
# Master-list placement. Advisor #3B (functional bug): under elevation
# GetFolderPath('MyDocuments') is the ADMIN's profile, but NiceLabel runs as the
# cashier and won't find the .nlbl there -> silent broken printing. Copy to the
# Documents of EVERY real user profile plus the admin's; record every path.
# ---------------------------------------------------------------------------
function Copy-MasterList {
    param([string]$Source)
    Step 'Copy NiceLabel Master List to Documents'

    # Get-TargetUserProfiles already validates each ProfileImagePath exists.
    $dests = @(Get-TargetUserProfiles | ForEach-Object { Join-Path $_.Profile 'Documents' })
    $admin = [Environment]::GetFolderPath('MyDocuments')
    if ($admin) { $dests += $admin }
    $dests = @($dests | Select-Object -Unique)

    if (-not $dests) { Fail "no Documents folder resolved"; $script:FinishFailed = $true; return }

    if ($DryRun) {
        foreach ($destDir in $dests) {
            Dry "would copy $Source -> $(Join-Path $destDir (Split-Path $Source -Leaf))"
        }
        return
    }

    if (-not (Test-Path $Source)) { Fail "$Source not found"; $script:FinishFailed = $true; return }

    # A terminal with no master list cannot print a label, so a copy that lands NOWHERE is
    # a failed run - not the Warn-and-exit-0 it used to be. Landing in some profiles but
    # not others stays a Warn: the profile that matters (the one the POS runs as) has it.
    $placed = 0
    foreach ($destDir in $dests) {
        $target = Join-Path $destDir (Split-Path $Source -Leaf)
        try {
            if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Force -Path $destDir | Out-Null }
            Copy-Item $Source $target -Force -ErrorAction Stop
            Ok "placed $(Split-Path $target -Leaf) in $destDir"
            $Manifest.filesPlaced += $target
            $placed++
        } catch {
            Warn "could not copy to ${destDir}: $($_.Exception.Message)"
        }
    }
    if ($placed -eq 0) { Fail 'master list could not be copied to ANY Documents folder'; $script:FinishFailed = $true }
}

# ---------------------------------------------------------------------------
# Embedded InstallShield response files (.iss), recorded once on the authorized
# build rig with `setup.exe -r -f1"<iss>"` choosing production defaults, then
# scrubbed of any rig-specific path. Version-locked to the Drive-hosted wrappers
# (123Scan v6.00.0022, Scanner SDK v3.07); the fixed Invoke-WrappedMsi covers a
# future EXE bump. Materialized at install time by Get-EmbeddedIss (ASCII/CRLF).
# ---------------------------------------------------------------------------
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

# POS-X OLE POS Setup 2.84 - InstallShield 5.52 (NOT IS7 like the Zebra pair above),
# so: Version=v5.00.000 and PLAIN dialog section names with no {GUID}- prefix.
# Recorded on the rig 2026-08-10 with `pkg.exe /a /r /f1"<path>"`; only three dialogs.
# bOpt1/bOpt2=0 = the two SdFinish checkboxes left unticked. There is no SdFinishReboot
# in the chain, so no BootOption pin is needed (verified: no reboot, no pending-rename).
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

# NiceLabel 2019 takes the activation ID on /s's command line for unattended online
# activation; LICENSECODE alone lets the server auto-fill name/company/country/email.
# An ARRAY (not a string) so it runs through Invoke-Installer's -ArgList path - keep it
# an array or NiceLabel loses /s and installs non-silent/unlicensed.
$NiceLabelArgs = if ($SkipNiceLabelActivation) { @('/s') } else { @('/s', "LICENSECODE=$NiceLabelLicense") }

# Per-installer table. DisplayNameMatch is a regex the uninstaller uses to find
# this product's UninstallString in HKLM:\...\Uninstall.
$Installers = @(
    @{ Name='Google Chrome';     File='Chrome Setup.exe';          Match='Google Chrome';     Args=@('/silent','/install'); ConfirmRegistry=$true }
    @{ Name='Alleaves Terminal'; File='Alleaves Terminal App.msi'; Match='Alleaves Terminal'; Msi=$true }
    # Both Zebra scanner wrappers are multi-MSI InstallScript chains that also
    # install the shared "Zebra CoreScanner Driver (64bit)" {29707249} (the
    # actual scanner service). Match (narrow) = this item's OWN product, used for
    # the install idempotency + iss-silent success checks (so the CoreScanner
    # that 123Scan installs does NOT falsely mark the SDK as already-installed).
    # UninstallMatch (broad) is recorded for -Uninstall so CoreScanner is also
    # removed. (The single extracted MSI installs the SDK WITHOUT CoreScanner, so
    # the .iss path is required for a working scanner.)
    # Iss= names the .iss file written to disk ($IssLeaf); IssContent= is the here-string itself.
    @{ Name='Zebra 123 Scan';    File='Zebra 123 Scan.exe';        Match='123Scan';           UninstallMatch='123Scan|Zebra CoreScanner';           Iss='123scan';    IssContent=$Iss123Scan;    CachedMsi='Zebra 123Scan (64bit).msi' }
    @{ Name='Zebra Scanner SDK'; File='Zebra Scanner SDK.exe';     Match='Zebra Scanner SDK'; UninstallMatch='Zebra Scanner SDK|Zebra CoreScanner'; Iss='scannersdk'; IssContent=$IssScannerSdk; CachedMsi='Zebra Scanner SDK (64bit).msi' }
    @{ Name='POS for .NET';      File='POSforDOTNet.msi';          Match='POS for \.NET';     Msi=$true }
    @{ Name='NiceLabel';         File='Nice Label.exe';            Match='NiceLabel';         Args=$NiceLabelArgs }
    # POS-X receipt printer OPOS driver. PackageForTheWeb stub wrapping an
    # InstallShield 5.52 (InstallScript) engine - a different animal from the Zebra IS7
    # pair above, hence the four Iss* overrides. Every override defaults to today's
    # behaviour in Invoke-IssSilent, so the validated Zebra path stays byte-identical.
    #   IssArgFormat  ALL-forward-slash: PFTW owns the leading /s and /a and forwards the
    #                 rest to the inner setup.exe. Mixing - and / in one line breaks it,
    #                 so the whole line (not just a prefix) has to change. /L0x0409 is
    #                 required because SETUP.INI has EnableLangDlg=Y and the language
    #                 dialog is shown by the LAUNCHER, before the engine - so it is not
    #                 in the recorded .iss and must be suppressed on the command line.
    #                 NOTE: keep these paths SHORT. IS5 has a fixed command-line buffer;
    #                 ~190 chars works, ~390 crashes the stub with an access violation.
    #                 $DownloadDir/$LogDir are fine; do not point -f1/-f2 at a deep path.
    #   IssWaitNames  real workers, measured on the rig: "Setup" and "_INS5576._MP"
    #                 (ProcessName does NOT strip ._MP, but the _INS* wildcard covers both).
    #   IssReapNames  EMPTY: unlike the Zebra chain there is no launcher/worker split to
    #                 exploit, so nothing here is ever safe to kill. IKernel.exe in
    #                 particular lingers by design and killing it blocks every later
    #                 InstallShield install until reboot.
    #   IssRegistryShortCircuit=$false  InstallScript's DeinstallStart() writes the ARP
    #                 entry BEFORE file transfer, so the usual "in the registry => done"
    #                 break would fire mid-copy and report a killed, half-copied install
    #                 as success. Wait for the worker to finish instead.
    #   NoMsiFallback there is no MSI anywhere in this package; without this the failure
    #                 path drops into Invoke-WrappedMsi, which opens the PFTW GUI and
    #                 polls %TEMP% for 600 s (and can grab an unrelated {GUID} MSI).
    @{ Name='OLE POS Setup';     File='OLE POS Setup.exe';         Match='OLE POS Setup';     Iss='olepos'; IssContent=$IssOlePos
       IssArgFormat='/s /a /s /L0x0409 /f1"{0}" /f2"{1}"'
       IssWaitNames=@('setup','_INS*'); IssReapNames=@(); IssRegistryShortCircuit=$false
       NoMsiFallback=$true }
    # Star TSP100 receipt printer driver (futurePRNT 7.6.0). A RAW-EXE row, deliberately
    # NOT an Iss one: the package is InstallShield BASIC MSI (extract_all / IsConfig.ini /
    # MsiExec in the string table), a different animal from the POS-X PFTW/IS5 InstallScript
    # stub above, so none of the Iss* override machinery applies.
    #   Zip/ZipMember  the download is the vendor's whole 471 MB CD image; the install loop
    #                  pulls this ONE member out with System32\tar.exe (see Invoke-InstallLoop).
    #                  32-bit setup.exe is also in there and unused - the .bat forces 64-bit.
    #   Args           documented verbatim by the vendor (Readme_En.txt S3): /s silences the
    #                  InstallShield LAUNCHER, /v"..." forwards to the INNER msiexec. BOTH
    #                  halves are required - /s alone still shows the MSI UI. Single-quoted
    #                  so the inner quotes survive the parser; Start-Process joins the array
    #                  with a plain Join(' ') and adds no escaping, so it arrives intact.
    #   Match          the ARP DisplayName. NEVER the ProductCode - it changes every release
    #                  (7.1.0/7.4.0/7.5.1/7.7.0 all differ), so a GUID would rot silently.
    #   SkipIfInstalled  the raw-exe branch has no ARP short-circuit of its own; without this
    #                  a 111 MB MSI-backed install replays on EVERY run. Opt-in per row so
    #                  Chrome and NiceLabel keep their existing replay behaviour exactly.
    @{ Name='Star TSP100 futurePRNT'; File='Star tsp100_v760.zip'
       Zip=$true; ZipMember='tsp100_v760/Windows/Installer/setup_x64.exe'
       Match='TSP100 Setup Version'; UninstallMatch='TSP100 Setup Version'
       Args=@('/s','/v"/qn /norestart"'); ConfirmRegistry=$true; SkipIfInstalled=$true }
)

# "Already installed" means SUCCESSFULLY installed. An ARP entry alone doesn't prove
# that: pure InstallScript writes it before file transfer (see $RegistryShortCircuit),
# and an MSI rollback can leave one too - so a run that FAILED leaves exactly the
# registry state a later run reads as "done", and the product is never repaired while
# every re-run reports success. If the prior manifest recorded this product as anything
# other than 'ok', don't let ARP short-circuit the install. Read from the on-disk
# manifest (this run's $Manifest has no row yet) and only once per run.
$script:PriorManifest = $null
function Get-PriorManifest {
    # The on-disk manifest from an EARLIER run, read at most once. Distinct from
    # $Manifest, which is this run's and is empty when the install loop starts.
    if ($null -eq $script:PriorManifest) {
        $script:PriorManifest = @{}
        if (Test-Path $ManifestPath) {
            # -ErrorAction Stop on BOTH, same guard as Invoke-UninstallPhase's read. MEASURED:
            # malformed JSON is statement-terminating and did reach the catch, but a manifest
            # LOCKED by AV / a backup agent fails in Get-Content, which is NON-TERMINATING
            # under 'Continue' - the pipeline then yields nothing, $script:PriorManifest is
            # assigned $null over the @{} default (so the read-once memo never satisfies and
            # every call re-reads and re-errors), and every caller reads it as an EMPTY
            # manifest: Test-PriorInstallFailed returns $false for a product that failed last
            # run and ARP alone skips its repair, and Write-XmlFile's $ours test reads $false
            # so run 2 backs up OUR OWN layout as the "OEM" one.
            # A ZERO-BYTE manifest is the third shape and needs its own test: Get-Content -Raw
            # returns $null with NO error, ConvertFrom-Json never runs, no catch fires - and the
            # result is the same silent "empty manifest" as the two above.
            try {
                $raw = Get-Content $ManifestPath -Raw -ErrorAction Stop
                if ([string]::IsNullOrWhiteSpace($raw)) { throw 'the manifest file is empty' }
                $script:PriorManifest = ($raw | ConvertFrom-Json -ErrorAction Stop)
            }
            catch { Warn "could not read the prior manifest: $($_.Exception.Message)" }
        }
    }
    return $script:PriorManifest
}
function Test-PriorInstallFailed {
    param([Parameter(Mandatory)][string]$Name)
    # No prior row = never attempted = trust the registry (a product installed by hand
    # or by an older build must still be skippable).
    return [bool](@((Get-PriorManifest).installed | Where-Object { $_.name -eq $Name -and $_.result -and $_.result -ne 'ok' }).Count)
}

function Invoke-InstallLoop {
    foreach ($i in $Installers) {
        if (Test-SkipMatch -Names @($i.Name, $i.File)) {   # F7: unified with the download phase; no longer matches $i.Match
            Step $i.Name
            Warn "skipped via -SkipPrograms"
            continue
        }

        # Pre-clean (full removal before reinstall) is only needed for products
        # that FAIL when their installer replays over an existing install: MSI
        # products go into reconfigure/SecureRepair -> 1603, and the Zebra .iss
        # installers run in maintenance mode -> silent fail. Raw installers (Chrome
        # /install, the NiceLabel suite) cleanly REINSTALL over an existing install,
        # so pre-cleaning them is unnecessary - and actively harmful for the
        # NiceLabel suite: msiexec removes its MSI but the suite's bootstrapper state
        # lingers, so the reinstall runs as a REPAIR that does NOT recreate the ARP
        # entries -> NiceLabel ends up installed but invisible to a later -Uninstall.
        # So skip pre-clean for non-MSI/.iss items; they handle reinstall themselves.
        if ($ForceReinstall -and ($i.Msi -or $i.Iss)) {
            # Pre-clean with the BROAD UninstallMatch when defined (the two Zebra
            # wrappers) so the shared "Zebra CoreScanner Driver (64bit)" is removed
            # too, not just this item's own product. Removing it per-item is
            # idempotent (whichever Zebra item reinstalls first re-creates it).
            $cleanPattern = if ($i.UninstallMatch) { $i.UninstallMatch } else { $i.Match }
            $existing = Find-InstalledProducts -Pattern $cleanPattern
            foreach ($e in $existing) {
                Step "$($i.Name) - pre-clean (ForceReinstall)"
                Write-Host "  found existing: $($e.DisplayName)"
                Invoke-SilentUninstall -DisplayName $e.DisplayName `
                    -UninstallString $e.UninstallString `
                    -QuietUninstallString $e.QuietUninstallString `
                    -ProductCode $e.PSChildName | Out-Null
            }
            # CRITICAL for .iss items: removing the Zebra MSI products via msiexec /X
            # leaves the InstallShield InstallScript ARP orphans AND the
            # "InstallShield Installation Information\{GUID}" cache folders behind.
            # If those remain, the silent .iss reinstall runs in MAINTENANCE mode
            # (not the recorded fresh-install flow) and fails silently -> the run
            # falls back to the cached MSI, which does NOT install the shared
            # CoreScanner driver, leaving a non-functional scanner. Sweep the orphans
            # + cache so the .iss sees a clean slate and reinstalls fresh
            # (ResultCode=0, CoreScanner included). Same sweep -Uninstall already uses.
            if ($i.Iss) { Remove-InstallShieldOrphans -Pattern $cleanPattern }
        }

        $full = Join-Path $DownloadDir $i.File
        # Some vendors ship the installer inside a CD image rather than on its own (Star
        # TSP100: one 111 MB setup_x64.exe inside a 471 MB zip). Pull out just that member.
        # ponytail: bsdtar extracts ONE member; Expand-Archive would unpack all 471 MB.
        # Must be System32\tar.exe - Git's tar is GNU tar and cannot read zip at all.
        # No --strip-components: the member keeps its stored path under $DownloadDir, which
        # holds however bsdtar treats strip on zip archives. Untracked and never cleaned up,
        # the same treatment the Zebra wrappers get - $DownloadDir survives -Uninstall by
        # design (uninstall removes manifest filesPlaced only, never the working root).
        # Re-extracted unconditionally: cheap beside the download it came from, and the .len
        # sidecar already guards the zip itself. If extraction silently yields nothing,
        # Invoke-Installer's existence check records 'fail-missing' rather than a phantom ok.
        #
        # Decided HERE, not down in the raw-exe branch, because the extraction above has to
        # honour it too: the 471 MB CD image was re-read by bsdtar on every single re-run
        # before the "already installed; skipping" check 100 lines below ever got a say -
        # exactly the cost SkipIfInstalled was added to avoid.
        $skipInstalled = ($i.SkipIfInstalled -and -not $ForceReinstall -and
                          -not (Test-PriorInstallFailed -Name $i.Name) -and
                          [bool](Find-InstalledProducts -Pattern $i.Match))
        if ($i.Zip) {
            # $full is rewritten either way so the -DryRun preview shows the command line
            # the real run would use; only the extraction itself is guarded (the zip is
            # not on disk during a dry run, and bsdtar would print a raw error).
            # $skipInstalled is tested BEFORE $DryRun: it is computed from live ARP even
            # under -DryRun, so the old order made a terminal that already has futurePRNT
            # preview a 471 MB extraction ("would extract ...") and then immediately print
            # "already installed; skipping" - a preview of a run that would never happen.
            if ($skipInstalled) { Write-Host "  $($i.Name) already installed - not re-extracting $($i.ZipMember)" }
            elseif ($DryRun) { Dry "would extract $($i.ZipMember) from $($i.File)" }
            else {
                & "$env:SystemRoot\System32\tar.exe" -xf $full -C $DownloadDir $i.ZipMember
                # tar's exit code is the only truncation signal there is. A disk that fills
                # mid-extraction of the 111 MB setup_x64.exe (the 471 MB zip sits in the same
                # directory) leaves a PARTIAL exe that Invoke-Installer's existence check
                # passes happily - it catches absence, not truncation - so a truncated binary
                # would be launched, and once ARP/SkipIfInstalled is satisfied it is never
                # re-extracted. Skip the install instead.
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
            # Idempotency guard: a default (non-forced) re-run must NOT replay
            # msiexec /i over an already-installed product. Doing so puts Windows
            # Installer into maintenance/reconfigure mode, whose SecureRepair step
            # can fail to re-verify the original source and exit 1603 (rolling back
            # a product that was working fine). -ForceReinstall pre-cleans above.
            if (-not $ForceReinstall -and -not (Test-PriorInstallFailed -Name $i.Name) -and
                (Find-InstalledProducts -Pattern $i.Match)) {
                Step $i.Name
                Ok 'already installed; skipping'
                $Manifest.installed += @{
                    name=$i.Name; source=$full; method='msi'
                    displayNameMatch=$i.Match; result='ok'; note='already-installed'
                }
                continue
            }
            Invoke-Msi -Name $i.Name -Msi $full -DisplayNameMatch $i.Match
        } elseif ($i.Iss) {
            # Zebra installers: documented InstallShield silent (.iss) method,
            # with the cached MSI / fixed wrapper kept as automatic fallback.
            # $i.Match = narrow (this item's own product) for the install checks;
            # $uMatch = broad (adds shared CoreScanner) recorded for -Uninstall.
            $uMatch = if ($i.UninstallMatch) { $i.UninstallMatch } else { $i.Match }
            # Idempotency guard (advisor S1): a re-run shouldn't replay a 446 MB
            # install over an already-present product. Check this item's OWN
            # product (narrow) - the shared CoreScanner that another Zebra item
            # installs must NOT mark this one as already-installed.
            if (-not $ForceReinstall -and -not (Test-PriorInstallFailed -Name $i.Name) -and
                (Find-InstalledProducts -Pattern $i.Match)) {
                Step $i.Name
                Ok 'already installed; skipping'
                $Manifest.installed += @{
                    name=$i.Name; source=$full; method='iss-silent'
                    displayNameMatch=$uMatch; result='ok'; note='already-installed'
                }
                continue
            }
            # Per-family overrides, each falling back to Invoke-IssSilent's own default
            # (= the original Zebra behaviour) when the row doesn't define it.
            $issOpt = @{}
            if ($i.IssArgFormat) { $issOpt['ArgFormat'] = $i.IssArgFormat }
            if ($i.IssWaitNames) { $issOpt['WaitNames'] = $i.IssWaitNames }
            # -contains the KEY, not a truthiness test: @() is legitimately falsy and an
            # empty ReapNames ("never kill anything") is exactly what IS5 needs.
            if ($i.Keys -contains 'IssReapNames')            { $issOpt['ReapNames'] = @($i.IssReapNames) }
            if ($i.Keys -contains 'IssRegistryShortCircuit') { $issOpt['RegistryShortCircuit'] = [bool]$i.IssRegistryShortCircuit }
            $res = Invoke-IssSilent -Name $i.Name -WrapperPath $full `
                -IssContent $i.IssContent -IssLeaf ("{0}.iss" -f $i.Iss) `
                -DisplayNameMatch $i.Match -RecordMatch $uMatch @issOpt
            # Fall back ONLY if the .iss method failed AND the product is still
            # absent: cached extracted MSI if present, else the fixed wrapper.
            # On a fresh box the cache is absent -> reaches Invoke-WrappedMsi.
            # NoMsiFallback: suppress for packages that contain no MSI at all. Otherwise
            # Invoke-WrappedMsi launches the wrapper with NO args (GUI on screen) and
            # polls %TEMP% for a {GUID}\*.msi for 600 s - which can pick up an unrelated
            # MSI another installer left there and run msiexec /i on it.
            if ($res -eq 'fail' -and -not $i.NoMsiFallback -and -not (Find-InstalledProducts -Pattern $i.Match)) {
                # Drop the .iss attempt's fail row before the fallback appends its own.
                # Invoke-IssSilent records result='fail' by design, and the fallback records
                # a SECOND row under the same name - Merge-PriorList only dedupes prior
                # against current, so both survived to disk. A run where the fallback
                # SUCCEEDED therefore exited 1, and Test-PriorInstallFailed (any non-ok row)
                # then returned $true forever: the 446 MB Zebra install replayed on every
                # future run and could never short-circuit on ARP.
                $Manifest.installed = @($Manifest.installed | Where-Object { $_.name -ne $i.Name })
                $cached = if ($i.CachedMsi) { Join-Path $DownloadDir $i.CachedMsi } else { $null }
                if ($cached -and (Test-Path $cached)) {
                    Step "$($i.Name) - fallback to cached MSI"
                    Write-Host "  iss-silent failed; using cached extracted MSI: $cached"
                    Invoke-Msi -Name $i.Name -Msi $cached -DisplayNameMatch $i.Match
                } else {
                    Step "$($i.Name) - fallback to wrapper extraction"
                    Warn 'iss-silent failed; falling back to wrapper MSI extraction'
                    Invoke-WrappedMsi -Name $i.Name -WrapperPath $full -DisplayNameMatch $i.Match
                }
            }
        } else {
            # Idempotency guard for raw-exe rows, OPT-IN via SkipIfInstalled. This branch
            # had none, so a raw-exe row replayed its installer on every run - tolerable for
            # Chrome's 1.3 MB stub, not for a 111 MB MSI-backed vendor installer. Opt-in
            # rather than blanket so Chrome and NiceLabel keep their validated behaviour
            # byte-for-byte (NiceLabel in particular re-runs to re-apply its license code).
            # Test-PriorInstallFailed for the same reason the Msi/Iss branches consult it:
            # "already installed" means SUCCESSFULLY installed, and a failed install leaves
            # exactly the ARP state a later run would read as "done".
            if ($skipInstalled) {
                Step $i.Name
                Ok 'already installed; skipping'
                $Manifest.installed += @{
                    name=$i.Name; source=$full; method='exe'
                    displayNameMatch=$i.Match; result='ok'; note='already-installed'
                }
                continue
            }
            Invoke-Installer -Name $i.Name -Path $full -DisplayNameMatch $i.Match -ArgList $i.Args -ConfirmRegistry:([bool]$i.ConfirmRegistry)
        }
    }
}

# ---------------------------------------------------------------------------
# Manifest persistence. Advisor #3C: do NOT blindly clobber a prior manifest -
# merge so a program skipped this run (already-installed / -SkipPrograms /
# download-failed) doesn't drop out and become un-uninstallable.
# ---------------------------------------------------------------------------
# Merge prior-manifest items forward that THIS run didn't touch, deduped by a key
# selector (for scalar arrays the key IS the item). This run wins on a key conflict.
function Merge-PriorList {
    param($Current, $Prior, [scriptblock]$Key, [string]$Announce)
    $have = @{}
    foreach ($e in @($Current)) { $k = & $Key $e; if ($k) { $have[$k] = $true } }
    $merged = @($Current)
    foreach ($p in @($Prior)) {
        $k = & $Key $p
        if ($k -and -not $have.ContainsKey($k)) {
            if ($Announce) { Write-Host "  manifest: carrying forward prior $Announce '$k'" }
            $merged += $p; $have[$k] = $true
        }
    }
    return ,$merged
}

function Save-Manifest {
    # Never persist over the real manifest during a dry-run: dryrun entries
    # share program names with real ones and would shadow the 'ok' results in
    # the merge below, leaving a later real -Uninstall with nothing to remove.
    if ($DryRun) { Ok 'dry-run: manifest not persisted (real manifest preserved)'; return }
    if (Test-Path $ManifestPath) {
        try {
            # -ErrorAction Stop on BOTH or the catch below never runs for the case that
            # matters most: a manifest LOCKED by AV / a backup agent fails in Get-Content,
            # which is non-terminating under 'Continue', so $prior lands $null, every merge
            # reads it as empty, and the Move-Item that preserves the only record of earlier
            # runs is skipped - the file is silently overwritten instead.
            $prior = Get-Content $ManifestPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $Manifest.installed              = Merge-PriorList $Manifest.installed              $prior.installed              { param($e) $e.name }   -Announce 'entry'
            $Manifest.filesPlaced            = Merge-PriorList $Manifest.filesPlaced            $prior.filesPlaced            { param($e) $e }
            # PRIOR wins (args swapped), same reason as regValuesSet below: only the FIRST
            # run saw the original file, so keeping a later run's row would point the
            # restore at a backup of our own output.
            $Manifest.filesReplaced          = Merge-PriorList $prior.filesReplaced          $Manifest.filesReplaced       { param($e) $e.path }
            $Manifest.teamViewerRemoved      = Merge-PriorList $Manifest.teamViewerRemoved      $prior.teamViewerRemoved      { param($e) $e }
            $Manifest.dependencies           = Merge-PriorList $Manifest.dependencies           $prior.dependencies           { param($e) $e.name }   -Announce 'dependency'
            # PRIOR wins here (args swapped vs every other list): 'prev' is the pre-install
            # state, and only the FIRST run saw it. A second run over the same value finds
            # our own data already there and records prevAbsent=$false; prev=<our value>,
            # so keeping the newer row makes -Uninstall RESTORE what it should remove.
            $Manifest.regValuesSet           = Merge-PriorList $prior.regValuesSet           $Manifest.regValuesSet        { param($e) if ($e.path) { "$($e.path)|$($e.name)" } }
            $Manifest.scheduledTasksCreated  = Merge-PriorList $Manifest.scheduledTasksCreated  $prior.scheduledTasksCreated  { param($e) $e.name }
            $Manifest.scheduledTasksDisabled = Merge-PriorList $Manifest.scheduledTasksDisabled $prior.scheduledTasksDisabled { param($e) $e.name }
            # PRIOR wins (args swapped), for the same reason as filesReplaced/regValuesSet
            # above: only the FIRST run saw the user's real Taskband. By run 2 the logon
            # task has already cleared it and Explorer has rewritten it with OUR pins, so
            # keeping the newer row made -Uninstall "restore" Alleaves Terminal + Alleaves
            # POS pins aimed at exes it had just deleted.
            $Manifest.taskbandBackups        = Merge-PriorList $prior.taskbandBackups        $Manifest.taskbandBackups     { param($e) $e.sid }
            # Keyed on serialFinal (the POST-switch serial) with serial as fallback:
            # Merge-PriorList skips falsy keys on both sides, and $e.serial is BLANK on the
            # common HID-KB start, so a prior run's scanner row was silently dropped.
            $Manifest.scannerConfigured      = Merge-PriorList $Manifest.scannerConfigured      $prior.scannerConfigured      { param($e) if ($e.serialFinal) { $e.serialFinal } else { $e.serial } }
            # Keyed on logicalName, which is NEVER null - same class of flaw as
            # scannerConfigured's blank serial above.
            $Manifest.printerConfigured      = Merge-PriorList $Manifest.printerConfigured      $prior.printerConfigured      { param($e) $e.logicalName }
            $Manifest.regKeysCreated         = Merge-PriorList $Manifest.regKeysCreated         $prior.regKeysCreated         { param($e) $e }
            $Manifest.accountCreated         = Merge-PriorList $Manifest.accountCreated         $prior.accountCreated         { param($e) $e.name }
            # Keyed on the timestamp, not the account: each override is its own event and
            # they all stay. This is the only durable trace of a bypassed precheck (the
            # block prints before Start-Transcript), so a later clean re-run must not
            # erase the record of the run that skipped the check.
            $Manifest.accountCheckOverride   = Merge-PriorList $Manifest.accountCheckOverride   $prior.accountCheckOverride   { param($e) $e.whenUtc }
            if ((-not $Manifest.computerRenamed -or @($Manifest.computerRenamed.Keys).Count -eq 0) -and $prior.computerRenamed -and $prior.computerRenamed.to) {
                $Manifest.computerRenamed = @{}
                foreach ($pn in $prior.computerRenamed.PSObject.Properties) { $Manifest.computerRenamed[$pn.Name] = $pn.Value }
            }
        } catch {
            # An unreadable prior manifest is the ONLY record of what a previous run
            # placed. Overwriting it turns every earlier install into something
            # -Uninstall can no longer see (it would report "nothing recorded" and
            # exit 0). Keep the bytes so they can be repaired by hand.
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
    # Write via a temp file + replace: Set-Content straight onto $ManifestPath leaves a
    # TRUNCATED file if the run is killed mid-write, and a truncated manifest is exactly
    # what trips the unreadable path above on the next run.
    $tmp = "$ManifestPath.tmp"
    try {
        ($Manifest | ConvertTo-Json -Depth 6) | Set-Content -Path $tmp -Encoding UTF8 -ErrorAction Stop
        Move-Item -LiteralPath $tmp -Destination $ManifestPath -Force -ErrorAction Stop
        Ok "manifest written: $ManifestPath"
    } catch {
        Fail "could not write manifest ${ManifestPath}: $($_.Exception.Message)"
        # Nothing this run did is recorded anywhere now, so -Uninstall would report
        # "nothing recorded" and exit 0. Must not be an exit-0 run (see the flag's decl).
        $script:ManifestWriteFailed = $true
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

# ===========================================================================
# POST-INSTALL FINISHING (per-terminal): computer rename, taskbar pin Alleaves
# Terminal + Alleaves POS / remove Edge, make Chrome the default browser,
# bookmark the Alleaves web POS. Every change is tracked in the
# manifest so -Uninstall reverses it, with two deliberate exceptions:
#   * the rename - restoring a factory-random name is pointless (same policy as the
#     TeamViewer removal);
#   * the per-user HKCU work the LOGON SCRIPT does - the http/https/.htm/.html UserChoice
#     values and the HKCU:\Software\AlleavesAuto marker. -Uninstall runs as the tech, and
#     the cashier's hive is not loaded, so it cannot reach them; loading NTUSER.DAT for
#     every profile to revert a file association is more machinery than the problem is
#     worth. The prior ProgId is logged to logs\finish_<user>.log before it is replaced,
#     which is the recovery path. Consequence to expect: after -Uninstall + Chrome removal
#     those associations point at a ChromeHTML ProgId whose exe is gone.
#
# IMPORTANT environment facts this code was built and verified against
# (build 10.0.26200 / 25H2, WORKGROUP, UCPD active - detect at runtime):
#   * Taskbar: the Win10 StartLayoutFile/LockedStartLayout policy does NOT drive
#     the Win11 taskbar (and would LOCK the Start menu). The Win11 machine-wide
#     mechanism is HKLM\...\Explorer\LayoutXMLPath -> a taskbar XML, which only
#     applies to profiles created AFTER it is set. To cover the EXISTING auto-
#     login cashier account we also drop a per-user LayoutModification.xml and,
#     at the next logon, clear that user's Taskband + restart Explorer so the XML
#     is (re)applied. There is no supported per-user "pin" API on Win11 25H2
#     (syspin/pttb are broken on 24H2+), so this clear+reapply is the method.
#   * Default browser: the DefaultAssociationsConfiguration policy is a documented
#     NO-OP on a non-domain workgroup box, and UCPD blocks UserChoice writes while
#     loaded. So we disable UCPD for the next boot (Start=4 + disable its "velocity"
#     re-enable task) and, post-reboot (UCPD inert), write the salted UserChoice
#     Hash ourselves, per user, from a logon task. The hash algorithm is the
#     Kolbicz/DanysysTeam UserChoice hash, validated 153/153 against this rig's
#     live associations before shipping.
# Both the taskbar reapply and the browser write run from ONE per-user logon task
# (AlleavesAuto-FinishUser) that fires after the post-install reboot.
# ===========================================================================

# Set a registry value AND record its prior state so -Uninstall can restore it
# (prevAbsent=true => the value did not exist => uninstall removes it).
function Set-TrackedRegValue {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Value,
        [ValidateSet('String','ExpandString','DWord','QWord','Binary','MultiString')][string]$Type='String',
        # Say so out loud when we are about to replace SOMEONE ELSE'S value rather than
        # one of our own. The prior state is recorded either way (so -Uninstall restores
        # it), but a silently clobbered ManagedBookmarks / deliberately-0
        # BookmarkBarEnabled is invisible in the transcript until someone complains.
        [string]$WarnIfPresent
    )
    # Internal DryRun guard. The two original callers guard externally, but a new
    # caller that forgets would write to HKLM during a -DryRun. Guard here instead.
    if ($DryRun) { Dry "would set $Path\$Name = $Value ($Type)"; return }

    $prev = $null; $prevAbsent = $true
    try {
        $existing = Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop
        $prev = $existing.$Name; $prevAbsent = $false
    } catch { $prevAbsent = $true }
    if ($WarnIfPresent -and -not $prevAbsent -and "$prev" -ne "$Value") {
        Warn "$WarnIfPresent - existing value '$prev' is being replaced (restored on -Uninstall)"
    }

    # Record the keys New-Item -Force is about to create, so -Uninstall can remove
    # them again. Walk UP from $Path to the shallowest ancestor that doesn't exist
    # yet; everything from there down is ours. Without this, restoring the VALUES
    # still leaves the empty KEYS behind - and an empty ServiceOPOS device key is a
    # phantom device that OPOS enumerates and then fails to open.
    if (-not (Test-Path $Path)) {
        $missing = @()
        $walk = $Path
        while ($walk -and -not (Test-Path $walk)) {
            $missing = @($walk) + $missing        # shallowest first
            $parent = Split-Path $walk -Parent
            if ($parent -eq $walk) { break }
            $walk = $parent
        }
        # -Stop for the same reason as the New-ItemProperty below: under 'Continue' a refused
        # New-Item (ACL/policy on HKLM\SOFTWARE\Policies\...) was non-terminating, yet every
        # walked ancestor was still appended to regKeysCreated - so the manifest shipped rows
        # for keys that do not exist and -Uninstall counted each as a removal failure (exit 1).
        New-Item -Path $Path -Force -ErrorAction Stop | Out-Null
        foreach ($m in $missing) {
            if ($Manifest.regKeysCreated -notcontains $m) { $Manifest.regKeysCreated += $m }
        }
    }
    # -Stop, and the manifest row goes AFTER it. $ErrorActionPreference is 'Continue', so a
    # refused write (ACL, policy, wrong type on an existing value) was non-terminating and
    # this function still recorded a value it never wrote - the same lie the printer
    # readback exists to catch, one layer lower and for every caller. Callers that can
    # continue past a failed write catch it; the printer step's per-device catch turns it
    # into exit 7, which is the code that failure is supposed to produce.
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force -ErrorAction Stop | Out-Null
    $Manifest.regValuesSet += @{
        path=$Path; name=$Name; type=$Type
        value      = if ($Type -eq 'Binary') { [Convert]::ToBase64String([byte[]]$Value) } else { "$Value" }
        prev       = if ($prevAbsent) { $null } elseif ($Type -eq 'Binary') { [Convert]::ToBase64String([byte[]]$prev) } else { "$prev" }
        prevAbsent = $prevAbsent
    }
}

# ---------------------------------------------------------------------------
# Feature 1 - computer rename (lowest risk; called EARLY so the tech types the
# name and walks away). Validated, skippable (Enter to skip).
# ---------------------------------------------------------------------------
function Invoke-ComputerRename {
    Step 'Computer rename (POS name & number)'
    if ($SkipRename) { Ok 'rename skipped (-SkipRename)'; return }
    $current = $env:COMPUTERNAME
    Write-Host "  current name: $current"

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
        $err = & $validate $ComputerName
        # $script:FinishFailed on both failure arms: the tally only scans installed/
        # dependencies, so a failed rename printed red [FAIL] and exited 0 - and
        # Get-PosNamePrefix then correctly refuses the unapplied name and falls back to the
        # CURRENT one, so Set-PrinterOpos registers OLDNAME_Printer and Alleaves (configured
        # for the new name) can never open it.
        if ($err) { Fail "preset -ComputerName '$ComputerName' invalid: $err"; Warn 'skipping rename'; $script:FinishFailed = $true; return }
        $name = $ComputerName
    } elseif ([Environment]::UserInteractive -and -not $env:ALLEAVES_NOPAUSE) {
        # F14: the rename prompt is install step 0. On a headless / RMM run there is
        # no console, so an unconditional Read-Host blocks on stdin forever or throws
        # (the throw would escape to the top-level catch and abort the ENTIRE install
        # before a single download). Only prompt when a console is present and the
        # unattended flag is not set; otherwise degrade to skip. The loop is also
        # wrapped as defense-in-depth against a missing console.
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

# Real interactive user profiles (S-1-5-21-*) from ProfileList, with load state.
function Get-TargetUserProfiles {
    $list = @()
    $pl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
    foreach ($k in (Get-ChildItem $pl -ErrorAction SilentlyContinue)) {
        $sid = $k.PSChildName
        if ($sid -notmatch '^S-1-5-21-') { continue }
        $pip = (Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue).ProfileImagePath
        if (-not $pip -or -not (Test-Path $pip)) { continue }
        $list += [pscustomobject]@{ Sid=$sid; Profile=$pip; Loaded=(Test-Path "Registry::HKEY_USERS\$sid") }
    }
    return $list
}

# Back up the Taskband blobs of every currently-LOADED user hive so -Uninstall
# can put the original taskbar pins back (the per-user finish task clears them at
# next logon). Profiles not loaded at uninstall time are cosmetic-only (documented).
function Backup-LoadedTaskbands {
    foreach ($k in (Get-ChildItem 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue)) {
        $sid = $k.PSChildName
        if ($sid -notmatch '^S-1-5-21-' -or $sid -match '_Classes$') { continue }
        $tb = "Registry::HKEY_USERS\$sid\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband"
        if (-not (Test-Path $tb)) { continue }
        if (@($Manifest.taskbandBackups | Where-Object { $_.sid -eq $sid }).Count) { continue }
        # F23: a malformed / wrong-typed Taskband blob makes the [byte[]] cast a
        # TERMINATING error (Continue doesn't suppress it) -> top-level catch ->
        # the whole install aborts before the manifest save, for a purely cosmetic
        # backup. Guard per-SID so one bad hive only skips that hive.
        try {
            $tp = Get-ItemProperty $tb -ErrorAction SilentlyContinue
            $Manifest.taskbandBackups += @{
                sid              = $sid
                favorites        = if ($tp.Favorites)        { [Convert]::ToBase64String([byte[]]$tp.Favorites) }        else { $null }
                favoritesResolve = if ($tp.FavoritesResolve) { [Convert]::ToBase64String([byte[]]$tp.FavoritesResolve) } else { $null }
            }
            Write-Host "  backed up Taskband for $sid (restorable on uninstall)"
        } catch {
            Warn "could not back up Taskband for ${sid}: $($_.Exception.Message)"
        }
    }
}

# The taskbar XML: pin each given all-users .lnk (in order) + keep File Explorer;
# PinListPlacement="Replace" drops the default Edge pin. NO XML comments (they
# silently break the file). The caller passes only the apps actually installed,
# so a missing product just loses its own pin instead of the whole layout.
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

function Write-XmlFile {
    param([string]$Path, [string]$Xml)
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    # Preserve a file we are about to REPLACE. LayoutModification.xml is a file OEM
    # images legitimately ship, and it goes into filesPlaced either way (leaving our
    # layout behind on uninstall would be worse - it would strand pins aimed at deleted
    # exes), so uninstall needs the original back after the delete.
    # "Existing" must mean SOMEONE ELSE'S: on any re-run the file is there because WE
    # wrote it last time, and backing that up would hand -Uninstall a copy of our own
    # layout to restore. The prior manifest is the authority on what we placed.
    # The filesReplaced half also requires the BACKUP to still exist. -Uninstall restores
    # by Move-Item, which CONSUMES the backup, but leaves the manifest in place - so on the
    # next install the stale row still said "ours", no new backup was taken, and the OEM's
    # own LayoutModification.xml was overwritten with nothing to restore it from. A second
    # -Uninstall then printed "backup is gone - cannot restore" and the OEM layout was lost.
    $prior = Get-PriorManifest
    $ours  = (@($prior.filesPlaced) -contains $Path) -or
             (@($prior.filesReplaced | Where-Object { $_.path -eq $Path -and $_.backup -and (Test-Path -LiteralPath $_.backup) }).Count -gt 0)
    if ((Test-Path -LiteralPath $Path) -and $Manifest -and -not $ours -and
        -not @($Manifest.filesReplaced | Where-Object { $_.path -eq $Path })) {
        $bak = "$Path.alleaves-orig"
        try {
            if (-not (Test-Path -LiteralPath $bak)) { Copy-Item -LiteralPath $Path -Destination $bak -Force -ErrorAction Stop }
            $Manifest.filesReplaced += @{ path=$Path; backup=$bak }
            Write-Host "  backed up existing $Path (restored on uninstall)"
        } catch { Warn "could not back up existing ${Path}: $($_.Exception.Message)" }
    }
    [IO.File]::WriteAllText($Path, ($Xml -replace "`r?`n","`r`n"), (New-Object System.Text.UTF8Encoding($false)))
}

# All-users Start Menu: the real path (create / Test-Path) and the %ALLUSERSPROFILE%
# form the taskbar XML wants. One pair so the two can't drift apart.
$StartMenuAll    = 'C:\ProgramData\Microsoft\Windows\Start Menu\Programs'
$StartMenuAllEnv = '%ALLUSERSPROFILE%\Microsoft\Windows\Start Menu\Programs'

# The shortcuts we create and pin. Named once because -Uninstall has to find them
# again in a SECOND place: when Explorer applies the layout it COPIES the .lnk into
# the per-user pinned folder below, and removing only the all-users source (via
# filesPlaced) strands a pin pointing at a deleted exe. Measured on the rig.
# Matched by EXACT name so a pin some other vendor created is never touched.
$TaskbarPinNames  = @('Alleaves Terminal', 'Alleaves POS')
$UserPinnedRelDir = 'AppData\Roaming\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar'

# Create an all-users Start Menu shortcut and record it so -Uninstall removes it
# (filesPlaced; no new manifest key needed). <taskbar:DesktopApp> can only pin a
# .lnk, which is why both taskbar entries are built here rather than pinned direct.
# Returns the .lnk path, or $null if there was nothing to point it at.
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
        # Keep WorkingDirectory pinned to the install dir: AlleavesLauncher.exe is an
        # updater that unpacks its payload RELATIVE to the working directory (measured
        # - run from a shell it dropped Build\ + version.txt into that shell's cwd).
        $sc.WorkingDirectory = Split-Path $Target -Parent
        $sc.Description      = if ($Description) { $Description } else { $Name }
        $sc.Save()
    } catch { Warn "could not create '$lnk': $($_.Exception.Message)"; return $null }
    $Manifest.filesPlaced += $lnk
    Ok "all-users shortcut created: $lnk"
    return $lnk
}

# The Alleaves MSI installs exactly two files (AlleavesLauncher.exe + .config) and
# NO shortcut anywhere - measured on the rig. ARP InstallLocation is the only source;
# no literal fallback, so a $null here means "don't pin it" rather than a pin aimed at
# a guessed path.
function Get-AlleavesLauncherPath {
    $p = @(Find-InstalledProducts -Pattern 'Alleaves Terminal')[0]
    if (-not $p -or -not $p.InstallLocation) { return $null }
    return (Join-Path $p.InstallLocation.TrimEnd('\') 'AlleavesLauncher.exe')
}

# App Paths is the canonical chrome.exe lookup and is correct for both the
# Program Files and Program Files (x86) installs.
function Get-ChromeExePath {
    $ap = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe' -ErrorAction SilentlyContinue).'(default)'
    if ($ap -and (Test-Path $ap)) { return $ap }
    return $null
}

# ---------------------------------------------------------------------------
# Features 2 + 4 - taskbar: pin Alleaves Terminal + "Alleaves POS", remove Edge.
# Sets $script:FinishTaskbar so the shared logon task applies it per user after
# the reboot. Pin order below is taskbar order: the terminal app first (the
# primary app on a POS), then the browser, then File Explorer.
#
# "Alleaves POS" is chrome.exe with $AlleavesUrl on its command line, and it
# REPLACES the plain Google Chrome pin. That is not a stylistic choice: Chrome
# refuses to honour a start-page policy on a terminal that is not domain-joined
# or CBCM-enrolled (see Invoke-ChromeBookmark), so a shortcut that carries the
# URL is the only way to make the cashier's browser icon land on the POS.
# ---------------------------------------------------------------------------
function Invoke-ChromeTaskbar {
    Step 'Taskbar: pin Alleaves Terminal + Alleaves POS, remove Edge'
    if ($SkipChromeTaskbar) { Ok 'taskbar step skipped (-SkipChromeTaskbar)'; return }

    # Build the pin list per app rather than bailing out on one missing product:
    # a single early return here would silently drop the OTHER app's pin too.
    $terminalPin = $TaskbarPinNames[0]
    $posPin      = $TaskbarPinNames[1]
    $pins = @()
    if ($DryRun) {
        Dry "would create '$StartMenuAll\$terminalPin.lnk' -> AlleavesLauncher.exe"
        Dry "would create '$StartMenuAll\$posPin.lnk' -> chrome.exe $AlleavesUrl"
        $pins = @("$StartMenuAllEnv\$terminalPin.lnk", "$StartMenuAllEnv\$posPin.lnk")
    } else {
        $launcher = Get-AlleavesLauncherPath
        if (-not $launcher) { Warn 'Alleaves Terminal not installed - not pinning it' }
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
        Warn 'neither Alleaves Terminal nor Chrome is installed - skipping the taskbar step'; return
    }
    $xml = Get-TaskbarXml -LinkPaths $pins

    # (a) Machine-wide XML + LayoutXMLPath - applies to NEW profiles.
    $machineXml = Join-Path $WorkDir 'TaskbarLayoutModification.xml'
    if ($DryRun) {
        Dry "would write taskbar XML -> $machineXml"
        Dry 'would set HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\LayoutXMLPath (new profiles)'
    } else {
        # try/catch like (b) and (c) below: $ErrorActionPreference='Continue' does NOT
        # suppress a .NET method exception, so an unguarded throw here would abort the
        # whole run at the top-level catch - after every download and install has
        # already happened - for one cosmetic file.
        try {
            Write-XmlFile -Path $machineXml -Xml $xml
            $Manifest.filesPlaced += $machineXml
            Set-TrackedRegValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer' -Name 'LayoutXMLPath' -Value $machineXml -Type 'String'
            Ok "LayoutXMLPath set (new profiles): $machineXml"
        } catch { Warn "could not write the machine taskbar XML: $($_.Exception.Message)" }
    }

    # (b) Default profile XML - brand-new accounts pick it up at first logon.
    $defXml = 'C:\Users\Default\AppData\Local\Microsoft\Windows\Shell\LayoutModification.xml'
    if ($DryRun) { Dry "would write Default-profile taskbar XML -> $defXml" }
    else {
        try { Write-XmlFile -Path $defXml -Xml $xml; $Manifest.filesPlaced += $defXml; Ok "Default-profile taskbar XML placed: $defXml" }
        catch { Warn "could not write Default-profile XML: $($_.Exception.Message)" }
    }

    # (c) Existing profiles (incl. the auto-login cashier): drop the per-user XML.
    # The logon task clears Taskband + restarts Explorer so this XML is applied.
    $userXmlPlaced = 0
    if (-not $DryRun) { Backup-LoadedTaskbands }
    foreach ($u in (Get-TargetUserProfiles)) {
        $uXml = Join-Path $u.Profile 'AppData\Local\Microsoft\Windows\Shell\LayoutModification.xml'
        if ($DryRun) { Dry "would write per-user taskbar XML -> $uXml (sid $($u.Sid))"; $userXmlPlaced++; continue }
        try { Write-XmlFile -Path $uXml -Xml $xml; $Manifest.filesPlaced += $uXml; $userXmlPlaced++; Ok "per-user taskbar XML placed for $($u.Sid)" }
        catch { Warn "could not write per-user XML for $($u.Sid): $($_.Exception.Message)" }
    }

    # Only arm the logon task if a layout actually landed. The task's first act is to
    # DELETE the user's Taskband pins and restart Explorer so the new XML is read; with
    # no XML written (e.g. a read-only per-user file on an OEM image, warned about just
    # above) that is a pure destruction - the cashier loses their pins and gets whatever
    # layout was already on disk, and ours never appears.
    if (-not $userXmlPlaced) {
        Warn 'no per-user taskbar layout could be written - not scheduling the per-user taskbar finish'
        Write-Host '  (the pinned shortcuts were still created; pin them by hand or re-run)'
        return
    }
    # The per-user marker records WHICH layout was applied, not merely that one was.
    # A bare "already applied" flag makes every later pin-set change invisible to a
    # terminal that is already deployed: the XML above is rewritten, but the logon task
    # sees the flag, skips the Taskband clear + Explorer restart that is the only thing
    # making Explorer re-read the XML, and the cashier keeps the OLD pins forever. The
    # pin list is the stamp - no hashing needed, and it changes exactly when the pins do.
    #
    # The pin list ALONE was not enough across an uninstall/reinstall cycle. The cashier's
    # hive is normally not loaded when the tech runs the installer, so that SID is not in
    # taskbandBackups and uninstall step 4d never reaches their marker - it survives. The
    # reinstall pins the same two apps, produces a byte-identical stamp, the logon task
    # decides it is already applied, Taskband is never cleared and the pins never come back.
    # So the stamp also carries a DEPLOYMENT GENERATION: one HKLM value, written through
    # Set-TrackedRegValue, which means -Uninstall removes it for free and the next install
    # mints a new one. A plain re-run finds the existing value and keeps the same stamp, so
    # it does NOT gratuitously wipe pins the cashier added.
    $genRoot = 'HKLM:\SOFTWARE\AlleavesAuto'
    $gen = (Get-ItemProperty -Path $genRoot -Name 'TaskbarGeneration' -ErrorAction SilentlyContinue).TaskbarGeneration
    if (-not $gen) {
        $gen = (Get-Date).ToString('yyyyMMddHHmmss')
        try { Set-TrackedRegValue -Path $genRoot -Name 'TaskbarGeneration' -Value $gen -Type 'String' }
        catch { Warn "could not record the taskbar generation: $($_.Exception.Message)" }
    }
    $script:TaskbarStamp  = ((@($pins) + $gen) -join '|')
    $script:FinishTaskbar = $true
    Write-Host '  (taskbar is applied per user at the next logon by AlleavesAuto-FinishUser)'
}

# ---------------------------------------------------------------------------
# Feature 3 - default browser (Chrome). Disables UCPD for next boot; the actual
# per-user UserChoice write happens post-reboot via the logon task.
# ---------------------------------------------------------------------------
function Invoke-ChromeDefaultBrowser {
    Step 'Default browser: make Google Chrome default (http/https/.htm/.html)'
    if ($SkipDefaultBrowser) { Ok 'default-browser step skipped (-SkipDefaultBrowser)'; return }
    if (-not $DryRun -and -not (Find-InstalledProducts -Pattern 'Google Chrome')) {
        Warn 'Google Chrome not installed - skipping default-browser'; return
    }
    if (-not $DryRun -and -not (Test-Path 'HKLM:\SOFTWARE\Clients\StartMenuInternet\Google Chrome')) {
        Warn 'Chrome StartMenuInternet registration missing - default may not stick'
    }

    # UCPD blocks UserChoice writes while loaded. Disable for next boot + disable
    # the "velocity" task that would re-enable it at logon. Both restored on uninstall.
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
                    Ok 'UCPD disabled for next boot (Start=4) - restored on uninstall'
                } catch {
                    Fail "could not disable UCPD: $($_.Exception.Message)"
                    $script:FinishFailed = $true
                }
            }
            # OUTSIDE the Start=4 test. This task's whole job is to re-enable UCPD, so it
            # has to be re-checked on every run - it used to live in the else arm, which
            # meant any re-run (where Start is already 4 from run 1) skipped it entirely.
            # If it ever came back, UCPD reloads at boot, every Set-UserChoiceDefault
            # burns its retries, and Chrome silently never becomes default - exit 0.
            # Disable-TrackedTask early-returns on an already-disabled task, so this is free.
            Disable-TrackedTask -TaskPath '\Microsoft\Windows\AppxDeploymentClient\' -TaskName 'UCPD velocity'
        }
    } else {
        Write-Host '  UCPD service not present - no driver to disable (UserChoice writes may already work)'
    }
    $script:FinishBrowser = $true
    Write-Host '  (Chrome is set default per user at the next logon by AlleavesAuto-FinishUser)'
}

# ---------------------------------------------------------------------------
# Feature 5 - the Alleaves bookmark. Chrome exposes no bookmark API, and hand-
# editing a profile's Bookmarks JSON is a dead end (Chrome checksums it, rewrites
# it while running, and a brand-new cashier profile would get nothing). The
# supported mechanism is Chrome's own policy registry: machine-wide, every user,
# every profile, applied at the next Chrome launch - so unlike the taskbar and
# default-browser work this needs NO per-user logon task.
#
# Deliberately MANDATORY (not the ...\Chrome\Recommended subkey): on a POS the
# cashier should not be able to delete the bookmark. Chrome will therefore show
# "managed by your organization" - expected.
#
# DO NOT add RestoreOnStartup / RestoreOnStartupURLs / HomepageLocation /
# HomepageIsNewTabPage / NewTabPageLocation here. MEASURED 2026-08-12 on the rig:
# chrome://policy reports every one of them "This policy is blocked, its value
# will be ignored." Chrome blocks the startup / homepage / search-provider
# policies on a machine that is not AD- or Entra-joined or CBCM-enrolled (an
# anti-hijacking measure); the ...\Recommended flavour is blocked too, and
# merging the same keys into Chrome's initial_preferences was also tested and did
# NOT carry into a brand-new profile. The start page is therefore delivered by
# the "Alleaves POS" taskbar shortcut instead (see Invoke-ChromeTaskbar), and
# ShowHomeButton is deliberately NOT set - the Home button would work but could
# only reach the new-tab page, since HomepageLocation is blocked.
# The two below are NOT in that blocked set and were verified "OK", in both an
# existing profile and a freshly created one.
#
# Install-Alleaves.bat forces 64-bit PowerShell (build-bat.ps1 Sysnative), so
# this lands in the native registry view Chrome reads - do NOT "fix" it by
# adding a WOW6432Node branch.
# ---------------------------------------------------------------------------
function Invoke-ChromeBookmark {
    Step "Chrome: bookmark the Alleaves POS ($AlleavesUrl)"
    if ($SkipChromeBookmark) { Ok 'Chrome bookmark step skipped (-SkipChromeBookmark)'; return }
    if (-not $DryRun -and -not (Find-InstalledProducts -Pattern 'Google Chrome')) {
        Warn 'Google Chrome not installed - skipping the bookmark'; return
    }

    # A read-only "Alleaves" folder on the bookmarks bar holding one entry.
    # Built with ConvertTo-Json so the quoting can't be got wrong by hand.
    $bookmarks = @(
        @{ toplevel_name = 'Alleaves' }
        @{ name = 'Alleaves POS'; url = $AlleavesUrl }
    ) | ConvertTo-Json -Compress

    # Set-TrackedRegValue has its own -DryRun guard and records prior state, so
    # -Uninstall restores each value and removes the keys we created.
    $root = 'HKLM:\SOFTWARE\Policies\Google\Chrome'
    try {
        Set-TrackedRegValue -Path $root -Name 'BookmarkBarEnabled' -Value 1 -Type 'DWord' `
            -WarnIfPresent 'Chrome BookmarkBarEnabled policy was already set'             # or the bookmark is off-screen
        Set-TrackedRegValue -Path $root -Name 'ManagedBookmarks' -Value $bookmarks -Type 'String' `
            -WarnIfPresent 'another ManagedBookmarks policy is already present (its bookmarks will disappear while this install is in place)'
    } catch {
        Fail "could not write the Chrome bookmark policy: $($_.Exception.Message)"
        $script:FinishFailed = $true
        return
    }
    if (-not $DryRun) { Ok "Chrome policy set: 'Alleaves' bookmark -> $AlleavesUrl" }
    Write-Host '  (applies the next time Chrome starts; verify at chrome://policy)'
}

function Disable-TrackedTask {
    param([Parameter(Mandatory)][string]$TaskPath, [Parameter(Mandatory)][string]$TaskName)
    try {
        $t = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction Stop
        if ($t.State -eq 'Disabled') { Ok "task '$TaskName' already disabled"; return }
        Disable-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction Stop | Out-Null
        # F18: record the prior state so -Uninstall only re-enables tasks that were
        # actually enabled (today guaranteed by the early-return above; recorded
        # explicitly so the invariant survives future changes).
        $Manifest.scheduledTasksDisabled += @{ path=$TaskPath; name=$TaskName; prevState="$($t.State)" }
        Ok "disabled scheduled task: $TaskPath$TaskName"
    } catch {
        # Flagged like its sibling (the UCPD Start=4 write, which sets the same flag at the
        # call site): the only caller is the 'UCPD velocity' task, whose whole job is to
        # re-enable UCPD. Leaving it enabled means UCPD reloads at boot, every
        # Set-UserChoiceDefault burns its retries and Chrome silently never becomes default -
        # while $script:FinishBrowser is still $true and the end-of-run banner tells the tech
        # the default browser is applied automatically at logon. That must not be exit 0.
        Fail "could not disable task '$TaskName': $($_.Exception.Message)"
        $script:FinishFailed = $true
    }
}

# The per-user finish script body (runs at logon, in the user's own context,
# AFTER the post-install reboot when UCPD is no longer loaded). Single-quoted
# here-string => literal; the two feature flags are substituted in below.
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
$ChromeProgId = '__CHROME_PROGID__'   # F17: real Chrome ProgId resolved at install time (fallback ChromeHTML)

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
function Get-HexDateTimeNow {
    $now=[DateTime]::Now
    $dt=[DateTime]::new($now.Year,$now.Month,$now.Day,$now.Hour,$now.Minute,0)
    $ft=$dt.ToFileTime(); $hi=($ft -shr 32); $low=($ft -band 0xFFFFFFFFL)
    return ($hi.ToString('X8')+$low.ToString('X8')).ToLower()
}
$experience='User Choice set via Windows User Experience {D18B6DD5-6124-4341-9318-804003BAFA0B}'
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
    $cur=(Get-ItemProperty $kp -ErrorAction SilentlyContinue).ProgId
    if ($cur -eq $ProgId) { L "$Token already $ProgId"; return $true }
    # The Remove-Item below destroys this user's prior association and -Uninstall cannot
    # put it back (it runs as the tech, and the cashier's hive is not loaded). Log what it
    # was so the value is at least recoverable by hand from finish_<user>.log.
    if ($cur) { L "$Token prior ProgId was '$cur' (NOT restored by -Uninstall)" }
    for ($try=0; $try -lt 3; $try++) {
        $hex=Get-HexDateTimeNow
        $baseInfo=("$Token$sid$ProgId$hex$experience").ToLower()
        $hash=Get-UserChoiceHash $baseInfo
        try { Remove-Item $kp -Recurse -Force -ErrorAction SilentlyContinue } catch {}
        try {
            [Microsoft.Win32.Registry]::SetValue($rk,'Hash',$hash)
            [Microsoft.Win32.Registry]::SetValue($rk,'ProgId',$ProgId)
        } catch { L "$Token write threw: $($_.Exception.Message)" }
        $now=Get-ItemProperty $kp -ErrorAction SilentlyContinue
        if ($now.ProgId -eq $ProgId -and $now.Hash -eq $hash) { L "$Token -> $ProgId OK"; return $true }
        L "$Token write not confirmed (UCPD still active? hex roll?) attempt $try"
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
    elseif ("$applied" -ne $stamp) {
        $tb='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband'
        try { Remove-ItemProperty -Path $tb -Name 'Favorites' -ErrorAction SilentlyContinue } catch {}
        try { Remove-ItemProperty -Path $tb -Name 'FavoritesResolve' -ErrorAction SilentlyContinue } catch {}
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
    # The layout stamp lands inside a single-quoted literal in the generated script, so
    # double any apostrophe (same treatment as __INSTALL_USER__ below). Empty stamp =>
    # the marker can never match => the apply runs, which is the safe direction.
    $body = $body.Replace('__TASKBAR_STAMP__', ("$($script:TaskbarStamp)").Replace("'","''"))
    # F15: bake the installer's username (literal .Replace, doubled quotes) so the
    # finish skips the tech/admin account that ran the install.
    # EXCEPT after an account swap. The resume task runs the installer AS the account it
    # just created - the very account that will run the POS - so baking $env:USERNAME there
    # made the finish skip the only profile that matters: no pins, no default browser, and
    # a log line saying "running as installer - skipping finish". Blank means skip nobody.
    $installUser = if (@($Manifest.accountCreated).Count) { '' } else { ("$env:USERNAME").Replace("'","''") }
    $body = $body.Replace('__INSTALL_USER__', $installUser)
    # F17: resolve Chrome's real URL-association ProgId (machine-wide) at install
    # time; fall back to ChromeHTML if the capability key is absent.
    $chromeProgId = 'ChromeHTML'
    try {
        $cap = (Get-ItemProperty 'HKLM:\SOFTWARE\Clients\StartMenuInternet\Google Chrome\Capabilities\URLAssociations' -ErrorAction Stop).http
        if ($cap) { $chromeProgId = "$cap" }
    } catch {}
    $body = $body.Replace('__CHROME_PROGID__', $chromeProgId.Replace("'","''"))
    return $body
}

# Stage the per-user finish script and register the shared logon task. Called
# once after the taskbar/browser steps, only if at least one set a Finish flag.
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
        [IO.File]::WriteAllText($finishPs, (Get-FinishScriptContent -DoBrowser $script:FinishBrowser -DoTaskbar $script:FinishTaskbar), (New-Object System.Text.UTF8Encoding($false)))
        $Manifest.filesPlaced += $finishPs
    } catch {
        Fail "could not stage finish script: $($_.Exception.Message)"
        # Clear the flags too: the end-of-run summary reads them to tell the tech "the
        # taskbar pin / default browser are applied automatically at logon", which is a
        # lie once the script or the task that runs it does not exist.
        $script:FinishFailed = $true; $script:FinishTaskbar = $false; $script:FinishBrowser = $false
        return
    }
    try {
        $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$finishPs`""
        $trigger   = New-ScheduledTaskTrigger -AtLogOn
        $principal = New-ScheduledTaskPrincipal -GroupId 'S-1-5-32-545' -RunLevel Limited
        $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
        $def       = New-ScheduledTask -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'AlleavesAuto per-user finish: set Chrome default + apply taskbar pin.'
        Register-ScheduledTask -TaskName $taskName -InputObject $def -Force | Out-Null
        $Manifest.scheduledTasksCreated += @{ path='\'; name=$taskName }
        Ok "registered per-user logon task: $taskName (applies after the post-install reboot)"
    } catch {
        Fail "could not register logon task '$taskName': $($_.Exception.Message)"
        $script:FinishFailed = $true; $script:FinishTaskbar = $false; $script:FinishBrowser = $false
    }
}

# ===========================================================================
# FINAL STEP: flip the connected Zebra scanner(s) to USB-OPOS via CoreScanner.
#
# A tech normally opens 123Scan -> "Load to scanner" to put each Zebra scanner
# into USB-OPOS so the Alleaves POS can read it. This automates that as the LAST
# functional step. It is model-agnostic: turning on OPOS is a single CoreScanner
# command - ExecCommand(6200 = DEVICE_SWITCH_HOST_MODE, "XUA-45001-8", silent,
# permanent) - identical across all Zebra USB scanner families (DS/LI/MP/...).
# Because we read the model/PID from GetScanners at runtime, this auto-adapts to
# whatever is plugged in (it does NOT hardcode the DS2208).
#
# Host-variant codes (shared across all Zebra USB scanners):
#   XUA-45001-1  USB IBM Hand-held      XUA-45001-8   USB OPOS  (target)
#   XUA-45001-2  USB IBM Table-top      XUA-45001-9   USB SNAPI
#   XUA-45001-3  USB HID Keyboard       XUA-45001-11  USB CDC Serial
#
# THE ONE GOTCHA: you cannot switch DIRECTLY from the factory HID-Keyboard
# default to OPOS - from HID-KB the only legal targets are IBM Hand-held or
# SNAPI. So from HID-KB (or any unconfirmed mode) we hop HID-KB -> IBM Hand-held
# (XUA-45001-1) -> OPOS (XUA-45001-8), waiting for USB re-enumeration between
# hops (the scanner reconnects and its scannerID CHANGES - so we re-match the
# physical unit by its stable SERIAL number, not by scannerID). permanent=TRUE
# survives power cycles; skipping the switch when already OPOS dodges an old-
# driver "switch-to-OPOS-while-OPOS" hang (our SDK v3.07 is current).
#
# Uninstall records only (removable=$false): scanner host mode is hardware-
# external state, like the computer rename and TeamViewer removal - not reverted.
# A tech can scan the "USB HID Keyboard" / "Set Defaults" barcode (or re-run
# 123Scan) to revert. Scanner_OPOS_barcode.pdf is the no-PC fallback.
#
# Design notes (migrated from the retired docs/SCANNER_OPOS_PLAN.md):
#   * Full parameter sets (beeper volume, symbologies, ...) beyond the host-mode
#     switch would need the per-model .scncfg + opcode 5020 path - a documented
#     FUTURE option only; regenerate a fresh 123Scan export if that day comes.
#     Setting OPOS itself never needs it (it is the 6200 command above).
#   * Factory-reset on uninstall (opcode 2015) was considered and deliberately
#     skipped: it needs a scanner attached at uninstall AND is SNAPI-only.
#   * Authority for the host-variant codes + the two-hop: Zebra TechDocs
#     "PowerShell Scripts for Windows - Examples"
#     (techdocs.zebra.com/dcs/scanners/powershell-scripts-windows/examples/),
#     "Scanner SDK for Windows - API" (.../sdk-windows/api/), and the Zebra
#     support thread "change Host Variant HID Keyboard -> OPOS".
# ===========================================================================

# Host-variant codes + opcode are STABLE across all Zebra USB scanners.
$ScannerOpcodeSwitchHostMode = 6200
$ScannerHostCodeOpos         = 'XUA-45001-8'   # USB OPOS (target)
$ScannerHostCodeIbmHandheld  = 'XUA-45001-1'   # USB IBM Hand-held (mandatory HID-KB hop)

# Host-mode detection. The signal is the GetScanners <scanner type="..."> attribute
# (confirmed on rig: OPOS enumerates as type="USBOPOS"); it feeds Get-ScannerHostMode.
# If it doesn't resolve, the mode reads 'unknown' and takes the UNIVERSAL two-hop
# (HID-KB -> IBM Hand-held -> OPOS), valid from ANY starting mode - so a gap here is
# SAFE, it just costs one extra harmless hop.
# type-attribute -> mode. Regex, case-insensitive. OPOS confirmed; the SNAPI/IBM/HID-KB
# strings are the documented CoreScanner type names (confirm the exact HID-KB/IBM strings
# when a unit is in those modes - unmatched falls through to 'unknown').
$ScannerTypeOpos     = 'OPOS'                 # e.g. USBOPOS  (CONFIRMED on rig 2026-07-01)
$ScannerTypeIbmSnapi = 'SNAPI|IBMHID|IBMTT|IBM'  # USBIBMHID / USBIBMTT / SNAPI
$ScannerTypeHidKb    = 'HIDKB|HIDKEYBOARD'    # USBHIDKB
# Regex (NOT a list): CoreScanner reports the full kit/config SKU in <modelnumber>
# (DS2208-SR7U2100SGW, DS2208-SR00007ZZWW, ...), never the bare family name - so match the
# family prefix. Add confirmed families with '|'. Must stay NON-EMPTY: '' matches everything
# and would silence the new-model fingerprint dump entirely.
$ScannerKnownModels  = 'DS2208'  # confirmed OPOS timing/type; any other family dumps a fingerprint

# Adaptive re-enumeration poll: after each host-mode hop, poll GetScanners until the
# unit's Id or host-mode leaves its pre-hop values, instead of a fixed sleep.
$ScannerReenumPollMs     = 1000  # GetScanners poll interval
# ponytail: 40s ceiling = the fingerprint script's proven $MaxWaitSec; only bites on a
# failed hop (success exits at the real reconnect). RIG-DEPENDENT / TODO[rig]: tune down
# if the slowest observed reconnect is well under this.
$ScannerReenumMaxWaitSec = 40

# RSM readiness. The host-mode switch (ExecCommand 6200) rides the Zebra Remote
# Scanner Management channel, which is UNAVAILABLE (ExecCommand status 112,
# "Device Unavailable") until the CoreScanner + RSM services are running and have
# settled. In a fresh install these run in the SAME session that just installed the
# SDK, before the recommended reboot, so we must ensure the services are up and
# retry 112 (Zebra's documented remediation is "start those services / reboot").
$ScannerStatusDeviceUnavailable = 112
# Confirmed on rig (DS2208, CoreScanner 3.4.0.0, 2026-07-01): the three Zebra services
# and their exact short-names. We resolve by exact name.
$ScannerServiceNames = @('CoreScanner', 'rsmdriverproviderservice', 'ScnSrvc')
$ScannerServiceSettleSec = 8   # TODO[rig]: wait after starting services before the first switch
$ScannerSwitchMaxRetries = 3   # TODO[rig]: attempts per hop while status 112 is returned
$ScannerRetryWaitSec     = 5   # TODO[rig]: wait between 112 retries

function Get-ScannerHostMode {
    # Derive a scanner's USB host mode from the GetScanners <scanner type="..."> attribute
    # (confirmed: OPOS = "USBOPOS"). Returns 'OPOS' | 'IBM/SNAPI' | 'HID-KB' | 'unknown'.
    # 'unknown' is the safe default (-> universal two-hop), so a gap never misroutes.
    param($Scanner)
    $t = ("$($Scanner.Type)").Trim()
    if ($t) {
        if ($t -match $ScannerTypeOpos)     { return 'OPOS' }
        if ($t -match $ScannerTypeIbmSnapi) { return 'IBM/SNAPI' }
        if ($t -match $ScannerTypeHidKb)    { return 'HID-KB' }
    }
    return 'unknown'
}

# Status of the LAST GetScanners call (-1 = it threw). An empty inventory means two very
# different things - "nothing is plugged in" (benign) and "the call failed" - and the two
# are only separable here, so the status is parked for the caller that must tell them
# apart. Read ONLY straight after a call (Set-ScannerOpos's zero-count branch); the
# re-enum poll loop calls this repeatedly and its transient failures are expected.
$script:ScannerInventoryStatus = 0
function Get-CoreScannerInventory {
    # Call GetScanners and parse OutXML into one object per connected scanner.
    # scannerID changes across re-enumeration; SERIAL is stable, so callers
    # re-match the same physical unit by Serial after each host-mode switch.
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
                $list += [pscustomobject]@{
                    Id       = [int]("$($n.scannerID)".Trim())
                    Model    = "$($n.modelnumber)".Trim()
                    Serial   = "$($n.serialnumber)".Trim()
                    Pid      = "$($n.PID)".Trim()
                    Type     = "$($n.type)".Trim()   # host-mode signal, e.g. USBOPOS
                    Vid      = "$($n.VID)".Trim()
                    Firmware = "$($n.firmware)".Trim()
                }
            }
        } catch { Warn "could not parse GetScanners XML: $($_.Exception.Message)" }
    }
    return ,$list
}

function Invoke-ScannerHostSwitch {
    # ExecCommand(6200) to switch one scanner's USB host mode. 1st bool = silent
    # reboot (no beeper menu), 2nd = permanent (survives power cycle). Returns the
    # CoreScanner status integer (0 = success).
    param($Obj, [int]$ScannerId, [string]$HostCode)
    $inXml  = "<inArgs><scannerID>$ScannerId</scannerID><cmdArgs><arg-string>$HostCode</arg-string><arg-bool>TRUE</arg-bool><arg-bool>TRUE</arg-bool></cmdArgs></inArgs>"
    $outXml = ''
    $st     = 0
    try { $Obj.ExecCommand($ScannerOpcodeSwitchHostMode, [ref]$inXml, [ref]$outXml, [ref]$st) }
    catch { Warn "ExecCommand(6200,$HostCode) threw: $($_.Exception.Message)"; return -1 }
    return [int]$st
}

function Confirm-ScannerServicesReady {
    # Ensure the Zebra CoreScanner + RSM / Symbol Scanner Management services are
    # Running so the RSM channel ExecCommand(6200) uses is available (fixes the
    # status-112 "Device Unavailable" seen when the switch runs in the same session
    # that just installed the SDK). Resolves by exact short-name (confirmed on
    # rig). STARTS any that are stopped
    # (never Restart-Service - that would drop the COM Open() we hold), then settles.
    # Returns $true if CoreScanner ended up Running.
    if ($DryRun) { Dry 'would verify/start Zebra CoreScanner + RSM services before the OPOS switch'; return $true }

    $svcs = @()
    foreach ($n in $ScannerServiceNames) {
        $s = Get-Service -Name $n -ErrorAction SilentlyContinue
        if ($s) { $svcs += $s }
    }
    $svcs = $svcs | Sort-Object -Property Name -Unique
    if (-not $svcs) { Warn '  no Zebra scanner services found (CoreScanner absent?)'; return $false }

    $started = $false
    foreach ($s in $svcs) {
        try {
            if ($s.Status -ne 'Running') {
                Write-Host "  starting service '$($s.Name)' ($($s.DisplayName)) [was $($s.Status)]"
                Start-Service -Name $s.Name -ErrorAction Stop
                $started = $true
            }
        } catch { Warn "  could not start service '$($s.Name)': $($_.Exception.Message)" }
    }
    if ($started) { Start-Sleep -Seconds $ScannerServiceSettleSec }   # let RSM attach

    $core = Get-Service -Name 'CoreScanner' -ErrorAction SilentlyContinue
    return [bool]($core -and $core.Status -eq 'Running')
}

function Invoke-ScannerHostSwitchResilient {
    # Wrap Invoke-ScannerHostSwitch with a bounded retry that treats status 112
    # (Device Unavailable = RSM channel not ready) as retryable: re-ensure the
    # services, wait, retry. Any other status returns immediately. Returns the final
    # CoreScanner status integer.
    param($Obj, [int]$ScannerId, [string]$HostCode, [string]$HopLabel)
    $st = -1
    for ($try = 1; $try -le $ScannerSwitchMaxRetries; $try++) {
        $st = Invoke-ScannerHostSwitch -Obj $Obj -ScannerId $ScannerId -HostCode $HostCode
        if ($st -ne $ScannerStatusDeviceUnavailable) { break }
        Warn "    $HopLabel returned status 112 (RSM unavailable) - attempt $try/$ScannerSwitchMaxRetries"
        if ($try -lt $ScannerSwitchMaxRetries) {
            Confirm-ScannerServicesReady | Out-Null
            Start-Sleep -Seconds $ScannerRetryWaitSec
        }
    }
    return $st
}

function Get-ReenumeratedScanner {
    # Re-match one physical scanner after a host-mode switch WITHOUT relying on the
    # pre-hop serial (blank for a factory HID-KB unit, which exposes no asset data).
    # Design assumes 1 scanner per terminal: if exactly one is present, take it. If
    # several, prefer a stable serial match, else the one whose Id changed AND whose
    # mode left the pre-hop mode, else best-effort first with a Warn. $null if none.
    param($Obj, [string]$PreHopSerial, [int]$PreHopId, [string]$PreHopMode)
    $all = @(Get-CoreScannerInventory $Obj)
    if ($all.Count -eq 0) { return $null }
    if ($all.Count -eq 1) { return $all[0] }               # 1-scanner terminal: unambiguous

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

function Wait-ScannerReenum {
    # Poll until the scanner re-enumerates after a host-mode hop (its Id or host-mode left
    # the pre-hop values), replacing a fixed Start-Sleep. Reuses Get-ReenumeratedScanner for
    # the actual re-match. On the ceiling, Scanner is the last best-effort re-match (may be
    # $null / unchanged) - the caller's verify decides. Returns @{ Scanner; Seconds }.
    param($Obj, [string]$PreHopSerial, [int]$PreHopId, [string]$PreHopMode)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $cand = $null
    while ($sw.Elapsed.TotalSeconds -lt $ScannerReenumMaxWaitSec) {
        Start-Sleep -Milliseconds $ScannerReenumPollMs
        $cand = Get-ReenumeratedScanner -Obj $Obj -PreHopSerial $PreHopSerial -PreHopId $PreHopId -PreHopMode $PreHopMode
        if ($cand -and ($cand.Id -ne $PreHopId -or (Get-ScannerHostMode $cand) -ne $PreHopMode)) { break }
    }
    $sw.Stop()
    return @{ Scanner = $cand; Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1) }
}

function Show-ScannerBarcodeFallback {
    # Loud, actionable guidance when the automated USB-OPOS switch fails after
    # retries. The unit still works via the one-scan barcode fallback; exit stays 6.
    # Scanner_OPOS_barcode.pdf is a repo/tech-share deliverable (NOT shipped in the .bat).
    Warn '*********************************************************************'
    Warn '*  AUTOMATED USB-OPOS SWITCH FAILED - 1-SCAN BARCODE FIX AVAILABLE   *'
    Warn '*  1. Open Scanner_OPOS_barcode.pdf (AlleavesAuto repo / tech share) *'
    Warn '*     - the "OPOS (IBM Hand-Held with Full Disable)" host barcode.   *'
    Warn '*  2. Scan it ONCE with the Zebra scanner - it sets OPOS at once.    *'
    Warn '*  3. Reboot, then re-run with -ScannerConfigOnly to confirm/record. *'
    Warn '*********************************************************************'
}

function Write-NewScannerFingerprint {
    # A scanner Model not in $ScannerKnownModels appeared. Dump every hop's full fingerprint
    # (inventory fields + hop status + measured reconnect secs) to ONE $LogDir file so the tech
    # can send it back to finalize the rig-dependent OPOS timing for that model. Records-only.
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
    # -Stop: under 'Continue' a read-only $LogDir / full disk failed non-terminatingly and
    # $path was still returned, so $entry.fingerprintLog pointed at a file that was never
    # written - the manifest telling the tech to send a log that does not exist. (Same
    # "recorded a thing we never wrote" shape as Set-TrackedRegValue.) Caught HERE, not
    # left to the caller's per-device catch: this dump is records-only and must never turn
    # a successful OPOS switch into a failure. $null -> no fingerprintLog key value.
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

function Set-ScannerOpos {
    Step 'Set Zebra scanner(s) to USB-OPOS'

    if ($SkipScannerConfig) { Ok 'scanner OPOS skipped (-SkipScannerConfig)'; return }
    if ($script:ScannerDegraded) { Warn 'CoreScanner missing - skipping scanner OPOS'; return }

    # DryRun simulates BEFORE the DLL existence + COM checks (same pattern as
    # Invoke-Installer): on a bare box the real run installs CoreScanner first, so
    # a not-yet-present Interop DLL is not a dry-run failure, and NO COM is touched.
    if ($DryRun) {
        Dry 'would set connected Zebra scanner(s) to USB-OPOS via CoreScanner (opcode 6200, XUA-45001-8)'
        $Manifest.scannerConfigured += @{ serial=$null; model=$null; hostBefore=$null; target='USB-OPOS'; result='dryrun'; removable=$false }
        return
    }

    $interopDll = 'C:\Program Files\Zebra Technologies\Barcode Scanners\Common\Interop.CoreScanner.dll'
    # Both bails below RECORD + FLAG, like every other bail in this function. They used to
    # Warn and return: with CoreScanner's service present (so $ScannerDegraded / exit 4 does
    # not fire) a missing Interop DLL or a refused Open() produced one yellow line, an empty
    # scannerConfigured list and exit 0 - nothing on disk said the step had even run.
    if (-not (Test-Path $interopDll)) {
        Warn "Interop.CoreScanner.dll not found ($interopDll) - skipping scanner OPOS"
        $Manifest.scannerConfigured += @{ serial=$null; model=$null; hostBefore=$null; target='USB-OPOS'; result='no-interop'; removable=$false }
        $script:ScannerConfigFailed = $true
        return
    }

    $obj = $null
    try {
        [System.Reflection.Assembly]::LoadFile($interopDll) | Out-Null
        $obj = New-Object Interop.CoreScanner.CCoreScannerClass

        # Open for ALL scanner types (scannerTypes[0] = 1).
        $status    = 0
        $appHandle = 0
        $types     = New-Object int16[] 1; $types[0] = 1
        $obj.Open($appHandle, $types, [int16]1, [ref]$status)
        if ($status -ne 0) {
            Warn "CoreScanner Open() returned status $status - skipping scanner OPOS"
            $Manifest.scannerConfigured += @{ serial=$null; model=$null; hostBefore=$null; target='USB-OPOS'; result="open-failed:$status"; removable=$false }
            $script:ScannerConfigFailed = $true
            return
        }

        # Ensure the RSM services are up BEFORE the first switch (fresh installs run
        # this before the recommended reboot, when RSM is often not yet ready -> 112).
        Confirm-ScannerServicesReady | Out-Null

        $scanners = @(Get-CoreScannerInventory $obj)
        # A FAILED enumeration is not the same answer as "no scanner attached". The status
        # was declared, passed as [ref] and never read, so a non-zero GetScanners (RSM not
        # attached yet - the same class of condition the 112 retries exist for) fell into
        # the benign branch below: a DS2208 physically plugged in shipped in HID-KB mode on
        # a green exit-0 run. RECORD + FLAG instead, like the no-interop / open-failed bails.
        if ($scanners.Count -eq 0 -and $script:ScannerInventoryStatus -ne 0) {
            Fail "GetScanners failed (status $script:ScannerInventoryStatus) - cannot enumerate scanners"
            $Manifest.scannerConfigured += @{ serial=$null; model=$null; hostBefore=$null; target='USB-OPOS'; result="enum-failed:$script:ScannerInventoryStatus"; removable=$false }
            $script:ScannerConfigFailed = $true
            return
        }
        if ($scanners.Count -eq 0) {
            # Benign: a terminal set up before its scanner is plugged in still
            # succeeds (exit 0); just re-run the .bat later with the scanner attached.
            Warn 'no Zebra scanner connected - skipping OPOS (re-run with the scanner attached)'
            $Manifest.scannerConfigured += @{ serial=$null; model=$null; hostBefore=$null; target='USB-OPOS'; result='no-scanner'; removable=$false }
            return
        }

        foreach ($s in $scanners) {
            # PER-DEVICE try/catch, same invariant the printer step keeps. With the single
            # outer catch, one scanner throwing (a bad cast in Get-ScannerHostMode, a COM
            # RCW disconnect mid-switch) aborted the loop before any later scanner was
            # touched AND before this one's $entry was appended - a device left mid-switch
            # with no record of it at all.
            $label = "$($s.Model) [$($s.Serial)]"
            $mode  = $null
            $result = 'fail'
            $entry = $null
            try {
            $mode  = Get-ScannerHostMode $s
            # Final identity is captured post-hop (a HID-KB start reports blank
            # serial/model up front; they populate once the unit is in a managed mode).
            $script:ScannerFinalSerial = $s.Serial
            $script:ScannerFinalModel  = $s.Model
            # Per-hop fingerprint, seeded with the pre-switch state; Set-OneScannerToOpos
            # appends each hop. Dumped only if the resolved model is unknown (Task 2).
            $script:ScannerHopLog = @( @{ label='initial'; s=$s; status=$null; seconds=$null } )

            if ($mode -eq 'OPOS') {
                Ok "  $label already USB-OPOS - no change"
                $result = 'already-opos'
            }
            else {
                # Route to OPOS. From HID-KB or an UNKNOWN/unconfirmed mode we MUST
                # hop via IBM Hand-held first; IBM/SNAPI may switch directly.
                $direct = ($mode -eq 'IBM/SNAPI')
                if ($direct) { Write-Host "  $label : $mode -> USB-OPOS (direct)" }
                else         { Write-Host "  $label : $mode -> IBM Hand-held -> USB-OPOS (two-hop)" }
                $result = Set-OneScannerToOpos -Obj $obj -Scanner $s -DirectFromIbm:$direct
            }

            switch ($result) {
                'ok'           { Ok   "  $label set to USB-OPOS" }
                'already-opos' { }   # already logged
                default        { Fail "  $label could NOT be set to USB-OPOS (result=$result)"; $script:ScannerConfigFailed = $true }
            }
            $entry = @{
                serial=$s.Serial; serialFinal=$script:ScannerFinalSerial; model=$s.Model
                modelFinal=$script:ScannerFinalModel; hostBefore=$mode; target='USB-OPOS'
                result=$result; removable=$false
            }
            # Model outside the known FAMILIES: dump its per-hop fingerprint + warn so the
            # rig constants can be finalized for it. Matched as a family regex, since the
            # reported model is a kit SKU (DS2208-SR7U2100SGW), not the bare family name.
            # Model is read post-hop (blank up front for a HID-KB start). Records-only;
            # never touches the exit code. -ForceFingerprint dumps it for a KNOWN model
            # too (rig capture), but newModel stays honest - it means the model really is
            # unknown, not "we asked for the log".
            $newModel = $script:ScannerFinalModel
            if ($newModel -and ($ForceFingerprint -or ($newModel -notmatch $ScannerKnownModels))) {
                if ($newModel -notmatch $ScannerKnownModels) { $entry.newModel = $true }
                $entry.fingerprintLog = Write-NewScannerFingerprint -Model $newModel -Hops $script:ScannerHopLog
            }
            } catch {
                Fail "  $label threw during the OPOS switch: $($_.Exception.Message)"
                $script:ScannerConfigFailed = $true
                if (-not $entry) {
                    $entry = @{ serial=$s.Serial; serialFinal=$script:ScannerFinalSerial; model=$s.Model
                                modelFinal=$script:ScannerFinalModel; hostBefore=$mode; target='USB-OPOS'
                                removable=$false }
                }
                $entry.result = "fail: $($_.Exception.Message)"
            }
            # Outside the catch: a device that threw still gets a row.
            if ($entry) { $Manifest.scannerConfigured += $entry }
        }
    } catch {
        Warn "scanner OPOS step failed: $($_.Exception.Message)"
        $script:ScannerConfigFailed = $true
    } finally {
        if ($obj) { try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($obj) | Out-Null } catch {} }
    }
}

function Set-OneScannerToOpos {
    # Drive ONE physical scanner to USB-OPOS. Re-match after each hop WITHOUT the
    # pre-hop serial (blank when starting from factory HID-KB, which exposes no asset
    # data): under the 1-scanner assumption Get-ReenumeratedScanner takes the sole
    # re-enumerated unit and we refresh serial/id/mode from the now-managed device.
    # Uses the resilient switch (retries status 112). Returns 'ok'|'fail'.
    # Each hop waits via Wait-ScannerReenum (adaptive poll to the real reconnect, not a
    # fixed sleep); OPOS is confirmed by the type attribute (Get-ScannerHostMode).
    param($Obj, $Scanner, [switch]$DirectFromIbm)
    $serial = $Scanner.Serial      # may be '' for a HID-KB start
    $id     = $Scanner.Id
    $mode0  = Get-ScannerHostMode $Scanner

    if (-not $DirectFromIbm) {
        # Hop 1: -> USB IBM Hand-held (the only legal target out of HID-KB).
        $st1 = Invoke-ScannerHostSwitchResilient -Obj $Obj -ScannerId $id `
                 -HostCode $ScannerHostCodeIbmHandheld -HopLabel 'hop1 (IBM Hand-held)'
        if ($st1 -ne 0) { Warn "    hop1 (IBM Hand-held) returned status $st1" }
        # 112 never cleared after retries: the RSM channel is genuinely unavailable, which
        # means the command never reached the scanner and it CANNOT have moved. Tested
        # BEFORE Wait-ScannerReenum, which used to poll the full $ScannerReenumMaxWaitSec
        # for a device sitting untouched in HID-KB - a verdict already known 40 s earlier.
        # TODO[rig]: retry/settle constants above are still the DS2208 values.
        if ($st1 -eq $ScannerStatusDeviceUnavailable) {
            Warn "    hop1 still 112 after $ScannerSwitchMaxRetries attempts - RSM unavailable"
            $script:ScannerHopLog += @{ label='after hop1 (IBM)'; s=$null; status=$st1; seconds=0 }
            return 'fail'
        }
        $w1 = Wait-ScannerReenum -Obj $Obj -PreHopSerial $serial -PreHopId $id -PreHopMode $mode0
        $re = $w1.Scanner
        $script:ScannerHopLog += @{ label='after hop1 (IBM)'; s=$re; status=$st1; seconds=$w1.Seconds }
        Write-Host "    re-enumerated in $($w1.Seconds)s"
        if (-not $re) { Warn '    scanner did not re-enumerate after the IBM Hand-held hop'; return 'fail' }
        $id     = $re.Id
        $serial = $re.Serial       # NOW populated (managed mode) - usable for hop 2
        $mode0  = Get-ScannerHostMode $re
        if ($re.Serial) { $script:ScannerFinalSerial = $re.Serial }
        if ($re.Model)  { $script:ScannerFinalModel  = $re.Model }
    }

    # Hop 2 (or direct): -> USB OPOS.
    $st2 = Invoke-ScannerHostSwitchResilient -Obj $Obj -ScannerId $id `
             -HostCode $ScannerHostCodeOpos -HopLabel 'hop2 (OPOS)'
    $w2 = Wait-ScannerReenum -Obj $Obj -PreHopSerial $serial -PreHopId $id -PreHopMode $mode0
    $after = $w2.Scanner
    $script:ScannerHopLog += @{ label='after hop2 (OPOS)'; s=$after; status=$st2; seconds=$w2.Seconds }
    Write-Host "    re-enumerated in $($w2.Seconds)s"
    if ($after) {
        if ($after.Serial) { $script:ScannerFinalSerial = $after.Serial }
        if ($after.Model)  { $script:ScannerFinalModel  = $after.Model }
        $newMode = Get-ScannerHostMode $after
        if ($newMode -eq 'OPOS') { return 'ok' }                       # confirmed via type
        # NO "unknown + clean status = ok" arm. $ScannerTypeOpos is the one CONFIRMED type
        # string and it is per-MODE, not per-model: any Zebra unit sitting in USB-OPOS
        # enumerates as USBOPOS. So 'unknown' here is positive evidence the unit came back
        # in some OTHER mode - a scanner that accepts the ExecCommand ($st2 = 0) but
        # re-enumerates still in IBM Hand-held used to be reported ok, exit 0, and Alleaves
        # then could not open it. The unconfirmed strings are the HID-KB / IBM ones.
        Warn "    post-switch mode is '$newMode' (status $st2) - OPOS not confirmed"
        return 'fail'
    }
    # No re-enumeration seen after the OPOS switch: trust a clean status, else fail.
    if ($st2 -eq 0) { return 'ok' }
    return 'fail'
}

# ===========================================================================
# UNINSTALL (manifest-driven reverse, lifted from uninstall_alleaves.ps1)
# ===========================================================================
function Invoke-UninstallPhase {
    if (-not (Test-Path $ManifestPath)) {
        Fail "Manifest not found: $ManifestPath"
        Fail "Cannot proceed - run the installer first."
        return 1
    }
    # ConvertFrom-Json is NON-TERMINATING under $ErrorActionPreference='Continue', so a
    # manifest truncated by a kill mid-write left $man = $null and EVERY $man.<list> below
    # read as empty: the phase removed nothing, incremented nothing, and returned 0 - an
    # RMM marked the decommission clean with the whole product still installed. Save-Manifest
    # already refuses to clobber this file for the same reason (<manifest>.unreadable);
    # the reader needs the matching guard or that preservation buys nothing.
    $man = $null
    try { $man = Get-Content $ManifestPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop } catch {
        Fail "Manifest unreadable ($ManifestPath): $($_.Exception.Message)"
        Fail 'Refusing to run a no-op uninstall - fix or remove the manifest and re-run.'
        return 1
    }
    if (-not $man) { Fail "Manifest is empty: $ManifestPath"; return 1 }
    Write-Host "Manifest from $($man.timestamp) on $($man.machine) by $($man.user)" -ForegroundColor Cyan
    if ($DryRun) { Write-Host "DRY RUN - nothing will be removed" -ForegroundColor Yellow }

    # F12: track per-product uninstall failures so a hung NiceLabel, Chrome exit 20,
    # or MSI 1603 makes the phase exit non-zero instead of always returning 0 (which
    # let RMM mark a decommission "clean" with the product still installed).
    # Invoke-SilentUninstall returns $true under -DryRun, so DryRun never increments.
    $uninstallFailures = 0

    # 1. Remove files we placed
    Step 'Remove placed files'
    if (-not $man.filesPlaced -or @($man.filesPlaced).Count -eq 0) {
        Ok 'manifest records no placed files'
    } else {
        foreach ($f in $man.filesPlaced) {
            if (-not (Test-Path $f)) { Warn "$f already gone"; continue }
            if ($DryRun) { Dry "would delete $f"; continue }
            try { Remove-Item -Path $f -Force -ErrorAction Stop; Ok "deleted $f" }
            # Counted like every other reversal failure: a locked all-users 'Alleaves POS.lnk'
            # survives pointing at a Chrome step 2 is about to uninstall - and step 4e already
            # counts the PINNED copy of that same .lnk, so leaving this one silent was a
            # straight inconsistency.
            catch { Warn "could not delete ${f}: $($_.Exception.Message)"; $uninstallFailures++ }
        }
    }

    # 1b. Put back any pre-existing file step 1 just deleted (an OEM taskbar layout we
    #     overwrote at install). Must run AFTER the deletion loop above, which removes
    #     the path this restores to.
    foreach ($fr in @($man.filesReplaced)) {
        if (-not $fr.path -or -not $fr.backup) { continue }
        if ($DryRun) { Dry "would restore $($fr.path) from $($fr.backup)"; continue }
        if (-not (Test-Path -LiteralPath $fr.backup)) { Warn "backup $($fr.backup) is gone - cannot restore $($fr.path)"; continue }
        try {
            Move-Item -LiteralPath $fr.backup -Destination $fr.path -Force -ErrorAction Stop
            Ok "restored original $($fr.path)"
        # Counted too: this is the OEM taskbar layout. Un-restored, EVERY account created
        # after the uninstall still gets our pins, aimed at exes that are gone.
        } catch { Warn "could not restore $($fr.path): $($_.Exception.Message)"; $uninstallFailures++ }
    }

    # 2. Uninstall installed programs in REVERSE order
    Step 'Uninstall Alleaves stack'
    $allowedResults = if ($DryRun) { @('ok','dryrun') } else { @('ok') }
    $reverseInstalled = @($man.installed | Where-Object { $allowedResults -contains $_.result })
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

    # 2b. Sweep InstallShield_ orphan ARP entries + cache folders left by the
    # Zebra .iss (InstallScript) installs once their MSI products are removed.
    $hadZebraIss = $false
    foreach ($entry in $reverseInstalled) {
        if ($entry.method -eq 'iss-silent' -and $entry.displayNameMatch) {
            $hadZebraIss = $true
            Remove-InstallShieldOrphans -Pattern $entry.displayNameMatch
        }
    }
    # The CoreScanner driver MSI uninstall deletes the binary but can leave the
    # SCM service registration behind (status Stopped, ImagePath now missing).
    # Remove that orphan so -Uninstall leaves no trace. Guarded by "binary gone"
    # so we never delete a live CoreScanner some other software still owns.
    if ($hadZebraIss) {
        $cs = Get-Service CoreScanner -ErrorAction SilentlyContinue
        if ($cs) {
            $img = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\CoreScanner' -ErrorAction SilentlyContinue).ImagePath
            $bin = if ($img) { [Environment]::ExpandEnvironmentVariables(($img -replace '^"','' -replace '".*$','')) } else { $null }
            # The DryRun test sits INSIDE the "binary gone" guard. Outside it, the preview
            # announced the one destructive act this guard exists to prevent: on a box
            # where CoreScanner.exe is still present (another vendor's live install) the
            # real run correctly leaves the service alone, but -DryRun said it would
            # delete it.
            if (-not $bin -or -not (Test-Path $bin)) {
                if ($DryRun) {
                    Dry 'would delete orphaned CoreScanner service entry'
                } else {
                    if ($cs.Status -ne 'Stopped') { Stop-Service CoreScanner -Force -ErrorAction SilentlyContinue }
                    & "$env:SystemRoot\System32\sc.exe" delete CoreScanner | Out-Null
                    Ok 'removed orphaned CoreScanner service entry'
                }
            } else {
                Write-Host '  CoreScanner service binary still present - leaving service intact'
            }
        }
    }

    # 3. Bootstrap deps. Shared runtimes (VC++ - the only thing ever recorded here)
    # are reported but NEVER removed: other software on the terminal may depend on them.
    if ($man.dependencies) {
        Step 'Uninstall bootstrap dependencies'
        foreach ($dep in $man.dependencies) { Ok "keeping shared dependency: $($dep.name)" }
    }
    # 4. Reverse the post-install finishing (taskbar / default browser / UCPD).
    #    The placed XMLs + the staged finish script come out via filesPlaced above.

    # 4a. Remove the per-user logon task we created (stop it re-applying).
    foreach ($ct in @($man.scheduledTasksCreated)) {
        if (-not $ct.name) { continue }
        if ($DryRun) { Dry "would delete scheduled task: $($ct.name)"; continue }
        try { Unregister-ScheduledTask -TaskName $ct.name -Confirm:$false -ErrorAction Stop; Ok "deleted scheduled task: $($ct.name)" }
        catch { Warn "could not delete task $($ct.name): $($_.Exception.Message)"; $uninstallFailures++ }
    }

    # 4b. Restore tracked registry values (UCPD Start, LayoutXMLPath, ...).
    if (@($man.regValuesSet | Where-Object { $_ }).Count) {
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
                    if ($rv.name -eq '(default)') {
                        # Remove-ItemProperty CANNOT delete a key's default value: -Name
                        # '(default)' throws "Property (default) does not exist" and -Name ''
                        # fails parameter binding - even though New-ItemProperty -Name
                        # '(default)' creates it happily. Only a WRITABLE handle can; the
                        # $false arg means "don't throw if it's already gone" (idempotent).
                        try {
                            $sub = $rv.path -replace '(?i)^HKLM:\\', ''
                            $h = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($sub, $true)
                            # Report what actually happened: a null handle (access denied,
                            # or the key is already gone) is NOT a removal, and logging one
                            # hides the phantom device this deletion exists to retire.
                            if ($h) {
                                try { $h.DeleteValue('', $false) } finally { $h.Close() }
                                Ok "removed $($rv.path)\(default)"
                            } else {
                                Write-Host "  $($rv.path) not open for write (already gone?) - (default) left alone"
                            }
                        # Counted HERE: this inner catch intercepts before the outer one that
                        # does the counting, and OpenSubKey throws SecurityException (it does
                        # NOT return $null) when write access is denied - so the one value
                        # whose survival leaves a phantom device was the only one uncounted.
                        } catch { Warn "could not remove $($rv.path)\(default): $($_.Exception.Message)"; $uninstallFailures++ }
                    } else {
                        # -Stop, not -SilentlyContinue: the Ok below is unconditional, so a
                        # swallowed access-denied reported a removal that never happened -
                        # the same false report the (default) arm above refuses to make.
                        Remove-ItemProperty -Path $rv.path -Name $rv.name -Force -ErrorAction Stop
                        Ok "removed $($rv.path)\$($rv.name)"
                    }
                } else {
                    $val = switch ($rv.type) {
                        'DWord'  { [int]$rv.prev }
                        'QWord'  { [int64]$rv.prev }
                        'Binary' { [Convert]::FromBase64String($rv.prev) }
                        default  { [string]$rv.prev }
                    }
                    if (-not (Test-Path $rv.path)) { New-Item -Path $rv.path -Force | Out-Null }
                    New-ItemProperty -Path $rv.path -Name $rv.name -Value $val -PropertyType $rv.type -Force | Out-Null
                    Ok "restored $($rv.path)\$($rv.name) = $($rv.prev)"
                }
            } catch { Warn "could not restore $($rv.path)\$($rv.name): $($_.Exception.Message)"; $uninstallFailures++ }
        }
    }

    # 4b-ii. Remove registry KEYS we created (the values above are gone by now).
    # Restoring values is not enough: an empty ...\ServiceOPOS\POSPrinter\<name> key is a
    # PHANTOM DEVICE that OPOS enumeration still lists and that fails on open. Measured on
    # the rig: the POS-X vendor uninstaller removes its files, ARP entry and CCO
    # registrations but LEAVES every OPOS device entry behind, so this is load-bearing.
    #
    # DEEPEST-FIRST so children go before parents, and guarded on SUBKEYS ONLY:
    #   * value count is deliberately NOT checked - a key in regKeysCreated did not exist
    #     before this run, so every value in it is ours by construction. (It would also be
    #     wrong: a key whose only value is the (default) ProgID reports ValueCount=1, so an
    #     "only if empty" test would never fire on exactly the key we must remove.)
    #   * a SUBKEY, though, may be a co-installed vendor device that landed under us - so
    #     that stops the removal. Non-recursive Remove-Item for the same reason.
    if (@($man.regKeysCreated | Where-Object { $_ }).Count) {
        Step 'Remove created registry keys'
        $ordered = @($man.regKeysCreated | Where-Object { $_ } | Sort-Object -Property @{ Expression = { ($_ -split '\\').Count } } -Descending)
        foreach ($rk in $ordered) {
            if (-not (Test-Path $rk)) { Ok "already gone: $rk"; continue }
            if ($DryRun) { Dry "would remove registry key: $rk"; continue }
            try {
                if ((Get-Item $rk).SubKeyCount -gt 0) { Warn "keeping $rk (has subkeys - another device lives under it)"; continue }
                Remove-Item -Path $rk -Force -ErrorAction Stop
                Ok "removed registry key: $rk"
            } catch { Warn "could not remove key ${rk}: $($_.Exception.Message)"; $uninstallFailures++ }
        }
    }

    # 4c. Re-enable scheduled tasks we disabled (UCPD velocity).
    foreach ($dt in @($man.scheduledTasksDisabled)) {
        if (-not $dt.name) { continue }
        # F18: only re-enable tasks that were enabled when we disabled them. Old
        # manifests have no prevState -> treat as enabled (the function only ever
        # recorded tasks it actually disabled, so this is backward-safe).
        $wasEnabled = (-not $dt.PSObject.Properties['prevState']) -or ($dt.prevState -and $dt.prevState -ne 'Disabled')
        if (-not $wasEnabled) { Ok "task $($dt.name) was disabled before install - leaving disabled"; continue }
        if ($DryRun) { Dry "would re-enable scheduled task: $($dt.path)$($dt.name)"; continue }
        try { Enable-ScheduledTask -TaskPath $dt.path -TaskName $dt.name -ErrorAction Stop | Out-Null; Ok "re-enabled scheduled task: $($dt.name)" }
        # Counted: leaving it silent reports a clean decommission on a machine where a
        # Microsoft-shipped task (UCPD velocity) stays permanently disabled by us.
        catch { Warn "could not re-enable task $($dt.name): $($_.Exception.Message)"; $uninstallFailures++ }
    }

    # 4d. Restore the original taskbar pins for any LOADED user hive (profiles not
    #     loaded now are cosmetic-only - removing the XML won't re-pin Edge; OK).
    foreach ($tb in @($man.taskbandBackups)) {
        if (-not $tb.sid) { continue }
        $hive = "Registry::HKEY_USERS\$($tb.sid)"
        $p    = "$hive\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband"
        if ($DryRun) { Dry "would restore Taskband for sid $($tb.sid)"; continue }
        if (-not (Test-Path $hive)) { Warn "sid $($tb.sid) hive not loaded - taskbar restore skipped (cosmetic)"; continue }
        try {
            if (-not (Test-Path $p)) { New-Item -Path $p -Force | Out-Null }
            if ($tb.favorites)        { New-ItemProperty -Path $p -Name 'Favorites'        -Value ([Convert]::FromBase64String($tb.favorites))        -PropertyType Binary -Force | Out-Null }
            if ($tb.favoritesResolve) { New-ItemProperty -Path $p -Name 'FavoritesResolve' -Value ([Convert]::FromBase64String($tb.favoritesResolve)) -PropertyType Binary -Force | Out-Null }
            Remove-ItemProperty -Path "$hive\Software\AlleavesAuto" -Name 'TaskbarApplied' -ErrorAction SilentlyContinue
            Ok "restored Taskband for sid $($tb.sid) (sign out/in to see the original pins)"
        } catch { Warn "could not restore Taskband for $($tb.sid): $($_.Exception.Message)" }
    }

    # 4e. Drop OUR pins from each user's pinned-taskbar folder. Explorer COPIES the
    #     .lnk there when it applies the layout, so step 1's filesPlaced sweep (which
    #     only removes the all-users Start Menu source) strands a pin pointing at a
    #     deleted exe - measured on the rig. Exact name match against $TaskbarPinNames
    #     only, so a pin another vendor created is never touched.
    foreach ($u in (Get-TargetUserProfiles)) {
        foreach ($n in $TaskbarPinNames) {
            $pin = Join-Path $u.Profile (Join-Path $UserPinnedRelDir "$n.lnk")
            if (-not (Test-Path $pin)) { continue }
            if ($DryRun) { Dry "would remove pinned shortcut: $pin"; continue }
            try { Remove-Item $pin -Force -ErrorAction Stop; Ok "removed pinned shortcut: $pin" }
            catch { Warn "could not remove pinned shortcut '$pin': $($_.Exception.Message)"; $uninstallFailures++ }
        }
    }

    # computerRenamed is intentionally NOT reverted (restoring a factory-random name
    # is pointless - same policy as the TeamViewer removal).
    if ($man.computerRenamed -and $man.computerRenamed.to) {
        Write-Host "  note: computer rename ('$($man.computerRenamed.from)' -> '$($man.computerRenamed.to)') is NOT reverted by design." -ForegroundColor DarkGray
    }

    # TeamViewer intentionally NOT restored.

    # accountCreated is intentionally NOT reverted. The terminal is signed into that
    # account right now, and its Documents folder holds the .nlbl master list. Deleting
    # it here would strand the box mid-uninstall; removing it is a deliberate manual act.
    foreach ($ac in @($man.accountCreated)) {
        if (-not $ac -or -not $ac.name) { continue }
        $how = if ($ac.created) { 'created' } else { 'promoted to administrator' }
        Write-Host "  note: local account '$($ac.name)' ($how by the installer) is NOT removed by design." -ForegroundColor DarkGray
    }

    # F12: fail the phase if any product failed to uninstall (dispatch propagates a
    # non-zero rc). DryRun never increments (Invoke-SilentUninstall returns $true).
    if ($uninstallFailures -gt 0) { Fail "$uninstallFailures reversal(s) failed (products, files, registry, tasks or pins)"; return 1 }
    return 0
}

# ===========================================================================
# Receipt printer: OPOS device registration. Per-brand, driven by $PrinterBrands.
#
# Neither vendor ships OPOS automation, so writing the registry ourselves is not a
# shortcut - it is the only path:
#   POS-X  the installer ("OLE POS Setup 2.84") stages the files and registers the
#          COM objects; SetupPOS.exe is only a GUI over the registry.
#   Star   futurePRNT's manual (S4.1.1) states verbatim that the Configuration
#          Utility's XML export/import EXCLUDES OPOS (as it does JavaPOS, serial
#          ports and Star Cloud). There is no SetupPOS.exe equivalent - Star's tool
#          is TSP100ControlPanel.exe, GUI-only, with no /add switch and no importable
#          XML. JavaPOS gets a jpos.xml generator; OPOS does not.
#
# Everything in the value tables below was CAPTURED from a real vendor-tool run and
# diffed; NONE of it is authored. The OPOS spec mandates only (default)=ProgID - the
# rest is vendor-private, and deriving POS-X's from Thermal.inf would have been subtly
# wrong (Description and PortShare appear in neither section of it).
#
# HOW MANY DEVICES IS PER BRAND, not a global rule:
#   POS-X  ONE device. Its cash drawer has no entry of its own (dropped 2026-08-12) -
#          it hangs off the printer's RJ-11, Standard.CashDrawer.SOU resolved to the
#          printer's own POSPrinterSOU.dll anyway, so a second logical device bought
#          nothing. The drawer follows the printer via DrawerOpen=1 below
#          ("Open CashDrawer" = "Follow Printer").
#   Star   TWO devices. futurePRNT has no equivalent of that flag: its drawer is a
#          separate CashDrawer OPOS device with its own LDN and its own settings
#          (drawer number, pulse width, polarity). That is why the device ARRAY exists
#          again after the 2026-08-12 flattening - there genuinely are two devices.
#
# Star's LDNs are the "Logical Device Name" its utility creates under Configure, NOT
# the device name Add New creates (which stays at the vendor default). Register the
# common OPOS CCO, not Star's own CO: the vendor manual recommends it, and the repo
# already installs POS for .NET, whose legacy bridge wraps a registered CO/SO.
#
# WOW6432Node is explicit and correct: the CCOs and service objects are 32-bit, and
# the .bat forces the 64-bit PowerShell host, whose registry provider takes the path
# literally (no redirection).
#
# Contrast with Set-ScannerOpos: that one is ~350 lines because flipping a scanner's
# host mode is a hardware command over RSM with re-enumeration polling. This is pure
# registry - no COM, no polling, no hardware - and works with nothing plugged in.
# ===========================================================================
$PrinterOposRoot = 'HKLM:\SOFTWARE\WOW6432Node\OLEforRetail\ServiceOPOS'

# Captured verbatim 2026-08-10 from OLE POS Setup 2.84 on the rig. ONE device - the
# drawer's entry was dropped 2026-08-12 (see above), so there is nothing to iterate.
$PosXPrinterStrings = [ordered]@{
    '(default)'='RecPrinter.POSPrinter.SOU'; ADKConfig='Thermal1.0'
    Description='OLE POS Printer OPOS Service Object'
    DeviceDesc='Thermal POS Printer (USB)'; DeviceName='ThermalU'
    Port='USB'; Version='1.0'
    BaudrateSel=''; BitLengthSel=''; HandShakeSel=''; IP=''; ParitySel=''; StopSel=''; XonXoffSel=''
}
$PosXPrinterDWords = [ordered]@{
    # DrawerOpen=1 is SetupPOS's "Open CashDrawer" = "Follow Printer" - the cash
    # drawer's whole configuration now that it has no device entry of its own.
    # CAPTURED 2026-08-12, not authored: driving the real SetupPOS combo from
    # 'CashDrawer' (0) to 'Follow Printer' (1) and diffing HKLM\...\OLEforRetail
    # changed exactly this one value. Thermal.inf's [UOPTION] default is 0.
    Baudrate=0; BitLength=0; DrawerOpen=1; HandShake=0; IdleSleep=10; InputBuf=0
    InputSleep=10; OutputBuf=1024; Parity=0; PortShare=0; Stop=0; Timeout=1000
    USBSerialNumber=0; XonXoff=0
}

# Star TSP100 (futurePRNT 7.6.0): NOT CAPTURED YET. Deliberately empty, not guessed -
# Star publishes no list of what its Configuration Utility writes, and the POS-X history
# is the warning: deriving values from the vendor .inf instead of a real registry diff
# produced a subtly wrong key. Fill these from the bench capture (before/after
# Collect-PrinterFingerprint.ps1 -SnapshotOnly, diffed; procedure and results table in
# docs/PRINTER_OPOS_FIELD_RESULTS.md), then set each device's Type/ProgId below.
# An EMPTY Strings OR DWords table is what Set-PrinterOpos's not-captured guard tests
# (both, since filling one of the four and forgetting the other is a one-line omission),
# so leaving these blank makes a StarTSP100 run exit 7 with result='not-captured' instead
# of writing a valueless key and reporting success. Do not "stub" them with plausible values.
$StarPrinterStrings = [ordered]@{}   # TODO[rig]
$StarPrinterDWords  = [ordered]@{}   # TODO[rig]
$StarDrawerStrings  = [ordered]@{}   # TODO[rig]
$StarDrawerDWords   = [ordered]@{}   # TODO[rig]

# The brand table. RowName is the $Installers/$DriveFiles row this brand needs (step 0b
# feeds it to -SkipPrograms for every brand the tech did NOT pick, so a POS-X terminal
# never downloads Star's 471 MB and vice versa) - it MUST match that row's Name/Label.
# ArpPattern is the driver's ARP DisplayName, checked before any entry is written so we
# never register a device pointing at a DLL that isn't there.
#
# A device has NO Type/ProgId field. They used to sit here and duplicate
# Strings['DeviceName'] and Strings['(default)'] - never written to the registry, never
# verified by the readback, and free to drift from the values that ARE written. Star was
# already drifted by construction (both ''), so filling only $StarPrinterStrings after the
# bench capture would have shipped "OPOS POSPrinter: POS01_Printer -> " on the console and
# progId=$null in the manifest, with Remove-StalePrinterOpos (which keys on
# logicalName/deviceClass) hiding the mistake. One source: the Strings table.
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
            # TODO[rig]: both tables are empty until the bench capture; the $uncaptured
            # guard in Set-PrinterOpos refuses to write a device from an empty table.
            @{ Class='POSPrinter'; Suffix='_Printer'
               Strings=$StarPrinterStrings; DWords=$StarPrinterDWords }
            @{ Class='CashDrawer'; Suffix='_Drawer'
               Strings=$StarDrawerStrings;  DWords=$StarDrawerDWords }
        )
    }
}

# The LDN prefix is the terminal's POS name. Deliberately NOT $env:COMPUTERNAME: the
# rename only takes effect on the post-install reboot, so the env var is stale for the
# whole run. Prefer the name this run asked for; fall back when -SkipRename / no name.
# 'applied' is REQUIRED: Invoke-ComputerRename's catch records the requested name with
# applied=$false, so a FAILED rename would otherwise name the devices after a name this
# terminal never gets - and Alleaves is configured against these exact names. 'dryRun'
# counts as applied: a -DryRun rename never applies anything, so without it the PREVIEW
# would advertise different device names than the real run creates.
function Get-PosNamePrefix {
    if ($Manifest -and $Manifest.computerRenamed -and $Manifest.computerRenamed.to -and
        ($Manifest.computerRenamed.applied -or $Manifest.computerRenamed.dryRun)) {
        return $Manifest.computerRenamed.to
    }
    # The fallback is the PENDING name, not $env:COMPUTERNAME (= the ACTIVE name). They
    # differ between Rename-Computer and its reboot - exactly the window a standalone
    # -PrinterConfigOnly run lands in when it is used to recover a failed printer step
    # (exit 7's own advice). With the env var, that run names the devices after the name
    # this terminal is LOSING and Remove-StalePrinterOpos then deletes the correct ones.
    # This key holds the name after next boot and equals the active name when nothing is
    # pending, so it is strictly better on both paths.
    $pending = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' `
                -Name ComputerName -ErrorAction SilentlyContinue).ComputerName
    if ($pending) { return $pending }
    return $env:COMPUTERNAME
}

# Brand prompt. Its own function because BOTH the install dispatch and the standalone
# -PrinterConfigOnly branch need it. Answered ONCE and cached: the install path asks up
# front (step 0, beside the rename prompt) so the tech can walk away for the long
# download/install - asking at step 5b would stall the run 20+ minutes in.
#
# The Read-Host is wrapped for the same reason the rename prompt is (F14): on a headless
# / RMM run it throws, and an escaping throw would land in the top-level catch and turn a
# clean install into exit 1. Interactivity is tested the SAME way as the rename
# (UserInteractive + ALLEAVES_NOPAUSE); the catch is what actually makes it safe, since
# `powershell -NonInteractive` still reports UserInteractive=$true.
function Resolve-PrinterBrand {
    if ($script:PrinterBrandResolved) { return $script:PrinterBrandResolved }
    $brand = 'POS-X'   # the historical default; every degraded path lands here
    if ($PrinterBrand) {
        $brand = $PrinterBrand
    } elseif ([Environment]::UserInteractive -and -not $env:ALLEAVES_NOPAUSE) {
        try {
            Write-Host ''
            Write-Host '  Receipt printer brand:' -ForegroundColor Cyan
            Write-Host '    1) POS-X   (default)'
            Write-Host '    2) None - no receipt printer (skips the driver install too)'
            Write-Host '    3) Star TSP100 (futurePRNT)'
            $sel = Read-Host '  Select 1-3 (Enter for POS-X)'
            # The WORDS are accepted alongside the digits: README documents -PrinterBrand
            # None, so typing "None" here is the natural mistake - and with no default
            # case it used to fall through to POS-X, installing the driver and registering
            # a phantom <POSname>_Printer on a terminal that has no printer at all.
            switch -Regex ("$sel".Trim()) {
                '^$'            { }                      # Enter = the POS-X default
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

# Drop device entries WE created that this run no longer registers. Two cases, one test:
# a rename (the advertised "re-run -PrinterConfigOnly to fix the names" would otherwise
# leave <OLDNAME>_Printer behind and the terminal advertises two), and a device RETIRED
# from the device table - which is how the 2026-08-12 cash-drawer removal reaches
# terminals already deployed with a <POSname>_Drawer entry. The old prefix-match test
# ("-like $Prefix_*") could not do the second: on the same terminal the retired drawer
# matched this run's own prefix and was stranded as a phantom device forever.
# Only names recorded in the PRIOR manifest are touched - never a device some other
# vendor or a manual SetupPOS run created. The stale rows (printerConfigured, plus that
# key's regValuesSet / regKeysCreated) are left to merge forward, so printerConfigured
# ACCUMULATES old names and (none:*) skips run after run; on uninstall every one of them
# resolves to a harmless "already gone". Pruning them costs more than it buys.
# ponytail: the emptied CLASS key (ServiceOPOS\CashDrawer) is left in place - it
# enumerates no devices, and -Uninstall still removes it via regKeysCreated.
function Remove-StalePrinterOpos {
    param(
        # The names that ACTUALLY registered this run - a WHITELIST, so anything the prior
        # manifest recorded and this list omits gets deleted. Mandatory on purpose: the old
        # default rebuilt the single expected LDN from a prefix + suffix, which stopped
        # being expressible once a brand can register more than one device, and a caller
        # that forgot the parameter would have silently retired every device but one. The
        # -DryRun preview passes the names it WOULD register; the real path passes only
        # what it verified, and skips the call entirely on a partial failure (see
        # Set-PrinterOpos) so a half-failed run never retires a device it failed to replace.
        [Parameter(Mandatory)][string[]]$Registered
    )
    # Read through Get-PriorManifest rather than a private copy of the same read: that one
    # is -ErrorAction Stop on both cmdlets and Warns. This one caught nothing on a LOCKED
    # manifest (Get-Content is non-terminating under 'Continue') and swallowed the Warn on a
    # malformed one, so an unreadable manifest silently meant "no stale devices" - after a
    # rename the terminal advertised TWO OPOS printers and Alleaves could open the dead one.
    # Safe here: this step runs BEFORE Save-Manifest, so the memoised copy is still an
    # EARLIER run's, which is exactly what "stale" means.
    $prior = Get-PriorManifest
    $keep = @($Registered)
    foreach ($p in @($prior.printerConfigured)) {
        if (-not $p.logicalName -or -not $p.deviceClass) { continue }          # skips the (none:*) rows
        if ($keep -contains $p.logicalName) { continue }                        # this run's own names
        $stale = "$PrinterOposRoot\$($p.deviceClass)\$($p.logicalName)"
        if (-not (Test-Path $stale)) { continue }
        if ($DryRun) { Dry "would remove stale OPOS device: $($p.logicalName)"; continue }
        # Same guard the uninstall path applies: a SUBKEY under a device may be a
        # co-installed vendor device that landed under us, and a non-recursive
        # Remove-Item on a key with children raises ShouldContinue - which prompts on an
        # interactive host and THROWS on an RMM one, so the stale device would silently
        # survive the very function whose job is to remove it.
        try {
            if ((Get-Item $stale -ErrorAction Stop).SubKeyCount -gt 0) {
                Warn "stale OPOS device '$($p.logicalName)' has subkeys - left in place (may hold another vendor's device)"
                continue
            }
            Remove-Item -Path $stale -Force -ErrorAction Stop
            Ok "removed stale OPOS device: $($p.logicalName)"
        } catch { Warn "could not remove stale OPOS device '$($p.logicalName)': $($_.Exception.Message)" }
    }
}

function Set-PrinterOpos {
    if ($SkipPrinterConfig) {
        Step 'Register receipt printer (OPOS)'
        Ok 'printer OPOS skipped (-SkipPrinterConfig)'
        return
    }

    # Resolve BEFORE the banner so the step names the brand it is actually doing.
    $brand = Resolve-PrinterBrand
    Step "Register $brand receipt printer (OPOS)"

    # Deliberate "this terminal has no receipt printer", recorded as its own result so the
    # manifest shows a choice the tech made rather than a failure. Returns BEFORE
    # Remove-StalePrinterOpos: None means skip, not retro-uninstall a prior run's entries
    # (-Uninstall is what removes those).
    if ($brand -eq 'None') {
        Ok 'no receipt printer selected - skipping OPOS registration'
        $Manifest.printerConfigured += @{
            logicalName='(none:None)'; deviceClass=$null; deviceType=$null
            progId=$null; brand=$brand; result='skipped'; removable=$true
        }
        return
    }

    $brandDef = $PrinterBrands[$brand]
    if (-not $brandDef) {
        # Unreachable via the param ValidateSet or the prompt (whose default arm falls back
        # to POS-X), so this only fires if a brand is added to one and not the other.
        Fail "no device table for printer brand '$brand' - this is a build error, not a terminal fault"
        $Manifest.printerConfigured += @{
            logicalName='(none:unknown-brand)'; deviceClass=$null; deviceType=$null
            progId=$null; brand=$brand; result='fail: unknown brand'; removable=$true
        }
        $script:PrinterConfigFailed = $true
        return
    }

    # The entries point at the vendor's service objects; writing them with the driver
    # absent registers a PHANTOM device aimed at a DLL that isn't there - Alleaves
    # then enumerates it and fails to open. Benign skip (exit 0), same shape as the
    # scanner step's "no scanner attached".
    # Checked via ARP, NOT the ProgID: the vendor uninstaller leaves the whole
    # ProgID -> CLSID -> InprocServer32 chain behind (measured), so a ProgID test says
    # "installed" on a box where the DLL is long gone. The ARP entry does go.
    # Skipped only for a DryRun of the FULL install, where the driver is legitimately
    # absent because the install loop that would have placed it was itself simulated.
    # Under -DryRun -PrinterConfigOnly nothing installs anything, so a real run would
    # refuse here - and a preview that "registers" devices the real run would decline is
    # a preview of the wrong run.
    if (-not ($DryRun -and -not $PrinterConfigOnly) -and -not (Find-InstalledProducts -Pattern $brandDef.ArpPattern)) {
        Warn "$brand printer driver ('$($brandDef.RowName)') is not installed - skipping OPOS registration."
        Warn 'Install it (full run, or without -SkipPrograms), then re-run with -PrinterConfigOnly.'
        $Manifest.printerConfigured += @{
            logicalName="(none:no-driver)"; deviceClass=$null; deviceType=$null
            progId=$null; brand=$brand; result='no-driver'; removable=$true
        }
        return
    }

    # A brand whose value tables have not been captured yet. Without this the write loops
    # below iterate ZERO times, the readback loops verify nothing, and the step reports
    # 'ok' after creating an empty device key - a phantom device plus a false success,
    # which is strictly worse than doing nothing. Loud failure (exit 7) instead, so a
    # build shipped ahead of the capture cannot be mistaken for a working one.
    # BOTH tables, not just Strings: the capture fills four of them, and a filled
    # $StarPrinterStrings beside a still-empty $StarPrinterDWords (a one-line omission)
    # passed the Strings-only test - the DWord write loop AND its readback loop both
    # iterated zero times, so the step reported 'ok' on a device with no pulse width, no
    # drawer number and no port settings. The same phantom, through the half of the tables
    # the guard was not looking at.
    $uncaptured = @($brandDef.Devices | Where-Object { $_.Strings.Count -eq 0 -or $_.DWords.Count -eq 0 })
    if ($uncaptured) {
        Warn "$brand OPOS values have not been captured yet ($(($uncaptured | ForEach-Object { $_.Class }) -join ', '))."
        Warn 'Run the bench capture in docs/PRINTER_OPOS_FIELD_RESULTS.md, fill the tables, then re-run with -PrinterConfigOnly.'
        # The ROW is recorded under -DryRun too (only the failure flag is not): without it
        # a dry run of an uncaptured brand left printerConfigured empty, indistinguishable
        # from a step that was never reached - while the real run exits 7. Every other bail
        # in this function records its result under -DryRun.
        $Manifest.printerConfigured += @{
            logicalName='(none:not-captured)'; deviceClass=$null; deviceType=$null
            progId=$null; brand=$brand; result='not-captured'; removable=$true
        }
        if (-not $DryRun) { $script:PrinterConfigFailed = $true }
        return
    }

    $prefix = Get-PosNamePrefix

    # DryRun BEFORE any registry touch. Set-TrackedRegValue guards internally too, but
    # returning here also keeps the manifest entries honest (result='dryrun').
    if ($DryRun) {
        # Pass the names this run WOULD register, so the preview retires exactly what the
        # real run would retire (Remove-StalePrinterOpos only reports under -DryRun).
        Remove-StalePrinterOpos -Registered @($brandDef.Devices | ForEach-Object { "$prefix$($_.Suffix)" })
        foreach ($dev in $brandDef.Devices) {
            $ldn = "$prefix$($dev.Suffix)"
            Dry "would register OPOS $($dev.Class) '$ldn' -> $($dev.Strings['(default)']) ($($dev.Strings.Count + $dev.DWords.Count) values)"
            $Manifest.printerConfigured += @{
                logicalName=$ldn; deviceClass=$dev.Class; deviceType=$dev.Strings['DeviceName']
                progId=$dev.Strings['(default)']; brand=$brand; result='dryrun'; removable=$true
            }
        }
        return
    }

    # One pass per device. Each gets its OWN try/catch: a shared one would let the
    # printer's failure skip the drawer entirely, so a terminal with a bad printer key
    # would also silently lose its drawer.
    $verified = @()
    $allOk    = $true
    foreach ($dev in $brandDef.Devices) {
        $ldn   = "$prefix$($dev.Suffix)"
        $key   = "$PrinterOposRoot\$($dev.Class)\$ldn"
        # Reported from the values actually being written, so the console line and the
        # manifest cannot disagree with the registry.
        $progId = $dev.Strings['(default)']
        $entry = @{
            logicalName=$ldn; deviceClass=$dev.Class; deviceType=$dev.Strings['DeviceName']
            progId=$progId; brand=$brand; removable=$true
        }
        try {
            foreach ($n in $dev.Strings.Keys) { Set-TrackedRegValue -Path $key -Name $n -Value $dev.Strings[$n] -Type String }
            foreach ($n in $dev.DWords.Keys)  { Set-TrackedRegValue -Path $key -Name $n -Value ([int]$dev.DWords[$n]) -Type DWord }

            # Verify by reading EVERY value back, by name, against the same tables that
            # were just written. This works with no hardware attached, which is why
            # exit 7 is meaningful on a printer-less bench run.
            # Per-name, NOT a value COUNT: $ErrorActionPreference is 'Continue', so a
            # failed New-ItemProperty is non-terminating and Set-TrackedRegValue records
            # a value it never wrote - and on a key that ALREADY holds the full set (any
            # re-run, or a terminal deployed before this table changed) the count is
            # already satisfied, so it can never catch that. The migration this misses is
            # the real one: DrawerOpen 0 -> 1 silently not applied, reported 'ok', and the
            # cash drawer never kicks. (default) is a Strings member, so it is covered
            # here too - by content, as the OPOS spec requires.
            $k = Get-Item $key -ErrorAction Stop
            foreach ($n in $dev.Strings.Keys) {
                # '(default)' is an ALIAS the *ItemProperty cmdlets accept for the key's default
                # value, whose real name is the empty string. GetValue does NOT accept it - it
                # looks for a value literally called "(default)", finds none, and returns $null,
                # so this loop failed on the very first key every run: the 28 values were all
                # written correctly yet the step reported 'fail' and exit 7, forever. Mirror
                # image of the trap the uninstall path documents for Remove-ItemProperty.
                # $null (value ABSENT) is tested separately from its string form. Seven of
                # the fourteen POS-X strings are legitimately '', and "$null" is also '' -
                # so the plain -cne compared '' against '' and PASSED for a value that was
                # never written at all. That blinded the readback for half the table, which
                # is precisely the half a failed non-terminating New-ItemProperty leaves
                # behind. Mirrors the DWord loop below.
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
            # This flag, NOT the config-only branch's "did anything change" floor, is what
            # produces exit 7 on a PARTIAL failure: with one device of two written, that
            # floor sees a change and stays quiet.
            $script:PrinterConfigFailed = $true
            $allOk = $false
        }
        $Manifest.printerConfigured += $entry
    }

    # Retire stale devices only AFTER every replacement verifies. Two reasons to be
    # all-or-nothing here. Deleting first means a failed write (exit 7, "re-run with
    # -PrinterConfigOnly") leaves the terminal with NO OPOS printer where it had a working
    # one under the old name a second earlier - and the delete has no rollback. And
    # -Registered is a WHITELIST, so passing a partial list after one device failed would
    # delete the prior run's copy of the very device that just failed to be replaced.
    if ($allOk -and $verified.Count) { Remove-StalePrinterOpos -Registered $verified }
    elseif ($verified.Count)         { Warn 'some devices failed - leaving existing OPOS device entries alone' }
    else                             { Warn 'nothing registered - leaving any existing OPOS device entries alone' }

    if ($verified.Count) {
        Write-Host "  Alleaves must be configured to open $(if ($verified.Count -gt 1) { 'these exact logical names' } else { 'this exact logical name' }): $($verified -join ', ')" -ForegroundColor Yellow
    }
}

# ---------------------------------------------------------------------------
# Fresh install-manifest skeleton. Shared by the full-install and the
# -ScannerConfigOnly dispatch paths so the key set never drifts between them
# (Save-Manifest merges a prior on-disk manifest forward, so a scanner-only run
# preserves the full install's records and only updates scannerConfigured).
# ---------------------------------------------------------------------------
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
        # Files that ALREADY EXISTED and were overwritten (the OEM taskbar layouts). They
        # are in filesPlaced too, so uninstall deletes them; this list puts the original
        # back afterwards. Without it, uninstalling strips an OEM's Default-profile
        # taskbar and every account created later gets Microsoft's stock layout instead.
        filesReplaced     = @()   # { path; backup } - uninstall restores backup -> path
        # Post-install finishing (rename / taskbar / default browser):
        computerRenamed        = @{}   # { from=...; to=... } - recorded only, NOT reverted
        regValuesSet           = @()   # { hive; path; name; type; value; prev } - uninstall restores prev (or removes if prev=$null)
        regKeysCreated         = @()   # registry KEYS we created (plain path strings) - uninstall removes them deepest-first if empty
        scheduledTasksCreated  = @()   # task names we created  - uninstall deletes them
        scheduledTasksDisabled = @()   # task names we disabled - uninstall re-enables them
        taskbandBackups        = @()   # { sid; profile; favorites(b64); favoritesResolve(b64) } - uninstall restores
        # Final step: connected Zebra scanner(s) flipped to USB-OPOS. Kept OUT of
        # 'installed' so a benign 'no-scanner' run doesn't trip the failure tally.
        # removable=$false: hardware-external state, recorded only (not reverted).
        scannerConfigured      = @()   # { serial; model; hostBefore; target='USB-OPOS'; result; removable=$false }
        # OPOS device entries (receipt printer). ONE ROW PER DEVICE, so a brand with a
        # separate cash drawer (Star) contributes two. Unlike the scanner this IS
        # reversible - it is pure registry - so removable=$true and the keys come back
        # out via regKeysCreated / regValuesSet.
        printerConfigured      = @()   # { logicalName; deviceClass; deviceType; progId; brand; result; removable=$true }
        # The account swap (see Invoke-AccountSwapOffer). RECORD ONLY, removable=$false,
        # same class as computerRenamed / teamViewerRemoved / scannerConfigured.
        # -Uninstall must NEVER delete this account: the terminal is signed into it, and
        # its Documents folder holds the .nlbl master list Get-TargetUserProfiles copied
        # there. The autologon is absent here on purpose - it is armed and fully undone
        # inside one swap cycle, so "restoring" it on a later uninstall would be wrong.
        # Seeded from the swap that got us here, so BOTH call sites record it without
        # each having to remember to. Save-Manifest then merges any prior run's row.
        accountCreated         = @(if ($script:AccountSwapDone) { $script:AccountSwapDone })
        # The account precheck was failed and waived (-IgnoreAccountCheck, or a "y" at
        # the continue-anyway prompt). RECORD ONLY, removable=$false - there is nothing
        # to reverse, but the whole precheck runs before Start-Transcript, so without
        # this row nothing on disk says the terminal was installed over a bad verdict.
        accountCheckOverride   = @(if ($script:AccountCheckOverride) { $script:AccountCheckOverride })
    }
}

# ===========================================================================
# DISPATCH
# ===========================================================================
$exitCode = 0
$RunLog = $null
try {
    if ($ScannerConfigOnly -or $PrinterConfigOnly) {
        # Single-step mode: run ONLY the final USB-OPOS scanner switch (-ScannerConfigOnly)
        # or ONLY the OPOS printer registration (-PrinterConfigOnly) - no downloads, no
        # installs, no finishing. For iterating the switch on the rig, (re)configuring a
        # scanner that was unplugged during the main install, or re-applying the printer
        # entries / fixing them after a rename (the vendor driver must already be
        # installed - this step only writes registry entries pointing at its service
        # objects). Still admin (COM + permanent switch / HKLM); -DryRun works
        # non-elevated. Save-Manifest MERGES onto any prior install_manifest.json, so only
        # the one step's rows are updated and the rest of the install is preserved.
        # No Invoke-ComputerRename here, so computerRenamed is empty and Get-PosNamePrefix
        # falls back to the CURRENT name - the right answer for a standalone run: by now
        # the rename reboot has already happened. Entries left under a PREVIOUS name are
        # removed by Remove-StalePrinterOpos inside.
        $scan   = [bool]$ScannerConfigOnly
        $RunLog = Join-Path $LogDir ("{0}_{1:yyyyMMdd_HHmmss}.log" -f $(if ($scan) { 'scannercfg' } else { 'printercfg' }), (Get-Date))
        Start-Transcript -Path $RunLog -Append | Out-Null
        Write-Host $(if ($scan) { 'Alleaves SCANNER-CONFIG ONLY (USB-OPOS)' } else { 'Alleaves PRINTER-CONFIG ONLY (OPOS)' }) -ForegroundColor Cyan
        Write-Host "WorkDir:  $WorkDir"
        Write-Host "Manifest: $ManifestPath"
        if ($DryRun) { Write-Host "DRY RUN - no system changes will be made" -ForegroundColor Yellow }

        $Manifest = New-InstallManifest
        if ($scan) { Set-ScannerOpos } else { Set-PrinterOpos }

        # A single-step run that changed NOTHING is not a success, even though every skip
        # inside these two steps is benign in a full install (no scanner attached during
        # the bench build is normal; a driver that failed to install already trips exit 1
        # there). Here the one requested step didn't happen - and these modes exist
        # precisely because the scanner IS attached / the driver IS installed now - so
        # exit 0 would tell RMM the remediation worked. Covers the scanner's 'no-scanner'
        # and missing-Interop/Open() bails and the printer's 'no-driver', none of which
        # set their *ConfigFailed flag; it is also the reason the guards near the top
        # reject -SkipScannerConfig / -SkipPrinterConfig here. Evaluated BEFORE
        # Save-Manifest so a prior run's merged-in 'ok' row cannot mask it.
        # Scanner counts 'already-opos' too: the scanner is in the requested state, which
        # is the point of the run - re-running to confirm must not report failure.
        if (-not $DryRun) {
            $changed = if ($scan) { @($Manifest.scannerConfigured | Where-Object { $_.result -in @('ok','already-opos') }) }
                       else       { @($Manifest.printerConfigured | Where-Object { $_.result -eq 'ok' }) }
            if (-not $changed) {
                if ($scan) { $script:ScannerConfigFailed = $true } else { $script:PrinterConfigFailed = $true }
            }
        }
        Save-Manifest
        # A manifest that could not be written is a HARD failure (1), not a re-run signal:
        # this mode's entire durable output is the merged row it just failed to persist.
        # Set before the 6/7 block so it is never masked by it (they gate on $exitCode -eq 0).
        if ($script:ManifestWriteFailed) { $exitCode = 1 }

        # Own copy of the non-fatal exit-code block (6 / 7) - without it this branch
        # always exits 0, whatever the step reported.
        if ($scan -and $script:ScannerConfigFailed -and $exitCode -eq 0) {
            $exitCode = 6
            Warn 'Scanner present but USB-OPOS switch failed - re-run (scanner attached).'
            Show-ScannerBarcodeFallback
        }
        if (-not $scan -and $script:PrinterConfigFailed -and $exitCode -eq 0) {
            $exitCode = 7
            Warn 'OPOS device registration did not complete - see the log above.'
        }
        Step 'Done'
        Write-Host "Manifest: $ManifestPath"
        Write-Host "Log:      $RunLog"
    } elseif ($Uninstall) {
        $RunLog = Join-Path $LogDir ("uninstall_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))
        Start-Transcript -Path $RunLog -Append | Out-Null
        Write-Host "Alleaves UNINSTALL" -ForegroundColor Cyan
        Write-Host "WorkDir:  $WorkDir"
        Write-Host "Manifest: $ManifestPath"
        $rc = Invoke-UninstallPhase
        if ($rc -ne 0) { $exitCode = $rc }
        Step 'Done'
    } else {
        $RunLog = Join-Path $LogDir ("install_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))
        Start-Transcript -Path $RunLog -Append | Out-Null

        Write-Host "Alleaves bootstrap INSTALL" -ForegroundColor Cyan
        Write-Host "WorkDir:      $WorkDir"
        Write-Host "Downloads:    $DownloadDir"
        Write-Host "Manifest:     $ManifestPath"
        Write-Host "Logs:         $LogDir"
        if ($DryRun) { Write-Host "DRY RUN - no system changes will be made" -ForegroundColor Yellow }

        $Manifest = New-InstallManifest

        # 0. Computer rename FIRST (prompt up front so the tech can walk away while
        # the long download/install runs). Effective on the post-install reboot.
        Invoke-ComputerRename

        # 0b. Ask the printer brand HERE, next to the rename, for the same reason:
        # every interactive question belongs before the long unattended stretch. The
        # answer is cached and consumed by Set-PrinterOpos at step 5b.
        # "None" also has to reach the DOWNLOAD phase below, which is why it is asked
        # before it: no printer means the vendor driver isn't wanted either, and feeding
        # $SkipPrograms reuses Test-SkipMatch for both the download and the install row
        # instead of adding a second skip mechanism.
        # The brand answer is about the HARDWARE, so it is tested independently of
        # -SkipPrinterConfig (which only says "don't write the OPOS entry"). Gating the
        # two together meant "-PrinterBrand None -SkipPrinterConfig" - this terminal has
        # no receipt printer AND don't register one - still downloaded and installed the
        # vendor driver. -PrinterBrand is read directly rather than via
        # Resolve-PrinterBrand when the registration is skipped, so -SkipPrinterConfig
        # still suppresses the interactive prompt exactly as before.
        # The -SkipPrinterConfig fallback is 'POS-X', NOT empty, and it is load-bearing in
        # both directions. -SkipPrinterConfig only means "don't write the OPOS entry" - it
        # says nothing about the hardware - and it deliberately suppresses the prompt, so
        # with no -PrinterBrand there is no answer to read. Leaving $brand0 empty made the
        # loop below skip EVERY brand (no printer driver installed at all); dropping the
        # loop for that case made it skip NONE, which downloads every brand's driver and
        # put 471 MB of Star payload on terminals that just wanted to suppress a registry
        # write. POS-X is Resolve-PrinterBrand's own default, so this reproduces exactly
        # what -SkipPrinterConfig did before a second brand existed.
        $brand0 = if ($SkipPrinterConfig) { if ($PrinterBrand) { $PrinterBrand } else { 'POS-X' } }
                  else { Resolve-PrinterBrand }
        # Skip every brand's rows EXCEPT the chosen one. Generalised from "None skips the
        # POS-X row" once a second brand existed: picking POS-X must not drag down 471 MB
        # of Star payload, and vice versa. 'None' is not a key, so it still skips them all
        # and the old behaviour falls out for free.
        foreach ($b in $PrinterBrands.Keys) {
            if ($b -ne $brand0) { $SkipPrograms += $PrinterBrands[$b].RowName }
        }
        if ($brand0 -eq 'None') { Ok 'no receipt printer - no printer driver will be downloaded or installed' }
        else { Ok "receipt printer: $brand0 - other brands' drivers will not be downloaded or installed" }

        # 1. Download
        Invoke-DownloadPhase

        # 2. TeamViewer removal
        if (-not $SkipUninstallTeamViewer) { Uninstall-TeamViewer }

        # 2b. Bootstrap the shared VC++ x64 runtime BEFORE the Zebra installers.
        # CoreScanner requires it; if absent the Zebra wrapper auto-installs it
        # and forces a reboot that derails the silent flow. (TLS is set inside.)
        Install-VcRedist | Out-Null

        # 3. Install loop
        Invoke-InstallLoop

        # 3b. CoreScanner is the Scanner SDK's functional core (the scanner
        # service). The .iss path installs it; the extracted-MSI FALLBACK does
        # NOT. Surface a clear warning if it's missing rather than reporting a
        # silent success that leaves the scanner non-functional.
        if (-not $DryRun -and -not (Test-SkipMatch -Names @('Zebra Scanner SDK','Zebra Scanner SDK.exe'))) {
            if (Get-Service CoreScanner -ErrorAction SilentlyContinue) {
                Ok 'Zebra CoreScanner service present'
            } else {
                Warn 'Zebra CoreScanner service NOT present - the scanner may not function.'
                Warn 'If the Scanner SDK fell back to the extracted MSI, re-run the installer (the .iss path installs CoreScanner).'
                $script:ScannerDegraded = $true   # F20: surface via a distinct exit code below
            }
        }

        # 3c. Per-terminal finishing: pin Alleaves Terminal + Alleaves POS / remove
        # Edge from the taskbar, make Chrome default, bookmark the Alleaves POS.
        # The first two defer the visible change to a per-user logon task that runs
        # after the post-install reboot (see the FINISHING block); the Chrome
        # bookmark policy is machine-wide and needs no task.
        Invoke-ChromeTaskbar
        Invoke-ChromeDefaultBrowser
        Invoke-ChromeBookmark
        Register-FinishLogonTask

        # 4. Master list -> cashier + admin Documents
        # Test-SkipMatch too, same as the Splashtop fetch: the .nlbl is a $DriveFiles row, so
        # -SkipPrograms 'Nice Label' correctly skips its DOWNLOAD - and this step then failed
        # "not found", set $script:FinishFailed and exited 1 on a deliberate skip.
        if (-not $SkipMasterList -and -not (Test-SkipMatch -Names @('Master List','Alleaves Nice Label Master List.nlbl'))) {
            $source = Join-Path $DownloadDir 'Alleaves Nice Label Master List.nlbl'
            Copy-MasterList -Source $source
        }

        # 5. FINAL functional step: flip the connected Zebra scanner(s) to USB-OPOS
        # (runs AFTER all installs, finishing, and the master-list copy - the last
        # thing that happens before the manifest captures it).
        Set-ScannerOpos

        # 5b. Register the chosen brand's receipt printer OPOS device entries.
        # Registry-only and hardware-independent, so unlike the scanner step it does
        # not care whether anything is plugged in.
        Set-PrinterOpos

        # Snapshot THIS run's results BEFORE Save-Manifest: the merge carries prior-run
        # rows forward into $Manifest for every product this run didn't touch (skipped
        # via -SkipPrograms, or dropped by -PrinterBrand None). Tallying after the merge
        # counts an OLD failure as a new one, so a run that fixed nothing but broke
        # nothing exits 1 forever - and that phantom 1 also suppresses the non-fatal
        # 4/6/7 re-run signals below, which are all gated on $exitCode -eq 0.
        $failed    = @($Manifest.installed    | Where-Object { $_.result -and ($_.result -notin @('ok','dryrun')) })
        $depFailed = @($Manifest.dependencies | Where-Object { $_.result -and ($_.result -notin @('ok','already-present','dryrun')) })
        # Snapshot THIS run's rename for the reboot banner below, for the same reason: the
        # merge carries a PRIOR run's computerRenamed forward when this run has none, so a
        # -SkipRename re-run on a box where VC++ returned 3010 announced "will be renamed
        # to 'POS01' on reboot" for a rename that landed weeks ago.
        $renamedTo = $Manifest.computerRenamed.to

        # 6. Persist manifest (merged)
        Save-Manifest

        # Tidy zero-byte stdout/stderr logs.
        Get-ChildItem $LogDir -Filter '*.std*.log' -ErrorAction SilentlyContinue |
            Where-Object { $_.Length -eq 0 } |
            Remove-Item -Force -ErrorAction SilentlyContinue

        # 7. Exit code: non-zero if anything failed (Advisor #4 + F19 dependencies).
        # F19: a failed VC++ x64 redist (the exact fresh-box gap this bootstrap
        # closes; CoreScanner hard-depends on it) lands in $Manifest.dependencies,
        # which the old scan ignored - so a broken dependency exited 0. Count it too.
        # ($failed / $depFailed are snapshotted above, before the manifest merge.)
        # $script:FinishFailed covers the steps that write NO $Manifest.installed row and so
        # were invisible here: the master-list copy, the Chrome bookmark policy, and the
        # staging/registration of the per-user logon task. Each of those used to Fail on the
        # console and still exit 0 - a terminal with no .nlbl and no logon task reported
        # clean to the RMM.
        # $script:ManifestWriteFailed is read HERE, after Save-Manifest - the tally above is
        # snapshotted before it on purpose, but the flag only exists once the write ran.
        if ($failed.Count -gt 0 -or $depFailed.Count -gt 0 -or $script:DownloadFailed -or $script:FinishFailed -or $script:ManifestWriteFailed) {
            $exitCode = 1
            Fail "$($failed.Count) install / $($depFailed.Count) dependency failure(s); download failure=$($script:DownloadFailed); finishing failure=$($script:FinishFailed); manifest write failure=$($script:ManifestWriteFailed)"
        }
        # F20: a degraded scanner (CoreScanner missing - e.g. the .iss path fell back
        # to the extracted MSI, which omits CoreScanner) is not a hard failure but DOES
        # need a re-run. Surface a distinct code (4) so RMM can tell "re-run needed"
        # from a real failure (1); don't mask an already-failing run.
        if ($script:ScannerDegraded -and $exitCode -eq 0) {
            $exitCode = 4
            Warn 'Scanner degraded (CoreScanner missing) - re-run the installer.'
        }
        # A scanner WAS connected but the OPOS switch failed (mirrors the ScannerDegraded
        # ->4 design): distinct non-fatal code 6 ("re-run with the scanner attached") so
        # RMM can tell it apart from a real install failure (1). Never masks an exit 1.
        if ($script:ScannerConfigFailed -and $exitCode -eq 0) {
            $exitCode = 6
            Warn 'Scanner present but USB-OPOS switch failed - re-run the installer (scanner attached).'
            Show-ScannerBarcodeFallback
        }
        # The OPOS printer entry is pure registry, so this failing means the
        # WRITE failed - not that hardware is missing. Non-fatal re-run signal (7), same
        # discipline as 4 and 6: never masks a real install failure (1).
        if ($script:PrinterConfigFailed -and $exitCode -eq 0) {
            $exitCode = 7
            Warn 'OPOS receipt printer registration failed - re-run (or use -PrinterConfigOnly).'
        }
        Step 'Done'
        Write-Host "Manifest: $ManifestPath"
        Write-Host "Log:      $RunLog"
        Write-Host "To reverse: Install-Alleaves.bat -Uninstall"

        # Zebra recommends a reboot after CoreScanner. We use /norestart
        # throughout (no mid-run reboot to derail later installers); advise the
        # tech here. Emphatic if VC++ flagged a pending reboot (3010). No auto-reboot.
        if ($script:RebootPending) {
            Warn '*** REBOOT REQUIRED before this terminal is ready.                    ***'
            if ($renamedTo) { Warn ("*** Computer will be renamed to '{0}' on reboot.{1}***" -f $renamedTo, (' ' * [Math]::Max(1, 21 - $renamedTo.Length))) }
            Warn '*** Reboot before using the Zebra scanner.                           ***'
        } else {
            Write-Host "  Recommended: reboot this terminal once to finalize Zebra CoreScanner." -ForegroundColor Yellow
        }
        if ($script:FinishBrowser -or $script:FinishTaskbar) {
            Write-Host "  After the reboot, sign in: the taskbar pin / default browser are applied" -ForegroundColor Yellow
            Write-Host "  automatically at logon (AlleavesAuto-FinishUser). Verify 'Alleaves Terminal'" -ForegroundColor Yellow
            Write-Host "  and 'Alleaves POS' are pinned, Edge is gone, and an http link opens in Chrome." -ForegroundColor Yellow
            Write-Host "  The Alleaves POS pin should open $AlleavesUrl, with an 'Alleaves' bookmark." -ForegroundColor Yellow
        }
    }
} catch {
    Fail "unhandled error: $($_.Exception.Message)"
    $exitCode = 1
} finally {
    # F22: a throw during the finishing steps (after UCPD Start=4, the logon task,
    # and the cleared taskbar are already on disk) would otherwise skip the single
    # Save-Manifest at step 5 -> no manifest -> those changes become un-uninstallable.
    # Persist from finally, guarded + idempotent (Save-Manifest no-ops on DryRun and
    # merges). $Manifest is $null on the uninstall path, so the guard skips it there.
    if (-not $Uninstall -and $Manifest) { try { Save-Manifest } catch {} }
    try { Stop-Transcript | Out-Null } catch {}
}

exit $exitCode
