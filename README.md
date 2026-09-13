# Alleaves-Auto

Single-file, double-clickable bootstrap for an **Alleaves POS** terminal on stock
Windows 10/11. Everything downloads and installs from one `.bat`.

## Download

**[Install-Alleaves.bat](https://github.com/nightious/Alleaves-Auto/releases/latest/download/Install-Alleaves.bat)**
— always the latest release. Save it to the terminal and double-click it; nothing else is needed.

Older builds and per-release notes: [Releases](https://github.com/nightious/Alleaves-Auto/releases).

## Prerequisites

- Stock Windows 10/11, internet access to Google Drive and the vendor CDNs (nothing is bundled).
- **The terminal must be signed into a plain local administrator account** — not a Microsoft,
  domain or Entra account. Typing a *different* admin's credentials at UAC does not satisfy it:
  the signed-in profile is the one that will run the POS. Otherwise exit `8` — see
  [Account precheck](#account-precheck-and-automatic-fix).

## What it installs

In order: Chrome → Alleaves Terminal → Zebra 123 Scan → Zebra Scanner SDK → POS for .NET →
NiceLabel → the receipt-printer driver for the brand you pick (POS-X `OLE POS Setup`, or Star
TSP100 futurePRNT). **Only the chosen brand is downloaded.** The VC++ 2015–2022 x64
redistributable is bootstrapped first if missing (a Zebra CoreScanner prerequisite; left in
place on `-Uninstall`).

Plus: the NiceLabel master list (`.nlbl`) copied into each user's Documents, a Splashtop SOS
download (staged, never installed), and removal of any existing **TeamViewer**
(`-SkipUninstallTeamViewer` keeps it).

**Final step:** any connected Zebra scanner is switched to **USB-OPOS** via the CoreScanner
driver — HID-Keyboard → IBM Hand-held → USB-OPOS, permanent across power cycles, model-agnostic.
No scanner attached is fine: the install still succeeds; re-run later with
`-ScannerConfigOnly`, or scan `scanner/Scanner_OPOS_barcode.pdf`.

## Per-terminal finishing

- **Computer rename** — interactive runs prompt early (Enter skips); unattended runs need
  `-ComputerName "POS-1"`. Takes effect on the next reboot.
- **Taskbar pins / Edge removal** — pins **Alleaves Terminal** and **Alleaves POS** (Chrome on
  `https://app.alleaves.com`), replacing a plain Chrome pin, and removes Edge. The installer
  creates both Start Menu shortcuts itself.
- **Default browser** — Chrome.
- **Alleaves bookmark** — a read-only bookmarks-bar folder applied machine-wide through Chrome's
  enterprise policy, so Chrome reports "managed by your organization" (expected; the cashier
  can't delete it).

> The start page is a taskbar shortcut, not a policy: Chrome blocks `RestoreOnStartup` /
> `HomepageLocation` on a machine that isn't AD/Entra-joined or CBCM-enrolled. Bookmark policies
> aren't blocked, so the bookmark is a real policy.

Pins and the default browser apply at the next logon via the `AlleavesAuto-FinishUser` task;
the bookmark applies the next time Chrome starts.

## After install — reboot

Nothing auto-reboots (`/norestart` throughout). **Reboot once**, then **sign back in** so the
logon task runs. A pending reboot prints `*** REBOOT REQUIRED ***` at the end.

Working root `%ProgramData%\AlleavesAuto` (`downloads\`, `logs\`) survives `-Uninstall`.

## Files

| File | Purpose |
| --- | --- |
| `alleaves_setup.ps1` | The installer — download, silent install, manifest-driven uninstall. |
| `build-bat.ps1` | Base64-packs the `.ps1` into `Install-Alleaves.bat` (SHA256 self-verified). |
| `Install-Alleaves.bat` | **The deliverable.** Generated — never hand-edit. |
| `docs/` | How it works and why — one file per subsystem; start at `docs/ARCHITECTURE.md`. |
| `tests/` | Runnable self-checks (no framework; each exits 0 on pass, 1 on failure). |
| `scanner/Scanner_OPOS_barcode.pdf` | One-scan USB-OPOS programming barcode; no PC software needed. |
| `docs/SCANNER_OPOS_RIG_VALIDATION_PROMPT.md` | Scanner hardware-validation notes and results table. |
| `printer/Collect-PrinterFingerprint.ps1` | Field diagnostic: dumps OPOS entries, ProgID→CLSID→DLL chain, USB IDs, then prints a test receipt (`-SnapshotOnly` reads only). Also the Star capture tool. |
| `docs/PRINTER_OPOS_FIELD_RESULTS.md` | Printer OPOS captured registry values and field results. |

## Usage

Double-click `Install-Alleaves.bat`. It elevates once (UAC), then prompts for the computer name
and printer brand on an interactive run; otherwise it runs unattended.

| Argument | Effect |
| --- | --- |
| _(none)_ | Install (products + finishing). |
| `-ComputerName "POS-1"` | Preset the POS name; the only way to name an unattended run. |
| `-DryRun` | Simulate; change nothing (no admin needed). |
| `-Uninstall` | Reverse a prior install from the manifest, including the bookmark policy and both pins (sign out/in to see it). A user's original pins only come back if that user was signed in during the install. Does **not** revert the rename, the scanner's OPOS mode, or shared runtimes. Excludes `-ScannerConfigOnly` / `-PrinterConfigOnly`. |
| `-ForceReinstall` | Re-download and reinstall even if cached / already present. |
| `-SkipPrograms <regex...>` | Drop matching products from **both** phases (e.g. `-SkipPrograms Zebra`). Quote cmd metacharacters: `"Chrome\|NiceLabel"`. An invalid regex exits `2`. |
| `-SkipMasterList` | Don't copy the `.nlbl`. |
| `-SkipUninstallTeamViewer` | Keep TeamViewer. |
| `-SkipRename` / `-SkipChromeTaskbar` / `-SkipDefaultBrowser` / `-SkipChromeBookmark` | Skip that finishing step. |
| `-PrinterBrand <name>` | `POS-X`, `StarTSP100` or `None` — skips the brand prompt. `None` = no printer driver and no OPOS registration. |
| `-SkipPrinterConfig` | Install the driver but don't register the OPOS entry. |
| `-SkipScannerConfig` | Leave the scanner's host mode alone. |
| `-ScannerConfigOnly` | Run **only** the USB-OPOS scanner step. A run that switches nothing exits `6`, not `0`. Excludes `-Uninstall` / `-SkipScannerConfig`. |
| `-PrinterConfigOnly` | Run **only** the OPOS printer registration — use after a rename (entries under the old name are retired). The driver must already be installed. Excludes `-Uninstall`, `-ScannerConfigOnly`, `-SkipPrinterConfig`, `-PrinterBrand None`. |
| `-ForceFingerprint` | Write the per-hop scanner fingerprint even for a known model (lands in `logs\`). Still attempts the switch. |
| `-NiceLabelLicense <id>` | Activation ID for NiceLabel (a working default is baked in). |
| `-SkipNiceLabelActivation` | Install NiceLabel unlicensed, for manual key entry. |
| `-IgnoreAccountCheck` | Report the precheck verdict but don't block on it (the unattended half of the override). Recorded in the manifest. |

### Exit codes

`0` ok · `1` install / uninstall / download / finishing / step failure · `2` mode ambiguity or a bad
argument · `3` not elevated · `4` scanner degraded, CoreScanner missing (re-run) · `5`
working-dir failed · `6` USB-OPOS switch failed (re-run with the scanner attached) · `7` OPOS
printer registration failed — also when the brand's values aren't captured yet (`StarTSP100`)
or an entry under a previous computer name couldn't be retired · `8` account precheck failed
and was not overridden (nothing downloaded or written; `-Uninstall` skips the check, `-DryRun`
reports and continues) · `9` account swap armed, rebooting to resume — do not dispatch a tech.

`4`, `6` and `7` are non-fatal "re-run" signals and never mask `1`.

`10` comes from the **launcher**, not the script: `Install-Alleaves.bat` could not decode its
embedded payload, so nothing ran. It sits outside the `0`–`9` set above on purpose — it used to
be `9`, which an RMM reads as "the box is rebooting to finish itself" and skips.

### Account precheck and automatic fix

The install refuses to run unless the **signed-in** account is a plain local admin. An
undetermined account type blocks too. A Microsoft account is refused because OneDrive can
redirect `Documents` — exactly where the master list goes.

On a block, an **interactive** run offers a fix:

| Situation | Offer |
| --- | --- |
| Local account, not an admin | Promote in place, then reboot. No password handled. |
| Microsoft / domain / Entra / undetermined | Create a local admin (prompts for name + password), arm a one-shot auto sign-in, reboot into it. |
| SYSTEM / service identity (no console) | **No offer** — relaunch from a signed-in console session. |

Either way a logon task re-runs the installer with the same arguments so the install resumes
itself; it exits `9` once armed. Never offered twice in one cycle. `-DryRun` reports the offer
it would make and arms nothing.

**Overriding the block.** Interactive: decline the offer and answer `y` to
`Continue the install anyway on this account (NOT recommended)? [y/N]`. Unattended: pass
`-IgnoreAccountCheck`. Both prompts default to **No** and a headless host reads as No, so an
unattended run with no switch still exits `8`. Every override is written to the manifest as
`accountCheckOverride` — the only durable record, since the precheck runs before the transcript
starts. The reasons don't go away when you override: override when you know the box.

> **One-shot auto sign-in** (create path only): Winlogon's `AutoLogonCount`, so the password
> sits in the registry in plaintext until that single sign-in clears it — reboot promptly. The
> resumed run restores the previous autologon settings. The created account is **never removed
> by `-Uninstall`**: the terminal is signed into it and its Documents holds the master list.

### Receipt printer (OPOS)

| Brand | Driver | Device | Logical name | Service object |
| --- | --- | --- | --- | --- |
| `POS-X` | `OLE POS Setup 2.84` | Printer | `<POSname>_Printer` | `RecPrinter.POSPrinter.SOU` |
| `StarTSP100` | `TSP100 Setup Version 7.6.0` | Printer | `<POSname>_Printer` | *(pending capture)* |
| `StarTSP100` | ″ | Cash drawer | `<POSname>_Drawer` | *(pending capture)* |

`<POSname>` is the computer name from this run. **Alleaves must be configured to open these
exact names**, so a later rename means re-running with `-PrinterConfigOnly`. The path is OPOS
end-to-end — nothing appears under Printers & Scanners, which is expected. Pure registry: fully
tracked and removed by `-Uninstall`.

> **Star is not finished.** The driver installs, is detected and uninstalls cleanly, but Star
> ships no OPOS automation and its registry values must be captured on a bench (see
> `docs/PRINTER_OPOS_FIELD_RESULTS.md`). Until then `-PrinterBrand StarTSP100` installs the
> driver and exits **7** (`not-captured`) rather than registering an empty device. POS-X is
> unaffected.

**Cash drawer, by brand.** POS-X: no device of its own — it hangs off the printer's RJ-11 and
follows it via the printer key's `DrawerOpen=1`. (A terminal set up before 2026-08-12 has a
stale `<POSname>_Drawer`; re-running removes it.) Star: a genuine second OPOS device, hence the
second row.

The Star download is the vendor's 471 MB CD image, so expect ~600 MB left in `downloads\`.

### Scanner USB-OPOS — barcode fallback

No scanner during the run, or no PC at all: scan the single USB-OPOS barcode in
`scanner/Scanner_OPOS_barcode.pdf`. One scan from the factory HID-Keyboard default — the
two-hop sequence is only the software path's constraint.

## Troubleshooting / logs

Under `%ProgramData%\AlleavesAuto\logs\` (both paths are echoed at the end of every run):

- `install_YYYYMMDD_HHMMSS.log` (or `uninstall_…` / `scannercfg_…` / `printercfg_…`) — the
  per-run transcript.
- `install_manifest.json` — everything installed, placed and changed; `-Uninstall` replays it
  in reverse.
- `scanner_new_model_<model>_<timestamp>.txt` — per-hop scanner fingerprint, written for an
  unrecognized model or with `-ForceFingerprint`. Send that file back.

## Rebuilding the deliverable

Edit `alleaves_setup.ps1`, then `.\build-bat.ps1`. Never edit `Install-Alleaves.bat` by hand —
it is a generated, SHA256-verified base64 pack of the `.ps1`. A failed self-verify renames the
output to `.bat.corrupt`. Self-checks: `tests\Test-AccountPrecheck.ps1`,
`tests\Test-ManifestMerge.ps1` (exit 0/1, no framework).

To ship it: `.\release.ps1 -Version v1.2.0`. That rebuilds the `.bat`, runs every test, refuses
a dirty tree (a rebuild that changes the `.bat` means the committed one was stale), then tags and
publishes the `.bat` as a GitHub release asset. Needs `gh auth status` to be green.
