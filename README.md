# Alleaves-Auto

Single-file, double-clickable bootstrap for deploying an **Alleaves POS** terminal
onto a stock Windows 10/11 machine. No Python, no `gdown`, no shipped install folder —
everything downloads and installs from one `.bat`.

## Prerequisites

- **Stock Windows 10 or 11** — no prior preparation needed.
- **Local administrator rights** — the `.bat` self-elevates once via UAC on double-click.
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
- **Chrome taskbar pin / Edge removal** — pins Google Chrome to the taskbar and removes Microsoft
  Edge from it. Skip with `-SkipChromeTaskbar`.
- **Default browser** — sets Chrome as the default browser. Skip with `-SkipDefaultBrowser`.

The taskbar pin and default-browser change are applied automatically at the next logon (via the
`AlleavesAuto-FinishUser` task), so they take effect after the reboot below.

## After install — reboot

The installer never auto-reboots (it uses `/norestart` throughout). **Reboot the terminal once** to
finalize the Zebra CoreScanner driver and apply the computer rename, then **sign back in** so the
`AlleavesAuto-FinishUser` logon task applies the Chrome taskbar pin and default-browser change. When
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
| `scanner/Collect-ScannerFingerprint.ps1` | Standalone rig tool. **By default it walks the scanner** HID-KB → IBM Hand-held → USB-OPOS (the same two-hop the installer does) while capturing its host mode, USB PID, serial, and model to help finalize the rig-dependent `Set-ScannerOpos` constants; pass `-SnapshotOnly` to read the current state without changing anything. Not part of the install flow. |
| `docs/SCANNER_OPOS_RIG_VALIDATION_PROMPT.md` | Hardware-validation follow-on for the scanner USB-OPOS step (the design lives in the `Set-ScannerOpos` header comment in `alleaves_setup.ps1`). |
| `printer/Collect-PrinterFingerprint.ps1` | Standalone field tool for the POS-X receipt printer / cash drawer. Dumps the OPOS device entries, the ProgID→CLSID→DLL chain, and the attached printer's USB VID/PID/device path, then runs a live OPOS probe (**prints a test receipt and opens the drawer**); `-SnapshotOnly` reads state without touching the hardware. Not part of the install flow. |
| `docs/PRINTER_POSX_OPOS_HANDOFF.md` | Design + evidence for the printer/drawer OPOS step: how the package installs silently, every captured registry value, and the measured answers behind each decision. |
| `docs/PRINTER_OPOS_FIELD_RESULTS.md` | Running table of real-terminal confirmations, fed by `Collect-PrinterFingerprint.ps1`. |

## Usage

Double-click `Install-Alleaves.bat` to install. It elevates once (UAC), then — on an interactive
run — prompts for the computer name before proceeding; otherwise it runs unattended.

