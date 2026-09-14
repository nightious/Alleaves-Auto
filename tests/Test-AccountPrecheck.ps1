<#
.SYNOPSIS
    Self-check: account-precheck verdict arms + the swap helpers.
    Why each arm is asserted: docs/ACCOUNT-SWAP.md

    Lifts the functions out of alleaves_setup.ps1 with the AST and stubs their
    probes, so every arm is checkable without a matching real account.
    Stub order matters - the Clear-AccountSwapState section shadows
    Restore-AutoLogon/Test-Path/Get-Content/Remove-Item, so it must stay LAST.

        PowerShell -ExecutionPolicy Bypass -File .\tests\Test-AccountPrecheck.ps1
    Exits 0 on pass, 1 on failure.
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')

$funcs  = Get-InstallerFunctions (Get-InstallerAst)
$wanted = @('Get-MicrosoftAccountId','Get-IdentityStoreEmail','Test-InstallAccount',
            'ConvertTo-ResumeArgs','Confirm-Swap','Read-SwapAnswer','Restore-AutoLogon',
            'Set-AccountCheckOverride','Clear-AccountSwapState')
Assert-InstallerHas $funcs $wanted
foreach ($w in $wanted) { . ([scriptblock]::Create($funcs[$w].Extent.Text)) }

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
Assert-Eq 'service-account'      (Get-Verdict 'NT AUTHORITY\SYSTEM' 'S-1-5-18'       $null     $true)  'SYSTEM reports service-account, not not-local'
Assert-Eq 'service-account'      (Get-Verdict 'NT AUTHORITY\LOCAL SERVICE' 'S-1-5-19' $null    $true)  'LocalService too'
Assert-Eq 'no-interactive-user'  (Get-Verdict 'till'           $null                 $null     $true)  'an unresolvable account is not an interactive user'

Assert-Eq 'account-type-unknown' (Get-Verdict 'POS01\till'     'S-1-5-21-1-2-3-1001' 'unknown' $true)  'undetermined account type BLOCKS (does not fail open)'
Assert-Eq 'not-local'            (Get-Verdict 'a@b.com'        'S-1-12-1-11-22-33-44' $null    $true)  'bare Entra SID reports not-local, not no-interactive-user'

Write-Host "`nGet-MicrosoftAccountId tri-state" -ForegroundColor Cyan
. ([scriptblock]::Create($funcs['Get-MicrosoftAccountId'].Extent.Text))
function Get-LocalUser { param($SID, $Name, $ErrorAction) [pscustomobject]@{ PrincipalSource = $script:StubPs } }
$script:StubPs = 'Local'
Assert-Eq ''        (Get-MicrosoftAccountId 'S-1-5-21-1-2-3-1001') "PrincipalSource 'Local' => proven local (null)"
$script:StubPs = $null
Assert-Eq 'unknown' (Get-MicrosoftAccountId 'S-1-5-21-1-2-3-1001') 'PrincipalSource null + no cache key => unknown'
Assert-Eq 'unknown' (Get-MicrosoftAccountId $null)                 'no SID => unknown (never a silent pass)'

Write-Host "`nConvertTo-ResumeArgs" -ForegroundColor Cyan
$bound = [ordered]@{
    DryRun        = [switch]$true
    ForceReinstall= [switch]$true
    ComputerName  = "O'Brien POS 1"
    SkipPrograms  = @('Star','NiceLabel')
}
$line = ConvertTo-ResumeArgs $bound
Assert-Eq $false ($line -match '-DryRun')                      'a dry run never arms, so -DryRun is dropped'
Assert-Eq $true  ($line -match '-ForceReinstall')              'switches survive'
Assert-Eq $true  ($line -match "-ComputerName 'O''Brien POS 1'") 'apostrophes are doubled, not lost'
Assert-Eq $true  ($line -match "-SkipPrograms 'Star','NiceLabel'") 'arrays are comma-joined and quoted'

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
function Read-SwapAnswer($p) { $script:StubAnswer }
$script:StubAnswer = $null; Assert-Eq $false (Confirm-Swap 'x') 'headless (null) declines'
$script:StubAnswer = '';    Assert-Eq $false (Confirm-Swap 'x') 'empty answer declines'
$script:StubAnswer = 'n';   Assert-Eq $false (Confirm-Swap 'x') "'n' declines"
$script:StubAnswer = 'y';   Assert-Eq $true  (Confirm-Swap 'x') "'y' consents"
$script:StubAnswer = 'yes'; Assert-Eq $true  (Confirm-Swap 'x') "'yes' consents"

