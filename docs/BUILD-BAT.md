# Build and the `.bat` transport

`alleaves_setup.ps1` is the **source of truth**. `Install-Alleaves.bat` is a **generated transport** —
`build-bat.ps1` base64-packs the `.ps1` into it — and is the whole deliverable.

```
.\build-bat.ps1        # after EVERY edit to the .ps1 - never hand-edit the .bat
```

## <a id="pack"></a>What the pack does

- Reads the `.ps1` as **raw bytes**, guaranteeing a byte-identical decode on the client regardless of BOM or
  line endings, then base64-encodes and chunks it into ≤4000-char lines.
- Emits a `.bat` that elevates once, transports the base64 via a **temp file**, decodes it with 64-bit
  PowerShell (`Sysnative`), runs the `.ps1` synchronously in the elevated console, propagates the exit code.
- Writes the `.bat` as **ASCII with no BOM** — a BOM on line 1 breaks `@echo off` — with CRLF.

The temp file is not optional: a single cmd variable caps at ~8191 chars, while the payload runs to a
quarter-megabyte of base64 (roughly 4/3 of the `.ps1`'s size, in ≤4000-char lines) — **~30× that cap**,
and it grows with every edit. `build-bat.ps1` prints the exact char and chunk counts on every run; do
not copy them back into this file, they go stale the next time the `.ps1` changes.

`-LiteralPath` on the source `Test-Path` and `Get-FileHash`: without it a checkout under a bracketed
directory throws "Source not found" on a file that is plainly there ([INSTALL-ENGINE.md#literalpath](INSTALL-ENGINE.md#literalpath)).

### <a id="echo-redirection"></a>Redirection first, command second

Each chunk is emitted `>>"%TEMP%\file" echo <chunk>`, never `echo <chunk>>>"%TEMP%\file"`: glued, cmd can
read a trailing digit as a **handle** (the classic `echo done 2>log` trap), and roughly one chunk in ten
ends in 0–9. The glued form measures safe on Win11 26200 — cmd only takes the digit as a handle when a
delimiter precedes it, and the base64 alphabet never puts one there — but the split form costs nothing and
removes the question. `+ / =` are not cmd metacharacters here.

## <a id="self-verify"></a>Self-verification

The build decodes the base64 back **out of the `.bat` it just wrote** — `ReadAllLines` plus a prefix-match
on the emitted echo lines — and confirms byte-length **and** SHA256 identity against the source.

> Deliberately **not** `$chunks`: that variable IS the source by construction, so comparing it to the source
> could only ever pass, and it cannot see the one kind of corruption this build step causes — a mangled
> echo line.

`[Convert]::FromBase64String` ignores whitespace, which is what lets both the verify and the client's
`ReadAllText` of the CRLF-separated temp file rejoin lines with no separator handling. Corrupt base64
**throws**, so the decode is caught: a bad build reports through the RESULT line / exit 1 contract instead
of dying with a stack trace.

<a id="corrupt"></a>**A failed self-verify renames the output to `.corrupt`**. The `.bat` is the whole
deliverable, so a corrupt one must not keep the shipping name: exit 1 alone left a plausible,
double-clickable `Install-Alleaves.bat` in the repo root, one `git add -A` from being shipped to a terminal.

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
2. **`%SystemRoot%\System32\whoami.exe` by FULL PATH** (with `if not exist` → `:probefail`), never a bare
   `whoami`: the bare name resolves through `PATH`, and a git-bash / MSYS / Cygwin shell puts its own GNU
   `whoami` first, which rejects `/groups` and exits 1 — the same fork, reached through a shadowed command
   name (observed 2026-09-13, hundreds of UAC prompts deep).
3. **Abort when the probe cannot answer.** A second probe for any `S-1-16-*` mandatory label sits behind the
   first, because a working `whoami` always prints one. No label means the *probe* is broken, not that the
   token is unelevated, so that case goes to `:probefail` → **exit 3**.

**Relaunch mechanics.** `-Wait -PassThru` on both arms so the non-elevated launcher waits for the elevated
child and propagates its real exit code. **`exit /b %ERRORLEVEL%` MUST stay OUTSIDE any `( )` block**:
inside a parenthesized block cmd freezes `%ERRORLEVEL%` at parse time to the find result (=1), reporting a
successful install as a failure. Treat the relaunch as **interactive-only** — `ALLEAVES_NOPAUSE` has not
been observed to survive the UAC boundary (nothing in `build-bat.ps1` forwards or tests it, so that is field
behaviour, not a code fact), and RMM callers should invoke it already-elevated.

## <a id="decode-guard"></a>The decode guard

The decoded `%TEMP%\alleaves_setup.ps1` is **pre-deleted** before the decode. The decode's exit code is
never checked and the only guard is `if not exist`, so a run killed between the decode and the trailing
`del` left the *previous* build's `.ps1` in `%TEMP%` — and a later run whose decode failed then ran THAT
against a terminal, with its exit code attributed to the new build.

A failed decode exits **10, not 9**: an RMM that read 9 here concluded the terminal was coming back to
finish itself and skipped it, when the script never ran at all. **10 is launcher-only** —
[ARCHITECTURE.md#exit-codes](ARCHITECTURE.md#exit-codes).

## <a id="args"></a>Argument forwarding

`%*` forwards all args in one expansion, so:

- **Quote any `-SkipPrograms` regex containing cmd metacharacters** (`| ^ & < >`), e.g. `-SkipPrograms
  "Chrome|NiceLabel"` — unquoted they are interpreted by cmd and get mangled. Callers needing exotic regexes
  should invoke `alleaves_setup.ps1` directly.
- `-PrinterBrand` values must be **single words, no spaces or apostrophes**: args are double-wrapped through
  cmd `%*` and a PowerShell single-quoted string on the non-elevated relaunch.
- The requested mode is recorded in `ALLEAVES_REQUESTED_MODE` so the `.ps1` can refuse a dropped
  `-Uninstall` (exit 2); `ALLEAVES_NOPAUSE=1` skips the trailing pause.

`-ExecutionPolicy Bypass` loses to an `AllSigned`/`Restricted` GPO; if that ever bites on a managed fleet,
switch to piping via `-EncodedCommand`.

## <a id="dev"></a>Dev run without packing

`PowerShell -File .\alleaves_setup.ps1 -DryRun` — no admin needed, and `-DryRun` falls back to `%TEMP%` for
its working root.
