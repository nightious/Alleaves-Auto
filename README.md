# Alleaves-Auto

Single-file, double-clickable bootstrap for deploying an **Alleaves POS** terminal
onto a stock Windows 10/11 machine. No Python, no `gdown`, no shipped install folder —
everything downloads and installs from one `.bat`.

## Prerequisites

- **Stock Windows 10 or 11** — no prior preparation needed.
- **A signed-in local administrator account** — *not* a Microsoft account, and not a domain /
  Entra ID account. The installer checks this before it downloads anything and refuses to run
  otherwise (exit `8`), printing the steps to create one. Elevating the run with a *different*
  admin's credentials at the UAC prompt does not satisfy it: the account the terminal is signed
  into is the one that has to be a local administrator, because that's the profile that will run
  the POS. There is no override switch. The `.bat` self-elevates via UAC on double-click, so on a
  standard-user terminal the UAC prompt still appears first and this message second.
- **An active internet connection** reaching Google Drive and the vendor CDNs — every product is
  downloaded at runtime, so there is no offline/bundled installer.

## What it installs

In order:

1. Google Chrome
2. Alleaves Terminal
3. Zebra 123 Scan
4. Zebra Scanner SDK
5. Microsoft POS for .NET
6. NiceLabel

Before the Zebra installers it also bootstraps the **Microsoft Visual C++ 2015–2022 x64
Redistributable** (a prerequisite for the Zebra CoreScanner driver), but only when it is missing.
As a shared Microsoft runtime it is intentionally left in place on `-Uninstall`.

Plus the NiceLabel master-list (`.nlbl`) copy and a Splashtop SOS download. Any existing
**TeamViewer** install is removed by default (Splashtop SOS is the remote-access tool for these
terminals) — pass `-SkipUninstallTeamViewer` to keep it.

As the **final step**, any connected Zebra scanner is automatically switched to **USB-OPOS**
so the Alleaves POS can read it — no more opening 123Scan to "Load to scanner" by hand. This
uses the already-installed Zebra CoreScanner driver and is model-agnostic (DS2208, DS4608,
DS8108, LI2208, MP7000, …). From the factory **USB HID-Keyboard** default it walks the scanner
through the required **HID-Keyboard → IBM Hand-held → USB-OPOS** sequence; the change is permanent
(survives power cycles). **If no scanner is plugged in during the run, that's fine** — the install
still succeeds; just re-run `Install-Alleaves.bat` later with the scanner attached, or use the
barcode fallback below (`scanner/Scanner_OPOS_barcode.pdf`).

## Per-terminal finishing

Every install also applies a few per-terminal changes so the terminal is floor-ready:

- **Computer rename** — on an interactive (double-clicked) run the installer pauses **early** to
  prompt for the terminal's computer name (POS name/number); press **Enter** to skip. Preset it
  non-interactively with `-ComputerName "POS-1"`, or disable the step with `-SkipRename`. The new
  name takes effect on the next reboot. On an unattended/RMM run there is no prompt, so the terminal
  is named **only** if you pass `-ComputerName`.
- **Taskbar pins / Edge removal** — pins two shortcuts, in this order, and removes Microsoft Edge:
  **Alleaves Terminal** (the launcher app) and **Alleaves POS** (Chrome opened straight on
  `https://app.alleaves.com`). Neither ships a shortcut, so the installer creates both all-users
  Start Menu shortcuts itself (removed on `-Uninstall`). The **Alleaves POS** pin takes the place
  of a plain Google Chrome pin — see the note below. Skip with `-SkipChromeTaskbar`.
- **Default browser** — sets Chrome as the default browser. Skip with `-SkipDefaultBrowser`.
- **Alleaves bookmark** — Chrome gets a read-only **Alleaves** folder on the bookmarks bar
  containing the POS. Applied machine-wide (every user, every profile) through Chrome's
  enterprise policy registry, so Chrome will report that it is "managed by your organization" —
  that is expected, and the cashier can't delete the bookmark. Skip with `-SkipChromeBookmark`.

> **Why the start page is a shortcut, not a setting.** Chrome refuses to honour the
> `RestoreOnStartup` / `HomepageLocation` policies on a machine that isn't Active-Directory or
> Entra-joined, or enrolled in Chrome Browser Cloud Management — `chrome://policy` reports
> *"This policy is blocked, its value will be ignored."* (Measured on the rig 2026-08-12; the
> `Recommended` flavour and an `initial_preferences` merge were both tested and fail the same
> way.) So the terminal instead gets a taskbar shortcut that launches Chrome with the URL on its
> command line, which works on any machine. Bookmark policies are *not* in Chrome's blocked set,
> so the bookmark is a real policy.

The taskbar pins and default-browser change are applied automatically at the next logon (via the
`AlleavesAuto-FinishUser` task), so they take effect after the reboot below. The bookmark needs no
logon task — it applies the next time Chrome starts (check `chrome://policy`).

## After install — reboot

