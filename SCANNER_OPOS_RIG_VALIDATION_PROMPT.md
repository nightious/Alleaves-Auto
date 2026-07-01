# Next step: finalize + validate the scanner USB-OPOS step on the physical rig

> Hand this prompt to a Claude Code session **running on the authorized test rig with a
> physical Zebra scanner (ideally a DS2208) attached**. It is the follow-on to the work
> recorded in `SCANNER_OPOS_PLAN.md` (the design) — that step is implemented and was verified
> only to DryRun + build-SHA256; the real OPOS switch, exact USB PIDs, and hop timing were
> deliberately deferred to hardware. This prompt finalizes them.

## Context (what already exists)

`alleaves_setup.ps1` already contains the full final step. Read it first, plus `CLAUDE.md`
(repo conventions) and `SCANNER_OPOS_PLAN.md` (the design + the host-variant code table).

- **`Set-ScannerOpos`** (+ helpers `Get-CoreScannerInventory`, `Get-ScannerHostModeFromPid`,
  `Invoke-ScannerHostSwitch`, `Invoke-ScannerHostSwitchResilient`, `Confirm-ScannerServicesReady`,
  `Get-ReenumeratedScanner`, `Set-OneScannerToOpos`, `Show-ScannerBarcodeFallback`) drives the
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
- **The placeholders you are here to finalize** are the block marked
  `*** RIG-DEPENDENT — FINALIZE ON THE TEST RIG ... ***` / `TODO[rig]`:
  - `$ScannerPidsOpos` — USB OPOS host PID(s) (currently `@()`)
  - `$ScannerPidsHidKb` — USB HID-Keyboard PID(s) (currently `@()`)
  - `$ScannerPidsIbmSnapi` — USB IBM/SNAPI PID(s) (currently `@()`)
  - `$ScannerReenumWaitSec` — re-enumeration settle time between hops (currently `12`)
  - `$ScannerModelsNoOpos` — model regex for OPOS-incapable units (currently `''`)
  - `$ScannerServiceDisplayPatterns` — DisplayName globs used to find the Zebra services to start;
    **confirm the real `Get-Service` short-names** (`RSM Driver Provider` / `Symbol Scanner
    Management` names vary by SDK version) and pin them.
  - `$ScannerServiceSettleSec` (`8`), `$ScannerSwitchMaxRetries` (`3`), `$ScannerRetryWaitSec` (`5`)
    — tune from how long RSM takes to become ready after the services start.
  With the PID lists empty, every scanner reads `'unknown'` → takes the safe **universal
  two-hop**, which is valid from any starting mode. So nothing is broken today; you are
  enabling the `already-opos` skip + the direct-from-IBM/SNAPI shortcut, and confirming timing.
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
   Pin the confirmed names in `$ScannerServiceDisplayPatterns` (or switch to exact `-Name` lookups).

1a. **Reproduce + confirm the 112 fix.** With the scanner in factory HID-KB, stop the RSM/Symbol
   service(s), run `Install-Alleaves.bat -ScannerConfigOnly`, and confirm hop1 returns **112**; then
   confirm the resilient retry (which re-runs `Confirm-ScannerServicesReady`) recovers, OR that a
   clean install-then-switch (services already up) no longer hits 112 at all. If start+retry does NOT
   clear 112 in-session, escalate to a `Restart-Service CoreScanner` before `Open()`, or defer the
   switch to a post-reboot one-shot task — document which was needed.

2. **Capture the live PID for each host mode** (this is the crux). For the attached model, record
   the `GetScanners` `<PID>`, `<modelnumber>`, `<serialnumber>` while the scanner is in each mode:
   **HID-Keyboard** (factory default), **IBM Hand-held**, and **OPOS**. Get there either by
   driving `ExecCommand(6200, ...)` with the codes above, or by setting each mode in **123Scan**
   and reading the PID back. A throwaway diagnostic script that loads the Interop DLL and dumps the
   parsed `GetScanners` XML is the cleanest way — put it in the scratchpad, not the repo.
   *Record the exact hex PID strings as they appear in the XML (e.g. `0x????`).*

3. **Fill in the constants** in `alleaves_setup.ps1` from the captured values:
   `$ScannerPidsOpos`, `$ScannerPidsHidKb`, `$ScannerPidsIbmSnapi`. Set `$ScannerReenumWaitSec`
   to a value comfortably above the **slowest** reconnect you observe (measure it; don't guess).
   Replace the `TODO[rig]` / `PLACEHOLDER` wording on each line you finalize with the confirmed
   value + a short "confirmed on rig <model>" note. Leave `$ScannerModelsNoOpos` empty unless you
   actually have an OPOS-incapable model to encode.

4. **Exercise the real two-hop from the factory default.** Reset the scanner to **USB HID
   Keyboard** first (scan "Set Defaults" / "USB HID Keyboard", or via 123Scan), then run
   `-ScannerConfigOnly`. Confirm it walks HID-KB → IBM Hand-held → OPOS, the unit re-enumerates
   each hop, and it ends in **USB-OPOS** (Device Manager / `GetScanners` PID). Confirm the
   **Alleaves POS reads scans via OPOS**. Manifest `scannerConfigured` should show
   `result=ok, hostBefore=HID-KB (or unknown), target=USB-OPOS, removable=false`; run exits `0`.

5. **Verify the other paths:**
   - **Idempotent re-run:** run again → `already-opos` skip, *no* re-enumeration, exit `0`
     (this is what filling `$ScannerPidsOpos` buys — confirm the PID-based skip fires).
   - **No-scanner:** unplug, run → Warn "no Zebra scanner connected", `result=no-scanner`, exit `0`.
   - **Direct path (optional):** put the scanner in IBM/SNAPI, run → confirm the direct-to-OPOS
     branch (single hop) works once `$ScannerPidsIbmSnapi` is populated.
   - **Multi / other model (if available):** confirm the same code path puts a 2nd model
     (e.g. DS8108) into OPOS unchanged.

6. **Decide on the post-switch verification.** Now that `$ScannerPidsOpos` is populated,
   `Set-OneScannerToOpos` confirms success by the post-switch PID. Sanity-check that the
   "trust status 0 when the PID table is empty" fallback is no longer the path being taken; keep
   it as defense-in-depth or tighten it — your call, but document the choice in a comment.
   **If PID detection proves unreliable on the rig**, leave the PID lists empty and rely on the
   universal two-hop (the code already does this); note that in the constants block and in CLAUDE.md.

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
     the confirmed PIDs / timing.

## Conventions + guardrails

- Match existing style: `Step`/`Ok`/`Warn`/`Fail`/`Dry` helpers, `$DryRun` guard, per-function
  try/catch with `Warn` fallback, manifest append. Keep OPOS a **command**, never ship/embed a
  `.scncfg`. Uninstall stays **record-only** (`removable=$false`).
- Resetting the scanner between test cycles: the switch is `permanent=TRUE`, so to re-test the
  HID-KB path you must scan "USB HID Keyboard" / "Set Defaults" (or use 123Scan) to revert it.
- Diagnostic/probe scripts go in the scratchpad, not the repo.
- **Stop and report before any `git commit`/`push`.**
