# CLAUDE.md

Guidance for Claude Code when working in this repo. For end-user usage and the full
option / exit-code tables, see `README.md`.

## Overview

AlleavesAuto is a single-file, self-bootstrapping POS installer for "Alleaves" on stock
Windows 10/11 terminals: silent, idempotent (re-runs skip installed products), reversible
(manifest-driven uninstall). `alleaves_setup.ps1` is the **source of truth**; `Install-Alleaves.bat`
is a **generated transport** — `build-bat.ps1` base64-packs the `.ps1` into the `.bat`, which
self-elevates once and runs the embedded script. The `.bat` is the whole deliverable. `docs/`
holds the scanner design + rig-validation notes; `scanner/` holds the no-PC barcode fallback and
`Collect-ScannerFingerprint.ps1`. README's Files table is the fuller map.

## Build & run

- **Build:** `.\build-bat.ps1` packs `alleaves_setup.ps1` → `Install-Alleaves.bat` and
  self-verifies (SHA256). **Always rebuild the `.bat` after editing the `.ps1`** — it won't pick
  up edits otherwise. Never hand-edit the `.bat`.
- **Run (target terminal):** `Install-Alleaves.bat` (self-elevates once). The `.ps1` `param()`
  block / README's table is the authoritative option set — notably `-Uninstall`, `-DryRun` (no
  admin), `-ForceReinstall`, `-ComputerName`, the `-Skip*` flags, and `-ScannerConfigOnly` (run
  ONLY the final USB-OPOS step — for iterating the switch on the rig or a later-attached scanner).
