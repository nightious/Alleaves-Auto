@echo off
setlocal enableextensions
REM ===================================================================
REM  Install-Alleaves.bat - the whole deliverable. It carries no payload:
REM  it downloads the current alleaves_setup.ps1 from the latest release
REM  and runs that, so a copy left on a terminal cannot go stale.
REM  Double-click = install.  "-Uninstall" = reverse.  "-DryRun" = test.
REM  Exit codes and usage: README.md.  Design: docs/BUILD-BAT.md
REM ===================================================================

REM --- Single elevation owner: probe elevated-integrity SID, relaunch once.
REM  docs/BUILD-BAT.md#elevation-probe - absolute path, BOTH SIDs, and abort
REM  (never relaunch) when the probe cannot answer. All three prevent a fork bomb.
set "SYS32=%SystemRoot%\System32"
set "WHOAMI=%SYS32%\whoami.exe"
if not exist "%WHOAMI%" goto :probefail
"%WHOAMI%" /groups | "%SYS32%\findstr.exe" /c:"S-1-16-12288" /c:"S-1-16-16384" >nul 2>&1
if not errorlevel 1 goto :elevated
REM  Second probe = the fork guard: no S-1-16-* label at all means the PROBE is
REM  broken, not that the token is unelevated. Abort instead of relaunching.
"%WHOAMI%" /groups | "%SYS32%\findstr.exe" /c:"S-1-16-" >nul 2>&1
if errorlevel 1 goto :probefail
echo Requesting administrator elevation...
REM  Two layers, both of which drop quoted args. Neither %* nor %~f0 may sit inside
REM  the -Command "..." string: the caller's own quote closes cmd's and a quoted
REM  regex pipe becomes a real pipe. And RunAs on a .bat re-enters cmd /c, which
REM  strips the outermost quote pair off the whole tail. So: path in a variable,
REM  args in a file, and relaunch cmd.exe double-wrapped, never the .bat direct.
REM  docs/BUILD-BAT.md#relaunch-args
set "ALLEAVES_SELF=%~f0"
>"%TEMP%\alleaves_args.txt" echo.%*
powershell -NoProfile -Command "$a=Get-Content -LiteralPath ($env:TEMP+'\alleaves_args.txt') -Raw -ErrorAction SilentlyContinue; if($a){$a=$a.Trim()}; $sp=@{FilePath=$env:ComSpec;Verb='RunAs';Wait=$true;PassThru=$true}; $sp.ArgumentList='/c ""'+$env:ALLEAVES_SELF+'" '+$a+'"'; exit (Start-Process @sp).ExitCode"
set "RC=%ERRORLEVEL%"
del /f /q "%TEMP%\alleaves_args.txt" >nul 2>&1
REM  "exit /b" MUST stay OUTSIDE any ( ) block. docs/BUILD-BAT.md#elevation-probe
exit /b %RC%

:probefail
echo [FAIL] Cannot determine this token's integrity level - refusing to relaunch.
echo        %SystemRoot%\System32\whoami.exe did not report a mandatory-label SID.
echo        Run Install-Alleaves.bat from cmd.exe or Explorer, not from a bash/MSYS
echo        shell - relaunching on an unreadable probe forks without bound.
exit /b 3

:elevated

REM --- Record requested mode so the .ps1 can refuse a dropped -Uninstall.
set "ALLEAVES_REQUESTED_MODE=install"
REM  Padded on both sides: a bare substring made -ComputerName TILL-UNINSTALL-2
REM  request an uninstall, and the .ps1 refused it with exit 2.
echo. %* .| "%SYS32%\find.exe" /i " -uninstall " >nul 2>&1 && set "ALLEAVES_REQUESTED_MODE=uninstall"
echo Mode: %ALLEAVES_REQUESTED_MODE%

REM --- Force 64-bit PowerShell (Sysnative when launched from a 32-bit shell).
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"

REM --- Fetch the current installer from the latest release. docs/BUILD-BAT.md#fetch
REM  .part staging, a parse check and BOTH pre-deletes are load-bearing - see the doc.
set "SETUPURL=https://github.com/nightious/Alleaves-Auto/releases/latest/download/alleaves_setup.ps1"
if exist "%TEMP%\alleaves_setup.ps1" del /f /q "%TEMP%\alleaves_setup.ps1"
if exist "%TEMP%\alleaves_setup.ps1.part" del /f /q "%TEMP%\alleaves_setup.ps1.part"
echo Downloading the current installer...
"%PS%" -NoProfile -Command "$ErrorActionPreference='Stop'; try { [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]3072; $p=$env:TEMP+'\alleaves_setup.ps1.part'; (New-Object Net.WebClient).DownloadFile($env:SETUPURL,$p); [void][ScriptBlock]::Create([IO.File]::ReadAllText($p)); Move-Item -LiteralPath $p -Destination ($env:TEMP+'\alleaves_setup.ps1') -Force } catch { Write-Host ('  ' + ($_.Exception.Message -split '\r?\n')[0]) }"
if not exist "%TEMP%\alleaves_setup.ps1" (
  echo.
  echo FATAL: could not download the installer from
  echo        %SETUPURL%
  echo        Check this terminal's internet connection, then re-run.
  del /f /q "%TEMP%\alleaves_setup.ps1.part" >nul 2>&1
  if not defined ALLEAVES_NOPAUSE pause
  REM 10, NOT 9 - launcher-only. docs/BUILD-BAT.md#fetch
  exit /b 10
)

REM --- Run synchronously in this elevated console; propagate exit code.
REM  QUOTE any -SkipPrograms regex containing cmd metacharacters (| ^ & < >),
REM  e.g. -SkipPrograms "Chrome|NiceLabel". docs/BUILD-BAT.md#args
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%TEMP%\alleaves_setup.ps1" %*
set "RC=%ERRORLEVEL%"

REM --- Temp hygiene + surface result for RMM/monitoring.
del /f /q "%TEMP%\alleaves_setup.ps1" >nul 2>&1
echo.
echo Alleaves setup exit code: %RC%
REM  Skip the pause for unattended/RMM runs: set ALLEAVES_NOPAUSE=1.
if not defined ALLEAVES_NOPAUSE pause
exit /b %RC%
