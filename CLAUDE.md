# CLAUDE.md

Guidance for Claude Code when working in this repo. For end-user usage and the full
option / exit-code tables, see `README.md`.

## Overview

AlleavesAuto is a single-file, self-bootstrapping POS installer for "Alleaves" on stock
Windows 10/11 terminals: silent, idempotent (re-runs skip installed products), reversible
(manifest-driven uninstall). `alleaves_setup.ps1` is the **source of truth**; `Install-Alleaves.bat`
is a **generated transport** — `build-bat.ps1` base64-packs the `.ps1` into the `.bat`, which
self-elevates once and runs the embedded script. The `.bat` is the whole deliverable. `docs/`
holds the scanner rig-validation notes (the design lives in the `Set-ScannerOpos` header comment)
plus the printer OPOS field-results table; `scanner/` holds the no-PC barcode fallback;
`printer/` holds `Collect-PrinterFingerprint.ps1`. README's Files table is the fuller map.

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
POS for .NET → NiceLabel → OLE POS Setup (POS-X printer driver). Around it: TeamViewer is
removed first (default; `-SkipUninstallTeamViewer` keeps it), VC++ bootstraps before the Zebra
products, then after the loop the Master List (`.nlbl`) is copied, the Scanner USB-OPOS switch
runs, and finally `Set-PrinterOpos` registers the receipt-printer OPOS entry.
**Splashtop SOS is download-only** — fetched up front and staged for the tech to run
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
- **Post-reboot finishing** — computer rename, Alleaves Terminal + Alleaves POS taskbar pins /
  Edge removal, default browser via UserChoice hashes (deferred to a logon task; UCPD disabled
  for next boot), and the Alleaves bookmark policy (`Invoke-ChromeBookmark`, no task).
- **Scanner USB-OPOS** — see the Gotchas bullet.
- **Receipt-printer OPOS** (`Set-PrinterOpos`) — final functional step; see the Gotchas bullet.
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
  degraded (CoreScanner missing) · `5` working-dir failed · `6` scanner present but switch failed ·
  `7` OPOS receipt-printer registration failed · `8` account precheck failed (not signed into a
  local admin account). `4`/`6`/`7` are non-fatal "re-run" codes that only set when nothing else
  failed — never masking `1`. `2`/`3`/`5`/`8` are pre-dispatch `exit`s, before the try/`$exitCode`
  machinery and before `Start-Transcript` — console-only, nothing logged to file.

## Gotchas / project rules

- **Production bar for every install step: bootstrap + track (manifest) + reverse (uninstall).**
  Don't add a step that can't be cleanly uninstalled.
