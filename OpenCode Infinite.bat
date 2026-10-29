@echo off
setlocal EnableExtensions
title OpenCode
REM ============================================================
REM  OpenCode launcher  (v2.16)
REM  Multi-egress (WARP / TOR / free HTTP) + dependency bootstrap
REM  + auto-resume.
REM
REM  Usage:
REM    double-click                          -> folder menu
REM    drag a folder onto this file          -> opens in that folder
REM    "OpenCode Infinite v2.16.bat" "D:\work\project"
REM                                          -> opens in that folder
REM
REM  This script never moves, renames or deletes your chats, your
REM  history or any file of yours, except option [5] Deep reset,
REM  which asks first and archives before it deletes. The self-update
REM  in [upd] is the only other file it touches: it replaces this
REM  script with the newer repo copy, only after you say yes, and
REM  only after a backup of this script was made first.
REM
REM  Everything is user-mode. UAC is only needed if WARP
REM  has to be installed, and WARP is optional: without it the
REM  launcher still starts opencode, only rotation is skipped.
REM
REM  PROXY SCOPE: HTTP_PROXY / HTTPS_PROXY are set only for the
REM  opencode process tree (TUI + resume + probe). The rest of the
REM  system (browser, other apps) is never touched.
REM
REM  Works on Windows 10/11, x64 / arm64 / 32-bit (limited), any
REM  system language. The UI text is English only.
REM
REM  What it does
REM  - Finds opencode on the machine, asks each candidate for its
REM    version and runs the newest one. An old standalone exe sitting
REM    next to a current npm CLI is skipped instead of chosen by name,
REM    and a v1 binary pointed at a v2 database is reported in plain
REM    text instead of failing inside opencode. The menu shows the
REM    version and path actually in use.
REM
REM  - Bootstraps what is missing: WARP (silent MSI install, UAC
REM    once) and opencode (npm first, standalone build otherwise,
REM    npm with 32-bit node on x86), with curl -f and a size gate on
REM    every download.
REM
REM  - Once per start, checks npm for a newer opencode-ai and offers to
REM    install it: installed version from "%OC_CMD% --version", latest
REM    from "npm view opencode-ai version" over a direct connection (no
REM    WARP proxy) with a hard 15 s cap, compared with :ver_gt. It asks
REM    [Y/N] first, never runs during an automatic resume, and stays
REM    silent when npm or the network is unavailable.
REM
REM  - After the workspace is chosen, asks for the egress mode:
REM      [1] WARP   - Cloudflare WARP proxy mode (rotation supported)
REM      [2] TOR    - local Tor SOCKS via an HTTP bridge (Privoxy
REM                   on 127.0.0.1:8118, process-only)
REM      [3] PROXY  - free HTTP proxies from the ProxyScrape list
REM                   (process-only; dead ones are skipped)
REM      [4] NONE   - direct, no proxy
REM
REM  - In TOR mode no WARP rotation runs: a retry restarts the
REM    resume on the same circuit. In PROXY mode a retry picks
REM    another free proxy. NONE returns to the menu.
REM
REM  - Rotates the WARP egress IP through the local proxy: drops the
REM    old registration, creates a new one, verifies the trace says
REM    warp=on, and starts the tunnel in proxy mode. Every warp-cli
REM    call is time-bounded and logged to wcli.log, with the daemon's
REM    own error text on every failure, so a wedge is readable instead
REM    of a private salt of exit codes. A missing WARP registration is
REM    detected and recreated before any tunnel call, and the tunnel
REM    falls back to WireGuard when MASQUE is refused.
REM
REM  - Verifies the route, not just the tunnel: IP fetches ignore
REM    stale HTTP_PROXY/HTTPS_PROXY, and optionally each candidate IP
REM    gets one cheap probe message on a throwaway session so burned
REM    IPs are skipped. IP_FIND_MAX=0 keeps hunting until one works.
REM
REM  - Watches the log while opencode runs. A fatal line (drain
REM    failure, usage limit, rate limit, quota, credits) kills the TUI
REM    and starts the egress retry; recoverable errors are ignored, so
REM    it only fires when the chat is actually stuck.
REM
REM  - Resumes the chat on the new IP. The resume runs as a bounded
REM    child process with stdout and stderr captured, under a private
REM    server born with the current proxy env. On OpenCode v2 that is
REM    --standalone; v1 has no shared service and no such flag, so the
REM    launcher probes the CLI help and drops the flag there. If it
REM    does not answer within RESUME_TIMEOUT the whole tree is killed
REM    and the launcher rotates instead of freezing on "sending
REM    continue". On failure the last lines of resume.err are printed.

REM  - Restarts the background opencode service after every rotation
REM    (v2 only), so the next TUI never inherits sockets from the old
REM    tunnel. v1 starts a fresh server per process, so there is
REM    nothing to restart.
REM
REM  - Locking and housekeeping: a second instance is locked out,
REM    temp files are unique, settings are validated numeric, every
REM    PowerShell call uses %PSX% with TLS 1.2 forced, and every path
REM    reaches PowerShell through the environment.
REM
REM  - Deep reset archives across volumes with copy-verify-delete
REM    before removing anything.
REM
REM  - Self-update [upd]: once per start the launcher checks the GitHub
REM    repo for a newer copy of itself. Silent when equal or offline;
REM    when a new version is found it asks, backs this script up, and
REM    swaps the new one in through a helper on a post-exit window.
REM
REM  All tunables live in the settings block below: rotation tries,
REM  probe on/off and its model, resume message and timeout, WARP
REM  timings, log watching, the proxy port, TOR/Privoxy ports, the
REM  ProxyScrape URL, and the self-update.
REM ============================================================

REM - settings (edit freely)
REM Rotation attempts for infrastructure problems (tunnel not up).
set "ROTATE_TRIES_MAX=4"
REM How many IPs the probe may reject as burned before giving up.
REM 0 = keep hunting until one works (Ctrl+C stops the launcher).
set "IP_FIND_MAX=0"
REM Seconds to wait after (re)connecting WARP.
set "WARP_WAIT=6"
REM Seconds to WAIT between rotate attempts. Cloudflare throttles rapid
REM "registration new" bursts (429 Too Many Requests); spacing them out
REM keeps the attempts accepted, which is why a fast burst can end in
REM errors while the same rotation spaced over seconds works.
set "ROTATE_COOLDOWN=10"
REM Full rotate cycles (each up to ROTATE_TRIES_MAX tries) with a 60 s
REM cool-down between cycles, before the launcher finally gives up and
REM puts you back at the menu. 0 = one cycle, no repeat rounds.
set "ROTATE_ROUNDS=3"
REM Seconds a single warp-cli call may take before it is killed.
set "WARP_CALL_TIMEOUT=15"
REM Seconds a single "where" lookup may take before it is killed. A PATH
REM entry on a dead mapped drive or an offline UNC share makes where.exe
REM block for minutes, and it does it before a single line is printed.
set "WHERE_TIMEOUT=5"
REM 1 = watch the log while opencode runs, rotate on any fatal error.
set "WATCH=1"
REM Message sent automatically so the chat continues where it stopped.
set "RESUME_MSG=continue"
REM 1 = the automatic resume runs unattended (auto-approves tool
REM permissions). 0 = the resume may stop and wait for permission.
set "RESUME_AUTO=1"
REM Seconds the resume message may run before it is killed and treated
REM as a dead exit IP. This is the hard stop that keeps the launcher
REM from sitting on "sending continue" forever.
set "RESUME_TIMEOUT=90"
REM Model used by the IP probe: one cheap message per candidate IP.
set "PROBE_MODEL=opencode/deepseek-v4.1-flash-free"
REM PROBE=0 skips the probe entirely (IPs are accepted without testing).
REM Default ON so burned free-tier IPs are skipped before resume.
set "PROBE=1"
REM 1 = every start checks the GitHub repo for a newer launcher,
REM offers to replace this script (backup first, ask first).
REM 0 = never touches the network for the launcher itself.
REM v2.16: default OFF while the repo copy is older than this file.
REM The complete [upd] block is unchanged; set this to 1 to re-enable it.
set "UPDATE_CHECK=0"

REM --- multi-egress tunables ---
REM TOR SOCKS port (default Tor Browser / tor service). Informational:
REM the launcher talks to the HTTP bridge, never to this port directly.
set "TOR_SOCKS_PORT=9050"
REM Privoxy (or any HTTP->SOCKS bridge) listen port. Required because
REM OpenCode/Bun does not speak SOCKS5 natively; only HTTP_PROXY works.
set "TOR_HTTP_PORT=8118"
REM ProxyScrape free list (protocolipport text). Only http:// entries used.
set "PROXY_LIST_URL=https://api.proxyscrape.com/v4/free-proxy-list/get?request=display_proxies&protocol=http&proxy_format=protocolipport&format=text"
REM How many free proxies to try before giving up (per rotate).
set "PROXY_TRY_MAX=12"
REM Seconds a single free-proxy probe may take.
set "PROXY_PROBE_TIMEOUT=8"

REM - internal
REM Local port where the WARP proxy listens (WARP proxy mode).
set "PROXY_PORT=40000"
REM HTTP and SOCKS5 forms of the same local proxy, used by curl.
set "PROXY=http://127.0.0.1:%PROXY_PORT%"
set "SOCKS_PROXY=socks5h://127.0.0.1:%PROXY_PORT%"
REM Endpoint that returns ip= and warp= lines, used to check the IP.
set "TRACE_URL=https://www.cloudflare.com/cdn-cgi/trace"
REM Official download address for the WARP installer (64-bit MSI).
set "WARP_MSI_URL=https://downloads.cloudflareclient.com/v1/download/windows/ga"
REM Self-update source. In this file a literal % is written %% , so the
REM URL below ends in the real "...%20Infinite.bat" form the repo uses.
set "UPDATE_URL=https://raw.githubusercontent.com/jeko1107/opencode-infinite/main/OpenCode%%20Infinite.bat"
REM Hosts that must never go through the proxy.
set "NO_PROXY=localhost,127.0.0.1,0.0.0.0,::1,[::1]"
REM Default PowerShell command; replaced below by the full path if it exists.
set "PSX=powershell"
if exist "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" set "PSX=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
REM This file's own path: the folder picker reads its embedded PowerShell
REM block from here, so the picker never needs a helper file on disk.
set "OCI_SELF=%~f0"
REM EGRESS mode: WARP | TOR | PROXY | NONE (set by the menu after the folder)
set "EGRESS=WARP"
REM ACTIVE_PROXY holds the exact URL handed to opencode (process-only).
set "ACTIVE_PROXY="

REM UTF-8 console: folder paths in any system language survive the
REM write/read round trip in lastfolder.txt
REM Note: chcp 65001 changes the code page of the whole console window
REM for as long as this launcher runs, not only for this script.
chcp 65001 >nul 2>&1

REM Where opencode keeps its data (chats, database, auth).
set "DATA_DIR=%USERPROFILE%\.local\share\opencode"
REM Log file the watcher and the quota check read. Falls back to the
REM LOCALAPPDATA location if the first one does not exist.
set "LOGFILE=%DATA_DIR%\log\opencode.log"
if not exist "%LOGFILE%" if exist "%LOCALAPPDATA%\opencode\log\opencode.log" set "LOGFILE=%LOCALAPPDATA%\opencode\log\opencode.log"
REM Folder for the launcher own state files (last folder, last IP, logs, locks).
set "STATE_DIR=%LOCALAPPDATA%\opencode-launcher"
set "LASTFOLDER=%STATE_DIR%\lastfolder.txt"
REM Run-time flags that are set and cleared during the session.
REM RESUME: 1 when the next launch should continue the last chat.
set "RESUME="
REM COLD: 1 = fresh start, 0 = continue the same session.
set "COLD=0"
REM WARP_UP: 1 once WARP has been connected in this session.
set "WARP_UP=0"
REM QHIT / FHIT: set to 1 when a quota or fatal error is found in the log.
set "QHIT="
set "FHIT="
REM IP and WARP hold the current exit IP and the WARP path, if found.
set "IP="
set "WARP="
REM OC_CMD: full path of the opencode command, filled by find_opencode.
set "OC_CMD="
REM CLI capabilities, filled by :detect_caps once opencode is located:
REM CAP_STANDALONE=1 when "run --standalone" exists (OpenCode v2),
REM CAP_SERVICE=1 when the "opencode service" command exists (v2).
REM v1 has neither: --standalone makes it print the help screen instead
REM of running the message, and "service" is an unknown command.
set "CAP_STANDALONE="
set "CAP_SERVICE="
REM OCUPD: 1 once the once-per-start npm version check has run.
set "OCUPD="
REM one fixed throwaway session for every probe: deleted after a pass
REM so that --continue always points at the real chat, never the probe
set "OC_PROBE_ID=ses_probe0000000"
REM fatal error family: anything that ends the chat without the user
REM choosing to stop. The pattern is matched against log lines.
set "OC_PAT=level=ERROR.*(Failed to drain Session|free usage limit|usage limit reached|rate limit|out of usage|insufficient credits|payment required)"

REM 32-bit Windows: PROCESSOR_ARCHITEW6432 is defined when a 32-bit
REM process runs on a 64-bit OS, so x86 alone is not proof.
REM REAL86=1 means a true 32-bit Windows system (WARP and opencode
REM standalone builds are not available there).
set "REAL86=0"
if /i "%PROCESSOR_ARCHITECTURE%"=="x86" if not defined PROCESSOR_ARCHITEW6432 set "REAL86=1"

REM Validate the numeric settings: invalid values fall back to defaults.
call :numcfg ROTATE_TRIES_MAX 4
call :numcfg WARP_WAIT 6
call :numcfg ROTATE_COOLDOWN 10
call :numcfg ROTATE_ROUNDS 3
call :numcfg WARP_CALL_TIMEOUT 15
call :numcfg WHERE_TIMEOUT 5
call :numcfg RESUME_TIMEOUT 90
call :numcfg PROXY_TRY_MAX 12
call :numcfg PROXY_PROBE_TIMEOUT 8
call :numcfg TOR_SOCKS_PORT 9050
call :numcfg TOR_HTTP_PORT 8118
REM this one may legitimately be 0 (hunt with no limit)
call :numcfg0 IP_FIND_MAX 0

REM Create the state folder if it is missing, then check the single-instance lock.
if not exist "%STATE_DIR%" mkdir "%STATE_DIR%" >nul 2>&1
REM Fresh trace for this run: the last line names the stage that froze.
if exist "%STATE_DIR%\startup.log" del /f /q "%STATE_DIR%\startup.log" >nul 2>&1
call :lock_check

REM Once per start: check the repo for a newer launcher. Silent when
REM nothing to do or offline; asks before ever replacing this file.
if "%UPDATE_CHECK%"=="1" call :self_update

REM ============================================================
REM  1) WORKING FOLDER
REM ============================================================
REM No parenthesised block may expand a path variable: a folder like
REM "Program Files (x86)" unbalances the block while it is parsed.
REM Everything here is sequential ifs and gotos instead.
REM If a folder was passed as argument (drag and drop), use it directly.
if "%~1"=="" goto :folder
if not exist "%~1\" goto :folder
set "OPFOLDER=%~1"
goto :folder_ok

REM Folder menu: reopen last folder, use the current one, browse, or exit.
:folder
cls
echo ============================================================
echo   OpenCode - choose a folder to work in
echo ============================================================
echo.
set "OPFOLDER="
set "LASTPATH="
REM Read the saved folder path, strip quotes, and drop it if it no longer exists.
if exist "%LASTFOLDER%" set /p LASTPATH=<"%LASTFOLDER%"
if defined LASTPATH set "LASTPATH=%LASTPATH:"=%"
if defined LASTPATH if not exist "%LASTPATH%\" set "LASTPATH="
echo.
echo   [1] Reopen the last folder
REM Show the saved path only when there is one; otherwise show a placeholder.
if defined LASTPATH goto :folder_lp
echo       ^(nothing saved yet^)
goto :folder_m2
:folder_lp
echo       "%LASTPATH%"
:folder_m2
echo   [2] Use this folder
echo       "%CD%"
echo   [3] Browse for a folder...
echo   [4] Exit
echo.
echo   One key, no Enter. ESC exits like [4].
echo.
REM Raw key read first, classic choice as the headless fallback.
call :readkey
if "%READKEY%"=="HEADLESS" goto :folder_choice
if /i "%READKEY%"=="ESC" goto :quit
if /i "%READKEY%"=="4" goto :quit
if /i "%READKEY%"=="3" goto :pick_folder
if /i "%READKEY%"=="2" goto :use_current
if /i "%READKEY%"=="1" goto :folder_1
goto :folder

