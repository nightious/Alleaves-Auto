# POS-X receipt printer — field confirmations

Running table of real-terminal results for the OPOS receipt-printer step, mirroring
`SCANNER_OPOS_RIG_VALIDATION_PROMPT.md`'s "Field confirmations so far".

Since 2026-08-12 the cash drawer has **no OPOS device of its own** — it follows the printer via
the printer key's `DrawerOpen` value (captured below).

Every row is backed by a `printer/Collect-PrinterFingerprint.ps1` report. Add a row per
terminal; attach or paste the raw capture into `docs/` alongside, as the scanner work does.

## What is already proven (do not re-litigate)

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

| Date | Machine | Printer model / USB VID:PID | Result |
|---|---|---|---|
| 2026-08-10 | `DESKTOP-FI6BRLV` (Win11 26200) — **bench, no hardware** | none attached | install `ResultCode=0`; `Open('DESKTOP-FI6BRLV_Printer')` → `0`, `Open('..._Drawer')` → `0`; `ClaimDevice` → `112` (expected, no hardware); uninstall removed 61 values + 5 keys cleanly *(two-device build, pre-2026-08-12)* |

*(no real-hardware rows yet — first field run pending)*

**Still open:** everything in "What only a real printer can answer" above. Until a row here
records `ClaimDevice → 0` and a printed receipt, the hardware half of this step is unproven.

## Conventions

- `Date` ISO (`2026-08-10`). `Machine` = computer name in backticks with the OS build.
- `Printer model / USB VID:PID` = whatever section 3 of the report shows, verbatim.
- `Result` = a compact semicolon-separated chain of observed facts and the outcome.
- Raw captures go in `docs/` next to this file, named
  `printer_fingerprint_<model>_<yyyymmdd>.txt`.
- Diagnostic/probe scripts stay in the scratchpad, not the repo.
- **Stop and report before any git commit/push.**