- **Account precheck (`Test-InstallAccount`, exit 8)** — sits right after the elevation abort and
  *before* `$WorkDir` is created, so a rejected box gets nothing written. It reads the **signed-in**
  user (`Win32_ComputerSystem.UserName`), never the process token: a standard user can launch the
  `.bat` and type someone else's admin credentials at UAC, which makes `Test-IsAdmin` pass while
  the profile that will actually run the POS is not an admin — the token is the wrong answer for
  exactly the case being tested. Order matters: **domain/Entra before the SID-shape test** (an
  Entra SID is `S-1-12-1-*` and would otherwise report as "no interactive user"), and the MSA test
  is `PrincipalSource`/IdentityStore, **not** the domain test — an MSA profile still presents as
  `COMPUTERNAME\shortname`. No bypass switch, so an undetermined verdict must **block**: failing
  open would be the bypass. `-Uninstall` skips the check (a blocker there would strand a terminal
  that later acquired an MSA with no way to reverse the install); `-DryRun` reports and continues
  (it writes nothing, and it's how the tech gets the verdict before touching the terminal) — and
  that `-DryRun` print is the only runnable check on the classification logic.
- The master list is a `.nlbl` — copy **as-is, never unzip** (the "encryption" is NiceLabel's
  internal format); copied into every real user profile's Documents (`Get-TargetUserProfiles`).
- NiceLabel gets an explicit service / registry / ProgramData sweep on uninstall, and must **never
  be pre-cleaned on reinstall**: the raw suite installer reinstalls cleanly over itself, but
  pre-cleaning strips its MSI while bootstrapper state lingers, so the reinstall becomes a *repair*
  that never re-creates the ARP entries — leaving NiceLabel invisible to a later `-Uninstall`. (The
  MSI/`.iss` families ARE pre-cleaned, for the opposite reason: reinstalling over them drops into
  maintenance mode and silently fails / 1603.)
- Zebra products use InstallShield `.iss` response-file silent installs; CoreScanner requires VC++
  first to avoid a forced mid-install reboot.
- **Scanner USB-OPOS is a CoreScanner *command*, not a file** — never embed a `.scncfg` in the
  installer (a per-model `.scncfg` + opcode 5020 is a documented *future* full-config path only —
  beeper volume, symbologies — never needed to set OPOS itself; regenerate a fresh export if ever used).
  `Set-ScannerOpos` is the LAST functional step and **records-only** on uninstall
  (`removable=$false`, like the rename / TeamViewer removal); it also runs standalone via
  `-ScannerConfigOnly` (`Save-Manifest` merges onto the prior manifest, both paths built from the
  shared `New-InstallManifest` so the key set can't drift). Key traps:
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
    real in-session 112→recovery run still pending — capture with `-ScannerConfigOnly
    -ForceFingerprint` (forces the `Write-NewScannerFingerprint` dump for an already-known model;
    lands in `logs\`), log to `docs/` (running table in `docs/SCANNER_OPOS_RIG_VALIDATION_PROMPT.md`).
  - `$ScannerKnownModels` (which models skip the new-model fingerprint dump) is a **family regex**,
    not a list: CoreScanner's `<modelnumber>` is the full kit/config SKU (`DS2208-SR7U2100SGW`),
    never the bare family name, so it's matched with `-notmatch` on the prefix. Add families with
    `|`; keep it non-empty (`''` matches everything and silences the dump).
  - `scanner/Scanner_OPOS_barcode.pdf` is the no-PC fallback (one scan from the HID-KB default — the
    two-hop is only the SDK path's constraint). A doc deliverable, **not** embedded, so it needs no
    `.bat` rebuild.
- **POS-X receipt printer (`Set-PrinterOpos`)** — the LAST functional step, and unlike the
  scanner it is **pure registry**: no COM, no polling, and it works with nothing plugged in
  (`Open()` returns 0 on a bare bench). Full evidence in `docs/PRINTER_OPOS_FIELD_RESULTS.md`.
  Key traps:
  - **The cash drawer has NO device entry** (dropped 2026-08-12; the `CashDrawer`/`StandardU`
    element and its 33 values came out, and the one-element device array flattened to the
    `$PrinterOpos*` constants). It hangs off the printer's
    RJ-11 and `Standard.CashDrawer.SOU` resolved to the printer's own `POSPrinterSOU.dll`
    anyway, so it follows the printer via the printer key's **`DrawerOpen=1`** — SetupPOS's
    *Open CashDrawer* = *Follow Printer*. That combo has exactly two items, `CashDrawer` (0)
    and `Follow Printer` (1); driving it and diffing `OLEforRetail` changed **only** that one
    value. `Thermal.inf`'s `[UOPTION]` default is `0`, so this is the one shipped value that
    deliberately differs from the vendor default — still captured, not authored.
  - **The device values are CAPTURED, never authored.** They came from diffing a real
    `SetupPOS.exe` run (28 printer values). Deriving them from `Thermal.inf` gives a subtly
    wrong key — `Description` and `PortShare` are in neither section of it. If the package
    version bumps, re-capture; don't hand-edit.
  - **The logical device name is per-terminal**: `<POSname>_Printer`, built
    from the *requested* rename (`$Manifest.computerRenamed.to`), **not** `$env:COMPUTERNAME` —
    the rename only lands on the post-install reboot, so the env var is stale all run. The
    `applied` flag is part of that test: a rename that *failed* still records `to`, and naming
    the device after a name the terminal never gets is silently unopenable. The vendor
    default (`ThermalU`) is deliberately **not** created. Alleaves must be
    configured to open this exact name, so a later rename must re-run the step —
    `Remove-StalePrinterOpos` drops any manifest-recorded device this run does *not* register
    (never a device another vendor created). That test is an **exact match against this run's
    LDNs**, not a prefix match: a prefix match cannot retire a device dropped from the table,
    which is how the removed `<POSname>_Drawer` reaches already-deployed terminals.
  - **The driver must be present before the entry is written** (`Find-InstalledProducts
    'OLE POS Setup'`, skipped under `-DryRun`): otherwise the step registers a device
    pointing at a DLL that isn't there. Check ARP, **not** the ProgID — the vendor uninstaller
    leaves the whole ProgID → CLSID → InprocServer32 chain behind (measured), so a ProgID test
    reports "installed" on a box where the DLL is long gone. Driver absent is a benign
    `result='no-driver'` skip, exit 0.
  - **Readback compares EVERY value by name**, against the same `Strings`/`DWords` tables just
    written. `$ErrorActionPreference` is `'Continue'`, so a failed `New-ItemProperty` is
    non-terminating and `Set-TrackedRegValue` records a value it never wrote. A value **count**
    cannot catch that on a key that already holds the full set — i.e. on every re-run and on every
    terminal deployed before the table changed, which is exactly when it matters: `DrawerOpen`
    0 → 1 silently not applied, reported `ok`, drawer never kicks. `(default)` is a `Strings`
    member, so it is covered by the same loop — but it must be READ as `GetValue('')`.
    `(default)` is an alias only the `*ItemProperty` cmdlets accept; `GetValue('(default)')`
    hunts for a value literally named that, finds none, and returns `$null` — which failed the
    readback on the first key of every run (all 28 values written correctly, step still
    reported `fail` + exit 7). Same alias trap as the uninstall path's `DeleteValue('')`.
  - **Register first, retire stale devices after.** `Remove-StalePrinterOpos` runs *after* the
    registration and is passed only the LDNs that actually verified. Deleting first meant a
    failed write (exit 7, "re-run with `-PrinterConfigOnly`") left the terminal with **no** OPOS
    printer where it had a working one under the old name a second earlier — and the delete has no
    rollback. It also applies the uninstall path's `SubKeyCount` guard: a non-recursive
    `Remove-Item` on a key with children raises `ShouldContinue`, which prompts on an interactive
    host and *throws* on an RMM one, silently defeating the removal.
  - **IS5 has a fixed command-line buffer.** The `/f1`/`/f2` paths must stay short: ~190 chars of
    inner command line works, ~390 crashes the PFTW stub with an access violation that looks
    like a broken package. `$DownloadDir`/`$LogDir` are fine, and that fixed `%ProgramData%` root is
    why there is no `-WorkDir` override: a caller-supplied deep path silently crashes the stub.
  - **The vendor uninstaller leaves every OPOS device entry behind** (measured). Our
    `regKeysCreated` removal is therefore load-bearing, not belt-and-braces — without it
    `-Uninstall` strands a phantom device pointing at a deleted DLL.
  - `Remove-ItemProperty` **cannot** delete a key's `(default)` value (it throws), even though
    `New-ItemProperty -Name '(default)'` creates it. Use a writable handle:
    `OpenSubKey($sub,$true).DeleteValue('',$false)`. And key-emptiness is guarded on
    **`SubKeyCount` only** — a key whose sole value is the default reports `ValueCount=1`, so an
    "only if empty" test would never fire on exactly the key that must go.
  - `-PrinterConfigOnly` runs it standalone (it shares the config-only dispatch branch with
    `-ScannerConfigOnly`, but each mode keeps its **own** non-fatal exit code — 7 / 6 — and its own
    "did nothing" check, run before `Save-Manifest` so a prior run's merged-in `ok` row can't mask
    it; without them the mode always exits 0. Rejects `-SkipPrinterConfig`, which would be a
    do-nothing exit 0). `printer/Collect-PrinterFingerprint.ps1` is the field diagnostic — a
    doc-style deliverable, **not** embedded, so it needs no `.bat` rebuild.
  - The **brand prompt is asked at step 0**, beside the rename prompt, and cached in
    `$script:PrinterBrandResolved` — every interactive question belongs before the long
    unattended stretch, not at step 5b. Option `2) None` (`-PrinterBrand None`) is the
    no-receipt-printer answer: it appends `OLE POS Setup` to `$SkipPrograms` so the *existing*
    `Test-SkipMatch` drops the driver from both the download and install rows, and
    `Set-PrinterOpos` returns `result='skipped'` — which is why the prompt has to run before
    the download phase. It returns *before* `Remove-StalePrinterOpos`: None is a skip, not a
    retro-uninstall. Rejected with `-PrinterConfigOnly` for the same reason
    `-SkipPrinterConfig` is. Its `Read-Host` is try/catch'd for the same reason the
    rename's is (F14): it throws on a headless run, and an escaping throw lands in the
    top-level catch and turns a clean install into exit 1. `UserInteractive` alone is not a
    sufficient guard — `powershell -NonInteractive` still reports `$true`.
- **Chrome → the Alleaves web POS (`$AlleavesUrl`)** — split across two steps for one reason:
  **Chrome blocks the start-page policies on an unmanaged box.** Measured on the rig 2026-08-12,
  `chrome://policy` reports *"This policy is blocked, its value will be ignored"* for
  `RestoreOnStartup`, `RestoreOnStartupURLs`, `HomepageLocation` and `HomepageIsNewTabPage` —
  Chrome's anti-hijacking gate, which only opens on an AD/Entra-joined or CBCM-enrolled device.
  The `\Recommended` flavour is blocked identically, and merging the same keys into Chrome's
  `initial_preferences` was tested and did **not** carry into a brand-new profile. **Don't
  re-add them.** So:
  - **Start page** = the `Alleaves POS` taskbar shortcut (`chrome.exe <url>`), which replaces the
    plain Chrome pin. Verified to open the POS cold-start. `ShowHomeButton` is deliberately *not*
    set — it works, but the Home button could only reach the new-tab page.
  - **Bookmark** (`Invoke-ChromeBookmark`) = `ManagedBookmarks` + `BookmarkBarEnabled` under
    `HKLM:\SOFTWARE\Policies\Google\Chrome` via `Set-TrackedRegValue`, so tracking + uninstall
    come free and there's **no logon task**. Both verified `OK`, in an existing profile *and* a
    fresh one. Mandatory, not `\Recommended` — the cashier must not be able to delete it; the
    "managed by your organization" banner is expected. `BookmarkBarEnabled=1` or it's off-screen.
    Hand-editing a profile's `Bookmarks` JSON is the wrong answer (Chrome checksums it, rewrites
    it while running, and a new cashier profile gets nothing). The `.bat` forces 64-bit
    PowerShell, so the write lands in the view Chrome reads: no `WOW6432Node` branch.
- **Taskbar pins** — `Get-TaskbarXml` takes the pin list; `Invoke-ChromeTaskbar` builds it per app
  so one missing product doesn't drop the other's pin (it used to hard-return on "no Chrome").
  Neither pin target ships a `.lnk` — the Alleaves MSI installs **no shortcut at all** (two files,
  measured) and `Alleaves POS` is ours — so `New-TrackedShortcut` creates both all-users Start
  Menu shortcuts that `DesktopApplicationLinkPath` needs, tracked via `filesPlaced`. Targets come
  from `Get-AlleavesLauncherPath` (ARP `InstallLocation`) and `Get-ChromeExePath` (`App Paths`).
  Still no XML comments in that here-string.
  **The per-user marker stores the LAYOUT, not a bare flag.** The logon task's
  `TaskbarApplied` value holds the pin list (`$script:TaskbarStamp` = `$pins -join '|'`),
  because clearing `Taskband` + restarting Explorer is the only thing that makes Explorer
  re-read the XML — so a boolean "already applied" made every later pin-set change
  invisible to a terminal that was already deployed (it kept the old pins forever, only
  recoverable by uninstall/reinstall). A deployed box holds the old DWORD `1`, which never
  equals a stamp, so it re-applies once and settles; compare as strings and write with
  `New-ItemProperty -Force -PropertyType String` (`Set-ItemProperty` would try to coerce
  the string into the existing DWORD). `$script:FinishTaskbar` is set **only if at least one
  per-user XML actually landed** — arming the task with no layout on disk is pure
  destruction (it deletes the cashier's pins and ours never appear).
  **A pinned `.lnk` lives in TWO places.** Applying the layout makes Explorer *copy* the shortcut
  into each user's `…\Quick Launch\User Pinned\TaskBar`, so `filesPlaced` — which only knows the
  all-users source — leaves a pin pointing at a deleted exe (measured: survived a full
  `-Uninstall`). Uninstall step **4e** deletes `$TaskbarPinNames` from every profile's pinned
  folder; that list exists so install and uninstall can't drift, and it is an **exact** name match
  so another vendor's pin is never removed.
- The four `Invoke-IssSilent` overrides (`ArgFormat`, `WaitNames`, `ReapNames`,
  `RegistryShortCircuit`) all **default to the original Zebra behaviour** — only a row that opts
  in changes anything, which is what keeps the validated Zebra path byte-identical. `ArgFormat`
  is a whole format string rather than a prefix because InstallShield rejects a line mixing `-`
  and `/` switch styles. `RegistryShortCircuit=$false` is mandatory for pure InstallScript:
  `DeinstallStart()` writes the ARP entry *before* file transfer, so the "in the registry ⇒ done"
  break would kill the worker mid-copy and record success. **`RegistryShortCircuit` also gates the
  SUCCESS VERDICT**, not just the poll loop: the verdict is `$logOk -or ($regOk -and
  $RegistryShortCircuit)`, so a `$false` family must show `ResultCode=0` in the response log
  (reachable — `/f2` forwarding is proven). Without that, a half-copied install was
  recorded `ok` and `Set-PrinterOpos`'s ARP driver guard then passed too, registering a device
  aimed at a DLL that was never copied.
- **"Already installed" means SUCCESSFULLY installed.** Both idempotency guards in
  `Invoke-InstallLoop` consult `Test-PriorInstallFailed` (which reads the prior manifest via
  `Get-PriorManifest`) before letting ARP presence skip a product — an install that failed leaves
  exactly the registry state a later run reads as "done", so without this a broken product is never
  repaired and every re-run reports success. A product with **no** prior row still skips on ARP
  alone (installed by hand or by an older build). Consequence to expect: a genuinely failing
  product retries every run until it succeeds.
- **The exit-code tally is snapshotted BEFORE `Save-Manifest`.** The merge carries prior-run rows
  forward for every product this run didn't touch (`-SkipPrograms`, `-PrinterBrand None`), so
  tallying after it counts an OLD failure as a new one — exit 1 forever, which then also suppresses
  the non-fatal 4/6/7 signals since they are gated on `$exitCode -eq 0`.
- **An unreadable prior manifest is never overwritten.** It is the only record of what earlier runs
  placed, so `Save-Manifest` moves it to `<manifest>.unreadable` instead of clobbering it, and
  writes via temp file + `Move-Item` so a kill mid-write can't produce the truncated JSON that
  causes the problem in the first place.
- Single elevation owner is `Install-Alleaves.bat`; the `.ps1` never self-relaunches — aborts if
  not admin (except `-DryRun`).
- Runtime payloads, logs, and the base64 build intermediate (`alleaves_b64.txt`) are git-ignored —
  see `.gitignore`.