:folder_choice
REM choice returns the key number through errorlevel: check highest first.
choice /c 1234 /n /m "Pick: "
if errorlevel 4 goto :quit
if errorlevel 3 goto :pick_folder
if errorlevel 2 goto :use_current
:folder_1
REM Option 1 with nothing saved: explain, wait, and show the menu again.
if not defined LASTPATH (
  echo.
  echo   No folder saved yet. Use [2] or [3] this time.
  timeout /t 3 /nobreak >nul 2>&1
  goto :folder
)
set "OPFOLDER=%LASTPATH%"
goto :folder_ok

REM Option 2: the folder the launcher was started from.
:use_current
set "OPFOLDER=%CD%"
goto :folder_ok

REM Option 3: modern Explorer folder picker (IFileDialog, FOS_PICKFOLDERS),
REM opened in the last used folder. ESC or X on it opens the classic
REM FolderBrowserDialog right after; cancelling that one too reaches the
REM retry question. Both pickers live at the end of this same file, after
REM the batch body, and run through :run_picker, which reads this script
REM with PowerShell and captures the chosen path from stdout. No helper
REM files and no temp results: the dialog is the only thing that touches
REM the disk, and it writes nothing.
:pick_folder
echo.
echo   Choose a folder in the dialog...
set "OPFOLDER="
REM Both dialogs open where the user last worked, when that folder exists.
set "OC_START=%USERPROFILE%"
if defined LASTPATH if exist "%LASTPATH%\" set "OC_START=%LASTPATH%"
set "OC_MODE=modern"
call :run_picker
if defined OPFOLDER goto :pick_done
REM Modern dialog cancelled (ESC/X) or unable to start: classic fallback.
echo   Opening the classic folder picker...
set "OC_MODE=classic"
call :run_picker
if defined OPFOLDER goto :pick_done
echo.
echo   No folder selected.
choice /c YN /n /m "   Try again? [Y/N]: "
if not errorlevel 2 goto :pick_folder
goto :folder
:pick_done
goto :folder_ok

REM - run the embedded picker (see the block after the end of the batch
REM   body) and capture the chosen folder from stdout. OC_MODE selects the
REM   dialog. The picker script is read out of this file from its marker
REM   line down, so the C# interop never has to cross cmd quoting and no
REM   helper file is ever written.
:run_picker
set "OPFOLDER="
call :olog "picker: %OC_MODE% dialog starting"
for /f "usebackq delims=" %%i in (`%PSX% -NoProfile -STA -Command "$l=Get-Content -LiteralPath $env:OCI_SELF; $i=[Array]::IndexOf($l,'#>>>OC_PICKER_PS'); if($i -lt 0){exit 1}; Invoke-Expression (($l[($i+1)..($l.Count-1)]) -join [Environment]::NewLine)"`) do set "OPFOLDER=%%i"
if not defined OPFOLDER goto :run_picker_none
call :olog "picker: %OC_MODE% returned a folder"
goto :eof
:run_picker_none
call :olog "picker: %OC_MODE% returned nothing"
goto :eof

REM Read one raw console key without waiting for Enter. Result in READKEY:
REM a letter/digit, ESC, ? (ignored key) or HEADLESS when the console is
REM not interactive (UTF holdover: RawUI fails under redirected stdin or a
REM non-console host, the menu then falls back to the classic choice line).
:readkey
set "READKEY="
set "RK_OUT=%TEMP%\oc_key_%RANDOM%.txt"
if exist "%RK_OUT%" del /f /q "%RK_OUT%" >nul 2>&1
"%PSX%" -NoProfile -Command "try{ if([Console]::IsInputRedirected){ throw 'headless stdin' }; $k=$Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown').Character; $s=[string]$k; if($k -eq [char]27){ $s='ESC' } elseif($k -notmatch '^[0-9A-Za-z]$'){ $s='?' }; [IO.File]::WriteAllText($env:RK_OUT, $s.ToUpper()) }catch{ [IO.File]::WriteAllText($env:RK_OUT, 'HEADLESS') }" >nul 2>&1
if exist "%RK_OUT%" for /f "usebackq delims=" %%i in ("%RK_OUT%") do set "READKEY=%%i"
if exist "%RK_OUT%" del /f /q "%RK_OUT%" >nul 2>&1
if not defined READKEY set "READKEY=HEADLESS"
exit /b

REM Check that the chosen folder exists before entering it.
:folder_ok
if exist "%OPFOLDER%\" goto :folder_ok2
echo.
echo   Folder not found: "%OPFOLDER%"
timeout /t 3 /nobreak >nul 2>&1
goto :folder

REM Enter the folder. pushd is used because it also accepts UNC (network) paths.
:folder_ok2
pushd "%OPFOLDER%" 2>nul
if not errorlevel 1 goto :folder_ok3
echo.
echo   Cannot enter: "%OPFOLDER%"
timeout /t 3 /nobreak >nul 2>&1
goto :folder

REM POPPED marks that a pushd was done, so :quit runs popd.
REM The path is saved in quotes; the quotes are removed when it is read back.
:folder_ok3
set "POPPED=1"
REM quoted write + quote-strip on read: survives & and () in the path
>"%LASTFOLDER%" echo "%CD%"
title OpenCode
echo.
echo   Working in: "%CD%"
call :trace folder "%CD%"
echo.

REM ============================================================
REM  1b) EGRESS MODE (process-only for opencode)
REM ============================================================
REM Asks once after the folder is fixed. The choice lives in EGRESS and
REM ACTIVE_PROXY. Only the opencode process tree inherits the proxy env.
:egress_menu
echo ============================================================
echo   Choose egress for OpenCode only (system traffic stays direct)
echo ============================================================
echo.
echo   [1] WARP     - Cloudflare WARP proxy mode (rotation supported)
echo   [2] TOR      - local Tor SOCKS via HTTP bridge on :%TOR_HTTP_PORT%
echo   [3] PROXY    - free HTTP proxies (ProxyScrape list)
echo   [4] NONE     - direct, no proxy
echo.
echo   One key, no Enter.
echo.
choice /c 1234 /n /m "Pick egress: "
if errorlevel 4 (
  set "EGRESS=NONE"
  set "ACTIVE_PROXY="
  set "WARP="
  echo   [egress] NONE - direct.
  goto :egress_done
)
if errorlevel 3 (
  set "EGRESS=PROXY"
  set "ACTIVE_PROXY="
  set "WARP="
  echo   [egress] PROXY - free HTTP list.
  goto :egress_done
)
if errorlevel 2 (
  set "EGRESS=TOR"
  set "WARP="
  set "ACTIVE_PROXY=http://127.0.0.1:%TOR_HTTP_PORT%"
  echo   [egress] TOR - expect Tor on :%TOR_SOCKS_PORT% + Privoxy on :%TOR_HTTP_PORT%.
  goto :egress_done
)
set "EGRESS=WARP"
set "ACTIVE_PROXY="
echo   [egress] WARP.
:egress_done
echo.
call :trace egress %EGRESS%

REM ============================================================
REM  2) DEPENDENCIES
REM ============================================================
REM Each stage names itself before it runs. They are silent when they work,
REM and a silent console cannot be told apart from a frozen one.
REM HAVE_CURL=1 when curl.exe is available (it is used for downloads and IP checks).
call :trace dep_curl
echo   [dep] curl
call :have_exe curl.exe
set "HAVE_CURL=%HAVE%"

REM - WARP (optional, only when EGRESS=WARP)
if /i not "%EGRESS%"=="WARP" goto :check_opencode
REM Look for warp-cli. If found, skip the WARP setup and go to opencode.
call :trace dep_warp
echo   [dep] warp
call :find_warp
if defined WARP goto :check_opencode

REM 32-bit systems cannot run the WARP installer: skip the offer.
if "%REAL86%"=="1" goto :no_warp_32

echo   [!] Cloudflare WARP not found - IP rotation will be disabled.
echo       Install it later from 1.1.1.1 if you want the rotation.
echo.
REM Offer the install. Answering N continues without rotation.
choice /c YN /n /m "   Try to download and install WARP now? [Y/N]: "
if errorlevel 2 goto :check_opencode
call :install_warp
call :find_warp
if defined WARP goto :warp_ready
echo   [!] WARP still not available - continuing without rotation.
echo       warp-cli errors, if any, are in %STATE_DIR%\wcli.log
goto :check_opencode

REM Message shown on 32-bit systems, then continue without WARP.
:no_warp_32
echo   [!] Cloudflare WARP publishes 64-bit Windows builds only.
echo       On this 32-bit system rotation is disabled.
goto :check_opencode

REM WARP was installed or found: confirm and continue.
:warp_ready
echo   [ok] WARP ready.

REM - opencode
REM Look for the opencode command. If found, go to the menu.
:check_opencode
call :trace dep_opencode
echo   [dep] opencode
call :find_opencode
call :db_guard
if defined OC_CMD goto :ready

REM Not found: install it (npm first, then the standalone build).
echo   [auto-install] opencode not found, fetching it...
call :install_opencode
call :find_opencode
if defined OC_CMD (
  echo   [ok] opencode ready.
  goto :ready
)
REM The install failed: show a manual link and stop.
echo   ERROR: opencode install failed or is not on PATH.
echo   Get it by hand: https://github.com/sst/opencode/releases
pause
goto :quit

REM Both dependencies are ready. Probe what this CLI build supports,
REM then a short pause before the menu.
:ready
call :detect_caps
call :oc_update_check
call :trace ready
timeout /t 1 /nobreak >nul 2>&1

REM ============================================================
REM  3) MENU
REM ============================================================
REM Main menu. Each pass redraws the screen and checks the IP.
:menu_loop
call :trace menu
REM keep the lock fresh so a second launcher can tell it is alive
REM The lock folder gets a new stamp each time, so its age shows it is alive.
if exist "%STATE_DIR%\lock\" echo(%RANDOM%>"%STATE_DIR%\lock\stamp" 2>nul
cls
echo ============================================================
echo   OpenCode
echo.
echo   Folder : "%CD%"
echo   Egress : %EGRESS%
if defined ACTIVE_PROXY echo   Proxy  : %ACTIVE_PROXY%
REM Show the WARP path only in WARP mode; otherwise say rotation is off.
if /i not "%EGRESS%"=="WARP" goto :menu_warp_done
if defined WARP goto :menu_warp_path
echo   WARP   : none ^(rotation disabled^)
goto :menu_warp_done
:menu_warp_path
echo   WARP   : "%WARP%"
:menu_warp_done
if not defined OC_VER goto :menu_ver_done
echo   Version: %OC_VER%  "%OC_CMD%"
:menu_ver_done
echo ============================================================
echo.

REM Connect WARP the first time the menu is shown in this session.
REM Later passes skip this step, because WARP_UP is already 1.
if /i not "%EGRESS%"=="WARP" goto :menu_ip
if not defined WARP goto :menu_ip
if "%WARP_UP%"=="1" goto :menu_ip
call :warp_up
set "WARP_UP=1"
REM Read the current exit IP through the proxy. WFLAG receives warp=on or off.
:menu_ip
set "WFLAG="
if /i "%EGRESS%"=="WARP" if defined WARP call :getip2 IP WFLAG
if defined IP goto :menu_ip_ok
REM No IP could be read: show "unknown" with the reason.
set "IP=unknown"
if /i "%EGRESS%"=="WARP" if defined WARP set "IP=unknown - WARP proxy not answering"
if /i "%EGRESS%"=="TOR" set "IP=via Tor"
if /i "%EGRESS%"=="PROXY" if defined ACTIVE_PROXY set "IP=via free proxy"
if /i "%EGRESS%"=="NONE" set "IP=direct"
:menu_ip_ok
echo   Exit IP: %IP%
echo.
echo   What do you want to do?
echo.
echo   [1] Fresh start   - get a new IP / proxy, then open OpenCode
echo                       (your chats and history stay untouched)
echo   [2] Continue      - same egress, open OpenCode as it was
echo   [3] Change IP     - rotate / pick new proxy only
echo   [4] Folder        - work in a different folder
echo   [5] Deep reset    - kill opencode, move chats to the Desktop,
echo                       clear saved tokens, open a fresh session
echo   [6] Exit
echo.
echo   One key, no Enter.
echo.
REM Read the menu choice. Highest number is checked first.
choice /c 123456 /n /m "Pick: "
REM choice exits 0 when stdin has no answer (piped input, EOF): redraw the
REM menu instead of guessing option 1 and launching on a cold start.
if not errorlevel 1 goto :menu_loop
if errorlevel 6 goto :quit
if errorlevel 5 goto :run_deep
if errorlevel 4 goto :folder
if errorlevel 3 goto :rotate
if errorlevel 2 goto :run_warm
goto :run_cold

REM Option 1 (fresh start): COLD=1 asks for a new IP before launching.
:run_cold
set "COLD=1"
goto :run

REM Option 2 (continue): COLD=0 keeps the current IP and session.
:run_warm
set "COLD=0"
goto :run

REM - the discord-style reset: close, archive, wipe tokens, reopen
REM Option 5. Destructive part: asks first, then closes opencode,
REM moves the chats to the Desktop and clears tokens.
:run_deep
echo.
echo --- deep reset -----------------------------------------------
echo   This closes opencode, moves your chats to the Desktop,
echo   clears the saved tokens and opens a brand new session.
echo   It is the only action in this script that touches your files.
echo.
choice /c yn /n /m "  Do that now? [Y/N] "
if errorlevel 2 goto :menu_loop
call :stop_opencode
call :deep_archive
call :clear_tokens
REM After a reset there is nothing to resume: start cold.
set "RESUME="
set "COLD=1"
goto :run

REM Launch step. Checks the egress first, then starts opencode.
:run
echo.
if "%COLD%"=="1" echo --- fresh start ---------------------------------------------
if not "%COLD%"=="1" echo --- continue ------------------------------------------------
echo     "%CD%"
echo     egress: %EGRESS%

REM never launch through a dead proxy, and never "rotate" into a
REM direct connection: the gate asks instead of leaking silently.
if /i "%EGRESS%"=="NONE" goto :run_noproxy
if /i "%EGRESS%"=="WARP" if not defined WARP goto :run_noproxy

REM Prepare ACTIVE_PROXY for the chosen mode (process-only).
if /i "%EGRESS%"=="WARP" (
  set "ACTIVE_PROXY=%PROXY%"
  call :export_proxy
  if errorlevel 1 (
    echo   [!] WARP proxy is not answering - rotation has no effect.
    echo       Going direct would run opencode on your real IP.
    choice /c YN /n /m "   Continue without WARP? [Y/N]: "
    if errorlevel 2 goto :menu_loop
    goto :run_noproxy
  )
  if "%COLD%"=="1" call :ensure_new_ip
  goto :run_gate_ok
)
if /i "%EGRESS%"=="TOR" (
  call :tor_ready
  if errorlevel 1 (
    echo   [!] Tor/Privoxy not answering on :%TOR_HTTP_PORT%.
    echo       Start Tor + Privoxy ^(or an HTTP-^>SOCKS bridge^) first.
    choice /c YN /n /m "   Continue direct? [Y/N]: "
    if errorlevel 2 goto :menu_loop
    goto :run_noproxy
  )
  set "ACTIVE_PROXY=http://127.0.0.1:%TOR_HTTP_PORT%"
  call :export_proxy_active
  goto :run_gate_ok
)
if /i "%EGRESS%"=="PROXY" (
  call :pick_free_proxy
  if errorlevel 1 (
    echo   [!] no working free proxy found.
    choice /c YN /n /m "   Continue direct? [Y/N]: "
    if errorlevel 2 goto :menu_loop
    goto :run_noproxy
  )
  call :export_proxy_active
  goto :run_gate_ok
)
goto :run_noproxy

