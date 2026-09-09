<#
.SYNOPSIS
    Self-check for the account precheck's classification logic and the swap helpers.

    Until this existed, the ONLY runnable check on Test-InstallAccount was the
    -DryRun print, which can only ever exercise the verdict for whatever account
    happens to be signed in - i.e. never the ones that matter (MSA, Entra,
    undetermined). This lifts the functions out of alleaves_setup.ps1 with the
    AST, stubs their probes, and asserts every arm.

    No framework, no fixtures. Run it directly:
        PowerShell -ExecutionPolicy Bypass -File .\tests\Test-AccountPrecheck.ps1
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

# --- lift the functions under test out of the installer -------------------
# Loading the whole script would run it (mode echo, elevation abort, the
# precheck itself). Pull just the definitions and evaluate those.
$target = Join-Path (Split-Path $PSScriptRoot -Parent) 'alleaves_setup.ps1'
$errs = $null
$ast  = [System.Management.Automation.Language.Parser]::ParseFile($target, [ref]$null, [ref]$errs)
if ($errs) { Write-Host "parse errors in $target" -ForegroundColor Red; exit 1 }

$wanted = @('Get-MicrosoftAccountId','Get-MsaLinkedEmail','Test-InstallAccount',
            'ConvertTo-ResumeArgs','Confirm-Swap','Read-SwapAnswer','Restore-AutoLogon',
            'Set-AccountCheckOverride','Clear-AccountSwapState')
$found = @{}
foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if ($wanted -contains $f.Name) { $found[$f.Name] = $f.Extent.Text }
}
foreach ($w in $wanted) {
    if (-not $found.ContainsKey($w)) { Write-Host "FAIL: $w not found in the installer" -ForegroundColor Red; exit 1 }
    . ([scriptblock]::Create($found[$w]))
}

# --- stubs: the probes Test-InstallAccount calls --------------------------
$script:StubAccount = $null; $script:StubMsa = $null; $script:StubAdmin = $true
function Get-SignedInAccount { $script:StubAccount }
function Get-MicrosoftAccountId($sid) { $script:StubMsa }
function Test-LocalAdminSid($sid, $name) { $script:StubAdmin }
function Warn($m) {}
$env:COMPUTERNAME = 'POS01'

