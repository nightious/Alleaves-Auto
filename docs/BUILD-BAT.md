# The `.bat` transport

`alleaves_setup.ps1` is the **source of truth**. `Install-Alleaves.bat` is a **fetching stub** — it carries
no payload, it downloads the current `.ps1` from the latest release and runs that — and is the whole
deliverable.

It is ~90 lines of plain cmd, checked in and hand-edited like any other source file. **Nothing generates
it, and it does not change when the `.ps1` changes** — that is the entire point: a `.bat` a terminal
downloaded a year ago runs today's installer. Write it ASCII, no BOM, CRLF; a BOM on line 1 breaks
`@echo off`.

## <a id="fetch"></a>The fetch

```
https://github.com/nightious/Alleaves-Auto/releases/latest/download/alleaves_setup.ps1
```

`releases/latest/download/…` is GitHub's own redirect to the newest non-prerelease asset of that name, so
the URL is a constant and what it resolves to is whatever `release.ps1` published last. **There is no
version check, no pin lever and no cached fallback**, deliberately: always-latest is the feature, and a
cached copy would only help in a no-network case where the install dies at the first Google Drive download
anyway ([INSTALL-ENGINE.md#download](INSTALL-ENGINE.md#download)). Roll back with `gh release delete`,
which re-points `latest` ([#dist-repo](#dist-repo)).

This trades a build-time integrity guarantee for HTTPS plus GitHub at run time. There is no way to keep
both: a pinned hash in the `.bat` *is* a pinned version. Four properties of the fetch block carry what is
left, and an edit must keep all four:

1. **`.part` staging, renamed on success.** `WebClient.DownloadFile` leaves a partial or zero-byte file
   behind when a transfer dies mid-stream, and the only guard here is `if not exist` — against the real
   name that check would pass and a truncated script would run against a terminal. Renaming only after the
   download returns is what makes `if not exist` a genuine success signal. Same `.part` idiom as
   `Get-FileWithRetry` ([INSTALL-ENGINE.md#download-retry](INSTALL-ENGINE.md#download-retry)).
2. **A parse check, `[ScriptBlock]::Create`, not a minimum byte count.** It rejects a truncated script
   *and* a 404 / captive-portal HTML page, and leaves no magic number to go stale as the `.ps1` grows.
   `Test-RealBinary` is the wrong tool here — it matches PK/OLE/MZ magic bytes and would reject any text
   payload.
3. **TLS 1.2 set before the request**, same `3072` as `Set-Tls12` in the installer.
4. **Both temp names pre-deleted**, `.ps1` and `.part`. The fetch's exit code is never checked, so a run
   killed between the download and the trailing `del` leaves the *previous* release's `.ps1` in `%TEMP%` —
   and a later run whose fetch failed then ran THAT against a terminal, with its exit code attributed to
   the new build. (That is a real incident from the base64 era; the mechanism survives the transport
   change unchanged.)

A failed fetch exits **10, not 9**: an RMM that read 9 here concluded the terminal was coming back to
finish itself and skipped it, when the script never ran at all. **10 is launcher-only** —
[ARCHITECTURE.md#exit-codes](ARCHITECTURE.md#exit-codes). Its pause honours `ALLEAVES_NOPAUSE`, unlike the
relaunch below: a network failure is ordinary, and a bare `pause` hangs an unattended run forever.

One retry, no backoff, is on purpose. `Get-FileWithRetry`'s four attempts exist for 600 MB Drive
transfers; this is a 200 KB GitHub asset, and "re-run it" is the same recovery with none of the code.

## <a id="elevation-probe"></a>The elevation probe

Single elevation owner; the `.ps1` never relaunches itself. **All three properties below guard one failure:
a fork bomb.** A probe that answers "not elevated" sends the `.bat` down the RunAs relaunch, and no UAC gate
stops an already-elevated token — so the child re-runs the same probe, gets the same wrong answer, and
relaunches again, unboundedly. The probe must be right about elevation and must **abort** rather than
relaunch when it cannot tell. Any future edit keeps all three.

1. **BOTH elevated-integrity SIDs**, `S-1-16-12288` (High) and `S-1-16-16384` (System), on one `findstr`.
   Matching High alone forked on any RMM dispatching the `.bat` as SYSTEM, while the `service-account`
   exit-8 verdict written for that account never reached the operator — see
   [ACCOUNT-SWAP.md#verdicts](ACCOUNT-SWAP.md#verdicts).
2. **Every System32 tool by FULL PATH** (`%SYS32%`, with `if not exist` → `:probefail` on `whoami.exe`),
   never a bare name: the bare name resolves through `PATH`, and a git-bash / MSYS / Cygwin shell puts its
   own GNU `whoami` first, which rejects `/groups` and exits 1 — the same fork, reached through a shadowed
   command name (observed 2026-09-13, hundreds of UAC prompts deep). `findstr` and the mode test's `find`
   are shadowed the same way: measured here, GNU `find` swallowed `/i` as a path and the requested mode was
   never recorded.
3. **Abort when the probe cannot answer.** A second probe for any `S-1-16-*` mandatory label sits behind the
   first, because a working `whoami` always prints one. No label means the *probe* is broken, not that the
   token is unelevated, so that case goes to `:probefail` → **exit 3**.

**Relaunch mechanics.** `-Wait -PassThru` so the non-elevated launcher waits for the elevated child and
propagates its real exit code. **`exit /b` MUST stay OUTSIDE any `( )` block**: inside a parenthesized
block cmd freezes `%ERRORLEVEL%` at parse time to the find result (=1), reporting a successful install as
a failure. That is now free — there is no block, because neither `%*` nor `%~f0` may appear inside the
relaunch's `-Command "…"` string ([#args](#args)), for two separate reasons one underneath the other
([#relaunch-args](#relaunch-args)). `%ERRORLEVEL%` is captured into `RC` before the args-file `del`,
which would otherwise clobber it.

Treat the relaunch as **interactive-only** — `ALLEAVES_NOPAUSE` has not been observed to survive the UAC
boundary (nothing in the `.bat` forwards or tests it across that call, so that is field behaviour, not a
code fact), and RMM callers should invoke it already-elevated.

## <a id="args"></a>Argument forwarding

`%*` forwards all args in one expansion, so:

- **Quote any `-SkipPrograms` regex containing cmd metacharacters** (`| ^ & < >`), e.g. `-SkipPrograms
  "Chrome|NiceLabel"` — unquoted they are interpreted by cmd and get mangled. Callers needing exotic regexes
  should invoke `alleaves_setup.ps1` directly.
- <a id="relaunch-args"></a>**Neither `%*` nor `%~f0` may sit inside the non-elevated relaunch's
  `-Command "…"` string.** cmd counts quotes left to right, so the caller's own `"` closed the one
  opened before `exit` and the `|` in `"Chrome|NiceLabel"` became a real pipe — the documented
  invocation simply did not elevate, while running the `.ps1` directly worked. A `)` in any argument
  ended the `if ( )` block the same way, and an apostrophe in the checkout path ended `'%~f0'`. Both now
  travel out of band: the path in `ALLEAVES_SELF`, the args written **redirection-first** to
  `%TEMP%\alleaves_args.txt` (`>"%TEMP%\…" echo.%*`, never the glued form — cmd can read a trailing digit
  as a handle — and where the caller's quotes stay balanced) and read back with `Get-Content`. The
  relaunch line itself contains only single quotes.

  **That fixes the cmd-parse layer, and there is a second one underneath it.** `Start-Process -Verb
  RunAs` on a `.bat` cannot carry a quoted argument at all: ShellExecute hands the batch to `cmd /c`,
  and `cmd /c` with more than two quotes on the line strips the *outermost pair* off the whole tail —
  which eats the opening quote of the batch path. The child then never starts, silently: no error, exit
  1 (or 255 once an unquoted `|` is re-exposed). `Install-Alleaves.bat -ComputerName "POS-1"` — the
  invocation in `README.md` — took that path. So the relaunch targets **`%ComSpec%`, not the `.bat`**,
  with the tail double-wrapped, `/c ""<self>" <args>"`: the pair `cmd /c` strips is the one added for
  it to strip, and the batch path and every caller quote arrive intact. Verified across no args,
  `-Uninstall`, unquoted, quoted, quoted-with-space, and `-SkipPrograms "Chrome|NiceLabel"`.
- The requested mode is recorded in `ALLEAVES_REQUESTED_MODE` so the `.ps1` can refuse a dropped
  `-Uninstall` (exit 2) — matched as a whole ` -uninstall ` token
  ([ARCHITECTURE.md#argument-guards-exit-2](ARCHITECTURE.md#argument-guards-exit-2));
  `ALLEAVES_NOPAUSE=1` skips the trailing pause.

`-ExecutionPolicy Bypass` loses to an `AllSigned`/`Restricted` GPO; if that ever bites on a managed fleet,
switch to piping via `-EncodedCommand`.

## <a id="dev"></a>Dev run

`PowerShell -File .\alleaves_setup.ps1 -DryRun` — no admin needed, and `-DryRun` falls back to `%TEMP%` for
its working root. Nothing to build first: the `.bat` fetches the *published* `.ps1`, so it never runs local
edits. Test edits against the `.ps1` directly, and the `.bat` only after a release.

## <a id="dist-repo"></a>One repo, and it must stay public

> **`nightious/Alleaves-Auto` going private breaks every installer in the field.** Not "the download
> page 404s" — every `.bat` already on a terminal fails at the fetch and exits 10, because
> `releases/latest/download/...` needs a token on a private repo. This is the single operational
> constraint the whole transport rests on.

That constraint used to be served by a **split**: a private source repo plus a public
`nightious/Alleaves-Install` holding nothing but the assets, because a private repo cannot serve an
anonymous download link. The split was deleted on 2026-09-14 and the dist repo with it — once the
source repo is public, one repo does both jobs and the second was pure indirection. `release.ps1`
passes no `--repo`; `gh` resolves it from `origin`.

**Publishing is a deployment.** The `.ps1` uploaded here is what every `.bat` already in the field runs
on its next double-click, not merely a new download someone may or may not take. And shipping a release
without the `.ps1` asset makes every stub 404 — `release.ps1` uploads the pair for that reason.

Public means public: `docs/`, `tests/` and the history are readable, and so are the nine Google Drive
`FileId`s and the default NiceLabel key in `alleaves_setup.ps1`. That exposure predates this — the
`.ps1` was already base64 inside a public `.bat`, which is the same exposure with a decode step in
front of it. Asked and answered; don't re-litigate it, and don't "fix" it by going private.
