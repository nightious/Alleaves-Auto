# Conventions

Why the rules in `CLAUDE.md` are the rules. The imperatives live there; the reasoning lives here.

## Comments are pointers, not essays

The scripts were deliberately stripped of ~2500 lines of narrative comments (commit "Extract
~2500 lines of narrative comments into docs/"). Narrative in code rots: it sits next to a
function that changed three passes ago, and nobody re-reads a 40-line comment block to notice.
New rationale goes in the matching `docs/` file; the code gets one line,
`# docs/<SUBSYSTEM>.md#<anchor>`.

Two exceptions stay in code:

- The `<# .SYNOPSIS #>` help blocks. On a customer terminal there is no repo — `Get-Help` is the
  only documentation that ships with the script.
- `ponytail:` markers naming a deliberate shortcut's ceiling and its upgrade path. A marker is
  worth more where the shortcut is than in a doc nobody opens.

Do not re-grow the narrative. If an explanation needs a paragraph, it needs a doc.

## The pointer web runs both ways

`tests/Test-DocLinks.ps1` asserts both directions:

1. Every `docs/<FILE>.md#<anchor>` cited anywhere resolves to a real anchor.
2. Every `<a id>` anchor declared in `docs/` is cited from somewhere.

So a renamed anchor can't silently turn a pointer into a dead end, and a deleted pointer can't
silently orphan a doc section. **Add the anchor and the pointer in the same change** — either
half alone fails the test.

A bare `#anchor` in parentheses resolves against the doc named earlier on the same line, so a
pointer that cites two anchors in one doc stays readable.

**Docs cite stable symbol names, never `:NNNN` line numbers.** A doc pass and a code pass in the
same session invalidated every line number twice. Write `Invoke-IssSilent`, not `:1598`.

## Production bar for every install step

Bootstrap + track + reverse:

- **bootstrap** — it installs itself on a stock terminal, silently, with no operator input;
- **track** — the result is recorded in `install_manifest.json` (see `MANIFEST.md`);
- **reverse** — `-Uninstall` replays that record and removes it.

A step that can't be cleanly uninstalled doesn't ship. The manifest is what makes a partial
failure visible: every result is recorded, so a run that half-worked cannot exit 0.

## Wrap every step in `Invoke-Step`

`Invoke-Step 'Name' { Do-Thing }`. A bare call reintroduces the "one throw kills the whole run"
bug — a single failing finishing step used to abandon every step after it.
`tests/Test-StepIsolation.ps1` AST-asserts against bare calls. Mechanics:
`ARCHITECTURE.md#step-isolation`.

## Console helpers and the colour scheme

| Helper | Colour | Use |
| --- | --- | --- |
| `Step` | cyan | starting a phase |
| `Ok` | green | it worked |
| `Warn` | yellow | **a human needs to look at this** |
| `Fail` | red | it didn't work |
| `Dry` | dark grey | `-DryRun` narration |
| `Info` | white | informational; adds **no indent** (call sites carry their own) |

A bare `Write-Host` renders grey and reads as `[DRY]` output — use `Info`.

Yellow is rationed on purpose. If everything is yellow, nothing is. The only yellow in a healthy
run is `Warn` plus exactly four advisories: the DRY RUN banner, "Recommended: reboot once", the
autologon-password caveat, and the account-precheck remediation body. Post-install "next steps",
path banners and prompt headers are `Info`.

## Every silent probe `catch` carries a `Write-Verbose`

The script is `[CmdletBinding()]`, so `-Verbose` surfaces these and the transcript captures them.
`$VerbosePreference` defaults to `SilentlyContinue`, so a normal run is byte-identical.

The swallow is still the contract — these probes are *supposed* to fail (a registry key that
doesn't exist yet, a service that isn't installed on this box). `Write-Verbose` only stops the
reason from being unrecoverable when one fails for a reason nobody predicted.

**Never promote one to `Warn`**: a healthy install would grow ~30 lines of noise, and the yellow
budget above would be worthless. The generated finish script has no console, so its catches use
its own `L()` file logger instead.

## Error handling

`$ErrorActionPreference = 'Continue'` with per-function try/catch and a `Warn` fallback — the run
keeps going and reports everything wrong with the terminal in one pass, instead of stopping at
the first problem and making the tech re-run for the second. Both `Invoke-Step` and the top-level
catch print `$_.InvocationInfo.ScriptLineNumber`.

## Naming

- Functions: `Verb-Noun`, PascalCase.
- Globals: PascalCase — `$LogDir`, `$Installers`.
- Manifest keys: camelCase — `filesPlaced`, `exitCode`, `scannerConfigured`.

## Secrets, network, and `-DryRun`

- Anything that **records** a command line redacts `LICENSECODE=` (`$safeArgs`); `$ArgList`
  reaches the installer untouched. The manifest is world-readable and survives `-Uninstall`.
- TLS 1.2 is forced before any network call — stock Windows 10 still negotiates TLS 1.0 first and
  the vendor CDNs refuse it.
- Guard every state change behind `-DryRun`, **flags included**. A mode that writes nothing must
  not raise `$FinishFailed` and produce a phantom exit 1. This is why a dry run can never return
  6 or 7.
- Runtime payloads, logs and `alleaves_b64.txt` are git-ignored.
