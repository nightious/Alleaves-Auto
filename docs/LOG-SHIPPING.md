# Log shipping

Every real run posts one message to the private Slack channel `#autoinstall-logs` in the `Alleaves`
workspace, so a rollout can be reviewed without Splashtopping into terminals one at a time. The log file
and the manifest stay on the terminal and remain the authority — the Slack message is a **summary and an
index**, not a replacement.

`Send-RunSummary` is the only outbound `POST` in the codebase. Everything else on the wire is a BITS or
`WebClient` **GET** of an installer, so this is also the only traffic a site firewall or an endpoint
product might flag as exfiltration. It is deliberately one request, to one fixed host, per run.

## <a id="webhook"></a>The webhook URL is encoded, not secret

`$script:SlackHook` holds a base64 blob decoded at startup. A Slack incoming-webhook URL is a **bearer
credential** — anyone holding it can post into the channel — and it is sitting in a file that is published
as a public release asset. That is not an oversight, and the encoding is not an attempt to fix it:

- The `.ps1` **must** be world-readable. `nightious/Alleaves-Auto` going private breaks every `.bat`
  already on a terminal ([BUILD-BAT.md#dist-repo](BUILD-BAT.md#dist-repo)), and the repo already publishes
  nine Google Drive `FileId`s and the default NiceLabel key.
- There is no release-time injection lever. `release.ps1` uploads the committed file byte-for-byte and its
  dirty-tree gate exists specifically to enforce `uploaded == committed`.

So the URL is public either way. What the encoding actually buys is **survival**: Slack scrapes public
GitHub for plaintext webhook URLs and silently revokes the ones it finds, and a revoked hook answers `404`.
A plaintext URL here would work for days and then stop, with the only symptom being a channel that quietly
went dead. Base64 defeats that regex.

State the other half honestly: the same move **opts out of Slack's auto-revocation**. That scanner is not
only a false-positive generator — it is the one mechanism that kills a published hook without anybody
noticing it was published, and hiding the URL from it means an abused hook keeps posting until a human
sees the channel filling with junk and rotates it by hand. The trade is accepted, not overlooked: a hook
that cannot be silently revoked for being public is also a hook nobody else will revoke for us.

The exposure that remains is real but small: the blast radius is *posting into one private internal log
channel*. Treat the channel as append-only and low-trust, and never widen the app's scopes past
`incoming-webhook` — that scope cannot read anything.

**Rotation is a release.** Delete the webhook in the Slack app config, add a new one bound to the same
channel, re-encode, commit, and ship. There is no runtime lever, by design — a runtime fetch would just move
the same public string one hop and add a network dependency to the one moment you most want a report.

## <a id="payload"></a>What gets posted

Incoming webhooks **cannot attach files**; uploading the log itself would need a bot token with
`files:write`, a far stronger credential in the same public artifact. So the message is a two-card
attachment built from the manifest and the transcript:

| Card | Part | Content |
|---|---|---|
| 1 | `title` | `:x: TILL-03 - install failed` — clamped at 150 |
| 1 | `fields` | Result, Elapsed, Products, Dependencies, Scanner, Printer, Renamed — all `short`, so they pair into two columns |
| 2 | `text` | *Failed* (the failing items **by name**), *Flagged lines*, *Log tail* |
| 2 | `footer` | user, log path |

Anything with nothing to say is skipped, so a clean run collapses to a **single** card: title, grid,
footer. The field list has a fixed maximum of **seven**, so it needs no cap. The title clamp stays despite
the terminal name being at most 15 characters on Windows: `-ComputerName` is caller-supplied text on its way
to a network API, and the Windows ceiling binds the *rename*, not every path that reaches this string.

**`-Uninstall` posts a thin card, by design.** `$Manifest` is only assigned in the config-only and install
branches, so an uninstall run formats against a null manifest and degrades to Result, Elapsed, the tail and
the log path, with **no `user` footer**. `Format-RunSummary` handles that and the test proves it. Do not
code around it — an uninstall's authority is its own log, and manufacturing a manifest for the card would
mean writing one on the single branch that deliberately does not.

**Two cards rather than one**, because a single attachment renders `text` *before* `fields` — which
buries the summary grid under a wall of log output on exactly the runs you most want to skim. Splitting
them puts the grid on top and the detail underneath, and the rail runs unbroken down both.

**The flagged-lines block is the point of the whole card.** `Send-RunSummary` scans the *entire*
transcript for `[FAIL]` and `[WARN]`, not just the tail — a step that failed early leaves nothing in the
last 60 lines, so a tail-only message would show a count and a screenful of unrelated success. That block
keeps the **first** 25 matches, because the first failure is usually the cause of every one after it.

Result codes stay verbatim (`fail-extract`, `already-present`). Only the *labels* become words. A
code-to-prose mapping table would rot the first time a new code appears, and the codes mean something to
whoever reads this channel.

**The ok-set is per list.** `Get-FailedRows` defaults to `ok`/`dryrun`, and each call adds the success codes
that list actually uses: `already-present` for `dependencies`, `already-opos` for `scannerConfigured`,
`already-configured` for `printerConfigured`. Those sets mirror **both** the exit tally's
`$failed`/`$depFailed` **and** the config-only "did anything change" floor
([ARCHITECTURE.md#config-only-modes](ARCHITECTURE.md#config-only-modes)) — the two places the script has
already ruled on what counts as success. A missing code does not under-report; it does the opposite. The
scanner and printer sets were once absent, so a re-run over an already-configured terminal exited **0** and
still posted `*Failed*` / `- DS2208 (already-opos)`. A review channel that cries wolf gets muted, and a
muted channel is worth less than no channel.

**The card reads `$script:SummaryManifest`, not `$Manifest`.** It is captured immediately before
`Save-Manifest` in the install and config-only branches both, because `Save-Manifest` merges prior-run rows
back into `$Manifest` **in place** — the exact bug the exit tally is snapshotted against
([ARCHITECTURE.md#tally-snapshot-ordering](ARCHITECTURE.md#tally-snapshot-ordering)), inherited here because
the card was added downstream of that merge and never got the same treatment. It is not theoretical: step 0b
pushes every non-chosen printer brand into `$SkipPrograms` on every run, so a `fail-extract` on a brand this
site no longer uses would ride along in every future green card, permanently.

The snapshot is a `ConvertTo-Json -Depth 6 | ConvertFrom-Json` round trip, **not `.Clone()`** —
`New-InstallManifest` returns an `[ordered]` hashtable and `OrderedDictionary` has no `Clone()` method, which
a dry run caught after the unit tests were already green. The consequence is worth stating: `Format-RunSummary`
is handed **`PSCustomObject`s** in production and hashtables in the test, so the test formats both and asserts
they agree. `Send-RunSummary` falls back to the live `$Manifest` when the snapshot is `$null`, which covers
`-Uninstall` and the exit-9 path, where neither exists.

The terminal name comes from `Get-PosNamePrefix`, **not** `$env:COMPUTERNAME`. After a rename,
`$env:COMPUTERNAME` stays stale for the entire run because `Rename-Computer` only lands on reboot, so every
message from a freshly-imaged terminal would otherwise carry the OEM name
([PRINTER-OPOS.md#ldn](PRINTER-OPOS.md#ldn)).

`Format-RunSummary` is pure — no registry, no filesystem, no network — and returns the payload **object**,
not a string, so `tests\Test-LogShipping.ps1` can run it and assert on the serialized JSON.
`Send-RunSummary` owns all the I/O. That split is the only reason any of this is testable.

Two serialization traps, both silent, both covered by the test:

- **`ConvertTo-Json -Depth 10` is load-bearing.** The default depth is **2**, which turns the nested
  `fields` into the literal string `System.Collections.Hashtable` and earns a `400` from Slack.
- A clean run emits exactly **one** attachment, and a one-element array that serialized as an object would
  be rejected. The test asserts the `[` is still there.

**Slack truncates legacy attachment `text` at exactly 8000 characters.** This is measured, not
documented — Slack's docs give 40000 (hard message truncation), 4000 (a recommendation) and 3000 (the
**Block Kit section** cap, which does *not* apply here — this card is legacy attachments,
[#colour](#colour)). A 12000-character probe with a position marker every 100 chars came back holding
offset 7900 and missing offset 8000. Re-measure the same way if Slack ever changes it: post markers, then
search the channel for a late one — search only indexes what actually landed.

`$MaxDetail = 7990` is that cliff minus ten, and it is a **total** across the detail card, not a per-part
figure. The earlier per-part-only budget could reach ~8200 combined and silently lose the end of the log
tail. `$Budget = 2800` still caps *Failed* and *Flagged lines* so neither can crowd the other out.

The tail is trimmed a line at a time *from the top*, so the newest output always survives — and a single
line fatter than the budget still ships a **clamped** tail block. It used to ship none at all: the trim
loop broke on its first iteration, the emit guard then read false, and the block vanished. A `[FAIL]` line
carrying a full argument dump is plausibly that long, and the failure mode was silence exactly where the
failure text belongs.

**The tail takes the leftover room rather than its own budget**, because it is emitted last and is already
capped upstream at 60 lines. Giving it the headroom the other two parts left unused means fewer of those 60
get trimmed; with everything maxed at once the card lands at ~7900 and still carries all 60. Clamping the
*joined* text instead would have cut the newest lines — the exact thing the top-trim exists to protect.

## <a id="colour"></a>Why legacy attachment fields and not Block Kit

`color` carries the rail: `good` green for exit 0, `warning` yellow for the non-fatal `4`/`6`/`7` **and for
`9`**, `danger` red for everything else. Scanning a week of rollouts becomes a glance down the left margin.
The named presets are used rather than hex — they are exactly the three states and they track Slack's own
theme.

`9` is deliberately not red. An armed account swap is a healthy terminal rebooting to finish itself
([ARCHITECTURE.md#exit-codes](ARCHITECTURE.md#exit-codes)), and a red card reading *failed* is precisely
what gets a tech dispatched to a box that needs nobody — the outcome exit 9 exists to prevent. It carries
its own `$meaning`, `account swap - rebooting to resume`, for the same reason.

This card was **built with Block Kit first and rewritten**, because of a behaviour no documentation states:

> An attachment carrying `blocks` accepts `color` and returns `ok`, **but no rail is drawn.** The same
> attachment using the legacy `title` / `fields` / `text` fields draws it.

That was confirmed by posting both side by side into this channel. So the choice is not "modern API vs
legacy API" — it is **rail or no rail**, and the rail is the whole reason the channel is skimmable. Slack
calls attachments legacy, and this is a deliberate exception.

What the legacy fields give up against blocks is only the large `header` font; `fields` still render as a
two-column grid and `mrkdwn_in` still gives bold and fenced code. If Slack ever drops attachments, the
content maps onto blocks one-for-one and only the rail is lost.

The install-path post happens in the `finally`, **after `Stop-Transcript`**. The transcript has to be closed
first or the tail is read from a file that is still being buffered. The cost is that the post's own console
output is not captured in the log — the same console-only window that already exists before the transcript
opens ([ARCHITECTURE.md#run-shape](ARCHITECTURE.md#run-shape)) — which is why the outcome is written back by
hand ([#fail-soft](#fail-soft)).

## <a id="redaction"></a>Redaction

The tail is transcript text, and posting it to a third party **is** recording it, so the same
`LICENSECODE=` rule applies as at the `$safeArgs` site in `Invoke-Installer`. The source sites already
redact before printing, so this is a second pass over ground that should already be clean — which is the
point. A log tail is the one payload that carries arbitrary text nobody reviewed, and it is the one payload
leaving the machine.

## <a id="hook"></a>Where it runs, and why it cannot fail the install

`Invoke-Step 'Slack run summary' { Send-RunSummary -ExitCode $exitCode }` sits in the `finally` block after
`Stop-Transcript`. Two properties make it safe:

- `$exitCode` is **final** there. The top-level `catch` has already run, and the step sits past the exit
  tally, so even `Invoke-Step`'s `$script:StepFailed` backstop cannot retroactively fail a clean install.
- `Send-RunSummary` swallows its own errors, so `Invoke-Step` is only a second net.

**The whole block is defined above the pre-dispatch guards, not beside that hook.** `$script:RunStart`,
`$script:SlackHook`, `Set-Tls12`, `Get-PosNamePrefix` and the five summary functions sit immediately after
`Invoke-AccountSwapOffer`, thousands of lines from their main caller. PowerShell defines a function when
execution reaches it, in **source order**, so a definition parked down by the dispatch tail does not exist
yet when the exit-9 path runs: the call throws `CommandNotFoundException` and the swap posts nothing. The
placement reads as arbitrary and is not — do not tidy it back down next to the hook. `$Mode` is *assigned*
below the definitions, which is fine: it is resolved when `Send-RunSummary` runs, not when it is defined.

**The second send site is exit 9**, `Invoke-Step 'Slack swap summary' { Send-RunSummary -ExitCode 9 }`
immediately before its `exit` ([#gap](#gap)). The step label differs from the `finally` hook's on purpose:
`tests\Test-LogShipping.ps1` finds the hook with `IndexOf("Invoke-Step 'Slack run summary'")` to assert it
is ordered after `Stop-Transcript`, and `IndexOf` returns the **first** match. A duplicate label would match
the exit-9 call instead — which sits ~3000 lines earlier — and the assert would fail on a perfectly correct
file. Keep the two labels distinct.

## <a id="fail-soft"></a>Fail-soft, and never yellow

A failed post reports through `Info`, never `Warn`. Yellow means *a human at this terminal needs to look at
this* ([CONVENTIONS.md](CONVENTIONS.md)), and an unreachable `hooks.slack.com` is not something the tech
standing at the POS can act on — the install itself is fine and the log is on disk. Making it yellow would
train techs to ignore yellow.

There is no retry and no queue. One `POST`, a 15-second timeout, then give up: the alternative is hanging
the installer at the very end of an otherwise successful run, on a network the terminal may not even have
yet. A dropped summary costs one terminal read the old way.

**The outcome is appended to `$RunLog` by hand.** `Send-RunSummary` runs after `Stop-Transcript`, so its
`Ok` / `Info` line reaches the console and nothing else — and on an unattended or RMM run there is no
console to reach. Both paths therefore set one `$msg`, print it, and an `Add-Content` writes
`  [slack] <msg>` into the log, guarded on the file existing. The single fact most worth having a week
later is *the summary did not post*, and it was the one fact recorded nowhere durable.

The reason comes from **`$_.ErrorDetails.Message`**, falling back to `$_.Exception.Message`. Slack states
the real fault — `invalid_payload`, `no_text`, `channel_not_found` — in the response **body**, which a
PS 5.1 `WebException` drops from `.Exception.Message`, leaving an unactionable `(400) Bad Request`.
PowerShell has already captured that body in `.ErrorDetails`.

`Set-Tls12` is called here explicitly. It is process-wide, but it only fires in `Invoke-DownloadPhase` and
`Install-VcRedist` — an `-Uninstall` or config-only run reaches this point having never set it.

## <a id="gap"></a>Pre-dispatch exits: `9` posts, the rest stay silent

Exits `2`, `3`, `5` and `8` ([ARCHITECTURE.md#exit-codes](ARCHITECTURE.md#exit-codes)) return before the
transcript is opened, so they never reach the `finally` and never post. That stays deliberate: a
fat-fingered flag, a non-elevated launch or a blocked account precheck is a tech-at-the-terminal problem,
there is no log to attach at that point, and a channel carrying them is a channel nobody skims.

**Exit 9 is the exception and does post**, from its own call site before the `exit` ([#hook](#hook)). It is
the one pre-dispatch exit with real value in a review channel: *account swap armed, the box is rebooting to
resume itself, do not dispatch anybody*. Without it the terminal simply goes quiet mid-rollout, which reads
exactly like a dead one.

That card is necessarily thin — no transcript to tail, no manifest to tally, and `$ModeBanner` not set yet
so the mode falls back to `$Mode`. It is Result, Elapsed and the terminal name, in yellow ([#colour](#colour)),
which is the whole of what is worth saying. The `-DryRun` early return still applies, so a dry run of the
swap path posts nothing.
