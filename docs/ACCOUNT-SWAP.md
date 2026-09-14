# Account precheck and swap

Exit 8 (blocked) and exit 9 (swap armed, rebooting to resume). See
[ARCHITECTURE.md#exit-codes](ARCHITECTURE.md#exit-codes).

## <a id="why"></a>Why elevation is not the question

"Is this process elevated?" is **not** "is this terminal signed into a local admin account", and two real
failures live in the gap:

- a **Microsoft account** profile ties the cashier terminal to someone's personal MSA (Store/sync, and
  OneDrive can redirect Documents — exactly where the `.nlbl` master list is copied). It cannot be handed
  over.
- a **standard user** can launch the `.bat` and type someone else's admin credentials at UAC. The process is
  elevated, `Test-IsAdmin` passes, exit 3 never fires — but the profile that will actually run the POS is
  not an administrator.

So the precheck reads the **signed-in** user (`Win32_ComputerSystem.UserName`), never the process token — on
that second case the token is the wrong answer for exactly the thing being tested. It sits right after the
elevation abort and **before `$WorkDir` is created**, so a rejected box gets nothing written. `-Uninstall`
skips it (a blocker there would strand a terminal that later acquired an MSA with no way to reverse the
install); `-DryRun` reports and continues, which is how the tech gets the verdict before touching the
terminal. The config-only sub-modes **do** get it; they mutate state.

`Get-SignedInAccount` falls back to `WindowsIdentity.GetCurrent()` when there is no console session
(RDP-only, service/RMM) — the one place the "never trust the token" rule is relaxed, so it **says so out
loud**: on a terminal with a console user that line should never appear, and if it does the verdict was
computed from the wrong account.

## <a id="verdicts"></a>Verdict order

`Test-InstallAccount` returns `@{ Ok; Reason; Detail }`. Order matters:

1. **Well-known SERVICE SIDs first**. Under an RMM the token fallback yields `NT AUTHORITY\SYSTEM`, whose
   backslash made `Domain` ≠ `$env:COMPUTERNAME`, so the domain arm claimed the terminal was domain-joined
   and handed the tech "create a local admin account" for a run whose only fault was having no console
   session.
2. **Domain / Entra before the SID-shape test**. An Entra SID is `S-1-12-1-*` and would otherwise fall out
   as "no interactive user", which misleads the tech.
