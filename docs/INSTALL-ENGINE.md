# Install engine

Download → install loop → silent uninstall. Manifest rules are in [MANIFEST.md](MANIFEST.md); the
run-level tally and the exit codes it feeds are in [ARCHITECTURE.md](ARCHITECTURE.md).

## <a id="download"></a>Download phase

Native PowerShell Google Drive fetch — no Python, no gdown. `confirm=t` bypasses Drive's virus-scan
interstitial; an alternate host is tried on the final attempt only.

**TLS 1.2 is forced before any network call**, or stock unpatched Win10 defaults to TLS 1.0 and every
Google/Splashtop fetch fails with an SSL error. `Set-Tls12` uses the **numeric** form (`3072`) as the
value: an int→enum cast does not need the member to exist by name, so one line does both jobs.

### <a id="transport"></a>Transport

`Invoke-FileDownload` is **BITS → `WebClient.DownloadFile`**, never `Invoke-WebRequest -OutFile`, which
on PS 5.1 buffers the whole body in memory and cannot resume. One shared User-Agent throughout — some
CDNs 403 a blank UA. The `WebClient` is **disposed on every path**: at 2 connections per host, leaked
sockets wedged the rest of the run on connection exhaustion instead of on the error that started it.

**471 MB already works. Don't "fix" it.** Measured 2026-08-28, the `confirm=t` URL `Get-DriveFile`
builds returns `206 / Content-Range: bytes 0-0/493881478` for the Star zip — no interstitial, **no
`uuid` parameter needed** — and the 566 MB `Zebra 123 Scan.exe` proves the transport at that scale.

### <a id="truncation"></a>Truncation guards

Three layers, because a header-valid but truncated installer installs as a corrupt 1603 and bricks
the terminal:

1. **Content-Length size check** — `Get-RemoteLength` tries HEAD, falling back to a **ranged GET**
   reading the total from `Content-Range`. A ranged 206 reports `ContentLength=1`, so a response with
   no parseable total is rejected — don't trust 1. A probe *failure* is not cached, so a transient
   miss can still succeed on a later retry. The `WebException`'s response is **closed**: at 2
   connections per host and a 60 s timeout, a leak wedges the *later* probes.
2. **Magic-byte sniff** (`Test-RealBinary`) — rejects an HTML interstitial saved as an installer
   (`<` = 0x3C), accepts `PK\x03\x04` (zip/nlbl), OLE compound (MSI), `MZ` (exe).
3. **`.len` sidecar** — the byte length is persisted on every successful download and re-verified
   against the on-disk size in each cache guard. A missing or mismatched sidecar re-downloads.

**The sniff floor is 8 bytes, not 2**: the magic tests read `$buf[0..3]`, and when `Get-RemoteLength`
cannot answer (`-1`) layer 1 is skipped and this sniff is the last guard left (that case **warns**). A
2-byte `MZ` fragment was once recorded `ok`, wrote its truncated size into the `.len` sidecar, and
passed `Test-CachedFileValid` forever after: a permanent 1603.

<a id="literalpath"></a>Every path these guards touch — and every path the uninstall's file sweep
touches — uses **`-LiteralPath`**: `-Path` treats `[ ]` as wildcards, so a bracketed path matches
nothing and is silently skipped as "already gone".

### <a id="download-retry"></a>Retry behaviour

**Every attempt downloads to `<target>.part` and is `Move-Item`d into place only after the size and
magic-byte checks pass.** Guarding the *delete* on `Test-CachedFileValid` was not enough: `WebClient`
(and BITS) truncate the destination before they have a body, so the first attempt that connected at all
overwrote the byte-correct 471 MB Star zip, after which the guard compared a 2 KB captive-portal page
against the old `.len` and deleted both. The `.part` is removed before each attempt and on exhaustion.

When the retries are exhausted but the on-disk file still validates, the call returns **success** — the
install runs from that exact file, so returning failure set `$script:DownloadFailed` and exited 1 on a
run that installed fine.

`Unblock-FileSafe` retries three times: Defender can hold a sharing lock mid-scan.

The phase guards **per FILE**, so one dead row costs neither the other downloads nor — since it runs
inside the dispatch try — every install after it.

## <a id="tables"></a>The two row tables

`$DriveFiles` (download) and `$Installers` (install).

> **`$DriveFiles` `Label` MUST equal the matching `$Installers` `Name`.** `Test-SkipMatch` tests
> `Label`/`File` for downloads but `Name`/`File` for installs, so a drifted Label makes one
> `-SkipPrograms` fragment hit only one phase — `-SkipPrograms NiceLabel` downloaded the whole suite
> and never installed it. `tests\Test-ManifestMerge.ps1` asserts this for the printer rows.

