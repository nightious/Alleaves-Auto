# Scanner USB-OPOS

`Set-ScannerOpos` is the **last functional step** before the printer registration. A tech normally opens
123Scan → "Load to scanner" to put each Zebra scanner into USB-OPOS so the Alleaves POS can read it; this
automates that.

Rig-validation log and running results table:
[SCANNER_OPOS_RIG_VALIDATION_PROMPT.md](SCANNER_OPOS_RIG_VALIDATION_PROMPT.md).

## <a id="open-items"></a>Open items (rig)

Confirmed on **DS2208** (CoreScanner 3.4.0.0, 2026-07-01). Still pending hardware:

- [ ] The exact CoreScanner `type` strings for HID-KB and IBM modes — only `USBOPOS` is confirmed.
- [ ] `$ScannerReenumMaxWaitSec` (40 s ceiling), tuned down if the slowest observed reconnect is well under it.
- [ ] Settle time after starting the Zebra services, before the first switch.
- [ ] Attempts per hop while status 112 is returned, and the wait between 112 retries — currently the DS2208
      values.
- [ ] A real in-session 112 → recovery run, never yet observed end to end.
- [ ] Other scanner families.

Capture with `-ScannerConfigOnly -ForceFingerprint` (forces the dump for an already-known model; lands in
`logs\`), then log the results to the table above. Every tunable lives in **one constants block** in
`alleaves_setup.ps1` — `$ScannerOpcodeSwitchHostMode` … `$ScannerRetryWaitSec`, immediately above
`Get-ScannerHostMode`, which holds no values of its own. Read that block; don't copy its values here.

## <a id="the-command"></a>It is a COMMAND, not a file

Turning on OPOS is a single CoreScanner command:

```
ExecCommand(6200 = DEVICE_SWITCH_HOST_MODE, "XUA-45001-8", silent, permanent)
```

Identical across all Zebra USB scanner families (DS/LI/MP/…). Model and PID are read from `GetScanners` at
runtime, so this auto-adapts to whatever is plugged in — it does **not** hardcode the DS2208.

> **Never embed a `.scncfg` in the installer.** A per-model `.scncfg` + opcode 5020 is a documented *future*
> full-config path only (beeper volume, symbologies) — never needed to set OPOS itself. Regenerate a fresh
> 123Scan export if that day comes.

Host-variant codes, stable across all Zebra USB scanners:

| Code | Mode | | Code | Mode |
|---|---|---|---|---|
| `XUA-45001-1` | USB IBM Hand-held | | `XUA-45001-8` | **USB OPOS (target)** |
| `XUA-45001-2` | USB IBM Table-top | | `XUA-45001-9` | USB SNAPI |
| `XUA-45001-3` | USB HID Keyboard | | `XUA-45001-11` | USB CDC Serial |

Authority: Zebra TechDocs *"PowerShell Scripts for Windows"* + *"Scanner SDK for Windows — API"*.

## <a id="two-hop"></a>The two-hop

**You cannot switch directly from the factory HID-Keyboard default to OPOS** — from HID-KB the only legal
targets are IBM Hand-held or SNAPI. So from HID-KB, or from any unconfirmed mode, the switch hops
**HID-KB → IBM Hand-held (`XUA-45001-1`) → OPOS (`XUA-45001-8`)**, waiting for USB re-enumeration between
hops. An SDK constraint, not a barcode one. An **unmatched `type` reads `'unknown'`**, which safely takes the
two-hop (valid from any starting mode) and costs one extra harmless hop — so nothing is broken while the
HID-KB and IBM type strings remain unconfirmed.

`permanent=TRUE` survives power cycles. The switch is skipped when the unit is already OPOS, which dodges an
old-driver "switch-to-OPOS-while-OPOS" hang (not reproduced on CoreScanner 3.4.0.0).

**HID-KB exposes no asset data**, so the serial is blank on a factory start and re-matching after each
re-enumeration is serial-agnostic (`Get-ReenumeratedScanner`): with exactly one scanner present take it; with
several prefer a stable serial match, else the one whose Id changed AND whose mode left the pre-hop mode,
else best-effort first with a Warn.

`Wait-ScannerReenum` is an **adaptive poll to the real reconnect**, not a fixed sleep: it polls `GetScanners`
until the unit's Id or host-mode leaves its pre-hop values.

> `ponytail:` the 40 s ceiling is the fingerprint script's proven `$MaxWaitSec`; it only bites on a failed
> hop, since success exits at the real reconnect.

## <a id="rsm"></a>Status 112 and the RSM channel

`ExecCommand(6200)` rides the Zebra **Remote Scanner Management** channel, which is UNAVAILABLE
(`ExecCommand` status **112**, "Device Unavailable") until the CoreScanner + RSM services are running and have
settled. On a fresh install these run in the **same session** that just installed the SDK, before the
recommended reboot — so `Confirm-ScannerServicesReady` starts any that are stopped (never `Restart-Service`,
which would drop the COM `Open()` we hold) and settles, and `Invoke-ScannerHostSwitchResilient` retries 112 to
*attempt* the switch in-session. Services are resolved by exact short-name (confirmed on rig).

> **`Confirm-ScannerServicesReady`'s verdict is USED, never discarded** — at both call sites. A CoreScanner
> that is not Running is the single most predictive signal that every `ExecCommand` will return 112, and it is
> the one condition the 112 retries cannot fix, since all they do is re-run that same check. So it bails with
> `result='rsm-unavailable'` + exit 6 instead of spending the retry budget arriving at a verdict already known.

### Both hops short-circuit on 112 — and on a NEGATIVE status

112 never clearing after retries means the RSM channel is genuinely unavailable, so the command **never
reached the scanner** and it cannot have moved. Tested **before** `Wait-ScannerReenum`, which used to poll the
full 40 s ceiling for a device sitting untouched in HID-KB, to reach a verdict already known. A **negative**
status is the same evidence: `Invoke-ScannerHostSwitch` returns `-1` when `ExecCommand` *threw*.

**Hop 2 carries hop 1's short-circuit and its `Warn` too** — without them a hop-2 112 returned `fail` having
printed nothing about `$st2`, since the status only ever reached the console via the "re-enumerated" branch.

**Hop 1 bails when the device is provably still in HID-KB afterwards**, rather than falling through to the one
switch the SDK documents as illegal (HID-KB → OPOS direct), where the failure reported would be hop 2's, not
the real one.

### <a id="verify"></a>No re-enumeration after hop 2 is `fail`, not `ok`

A unit sitting in USB-OPOS enumerates as `USBOPOS`, so silence is **positive evidence** the switch is
unconfirmed. Fail closed: exit 6 is non-fatal and prints the one-scan barcode fallback.

For the same reason there is **no "unknown + clean status = ok" arm**. `$ScannerTypeOpos` is the one confirmed
type string and it is per-MODE, not per-model, so `'unknown'` here is positive evidence the unit came back in
some *other* mode: a scanner that accepts the `ExecCommand` (`$st2 = 0`) but re-enumerates still in IBM
Hand-held used to be reported ok, exit 0, and Alleaves then could not open it.

## <a id="inventory"></a>An enumeration FAILURE is not an empty terminal

`Get-CoreScannerInventory` parks the status of the last `GetScanners` call in
`$script:ScannerInventoryStatus`. An empty inventory means two very different things — "nothing is plugged in"
(benign) and "the call failed" — and they are only separable there.

| Status | Meaning |
|---|---|
| `0` + empty list | benign `no-scanner` arm — no flag, exit 0 |
| non-zero | the call failed (e.g. RSM not attached yet) |
| `-1` | `GetScanners` threw |
| `-2` | malformed `OutXML` |
| `-3` | "GetScanners reported N but nothing parsed" — the `[ref] $count` that was never read |

`-2` and `-3` both existed as bugs: a parse failure produced an empty list with status **0**, the enum-failed
guard was bypassed, and a DS2208 physically plugged in shipped in HID-KB on a green exit-0 run. Both are
assigned **only over a still-clean status**, so a real non-zero status is never masked by a parse problem.
Read the status **only** straight after a call — the re-enum poll loop calls this repeatedly and its transient
failures are expected. **Each node parses under its own try**: `[int]''` THROWS on a node with no
`<scannerID>`, and one bad node used to abort the whole `foreach`, discarding every scanner already parsed and
reporting the terminal as empty.

## <a id="bails"></a>Every bail records a `scannerConfigured` row

An empty `scannerConfigured` is indistinguishable from a step that never ran.

| Situation | `result` | Exit |
|---|---|---|
| `-SkipScannerConfig` | `skipped:flag` | 0 |
| `$script:ScannerDegraded` | `skipped:degraded` | 4 |
| `-DryRun` | `dryrun` | 0 |
| Interop DLL missing | `no-interop` | 6 |
| `Open()` refused | `open-failed:<status>` | 6 |
| CoreScanner not Running | `rsm-unavailable` | 6 |
| enumeration failed | `enum-failed:<status>` | 6 |
| nothing attached | `no-scanner` | 0 |
| already in OPOS | `already-opos` | 0 |
| outer catch | `error: …` | 6 |

The **outer catch included** (a blocked Interop DLL in `LoadFile`, an unregistered COM class, an `Open()`
throwing "RPC server unavailable" — all *before* the device loop), and the two flag bails that return first:
each used to leave `scannerConfigured` empty, so nothing on disk said the step had even run.

The Interop DLL path comes from **`$env:ProgramFiles`**, not a hardcoded `C:\`: a terminal imaged with Program
Files on another volume recorded `result='no-interop'` and exited 6 forever with the SDK installed. `-DryRun`
simulates **before** the DLL existence and COM checks (same pattern as `Invoke-Installer`), because on a bare
box the real run installs CoreScanner first.

**`Open()` is paired with `Close()` in the `finally`.** `ReleaseComObject` drops our RCW but never tells the
CoreScanner service to tear down the registered application session, and every early return inside the try
left it registered. Its own try/catch, so a failed `Close` cannot mask the real result.

### Per-device try/catch

Same invariant the printer step keeps ([PRINTER-OPOS.md#per-device-catch](PRINTER-OPOS.md#per-device-catch)):
with a single outer catch, one scanner throwing aborted the loop before any later scanner was touched **and**
before its own row was appended. Identity is **seeded above the try**, because a throw inside
`Get-ScannerHostMode` otherwise left it holding the *previous* device's identity — and `Merge-PriorList` keys
`scannerConfigured` on `serialFinal`, so the stale one collided with that device's own success row. The row is
appended **outside** the catch; final identity is captured **post-hop**, a HID-KB start reporting blank serial
and model.

## <a id="fingerprint"></a>New-model fingerprint dump

`Write-NewScannerFingerprint` dumps every hop's full fingerprint (inventory fields + hop status + measured
reconnect seconds) to one `logs\` file so the tech can send it back to finalize the rig constants for that
model. **Records-only** — it never touches the exit code.

It is `-ErrorAction Stop` internally: under `'Continue'` a read-only `$LogDir` or a full disk failed
non-terminatingly and the path was still returned, so `fingerprintLog` pointed at a file that was never
written — the manifest telling the tech to send a log that does not exist. Caught **there**, not left to the
caller's per-device catch: this dump must never turn a successful OPOS switch into a failure.

### <a id="known-models"></a>`$ScannerKnownModels` is a FAMILY REGEX, not a list

CoreScanner's `<modelnumber>` is the full kit/config SKU (`DS2208-SR7U2100SGW`, `DS2208-SR00007ZZWW`), never
the bare family name — so it is matched with `-notmatch` on the family prefix. Add confirmed families with
`|`. **Keep it non-empty**: `''` matches everything and silences the dump entirely.

### A BLANK model still dumps

Under an `unknown-model` placeholder. A HID-KB start reports blank until a hop re-enumerates the unit, so
gating the dump on a non-empty model wrote nothing in exactly the documented rig case — an unvalidated family
in factory HID-KB whose hop 1 fails — and `-ForceFingerprint` was silently ignored there.

The `newModel` **flag** still needs a reported model that misses the regex: a blank one proves nothing, and
`-ForceFingerprint` dumping for a known model must not make the flag claim the family is unknown.

## <a id="fallback"></a>Barcode fallback

On terminal failure `Show-ScannerBarcodeFallback` prints loud, actionable guidance. The unit still works via
`scanner/Scanner_OPOS_barcode.pdf` — **one scan from the HID-KB default**, since the two-hop is an SDK-path
constraint only. Exit stays 6 (non-fatal); no scanner attached at all is a benign Warn, exit 0.

That PDF is a repo / tech-share deliverable, **not embedded** in the `.bat`, so it needs no rebuild. Verified
payload `SXUAH20008`.

## <a id="uninstall"></a>Uninstall

**Records-only, `removable=$false`** — scanner host mode is hardware-external state, like the computer rename
and the TeamViewer removal ([MANIFEST.md#not-reverted](MANIFEST.md#not-reverted)). A tech can scan the "USB
HID Keyboard" / "Set Defaults" barcode (or re-run 123Scan) to revert.

Factory-reset on uninstall (opcode 2015) was considered and deliberately skipped: it needs a scanner attached
at uninstall time AND is SNAPI-only.

`-ScannerConfigOnly` runs this step standalone; `Save-Manifest` merges onto the prior manifest. See
[ARCHITECTURE.md#config-only-modes](ARCHITECTURE.md#config-only-modes).
