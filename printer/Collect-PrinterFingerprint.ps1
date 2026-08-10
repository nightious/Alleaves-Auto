<#
    Collect-PrinterFingerprint.ps1
    ---------------------------------------------------------------------------
    Run this on a terminal that has a POS-X receipt printer (and/or cash drawer)
    ATTACHED. We have never had one on the bench: every constant in Set-PrinterOpos
    was captured from the vendor's own SetupPOS.exe on a printer-less rig, and the
    OPOS device entries were proved to Open() with nothing plugged in. What is still
    unknown is everything that only a real unit can show.

    This capture yields, in order:

      1. The OPOS device entries as they actually exist, verbatim, in BOTH registry
         views - validates what Set-PrinterOpos wrote (and the per-terminal LDNs
         <POSname>_Printer / <POSname>_Drawer).
      2. The ProgID -> CLSID -> InprocServer32 chain, i.e. whether the service
         objects the entries point at are really registered and really on disk.
      3. Get-PnpDevice for the attached USB printer: VID / PID / status / device
         path. WE HAVE NO SAMPLE OF THIS AT ALL. It is the single most valuable
         thing a field run can bring back, and it is what would let a future build
         detect "printer present" the way the scanner step detects a scanner.
      4. Spooler + Get-Printer / Get-PrinterPort as DIAGNOSTIC CONTEXT ONLY. Nothing
         is expected to be there - the print path is OPOS, not the Windows queue
         (POSPrinterSOU.dll imports no WINSPOOL at all). A queue showing up is
         itself informative, not a requirement.
      5. Unless -SnapshotOnly, a live OPOS probe: Open -> ClaimDevice ->
         DeviceEnabled -> PrintNormal, reporting a result code per call. THIS PRINTS
         A TEST RECEIPT and opens the cash drawer.

    Already known (do NOT need again): the printer/drawer value sets, the ProgIDs
    (RecPrinter.POSPrinter.SOU / Standard.CashDrawer.SOU), and that Open() returns 0
    with no hardware.

    Invocation (ELEVATED):
        powershell -ExecutionPolicy Bypass -File .\Collect-PrinterFingerprint.ps1
        powershell -ExecutionPolicy Bypass -File .\Collect-PrinterFingerprint.ps1 -SnapshotOnly

    It writes ONE report file to the Desktop and prints the path. Send that file back.
#>
[CmdletBinding()]
param(
    [switch]$SnapshotOnly,      # read current state only; do not touch the hardware
    [string]$PrinterName,       # override the printer LDN (default <COMPUTERNAME>_Printer)
    [string]$DrawerName         # override the drawer  LDN (default <COMPUTERNAME>_Drawer)
)

$ErrorActionPreference = 'Continue'
$OposRoots  = @('HKLM:\SOFTWARE\WOW6432Node\OLEforRetail', 'HKLM:\SOFTWARE\OLEforRetail')
$InstDir    = 'C:\Program Files (x86)\OPOS\StdOPOS2.84'
$Ps32       = "$env:WINDIR\SysWOW64\WindowsPowerShell\v1.0\powershell.exe"
if (-not $PrinterName) { $PrinterName = "$env:COMPUTERNAME`_Printer" }
if (-not $DrawerName)  { $DrawerName  = "$env:COMPUTERNAME`_Drawer" }
# GetFolderPath, not $env:USERPROFILE\Desktop: a OneDrive-redirected Desktop makes that
# path nonexistent, Start-Transcript then fails and the closing Stop-Transcript throws.
$Desktop    = [Environment]::GetFolderPath('Desktop')
if (-not $Desktop -or -not (Test-Path $Desktop)) { $Desktop = $env:USERPROFILE }
$ReportPath = Join-Path $Desktop ("PrinterFingerprint_{0}_{1:yyyyMMdd_HHmmss}.txt" -f $env:COMPUTERNAME, (Get-Date))

function Section($t) { Write-Host ''; Write-Host ('=' * 72); Write-Host "== $t"; Write-Host ('=' * 72) }

# --- helpers ---------------------------------------------------------------

