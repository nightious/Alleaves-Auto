# Alleaves-Auto

Single-file, double-clickable bootstrap for an **Alleaves POS** terminal on stock Windows 10/11.
Everything downloads and installs from one `.bat`.

The `.bat` pulls the current installer from the latest release every time it runs, so a copy kept on a
terminal, a USB stick or a tech's desktop never goes stale — **keep it and re-use it, you do not need to
re-download it.**

## Quick start

**Before you start**

1. Stock Windows 10/11 with internet access (GitHub, Google Drive + vendor CDNs — nothing is bundled;
   the `.bat` needs the network to *start*, not just to install).
2. **Sign in as a plain local administrator.** Not a Microsoft, domain or Entra account — typing a
   *different* admin's password at UAC does not count; the signed-in profile is the one that runs
   the POS. Otherwise the install stops with exit `8`.
3. Know the terminal's name (e.g. `POS-1`) and its receipt-printer brand.

**Run it**

1. Download **[Install-Alleaves.bat](https://github.com/nightious/Alleaves-Auto/releases/latest/download/Install-Alleaves.bat)**
   ([older builds](https://github.com/nightious/Alleaves-Auto/releases)) onto the terminal.
2. Double-click it and accept the UAC prompt. It elevates once, downloads the current installer, runs.
3. Answer the two prompts: **computer name** (Enter skips) and **printer brand**.
4. Wait. Everything else is silent; nothing reboots on its own.
5. **Reboot, then sign back in** — the taskbar pins and default browser are applied by a logon
   task on that first sign-in. A pending reboot prints `*** REBOOT REQUIRED ***`.
6. Check the last line: exit `0` is done. Anything else → [Exit codes](#exit-codes).

Re-running is safe: installed products are skipped.

**No scanner plugged in?** That's fine, the install still succeeds. Plug it in and re-run with
`-ScannerConfigOnly`, or scan the barcode in `scanner/Scanner_OPOS_barcode.pdf`.

## Arguments

Optional — a bare double-click needs none. From a terminal:
`Install-Alleaves.bat -ComputerName "POS-1" -PrinterBrand POS-X`

| Argument | Effect |
| --- | --- |
| `-ComputerName "POS-1"` | Preset the POS name; the only way to name an unattended run. Applies on next reboot. |
| `-PrinterBrand <name>` | `POS-X`, `StarTSP100` or `None` — skips the brand prompt. Only the chosen brand is downloaded. `None` = no driver, no OPOS entry. |
| `-DryRun` | Simulate; change nothing but the working root and this run's log. The only mode that runs without admin (working root moves to `%TEMP%\AlleavesAuto`; the manifest it previews against is still the real one). |
| `-Uninstall` | Reverse a prior install from the manifest — products, bookmark policy, both pins (sign out/in to see it). Does **not** revert the rename, the scanner's OPOS mode, shared runtimes, or anything the installer found already installed. |
| `-ForceReinstall` | Re-download and reinstall even if cached / already present. |
| `-SkipPrograms <regex...>` | Drop matching products from **both** download and install (`-SkipPrograms Zebra`). Quote cmd metacharacters: `"Chrome\|NiceLabel"`. Invalid regex exits `2`. |
| `-SkipMasterList` | Don't copy the NiceLabel `.nlbl` master list into each user's Documents. |
| `-SkipUninstallTeamViewer` | Keep an existing TeamViewer (removed by default). |
| `-SkipRename` | No rename prompt or apply. |
| `-SkipChromeTaskbar` | Don't pin Alleaves Terminal / Alleaves POS, don't remove Edge. |
| `-SkipDefaultBrowser` | Don't make Chrome the default browser. |
| `-SkipChromeBookmark` | Don't apply the read-only Alleaves bookmark. |
| `-SkipScannerConfig` | Leave the Zebra scanner's host mode alone. |
| `-SkipPrinterConfig` | Install the driver but don't register the OPOS entry. Also suppresses the brand prompt (unset brand then defaults to `POS-X`). |
| `-ScannerConfigOnly` | Run **only** the USB-OPOS scanner switch. Switching nothing exits `6`, not `0`. |
| `-PrinterConfigOnly` | Run **only** the OPOS printer registration — use after a rename. The driver must already be installed. |
| `-ForceFingerprint` | Also write the per-hop scanner fingerprint for an already-known model (lands in `logs\`). Still attempts the switch. |
| `-NiceLabelLicense <id>` | NiceLabel activation ID (a working default is baked in). |
| `-SkipNiceLabelActivation` | Install NiceLabel unlicensed, for manual key entry. |
| `-IgnoreAccountCheck` | Report the account-precheck verdict but don't block — the unattended override for exit `8`. Recorded in the manifest. |

**Combinations rejected with exit `2`:** `-ScannerConfigOnly` with `-Uninstall` or
`-SkipScannerConfig` · `-PrinterConfigOnly` with `-Uninstall`, `-ScannerConfigOnly`,
`-SkipPrinterConfig` or `-PrinterBrand None` · `-ComputerName` with `-SkipRename` ·
`-NiceLabelLicense` with `-SkipNiceLabelActivation`. Every option needs its leading dash — a bare word
(`Install-Alleaves.bat uninstall`) is rejected too, rather than binding to `-SkipPrograms`.

## Exit codes

| | |
| --- | --- |
| `0` | Success. |
| `1` | Install / uninstall / download / finishing / step failure. |
| `2` | Bad argument or a rejected combination (above). |
| `3` | Not elevated — or, from the launcher, it couldn't read its own integrity level and refused to relaunch (don't start the `.bat` from a bash/MSYS shell). |
| `4` | Scanner degraded — CoreScanner service missing after install; re-run. |
| `5` | Working directory could not be created or written. |
| `6` | USB-OPOS scanner switch failed; re-run with the scanner attached. |
| `7` | OPOS printer registration failed — including `StarTSP100`, whose values aren't captured yet, and an entry under a previous computer name that couldn't be retired. |
| `8` | Account precheck failed and wasn't overridden. Nothing was downloaded or written. |
| `9` | Account swap armed, rebooting to resume — **do not dispatch a tech**. |
| `10` | The `.bat` couldn't download the installer; nothing ran. Check the terminal's internet connection and re-run. Outside `0`–`9` on purpose so an RMM doesn't read it as `9`. |

`4`, `6` and `7` are non-fatal "re-run" signals and never mask `1`. A `-DryRun` never returns
`6` or `7`.

**Exit `8` / `9`:** the signed-in account must be a plain local admin (a Microsoft account is
refused because OneDrive can redirect `Documents`, which is where the master list goes). An
interactive run offers to promote the account or create a local admin and reboot into it — that
exits `9` and resumes itself. Unattended, pass `-IgnoreAccountCheck`. Details:
[`docs/ACCOUNT-SWAP.md`](docs/ACCOUNT-SWAP.md).

## What it installs

In order: Chrome → Alleaves Terminal → Zebra 123 Scan → Zebra Scanner SDK → POS for .NET →
NiceLabel → the chosen printer driver (POS-X `OLE POS Setup`, or Star TSP100 futurePRNT — a
471 MB CD image, so expect ~600 MB left in `downloads\`). The VC++ 2015–2022 x64 redistributable
is bootstrapped first if missing and left in place on `-Uninstall`.

Also: the NiceLabel master list copied into every user's Documents, `SplashtopSOS.exe`
downloaded but **never installed**, and any existing TeamViewer removed.

Then, per terminal: rename · taskbar pins for Alleaves Terminal and Alleaves POS + Edge removed ·
Chrome as default browser · a machine-wide Alleaves bookmark policy (so Chrome says "managed by
your organization" — expected) · any connected Zebra scanner switched to **USB-OPOS** · the
printer registered as OPOS device `<POSname>_Printer` (nothing appears under Printers & Scanners;
a later rename means re-running `-PrinterConfigOnly`). See
[`docs/FINISHING.md`](docs/FINISHING.md), [`docs/SCANNER-OPOS.md`](docs/SCANNER-OPOS.md),
[`docs/PRINTER-OPOS.md`](docs/PRINTER-OPOS.md).

> **Star TSP100 is unfinished.** The driver installs and uninstalls cleanly, but its OPOS values
> are still un-captured, so the run exits `7` instead of registering an empty device. POS-X is
> unaffected.

## Logs

Under `%ProgramData%\AlleavesAuto\logs\` (echoed at the end of every run; the working root
survives `-Uninstall`):

- `install_YYYYMMDD_HHMMSS.log` — per-run transcript (also `uninstall_…`, `scannercfg_…`,
  `printercfg_…`).
- `install_manifest.json` — everything installed, placed and changed; `-Uninstall` replays it.
- `scanner_new_model_<model>_<ts>.txt` — scanner fingerprint for an unrecognized model. Send it back.

## Files

| File | Purpose |
| --- | --- |
| `alleaves_setup.ps1` | The installer — source of truth, and the release asset every terminal runs. |
| `Install-Alleaves.bat` | **The deliverable.** ~90 lines: elevate, download the current `.ps1`, run it. Carries no payload and never changes. |
| `release.ps1` | Test + tag + publish both assets. Publishing is a deployment. |
| `docs/` | How it works and why — start at `docs/ARCHITECTURE.md`. |
| `tests/` | Self-checks, no framework; each `Test-*.ps1` exits 0 on pass, 1 on failure (`_common.ps1` is shared helpers, not a test). |
| `scanner/Scanner_OPOS_barcode.pdf` | One-scan USB-OPOS programming barcode; no PC needed. |
| `printer/Collect-PrinterFingerprint.ps1` | Field diagnostic: OPOS entries, ProgID→CLSID→DLL, USB IDs, test receipt (`-SnapshotOnly` reads only). |

## Developing

```powershell
PowerShell -File .\alleaves_setup.ps1 -DryRun   # dev run, no admin (docs/BUILD-BAT.md#dev)
.\tests\Test-*.ps1                              # all five must exit 0
.\release.ps1 -Version v1.3.0                   # test + tag + publish (needs gh auth)
```

Nothing to build: the `.bat` is a checked-in stub that fetches the **published** `.ps1`, so it never
runs local edits — test edits against the `.ps1` directly, and the `.bat` only after a release.
`release.ps1` refuses a dirty tree, because the `.ps1` it uploads is what every terminal in the field
executes on its next run. Rolling back is `gh release delete <tag>`,
which re-points `latest` at the previous release.

Reasoning lives in `docs/`: [ARCHITECTURE](docs/ARCHITECTURE.md) (flow, step isolation, exit
codes) · [INSTALL-ENGINE](docs/INSTALL-ENGINE.md) (download, MSI/`.iss`/wrapper families) ·
[MANIFEST](docs/MANIFEST.md) (keys, merge rules, `-Uninstall` replay) ·
[ACCOUNT-SWAP](docs/ACCOUNT-SWAP.md) · [FINISHING](docs/FINISHING.md) ·
[SCANNER-OPOS](docs/SCANNER-OPOS.md) · [PRINTER-OPOS](docs/PRINTER-OPOS.md) ·
[BUILD-BAT](docs/BUILD-BAT.md).