The installer never auto-reboots (it uses `/norestart` throughout). **Reboot the terminal once** to
finalize the Zebra CoreScanner driver and apply the computer rename, then **sign back in** so the
`AlleavesAuto-FinishUser` logon task applies the taskbar pins and default-browser change. When
a pending reboot is detected (e.g. the VC++ redistributable requested one), the run prints an
emphatic `*** REBOOT REQUIRED ***` at the end.

Working root is `%ProgramData%\AlleavesAuto` — a `downloads\` folder and a `logs\` folder (the
latter holds the per-run transcript **and** the install manifest) — so state survives a later
`-Uninstall`.

## Files

| File | Purpose |
| --- | --- |
| `alleaves_setup.ps1` | The actual installer — native-PowerShell Google Drive download, silent install, manifest-driven uninstall. |
| `build-bat.ps1` | Base64-packs `alleaves_setup.ps1` into the single deliverable `Install-Alleaves.bat` (self-verifies SHA256 byte-identity). |
| `Install-Alleaves.bat` | **The deliverable.** Generated — do not hand-edit. Elevates once, decodes the embedded script, runs it. |
| `scanner/Scanner_OPOS_barcode.pdf` | One-page printable **USB-OPOS programming barcode** — the DS2208 PRG "OPOS (IBM Hand-Held with Full Disable)" host-type barcode. Scan it once to set OPOS with zero PC software when no scanner was attached during the run; a single scan from the factory HID-Keyboard default, and the same barcode works across Zebra USB families. |
| `docs/SCANNER_OPOS_RIG_VALIDATION_PROMPT.md` | Hardware-validation follow-on for the scanner USB-OPOS step (the design lives in the `Set-ScannerOpos` header comment in `alleaves_setup.ps1`). |
| `printer/Collect-PrinterFingerprint.ps1` | Standalone field tool for the POS-X receipt printer. Dumps the OPOS device entry (including the `DrawerOpen` setting), the ProgID→CLSID→DLL chain, and the attached printer's USB VID/PID/device path, then runs a live OPOS probe (**prints a test receipt** — watch whether the drawer kicks); `-SnapshotOnly` reads state without touching the hardware. Not part of the install flow. |
| `docs/PRINTER_OPOS_FIELD_RESULTS.md` | Design + evidence for the printer OPOS step (how the package installs silently, every captured registry value, the measured answer behind each decision) plus the running table of real-terminal confirmations, fed by `Collect-PrinterFingerprint.ps1`. |

## Usage

Double-click `Install-Alleaves.bat` to install. It elevates once (UAC), then — on an interactive
run — prompts for the computer name before proceeding; otherwise it runs unattended.

| Argument | Effect |
| --- | --- |
| _(none)_ | Install (products + per-terminal finishing). |
| `-ComputerName "POS-1"` | Preset the terminal's computer (POS) name and skip the interactive rename prompt. On an unattended/RMM run this is the **only** way to name the terminal. |
| `-DryRun` | Simulate everything; make no system changes (no admin required). |
| `-Uninstall` | Reverse a prior install using the persisted manifest — including the Chrome bookmark policy and both taskbar pins (**sign out and back in** to see the change). A user's *original* pins are only restored if that user was signed in when the installer ran — the backup is taken from loaded profiles, so on the usual deployment (tech signed in as admin, cashier signed out) the cashier's taskbar comes back empty rather than as it was. Does **not** revert the computer rename or the scanner's USB-OPOS mode, and leaves shared runtimes (the VC++ redistributable) in place. To revert the scanner, scan the "USB HID Keyboard" / "Set Defaults" barcode or re-run 123Scan. Mutually exclusive with `-ScannerConfigOnly`. |
| `-ForceReinstall` | Re-download even if a valid cached file exists, and pre-clean/reinstall products already present (a normal re-run skips anything already installed). |
| `-SkipMasterList` | Don't copy the NiceLabel master list (`.nlbl`) into each user's Documents folder. |
| `-SkipUninstallTeamViewer` | Keep any existing TeamViewer install (removed by default). |
| `-SkipRename` | Don't prompt for / apply the computer rename. |
| `-SkipChromeTaskbar` | Don't pin Alleaves Terminal / Alleaves POS, or remove Edge, from the taskbar. |
| `-SkipDefaultBrowser` | Don't make Chrome the default browser. |
| `-SkipChromeBookmark` | Don't add the Alleaves bookmark to Chrome (leave Chrome unmanaged). |
| `-SkipScannerConfig` | Don't flip the connected Zebra scanner(s) to USB-OPOS (leave the scanner's host mode untouched). |
| `-SkipPrograms <regex...>` | Skip specific products in **both** the download and install phases — any product whose name matches one of the given regex fragments is dropped (e.g. `-SkipPrograms Zebra` skips both Zebra products). Quote a fragment that contains cmd metacharacters, e.g. `-SkipPrograms "Chrome\|NiceLabel"`. |
| `-ScannerConfigOnly` | Run **only** the USB-OPOS scanner step — skip all downloads, installs, and finishing. Use it to configure a scanner that wasn't attached during the main install (just plug it in and run this), or to re-apply OPOS. Because the whole point is that a scanner is attached *now*, a run that switches nothing (none connected, or the Zebra SDK is missing) exits **6**, not 0. Mutually exclusive with `-Uninstall` and `-SkipScannerConfig`. Pair it with `-ForceFingerprint` for a rig capture. |
| `-ForceFingerprint` | Write the per-hop scanner fingerprint log even for a model the installer already knows (normally only an unknown model dumps one). Rig/diagnostic capture — the report lands in `%ProgramData%\AlleavesAuto\logs\` as `scanner_new_model_<model>_<timestamp>.txt`. There is no read-only mode: the run still attempts the OPOS switch. |
| `-SkipPrinterConfig` | Don't register the OPOS receipt-printer device entry. |
| `-PrinterBrand <name>` | `POS-X` or `None`. Skips the interactive brand prompt (asked once, up front beside the computer-name prompt). `None` = this terminal has no receipt printer: the `OLE POS Setup` driver is neither downloaded nor installed **and** the OPOS registration is skipped (this holds with `-SkipPrinterConfig` too). Single word — no spaces. At the interactive prompt you can answer with the number or the word (`2` or `None`); anything unrecognized warns and falls back to POS-X. |
| `-PrinterConfigOnly` | Run **only** the OPOS receipt-printer registration — skip all downloads, installs, and finishing. Use it to re-apply the entry, or to fix it after the terminal was renamed (entries left under the old name are removed). The POS-X driver must already be installed — if it isn't, the step warns and does nothing rather than registering a device that points at a missing DLL. Mutually exclusive with `-Uninstall`, `-ScannerConfigOnly` and `-SkipPrinterConfig`. |

### Exit codes

`0` success · `1` install/uninstall failure · `2` mode ambiguity · `3` not elevated ·
`4` scanner degraded (CoreScanner missing — re-run) · `5` working-dir creation failed ·
`6` the USB-OPOS switch failed (re-run with the scanner attached) — during a full install this
means a scanner was connected and could not be switched; under `-ScannerConfigOnly` it also covers
a run that switched nothing at all ·
`7` OPOS receipt-printer registration failed (re-run, or use `-PrinterConfigOnly`) ·
`8` account precheck failed — the terminal is not signed into a local administrator account
(Microsoft account, domain/Entra account, standard user, or no interactive user). Nothing is
downloaded or written; the console output names the fix. Skipped for `-Uninstall`; `-DryRun`
reports the verdict and continues.
Codes `4`, `6` and `7` are non-fatal "re-run" signals and never mask a hard failure (`1`).

### Receipt printer (OPOS)

The POS-X driver (`OLE POS Setup 2.84`) installs silently, then the installer registers one
OPOS device entry named after the terminal:

| Device | Logical name | Service object |
| --- | --- | --- |
| Receipt printer | `<POSname>_Printer` | `RecPrinter.POSPrinter.SOU` |

`<POSname>` is the computer name entered at the start of the run. **Alleaves must be configured
to open this exact logical name.** The print path is OPOS end-to-end — no Windows print driver,
print queue or spooler involvement — so nothing shows up under Printers & Scanners, and that is
expected. The entry is pure registry: fully tracked in the manifest and removed by `-Uninstall`.

**The cash drawer has no device entry of its own.** It hangs off the printer's RJ-11 and is
kicked by the printer: the installer sets the printer's *Open CashDrawer* option to
**Follow Printer** (the `DrawerOpen` value inside the printer's key), so the drawer opens on
receipt print with nothing else to configure. A terminal set up before 2026-08-12 has a
leftover `<POSname>_Drawer` device; re-running (or `-PrinterConfigOnly`) removes it.

To capture diagnostics from a terminal with a printer attached, run
`printer\Collect-PrinterFingerprint.ps1` (add `-SnapshotOnly` to read state without printing a
test receipt). It writes one report to the Desktop; send that file back.

### Scanner USB-OPOS — barcode fallback

The installer sets OPOS automatically (software path). For a terminal that has no scanner attached
during the run, or a no-PC situation, scan the single **USB-OPOS** programming barcode in
`scanner/Scanner_OPOS_barcode.pdf` — same end result, no software required. It sets OPOS in one scan
straight from the factory HID-Keyboard default (the HID-KB → IBM Hand-held → OPOS two-hop is only
needed by the software/CoreScanner path, not by scanning the barcode).

## Troubleshooting / logs

If a run fails, look under `%ProgramData%\AlleavesAuto\logs\` (both paths are also echoed at the end
of every run):

- `install_YYYYMMDD_HHMMSS.log` (or `uninstall_…` / `scannercfg_…` / `printercfg_…` for those
  modes) — the full per-run transcript.
- `install_manifest.json` — the JSON record of everything installed, placed, and changed;
  `-Uninstall` replays it in reverse.
- `scanner_new_model_<model>_<timestamp>.txt` — the per-hop scanner fingerprint, written
  automatically when an unrecognized scanner model turns up (or on demand with
  `-ForceFingerprint`). Send that file back.

## Rebuilding the deliverable

Edit `alleaves_setup.ps1`, then regenerate the `.bat`:

```powershell
.\build-bat.ps1
```

Never edit `Install-Alleaves.bat` by hand — it is a generated, SHA256-verified
base64 pack of the `.ps1`.
