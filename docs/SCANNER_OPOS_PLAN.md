# Auto-set Zebra scanners to USB-OPOS (final install step)

> Approved implementation plan for AlleavesAuto. Source of truth for the work:
> add a final, model-agnostic step that flips the connected Zebra scanner(s) to USB-OPOS via the
> already-installed CoreScanner driver. Edit `alleaves_setup.ps1` (source of truth), then rebuild
> `Install-Alleaves.bat` with `build-bat.ps1`.

## Context

Today a tech manually opens **123Scan** and runs *Load to scanner* to put each Zebra **DS2208**
(and any other Zebra USB scanner) into **USB-OPOS** mode so the Alleaves POS can read it. We want
that to happen automatically as the **last step** of the AlleavesAuto run — after everything else is
installed and configured, the connected scanner is flipped to OPOS.

**Research conclusion (answers the "single config for all scanners?" question):** **Yes.** Turning
on OPOS does **not** need a per-model config file or a 1-5 model menu. It is a single, model-agnostic
CoreScanner command — `ExecCommand(6200 = DEVICE_SWITCH_HOST_MODE, "XUA-45001-8", silent, permanent)`.
The host-variant codes are part of the shared CoreScanner/RSM architecture and are **identical across
all Zebra USB scanner families** (DS2208, DS4608, DS8108, DS9308, MP7000, LI2208, …):

| Code | Mode | | Code | Mode |
|------|------|--|------|------|
| XUA-45001-1 | USB IBM Hand-held | | XUA-45001-8 | **USB OPOS** |
| XUA-45001-2 | USB IBM Table-top | | XUA-45001-9 | USB SNAPI (imaging) |
| XUA-45001-3 | USB HID Keyboard | | XUA-45001-11 | USB CDC Serial |

**Scope — works for any OPOS-capable Zebra USB scanner, not just the DS2208.** CoreScanner provides
"a single programming interface … for all scanner communication variants … for all scanners," so the
same opcode-6200 / `XUA-45001-8` call applies across **DS** handhelds/presentation (DS2208, DS2278,
DS4608, DS8108, DS8178, DS9308, DS9908…), **LI** linear imagers (LI2208, LI4278…), **MP** bioptics
(MP7000, MP6200), and **cordless + cradle** units (DS8178/cradle — handled as a cascaded device).
The command/code is universal; only *whether a model supports OPOS* is per-model (a few entry-level
or pre-RSM Symbol models support only IBM Hand-held/SNAPI). Because `Set-ScannerOpos` reads model/PID
from `GetScanners` at runtime, it **auto-adapts to whatever is plugged in** — it does not hardcode
DS2208 — and records a model that lacks OPOS as `unsupported` (Warn), not a failure.

**The one gotcha (verified):** you **cannot** switch directly from the factory **HID-Keyboard**
default to OPOS — from HID-KB the only allowed targets are **IBM Hand-held** or **SNAPI**. So the
routine must hop **HID-KB → IBM Hand-held (XUA-45001-1) → OPOS (XUA-45001-8)**, waiting for USB
re-enumeration between hops (the scanner reconnects and its `scannerID` changes). This is Zebra's
documented, supported path. `permanent=TRUE` makes it survive power cycles; skipping the switch when
already OPOS also dodges an old-driver "switch-to-OPOS-while-OPOS" hang (our SDK v3.07 is current).

**Net:** native PowerShell via the already-installed CoreScanner driver, **zero new dependencies**,
one universal code path for all scanner models. The per-model `.scncfg` + opcode 5020 path is
**documented as a future option only** — needed solely if you later want full parameter sets (beeper
volume, symbologies, etc.) beyond OPOS; that's the only scenario where a model menu/detection matters.

Decisions taken: **inline, 1 scanner per terminal**, run **last**; **uninstall records only** (does
not reset the scanner); **also ship a one-barcode OPOS fallback** for no-PC/no-scanner situations.

References: Zebra TechDocs *PowerShell Scripts for Windows – Examples*
(`techdocs.zebra.com/dcs/scanners/powershell-scripts-windows/examples/`), *Scanner SDK for Windows –
API* (`.../sdk-windows/api/`), and the Zebra support thread "change Host Variant HID Keyboard → OPOS"
(confirms the required two-hop).

## Runtime flow (the new last step)

CoreScanner is already installed + verified present at `alleaves_setup.ps1:2294-2302` (sets
`$script:ScannerDegraded` if missing). The new step:

1. Load `C:\Program Files\Zebra Technologies\Barcode Scanners\Common\Interop.CoreScanner.dll`;
   `$obj = New-Object Interop.CoreScanner.CCoreScannerClass`.
