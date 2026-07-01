# CLAUDE.md

Guidance for Claude Code when working in this repo. For end-user usage, see `README.md`.

## Overview

AlleavesAuto is a single-file, self-bootstrapping POS installer for "Alleaves" on stock
Windows 10/11 terminals. It is silent, idempotent (re-runs skip installed products), and
reversible (manifest-driven uninstall). `alleaves_setup.ps1` is the **source of truth**;
`Install-Alleaves.bat` is a **generated transport** — `build-bat.ps1` base64-packs the `.ps1`
into the `.bat`, which elevates once and runs the embedded script. No Python/gdown, no shipped
folder: the `.bat` is the whole deliverable.

## Build & run

- **Build the deliverable:** `.\build-bat.ps1` — base64-packs `alleaves_setup.ps1` →
  `Install-Alleaves.bat`, then self-verifies via SHA256. **Always rebuild the `.bat` after
  editing the `.ps1`** — the `.bat` is generated and won't pick up `.ps1` edits otherwise.
- **Run (target terminal):** `Install-Alleaves.bat` (elevates once). Options:
  `-Uninstall`, `-DryRun` (no admin required), `-ComputerName "POS-1"`, `-ForceReinstall`,
  `-SkipMasterList`, `-SkipPrograms <regex...>`,
  `-SkipRename/-SkipChromeTaskbar/-SkipDefaultBrowser/-SkipScannerConfig`,
  `-ScannerConfigOnly` (run ONLY the final USB-OPOS step — no downloads/installs/finishing;
  for iterating the OPOS switch on the rig or configuring a later-attached scanner).