3. An **Entra sign-in with no `DOMAIN\` prefix** gets its own arm — same verdict, accurate message.
4. SID shape, then MSA, then local-admin membership.

**An undetermined verdict must block.** The override below is explicit and recorded, so a probe that quietly
failed open would be a *second*, invisible bypass — the one thing this design rules out. `Sid` rides along
in the verdict so the promote path can add that account to Administrators by SID without re-resolving it.

## <a id="msa"></a>`Get-MicrosoftAccountId` is TRI-STATE

MSA-linked accounts still present as `COMPUTERNAME\shortname`, so the "is it local?" test does **not** catch
them — only this does.

| Return | Meaning |
|---|---|
| an email | MSA |
| `$null` | **proven** local |
| `'unknown'` | undetermined → `account-type-unknown` → block |

It returned `$null` for both "proven local" and "every probe threw", and `$null` reads as "not MSA" — so the
least-trusted branch in the function was also the only one failing *open*.

`PrincipalSource` is asked **first** and believed in both directions. The IdentityStore registry cache is
the fallback, and its *absence* cannot tell "local" from "this build doesn't populate it" — so that path is
`'unknown'`, not a pass. That cache probe is **one** function, `Get-IdentityStoreEmail`, called twice by
`Get-MicrosoftAccountId`: it returns the email or `$null` and decides nothing, because it is the probe
most likely to change and two byte-identical copies drift. Each arm maps "no answer" itself — `'unknown'`
(block) for the verdict, `'(linked email unknown)'` for the message.

> **TODO[rig]** — confirm on a real MSA terminal that `PrincipalSource` answers, so the registry fallback
> stays the rare path rather than the usual one. Neither probe has been seen against a real MSA box.

`Test-LocalAdminSid` resolves the group from **`S-1-5-32-544`** because the display name is localized: on a
non-English Windows the literal `'Administrators'` made `net localgroup` error, the loop saw nothing, and a
genuine local-admin terminal was blocked. The literal survives only as the last-resort *name* when even
`Get-LocalGroup -SID` fails.

> `ponytail:` direct members of `BUILTIN\Administrators` only — no nested-group expansion. An
> admin-via-nested-group reads as not-admin, which is the safe direction on a POS terminal.

## <a id="override"></a>Override — `Set-AccountCheckOverride`

The block is overridable but never silently: `-IgnoreAccountCheck` (unattended) or a `y` at the
continue-anyway prompt (interactive, offered after a declined swap and on the loop-guard arm, which
otherwise has no way forward). Every verdict is overridable, including `microsoft-account`.

- **`-IgnoreAccountCheck` is tested FIRST**, before `-DryRun` and the offer: an RMM run must never reach a
  `Read-Host`, and `-DryRun -IgnoreAccountCheck` must report what the real run would *do* (continue), not an
  offer it would never make.
- **`$wouldOffer` is ONE expression** read by both the preview and the real dispatch, because when they were
  two the dry run promised an offer the real run refused; `$wouldPromote` follows the same doctrine,
  computed once and passed **into** `Invoke-AccountSwapOffer`.
- `$wouldOffer` excludes the loop guard and excludes **`service-account`**: nothing about the *account* is
  wrong there, so having the tech type a new admin password "fixes" a run whose only fault was having no
  console session. That verdict therefore gets its own remediation block ("run this from the terminal's own
  signed-in session") instead of the create-a-local-admin text.
- **The prompt reuses `Confirm-Swap`**, which already defaults to NO and catches in `Read-SwapAnswer`, so a
  headless host reads as "no" and still exits 8 — don't add a second helper or default it to yes.
- **The override is manifested** (`accountCheckOverride`, record-only, `removable=$false`) because the whole
  precheck runs *before* `Start-Transcript`, so that row is the only durable trace that a terminal was
  installed over a failed verdict — hence the `whenUtc` merge key
  ([MANIFEST.md#key-selectors](MANIFEST.md#key-selectors)).

The full remediation text still prints on every path; the override changes what happens *after* the block is
reported, never whether it is reported.

## <a id="swap"></a>The swap — `Invoke-AccountSwapOffer`

On a block, an interactive run offers to create or promote a local admin, then reboots and resumes itself.

**Self-contained by necessity.** It sits *above* `$WorkDir`, `$Manifest` and `Set-TrackedRegValue` in a
top-to-bottom script, so raw cmdlets only. The facts reach the manifest via the `account_swap.json` marker
(`Clear-AccountSwapState` → `$script:AccountSwapDone` → `New-InstallManifest` seeds `accountCreated`).

The **`not-admin` path arms NO autologon**: reaching that arm already proves the account is local and
non-MSA, so promoting it in place is one `Add-LocalGroupMember` and the tech types a password they already
know. Only the create path handles a secret, because only there do we have one.

**`Read-SwapAnswer` honours `UserInteractive` + `ALLEAVES_NOPAUSE`**, like the rename and printer-brand
prompts. Without it an unattended RMM run that tripped the precheck reached `Read-Host` and, with stdin an
inherited handle rather than a console, blocked forever on "Create a local admin account and reboot?" —
the flag that means "unattended" was honoured everywhere except the one prompt that can create an account
and reboot. Declining is the safe default, so a `$null` answer degrades straight to exit 8. Gating that
one function covers all three swap prompts, since the other two sit behind `Confirm-Swap`.

`-NiceLabelLicense` is deliberately **not** persisted into the resume task (the task XML is world-readable),
but the resumed run then falls back to the built-in key, so `ConvertTo-ResumeArgs` says so out loud.

### <a id="autologon"></a>`AutoLogonCount=1`, not an LSA secret

Winlogon deletes `AutoAdminLogon` / `DefaultPassword` / `AutoLogonCount` itself when the count hits 0. The
LSA-secret route is unreadable but has **no auto-clear**, so a resume that never runs leaves the terminal
auto-logging in as an admin forever. The cost of self-clearing is one boot of a plaintext `DefaultPassword`
under a Winlogon key `BUILTIN\Users` can read. In `Set-OneShotAutoLogon` / `Restore-AutoLogon`:

- **`AutoLogonCount` first**: it is the self-clearing mechanism, so a throw after a partial write leaves a
  *countless* autologon — permanent admin sign-in with a cleartext password — on a run reporting exit 8,
  "blocked and nothing was done".
- Prior values land in `$script:AutoLogonPrior` **before the first write**, so a throw partway still leaves
  the caller's rollback able to put things back.
- The registry **kind** too, via `GetValueKind()`: an OEM or Sysinternals box can carry `AutoAdminLogon` as
  REG_DWORD, and recreating it as REG_SZ is not the pre-swap state. The hardcoded `DWord`/`String` pair in
  `Restore-AutoLogon` is only the fallback for a kind that could not be read.
- **`DefaultPassword` is captured as PRESENT, its VALUE dropped**: the marker is serialized under
  `%ProgramData%`, whose inherited ACL grants `BUILTIN\Users` read.
- `Restore-AutoLogon` therefore **removes** that value rather than writing it back — it is the one we know
  we overwrote — and verifies by read-back, since `-EA SilentlyContinue` cannot tell "already absent" from
  "could not delete".
- It returns a **count** of values that could not be put back, or `$null` when there was nothing to restore:
  nothing in it throws, so an unconditional "restored" was green after a WARN and announced a restore on the
  promote path, which arms no autologon at all.
- Autologon is deliberately **not** manifested, or a later `-Uninstall` would "restore" it onto a live
  terminal. And it ends in a **reboot, never `shutdown /l`**: `AutoAdminLogon` doesn't fire after a logoff
  without `ForceAutoLogon=1`, which is sticky in exactly the way this design avoids.

### <a id="resume-task"></a>The resume task

Runs **as the target user, `Interactive` + `RunLevel Highest` — not SYSTEM**. SYSTEM has no visible console
and step 0 is interactive; those `Read-Host`s are try/catch'd, so under SYSTEM they would silently take
defaults and the terminal would get the wrong computer name and possibly the wrong printer driver.
`Interactive` also needs no stored credential; `Highest` means elevation with no UAC prompt.
`ExecutionTimeLimit` must be `[TimeSpan]::Zero` — `Register-FinishLogonTask`'s 5-minute limit would kill a
full install mid-run. It targets a **copy** of the `.ps1` under `$WorkDir`, because the `.bat` deletes its
decoded temp copy on exit.

**`-Command`, not `-File`**. `ConvertTo-ResumeArgs` emits PowerShell *expression* syntax — single-quoted
values, comma-joined array literals — and `-File` hands each token through literally, so `-SkipPrograms
'Star','NiceLabel'` arrived as one bogus element (the resumed run re-downloaded 471 MB the operator had
excluded) and `-ComputerName 'POS 1'` split on the space.

`ConvertTo-ResumeArgs` takes `$bound` **explicitly** — inside a function the automatic `$PSBoundParameters`
would be the *function's*, not the script's. It drops **`NiceLabelLicense`** as well as `DryRun`: a task
action is persisted, readable by any standard user (`schtasks /query /xml`) and outlives the run — the
exposure `$safeArgs` redacts everywhere else. `param()`'s default hands the key back on resume.

### <a id="loop-guard"></a>`$script:AccountSwapAttempted` — the loop guard

Set by `Clear-AccountSwapState` whenever a marker existed. Without it a resume landing on a still-wrong
account offers another account, arms autologon again, and reboots — every cycle, forever. The override
**is** still offered on that arm: a resume stranded on the wrong account is exactly the case with no other
way forward, and it is a prompt, not a second reboot, so it cannot loop.

### <a id="clear-state"></a>`Clear-AccountSwapState`

Runs in **every** mode (`-Uninstall` included, which skips the precheck itself) so a stranded marker is
always cleaned — **except `-DryRun`, which reports and returns after setting the loop guard**. The `.bat`
self-elevates, so a tech who armed a swap and then dry-ran to re-check the verdict had the dry run succeed
at disarming it: autologon restored, task unregistered, marker deleted, box reboots into the old account
with nothing left to finish. Each step is guarded separately: a task that will not unregister must not stop
the autologon from being cleared, which is the one that matters.

- **`Unregister-ScheduledTask` sits OUTSIDE the `if ($m)`**: the task name is a constant and never needed
  the marker, and while it lived inside, an unreadable marker (power-off mid-write) skipped the unregister
  while deleting the marker anyway — relaunching the installer at every logon, forever, with the only record
  of it gone.
- **The unregister is VERIFIED, not assumed** (`Get-ScheduledTask` after it), because everything past that
  point destroys the ability to retry — the marker is what brings this function back and the staged copy is
  the script the task launches — so a surviving task keeps both, and only autologon is restored
  unconditionally, that being the piece that must never stay armed.
- **The resume directory is a CONSTANT**, not `Split-Path $m.scriptCopy -Parent`, which recursively deleted
  whatever the marker named as the parent — for a `scriptCopy` under the working root, the working root
  itself (manifest, logs, downloads).
- A marker that survived (AV holding the JSON) is not cosmetic: every later run re-enters this path, prints
  a green Ok for a swap that already finished, and trips the loop guard, suppressing the offer forever with
  nothing on the console saying why.
- Both terminal arms therefore raise `$script:FinishFailed` → **exit 1**: a surviving `DefaultPassword` is a
  cleartext admin password under a key `BUILTIN\Users` can read, and a surviving task relaunches the whole
  installer at every logon. Since this function runs in every mode, the dispatch tail reads that flag on all
  three branches (install, config-only, uninstall) — red console text paired with exit 0 is exactly the
  outcome an RMM cannot see.

### <a id="rollback"></a>The rollback

`$rollback` unwinds the swap **machinery** on any failure — a half-armed swap is worse than no swap, and
every piece of it is ours and seconds old (a just-created account has no profile yet). A **promotion is
deliberately NOT unwound**: that is the fix the tech asked for and it stands on its own.

- **Defined BEFORE the first destructive step**, not after the last one. Staged above it, with nothing to
  call, a failed `Copy-Item` landed on exit 8 leaving directories under `%ProgramData%` on a box the
  precheck had just refused.
- It removes those parents **only while empty**, non-recursively: on a re-run they are the working root. Its
  `Get-ChildItem` is **`-ErrorAction Stop`**, or the guard fails **open** — under `'Continue'` an unreadable
  directory returns nothing, `-not $null` reads as empty, and the non-recursive `Remove-Item` walks into the
  `ShouldContinue` prompt the test exists to avoid.
- Its `Unregister-ScheduledTask` is `-EA Stop` + a `Get-ScheduledTask` readback, for a worse case than
  `Clear-AccountSwapState`'s: this rollback runs when the **marker write** failed, so a surviving task has
  nothing to bring `Clear-AccountSwapState` back and no record on the box. The **readback**, not the
  unregister's own exception, is the verdict — the rollback also runs before the task was ever registered,
  where `-EA Stop` throws the outcome we want.
- `& $rollback; return $false` at every call site; the rollback must stay output-free (`Restore-AutoLogon`'s
  count is captured inside it) or `if (Invoke-AccountSwapOffer ...)` tests a 2-element array and a failed
  arm exits 9.

### Other traps

- **"Already a member" is matched on `FullyQualifiedErrorId`, never the message text** — the message is
  localized, so on a non-English Windows `-notmatch 'already a member'` fired on a promotion that had
  *succeeded* and rolled the whole swap back.
- **The marker is written LAST and its failure is FATAL to the swap.** It is the only record that lets the
  resumed run clear the autologon, unregister the task and record the account.
- `Confirm-Swap` deliberately does **not** gate on `UserInteractive`, which `powershell -NonInteractive`
  still reports `$true`; that test is used only where taking a default is harmless
  (`Invoke-ComputerRename` and `Resolve-PrinterBrand`), never where the answer authorizes a reboot.
- `-Uninstall` leaves the created account alone — [MANIFEST.md#not-reverted](MANIFEST.md#not-reverted).