Write-Host "`nRestore-AutoLogon puts prior state back exactly" -ForegroundColor Cyan
$script:Wrote = @{}; $script:Removed = @()
function New-ItemProperty { param($Path,$Name,$Value,$PropertyType,[switch]$Force,$ErrorAction) $script:Wrote[$Name] = "$Value/$PropertyType" }
function Remove-ItemProperty { param($Path,$Name,[switch]$Force,$ErrorAction) $script:Removed += $Name }
$AutoLogonValues = @('AutoAdminLogon','DefaultUserName','DefaultDomainName','DefaultPassword','AutoLogonCount')
$WinlogonKey = 'HKLM:\fake'
# NOT $failures: that is $script:Failures (names are case-insensitive) and assigning it
# here would zero the assertion counter mid-run. docs/ARCHITECTURE.md#tests
$restoreFailures = Restore-AutoLogon ([pscustomobject]@{
    AutoAdminLogon    = [pscustomobject]@{ present = $true;  value = '0' }
    DefaultUserName   = [pscustomobject]@{ present = $false; value = $null }
    DefaultDomainName = [pscustomobject]@{ present = $false; value = $null }
    DefaultPassword   = [pscustomobject]@{ present = $false; value = $null }
    AutoLogonCount    = [pscustomobject]@{ present = $false; value = $null }
})
Assert-Eq '0/String' $script:Wrote['AutoAdminLogon']       'a pre-existing AutoAdminLogon is RESTORED, not deleted'
Assert-Eq $true      ($script:Removed -contains 'DefaultPassword') 'the password we added is removed'
Assert-Eq 4          $script:Removed.Count                 'exactly the four values that were absent are removed'
Assert-Eq $true      ($script:Removed -notcontains 'AutoAdminLogon') 'a value that existed is never removed'
Assert-Eq 0          $restoreFailures                      'a clean restore reports zero failures (not $null, not silence)'

$script:Wrote = @{}; $script:Removed = @()
Restore-AutoLogon ([pscustomobject]@{
    AutoAdminLogon    = [pscustomobject]@{ present = $false; value = $null }
    DefaultUserName   = [pscustomobject]@{ present = $false; value = $null }
    DefaultDomainName = [pscustomobject]@{ present = $false; value = $null }
    DefaultPassword   = [pscustomobject]@{ present = $true;  value = $null }
    AutoLogonCount    = [pscustomobject]@{ present = $false; value = $null }
}) | Out-Null
Assert-Eq $true  ($script:Removed -contains 'DefaultPassword') 'a pre-existing DefaultPassword is removed, not restored'
Assert-Eq $false ($script:Wrote.ContainsKey('DefaultPassword')) 'no password is ever written back'

Assert-Eq $true ($null -eq (Restore-AutoLogon $null)) 'nothing to restore returns $null, not a count'

Write-Host "`nClear-AccountSwapState" -ForegroundColor Cyan
$AccountSwapDir    = 'C:\fake-alleaves-test'
$AccountSwapMarker = 'C:\fake-alleaves-test\account_swap.json'
$AccountSwapTask   = 'AlleavesAuto-Resume'
$script:MarkerBody = $null
$script:Unregistered = 0; $script:MarkerDeleted = 0; $script:Restored = 0; $script:ResumeDirDeleted = 0
function Step($m) {}
function Ok($m) {}
function Fail($m) {}
function Dry($m) {}
# The marker's existence has to TRACK the stubbed delete, or the post-delete readback
# always says "still there" and the exit-1 arm is the only one the test ever exercises.
function Test-Path { param($Path, $LiteralPath, $ErrorAction)
                     if ("$Path" -eq $AccountSwapMarker) { return $script:MarkerExists }
                     $true }