REM Proxy is working: continue with the gate checks.
:run_gate_ok
REM the background service is the process that talks to the API: it
REM must be born with the proxy env. if it was ever started direct
REM (for example by hand before WARP existed), restart it once.
REM The svc_proxied marker records that the restart already happened.
REM v1 has no shared service: skip the restart and the marker there.
if not defined CAP_SERVICE goto :run_marked
if not exist "%STATE_DIR%\svc_proxied" call "%OC_CMD%" service restart >nul 2>&1
if exist "%STATE_DIR%\svc_proxied" goto :run_marked
echo ok>"%STATE_DIR%\svc_proxied"
:run_marked
REM Common path for launching with or without egress.
:run_noproxy

REM Remember the log size before launch, so the watcher and the quota
REM check only read what this run writes.
set "SIZE_BEFORE=0"
for %%S in ("%LOGFILE%") do if not "%%~zS"=="" set "SIZE_BEFORE=%%~zS"
REM WHY records the reason the run ended (exit, quota, stop, watcher).
set "WHY="

REM FLAGS gets --continue when resuming the last chat.
set "FLAGS="
if defined RESUME set "FLAGS=--continue"
if defined RESUME echo   reopening the last session on the same chat...
set "RESUME="

REM Start the watcher, open the TUI, and stop the watcher when it closes.
call :watch_start
call :launch
call :watch_stop
REM Save the exit code of the TUI before anything else overwrites it.
set "EC=%errorlevel%"
REM the proxy belongs to the child process only: clear it so later
REM direct fetches never inherit a proxy that may already be dead.
set "HTTP_PROXY="
set "HTTPS_PROXY="
echo.

REM the watcher firing outranks the exit code: a killed TUI exits
REM nonzero, but the marker tells us WHY and where to go.
REM If the watcher left a hit marker, it killed the TUI because of a fatal error.
if not exist "%STATE_DIR%\watch_hit.txt" goto :run_no_hit
del /f /q "%STATE_DIR%\watch_hit.txt" >nul 2>&1
echo   [watch] a fatal error cut the chat - rotating and resuming it.
set "WHY=watcher"
goto :quota_rotate
REM No watcher hit. A nonzero exit code means opencode crashed.
:run_no_hit
if not "%EC%"=="0" goto :exit_rotate
REM NONE (or WARP mode without WARP) has no egress to retry: menu.
if /i "%EGRESS%"=="NONE" goto :closed
if /i "%EGRESS%"=="WARP" if not defined WARP goto :closed
REM A clean exit: check the log for a quota message before deciding.
call :check_quota
if defined QHIT set "WHY=quota"
if defined QHIT goto :quota_rotate

REM Normal close: offer a new egress and resume, or go to the menu.
:closed
echo OpenCode closed.
if /i "%EGRESS%"=="NONE" goto :menu_loop
if /i "%EGRESS%"=="WARP" if not defined WARP goto :menu_loop
echo.
echo   Ctrl+C is the stop button: one press hands you a new egress,
echo   resumes the chat where it stopped and reopens the session.
REM v2.11: default is N after 5 seconds. ESC inside OpenCode quits the app;
REM the launcher used to yank the session back with an auto-Y. Since the new
REM rotation paths are automatic, a clean quit now lands in the menu unless
REM Y is pressed within the 5s window.
set "RC_MSG=New IP and resume in 5s"
if /i "%EGRESS%"=="TOR" set "RC_MSG=Resume on Tor in 5s"
if /i "%EGRESS%"=="PROXY" set "RC_MSG=New proxy and resume in 5s"
choice /c yn /n /t 5 /d n /m "  %RC_MSG% [Y/N]: "
if errorlevel 2 goto :menu_loop
set "WHY=stop"
goto :quota_rotate



REM opencode exited with a nonzero code and the watcher did not catch it.
:exit_rotate
set "WHY=exit"

REM Common exit path for the egress retry. WHY is one of: exit, quota, stop, watcher.
REM Only the message for the current WHY value is shown.
:quota_rotate
if "%WHY%"=="exit" echo OpenCode exited with code %EC%.
if "%WHY%"=="quota" echo Free quota reached on this egress.
if "%WHY%"=="stop" echo Reopening on a new egress.
if "%WHY%"=="watcher" echo Fatal error caught by the watcher - switching egress.

REM Non-WARP modes: pick a new free proxy or just resume on TOR/NONE.
if /i "%EGRESS%"=="PROXY" (
  echo   [proxy] picking a fresh free proxy before resume...
  call :pick_free_proxy
  if errorlevel 1 (
    echo   [!] no working free proxy - back to menu.
    pause
    goto :menu_loop
  )
  set "RESUME=1"
  set "COLD=0"
  goto :resume_and_run
)
if /i "%EGRESS%"=="TOR" (
  call :tor_ready
  if errorlevel 1 (
    echo   [!] Tor/Privoxy not answering on :%TOR_HTTP_PORT% - back to menu.
    pause
    goto :menu_loop
  )
  echo   [tor] same circuit - resume only. Restart Tor for a new exit.
  set "RESUME=1"
  set "COLD=0"
  goto :resume_and_run
)
if /i "%EGRESS%"=="NONE" goto :menu_loop
if not defined WARP goto :menu_loop
echo Getting a new IP before the next attempt...
timeout /t 3 /nobreak >nul 2>&1

REM ============================================================
REM  3b) ROTATION + PROBE + RESUME
REM ============================================================
REM Automatic rotation: keep trying until a verified, unused IP answers the probe.
REM ROTATE_TRIES counts attempts; PROBE_TRIES counts IPs the probe rejected.
:auto_rotate
set /a ROTATE_TRIES=0
set /a PROBE_TRIES=0
REM rounds: full give-up-and-restart cycles left before the final pause
set /a RR_LEFT=%ROTATE_ROUNDS%
:rotate_loop
set /a ROTATE_TRIES+=1
if %ROTATE_TRIES% GTR %ROTATE_TRIES_MAX% goto :rotate_fail
REM Space the attempts out: a plain burst of "registration new" is what
REM Cloudflare throttles. From the second attempt on, wait first.
if %ROTATE_TRIES% GTR 1 (
    echo [%ROTATE_TRIES%] cooling down %ROTATE_COOLDOWN%s...
    timeout /t %ROTATE_COOLDOWN% /nobreak >nul 2>&1
)
REM Drop the current WARP connection and its registration.
echo [%ROTATE_TRIES%] dropping the old registration...
call :reg_drop
REM A new registration gets a new exit IP from Cloudflare.
echo [%ROTATE_TRIES%] new registration...
call :reg_new
if "%REGNEW%"=="0" echo [%ROTATE_TRIES%] the daemon refused a new registration - see wcli.log
echo [%ROTATE_TRIES%] reconnect...
call :warp_up
set "WARP_UP=1"
echo [%ROTATE_TRIES%] waiting %WARP_WAIT%s...
timeout /t %WARP_WAIT% /nobreak >nul 2>&1

REM an IP counts only when the trace came back through the proxy AND
REM says warp=on. anything else is a retry, never a silent launch.
call :getip2 IPN WFLAG
if not defined IPN goto :rotate_retry
if not "%WFLAG%"=="on" goto :rotate_retry
REM An IP equal to the previous one does not count: retry for a new one.
if /i "%IPN%"=="%IP%" goto :rotate_retry
echo [%ROTATE_TRIES%] new exit IP: %IPN% ^(WARP verified^)

REM probe: one cheap message on the throwaway session. burned IP ->
REM skip it and rotate again. this does not consume the infrastructure
REM budget, it consumes the probe budget (IP_FIND_MAX, 0 = no limit).
REM With PROBE=0 the probe is skipped and the IP is accepted directly.
if "%PROBE%"=="0" goto :rotate_good
echo [%ROTATE_TRIES%] probing if this IP can still talk...
call :probe_once
if not errorlevel 1 goto :rotate_good
REM The probe failed: this IP is burned. Undo the attempt count and count the probe.
set /a ROTATE_TRIES-=1
set /a PROBE_TRIES+=1
REM IP_FIND_MAX=0 means no limit on probes. Otherwise stop after the limit.
if "%IP_FIND_MAX%"=="0" goto :probe_endless
if %PROBE_TRIES% GTR %IP_FIND_MAX% goto :probe_exhausted
:probe_endless
echo [%PROBE_TRIES%] IP already burned, rotating - hunting with no cap ^(Ctrl+C stops^)...
goto :rotate_loop
:probe_exhausted
echo.
echo   [!] %PROBE_TRIES% IPs probed, every one of them already burned.
goto :rotate_fail

REM A verified IP that passed the probe: save it, mark the resume, and resume the chat.
:rotate_good
echo [%ROTATE_TRIES%] IP %IPN% works.
>"%STATE_DIR%\lastip.txt" echo %IPN%
set "IP=%IPN%"
set "RESUME=1"
set "COLD=0"
REM the background service holds sockets from the old tunnel, and its env
REM was captured before this rotation: restart it so the next TUI is born
REM on this exit IP. this runs on every rotation, not once per machine.
if defined CAP_SERVICE if defined OC_CMD call "%OC_CMD%" service restart >nul 2>&1
goto :resume_and_run

REM Not a usable IP yet (no answer, or WARP not on): try again.
:rotate_retry
echo [%ROTATE_TRIES%] no verified WARP IP yet, retrying...
goto :rotate_loop

REM Rotation gave up this cycle: cool down and run whole new rounds before
REM handing control back to the user. Cloudflare throttles come and go in
REM minutes, and the goal is "hit the limit -> new IP -> keep going" with
REM no hands on the keyboard.
:rotate_fail
if %RR_LEFT% LEQ 0 goto :rotate_pause
set /a RR_LEFT-=1
echo   [i] rotation failed - cooling down 60s, then %RR_LEFT% more round(s)...
timeout /t 60 /nobreak >nul 2>&1
set /a ROTATE_TRIES=0
goto :rotate_loop
:rotate_pause
REM never leave the probe session behind as the last session
call "%OC_CMD%" session delete %OC_PROBE_ID% >nul 2>&1
echo   [!] giving up after all rounds - warp-cli errors in %STATE_DIR%\wcli.log
pause
goto :menu_loop

REM - send the resume message so the chat continues, then open the
REM    TUI on the same session. a fresh fatal here loops back into
REM    the rotation.
REM Send RESUME_MSG to the existing session. Then reopen the TUI with --continue.
REM The call is bounded by RESUME_TIMEOUT: a resume that never answers is a
REM dead exit IP, not a reason to freeze the console.
:resume_and_run
if not defined RESUME goto :run
echo   sending "%RESUME_MSG%" so the chat picks up where it stopped...
REM The proxy must answer before the message is sent: a dead route here is
REM the exact case that used to block forever with both streams discarded.
if /i "%EGRESS%"=="WARP" (
  call :export_proxy
) else if /i "%EGRESS%"=="NONE" (
  set "HTTP_PROXY="
  set "HTTPS_PROXY="
) else (
  call :export_proxy_active
)
if errorlevel 1 (
    echo   [!] proxy dead - retrying on the current egress instead of resuming.
    call :resume_tail
    set "WHY=quota"
    goto :quota_rotate
)
REM RZB stores the log size before the resume message, to scan only its output.
REM It stays EMPTY when the log does not exist: an empty offset makes
REM scan_log read the whole file and match the quota error from hours ago.
set "RZB="
for %%S in ("%LOGFILE%") do if not "%%~zS"=="" set "RZB=%%~zS"
REM RESUME_AUTO=1 adds --auto, which approves tool permissions without asking.
REM On OpenCode v2, --standalone gives the resume a private server born with
REM THIS proxy env, instead of the long-lived background service that still
REM holds the old tunnel's sockets. v1 has no shared service and no such
REM flag: it prints the help screen and never sends the message. So the flag
REM is added only when :detect_caps found it in the CLI help.
set "RARGS=-c"
if defined CAP_STANDALONE set "RARGS=-c --standalone"
if "%RESUME_AUTO%"=="1" set "RARGS=%RARGS% --auto"
call :resume_run %RARGS%
set "REC=%errorlevel%"
set "HTTP_PROXY="
set "HTTPS_PROXY="
REM 124 is the watchdog code: the resume was killed for taking too long.
if "%REC%"=="124" (
    echo   [!] no answer in %RESUME_TIMEOUT%s - this exit IP is dead.
    call :resume_tail
    set "WHY=quota"
    goto :quota_rotate
)
REM Free-tier / quota text often lands on stderr even when exit code is noisy.
REM Catch it here so a burned IP never becomes the next TUI session.
set "RESLIMIT="
if exist "%STATE_DIR%\resume.err" findstr /i /c:"Free usage limit" /c:"usage limit reached" /c:"out of usage" /c:"insufficient credits" /c:"payment required" /c:"rate limit" "%STATE_DIR%\resume.err" >nul 2>&1 && set "RESLIMIT=1"
if exist "%STATE_DIR%\resume.out" if not defined RESLIMIT findstr /i /c:"Free usage limit" /c:"usage limit reached" /c:"out of usage" /c:"insufficient credits" /c:"payment required" /c:"rate limit" "%STATE_DIR%\resume.out" >nul 2>&1 && set "RESLIMIT=1"
if defined RESLIMIT goto :resume_fatal
REM No usable offset means no verdict from the log: trust the exit code only.
if not defined RZB goto :resume_noscan
call :scan_log %RZB%
if defined FHIT goto :resume_fatal
:resume_noscan
if not "%REC%"=="0" goto :resume_fatal
echo   chat resumed on the new IP.
goto :run
REM The resume hit a limit: go back to the rotation with WHY=quota.
:resume_fatal
echo   [!] the resume itself hit a limit - rotating again.
call :resume_tail
set "WHY=quota"
goto :quota_rotate

REM Option 3: rotate only, without opening opencode. Shows the result and waits.
:rotate
if /i "%EGRESS%"=="NONE" (
  echo.
  echo   Egress is NONE - nothing to rotate.
  pause
  goto :menu_loop
)
if /i "%EGRESS%"=="TOR" (
  echo.
  echo   TOR mode - restart Tor / Privoxy yourself for a new circuit.
  echo   Current bridge: http://127.0.0.1:%TOR_HTTP_PORT%
  pause
  goto :menu_loop
)
if /i "%EGRESS%"=="PROXY" (
  echo.
  echo   Picking a new free HTTP proxy...
  call :pick_free_proxy
  if errorlevel 1 (
    echo   [!] no working free proxy found.
  ) else (
    echo   New proxy: %ACTIVE_PROXY%
  )
  pause
  goto :menu_loop
)
REM WARP path
if not defined WARP (
  echo.
  echo WARP is not available - nothing to rotate.
  pause
  goto :menu_loop
)
echo.
echo Requesting a new WARP registration...
call :reg_drop
call :reg_new
if "%REGNEW%"=="0" echo   [!] the WARP daemon refused a new registration - see "%STATE_DIR%\wcli.log"
call :warp_up
set "WARP_UP=1"
echo waiting %WARP_WAIT%s...
timeout /t %WARP_WAIT% /nobreak >nul 2>&1
call :getip2 IPN WFLAG
if defined IPN if "%WFLAG%"=="on" goto :rotate_ok
REM Explain why the rotation failed: no answer or tunnel down.
echo   [!] no verified WARP IP.
if defined IPN if not "%WFLAG%"=="on" echo       the trace answered but warp=off - the tunnel is not up.
if not defined IPN echo       no trace answer - the proxy on port %PROXY_PORT% is down.
echo       warp-cli errors land in %STATE_DIR%\wcli.log
pause
goto :menu_loop
REM Rotation succeeded. Report whether the IP changed or stayed the same.
:rotate_ok
if /i not "%IPN%"=="%IP%" goto :rotate_new
echo   same IP as before: %IPN%
goto :rotate_done
:rotate_new
echo   New exit IP: %IPN% ^(WARP verified^)
>"%STATE_DIR%\lastip.txt" echo %IPN%
set "IP=%IPN%"
:rotate_done
echo.
pause
goto :menu_loop

REM ============================================================
REM  4) SUBROUTINES
REM ============================================================

