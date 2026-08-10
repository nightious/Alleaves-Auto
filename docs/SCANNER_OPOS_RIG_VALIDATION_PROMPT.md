# Next step: finalize + validate the scanner USB-OPOS step on the physical rig

> Hand this prompt to a Claude Code session **running on the authorized test rig with a
> physical Zebra scanner (ideally a DS2208) attached**. It is the follow-on to the design
> recorded in the `Set-ScannerOpos` header comment in `alleaves_setup.ps1` — that step is implemented
> and was verified only to DryRun + build-SHA256; the real OPOS switch, the exact HID-KB/IBM
> `type` strings, and hop reconnect timing were deliberately deferred to hardware. This prompt finalizes them.

## Context (what already exists)

`alleaves_setup.ps1` already contains the full final step. Read it first — especially the
`Set-ScannerOpos` header comment (the design + the host-variant code table) — plus `CLAUDE.md`
(repo conventions).

- **`Set-ScannerOpos`** (+ helpers `Get-CoreScannerInventory`, `Get-ScannerHostMode`,
  `Invoke-ScannerHostSwitch`, `Invoke-ScannerHostSwitchResilient`, `Confirm-ScannerServicesReady`,
  `Get-ReenumeratedScanner`, `Wait-ScannerReenum`, `Set-OneScannerToOpos`, `Show-ScannerBarcodeFallback`,
  `Write-NewScannerFingerprint`) drives the
  already-installed Zebra CoreScanner COM driver: `Open` → ensure RSM services →
  `GetScanners` → per-scanner route to OPOS via `ExecCommand(6200, "XUA-45001-8", silent, permanent)`.
  From the factory **USB HID-Keyboard** default it does the mandatory two-hop **HID-KB → IBM
  Hand-held (`XUA-45001-1`) → OPOS (`XUA-45001-8`)**. HID-KB reports **no serial/model**, so
  re-matching across USB re-enumeration is **serial-agnostic** (`Get-ReenumeratedScanner` — the sole
  scanner on a 1-scanner terminal), NOT by serial.
- **Production failure this fixed (GEMZINVENTORY, 2026-07-01):** the in-session switch hit
  `ExecCommand` **status 112 "Device Unavailable"** (RSM channel not ready right after the SDK
  install, before the reboot) AND a blank-serial re-match miss. `Confirm-ScannerServicesReady`
  (starts CoreScanner/RSM/Symbol-Scanner-Management) + `Invoke-ScannerHostSwitchResilient` (retries
  112) now address it. **Whether starting the services in-session actually clears 112 — vs. needing a
  full restart or a post-reboot deferral — is THE key thing to confirm on the rig.**
- **The opcode + host-variant codes are STABLE** and must not change:
  `$ScannerOpcodeSwitchHostMode = 6200`, `$ScannerHostCodeOpos = 'XUA-45001-8'`,
  `$ScannerHostCodeIbmHandheld = 'XUA-45001-1'`.
