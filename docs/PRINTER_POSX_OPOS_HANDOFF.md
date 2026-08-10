# POS-X Receipt Printer (OPOS) — Implementation Handoff

> **Self-contained.** Everything needed to execute with zero prior conversation.
> Repo: `C:\Users\xpc\Desktop\AI\Code\AlleavesAuto` · branch `docs-readme-claude-refresh`
> Rev 2, 2026-08-10. All line numbers refer to `alleaves_setup.ps1` @ 2832 lines and were
> re-verified against source on 2026-08-10.

---

## 0. Goal and scope

Add receipt-printer setup to the AlleavesAuto installer. The eventual UX is a prompt after the
computer-name entry: **brand**, then **type**.

**Scope is exactly one package: the POS-X OPOS driver (`OLE POS Setup 2.84`).**

Established from the user, and load-bearing for every decision below:

- The print path is **OPOS**. "We make sure it's marked as an OPOS thermal printer, then Alleaves
  Terminal reads the data and sends it to alleaves.com." It is **not** the Windows print queue.
- **"Type" = the OPOS device type.** For POS-X over USB that is **`ThermalU`**.
- Printers connect by **USB**.
- **No Windows print driver is installed on a real terminal.** OPOS is the entire path. (This is
  why Q5 in §4 is a risk check, not an optimization.)
- **No printer hardware is available for testing.** First contact with a real unit is in the
  field — which is why §8's fingerprint collector exists.