REM - launch opencode with a tracked PID
REM The TUI runs through a small PowerShell host in this same console
REM so the launcher knows the exact PID (written to tui.pid). The
REM watcher kills exactly that process tree, and .cmd shims from npm
REM installs work the same as plain .exe builds.
REM Start opencode, save its PID to tui.pid, wait for it to exit, and return its exit code.
:launch
set "OC_EXE=%OC_CMD%"
set "OC_FLAGS=%FLAGS%"
set "OC_PIDF=%STATE_DIR%\tui.pid"
if exist "%OC_PIDF%" del /f /q "%OC_PIDF%" >nul 2>&1
REM Start-Process -ArgumentList treats one spaced string as ONE argument:
REM split the flags into tokens first (FLAGS is only --continue here).
REM PowerShell 5.1 REJECTS an empty -ArgumentList ("El argumento es NULL,
REM ..."): a fresh start has no --continue, so the plain-exe branch must
REM omit the parameter entirely when the list is empty.
REM .cmd and .bat files are started through cmd.exe, others are started directly.
"%PSX%" -NoProfile -Command "$exe=$env:OC_EXE; $a=@(); if($env:OC_FLAGS){ $a=([string]$env:OC_FLAGS) -split [char]32; $a=@($a | Where-Object { $_ }) }; $p=$null; if($exe -match '[.](cmd|bat)$'){ $p=Start-Process cmd.exe -ArgumentList (@('/c',$exe)+$a) -NoNewWindow -PassThru } elseif($a.Count){ $p=Start-Process $exe -ArgumentList @($a) -NoNewWindow -PassThru } else { $p=Start-Process $exe -NoNewWindow -PassThru }; if(-not $p){ exit 1 }; $null=$p.Handle; Set-Content -LiteralPath $env:OC_PIDF -Value $p.Id; [void]$p.WaitForExit(); if($p.ExitCode -ne $null){ exit $p.ExitCode }; exit 1"
set "EC=%errorlevel%"
goto :eof

REM - resume message under a hard time limit
REM usage: call :resume_run -c [--standalone] --auto
REM stdout goes to resume.out, stderr to resume.err, and the whole tree is
REM killed after RESUME_TIMEOUT seconds. Returns 124 on timeout, otherwise
REM the real exit code of opencode.
:resume_run
set "OC_EXE=%OC_CMD%"
set "OC_FL=%*"
if not defined RESUME_MSG set "RESUME_MSG=continue"
set "OC_MSG=%RESUME_MSG%"
set "OC_OUTF=%STATE_DIR%\resume.out"
set "OC_ERRF=%STATE_DIR%\resume.err"
set "OC_TO=%RESUME_TIMEOUT%"
if exist "%OC_OUTF%" del /f /q "%OC_OUTF%" >nul 2>&1
if exist "%OC_ERRF%" del /f /q "%OC_ERRF%" >nul 2>&1
"%PSX%" -NoProfile -Command "$exe=$env:OC_EXE; $a=@('run'); if($env:OC_FL){ $a+=@($env:OC_FL -split [char]32 | Where-Object { $_ }) }; if($env:OC_MSG){ $a+=([char]34 + $env:OC_MSG + [char]34) }; $a=@($a | Where-Object { $_ }); $o=$env:OC_OUTF; $e=$env:OC_ERRF; if($exe -match '[.](cmd|bat)$'){ $p=Start-Process cmd.exe -ArgumentList (@('/c',$exe)+$a) -NoNewWindow -PassThru -RedirectStandardOutput $o -RedirectStandardError $e } else { $p=Start-Process $exe -ArgumentList $a -NoNewWindow -PassThru -RedirectStandardOutput $o -RedirectStandardError $e }; if(-not $p){ exit 1 }; $null=$p.Handle; if(-not $p.WaitForExit([int]$env:OC_TO*1000)){ Start-Process taskkill.exe -ArgumentList @('/T','/F','/PID',$p.Id) -WindowStyle Hidden -Wait; exit 124 }; exit $p.ExitCode"
exit /b %errorlevel%

REM - print what the resume actually said
REM Only called on failure: the last lines of each stream, indented.
:resume_tail
if not exist "%STATE_DIR%\resume.err" if not exist "%STATE_DIR%\resume.out" goto :eof
echo   --- resume stderr ---
set "OC_TF=%STATE_DIR%\resume.err"
"%PSX%" -NoProfile -Command "if(Test-Path -LiteralPath $env:OC_TF){ Get-Content -LiteralPath $env:OC_TF -Tail 8 | ForEach-Object { '     ' + $_ } }"
echo   --- resume stdout ---
set "OC_TF=%STATE_DIR%\resume.out"
"%PSX%" -NoProfile -Command "if(Test-Path -LiteralPath $env:OC_TF){ Get-Content -LiteralPath $env:OC_TF -Tail 8 | ForEach-Object { '     ' + $_ } }"
goto :eof

REM - the watcher: tail the log, kill the TUI only when stuck
REM Polls every 2 seconds. On a fatal pattern it waits 4 seconds and
REM re-reads: if normal activity (INFO/DEBUG) followed the error, the
REM session recovered on its own and is left alone. Only a stuck chat
REM gets killed, and it kills exactly the tracked PID tree.
REM The watcher runs in the background (start /b). It reads the log
REM from SIZE_BEFORE onward, and if the TUI is still alive after a
REM confirmed fatal error, it writes watch_hit.txt and kills the tree.
REM Starts the background PowerShell watcher. Does nothing if WATCH is not 1,
REM the egress is NONE, or WARP mode has no WARP.
:watch_start
if not "%WATCH%"=="1" goto :eof
REM Clear leftovers from a previous run (also in modes that do not watch).
if exist "%STATE_DIR%\watch_hit.txt" del /f /q "%STATE_DIR%\watch_hit.txt" >nul 2>&1
if exist "%STATE_DIR%\watch.pid" del /f /q "%STATE_DIR%\watch.pid" >nul 2>&1
if /i "%EGRESS%"=="NONE" goto :eof
if /i "%EGRESS%"=="WARP" if not defined WARP goto :eof
REM Paths and settings passed to the watcher through the environment.
set "OC_WPIDF=%STATE_DIR%\watch.pid"
set "OC_TPIDF=%STATE_DIR%\tui.pid"
set "OC_HITF=%STATE_DIR%\watch_hit.txt"
set "OC_LOGF=%LOGFILE%"
set "OC_OFF=%SIZE_BEFORE%"
set "OC_FATPAT=%OC_PAT%"
REM Watcher body (PowerShell, one line). Its steps in order:
REM  1) save its own PID, 2) wait up to 60 s for the TUI PID,
REM  3) loop every 2 s: read new log bytes, look for a fatal pattern,
REM     re-read after 4 s, ignore it if INFO or DEBUG lines followed,
REM     otherwise write the hit marker and kill the TUI process tree.
start "" /b "%PSX%" -NoProfile -Command "$PID | Set-Content -LiteralPath $env:OC_WPIDF; $tpid=0; $off=0; if($env:OC_OFF){$off=[int64]$env:OC_OFF}; $dl=(Get-Date).AddSeconds(60); while($tpid -eq 0){ if((Get-Date) -gt $dl){exit 0}; if(Test-Path -LiteralPath $env:OC_TPIDF){ $c=(Get-Content -LiteralPath $env:OC_TPIDF -ErrorAction SilentlyContinue | Select-Object -First 1); if($c){$tpid=[int]$c} }; if($tpid -eq 0){Start-Sleep -Seconds 1} }; while($true){ Start-Sleep -Seconds 2; $p=Get-Process -Id $tpid -ErrorAction SilentlyContinue; if(-not $p){exit 0}; $t=''; try{ $fs=[IO.File]::Open($env:OC_LOGF,'Open','Read','ReadWrite'); if($fs.Length -lt $off){$off=0}; if($fs.Length -gt $off){ [void]$fs.Seek($off,'Begin'); $sr=New-Object IO.StreamReader($fs); $t=$sr.ReadToEnd(); $off=$fs.Length; $sr.Close() } else { $fs.Close() } }catch{ continue }; if(-not ($t -match $env:OC_FATPAT)){ continue }; Start-Sleep -Seconds 4; $t2=''; try{ $fs2=[IO.File]::Open($env:OC_LOGF,'Open','Read','ReadWrite'); if($fs2.Length -gt $off){ [void]$fs2.Seek($off,'Begin'); $sr2=New-Object IO.StreamReader($fs2); $t2=$sr2.ReadToEnd(); $off=$fs2.Length; $sr2.Close() } else { $fs2.Close() } }catch{}; $lines=($t+$t2) -split [char]10; $idx=-1; for($i=0;$i -lt $lines.Count;$i++){ if($lines[$i] -match $env:OC_FATPAT){$idx=$i} }; $rec=$false; if($idx -ge 0){ for($j=$idx+1;$j -lt $lines.Count;$j++){ if($lines[$j] -match 'level=(INFO|DEBUG)'){$rec=$true} } }; if($rec){ continue }; $p2=Get-Process -Id $tpid -ErrorAction SilentlyContinue; if($p2){ try{Set-Content -LiteralPath $env:OC_HITF -Value 'HIT'}catch{}; Start-Process taskkill.exe -ArgumentList @('/T','/F','/PID',$tpid) -WindowStyle Hidden -Wait; exit 1 } }"     
goto :eof

REM Stop the watcher and remove the PID files once the TUI has closed.
:watch_stop
if not exist "%STATE_DIR%\watch.pid" goto :ws_clean
for /f "usebackq delims=" %%p in ("%STATE_DIR%\watch.pid") do taskkill /f /pid %%p >nul 2>&1
del /f /q "%STATE_DIR%\watch.pid" >nul 2>&1
:ws_clean
if exist "%STATE_DIR%\tui.pid" del /f /q "%STATE_DIR%\tui.pid" >nul 2>&1
goto :eof

REM - scan the log from a byte offset for a fatal pattern
REM usage: call :scan_log <offset>; sets FHIT=1 when the delta matches.
REM Reads the log from the given byte offset and writes HIT or NOHIT to a temp file.
REM The result is read back into FHIT, and the temp file is removed.
:scan_log
set "FHIT="
set "SCANF=%TEMP%\oc_scan_%RANDOM%%RANDOM%.txt"
if exist "%SCANF%" del /f /q "%SCANF%" >nul 2>&1
set "OC_SCANF=%SCANF%"
set "OC_OFF=%~1"
"%PSX%" -NoProfile -Command "try{ $fs=[IO.File]::Open($env:OC_LOGF,'Open','Read','ReadWrite'); if($fs.Length -lt [int64]$env:OC_OFF){ Set-Content -LiteralPath $env:OC_SCANF -Value 'NOHIT' } else { [void]$fs.Seek([int64]$env:OC_OFF,'Begin'); $sr=New-Object IO.StreamReader($fs); $t=$sr.ReadToEnd(); $sr.Close(); if($t -match $env:OC_FATPAT){ Set-Content -LiteralPath $env:OC_SCANF -Value 'HIT' } else { Set-Content -LiteralPath $env:OC_SCANF -Value 'NOHIT' } } }catch{ try{ Set-Content -LiteralPath $env:OC_SCANF -Value 'NOHIT' }catch{} }" >nul 2>&1
if exist "%SCANF%" for /f "usebackq delims=" %%q in ("%SCANF%") do if /i "%%q"=="HIT" set "FHIT=1"
if exist "%SCANF%" del /f /q "%SCANF%" >nul 2>&1
goto :eof

REM - one probe message on the throwaway session
REM exit 0 = the IP can talk, exit 1 = burned or opencode failed.
REM Sends one short message through the proxy to the probe session.
REM Fails if opencode returns an error or the log shows a fatal line.
:probe_once
set "HTTP_PROXY=%PROXY%"
set "HTTPS_PROXY=%PROXY%"
set "PZB="
for %%S in ("%LOGFILE%") do if not "%%~zS"=="" set "PZB=%%~zS"
call "%OC_CMD%" run -m %PROBE_MODEL% -s %OC_PROBE_ID% --auto "reply with just: ok" >nul 2>&1
set "PEC=%errorlevel%"
set "HTTP_PROXY="
set "HTTPS_PROXY="
REM No usable offset = no verdict from the log. Never scan the whole file:
REM it still holds every old quota error and would fail every probe.
if not defined PZB goto :probe_noscan
call :scan_log %PZB%
if defined FHIT goto :probe_bad
:probe_noscan
if not "%PEC%"=="0" goto :probe_bad
REM pass: delete the probe session so --continue points at the chat
call "%OC_CMD%" session delete %OC_PROBE_ID% >nul 2>&1
exit /b 0
REM Probe failed: exit with code 1.
:probe_bad
exit /b 1

REM - locate warp-cli anywhere reasonable
REM Search in order: PATH, then the standard install folders.
REM Sets WARP to the first path found. Leaves it empty if none exists.
:find_warp
set "WARP="
set "WF=%TEMP%\oc_where_warp_%RANDOM%%RANDOM%.txt"
call :bwhere warp-cli.exe "%WF%"
if exist "%WF%" for /f "usebackq delims=" %%w in ("%WF%") do if not defined WARP set "WARP=%%w"
del /f /q "%WF%" >nul 2>&1
if defined WARP goto :eof
if exist "%ProgramFiles%\Cloudflare\Cloudflare WARP\warp-cli.exe" set "WARP=%ProgramFiles%\Cloudflare\Cloudflare WARP\warp-cli.exe"
if defined WARP goto :eof
REM 32-bit Program Files folder, when it exists.
set "PF86="
if defined ProgramFiles(x86) set "PF86=%ProgramFiles(x86)%"
if defined PF86 if exist "%PF86%\Cloudflare\Cloudflare WARP\warp-cli.exe" set "WARP=%PF86%\Cloudflare\Cloudflare WARP\warp-cli.exe"
if defined WARP goto :eof
if defined ProgramW6432 if exist "%ProgramW6432%\Cloudflare\Cloudflare WARP\warp-cli.exe" set "WARP=%ProgramW6432%\Cloudflare\Cloudflare WARP\warp-cli.exe"
if defined WARP goto :eof
if exist "%LOCALAPPDATA%\Cloudflare\Cloudflare WARP\warp-cli.exe" set "WARP=%LOCALAPPDATA%\Cloudflare\Cloudflare WARP\warp-cli.exe"
goto :eof

REM - one "where" lookup with a hard time limit
REM usage: call :bwhere "name1 name2" "outfile"
REM where.exe walks every PATH entry, and a dead mapped drive or an offline
REM UNC share makes it block for minutes before a single line is printed.
REM The lookup is killed after WHERE_TIMEOUT seconds and the output file
REM keeps whatever was found before the kill.
:bwhere
set "OC_WN=%~1"
set "OC_WF=%~2"
set "OC_WTO=%WHERE_TIMEOUT%"
if exist "%OC_WF%" del /f /q "%OC_WF%" >nul 2>&1
"%PSX%" -NoProfile -Command "$names=@($env:OC_WN -split ' ' | Where-Object { $_ }); $f=$env:OC_WF; $to=[int]$env:OC_WTO*1000; $p=Start-Process where.exe -ArgumentList $names -NoNewWindow -PassThru -RedirectStandardOutput $f -RedirectStandardError ($f+'.err'); if(-not $p){ exit 1 }; $null=$p.Handle; if(-not $p.WaitForExit($to)){ Start-Process taskkill.exe -ArgumentList @('/T','/F','/PID',$p.Id) -WindowStyle Hidden -Wait; exit 124 }; exit 0" >nul 2>&1
if exist "%OC_WF%.err" del /f /q "%OC_WF%.err" >nul 2>&1
goto :eof

REM - is this command on PATH? (bounded, unlike a bare where)
REM usage: call :have_exe curl.exe   -> HAVE=1 when found, HAVE=0 when not.
:have_exe
set "HAVE=0"
set "OC_WF=%TEMP%\oc_where_%RANDOM%%RANDOM%.txt"
call :bwhere "%~1" "%OC_WF%"
if exist "%OC_WF%" for %%F in ("%OC_WF%") do if not "%%~zF"=="0" set "HAVE=1"
del /f /q "%OC_WF%" >nul 2>&1
goto :eof