- **What you are here to finalize** (the `RIG-DEPENDENT` / `TODO[rig]` items — mode detection is
  now **type-only**; the per-mode PID tables were deleted 2026-07-09):
  - `$ScannerTypeHidKb` / `$ScannerTypeIbmSnapi` — the `type=` regexes for the HID-KB and IBM
    modes (OPOS = `USBOPOS` already confirmed). Confirm the exact strings a live unit reports in
    those modes so the `already-opos` skip and the direct-from-IBM/SNAPI shortcut fire correctly.
  - `$ScannerReenumMaxWaitSec` (`40`) — the adaptive re-enum **poll ceiling** (`Wait-ScannerReenum`
    polls `$ScannerReenumPollMs` = 1000ms until the unit's Id/type changes). It only bites on a
    failed hop; confirm it sits comfortably above the **slowest** reconnect you measure.
  - `$ScannerServiceNames` — exact `-Name` list of Zebra services to start;
    **confirm the real `Get-Service` short-names** (`RSM Driver Provider` / `Symbol Scanner
    Management` names vary by SDK version) and pin them.
  - `$ScannerServiceSettleSec` (`8`), `$ScannerSwitchMaxRetries` (`3`), `$ScannerRetryWaitSec` (`5`)
    — tune from how long RSM takes to become ready after the services start.
  An unmatched `type` reads `'unknown'` → takes the safe **universal two-hop**, valid from any
  starting mode. So nothing is broken today; you are confirming the type strings (to enable the
  skip + direct shortcut) and the reconnect timing. **Any model outside the known families
  auto-dumps a per-hop fingerprint** to `$LogDir` (`Write-NewScannerFingerprint`) with a loud warn —
  that file has the exact `type`/reconnect data to finalize a new model; add the confirmed model
  **family** to the `$ScannerKnownModels` regex.
- **Fast iteration:** use **`-ScannerConfigOnly`** to run ONLY this step (no
  downloads/installs/finishing). `Install-Alleaves.bat -ScannerConfigOnly`, or non-elevated
  `PowerShell -File .\alleaves_setup.ps1 -ScannerConfigOnly -DryRun`. `Save-Manifest` merges
  onto the prior manifest, so it only updates `scannerConfigured`.
- **Exit codes:** `4` = CoreScanner missing (degraded), `6` = scanner present but OPOS switch
  failed. Both are non-fatal "re-run" codes that never mask a hard `1`. Manifest key is
  `scannerConfigured` (`removable=$false`, record-only on uninstall).

## Do this

Work in small loops using `-ScannerConfigOnly` so you don't re-run the whole installer each time.

1. **Confirm the driver + services.** Verify the `CoreScanner` service and
   `C:\Program Files\Zebra Technologies\Barcode Scanners\Common\Interop.CoreScanner.dll` exist.
   If not, run the full `Install-Alleaves.bat` once first (it installs the Scanner SDK /
   CoreScanner via the `.iss` path). Then capture the **exact Zebra service short-names + status**:
   ```powershell
   Get-Service | ? { $_.DisplayName -match 'CoreScanner|Scanner Management|RSM|Symbol' } |
     Select Name,DisplayName,Status,StartType | Format-Table -Auto
   ```
   Pin the confirmed names in `$ScannerServiceNames`.

1a. **Reproduce + confirm the 112 fix.** With the scanner in factory HID-KB, stop the RSM/Symbol
   service(s), run `Install-Alleaves.bat -ScannerConfigOnly`, and confirm hop1 returns **112**; then
   confirm the resilient retry (which re-runs `Confirm-ScannerServicesReady`) recovers, OR that a
   clean install-then-switch (services already up) no longer hits 112 at all. If start+retry does NOT
   clear 112 in-session, escalate to a `Restart-Service CoreScanner` before `Open()`, or defer the
   switch to a post-reboot one-shot task — document which was needed.

2. **Confirm the `type` string for each host mode** (this is the crux — mode detection keys off
   `type=`, not PID). Record the `GetScanners` `<type>`, `<modelnumber>`, `<serialnumber>` (and
   `<PID>` for the record) while the scanner is in each mode: **HID-Keyboard** (factory default),
   **IBM Hand-held**, and **OPOS**. The repo's **`scanner/Collect-ScannerFingerprint.ps1`** already
   does exactly this — run it (default full walk, or `-SnapshotOnly`); it drives the same
   `ExecCommand(6200, ...)` hops, dumps the parsed XML per mode, and measures the reconnect seconds.

3. **Finalize the constants** in `alleaves_setup.ps1` from the captured values: confirm the
   `$ScannerTypeHidKb` / `$ScannerTypeIbmSnapi` regexes match the strings you observed, and set
   `$ScannerReenumMaxWaitSec` comfortably above the **slowest** reconnect (measure it; don't guess —
   the poll exits at the real time, so this only caps a failed hop). Replace the `TODO[rig]` /
   `ponytail:` wording on each line you finalize with the confirmed value + a "confirmed on rig <model>" note.

4. **Exercise the real two-hop from the factory default.** Reset the scanner to **USB HID
   Keyboard** first (scan "Set Defaults" / "USB HID Keyboard", or via 123Scan), then run
   `-ScannerConfigOnly`. Confirm it walks HID-KB → IBM Hand-held → OPOS, the unit re-enumerates
   each hop, and it ends in **USB-OPOS** (Device Manager / `GetScanners` PID). Confirm the
   **Alleaves POS reads scans via OPOS**. Manifest `scannerConfigured` should show
   `result=ok, hostBefore=HID-KB (or unknown), target=USB-OPOS, removable=false`; run exits `0`.

5. **Verify the other paths:**
   - **Idempotent re-run:** run again → `already-opos` skip, *no* re-enumeration, exit `0`
     (the skip keys off `type=USBOPOS`, already confirmed on the DS2208).
   - **No-scanner:** unplug, run → Warn "no Zebra scanner connected", `result=no-scanner`, exit `0`.
   - **Direct path (optional):** put the scanner in IBM/SNAPI, run → confirm the direct-to-OPOS
     branch (single hop) fires once the IBM/SNAPI `type` string is confirmed in `$ScannerTypeIbmSnapi`.
   - **Other family (if available):** confirm a 2nd family (e.g. DS8108) lands in OPOS unchanged, and
     that it **auto-dumps a `scanner_new_model_*.txt` fingerprint + loud warn** (non-fatal, exit `0`);
     send that file, then add the family prefix to the `$ScannerKnownModels` regex. A different *SKU*
     of an already-known family (DS2208-SR7U2100SGW vs DS2208-SR00007ZZWW) must NOT dump a fingerprint.

6. **Confirm the post-switch verification.** `Set-OneScannerToOpos` confirms success via
   `Get-ScannerHostMode` (the `type=USBOPOS` attribute), falling back to "trust clean status 0"
   only when the type reads `'unknown'`. Sanity-check that on your rig the switch is confirmed by
   **type**, not the status-0 fallback. If the type attribute proves unreliable for a model, that
   model just rides the universal two-hop + status-0 trust — note it in the constants block and CLAUDE.md.

7. **Full round-trip + reboot** (project rule — no partial tests):
   full `Install-Alleaves.bat` → reboot → confirm OPOS holds and is the **last** step in the log;
   `Install-Alleaves.bat -Uninstall` → confirm the scanner is **left in OPOS** (record-only) and
   uninstall completes; **reboot between install/uninstall cycles** before re-testing.

8. **Barcode fallback.** Produce **`Scanner_OPOS_barcode.pdf`** (one-time manual export: the single
   "USB OPOS (IBM Hand-held)" barcode from the model's Product Reference Guide, **or** 123Scan →
   load an OPOS config → *Print as a sheet of programming barcodes* → save PDF). Scan it on a
   clean scanner to confirm it lands in OPOS, matching the SDK path. Commit it and **remove the
   "TODO — not yet committed" markers** from `README.md` and `CLAUDE.md`.

9. **Finalize the deliverable + docs.**
   - Rebuild after **every** `.ps1` edit: `.\build-bat.ps1` (SHA256 self-verify must pass).
     Never hand-edit `Install-Alleaves.bat`.
   - Update `CLAUDE.md` / `README.md` to reflect the finalized (no-longer-placeholder) constants
     and the committed barcode PDF.
   - Update the memory file `project_scanner_opos_step.md` to mark the rig items done and record
     the confirmed `type` strings / reconnect timing.

## Field confirmations so far

| Date | Machine | Model (reported `<modelnumber>`) | Result |
|---|---|---|---|
| 2026-07-01 | rig | DS2208 (CoreScanner 3.4.0.0) | `type="USBOPOS"` → `OPOS`; services `CoreScanner` / `rsmdriverproviderservice` / `ScnSrvc` pinned |
| 2026-07-31 | `DESKTOP-GT30M4V` (Win10 19045) | `DS2208-SR7U2100SGW`, fw `PAADES00-007-R00`, VID 1504 / PID 4864 | `type="USBOPOS"` → `OPOS`, `already-opos` skip, exit `0` |

Raw capture for the 2026-07-31 row: `docs/scanner_fingerprint_DS2208-SR7U2100SGW_20260731.txt`
(the installer's new-model dump, taken mid-switch with the unit already reporting `USBOPOS`).

The 2026-07-31 run is a **second independent confirmation of the `type` attribute** (different
machine + CoreScanner install), which is what the skip and direct-hop shortcuts rest on. It also
exposed the exact-match `$ScannerKnownModels` bug — CoreScanner reports the **kit SKU**
(`DS2208-SR7U2100SGW`; per Zebra, the kit for scanner `DS2208-SR00007ZZWW`), never the bare family
name, so `-notcontains` false-flagged every real DS2208 as a new model. Now a family regex.

**Still open:** that unit arrived already in OPOS (`hostBefore=OPOS`), so the two-hop never ran —
no hop status, no reconnect timing. The `RIG-DEPENDENT` / `TODO[rig]` constants
(`$ScannerReenumMaxWaitSec`, `$ScannerServiceSettleSec`, `$ScannerSwitchMaxRetries`,
`$ScannerRetryWaitSec`) and the in-session status-112 recovery remain **unvalidated**. Capturing
them needs a scanner deliberately reset to HID-KB (step 4 above).

## Conventions + guardrails

- Match existing style: `Step`/`Ok`/`Warn`/`Fail`/`Dry` helpers, `$DryRun` guard, per-function
  try/catch with `Warn` fallback, manifest append. Keep OPOS a **command**, never ship/embed a
  `.scncfg`. Uninstall stays **record-only** (`removable=$false`).
- Resetting the scanner between test cycles: the switch is `permanent=TRUE`, so to re-test the
  HID-KB path you must scan "USB HID Keyboard" / "Set Defaults" (or use 123Scan) to revert it.
- Diagnostic/probe scripts go in the scratchpad, not the repo.
- **Stop and report before any `git commit`/`push`.**