function Get-Content { param($Path, [switch]$Raw, $EA, $ErrorAction) if ($null -eq $script:MarkerBody) { throw 'truncated' }; $script:MarkerBody }
function Unregister-ScheduledTask { param($TaskName, [switch]$Confirm, $EA, $ErrorAction) $script:Unregistered++ }
function Get-ScheduledTask { param($TaskName, $EA, $ErrorAction)
                             if ($script:TaskSurvives) { [pscustomobject]@{ TaskName = $TaskName } } }
function Restore-AutoLogon($prior) { $script:Restored++ }
function Remove-Item { param($Path, [switch]$Recurse, [switch]$Force, $EA, $ErrorAction)
                       if ("$Path" -eq $AccountSwapMarker) { $script:MarkerDeleted++; $script:MarkerExists = $script:MarkerSticky }
                       else { $script:ResumeDirDeleted++ } }

function Reset-SwapStubs { $script:Unregistered=0; $script:MarkerDeleted=0; $script:Restored=0; $script:ResumeDirDeleted=0
                           $script:AccountSwapAttempted=$false; $script:AccountSwapDone=$null
                           $script:TaskSurvives=$false; $script:FinishFailed=$false
                           $script:MarkerExists=$true; $script:MarkerSticky=$false }

Reset-SwapStubs; $DryRun = $true
Clear-AccountSwapState
Assert-Eq 0     $script:Unregistered      '-DryRun does not unregister the resume task'
Assert-Eq 0     $script:MarkerDeleted     '-DryRun does not delete the marker'
Assert-Eq 0     $script:Restored          '-DryRun does not touch autologon'
Assert-Eq 0     $script:ResumeDirDeleted  '-DryRun does not delete the staged resume copy'
Assert-Eq $true $script:AccountSwapAttempted '-DryRun still trips the loop guard'

Reset-SwapStubs; $DryRun = $false; $script:MarkerBody = $null
Clear-AccountSwapState
Assert-Eq 1 $script:Unregistered  'unreadable marker: the resume task is STILL unregistered'
Assert-Eq 1 $script:MarkerDeleted 'unreadable marker: the marker is cleaned up'
Assert-Eq 1 $script:ResumeDirDeleted 'unreadable marker: the staged resume copy is STILL removed'
Assert-Eq $false $script:FinishFailed 'unreadable marker: not an exit-1 - the state IS cleared'

Reset-SwapStubs; $script:MarkerBody = '{"account":"POS01\\till","sid":"S-1-5-21-1-2-3-1001","created":true,"winlogonPrior":{}}'
Clear-AccountSwapState
Assert-Eq 1        $script:Unregistered            'resume: task unregistered'
Assert-Eq 1        $script:Restored                'resume: autologon restored'
Assert-Eq 1        $script:MarkerDeleted           'resume: marker deleted'
Assert-Eq 'POS01\till' $script:AccountSwapDone.name 'resume: the account reaches the manifest seed'
Assert-Eq $false   $script:FinishFailed            'resume: a clean pass does NOT raise the exit-1 flag'

Reset-SwapStubs; $script:MarkerSticky = $true
$script:MarkerBody = '{"account":"POS01\\till","sid":"S-1-5-21-1-2-3-1001","created":true,"winlogonPrior":{}}'
Clear-AccountSwapState
Assert-Eq 1     $script:MarkerDeleted 'undeletable marker: the delete is still attempted'
Assert-Eq $true $script:FinishFailed  'undeletable marker: the next run would re-enter resume, so exit 1'

Reset-SwapStubs; $script:TaskSurvives = $true
$script:MarkerBody = '{"account":"POS01\\till","sid":"S-1-5-21-1-2-3-1001","created":true,"winlogonPrior":{}}'
Clear-AccountSwapState
Assert-Eq 0 $script:MarkerDeleted    'surviving resume task: the marker is KEPT so the next run retries'
Assert-Eq 0 $script:ResumeDirDeleted 'surviving resume task: the staged script it launches is kept too'
Assert-Eq 1 $script:Restored         'surviving resume task: autologon is STILL restored (never left armed)'
Assert-Eq $true $script:FinishFailed 'surviving resume task: raises the exit-1 flag'

Write-Host "`nSet-AccountCheckOverride records the waiver" -ForegroundColor Cyan
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
