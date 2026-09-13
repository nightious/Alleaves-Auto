# Manifest and uninstall

`%ProgramData%\AlleavesAuto\logs\install_manifest.json` records every install (method, exit code,
logs), placed files, registry changes, scheduled tasks, the TeamViewer removal, scanner and printer
results. `-Uninstall` replays it in **reverse order**.

The skeleton is built once by `New-InstallManifest`, shared by the full-install and config-only
dispatch paths so the key set can never drift between them.

## <a id="keys"></a>Key set

| Key | Shape | Reversal |
|---|---|---|
| `installed` | `name, source, displayNameMatch, result` always; `args` (redacted), `exitCode`, `stdoutLog`/`stderrLog`, `note`, `method` per writer — see below | uninstalled in reverse |
| `dependencies` | VC++ only | **reported, never removed** — other software may depend on it |
| `filesPlaced` | paths — **may hold a DIRECTORY** | deleted in order |
| `filesReplaced` | `{ path; backup }` | backup moved back over path, after the deletes |
| `computerRenamed` | `{ from; to; applied; dryRun; error }` — the last two only on a dry run / a failed rename | **record only** |
| `regValuesSet` | `{ path; name; type; value; prev; prevAbsent }` — **no `hive`** | prev restored, or removed |
| `regKeysCreated` | plain path strings | removed deepest-first if childless |
| `scheduledTasksCreated` | `{ path; name }` | unregistered by `name` |
| `scheduledTasksDisabled` | `{ path; name; prevState }` | re-enabled if previously enabled |
| `taskbandBackups` | `{ sid; favorites(b64); favoritesResolve(b64) }` | restored for loaded hives |
| `scannerConfigured` | `{ serial; serialFinal; model; modelFinal; hostBefore; target; result; removable=$false }` | **record only** |
| `printerConfigured` | `{ logicalName; deviceClass; deviceType; progId; brand; result; removable }` | reversible — pure registry |
| `teamViewerRemoved` | bare name strings | **record only** |
| `accountCreated` | `{ name; sid; created; removable=$false }` | **record only** |
| `accountCheckOverride` | `{ account; reason; via; whenUtc; removable=$false }` | **record only** |

