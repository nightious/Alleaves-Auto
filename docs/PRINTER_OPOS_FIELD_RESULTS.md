# POS-X receipt printer + cash drawer — field confirmations

Running table of real-terminal results for the OPOS printer/drawer step, mirroring
`SCANNER_OPOS_RIG_VALIDATION_PROMPT.md`'s "Field confirmations so far".

Every row is backed by a `printer/Collect-PrinterFingerprint.ps1` report. Add a row per
terminal; attach or paste the raw capture into `docs/` alongside, as the scanner work does.

## What is already proven (do not re-litigate)

Verified on the bench rig 2026-08-10, **without any printer attached** — see
`PRINTER_POSX_OPOS_HANDOFF.md` for the full evidence:

- Silent install works: `pkg.exe /s /a /s /L0x0409 /f1"<iss>" /f2"<log>"` → `ResultCode=0`,
  no GUI, ~26 s. **Keep those paths short** — IS5 has a fixed command-line buffer and ~390
  chars crashes the stub (§3.7).
- Silent uninstall works: `IsUninst.exe -y -a -f"…\Uninst.isu"`, ~8 s, no dialog.
- The registry entries are byte-identical to what the vendor's `SetupPOS.exe` writes
  (28 printer values, 33 drawer values, diffed).
- Both devices `Open()` → **0** over 32-bit COM with nothing plugged in.
- Full uninstall round-trip removes all 61 values and all 5 keys, leaving the vendor's
  `OLEforRetail\ServiceInfo` untouched.
- `POSPrinterSOU.dll` imports **no `WINSPOOL.DRV`** — the print path bypasses the spooler
  entirely, so no Windows print driver or queue is needed.

## What only a real printer can answer

1. **The USB PnP identity — VID / PID / status / device path.** We have no sample at all.
   This is the single most valuable thing a field run returns, and it is what a future build
   would need to detect "printer present" the way the scanner step detects a scanner.
2. **`ClaimDevice` and `PrintNormal` actually succeeding.** On the bench `ClaimDevice(2000)`
   returns **112 (OPOS_E_TIMEOUT)** with no hardware — expected, and *not* 107/NOHARDWARE.
   A real unit should return 0.
3. **Whether the drawer fires** on `OpenDrawer()` when hung off the printer's RJ-11, and
   whether `ConnectorPinNo=2` (the captured default) is right for POS-X cabling.
4. **Whether Alleaves opens the LDNs we register.** Alleaves Terminal is only a launcher; the
   real client is pulled from CloudFront at runtime, so its contract could not be inspected
   statically. If it cannot see the printer, capture what logical name it *is* asking for.
5. Whether a Windows print queue unexpectedly appears (section 5 of the report). Nothing is
   expected there; if something shows up, that is informative.

## Field confirmations so far

| Date | Machine | Printer model / USB VID:PID | Result |
|---|---|---|---|
| 2026-08-10 | `DESKTOP-FI6BRLV` (Win11 26200) — **bench, no hardware** | none attached | install `ResultCode=0`; `Open('DESKTOP-FI6BRLV_Printer')` → `0`, `Open('..._Drawer')` → `0`; `ClaimDevice` → `112` (expected, no hardware); uninstall removed 61 values + 5 keys cleanly |

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
