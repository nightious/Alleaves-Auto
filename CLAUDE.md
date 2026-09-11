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
  self-verifies (SHA256) by decoding the base64 back **out of the `.bat` it just wrote**, not out
  of the in-memory `$chunks` — `$chunks` *is* the source by construction, so that comparison could
  only ever pass and could never see the one corruption this step can actually cause (a mangled,
  dropped or reordered echo line). **Always rebuild the `.bat` after editing the `.ps1`** — it
  won't pick up edits otherwise. Never hand-edit the `.bat`. A failed self-verify **renames the
  output to `.corrupt`**: the `.bat` is the whole deliverable, so a corrupt one must not keep the
  shipping name, one `git add -A` from being sent to a terminal.
- The emitted `.bat`'s elevation probe matches **both** High (`S-1-16-12288`) and System
  (`S-1-16-16384`) integrity SIDs: High alone meant an RMM dispatching it as SYSTEM failed the
  probe and re-launched itself elevated — no UAC gate stops an already-elevated token, so the child
  failed the same probe and forked unboundedly, while the `service-account` exit-8 verdict written
  for that account never reached the operator. It also **pre-deletes** the decoded
  `%TEMP%\alleaves_setup.ps1` (the decode's exit code is never checked and the only guard is
  `if not exist`, so a failed decode ran the *previous* build under this build's name).
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
POS for .NET → NiceLabel → the chosen printer driver (`OLE POS Setup` for POS-X, or
`Star TSP100 futurePRNT`). Around it: TeamViewer is
removed first (default; `-SkipUninstallTeamViewer` keeps it), VC++ bootstraps before the Zebra
products, then after the loop the Master List (`.nlbl`) is copied, the Scanner USB-OPOS switch
runs, and finally `Set-PrinterOpos` registers the receipt-printer OPOS entries.
**Only the chosen brand's printer row runs** — step 0b feeds every *other* brand's `RowName`
to `$SkipPrograms`, so the rows are dropped from both the download and install phases.
**Splashtop SOS is download-only** — fetched up front and staged for the tech to run
manually, never installed.

Major function groups in `alleaves_setup.ps1`:
- **Download phase** — native Google Drive fetch; magic-byte sniffing rejects HTML interstitials;
  size/truncation guards.
- **Install loop** — per family: MSI (`msiexec /qn`), raw `.exe` (a **capped** `WaitForExit`
  recording `result='fail-timeout'` and deliberately **not** killing the process — for these
  families the launcher may itself be the install engine), InstallShield `.iss` response-file
  silent installs, and wrapper-MSI extraction (poll `%TEMP%`, wait for the MSI size to stabilize,
  cache the extracted MSI). A 3010/1641 raises the deferred-reboot flag from **inside** the success
  arm, or a row that just recorded `fail` printed the hard reboot banner too.
- **Silent uninstall** — registry lookup + per-family flags; registry polling is authoritative for
  completion, and a success exit code other than 3010/1641 is **re-checked against ARP** (an
  uninstaller that refused the silent switch or was blocked by policy/AV exits 0 having removed
  nothing, and nothing downstream re-scans); a hung launcher is killed only past a ~60 s floor, so
  a vendor that clears ARP *before* deleting files isn't killed on the first poll and recorded
  removed.
- **VC++ bootstrap** — before Zebra CoreScanner, to avoid a mid-install reboot.
- **Post-reboot finishing** — computer rename, Alleaves Terminal + Alleaves POS taskbar pins /
  Edge removal, default browser via UserChoice hashes (deferred to a logon task; UCPD disabled
  for next boot — `Start=4` raises the deferred-reboot flag, because it is a next-boot-only change
  the whole default-browser design depends on), and the Alleaves bookmark policy
  (`Invoke-ChromeBookmark`, no task).
- **Scanner USB-OPOS** — see the Gotchas bullet.
- **Receipt-printer OPOS** (`Set-PrinterOpos`) — final functional step; see the Gotchas bullet.
- **Manifest persistence** — JSON records every install (method, exit code, logs), placed files,
  registry changes, scheduled tasks, TeamViewer removal, scanner results. Uninstall replays it in
  **reverse order**, replaying `result='fail'` rows as well as `'ok'`: InstallShield writes the ARP
  entry *before* file transfer, so a failed row routinely leaves a live ARP entry and partial files
  — skipping those stranded exactly the installs most in need of reversing.

## Conventions (match these when editing)

- Colored console helpers `Step` / `Ok` / `Warn` / `Fail` / `Dry`.
- `$ErrorActionPreference = 'Continue'`; per-function try/catch with a `Warn` fallback. Every
  result is recorded to the manifest so partial failures **don't** exit 0.
- Naming: `Verb-Noun` PascalCase functions (`Invoke-*`, `Get-*`), PascalCase globals (`$LogDir`,
  `$Installers`), camelCase manifest keys (`filesPlaced`, `exitCode`, `scannerConfigured`).
- Idempotency: registry lookup before install/uninstall; manifest **merge** (never drop prior
  items, and `$null` rows are filtered out — an absent JSON key reads as `@($null)`, a one-element
  array holding `$null`, which the prior-wins merges injected as a literal null row into lists
  uninstall walks with no null guard); cached extracted MSIs skip future wrapper runs. Guard state changes behind `-DryRun`,
  **flags included** — every check in `Copy-MasterList` sits below its dry-run return, because a
  mode that writes nothing must not raise `$FinishFailed` and produce a phantom exit 1.
- Anything that **records** a command line redacts `LICENSECODE=` (`$safeArgs`: the manifest's
  `args`, the console, so the transcript); `$ArgList` reaches the installer untouched. The manifest
  survives `-Uninstall` under world-readable `%ProgramData%`, so the key outlived the install.
- TLS 1.2 forced before any network call (stock Win10 defaults too low for the CDNs).
- `Set-TrackedRegValue`'s `ValidateSet` is **`'String','DWord'` only** — the two every caller uses.
  The Binary / QWord / MultiString / ExpandString arms were dead and each carried a latent restore
  bug (a MultiString prev stringifies to a space-joined scalar; an ExpandString prev comes back
  already expanded; `type` recorded what we *wrote*, not the prior kind). Add one back — capturing
  the prior type via `GetValueKind()` — only when a caller genuinely needs it.
- **Exit codes** are an RMM contract set in the `$exitCode` dispatch tail (verify there): `0` ok ·
  `1` install/uninstall/download/**finishing** fail (`$script:FinishFailed` — the master-list
  copy, the Chrome bookmark policy, the logon-task staging/registration, a failed **computer
  rename** (a preset `-ComputerName` equal to the current name is a no-op `Ok`, not a validation
  fail — an RMM that always passes `-ComputerName POS01` renamed on run 1 and exited 1 on every
  idempotent run after), a failed `Disable-TrackedTask`, a failed
  **TeamViewer removal** (third-party remote access left on the box is a security outcome, not a
  cosmetic one — but a sibling ARP entry whose product an earlier pass already removed is *not* a
  failure; the exe path has no `1605` to absorb that the way msiexec does), the two terminal arms of
  `Clear-AccountSwapState` (autologon values that would not restore, a resume task still registered)
  and a swap marker that would not delete — which is why `$script:FinishFailed = $false` is
  initialized **above** that call rather than with the other flags below it, and **either**
  total-taskbar
  arm in `Invoke-ChromeTaskbar` — neither product installed, or no per-user layout written — all
  write no `$Manifest.installed` row, so the tally could not see them and they exited 0; a failed
  rename also silently poisons the OPOS device
  names, since `Get-PosNamePrefix` correctly falls back to the *current* name. A manifest that
  could not be written is its own flag, `$script:ManifestWriteFailed`, read **after**
  `Save-Manifest` — the tally itself is still snapshotted before it; the `finally`'s second
  `Save-Manifest` is gated on `$script:ManifestSaved`, since it runs after `$exitCode` is final and
  a failed write there set the flag with nothing left to read it) · `2` mode
  ambiguity, or a bad argument — an invalid `-SkipPrograms` regex is rejected up front beside the
  other guards, because inside `Test-SkipMatch` it only warned (once per name per row per phase)
  and then read as "no match", so the operator's skip was silently not honoured while ~34 warnings
  scrolled past an RMM log that still exited 0 · `3` not elevated · `4` scanner
  degraded (CoreScanner missing; its printed "re-run the installer" only became real once
  `Test-PriorInstallFailed` started rejecting a `note='msi-fallback'` row — see that bullet) ·
  `5` working-dir failed · `6` scanner present but switch failed ·
  `7` OPOS receipt-printer registration failed — including a **stale device that could not be
  retired** (the two-OPOS-printers state the retirement exists to prevent, `SubKeyCount` refusal
  included), a brand-switch key that could not be cleared, and a brand with **zero** devices ·
  `8` account precheck failed and was not
  overridden (not signed into a local admin account) · `9` account swap armed, rebooting to resume. `4`/`6`/`7` are non-fatal
  "re-run" codes that only set when nothing else failed — never masking `1`, and they live in
  **one** copy after the branch `if/elseif/else` (gated `-not $Uninstall`), printing after
  `Step 'Done'`: the config-only and install branches each used to carry their own and the wording
  had already drifted. `2`/`3`/`5`/`8`/`9`
  are pre-dispatch `exit`s, before the try/`$exitCode` machinery and before `Start-Transcript` —
  console-only, nothing logged to file. `9` is distinct from `8` on purpose: `8` means blocked and
  nothing was done, `9` means the box is coming back to finish itself, so an RMM must not dispatch.

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
  `COMPUTERNAME\shortname`. An undetermined verdict must **block**: the override below is explicit
  and recorded, so a probe that quietly fails open would be a *second*, invisible bypass — which is
  the one thing the design rules out. `-Uninstall` skips the check (a blocker there would strand a
  terminal that later acquired an MSA with no way to reverse the install); `-DryRun` reports and
  continues (it writes nothing, and it's how the tech gets the verdict before touching the terminal).
  **`Get-MicrosoftAccountId` is TRI-STATE** — email (MSA), `$null` (*proven* local), `'unknown'`
  (undetermined → `account-type-unknown` → block). It returned `$null` for both "proven local" and
  "every probe threw", and `$null` reads as "not MSA", so the least-trusted branch in the function
  (its `TODO[rig]` says neither probe was ever confirmed on a real MSA box) was also the only one
  failing *open*. `PrincipalSource` is asked first and believed both ways; the IdentityStore cache
  is the fallback, and its *absence* can't tell "local" from "this build doesn't populate it" — so
  that path is `'unknown'`, not a pass. That cache probe is **one** function, `Get-IdentityStoreEmail`,
  shared with `Get-MsaLinkedEmail`: it returns the email or `$null` and decides nothing, because it
  is the probe most likely to change and two byte-identical copies drift. Each caller maps "no
  answer" itself — `'unknown'` (block) for the verdict, a display string for the message.
  An Entra SID (`S-1-12-1-*`) with no `DOMAIN\` prefix gets
  its own arm: same verdict as before, but it used to report "no interactive user".
  `tests\Test-AccountPrecheck.ps1` lifts these functions out with the AST and stubs the probes, so
  every arm is checkable without a matching real account — the `-DryRun` print can only ever
  exercise whatever account happens to be signed in.
- **Precheck override (`Set-AccountCheckOverride`)** — the block is overridable but never silently:
  `-IgnoreAccountCheck` (unattended) or a `y` at the continue-anyway prompt (interactive, offered
  *after* a declined swap and on the loop-guard arm, which otherwise has no way forward). Every
  verdict is overridable, including `microsoft-account`. Traps:
  - **`-IgnoreAccountCheck` is tested FIRST**, before `-DryRun` and before the offer: an RMM run
    must never reach a `Read-Host`, and `-DryRun -IgnoreAccountCheck` should report what the real
    run would *do* (continue), not an offer it would never make. Same reason **`$wouldOffer` is one
    expression** read by both the preview and the real dispatch: the two used to disagree, so the
    dry run promised an offer the real run refuses. Same doctrine for the promote-vs-create test —
    one expression, passed **into** `Invoke-AccountSwapOffer` rather than recomputed there beside
    the preview's byte-identical copy. It excludes the loop guard, and it excludes
    **`service-account`** — nothing about the *account* is wrong there, so having the tech type a
    new admin password "fixes" a run whose only fault was having no console session (that verdict
    is excluded from the printed remediation for the same reason).
  - **The prompt reuses `Confirm-Swap`** — it already defaults to NO and its `Read-SwapAnswer` is
    try/catch'd, so a headless host reads as "no" and still exits 8. Don't add a second prompt
    helper, and don't give it a default of yes.
  - **The override is manifested (`accountCheckOverride`, record-only, `removable=$false`)** because
    the whole precheck runs *before* `Start-Transcript` — the console warning lands in no log, so
    that row is the only durable trace that a terminal was installed over a failed verdict. Merged
    on **`whenUtc`**, not the account: each override is its own event, and a later clean re-run must
    not erase the record of the run that skipped the check.
  - The full remediation text still prints on every path. The override changes what happens *after*
    the block is reported, never whether it is reported.
- **Account swap (`Invoke-AccountSwapOffer`, exit 9)** — on a block, an interactive run offers to
  create or promote a local admin, then reboots and resumes itself. Self-contained by necessity:
  it sits *above* `$WorkDir`, `$Manifest` and `Set-TrackedRegValue` in a top-to-bottom script, so
  raw cmdlets only, and the facts reach the manifest via the `account_swap.json` marker
  (`Clear-AccountSwapState` → `$script:AccountSwapDone` → `New-InstallManifest` seeds
  `accountCreated`). Traps:
  - **The `not-admin` path arms NO autologon.** Reaching that arm already proves the account is
    local and non-MSA, so promoting it in place is one `Add-LocalGroupMember` and the tech types a
    password they already know. Only the create path handles a secret, because only there do we
    have one.
  - **`AutoLogonCount=1`, not an LSA secret.** Winlogon deletes `AutoAdminLogon`/`DefaultPassword`/
    `AutoLogonCount` itself when the count hits 0. The LSA-secret route (Sysinternals Autologon) is
    unreadable but has **no auto-clear**: a resume that never runs leaves the terminal auto-logging
    in as an admin forever. Self-clearing beats unreadable here. It is written **FIRST**: it is the
    entire self-clearing mechanism, so written last a throw partway through left a *countless*
    autologon — permanent auto sign-in with a cleartext password — on a run reporting exit 8,
    "blocked and nothing was done". Prior values are captured into the marker (their registry
    **kind** too, via `GetValueKind()`: an OEM or Sysinternals box can carry `AutoAdminLogon` as
    REG_DWORD, and recreating it as REG_SZ is not the pre-swap state the restore claims) and
    replayed by `Restore-AutoLogon` — deliberately **not** manifested, or a later `-Uninstall`
    would "restore" autologon onto a live terminal.
  - **Reboot, never `shutdown /l`.** `AutoAdminLogon` doesn't fire after a logoff without
    `ForceAutoLogon=1`, which is sticky in exactly the way this design avoids.
  - **The resume task runs as the target user, `Interactive` + `RunLevel Highest` — not SYSTEM.**
    SYSTEM has no visible console, and step 0 is interactive; those `Read-Host`s are try/catch'd,
    so under SYSTEM they'd silently take defaults and the terminal would get the wrong computer
    name and possibly the wrong printer driver. `Interactive` also needs no stored credential.
    `ExecutionTimeLimit` must be `[TimeSpan]::Zero` — `Register-FinishLogonTask`'s 5-minute limit
    would kill a full install mid-run. It targets a **copy** of the `.ps1` under `$WorkDir`,
    because the `.bat` deletes its decoded temp copy on exit. `ConvertTo-ResumeArgs` drops
    **`NiceLabelLicense`** as well as `DryRun`: a task action is persisted, readable by any standard
    user (`schtasks /query /xml`) and outlives the run — the exposure `$safeArgs` redacts
    everywhere else. `param()`'s default hands the key back on resume.
  - **`$script:AccountSwapAttempted` is the loop guard**, set by `Clear-AccountSwapState` whenever a
    marker existed. Without it a resume landing on a still-wrong account offers another account,
    arms autologon again, and reboots — every cycle, forever. `Clear-AccountSwapState` runs in
    **every** mode (`-Uninstall` included, which skips the precheck itself) so a stranded marker is
    always cleaned — **except `-DryRun`, which reports and returns.** The `.bat` self-elevates, so
    a tech who armed a swap and then dry-ran to re-check the verdict had the dry run succeed at
    disarming it: autologon restored, resume task unregistered, marker deleted, box reboots into
    the old account with nothing left to finish. It still sets the loop guard.
    Each of its steps is guarded separately, and **the `Unregister-ScheduledTask` sits OUTSIDE
    the `if ($m)`**: the task name is a constant and never needed the marker, but while it lived
    inside, an unreadable marker (power-off mid-write) skipped the unregister while the marker
    was deleted anyway — the resume task then relaunched the installer at every logon, forever,
    with the only record of it gone. **The unregister is VERIFIED, not assumed** (`Get-ScheduledTask`
    after it): everything past that point destroys the ability to retry — the marker is the only
    thing that brings this function back and the staged copy is the script the task launches — so
    a task that survived keeps both, and only autologon is restored unconditionally, because
    *that* is the piece that must never stay armed.
  - `Confirm-Swap` defaults to **NO** and `Read-SwapAnswer` catches (F14): consent to create an
    account and reboot must never be inferred from a headless host's empty read.
  - **The resume staging is the `$rollback`'s first customer, so it is defined below it.** Staged
    *above* it, with nothing to call, a failed `Copy-Item` landed on exit 8 leaving directories
    under `%ProgramData%` on a box the precheck had just refused — the one thing the ordering
    exists to prevent. The rollback removes those parents **only while empty**, non-recursively:
    on a re-run they are the working root — and its `Get-ChildItem` is `-ErrorAction Stop`, or the
    guard fails **open** (under `'Continue'` an unreadable directory returns nothing, `-not $null`
    reads as empty, and the non-recursive `Remove-Item` walks into the `ShouldContinue` prompt the
    test exists to avoid). Its `Unregister-ScheduledTask` is `-EA Stop` + a `Get-ScheduledTask`
    readback, like `Clear-AccountSwapState`'s and for a worse case: this rollback runs when the
    **marker write** failed, so a surviving task has nothing to bring `Clear-AccountSwapState` back
    and no record on the box — it relaunches the installer at every logon, forever. The readback,
    not the unregister's own exception, is the verdict: the rollback also runs before the task was
    ever registered, where `-EA Stop` throws the outcome we want.
  - **"Already a member" is matched on `FullyQualifiedErrorId`, never the message text** — the
    message is localized, so on a non-English Windows `-notmatch 'already a member'` fired on a
    promotion that had *succeeded* and rolled the whole swap back. `Test-LocalAdminSid` dodges the
    same trap by resolving the group from `S-1-5-32-544`.
  - `accountCreated` is `removable=$false`, like the rename / TeamViewer removal. `-Uninstall` must
    never delete it — the terminal is signed into it and its Documents holds the `.nlbl`.
- The master list is a `.nlbl` — copy **as-is, never unzip** (the "encryption" is NiceLabel's
  internal format); copied into every real user profile's Documents (`Get-TargetUserProfiles`).
  That enumeration means "a human who will use this terminal", not "a domain-shaped SID": **RID ≥
  1000**, and no `.bak` keys. `S-1-5-21-*` alone also matches Guest (501), `DefaultAccount` (503),
  `WDAGUtilityAccount` (504) and OEM `defaultuser0` — each was collecting a taskbar layout *and* a
  copy of the master list — and Windows renames a broken profile's key to `<sid>.bak` while
  creating a fresh one pointing at the **same** directory, so accepting both writes everything twice.
  A profile whose `Documents` is missing is checked for a **OneDrive Known-Folder-Move**
  redirection (`<profile>\OneDrive*\Documents`) first: creating the plain path there manufactures a
  *decoy* the `.nlbl` lands in, `[OK]` prints, and NiceLabel never sees the master list. A directory
  the step did have to create is recorded in `filesPlaced` (after the `.nlbl` — uninstall step 1
  walks the list in order), so **`filesPlaced` can hold a DIRECTORY**; step 1 skips one that still
  holds someone else's files, **uncounted**, because a folder holding the user's documents is the
  right outcome, not a reversal failure.
- NiceLabel's uninstall verdict covers its **services, its own ARP key, the low-level Windows
  Installer registration and its program files** — not just the product. `sc.exe delete`'s exit code
  is the only answer available (it writes failures to *stdout*, so the old `2>$null` suppressed
  nothing and the green "removed NiceLabel service" line printed over 1072 `MARKED_FOR_DELETE` and
  5 alike — the same trap the orphaned-CoreScanner `sc.exe delete` reads `$LASTEXITCODE` for), and
  the sweep of `Classes\Installer\Products`, its `Features` sibling, `UserData\S-1-5-18\Products`
  and the `%ProgramData%\{GUID}` cache is `-ErrorAction Stop` and counted. Residue is checked
  **first**: neither authority after it (msiexec's exit code, the ARP re-scan) can see a deferred
  service, an orphan key or ~900 MB of Suite files, so a survivor fails the pass here or
  `-Uninstall` exits 0 with NiceLabel still registered.
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
    non-fatal); no scanner attached = benign Warn, exit 0. **`Confirm-ScannerServicesReady`'s
    verdict is used, never discarded**, at both call sites: a CoreScanner that is not Running is
    the one condition the 112 retries cannot fix (all they do is re-run that same check), so it
    bails with `result='rsm-unavailable'` + exit 6 instead of spending the retry budget and a 40 s
    re-enumeration ceiling per hop. Hop 2 carries hop 1's short-circuit and status `Warn` too —
    without them a hop-2 112 returned `fail` having printed nothing about `$st2` — and **both** hops
    short-circuit on a NEGATIVE status too: `-1` means `ExecCommand` threw, the same evidence that
    the command never reached the scanner. Hop 1 bails when the device is provably **still in
    HID-KB** afterwards, rather than falling through to the one switch the SDK documents as illegal
    (HID-KB → OPOS direct), where the failure reported would be hop 2's. And no re-enumeration after
    hop 2 is `fail`, not `ok`: a unit in USB-OPOS enumerates as `USBOPOS`, so silence is positive
    evidence the switch is unconfirmed.
  - **Every bail records a `scannerConfigured` row, the outer catch included** (`result="error: …"`,
    exit 6): a blocked Interop DLL (its path comes from `$env:ProgramFiles`), an unregistered COM
    class or an `Open()` against a dead service all throw before the device loop, and an empty
    `scannerConfigured` is indistinguishable from a step that never ran. `-SkipScannerConfig` and
    the `$script:ScannerDegraded` bail record theirs too (`skipped:flag` / `skipped:degraded`),
    matching the printer step's invariant. `Open()` is paired with `Close()` in the `finally` — `ReleaseComObject`
    drops our RCW but leaves the application session registered with the service.
  - **An enumeration *failure* must not look like an empty terminal.** `Get-CoreScannerInventory`
    sets a distinct NEGATIVE `$script:ScannerInventoryStatus` for a malformed `OutXML` (`-2`) and
    for "GetScanners reported N but nothing parsed" (`-3`, the `[ref] $count` that was never read);
    each node parses under its own try, so one node missing a `<scannerID>` no longer discards the
    scanners already parsed. An empty list with status **0** takes the benign `no-scanner` arm — no
    flag, exit 0 — with a scanner physically attached in HID-KB.
  - Per-mode PIDs, hop/settle timing, retry counts, and post-switch verification are rig-dependent
    (`RIG-DEPENDENT` / `TODO[rig]` in `Set-ScannerOpos`; `Get-ScannerHostMode` / `$ScannerServiceNames`
    hold current values — read those, don't copy them here). Confirmed on DS2208; other models and a
    real in-session 112→recovery run still pending — capture with `-ScannerConfigOnly
    -ForceFingerprint` (forces the `Write-NewScannerFingerprint` dump for an already-known model;
    lands in `logs\`), log to `docs/` (running table in `docs/SCANNER_OPOS_RIG_VALIDATION_PROMPT.md`).
    The dump also fires on a **blank** model, under an `unknown-model` placeholder: a HID-KB start
    reports blank until a hop re-enumerates the unit, so gating it on a non-empty model wrote
    nothing in exactly the documented rig case — an unvalidated family in factory HID-KB whose hop 1
    fails — and `-ForceFingerprint` was silently ignored there. The `newModel` **flag** still needs
    a reported model that misses the regex; a blank one proves nothing.
  - `$ScannerKnownModels` (which models skip the new-model fingerprint dump) is a **family regex**,
    not a list: CoreScanner's `<modelnumber>` is the full kit/config SKU (`DS2208-SR7U2100SGW`),
    never the bare family name, so it's matched with `-notmatch` on the prefix. Add families with
    `|`; keep it non-empty (`''` matches everything and silences the dump).
  - `scanner/Scanner_OPOS_barcode.pdf` is the no-PC fallback (one scan from the HID-KB default — the
    two-hop is only the SDK path's constraint). A doc deliverable, **not** embedded, so it needs no
    `.bat` rebuild.
- **Receipt printer (`Set-PrinterOpos`)** — the LAST functional step, and unlike the
  scanner it is **pure registry**: no COM, no polling, and it works with nothing plugged in
  (`Open()` returns 0 on a bare bench). Full evidence in `docs/PRINTER_OPOS_FIELD_RESULTS.md`.
  **Brand-driven** via `$PrinterBrands` (`POS-X` · `StarTSP100` · `None`), each brand naming
  its `RowName` (the `$Installers`/`$DriveFiles` row), its `ArpPattern` (the driver's ARP
  DisplayName), and a **device array**. Read that table — don't copy its values here.
  Key traps:
  - **Neither vendor ships OPOS automation, so writing the registry IS the supported path,
    not a workaround.** POS-X's `SetupPOS.exe` is only a GUI over the registry. Star is worse:
    futurePRNT's manual (§4.1.1) states verbatim that the Configuration Utility's XML
    export/import **excludes OPOS** (and JavaPOS, serial ports, Star Cloud); its tool
    (`TSP100ControlPanel.exe`) is GUI-only with no `/add` switch and no importable XML.
    JavaPOS gets a `jpos.xml` generator; OPOS does not. Don't go looking for one again.
  - **How many devices is PER BRAND, not a global rule.** POS-X = one; Star = two.
    - *POS-X:* the cash drawer has **NO** device entry (dropped 2026-08-12; the
      `CashDrawer`/`StandardU` element and its 33 values came out). It hangs off the printer's
      RJ-11 and `Standard.CashDrawer.SOU` resolved to the printer's own `POSPrinterSOU.dll`
      anyway, so it follows the printer via the printer key's **`DrawerOpen=1`** — SetupPOS's
      *Open CashDrawer* = *Follow Printer*. That combo has exactly two items, `CashDrawer` (0)
      and `Follow Printer` (1); driving it and diffing `OLEforRetail` changed **only** that one
      value. `Thermal.inf`'s `[UOPTION]` default is `0`, so this is the one shipped value that
      deliberately differs from the vendor default — still captured, not authored.
    - *Star:* has **no equivalent of that flag**. Its drawer is a separate `CashDrawer` OPOS
      device with its own LDN and settings (drawer number, pulse width, polarity) — which is
      why the device **array** came back after the 2026-08-12 flattening. Its LDNs are the
      utility's *Logical Device Name* (`Configure → Add New`), not the device name `Add New`
      creates; register the common **OPOS CCO**, not Star's own CO (vendor recommendation, and
      POS for .NET's legacy bridge wraps a registered CO/SO).
  - **Star's four value tables are EMPTY (`TODO[rig]`) until the bench capture lands.** The
    `$uncaptured` guard in `Set-PrinterOpos` tests `Strings.Count`, `DWords.Count` **and
    `Strings['(default)']` by name**, and returns `result='not-captured'` + exit 7. All three: a
    filled `$StarPrinterStrings` beside a still-empty `$StarPrinterDWords` passed a Strings-only
    test with both DWord loops iterating zero times, and `(default)` — the ProgID, the one value
    OPOS mandates — is the one the readback can never catch itself, since it iterates
    `$dev.Strings.Keys` and never looks for a key missing from the transcribed table (`progId`
    lands `$null`, the console prints `… -> `, the step reports `ok`). Without it the write loops iterate zero times, the
    readback loops verify nothing, and the step reports `ok` after creating an **empty device
    key** — a phantom device plus a false success. Never "stub" those tables with plausible
    values; that guard is the only thing standing between a stubbed build and a silent lie.
    A brand with **no devices at all** needs its own test beside it (`$noDevices`): an empty
    pipeline yields no matches, so it slipped past `$uncaptured`, the device loop iterated zero
    times, `$allOk` stayed `$true`, and a full install landed on the trailing "nothing registered"
    `Warn` and exited **0** under a green banner having registered nothing. Count it **filtered** —
    `@($null)` is an array of one `$null`, so a missing `Devices` key counts as one device — and
    that trailing `else` now sets `$script:PrinterConfigFailed` unconditionally.
  - **The device values are CAPTURED, never authored.** They came from diffing a real
    `SetupPOS.exe` run (28 printer values). Deriving them from `Thermal.inf` gives a subtly
    wrong key — `Description` and `PortShare` are in neither section of it. If the package
    version bumps, re-capture; don't hand-edit.
  - **The logical device name is per-terminal**: `<POSname>` + the device's `Suffix`, built
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
    A retired device's `printerConfigured` / `regValuesSet` / `regKeysCreated` rows are
    deliberately **left to merge forward** — but that is only tolerable *because* uninstall step
    4b now skips a value that is already gone and refuses to `New-Item` a key back just to restore
    into it. It was never automatic: `Test-Path` covered `regKeysCreated`, while
    `Remove-ItemProperty` on a retired device's path **throws**, `-ErrorAction Stop` fed it to the
    counting catch, and ~27 phantom "reversal failures" made every decommission after a rename
    exit 1 forever — while a `prevAbsent=$false` row's restore arm *recreated* the retired key,
    resurrecting the phantom device the uninstall exists to remove.
  - **POS-X and Star share both `Class` (`POSPrinter`) and `Suffix` (`_Printer`)**, so on a brand
    switch the key path is byte-identical and nothing else notices: `Remove-StalePrinterOpos` reads
    the same LDN as "this run's own name", and the write and readback loops only ever touch the
    *new* brand's value names, so neither looks for values that shouldn't be there. The step printed
    `ok` on a key that was half POS-X and half Star (stale `ADKConfig` / `DrawerOpen` / `PortShare`).
    `Set-PrinterOpos` therefore clears the key first when the **prior manifest** records a different
    `brand` for that logical name — gated on that record rather than deleting unconditionally, which
    would throw away the `prev` state captured for a key a manual `SetupPOS` run created. Same
    `SubKeyCount` guard as the stale-device removal; a failed clear still writes the new values (a
    mixed key beats no key) but sets `$script:PrinterConfigFailed`, since exit 7 is the only thing
    that tells the tech to look — **and stamps the PRIOR brand on that device's manifest row**, or
    exit 7's own remediation cannot fix what it reports: `printerConfigured` merges current-wins on
    `logicalName`, so the new brand made the advised `-PrinterConfigOnly` re-run read `$wasBrand` as
    the new brand, find no mismatch, attempt no clear, and report `ok` / exit 0 on a key that stays
    half POS-X forever. `-DryRun` **previews** the clear — the one destructive, un-rollback-able
    step here, and the preview showed only "would register" and "would remove stale device".
  - **The driver must be present before the entry is written** (`Find-InstalledProducts
    -Pattern $brandDef.ArpPattern`, skipped under a **full-install** `-DryRun` only — under
    `-DryRun -PrinterConfigOnly` the check still runs, because nothing installs anything in
    that mode and a preview that "registers" devices the real run would decline is a preview
    of the wrong run): otherwise the step registers a
    device pointing at a DLL that isn't there. Check ARP, **not** the ProgID — the vendor uninstaller
    leaves the whole ProgID → CLSID → InprocServer32 chain behind (measured), so a ProgID test
    reports "installed" on a box where the DLL is long gone. Driver absent is a benign
    `result='no-driver'` skip, exit 0 — returning **before** `Remove-StalePrinterOpos`, like `None`
    but for its own reason: with the driver gone there is nothing to register in place of a stale
    `<OLDNAME>_Printer`, so retiring it would leave *no* OPOS printer on a box whose driver an
    operator may simply be reinstalling. `-Uninstall` is what removes those rows. An unknown brand
    (a build error — a brand added to `$PrinterBrands` or the prompt, not both) records
    `result='fail: unknown brand'` but raises the flag only when **not** `-DryRun`.
  - **A device row has NO `Type`/`ProgId` field.** Both used to sit in `$PrinterBrands.Devices`
    duplicating `Strings['DeviceName']` and `Strings['(default)']` — never written, never
    verified by the readback, free to drift. Star was already drifted by construction (both
    `''`), so filling only `$StarPrinterStrings` after the capture would have printed
    `OPOS POSPrinter: POS01_Printer -> ` and manifested `progId=$null`. One source: the
    `Strings` table.
  - **Readback compares EVERY value by name AND tests `$null` separately.** `"$null"` is `''`,
    and **seven of the fourteen POS-X strings are legitimately `''`** — so a plain
    `"$got" -cne "$expected"` compared `''` against `''` and *passed* for a value that was never
    written at all, blinding the check for half the table. `$null -eq $got -or …`, mirroring the
    DWord loop. One layer lower, `Set-TrackedRegValue`'s own `New-ItemProperty` is now
    `-ErrorAction Stop` with the manifest row recorded *after* it — the root cause, fixed once
    for every caller; the printer step's per-device catch turns the throw into exit 7, which is
    the code that failure is supposed to produce.
    `$ErrorActionPreference` is `'Continue'`, so before that a failed `New-ItemProperty` was
    non-terminating and `Set-TrackedRegValue` recorded a value it never wrote. A value **count**
    cannot catch that on a key that already holds the full set — i.e. on every re-run and on every
    terminal deployed before the table changed, which is exactly when it matters: `DrawerOpen`
    0 → 1 silently not applied, reported `ok`, drawer never kicks. `(default)` is a `Strings`
    member, so it is covered by the same loop — but it must be READ as `GetValue('')`.
    `(default)` is an alias only the `*ItemProperty` cmdlets accept; `GetValue('(default)')`
    hunts for a value literally named that, finds none, and returns `$null` — which failed the
    readback on the first key of every run (all 28 values written correctly, step still
    reported `fail` + exit 7). Same alias trap as the uninstall path's `DeleteValue('')`.
  - **Register first, retire stale devices after — and all-or-nothing.**
    `Remove-StalePrinterOpos` runs *after* the registration and is passed only the LDNs that
    actually verified. Deleting first meant a failed write (exit 7, "re-run with
    `-PrinterConfigOnly`") left the terminal with **no** OPOS printer where it had a working one
    under the old name a second earlier — and the delete has no rollback. With more than one
    device the same reasoning goes further: `-Registered` is a **whitelist**, so passing a
    *partial* list after one device failed would delete the prior run's copy of the very device
    that just failed to be replaced. If any device fails, skip the call entirely. It also
    applies the uninstall path's `SubKeyCount` guard: a non-recursive `Remove-Item` on a key
    with children raises `ShouldContinue`, which prompts on an interactive host and *throws* on
    an RMM one, silently defeating the removal — and that refusal is **counted, not silent**:
    the function returns the number of stale devices still standing and the call site turns a
    non-zero count into `$script:PrinterConfigFailed` → exit 7. A survivor *is* the
    two-OPOS-printers state (Alleaves can open the dead `<OLDNAME>_Printer`), so reporting exit 0
    would tell the RMM the advertised rename fix landed when it did not — and exit 7's own
    remediation, re-run with `-PrinterConfigOnly`, is exactly the retry that fixes it.
  - **Each device gets its OWN try/catch, and each catch sets `$script:PrinterConfigFailed`.**
    A shared catch means the printer's failure skips the drawer entirely. And that flag — *not*
    the config-only branch's `$changed` floor — is what produces exit 7 on a **partial** failure:
    with one device of two written, that floor sees a change and stays quiet.
  - `Remove-StalePrinterOpos`'s `-Registered` is **`[Parameter(Mandatory)]`**. Its old default
    rebuilt the single expected LDN from prefix + suffix, which stopped being expressible once a
    brand can register several devices — and a caller that forgot the parameter would have
    silently retired every device but one. The `-DryRun` path passes the names it *would*
    register, so the preview retires exactly what the real run would.
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
    unattended stretch, not at step 5b. **Step 0b skips every brand's row except the chosen
    one** (`$SkipPrograms += $PrinterBrands[$b].RowName`), reusing the *existing*
    `Test-SkipMatch` to drop those rows from both the download and install phases — which is
    why the prompt has to run before the download phase, and why each brand's `RowName` must
    equal its `$DriveFiles` **Label** and `$Installers` **Name**. Picking POS-X must not drag
    down 471 MB of Star payload, and vice versa. `None` is not a key, so it skips them all and
    the old behaviour falls out for free; `Set-PrinterOpos` then returns `result='skipped'`,
    returning *before* `Remove-StalePrinterOpos` — None is a skip, not a retro-uninstall.
    **Every bail records a `printerConfigured` row**, `-SkipPrinterConfig` included
    (`result='skipped:flag'`; `brand` is `-PrinterBrand` *as given*, empty when it wasn't, since
    the flag suppresses the prompt) — a missing row could not tell "the tech suppressed it" from
    "the run died before step 5b".
    ⚠️ **`-SkipPrinterConfig` with no `-PrinterBrand` falls back to `'POS-X'`, not empty.**
    That flag only means "don't write the OPOS entry" and it deliberately suppresses the
    prompt, so there is no answer to read. Leaving the brand empty made the loop skip *every*
    brand (no driver installed at all); dropping the loop for that case made it skip *none*,
    putting 471 MB of Star on terminals that only wanted to suppress a registry write. POS-X
    is `Resolve-PrinterBrand`'s own default, so the fallback reproduces exactly what
    `-SkipPrinterConfig` did before a second brand existed.
    Rejected with `-PrinterConfigOnly` for the same reason
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
  `TaskbarApplied` value holds the pin list **plus a deployment generation**
  (`$script:TaskbarStamp` = `$pins + $gen -join '|'`, where `$gen` is one
  `HKLM:\SOFTWARE\AlleavesAuto\TaskbarGeneration` value written through `Set-TrackedRegValue`
  — so `-Uninstall` removes it for free and the next install mints a new one, while a plain
  re-run reuses it and does **not** gratuitously wipe pins the cashier added). The pin list
  alone was not enough across an uninstall/reinstall: the cashier's hive is normally not
  loaded when the tech installs, so their SID is not in `taskbandBackups` and step 4d never
  reaches their marker — it survives, the reinstall produces a byte-identical stamp, and the
  pins never come back),
  because clearing `Taskband` + restarting Explorer is the only thing that makes Explorer
  re-read the XML — so a boolean "already applied" made every later pin-set change
  invisible to a terminal that was already deployed (it kept the old pins forever, only
  recoverable by uninstall/reinstall). A deployed box holds the old DWORD `1`, which never
  equals a stamp, so it re-applies once and settles; compare as strings and write with
  `New-ItemProperty -Force -PropertyType String` (`Set-ItemProperty` would try to coerce
  the string into the existing DWORD). A generation that could **not** be persisted must not be
  used: `$gen` still holds the timestamp minted a line earlier, and building the stamp from a value
  that reached no disk means the next run mints a different one — inverting the generation's whole
  job (stay stable across plain re-runs) into "clear the cashier's `Taskband` and restart Explorer
  at every logon after every run". Reuse the prior manifest's recorded generation instead, and with
  none to reuse say that consequence out loud. `$script:FinishTaskbar` is set **only if at least one
  per-user XML actually landed** — arming the task with no layout on disk is pure
  destruction (it deletes the cashier's pins and ours never appear).
  **No path in this area is hardcoded to `C:\`.** `$StartMenuAll` comes from `%ALLUSERSPROFILE%`
  (its twin already did, and the pair drifting from the *machine* puts the `.lnk` at one path while
  the XML pins another) and the Default-profile XML from `ProfileList\Default`. `Write-XmlFile`
  creates the whole directory chain, so on a relocated-profiles or non-`C:` box a hardcoded path
  *manufactures* a junk tree, prints `[OK]`, adds it to `filesPlaced` — and every brand-new cashier
  profile still gets no layout.
  **`Write-XmlFile` backs up only SOMEONE ELSE'S `LayoutModification.xml`, and "ours" requires that
  no ORPHANED backup row exist** — in *both* halves of the test. `-Uninstall` restores by
  `Move-Item`, which **consumes** the `.alleaves-orig`, and never rewrites the manifest; with that
  check on the `filesReplaced` half only, the `-or` short-circuited past it on the `filesPlaced`
  half, so the reinstall took no new backup and destroyed the just-restored OEM layout for good. An
  unreadable prior manifest can't answer "is this ours?" at all — `$script:PriorManifestUnreadable`
  skips the backup block entirely, or it records **our own** layout as the OEM original.
  **A pinned `.lnk` lives in TWO places.** Applying the layout makes Explorer *copy* the shortcut
  into each user's `…\Quick Launch\User Pinned\TaskBar`, so `filesPlaced` — which only knows the
  all-users source — leaves a pin pointing at a deleted exe (measured: survived a full
  `-Uninstall`). Uninstall step **4e** deletes `$TaskbarPinNames` from every profile's pinned
  folder; that list exists so install and uninstall can't drift, and it is an **exact** name match
  so another vendor's pin is never removed.
- **The per-user finish logon task** (`Register-FinishLogonTask` + the generated finish script):
  - `Register-ScheduledTask` needs **`-ErrorAction Stop`**, like every other task cmdlet here. It
    is a CIM cmdlet, so under `'Continue'` a refused registration (policy, a locked Task Scheduler
    store) skipped the catch, printed "registered", wrote a `scheduledTasksCreated` row for a task
    that doesn't exist, left `$FinishFailed` clear and exited 0 — and a later `-Uninstall` then
    failed to unregister the phantom and exited 1. So do the four `New-ScheduledTask*` builders
    that feed it: the register alone was not enough, because a nulled **principal** registers a
    task that runs as the *tech* — whom the finish script skips by design.
  - The finish script is written **with a BOM**, unlike `Write-XmlFile`'s XML (which declares its
    own encoding). PS 5.1 decodes a BOM-less `.ps1` as ANSI, and two machine values are baked into
    the body — the install user and the taskbar stamp — so a non-ASCII tech account name mojibakes
    both: the `$env:USERNAME -eq $installUser` test fails (the finish runs *for the tech*) and the
    stamp never matches its marker, re-clearing the cashier's pins at every logon, forever.
    `$installUser` is **blank** whenever an account was swapped in — this run's `accountCreated`
    **or the prior manifest's**, since this runs inside `Register-FinishLogonTask`, before
    `Save-Manifest` merges the prior row forward. The resume runs the installer *as* the account
    that will run the POS, and so does a later re-run by a tech signed into it (it is the terminal's
    only admin, which is the point of the swap) — baking that name in disabled the finish for the
    one profile that matters.
  - `Disable-TrackedTask` looks the task up with **`SilentlyContinue` + an explicit absence test**,
    never `-Stop`: the caller gates on the UCPD *service* key while what is disabled is the UCPD
    velocity *task* — separate objects that merely shipped together — so on a box where the task was
    pruned (debloat script, custom image) `-Stop` made "does not exist" terminating, it landed in
    the same catch as a refusal, and a healthy install exited 1. Only the `Disable` is a failure.
  - **Chrome's ProgId is resolved at logon from HKCU**, with the install-time HKLM value only as a
    fallback: a per-user Chrome registers a *suffixed* ProgId (`ChromeHTML.XXXXXXXX`) the
    installer's machine-wide probe can't see, and a well-formed UserChoice for a ProgId that
    doesn't exist still verifies `OK` while links keep opening Edge. Same self-confirming readback
    as the **minute roll**: Windows validates the hash against the key's `LastWriteTime` truncated
    to the minute, and four registry ops run between building it and the last `SetValue` — so
    re-check the clock and rebuild rather than confirm a hash Windows will silently reject.
- The four `Invoke-IssSilent` overrides (`ArgFormat`, `WaitNames`, `ReapNames`,
  `RegistryShortCircuit`) all **default to the original Zebra behaviour** — only a row that opts
  in changes anything, which is what keeps the validated Zebra path byte-identical. `ArgFormat`
  is a whole format string rather than a prefix because InstallShield rejects a line mixing `-`
  and `/` switch styles. `RegistryShortCircuit=$false` is mandatory for pure InstallScript:
  `DeinstallStart()` writes the ARP entry *before* file transfer, so the "in the registry ⇒ done"
  break would kill the worker mid-copy and record success. **The ARP test lives in the poll loop's
  NO-WORKERS branch**, not as its first statement: as the first statement it fired on the very
  first poll of a *repair* run — a prior run that failed after InstallShield wrote the ARP entry,
  which is exactly when `Test-PriorInstallFailed` declines the ARP skip and re-runs the installer —
  and the `break` fell straight into the `$ReapNames` sweep, force-killing the live `setup.exe`
  and then recording `ok`. ARP presence only means "committed" once nothing of ours is still
  running — and the wait needs **two consecutive idle polls** once a worker has been seen: one empty
  poll ended it on the momentary gap where `setup.exe` finishes MSI #1 of the Zebra chain before
  spawning MSI #2, force-killing the live workers and dropping into the fallback, a second installer
  over the first. The "is a worker busy" **msiexec** clause is gated on `$RegistryShortCircuit` (the
  flag that already means "MSI-backed family"): unconditional, a pure-InstallScript row (OLE POS
  Setup, no msiexec in the package at all) was pinned the full 900 s by an unrelated Windows Update
  msiexec — and the verdict then fired the moment *that* process ended. `Get-EmbeddedIss` verifies
  the response file landed and throws if not: a .NET write exception is statement-terminating only,
  so under `'Continue'` a failed write handed InstallShield an `/f1` pointing at nothing, which does
  **not** run silently — it falls back to interactive on a hidden window.
  **`RegistryShortCircuit` also gates the
  SUCCESS VERDICT**, not just the poll loop: the verdict is `$logOk -or ($regOk -and
  $RegistryShortCircuit)`, so a `$false` family must show `ResultCode=0` in the response log
  (reachable — `/f2` forwarding is proven). Without that, a half-copied install was
  recorded `ok` and `Set-PrinterOpos`'s ARP driver guard then passed too, registering a device
  aimed at a DLL that was never copied. **Only a log THIS launch produced counts** — its
  `LastWriteTime` is compared to `$launchTime`. The pre-run delete is best-effort by necessity
  (`SilentlyContinue`), so a log held open by a crashed helper or an AV scanner survives it, and
  reading the survivor served up the *previous* run's `ResultCode=0` — the entire verdict for a
  `$false` family, handed to a PFTW stub that access-violated and wrote nothing.
- **Star TSP100 futurePRNT is a RAW-EXE row, not an `Iss` one.** The package is InstallShield
  **Basic MSI** (`extract_all` / `IsConfig.ini` / `MsiExec` in its strings), a different animal
  from the POS-X PFTW/IS5 InstallScript stub, so **none** of the `Iss*` override machinery
  applies. `Args=@('/s','/w','/v"/qn /norestart"')`: `/s` and `/v"…"` are documented verbatim by the
  vendor (`Readme_En.txt` §3) — `/s` silences the InstallShield **launcher**, `/v"…"` forwards to
  the **inner msiexec**, and *both* halves are required, `/s` alone still shows the MSI UI. **`/w`
  is ours and mandatory**: without it the Basic MSI launcher returns immediately instead of waiting
  and returning the inner msiexec's code, so `-ConfirmRegistry` read ARP while the MSI was still
  copying and the row failed forever. Author it
  **single-quoted**; a double-quoted PowerShell string loses the inner quotes to the parser, and
  `Start-Process` joins the array with a plain `Join(' ')` and adds no escaping, so it arrives
  intact. Match on the ARP **DisplayName**, never the ProductCode — it changes every release
  (7.1.0 / 7.4.0 / 7.5.1 / 7.7.0 all differ). Uninstall needs no new code: the generic
  `msiexec` dispatch already normalises `/I`→`/X` and appends `/qn /norestart` — which is also why
  the row carries no `UninstallMatch`: it duplicated `Match` and a raw-exe row never reads it.
- **Two row fields exist for that one product**, both opt-in so every other row is unchanged:
  - `Zip` / `ZipMember` — the download is the vendor's whole 471 MB CD image and the installer
    is one member inside it. `System32\tar.exe` (bsdtar) extracts **that member only**;
    `Expand-Archive` would unpack all 471 MB, and **Git's `tar` is GNU tar and cannot read zip
    at all**. No `--strip-components` — the member keeps its stored path under `$DownloadDir`,
    which holds however bsdtar treats strip on zip. Untracked and never cleaned up, the same
    treatment the Zebra wrappers get (`$DownloadDir` survives `-Uninstall` by design). Costs
    ~600 MB of cache; re-extracted every run, which is cheap beside the download it came from.
  - `SkipIfInstalled` — the raw-exe branch had **no ARP short-circuit at all**, so a raw-exe row
    replays its installer on every run. Tolerable for Chrome's 1.3 MB stub, not for a 111 MB
    MSI-backed installer. Opt-in rather than blanket so Chrome and NiceLabel keep their
    validated behaviour byte-for-byte (NiceLabel in particular re-runs to re-apply its license
    code). It consults `Test-PriorInstallFailed`, same as the MSI/`.iss` guards.
- **The download path already handles 471 MB, and Drive's `confirm=t` is enough.** Don't
  "fix" it. `Invoke-FileDownload` is **BITS → `WebClient.DownloadFile`**, never
  `Invoke-WebRequest -OutFile` (which on PS 5.1 buffers the whole body in memory) — the comment
  above it says so. Measured 2026-08-28: the `confirm=t` URL `Get-DriveFile` builds returns
  `206 / application/octet-stream / Content-Range: bytes 0-0/493881478` for the Star zip — no
  virus-scan interstitial, **no `uuid` parameter needed** — and `Get-RemoteLength`'s
  `Content-Range` branch reads the total, so the truncation guard works too. The 566 MB
  `Zebra 123 Scan.exe` already proves the transport at this scale. A prior plan proposed
  swapping in `curl.exe` plus a uuid scrape on a false premise; it was dropped. `Test-RealBinary`'s
  floor is **8 bytes, not 2**: the magic tests read `$buf[0..3]`, and when `Get-RemoteLength` can't
  answer (`$expected = -1`) the Content-Length check is skipped entirely and this sniff is the last
  truncation guard — a 2-byte `MZ` fragment was recorded `ok`, wrote its truncated size into the
  `.len` sidecar and passed `Test-CachedFileValid` forever after: a permanent 1603. That `-1`
  **warns** (silently dropping a guard is worse than dropping it), and the `WebException`'s response
  is closed — 2 connections per host at a 60 s timeout means a leak wedges the *later* probes. When
  the retries are exhausted but the on-disk file still passes `Test-CachedFileValid`, the call
  returns **success**: the install runs from that exact file, so returning failure set
  `$script:DownloadFailed` and exited 1 on a run that installed fine.
- **"Already installed" means SUCCESSFULLY installed.** Both idempotency guards in
  `Invoke-InstallLoop` consult `Test-PriorInstallFailed` (which reads the prior manifest via
  `Get-PriorManifest`) before letting ARP presence skip a product — an install that failed leaves
  exactly the registry state a later run reads as "done", so without this a broken product is never
  repaired and every re-run reports success. A product with **no** prior row still skips on ARP
  alone (installed by hand or by an older build), and an `ok` row carrying `note='msi-fallback'`
  counts as **not** successfully installed (see the fallback bullet). Consequence to expect: a
  genuinely failing product retries every run until it succeeds.
- **The exit-code tally is snapshotted BEFORE `Save-Manifest`.** The merge carries prior-run rows
  forward for every product this run didn't touch (`-SkipPrograms`, `-PrinterBrand None`), so
  tallying after it counts an OLD failure as a new one — exit 1 forever, which then also suppresses
  the non-fatal 4/6/7 signals since they are gated on `$exitCode -eq 0`.
- **An unreadable prior manifest is never overwritten, and never silently read as empty.**
  `Save-Manifest` moves it to `<manifest>.unreadable` instead of clobbering it, and writes via
  temp file + `Move-Item` so a kill mid-write can't produce the truncated JSON in the first
  place. `Invoke-UninstallPhase` has the matching guard on the **read** side: `ConvertFrom-Json`
  is non-terminating under `'Continue'`, so a truncated manifest left `$man = $null`, every
  `$man.<list>` read as empty, the phase removed nothing and **returned 0** — an RMM marked the
  decommission clean with the whole product installed. Now `-ErrorAction Stop` + `return 1`.
- **`-Uninstall` counts EVERY reversal failure, not just products.** `$uninstallFailures` used to
  be incremented in one place; a scheduled task that wouldn't unregister, a reg key that wouldn't
  delete, a value that wouldn't restore and a locked pinned `.lnk` were all `Warn`-and-return-0.
  Four more were still uncounted until 2026-09-09: the step-1 file delete, the step-1b file
  restore, the step-4c UCPD task **re-enable**, and — worst — step 4b's `(default)` deletion,
  whose *inner* try/catch intercepted before the outer `$uninstallFailures++`; that is the value
  whose survival leaves the phantom OPOS device, so it was the wrong one to swallow. That arm also
  counts — rather than narrating "already gone" — a recorded path **not under HKLM**
  (`LocalMachine.OpenSubKey` reads anything else as a *relative* subkey and returns `$null`) and a
  handle it could not open: the `Get-ItemProperty` test one line up has just proven the value
  exists, so a null handle means access denied. Three more
  after that: step 4d's **`Taskband` restore** catch (not the benign "hive not loaded" skip above
  it — reaching the catch means the hive *is* loaded and the write was refused, so the cashier's
  taskbar keeps our pins aimed at exes step 2 just uninstalled), step 1b's **"backup is gone"**
  branch (unlike step 1's "already gone", here gone means the OEM layout is *unrecoverable* — the
  same consequence as the catch two lines below it, which was counted), and
  `Remove-InstallShieldOrphans`, which had no way to reach the counter at all and now **returns a
  failure count** (the uninstall caller adds it; the install-side pre-clean caller `Out-Null`s it,
  since there a leftover orphan already shows up as the `.iss` dropping into maintenance mode).
  Step 1 also uses **`-LiteralPath`**, like 1b: `-Path` treats `[ ]` as wildcards, so a bracketed
  path reported "already gone" and was skipped uncounted. The summary
  line says "reversal(s)", not "product(s)", because it has counted more than products for a while.
  The load-bearing case: `AlleavesAuto-FinishUser` surviving keeps clearing `Taskband` and
  re-applying our pins at every logon. Relatedly, the non-`(default)` value deletion is
  `-ErrorAction Stop` — its `Ok "removed …"` is unconditional, so `SilentlyContinue` reported
  removals that never happened.
- **The `.iss` → fallback path drops the failed row before retrying.** `Invoke-IssSilent` records
  `result='fail'` by design and the fallback appends a second row under the **same name**;
  `Merge-PriorList` only dedupes prior-vs-current, so both persisted. A run where the fallback
  *succeeded* therefore exited 1, and `Test-PriorInstallFailed` (any non-`ok` row) then returned
  `$true` forever — the 446 MB Zebra install replayed every run and could never short-circuit.
  Three more things ride on that surviving row:
  - It is stamped **`note='msi-fallback'`** (`result` stays `ok` — the exit tally must not count a
    fallback that worked as a failure; this is about idempotency). Neither fallback MSI carries
    the shared CoreScanner driver the `.iss` install does, so the product lands in ARP, the guard
    skips it on every future run, CoreScanner stays absent and the run exits **4 forever** — with
    its only advertised remediation, "re-run the installer", doing nothing. `Test-PriorInstallFailed`
    treats the stamp as not-successfully-installed so the `.iss` path is re-attempted.
  - Both fallbacks record the **broad `$uMatch`**, not `$i.Match`. The narrow pattern is right for
    this item's own install-side checks and wrong for the manifest, which `-Uninstall` replays:
    under `Zebra Scanner SDK` alone the shared `Zebra CoreScanner Driver (64bit)` was never
    removed. For the same reason the uninstall orphan sweep gates on
    `method -eq 'iss-silent' -or note -eq 'msi-fallback'` — the `.iss` row is *gone* by then, so a
    method-only test skipped the sweep for exactly the products whose `.iss` attempt made the orphans.
  - `Invoke-WrappedMsi` confirms **ARP** after a success exit code, like `Invoke-Installer`'s
    `-ConfirmRegistry`: it harvests an MSI from *any* new `%TEMP%\{GUID}` dir ("largest `*.msi`
    > 1 MB", never verified as our wrapper's), so an RMM or vendor update dropping one there during
    the 600 s poll got installed instead — exit 0, row `ok`, product absent, and `-Uninstall`
    (which filters on `ok`) removed nothing. That check takes its own **mandatory `-ConfirmMatch`**
    (the narrow `$i.Match`); the broad `-DisplayNameMatch` recorded for uninstall is satisfied by
    the CoreScanner the *other* Zebra row installed. It caches the extracted MSI **only after
    msiexec proves it installed**, under the row's `CachedMsi` constant (**mandatory** `-CacheAs` —
    the "fall back to the extracted leaf name" arm was unreachable and reinstated the cache bug
    below the moment a row forgot the key), copied from the staged file msiexec actually ran.
    Size-stabilization + the OLE sniff both pass a fragment left by a writer killed mid-extract,
    and the copy is permanent and `Test-Path`-guarded, so that fragment 1603'd every future run
    (`-ForceReinstall` included) until someone deleted it by hand; caching under the vendor's own
    leaf name silently disabled the cache on any filename bump, since the fallback looks it up
    under the constant. Its orphan reap uses the **exact** `$launchTime`, no minute of slack:
    slack is safe in a *wait* filter, but here it decides what to force-kill and the two Zebra
    rows run back to back.
- **`Install-VcRedist` re-confirms presence, not just the exit code** — it is the one installer
  routed around `Invoke-Installer`, so it never got `-ConfirmRegistry`, and it is also the one that
  accepts **1638** ("a newer build is present"), which `Test-VcRedistPresent` had *disproved* a few
  lines earlier. A child MSI blocked by policy or AV exits 1638 (or 0) having installed nothing:
  recorded `ok`, CoreScanner then forces exactly the mid-install reboot this bootstrap exists to
  prevent, and the run still exits 0.
- **`$DriveFiles` `Label` must equal the matching `$Installers` `Name`** — not just for the
  printer rows. `Test-SkipMatch` tests `Label`/`File` for downloads but `Name`/`File` for
  installs, so a drifted Label makes one `-SkipPrograms` fragment hit only one phase
  (`-SkipPrograms NiceLabel` downloaded the whole suite and never installed it).
- **`tests\`** holds the runnable self-checks, both AST-lifting functions out of the `.ps1` rather
  than loading it: `Test-AccountPrecheck.ps1` (verdict arms, `ConvertTo-ResumeArgs` **round-trip**
  — not just its string shape, `Clear-AccountSwapState`'s dry-run/unreadable-marker arms plus the
  **surviving resume task** case: marker and staged copy kept, autologon still restored) and
  `Test-ManifestMerge.ps1` (`Merge-PriorList` direction per list, the `serialFinal` key, the
  `.iss` fallback row-drop, `Test-PriorInstallFailed`'s arms — notably that `note='msi-fallback'`
  forces a replay while `note='already-installed'` does not — and uninstall step 4b's stale
  `regValuesSet` rows, whose loop body is lifted whole and run against a scratch `HKCU` key so the
  "counts zero failures / does not resurrect the retired device key" claim is actually executed —
  plus the cross-table check that every `$PrinterBrands` `RowName` appears as both a `$DriveFiles`
  **Label** and an `$Installers` **Name**, since step 0b's brand skip goes through `Test-SkipMatch`,
  which reads a different field in each phase).
  Both exit 0/1, no framework. Stub order matters in the first one —
  the `Clear-AccountSwapState` section shadows `Restore-AutoLogon`/`Test-Path`/`Get-Content`/
  `Remove-Item`, so it must stay **last**.
- Single elevation owner is `Install-Alleaves.bat`; the `.ps1` never self-relaunches — aborts if
  not admin (except `-DryRun`).
- Runtime payloads, logs, and the base64 build intermediate (`alleaves_b64.txt`) are git-ignored —
  see `.gitignore`.
