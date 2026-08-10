<#
    Collect-ScannerFingerprint.ps1
    ------------------------------------------------------------------------------
    Run this on a terminal whose Zebra scanner is STILL PRE-OPOS (factory USB
    HID-Keyboard, or any non-OPOS mode). It captures the exact data still missing to
    finalize the AlleavesAuto USB-OPOS auto-config:

      1. the per-mode "fingerprint" (GetScanners <type> + <PID> + <serial>) for
         HID-Keyboard, IBM Hand-held, and OPOS  -> confirms the type strings the installer
         matches on ($ScannerTypeHidKb / $ScannerTypeIbmSnapi) and gives a full fingerprint
         for any non-DS2208 model
      2. the REAL in-session ExecCommand status per hop (does status 112 "Device
         Unavailable" occur, and does ensuring the Zebra services + retrying clear it?)
      3. the measured USB re-enumeration time per hop -> validates the installer's adaptive
         re-enum poll and confirms its ceiling $ScannerReenumMaxWaitSec is comfortable

    By DEFAULT it performs the full walk **HID-KB -> IBM Hand-held -> OPOS** (the same
    two-hop the installer does), so a fresh terminal ends up correctly in OPOS - the
    switch is the desired outcome AND the source of the data. Use -SnapshotOnly to just
    read the current state with NO changes.

    Already known (do NOT need again): OPOS = type "USBOPOS" / PID 4864 (0x1300) on the
    DS2208; services CoreScanner / rsmdriverproviderservice / ScnSrvc.

    Run in an ADMIN PowerShell (COM + service start + the switch need admin):
        powershell -NoProfile -ExecutionPolicy Bypass -File .\Collect-ScannerFingerprint.ps1
        powershell -NoProfile -ExecutionPolicy Bypass -File .\Collect-ScannerFingerprint.ps1 -SnapshotOnly

    It writes ONE report file to the Desktop and prints the path. Send that file back.
#>
[CmdletBinding()]
param(
    [switch]$SnapshotOnly,      # read current state only, change nothing
    [int]$MaxWaitSec = 40,      # max seconds to wait for a re-enumeration per hop
    [int]$MaxRetry   = 4        # attempts per hop while ExecCommand returns 112
)

$ErrorActionPreference = 'Continue'
$InteropDll = 'C:\Program Files\Zebra Technologies\Barcode Scanners\Common\Interop.CoreScanner.dll'
$Opcode     = 6200
$CodeIbm    = 'XUA-45001-1'    # -> USB IBM Hand-held
$CodeOpos   = 'XUA-45001-8'    # -> USB OPOS
$SvcNames   = @('CoreScanner', 'rsmdriverproviderservice', 'ScnSrvc')
$ReportPath = Join-Path $env:USERPROFILE ("Desktop\ScannerFingerprint_{0}_{1:yyyyMMdd_HHmmss}.txt" -f $env:COMPUTERNAME, (Get-Date))

function Section($t) { Write-Host ''; Write-Host ('=' * 72); Write-Host "== $t"; Write-Host ('=' * 72) }

# --- CoreScanner helpers ---------------------------------------------------
function Get-Inv($obj) {
    $c = [int16]0; $ids = New-Object int16[] 255; $xml = ''; $st = 0
    try { $obj.GetScanners([ref]$c, $ids, [ref]$xml, [ref]$st) } catch { return @() }
    $list = @()
    if ($xml) {
        try {
            [xml]$x = $xml
            foreach ($n in @($x.scanners.scanner)) {
                if (-not $n) { continue }
                $list += [pscustomobject]@{
                    Id       = [int]("$($n.scannerID)".Trim())
                    Type     = "$($n.type)".Trim()
                    Model    = "$($n.modelnumber)".Trim()
                    Serial   = "$($n.serialnumber)".Trim()
                    PID      = "$($n.PID)".Trim()
                    VID      = "$($n.VID)".Trim()
                    Firmware = "$($n.firmware)".Trim()
                }
            }
        } catch {}
    }
    return ,$list
}
function Ensure-Services {
    $out = @()
    foreach ($n in $SvcNames) {
        $s = Get-Service -Name $n -ErrorAction SilentlyContinue
        if (-not $s) { $out += "  MISSING service: $n"; continue }
        if ($s.Status -ne 'Running') {
            try { Start-Service -Name $n -ErrorAction Stop; $out += "  started $n (was $($s.Status))" }
            catch { $out += "  could NOT start $n : $($_.Exception.Message)" }
        } else { $out += "  $n : Running" }
    }
    $out | ForEach-Object { Write-Host $_ }
}
function Invoke-Hop($obj, $id, $code, $label) {
    # ExecCommand(6200) with 112-retry (re-ensure services between tries). Returns hashtable.
    $inXml = "<inArgs><scannerID>$id</scannerID><cmdArgs><arg-string>$code</arg-string><arg-bool>TRUE</arg-bool><arg-bool>TRUE</arg-bool></cmdArgs></inArgs>"
    $st = -1; $attempts = 0
    for ($t = 1; $t -le $MaxRetry; $t++) {
        $attempts = $t; $o = ''; $st = 0
        try { $obj.ExecCommand($Opcode, [ref]$inXml, [ref]$o, [ref]$st) }
        catch { Write-Host "    $label ExecCommand threw: $($_.Exception.Message)"; $st = -1 }
        Write-Host "    $label ($code) attempt $t -> status $st  (112 = Device Unavailable / RSM not ready)"
        if ($st -ne 112) { break }
        if ($t -lt $MaxRetry) { Write-Host '      status 112 - re-ensuring services + waiting 5s, then retry'; Ensure-Services; Start-Sleep -Seconds 5 }
    }
    return @{ Status = [int]$st; Attempts = $attempts }
}
function Wait-Reenum($obj, $preId, $preType, $maxWait) {
    # Poll GetScanners until a scanner appears whose Id OR Type changed from pre-hop.
    # Returns @{ Scanner; Seconds }. 1-scanner terminal assumption.
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $found = $null
    while ($sw.Elapsed.TotalSeconds -lt $maxWait) {
        Start-Sleep -Milliseconds 1000
        $inv = Get-Inv $obj
        if ($inv.Count -ge 1) {
            $cand = $inv | Where-Object { $_.Id -ne $preId -or $_.Type -ne $preType } | Select-Object -First 1
            if (-not $cand -and $inv.Count -eq 1) { $cand = $inv[0] }   # single unit, mode may read same pre-managed
            if ($cand) { $found = $cand; break }
        }
    }
    $sw.Stop()
    return @{ Scanner = $found; Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1) }
}
function Dump($tag, $s) {
    if (-not $s) { Write-Host "  [$tag] (no scanner)"; return }
    Write-Host ("  [{0}] type='{1}'  pid={2}  serial='{3}'  model='{4}'  id={5}  fw='{6}'" -f `
        $tag, $s.Type, $s.PID, $s.Serial, $s.Model, $s.Id, $s.Firmware)
}

# --------------------------------------------------------------------------
Start-Transcript -Path $ReportPath -Append | Out-Null
Write-Host "Zebra scanner FINGERPRINT (pre-OPOS) - $(Get-Date)"
Write-Host "Machine : $env:COMPUTERNAME   User: $env:USERNAME"
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Write-Host "Elevated: $admin   Mode: $(if($SnapshotOnly){'SNAPSHOT-ONLY (no changes)'}else{'FULL WALK HID-KB -> IBM -> OPOS'})"

Section '1. Zebra services'
if ($SnapshotOnly) {
    Get-Service -Name $SvcNames -ErrorAction SilentlyContinue | Select-Object Name, DisplayName, Status, StartType | Format-Table -AutoSize | Out-String | Write-Host
} else { Ensure-Services }

Section '2. CoreScanner + DLL'
if (-not (Test-Path $InteropDll)) {
    Write-Host "  MISSING: $InteropDll  - run the full Install-Alleaves.bat first, then re-run this."
    Stop-Transcript | Out-Null; Write-Host "REPORT FILE: $ReportPath"; return
}
$fi = Get-Item $InteropDll
Write-Host "  Interop.CoreScanner.dll version $($fi.VersionInfo.FileVersion)  (modified $($fi.LastWriteTime))"

$obj = $null
try {
    [System.Reflection.Assembly]::LoadFile($InteropDll) | Out-Null
    $obj = New-Object Interop.CoreScanner.CCoreScannerClass
    $status = 0; $types = New-Object int16[] 1; $types[0] = 1
    $obj.Open(0, $types, [int16]1, [ref]$status)
    Write-Host "  Open() status = $status  (0 = ok)"

    Section '3. Current (pre-OPOS) fingerprint - raw OutXML'
    $c = [int16]0; $ids = New-Object int16[] 255; $xml = ''; $st = 0
    $obj.GetScanners([ref]$c, $ids, [ref]$xml, [ref]$st)
    Write-Host "  count = $c  status = $st"
    Write-Host $xml
    $inv = Get-Inv $obj
    if ($inv.Count -eq 0) { Write-Host '  NO scanner reported. Plug it in / try another USB port, then re-run.'; throw 'no scanner' }
    if ($inv.Count -gt 1) { Write-Host "  NOTE: $($inv.Count) scanners present - this script assumes 1. Using the first." }
    $start = $inv[0]
    Dump 'START' $start
    $isOpos = $start.Type -match 'OPOS'
    if ($isOpos) { Write-Host '  Scanner is ALREADY in OPOS (type~OPOS). This box is not pre-OPOS; run on a HID-KB unit for the fingerprints.' }

    if ($SnapshotOnly -or $isOpos) {
        Section 'DONE (snapshot only / already OPOS)'
    } else {
        Section '4. HOP 1 : (HID-KB) -> IBM Hand-held'
        $r1 = Invoke-Hop $obj $start.Id $CodeIbm 'hop1 IBM'
        $w1 = Wait-Reenum $obj $start.Id $start.Type $MaxWaitSec
        Write-Host "  re-enumerated in $($w1.Seconds)s"
        Dump 'AFTER-HOP1 (IBM)' $w1.Scanner

        if ($w1.Scanner) {
            Section '5. HOP 2 : IBM Hand-held -> OPOS'
            $r2 = Invoke-Hop $obj $w1.Scanner.Id $CodeOpos 'hop2 OPOS'
            $w2 = Wait-Reenum $obj $w1.Scanner.Id $w1.Scanner.Type $MaxWaitSec
            Write-Host "  re-enumerated in $($w2.Seconds)s"
            Dump 'AFTER-HOP2 (OPOS)' $w2.Scanner

            Section '6. SUMMARY (paste this back)'
            Dump 'HID-KB (start)  ' $start
            Dump 'IBM  (after hop1)' $w1.Scanner
            Dump 'OPOS (after hop2)' $w2.Scanner
            Write-Host ''
            Write-Host "  hop1 status=$($r1.Status) attempts=$($r1.Attempts) reconnect=$($w1.Seconds)s"
            Write-Host "  hop2 status=$($r2.Status) attempts=$($r2.Attempts) reconnect=$($w2.Seconds)s"
            $finalOpos = $w2.Scanner -and ($w2.Scanner.Type -match 'OPOS')
            Write-Host "  FINAL OPOS confirmed: $finalOpos"
            Write-Host '  -> record: HID-KB type/PID, IBM type/PID, whether 112 appeared + cleared, and the two reconnect times.'
        } else {
            Write-Host '  scanner did not re-enumerate after hop1 - stopping. Note the hop1 status above.'
        }
    }
} catch {
    Write-Host "  probe failed: $($_.Exception.Message)"
} finally {
    if ($obj) { try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($obj) | Out-Null } catch {} }
}

Section 'DONE'
Write-Host "Report written to: $ReportPath  - send that file back."
Stop-Transcript | Out-Null
Write-Host ''
Write-Host "REPORT FILE: $ReportPath"
