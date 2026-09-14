# Next step: finalize + validate the scanner USB-OPOS step on the physical rig

> Hand this prompt to a Claude Code session **running on the authorized test rig with a
> physical Zebra scanner (ideally a DS2208) attached**. The step is implemented and was verified
> only to DryRun + build-SHA256; the real OPOS switch, the exact HID-KB/IBM `type` strings, and
> hop reconnect timing were deliberately deferred to hardware. This prompt finalizes them.

## Before you start

Read [SCANNER-OPOS.md](SCANNER-OPOS.md) end to end, then the rig-dependent constants block it names
([#open-items](SCANNER-OPOS.md#open-items)). Everything below assumes you have it: the design, the
host-variant code table, the two-hop rule, the exit codes and every bail row live in that doc — **not**
in a header comment in the script, which is now a one-line pointer.

**The production failure this fixed (GEMZINVENTORY, 2026-07-01):** the in-session switch hit
`ExecCommand` **status 112 "Device Unavailable"** (RSM channel not ready right after the SDK
install, before the reboot) AND a blank-serial re-match miss. `Confirm-ScannerServicesReady`
(starts CoreScanner/RSM/Symbol-Scanner-Management) + `Invoke-ScannerHostSwitchResilient` (retries
112) now address it. **Whether starting the services in-session actually clears 112 — vs. needing a
full restart or a post-reboot deferral — is THE key thing to confirm on the rig.**

## Do this

Work in small loops using **`-ScannerConfigOnly`** (runs only this step — no downloads, installs or
finishing) so you don't re-run the whole installer each time. `Install-Alleaves.bat
-ScannerConfigOnly`, or non-elevated `PowerShell -File .\alleaves_setup.ps1 -ScannerConfigOnly
-DryRun`. Add **`-ForceFingerprint`** to capture the per-hop dump on a model the installer already
knows.

1. **Confirm the driver + services.** Verify the `CoreScanner` service and
   `C:\Program Files\Zebra Technologies\Barcode Scanners\Common\Interop.CoreScanner.dll` exist.
   If not, run the full `Install-Alleaves.bat` once first (it installs the Scanner SDK /
   CoreScanner via the `.iss` path). Then capture the **exact Zebra service short-names + status**:
   ```powershell
   Get-Service | ? { $_.DisplayName -match 'CoreScanner|Scanner Management|RSM|Symbol' } |
     Select Name,DisplayName,Status,StartType | Format-Table -Auto
   ```
   `$ScannerServiceNames` is already pinned (`CoreScanner` / `rsmdriverproviderservice` / `ScnSrvc`,
   rig 2026-07-01) — **re-confirm only if this box runs an SDK other than CoreScanner 3.4.0.0.**

1a. **Reproduce + confirm the 112 fix.** With the scanner in factory HID-KB, stop the RSM/Symbol
   service(s), run `Install-Alleaves.bat -ScannerConfigOnly`, and confirm hop1 returns **112**; then
   confirm the resilient retry recovers, OR that a clean install-then-switch (services already up) no
   longer hits 112 at all. If start+retry does NOT clear 112 in-session, escalate to a
   `Restart-Service CoreScanner` before `Open()`, or defer the switch to a post-reboot one-shot task —
   document which was needed.

2. **Confirm the `type` string for each host mode** (the crux — mode detection keys off `type=`, not
   PID). Record the `GetScanners` `<type>`, `<modelnumber>`, `<serialnumber>` (and `<PID>` for the
   record) while the scanner is in each mode: **HID-Keyboard** (factory default), **IBM Hand-held**,
   and **OPOS**. Run **`Install-Alleaves.bat -ScannerConfigOnly -ForceFingerprint`**: one switch run
   records the parsed XML per hop plus the measured reconnect seconds to
   `%ProgramData%\AlleavesAuto\logs\scanner_new_model_<model>_<timestamp>.txt`. There is **no
   read-only/snapshot mode** — a run always attempts the switch, so start the scanner in the mode you
   want captured and let the two-hop walk it from there.

3. **Finalize the constants** from the captured values: confirm `$ScannerTypeHidKb` /
   `$ScannerTypeIbmSnapi` match the strings you observed, and set `$ScannerReenumMaxWaitSec`
   comfortably above the **slowest** reconnect (measure it; don't guess — the poll exits at the real
   time, so this only caps a failed hop). Replace the `ponytail:` block above
   `$ScannerReenumMaxWaitSec` with the confirmed value plus a "confirmed on rig <model>" note.

4. **Exercise the real two-hop from the factory default.** Reset the scanner to **USB HID
   Keyboard** first (scan "Set Defaults" / "USB HID Keyboard", or via 123Scan), then run
   `-ScannerConfigOnly`. Confirm it walks HID-KB → IBM Hand-held → OPOS, the unit re-enumerates
   each hop, and it ends in **USB-OPOS** (Device Manager / `GetScanners` PID). Confirm the
   **Alleaves POS reads scans via OPOS**. Manifest `scannerConfigured` should show
   `result=ok, hostBefore=HID-KB (or unknown), target=USB-OPOS, removable=false`; run exits `0`.

5. **Verify the other paths:**
   - **Idempotent re-run:** run again → `already-opos` skip, *no* re-enumeration, exit `0`.
   - **No-scanner:** unplug, run → Warn "no Zebra scanner connected", `result=no-scanner`, exit `0`.
   - **Direct path (optional):** put the scanner in IBM/SNAPI, run → confirm the direct-to-OPOS
     branch (single hop) fires once that `type` string is confirmed in `$ScannerTypeIbmSnapi`.
   - **Other family (if available):** confirm a 2nd family (e.g. DS8108) lands in OPOS unchanged, and
     that it **auto-dumps a `scanner_new_model_*.txt` fingerprint + loud warn** (non-fatal, exit `0`);
     send that file, then add the family prefix to the `$ScannerKnownModels` regex. A different *SKU*
     of an already-known family (DS2208-SR7U2100SGW vs DS2208-SR00007ZZWW) must NOT dump a fingerprint.

6. **Confirm the post-switch verification.** `Set-OneScannerToOpos` confirms success from the
   post-hop2 `type` string alone. Capture that string on your rig, and if a real OPOS unit ever
   reports something other than `USBOPOS`, **widen `$ScannerTypeOpos`** — do not bring back a
   "trust a clean status 0" fallback arm.

7. **Full round-trip + reboot** (project rule — no partial tests):
   full `Install-Alleaves.bat` → reboot → confirm OPOS holds and is the **last** step in the log;
   `Install-Alleaves.bat -Uninstall` → confirm the scanner is **left in OPOS** (record-only) and
   uninstall completes; **reboot between install/uninstall cycles** before re-testing.

8. **Barcode fallback.** `scanner/Scanner_OPOS_barcode.pdf` is committed and referenced from the
   README; the open half is only to **scan it on a clean scanner** and confirm it lands in OPOS,
   matching the SDK path.

9. **Finalize the deliverable + docs.**
   - Test against `alleaves_setup.ps1` directly — the `.bat` fetches the *published* `.ps1`, so it
     will not see your edits. They reach the field only via `.\release.ps1 -Version vX.Y.Z`.
   - Update `SCANNER-OPOS.md#open-items` to reflect the finalized constants.
   - Update the memory file `project_scanner_opos_step.md` to mark the rig items done and record
     the confirmed `type` strings / reconnect timing.

## Field confirmations so far

| Date | Machine | Model (reported `<modelnumber>`) | Result |
|---|---|---|---|
| 2026-07-01 | rig | DS2208 (CoreScanner 3.4.0.0) | `type="USBOPOS"` → `OPOS`; services `CoreScanner` / `rsmdriverproviderservice` / `ScnSrvc` pinned |
| 2026-07-31 | `DESKTOP-GT30M4V` (Win10 19045) | `DS2208-SR7U2100SGW`, fw `PAADES00-007-R00`, VID 1504 / PID 4864 | `type="USBOPOS"` → `OPOS`, `already-opos` skip, exit `0` |

Raw capture for the 2026-07-31 row: `docs/scanner_fingerprint_DS2208-SR7U2100SGW_20260731.txt`
(the installer's new-model dump, taken mid-switch with the unit already reporting `USBOPOS`).

That run is a **second independent confirmation of the `type` attribute** (different machine +
CoreScanner install), which is what the skip and direct-hop shortcuts rest on. It also exposed the
exact-match `$ScannerKnownModels` bug, which `-notcontains` had made false-flag every real DS2208 as a
new model — now a family regex ([SCANNER-OPOS.md#known-models](SCANNER-OPOS.md#known-models)).

**Still open:** that unit arrived already in OPOS (`hostBefore=OPOS`), so the two-hop never ran — no
hop status, no reconnect timing. The rest of the pending list is
[SCANNER-OPOS.md#open-items](SCANNER-OPOS.md#open-items); capturing it needs a scanner deliberately
reset to HID-KB (step 4 above).

**Changed 2026-09-09 (audit), still needs a HID-KB run to confirm on hardware** — the rules are in
[SCANNER-OPOS.md](SCANNER-OPOS.md); what to capture:

- **The 112 short-circuit now precedes `Wait-ScannerReenum`.** On a real in-session 112 run, confirm
  the hop fails inside the retry budget alone with no 40 s tail. That budget is ≈ **2 ×
  `$ScannerRetryWaitSec` (~10 s per hop)**, not three waits: the sleep runs only *between* attempts,
  and `$ScannerServiceSettleSec` is slept only if `Confirm-ScannerServicesReady` actually started a
  service — on the in-session path the services were already confirmed Running, so nothing starts and
  nothing settles. Also confirm the hop log still carries an `after hop1 (IBM)` entry (synthesised
  with `s=$null; seconds=0` on that path).
- **A post-switch mode of `unknown` no longer returns `ok`** even with a clean status: capture step 6.
- **Each scanner in the loop has its own try/catch.** Only observable with two scanners attached.

## Conventions + guardrails

Repo conventions are in [CLAUDE.md](../CLAUDE.md) — match them. Two that bite on this rig
specifically: the switch is `permanent=TRUE`, so re-testing the HID-KB path means scanning
"USB HID Keyboard" / "Set Defaults" (or 123Scan) to revert the unit first, and **stop and report
before any `git commit`/`push`.**