2. `$obj.Open(...)` (scannerTypes[0]=1 = all), then `$obj.GetScanners(...)`; parse OutXML for every
   connected Zebra scanner (`<scannerID>`, `<modelnumber>`, `<serialnumber>`, `<PID>`).
3. For each scanner, derive current host mode (from `<PID>` — each mode enumerates a distinct USB
   PID) and route to OPOS:
   - already **OPOS** → skip (idempotent);
   - **HID-KB** (or unknown) → `ExecCommand(6200, "XUA-45001-1", TRUE, TRUE)` → wait + re-`GetScanners`
     (ID changes) → `ExecCommand(6200, "XUA-45001-8", TRUE, TRUE)` → wait re-enumerate;
   - **IBM/SNAPI** → `ExecCommand(6200, "XUA-45001-8", TRUE, TRUE)` directly.
   inXML: `<inArgs><scannerID>N</scannerID><cmdArgs><arg-string>XUA-45001-8</arg-string><arg-bool>TRUE</arg-bool><arg-bool>TRUE</arg-bool></cmdArgs></inArgs>`
   (1st bool = silent reboot, 2nd = permanent). Treat `$Status==0` + post-switch PID==OPOS as success.
4. Record each scanner's result in the manifest; release the COM object.

**Idempotent re-run / no-scanner:** already-OPOS is a no-op; **no scanner connected = benign Warn,
exit 0** (a terminal set up before its scanner is plugged in still succeeds; just re-run the `.bat`
later with the scanner attached). *Exact per-mode USB PIDs and the hop timing are finalized on the
test rig; if PID detection proves unreliable, fall back to an unconditional `→IBM Hand-held→OPOS`
two-hop, which is valid from any starting mode.*

## Changes to `alleaves_setup.ps1` (source of truth)

Match existing conventions (Step/Ok/Warn/Fail/Dry at `:65-69`; `$DryRun` guard + try/catch + Warn
fallback + manifest append, per `Invoke-Installer`/`Invoke-IssSilent`). No file embedding needed
(OPOS is a command, not a config file) — so **no base64 / no opcode 5020 / no `.scncfg` shipped**.

1. **Param + echo.** Add `[switch]$SkipScannerConfig` to the param block (`:53-57`, with the other
   `-Skip*` finishing switches); append it to the mode echo (`:88-89`).

2. **`$script` flag.** Add `$script:ScannerConfigFailed = $false` next to `$script:ScannerDegraded`
   (`:142`).

3. **New function `Set-ScannerOpos`.** Place among the finishing functions. Implements the Runtime
   flow. Guards (in order): `if ($SkipScannerConfig) { Ok 'scanner OPOS skipped (-SkipScannerConfig)'; return }`;
   `if ($script:ScannerDegraded) { Warn 'CoreScanner missing — skipping scanner OPOS'; return }`;
   `if (-not (Test-Path $interopDll)) { Warn ...; return }`; `$DryRun` → `Dry "would set connected
   Zebra scanner(s) to USB-OPOS via CoreScanner (opcode 6200, XUA-45001-8)"` + record `result='dryrun'`.
   Outcomes per scanner: `ok`, `already-opos`, `no-scanner` (benign), `unsupported` (model lacks
   OPOS → Warn), `fail` (sets `$script:ScannerConfigFailed`). Loops over **all** connected Zebra
   scanners (robust if >1).

