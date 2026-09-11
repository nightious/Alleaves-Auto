# Receipt printer OPOS — field confirmations

Running table of real-terminal results for the OPOS receipt-printer step, mirroring
`SCANNER_OPOS_RIG_VALIDATION_PROMPT.md`'s "Field confirmations so far".

Two brands: **POS-X** (`OLE POS Setup`) and **Star TSP100** (futurePRNT). How the cash drawer is
handled differs between them — on POS-X, since 2026-08-12, it has **no OPOS device of its own**
and follows the printer via the printer key's `DrawerOpen` value (captured below); on Star it is
a genuine second OPOS device.

Every row is backed by a `printer/Collect-PrinterFingerprint.ps1` report. Add a row per
terminal; attach or paste the raw capture into `docs/` alongside, as the scanner work does.

## POS-X — what is already proven (do not re-litigate)

Verified on the bench rig 2026-08-10, **without any printer attached**:

- Silent install works: `pkg.exe /s /a /s /L0x0409 /f1"<iss>" /f2"<log>"` → `ResultCode=0`,
  no GUI, ~26 s. **Keep those paths short** — IS5 has a fixed command-line buffer: ~190 chars
  of inner command line works, ~390 crashes the PFTW stub with an access violation.
- Silent uninstall works: `IsUninst.exe -y -a -f"…\Uninst.isu"`, ~8 s, no dialog.
- The registry entries are byte-identical to what the vendor's `SetupPOS.exe` writes
  (28 printer values, diffed — plus the 33 drawer values, before that device was dropped).
- The printer device `Open()`s → **0** over 32-bit COM with nothing plugged in.
- Full uninstall round-trip removes every value and key we create, leaving the vendor's
  `OLEforRetail\ServiceInfo` untouched (measured at 61 values / 5 keys on the two-device
  build; 28 / 3 now).
- `POSPrinterSOU.dll` imports **no `WINSPOOL.DRV`** — the print path bypasses the spooler
  entirely, so no Windows print driver or queue is needed.
- **`DrawerOpen=1` is "Open CashDrawer = Follow Printer"** (captured 2026-08-12 on the bench
  rig, driver freshly installed). SetupPOS → POSPrinter → `<POSname>_Printer` →
  *Printer Test And Setting* has an **Open CashDrawer** combo with exactly two items:
  `CashDrawer` (index 0, the `Thermal.inf` default) and `Follow Printer` (index 1). Driving it
  to `Follow Printer` and diffing the whole `OLEforRetail` tree produced a **one-line** diff:

  ```
  "DrawerOpen"=dword:00000000   ->   "DrawerOpen"=dword:00000001
  ```

  Nothing else moved — no companion value, no key outside the device. Re-capture procedure if
  the package version ever bumps:

  ```powershell
  reg export "HKLM\SOFTWARE\WOW6432Node\OLEforRetail" "$env:TEMP\b.reg" /y
  #  SetupPOS.exe -> POSPrinter -> <POSname>_Printer -> Printer Test And Setting
  #    -> "Open CashDrawer" = "Follow Printer" -> Close
  reg export "HKLM\SOFTWARE\WOW6432Node\OLEforRetail" "$env:TEMP\a.reg" /y
  Compare-Object (gc "$env:TEMP\b.reg") (gc "$env:TEMP\a.reg")
  ```

## Star TSP100 — what is settled, and the blocking capture

Settled without hardware (discovery 2026-08-28, no re-research needed):

- The payload is `Star tsp100_v760.zip`, 493,881,478 bytes, SHA256
  `FFB47D08C7CF531C55CE665C83F10DE93098B82E9D309A4F7FA8BE68E9E2A4AD`, the whole **futurePRNT
  7.6.0** CD image. The installer is one member inside it:
  `tsp100_v760/Windows/Installer/setup_x64.exe` (111 MB, Authenticode valid,
  `CN="STAR MICRONICS CO., LTD."`). InstallShield **Basic MSI**, not InstallScript.
