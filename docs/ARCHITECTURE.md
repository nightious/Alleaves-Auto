# Architecture

`alleaves_setup.ps1` is a single-file, self-bootstrapping POS installer for stock Windows 10/11 terminals:
silent, idempotent, reversible. `Install-Alleaves.bat` is a generated transport around it
([BUILD-BAT.md](BUILD-BAT.md)) and is the whole deliverable.

Subsystem docs: [ACCOUNT-SWAP.md](ACCOUNT-SWAP.md) · [INSTALL-ENGINE.md](INSTALL-ENGINE.md) ·
[MANIFEST.md](MANIFEST.md) · [FINISHING.md](FINISHING.md) · [SCANNER-OPOS.md](SCANNER-OPOS.md) ·
[PRINTER-OPOS.md](PRINTER-OPOS.md)

## <a id="run-shape"></a>Run shape

Working root `%ProgramData%\AlleavesAuto` (`downloads\`, `logs\`, `logs\install_manifest.json`). It
deliberately **survives `-Uninstall`** — the `.bat` deletes its own decoded `.ps1` from `%TEMP%`, so the
working root is the only durable state. `-DryRun` without admin falls back to `%TEMP%`. `$WorkDir` is **not
caller-overridable**: a deep path overflows the IS5 stub's fixed command-line buffer
([INSTALL-ENGINE.md#is5-buffer](INSTALL-ENGINE.md#is5-buffer)), and nothing ever set it.

**`$ManifestPath` does NOT follow that fallback.** It is always the `%ProgramData%` copy — only `-DryRun`
reaches the `%TEMP%` branch and it never writes the manifest, so following `$WorkDir` made a non-elevated
dry run preview against an *empty* one: `Test-PriorInstallFailed` trusted ARP, `Write-XmlFile` planned a
backup it had already taken, `Remove-StalePrinterOpos` retired nothing, and `$installUser` flipped. Logs
and the transcript still live under `$WorkDir`.

The transcript is opened **once, before the mode branch**, from a mode-keyed log prefix and banner; all
three branches used to carry their own copy and one dry-run banner had already drifted from the others.

**Single elevation owner is the `.bat`.** The `.ps1` never relaunches itself; it aborts with exit 3 if not
admin (except `-DryRun`).

## <a id="order-of-operations"></a>Order of operations

Pre-dispatch, before `Start-Transcript` (console-only, nothing logged to file): mode echo + ambiguity guards
→ exit 2; elevation abort → exit 3; account precheck → exit 8 / swap → exit 9
([ACCOUNT-SWAP.md](ACCOUNT-SWAP.md)); working-dir creation with a write probe → exit 5. Then the install
branch:

| Step | What |
|---|---|
| 0 | Computer rename prompt |
| 0b | Printer-brand prompt → feeds `$SkipPrograms` |
| 1 | Download phase |
| 2 | TeamViewer removal (default on) |
| 2b | VC++ x64 bootstrap |
| 3 | Install loop |
| 3b | CoreScanner presence check → exit 4 flag |
| 3c | Per-terminal finishing: taskbar pins, default browser, Chrome bookmark, then the **logon task** that makes the first three take effect ([FINISHING.md](FINISHING.md)) |
| 4 | Master-list `.nlbl` copy |
| 5 | Scanner USB-OPOS switch |
| 5b | Receipt-printer OPOS registration |
| 6 | `Save-Manifest` |
| 7 | Exit-code dispatch |

Install order inside step 3: Chrome → Alleaves Terminal → Zebra 123 Scan → Zebra Scanner SDK → POS for .NET
→ NiceLabel → the chosen printer driver. **Splashtop SOS is download-only** — staged for the tech to run by
hand, never installed.

### <a id="why-the-two-prompts-are-at-step-0"></a>Why the two prompts are at step 0

Every interactive question belongs before the long unattended stretch, so the tech can walk away.

Step 0b must also precede the **download** phase: it adds every *unchosen* brand's `RowName` to
`$SkipPrograms`, so `Test-SkipMatch` drops those rows from both download and install. Picking POS-X must not
drag down 471 MB of Star payload, and vice versa. `'None'` is not a key in `$PrinterBrands`, so it skips them
all for free.

The brand is resolved **independently of `-SkipPrinterConfig`**: gated together, `-PrinterBrand None
-SkipPrinterConfig` still downloaded and installed a driver
([PRINTER-OPOS.md#skip-fallback](PRINTER-OPOS.md#skip-fallback)).

## <a id="step-isolation"></a>Step isolation

**A failing step stops the STEP, not the run**: the install branch is one `try`, so an unguarded throw skips
every later step and the exit tally. Every step call is therefore wrapped as
`Invoke-Step 'Taskbar pins' { Invoke-ChromeTaskbar }`, which records the failure on `$script:StepFailed`
(→ exit 1) and **continues**. A bare call reintroduces the whole bug, which is why
`tests\Test-StepIsolation.ps1` AST-asserts that none survives. Traps:

- It is the guard for every step body that is **not** fully try/catch'd — most of them.
  `Uninstall-TeamViewer` has none at all; `Invoke-ComputerRename`, `Copy-MasterList`, the three Chrome steps,
  `Register-FinishLogonTask` and `Set-PrinterOpos` each guard only part of a body. Only `Set-ScannerOpos` is
  fully wrapped internally — assume a new step is in the unguarded majority.
- <a id="brand-fallback"></a>**`Invoke-Step` yields nothing when the body throws.** The one caller that
  reads a return value — the step-0b brand resolve — needs `if (-not $brand0) { $brand0 = 'POS-X' }` after
  it, or the brand loop skips **every** brand and no printer driver is downloaded or installed.
- The install loop guards each **row** and the download phase each **file**, one level down, for the same
  reason: one bad product must cost exactly one product.
- The config-only branch's single step is wrapped too: a throw there skipped that mode's own "did nothing"
  check and its `Save-Manifest`.
- The top-level `catch` stays as the last-resort net; it is no longer the normal path.

## <a id="exit-codes"></a>Exit codes

Set in the `$exitCode` dispatch tail — the authoritative copy. This is an RMM contract.

| Code | Meaning |
|---|---|
| 0 | ok |
| 1 | install / uninstall / download / finishing / step failure |
| 2 | mode ambiguity or a bad argument |
| 3 | not elevated |
| 4 | scanner degraded (CoreScanner missing) |
| 5 | working directory could not be created |
| 6 | scanner present but the OPOS switch failed |
| 7 | OPOS receipt-printer registration failed |
| 8 | account precheck failed and was not overridden |
| 9 | account swap armed, rebooting to resume — **an RMM must not dispatch a tech** |
| 10 | **launcher only** — the `.bat` could not decode its payload; nothing ran |

`2`/`3`/`5`/`8`/`9` are pre-dispatch `exit`s: console-only, nothing logged to file. `9` is distinct from `8`
on purpose — `8` means blocked and nothing was done, `9` means the box is coming back to finish itself — and
`10` sits outside the `0`–`9` set so the launcher's own failure can never be read as `9`
([BUILD-BAT.md#decode-guard](BUILD-BAT.md#decode-guard)).

### <a id="what-folds-into-exit-1"></a>What folds into exit 1

`$script:StepFailed` (a step that threw and was carried past) plus `$script:FinishFailed`, which covers
every step that writes **no `$Manifest.installed` row** and so was invisible to the tally:

- the master-list copy, the Chrome bookmark policy, logon-task staging and registration, a failed
  `Disable-TrackedTask`, and **either** total-taskbar arm of `Invoke-ChromeTaskbar`
- the default-browser step's **UCPD arm** — `Start=4` is what lets the UserChoice writes stick, so a silent
  failure there ships a terminal that opens links in Edge ([FINISHING.md#default-browser](FINISHING.md#default-browser))
- a failed **computer rename**, which also silently poisons the OPOS device names
  ([FINISHING.md#rename](FINISHING.md#rename))
- a failed **TeamViewer removal** — remote access left on the box is a security outcome; a sibling ARP entry
  already removed by an earlier pass is not a failure
- the two terminal arms of `Clear-AccountSwapState` and a swap marker that would not delete — which is why
  `$script:FinishFailed = $false` is initialized immediately above that call, not down with the other flags

`$script:ManifestWriteFailed` is its own flag, read **after** `Save-Manifest`. The `finally`'s second
`Save-Manifest` is gated on `$script:ManifestSaved`: it runs after `$exitCode` is final, so a failed write
there would set the flag with nothing left to read it.

### <a id="tally-snapshot-ordering"></a>Tally snapshot ordering

**The exit-code tally is snapshotted BEFORE `Save-Manifest`**. The merge carries prior-run rows forward for
every product this run didn't touch (`-SkipPrograms`, `-PrinterBrand None`), so tallying after it counts an
OLD failure as a new one — exit 1 forever, which then also suppresses the non-fatal 4/6/7 signals, gated as
they are on `$exitCode -eq 0`. `computerRenamed` is snapshotted for the same reason: a `-SkipRename` re-run
otherwise announced a rename that landed weeks ago.

### <a id="the-non-fatal-block"></a>The non-fatal block

`4`/`6`/`7` are "re-run" codes that only set when nothing else failed, so they never mask `1`. They live in
**one** copy after the branch `if/elseif/else` (gated `-not $Uninstall`), printing after `Step 'Done'` — the
config-only and install branches each used to carry their own and the wording had already drifted. Exit
`4`'s printed "re-run the installer" only became real once `Test-PriorInstallFailed` started rejecting a
`note='msi-fallback'` row ([INSTALL-ENGINE.md#msi-fallback](INSTALL-ENGINE.md#msi-fallback)).

## <a id="argument-guards-exit-2"></a>Argument guards (exit 2)

All of these are rejected up front, beside each other:

- <a id="positional"></a>a **positional** argument. `param()` hands every non-switch parameter an implicit
  position, so `Install-Alleaves.bat uninstall` bound `uninstall` to `-SkipPrograms` and ran a full
  INSTALL — the launcher's token test needs the dash, so no mode guard fired.
  `[CmdletBinding(PositionalBinding=$false)]` plus a `ValueFromRemainingArguments` sink turns any
  dashless token into exit 2 instead.
- a **dropped `-Uninstall`**: the launcher sets `ALLEAVES_REQUESTED_MODE=uninstall` when its arg line
  holds ` -uninstall ` as a whole token — padded on both sides, because the bare substring made
  `-ComputerName TILL-UNINSTALL-2` request one. The reverse test ("requested install, parsed
  uninstall") is gone: nothing can reach it except a legal abbreviation like `-Uninstal`, which it
  then rejected.
- `-ScannerConfigOnly` with `-Uninstall`, or with `-SkipScannerConfig` — "run ONLY this step" plus "skip
  this step" is a run that does nothing and exits 0, which reads as success to an RMM
- `-PrinterConfigOnly` with `-Uninstall`, `-ScannerConfigOnly`, `-SkipPrinterConfig`, or `-PrinterBrand
  None`
- `-SkipRename` with `-ComputerName` — `Invoke-ComputerRename` returns on `-SkipRename` before it looks at
  `-ComputerName`, so the pair silently dropped the name *and* left the OPOS device names built from the old
  one: a terminal Alleaves cannot open, discovered at the till
- `-SkipNiceLabelActivation` with `-NiceLabelLicense` — tested on `$PSBoundParameters.ContainsKey`, **not**
  on the variable, since `-NiceLabelLicense` has a non-empty default in `param()`
- an **invalid `-SkipPrograms` regex**. Inside `Test-SkipMatch` it only warned and then read as "no match",
  so the operator's skip was silently not honoured on a run that still exited 0. Pre-validating here makes
  that `Warn` unreachable for CLI input; step 0b's later additions are metacharacter-free brand `RowName`s,
  so they need no second pass.

## <a id="config-only-modes"></a>Config-only modes

`-ScannerConfigOnly` and `-PrinterConfigOnly` share one dispatch branch: no downloads, no installs, no
finishing. Still admin (COM + HKLM); `-DryRun` works non-elevated. `Save-Manifest` merges onto the prior
manifest, so only that step's rows update.

Each mode keeps its **own** non-fatal exit code (6 / 7) and its **own "did nothing" check**, run before
`Save-Manifest` so a prior run's merged-in `ok` row can't mask it; without it the mode always exits 0. A
skip that is benign in a full install (no scanner attached at bench-build time is normal) is a failure here,
because these modes exist precisely when the device IS attached. The floor counts `already-opos` /
`already-configured` as changes — the device is in the requested state, which is the point of the run.

No `Invoke-ComputerRename` runs here, so `computerRenamed` is empty and `Get-PosNamePrefix` falls back to
the current name — correct, since by then the rename reboot has happened.

## <a id="tests"></a>Tests

`tests\` holds the runnable self-checks; all exit 0/1, no framework. Three AST-lift functions out of the
`.ps1` rather than loading it; `Test-InstallerExitCode.ps1` lifts nothing — it spawns a live `cmd.exe /c
exit 7`, then only compares AST extents and regex-matches body text.

`_common.ps1` holds `Assert-Eq`, `Get-InstallerAst`, `Get-InstallerFunctions` and
`Assert-InstallerHas`, dot-sourced by all five. It is **not** a test — the runner and `release.ps1` glob
`Test-*.ps1` — and `$script:Failures` still belongs to each dot-sourcing test, since that is the scope the
functions are defined in.

| File | Covers |
|---|---|
| `Test-AccountPrecheck.ps1` | every `Test-InstallAccount` verdict arm on stubbed probes; `Get-MicrosoftAccountId`'s tri-state ([ACCOUNT-SWAP.md#msa](ACCOUNT-SWAP.md#msa)); `ConvertTo-ResumeArgs` **round-trip**, not just its string shape; `Confirm-Swap`'s headless NO; `Restore-AutoLogon` ([ACCOUNT-SWAP.md#autologon](ACCOUNT-SWAP.md#autologon)) — a pre-existing value is never deleted and **no password is ever written back**; `Clear-AccountSwapState`'s dry-run / unreadable-marker / surviving-task arms; `Set-AccountCheckOverride`'s recorded fields |
| `Test-ManifestMerge.ps1` | `Merge-PriorList` direction and the prior-side falsy-key drop per list ([MANIFEST.md#merge](MANIFEST.md#merge)); the `.iss` fallback row-drop; `Test-PriorInstallFailed`'s arms; `Get-PriorManifest` against a **locked** file; uninstall step 4b's stale-row loop on a scratch `HKCU` key; that every `$PrinterBrands` `RowName` is both a `$DriveFiles` **Label** and an `$Installers` **Name**; `Test-PrinterOposConfigured` |
| `Test-StepIsolation.ps1` | `Invoke-Step`'s four behaviours ([#step-isolation](#step-isolation)), plus AST asserts that no bare step call survives and that the install loop's `foreach` still opens with a `try` recording `fail-exception` |
| `Test-InstallerExitCode.ps1` | the `$p.Handle` trap ([INSTALL-ENGINE.md#invoke-installer](INSTALL-ENGINE.md#invoke-installer)) — live behaviour *and* an AST assert that the dereference still sits between `Start-Process` and `WaitForExit`; the null-exit arm's `note='exit-unknown-but-registered'` row |

Stub order matters in `Test-AccountPrecheck.ps1`: the `Clear-AccountSwapState` section shadows
`Restore-AutoLogon` / `Test-Path` / `Get-Content` / `Remove-Item`, so **nothing needing a real one may
follow it**. `Set-AccountCheckOverride` does run after it, and survives only because it touches none.