- **Dev run without packing:** `PowerShell -File .\alleaves_setup.ps1 -DryRun`.
- Working root `%ProgramData%\AlleavesAuto` (`downloads\`, `logs\`; manifest is
  `logs\install_manifest.json`) survives a later `-Uninstall`. `-DryRun` without admin falls back
  to `%TEMP%`.

## Architecture / flow

**Install loop, in order:** Chrome → Alleaves Terminal → Zebra 123 Scan → Zebra Scanner SDK →
POS for .NET → NiceLabel. Around it: TeamViewer is removed first (default;
`-SkipUninstallTeamViewer` keeps it), VC++ bootstraps before the Zebra products, then after the
loop the Master List (`.nlbl`) is copied and the Scanner USB-OPOS switch runs (final functional
step). **Splashtop SOS is download-only** — fetched up front and staged for the tech to run
manually, never installed.

Major function groups in `alleaves_setup.ps1`:
- **Download phase** — native Google Drive fetch; magic-byte sniffing rejects HTML interstitials;
  size/truncation guards.
- **Install loop** — per family: MSI (`msiexec /qn`), raw `.exe`, InstallShield `.iss`
  response-file silent installs, and wrapper-MSI extraction (poll `%TEMP%`, wait for the MSI size
  to stabilize, cache the extracted MSI).
- **Silent uninstall** — registry lookup + per-family flags; registry polling is authoritative for
  completion; kills hung launchers.
- **VC++ bootstrap** — before Zebra CoreScanner, to avoid a mid-install reboot.
- **Post-reboot finishing** — computer rename, Chrome taskbar pin / Edge removal, default browser
  via UserChoice hashes (deferred to a logon task; UCPD disabled for next boot).
- **Scanner USB-OPOS** — final functional step; see the Gotchas bullet.
- **Manifest persistence** — JSON records every install (method, exit code, logs), placed files,
  registry changes, scheduled tasks, TeamViewer removal, scanner results. Uninstall replays it in
  **reverse order**.

## Conventions (match these when editing)

- Colored console helpers `Step` / `Ok` / `Warn` / `Fail` / `Dry`.
- `$ErrorActionPreference = 'Continue'`; per-function try/catch with a `Warn` fallback. Every
  result is recorded to the manifest so partial failures **don't** exit 0.
- Naming: `Verb-Noun` PascalCase functions (`Invoke-*`, `Get-*`), PascalCase globals (`$LogDir`,
  `$Installers`), camelCase manifest keys (`filesPlaced`, `exitCode`, `scannerConfigured`).
- Idempotency: registry lookup before install/uninstall; manifest **merge** (never drop prior
  items); cached extracted MSIs skip future wrapper runs. Guard state changes behind `-DryRun`.
- TLS 1.2 forced before any network call (stock Win10 defaults too low for the CDNs).
- **Exit codes** are an RMM contract set in the `$exitCode` dispatch tail (verify there): `0` ok ·
  `1` install/uninstall/download fail · `2` mode ambiguity · `3` not elevated · `4` scanner
  degraded (CoreScanner missing) · `5` working-dir failed · `6` scanner present but switch failed.
  `4`/`6` are non-fatal "re-run" codes that only set when nothing else failed — never masking `1`.

## Gotchas / project rules

- **Production bar for every install step: bootstrap + track (manifest) + reverse (uninstall).**
  Don't add a step that can't be cleanly uninstalled.
- The master list is a `.nlbl` — copy **as-is, never unzip** (the "encryption" is NiceLabel's
  internal format); copied to both admin and cashier Documents.
- NiceLabel gets an explicit service / registry / ProgramData sweep on uninstall, and must **never
  be pre-cleaned on reinstall**: the raw suite installer reinstalls cleanly over itself, but
  pre-cleaning strips its MSI while bootstrapper state lingers, so the reinstall becomes a *repair*
  that never re-creates the ARP entries — leaving NiceLabel invisible to a later `-Uninstall`. (The
  MSI/`.iss` families ARE pre-cleaned, for the opposite reason: reinstalling over them drops into
  maintenance mode and silently fails / 1603.)
- Zebra products use InstallShield `.iss` response-file silent installs; CoreScanner requires VC++
  first to avoid a forced mid-install reboot.
- **Scanner USB-OPOS is a CoreScanner *command*, not a file** — never embed a `.scncfg` in the
  installer (the committed `scanner/DS2208_OPOS.scncfg` is a reference export it never consumes).
  `Set-ScannerOpos` is the LAST functional step and **records-only** on uninstall
  (`removable=$false`, like the rename / TeamViewer removal); it also runs standalone via
  `-ScannerConfigOnly` (own dispatch branch; `Save-Manifest` merges onto the prior manifest, both
  paths built from the shared `New-InstallManifest` so the key set can't drift). Key traps:
  - The switch **must** two-hop **HID-KB → IBM Hand-held → OPOS**: the SDK's `DEVICE_SWITCH_HOST_MODE`
    only accepts IBM Hand-held or SNAPI as a target out of HID-KB (no direct-to-OPOS). An SDK
    constraint, not a barcode one; an unknown mode safely takes the two-hop.
  - HID-KB exposes no asset data, so re-matching after each USB re-enumeration is serial-agnostic
    (`Get-ReenumeratedScanner`).
  - The switch rides the **RSM** channel, unavailable right after the SDK install (`ExecCommand`
    status **112**); `Confirm-ScannerServicesReady` starts the Zebra services and
    `Invoke-ScannerHostSwitchResilient` retries 112 to *attempt* the switch in-session before the
    reboot. On terminal failure `Show-ScannerBarcodeFallback` prints the one-scan fallback (exit 6,
    non-fatal); no scanner attached = benign Warn, exit 0.
  - Per-mode PIDs, hop/settle timing, retry counts, and post-switch verification are rig-dependent
    (`RIG-DEPENDENT` / `TODO[rig]` in `Set-ScannerOpos`; `Get-ScannerHostMode` / `$ScannerServiceNames`
    hold current values — read those, don't copy them here). Confirmed on DS2208; other models and a
    real in-session 112→recovery run still pending — capture with `scanner/Collect-ScannerFingerprint.ps1`,
    log to `docs/`.
  - `scanner/Scanner_OPOS_barcode.pdf` is the no-PC fallback (one scan from the HID-KB default — the
    two-hop is only the SDK path's constraint). A doc deliverable, **not** embedded, so it needs no
    `.bat` rebuild.
- Single elevation owner is `Install-Alleaves.bat`; the `.ps1` never self-relaunches — aborts if
  not admin (except `-DryRun`).
- Runtime payloads, logs, and the base64 build intermediate (`alleaves_b64.txt`) are git-ignored —
  see `.gitignore`.
