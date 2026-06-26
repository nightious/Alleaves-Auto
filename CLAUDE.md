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
  `-SkipMasterList`, `-SkipPrograms <regex...>`, `-SkipRename/-SkipChromeTaskbar/-SkipDefaultBrowser`.
- **Dev run without packing:** `PowerShell -File .\alleaves_setup.ps1 -DryRun`.
- Working root is `%ProgramData%\AlleavesAuto` (`downloads\`, `logs\`, manifest) so state
  survives a later `-Uninstall` (the `.bat` deletes the decoded `.ps1`).

## Architecture / flow

Install order: **Chrome → Alleaves Terminal → Zebra 123 Scan → Zebra Scanner SDK →
POS for .NET → NiceLabel → Master List (`.nlbl`) → Splashtop SOS.**

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
- **Manifest persistence** — JSON records every install (method, exit code, logs), placed
  files, registry changes, and scheduled tasks. Uninstall replays it in **reverse order**.

## Conventions (match these when editing)

- Console helpers: `Step` (cyan) / `Ok` (green) / `Warn` (yellow) / `Fail` (red) / `Dry` (gray).
- `$ErrorActionPreference = 'Continue'`; per-function try/catch with `Warn` fallback. Every
  result is recorded to the manifest so partial failures **don't** exit 0.
- Naming: CamelCase functions (`Invoke-*`, `Get-*`), UPPERCASE globals, snake_case manifest keys.
- Idempotency: registry lookup before install/uninstall; manifest **merge** (never drop prior
  items); cached extracted MSIs skip future wrapper runs. Guard state changes behind `-DryRun`.
- TLS 1.2 is forced before any network call (stock Win10 defaults too low for the CDNs).
- Exit codes: `0` ok, `1` install/uninstall fail, `2` mode ambiguity, `3` not elevated,
  `4` scanner degraded (CoreScanner missing), `5` working-dir creation failed.

## Gotchas / project rules

- **Production bar for every install step: bootstrap + track (manifest) + reverse (uninstall).**
  Don't add a step that can't be cleanly uninstalled.
- The master list is a `.nlbl` — copy it **as-is, never unzip**; the "encryption" is NiceLabel's
  internal format. It's copied to both admin and cashier Documents.
- NiceLabel needs an explicit service / registry / ProgramData sweep on uninstall; **never
  pre-clean on reinstall** (MSI maintenance mode breaks).
- Zebra products use InstallShield `.iss` response-file silent installs; CoreScanner requires
  VC++ first to avoid a forced mid-install reboot.
- Single elevation owner is `Install-Alleaves.bat`; the `.ps1` never self-relaunches — it aborts
  if not admin (except `-DryRun`, which falls back to `%TEMP%`).
- Runtime state (`downloads/`, `logs/`, `*.exe/*.msi/*.zip` payloads, `alleaves_b64.txt`) is
  git-ignored and created on the target terminal — don't commit it.
