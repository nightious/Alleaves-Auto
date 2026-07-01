# Alleaves-Auto

Single-file, double-clickable bootstrap for deploying an **Alleaves POS** terminal
onto a stock Windows 10/11 machine. No Python, no `gdown`, no shipped install folder —
everything downloads and installs from one `.bat`.

## What it installs

In order:

1. Google Chrome
2. Alleaves Terminal
3. Zebra 123 Scan
4. Zebra Scanner SDK
5. Microsoft POS for .NET
6. NiceLabel

Plus the NiceLabel master-list (`.nlbl`) copy and a Splashtop SOS download.

As the **final step**, any connected Zebra scanner is automatically switched to **USB-OPOS**
so the Alleaves POS can read it — no more opening 123Scan to "Load to scanner" by hand. This
uses the already-installed Zebra CoreScanner driver and is model-agnostic (DS2208, DS4608,
DS8108, LI2208, MP7000, …). From the factory **USB HID-Keyboard** default it walks the scanner
through the required **HID-Keyboard → IBM Hand-held → USB-OPOS** sequence; the change is permanent
(survives power cycles). **If no scanner is plugged in during the run, that's fine** — the install
still succeeds; just re-run `Install-Alleaves.bat` later with the scanner attached, or use the
barcode fallback below (`scanner/Scanner_OPOS_barcode.pdf`).

Working root is `%ProgramData%\AlleavesAuto` (`downloads\`, `logs\`, and the install
manifest) so state survives a later `-Uninstall`.

## Files

| File | Purpose |
| --- | --- |
| `alleaves_setup.ps1` | The actual installer — native-PowerShell Google Drive download, silent install, manifest-driven uninstall. |
| `build-bat.ps1` | Base64-packs `alleaves_setup.ps1` into the single deliverable `Install-Alleaves.bat` (self-verifies SHA256 byte-identity). |
| `Install-Alleaves.bat` | **The deliverable.** Generated — do not hand-edit. Elevates once, decodes the embedded script, runs it. |
| `scanner/Scanner_OPOS_barcode.pdf` | One-page printable **USB-OPOS programming barcode** — the DS2208 PRG "OPOS (IBM Hand-Held with Full Disable)" host-type barcode. Scan it once to set OPOS with zero PC software when no scanner was attached during the run; a single scan from the factory HID-Keyboard default, and the same barcode works across Zebra USB families. |
| `scanner/DS2208_OPOS.scncfg` | Reference only — a full per-model 123Scan config. **Not** used by the installer (OPOS is set via a CoreScanner command, not a config file). Kept for a possible future full-parameter path. |
| `scanner/Collect-ScannerFingerprint.ps1` | Standalone rig tool — dumps a connected Zebra scanner's host mode, USB PID, serial, and model to help finalize the rig-dependent `Set-ScannerOpos` constants. Not part of the install flow. |
| `docs/SCANNER_OPOS_PLAN.md`, `docs/SCANNER_OPOS_RIG_VALIDATION_PROMPT.md` | Design + hardware-validation follow-on for the scanner USB-OPOS step. |

## Usage

Double-click `Install-Alleaves.bat` to install (it requests elevation once).

| Argument | Effect |
| --- | --- |
| _(none)_ | Install |
| `-Uninstall` | Reverse a prior install using the persisted manifest. Does **not** reset the scanner — to revert it, scan the "USB HID Keyboard" / "Set Defaults" barcode or re-run 123Scan. |
| `-DryRun` | Simulate everything; make no system changes (no admin required) |
| `-SkipScannerConfig` | Don't flip the connected Zebra scanner(s) to USB-OPOS (leave the scanner's host mode untouched) |
| `-ScannerConfigOnly` | Run **only** the USB-OPOS scanner step — skip all downloads, installs, and finishing. Use it to configure a scanner that wasn't attached during the main install (just plug it in and run this), or to re-apply OPOS. Mutually exclusive with `-Uninstall`. |

### Exit codes

`0` success · `1` install/uninstall failure · `2` mode ambiguity · `3` not elevated ·
`4` scanner degraded (CoreScanner missing — re-run) · `5` working-dir creation failed ·
`6` a scanner was connected but the USB-OPOS switch failed (re-run with the scanner attached).
Codes `4` and `6` are non-fatal "re-run" signals and never mask a hard failure (`1`).

### Scanner USB-OPOS — barcode fallback

The installer sets OPOS automatically (software path). For a terminal that has no scanner attached
during the run, or a no-PC situation, scan the single **USB-OPOS** programming barcode in
`scanner/Scanner_OPOS_barcode.pdf` — same end result, no software required. It sets OPOS in one scan straight
from the factory HID-Keyboard default (the HID-KB → IBM Hand-held → OPOS two-hop is only needed by the
software/CoreScanner path, not by scanning the barcode).

## Rebuilding the deliverable

Edit `alleaves_setup.ps1`, then regenerate the `.bat`:

```powershell
.\build-bat.ps1
```

Never edit `Install-Alleaves.bat` by hand — it is a generated, SHA256-verified
base64 pack of the `.ps1`.