REM - one warp-cli call with a hard time limit
REM usage: call :wcli registration new
REM A hung call is killed after WARP_CALL_TIMEOUT seconds. Failures
REM are logged to %STATE_DIR%\wcli.log with a timestamp, the exit
REM code, the exact subcommand AND the daemon's own error text (last
REM non-empty stdout/stderr line). Without that text the log only
REM ever says "exit 1" and nobody can tell Registration missing from
REM a daemon that is not listening. Every value travels through the
REM environment, so no path can break the PowerShell command line.
:wcli
if not defined WARP goto :eof
set "WCMD=%*"
set "OC_EXE=%WARP%"
set "OC_ARGS=--accept-tos %WCMD%"
set "OC_LOG=%STATE_DIR%\wcli.log"
set "OC_TO=%WARP_CALL_TIMEOUT%"
set "OC_RRF=%STATE_DIR%\wcli_out.txt"
"%PSX%" -NoProfile -Command "$o=$env:OC_RRF; $p=Start-Process -FilePath $env:OC_EXE -ArgumentList $env:OC_ARGS -NoNewWindow -PassThru -RedirectStandardOutput $o -RedirectStandardError ($o+'.err'); if(-not $p){ exit 1 }; $null=$p.Handle; if(-not $p.WaitForExit([int]$env:OC_TO*1000)){ try{$p.Kill()}catch{}; try{Add-Content -LiteralPath $env:OC_LOG -Value (((Get-Date -Format o)+' TIMEOUT: '+$env:OC_ARGS))}catch{}; exit 1 }; if($p.ExitCode -eq $null){ exit 1 }; $rc=$p.ExitCode; if($rc -ne 0){ $why=''; foreach($f in @($o,($o+'.err'))){ if(Test-Path -LiteralPath $f){ $l=@(Get-Content -LiteralPath $f -ErrorAction SilentlyContinue | Where-Object { $_ }); if($l.Count){ $why=$l[$l.Count-1]; break } } }; $line=((Get-Date -Format o)+' exit '+$rc+': '+$env:OC_ARGS); if($why){ $line=$line+' :: '+$why }; try{Add-Content -LiteralPath $env:OC_LOG -Value $line}catch{}; exit $rc }; exit 0" >nul 2>&1
if exist "%OC_RRF%" del /f /q "%OC_RRF%" >nul 2>&1
if exist "%OC_RRF%.err" del /f /q "%OC_RRF%.err" >nul 2>&1
set "WCLIRC=%errorlevel%"
if not "%WCLIRC%"=="0" echo   [wcli] "%WCMD%" failed - see wcli.log
exit /b %WCLIRC%

REM - install WARP (UAC once)
REM Downloads the WARP MSI (curl if available, otherwise PowerShell),
REM checks its size, and installs it silently with an elevated msiexec.
REM The proxy variables are cleared during the download and restored afterwards.
:install_warp
set "MSI=%TEMP%\Cloudflare_WARP_x64.msi"
if exist "%MSI%" del /f /q "%MSI%" >nul 2>&1
set "KEEP_HP=%HTTP_PROXY%"
set "KEEP_SP=%HTTPS_PROXY%"
set "HTTP_PROXY="
set "HTTPS_PROXY="
set "OC_URL=%WARP_MSI_URL%"
set "OC_OUT=%MSI%"
echo   downloading the WARP installer, about 60 MB...
if "%HAVE_CURL%"=="1" goto :iw_curl
"%PSX%" -NoProfile -Command "try{[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -UseBasicParsing -Uri $env:OC_URL -OutFile $env:OC_OUT}catch{}" >nul 2>&1
goto :iw_check
REM Download with curl: fail on HTTP errors, 15 minute limit, no proxy.
:iw_curl
curl.exe -L -f -s --max-time 900 --noproxy "*" -o "%MSI%" "%WARP_MSI_URL%"
if not errorlevel 1 goto :iw_check
REM Direct egress failed: retry through the Windows proxy settings.
"%PSX%" -NoProfile -Command "try{[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -UseBasicParsing -Uri $env:OC_URL -OutFile $env:OC_OUT}catch{}" >nul 2>&1
:iw_check
set "HTTP_PROXY=%KEEP_HP%"
set "HTTPS_PROXY=%KEEP_SP%"
set "MSIOK=0"
if exist "%MSI%" for %%M in ("%MSI%") do if not "%%~zM"=="" if %%~zM GTR 5000000 set "MSIOK=1"
if "%MSIOK%"=="1" goto :iw_install
echo   [!] download failed.
echo       grab it by hand and run it: %WARP_MSI_URL%
if exist "%MSI%" del /f /q "%MSI%" >nul 2>&1
goto :eof
REM Install silently; the UAC prompt appears here. Remove the MSI afterwards.
:iw_install
echo   installing, accept the UAC prompt...
set "OC_MSI=%MSI%"
"%PSX%" -NoProfile -Command "try{Start-Process msiexec.exe -ArgumentList '/i',$env:OC_MSI,'/qn' -Verb RunAs -Wait}catch{}" >nul 2>&1
del /f /q "%MSI%" >nul 2>&1
goto :eof

REM - install opencode: official winget channel first, npm next, else the
REM standalone build from the GitHub release. Every hop is logged to
REM %STATE_DIR%\install.log so a VM that stalls shows where it stalled.
:install_opencode
if exist "%LOCALAPPDATA%\opencode\bin\opencode.exe" goto :eof
call :olog "install opencode start"
call :install_opencode_winget
call :find_opencode
if defined OC_CMD goto :ioc_done
call :olog "winget channel produced nothing"
call :have_exe npm
if "%HAVE%"=="0" (
    call :olog "npm not present, going standalone"
    goto :standalone
)
call :olog "npm channel: opencode-ai"
call :npm_install
call :find_opencode
if defined OC_CMD goto :ioc_done
call :olog "npm produced nothing, going standalone"
echo   [auto-install] npm did not deliver it, going standalone.
goto :standalone
:ioc_done
call :olog "opencode ready: %OC_CMD%"
goto :eof

REM Standalone build. Chooses x64 or arm64; 32-bit systems go through npm.
:standalone
set "OCARCH=x64"
if /i "%PROCESSOR_ARCHITECTURE%"=="ARM64" set "OCARCH=arm64"
if not "%REAL86%"=="1" goto :sa_ok
REM 32-bit: opencode publishes no x86 Windows binary. The JS package
REM runs fine on 32-bit node, so the npm route is the supported path.
echo   [i] 32-bit Windows: no standalone build - installing via npm.
call :install_node_x86
call :npm_install
call :find_opencode
if defined OC_CMD (
  echo   [ok] opencode ready on 32-bit via npm.
  goto :eof
)
echo   ERROR: opencode could not be installed on 32-bit Windows.
echo          Install 32-bit node.js by hand from nodejs.org, then run:
echo          npm i -g opencode-ai
pause
goto :quit

REM Download the standalone zip from the latest GitHub release.
:sa_ok
set "OC_URL=https://github.com/sst/opencode/releases/latest/download/opencode-windows-%OCARCH%.zip"
set "OCZIP=%TEMP%\opencode-windows.zip"
set "OCBIN=%LOCALAPPDATA%\opencode\bin"
echo   [auto-install] downloading the standalone build...
echo     %OC_URL%
if exist "%OCZIP%" del /f /q "%OCZIP%" >nul 2>&1
REM Clear the proxy during the download, as in install_warp.
set "KEEP_HP=%HTTP_PROXY%"
set "KEEP_SP=%HTTPS_PROXY%"
set "HTTP_PROXY="
set "HTTPS_PROXY="
set "OC_OUT=%OCZIP%"
if "%HAVE_CURL%"=="1" goto :sa_curl
"%PSX%" -NoProfile -Command "try{[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -UseBasicParsing -Uri $env:OC_URL -OutFile $env:OC_OUT}catch{}" >nul 2>&1
goto :sa_check
REM Download with curl, as in install_warp.
:sa_curl
curl.exe -L -f -s --max-time 900 --noproxy "*" -o "%OCZIP%" "%OC_URL%"
if not errorlevel 1 goto :sa_check
REM Direct egress failed: retry through the Windows proxy settings.
"%PSX%" -NoProfile -Command "try{[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -UseBasicParsing -Uri $env:OC_URL -OutFile $env:OC_OUT}catch{}" >nul 2>&1
:sa_check
set "HTTP_PROXY=%KEEP_HP%"
set "HTTPS_PROXY=%KEEP_SP%"
set "ZOK=0"
if exist "%OCZIP%" for %%Z in ("%OCZIP%") do if not "%%~zZ"=="" if %%~zZ GTR 5000000 set "ZOK=1"
if "%ZOK%"=="1" goto :sa_unzip
echo     [!] download failed.
if exist "%OCZIP%" del /f /q "%OCZIP%" >nul 2>&1
goto :eof
REM Unpack the zip into the bin folder, then add that folder to PATH for this session.
:sa_unzip
if not exist "%OCBIN%" mkdir "%OCBIN%" >nul 2>&1
echo   [auto-install] unpacking, about 200 MB on disk...
set "OC_ZIP=%OCZIP%"
set "OC_BIN=%OCBIN%"
"%PSX%" -NoProfile -Command "try{Expand-Archive -LiteralPath $env:OC_ZIP -DestinationPath $env:OC_BIN -Force}catch{}" >nul 2>&1
del /f /q "%OCZIP%" >nul 2>&1
set "PATH=%PATH%;%OCBIN%"
if exist "%OCBIN%\opencode.exe" echo   [ok] installed to %OCBIN%
goto :eof

REM - install opencode via the official winget channel (SST.opencode)
REM winget is the publisher-backed path: silent, one UAC prompt if the
REM package requires elevation, and a stable uninstall entry. The portable
REM shim lands in %LOCALAPPDATA%\Microsoft\WinGet\Links, which is added to
REM the session PATH here and to :find_opencode as a fixed candidate.
:install_opencode_winget
if exist "%LOCALAPPDATA%\opencode\bin\opencode.exe" goto :eof
if "%REAL86%"=="1" goto :iow_eof
call :have_exe winget
if "%HAVE%"=="0" (
    call :olog "winget not present - skipping official channel"
    goto :iow_eof
)
echo   [auto-install] official channel (winget): SST.opencode...
call :olog "winget channel: SST.opencode start"
set "IWC=0"
for /f "usebackq delims=" %%v in (`winget --version 2^>nul`) do set "IWC=%%v"
if not defined IWC (
    call :olog "winget exists but --version gave nothing - treating as broken"
    goto :iow_eof
)
if "%IWC%"=="1" (
    call :olog "winget --version blocked (timeout, code 124)"
    goto :iow_eof
)
"%PSX%" -NoProfile -Command "$p=Start-Process -FilePath winget.exe -ArgumentList @('install','--id','SST.opencode','--exact','--silent','--accept-package-agreements','--accept-source-agreements') -NoNewWindow -PassThru; if(-not $p){ exit 1 }; $null=$p.Handle; if(-not $p.WaitForExit(600000)){ Start-Process taskkill.exe -ArgumentList @('/T','/F','/PID',$p.Id) -WindowStyle Hidden -Wait; exit 124 }; exit $p.ExitCode" >nul 2>&1
set "IWR=%errorlevel%"
call :olog "winget install SST.opencode rc=%IWR%"
if "%IWR%"=="124" (
    echo   [!] winget install timed out - continuing to the next channel.
    goto :iow_eof
)
set "PATH=%PATH%;%LOCALAPPDATA%\Microsoft\WinGet\Links"
call :find_opencode
if defined OC_CMD goto :iow_eof
call :olog "winget reported success but opencode was not found - trying next channel"
:iow_eof
goto :eof

REM - the one-line install trail: every hop a channel attempt makes is
REM written here, so a VM that refuses to install gives the reason.
:olog
>>"%STATE_DIR%\install.log" echo [%DATE% %TIME%] %~1
goto :eof

REM Install opencode with npm globally, then add the npm folder to PATH for this session.
:npm_install
echo   [auto-install] installing with npm...
call npm install -g opencode-ai
set "PATH=%PATH%;%ProgramFiles%\nodejs;%APPDATA%\npm"
goto :eof

REM - 32-bit support: make sure npm exists, installing node if not
REM opencode publishes no x86 Windows binary, so npm with 32-bit node
REM is the only supported route there. Node installs through winget
REM when the Windows package manager is present, else a pinned 32-bit
REM MSI from the nodejs.org v22 LTS line; the MSI size is gated like
REM every other download and direct-egress failures retry through the
REM Windows proxy settings. /qn installs silently after the UAC prompt.
:install_node_x86
call :have_exe npm
if "%HAVE%"=="1" goto :eof
echo   [auto-install] node.js (32-bit) is missing - installing it...
call :have_exe winget.exe
if "%HAVE%"=="1" goto :node_winget
goto :node_msi
:node_winget
echo     via winget...
echo   [i] this can take a few minutes on its first run.
"%PSX%" -NoProfile -Command "$p=Start-Process -FilePath winget.exe -ArgumentList @('install','--id','OpenJS.NodeJS.LTS','--silent','--accept-package-agreements','--accept-source-agreements','--disable-interactivity') -NoNewWindow -PassThru; $null=$p.Handle; if(-not $p.WaitForExit(600000)){ try{$p.Kill()}catch{}; exit 1 }; exit $p.ExitCode" >nul 2>&1
if not errorlevel 1 goto :node_done
echo     winget failed - trying the MSI installer from nodejs.org...
:node_msi
REM Pinned: the pin moves with the LTS line; bump the version tag when
REM nodejs.org retires v22 (the MSI filename embeds the version).
set "NODE_MSI_URL=https://nodejs.org/dist/v22.13.1/node-v22.13.1-x86.msi"
set "NODE_MSI=%TEMP%\node_x86.msi"
if exist "%NODE_MSI%" del /f /q "%NODE_MSI%" >nul 2>&1
set "KEEP_HP=%HTTP_PROXY%"
set "KEEP_SP=%HTTPS_PROXY%"
set "HTTP_PROXY="
set "HTTPS_PROXY="
set "OC_URL=%NODE_MSI_URL%"
set "OC_OUT=%NODE_MSI%"
echo     downloading %NODE_MSI_URL% ...
if "%HAVE_CURL%"=="1" goto :nx_curl
"%PSX%" -NoProfile -Command "try{[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -UseBasicParsing -Uri $env:OC_URL -OutFile $env:OC_OUT -TimeoutSec 900}catch{}" >nul 2>&1
goto :nx_check
:nx_curl
curl.exe -L -f -s --max-time 900 --noproxy "*" -o "%NODE_MSI%" "%NODE_MSI_URL%"
if not errorlevel 1 goto :nx_check
echo     direct download failed - retrying through the Windows proxy settings...
"%PSX%" -NoProfile -Command "try{[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -UseBasicParsing -Uri $env:OC_URL -OutFile $env:OC_OUT -TimeoutSec 900}catch{}" >nul 2>&1
REM Restore the proxy variables and check the MSI size.
:nx_check
set "HTTP_PROXY=%KEEP_HP%"
set "HTTPS_PROXY=%KEEP_SP%"
set "NOK=0"
if exist "%NODE_MSI%" for %%M in ("%NODE_MSI%") do if not "%%~zM"=="" if %%~zM GTR 1000000 set "NOK=1"
if not "%NOK%"=="1" goto :node_done
echo     installing, accept the UAC prompt...
set "OC_MSI=%NODE_MSI%"
"%PSX%" -NoProfile -Command "try{Start-Process msiexec.exe -ArgumentList '/i',$env:OC_MSI,'/qn','/norestart' -Verb RunAs -Wait}catch{}" >nul 2>&1
del /f /q "%NODE_MSI%" >nul 2>&1
REM Either route: refresh the session PATH with the standard homes.
:node_done
set "PATH=%PATH%;%ProgramFiles%\nodejs;%APPDATA%\npm"
call :have_exe npm
if "%HAVE%"=="0" echo   [!] node.js is still not available - install the 32-bit build from nodejs.org.
exit /b 0