- **Dev run without packing:** `PowerShell -File .\alleaves_setup.ps1 -DryRun`.
- Working root is `%ProgramData%\AlleavesAuto` (`downloads\`, `logs\`, manifest) so state
  survives a later `-Uninstall` (the `.bat` deletes the decoded `.ps1`).

## Architecture / flow

Install order: **Chrome → Alleaves Terminal → Zebra 123 Scan → Zebra Scanner SDK →
POS for .NET → NiceLabel → Master List (`.nlbl`) → Splashtop SOS → Scanner USB-OPOS (final).**

Major function groups in `alleaves_setup.ps1`:
- **Download phase** — native Google Drive fetch; magic-byte sniffing rejects HTML
  interstitials; size/truncation guards.
- **Install loop** — dispatches per family: MSI (`msiexec /qn`), raw `.exe`, InstallShield
  `.iss` response-file silent installs, and wrapper-MSI extraction (poll `%TEMP%`, wait for
  MSI size to stabilize, cache the extracted MSI).
- **Silent uninstall** — registry lookup + per-family flags; registry polling is authoritative
  for completion; kills hung launchers.
- **VC++ bootstrap** — installed before Zebra CoreScanner to avoid a mid-install reboot.
- **Post-reboot finishing** — computer rename, Chrome taskbar pin / Edge removal, default
  browser via UserChoice hashes (deferred to a logon task; UCPD disabled for next boot).
- **Scanner USB-OPOS (final functional step)** — `Set-ScannerOpos` drives the already-installed
  CoreScanner COM driver to flip every connected Zebra scanner to USB-OPOS. Model-agnostic:
  one command (`ExecCommand(6200, "XUA-45001-8", silent, permanent)`), no per-model config.
  From the factory HID-Keyboard default it hops **HID-KB → IBM Hand-held → OPOS**. HID-KB exposes
  no asset data (blank serial/model), so re-matching after each USB re-enumeration is
  **serial-agnostic** (`Get-ReenumeratedScanner`: 1-scanner terminals take the sole unit; serial is
  read back once the device is in a managed mode). The switch rides the **RSM** channel, which is
  unavailable right after the SDK install (`ExecCommand` status **112** "Device Unavailable") —
  `Confirm-ScannerServicesReady` starts the CoreScanner/RSM/Symbol-Scanner-Management services and
  `Invoke-ScannerHostSwitchResilient` retries 112, so the switch works in-session before the reboot.
  On terminal failure `Show-ScannerBarcodeFallback` prints the one-scan `Scanner_OPOS_barcode.pdf`
  instructions (exit 6, non-fatal). No scanner attached = benign Warn, exit 0.
- **Manifest persistence** — JSON records every install (method, exit code, logs), placed
  files, registry changes, scheduled tasks, and scanner OPOS results. Uninstall replays it in
  **reverse order**.

## Conventions (match these when editing)

- Console helpers: `Step` (cyan) / `Ok` (green) / `Warn` (yellow) / `Fail` (red) / `Dry` (gray).
- `$ErrorActionPreference = 'Continue'`; per-function try/catch with `Warn` fallback. Every
  result is recorded to the manifest so partial failures **don't** exit 0.
- Naming: CamelCase functions (`Invoke-*`, `Get-*`), UPPERCASE globals, snake_case manifest keys.
- Idempotency: registry lookup before install/uninstall; manifest **merge** (never drop prior
  items); cached extracted MSIs skip future wrapper runs. Guard state changes behind `-DryRun`.
- TLS 1.2 is forced before any network call (stock Win10 defaults too low for the CDNs).
- Exit codes: `0` ok, `1` install/uninstall fail, `2` mode ambiguity, `3` not elevated,
  `4` scanner degraded (CoreScanner missing), `5` working-dir creation failed, `6` scanner
  present but USB-OPOS switch failed (re-run). `4` and `6` are non-fatal "re-run" codes that
  never mask an exit `1`.

## Gotchas / project rules

- **Production bar for every install step: bootstrap + track (manifest) + reverse (uninstall).**
  Don't add a step that can't be cleanly uninstalled.
- The master list is a `.nlbl` — copy it **as-is, never unzip**; the "encryption" is NiceLabel's
  internal format. It's copied to both admin and cashier Documents.
- NiceLabel needs an explicit service / registry / ProgramData sweep on uninstall; **never
  pre-clean on reinstall** (MSI maintenance mode breaks).
- Zebra products use InstallShield `.iss` response-file silent installs; CoreScanner requires
  VC++ first to avoid a forced mid-install reboot.
- **Scanner USB-OPOS is a CoreScanner *command*, not a file** — never ship/embed a `.scncfg`.
  `Set-ScannerOpos` is the LAST functional step and **records-only** on uninstall
  (`removable=$false`, like the rename/TeamViewer removal). It can also be run standalone via
  `-ScannerConfigOnly` (its own dispatch branch — `Save-Manifest` merges onto the prior manifest,
  so only `scannerConfigured` is updated). Both that branch and the full install build their
  manifest from the shared `New-InstallManifest` so the key set can't drift. You **cannot** switch HID-Keyboard →
  OPOS directly (only IBM Hand-held/SNAPI), so the two-hop is mandatory. Exact per-mode USB PIDs,
  hop timing, post-switch verification, **the Zebra service short-names**, and **whether starting the
  services (vs. a full restart/reboot) actually clears status 112** are **rig-dependent** — the
  constants in `Set-ScannerOpos` are clearly marked `RIG-DEPENDENT` / `TODO[rig]` placeholders to
  finalize with a physical scanner; until then an unknown mode safely takes the universal two-hop.
  Host mode is read **type-first** (`Get-ScannerHostMode` uses the GetScanners `type="..."` attribute —
  `USBOPOS` etc. — then the PID tables; `<PID>` is DECIMAL). Confirmed on GEMZINVENTORY (2026-07-01):
  the pre-fix in-session switch failed with **status 112** (RSM not ready) + a blank-serial re-match
  miss — the current code addresses both. Confirmed on DESKTOP-GG0BMOA (2026-07-01, DS2208): the three
  Zebra service short-names (`CoreScanner`, `rsmdriverproviderservice`, `ScnSrvc`, now pinned in
  `$ScannerServiceNames`) and OPOS `type=USBOPOS` / PID `4864` (0x1300). Still to capture on hardware:
  HID-KB/IBM type+PID, hop timing, and one real in-session 112→recovery run. `scanner/Scanner_OPOS_barcode.pdf` (committed
  under `scanner/`) is the no-PC barcode fallback: the single **"OPOS (IBM Hand-Held with Full Disable)"**
  USB host-type barcode from the DS2208 PRG (MN-002874-14EN, p.7-5). It sets OPOS in **one scan** from
  the factory HID-Keyboard default — the two-hop above is an SDK `DEVICE_SWITCH_HOST_MODE` constraint
  (HID-KB lacks the Remote-Management channel), **not** a barcode one. Reproduced as clean vector
  (verified decode `SXUAH20008`, matches the official barcode); it is a doc deliverable — **not**
  embedded in the installer, so no `.bat` rebuild on changes. Physical cold-scan still pending hardware.
- Single elevation owner is `Install-Alleaves.bat`; the `.ps1` never self-relaunches — it aborts
  if not admin (except `-DryRun`, which falls back to `%TEMP%`).
- Runtime state (`downloads/`, `logs/`, `*.exe/*.msi/*.zip` payloads, `alleaves_b64.txt`) is
  git-ignored and created on the target terminal — don't commit it.