# Full recursive dump of a registry subtree, values typed, default shown as (Default).
function Dump-Key($path, $indent = '  ') {
    if (-not (Test-Path $path)) { Write-Host "$indent(absent) $path"; return }
    $k = Get-Item $path -ErrorAction SilentlyContinue
    if (-not $k) { return }
    Write-Host ("{0}[{1}]" -f $indent, ($k.Name -replace '^HKEY_LOCAL_MACHINE\\', 'HKLM:\'))
    foreach ($n in ($k.GetValueNames() | Sort-Object)) {
        $disp = if ($n -eq '') { '(Default)' } else { $n }
        Write-Host ("{0}    {1,-8} {2,-18} = {3}" -f $indent, $k.GetValueKind($n), $disp, $k.GetValue($n))
    }
    foreach ($c in ($k.GetSubKeyNames() | Sort-Object)) { Dump-Key (Join-Path $path $c) ($indent + '  ') }
}

# ProgID -> CLSID -> InprocServer32. NOTE the redirection asymmetry: under
# HKLM\SOFTWARE\Classes the ProgID keys are SHARED (not redirected), while CLSID
# keys ARE redirected - so a 32-bit SO's ProgID lives at ...\Classes\<ProgID> but
# its InprocServer32 lives at ...\Classes\WOW6432Node\CLSID\{...}. Looking for the
# ProgID under WOW6432Node returns "absent" and reads as a broken registration
# when nothing is wrong.
function Resolve-ProgId($progId) {
    $pk = "HKLM:\SOFTWARE\Classes\$progId"
    if (-not (Test-Path $pk)) { Write-Host ("  {0,-30} PROGID ABSENT" -f $progId); return }
    $clsid = if (Test-Path "$pk\CLSID") { (Get-Item "$pk\CLSID").GetValue('') } else { $null }
    Write-Host ("  {0,-30} CLSID = {1}" -f $progId, $(if ($clsid) { $clsid } else { '(none)' }))
    if (-not $clsid) { return }
    foreach ($v in @('HKLM:\SOFTWARE\Classes\WOW6432Node\CLSID', 'HKLM:\SOFTWARE\Classes\CLSID')) {
        $ip = "$v\$clsid\InprocServer32"
        if (Test-Path $ip) {
            $dll = (Get-Item $ip).GetValue('')
            # No 8.3 expansion needed: Test-Path resolves C:\PROGRA~2\... natively.
            Write-Host ("  {0,-30}   -> {1}" -f '', $dll)
            Write-Host ("  {0,-30}      on disk: {1}" -f '', (Test-Path $dll))
        }
    }
}

# --------------------------------------------------------------------------
Start-Transcript -Path $ReportPath -Append | Out-Null
Write-Host "POS-X printer / cash drawer OPOS FINGERPRINT - $(Get-Date)"
Write-Host "Machine : $env:COMPUTERNAME   User: $env:USERNAME"
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Write-Host "Elevated: $admin   Mode: $(if($SnapshotOnly){'SNAPSHOT-ONLY (no printing)'}else{'FULL (WILL PRINT A RECEIPT + OPEN THE DRAWER)'})"
Write-Host "Looking for LDNs: printer='$PrinterName'  drawer='$DrawerName'"

Section '1. OPOS device entries - both registry views, verbatim'
foreach ($r in $OposRoots) {
    Write-Host ""
    Write-Host "  --- $r ---"
    if (-not (Test-Path $r)) { Write-Host '    (absent)'; continue }
    Dump-Key "$r\ServiceOPOS" '    '
}
Write-Host ''
Write-Host '  Devices found, by class:'
$found = @()
foreach ($r in $OposRoots) {
    foreach ($cls in (Get-ChildItem "$r\ServiceOPOS" -ErrorAction SilentlyContinue)) {
        foreach ($dev in (Get-ChildItem $cls.PSPath -ErrorAction SilentlyContinue)) {
            $found += $dev.PSChildName
            Write-Host ("    {0,-12} {1}" -f $cls.PSChildName, $dev.PSChildName)
        }
    }
}
if (-not $found) { Write-Host '    NONE - the installer step did not run, or ran against a different name.' }
Write-Host ''
Write-Host ("  expected printer LDN present : {0}" -f ($found -contains $PrinterName))
Write-Host ("  expected drawer  LDN present : {0}" -f ($found -contains $DrawerName))

Section '2. ProgID -> CLSID -> InprocServer32'
foreach ($p in @('RecPrinter.POSPrinter.SOU','Standard.CashDrawer.SOU','OPOS.POSPrinter','OPOS.CashDrawer')) { Resolve-ProgId $p }

Section '3. USB printer PnP device  *** THE MOST VALUABLE PART - WE HAVE NO SAMPLE ***'
$pnp = @()
try {
    $pnp = @(Get-PnpDevice -ErrorAction SilentlyContinue |
             Where-Object { $_.Class -match '(?i)USB|Printer|Ports|WSDPRINT' -or $_.FriendlyName -match '(?i)printer|POS|thermal|receipt|sewoo|LK-' })
} catch { Write-Host "  Get-PnpDevice failed: $($_.Exception.Message)" }
if (-not $pnp) { Write-Host '  no candidate devices found' }
foreach ($d in $pnp) {
    Write-Host ("  {0,-10} {1,-8} {2}" -f $d.Status, $d.Class, $d.FriendlyName)
    Write-Host ("             InstanceId : {0}" -f $d.InstanceId)
    foreach ($pn in @('DEVPKEY_Device_DriverVersion','DEVPKEY_Device_Service','DEVPKEY_Device_LocationInfo')) {
        $v = (Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName $pn -ErrorAction SilentlyContinue).Data
        if ($v) { Write-Host ("             {0,-28} {1}" -f ($pn -replace '^DEVPKEY_Device_',''), $v) }
    }
}
Write-Host ''
Write-Host '  USBPRINT device-interface class {28d78fad-5a12-11d1-ae5b-0000f803a8c2}:'
Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceClasses\{28d78fad-5a12-11d1-ae5b-0000f803a8c2}' -ErrorAction SilentlyContinue |
    ForEach-Object { Write-Host ("    {0}" -f $_.PSChildName) }

Section '4. Vendor install state'
$hives = @('HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*')
$app = Get-ItemProperty $hives -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match 'OLE POS' } | Select-Object -First 1
if (-not $app) { Write-Host '  OLE POS Setup NOT in Add/Remove Programs - the driver is not installed.' }
else {
    Write-Host ("  DisplayName     : {0}" -f $app.DisplayName)
    Write-Host ("  PSChildName     : {0}" -f $app.PSChildName)
    Write-Host ("  UninstallString : {0}" -f $app.UninstallString)
}
Write-Host ''
if (Test-Path $InstDir) {
    Get-ChildItem $InstDir -Filter 'POSPrinterSO*.dll' -ErrorAction SilentlyContinue |
        ForEach-Object { Write-Host ("  {0,-22} v{1}  {2:yyyy-MM-dd}" -f $_.Name, $_.VersionInfo.FileVersion, $_.LastWriteTime) }
    Get-ChildItem $InstDir -Filter '*.ocx' -ErrorAction SilentlyContinue |
        ForEach-Object { Write-Host ("  {0,-22} v{1}" -f $_.Name, $_.VersionInfo.FileVersion) }
} else { Write-Host "  $InstDir absent" }

Section '5. Windows print stack - DIAGNOSTIC CONTEXT ONLY (nothing is expected here)'
$sp = Get-Service Spooler -ErrorAction SilentlyContinue
Write-Host ("  Spooler: {0} / StartType {1}" -f $(if($sp){$sp.Status}else{'absent'}), $(if($sp){$sp.StartType}else{'-'}))
Write-Host '  Get-Printer:'
Get-Printer -ErrorAction SilentlyContinue | ForEach-Object { Write-Host ("    {0,-34} port={1,-14} driver={2}" -f $_.Name, $_.PortName, $_.DriverName) }
Write-Host '  Get-PrinterPort (USB/COM only):'
Get-PrinterPort -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '(?i)^(USB|COM|LPT)' } | ForEach-Object { Write-Host ("    {0}" -f $_.Name) }
Write-Host '  (a queue appearing here is informative, NOT required: the print path is OPOS)'

