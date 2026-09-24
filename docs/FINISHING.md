# Post-install finishing

Computer rename, taskbar pins, default browser, Alleaves bookmark, master-list copy, and the per-user
logon task that applies the deferred halves after the post-install reboot.

Every change is tracked so `-Uninstall` reverses it, with **two deliberate exceptions**:

- **the rename** — restoring a factory-random name is pointless (same policy as the TeamViewer removal);
- **the http/https/.htm/.html UserChoice values the logon script writes** — `-Uninstall` runs as the tech with
  the cashier's hive unloaded, and loading `NTUSER.DAT` per profile to revert a file association is more
  machinery than the problem is worth. The prior ProgId is logged to `logs\finish_<user>.log` first, which is
  the recovery path. **Consequence to expect:** after `-Uninstall` + Chrome removal those associations point
  at a `ChromeHTML` ProgId whose exe is gone.

The `HKCU:\Software\AlleavesAuto` marker is **not** one of them ([#stamp](#stamp)).

## <a id="environment"></a>Environment facts this was built against

Build 10.0.26200 / 25H2, WORKGROUP, UCPD active — all detected at runtime.

- **Taskbar.** The Win10 `StartLayoutFile`/`LockedStartLayout` policy does **not** drive the Win11 taskbar (and
  would LOCK the Start menu). Win11's machine-wide mechanism, `HKLM\…\Explorer\LayoutXMLPath` → a taskbar XML,
  applies only to profiles created **after** it is set, so the existing auto-login cashier also gets a per-user
  `LayoutModification.xml` plus a `Taskband` clear + Explorer restart at the next logon. There is **no
  supported per-user pin API on Win11 25H2** — syspin/pttb are broken on 24H2+ — so clear-and-reapply is the
  method.
- **Default browser.** `DefaultAssociationsConfiguration` is a documented **no-op on a non-domain workgroup
  box** and UCPD blocks UserChoice writes while loaded, so UCPD is disabled for the next boot (`Start=4` plus
  its "velocity" re-enable task) and the salted UserChoice hash is written per user from a logon task once
  UCPD is inert. The algorithm is the Kolbicz/DanysysTeam UserChoice hash — **provenance, not a validated
  guarantee**: it lives inside the generated finish script's here-string, which no test here can reach.

Both halves run from ONE per-user logon task (`AlleavesAuto-FinishUser`) that fires after the reboot.

## <a id="rename"></a>Computer rename

Lowest risk, so it runs **first** — the tech types the name and walks away. Validated, skippable (Enter to
skip). Effective on the post-install reboot.

- **A preset `-ComputerName` equal to the current name is a no-op `Ok`, not a validation error.** `$validate`
  rejects the current name, right for the prompt loop (re-typing it is a typo), but an RMM policy that always
  passes `-ComputerName POS01` renamed on run 1 and hit the Fail arm on every run after — exit 1 forever,
  `-ForceReinstall` cycle and post-swap resume included.
- **Both failure arms set `$script:FinishFailed`**: this step writes no `installed` row, so without the flag a
  failed rename printed red `[FAIL]`, exited 0, and `Get-PosNamePrefix` fell back to the CURRENT name —
  `Set-PrinterOpos` then registered `OLDNAME_Printer`, which Alleaves (configured for the new name) can never
  open.
- <a id="headless-prompt"></a>**The prompt is try/catch'd and gated on a console**: an unconditional `Read-Host`
  on a headless / RMM run blocks on stdin forever or throws, and that throw escapes to the top-level catch and
  aborts the install before a single download. `UserInteractive` alone is not sufficient (`-NonInteractive`
  still reports `$true`), so the catch is what makes it safe; otherwise degrade to skip. The printer-brand
  prompt follows the same pattern.

## <a id="profiles"></a>`Get-TargetUserProfiles`

Every profile this returns gets a taskbar XML **and** a copy of the `.nlbl` master list in its Documents, so
the filter has to mean "a human who will use this terminal", not "a domain-shaped SID":

- **RID ≥ 1000.** `S-1-5-21-*` alone also matches Guest (501), `DefaultAccount` (503), `WDAGUtilityAccount`
  (504) and OEM `defaultuser0` — each was collecting a taskbar layout *and* a copy of the master list.
- **No `.bak` keys.** Windows renames a broken profile's key to `<sid>.bak` while creating a fresh one pointing
  at the **same** directory, so accepting both writes everything twice.

It already validates that each `ProfileImagePath` exists.

## <a id="master-list"></a>Master list (`.nlbl`)

Under elevation `GetFolderPath('MyDocuments')` is the **admin's** profile, but NiceLabel runs as the cashier
and won't find the `.nlbl` there → silent broken printing. So it goes to the Documents of **every** real user
profile plus the admin's, every path recorded. **Copy as-is, never unzip** — the "encryption" is NiceLabel's
internal format.

<a id="onedrive"></a>**A profile whose `Documents` is missing is checked for a OneDrive Known-Folder-Move
redirection first** (`<profile>\OneDrive*\Documents`): creating the plain path there manufactures a **decoy**
where the `.nlbl` lands in a folder nothing reads, `[OK]` prints, and NiceLabel never sees the master list.
Only a profile with neither gets a directory created.

- A directory this step had to create is recorded in `filesPlaced`, **after** the `.nlbl`, so the in-order
  uninstall walk empties it before the non-recursive `Remove-Item` reaches it —
  [MANIFEST.md#counting](MANIFEST.md#counting).
- **A copy that lands NOWHERE is a failed run**, not a Warn-and-exit-0: a terminal with no master list cannot
  print a label. Landing in some profiles but not others stays a Warn — the profile that matters has it.
- **Every check sits BELOW the dry-run return**, or a mode that writes nothing raises `$FinishFailed` and
  produces a phantom exit 1.
- It consults `Test-SkipMatch` too: the `.nlbl` is a `$DriveFiles` row, so `-SkipPrograms 'Nice Label'`
  correctly skips its *download* — and this step then failed "not found" and exited 1 on a deliberate skip.

## <a id="splashtop-sos"></a>Splashtop SOS

`SplashtopSOS.exe` (what sos.splashtop.com serves) is a **portable exe — no installer, no ARP entry** — so
`Install-SplashtopSos` "installs" it by copying it to `%ProgramFiles%\Splashtop SOS\` and creating two
`New-TrackedShortcut`s: the all-users Start Menu (makes it Windows-search-findable) and the Public Desktop
(`-Dir`). Exe, created dir (after the exe — [#master-list](#master-list)) and both `.lnk`s go in
`filesPlaced`; the existing `-Uninstall` walk reverses them, no dedicated uninstall code.

- **An existing exe is left alone unless `-ForceReinstall`**: the tech may be connected *through* SOS
  while re-running, and overwriting a running exe fails.
- Not copied from `downloads\` in place: that folder survives `-Uninstall`, and the shortcuts need a path
  that is ours to remove.

## <a id="taskbar"></a>Taskbar pins

`Get-TaskbarXml` takes the pin list; `Invoke-ChromeTaskbar` builds it **per app** so one missing product
doesn't drop the other's pin (it used to hard-return on "no Chrome"). Pin order is taskbar order: the terminal
app first (the primary app on a POS), then the browser, then File Explorer. `PinListPlacement="Replace"` drops
the default Edge pin.

> **No XML comments in that here-string** — they silently break the file.

<a id="alleaves-pos-pin"></a>**"Alleaves POS" is `chrome.exe` with `$AlleavesUrl` on its command line, and it
REPLACES the plain Google Chrome pin.** Not stylistic: Chrome refuses to honour a start-page policy on a
terminal that is not domain-joined or CBCM-enrolled ([#chrome-policy](#chrome-policy)), so a shortcut carrying
the URL is the only way to make the cashier's browser icon land on the POS. Verified cold-start.

### <a id="shortcuts"></a>Shortcuts

Neither pin target ships a `.lnk` — the Alleaves MSI installs **no shortcut at all** (two files, measured) and
`Alleaves POS` is ours — so `New-TrackedShortcut` creates both all-users Start Menu shortcuts that
`DesktopApplicationLinkPath` needs, tracked via `filesPlaced`. `<taskbar:DesktopApp>` can only pin a `.lnk`.

`WorkingDirectory` is pinned to the install dir: `AlleavesLauncher.exe` unpacks its payload **relative to the
working directory** (measured — run from a shell it dropped `Build\` + `version.txt` into that shell's cwd).

<a id="launcher-path"></a>**`Get-AlleavesLauncherPath` can't trust ARP `InstallLocation` — the shipping
Alleaves MSI leaves it BLANK.** On 2026-09-13 the install loop reported "Alleaves Terminal: already installed"
while the taskbar step three screens later printed "not installed — not pinning it", and the terminal's
primary app silently lost its pin. It now falls through:

1. `InstallLocation`, **`Test-Path`'d** so a stale one doesn't win
2. the ARP `DisplayIcon`, `,0` index and quotes stripped, **only when it names `AlleavesLauncher.exe`**
3. a `-Depth 3` search of `%ProgramFiles%`, `%ProgramFiles(x86)%` and `%LOCALAPPDATA%\Programs`

All three are **measured** sources — a hardcoded path would still be wrong. `$null` still means "don't pin it",
and the warning says *"could not locate AlleavesLauncher.exe"*, never "not installed", which contradicted the
install loop. `Get-ChromeExePath` uses **App Paths**, correct for both Program Files and (x86) installs.

### <a id="where-the-xml-goes"></a>Where the XML goes

| | Covers |
|---|---|
| (a) machine-wide XML + `LayoutXMLPath` | profiles created AFTER it is set |
| (b) Default-profile XML | brand-new accounts at first logon |
| (c) per-user XML for existing profiles | the auto-login cashier — applied by the logon task |

<a id="no-hardcoded-c"></a>**No path here is hardcoded to `C:\`.** `$StartMenuAll` comes from
`%ALLUSERSPROFILE%` (the pair drifting from the *machine* puts the `.lnk` at one path while the XML pins
another) and the Default-profile XML from `ProfileList\Default`. `Write-XmlFile` creates the whole directory
chain, so on a relocated-profiles or non-`C:` box a hardcoded path *manufactures* a junk tree, prints `[OK]`,
adds it to `filesPlaced` — and every brand-new cashier profile still gets no layout.

All three writes are try/catch'd: `$ErrorActionPreference='Continue'` does **not** suppress a .NET method
exception, so an unguarded throw would abort the whole run at the top-level catch — after every download and
install has already happened — for one cosmetic file.

### <a id="finish-taskbar-flag"></a>`$script:FinishTaskbar` is set only if a layout actually landed

The task's first act is to **delete** the user's Taskband pins and restart Explorer so the new XML is read, so
with no XML written (a read-only per-user file on an OEM image) that is pure destruction — the cashier loses
their pins and ours never appear.

Both total-failure arms set `$script:FinishFailed`, since this step writes no `installed` row. The failure
messages avoid *"not installed"* and *"neither product is installed"*: `$pins` is also empty when
`New-TrackedShortcut` failed (blocked `WScript.Shell` COM, a read-only all-users Start Menu), and both
wordings sent techs hunting a healthy install.

### <a id="write-xmlfile"></a>`Write-XmlFile` backup rule

It preserves a file it is about to **replace**. `LayoutModification.xml` is a file OEM images legitimately
ship, and it goes into `filesPlaced` either way (leaving our layout behind would strand pins aimed at deleted
exes), so uninstall needs the original back after the delete.

**"Existing" must mean SOMEONE ELSE'S**, and "ours" requires that **no orphaned backup row exist — in both
halves of the `-or`**: uninstall restores by `Move-Item`, consuming the `.alleaves-orig` without rewriting the
manifest, so with the test on one half only the `-or` short-circuited past it, the reinstall took no new
backup, and the restored OEM layout was destroyed permanently.

An **unreadable prior manifest** can't answer "is this ours?" at all, so `$script:PriorManifestUnreadable`
skips the backup block entirely — guessing "someone else's" is the destructive guess
([MANIFEST.md#prior](MANIFEST.md#prior)).

### <a id="stamp"></a>The per-user marker stores the LAYOUT, not a bare flag

`TaskbarApplied` holds the **pin list plus a deployment generation** (`$script:TaskbarStamp` =
`$pins + $gen -join '|'`). A bare "already applied" flag makes every later pin-set change invisible to a
deployed terminal — the task sees the flag, skips the `Taskband` clear + Explorer restart that is the only
thing making Explorer re-read the rewritten XML, and the cashier keeps the OLD pins forever. The pin list
alone was not enough either: the cashier's hive is usually unloaded at install time, so uninstall step 4d
never reaches their marker and a reinstall produces a byte-identical stamp. Hence `$gen`, one
`HKLM:\SOFTWARE\AlleavesAuto\TaskbarGeneration` value written through `Set-TrackedRegValue` — `-Uninstall`
removes it for free and the next install mints a new one, while a plain re-run reuses it and does not wipe
pins the cashier added.

- A deployed box holds the old DWORD `1`, which never equals a stamp, so it re-applies once and settles.
  Compare as **strings** and write with `New-ItemProperty -Force -PropertyType String` — `Set-ItemProperty`
  would coerce the string into the existing DWORD; `-Force` replaces the value **and its type**.
- **A generation that failed to persist must not be used** — reuse the prior manifest's, else every logon
  re-clears the cashier's pins. With none to reuse, say that consequence out loud.

### <a id="pinned-lnk"></a>A pinned `.lnk` lives in TWO places

Applying the layout makes Explorer **copy** the shortcut into each user's
`…\Quick Launch\User Pinned\TaskBar`, so `filesPlaced` — which only knows the all-users source — leaves a pin
pointing at a deleted exe (measured: it survived a full `-Uninstall`). Uninstall step **4e** deletes
`$TaskbarPinNames` from every profile's pinned folder; that list exists so install and uninstall can't drift,
and it is an **exact** name match so another vendor's pin is never removed.

### <a id="backup-loadedtaskbands"></a>`Backup-LoadedTaskbands`

Backs up every loaded user hive's `Taskband` blob so `-Uninstall` can restore the original pins (step 4d,
which also drops that SID's `TaskbarApplied` marker). Guarded **per SID**: a malformed blob makes the
`[byte[]]` cast *terminating*, aborting the install before `Save-Manifest` for a purely cosmetic backup.

## <a id="default-browser"></a>Default browser

`Invoke-ChromeDefaultBrowser` disables UCPD for next boot; the per-user UserChoice write happens post-reboot
via the logon task.

- **`Start=4` raises the deferred-reboot flag**, because it only takes effect at BOOT while the logon task
  needs only a logon. With `-SkipRename` and no 3010 from any installer nothing else set that flag, so the
  tech got the soft "reboot recommended" line, signed out and in instead, all four `Set-UserChoiceDefault`
  calls burned their retries against a still-loaded UCPD, and Chrome was never default — on a run that
  exited 0.
- **The velocity-task disable sits OUTSIDE the `Start=4` test.** In the `else` arm, every re-run (where
  `Start` is already 4 from run 1) skipped the one task whose whole job is to re-enable UCPD. Free:
  `Disable-TrackedTask` early-returns on an already-disabled task.

### <a id="disable-trackedtask"></a>`Disable-TrackedTask`

Looks the task up with **`SilentlyContinue` + an explicit absence test**, never `-Stop` — the caller gates on
the UCPD *service* key while the target is the velocity *task*, so on a box where the task was pruned `-Stop`
made "does not exist" terminating and a healthy install exited 1. **Only the `Disable` is a failure**, and it
sets `$script:FinishFailed`, or UCPD reloads at boot and Chrome silently never becomes default while the
banner tells the tech otherwise. `prevState` gates the uninstall re-enable.

## <a id="chrome-policy"></a>Chrome bookmark — and what Chrome blocks

`Invoke-ChromeBookmark` writes `ManagedBookmarks` + `BookmarkBarEnabled` under
`HKLM:\SOFTWARE\Policies\Google\Chrome` via `Set-TrackedRegValue`, so tracking and uninstall come free and
there is **no logon task**. Both verified `OK`, in an existing profile *and* a fresh one.

- **Mandatory, not `\Recommended`** — the cashier must not be able to delete it. The "managed by your
  organization" banner is expected.
- **`BookmarkBarEnabled=1`** or it's off-screen.
- A read-only "Alleaves" folder holding one entry, built with `ConvertTo-Json` so the quoting can't be got
  wrong by hand.
- Hand-editing a profile's `Bookmarks` JSON is the wrong answer: Chrome checksums it, rewrites it while
  running, and a new cashier profile gets nothing.
- The `.bat` forces 64-bit PowerShell, so the write lands in the view Chrome reads — **do not add a
  `WOW6432Node` branch.**

> **DO NOT re-add `RestoreOnStartup`, `RestoreOnStartupURLs`, `HomepageLocation`, `HomepageIsNewTabPage` or
> `NewTabPageLocation`.**
>
> Measured 2026-08-12 on the rig: `chrome://policy` reports every one of them *"This policy is blocked, its
> value will be ignored."* Chrome blocks the startup / homepage / search-provider policies on a machine that is
> not AD- or Entra-joined or CBCM-enrolled — an anti-hijacking measure. The `\Recommended` flavour is blocked
> identically, and merging the same keys into Chrome's `initial_preferences` did **not** carry into a
> brand-new profile.

The start page is therefore delivered by the [Alleaves POS taskbar shortcut](#alleaves-pos-pin), and
`ShowHomeButton` is deliberately **not** set — the Home button would work but could only reach the new-tab
page, since `HomepageLocation` is blocked.

## <a id="logon-task"></a>The per-user finish logon task

`Register-FinishLogonTask` stages the generated finish script and registers `AlleavesAuto-FinishUser`, once
after the taskbar/browser steps and only if at least one set a Finish flag.

- **`Register-ScheduledTask` needs `-ErrorAction Stop`**, like every task cmdlet here: it is a CIM cmdlet, so
  under `'Continue'` a refused registration (policy, a locked Task Scheduler store) skipped the catch and
  reported success — a `scheduledTasksCreated` row for a task that doesn't exist, exit 0, and a later
  `-Uninstall` failing to unregister the phantom and exiting 1.
- **So do the four `New-ScheduledTask*` builders.** None of `-Trigger`/`-Principal`/`-Settings` is mandatory,
  so a builder that failed non-terminatingly produced a definition with that component **nulled** and the
  registration succeeded. A null **principal** defaults to the **tech's** account — whom the finish script
  explicitly skips — so the cashier gets no pins and no default browser, reported `[OK]`, exit 0.
- On failure the **flags are cleared too**, or the end-of-run summary tells the tech the taskbar pin and
  default browser apply automatically at logon when the script or task does not exist.

### <a id="finish-bom"></a>The finish script is written WITH a BOM

Unlike `Write-XmlFile`'s XML, which declares its own encoding. PS 5.1 decodes a BOM-less `.ps1` as ANSI, and
**three machine-derived values are baked into the body** — the install user, the taskbar stamp, and Chrome's
install-time ProgId from HKLM — so a non-ASCII tech account name mojibakes them: the
`$env:USERNAME -eq $installUser` test fails (the finish runs *for the tech*) and the stamp never matches its
marker, re-clearing the cashier's pins at every logon, forever.

The stamp lands inside a single-quoted literal, so any apostrophe is doubled (same as the username). An empty
stamp can never match, so the apply runs — the safe direction.

### <a id="install-user"></a>`$installUser` is BLANK after an account swap

The task is group-scoped to `BUILTIN\Users`, so it also fires for the tech/admin — and the finishing is the
cashier's, so the account that RAN the installer is baked in and skipped. An `IsInRole(Administrator)` test
cannot replace that: the task's RunLevel is Limited, so the token is always filtered. Known caveat: a
single-account deploy where the installer *is* the cashier gets skipped.

**Except after a swap.** The resume task runs the installer **as** the account it just created, the very
account that will run the POS, so baking `$env:USERNAME` there made the finish skip the only profile that
matters: no pins, no default browser, and a log line saying "running as installer — skipping finish".

**The PRIOR manifest counts too.** `New-InstallManifest` seeds `accountCreated` from this run's
`$script:AccountSwapDone` only, and this runs inside `Register-FinishLogonTask` — *before* `Save-Manifest`
merges the prior row forward — so a later re-run by a tech signed in as the swap-created account (the
terminal's only admin, which is the point of the swap) baked that name in again. Blank means skip nobody.

**Both counts go through `| Where-Object { $_ }`, not a bare `@(…)`.** `@($null).Count` is **1**, and on
a first install there is no prior manifest, so `(Get-PriorManifest).accountCreated` is `$null` and the
test read "a swap happened" — `$installUser` went blank and the finish ran **for the tech**, wiping their
Taskband and flipping their default browser at the next sign-in. Run 2 found `accountCreated: []`,
counted 0, and silently started behaving correctly.

### <a id="progid"></a>Chrome's ProgId is resolved at logon from HKCU

The install-time HKLM value is only the **fallback**. A per-user Chrome registers a *suffixed* ProgId
(`ChromeHTML.XXXXXXXX`) the installer's machine-wide probe can't see, and a well-formed UserChoice for a ProgId
that doesn't exist still verifies `OK` while links keep opening Edge.

### <a id="minute-roll"></a>The minute roll

Windows validates the UserChoice hash against the key's `LastWriteTime` **truncated to the minute**, and
**three** registry ops (one a recursive delete) run between building the hash and the last `SetValue` — so the
minute can roll mid-write, Windows rejects the association silently, and the readback still reports OK because
it compares the key against what the script itself just wrote (the same self-confirming trap as the ProgId
above). Re-check the clock and rebuild rather than confirm a hash Windows will never honour; no sleep is
needed, because the minute just turned and the next attempt has a full one to itself.

The "already set" short-circuit therefore requires the **`Hash` value as well as the `ProgId`**: a key
carrying the right ProgId and no hash is one Windows ignores, and reading only the ProgId declared
success on it and never repaired it at any later logon.