REM - what this opencode build actually supports
REM The CLI surface moved between v1 and v2: v2 has the shared background
REM service, "opencode service ..." and the global --standalone flag; v1 has
REM none of them and rejects the whole command (help screen) when it sees an
REM unknown flag. Probe the top-level help once, bounded, and set the two
REM capability flags the rest of the launcher keys off. Only ASCII markers
REM are searched, so the ANSI/code-page noise in the help output is harmless.
:detect_caps
set "CAP_STANDALONE="
set "CAP_SERVICE="
if not defined OC_CMD goto :eof
set "OC_VEXE=%OC_CMD%"
set "OC_VF=%TEMP%\oc_caps_%RANDOM%%RANDOM%.txt"
set "OC_VTO=8"
if exist "%OC_VF%" del /f /q "%OC_VF%" >nul 2>&1
"%PSX%" -NoProfile -Command "$exe=$env:OC_VEXE; $o=$env:OC_VF; $to=[int]$env:OC_VTO*1000; $line='call '+[char]34+$exe+[char]34+' --help 2>&1'; $p=Start-Process cmd.exe -ArgumentList @('/c',$line) -NoNewWindow -PassThru -RedirectStandardOutput $o; if($p){ $null=$p.Handle; if(-not $p.WaitForExit($to)){ Start-Process taskkill.exe -ArgumentList @('/T','/F','/PID',$p.Id) -WindowStyle Hidden -Wait } }" >nul 2>&1
if not exist "%OC_VF%" goto :dc_eof
findstr /i /c:"--standalone" "%OC_VF%" >nul 2>&1 && set "CAP_STANDALONE=1"
findstr /i /c:"opencode service" "%OC_VF%" >nul 2>&1 && set "CAP_SERVICE=1"
:dc_eof
if exist "%OC_VF%" del /f /q "%OC_VF%" >nul 2>&1
goto :eof

REM - locate opencode anywhere reasonable
REM Collects every candidate (PATH, npm shim, standalone builds), reads the
REM version of each and keeps the newest one. A machine can hold an old
REM standalone exe next to a current npm CLI: picking the first hit by name
REM starts v1 against a v2 database and dies with
REM "Database is not empty and has no session table".
REM Sets OC_CMD to the newest working binary and OC_VER to its version.
:find_opencode
set "OC_CMD="
set "OC_VER="
set "OCCAND=%TEMP%\oc_cand_%RANDOM%%RANDOM%.txt"
if exist "%OCCAND%" del /f /q "%OCCAND%" >nul 2>&1
REM One bounded lookup for all three names instead of three unbounded ones.
call :bwhere "opencode.exe opencode.cmd opencode.bat" "%OCCAND%"
call :add_cand "%APPDATA%\npm\opencode.cmd"
call :add_cand "%USERPROFILE%\.local\bin\opencode.exe"
call :add_cand "%LOCALAPPDATA%\Programs\opencode\opencode.exe"
call :add_cand "%LOCALAPPDATA%\opencode\bin\opencode.exe"
call :add_cand "%USERPROFILE%\.opencode\bin\opencode.exe"
call :add_cand "%LOCALAPPDATA%\Microsoft\WinGet\Links\opencode.exe"
if not exist "%OCCAND%" goto :eof
REM One candidate: take it without paying the cost of a version probe.
set "OCN=0"
for /f "usebackq delims=" %%c in ("%OCCAND%") do set /a OCN+=1
if %OCN% LEQ 1 for /f "usebackq delims=" %%c in ("%OCCAND%") do set "OC_CMD=%%c"
if defined OC_CMD goto :fo_ver
REM Several candidates: probe each one, the highest version wins.
for /f "usebackq delims=" %%c in ("%OCCAND%") do call :oc_probe "%%c"
:fo_ver
del /f /q "%OCCAND%" >nul 2>&1
if defined OC_CMD if not defined OC_VER (
    set "OC_CAN=%OC_CMD%"
    call :oc_version
    REM One candidate skips the probe loop, so its version is carried here;
    REM without this the menu loses the version line and the database check
    REM pays for a second probe.
    if defined CVER set "OC_VER=%CVER%"
)
goto :eof

REM - add one candidate path, at most once
REM A duplicate costs a second version probe (2 to 5 seconds) for a path
REM that was already found by "where": one path, one probe.
:add_cand
set "OCP=%~1"
if not exist "%OCP%" goto :eof
findstr /x /i /c:"%OCP%" "%OCCAND%" >nul 2>&1
if not errorlevel 1 goto :eof
>>"%OCCAND%" echo %OCP%
goto :eof

REM - probe one candidate, keep it when it is the newest
REM Sets CVER and, when it wins, OC_CMD and OC_VER.
:oc_probe
set "OC_CAN=%~1"
call :oc_version
if not defined CVER goto :eof
if not defined OC_CMD goto :op_take
set "VGT=0"
call :ver_gt "%CVER%" "%OC_VER%"
if "%VGT%"=="1" goto :op_take
goto :eof
:op_take
set "OC_CMD=%OC_CAN%"
set "OC_VER=%CVER%"
goto :eof

REM - version string of the binary in OC_CAN
REM "opencode v2.2.0" and a bare "2.2.0" both land in CVER unchanged.
REM The probe is bounded and writes to a file instead of a nested for /f:
REM a candidate that starts an interactive UI instead of printing a version
REM used to hang the launcher right after "Working in:" with no output.
:oc_version
call :trace oc_version
set "CVER="
set "OC_VF=%TEMP%\oc_ver_%RANDOM%%RANDOM%.txt"
set "OC_VEXE=%OC_CAN%"
set "OC_VTO=3"
if exist "%OC_VF%" del /f /q "%OC_VF%" >nul 2>&1
"%PSX%" -NoProfile -Command "$exe=$env:OC_VEXE; $o=$env:OC_VF; $to=[int]$env:OC_VTO*1000; $line='call ' + [char]34 + $exe + [char]34 + ' --version 2>nul <nul'; $p=Start-Process cmd.exe -ArgumentList @('/c',$line) -NoNewWindow -PassThru -RedirectStandardOutput $o; if(-not $p){ exit 1 }; $null=$p.Handle; if(-not $p.WaitForExit($to)){ Start-Process taskkill.exe -ArgumentList @('/T','/F','/PID',$p.Id) -WindowStyle Hidden -Wait; exit 124 }; exit 0" >nul 2>&1
if not exist "%OC_VF%" goto :eof
set "VLINE="
set /p VLINE=<"%OC_VF%"
del /f /q "%OC_VF%" >nul 2>&1
if not defined VLINE goto :eof
for /f "tokens=2" %%v in ("%VLINE%") do if not defined CVER set "CVER=%%v"
if not defined CVER for /f "tokens=1" %%v in ("%VLINE%") do if not defined CVER set "CVER=%%v"
goto :eof

REM - numeric version compare
REM usage: call :ver_gt <a> <b>; sets VGT=1 when a is newer than b.
:ver_gt
set "VGT=0"
set "VA=%~1"
set "VB=%~2"
if not defined VB goto :vg_new
set "VA=%VA:v=%"
set "VB=%VB:v=%"
set "A1=0"
set "A2=0"
set "B1=0"
set "B2=0"
for /f "tokens=1,2 delims=." %%a in ("%VA%") do (set "A1=%%a" & set "A2=%%b")
for /f "tokens=1,2 delims=." %%a in ("%VB%") do (set "B1=%%a" & set "B2=%%b")
call :vnum A1
call :vnum A2
call :vnum B1
call :vnum B2
if %A1% GTR %B1% goto :vg_new
if %A1% LSS %B1% goto :eof
if %A2% GTR %B2% goto :vg_new
goto :eof
:vg_new
set "VGT=1"
goto :eof

REM - force a token to a non-negative integer
REM usage: call :vnum NAME; anything that is not a number becomes 0.
:vnum
set "NV=%~1"
call set "NRAW=%%%NV%%%"
set "NN="
set /a NN=NRAW 2>nul
if not defined NN set "NN=0"
if %NN% LSS 0 set "NN=0"
set "%NV%=%NN%"
goto :eof

REM - offer a newer opencode-ai from npm, once per start, ask first
REM Installed version comes from "%OC_CMD% --version" (:oc_version), the
REM latest from "npm view opencode-ai version" over a direct connection: the
REM proxy env is cleared for the child so WARP is never in the path, and the
REM call is killed after 15 s. No npm, no network, a timeout or a bad answer
REM all leave the launcher running exactly as it was. The check is skipped
REM during an automatic resume and never installs without a Y.
:oc_update_check
if defined OCUPD goto :eof
set "OCUPD=1"
if not defined OC_CMD goto :eof
if defined RESUME goto :eof
call :trace oc_update
call :have_exe npm
if not "%HAVE%"=="1" goto :eof
REM Installed version, read from the binary itself.
set "OC_CAN=%OC_CMD%"
call :oc_version
if not defined CVER goto :eof
set "OCUPD_CUR=%CVER%"
REM Latest version from the registry, direct, hard-capped at 15 s.
set "OCUPD_LAT="
set "OC_VF=%TEMP%\oc_npmver_%RANDOM%%RANDOM%.txt"
set "OC_VTO=15"
if exist "%OC_VF%" del /f /q "%OC_VF%" >nul 2>&1
set "KEEP_HP=%HTTP_PROXY%"
set "KEEP_SP=%HTTPS_PROXY%"
set "HTTP_PROXY="
set "HTTPS_PROXY="
"%PSX%" -NoProfile -Command "$o=$env:OC_VF; $to=[int]$env:OC_VTO*1000; $line='call npm view opencode-ai version 2>nul'; $p=Start-Process cmd.exe -ArgumentList @('/c',$line) -NoNewWindow -PassThru -RedirectStandardOutput $o; if(-not $p){ exit 1 }; $null=$p.Handle; if(-not $p.WaitForExit($to)){ Start-Process taskkill.exe -ArgumentList @('/T','/F','/PID',$p.Id) -WindowStyle Hidden -Wait; exit 124 }; exit 0" >nul 2>&1
set "OCUPD_RC=%errorlevel%"
set "HTTP_PROXY=%KEEP_HP%"
set "HTTPS_PROXY=%KEEP_SP%"
if not "%OCUPD_RC%"=="0" goto :ouc_cleanup
if not exist "%OC_VF%" goto :ouc_cleanup
for /f "usebackq delims=" %%v in ("%OC_VF%") do set "OCUPD_LAT=%%v"
:ouc_cleanup
if exist "%OC_VF%" del /f /q "%OC_VF%" >nul 2>&1
if not defined OCUPD_LAT goto :eof
REM Compare with the same helper the binary picker uses.
set "VGT=0"
call :ver_gt "%OCUPD_LAT%" "%OCUPD_CUR%"
if not "%VGT%"=="1" goto :eof
echo.
echo   opencode update available: %OCUPD_CUR% -^> %OCUPD_LAT%
choice /c YN /n /m "   Update now with npm? [Y/N]: "
REM errorlevel 0 (no stdin) and 2 (N) both skip the install.
if not errorlevel 1 goto :eof
if errorlevel 2 goto :eof
echo   [update] npm i -g opencode-ai@latest
call npm i -g opencode-ai@latest
if errorlevel 1 echo   [!] npm update failed - keeping the current version.
REM Re-read what the binary reports now and refresh the capability flags.
set "OC_CAN=%OC_CMD%"
call :oc_version
if defined CVER set "OC_VER=%CVER%"
call :detect_caps
if defined OC_VER echo   [update] opencode now reports %OC_VER%
timeout /t 2 /nobreak >nul 2>&1
goto :eof

REM - v1 binary on a v2 database
REM A v1 CLI cannot open the v2 database and fails inside opencode with
REM "Database is not empty and has no session table". Say it here instead.
:db_guard
if not defined OC_CMD goto :eof
if not exist "%DATA_DIR%\opencode.db" goto :eof
if defined OC_VER goto :dg_check
set "OC_CAN=%OC_CMD%"
call :oc_version
:dg_check
if not defined OC_VER goto :eof
set "OCMAJ=0"
for /f "tokens=1 delims=." %%m in ("%OC_VER:v=%") do set "OCMAJ=%%m"
call :vnum OCMAJ
if %OCMAJ% GEQ 2 goto :eof
echo   [!] "%OC_CMD%" reports %OC_VER% but this machine has a v2 database.
echo       A v1 binary cannot open it: "Database is not empty and has no session table".
echo       Update it:  npm i -g opencode-ai@latest
goto :eof

REM - WARP into WireGuard + proxy mode on port 40000 and connected
REM Sets the tunnel protocol to MASQUE, switches to proxy mode on
REM PROXY_PORT, then connects. Waits 3 seconds for the connection.
:warp_up
call :trace warp_up
call :warp_register
call :wcli tunnel protocol set MASQUE
if errorlevel 1 call :wcli tunnel protocol set WireGuard
call :wcli mode proxy
call :wcli proxy port %PROXY_PORT%
call :wcli connect
timeout /t 3 /nobreak >nul 2>&1
goto :eof

REM - recreate a missing WARP registration
REM After a manual deletion every later call fails in a confusing way:
REM mode, port, connect and the MASQUE protocol all report errors because
REM there is no registration behind them. Create one before the tunnel.
:warp_register
if not defined WARP goto :eof
set "OC_WARPF=%TEMP%\oc_wstate_%RANDOM%%RANDOM%.txt"
set "OC_WARPEXE=%WARP%"
set "OC_WARPTO=%WARP_CALL_TIMEOUT%"
REM Bounded: a warp-cli that never answers (service stopped, tunnel wedged)
REM used to freeze the launcher here with nothing on screen.
"%PSX%" -NoProfile -Command "$f=$env:OC_WARPF; $to=[int]$env:OC_WARPTO*1000; $p=Start-Process $env:OC_WARPEXE -ArgumentList @('--accept-tos','status') -NoNewWindow -PassThru -RedirectStandardOutput $f -RedirectStandardError ($f+'.err'); if(-not $p){ exit 1 }; $null=$p.Handle; if(-not $p.WaitForExit($to)){ Start-Process taskkill.exe -ArgumentList @('/T','/F','/PID',$p.Id) -WindowStyle Hidden -Wait; exit 124 }; exit 0" >nul 2>&1
if not exist "%OC_WARPF%" goto :eof
if exist "%OC_WARPF%.err" type "%OC_WARPF%.err" >>"%OC_WARPF%" 2>nul
set "REGMISS="
findstr /i /c:"Registration Missing" "%OC_WARPF%" >nul 2>&1
if not errorlevel 1 set "REGMISS=1"
del /f /q "%OC_WARPF%" "%OC_WARPF%.err" >nul 2>&1
if not defined REGMISS goto :eof
echo   [!] WARP registration missing - creating a new one.
call :wcli registration new
timeout /t 2 /nobreak >nul 2>&1
goto :eof

REM - drop the current registration, then wait for the daemon to let go
REM registration delete returns before the daemon has finished tearing the
REM old one down, and the next "registration new" then fails with
REM "Old registration is still around", which used to loop forever.
REM Deletes once, then polls registration show until it stops answering.
:reg_drop
call :wcli disconnect
timeout /t 1 /nobreak >nul 2>&1
call :wcli registration delete
set /a RD_TRIES=0
:rd_wait
set /a RD_TRIES+=1
if %RD_TRIES% GTR 6 goto :rd_go
call :wcli registration show
if errorlevel 1 goto :rd_go
timeout /t 1 /nobreak >nul 2>&1
goto :rd_wait
:rd_go
goto :eof

REM - create a WARP registration, retrying once after a full drop
REM Sets REGNEW=1 when the daemon accepted a registration.
:reg_new
set "REGNEW=0"
call :wcli registration new
if not errorlevel 1 goto :rn_ok
REM The daemon may still hold the previous registration: drop it and retry.
call :wcli registration delete
timeout /t 2 /nobreak >nul 2>&1
call :wcli registration new
if errorlevel 1 goto :rn_done
:rn_ok
set "REGNEW=1"
:rn_done
goto :eof