`Test-SkipMatch` matches only the human `Name`/`Label` and the `File` — it used to also match the
internal `$i.Match` regex, so a skip fragment could accidentally hit a product's *registry* pattern.

### <a id="row-fields"></a>Row fields

| Field | Meaning |
|---|---|
| `Match` | **narrow** — this item's OWN product. Install idempotency + success checks. |
| `UninstallMatch` | **broad** — recorded for `-Uninstall`. See [#anchoring](#anchoring). |
| `Msi` / `Iss` / raw | install family |
| `Zip` / `ZipMember` | extract one member from a CD image before installing |
| `SkipIfInstalled` | ARP short-circuit for raw-exe rows |
| `CachedMsi` | the constant name the `.iss` fallback looks the extracted-MSI cache up under |
| `Iss*` overrides | see [#four-overrides](#four-overrides) |

### <a id="zip"></a>`Zip` / `ZipMember`

The Star download is the vendor's whole 471 MB CD image; the installer is one 111 MB member inside it.

- **`System32\tar.exe` (bsdtar) extracts that member only.** `Expand-Archive` would unpack all 471 MB,
  and **Git's `tar` is GNU tar and cannot read zip at all** — hence the full path.
- No `--strip-components`: the member keeps its stored path under `$DownloadDir`. Untracked and never
  cleaned up, like the Zebra wrappers — `$DownloadDir` survives `-Uninstall` by design, at ~600 MB.
- **tar's exit code is the only truncation signal there is** — the existence check catches absence, not
  truncation, and once `SkipIfInstalled` is satisfied the member is never re-extracted. A non-zero exit
  records `result='fail-extract'` and skips the install.

### <a id="skipifinstalled"></a>`SkipIfInstalled`

Set on **every** raw-exe row, Chrome and NiceLabel included: that branch had no ARP short-circuit at
all, and replaying an installer over an already-installed product is how a working terminal ends up
printing a red `[FAIL]` the tech has to interpret. Same `Test-PriorInstallFailed` + `-ForceReinstall`
gate as the MSI/`.iss` guards.

Evaluated **before** the zip extraction and **before** `$DryRun`, because it reads live ARP either
way: ordering it later re-extracted 471 MB and only then printed "already installed; skipping".

Trade-off, accepted: a NiceLabel installed **by hand** (no prior manifest row) skips on ARP alone and
its license is not re-applied. `-ForceReinstall` is the remedy.

## <a id="install-loop"></a>Install loop

Each `foreach` body opens with a **`try` recording `result='fail-exception'`** — see
[ARCHITECTURE.md#step-isolation](ARCHITECTURE.md#step-isolation). `$full` is only assigned partway
through the body, so the catch rebuilds the path from the row rather than reporting the *previous*
row's file.

### <a id="pre-clean"></a>Pre-clean

**Only under `-ForceReinstall`, and only for MSI/`.iss` rows** — those two FAIL when replayed over an
existing install (MSI → reconfigure/SecureRepair → 1603; Zebra `.iss` → maintenance mode → silent
fail). Raw rows (Chrome `/install`, the NiceLabel suite) cleanly reinstall over themselves, and
pre-cleaning is **actively harmful for NiceLabel**: msiexec removes its MSI but the suite's
bootstrapper state lingers, so the reinstall runs as a *repair* that does not recreate the ARP entries
→ NiceLabel installed but invisible to a later `-Uninstall`.

It pre-cleans on the broad `UninstallMatch` when defined ([#anchoring](#anchoring)); removing the
shared CoreScanner per-item is idempotent — whichever Zebra item reinstalls first re-creates it.

**Critical for `.iss` items:** `msiexec /X` on the Zebra MSI products leaves the InstallScript ARP
orphans *and* the `InstallShield Installation Information\{GUID}` cache folders behind, and if those
remain the silent `.iss` reinstall runs in maintenance mode and fails silently → the run falls back to
the cached MSI, which carries no CoreScanner → non-functional scanner. `Remove-InstallShieldOrphans`
sweeps both; the install-side caller `Out-Null`s its return (a failure count for the uninstall tally).

### <a id="already-installed"></a>"Already installed" means SUCCESSFULLY installed

All **three** idempotency guards — `skipInstalled`, the MSI guard and the `.iss` guard — consult
`Test-PriorInstallFailed`, which reads the prior on-disk manifest via `Get-PriorManifest`.

**An ARP entry alone does not prove success.** Pure InstallScript's `DeinstallStart()` writes the ARP
entry **before** file transfer, and an MSI rollback can leave one too, so a run that aborts mid-install
leaves exactly the registry state a later run reads as "done": the product is never repaired and every
re-run reports success.

- **No prior row** = never attempted = trust the registry (installed by hand or by an older build must
  still be skippable).
- <a id="msi-fallback"></a>**An `ok` row carrying `note='msi-fallback'` counts as NOT successfully
  installed.** Neither fallback MSI carries the shared CoreScanner driver the `.iss` install does, so
  the product lands in ARP, the guard skips it on every future run, and the run exits **4 forever** —
  with its only advertised remediation, "re-run the installer", doing nothing. `result` stays `ok` on
  purpose: the tally must not count a fallback that worked as a failure.

All three write their row through `Add-AlreadyInstalledRow`, which also decides **`removable`**: a
product with no prior manifest row was never installed by us, so the row is `removable=$false` and
[step 2](MANIFEST.md#step-2) leaves it alone. Without it `-Uninstall` ran Chrome's
`setup.exe --force-uninstall` over a customer's own Chrome, profile and all. The prior-row test ignores
rows that are themselves `removable=$false`, or run 2 would flip a pre-existing product back to
removable.

Consequence to expect: a genuinely failing product retries every run until it succeeds.

## <a id="invoke-installer"></a>`Invoke-Installer`

> **`Invoke-Installer` must dereference `$p.Handle` before `WaitForExit`, or there is no exit code at
> all.**

On PS 5.1, `Start-Process -PassThru` **combined with output redirection** hands back a Process whose
`.ExitCode` reads `$null` after the wait; dereferencing `.Handle` first makes .NET cache it. The only
redirecting launch site in the file — but that meant every raw-exe row **and every MSI via
`Invoke-Msi`** recorded `exitCode=null` → `result='fail'` on installs that had **succeeded**, never
reaching Chrome's `-ConfirmRegistry` check or the 3010/1641 reboot flag. Measured 2026-09-13, identical
at 0 s, 1 s and 3 s lifetimes, so not a race. A one-line fix invisible on a healthy run, hence
`tests\Test-InstallerExitCode.ps1`.

A null `$exit` that survives anyway takes its **own arm** rather than the failure `else`: product in
ARP → `result='ok'`, `note='exit-unknown-but-registered'`; absent → `fail`, `note='exit-unknown'`.

### <a id="invoke-installer-rules"></a>Other `Invoke-Installer` rules

- **Capped `WaitForExit`, never `-Wait`.** `-Wait` is uncapped, so a stalled installer hangs the whole
  unattended run — no exit code, no transcript end, no manifest row, nothing to page on. Real trigger:
  `Nice Label.exe /s LICENSECODE=...` against a slow activation server, or an "another installation is
  in progress" dialog on a hidden window.
- **Never KILL it.** For these families the launcher may itself BE the install engine, so the run gives
  up on it (`result='fail-timeout'`) and lets the tally report the failure.
- **`-ConfirmRegistry`** — a raw-exe installer reports success by exit code alone, so an
  exit-0-but-not-installed case (GPO block, AV quarantine, wrong stub) would record `ok` with no
  product. That `fail` row is still replayed on `-Uninstall` and simply finds nothing to remove —
  [MANIFEST.md#step-2](MANIFEST.md#step-2).
- **3010/1641 raise the deferred-reboot flag from INSIDE the success arm.** It sat after the if/else,
  so a row that had just recorded `result='fail'` still printed the hard reboot banner — and the tech
  reboots a terminal that installed nothing, reading the reboot as the remediation.
- `-DryRun` simulates **before** the existence check: on a bare machine the real run downloads first,
  so a not-yet-present installer is not a failure here.
- <a id="redaction"></a>**Anything that RECORDS a command line redacts `LICENSECODE=`** (`$safeArgs`:
  the manifest's `args`, the console, hence the transcript); `$ArgList` reaches the installer
  untouched. The manifest survives `-Uninstall` under world-readable `%ProgramData%`, so the key
  outlived the install.

## <a id="vcredist"></a>VC++ bootstrap

CoreScanner hard-requires the x64 VC++ runtime. On a fresh-from-store box it is **absent** and the
Zebra wrapper would auto-install it and force a reboot that derails the silent flow (the dev rig had
it — "it worked here"; the client did not), so it goes first, `/norestart`. It is the one installer
deliberately routed **around** `Invoke-Installer`, because its success codes must include **1638** ("a
newer build is already present"), which `Invoke-Installer`'s omit.

> **`Install-VcRedist` re-confirms presence, not just the exit code.** Routed around `Invoke-Installer`
> it never got `-ConfirmRegistry` — and it is also the one that accepts 1638, which
> `Test-VcRedistPresent` had *disproved* a few lines earlier. A child MSI blocked by policy or AV exits
> 1638 (or 0) having installed nothing: recorded `ok`, CoreScanner then forces exactly the mid-install
> reboot this bootstrap exists to prevent, and the run still exits 0.

`Test-VcRedistPresent` reads the VC runtime `Installed` flag in either bitness view (authoritative),
with an ARP entry for the 2015-2022 / 2015-2019 x64 redist as the secondary test.

TLS 1.2 is set as this function's **first** action — do not rely on `Invoke-DownloadPhase` having run.
Both source URLs are evergreen permalinks; the old bare `/download/pr/` path was fabricated (HTTP 400
plus a tiny JSON body), so the "two sources" redundancy was illusory.

## <a id="wrapped-msi"></a>Wrapper-MSI extraction

InstallShield Setup Launcher wrappers (Zebra 123 Scan, Zebra Scanner SDK) crash on every documented
silent flag but **do** extract a usable `.msi` to `%TEMP%\{GUID}\` first, which is what this harvests.

- **5 consecutive equal size polls** (~15 s of no growth), alive writer or not: a 1 MB-and-accept
  staged a fragment of the 446 MB 123Scan MSI, and a 2-poll accept could still take a *growing* MSI
  across a Defender pause.
- **`HasExited` is NOT a stop signal** — an InstallShield Setup Launcher is exactly "a wrapper that
  exits fast but leaves a writer behind", and accepting on its exit staged a 40 MB fragment → 1603.
- **30 s early-out, but only if no candidate has EVER been seen**: a wrapper that died at t≈3 s used to
  sleep out the full 600 s, while without the never-seen clause an MSI still stabilizing at t=30 s
  trips the early-out.
- **The orphan reap uses the EXACT `$launchTime`, no minute of slack** — the two Zebra rows run back to
  back, so slack had row 2's reap killing a helper row 1 started a minute earlier and still used.
- **Staged to `logs\` before msiexec** so it survives the wrapper's temp cleanup, and that launch is
  `-ErrorAction Stop` with a launch-failed row — under `'Continue'` a failure left `$p` null and the
  verdict blamed an exit code never produced.
- **ARP is confirmed after a success exit code**, under a mandatory **`-ConfirmMatch`** (the narrow
  `$i.Match` — [#anchoring](#anchoring)). The candidate filter is "new `{*}` dir, largest `*.msi` over
  1 MB" and never proves our wrapper created it, so an RMM update dropping an MSI in `%TEMP%` during
  the poll got installed instead — exit 0, row `ok`, product absent, `-Uninstall` removed nothing.
- <a id="msi-cache"></a>**Cached only AFTER msiexec proves it installed**, from the **staged** copy (the
  wrapper may have wiped its `{GUID}` folder by now), under the row's **`CachedMsi` constant**
  (`-CacheAs`, **mandatory**). Caching on size+sniff alone let a mid-extract fragment 1603 on every
  future run — `-ForceReinstall` included — until someone deleted it by hand; caching under the
  vendor's extracted leaf name silently disabled the cache the `.iss` fallback reads.
- It is the **third writer of the deferred-reboot flag** (`Invoke-Installer` and `Install-VcRedist` are
  the others, and this one was missed): a 3010 here left the summary printing the soft "recommended:
  reboot" line.

## <a id="iss"></a>InstallShield `.iss` silent installs

Zebra's **documented** silent method, preferred over the temp-folder MSI extraction race:
`setup.exe -s -f1"<response.iss>" -f2"<log>"`. The `.iss` files are recorded once on the authorized
build rig with `setup.exe -r -f1"<iss>"` choosing production defaults, scrubbed of rig-specific paths,
and embedded as here-strings. Version-locked to the Drive-hosted wrappers (123Scan v6.00.0022, Scanner
SDK v3.07).

`Get-EmbeddedIss` materializes them **ASCII, no BOM, forced CRLF** (real CR/LF chars via backtick
escapes, not a literal `\r\n` text) — InstallShield's parser is byte-sensitive. It **verifies the file
landed and throws if not**: a .NET write exception is statement-terminating only, so under `'Continue'`
a failed write handed InstallShield an `/f1` pointing at nothing, which does **not** run silently — it
falls back to interactive on a hidden window and burns the full timeout.

### <a id="four-overrides"></a>The four overrides

All **default to the original Zebra behaviour**, so only a row that opts in changes anything — that is
what keeps the validated Zebra path byte-identical.

| Override | Default | Why it exists |
|---|---|---|
| `ArgFormat` | the Zebra `-s -f1"{0}" -f2"{1}"` line | A whole format string, not a prefix: InstallShield **rejects a line mixing `-` and `/` switch styles**, so a PFTW-wrapped IS5 package needs the WHOLE line in `/`-form. |
| `WaitNames` | Zebra's workers | Processes to **wait for** — the install isn't done while one is alive. |
| `ReapNames` | Zebra's helpers | Processes safe to **reap** afterwards. Two lists, because one literal serving both meanings means telling it about a new worker also tells it to kill that worker. Pass `@()` for families with no launcher/worker split. |
| `RegistryShortCircuit` | `$true` | See below. |

`ReapNames` and `RegistryShortCircuit` are looked up with **`-contains` the KEY**, because `@()` and
`$false` are legitimately falsy and an empty `ReapNames` ("never kill anything") is exactly what IS5
needs. The other two use a plain truthiness test — they have no meaningful empty value.

### <a id="registry-shortcircuit"></a>`RegistryShortCircuit`

- **`$true` (MSI-backed InstallScript):** the ARP entry appears when msiexec commits, near the end — so
  "present in registry" safely means "done".
- **`$false` (pure InstallScript / IS5):** the ARP entry is written *before* file transfer
  ([#already-installed](#already-installed)), so breaking on it would kill the worker mid-copy and
  record success.

It gates two things:

1. **The poll loop's short-circuit** — and the ARP test lives in the loop's **NO-WORKERS branch**, not
   as its first statement. As the first statement it fired on the very first poll of a *repair* run
   (exactly when `Test-PriorInstallFailed` declines the ARP skip and re-runs the installer) and the
   `break` fell straight into the `$ReapNames` sweep, force-killing the live `setup.exe` and then
   recording `ok`: the one path meant to repair a broken Zebra install was the one guaranteed to break
   it, silently, exit 0.
2. **The SUCCESS VERDICT**: `$logOk -or ($regOk -and $RegistryShortCircuit)`. A `$false` family must
   show `ResultCode=0` in the response log (reachable — `/f2` forwarding is proven), or a half-copied
   install is recorded `ok`, `Set-PrinterOpos`'s ARP driver guard passes too, and a device is
   registered aimed at a DLL that was never copied.

### <a id="poll-loop"></a>The poll loop

- **Capped wait on the launcher.** An uncapped `WaitForExit()` made `$TimeoutSeconds` no backstop at
  all: for a family whose launcher IS the whole install (OLE POS Setup, `ReapNames` empty), a stub
  blocked on an unexpected dialog on its hidden window hung the run forever. Never kill it, though —
  [#invoke-installer](#invoke-installer).
- **Scope to OUR workers.** Pre-existing msiexec PIDs are snapshotted before launch, so the wait scopes
  to the instance *this* wrapper spawns, not an unrelated long-lived one (Windows Update, RMM).
  Parent-PID scoping is unreliable because the `-s` launcher exits early and orphans its msiexec child.
  An inaccessible process counts as NOT-ours, so a locked SYSTEM process can't pin the loop.
- **The msiexec clause is gated on `RegistryShortCircuit`** — the flag that already means "MSI-backed
  family". Unconditional, a pure-InstallScript row (OLE POS Setup, no msiexec in the package) was
  pinned the full 900 s by an unrelated Windows Update msiexec, and the verdict then fired the moment
  *that* process ended.
- **The deadline is anchored after the launcher returns**, not at `$launchTime`: a launcher that ran 16
  minutes left zero worker budget, the loop never executed once, and the verdict was taken while
  msiexec was still copying 446 MB.
- **An idle poll ends the wait two ways.** **Two consecutive idle polls once a worker has been seen**
  (~6 s) — a single one ended the wait on the momentary gap where `setup.exe` finishes MSI #1 of the
  Zebra chain before spawning MSI #2, the reap force-killed the live workers, and the `fail` verdict
  dropped into the fallback: a second installer over the first. **Or ten idle polls (~30 s) when no
  worker was EVER seen**, which is how a family that leaves nothing to wait on and nothing for the ARP
  short-circuit to break on (`RegistryShortCircuit=$false`, OLE POS Setup) reaches its verdict at ~30 s
  instead of at the 900 s deadline.
- **Never force-kill msiexec** — it bricks the product mid-install. Only orphaned `$ReapNames` helpers
  are reaped.

### <a id="iss-log"></a>Only a log THIS launch produced counts

The response log's `LastWriteTime` is compared to `$launchTime`. The pre-run delete is best-effort by
necessity (`SilentlyContinue`), so a log held open by a crashed helper or an AV scanner survives it —
and reading the survivor served up the *previous* run's `ResultCode=0`, the entire verdict for a
`RegistryShortCircuit=$false` family, handed to a PFTW stub that access-violated and wrote nothing.

### <a id="iss-fallback"></a>The `.iss` → MSI fallback

Falls back only if the `.iss` method failed **and** the product is still absent: cached extracted MSI
if present, else the fixed wrapper. `NoMsiFallback` suppresses this for packages with no MSI at all —
otherwise `Invoke-WrappedMsi` launches the wrapper with no args (GUI on screen) and polls `%TEMP%` for
600 s, where it can pick up an unrelated MSI.

**The failed `.iss` row is DROPPED before the fallback appends its own.** `Invoke-IssSilent` records
`result='fail'` by design and the fallback records a second row under the same name; `Merge-PriorList`
only dedupes prior-vs-current, so both persisted — a run where the fallback *succeeded* exited 1, and
`Test-PriorInstallFailed` (any non-`ok` row) then returned `$true` forever, replaying the 446 MB Zebra
install every run.

Both fallbacks record the **broad `$uMatch`** ([#anchoring](#anchoring)): under `Zebra Scanner SDK`
alone the shared CoreScanner driver was never removed by `-Uninstall`. For the same reason the
uninstall orphan sweep gates on `method -eq 'iss-silent' -or note -eq 'msi-fallback'` — the `.iss` row
is *gone* by then, so a method-only test skipped the sweep for exactly the products whose `.iss`
attempt made the orphans. The surviving row is stamped **`note='msi-fallback'`** —
[#already-installed](#already-installed).

## <a id="rows"></a>Per-product notes

### <a id="posx"></a>POS-X `OLE POS Setup 2.84`

A PackageForTheWeb stub wrapping an **InstallShield 5.52 (InstallScript)** engine — a different animal
from the Zebra IS7 pair, hence all four `Iss*` overrides. Their values are in the row and the generic
rules are [#four-overrides](#four-overrides); what the row cannot tell you:

- **`/L0x0409` is mandatory**: `SETUP.INI` has `EnableLangDlg=Y` and the language dialog is shown by
  the **launcher**, before the engine — so it is not in the recorded `.iss` and can only be suppressed
  on the command line.
- <a id="is5-buffer"></a>**IS5 has a fixed command-line buffer.** The `/f1`/`/f2` paths must stay short:
  ~190 chars of inner command line works, ~390 crashes the PFTW stub with an access violation that
  looks like a broken package. `$DownloadDir`/`$LogDir` are fine, and that fixed `%ProgramData%` root
  is why there is no `-WorkDir` override.
- **`IKernel.exe` must never be killed** — it lingers by design and killing it blocks every later
  InstallShield install until reboot. That, not taste, is why `IssReapNames` is empty.
- Its `.iss` was recorded on the rig 2026-08-10 with `pkg.exe /a /r /f1"<path>"`. IS 5.52 means
  `Version=v5.00.000` and **plain dialog section names with no `{GUID}-` prefix** (unlike the Zebra IS7
  pair); `bOpt1`/`bOpt2=0` leaves the `SdFinish` checkboxes unticked, and with no `SdFinishReboot` in
  the chain no `BootOption` pin is needed (verified: no reboot, no pending-rename).
- ARP uninstall string: `C:\WINDOWS\IsUninst.exe -f"<...>\Uninst.isu"` —
  [#uninstall-flags](#uninstall-flags).

### <a id="star"></a>Star TSP100 futurePRNT

**A RAW-EXE row, not an `Iss` one.** The package is InstallShield **Basic MSI** (`extract_all` /
`IsConfig.ini` / `MsiExec` in its string table), so **none** of the `Iss*` machinery applies.

- `/s` (launcher) and `/v"…"` (forwarded to the inner msiexec) are documented verbatim by the vendor
  (`Readme_En.txt` §3) and *both* are required — `/s` alone still shows the MSI UI. **`/w` is ours and
  mandatory**: without it the Basic MSI launcher returns immediately instead of waiting and returning
  the inner msiexec's code, so `-ConfirmRegistry` read ARP mid-copy and the row failed forever.
- Author the args **single-quoted** — a double-quoted PowerShell string loses the inner quotes to the
  parser, and `Start-Process` joins the array with a plain `Join(' ')` adding no escaping of its own.
- `Match` is the ARP **DisplayName**, never the ProductCode, which changes every release (7.1.0 / 7.4.0
  / 7.5.1 / 7.7.0 all differ). Uninstall needs no new code — the generic msiexec dispatch normalises
  `/I`→`/X` and appends `/qn /norestart` — which is also why the row carries no `UninstallMatch` (it
  duplicated `Match`, and a raw-exe row never reads it).
- The zip also holds a 32-bit `setup.exe`; it goes unused because the row names the other member
  (`ZipMember='…/setup_x64.exe'`).

### <a id="nicelabel-args"></a>NiceLabel activation

NiceLabel 2019 takes the activation ID on `/s`'s command line for unattended online activation;
`LICENSECODE` alone lets the server auto-fill name/company/country/email, so by default **only**
`LICENSECODE` is sent. `-SkipNiceLabelActivation` falls back to plain `/s`. The args must stay an
**ARRAY**, not a string, so they run through `Invoke-Installer`'s `-ArgList` path — as a string
NiceLabel loses `/s` and installs non-silent/unlicensed.

## <a id="uninstall"></a>Silent uninstall

Registry lookup + per-family flags. **Registry polling is authoritative for completion; the exit code
is not.**

`Find-InstalledProducts` skips the `InstallShield_{GUID}` duplicate ARP entries the Zebra InstallScript
installs create alongside the real MSI product: they share the DisplayName but their `UninstallString`
is an **interactive** `setup.exe … -removeonly`. The real MSI entry removes the product silently; the
orphaned key is cleaned up by `Remove-InstallShieldOrphans`.

### <a id="anchoring"></a>ARP patterns: narrow vs broad, and ANCHORED

**Install-side checks (idempotency, `-ConfirmMatch`) take the narrow `Match`; anything recorded to the
manifest or pre-cleaned takes the broad `UninstallMatch`.** Both Zebra scanner wrappers are multi-MSI
InstallScript chains that also install the shared **Zebra CoreScanner Driver (64bit)** — the actual
scanner service, which the single extracted MSI does *not* install. Narrow keeps the CoreScanner
123Scan installs from falsely marking the SDK as already-installed; broad (`'…|Zebra CoreScanner'`) is
what `-Uninstall` replays, or CoreScanner is never removed. *(Field observation, not a code fact: the
CoreScanner ARP key has been seen as `{29707249}`. Nothing keys off it.)*

`Find-InstalledProducts` matches with `-match`, so an unanchored escaped name is a **substring** test.
When one DisplayName is a prefix of a sibling's (`TeamViewer` + `TeamViewer Host`, the standard
unattended-access pair) removing the first still "found" the second: the exit-0 re-check waited its
full 60 s, reported "still in registry — not removed", returned `$false`, and the caller raised
`$FinishFailed` → exit 1 on a terminal the *next* loop iteration then cleaned completely. So every
internal "is THIS exact ARP entry still there" test is `'^' + [regex]::Escape($name) + '$'`.

### <a id="uninstall-flags"></a>Per-family silent flags

A blanket `/S` is **wrong** (and hangs the unattended uninstall) for two products actually shipped:

- **Chrome** — `setup.exe` ignores `/S`; without `--force-uninstall` it pops a confirmation dialog that
  blocks forever. It reports success as **19** (`UNINSTALL_SUCCESSFUL`) or **29**
  (`UNINSTALL_REQUIRES_REBOOT`), **not 0**; **20** (`UNINSTALL_FAILED`) is deliberately not accepted,
  and 3010/1641 are MSI codes Chrome's setup.exe never emits.
- **InstallShield 5.x** (POS-X `OLE POS Setup 2.84`) — the giveaway (`IsUninst`) is in the **exe path**,
  not the argument tail, so a `$rest`-only test never matched it and it fell through to the generic
  `/S`, which IS5 does not understand, hanging to the timeout cap. Flags are `-a` (silent) `-y` (no
  confirm), **prepended** so the existing `-f"<.isu>"` and any `-c"<dll>"` survive verbatim. The `.isu`
  name is machine-dependent (`Uninst.isu` here, `DeIsL#.isu` elsewhere) — read from ARP, never built.
- InstallShield InstallScript maintenance launcher: lowercase `-s`.
- The argument tail is passed as **one verbatim string** — splitting on whitespace shatters quoted
  `C:\Program Files\…` arguments.

**The msiexec command is rewritten with an ANCHORED replace that eats everything up to and including
the exe name.** The old unanchored form only removed the word, so
`C:\WINDOWS\system32\MsiExec.exe /I{GUID}` became `C:\WINDOWS\system32\/X{GUID}`, which msiexec reads
as a package path and rejects with 1619 — the product could then never be uninstalled or pre-cleaned,
on every run.

**The exe/args split is on the `.exe` boundary, not the first space.** An unquoted ARP string
(`C:\Program Files\Vendor\uninst.exe /S`, common on older InstallScript/NSIS products) yielded
`$exe='C:\Program'`, which `Start-Process -Stop` threw on, and the catch reported a bare "uninstall
failed" with no hint the path was mangled.

**`1605` = "product not installed" is accepted.** `Find-InstalledProducts` snapshots BOTH entries of a
broad match (`Zebra Scanner SDK|Zebra CoreScanner`), and removing the SDK chain also removes
CoreScanner — so the second pass ran a stale `UninstallString`, returned `$false`, and made
`-Uninstall` exit 1 on a terminal that was actually clean. Every time.

### <a id="hang-heuristic"></a>The hang heuristic

NiceLabel's InstallShield Advanced UI bootstrapper *finishes* the removal, deletes its own exe, then
blocks forever waiting on a pending reboot — it never exits, so a plain `-Wait` hangs the entire
uninstall. So: poll, and the moment the product leaves the registry while the process is still alive,
that's the hung-post-removal case → kill the orphan and report success. The hard cap is a final
backstop; msiexec is never killed and stays on `-Wait`.

The ARP-gone break runs for **every** non-msiexec family, so a vendor that clears its ARP key *before*
deleting files (the uninstall-side mirror of the `DeinstallStart()` lesson) was killed on the first 5 s
poll and recorded as removed. It is therefore honoured only past a **60 s floor**.

> `ponytail:` 60 s flat floor is this heuristic's ceiling — a genuinely hung uninstaller pays 60 s, a
> slow-but-honest one under 60 s of file deletion still gets killed. Per-family floors only if a vendor
> needs one.

### <a id="exit0-recheck"></a>The exit-0 re-check is POLLED, not snapshotted

A success exit code other than 3010/1641 is re-checked against ARP: an uninstaller refused the silent
switch or blocked by policy/AV exits 0 having removed nothing, and nothing downstream re-scans. But it
**polls for 60 s**, because an NSIS uninstaller (TeamViewer's) copies itself to `%TEMP%` and relaunches
**detached** — the process we waited on exits 0 within a second while the removal is still running, and
the instantaneous test reported "still in registry after uninstaller exit 0 — not removed" on a removal
that finished seconds later (a counted reversal failure, and on the install side exit 1). Rig-observed.

**Both families re-check**, msiexec included. `$escName` used to be assigned inside the exe branch only,
so the whole poll was skipped for every MSI: a stale ProductCode in ARP returns the accepted `1605` and
reported "removed" with the product still installed. The poll costs nothing when the product really is
gone, which is what makes the documented `1605` case (a broad match's second, already-removed entry)
still pass instantly. Console strings: `removed <name> (exit <code>)` on success, `<name> uninstaller
exited <code>` on failure.

### <a id="nicelabel-uninstall"></a>NiceLabel

An InstallShield **Suite** with a dedicated handler, never the generic bootstrapper path. It registers
**two** ARP entries, both pointing at its bootstrapper (one keyed by the MSI ProductCode GUID, one by a
plain name). That bootstrapper **ignores `/silent`** and pops a confirm dialog → the unattended
uninstall hangs, so it is bypassed with `msiexec /x <ProductCode>`. But it is also what removes
everything that is not the MSI, and **msiexec leaves all of it behind (verified)**, so the sweep
explicitly removes:

- its **services** (stopped first — running services pin files, so msiexec would defer removal to a
  reboot and leave the registration behind)
- its own **ARP orphan key**
- `Classes\Installer\Products`, its `Features` sibling, and `UserData\S-1-5-18\Products` — named by a
  packed GUID, so they are found by **product name** instead (no GUID needed, so this runs on both
  paths). `Features` subkeys carry no `ProductName`, so they are matched by the key name of the
  `Products` hit
- the `%ProgramData%\{GUID}` cache (path read from the uninstall command)
- the ~900 MB of Suite-installed files (install dir captured from ARP `InstallLocation` **before**
  msiexec clears the registration; guarded by a NiceLabel-in-path check + `Test-Path`)

**`sc.exe`'s exit code is the only answer available** — it writes failures to *stdout*, so the old
`2>$null` suppressed nothing and the green "removed NiceLabel service" line printed over 1072
(`MARKED_FOR_DELETE`) and 5 (access denied) alike. A plain `foreach`, not `ForEach-Object`, so the
success flag is unambiguously ours. The registry sweep is **`-ErrorAction Stop` and counted**, with
`Test-Path` first so a `Features` key that legitimately does not exist is not a failure.

**Residue is checked FIRST**, because no authority after it can see a deferred service, an orphan key
or ~900 MB of Suite files. Authority then differs by path: on the **GUID path** msiexec's exit code
decides (the Suite's second, name-keyed entry legitimately lingers until its own pass, so a registry
re-scan here would false-fail the first of two passes); on the **no-GUID path** this pass removed no
product, so any surviving NiceLabel ARP entry is a real failure.

**Never pre-clean NiceLabel on reinstall** — see [#pre-clean](#pre-clean).