| Argument | Effect |
| --- | --- |
| _(none)_ | Install (products + per-terminal finishing). |
| `-ComputerName "POS-1"` | Preset the terminal's computer (POS) name and skip the interactive rename prompt. On an unattended/RMM run this is the **only** way to name the terminal. |
| `-DryRun` | Simulate everything; make no system changes (no admin required). |
| `-Uninstall` | Reverse a prior install using the persisted manifest. Does **not** revert the computer rename or the scanner's USB-OPOS mode, and leaves shared runtimes (the VC++ redistributable) in place. To revert the scanner, scan the "USB HID Keyboard" / "Set Defaults" barcode or re-run 123Scan. Mutually exclusive with `-ScannerConfigOnly`. |
| `-ForceReinstall` | Re-download even if a valid cached file exists, and pre-clean/reinstall products already present (a normal re-run skips anything already installed). |
| `-SkipMasterList` | Don't copy the NiceLabel master list (`.nlbl`) into the admin/cashier Documents folders. |
| `-SkipUninstallTeamViewer` | Keep any existing TeamViewer install (removed by default). |
| `-SkipRename` | Don't prompt for / apply the computer rename. |
| `-SkipChromeTaskbar` | Don't pin Chrome / remove Edge from the taskbar. |
| `-SkipDefaultBrowser` | Don't make Chrome the default browser. |
| `-SkipScannerConfig` | Don't flip the connected Zebra scanner(s) to USB-OPOS (leave the scanner's host mode untouched). |
| `-SkipPrograms <regex...>` | Skip specific products in **both** the download and install phases — any product whose name matches one of the given regex fragments is dropped (e.g. `-SkipPrograms Zebra` skips both Zebra products). Quote a fragment that contains cmd metacharacters, e.g. `-SkipPrograms "Chrome\|NiceLabel"`. |
| `-ScannerConfigOnly` | Run **only** the USB-OPOS scanner step — skip all downloads, installs, and finishing. Use it to configure a scanner that wasn't attached during the main install (just plug it in and run this), or to re-apply OPOS. Mutually exclusive with `-Uninstall`. |
| `-SkipPrinterConfig` | Don't register the OPOS receipt-printer / cash-drawer device entries. |
| `-PrinterBrand <name>` | `POS-X` (the only one implemented), `Star`, `Epson`, or `None`. Skips the interactive brand prompt (asked once, up front beside the computer-name prompt); Star/Epson select cleanly and warn "not yet implemented" — the POS-X driver still installs. `None` = this terminal has no receipt printer: the `OLE POS Setup` driver is neither downloaded nor installed **and** the OPOS registration is skipped. Single word — no spaces. |
| `-PrinterConfigOnly` | Run **only** the OPOS printer + cash-drawer registration — skip all downloads, installs, and finishing. Use it to re-apply the entries, or to fix them after the terminal was renamed (entries left under the old name are removed). The POS-X driver must already be installed — if it isn't, the step warns and does nothing rather than registering devices that point at a missing DLL. Mutually exclusive with `-Uninstall`, `-ScannerConfigOnly` and `-SkipPrinterConfig`. |

### Exit codes

`0` success · `1` install/uninstall failure · `2` mode ambiguity · `3` not elevated ·
`4` scanner degraded (CoreScanner missing — re-run) · `5` working-dir creation failed ·
`6` a scanner was connected but the USB-OPOS switch failed (re-run with the scanner attached) ·
`7` OPOS printer/cash-drawer registration failed (re-run, or use `-PrinterConfigOnly`).
Codes `4`, `6` and `7` are non-fatal "re-run" signals and never mask a hard failure (`1`).

### Receipt printer + cash drawer (OPOS)

The POS-X driver (`OLE POS Setup 2.84`) installs silently, then the installer registers two
OPOS device entries named after the terminal:

| Device | Logical name | Service object |
| --- | --- | --- |
| Receipt printer | `<POSname>_Printer` | `RecPrinter.POSPrinter.SOU` |
| Cash drawer | `<POSname>_Drawer` | `Standard.CashDrawer.SOU` |

`<POSname>` is the computer name entered at the start of the run. **Alleaves must be configured
to open these exact logical names.** The print path is OPOS end-to-end — no Windows print driver,
print queue or spooler involvement — so nothing shows up under Printers & Scanners, and that is
expected. Both entries are pure registry: fully tracked in the manifest and removed by
`-Uninstall`.

To capture diagnostics from a terminal with a printer attached, run
`printer\Collect-PrinterFingerprint.ps1` (add `-SnapshotOnly` to read state without printing a
test receipt or kicking the drawer). It writes one report to the Desktop; send that file back.

### Scanner USB-OPOS — barcode fallback

The installer sets OPOS automatically (software path). For a terminal that has no scanner attached
during the run, or a no-PC situation, scan the single **USB-OPOS** programming barcode in
`scanner/Scanner_OPOS_barcode.pdf` — same end result, no software required. It sets OPOS in one scan
straight from the factory HID-Keyboard default (the HID-KB → IBM Hand-held → OPOS two-hop is only
needed by the software/CoreScanner path, not by scanning the barcode).

## Troubleshooting / logs

If a run fails, look under `%ProgramData%\AlleavesAuto\logs\` (both paths are also echoed at the end
of every run):

- `install_YYYYMMDD_HHMMSS.log` (or `uninstall_…` / `scannercfg_…` for those modes) — the full
  per-run transcript.
- `install_manifest.json` — the JSON record of everything installed, placed, and changed;
  `-Uninstall` replays it in reverse.

## Rebuilding the deliverable

Edit `alleaves_setup.ps1`, then regenerate the `.bat`:

```powershell
.\build-bat.ps1
```

Never edit `Install-Alleaves.bat` by hand — it is a generated, SHA256-verified
base64 pack of the `.ps1`.