`regValuesSet` has **no `hive` field**, and that absence is load-bearing: it is why the `(default)`
deletion arm can only assume HKLM ([#default-value](#default-value)).

<a id="installed-method"></a>**`method` is NOT on every `installed` row.** `Invoke-Installer` omits it,
so every raw-exe row and every `Invoke-Msi` row lacks it. It is written only by `Invoke-IssSilent`
(`'iss-silent'`), `Invoke-WrappedMsi` (`'wrapper-extract'`) and the install loop's own skip /
extract-failure / exception rows. Anything that gates on it must tolerate the gap — [step 2b](#step-2b)
does, by also accepting `note -eq 'msi-fallback'`.

`scannerConfigured` is kept **out of `installed`** so a benign `no-scanner` run doesn't trip the
failure tally. `printerConfigured` is **one row per device**, so a brand with a separate cash drawer
(Star) contributes two.

`accountCreated` carries no autologon state on purpose: it is armed and fully undone inside one swap
cycle, so "restoring" it on a later uninstall would be wrong. See
[ACCOUNT-SWAP.md#autologon](ACCOUNT-SWAP.md#autologon).

## <a id="merge"></a>Merge rules

`Merge-PriorList` carries prior-manifest items forward that **this** run didn't touch, deduped by a key
selector (for scalar arrays the key IS the item). **This run wins on a key conflict** — except for the
three lists below.

> **Current-side nulls are filtered.** An absent JSON key reads as `$null`, and `@($null)` is a
> one-element array holding `$null`, so a manifest predating a key injected a literal null row into
> the merge. Reachable only through the three prior-wins lists (a current-side list is always at least
> `@()` from `New-InstallManifest`), and all three consumers happen to guard — but the filter is what
> keeps a null out of the file in the first place.

### <a id="prior-wins"></a>PRIOR wins (args swapped)

Only the **first** run saw the pre-install state.

- **`filesReplaced`** — keeping a later run's row would point the restore at a backup of our own output.
- **`regValuesSet`** — `prev` is the pre-install state. A second run over the same value finds our own
  data already there and records `prevAbsent=$false; prev=<our value>`, so keeping the newer row makes
  `-Uninstall` RESTORE what it should remove.
- **`taskbandBackups`** — by run 2 the logon task has cleared Taskband and Explorer has rewritten it
  with OUR pins, so keeping the newer row made `-Uninstall` "restore" Alleaves pins aimed at exes it had
  just deleted.

### <a id="key-selectors"></a>Key selectors

- `scannerConfigured` keys on **`serialFinal`** (the post-switch serial) with `serial` as fallback,
  because `serial` is **blank** on the common HID-KB start and a **PRIOR-side** row with a falsy key is
  **dropped** — so a prior run's scanner row vanished silently. (The skip is asymmetric: a *current*
  row with a falsy key stays in the merged list, it just isn't registered as a dedupe key.
  `tests\Test-ManifestMerge.ps1` asserts the prior-side drop.)
- `printerConfigured` keys on `logicalName`, which is never null — same class of flaw.
- `accountCheckOverride` keys on the **timestamp, not the account**: each override is its own event and
  they all stay, so a later clean re-run cannot erase the record
  ([ACCOUNT-SWAP.md#override](ACCOUNT-SWAP.md#override)).

## <a id="save"></a>`Save-Manifest`

- **Never persists over the real manifest during a dry run.** Dry-run entries share program names with
  real ones and would shadow the `ok` results in the merge, leaving a later real `-Uninstall` with
  nothing to remove.
- Writes via **temp file + `Move-Item`**, so a kill mid-write can't produce truncated JSON in the first
  place.
- **An unreadable prior manifest is never overwritten.** It is moved to `<manifest>.unreadable` instead
  of clobbered — it is the only record of what a previous run placed, and overwriting it turns every
  earlier install into something `-Uninstall` can no longer see (it would report "nothing recorded" and
  exit 0).
- Both the read cmdlets are **`-ErrorAction Stop`**, or the catch never runs for the case that matters
  most: a manifest LOCKED by AV or a backup agent fails in `Get-Content`, which is **non-terminating**
  under `'Continue'` — `$prior` lands `$null`, every merge reads it as empty, and the preserving
  `Move-Item` is skipped.
- A failed write sets `$script:ManifestWriteFailed` → exit 1. Nothing this run did is recorded anywhere
  otherwise.

## <a id="prior"></a>`Get-PriorManifest`

The on-disk manifest from an **earlier** run, read at most once. Distinct from `$Manifest`, which is
this run's and is empty when the install loop starts.

Three failure shapes used to read as "empty manifest": **malformed JSON** (statement-terminating, does
reach the catch); a **locked file** (`Get-Content` fails *non-terminatingly* under `'Continue'`, so
`$script:PriorManifest` is assigned `$null` over its `@{}` default and the read-once memo never
satisfies — hence `-ErrorAction Stop` on **both** cmdlets here); and a **zero-byte file** (`-Raw`
returns `$null` with no error, so no catch can fire — hence the explicit `IsNullOrWhiteSpace` test).

Consequences when it silently read empty: `Test-PriorInstallFailed` returned `$false` for a product that
failed last run and ARP alone skipped its repair; `Write-XmlFile`'s "is this ours?" test read `$false`
so run 2 backed up OUR OWN layout as the "OEM" one
([FINISHING.md#write-xmlfile](FINISHING.md#write-xmlfile)); and after a rename the terminal advertised
two OPOS printers ([PRINTER-OPOS.md#stale](PRINTER-OPOS.md#stale)).

**An UNKNOWN prior state is not an empty one.** `$script:PriorManifestUnreadable` makes the taskbar step
decline to guess rather than destroy the OEM layout — `Save-Manifest` preserves the bytes, but that
runs at the END of the run, long after the taskbar step.

## <a id="set-trackedregvalue"></a>`Set-TrackedRegValue`

Sets a registry value **and** records its prior state so `-Uninstall` can restore it
(`prevAbsent=true` ⇒ the value did not exist ⇒ uninstall removes it).

- **`ValidateSet` is `'String','DWord'` ONLY.** The other arms were dead and each carried a latent
  restore bug — `type` records what we *wrote*, not the prior kind. Re-add one only together with a
  `GetValueKind()` capture of the prior type.
- **It has its own internal `-DryRun` guard.** The original callers guarded externally, but a new caller
  that forgot would write to HKLM during a dry run.
- **`-WarnIfPresent` is opt-in.** When a caller passes it, replacing SOMEONE ELSE'S value says so out
  loud — a silently clobbered `ManagedBookmarks` or deliberately-`0` `BookmarkBarEnabled` is invisible
  in the transcript until someone complains. Callers that omit it clobber quietly; the prior state is
  recorded either way.
- **It records the KEYS `New-Item -Force` is about to create**, walking UP from the path to the
  shallowest ancestor that doesn't exist yet. Without this, restoring the *values* still leaves the empty
  *keys* behind — a phantom OPOS device ([#step-4b-ii](#step-4b-ii)).
- **Both `New-Item` and `New-ItemProperty` are `-ErrorAction Stop`, and the manifest row goes AFTER the
  write.** `$ErrorActionPreference` is `'Continue'`, so a refused write (ACL, policy, wrong type on an
  existing value) was non-terminating and this function recorded a value it never wrote — the same lie
  the printer readback exists to catch, one layer lower and for every caller. Likewise a refused
  `New-Item` still appended every walked ancestor to `regKeysCreated`, so the manifest shipped rows for
  keys that do not exist and `-Uninstall` counted each as a removal failure.

## <a id="uninstall-phase"></a>`Invoke-UninstallPhase`

**The read is `-ErrorAction Stop` + `return 1`.** `ConvertFrom-Json` is non-terminating under
`'Continue'`, so a manifest truncated by a kill mid-write left `$man = $null`, every `$man.<list>` read
as empty, the phase removed nothing and **returned 0** — an RMM marked the decommission clean with the
whole product installed. `Save-Manifest` already refuses to clobber that file for the same reason; the
reader needs the matching guard or that preservation buys nothing.

### <a id="counting"></a>Every reversal failure is COUNTED

`$uninstallFailures` used to be incremented in one place; everything else was `Warn`-and-return-0. The
summary line therefore says "reversal(s)", not "product(s)". The load-bearing case:
`AlleavesAuto-FinishUser` surviving keeps clearing `Taskband` and re-applying our pins at every logon.

Every reversal now counts — deletes and restores, task unregister and re-enable, value restore (the
`(default)` arm included, whose *inner* try/catch used to intercept before the outer counter), key
removal, `Taskband`, pinned `.lnk`, and `Remove-InstallShieldOrphans` (which could not reach the counter
at all and now **returns a failure count**). Two deliberate **non**-failures: a `filesPlaced` directory
that still holds someone else's files, and a `regKeysCreated` key that still has subkeys.

`-DryRun` does not increment for any *attempted* removal — `Invoke-SilentUninstall` returns `$true`
under it. One arm is exempt on purpose: the `if (-not $cmd)` return sits **above** the dry-run return, so
an ARP entry with no `UninstallString`/`QuietUninstallString` returns `$false` even under `-DryRun` and a
dry `-Uninstall` exits 1. That is a **true prediction** — the real uninstall would fail on that entry —
obtained without writing anything, which is exactly what a dry run is for.

### Steps

**<a id="step-1"></a>1 — remove files we placed.** `-LiteralPath`, like 1b — see
[INSTALL-ENGINE.md#literalpath](INSTALL-ENGINE.md#literalpath) — or a bracketed path reports "already
gone" and is skipped uncounted.

`filesPlaced` **can hold a directory** (`Copy-MasterList` records a Documents folder it had to create,
after the `.nlbl`, so the in-order walk empties it first). If the cashier has since put their own files
in it, it is left alone and **uncounted** — a folder holding someone's documents is the right outcome,
not a reversal failure.

**<a id="step-1b"></a>1b — restore pre-existing files.** Must run AFTER the deletion loop, which removes
the path this restores to.

**<a id="step-2"></a>2 — uninstall products in REVERSE order.** **`'fail'` rows are replayed too, not
just `'ok'`** (`$allowedResults`; `-DryRun` additionally replays `'dryrun'`): a row recorded fail
routinely leaves a live ARP entry and partially copied files
([INSTALL-ENGINE.md#already-installed](INSTALL-ENGINE.md#already-installed)), so skipping those
stranded exactly the installs most in need of reversing. A row for something never installed costs
nothing — `Find-InstalledProducts` finds no match and skips it with a warning.

**<a id="step-2b"></a>2b — sweep InstallShield orphans.** Gated on `method -eq 'iss-silent' -or
note -eq 'msi-fallback'`; see [INSTALL-ENGINE.md#iss-fallback](INSTALL-ENGINE.md#iss-fallback) and
[#installed-method](#installed-method).

Also removes the **orphaned CoreScanner SCM service**: the driver MSI uninstall deletes the binary but
can leave the service registration (Stopped, `ImagePath` missing). Guarded by "binary gone" so a live
CoreScanner another vendor owns is never touched — and **the `-DryRun` test sits INSIDE that guard**,
because outside it the preview announced the one destructive act the guard exists to prevent.
`$LASTEXITCODE` is read, for the same reason as the NiceLabel service sweep: `sc.exe` writes failures to
**stdout**, so `| Out-Null` suppresses nothing.

**<a id="step-3"></a>3 — bootstrap deps.** Reported, never removed.

**<a id="step-4a"></a>4a — unregister the per-user logon task.** By `name` only; the row's `path` is
unused here.

**<a id="step-4b"></a>4b — restore tracked registry values.**

<a id="stale-rows"></a>A retired printer device's rows **merge forward forever** (see
[PRINTER-OPOS.md#stale](PRINTER-OPOS.md#stale)), so this step must tolerate them:

- **Skip a value that is already gone.** `Remove-ItemProperty` on a path that no longer exists **throws**
  — `-ErrorAction Stop` handed it straight to the counting catch. After any computer rename, or the
  2026-08-12 drawer retirement reaching an already-deployed terminal, that is ~27 counted "reversal
  failures" and exit 1 on a decommission that actually succeeded, permanently.
- `Get-ItemProperty -Name '(default)'` throws `PSArgumentException` on a key with no default, so
  `SilentlyContinue` correctly yields `$null` there — the guard has to be right for the alias too.
- **The restore arm must NOT `New-Item` the key back.** That resurrects the OPOS device a rename (or the
  drawer retirement) just retired — a phantom device created by the uninstall whose job is to remove
  them. A restore only means anything while the key that owns the value still exists.

<a id="default-value"></a>**`Remove-ItemProperty` CANNOT delete a key's `(default)` value.** `-Name
'(default)'` throws "Property (default) does not exist" and `-Name ''` fails parameter binding. Only a
writable handle can:

```powershell
[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($sub, $true).DeleteValue('', $false)
```

Three things are counted, not narrated, in that arm:

- a recorded path **not under HKLM** — `LocalMachine.OpenSubKey` reads anything else as a *relative*
  subkey and returns `$null`, and the row has no `hive` field to do better with ([#keys](#keys))
- a **null handle** — the `Get-ItemProperty` test one line up just proved the value exists, so null
  means access denied
- `OpenSubKey` **throwing** `SecurityException` (it does not return `$null`) when write is denied

The non-`(default)` deletion is `-ErrorAction Stop`: its `Ok "removed …"` is unconditional, so
`SilentlyContinue` reported removals that never happened.

**<a id="step-4b-ii"></a>4b-ii — remove registry KEYS we created.** Restoring values is not enough: an
empty `…\ServiceOPOS\POSPrinter\<name>` key is a **phantom device** that OPOS still enumerates and that
fails on open. Measured on the rig: the POS-X vendor uninstaller removes its files, ARP entry and CCO
registrations but **leaves every OPOS device entry behind**, so this is load-bearing.

Deepest-first, guarded on **`SubKeyCount` only**:

- value count is deliberately **not** checked: every value under a `regKeysCreated` key is ours by
  construction, and a key whose only value is the `(default)` ProgID reports `ValueCount=1`, so an "only
  if empty" test would never fire on exactly the key that must go.
- a **subkey** stops the removal (and `Remove-Item` is non-recursive for the same reason) — it may be a
  co-installed vendor device that landed under us. That refusal stays **uncounted**: deletion is
  deepest-first, so a surviving child is foreign and counting it would exit 1 on every multi-vendor box.
- `Get-Item` is **`-ErrorAction Stop`** — without it a denied or locked key returns `$null` under
  `'Continue'`, `$null.SubKeyCount -gt 0` is `$false`, and the guard fell through to `Remove-Item` on a
  key it could not even read.

**<a id="step-4c"></a>4c — re-enable tasks we disabled.** Only those recorded as enabled when disabled;
re-enabled with `-TaskPath $dt.path`, so the row's `path` is required. Old manifests have no `prevState`
→ treat as enabled (the function only ever recorded tasks it actually disabled).

**<a id="step-4d"></a>4d — restore Taskband for any LOADED user hive**, keyed by `sid`, and remove that
SID's `TaskbarApplied` marker ([FINISHING.md#backup-loadedtaskbands](FINISHING.md#backup-loadedtaskbands)).
Profiles not loaded now are cosmetic-only: removing the XML won't re-pin Edge.

**<a id="step-4e"></a>4e — drop OUR pins from each user's pinned-taskbar folder.** Explorer copies the
`.lnk` there, so step 1's `filesPlaced` sweep strands a pin aimed at a deleted exe; exact
`$TaskbarPinNames` match only — [FINISHING.md#pinned-lnk](FINISHING.md#pinned-lnk).

### <a id="not-reverted"></a>Not reverted, on purpose

`computerRenamed` (restoring a factory-random name is pointless), `teamViewerRemoved`,
`scannerConfigured` ([SCANNER-OPOS.md#uninstall](SCANNER-OPOS.md#uninstall)), and `accountCreated` — the
terminal is signed into it and its Documents holds the `.nlbl`. `Invoke-UninstallPhase` merely prints a
note for all four; the `removable` key is read at exactly one place, `Remove-StalePrinterOpos`
([PRINTER-OPOS.md#removable-guard](PRINTER-OPOS.md#removable-guard)).
