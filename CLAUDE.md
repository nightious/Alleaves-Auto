# CLAUDE.md

Guidance for Claude Code in this repo. End-user usage and the option / exit-code tables are in
`README.md`. **All design rationale lives in `docs/`** — this file does not repeat it.

## What this is

AlleavesAuto is a single-file, self-bootstrapping POS installer for "Alleaves" on stock Windows
10/11 terminals: silent, idempotent (re-runs skip installed products), reversible (manifest-driven
uninstall). `alleaves_setup.ps1` is the **source of truth**; `Install-Alleaves.bat` is a **generated
transport** and the whole deliverable.

## Build & run

```powershell
.\build-bat.ps1                                     # ALWAYS after editing the .ps1
PowerShell -File .\alleaves_setup.ps1 -DryRun       # dev run, no admin, no packing
.\Install-Alleaves.bat                              # target terminal; self-elevates once
```

- **The `.bat` does not pick up `.ps1` edits on its own — rebuild.** Never hand-edit the `.bat`; a
  failed self-verify renames it to `.bat.corrupt`, and that is deliberate.
- The `.ps1` `param()` block is the authoritative option set. Notable: `-Uninstall`, `-DryRun`
  (no admin), `-ForceReinstall`, `-ComputerName`, the `-Skip*` flags, `-ScannerConfigOnly`,
  `-PrinterConfigOnly`.
- Working root `%ProgramData%\AlleavesAuto` (`downloads\`, `logs\`, `logs\install_manifest.json`)
  survives `-Uninstall` by design. `-DryRun` without admin falls back to `%TEMP%`.
- `scanner/` (barcode fallback PDF) and `printer/Collect-PrinterFingerprint.ps1` are doc-style
  deliverables, **not** embedded — editing them needs no rebuild.

## Checks to run before calling a change done

```powershell
.\build-bat.ps1                                     # self-verifies SHA256 out of the written .bat
.\tests\Test-DocLinks.ps1                           # all five exit 0 on pass, 1 on failure
.\tests\Test-AccountPrecheck.ps1
.\tests\Test-ManifestMerge.ps1
.\tests\Test-StepIsolation.ps1
.\tests\Test-InstallerExitCode.ps1
PowerShell -File .\alleaves_setup.ps1 -DryRun
```

Install/uninstall behaviour changes need a **full round trip with a reboot between cycles**, not a
partial test.

## Where the reasoning lives

| Subsystem | Doc |
|---|---|
| Flow, step isolation, exit codes, argument guards, config-only modes, tests | `docs/ARCHITECTURE.md` |
| Account precheck (exit 8) and the automated swap (exit 9) | `docs/ACCOUNT-SWAP.md` |
| Download, install loop, MSI / `.iss` / raw-exe / wrapper families, silent uninstall | `docs/INSTALL-ENGINE.md` |
| Manifest keys, merge rules, `Set-TrackedRegValue`, `-Uninstall` replay | `docs/MANIFEST.md` |
| Rename, taskbar pins, default browser, Chrome bookmark, the logon task | `docs/FINISHING.md` |
| Zebra USB-OPOS switch | `docs/SCANNER-OPOS.md` |
| Receipt-printer OPOS registration | `docs/PRINTER-OPOS.md` |
| `build-bat.ps1` and the `.bat` transport / elevation probe | `docs/BUILD-BAT.md` |
| Printer bench evidence | `docs/PRINTER_OPOS_FIELD_RESULTS.md` |
| Scanner rig validation log | `docs/SCANNER_OPOS_RIG_VALIDATION_PROMPT.md` |

Open hardware items are checklists at the top of `docs/SCANNER-OPOS.md` and
`docs/PRINTER-OPOS.md`.

## Conventions (match these when editing)

- **Comments are pointers, not essays.** New rationale goes in the matching `docs/` file; the code
  gets one line, `# docs/<SUBSYSTEM>.md#<anchor>`. The scripts were deliberately stripped of ~2500 lines of
  narrative — do not re-grow it. Exceptions kept in code: the `<# .SYNOPSIS #>` help blocks (that is
  `Get-Help`'s only source on a customer terminal), and `ponytail:` markers naming a deliberate
  shortcut's ceiling.
- **The pointer web runs both ways and `tests\Test-DocLinks.ps1` enforces it**: every `#anchor` the
  code cites must exist, and every `<a id>` in `docs/` must be cited from somewhere. Add the anchor
  and the pointer in the same change. A bare `#anchor` in parentheses resolves against the doc named
  earlier on the same line, so pointers stay readable.
- **Docs cite stable symbol names, never `:NNNN` line numbers** — a doc pass and a code pass in the
  same session invalidated every line number twice. `Invoke-IssSilent`, not `:1598`.
- **Production bar for every install step: bootstrap + track (manifest) + reverse (uninstall).**
  Don't add a step that can't be cleanly uninstalled.
- **Wrap every new step in `Invoke-Step`** — `Invoke-Step 'Name' { Do-Thing }`. A bare call
  reintroduces the "one throw kills the whole run" bug; `tests\Test-StepIsolation.ps1` AST-asserts
  against it. Details: `docs/ARCHITECTURE.md#step-isolation`.
- Console helpers: `Step` (cyan) / `Ok` (green) / `Warn` (yellow) / `Fail` (red) / `Dry` (dark grey)
  / **`Info` (white = informational)**. A bare `Write-Host` renders grey and reads as `[DRY]` — use
  `Info`, which adds **no indent** (call sites carry their own). **Yellow means "a human needs to
  look at this"**: `Warn` plus exactly four advisories — the DRY RUN banner, "Recommended: reboot
  once", the autologon-password caveat, and the account-precheck remediation body. Post-install
  "next steps", path banners and prompt headers are `Info`.
- **Every silent probe `catch` carries a `Write-Verbose`.** The script is `[CmdletBinding()]`, so
  `-Verbose` surfaces them and the transcript captures them; `$VerbosePreference` defaults to
  `SilentlyContinue`, so a normal run is byte-identical. The swallow is still the contract — these
  probes are *supposed* to fail — `Write-Verbose` just stops the reason from being unrecoverable.
  Never promote one to `Warn`, or a healthy install grows ~30 lines of noise. The generated finish
  script has no console, so its catches use its own `L()` file logger.
- `$ErrorActionPreference = 'Continue'`; per-function try/catch with a `Warn` fallback. Every result
  is recorded to the manifest so partial failures **don't** exit 0. `Invoke-Step` and the top-level
  catch both print `$_.InvocationInfo.ScriptLineNumber`.
- Naming: `Verb-Noun` PascalCase functions, PascalCase globals (`$LogDir`, `$Installers`), camelCase
  manifest keys (`filesPlaced`, `exitCode`, `scannerConfigured`).
- Anything that **records** a command line redacts `LICENSECODE=` (`$safeArgs`); `$ArgList` reaches
  the installer untouched. The manifest is world-readable and survives `-Uninstall`.
- TLS 1.2 is forced before any network call.
- Guard state changes behind `-DryRun`, **flags included** — a mode that writes nothing must not
  raise `$FinishFailed` and produce a phantom exit 1.
- Runtime payloads, logs and `alleaves_b64.txt` are git-ignored.