Out of scope: **Star TSP and Epson** (the brand prompt selects them and warns "not yet
implemented"). Also out of scope, and deliberately so: **any Windows print driver**, `pnputil`,
`Add-PrinterDriver`, print monitors, and print queues. A previous revision of this document
covered a `POS-X Thermal Printer 4.64` Windows driver package; that package was linked in error,
is not part of this work, and every trace of it has been removed from this document.

`alleaves_setup.ps1:652` currently reads
`# SKIP (phase-2 drivers, not installed today): Star TSP 100, OLE POS Setup.` — this work removes
`OLE POS Setup` from that SKIP list.

---

## 1. The package (verified by extraction, not inference)

| | |
|---|---|
| Google Drive id | `1y14kZ2g4Bwqhi9M0inszCCi_TREkNaH0` |
| Drive filename | `OLE POS Setup_v2.84.exe` |
| Vendor mirror | `https://px-download.s3.amazonaws.com/Receipt_Printer_OPOS_Driver.exe` |
| Bytes | 8,771,516 |
| SHA256 | `F4FAD6E096065892C51D88CBE43AB7585BD4B9EE8E737D1C731BF1C38BC5D67E` |
| Outer stub | InstallShield **PackageForTheWeb** (`InternalName=stub32`, `OriginalFilename=stub32i.exe`) — **unsigned** |
| Inner engine | **InstallShield 5.52** (5,52,164,0) InstallScript |
| Cab header version | `0x01005201` → major 5 |
| `AppName` | `OLE POS Setup 2.84` |
| ProductGUID | *(IS5 — none in `SETUP.INI`)* |
| Vendor string | **`CompanyName=LK`** ← the real OEM |
| MSCF carve offset | 296422 |

**Not a Basic MSI.** InstallScript. There is no MSI anywhere in the package — which is why the
MSI fallback in §3.6 must be suppressed rather than left to fire.

Downloaded and **SHA256-verified on 2026-08-10** from the vendor mirror; the hash matches the
Drive copy's recorded hash exactly, so the two are the same genuine vendor build. Working copy:
`…\scratchpad\posx\OLE POS Setup_v2.84.exe`.

### Extraction method (reproducible, executes nothing)

Read the `.exe`, find the `MSCF` signature whose header is valid (`reserved1==0`, version `1.3`),
carve `cbCabinet` bytes to a `.cab`, then `expand.exe <cab> -F:* <outdir>`. The container sits in
the PE overlay. **Caveat:** everything inside the IS5 `data1.cab` is compressed (verified), so
reading the payload files themselves needs `unshield` or `7z` — neither is on this box. The
simpler route is to just install the package (Q6) and read them from disk.

### Payload

- `SetupPOS.exe` — a VB6 8-step wizard (`frmStep1..8.frm`). This is the GUI whose registry
  output we are replacing.
- Service objects: `POSPrinterSO.dll` (serial), **`POSPrinterSOU.dll` (USB — ours)**,
  `POSPrinterSON.dll` (network), `POSPrinterSOP.dll` (parallel).
- CCOs: `OPOSPOSPrinter.ocx`, `OPOSCashDrawer.ocx`; `Interop.*`/`AxInterop.*` for OPOS 1.5/1.8/CCO.
- `Thermal.inf`, `StdCash.inf`, `DotP2/3/4.inf`, `DotPD30.inf`, `USBPrint.inf` + `USBPrint.sys`.
- FTDI VCP: `FTDIBUS.INF/.CAT`, `FTDIPORT.INF/.CAT`, `ftdibus.sys`, `ftser2k.sys`.
- `NVUpload.exe`, `USBSNChanger.exe`; VB/C#/VC samples (`LKPrint.cs`, `LKPrint.vb`).
- Features: `SetupPOS`, `NV logo Setup`, `VB Sample`, `VC Sample`, `USB Driver Files(2004)`,
  `USB Driver Files(2005)`. Setup types: `Typical` / `Compact` / `Custom`.
- `SETUP.INI` has **`EnableLangDlg=Y`** — see the `/L0x0409` note in §3.1.

Two payload facts worth carrying into Q3 and Q5:

- **`Thermal.inf` / `StdCash.inf` are probably not Windows INFs.** A cash drawer on an RJ-11 is
  not a PnP device, so these are very likely **SetupPOS device-type definition files** and may
  contain the `ThermalU` / `ThermalS` definitions outright. Read them first at Q3 — it is a free
  head start on the registry contract.
- **`USBPrint.inf` + `USBPrint.sys` is the leading hypothesis for Q5.** `USBPrint.sys` is the
  kernel driver that exposes a USB printer's device interface
  (`{28d78fad-5a12-11d1-ae5b-0000f803a8c2}`). An application can `CreateFile` that interface
  directly, **bypassing the spooler and needing no print queue**. If `POSPrinterSOU.dll` does
  that, the "no Windows print driver" design is sound. Confirm by imports, don't assume.

### Signing

The **only** `.cat` files in the package are FTDI's. `Thermal.inf`, `StdCash.inf`, `USBPrint.inf`
and `DotP*.inf` have **no catalog — unsigned**. The outer `.exe` is unsigned; only the inner
InstallShield `setup.exe` engine carries a valid (InstallShield's own) signature.

This does **not** block anything: we never stage an INF through PnP/the DriverStore, so the
"unsigned INF blocks `pnputil /add-driver` on Win10/11 x64" problem is not on this path. The
vendor installer's own COM self-registration is what matters, and that is unaffected by INF
signing.

---

## 2. State of the dev box

`C:\Users\xpc\Desktop\AI\Code\AlleavesAuto` — **this machine is the authorized test rig.**

> **SUPERSEDED 2026-08-10 (later same day).** The bullets below described the box *before*
> a working session installed things on it. Re-verified state follows underneath — read that,
> not the struck-through original.

Originally verified 2026-08-10 (**now stale**):

- ~~**No OPOS anywhere.** `HKLM\SOFTWARE\OLEforRetail` and `HKLM\SOFTWARE\WOW6432Node\OLEforRetail`
  both absent. No `C:\Program Files (x86)\OPOS`.~~
- **Alleaves Terminal is not installed.** **POS for .NET is not installed.** (Both matter for Q4.)
  — still true.
- Print Spooler is **Running**, `StartType` **Manual**.
- `C:\Program Files (x86)\InstallShield Installation Information` holds `{8833FFB6-…}` and
  `{F132AF7F-…}` from unrelated products — useful as a reminder that the folder is shared and
  must never be swept indiscriminately.
- A `POS-X Thermal Printer 4.64` package was installed here in error and is being removed
  (`scratchpad\posx\Remove-ThermalPackage.ps1`). It must be **fully gone** before Q3, or its
  leftovers pollute the before/after registry diffs. Nothing in this document depends on it.
  — **still present**, still to be removed.

### Re-verified state, 2026-08-10

**`OLE POS Setup 2.84` is already installed on this box** (`Uninst.isu` timestamped 03:02).
The `.iss` recording (Q6a) therefore needs a clean state first — see the revised order in §4.

- `HKLM\SOFTWARE\WOW6432Node\OLEforRetail` **exists**, but holds **only**
  `ServiceInfo\OLE OPOS\OPOS 2.81` (`OposDir`, `Title=OLE POS Printer`, `Language=US`,
  `Version=1.13.1`; parent has `ConfigList=OPOS 1.0.0`).
  **There is no `ServiceOPOS` branch at all** — so the Q3 before/after diff is still clean,
  and §3.5's key-removal fix must handle **three** created levels (`ServiceOPOS`,
  `ServiceOPOS\POSPrinter`, `…\<logicalName>`) while preserving the pre-existing
  `OLEforRetail` parent. `HKLM\SOFTWARE\OLEforRetail` (native view) is still absent.
- `C:\Program Files (x86)\OPOS\StdOPOS2.84\` exists with the full payload §1 predicted:
  `SetupPOS.exe`, `POSPrinterSO{,N,P,U}.dll` (all FileVersion `2, 84, 0, 0`),
  `OPOSPOSPrinter.ocx` / `OPOSCashDrawer.ocx` (`1, 13, 001, 0`), `Thermal.inf`, `StdCash.inf`,
  `DotP*.inf`, `NVUpload.exe`, the FTDI `USBDriver\` tree, and the VB/C# samples.
- **COM registration succeeded and is correct** (so §5's architecture split is validated):

  | ProgID | CLSID | InprocServer32 |
  |---|---|---|
  | `RecPrinter.POSPrinter.SOU` | `{86D3697F-5C7A-48DF-8A63-243C4D06297C}` | `C:\PROGRA~2\OPOS\StdOPOS2.84\POSPrinterSOU.dll` |
  | `OPOS.POSPrinter` (CCO) | `{CCB90152-B81E-11D2-AB74-0040054C3719}` | `…\StdOPOS2.84\OPOSPOSPrinter.ocx` |

  `RecPrinter.POSPrinter.{SO,SON,SOP}` and `Standard.CashDrawer.{SO,SON,SOP,SOU}` are
  registered too. **Registry-view trap worth knowing:** under `HKLM\SOFTWARE\Classes`,
  **ProgID keys are NOT redirected** (they live in the shared view, so they appear at
  `HKLM:\SOFTWARE\Classes\<ProgID>` and *not* under `…\Classes\WOW6432Node\`), while
  **CLSID keys ARE redirected** (the 32-bit `InprocServer32` is under
  `…\Classes\WOW6432Node\CLSID\{…}`). Looking for the ProgID in the WOW6432Node view returns
  "absent" and reads as a failed registration when nothing is wrong.
  Note the CCO CLSID fits the `{CCB90##2-B81E-11D2-AB74-0040054C3719}` range in Q4's
  `DllSurrogate` reserve plan (`##` = `15` for POSPrinter).

---

## 3. Defects in `alleaves_setup.ps1` that block this work

All verified against source on 2026-08-10. These are not speculative. §3.1 and §3.2 are hard
blockers — today the installer would report a killed, half-copied install as success.

### 3.1 BLOCKER — `Invoke-IssSilent` sends its switches to the wrong process

`:1126` builds `$argLine = "-s -f1`"$issPath`" -f2`"$log`""` and `:1136` sets
`$psi.FileName = $WrapperPath` — i.e. the **PackageForTheWeb stub**. PFTW has its own switch
namespace and swallows anything it does not own. It forwards to the inner `setup.exe` **only
after `/a`**.

`$argLine` is a fixed literal; only `$issPath` and `$log` vary. There is **no mechanism to emit a
prefix** — the `$Installers` rows for `.iss` items carry no `Args` key. Needs a `-WrapperArgs`
parameter.

Correct forms (`/a` last among wrapper switches; **no space** after `/f1`/`/f2`; never mix `-`
and `/` in one line):

```
install:   pkg.exe /s /a /s /L0x0409 /f1"C:\...\x.iss" /f2"C:\...\x.log"
record:    pkg.exe /a /r /f1"C:\...\x.iss"          <- NO outer /s when recording
```

Two `/s` is intentional: the first silences the wrapper, the second is forwarded to the inner
setup. **`/L0x0409` is required** because `SETUP.INI` has `EnableLangDlg=Y` and the language
dialog is shown by the launcher *before* the engine starts — so it is **not** captured in the
recorded `.iss` and must be suppressed on the command line.

### 3.2 BLOCKER — the registry short-circuit reports a killed install as success

`:1171`, the first statement of each poll iteration:

```powershell
if (Find-InstalledProducts -Pattern $DisplayNameMatch) { Start-Sleep -Seconds 2; break }
```

For **MSI** products (Zebra) the ARP entry appears when msiexec commits, near the end — safe.
For **InstallScript** (our package) `DeinstallStart()` creates the ARP entry **before file
transfer**. Sequence:

1. ARP key appears while files are still copying
2. `:1171` fires → `break`
3. `:1185-1187` force-kills every process named `setup` started after `$launchTime` — **the live
   worker, mid-copy**
4. `:1196` `$regOk = $true`
5. `:1204` `if ($logOk -or $regOk)` → records **`result='ok'`**, returns `'ok'`

A half-copied, killed install recorded as success, exit 0. It then compounds: `:1441` skips the
product on re-run ("already installed"), and `:2477` will try to uninstall it because
`result -eq 'ok'`.

**Fix:** make the `:1171` break conditional (`-RegistryShortCircuit:$false`), so for InstallScript
the exit condition is *worker-gone* (`$sawWorker -and $busy.Count -eq 0`) and registry presence is
checked **after** the loop, not as the break.

### 3.3 One worker-name list serving two opposite meanings

`'setup','ISBEW64','ISSetupPrerequisites'` is a **hardcoded literal at three sites**: `:1015`
(`Invoke-WrappedMsi`), `:1174` (processes to **wait for**, uses `$launchTime.AddMinutes(-1)`),
and `:1185` (orphans **safe to kill**, uses `$launchTime`). One list feeding both wait-for and
kill means telling it about the InstallScript workers would tell it to kill them.

**Fix:** introduce `-WaitNames` and `-ReapNames`, both defaulting to today's literal so the
validated Zebra path stays byte-identical. Pass **`-ReapNames @()`** for InstallScript — there is
no launcher/worker split to exploit.

IS5 worker process names for reference: **`_INS####._MP`** in `%TEMP%` — note .NET `ProcessName`
strips the final extension, so it enumerates as `_INS5576` and `Get-Process -Name '_INS*'` is the
way to match it. **`IKernel.exe` lingers after the install by design** — never use "ikernel
exited" as a completion signal, and **never kill it** (a killed instance blocks every later
InstallShield install until reboot).

### 3.4 `-ForceReinstall` pre-clean and silent uninstall are both wrong for InstallScript

`Remove-InstallShieldOrphans` (function `:398`, filter `:408`) requires
`PSChildName -like 'InstallShield_*'` **and** a non-empty `DisplayName` matching `$Pattern`. That
shape is specific to InstallScript **MSI** (the Zebra shape). An IS5 product does not register
that way, so the filter matches nothing and the `InstallShield Installation Information\{GUID}`
cache folder is never swept. The `$guid` derivation at `:414`
(`$_.PSChildName -replace '^InstallShield_',''`) is a no-op for any other shape.

The uninstall half is also wrong. `Invoke-SilentUninstall:352-357`:

```powershell
} elseif ($rest -match '(?i)-removeonly|isuninst|InstallShield') {
    if ($rest -notmatch '(?i)(^|\s)-s(\s|$)') { $rest = ($rest + ' -s').Trim() }
} elseif ($rest -notmatch '/S|/silent|/quiet|--silent') {
    $rest = ($rest + ' /S').Trim()
}
```

The match is against **`$rest` (the argument tail) only**, not the exe path. An IS5 uninstall
string is `C:\WINDOWS\IsUninst.exe -f"C:\…\DeIsL1.isu"` — `$rest` is just the `-f"…"`, which
matches **neither** `isuninst` nor `InstallShield` (both live in the exe path). So it falls
through to the generic `/S` at `:355`, which IS5 does not understand, and hangs against the 360 s
cap at `:216` / `:383-388`.

Correct IS5 invocation:

```
C:\WINDOWS\IsUninst.exe -y -a -f"C:\...\DeIsL1.isu"
```

`-a` silent, `-y` no confirm, `-f` the `.isu`. Preserve any `-c"<dll>"` present in the original
string. **`DeIsL1`/`DeIsL2`/`DeIsL3` numbering is machine-dependent — always read it from ARP,
never hardcode.** Some IS5 builds use `_isdel.exe` instead of `IsUninst.exe`; read the actual
`UninstallString` and branch on what is there. `IsUninst.exe` has been reported to hang when
launched as SYSTEM via PsExec — validate under the RMM's actual context.

~~The exact ARP shape this package registers is **unknown until Q6 installs it** — capture it then
and finalize both fixes against the real value.~~

> **UPDATED 2026-08-10 — the ARP shape is now captured (see Q6a), and it cancels half of this
> section.** `PSChildName` is the literal `OLE POS Setup 2.84`, there is **no** `InstallShield_*`
> entry and **no** `{GUID}` cache folder, and the `.isu` is `Uninst.isu` inside the install dir.
>
> - **`Remove-InstallShieldOrphans`: do NOT change it.** It matches nothing for this product
>   because this product creates none of the artifacts it sweeps. That is correct behaviour,
>   not the defect described above.
> - **`Invoke-SilentUninstall`: the defect is real and confirmed** — fix it by matching on the
>   **exe path** (`IsUninst.exe` / `_isdel.exe`), not `$rest`.
> - **`-ForceReinstall` is repaired for free** by that same fix: `:1397` already routes
>   pre-clean through `Invoke-SilentUninstall`.
>
> Exact flags (`-y -a -f"…"`, plus any `-c"<dll>"` preserved) still to be confirmed by running
> them at Q6b.

### 3.5 `Set-TrackedRegValue` creates keys it never removes

`:1567` `New-Item -Path $Path -Force` creates the whole path. `Invoke-UninstallPhase:2555-2582`
only ever calls `Remove-ItemProperty` / `New-ItemProperty` — there is **no `Remove-Item`** for
keys, and no `regKeysCreated` array in `New-InstallManifest:2634-2657`.

So `-Uninstall` would leave `…\OLEforRetail\ServiceOPOS\POSPrinter\Thermal` **plus three empty
parents** (`OLEforRetail`, `ServiceOPOS`, `POSPrinter` — none of which exist on this box in either
view). Not cosmetic: **OPOS control objects enumerate `ServiceOPOS\POSPrinter\*`**, so an empty
`Thermal` key is a phantom device Alleaves may list and fail to open. Violates the repo's
bootstrap + track + **reverse** bar.

~~**Fix:** add `regKeysCreated = @()`; record the deepest path that did *not* exist before the
`New-Item -Force`; remove after the value-restore loop, **deepest-first and only if empty**
(`ValueCount -eq 0 -and (Get-ChildItem).Count -eq 0`) so a co-installed vendor device is not nuked.~~

> **CORRECTED 2026-08-10 — the `ValueCount -eq 0` half of that guard is wrong and would defeat
> the whole fix.** Q2 measured it: a key whose only value is the `(default)` ProgID reports
> `ValueCount = 1`, so the guard never fires and the phantom device survives.
>
> **Corrected fix:** add `regKeysCreated = @()`; record the deepest path that did *not* exist
> before the `New-Item -Force`; after the value-restore loop remove them **deepest-first, guarded
> on subkeys only**:
>
> ```powershell
> if ((Get-Item $p).SubKeyCount -eq 0) { Remove-Item $p -Force }
> ```
>
> **Why subkeys-only is the right guard, not a laxer one:** a path in `regKeysCreated` by
> definition **did not exist before this run**, so every *value* under it is ours and counting
> values proves nothing. What genuinely needs protecting is a *co-installed vendor device* that
> landed underneath us — e.g. a second logical device added under `…\ServiceOPOS\POSPrinter`
> after we created that key. That shows up as a **subkey**, and `SubKeyCount -eq 0` catches it
> exactly. Simpler than the original and actually correct.
>
> Plain `Remove-Item -Force` (non-recursive) removes a default-value-only key fine, so no
> value cleanup is needed first — and `-Recurse` must **not** be used, or the subkey guard is
> pointless.
>
> Separately, fix the `prevAbsent` restore at `:2567` to handle a `(default)` value via a
> writable handle (`OpenSubKey($sub,$true).DeleteValue('',$false)`) — see Q2, Trap 2.
> `Remove-ItemProperty` **throws** on `(default)`, which would put a spurious error in every
> uninstall log even though the subsequent key removal makes the end state correct.

### 3.7 NEW, MEASURED 2026-08-10 — the IS5 command line has a hard length ceiling

Discovered the hard way: the first silent replay of the recorded `.iss` **failed** with
`Error Executing the Specified Program`, immediately followed by an access violation in the
PFTW stub (`The instruction at 0x00000000705C6461 referenced memory at 0x00000000705C6461.
The memory could not be read.`).

The error dialog was the diagnosis — it printed the command PFTW had assembled for the inner
engine:

```
"C:\Users\xpc\AppData\Local\Temp\pftC989.tmp\Setup.exe" /s /L0x0409
   /f1"C:\Users\...\claude\C--Users-xpc-Desktop-AI-Code-AlleavesAuto\<guid>\scratchpad\posx\replay.iss"
   /f2"C:\Users\...\<same enormous prefix>\replay.log" /SMS
```

So **forwarding was working perfectly** — PFTW consumed the leading `/s` and the `/a`, passed
everything after `/a` to the inner `Setup.exe`, and appended its own `/SMS`. The command line
was simply **~390 characters**, and IS 5.52 is a 1998-era engine with fixed buffers. It
overran and crashed.

Re-running the **identical** command with the paths `Invoke-IssSilent` actually uses:

| | Take 1 (crashed) | Take 2 (succeeded) |
|---|---|---|
| `/f1` | 150 chars (scratchpad) | 49 chars — `C:\ProgramData\AlleavesAuto\downloads\oleposs.iss` |
| `/f2` | 150 chars (scratchpad) | 57 chars — `C:\ProgramData\AlleavesAuto\logs\OLE_POS_Setup.silent.log` |
| inner command line | **~390 chars** | **190 chars** |
| Result | `Error Executing the Specified Program` + AV | **`ResultCode=0`, silent, 25.7 s, 200 files, ARP present** |

**Implications:**

- **The shipping configuration is safe.** `$DownloadDir` and `$LogDir` derive from the fixed
  `%ProgramData%\AlleavesAuto` root (`:1120-1121`), so the real inner command line is ~190
  chars with roughly 60+ chars of headroom before trouble. No guard code is warranted.
- **Never point `/f1` or `/f2` at a long path when testing.** A future debugging session that
  drops the `.iss` in a deep temp folder will see a crash that looks like a broken package and
  is not.
- The exact ceiling was not bisected — 190 works, 390 does not. Somewhere around a 256-byte
  buffer is the obvious suspect. Not worth pinning down further.

**Also measured in the same run — the real worker process names** (these validate `-WaitNames`
/ `-ReapNames` in §3.3):

```
Setup          (pid 20720)
_INS5576._MP   (pid 13000)
```

Note `Setup` is already covered by the existing default list. Note also that §3.3's claim that
.NET `ProcessName` "strips the final extension, so it enumerates as `_INS5576`" is **wrong** —
it enumerated as the full `_INS5576._MP`. Harmless, because a `_INS*` wildcard matches either
form, but do not rely on the stripped spelling.

### 3.6 Smaller but real

- **`Set-TrackedRegValue` has no internal `-DryRun` guard** (`:1555-1575` writes unconditionally).
  Both existing callers guard externally (`:1738` LayoutXMLPath, `:1788` UCPD `Start`). A new
  `Set-PrinterOpos` must do the same or `-DryRun` writes to HKLM. `Set-ScannerOpos:2294-2298` is
  the precedent for the *shape* of the leading guard (it writes no registry itself).
- **`-Name ''` vs `'(default)'`.** With `-Name ''` the read at `:1565` returns empty without
  throwing → `prevAbsent=$false`, `prev=''` → on uninstall `:2570-2577` writes `[string]''`,
  **silently clobbering** the pre-existing ProgID instead of restoring it. Use `'(default)'`.
  Whether `New-ItemProperty -Name '(default)' -PropertyType String` sets the *real* default value
  is **Q2**; if not, use `Set-Item -Path <key> -Value <data>`.
- **MSI fallback fires on an MSI-less package.** The gate at `:1456-1465` is three conditions
  ANDed (`$res -eq 'fail'` **and** not found in registry **and** no cached MSI). Our row defines
  no `CachedMsi`, so `Test-Path` is false and it falls straight through to
  `Invoke-WrappedMsi:943`, which launches the wrapper with **no args** (`:974` bare
  `Start-Process` → PFTW opens its GUI), polls `%TEMP%` for a `{GUID}\*.msi` > 1 MB for **600 s**
  (`:986-1010`), then kills helpers. Best case: 10 wasted minutes and a GUI on screen. Worst case:
  it picks up an **unrelated** `{GUID}` MSI left in `%TEMP%` by something else and runs
  `msiexec /i` on it. Add an explicit `NoMsiFallback`.
- **A reboot dialog would be fatal to the manifest.** If the recorded `.iss` does not pin
  `BootOption=0`, the engine can reboot mid-loop and `Copy-MasterList` (`:2753-2757`),
  `Set-ScannerOpos` (`:2762`) and `Save-Manifest` (`:2765`) never run — the manifest is never
  written, so **everything that did install becomes un-uninstallable**. The `finally`
  `Save-Manifest` at `:2828` does not survive a reboot either. Check the recorded dialog chain for
  a finish-reboot dialog and pin `BootOption=0` if present.
- **`Get-EmbeddedIss` (function `:1074`) writes ASCII at `:1085`.** Any non-ASCII in a recorded
  `.iss` (an accented `szDir`, a localized string — and this package has `EnableLangDlg=Y`) is
  silently mangled to `?`. **Verify the recorded file is pure ASCII before embedding.**
- **`ResultCode` parsing traps.** The log is written **early**, often with `ResultCode=0`, then
  **overwritten** on later failure — never read it while the worker is alive. The process exit
  code is meaningless. `-3` ("required data not found") is the common failure and means the
  `.iss` does not match the dialog sequence on that box. Full table:
  `0` ok · `-1` general · `-2` invalid mode · `-3` data not found in .iss · `-4` memory ·
  `-5` file not found · `-6` can't write response file · `-7` can't write log · `-8` invalid
  .iss path · `-9` invalid list type · `-10` invalid data type · `-11` unknown ·
  `-12` dialogs out of order · `-51` can't create folder · `-52` can't access file/folder ·
  `-53` invalid option.
  Also note `:1204` is `if ($logOk -or $regOk)` — an **OR**, not a double-check. With IS5 and an
  unforwarded `-f2` the log lands in the PFTW temp dir, which is deleted, so `$logOk` is
  permanently `$false` and success collapses to registry-only.
- **`Merge-PriorList:1481-1494`**: `:1488` `if ($k -and -not $have.ContainsKey($k))` — a **null
  key silently drops the prior entry**. `scannerConfigured` keys on `$e.serial`, which is `$null`
  on the dryrun/no-scanner paths. Do not copy that: key `printerConfigured` on the OPOS **logical
  name**, which is always non-null.
- **`removable=$false` is decorative** on `scannerConfigured` — it is only honoured in the
  `dependencies` loop (`:2532`), and `Invoke-UninstallPhase` never reads `scannerConfigured`. The
  printer OPOS entry genuinely **is** reversible, so do not cargo-cult it.
- **Exit code 7 is free** (`.ps1` uses 0-6; `build-bat.ps1:91` reserves 9; the `.bat` translates
  nothing — `:102` `set "RC=%ERRORLEVEL%"`, `:111` `exit /b %RC%`). Define it as **"OPOS device
  registration failed"**. It is genuinely settable with **no printer attached**, because the
  registry writes succeed or fail regardless of hardware. Non-fatal, set only when nothing else
  failed — same discipline as `4`/`6`, never masking `1`.
- **`build-bat.ps1:65`** double-wraps args through cmd `%*` and a PS single-quoted string on the
  non-elevated relaunch — keep `-PrinterBrand` values **single-word, no spaces or apostrophes**.
- **`ALLEAVES_REQUESTED_MODE`** is set only by `echo %*| find /i "-uninstall"`
  (`build-bat.ps1:71-72`), so new switches are invisible to it and the `:112-122` guard behaves
  correctly (mode `install`, same as `-ScannerConfigOnly`). **No `.bat` logic change needed** —
  but the `.bat` **must be rebuilt** because it embeds the `.ps1` as base64.

---

## 4. Open questions — ALL need an ELEVATED PowerShell

Answers get recorded back into this document as `> **ANSWERED <date>**` blocks under each
question, before moving to the next.

~~**Execution order: Q1 → Q2 → Q4 → Q6a → Q3 → Q5 → Q6b.**~~
~~Q3 needs the package installed and Q5 needs `POSPrinterSOU.dll` on disk — and **Q6's recording
runs are the same wizard passes that install and uninstall it**. Separating them costs two extra
install/uninstall cycles for no added information.~~

> **REVISED 2026-08-10.** The original order assumed a clean box with nothing answered. Neither
> holds: **Q1 and Q5 are answered** (see their blocks below), and the package is **already
> installed**, so a valid *install* `.iss` can only be recorded after returning to a clean state.
>
> **Revised order: [cleanup] → Q6b → Q2 → Q6a → Q3 → [replay proof] → Q4.**
>
> 1. **Cleanup** — remove the out-of-scope `POS-X Thermal Printer 4.64`
>    (`scratchpad\posx\Remove-ThermalPackage.ps1`), so its leftovers can't pollute the Q3 diffs.
> 2. **Q6b first**, using the *existing* install as the test subject. This both answers Q6b and
>    produces the clean state everything else needs.
> 3. **Q2** — 10 s, self-cleaning, order-independent.
> 4. **Q6a** — record the install `.iss` from the now-clean box; re-capture the ARP shape from a
>    known-good fresh install.
> 5. **Q3** — snapshot, run `SetupPOS.exe`, snapshot, diff.
> 6. **Replay proof** — uninstall again (re-exercising Q6b), then replay the recorded `.iss`
>    with the exact §3.1 command form and require `ResultCode=0` with **no GUI**. This is the
>    real validation of the command the installer will ship; Q1 only proved the switches arrive.
> 7. **Q4** — install Alleaves Terminal and grep its binaries. Deliberately last: it is the only
>    step that adds an unrelated product to the rig, and it is independent of everything above.

### Q1 — Does the PFTW stub forward `/a`? **(THE GATE)**

> **ANSWERED 2026-08-10 — YES. The gate is open.**
>
> Evidence: `C:\Users\xpc\Desktop\Q1_PftwForwarding_20260810_031341.txt` (a run of
> `Q1-Probe-PftwForwarding.ps1`), logs preserved in `C:\probe\`.
>
> | Pass | `/f1` target | `ResultCode` | Reads as |
> |---|---|---|---|
> | 1 | file does **not** exist | **-5** (file not found) | log written to `/f2`'s path ⇒ `/a` forwards, `/f2` honoured |
> | 2 | real file, empty `[DlgOrder]` | **-12** (dialogs out of order) | the engine **read and parsed our file** ⇒ `/f1` honoured |
>
> This is a clean A/B: the only thing that changed between the two runs was whether the `/f1`
> file existed, and the engine's complaint moved from "can't find it" to "its contents don't
> match my dialog chain". Both switches reach the inner IS 5.52 engine. The log landed exactly
> where `/f2` pointed — `%WINDIR%\setup.log` and `%WINDIR%\setup.iss` are both **absent**, so
> the §3.6 worry that an unforwarded `-f2` would strand the log in the deleted PFTW temp dir
> (leaving `$logOk` permanently `$false`) **does not apply**. Both runs emitted
> `Version=v5.00.000`, confirming the IS5 engine and not the wrapper answered.
>
> Command form proven end to end:
> `pkg.exe /s /a /s /L0x0409 /f1"<iss>" /f2"<log>"` — **all forward slashes**, no space after
> `/f1`/`/f2`.
>
> **Two caveats, neither affecting the conclusion:**
> 1. The probe ran **non-elevated** (`Elevated: False` in the transcript). Forwarding is a
>    wrapper/engine behaviour, not a privilege one, but the real install still needs admin.
> 2. The package was **already installed** when the probe ran, so the engine was in
>    **maintenance mode**. That is why pass 2 returned `-12` rather than the `-3` this section
>    predicted — `-3` ("required data not found") and `-12` ("dialogs out of order") both prove
>    the response file was read; only `-5`/`-8` would have meant it never arrived.
> 3. Consequence: the *install* `.iss` (Q6a) must still be recorded from a **clean** box, and
>    the recorded file must then be replayed silently to prove the real command. See the
>    revised order above.
>
> The **control run** (same command *without* `/a`, expecting a visible UI) was not performed —
> it needs a human to watch and cancel. It is no longer worth doing: passes 1 and 2 already
> prove forwarding positively, so the negative control adds nothing.

If it does not, silent install via the stub is dead and the whole approach must be re-planned
around extracting the inner engine instead of driving the wrapper. Everything else depends on this.

Zero-install probe — `nope.iss` does not exist, so nothing can install; the engine bails at
response-file load:

```powershell
mkdir C:\probe
& "<pkg>.exe" /s /a /s /L0x0409 /f1"C:\probe\nope.iss" /f2"C:\probe\probe.log"
```

- `C:\probe\probe.log` exists with a negative `ResultCode` → forwarding works, `/f1` and `/f2`
  both honoured. Command line proven end to end.
- No log anywhere and/or the UI appears → args swallowed by the wrapper.
- Log at `%WINDIR%\setup.log` instead → `/f2` ignored on that engine.

To disambiguate "was `/f1` honoured, or did it fall back to `%WINDIR%\setup.iss`?": put a file at
`C:\probe\nope.iss` containing a valid IS5 header (`Version=v5.00.000`) plus an empty
`[DlgOrder]`. **`-3` proves your file was read and parsed; `-5`/`-8` proves it was not.**

Control run: the same command **without** `/a` should show a visible UI. Cancel out; nothing is
written before the first dialog.

A ready-made probe script exists at `…\scratchpad\posx\Q1-Probe-PftwForwarding.ps1`. It caps each
run and kills on timeout (a still-alive run *is* the "swallowed" answer) so the shell cannot hang,
reads `ResultCode` only after the process is gone, and never touches `IKernel.exe`.

### Q2 — Does `New-ItemProperty -Name '(default)'` set the real default value?

> **ANSWERED 2026-08-10 — YES for writing. But probing it exposed two traps on the *removal*
> side that break §3.5's proposed fix as written.**
>
> **Writing works.** `New-ItemProperty -Name '(default)' -PropertyType String` sets the genuine
> default: `(Get-Item $k).GetValue('')` returns the data, the key's only value name is the
> empty/default one, and no literal value named `(default)` is created. `Set-Item -Path $k
> -Value <data>` is equivalent. **Use `-Name '(default)'`; the `Set-Item` fallback is not needed.**
>
> **Trap 1 — `ValueCount` counts the default value.** A key whose *only* value is the default
> reports `ValueCount = 1`, `SubKeyCount = 0`, `(Get-ChildItem).Count = 0`. So §3.5's proposed
> guard `ValueCount -eq 0 -and (Get-ChildItem).Count -eq 0` **would refuse to remove the very
> key it exists to remove**, leaving the phantom `…\POSPrinter\<name>` device behind — the exact
> failure §3.5 is written to prevent. Corrected guard is in §3.5.
>
> **Trap 2 — you cannot delete a default value with `Remove-ItemProperty`.** Measured:
>
> | Attempt | Result |
> |---|---|
> | `Remove-ItemProperty -Name '(default)'` | **throws** `Property (default) does not exist at path …` |
> | `Remove-ItemProperty -Name ''` | **throws** — parameter binding rejects the empty string |
> | `(Get-Item $k).DeleteValue('')` | **throws** `Cannot write to the registry key` (`Get-Item` opens read-only) |
>
> Note the asymmetry: `New-ItemProperty -Name '(default)'` creates it happily, but
> `Remove-ItemProperty -Name '(default)'` cannot see it. This matters because
> `Invoke-UninstallPhase:2567` calls `Remove-ItemProperty` on the `prevAbsent` path, which is
> exactly the path a newly-written `(default)` takes on uninstall.
>
> **What does work** — a *writable* handle plus the two-arg `DeleteValue`:
>
> ```powershell
> $sub = $path -replace '^HKLM:\\', ''
> $h = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($sub, $true)   # $true = writable
> if ($h) { try { $h.DeleteValue('', $false) } finally { $h.Close() } }   # $false = don't throw if absent
> ```
>
> Verified: deletes the default, **leaves sibling values intact**, and is idempotent (a second
> call on an already-absent default does not throw). Worth fixing in the shared restore loop
> rather than special-casing the printer, since any future caller writing a `(default)` hits it.
>
> **Also verified:** plain `Remove-Item <key> -Force` (non-recursive) *does* remove a key whose
> only value is the default — so key removal itself was never the problem.

```powershell
$t='HKLM:\SOFTWARE\AlleavesAutoProbe'
New-Item -Path $t -Force | Out-Null
New-ItemProperty -Path $t -Name '(default)' -Value 'PROBE.ProgId' -PropertyType String -Force | Out-Null
(Get-Item $t).GetValue('')      # <- what COM/OPOS actually reads. Must be 'PROBE.ProgId'.
Remove-Item $t -Recurse -Force
```

If it fails, use `Set-Item -Path $key -Value $progid`. Self-cleaning; ~10 seconds.

### Q4 — Which contract does Alleaves use? *(highest leverage)*

> **ANSWERED 2026-08-10 — as far as it can be answered statically. Net effect: neither the
> `PosDm.exe ADDNAME` step nor the `DllSurrogate` workaround is needed.**
>
> `Alleaves Terminal App.msi` (249,856 bytes) was downloaded and installed `/qn` (exit 0) on
> this rig. It is **not the terminal app** — it is a thin launcher/updater:
>
> - Installs exactly **two files** into `C:\Program Files (x86)\Alleaves Terminal`:
>   `AlleavesLauncher.exe` (51,200 B) and `AlleavesLauncher.exe.config`.
> - `AlleavesLauncher.exe` is **x86 (32-bit)**, .NET 4.7.2 WPF. Its type names include
>   `MainWindow+<CheckForUpdates>d__17` and `MainWindow+<Update>d__20`, and it references
>   `System.IO.Compression` / `System.IO.Compression.FileSystem` — it downloads and unpacks a
>   payload at runtime. Product string: **"Alleaves Sell"**.
> - `AlleavesLauncher.exe.config` points at `cloudFrontBaseUrl = https://d30nrlnqejdt4m.cloudfront.net`,
>   `environment = production`.
> - ARP: `Alleaves Terminal` 1.0.0.0, `MsiExec.exe /I{D5DD2F3C-1ABB-4543-93AA-3CD973B413E7}`.
>
> **Marker tally across the whole install tree — every one zero:**
> `OPOS.POSPrinter` · `OPOS.CashDrawer` · `Microsoft.PointOfService` · `PosExplorer` ·
> `RecPrinter.POSPrinter` · `ServiceOPOS` · `OLEforRetail`. No print/device/OPOS strings of any
> kind. Only referenced module is `mscoree.dll`.
>
> **Conclusions that are safe to build on:**
>
> 1. **No `PosDm.exe ADDNAME` step.** There is no POS for .NET usage anywhere, and POS for .NET
>    is not installed by this MSI (`PosDm.exe` absent, `Configuration.xml` absent, nothing in
>    ARP). The `Microsoft.PointOfService` branch of this question is dead.
> 2. **No `DllSurrogate` workaround.** The launcher is **32-bit**, so the 32-bit CCO loads
>    in-process. The `{CCB90##2-…}` reserve plan stays in reserve, unapplied.
> 3. **The registry write is the entire contract**, which is consistent with the LDN naming
>    convention being chosen on the Alleaves side rather than dictated by the driver — see the
>    LDN decision recorded under Q3.
>
> **Residual risk, stated plainly:** the *real* client is fetched from CloudFront at first run,
> so its contract could not be inspected here. Proving it needs a live terminal with
> credentials. That is precisely the gap `printer/Collect-PrinterFingerprint.ps1` exists to
> close — a field run reports whether the device opens and what Alleaves did with it. Chasing
> the CloudFront payload by guessing URLs was judged a fishing expedition and deliberately not
> attempted.

This project already installs **POS for .NET**, and Microsoft is explicit that
`PosExplorer.GetDevice` **cannot take an OPOS service-object name** — it needs a logical name
registered via `PosDm.exe ADDNAME`, which writes
`%ProgramData%\Microsoft\Point Of Service\Configuration\Configuration.xml`. That is a file, so it
is trackable and reversible and fits the manifest model.

- Alleaves → **CCO** (`CreateObject("OPOS.POSPrinter")` → `Open("Thermal")`) ⇒ the registry write
  alone suffices.
- Alleaves → **POS for .NET** ⇒ we **also** need a `PosDm.exe ADDNAME` step.

Alleaves is **not installed on this box**; install it first (Drive id
`1UAqW1zzxj9LJ-Pk0riNsZ8MiYoSQNoxP`, `Alleaves Terminal App.msi`, plain `msiexec /qn`), then:

```powershell
Get-ChildItem "<Alleaves install dir>" -Recurse -Include *.exe,*.dll |
  Select-String 'OPOS\.POSPrinter|Microsoft\.PointOfService|PosExplorer' -List
```

**Also record its bitness.** If Alleaves is 64-bit and uses POS for .NET it **cannot load the
32-bit OPOS SO in-process at all**; Microsoft's documented fix is a `DllSurrogate` out-of-proc
registration across the CCO CLSID range `{CCB90##2-B81E-11D2-AB74-0040054C3719}` for `## = 02..37`.
Keep in reserve; do **not** apply preemptively.

### Q6a — Record the install `.iss` (installs the package)

> **PARTIALLY ANSWERED 2026-08-10 — the ARP half is captured; the `.iss` recording is not.**
>
> Read off the install already present on this box:
>
> | | |
> |---|---|
> | ARP key | `HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\OLE POS Setup 2.84` |
> | `PSChildName` | `OLE POS Setup 2.84` — the **literal DisplayName**. Not a GUID, not `InstallShield_*`. |
> | `DisplayName` | `OLE POS Setup 2.84` |
> | `UninstallString` | `C:\WINDOWS\IsUninst.exe -f"C:\Program Files (x86)\OPOS\StdOPOS2.84\Uninst.isu"` |
> | `.isu` file | **`Uninst.isu`, in the install directory** — **not** `DeIsL#.isu`, and **not** under `InstallShield Installation Information`. |
> | IS cache folder | **none created.** No `InstallShield Installation Information\{GUID}` entry for this product. |
>
> Vindicates §3.4's "always read the `.isu` from ARP, never hardcode" rule — the real name
> isn't in the `DeIsL#` family this document assumed.
>
> **Two consequences for §3.4, one of which cancels half of it:**
>
> 1. **`Remove-InstallShieldOrphans` needs no change.** Its filter requires
>    `PSChildName -like 'InstallShield_*'` and it sweeps a `{GUID}` cache folder. This product
>    has **neither**, so the function is correctly a **no-op** here — there are no orphans to
>    sweep. §3.4 called this a defect because the real ARP shape wasn't known yet; it isn't one.
>    (Re-confirm against the fresh install when Q6a proper runs.)
> 2. **`Invoke-SilentUninstall` is genuinely broken, exactly as described.** `$rest` is just
>    `-f"C:\Program Files (x86)\OPOS\StdOPOS2.84\Uninst.isu"`, which matches neither `isuninst`
>    nor `InstallShield` — both of those live in the **exe path**, which `:352` never inspects.
>    So it falls through to the generic `/S` at `:355`, which IS5 ignores, and hangs to the
>    360 s cap. This is the one fix that must actually be written.
>
> A useful side effect: because `:1397` already routes `-ForceReinstall` pre-clean through
> `Invoke-SilentUninstall`, fixing that branch also repairs `-ForceReinstall` for this row —
> no separate pre-clean work needed.
>
> **Still outstanding:** the recorded install `.iss` itself, its ASCII check, the
> `BootOption=0` decision, and re-confirmation of the table above against a *fresh* install
> rather than this pre-existing one.

```
pkg.exe /a /r /f1"C:\...\opos_install.iss"        <- NO outer /s when recording
```

Default `-r` output if `-f1` is omitted is `%WINDIR%\setup.iss`, written at "Start Copying Files",
not at exit. IS5 `.iss` headers are `Version=v5.00.000` with plain (non-GUID-prefixed) dialog
section names. Pin `BootOption=0` if the chain ends in a finish-reboot dialog. **Verify pure ASCII.**

Capture at the same time, for §3.4: the exact **ARP key shape**, `DisplayName`, `UninstallString`,
and the `DeIsL#.isu` filename this install produces.

### Q3 — What does `SetupPOS.exe` actually write? *(the one genuinely un-derivable thing)*

> **PARTIALLY ANSWERED 2026-08-10 — the ProgID contract is settled; the value set is not.**
>
> §1 guessed right: **`Thermal.inf` is not a Windows INF.** Its own header says
> *"OPOS Machine Dependent Data File of RecPrinter"*. It is a SetupPOS device-type definition
> with four sections (`S`=serial, `P`=parallel, `N`=network, `U`=USB), `[COMMNumber] Cnumber=4`.
> The USB section, verbatim:
>
> ```ini
> [UMAIN]
> DeviceClass = POSPrinter
> DeviceName  = ThermalU
> DeviceDesc  = Thermal POS Printer (USB)
> SOName      = RecPrinter.POSPrinter.SOU
> ADKConfig   = Thermal1.0
>
> [UPORT]
> Port = USB   OutputBuf = 1024   Timeout = 1000
>
> [UOPTION]
> IdleSleep = int:10   InputSleep = int:10   DrawerOpen = int:0   USBSerialNumber = int:0
> ```
>
> So the ProgID for USB is **`RecPrinter.POSPrinter.SOU`**, and §2's re-verified state already
> resolves the rest of the chain: → `{86D3697F-5C7A-48DF-8A63-243C4D06297C}` →
> `WOW6432Node\CLSID\…\InprocServer32` → `POSPrinterSOU.dll`. **The `(Default)` value this step
> must write is therefore known.** `StdCash.inf` is the same shape for `CashDrawer`
> (`StandardU` / `Standard.CashDrawer.SOU`) — out of scope, but it means a drawer would be one
> more entry of the same form, not new machinery.
>
> **Still genuinely unknown, and still requiring the `SetupPOS.exe` run + diff:** the
> *vendor-private value set* written under `ServiceOPOS\POSPrinter\<logicalName>` — which of
> `[UPORT]`/`[UOPTION]` become registry values, under what names, and with what types
> (`int:` suggests some are DWORD, but that is an inference, not evidence). **Do not author
> these from the `.inf`.**
>
> Watch specifically for **`ADKConfig = Thermal1.0`**: that strongly implies SetupPOS also
> creates a *separate* `Thermal1.0` configuration key somewhere outside the logical-device key.
> An `.inf`-derived guess would miss it entirely, and a missed key is an un-reversed key —
> exactly what §3.5 exists to prevent. Diff the **whole** `OLEforRetail` tree, not just the
> `ServiceOPOS\POSPrinter` branch.
>
> The "before" state is clean: `ServiceOPOS` does not exist at all right now (§2), so every
> key the diff shows is one we created and must remove on uninstall.

> **ANSWERED 2026-08-10 — full payload captured by before/after diff around a real
> `SetupPOS.exe` run on a freshly-installed, `ServiceOPOS`-free box.**
>
> #### Correction 1: the logical name is **`ThermalU`**, not `Thermal`
>
> SetupPOS does **not** prompt for a free-text logical name — it names the device after the
> device *type*. Everything in this document that says `Open('Thermal')` (§5, §7, §8) is wrong
> and is corrected to **`ThermalU`**.
>
> Proved by COM, 32-bit, **with no printer attached**:
>
> | Call | Result |
> |---|---|
> | `Open('ThermalU')` | **0 — success.** `State=2` (idle), `ServiceObjectDescription = OLE OPOS POSPrinter Service Object` |
> | `Open('Thermal')` | **109 = OPOS_E_NOEXIST** |
> | `Open('thermalu')` | **0 — success** |
> | `ClaimDevice(2000)` after a good Open | **112 = OPOS_E_TIMEOUT** (expected with no hardware; *not* 107) |
>
> **Correction 2: the lookup is case-INSENSITIVE.** §7's claim that the name "should be treated
> as case-sensitive; a mismatch returns `OPOS_E_NOSERVICE` (104)" is wrong on both counts —
> `thermalu` opens fine (it is a registry key lookup, which is case-insensitive), and a genuinely
> wrong name returns **109**, not 104. Match the vendor's casing anyway as hygiene, but do not
> build logic on case.
>
> **Correction 3 — the big one: `Open()` returning 0 with no printer attached** means the whole
> registry contract is verifiable on a printer-less rig. `Set-PrinterOpos` can be proven
> end-to-end here; only `ClaimDevice`/`PrintNormal` need real hardware. This is exactly what
> exit code 7 ("OPOS device registration failed") is for, and it is genuinely settable.
>
> #### The value set — capture verbatim, never author
>
> Key: `HKLM\SOFTWARE\WOW6432Node\OLEforRetail\ServiceOPOS\POSPrinter\ThermalU`
>
> | Type | Name | Data |
> |---|---|---|
> | String | `(Default)` | `RecPrinter.POSPrinter.SOU` |
> | String | `ADKConfig` | `Thermal1.0` |
> | String | `Description` | `OLE POS Printer OPOS Service Object` |
> | String | `DeviceDesc` | `Thermal POS Printer (USB)` |
> | String | `DeviceName` | `ThermalU` |
> | String | `Port` | `USB` |
> | String | `Version` | `1.0` |
> | String | `BaudrateSel`, `BitLengthSel`, `HandShakeSel`, `IP`, `ParitySel`, `StopSel`, `XonXoffSel` | *(empty string, all seven)* |
> | DWord | `IdleSleep` | `10` |
> | DWord | `InputSleep` | `10` |
> | DWord | `OutputBuf` | `1024` |
> | DWord | `Timeout` | `1000` |
> | DWord | `Baudrate`, `BitLength`, `DrawerOpen`, `HandShake`, `InputBuf`, `Parity`, `PortShare`, `Stop`, `USBSerialNumber`, `XonXoff` | `0` (all ten) |
>
> 28 values total (14 String + 14 DWord). The serial-port fields are present but zeroed/blanked for a USB device —
> `Port=USB`, `OutputBuf`/`Timeout`/`IdleSleep`/`InputSleep` carry the `[UPORT]`/`[UOPTION]`
> values from `Thermal.inf`, everything else is inert. Note `PortShare` and `Description` appear
> in **neither** `.inf` section — a reminder that authoring from `Thermal.inf` would have
> produced a subtly wrong key.
>
> #### `ADKConfig` is a value, not a stray key
>
> The §1/Q3 worry about a separate `Thermal1.0` configuration key **does not materialise**.
> `ADKConfig=Thermal1.0` is a plain String value *inside* the device key. A stray hunt across
> `HKLM\SOFTWARE` and `HKLM\SOFTWARE\WOW6432Node` for `thermal|ADKConfig|RecPrinter` found
> nothing outside `OLEforRetail`, and a file diff of the install directory showed **no changes at
> all** — SetupPOS writes nothing outside the registry. No `.ini` to track.
>
> #### Keys created (these are the `regKeysCreated` set)
>
> SetupPOS created **four**:
> `ServiceOPOS` · `ServiceOPOS\CashDrawer` · `ServiceOPOS\POSPrinter` · `ServiceOPOS\POSPrinter\ThermalU`
>
> ~~**We only need three.**~~ Superseded by the scope change below — the cash drawer is now in
> scope, so `ServiceOPOS\CashDrawer` **is** ours to create.

### Q3 addendum — SCOPE CHANGE 2026-08-10: per-terminal LDNs + cash drawer

Two changes requested by the user after seeing the Q3 results. Both are registry-only and add
no new machinery.

**1. Per-terminal logical device names, replacing the vendor defaults.**

| Device class | LDN | Service object |
|---|---|---|
| `POSPrinter` | **`<POSname>_Printer`** | `RecPrinter.POSPrinter.SOU` |
| `CashDrawer` | **`<POSname>_Drawer`** | `Standard.CashDrawer.SOU` |

`<POSname>` is the terminal name set at the start of the run. **Use the *requested* name, not
`$env:COMPUTERNAME`** — the rename only takes effect after a reboot, so the environment
variable is stale for the whole run. Fall back to `$env:COMPUTERNAME` when `-SkipRename` is
used or no name is supplied.

**Decided: custom LDNs only.** The vendor defaults `ThermalU` / `StandardU` are **not** created.

**Proven, not assumed:** an arbitrary LDN works. Cloning the captured `ThermalU` value set to
`ZZTEST_Printer` and the `StandardU` set to `ZZTEST_CashDrawer` gave
`POSPrinter.Open('ZZTEST_Printer') -> 0` and `CashDrawer.Open('ZZTEST_CashDrawer') -> 0` over
32-bit COM. Both aliases were removed afterwards. The LDN really is just the registry key name.

**2. Cash drawer is in scope.** Captured the same way — SetupPOS → CashDrawer → `StandardU`,
before/after diff. 33 values under `…\ServiceOPOS\CashDrawer\StandardU`:

| Type | Name | Data |
|---|---|---|
| String | `(Default)` | `Standard.CashDrawer.SOU` |
| String | `ADKConfig` | `CashDrawer1.0` |
| String | `Description` | `OLE Cash Drawer OPOS Service Object` |
| String | `DeviceDesc` | `Standard Cash Drawer` |
| String | `DeviceName` | `StandardU` |
| String | `Port` | `USB` |
| String | `Version` | `1.0` |
| String | `BaudrateSel`, `BitLengthSel`, `HandShakeSel`, `IP`, `ParitySel`, `StopSel`, `XonXoffSel` | *(empty, all seven)* |
| DWord | `ConnectorPinNo` | `2` |
| DWord | `DrawerClose` | `1` |
| DWord | `OpenLevel` | `1` |
| DWord | `PulseOnTime` | `100` |
| DWord | `PulseOffTime` | `400` |
| DWord | `InputSleep` | `10` |
| DWord | `OutputBuf` | `1024` |
| DWord | `Baudrate`, `BitLength`, `DrawerOpen`, `HandShake`, `IdleSleep`, `InputBuf`, `Parity`, `PortShare`, `Stop`, `Timeout`, `USBSerialNumber`, `XonXoff` | `0` (all twelve) |

Differences from the printer set worth noting: the drawer adds `ConnectorPinNo`, `DrawerClose`,
`OpenLevel`, `PulseOnTime`, `PulseOffTime`; and its `IdleSleep` and `Timeout` are **`0`**, where
the printer uses `10` and `1000`. Copying the printer's values would have been subtly wrong —
another reason "capture, never author" earned its place.

`Standard.CashDrawer.SOU` resolves to `POSPrinterSOU.dll` — the drawer rides the printer's USB
service object, consistent with a drawer hanging off the printer's RJ-11.

**So `Set-PrinterOpos` creates five keys**, removed deepest-first and subkey-guarded on
uninstall: `ServiceOPOS` · `ServiceOPOS\POSPrinter` · `ServiceOPOS\POSPrinter\<POSname>_Printer`
· `ServiceOPOS\CashDrawer` · `ServiceOPOS\CashDrawer\<POSname>_Drawer`.

```powershell
reg export "HKLM\SOFTWARE\WOW6432Node\OLEforRetail" "$env:TEMP\opos_before.reg" /y
Get-ChildItem "C:\Program Files (x86)\OPOS" -Recurse -File |
  Select FullName,Length,LastWriteTime | Export-Csv "$env:TEMP\oposdir_before.csv" -NoType
#   run SetupPOS.exe:  POSPrinter -> Add New Device -> name "Thermal", type "ThermalU"
reg export "HKLM\SOFTWARE\WOW6432Node\OLEforRetail" "$env:TEMP\opos_after.reg" /y
Compare-Object (gc "$env:TEMP\opos_before.reg") (gc "$env:TEMP\opos_after.reg")
#   then resolve the ProgID -> CLSID -> DLL chain:
$k='HKLM:\SOFTWARE\WOW6432Node\OLEforRetail\ServiceOPOS\POSPrinter\Thermal'
$progid=(Get-Item $k).GetValue(''); $progid
$clsid=(Get-Item "HKLM:\SOFTWARE\Classes\WOW6432Node\$progid\CLSID").GetValue('')
(Get-ItemProperty "HKLM:\SOFTWARE\Classes\WOW6432Node\CLSID\$clsid\InprocServer32")
```

Diff the directory CSVs too — SetupPOS may write an `.ini` outside the registry.

**Capture the vendor-private values verbatim; never author them.** The OPOS spec mandates only
`(Default)` = ProgID; everything else under the logical-device key is vendor-private (Datalogic
uses `AbstractDevice`/`Usage`/`Port`/`BaudRate`; LK will differ).

Read `Thermal.inf` / `StdCash.inf` from the install dir first — see §1.

### Q5 — Does `POSPrinterSOU.dll` need the Windows print queue? *(RISK CHECK)*

> **ANSWERED 2026-08-10 — NO. It bypasses the spooler entirely. The design is sound; there is
> no functional gap to escalate.**
>
> Import/string analysis of the on-disk
> `C:\Program Files (x86)\OPOS\StdOPOS2.84\POSPrinterSOU.dll` (114,688 B, FileVersion
> `2, 84, 0, 0`):
>
> - **Referenced modules:** `ADVAPI32.dll`, `GDI32.dll`, `KERNEL32.dll`, `MFC42.DLL`,
>   `msvcrt.dll`, `OLEAUT32.dll`, **`SETUPAPI.DLL`**, `USER32.dll`, `WINMM.dll`.
> - **`WINSPOOL.DRV` is absent.** Zero hits for `OpenPrinter`, `StartDocPrinter`,
>   `WritePrinter`, `EndDocPrinter`, `ClosePrinter`, `StartPagePrinter`, `EnumPrinters`,
>   `GetPrinter`.
> - **Direct device-interface API present:** `SetupDiGetClassDevsA`,
>   `SetupDiEnumDeviceInterfaces` (SETUPAPI) plus `CreateFileA` and `WriteFile` (KERNEL32).
>
> That is the textbook USBPRINT pattern §1 named as the leading hypothesis: enumerate the
> device-interface class, `CreateFile` the resulting `\\?\usb#…` device path, `WriteFile` raw
> bytes to it. No spooler, no print queue, **no Windows print driver required** — which is
> exactly the premise the "OPOS is the entire path" design rests on.
>
> The interface GUID `{28d78fad-5a12-11d1-ae5b-0000f803a8c2}` does not appear as an ASCII
> string, but that proves nothing either way — a GUID is normally embedded as 16 binary bytes.
> The decisive evidence is the total absence of `WINSPOOL.DRV`.
>
> Incidental: the PE's internal module name is `SEWOO_POSPrinterSOP.dll`, confirming the OEM
> behind §1's `CompanyName=LK` is **Sewoo** (the LK-series printers). Useful when searching
> vendor documentation.
>
> Final confirmation against a real unit still comes from §8's collector, but nothing is
> blocked on it.

No printer is available, so this is settled by evidence, not by printing. Dump the DLL's imports
and strings:

- imports `WINSPOOL.DRV` with `OpenPrinter` / `StartDocPrinter` / `WritePrinter` ⇒ it **rides the
  Windows print queue**. Since no print driver is installed on a real terminal, **OPOS alone will
  not print** — a functional gap to escalate, not something to work around quietly.
- `CreateFile` against a `\\?\usb#…` device path, the USBPRINT interface GUID
  `{28d78fad-5a12-11d1-ae5b-0000f803a8c2}`, WinUSB, a raw HID path, or the FTDI VCP ⇒ it talks to
  the device **directly** and the design is sound. This is the leading hypothesis (§1).

Final confirmation comes from the first live printer via §8's collector.

### Q6b — Record the uninstall `.iss` / capture the uninstall command (removes the package)

> **ANSWERED 2026-08-10 — the command works. Silent, 8 seconds, no dialog, no reboot.**
>
> Run against the install that was already on the rig, with the `.isu` read from ARP:
>
> ```
> "C:\WINDOWS\IsUninst.exe" -y -a -f"C:\Program Files (x86)\OPOS\StdOPOS2.84\Uninst.isu"
> ```
>
> The exe-path match `(?i)\\(IsUninst|_isdel)\.exe$` fired correctly, and prepending `-y -a`
> preserved the existing `-f"…"` verbatim. No `-c"<dll>"` was present on this product.
>
> **Removed cleanly:** the ARP entry; all **200** files and the whole
> `C:\Program Files (x86)\OPOS` tree; the `OLEforRetail\ServiceInfo\OLE OPOS\OPOS 2.81` values;
> and the **CCO** registrations (`OPOS.POSPrinter`, `OPOS.CashDrawer` — ProgID and CLSID both).
> No `IsUninst` or `IKernel` process left running. Nothing needed killing.
>
> **Residue the vendor uninstaller leaves behind** — measured, and deliberately *not* our
> problem to sweep:
>
> 1. `HKLM\SOFTWARE\WOW6432Node\OLEforRetail` and its `ServiceInfo` child survive as **two empty
>    keys** (all values and the `OLE OPOS` branch are gone).
> 2. The **service-object** registrations are left **dangling**: `RecPrinter.POSPrinter.{SO,SON,SOP,SOU}`
>    and `Standard.CashDrawer.{SO,SON,SOP,SOU}` keep their ProgID → CLSID → `InprocServer32`
>    chains pointing at DLLs that no longer exist. (Incidentally `Standard.CashDrawer.SOU` maps to
>    `POSPrinterSOU.dll` — the drawer rides the printer's USB service object, which is consistent
>    with a drawer hanging off the printer's RJ-11.)
>
> Both are inert: nothing enumerates ProgIDs by name, and OPOS discovery walks
> `ServiceOPOS\*`, which does not exist. They are the vendor uninstaller's imperfection, in the
> same class as the VC++ redistributable the README already documents as intentionally left in
> place. **We reverse what we add; we do not hand-sweep another vendor's COM registrations** —
> that is unbounded risk for zero functional gain.
>
> **Two consequences for verification, both of which correct §7 as written:**
>
> - **§7 step 5's "verify `OLEforRetail` is fully absent again" will never pass and is the wrong
>   expectation.** The correct post-uninstall assertion is: `OLEforRetail` is back to the
>   **vendor's own post-uninstall shape** — `OLEforRetail\ServiceInfo`, both empty, and
>   crucially **no `ServiceOPOS` branch**. That last part is the thing our fix is responsible for.
> - A reinstall does **not** start from a virgin COM state. Harmless (the installer's
>   `regsvr32` overwrites), and it does not touch the Q3 diff, which is taken on `OLEforRetail`
>   rather than on `Classes`.
>
> The `.iss`-recording framing in the rest of this section does not apply: for the IS5
> `IsUninst.exe` shape there is no uninstall `.iss` — capturing the command *is* the answer.
>
> #### Re-run with OPOS devices present: **§3.5 is LOAD-BEARING, confirmed**
>
> The first Q6b run happened before any `ServiceOPOS` entry existed, so it could not answer the
> question that actually matters. Repeated later with both a `POSPrinter\ThermalU` and a
> `CashDrawer\StandardU` device registered:
>
> ```
> ARP after           : gone
> OPOS dir after      : False
> ServiceOPOS after   : True     <<<
> ThermalU key after  : True     <<<
> ```
>
> **The vendor uninstaller removes its own files, ARP entry and CCO registrations but leaves
> every OPOS device entry behind.** Without our own `regKeysCreated` removal, `-Uninstall`
> would strand `…\ServiceOPOS\POSPrinter\<POSname>_Printer` pointing at a deleted
> `POSPrinterSOU.dll` — a phantom device that OPOS enumeration still lists and that fails on
> open. That is exactly the §3.5 failure mode, and it is real, not theoretical.
>
> The deepest-first, non-recursive, `SubKeyCount -eq 0` removal was then exercised by hand
> against that exact state and cleared all five keys in the right order, leaving
> `OLEforRetail\ServiceInfo` untouched. The corrected §3.5 algorithm is validated before a line
> of it ships.

Record the uninstall in **removeonly / maintenance mode**, not by replaying the install `.iss`
against it — recording an install `.iss` and replaying it against maintenance mode is the top
cause of a surviving Yes/No dialog and of `-3`.

For the IS5 `IsUninst.exe` shape the "recording" is really *capturing the exact command*:

```
C:\WINDOWS\IsUninst.exe -y -a -f"C:\...\DeIsL1.isu"
```

Read `DeIsL#` **from ARP**, never hardcode. Confirm it runs silently to completion and that the
ARP entry, `C:\Program Files (x86)\OPOS`, and the `OLEforRetail` tree are all gone afterward.

---

## 4b. IMPLEMENTED + VERIFIED 2026-08-10

All of §6 is implemented in `alleaves_setup.ps1` and `printer/Collect-PrinterFingerprint.ps1`,
and `Install-Alleaves.bat` is rebuilt (SHA256 self-verify OK).

**Deviations from §6, each deliberate:**

| §6 said | Shipped | Why |
|---|---|---|
| `-WrapperArgs` prefix | **`-ArgFormat`** (whole format string) | A prefix leaves the inner switches as `-f1`/`-f2`, producing exactly the mixed `-`/`/` line §3.1 forbids. One format string is a smaller diff *and* the only correct shape. |
| `-NoMsiFallback` on `Invoke-IssSilent` | Row key checked at the **call site** (`Invoke-InstallLoop`) | The MSI fallback gate lives in the loop, not in the function. |
| Fix `Remove-InstallShieldOrphans` | **No change** | Verified no-op for this product (no `InstallShield_*` ARP key, no `{GUID}` cache folder). |
| Remove keys "only if empty" | Guarded on **`SubKeyCount` only** | `ValueCount` counts the `(default)` value, so the original test would never fire on the key it exists to remove (Q2, Trap 1). |
| `printerConfigured` only | Also **`regKeysCreated`** + a `(default)`-aware restore | Q2, Trap 2. |

**Test results on the rig (`DESKTOP-FI6BRLV`, Win11 26200):**

1. **`-DryRun`** — row appears in both phases, brand prompt degrades under `ALLEAVES_NOPAUSE`,
   and `OLEforRetail` is **byte-identical before and after** (the new internal
   `Set-TrackedRegValue` guard holds).
2. **Zebra regression (§7 step 8) — PASSED for real, not just in DryRun.** A full install run
   installed `Zebra 123 Scan` and `Zebra Scanner SDK` with `ResultCode=0`, emitting the
   unchanged `-s -f1"…" -f2"…"` line. CoreScanner service present afterwards.
3. **`OLE POS Setup` installed through the installer's own code path** — `ResultCode=0`,
   `registry=True`, no GUI, via `/s /a /s /L0x0409 /f1"…" /f2"…"`.
4. **Registry values byte-identical to SetupPOS** — a real `Compare-Object` against the Q3
   capture: 28/28 printer values, **no differences**. Drawer: 33 values.
5. **Both devices `Open()` → 0** over 32-bit COM with no hardware attached.
6. **Full `-Uninstall` round-trip, exit 0** — all 7 products gone from ARP (OLE POS via the new
   IS5 `-y -a -f"…"` branch), all 61 values removed **including both `(default)` values**, and
   the created keys removed deepest-first.
7. **`-ForceReinstall`** correctly routes pre-clean for this row through `Invoke-SilentUninstall`
   (`found existing: OLE POS Setup 2.84`), which the IS5 branch now handles.
8. **`-PrinterConfigOnly`** runs standalone and `Save-Manifest` merges onto the prior manifest.

**One nuance worth knowing:** `regKeysCreated` held **5** keys on a bare box but **4** after a
full install — because **POS for .NET creates `…\OLEforRetail\ServiceOPOS` itself**. The
"deepest ancestor that did not exist" walk correctly recorded only what *we* created, so
uninstall removed our two device keys and the two class keys and **left `ServiceOPOS` alone**.
Exactly the intended behaviour, and a good demonstration that the guard is not cosmetic.

**Still unproven — hardware only.** `ClaimDevice` returns **112 (OPOS_E_TIMEOUT)** on a bench
with no printer (not 107). Printing, the drawer kick, `ConnectorPinNo=2`, the USB VID/PID, and
whether Alleaves opens these LDNs all need a real terminal — see
`docs/PRINTER_OPOS_FIELD_RESULTS.md`. A **reboot-between-cycles** re-run is also still
outstanding; the round-trip above was install → uninstall within one session.

## 5. Architecture

Split at the seam the vendor itself uses:

| Layer | Who | Why |
|---|---|---|
| File staging + ARP + COM registration | **The vendor installer, silent via PFTW `/a`** | Only it can `regsvr32` the OPOS service objects and CCOs. Registry import cannot replace COM self-registration (typelib, interface/proxy entries), and on x64 the SO must be registered with `SysWOW64\regsvr32.exe`. |
| OPOS device entry | **`Set-TrackedRegValue` into `HKLM\SOFTWARE\WOW6432Node\OLEforRetail\ServiceOPOS\POSPrinter\Thermal`** | `SetupPOS.exe` is only a GUI over the registry. Doing it ourselves makes it silent, tracked and reversible. |

**Registry redirection:** the PS registry provider treats the path literally and the `.bat` forces
the 64-bit host (`build-bat.ps1:77`, Sysnative), so writing the explicit `WOW6432Node` path is
correct — the CCOs are 32-bit.

### Reliability grading

| Piece | Grade | Note |
|---|---|---|
| Download (Drive or POS-X S3) | High | byte-identical to vendor, SHA256 pinnable |
| PFTW `/s /a /s …` silent install | Medium-High | pending Q1; the `.iss` is **version-locked to 2.84** — re-record on any bump |
| OPOS entry via tracked registry writes | High **once captured** | values must be captured (Q3), never authored |
| Uninstall | Medium | needs the captured `IsUninst.exe` command + the §3.5 key-removal fix |
| `-ForceReinstall` | **Broken today** | document as unsupported for the printer row until §3.4 is fixed |
| `pnputil` / print drivers / ports | N/A | not used, by design |

---

## 6. Implementation checklist

Only after Q1 and Q2 have real answers. **Guiding constraint: every new parameter defaults to
today's behavior**, so the validated Zebra path stays byte-identical and only the new row opts in.

**Install-execution core — the real work**

- `Invoke-IssSilent` (`:1089`): add `-WrapperArgs` (emits `/s /a` ahead of the inner switches);
  add `-WaitNames` / `-ReapNames` defaulting to the current literal, passing **`-ReapNames @()`**
  for this row; add `-RegistryShortCircuit` (default `$true`) so the `:1171` break is skipped and
  the exit condition becomes worker-gone with registry checked after the loop; add
  `-NoMsiFallback`. Update the sole call site `:1450-1452`.
- `Remove-InstallShieldOrphans` (`:408`): handle the real ARP shape captured at Q6a; sweep the
  `InstallShield Installation Information\{GUID}` cache folder by GUID where applicable.
- `Invoke-SilentUninstall` (`:352-357`): add the IS5 case — match on the **exe path**, not just
  `$rest`, and emit `-y -a -f"…"`, preserving any `-c"<dll>"`.

**Tables and the new step**

- `$DriveFiles` (`:643-651`) + `$Installers` (`:1352`): **one** row, with `Label`/`Name`/`File`
  aligned across both tables per the F7 note at `:648`; remove `OLE POS Setup` from the SKIP
  comment at `:652`. Suggested `Match='OLE POS Setup'`. Place it **last** in `$Installers` (after
  NiceLabel) unless `BootOption=0` is verified.
- New **`Set-PrinterOpos` — ~15 lines**, NOT a `Set-ScannerOpos` clone. `Set-ScannerOpos` is ~350
  lines (`:2285-2440`) of COM, two-hop switching and re-enumeration polling because the scanner
  switch is a hardware command over RSM. This is a leading `if ($DryRun) { Dry …; return }` guard
  (per `:2294`) plus `foreach { Set-TrackedRegValue }` with the Q3-captured values. No COM, no
  polling, no hardware.
- `Set-TrackedRegValue` (`:1555`): add the internal `-DryRun` guard; record created keys into a
  new `regKeysCreated`. Use `-Name '(default)'` (or `Set-Item`, per Q2) — **never `-Name ''`**.
- `Invoke-UninstallPhase` (`:2555-2582`): after the value-restore loop, remove `regKeysCreated`
  **deepest-first and only if empty**.
- Manifest: `printerConfigured = @()` **and** `regKeysCreated = @()` in `New-InstallManifest`
  (`:2634`), **plus** matching `Merge-PriorList` lines in the `:1504-1516` block — omitting either
  silently drops the array on a re-run:
  ```powershell
  $Manifest.printerConfigured = Merge-PriorList $Manifest.printerConfigured `
      $prior.printerConfigured { param($e) $e.logicalName }
  ```

**Params / dispatch**

- `-PrinterBrand` (single-word), `-SkipPrinterConfig`, `-PrinterConfigOnly`. Mirror
  `-ScannerConfigOnly` at `:104` (mode string), `:105-109` (arg echo — renumber the `-f`
  placeholders), `:127-130` (exclude against `-Uninstall` **and** `-ScannerConfigOnly`), the
  comment-based help `:22-57`, and a dispatch branch beside `:2665` **with its own copy of the
  non-fatal exit-code block** (as `:2683-2688` does) or `-PrinterConfigOnly` always exits 0.
  Put the brand prompt in a function **both** branches call, or make `-PrinterBrand` mandatory
  under `-PrinterConfigOnly` — a prompt placed inside the install branch is unreachable from the
  standalone branch.
- **Drop any `-SkipPrinter`** — `-SkipPrograms 'OLE POS'` already covers it via `Test-SkipMatch`.
- Exit code **7** = "OPOS device registration failed" (§3.6).
- Prompt shape: brand → POS-X (Star/Epson select cleanly and warn "not yet implemented"). Type →
  the OPOS device type, USB = `ThermalU`; a brand-conditional single default, not a menu.

**Then:** `.\build-bat.ps1`; update `README.md:104-107` (option + exit-code tables) and `CLAUDE.md`.

---

## 7. Verification

Repo rule: **full round-trip with a reboot between cycles.** No partial tests.

1. `PowerShell -File .\alleaves_setup.ps1 -DryRun` — the row appears in the plan; the brand prompt
   degrades under `ALLEAVES_NOPAUSE=1`; **zero HKLM writes** (the new `Set-TrackedRegValue` guard).
   Confirm by snapshotting `OLEforRetail` before and after.
2. `.\build-bat.ps1` (packs + self-verifies SHA256), then `Install-Alleaves.bat`.
   **Watch for any GUI** — one appearing means the `.iss` did not match the dialog chain (`-3`).
3. Confirm: the ARP entry exists;
   `(Get-Item 'HKLM:\SOFTWARE\WOW6432Node\OLEforRetail\ServiceOPOS\POSPrinter\Thermal').GetValue('')`
   returns the Q3-captured ProgID; the manifest has `printerConfigured`, `regValuesSet`,
   `regKeysCreated`.
4. Reboot. Run `printer\Collect-PrinterFingerprint.ps1 -SnapshotOnly` and confirm the report is
   complete and readable — this is the artifact a field tech sends back.
5. `Install-Alleaves.bat -Uninstall` — the product is gone, ServiceOPOS values restored **and the
   created keys removed** (verify `OLEforRetail` is fully absent again, not left as empty parents).
6. Reboot; re-run for idempotency (the second run skips the row). `-ForceReinstall` only after the
   §3.4 fix, and test it explicitly since it is broken today.
7. `-PrinterConfigOnly` standalone; confirm `Save-Manifest` merges onto the prior manifest.
8. **Regression:** confirm the Zebra `.iss` rows still install unchanged — they share
   `Invoke-IssSilent`, which is why every new parameter defaults to today's behavior.

End-to-end OPOS proof (**must be 32-bit PowerShell**):

```powershell
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -NoProfile -Command {
  $p = New-Object -ComObject OPOS.POSPrinter
  $p.Open('Thermal'); $p.GetOpenResult()      # 0 = success
  $p.ClaimDevice(1000); $p.DeviceEnabled = $true
  $p.PrintNormal(2, "OPOS OK`n`n`n")
}
```

The logical name is the entire contract and should be treated as **case-sensitive**; a mismatch
returns `OPOS_E_NOSERVICE` (104).

---

## 8. `printer/Collect-PrinterFingerprint.ps1`

No printer is available, so the first real unit is met in the field. The installer must send
evidence home rather than rely on someone describing what happened.

Mirror the existing convention exactly — `scanner/Collect-ScannerFingerprint.ps1` is the template:
`param([switch]$SnapshotOnly)`, a `Section` helper, `Start-Transcript` to **one** Desktop report
file, print the path, "send that file back."

Captures, snapshot mode:

- the whole `OLEforRetail\ServiceOPOS\POSPrinter\*` tree **verbatim**, both registry views
- the `(Default)` ProgID → `CLSID` → `InprocServer32` DLL chain
- the Spooler service state, and `Get-Printer` / `Get-PrinterPort` **as diagnostic context only**
  (nothing is expected to be there — a queue showing up is itself informative)
- the OLE POS ARP entry and `POSPrinterSO*.dll` file versions
- `Get-PnpDevice` for the attached USB printer — **VID/PID/status/device path**. We have no sample
  of this yet; it is the single most valuable thing a field run can bring back, and it is what
  would let a future build detect "printer present".

Then, unless `-SnapshotOnly`, a live OPOS probe reporting a result code per call:
`Open` → `GetOpenResult` → `ClaimDevice` → `DeviceEnabled` → `PrintNormal`. The CCOs are
**32-bit**, so that probe shells out to
`C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe` and captures the output — cheaper than
relaunching the whole script under WOW64.

Like `scanner/Scanner_OPOS_barcode.pdf` this is a standalone doc-style deliverable — it is **not**
embedded, so it needs **no `.bat` rebuild**. Field results accumulate in a running table in
`docs/`, mirroring `docs/SCANNER_OPOS_RIG_VALIDATION_PROMPT.md`.

`Set-PrinterOpos` records the same identity fields into the manifest's `printerConfigured` array,
so a field run's manifest is diagnostic on its own even if nobody runs the collector.

---

## 9. Working files

| Path | What |
|---|---|
| `…\scratchpad\posx\OLE POS Setup_v2.84.exe` | the package, SHA256-verified 2026-08-10 |
| `…\scratchpad\posx\Q1-Probe-PftwForwarding.ps1` | ready-to-run Q1 probe (elevated) |
| `…\scratchpad\posx\Remove-ThermalPackage.ps1` | one-time cleanup of the erroneously-installed package |

`…\scratchpad\` = `C:\Users\xpc\AppData\Local\Temp\claude\C--Users-xpc-Desktop-AI-Code-AlleavesAuto\<session>\scratchpad`.
Scratchpad contents are **temporary** — the package is re-downloadable from either source in §1,
and the scripts are re-derivable from §4.