- **Silent install, documented verbatim** by the vendor in `tsp100_v760/Readme_En.txt` §3:
  `Setup_x64.exe /s /v"/qn"`. `/s` silences the launcher, `/v"…"` forwards to the inner
  msiexec — *both* halves are required. §5's FilesInUse dialog is suppressed by `/qn` and does
  not actually reboot; §16's DirectPlay prompt only appears via `Autorun.exe`.
- Silent uninstall is plain msiexec; ARP `DisplayName` is `TSP100 Setup Version 7.6.0`,
  Publisher `Star Micronics`. **Match on the DisplayName, never the ProductCode** — it changes
  every release (7.1.0 / 7.4.0 / 7.5.1 / 7.7.0 all differ).
- Install does **not** require the printer attached (manual: *"Execute steps (1) to (12) before
  connecting the TSP100"*). The print **queue** is created by PnP only when the printer is
  later powered on.
- **There is no vendor OPOS automation, and there is not going to be one.** futurePRNT's manual
  §4.1.1 states verbatim that the Configuration Utility's XML export/import **excludes** OPOS
  (as it does JavaPOS, serial ports, virtual TCP/IP port and Star Cloud). There is no
  `SetupPOS.exe` equivalent — Star's tool is `TSP100ControlPanel.exe`, GUI-only, no `/add`
  switch, no INI, no importable XML. JavaPOS gets a `jpos.xml` generator; OPOS does not.
  Writing the registry directly is therefore the *only* path, which is exactly what
  `Set-PrinterOpos` already does. Only the value tables are missing.

Proven on the bench rig 2026-08-28 (`DESKTOP-FI6BRLV`, Win11 26200, **no TSP100 attached**) —
the whole install half, end to end:

- Download: 493,881,478 bytes on the **first attempt, no retries**, via the plain `confirm=t`
  URL `Get-DriveFile` already builds. `Content-Length` matched, magic-byte check passed, `.len`
  sidecar written. **No Drive interstitial and no `uuid` parameter needed** — an earlier plan to
  swap in `curl.exe` plus a uuid scrape was based on a false reading of the download path and
  was dropped.
- Extraction: `System32\tar.exe -xf <zip> -C <downloads> tsp100_v760/Windows/Installer/setup_x64.exe`
  produced exactly that one member at its **stored path**
  (`downloads\tsp100_v760\Windows\Installer\setup_x64.exe`, 111,399,952 bytes), no stderr, and a
  recursive `setup*.exe` search found nothing else. `--strip-components` is deliberately not
  used and is not needed.
- Install: `setup_x64.exe /s /v"/qn /norestart"` — inner quotes survived `Start-Process`
  verbatim (manifest records `["/s","/v\"/qn /norestart\""]`). Fully unattended, no window,
  exit **0**, ~4.5 min total run.
- ARP: **exactly ONE row** — `TSP100 Setup Version 7.6.0` / `Star Micronics` / 7.6.0 /
  `InstallLocation C:\Program Files (x86)\StarMicronics\TSP100\Software\20210824\` /
  `MsiExec.exe /X{C0CDC4EE-EC57-475F-A5C1-175627446E82}`, in the **32-bit** view only.
  ⇒ the generic msiexec uninstall path does **not** need 1605 adding; that open question is
  closed.
- Idempotency: a second identical run took **1 s** against 274 s, printed
  `already installed; skipping`, never launched the installer, and left one manifest row with
  `note='already-installed'`. That is the `SkipIfInstalled` row flag doing its job.
- `Set-PrinterOpos` returned `result='not-captured'` and exit **7**, and wrote **nothing**:
  `HKLM:\SOFTWARE\WOW6432Node\OLEforRetail\ServiceOPOS` still held only the pre-existing `Scale`
  and `Scanner` classes — no `POSPrinter`, no `CashDrawer` key.

**The four value tables ship EMPTY** (`$StarPrinterStrings` / `$StarPrinterDWords` /
`$StarDrawerStrings` / `$StarDrawerDWords`, all `TODO[rig]`). `Set-PrinterOpos`'s
`not-captured` guard tests `Strings.Count -eq 0` and exits **7** rather than writing a valueless
device key. Do not fill them with plausible values — the POS-X history is the warning: deriving
values from the vendor `.inf` instead of a real diff produced a subtly wrong key.

### The capture procedure

`printer/Collect-PrinterFingerprint.ps1` already *is* this capture — its section 1 walks
`ServiceOPOS` recursively in **both** registry views, printing every value's kind, name and data
with `(Default)` shown correctly. So it is a before/after diff of two of its reports, not a
fresh `reg export` script. Its sections 2 and 4 will report the POS-X ProgIDs and `OLE POS
Setup` as absent — harmless noise on a Star box, ignore it.

Elevated, on the bench, **no printer attached**:

```powershell
# 1. install futurePRNT (from the extracted installer)
.\setup_x64.exe /s /v"/qn /norestart"

# 2. BEFORE snapshot -> writes PrinterFingerprint_<PC>_<stamp>.txt to the Desktop
powershell -ExecutionPolicy Bypass -File .\printer\Collect-PrinterFingerprint.ps1 -SnapshotOnly
#    rename it before.txt

# 3. Start -> StarMicronics -> "Configuration Utility TSP100"
#      Control Object Registration = "OPOS CCO"       <- NOT Star CO. The vendor manual:
#        "If the Star printer is used with a non-Star control object, it may not run
#         normally... we recommend register 'OPOS CCO'." It also matters because the repo
#         installs POS for .NET, whose legacy bridge wraps a registered OPOS CO/SO.
#      OPOS POSPrinter -> Add New -> (device) -> Configure -> Add New -> <PCNAME>_Printer
#      OPOS CashDrawer -> Add New -> (device) -> Configure -> Add New -> <PCNAME>_Drawer
#      Apply Changes
#    Two-level naming: "Add New" creates the DEVICE (the registry subkey, left at its vendor
#    default); "Configure -> Add New" creates the LOGICAL DEVICE NAME the application opens.
#    <POSname>_Printer / _Drawer must be the LDNs. Use this bench PC's current computer name
#    as <PCNAME> so the collector's default LDN check lines up.

# 4. AFTER snapshot - same command again; rename it after.txt

# 5. diff
Compare-Object (gc .\before.txt) (gc .\after.txt) | Format-Table -Wrap
```

**Send back three files:** `before.txt`, `after.txt`, and the `Compare-Object` output. They
settle: which hive moved, the ProgID in each device key's `(default)`, and every value name /
type / data for both devices. File the raw capture here as
`printer_fingerprint_tsp100_<yyyymmdd>.txt`, per the convention below.

### Risks to watch during the capture — report, don't work around

1. **OPOS is Star Line mode only.** The manual's chapter heading is literally
   `4.7. OPOS Installation <Star Line mode only>`, and a TSP100 may default to
   raster/futurePRNT mode. If the emulation has to be switched, note what you changed — and
   check whether it rides the utility's *importable* XML (the ZIP ships
   `Windows/ConfigurationSettingFiles/*/default config.xml` and `escpos.xml`, which suggests it
   does). That part **would** be automatable even though OPOS is not.
2. **No printer attached.** futurePRNT does not create the print queue until the printer is
   powered on, and the utility may enumerate queues. If `Add New` refuses without hardware, the
   capture needs a real TSP100 on the bench — there is no way around it. **Report that rather
   than inventing values.**
3. **Which hive.** `WOW6432Node` is expected (Star's SOs are 32-bit COM, matching
   `$PrinterOposRoot`) but **unverified** — hence exporting both views. If futurePRNT writes the
   64-bit view instead, add a per-brand `Root` to `$PrinterBrands` *then*, not pre-emptively.
4. **Uninstall leftovers.** Unknown whether Star's uninstaller strands OPOS device keys. POS-X
   measurably does, which is why our `regKeysCreated` removal is load-bearing. Check during the
   round-trip; the reversal covers us either way.
5. **Fallback if OPOS proves ugly.** futurePRNT's Windows print-queue driver can kick the drawer
   itself via its "Peripheral Unit" settings (document top/bottom). Not the plan, but it exists.

## What only a real printer can answer

1. **The USB PnP identity — VID / PID / status / device path.** We have no sample at all.
   This is the single most valuable thing a field run returns, and it is what a future build
   would need to detect "printer present" the way the scanner step detects a scanner.
2. **`ClaimDevice` and `PrintNormal` actually succeeding.** On the bench `ClaimDevice(2000)`
   returns **112 (OPOS_E_TIMEOUT)** with no hardware — expected, and *not* 107/NOHARDWARE.
   A real unit should return 0.
3. **Whether the drawer actually fires** on the printer's RJ-11 with `DrawerOpen=1`. The
   registry half is settled (below); what no bench can prove is a real drawer kicking when the
   receipt prints. That is the acceptance test now — there is no `OpenDrawer()` call to make,
   because there is no drawer device.
4. **Whether Alleaves opens the LDN we register.** Alleaves Terminal is only a launcher; the
   real client is pulled from CloudFront at runtime, so its contract could not be inspected
   statically. If it cannot see the printer, capture what logical name it *is* asking for.
5. Whether a Windows print queue unexpectedly appears (section 5 of the report). Nothing is
   expected there; if something shows up, that is informative.

## Field confirmations so far

| Date | Brand | Machine | Printer model / USB VID:PID | Result |
|---|---|---|---|---|
| 2026-08-10 | POS-X | `DESKTOP-FI6BRLV` (Win11 26200) — **bench, no hardware** | none attached | install `ResultCode=0`; `Open('DESKTOP-FI6BRLV_Printer')` → `0`, `Open('..._Drawer')` → `0`; `ClaimDevice` → `112` (expected, no hardware); uninstall removed 61 values + 5 keys cleanly *(two-device build, pre-2026-08-12)* |
| 2026-08-28 | StarTSP100 | `DESKTOP-FI6BRLV` (Win11 26200) — **bench, no hardware** | none attached | **install half only.** download 493,881,478 B first attempt; tar extracted `setup_x64.exe` (111,399,952 B) at its stored path; `/s /v"/qn /norestart"` → exit `0`, silent, ~4.5 min; **one** ARP row (32-bit view); re-run 1 s vs 274 s = `already installed; skipping`; `Set-PrinterOpos` → `not-captured`, exit `7`, nothing written under `ServiceOPOS`. **OPOS half unproven — capture not yet run.** |

*(no real-hardware rows yet — first field run pending; no Star rows at all until the capture)*

**Still open:**

- **POS-X:** everything in "What only a real printer can answer" above. Until a row here
  records `ClaimDevice → 0` and a printed receipt, the hardware half of this step is unproven.
- **Star TSP100:** the whole OPOS half. The install half (download → extract → silent install →
  ARP detection → silent uninstall) ships now; the four value tables are empty until the
  capture above is run, and a `-PrinterBrand StarTSP100` run exits **7** (`not-captured`) in the
  meantime. Nothing about Star's OPOS registration has been observed on real hardware or a real
  bench yet.

## Conventions

- `Date` ISO (`2026-08-10`). `Machine` = computer name in backticks with the OS build.
- `Printer model / USB VID:PID` = whatever section 3 of the report shows, verbatim.
- `Result` = a compact semicolon-separated chain of observed facts and the outcome.
- Raw captures go in `docs/` next to this file, named
  `printer_fingerprint_<model>_<yyyymmdd>.txt`.
- Diagnostic/probe scripts stay in the scratchpad, not the repo.
- **Stop and report before any git commit/push.**