function Get-Verdict($name, $sid, $msa, $isAdmin) {
    $script:StubAccount = [pscustomobject]@{
        Name = $name; Sid = $sid
        Domain = $(if ($name -like '*\*') { $name.Split('\')[0] } else { '' })
    }
    $script:StubMsa = $msa; $script:StubAdmin = $isAdmin
    (Test-InstallAccount).Reason
}

Write-Host "`nTest-InstallAccount verdicts" -ForegroundColor Cyan
Assert-Eq 'ok'                   (Get-Verdict 'POS01\till'     'S-1-5-21-1-2-3-1001' $null     $true)  'local admin passes'
Assert-Eq 'not-admin'            (Get-Verdict 'POS01\till'     'S-1-5-21-1-2-3-1001' $null     $false) 'local non-admin blocks'
Assert-Eq 'microsoft-account'    (Get-Verdict 'POS01\till'     'S-1-5-21-1-2-3-1001' 'a@b.com' $true)  'MSA blocks even when admin'
Assert-Eq 'not-local'            (Get-Verdict 'CONTOSO\till'   'S-1-5-21-9-9-9-1001' $null     $true)  'domain account blocks'
Assert-Eq 'not-local'            (Get-Verdict 'AzureAD\a@b.com' 'S-1-12-1-11-22-33-44' $null   $true)  'Entra with domain prefix blocks'
Assert-Eq 'no-interactive-user'  (Get-Verdict 'SYSTEM'         'S-1-5-18'            $null     $true)  'SYSTEM is not an interactive user'

# The two regressions this file exists for.
# 1b: an undetermined account type used to return $null from the MSA probe,
#     which reads as "not MSA" -> the account PASSED. Undetermined must block.
Assert-Eq 'account-type-unknown' (Get-Verdict 'POS01\till'     'S-1-5-21-1-2-3-1001' 'unknown' $true)  'undetermined account type BLOCKS (does not fail open)'
# 1c: an Entra SID with no DOMAIN\ prefix used to fall through to the generic
#     SID-shape arm and report "no interactive user" - right verdict, wrong reason.
Assert-Eq 'not-local'            (Get-Verdict 'a@b.com'        'S-1-12-1-11-22-33-44' $null    $true)  'bare Entra SID reports not-local, not no-interactive-user'

Write-Host "`nGet-MicrosoftAccountId tri-state" -ForegroundColor Cyan
# The verdict tests above needed a STUBBED Get-MicrosoftAccountId; put the real
# one back before testing it, or this section silently tests the stub.
. ([scriptblock]::Create($found['Get-MicrosoftAccountId']))
# PrincipalSource answering 'Local' is proof; anything unreadable is 'unknown'.
# The param list must swallow -ErrorAction: a non-advanced function does not
# bind common parameters, and the real code calls Get-LocalUser -ErrorAction Stop.
function Get-LocalUser { param($SID, $Name, $ErrorAction) [pscustomobject]@{ PrincipalSource = $script:StubPs } }
$script:StubPs = 'Local'
Assert-Eq ''        (Get-MicrosoftAccountId 'S-1-5-21-1-2-3-1001') "PrincipalSource 'Local' => proven local (null)"
$script:StubPs = $null
Assert-Eq 'unknown' (Get-MicrosoftAccountId 'S-1-5-21-1-2-3-1001') 'PrincipalSource null + no cache key => unknown'
Assert-Eq 'unknown' (Get-MicrosoftAccountId $null)                 'no SID => unknown (never a silent pass)'

Write-Host "`nConvertTo-ResumeArgs" -ForegroundColor Cyan
$bound = [ordered]@{
    DryRun        = [switch]$true          # must be dropped
    ForceReinstall= [switch]$true
    ComputerName  = "O'Brien POS 1"        # apostrophe must be doubled
    SkipPrograms  = @('Star','NiceLabel')
}
$line = ConvertTo-ResumeArgs $bound
Assert-Eq $false ($line -match '-DryRun')                      'a dry run never arms, so -DryRun is dropped'
Assert-Eq $true  ($line -match '-ForceReinstall')              'switches survive'
Assert-Eq $true  ($line -match "-ComputerName 'O''Brien POS 1'") 'apostrophes are doubled, not lost'
Assert-Eq $true  ($line -match "-SkipPrograms 'Star','NiceLabel'") 'arrays are comma-joined and quoted'

# ROUND-TRIP, not just the string shape. The assertions above passed the whole time
# Register-ResumeTask launched the resumed run with -File, which does NOT evaluate this
# syntax: it hands each token through literally, so the array arrived as one bogus element
# and "O'Brien POS 1" split on its spaces. Bind it the way -Command does and check the
# VALUES that come out the other side.
$sink = {
    param([switch]$ForceReinstall, [string]$ComputerName, [string[]]$SkipPrograms, [switch]$DryRun)
    [pscustomobject]@{ F=$ForceReinstall.IsPresent; C=$ComputerName; S=$SkipPrograms; D=$DryRun.IsPresent }
}
$rt = Invoke-Expression "& `$sink $line"
Assert-Eq $true            $rt.F        'round-trip: -ForceReinstall binds as a switch'
Assert-Eq "O'Brien POS 1"  $rt.C        'round-trip: a name with a space and an apostrophe survives intact'
Assert-Eq 2                $rt.S.Count  'round-trip: -SkipPrograms binds as TWO elements, not one string'
Assert-Eq 'NiceLabel'      $rt.S[1]     'round-trip: the second element is intact'
Assert-Eq $false           $rt.D        'round-trip: -DryRun never reaches the resumed run'

Write-Host "`nConfirm-Swap defaults to NO" -ForegroundColor Cyan
# Consent to create an account and reboot must never be inferred from silence.
function Read-SwapAnswer($p) { $script:StubAnswer }
$script:StubAnswer = $null; Assert-Eq $false (Confirm-Swap 'x') 'headless (null) declines'
$script:StubAnswer = '';    Assert-Eq $false (Confirm-Swap 'x') 'empty answer declines'
$script:StubAnswer = 'n';   Assert-Eq $false (Confirm-Swap 'x') "'n' declines"
$script:StubAnswer = 'y';   Assert-Eq $true  (Confirm-Swap 'x') "'y' consents"
$script:StubAnswer = 'yes'; Assert-Eq $true  (Confirm-Swap 'x') "'yes' consents"

Write-Host "`nRestore-AutoLogon puts prior state back exactly" -ForegroundColor Cyan
# The whole reason autologon is captured rather than blindly deleted: a box can
# ALREADY carry AutoAdminLogon (this rig has it set to '0'). Deleting what was
# there is not the same as restoring it.
$script:Wrote = @{}; $script:Removed = @()
function New-ItemProperty { param($Path,$Name,$Value,$PropertyType,[switch]$Force,$ErrorAction) $script:Wrote[$Name] = "$Value/$PropertyType" }
function Remove-ItemProperty { param($Path,$Name,[switch]$Force,$ErrorAction) $script:Removed += $Name }
$AutoLogonValues = @('AutoAdminLogon','DefaultUserName','DefaultDomainName','DefaultPassword','AutoLogonCount')
$WinlogonKey = 'HKLM:\fake'
Restore-AutoLogon ([pscustomobject]@{
    AutoAdminLogon    = [pscustomobject]@{ present = $true;  value = '0' }   # pre-existing
    DefaultUserName   = [pscustomobject]@{ present = $false; value = $null }
    DefaultDomainName = [pscustomobject]@{ present = $false; value = $null }
    DefaultPassword   = [pscustomobject]@{ present = $false; value = $null }
    AutoLogonCount    = [pscustomobject]@{ present = $false; value = $null }
})
Assert-Eq '0/String' $script:Wrote['AutoAdminLogon']       'a pre-existing AutoAdminLogon is RESTORED, not deleted'
Assert-Eq $true      ($script:Removed -contains 'DefaultPassword') 'the password we added is removed'
Assert-Eq 4          $script:Removed.Count                 'exactly the four values that were absent are removed'
Assert-Eq $true      ($script:Removed -notcontains 'AutoAdminLogon') 'a value that existed is never removed'

# LAST section on purpose: its stubs shadow Restore-AutoLogon, Test-Path, Get-Content and
# Remove-Item, so anything after it would be testing the stubs.
Write-Host "`nClear-AccountSwapState" -ForegroundColor Cyan
# Three regressions live here. The marker is the ONLY record that a swap was armed, and
# this function is the only thing that disarms it.
$AccountSwapMarker = 'X:\fake\account_swap.json'
$AccountSwapTask   = 'AlleavesAuto-Resume'
$script:MarkerBody = $null      # $null => Get-Content throws (unreadable marker)
$script:Unregistered = 0; $script:MarkerDeleted = 0; $script:Restored = 0
function Step($m) {}
function Ok($m) {}
function Fail($m) {}
function Dry($m) {}
function Test-Path { param($Path, $LiteralPath, $ErrorAction) $true }
function Get-Content { param($Path, [switch]$Raw, $EA, $ErrorAction) if ($null -eq $script:MarkerBody) { throw 'truncated' }; $script:MarkerBody }
function Unregister-ScheduledTask { param($TaskName, [switch]$Confirm, $EA, $ErrorAction) $script:Unregistered++ }
function Restore-AutoLogon($prior) { $script:Restored++ }
function Remove-Item { param($Path, [switch]$Recurse, [switch]$Force, $EA, $ErrorAction) $script:MarkerDeleted++ }

function Reset-SwapStubs { $script:Unregistered=0; $script:MarkerDeleted=0; $script:Restored=0
                           $script:AccountSwapAttempted=$false; $script:AccountSwapDone=$null }

# 1. -DryRun must touch NOTHING. A tech who armed a swap and then ran -DryRun to re-check
#    the verdict had the (elevated) dry run silently disarm it, and the box rebooted into
#    the old account with no autologon and no resume task.
Reset-SwapStubs; $DryRun = $true
Clear-AccountSwapState
Assert-Eq 0     $script:Unregistered      '-DryRun does not unregister the resume task'
Assert-Eq 0     $script:MarkerDeleted     '-DryRun does not delete the marker'
Assert-Eq 0     $script:Restored          '-DryRun does not touch autologon'
Assert-Eq $true $script:AccountSwapAttempted '-DryRun still trips the loop guard'

# 2. An UNREADABLE marker must still unregister the task. It used to sit inside "if ($m)"
#    while the marker was deleted unconditionally, so a marker truncated by a power-off
#    left the resume task relaunching the installer at every logon, forever, with the only
#    record of it gone.
Reset-SwapStubs; $DryRun = $false; $script:MarkerBody = $null
Clear-AccountSwapState
Assert-Eq 1 $script:Unregistered  'unreadable marker: the resume task is STILL unregistered'
Assert-Eq 1 $script:MarkerDeleted 'unreadable marker: the marker is cleaned up'

# 3. The normal resume path still does all three.
Reset-SwapStubs; $script:MarkerBody = '{"account":"POS01\\till","sid":"S-1-5-21-1-2-3-1001","created":true,"winlogonPrior":{}}'
Clear-AccountSwapState
Assert-Eq 1        $script:Unregistered            'resume: task unregistered'
Assert-Eq 1        $script:Restored                'resume: autologon restored'
Assert-Eq 1        $script:MarkerDeleted           'resume: marker deleted'
Assert-Eq 'POS01\till' $script:AccountSwapDone.name 'resume: the account reaches the manifest seed'

Write-Host "`nSet-AccountCheckOverride records the waiver" -ForegroundColor Cyan
# The precheck prints BEFORE Start-Transcript, so this hashtable is the only
# durable evidence that a terminal was installed over a failed verdict. If the
# shape drifts, New-InstallManifest and Save-Manifest's whenUtc merge both go
# quietly wrong - and nothing on the box would say the check was skipped.
$script:AccountCheckOverride = $null
Set-AccountCheckOverride ([pscustomobject]@{ Detail='POS01\till'; Reason='microsoft-account' }) 'prompt'
$o = $script:AccountCheckOverride
Assert-Eq 'POS01\till'       $o.account   'the account that failed is recorded'
Assert-Eq 'microsoft-account' $o.reason   'the verdict that was waived is recorded'
Assert-Eq 'prompt'           $o.via       'HOW it was waived is recorded (prompt vs switch)'
Assert-Eq $false             $o.removable 'record-only: -Uninstall must never try to reverse it'
Assert-Eq $true  ([bool]$o.whenUtc)       'whenUtc is set - it is the manifest merge key'

Write-Host ''
if ($script:Failures) { Write-Host "$($script:Failures) FAILED" -ForegroundColor Red; exit 1 }
Write-Host 'all passed' -ForegroundColor Green
exit 0
