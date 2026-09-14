# CLAUDE.md

Guidance for Claude Code in this repo. **All design rationale lives in `docs/`** — this file does
not repeat it. End-user usage and the option / exit-code tables are in `README.md`.

## What this is

AlleavesAuto is a single-file, self-bootstrapping POS installer for "Alleaves" on stock Windows
10/11 terminals: silent, idempotent (re-runs skip installed products), reversible (manifest-driven
uninstall). `alleaves_setup.ps1` is the **source of truth** *and* the shipped artifact;
`Install-Alleaves.bat` is a payload-free stub that downloads it from the latest release on every
run, and is the whole deliverable.

## Build & run

```powershell
PowerShell -File .\alleaves_setup.ps1 -DryRun       # dev run, no admin. There is nothing to build.
.\Install-Alleaves.bat                              # target terminal; elevates, fetches, runs
.\release.ps1 -Version v1.3.0                       # ship: test + tag + publish BOTH assets
```

- **The `.bat` runs the *published* `.ps1`, never your local edits.** Test against the `.ps1`
  directly; exercise the `.bat` only after a release. It is a checked-in ~90-line source file —
  edit it like any other, nothing generates it.
- **Publishing is a deployment.** Every `.bat` in the field runs the newly uploaded `.ps1` on its
  next double-click. There is no pin lever; roll back with `gh release delete`.
- The `.ps1` `param()` block is the authoritative option set — `README.md`'s table mirrors it.
- Working root `%ProgramData%\AlleavesAuto` (`downloads\`, `logs\`, `logs\install_manifest.json`)
  survives `-Uninstall` by design. `-DryRun` without admin falls back to `%TEMP%`.
- `scanner/` (barcode fallback PDF) and `printer/Collect-PrinterFingerprint.ps1` are doc-style
  deliverables the installer never touches — edit them in place, no release needed.

## Checks to run before calling a change done

```powershell
.\tests\Test-DocLinks.ps1                           # all six exit 0 on pass, 1 on failure
.\tests\Test-AccountPrecheck.ps1
.\tests\Test-ManifestMerge.ps1
.\tests\Test-StepIsolation.ps1
.\tests\Test-InstallerExitCode.ps1
.\tests\Test-LogShipping.ps1
PowerShell -File .\alleaves_setup.ps1 -DryRun
```

Install/uninstall behaviour changes need a **full round trip with a reboot between cycles**, not a
partial test.

## Conventions

One line each; the reasoning is in [`docs/CONVENTIONS.md`](docs/CONVENTIONS.md). Read it before a
first edit — every rule here has a failure behind it.

- **Comments are pointers, not essays.** New rationale goes in `docs/`; the code gets
  `# docs/<SUBSYSTEM>.md#<anchor>`. Kept in code: `<# .SYNOPSIS #>` blocks and `ponytail:` markers.
- **Add the anchor and the pointer in the same change** — `tests\Test-DocLinks.ps1` enforces both
  directions. Cite stable symbol names, never `:NNNN` line numbers.
- **Every install step: bootstrap + track (manifest) + reverse (uninstall).** No exceptions.
- **Wrap every step in `Invoke-Step`** — `Invoke-Step 'Name' { Do-Thing }`. A bare call is a bug
  `tests\Test-StepIsolation.ps1` AST-asserts against.
- Console: `Step` cyan / `Ok` green / `Warn` yellow / `Fail` red / `Dry` dark grey / `Info` white.
  Never a bare `Write-Host`. **Yellow means "a human needs to look at this"** — `Warn` plus
  exactly four advisories, nothing else.
- **Every silent probe `catch` carries a `Write-Verbose`.** Never promote one to `Warn`.
- `$ErrorActionPreference = 'Continue'`; per-function try/catch with a `Warn` fallback; every
  result recorded to the manifest so partial failures don't exit 0.
- Naming: `Verb-Noun` PascalCase functions, PascalCase globals, camelCase manifest keys.
- Redact `LICENSECODE=` anywhere a command line is **recorded** (`$safeArgs`).
- TLS 1.2 before any network call.
- Guard state changes behind `-DryRun`, **flags included** — no phantom exit 1.

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
| The `.bat` stub: the fetch, elevation probe, arg relay, two-repo release split | `docs/BUILD-BAT.md` |
| Per-run Slack summary: the encoded webhook, payload budget, fail-soft rules | `docs/LOG-SHIPPING.md` |
| Coding conventions above, in full | `docs/CONVENTIONS.md` |
| Printer bench evidence | `docs/PRINTER_OPOS_FIELD_RESULTS.md` |
| Scanner rig validation log | `docs/SCANNER_OPOS_RIG_VALIDATION_PROMPT.md` |

Open hardware items are checklists at the top of `docs/SCANNER-OPOS.md` and
`docs/PRINTER-OPOS.md`.