4. **Manifest key.** In the `$Manifest` initializer (`:2252-2270`) add `scannerConfigured = @()`
   (kept out of `installed` so a benign `no-scanner` doesn't trip the failure tally at `:2329`).
   Entry: `@{ serial; model; hostBefore; target='USB-OPOS'; result; removable=$false }`. Add the
   carry-forward merge for this key in `Save-Manifest` (`:1497-1556`), mirroring `dependencies`.

5. **Call site — LAST functional step.** Insert **after** the finishing + master-list steps and
   **immediately before** `Save-Manifest`, i.e. after `:2315`, before `:2318`:
   ```powershell
   # 6. FINAL: image the connected Zebra scanner(s) -> USB-OPOS
   Set-ScannerOpos
   ```
   (Runs after all installs, taskbar/browser finishing, and master-list copy — "the last thing that
   happens," then the manifest captures it.)

6. **Exit code.** After the existing logic (`:2329-2342`), add a distinct non-fatal code mirroring
   the ScannerDegraded→4 design — **exit 6** ("scanner present but OPOS switch failed — re-run"),
   only when `$exitCode -eq 0`. Document it in CLAUDE.md's exit-code list.

## Uninstall — record only (chosen)

Scanner host mode is hardware-external state, like the existing **computer rename** (`:2214-2216`)
and **TeamViewer removal** (`:2218`), both intentionally not reverted. **No new code in
`Invoke-UninstallPhase`**; `scannerConfigured` carries `removable=$false` and is ignored on
`-Uninstall`. Add a one-line note (README/CLAUDE) that uninstall does not reset scanners; a tech can
scan the "USB HID Keyboard" / "Set Defaults" barcode (or re-run 123Scan) to revert. *(Factory-reset
on uninstall via opcode 2015 was considered and deliberately skipped — it needs a scanner attached
at uninstall and is SNAPI-only.)*

## Barcode fallback (no-PC / no-scanner-during-run path) — chosen

Ship a one-page printable sheet with the **"USB OPOS (IBM Hand-held)"** programming barcode so a tech
can set OPOS with zero PC software. Two equivalent sources (one-time, manual — there is no 123Scan
CLI to auto-generate it):
- the single **USB OPOS Hand-held** barcode from the scanner's Product Reference Guide (works per
  model family), **or**
- 123Scan → load an OPOS config → *Print as a sheet of programming barcodes* → save PDF.
Commit as **`Scanner_OPOS_barcode.pdf`** and document in `README.md` (software primary, barcode
fallback; same OPOS result either way).

## Files to modify

- **`alleaves_setup.ps1`** — param switch + echo; `$script:ScannerConfigFailed`; `Set-ScannerOpos`;
  `$Manifest.scannerConfigured` + `Save-Manifest` merge; call site after `:2315` (before
  `Save-Manifest`); exit code 6.
- **`Install-Alleaves.bat`** — regenerated only: run **`.\build-bat.ps1`** after the `.ps1` edits
  (CLAUDE.md rule; it self-verifies via SHA256). No `build-bat.ps1` change.
- **`Scanner_OPOS_barcode.pdf`** — new committed file (one-time, manual).
- **`README.md`** — `-SkipScannerConfig`, scanner-connected behavior, exit code 6, barcode fallback.
- **`CLAUDE.md`** — note the final scanner-OPOS step in the flow + the new exit code.
- The existing committed `DS2208_OPOS.scncfg` stays as reference / future full-config source — **not
  shipped or embedded** by this change.

## Verification (full round-trip + reboot, per project rule)

On the authorized test rig **with a physical Zebra scanner attached** (ideally test from the
factory HID-KB default to exercise the two-hop):

1. **Dry run:** `PowerShell -File .\alleaves_setup.ps1 -DryRun` → new `[DRY]` line, no COM calls, no
   manifest write.
2. **Build:** `.\build-bat.ps1` → SHA256 self-verify passes.
3. **Real run:** `Install-Alleaves.bat` → confirm the OPOS step runs **last**; watch the scanner
   re-enumerate (HID-KB → IBM Hand-held → OPOS). Verify it ends as **USB-OPOS** (Device Manager /
   `GetScanners` PID) and the Alleaves POS reads scans via OPOS. Manifest `scannerConfigured` shows
   `result=ok, target=USB-OPOS, removable=false`; run exits **0**.
4. **Idempotency:** re-run → `already-opos` skip path, no re-enumeration, exit 0.
5. **No-scanner path:** unplug, run → Warn "no Zebra scanner connected," `result=no-scanner`, exit 0.
6. **Multi/other models (if available):** confirm the same code path puts a 2nd model (e.g. DS8108)
   into OPOS unchanged.
7. **Uninstall:** `Install-Alleaves.bat -Uninstall` → scanner left in OPOS, uninstall completes.
8. **Reboot between install/uninstall cycles** before re-testing.
9. **Barcode fallback:** scan `Scanner_OPOS_barcode.pdf` on a clean scanner → ends in OPOS, matching
   the SDK path.

## Key reference snippet (Zebra's official PowerShell pattern to adapt)

```powershell
[System.Reflection.Assembly]::LoadFile("C:\Program Files\Zebra Technologies\Barcode Scanners\Common\Interop.CoreScanner.dll") | Out-Null
$obj = New-Object Interop.CoreScanner.CCoreScannerClass
$status = 0; $appHandle = 0; $outXml = ""; $count = 0
$types = New-Object int16[] 1; $types[0] = 1            # 1 = all scanner types
$obj.Open($appHandle, $types, [int16]1, [ref]$status)
$ids = New-Object int16[] 255
$obj.GetScanners([ref]$count, $ids, [ref]$outXml, [ref]$status)
# parse $outXml -> per scanner: scannerID, modelnumber, PID
$inXml = "<inArgs><scannerID>$id</scannerID><cmdArgs><arg-string>XUA-45001-8</arg-string><arg-bool>TRUE</arg-bool><arg-bool>TRUE</arg-bool></cmdArgs></inArgs>"
$obj.ExecCommand(6200, [ref]$inXml, [ref]$outXml, [ref]$status)   # 6200 = DEVICE_SWITCH_HOST_MODE
```
```