REM - exit IP + warp flag
REM When WARP is on, an IP is reported only if the trace came back
REM through the proxy AND says warp=on. a dead tunnel reports nothing,
REM never the real IP dressed up as a fresh one.
REM Returns the exit IP in the variable named by argument 1 and the
REM warp flag in the variable named by argument 2.
REM Tries the HTTP proxy first, then SOCKS5, when WARP is on.
REM Without WARP it reads the IP directly.
:getip2
call :trace getip2
set "%~1="
set "%~2="
set "GIP="
set "GFLAG="
if not defined WARP goto :getip2_direct
set "TFILE=%TEMP%\oc_trace_%RANDOM%.txt"
set "OC_TURL=%TRACE_URL%"
set "OC_TFILE=%TFILE%"
set "OC_TPROXY=%PROXY%"
if "%HAVE_CURL%"=="1" goto :gip_curl_http
REM PowerShell fallback: read the trace through the proxy and write it to a file.
"%PSX%" -NoProfile -Command "try{[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; (Invoke-RestMethod -Uri $env:OC_TURL -Proxy $env:OC_TPROXY -TimeoutSec 8) -replace [char]13,[char]10 | Out-File -LiteralPath $env:OC_TFILE -Encoding ascii}catch{}" >nul 2>&1
goto :gip_parse
REM curl through the HTTP proxy. If the file is empty, try the SOCKS5 proxy.
:gip_curl_http
curl.exe -4 -s -f --max-time 8 -x "%PROXY%" -o "%TFILE%" "%TRACE_URL%" >nul 2>&1
if exist "%TFILE%" for %%T in ("%TFILE%") do if %%~zT GTR 0 goto :gip_parse
curl.exe -4 -s -f --max-time 8 -x "%SOCKS_PROXY%" -o "%TFILE%" "%TRACE_URL%" >nul 2>&1
goto :gip_parse

REM Without WARP: read the IP directly, with proxies ignored.
:getip2_direct
set "TFILE=%TEMP%\oc_trace_%RANDOM%.txt"
set "OC_TURL=%TRACE_URL%"
set "OC_TFILE=%TFILE%"
if "%HAVE_CURL%"=="1" goto :gid_curl
"%PSX%" -NoProfile -Command "try{[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; (Invoke-RestMethod -Uri $env:OC_TURL -TimeoutSec 10) -replace [char]13,[char]10 | Out-File -LiteralPath $env:OC_TFILE -Encoding ascii}catch{}" >nul 2>&1
goto :gip_parse
REM curl without any proxy.
:gid_curl
curl.exe -4 -s -f --max-time 10 --noproxy "*" -o "%TFILE%" "%TRACE_URL%" >nul 2>&1

REM Read the ip= and warp= lines from the trace file, then delete it.
REM With WARP on, a result that is not warp=on is discarded.
:gip_parse
if not exist "%TFILE%" goto :gip_done
for /f "tokens=2 delims==" %%i in ('findstr /b "ip=" "%TFILE%"') do set "GIP=%%i"
for /f "tokens=2 delims==" %%w in ('findstr /b "warp=" "%TFILE%"') do set "GFLAG=%%w"
del /f /q "%TFILE%" >nul 2>&1
:gip_done
if not defined WARP goto :gip_store
if not "%GFLAG%"=="on" set "GIP="
REM Return the values through the caller variable names.
:gip_store
if defined GIP set "%~1=%GIP%"
if defined GFLAG set "%~2=%GFLAG%"
goto :eof

REM - make sure this launch does not reuse the last egress IP
REM Compares the current IP with lastip.txt. If they match, it asks
REM WARP for a new registration, up to ROTATE_TRIES_MAX times.
REM After the limit, it keeps the current IP and continues.
:ensure_new_ip
set "LASTIP="
if exist "%STATE_DIR%\lastip.txt" set /p LASTIP=<"%STATE_DIR%\lastip.txt"
call :getip2 CUR CFLAG
if defined CUR if /i "%CFLAG%"=="on" goto :ens_have
echo   WARP proxy is not answering - cannot verify the exit IP.
goto :eof
REM Current IP is verified: compare it with the last one.
:ens_have
if not defined LASTIP goto :remember_ip
if /i not "%CUR%"=="%LASTIP%" goto :remember_ip
echo   same IP as the last run, requesting a new registration...
set /a EN_TRIES=0

REM Loop: new registration until the IP differs or the limit is reached.
:ens_loop
set /a EN_TRIES+=1
if %EN_TRIES% GTR %ROTATE_TRIES_MAX% goto :ens_giveup
echo   [%EN_TRIES%] dropping the old registration...
call :reg_drop
echo   [%EN_TRIES%] new registration...
call :reg_new
if "%REGNEW%"=="0" echo   [%EN_TRIES%] the daemon refused a new registration - see wcli.log
echo   [%EN_TRIES%] reconnecting WARP proxy...
call :warp_up
set "WARP_UP=1"
echo   [%EN_TRIES%] waiting %WARP_WAIT%s...
timeout /t %WARP_WAIT% /nobreak >nul 2>&1
call :getip2 CUR CFLAG
if not defined CUR goto :ens_loop
if not "%CFLAG%"=="on" goto :ens_loop
if /i "%CUR%"=="%LASTIP%" goto :ens_loop

REM Save the IP as the last one used and show it.
:remember_ip
if defined CUR if /i "%CFLAG%"=="on" >"%STATE_DIR%\lastip.txt" echo %CUR%
set "IP=%CUR%"
echo   exit IP: %CUR%
goto :eof
REM Limit reached without a new IP: continue with the current one.
:ens_giveup
echo   no new IP after %ROTATE_TRIES_MAX% tries, launching on the current one.
goto :remember_ip

REM - did this run write a fatal line to the log?
REM Sets QHIT=1 when the log part written during this run has a fatal line.
REM If the log does not exist, warns once and leaves auto-detection off.
:check_quota
set "QHIT="
if exist "%LOGFILE%" goto :cq_run
if defined QWARNED goto :eof
set "QWARNED=1"
echo   [note] opencode log not found: "%LOGFILE%"
echo          auto-detect stays off until the log appears.
goto :eof
REM Scan the log from the size recorded before launch.
:cq_run
call :scan_log %SIZE_BEFORE%
if defined FHIT set "QHIT=1"
goto :eof

REM - close every opencode process so the chat db unlocks
REM Ask opencode to stop its service, then kill any remaining processes.
REM The short wait lets the database files unlock before they are moved.
:stop_opencode
if defined CAP_SERVICE if defined OC_CMD call "%OC_CMD%" service stop >nul 2>&1
taskkill /f /im "OpenCode.exe" >nul 2>&1
taskkill /f /im "opencode.exe" >nul 2>&1
taskkill /f /im "opencode-cli.exe" >nul 2>&1
timeout /t 2 /nobreak >nul 2>&1
goto :eof

REM - the desktop can be redirected to OneDrive or another drive
REM Asks PowerShell for the real Desktop folder. If that fails, falls back
REM to OneDrive\Desktop, then Desktop, then the user profile folder.
:find_desktop
set "DESKTOP="
set "OC_OUT=%TEMP%\oc_dsk_%RANDOM%.txt"
if exist "%OC_OUT%" del /f /q "%OC_OUT%" >nul 2>&1
set "OC_DSK=%OC_OUT%"
"%PSX%" -NoProfile -Command "try{[IO.File]::WriteAllLines($env:OC_DSK, [Environment]::GetFolderPath('Desktop'))}catch{}" >nul 2>&1
if exist "%OC_OUT%" for /f "usebackq delims=" %%D in ("%OC_OUT%") do set "DESKTOP=%%D"
if exist "%OC_OUT%" del /f /q "%OC_OUT%" >nul 2>&1
if defined DESKTOP if not exist "%DESKTOP%\" set "DESKTOP="
if not defined DESKTOP if exist "%USERPROFILE%\OneDrive\Desktop" set "DESKTOP=%USERPROFILE%\OneDrive\Desktop"
if not defined DESKTOP if exist "%USERPROFILE%\Desktop" set "DESKTOP=%USERPROFILE%\Desktop"
if not defined DESKTOP set "DESKTOP=%USERPROFILE%"
goto :eof

REM - move the chats out of the way, timestamped, never overwritten
REM Creates a timestamped folder on the Desktop and moves the chat database
REM and storage folder into it. The stamp comes from PowerShell, with a random
REM fallback. MOVED stays 0 when nothing was moved, and the empty folder is removed.
:deep_archive
if not defined DESKTOP call :find_desktop
set "ARCHIVE_ROOT=%DESKTOP%\opencode_chats_archiviate"
set "STAMP="
set "OC_OUT=%TEMP%\oc_stm_%RANDOM%.txt"
if exist "%OC_OUT%" del /f /q "%OC_OUT%" >nul 2>&1
set "OC_STM=%OC_OUT%"
"%PSX%" -NoProfile -Command "try{[IO.File]::WriteAllLines($env:OC_STM, (Get-Date -Format yyyyMMdd-HHmmss))}catch{}" >nul 2>&1
if exist "%OC_OUT%" for /f "usebackq delims=" %%T in ("%OC_OUT%") do set "STAMP=%%T"
if exist "%OC_OUT%" del /f /q "%OC_OUT%" >nul 2>&1
if not defined STAMP set "STAMP=r%RANDOM%%RANDOM%"
set "TARGET=%ARCHIVE_ROOT%\%STAMP%"
echo   archiving chats to:
echo     "%TARGET%"
set "MOVED=0"
if exist "%DATA_DIR%\storage" call :archive_storage
for %%F in (opencode.db opencode.db-wal opencode.db-shm) do call :archive_file %%F
if not "%MOVED%"=="0" goto :arch_done
if exist "%TARGET%" rmdir "%TARGET%" >nul 2>&1
echo   nothing to archive.
goto :eof
REM Something was moved: report it.
:arch_done
echo   archived.
goto :eof

REM robocopy does not care about volumes and deletes the source
REM only after the copy is complete.
REM Move the storage folder with robocopy. Exit codes 8 and above mean failure.
:archive_storage
if not exist "%TARGET%" mkdir "%TARGET%" >nul 2>&1
robocopy "%DATA_DIR%\storage" "%TARGET%\storage" /e /move /r:1 /w:1 /nfl /ndl /njh /njs /np >nul
if errorlevel 8 (
  echo   [!] could not move the storage folder - it stays where it is.
  goto :eof
)
set "MOVED=1"
goto :eof

REM copy first, verify the size, delete only then.
REM Copy one database file, compare the sizes, and delete the original only if they match.
:archive_file
if not exist "%DATA_DIR%\%1" goto :eof
if not exist "%TARGET%" mkdir "%TARGET%" >nul 2>&1
copy /y "%DATA_DIR%\%1" "%TARGET%\%1" >nul
if errorlevel 1 (
  echo   [!] could not copy %1 - it stays where it is.
  goto :eof
)
set "SZS="
set "SZD="
for %%A in ("%DATA_DIR%\%1") do set "SZS=%%~zA"
for %%A in ("%TARGET%\%1") do set "SZD=%%~zA"
if "%SZS%"=="%SZD%" goto :af_del
echo   [!] size mismatch on %1 - the bad copy is deleted, the original stays.
del /f /q "%TARGET%\%1" >nul 2>&1
goto :eof
REM Sizes match: delete the original and count the file as moved.
:af_del
del /f /q "%DATA_DIR%\%1" >nul 2>&1
set "MOVED=1"
goto :eof

REM - cache and saved tokens
REM Delete the opencode cache folder and the saved login file (auth.json).
REM Chats in the database are not touched here.
:clear_tokens
set "CACHE_DIR=%USERPROFILE%\.cache\opencode"
if exist "%CACHE_DIR%" rmdir /s /q "%CACHE_DIR%" >nul 2>&1
if exist "%DATA_DIR%\auth.json" del /f /q "%DATA_DIR%\auth.json" >nul 2>&1
echo   cache and tokens cleared.
goto :eof

REM - hand the WARP proxy to the child process only
REM Returns errorlevel 1 when the proxy is dead; the caller decides.
REM Sets HTTP_PROXY, HTTPS_PROXY and no_proxy so that child processes use the proxy.
:export_proxy
if not defined WARP goto :eof
call :proxy_ok
if errorlevel 1 exit /b 1
set "HTTP_PROXY=%PROXY%"
set "HTTPS_PROXY=%PROXY%"
set "no_proxy=%NO_PROXY%"
exit /b 0

REM - hand ACTIVE_PROXY (TOR / free HTTP) to the child process only
:export_proxy_active
if not defined ACTIVE_PROXY exit /b 1
set "HTTP_PROXY=%ACTIVE_PROXY%"
set "HTTPS_PROXY=%ACTIVE_PROXY%"
set "no_proxy=%NO_PROXY%"
echo   [proxy] process-only: %ACTIVE_PROXY%
exit /b 0

REM - can the proxy actually carry an https request?
REM With curl: try the HTTP proxy, then SOCKS5. Without curl: only check
REM that the port accepts a TCP connection (the 1.5 second wait).
:proxy_ok
if not "%HAVE_CURL%"=="1" goto :proxy_ok_tcp
curl.exe -sS -o nul -f --max-time 6 --noproxy "" --proxy "%PROXY%" "%TRACE_URL%" >nul 2>&1
if not errorlevel 1 exit /b 0
curl.exe -sS -o nul -f --max-time 6 --noproxy "" --proxy "%SOCKS_PROXY%" "%TRACE_URL%" >nul 2>&1
if not errorlevel 1 exit /b 0
exit /b 1

REM TCP-only check, used when curl is missing.
:proxy_ok_tcp
"%PSX%" -NoProfile -Command "try{$c=New-Object Net.Sockets.TcpClient;$a=$c.BeginConnect('127.0.0.1',%PROXY_PORT%,$null,$null);if(-not $a.AsyncWaitHandle.WaitOne(1500)){exit 1};$c.EndConnect($a);$c.Close();exit 0}catch{exit 1}" >nul 2>&1
if errorlevel 1 exit /b 1
exit /b 0

REM - TOR readiness: Privoxy (or any HTTP->SOCKS bridge) must answer on TOR_HTTP_PORT
:tor_ready
"%PSX%" -NoProfile -Command "try{$c=New-Object Net.Sockets.TcpClient;$a=$c.BeginConnect('127.0.0.1',%TOR_HTTP_PORT%,$null,$null);if(-not $a.AsyncWaitHandle.WaitOne(1500)){exit 1};$c.EndConnect($a);$c.Close();exit 0}catch{exit 1}" >nul 2>&1
if errorlevel 1 exit /b 1
if "%HAVE_CURL%"=="1" (
  curl.exe -sS -o nul -f --max-time 8 --noproxy "" --proxy "http://127.0.0.1:%TOR_HTTP_PORT%" "%TRACE_URL%" >nul 2>&1
  if errorlevel 1 exit /b 1
)
exit /b 0

REM - download the free HTTP proxy list and pick the first that answers TRACE
:pick_free_proxy
set "ACTIVE_PROXY="
set "PLIST=%STATE_DIR%\proxy_list.txt"
if exist "%PLIST%" del /f /q "%PLIST%" >nul 2>&1
echo   [proxy] fetching free list...
set "KEEP_HP=%HTTP_PROXY%"
set "KEEP_SP=%HTTPS_PROXY%"
set "HTTP_PROXY="
set "HTTPS_PROXY="
if "%HAVE_CURL%"=="1" (
  curl.exe -L -f -s --max-time 20 --noproxy "*" -o "%PLIST%" "%PROXY_LIST_URL%" >nul 2>&1
) else (
  set "OC_URL=%PROXY_LIST_URL%"
  set "OC_OUT=%PLIST%"
  "%PSX%" -NoProfile -Command "try{[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -UseBasicParsing -Uri $env:OC_URL -OutFile $env:OC_OUT -TimeoutSec 20}catch{}" >nul 2>&1
)
set "HTTP_PROXY=%KEEP_HP%"
set "HTTPS_PROXY=%KEEP_SP%"
if not exist "%PLIST%" exit /b 1
set "PLSZ=0"
for %%F in ("%PLIST%") do set "PLSZ=%%~zF"
if %PLSZ% LSS 20 exit /b 1
set /a PTRY=0
for /f "usebackq delims=" %%p in ("%PLIST%") do (
  set "CAND=%%p"
  call :pfp_count
  if errorlevel 1 goto :pfp_fail
  call :try_one_proxy
  if not errorlevel 1 goto :pfp_ok
)
:pfp_fail
exit /b 1
:pfp_ok
exit /b 0

REM - count one list attempt and enforce PROXY_TRY_MAX
REM Called from the for body so the counter is not frozen by block expansion.
:pfp_count
set /a PTRY+=1
if %PTRY% GTR %PROXY_TRY_MAX% exit /b 1
exit /b 0

