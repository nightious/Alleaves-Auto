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

Working root is `%ProgramData%\AlleavesAuto` (`downloads\`, `logs\`, and the install
manifest) so state survives a later `-Uninstall`.

## Files

| File | Purpose |
| --- | --- |
| `alleaves_setup.ps1` | The actual installer — native-PowerShell Google Drive download, silent install, manifest-driven uninstall. |
| `build-bat.ps1` | Base64-packs `alleaves_setup.ps1` into the single deliverable `Install-Alleaves.bat` (self-verifies SHA256 byte-identity). |
| `Install-Alleaves.bat` | **The deliverable.** Generated — do not hand-edit. Elevates once, decodes the embedded script, runs it. |
| `DS2208_OPOS.scncfg` | Zebra DS2208 scanner OPOS configuration. |

## Usage

Double-click `Install-Alleaves.bat` to install (it requests elevation once).

| Argument | Effect |
| --- | --- |
| _(none)_ | Install |
| `-Uninstall` | Reverse a prior install using the persisted manifest |
| `-DryRun` | Simulate everything; make no system changes (no admin required) |

## Rebuilding the deliverable

Edit `alleaves_setup.ps1`, then regenerate the `.bat`:

```powershell
.\build-bat.ps1
```

Never edit `Install-Alleaves.bat` by hand — it is a generated, SHA256-verified
base64 pack of the `.ps1`.
