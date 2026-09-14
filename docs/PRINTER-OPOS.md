# Receipt printer OPOS

`Set-PrinterOpos` is the **last functional step**. Unlike the scanner it is **pure registry** — no COM, no
polling, no hardware — and works with nothing plugged in (`Open()` returns 0 on a bare bench), which is why
exit 7 is meaningful on a printer-less bench run.

Full evidence and the bench-capture procedure: [PRINTER_OPOS_FIELD_RESULTS.md](PRINTER_OPOS_FIELD_RESULTS.md).

## <a id="open-items"></a>Open items (bench)

- [ ] **`$StarPrinterStrings`, `$StarPrinterDWords` and the two drawer tables are EMPTY.** Fill them from the
      bench capture (before/after `Collect-PrinterFingerprint.ps1 -SnapshotOnly`, diffed); the device rows
      carry no `Type`/`ProgId` field by design. Until then a `StarTSP100` run exits 7 with
      `result='not-captured'`, which is the intended behaviour — see [#uncaptured](#uncaptured).

## <a id="why-registry"></a>Writing the registry IS the supported path

Neither vendor ships OPOS automation, so this is not a workaround:

- **POS-X** — the installer (`OLE POS Setup 2.84`) stages the files and registers the COM objects;
  `SetupPOS.exe` is only a GUI over the registry.
- **Star** — worse: no `SetupPOS.exe` equivalent, and futurePRNT's manual rules OPOS out of the one importable
  format the utility has ([evidence, with the §-reference](PRINTER_OPOS_FIELD_RESULTS.md)).

**Don't go looking for one again.**

`WOW6432Node` in the key path is explicit and correct: the CCOs and service objects are 32-bit, and the `.bat`
forces the 64-bit PowerShell host, whose registry provider takes the path literally (no redirection).

## <a id="brands"></a>The brand table

`$PrinterBrands` — `POS-X` · `StarTSP100`; **`None` short-circuits before the table is ever indexed**, so it
is not a key (a `None` entry would also need a `RowName` and would break step 0b, which iterates
`$PrinterBrands.Keys` to build `-SkipPrograms`). Read the table in the script; don't copy its values here.

| Field | Meaning |
|---|---|
| `RowName` | the `$Installers`/`$DriveFiles` row this brand needs, and it **MUST equal that row's `Name` and `Label`** — [INSTALL-ENGINE.md#tables](INSTALL-ENGINE.md#tables). `tests\Test-ManifestMerge.ps1` asserts the cross-table match. |
| `ArpPattern` | the driver's ARP DisplayName, checked before any entry is written |
| `Devices` | an **array** — see below |

<a id="no-type-field"></a>**A device row has NO `Type`/`ProgId` field.** Both used to sit in `Devices`
duplicating `Strings['DeviceName']` and `Strings['(default)']` — never written, never verified by the
readback, free to drift. Star was already drifted by construction (both `''`), so filling only
`$StarPrinterStrings` after the capture would have printed `OPOS POSPrinter: POS01_Printer -> ` and manifested
`progId=$null`, with `Remove-StalePrinterOpos` (which keys on `logicalName`/`deviceClass`) hiding the mistake.
**One source: the `Strings` table.**

## <a id="device-count"></a>How many devices is PER BRAND, not a global rule

### POS-X — ONE device

The cash drawer has **no** device entry (dropped 2026-08-12; the `CashDrawer`/`StandardU` element and its 33
values came out). It hangs off the printer's RJ-11 and `Standard.CashDrawer.SOU` resolved to the printer's own
`POSPrinterSOU.dll` anyway, so a second logical device bought nothing.

The drawer follows the printer via the printer key's **`DrawerOpen=1`** — SetupPOS's *Open CashDrawer* =
*Follow Printer*, captured as a one-value diff ([evidence](PRINTER_OPOS_FIELD_RESULTS.md)). `Thermal.inf`'s
`[UOPTION]` default is `0`, so this is the one shipped value that deliberately differs from the vendor
default — still captured, not authored.

### Star — TWO devices

futurePRNT has **no equivalent of that flag**. Its drawer is a separate `CashDrawer` OPOS device with its own
LDN and its own settings (drawer number, pulse width, polarity). That is why the device **array** came back
after the 2026-08-12 flattening — there genuinely are two devices.

Star's LDNs are the utility's **Logical Device Name** (`Configure → Add New`), not the device name `Add New`
creates (which stays at the vendor default). Register the common **OPOS CCO**, not Star's own CO: the vendor
manual recommends it, and this repo already installs POS for .NET, whose legacy bridge wraps a registered
CO/SO.

## <a id="captured"></a>The device values are CAPTURED, never authored

They came from diffing a real `SetupPOS.exe` run (28 printer values, 2026-08-10, OLE POS Setup 2.84). The OPOS
spec mandates only `(default)` = ProgID; the rest is vendor-private. Deriving them from `Thermal.inf` gives a
subtly wrong key — `Description` and `PortShare` are in **neither section** of it. If the package version
bumps, re-capture; don't hand-edit.

## <a id="uncaptured"></a>The uncaptured guard

`$uncaptured` tests `Strings.Count`, `DWords.Count` **and `Strings['(default)']` by name**, and returns
`result='not-captured'` + exit 7. Without it the write loops iterate zero times, the readback verifies
nothing, and the step reports `ok` after creating an **empty device key** — a phantom device plus a false
success, strictly worse than doing nothing. All three tests matter:

- A filled `$StarPrinterStrings` beside a still-empty `$StarPrinterDWords` (a one-line omission) passed a
  Strings-only test with **both DWord loops iterating zero times** — `ok` reported on a device with no pulse
  width, no drawer number and no port settings.
- `(default)` — the ProgID, the one value OPOS mandates — is the one the readback can never catch itself,
  since it iterates `$dev.Strings.Keys` and never looks for a key missing from the transcribed table (`progId`
  lands `$null`, the console prints `… -> `, the step reports `ok`). The counts go non-zero the moment a
  capture fills *anything*.

> **Never "stub" those tables with plausible values.** That guard is the only thing standing between a stubbed
> build and a silent lie.

<a id="no-devices"></a>A brand with **no devices** needs its own `$noDevices` test beside `$uncaptured`: an
empty pipeline slips past `$uncaptured`, the loop iterates zero times, and the run exits 0 having registered
nothing. Count it filtered — `@($null)` is one element — and the trailing `else` raises
`$script:PrinterConfigFailed` unconditionally. The row is recorded under `-DryRun` too (only the flag is not),
or a dry run of an uncaptured brand leaves `printerConfigured` empty, indistinguishable from a step that was
never reached.

## <a id="already-configured"></a>ALREADY CONFIGURED is a success — checked BEFORE the uncaptured bail

The uncaptured bail is right on a fresh terminal and **wrong** on one whose OPOS device the vendor utility (or
an earlier deployment) already created under the exact name Alleaves opens: the tech got a red failure and
exit 7 on a box that works, with a remediation (run the bench capture) that changes nothing about it.

`Test-PrinterOposConfigured` tests the key's **`(default)` value, not mere existence** — the default *is* the
ProgID, and a key without it is the phantom-device state the rest of the step avoids. With no table to verify
against, that is the strongest claim available, and the same one OPOS acts on when it opens the device.

- **Every** device must be present, or success would hide a missing cash drawer; the partial case warns
  "N of M" and falls through to the normal bail.
- The match is on the **exact** logical name: a device the vendor utility registered under some *other* name
  correctly does **not** count.
- Rows are `result='already-configured'`, **`removable=$false`** — we did not create those keys, so
  `-Uninstall` must not remove them.
- The arm returns **before** `Remove-StalePrinterOpos`, like `no-driver`: this run registered nothing of its
  own, so there is no replacement to retire an older name in favour of.
- `$prefix = Get-PosNamePrefix` is hoisted **above** the bail because the check needs it to build the key
  names.
- It is read-only (`SilentlyContinue` + a null test, not `-Stop`), so it is safe under `-DryRun` and can never
  be the thing that throws. A key we cannot read is not a key we can call configured.

## <a id="ldn"></a>The logical device name is per-terminal

`<POSname>` + the device's `Suffix`, built by `Get-PosNamePrefix` from the **requested** rename
(`$Manifest.computerRenamed.to`), **not** `$env:COMPUTERNAME` — the rename only lands on the post-install
reboot, so the env var is stale all run.

- The **`applied` flag is part of that test**: `Invoke-ComputerRename`'s catch records the requested name with
  `applied=$false`, so a rename that *failed* would otherwise name the devices after a name the terminal never
  gets — silently unopenable. `'dryRun'` counts as applied, or the preview would advertise different device
  names than the real run creates.
- The **fallback is the PENDING name**, read from the registry — not `$env:COMPUTERNAME`, which is the ACTIVE
  name. They differ between `Rename-Computer` and its reboot, exactly the window a standalone
  `-PrinterConfigOnly` run lands in when it is used to recover a failed printer step (exit 7's own advice):
  with the env var, that run names the devices after the name the terminal is LOSING and
  `Remove-StalePrinterOpos` then deletes the correct ones. The pending key equals the active name when nothing
  is pending, so it is strictly better on both paths.

**No LDN named `ThermalU` is registered — only `<POSname>_Printer`.** (`ThermalU` is still written, as the
`DeviceName` *string value* inside that key; it is the vendor's device name, not a logical device name.)
Alleaves must be configured to open the exact LDN, so a later rename must re-run the step.

## <a id="stale"></a>`Remove-StalePrinterOpos`

Drops device entries **we created** that this run no longer registers. Two cases, one test: a **rename**,
where the advertised "re-run `-PrinterConfigOnly` to fix the names" would otherwise leave `<OLDNAME>_Printer`
behind and the terminal advertises two; and a device **retired from the table**, which is how the 2026-08-12
cash-drawer removal reaches already-deployed terminals. The test is an **exact match against this run's
LDNs** — a prefix match cannot do case 2, because the retired drawer matched this run's own prefix and was
stranded as a phantom device forever.

- **`-Registered` is `[Parameter(Mandatory)]`** and a **whitelist**. Its old default rebuilt the one expected
  LDN from prefix + suffix, which stopped being expressible once a brand can register several devices — and a
  caller that forgot the parameter would have silently retired every device but one.
- **Only names in the PRIOR manifest are touched**, read through `Get-PriorManifest` — a private copy of that
  read swallowed a locked or malformed manifest, so "unreadable" silently meant "no stale devices" and after a
  rename the terminal advertised TWO OPOS printers.
- <a id="removable-guard"></a>**`removable=$false` rows are skipped** — the `already-configured` rows, whose
  keys we did not create. Without the test a later rename drops the old name out of `$Registered` and the
  retirement deletes a **vendor-created device**, exactly what this function promises never to do.
  (`$null -eq $false` is `$false`, so a manifest predating the key still defaults to removable.)
- The uninstall path's **`SubKeyCount` guard** applies: a non-recursive `Remove-Item` on a key with children
  raises `ShouldContinue`, which prompts on an interactive host and *throws* on an RMM one.
- **That refusal is COUNTED, not silent** — the function returns the survivors and the call site turns a
  non-zero count into `$script:PrinterConfigFailed` → exit 7, because a survivor *is* the two-OPOS-printers
  state (Alleaves can open the dead `<OLDNAME>_Printer`) and exit 7's remediation is the retry that fixes it.

<a id="stale-rows"></a>A retired device's rows are deliberately **left to merge forward**, so
`printerConfigured` accumulates old names and `(none:*)` skips — tolerable only because uninstall step 4b
skips a value that is already gone and refuses to `New-Item` a key back just to restore into it. See
[MANIFEST.md#stale-rows](MANIFEST.md#stale-rows).

> `ponytail:` the emptied CLASS key (`ServiceOPOS\CashDrawer`) is left in place — it enumerates no devices, and
> `-Uninstall` still removes it via `regKeysCreated`.

## <a id="register-then-retire"></a>Register first, retire after — all-or-nothing

`Remove-StalePrinterOpos` runs **after** the registration and is passed **only the LDNs that actually
verified**. Deleting first meant a failed write (exit 7, "re-run with `-PrinterConfigOnly`") left the terminal
with **no** OPOS printer where it had a working one under the old name a second earlier — and the delete has
no rollback.

With more than one device the reasoning goes further: `-Registered` is a whitelist, so passing a *partial*
list after one device failed would delete the prior run's copy of the very device that just failed to be
replaced. **If any device fails, skip the call entirely.**

The `-DryRun` path passes the names it *would* register, so the preview retires exactly what the real run
would.

## <a id="driver-guard"></a>The driver must be present first

`Find-InstalledProducts -Pattern $brandDef.ArpPattern`. Otherwise the step registers a device pointing at a
DLL that isn't there — Alleaves enumerates it and fails to open.

**Check ARP, NOT the ProgID.** The vendor uninstaller leaves the whole ProgID → CLSID → InprocServer32 chain
behind (measured), so a ProgID test reports "installed" on a box where the DLL is long gone. The ARP entry
does go.

Skipped only for a **full-install `-DryRun`**, where the driver is legitimately absent because the install
loop that would have placed it was itself simulated. Under **`-DryRun -PrinterConfigOnly` the check still
runs**: nothing installs anything in that mode, so a real run would refuse here — and a preview that
"registers" devices the real run would decline is a preview of the wrong run.

Driver absent is a benign `result='no-driver'` skip, exit 0 — returning **before** `Remove-StalePrinterOpos`,
like `None` but for its own reason: with the driver gone there is nothing to register in place of a stale
`<OLDNAME>_Printer`, so retiring it would leave *no* OPOS printer on a box whose driver an operator may simply
be reinstalling. `-Uninstall` is what removes those rows.

## <a id="brand-switch"></a>Brand switch

**POS-X and Star share both `Class` (`POSPrinter`) and `Suffix` (`_Printer`)**, so on a brand switch the key
path is byte-identical and nothing else notices: `Remove-StalePrinterOpos` reads the same LDN as this run's
own name, and the write and readback loops only touch the *new* brand's value names. The step printed `ok` on
a key that was half POS-X and half Star — stale `ADKConfig` / `DrawerOpen` / `PortShare` beside Star's values.

So the key is cleared first **when the prior manifest records a different `brand` for that logical name** —
gated on that record rather than deleting unconditionally, which would throw away the `prev` state
`Set-TrackedRegValue` captured for a key a manual `SetupPOS` run created.

- Same `SubKeyCount` guard as the stale-device removal.
- A failed clear **still writes the new values** (a mixed key beats no key) but sets
  `$script:PrinterConfigFailed`: the leftovers are invisible to the readback, so exit 7 is the only thing that
  tells the tech to look.
- <a id="prior-brand"></a>**It stamps the PRIOR brand on that device's manifest row**, or exit 7's own
  remediation cannot fix what it reports. `printerConfigured` merges current-wins on `logicalName`, so
  stamping the new brand made the advised `-PrinterConfigOnly` re-run read `$wasBrand` as the new brand, find
  no mismatch, attempt no clear, and report `ok` / exit 0 on a key that stays half POS-X forever. The stamp is
  reset per device — it is a one-device fact.
- **`-DryRun` previews the clear.** It is the one destructive, un-rollback-able thing this step does, and the
  preview showed only "would register" and "would remove stale device".

The prior manifest is read **once, above the `-DryRun` block**, for the brand-switch check in both paths.

## <a id="readback"></a>Readback compares EVERY value by name, and tests `$null` separately

- **Per-name, NOT a value COUNT.** `$ErrorActionPreference` is `'Continue'`, so a failed `New-ItemProperty` is
  non-terminating and `Set-TrackedRegValue` recorded a value it never wrote — and on a key that **already
  holds the full set** (every re-run, and every terminal deployed before the table changed) the count is
  already satisfied, so it can never catch that. The migration it misses is the real one: `DrawerOpen` 0 → 1
  silently not applied, reported `ok`, drawer never kicks.
- <a id="null-vs-empty"></a>**`$null` (value ABSENT) is tested separately from its string form.** `"$null"` is
  `''`, and **seven of the fourteen POS-X strings are legitimately `''`**, so a plain `"$got" -cne "$expected"`
  compared `''` against `''` and *passed* for a value never written at all — blinding the readback for exactly
  the half a failed non-terminating write leaves behind. Mirrors the DWord loop.
- <a id="default-alias"></a>**`(default)` must be READ as `GetValue('')`.** It is an alias only the
  `*ItemProperty` cmdlets accept; `GetValue('(default)')` hunts for a value literally named that and returns
  `$null`, which failed the readback on the first key of every run (all 28 values written correctly, step
  still reported `fail` + exit 7). Same alias trap as the uninstall path's `DeleteValue('')`; see
  [MANIFEST.md#default-value](MANIFEST.md#default-value).

One layer lower, `Set-TrackedRegValue`'s own `New-ItemProperty` is `-ErrorAction Stop` with the manifest row
recorded *after* it — the root cause, fixed once for every caller. The console line and manifest row are
reported **from the values actually being written**, so they cannot disagree with the registry.

## <a id="per-device-catch"></a>Each device gets its OWN try/catch

A shared catch means the printer's failure skips the drawer entirely, so a terminal with a bad printer key
silently loses its drawer too. **Each catch sets `$script:PrinterConfigFailed`** — that flag, *not* the
config-only branch's `$changed` floor, is what produces exit 7 on a **partial** failure, since with one device
of two written the floor sees a change and stays quiet. All-devices-failed says so explicitly instead of
falling through to the "nothing registered" Warn, whose premise is a loop that iterated zero times.

## <a id="bails"></a>Every bail records a `printerConfigured` row

A missing row cannot tell "the tech suppressed it" from "the run died before step 5b". All six are the
same shape, so one local `$bail` scriptblock writes them.

| Situation | `result` | Exit |
|---|---|---|
| `-SkipPrinterConfig` | `skipped:flag` | 0 |
| `-PrinterBrand None` | `skipped` | 0 |
| unknown brand (build error) | `fail: unknown brand` | 7, or 0 under `-DryRun` |
| driver absent | `no-driver` | 0 |
| tables not captured | `not-captured` | 7 |
| already registered | `already-configured` | 0 |

For `skipped:flag` the `brand` is the one step 0b settled on (`-PrinterBrand`, else the POS-X fallback),
read from `$script:PrinterBrandResolved` — the flag suppresses the *prompt*, but step 0b still had to pick
a brand to gate the downloads, and recording the raw empty param instead made the row disagree with what
the run actually installed. `None` returns *before* `Remove-StalePrinterOpos` — it is a skip, not a
retro-uninstall. `-Uninstall` removes those rows.

An **unknown brand** is unreachable via the param `ValidateSet` or the prompt (whose default arm falls back to
POS-X), so it only fires if a brand is added to one and not the other. It raises the flag only when **not**
`-DryRun`, like the not-captured bail: a dry run writes nothing, so it must not produce exit 7 for a build
defect it could not have acted on either way.

`already-configured` counts as a change in the config-only "did nothing" floor —
[ARCHITECTURE.md#config-only-modes](ARCHITECTURE.md#config-only-modes).

## <a id="brand-prompt"></a>`Resolve-PrinterBrand`

Its own function because both the install dispatch and the standalone `-PrinterConfigOnly` branch need it.
Answered **once** and cached — see
[ARCHITECTURE.md#why-the-two-prompts-are-at-step-0](ARCHITECTURE.md#order-of-operations).

- The `Read-Host` is try/catch'd and gated the same way the rename prompt is; see
  [FINISHING.md#headless-prompt](FINISHING.md#headless-prompt).
- **The WORDS are accepted alongside the digits.** README documents `-PrinterBrand None`, so typing "None"
  here is the natural mistake — and with no default case it fell through to POS-X, installing the driver and
  registering a phantom `<POSname>_Printer` on a terminal that has no printer at all.
- Enter = the POS-X default; every degraded path lands there.

<a id="skip-fallback"></a>⚠️ **`-SkipPrinterConfig` with no `-PrinterBrand` falls back to `'POS-X'`, not
empty.** That flag only means "don't write the OPOS entry" and it suppresses the prompt, so there is no answer
to read — and an empty brand made the loop skip *every* brand, while dropping the loop put 471 MB of Star on
terminals that only wanted to suppress a registry write. Same trap as the
[`Invoke-Step` brand fallback](ARCHITECTURE.md#brand-fallback).

## <a id="uninstall"></a>Uninstall

Unlike the scanner this **is** reversible — pure registry — so `removable=$true` and the keys come back out
via `regKeysCreated` / `regValuesSet`. Removing the device *keys*, not just the values, is load-bearing
because the vendor uninstaller strands them: [MANIFEST.md#step-4b-ii](MANIFEST.md#step-4b-ii), and the
`(default)`-deletion trap at [MANIFEST.md#default-value](MANIFEST.md#default-value).

`printer/Collect-PrinterFingerprint.ps1` is the field diagnostic — a doc-style deliverable, **not** embedded,
so it needs no `.bat` rebuild.