REM - test one candidate from the free list (HTTP only)
:try_one_proxy
REM CAND is either "http://ip:port" or "ip:port"
set "C=%CAND%"
echo %C% | findstr /i /b "http://" >nul 2>&1
if errorlevel 1 set "C=http://%C%"
echo %C% | findstr /i "socks" >nul 2>&1
if not errorlevel 1 exit /b 1
if not "%HAVE_CURL%"=="1" exit /b 1
curl.exe -sS -o nul -f --max-time %PROXY_PROBE_TIMEOUT% --noproxy "" --proxy "%C%" "%TRACE_URL%" >nul 2>&1
if errorlevel 1 exit /b 1
set "ACTIVE_PROXY=%C%"
echo   [proxy] live: %ACTIVE_PROXY%
exit /b 0

REM - one launcher at a time
REM The lock is a folder: creating it succeeds only for the first launcher.
REM A lock older than 2 hours is treated as stale and removed. A newer lock
REM triggers a question: continue anyway, or exit.
:lock_check
set "LOCKDIR=%STATE_DIR%\lock"
md "%LOCKDIR%" >nul 2>&1
if not errorlevel 1 goto :eof
set "OC_LOCK=%LOCKDIR%"
REM Remove the lock if it is older than 2 hours (exit 0 means stale and removed).
"%PSX%" -NoProfile -Command "try{$i=Get-Item -LiteralPath $env:OC_LOCK -Force;if(((Get-Date)-$i.LastWriteTime).TotalHours -gt 2){Remove-Item -LiteralPath $env:OC_LOCK -Recurse -Force;exit 0}else{exit 1}}catch{exit 0}" >nul 2>&1
if not errorlevel 1 goto :lock_retry
echo   [!] Another OpenCode launcher seems to be running.
choice /c YN /n /m "   Continue anyway? [Y/N]: "
if errorlevel 2 goto :quit_busy
rmdir /s /q "%LOCKDIR%" >nul 2>&1
md "%LOCKDIR%" >nul 2>&1
goto :eof
REM Stale lock removed: create a new one.
:lock_retry
md "%LOCKDIR%" >nul 2>&1
goto :eof
REM User chose not to continue: exit.
:quit_busy
echo   Exiting.
timeout /t 2 /nobreak >nul 2>&1
goto :quit

REM - startup trace: one line per stage, appended to startup.log -----
REM If the launcher freezes, the last line names the stage it froze in.
:trace
if not exist "%STATE_DIR%" goto :eof
>>"%STATE_DIR%\startup.log" echo %DATE% %TIME% %*
goto :eof

REM - self-update: newest launcher from the GitHub repo [upd] ---------
REM Once per start, before anything interactive. Steps:
REM   1) download the raw .bat (curl, else PowerShell), 30 s cap,
REM      direct (never through the WARP proxy), HTTP errors fail;
REM   2) size gate (real script is ~70 KB, an error page is not) plus
REM      a header-marker gate, so a truncated or wrong file never
REM      replaces the launcher;
REM   3) read "launcher  (vX.Y)" from the running file and the
REM      downloaded one; equal -> one quiet line, no download copy.
REM   4) different -> ask. On yes: backup to STATE_DIR, write a tiny
REM      helper that waits for THIS cmd to exit (a running .bat cannot
REM      be overwritten), copies the new file over it and restarts.
REM      The current script ends right after starting it: no batch
REM      line is ever read from a file that is being swapped.
REM The check is fully silent when the network is down or the repo is
REM unreachable: the launcher never blocks its start on GitHub.
:self_update
call :trace upd_start
set "SU_TMP=%STATE_DIR%\upd_remote.bat"
if exist "%SU_TMP%" del /f /q "%SU_TMP%" >nul 2>&1
call :have_exe curl.exe
REM v2.12: resolve the newest commit SHA on main through the GitHub API
REM first, then build a SHA-pinned raw URL. A raw/<SHA>/ URL can never
REM serve a stale CDN copy, unlike raw/main which once did (the bug that
REM kept v2.11 away from a launched update). API miss falls back to the
REM plain main URL.
set "SU_SHA="
set "SU_SHA_OUT=%STATE_DIR%\su_sha.tmp"
if exist "%SU_SHA_OUT%" del /f /q "%SU_SHA_OUT%" >nul 2>&1
"%PSX%" -NoProfile -Command "try{ [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; $r = Invoke-RestMethod -UseBasicParsing -Uri 'https://api.github.com/repos/jeko1107/opencode-infinite/commits/main' -TimeoutSec 15; if ($r.sha -match '^[0-9a-f]{40}$') { [IO.File]::WriteAllText($env:SU_SHA_OUT, $r.sha) } }catch{}" >nul 2>&1
if not exist "%SU_SHA_OUT%" goto :su_url_plain
for /f "usebackq delims=" %%s in ("%SU_SHA_OUT%") do set "SU_SHA=%%s"
del /f /q "%SU_SHA_OUT%" >nul 2>&1
if not defined SU_SHA goto :su_url_plain
call :trace upd_sha %SU_SHA%
set "SU_URL=https://raw.githubusercontent.com/jeko1107/opencode-infinite/%SU_SHA%/OpenCode%%20Infinite.bat"
call :trace upd_url %SU_URL%
goto :su_url_done
:su_url_plain
set "SU_URL=%UPDATE_URL%"
:su_url_done
if "%HAVE%"=="1" goto :su_curl
"%PSX%" -NoProfile -Command "try{[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -UseBasicParsing -Uri $env:SU_URL -OutFile $env:SU_TMP -TimeoutSec 30}catch{exit 1}" >nul 2>&1
if errorlevel 1 goto :su_eof
goto :su_size
:su_curl
curl.exe -L -f -s --max-time 30 --noproxy "*" -o "%SU_TMP%" "%UPDATE_URL%" >nul 2>&1
if not errorlevel 1 goto :su_size
REM Direct egress failed (firewalls and corporate proxies block raw
REM downloads): retry through the Windows proxy settings, which iwr
REM reads on its own.
"%PSX%" -NoProfile -Command "try{[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -UseBasicParsing -Uri $env:SU_URL -OutFile $env:SU_TMP -TimeoutSec 30}catch{exit 1}" >nul 2>&1
if errorlevel 1 goto :su_eof
:su_size
set "SU_OK="
if exist "%SU_TMP%" for %%s in ("%SU_TMP%") do if %%~zs GEQ 20000 set "SU_OK=1"
if not defined SU_OK goto :su_delete
REM Header gate: it must be the launcher, never an HTML error page.
findstr /b /c:"REM  OpenCode launcher" "%SU_TMP%" >nul 2>&1
if errorlevel 1 goto :su_delete
REM Version tokens, from the () in the header line.
set "SU_LV="
set "SU_RV="
for /f "tokens=2 delims=()" %%v in ('findstr /b /c:"REM  OpenCode launcher  (" "%~f0"') do set "SU_LV=%%v"
for /f "tokens=2 delims=()" %%v in ('findstr /b /c:"REM  OpenCode launcher  (" "%SU_TMP%"') do set "SU_RV=%%v"
if not defined SU_LV goto :su_delete
if not defined SU_RV goto :su_delete
call :trace upd_ver %SU_LV% / %SU_RV%
if /i "%SU_RV%"=="%SU_LV%" goto :su_same
echo   [upd] update found: local %SU_LV% - repo %SU_RV%
choice /c YN /n /m "   Replace this launcher with %SU_RV%? [Y/N]: "
if errorlevel 2 goto :su_delete
goto :su_apply
:su_same
echo   [upd] launcher matches the repo, %SU_LV%.
goto :su_delete
:su_apply
call :trace upd_apply
REM Backup first - it is never overwritten silently: timestamped name.
set "SU_BAK=%STATE_DIR%\OpenCode Infinite backup %SU_LV%.bat"
copy /y "%~f0" "%SU_BAK%" >nul 2>&1
if errorlevel 1 goto :su_fail
if not exist "%SU_BAK%" goto :su_fail
REM The updater waits for this cmd to release the .bat, swallows the
REM swap and restarts. Written with single caret escapes for the
REM redirects; %%~ stays %%~ so the helper sees its own arguments.
set "SU_HELP=%STATE_DIR%\oc_updater.cmd"
>"%SU_HELP%" echo @echo off
>>"%SU_HELP%" echo setlocal EnableExtensions
>>"%SU_HELP%" echo title OpenCode update
>>"%SU_HELP%" echo :u_retry
>>"%SU_HELP%" echo del /f /q "%%~2" ^>nul 2^>^&1
>>"%SU_HELP%" echo if not exist "%%~2" goto u_put
>>"%SU_HELP%" echo timeout /t 1 /nobreak ^>nul 2^>^&1
>>"%SU_HELP%" echo goto u_retry
>>"%SU_HELP%" echo :u_put
>>"%SU_HELP%" echo copy /y "%%~1" "%%~2" ^>nul 2^>^&1
>>"%SU_HELP%" echo if errorlevel 1 goto u_fail
>>"%SU_HELP%" echo start "" "%%~2"
>>"%SU_HELP%" echo del /f /q "%%~1" ^>nul 2^>^&1
>>"%SU_HELP%" echo del /f /q "%%~f0" ^>nul 2^>^&1
>>"%SU_HELP%" echo exit /b 0
>>"%SU_HELP%" echo :u_fail
>>"%SU_HELP%" echo echo   [upd] The replacement could not finish during the restart.
>>"%SU_HELP%" echo echo   The new copy stays in: %%~1
>>"%SU_HELP%" echo echo   Replace by hand: %%~2
>>"%SU_HELP%" echo pause
>>"%SU_HELP%" echo exit /b 1
if not exist "%SU_HELP%" goto :su_fail
REM The restarted launcher would otherwise meet a fresh lock dir and be
REM treated as a second instance. Same cleanup :quit does.
if exist "%STATE_DIR%\lock\" rmdir /s /q "%STATE_DIR%\lock" >nul 2>&1
echo   [upd] swapping in %SU_RV% - this window closes now.
call :trace upd_launch
start "" "%SU_HELP%" "%SU_TMP%" "%~f0"
REM Exit now: nothing here is read after the file is replaced.
timeout /t 2 /nobreak >nul 2>&1
exit
:su_fail
echo   [upd] the swap could not be prepared - keeping %SU_LV%.
echo         The downloaded copy is in "%SU_TMP%".
pause
goto :eof
:su_delete
del /f /q "%SU_TMP%" >nul 2>&1
:su_eof
goto :eof

REM - keep the settings numeric (0 allowed only for numcfg0)
REM Accepts only numbers of at least 1. Anything else falls back to the default.
REM A default is set first when the variable is empty.
:numcfg
if not defined %1 set "%1=%~2"
call set "NCV=%%%1%%"
set "NCN="
set /a NCN=NCV 2>nul
if not defined NCN set "NCN=%~2"
if %NCN% LSS 1 set "NCN=%~2"
set "%1=%NCN%"
goto :eof
REM Same as numcfg, but accepts 0 as a valid value.
:numcfg0
if not defined %1 set "%1=%~2"
call set "NCV=%%%1%%"
set "NCN="
set /a NCN=NCV 2>nul
if not defined NCN set "NCN=%~2"
if %NCN% LSS 0 set "NCN=%~2"
set "%1=%NCN%"
goto :eof

REM Common exit: restore the folder with popd, remove the lock, and end the local scope.
:quit
if defined POPPED popd
if exist "%STATE_DIR%\lock\" rmdir /s /q "%STATE_DIR%\lock" >nul 2>&1
endlocal

REM ============================================================
REM  Embedded folder picker (PowerShell). :run_picker reads this
REM  file from the marker line down and runs the block with
REM  PowerShell; the batch body ends at exit /b and never reads
REM  these lines. OC_MODE=modern opens the Explorer-style
REM  IFileDialog picker; classic opens FolderBrowserDialog. Both
REM  print the chosen folder on stdout and print nothing on
REM  cancel, so no temp file and no helper script is ever made.
REM ============================================================
exit /b

#>>>OC_PICKER_PS
$ErrorActionPreference = 'Stop'
$start = $env:OC_START
if ($env:OC_MODE -eq 'classic') {
    Add-Type -AssemblyName System.Windows.Forms
    $d = New-Object System.Windows.Forms.FolderBrowserDialog
    $d.Description = 'Folder to open OpenCode in'
    $d.ShowNewFolderButton = $true
    if ($start -and (Test-Path -LiteralPath $start)) { $d.SelectedPath = $start }
    if ($d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        [Console]::Out.WriteLine($d.SelectedPath)
    }
    exit 0
}
Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.Runtime.InteropServices;

[ComImport, Guid("DC1C5A9C-E88A-4DDE-A5A1-60F82A20AEF7")]
public class FileOpenDialog { }

[ComImport, Guid("43826d1e-e718-42ee-bc55-a1e261c37bfe"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IShellItem
{
    void BindToHandler(IntPtr pbc, ref Guid bhid, ref Guid riid, out IntPtr ppv);
    void GetParent(out IShellItem ppsi);
    void GetDisplayName(uint sigdnName, out IntPtr ppszName);
    void GetAttributes(uint sfgaoMask, out uint psfgaoAttribs);
    void Compare(IShellItem psi, uint hint, out int piOrder);
}

[ComImport, Guid("42f85136-db7e-439c-85f1-e4075d135fc8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IFileDialog
{
    [PreserveSig] int Show(IntPtr hwndParent);
    void SetFileTypes(uint cFileTypes, IntPtr rgFilterSpec);
    void SetFileTypeIndex(uint iFileType);
    void GetFileTypeIndex(out uint piFileType);
    void Advise(IntPtr pfde, out uint pdwCookie);
    void Unadvise(uint dwCookie);
    void SetOptions(uint fos);
    void GetOptions(out uint pfos);
    void SetDefaultFolder(IShellItem psi);
    void SetFolder(IShellItem psi);
    void GetFolder(out IShellItem ppsi);
    void GetCurrentSelection(out IShellItem ppsi);
    void SetFileName([MarshalAs(UnmanagedType.LPWStr)] string pszName);
    void GetFileName(out IntPtr pszName);
    void SetTitle([MarshalAs(UnmanagedType.LPWStr)] string pszTitle);
    void SetOkButtonLabel([MarshalAs(UnmanagedType.LPWStr)] string pszText);
    void SetFileNameLabel([MarshalAs(UnmanagedType.LPWStr)] string pszLabel);
    void GetResult(out IShellItem ppsi);
    void AddPlace(IShellItem psi, int fdap);
    void SetDefaultExtension([MarshalAs(UnmanagedType.LPWStr)] string pszDefaultExtension);
    void Close(int hr);
    void SetClientGuid(ref Guid guid);
    void ClearClientData();
    void SetFilter(IntPtr pFilter);
}

public static class Shell
{
    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
    public static extern void SHCreateItemFromParsingName(
        [MarshalAs(UnmanagedType.LPWStr)] string pszPath,
        IntPtr pbc,
        [MarshalAs(UnmanagedType.LPStruct)] Guid riid,
        [MarshalAs(UnmanagedType.Interface)] out IShellItem ppv);

    public static string PickFolder(string title, string start)
    {
        IFileDialog dlg = (IFileDialog)new FileOpenDialog();
        uint opt;
        dlg.GetOptions(out opt);
        dlg.SetOptions(opt | 0x20 | 0x40);
        dlg.SetTitle(title);
        if (!string.IsNullOrEmpty(start) && Directory.Exists(start))
        {
            try
            {
                IShellItem folder;
                SHCreateItemFromParsingName(start, IntPtr.Zero, typeof(IShellItem).GUID, out folder);
                dlg.SetFolder(folder);
            }
            catch { }
        }
        int hr = dlg.Show(IntPtr.Zero);
        if (hr != 0) return null;
        IShellItem item;
        dlg.GetResult(out item);
        IntPtr ptr;
        item.GetDisplayName(0x80058000, out ptr);
        try { return Marshal.PtrToStringUni(ptr); }
        finally { Marshal.FreeCoTaskMem(ptr); }
    }
}
"@
$path = [Shell]::PickFolder('Folder to open OpenCode in', $start)
if ($path -and (Test-Path -LiteralPath $path)) {
    [Console]::Out.WriteLine($path)
}