if ($SnapshotOnly) {
    Section 'DONE (snapshot only - nothing was printed)'
    Write-Host "Report written to: $ReportPath  - send that file back."
    Stop-Transcript | Out-Null
    Write-Host ''
    Write-Host "REPORT FILE: $ReportPath"
    return
}

Section '6. LIVE OPOS PROBE - this prints a receipt and opens the drawer'
# The CCOs are 32-bit, so shell out to the WOW64 host rather than relaunching the
# whole script under it. Each call reports its own result code.
$probe = @"
`$ErrorActionPreference = 'Continue'
function RC(`$label, `$code) { Write-Host ('  {0,-34} {1}' -f `$label, `$code) }

Write-Host '  --- POSPrinter: $PrinterName ---'
try {
  `$p = New-Object -ComObject OPOS.POSPrinter
  RC "Open('$PrinterName')" `$p.Open('$PrinterName')
  Write-Host ('  ServiceObjectDescription : ' + `$p.ServiceObjectDescription)
  Write-Host ('  DeviceDescription        : ' + `$p.DeviceDescription)
  RC 'ClaimDevice(3000)' `$p.ClaimDevice(3000)
  Write-Host ('  Claimed                  : ' + `$p.Claimed)
  `$p.DeviceEnabled = `$true
  Write-Host ('  DeviceEnabled            : ' + `$p.DeviceEnabled)
  Write-Host ('  CapCoverSensor/CoverOpen : ' + `$p.CapCoverSensor + ' / ' + `$p.CoverOpen)
  Write-Host ('  RecEmpty / RecNearEnd    : ' + `$p.RecEmpty + ' / ' + `$p.RecNearEnd)
  Write-Host ('  RecLineChars             : ' + `$p.RecLineChars)
  RC 'PrintNormal(2, test)' `$p.PrintNormal(2, "AlleavesAuto OPOS test`n$env:COMPUTERNAME`n`n`n")
  Write-Host ('  ResultCode               : ' + `$p.ResultCode)
  try { `$p.DeviceEnabled = `$false; `$p.ReleaseDevice(); `$p.Close() } catch {}
} catch { Write-Host ('  POSPrinter probe threw: ' + `$_.Exception.Message) }

Write-Host ''
Write-Host '  --- CashDrawer: $DrawerName ---'
try {
  `$d = New-Object -ComObject OPOS.CashDrawer
  RC "Open('$DrawerName')" `$d.Open('$DrawerName')
  RC 'ClaimDevice(3000)' `$d.ClaimDevice(3000)
  `$d.DeviceEnabled = `$true
  Write-Host ('  DrawerOpened (before)    : ' + `$d.DrawerOpened)
  RC 'OpenDrawer()' `$d.OpenDrawer()
  Write-Host ('  ResultCode               : ' + `$d.ResultCode)
  try { `$d.DeviceEnabled = `$false; `$d.ReleaseDevice(); `$d.Close() } catch {}
} catch { Write-Host ('  CashDrawer probe threw: ' + `$_.Exception.Message) }

Write-Host ''
Write-Host '  OPOS codes: 0=OK 101=CLOSED 103=NOTCLAIMED 104=NOSERVICE 105=DISABLED'
Write-Host '              106=ILLEGAL 107=NOHARDWARE 108=OFFLINE 109=NOEXIST 111=FAILURE 112=TIMEOUT'
"@
$probeFile = Join-Path $env:TEMP 'alleaves_printer_probe.ps1'
Set-Content -Path $probeFile -Value $probe -Encoding ASCII
& $Ps32 -NoProfile -ExecutionPolicy Bypass -File $probeFile 2>&1 | ForEach-Object { Write-Host $_ }
Remove-Item $probeFile -Force -ErrorAction SilentlyContinue

Section '7. SUMMARY (paste this back)'
Write-Host ("  machine        : {0}" -f $env:COMPUTERNAME)
Write-Host ("  printer LDN    : {0}   present={1}" -f $PrinterName, ($found -contains $PrinterName))
Write-Host ("  drawer  LDN    : {0}   present={1}" -f $DrawerName, ($found -contains $DrawerName))
Write-Host ("  driver in ARP  : {0}" -f [bool]$app)
Write-Host ("  USB candidates : {0}" -f @($pnp).Count)
Write-Host '  -> record the row in docs/PRINTER_OPOS_FIELD_RESULTS.md'

Section 'DONE'
Write-Host "Report written to: $ReportPath  - send that file back."
Stop-Transcript | Out-Null
Write-Host ''
Write-Host "REPORT FILE: $ReportPath"
