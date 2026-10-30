@echo off
setlocal EnableExtensions
title OpenCode
REM ============================================================
REM  OpenCode launcher  (v2.28)
REM  Multi-egress (WARP / TOR / free HTTP) + dependency bootstrap
REM  + auto-resume.
REM  v2.22 - v2.28: every fixed bug carries an inline "REM v2.2x:"
REM  note.
REM
REM  Usage:
REM    double-click                          -> folder menu
REM    drag a folder onto this file          -> opens in that folder
REM    "OpenCode Infinite.bat" "D:\work\project"
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
REM  - Once per start, checks opencode.ai for a newer opencode and offers
REM    to install it (v2.28): installed version from "%OC_CMD% --version",
REM    latest from the official release metadata over a direct connection
REM    (no WARP proxy), compared with :ver_gt. It asks [Y/N] first, updates
REM    through the channel the running command came from (npm @opencode/cli
REM    or the official standalone build, sha256-verified), never runs during
REM    an automatic resume, and stays silent when the network is unavailable.
REM
REM  - After the workspace is chosen, asks for the egress mode:
REM      [1] WARP   - Cloudflare WARP proxy mode (rotation supported)
REM      [2] TOR    - local Tor SOCKS through the launcher's own built-in
REM                   HTTP bridge on 127.0.0.1:8118 (process-only; no
REM                   Privoxy and nothing else to install)
REM      [3] PROXY  - free HTTP proxies from the ProxyScrape list
REM                   (process-only; dead ones are skipped)
REM      [4] NONE   - direct, no proxy
REM
REM  - TOR with nothing installed: [2] sets itself up. The portable
REM    Tor Expert Bundle (a tar.gz: no installer, no UAC, no service)
REM    is downloaded once into the launcher state folder, started
REM    hidden, and exposed as an HTTP proxy through a tiny built-in
REM    bridge process, so no Privoxy install is needed. A Tor already
REM    running (Tor Browser on 9150 or a user tor on 9050) is used as it
REM    is and never killed by this launcher. All of it is removed from
REM    memory again on exit, files stay portable.
REM
REM  - In TOR mode a burned circuit is renewed by restarting the Tor the
REM    launcher started, with a bounded attempt counter before the menu
REM    takes over. In PROXY mode a retry picks another free proxy. NONE
REM    returns to the menu.
REM
REM  - Rotates the WARP egress IP through the local proxy: drops the
REM    old registration, creates a new one, verifies the trace says
REM    warp=on (v2.22: or warp=plus, the WARP+ answer), and starts the
REM    tunnel in proxy mode. Every warp-cli
REM    call is time-bounded and logged to wcli.log, with the daemon's
REM    own error text on every failure, so a wedge is readable instead
REM    of a private salt of exit codes. A missing WARP registration is
REM    detected and recreated before any tunnel call, and the tunnel
REM    falls back to WireGuard when MASQUE is refused.
REM
REM  - Verifies the route, not just the tunnel: IP fetches ignore
REM    stale HTTP_PROXY/HTTPS_PROXY, and optionally each candidate IP
REM    gets one cheap probe message on a throwaway session so burned
REM    IPs are skipped. The probe runs standalone (its own server born
REM    with the NEW proxy env): a plain run would be answered by the
REM    shared background service, which still holds the old tunnel's
REM    sockets, and then every brand-new IP probes as burned. Only
REM    limit-shaped answers mark an IP burned; any other probe failure
REM    stops the hunt and is printed, because rotation cannot fix a
REM    broken probe. IP_FIND_MAX=0 keeps hunting until one works.
REM
REM  - TOR mode is fully self-contained. The details that are easy to get
REM    wrong: the spawn is verified live two seconds in, so a tor that
REM    refuses its config fails loudly with its own reason instead of
REM    leaving a dead pid behind; the torrc carries the Windows paths as
REM    forward slashes because tor treats a backslash inside double quotes
REM    as an escape sequence; the bridge serves every connection in its own
REM    PowerShell runspace (worker threads cannot run PowerShell functions),
REM    so parallel HTTP traffic is served correctly. Bugs there read as a
REM    hang at the TOR readiness prompt, which is why each piece fails
REM    loudly with a printed reason.
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
REM  timings, log watching, the proxy port, the Tor bridge port, the
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
REM How many probe failures that are NOT a limit error are tolerated
REM before the hunt stops and asks. Catches a retired PROBE_MODEL id or
REM an auth problem: a broken probe that would otherwise read every
REM fresh IP as burned and rotate forever.
set "PROBE_BROKEN_MAX=3"
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
REM v2.24: this is the launcher's OWN built-in HTTP->SOCKS bridge, not
REM Privoxy. Required because OpenCode/Bun does not speak SOCKS5 natively;
REM only HTTP_PROXY works.
set "TOR_HTTP_PORT=8118"
REM [2] TOR auto-setup (v2.18): when nothing answers on the TOR ports,
REM download the portable Tor Expert Bundle once, run it hidden, and
REM expose it through the built-in bridge on TOR_HTTP_PORT. 0 = never
REM download; the launcher then behaves like older versions.
set "TOR_AUTO_INSTALL=1"
REM Seconds to wait for Tor to finish bootstrapping. The first run is
REM slower; later runs usually need a fraction of this.
set "TOR_BOOTSTRAP_WAIT=120"
REM v2.28: The proxy list. A URL (http, https, ftp, file:///) or a local path,
REM in ANY format: plain text, CSV, JSON, NDJSON, XML or HTML; sorted or not;
REM "ip:port", "scheme://user:pass@host:port", or ip and port in separate
REM fields/columns. Every proxy found is used; SOCKS entries are skipped
REM (OpenCode cannot use them) and lines starting with # or ; are comments.
REM Local example: set "PROXY_LIST_URL=D:\lists\my proxies.json"
REM Percent signs in a URL must be doubled (%%) inside this file.
set "PROXY_LIST_URL=https://api.proxyscrape.com/v4/free-proxy-list/get?request=display_proxies&protocol=http&proxy_format=protocolipport&format=text"
REM Minimum bytes the downloaded list must have before the launcher
REM trusts it (a tiny error page is not a list). v2.21: configurable,
REM so a short custom list can pass the gate; 0 turns the gate off and
REM accepts any downloaded file.
set "PROXY_LIST_MIN_BYTES=20"
REM How many free proxies to try before giving up (per rotate).
set "PROXY_TRY_MAX=12"
REM Seconds a single free-proxy probe may take.
set "PROXY_PROBE_TIMEOUT=8"
REM NEW: how many burned proxies in a row before PROXY mode gives up and
REM offers Tor. Every proxy that hits the limit is remembered and skipped.
set "PROXY_ROT_MAX=10"
REM v2.22: a free proxy must also reach the host opencode's API talks to,
REM not only the Cloudflare trace, or the TUI dies on its first request.
REM v2.23: OFF by default. PROXY_API_CHECK_URL was never verified, and a
REM host that does not resolve rejects every proxy and kills PROXY mode.
REM Set it to 1 only after checking the URL by hand.
set "PROXY_API_CHECK=0"
set "PROXY_API_CHECK_URL=https://api.opencode.ai/"
REM v2.28: official release metadata (version, url, sha256 for every file).
REM GitHub "releases/latest", the npm package opencode-ai and winget SST.opencode
REM are all frozen on the old v1 line (1.19.5) - the current v2 is published here
REM and as the npm package @opencode/cli. 32-bit Windows has no v2 build.
set "OC_API_BASE=https://opencode.ai/update/api/latest"

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
REM TOR portable setup runtime state (v2.18). TOR_DIR keeps the portable
REM Tor bundle and is the stop-identity root: at exit (v2.20) only tor
REM processes whose image path lives inside TOR_DIR, plus bridge
REM processes carrying the OC_TORBRIDGE_PS marker, are ever stopped -
REM so a Tor or a bridge already running before the launcher is never
REM touched and never killed. OURTOR / OURBRIDGE mean "the launcher
REM started it this session".
set "TOR_DIR=%LOCALAPPDATA%\opencode-launcher\tor"
set "TOR_EXE="
set "OURTOR="
set "OURBRIDGE="

REM v2.22: remember the user's own proxy variables before anything touches
REM them. They may be set system-wide; every cleanup used to delete them.
set "OC_HP0=%HTTP_PROXY%"
set "OC_SP0=%HTTPS_PROXY%"
set "OC_NP0=%no_proxy%"

REM UTF-8 console: folder paths in any system language survive the
REM write/read round trip in lastfolder.txt
REM Note: chcp 65001 changes the code page of the whole console window
REM for as long as this launcher runs, not only for this script.
REM v2.22: the original code page is saved here and restored in :quit.
set "OC_OLDCP="
for /f "tokens=2 delims=:" %%c in ('chcp') do set "OC_OLDCP=%%c"
set "OC_OLDCP=%OC_OLDCP: =%"
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
REM v2.22: the watcher paths used to be defined only inside :watch_start, so
REM with WATCH=0 (and in NONE / WARP-without-WARP) :scan_log read an empty
REM OC_LOGF and always answered NOHIT. They are defined here, once, for the
REM whole session; :watch_start still uses the same two names.
set "OC_LOGF=%LOGFILE%"
set "OC_FATPAT=%OC_PAT%"

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
call :numcfg PROXY_ROT_MAX 10
call :numcfg PROXY_PROBE_TIMEOUT 8
REM 0 is also valid here: "no size gate on a custom list"
call :numcfg0 PROXY_LIST_MIN_BYTES 20
call :numcfg TOR_SOCKS_PORT 9050
call :numcfg TOR_HTTP_PORT 8118
REM this one may legitimately be 0 (hunt with no limit)
call :numcfg0 IP_FIND_MAX 0
call :numcfg PROBE_BROKEN_MAX 3
call :numcfg TOR_BOOTSTRAP_WAIT 120

REM Create the state folder if it is missing, then check the single-instance lock.
if not exist "%STATE_DIR%" mkdir "%STATE_DIR%" >nul 2>&1
REM Fresh trace for this run: the last line names the stage that froze.
if exist "%STATE_DIR%\startup.log" del /f /q "%STATE_DIR%\startup.log" >nul 2>&1
REM v2.20: bound wcli.log too (it only grows on warp-cli failures, but a
REM dying daemon can fail for weeks - keep the last 400 lines above 200 KB)
call :trim_log "%STATE_DIR%\wcli.log" 200000 400
call :lock_check
REM v2.22: :lock_check no longer jumps to :quit from inside a called
REM subroutine (that returned to this caller with an emptied scope). It
REM sets LOCK_BUSY and returns; the exit happens here, at top level.
if defined LOCK_BUSY goto :quit

REM Once per start: check the repo for a newer launcher. Silent when
REM nothing to do or offline; asks before ever replacing this file.
if "%UPDATE_CHECK%"=="1" call :self_update

REM ============================================================
REM  0) APP MODE: CLI (terminal TUI) or the desktop app
REM ============================================================
REM v2.26: new. APP_MODE=CLI keeps the whole flow as it was. APP_MODE=DESKTOP launches
REM the OpenCode desktop exe through the same egress, and restarts it after
REM every rotation (there is no CLI chat to resume). OC_APP overrides the exe.
:mode_menu
cls
call :find_desktop_app
echo ============================================================
echo   OpenCode - how do you want to run it?
echo ============================================================
echo.
echo   [1] CLI      - terminal TUI ^(chat resumes on every new IP^)
echo   [2] Desktop  - the OpenCode desktop app ^(restarted on every new IP^)
if defined OC_DESKTOP echo       "%OC_DESKTOP%"
if not defined OC_DESKTOP echo       ^(not found - [2] offers to install it^)
echo   [3] Exit
echo.
echo   One key, no Enter.
echo.
choice /c 123 /n /m "Pick: "
if errorlevel 100 goto :quit
if not errorlevel 1 goto :mode_menu
if errorlevel 3 goto :quit
if errorlevel 2 goto :mode_desktop
set "APP_MODE=CLI"
goto :mode_done
:mode_desktop
call :find_desktop_app
if defined OC_DESKTOP goto :mode_desktop_ok
echo.
echo   [!] OpenCode desktop not found.
choice /c YN /n /m "   Download and install it now? [Y/N]: "
if errorlevel 100 goto :quit
if errorlevel 2 goto :mode_menu
call :install_desktop
call :find_desktop_app
if defined OC_DESKTOP goto :mode_desktop_ok
echo   [!] still not found - set OC_APP to its OpenCode.exe.
pause
goto :mode_menu
:mode_desktop_ok
set "APP_MODE=DESKTOP"
echo.
echo   [app] DESKTOP "%OC_DESKTOP%"
call :desktop_update_check
:mode_done
REM The desktop app has its own project picker: no folder step for it.
if /i not "%APP_MODE%"=="DESKTOP" goto :mode_folder
set "OPFOLDER=%CD%"
goto :folder_ok
:mode_folder

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
echo   One key, no Enter.
echo.
REM v2.22: choice is the main path again. Every keypress used to start a
REM fresh PowerShell just to read one character; ESC is no longer read
REM here, [4] exits.
REM v2.23: the raw-key reader :readkey is gone - nothing called it any more
REM and every keypress used to cost a PowerShell start.
goto :folder_choice

:folder_choice
REM choice returns the key number through errorlevel: check highest first.
choice /c 1234 /n /m "Pick: "
REM v2.22: errorlevel 0 (Ctrl+C) redraws the menu instead of falling through
REM to option [1] and forcing the last folder.
REM v2.25: stdin closed answers 255 - leave instead of looping.
if errorlevel 100 goto :quit
if not errorlevel 1 goto :folder
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
echo   [2] TOR      - local Tor + built-in bridge on :%TOR_HTTP_PORT%
echo                  (auto-installs a portable Tor, nothing to set up)
echo   [3] PROXY    - free HTTP proxies (ProxyScrape list)
echo   [4] NONE     - direct, no proxy
echo.
echo   One key, no Enter.
echo.
choice /c 1234 /n /m "Pick egress: "
REM v2.25: stdin closed answers 255; do not silently pick NONE.
if errorlevel 100 goto :quit
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
  REM v2.22: circuit rotation counter, reset every time TOR is chosen.
  set "TOR_TRIES=0"
  REM v2.22: the menu still described a manual Privoxy setup; TOR installs
  REM and bridges itself now.
  echo   [egress] TOR - portable Tor + built-in bridge on :%TOR_HTTP_PORT%, auto-setup.
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
REM v2.22: :install_opencode can abort (32-bit with no route) - exit from
REM here, at top level, where :quit is safe to reach with goto.
if defined OC_ABORT goto :quit
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
REM v2.22: :lock_touch recreates the stamp entry, which is what moves the
REM folder timestamp (see :lock_check).
if exist "%STATE_DIR%\lock\" call :lock_touch
cls
echo ============================================================
echo   OpenCode
echo.
echo   Folder : "%CD%"
echo   Egress : %EGRESS%
echo   Mode   : %APP_MODE%
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
if /i not "%APP_MODE%"=="DESKTOP" echo   [4] Folder        - work in a different folder
if /i "%APP_MODE%"=="DESKTOP" echo   [4] Mode          - switch between CLI and Desktop
echo   [5] Deep reset    - kill opencode, move chats to the Desktop,
echo                       clear saved tokens, open a fresh session
echo   [6] Exit
REM NEW: option 7 is like [5] but leaves the chats where they are.
echo   [7] Token reset   - kill opencode, clear saved tokens, keep chats
echo                       where they are, open a fresh session
echo.
echo   One key, no Enter.
echo.
REM Read the menu choice. Highest number is checked first.
choice /c 1234567 /n /m "Pick: "
REM choice exits 0 on Ctrl+C: redraw the menu instead of guessing option 1.
REM v2.25: with stdin closed (piped input, EOF) choice answers 255, not 0, and
REM 255 satisfies every "if errorlevel N" below, so the old guard looped here
REM forever through the token-reset prompt. No console to ask: leave.
if errorlevel 100 goto :quit
if not errorlevel 1 goto :menu_loop
REM NEW: 7 is checked first (highest number first).
if errorlevel 7 goto :run_soft
if errorlevel 6 goto :quit
if errorlevel 5 goto :run_deep
if errorlevel 4 goto :menu_opt4
if errorlevel 3 goto :rotate
if errorlevel 2 goto :run_warm
goto :run_cold

REM Option 4: the desktop app has no folder step, so it switches mode instead.
:menu_opt4
if /i "%APP_MODE%"=="DESKTOP" goto :mode_menu
goto :folder

REM Option 1 (fresh start): COLD=1 asks for a new IP before launching.
:run_cold
set "COLD=1"
REM NEW: a fresh start forgets the burned proxies.
del /f /q "%STATE_DIR%\proxy_burned.txt" >nul 2>&1
set "PROXY_ROT=0"
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
REM v2.22: :stop_opencode kills every opencode.exe on the machine, not only
REM this session's. Say so before asking.
echo   It also kills EVERY opencode process on this computer,
echo   including windows opened by hand or by another launcher.
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

REM NEW: Option 7 (token reset). Same as option 5 but the chats are NOT moved.
REM Only the token cache is cleared and auth.json is copied to the Desktop
REM (verified) before it is removed.
:run_soft
echo.
echo --- token reset ----------------------------------------------
echo   This closes opencode, clears the saved tokens and opens a
echo   brand new session. Your chats are NOT moved.
echo   auth.json is copied to the Desktop first, then removed.
echo   It also kills EVERY opencode process on this computer,
echo   including windows opened by hand or by another launcher.
echo.
choice /c yn /n /m "  Do that now? [Y/N] "
if errorlevel 2 goto :menu_loop
call :stop_opencode
call :soft_target
call :clear_tokens
set "RESUME="
set "COLD=1"
goto :run

REM NEW: builds the backup folder for option 7 only. It sets TARGET so
REM :archive_auth works, and never creates the chats folder. TARGET is
REM always recomputed so a value left by an earlier deep reset is not reused.
:soft_target
if not defined DESKTOP call :find_desktop
set "STAMP="
set "OC_OUT=%TEMP%\oc_stm_%RANDOM%.txt"
if exist "%OC_OUT%" del /f /q "%OC_OUT%" >nul 2>&1
set "OC_STM=%OC_OUT%"
"%PSX%" -NoProfile -Command "try{[IO.File]::WriteAllLines($env:OC_STM, (Get-Date -Format yyyyMMdd-HHmmss))}catch{}" >nul 2>&1
if exist "%OC_OUT%" for /f "usebackq delims=" %%T in ("%OC_OUT%") do set "STAMP=%%T"
if exist "%OC_OUT%" del /f /q "%OC_OUT%" >nul 2>&1
if not defined STAMP set "STAMP=r%RANDOM%%RANDOM%"
set "TARGET=%DESKTOP%\opencode_auth_backup\%STAMP%"
goto :eof

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
REM v2.22: TOR and PROXY left the parenthesised block and became labelled
REM steps, so the PROXY branch can test COLD/ACTIVE_PROXY without the
REM parse-time expansion trap those blocks carry.
if /i "%EGRESS%"=="TOR" goto :run_tor
if /i "%EGRESS%"=="PROXY" goto :run_free
goto :run_noproxy

REM - TOR egress: gate first, then hand the bridge to the child
:run_tor
call :tor_gate
if errorlevel 1 goto :run_tor_fail
set "ACTIVE_PROXY=http://127.0.0.1:%TOR_HTTP_PORT%"
call :export_proxy_active
goto :run_gate_ok
:run_tor_fail
echo   [!] Tor did not get ready.
choice /c YN /n /m "   Continue direct? [Y/N]: "
if errorlevel 2 goto :menu_loop
goto :run_noproxy

REM - free proxy egress
REM v2.22: [2] Continue used to pick a brand-new free proxy on each :run.
REM With COLD=0 the proxy already in ACTIVE_PROXY is kept; a fresh start
REM or an empty slot picks a new one.
:run_free
if "%COLD%"=="0" if defined ACTIVE_PROXY goto :run_free_keep
:run_free_pick
call :pick_free_proxy
if errorlevel 1 goto :run_free_fail
call :export_proxy_active
goto :run_gate_ok
:run_free_keep
REM v2.22: a kept proxy is checked before it is reused - a dead one falls
REM back to picking a new candidate instead of launching through a corpse.
call :proxy_alive "%ACTIVE_PROXY%"
if errorlevel 1 goto :run_free_pick
call :export_proxy_active
goto :run_gate_ok
:run_free_fail
echo   [!] no working free proxy found.
choice /c YN /n /m "   Continue direct? [Y/N]: "
if errorlevel 2 goto :menu_loop
goto :run_noproxy

REM Proxy is working: continue with the gate checks.
:run_gate_ok
REM the background service is the process that talks to the API: it
REM must be born with the proxy env.
REM v2.22: the svc_proxied marker restarted it ONCE in the life of the
REM machine, so a service first started direct kept the real IP after
REM WARP/TOR/PROXY was chosen later. The restart now runs whenever the
REM egress URL in use differs from the one it was last restarted on,
REM which covers every mode and every proxy change.
REM v1 has no shared service: skip the restart there.
if not defined CAP_SERVICE goto :run_marked
if not defined ACTIVE_PROXY goto :run_marked
if /i "%ACTIVE_PROXY%"=="%SVC_PROXIED%" goto :run_marked
call "%OC_CMD%" service restart >nul 2>&1
set "SVC_PROXIED=%ACTIVE_PROXY%"
:run_marked
REM v2.22: delete the obsolete marker once; nothing reads it anymore.
if exist "%STATE_DIR%\svc_proxied" del /f /q "%STATE_DIR%\svc_proxied" >nul 2>&1
REM v2.23: WARP/TOR/PROXY used to fall straight through into the clearing
REM block below, which wiped the proxy that had just been exported and ran
REM opencode on the real IP. Proxied runs jump over that block now.
goto :run_launch

REM - direct path: NONE, WARP without WARP, or "Continue direct?"
:run_noproxy
REM v2.22: NONE (and the no-WARP fallback) must be direct for the child
REM too: a system-wide HTTP_PROXY used to leak into the "no proxy" mode.
set "HTTP_PROXY="
set "HTTPS_PROXY="
set "no_proxy="
set "ACTIVE_PROXY="
REM v2.23: a v2 service born under a proxy keeps the old tunnel's sockets.
REM Coming back to NONE restarts it once, then forgets the proxy it had.
if not defined SVC_PROXIED goto :run_launch
if defined CAP_SERVICE if defined OC_CMD call "%OC_CMD%" service restart >nul 2>&1
set "SVC_PROXIED="

REM Common launch path, proxied and direct runs alike (v2.23).
:run_launch

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
set "EC="
call :launch
REM v2.22: the TUI exit code is taken right after the launch. :launch stores
REM it in EC itself and the fallback read covers a build where it did not.
REM The old capture sat after :watch_stop, whose taskkill overwrote
REM errorlevel, so a crashed TUI was reported as a clean exit.
if not defined EC set "EC=%errorlevel%"
call :watch_stop
REM v2.22: restore the user's own proxy variables instead of deleting them.
call :restore_env
REM v2.22: the watcher can flag a dead proxy/tunnel while the TUI is open
REM (WARP/TOR/PROXY). It never kills the TUI; the note is shown here.
if not exist "%STATE_DIR%\proxy_warn.txt" goto :run_warn_done
echo.
echo   [!] the egress proxy stopped answering while OpenCode was open:
echo       %STATE_DIR%\proxy_warn.txt
del /f /q "%STATE_DIR%\proxy_warn.txt" >nul 2>&1
:run_warn_done
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
REM NEW: PROXY used to pick the SAME first live proxy every time and loop
REM forever. Now the proxy that just hit the limit is remembered (burned),
REM skipped by the next pick, and the attempts are bounded.
if /i "%EGRESS%"=="PROXY" goto :qr_proxy
REM v2.22: TOR used to resume on the SAME circuit forever: a burned exit
REM node hit the limit, the gate passed, and the resume met the same limit
REM again with no way out. The circuit is now renewed for real (restart of
REM the launcher-managed Tor) with a bounded attempt counter.
if /i not "%EGRESS%"=="TOR" goto :qr_after_tor
set /a TOR_TRIES+=1
if %TOR_TRIES% GTR %ROTATE_TRIES_MAX% goto :tor_exhausted
echo   [tor] renewing the circuit, attempt %TOR_TRIES% of %ROTATE_TRIES_MAX%...
call :tor_rotate
if errorlevel 1 goto :tor_rotate_fail
call :tor_gate
if errorlevel 1 goto :tor_rotate_fail
echo   [tor] new circuit - resuming.
set "RESUME=1"
set "COLD=0"
goto :resume_and_run
:tor_rotate_fail
echo   [!] Tor could not be renewed - back to menu.
pause
goto :menu_loop
:tor_exhausted
echo   [!] Tor could not get a usable circuit after %ROTATE_TRIES_MAX% attempts.
echo       The exit node may be blocked: try a new identity in Tor, or
echo       switch to [1] WARP. warp/tor notes: "%TOR_DIR%\tor.log"
set /a TOR_TRIES=0
pause
goto :menu_loop
:qr_proxy
if defined ACTIVE_PROXY >>"%STATE_DIR%\proxy_burned.txt" echo %ACTIVE_PROXY%
set /a PROXY_ROT+=1
if %PROXY_ROT% GTR %PROXY_ROT_MAX% goto :proxy_exhausted
echo   [proxy] %ACTIVE_PROXY% is burned - attempt %PROXY_ROT% of %PROXY_ROT_MAX%, picking another...
echo   [proxy] picking a fresh free proxy before resume...
call :pick_free_proxy
if errorlevel 1 goto :proxy_exhausted
set "RESUME=1"
set "COLD=0"
goto :resume_and_run
:proxy_exhausted
echo   [!] no free proxy is left that still works ^(they all hit the limit^).
echo       Free proxies are shared by many people, so their limit is often used up.
choice /c yn /n /m "   Switch to Tor and keep going? [Y/N]: "
if errorlevel 2 goto :proxy_exhausted_menu
set "EGRESS=TOR"
set "WARP="
set "TOR_TRIES=0"
set "PROXY_ROT=0"
set "ACTIVE_PROXY=http://127.0.0.1:%TOR_HTTP_PORT%"
call :tor_gate
if errorlevel 1 goto :tor_rotate_fail
set "RESUME=1"
set "COLD=0"
goto :resume_and_run
:proxy_exhausted_menu
set "PROXY_ROT=0"
pause
goto :menu_loop
:qr_after_tor
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
set /a REG_DONE=0
set "PBROKEN=0"
REM rounds: full give-up-and-restart cycles left before the final pause
set /a RR_LEFT=%ROTATE_ROUNDS%
:rotate_loop
set /a ROTATE_TRIES+=1
if %ROTATE_TRIES% GTR %ROTATE_TRIES_MAX% goto :rotate_fail
REM Space the attempts out: a plain burst of "registration new" is what
REM Cloudflare throttles. From the second attempt on, wait first.
REM v2.22: the wait is keyed to REG_DONE (registrations already made in
REM this round), not to ROTATE_TRIES. Both probe paths decrement
REM ROTATE_TRIES, so the next pass came back as attempt 1, skipped the
REM cooldown and fired two registrations back to back: the 429.
if %REG_DONE% GTR 0 (
    echo [%ROTATE_TRIES%] cooling down %ROTATE_COOLDOWN%s...
    timeout /t %ROTATE_COOLDOWN% /nobreak >nul 2>&1
)
set /a REG_DONE+=1
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
REM Classify the miss: only a limit-shaped answer marks the IP burned.
REM Anything else is a broken probe (retired model id, auth, a CLI
REM change), and no amount of IP rotation fixes that.
REM v2.22: a probe session the CLI refuses is its own case and never
REM counts as a burned IP.
if /i "%PCLASS%"=="nosession" goto :probe_no_session
if /i not "%PCLASS%"=="broken" goto :probe_miss_burned
set /a PBROKEN+=1
echo   [!] probe failed for a reason that is NOT a limit - attempt %PBROKEN% of %PROBE_BROKEN_MAX%. Last output:
call :probe_print
if %PBROKEN% GEQ %PROBE_BROKEN_MAX% goto :probe_broken_stop
set /a ROTATE_TRIES-=1
goto :rotate_loop
:probe_miss_burned
REM The probe hit the limit on this fresh IP: the IP is burned. Undo the
REM attempt count and count the probe instead.
set "PBROKEN=0"
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
:probe_broken_stop
echo.
echo   [!] the probe failed %PBROKEN% times and none of them was a limit error.
echo       The probe itself is broken, not every IP: a retired PROBE_MODEL id,
echo       an auth error or a CLI change. Rotation cannot fix that.
echo       Check PROBE_MODEL in the settings block, or run the probe model once
echo       by hand to see the real error.
choice /c YN /n /m "   Continue WITHOUT the probe this session (IPs accepted untested)? [Y/N]: "
if errorlevel 2 goto :pbs_quit
echo   [i] probe off for this session - IPs are accepted on WARP-trace proof
echo       only, and the resume's own limit check keeps catching burned ones.
set "PROBE=0"
set "PBROKEN=0"
set /a ROTATE_TRIES-=1
goto :rotate_loop
:pbs_quit
call "%OC_CMD%" session delete %OC_PROBE_ID% >nul 2>&1
pause
goto :menu_loop

REM v2.22 (defensive, unverified against real CLI behaviour): nothing here
REM creates the fixed probe session, so a build that REFUSES an unknown
REM "-s <id>" would fail the probe for every IP. That must never read as
REM "all IPs burned": the probe is switched off for this session, the
REM current IP is kept, and the reason is printed in plain text.
:probe_no_session
echo.
echo   [!] the probe session "%OC_PROBE_ID%" does not exist and this
echo       opencode build refused it. That is a probe problem, NOT a
echo       burned IP - no rotation can fix it.
echo   [i] the probe is off for this session: IPs are accepted on
echo       WARP-trace proof only, and the resume's own limit check still
echo       catches a burned one. To keep the probe, create the session by
echo       hand once, or clear PROBE in the settings block.
set "PROBE=0"
set "PBROKEN=0"
REM v2.23: the IP itself was fine, only the probe could not run. Rotating
REM again burned a fresh Cloudflare registration for nothing; accept this
REM IP and resume.
goto :rotate_good

REM A verified IP that passed the probe: save it, mark the resume, and resume the chat.
:rotate_good
echo [%ROTATE_TRIES%] IP %IPN% works.
set "PBROKEN=0"
>"%STATE_DIR%\lastip.txt" echo %IPN%
set "IP=%IPN%"
set "RESUME=1"
set "COLD=0"
REM the background service holds sockets from the old tunnel, and its env
REM was captured before this rotation: restart it so the next TUI is born
REM on this exit IP. this runs on every rotation, not once per machine.
REM v2.25: the restart used to run on the user's own env (the probe had just
REM restored it), so the new service was born DIRECT and every later request
REM left on the real IP. The WARP proxy env is exported around it now.
if not defined CAP_SERVICE goto :rg_svc_done
if not defined OC_CMD goto :rg_svc_done
call :export_proxy
call "%OC_CMD%" service restart >nul 2>&1
call :restore_env
if defined ACTIVE_PROXY set "SVC_PROXIED=%ACTIVE_PROXY%"
:rg_svc_done
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
REM v2.22: a new round starts after a full 60 s wait, so the per-round
REM cooldown counter starts from zero again.
set /a REG_DONE=0
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
if /i not "%APP_MODE%"=="DESKTOP" goto :resume_cli
echo   restarting the desktop app on the new egress...
set "RESUME="
goto :run
:resume_cli
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
REM v2.22: restore the user's own proxy variables instead of deleting them.
call :restore_env
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
REM v2.23: a good resume clears the circuit counter. Without this TOR_TRIES
REM accumulated for the whole session and four clean renewals in a row sent
REM the fifth to the menu.
set /a TOR_TRIES=0
set "PROXY_ROT=0"
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
  if defined OURTOR (
    echo   Restarting the launcher-managed Tor for a new circuit...
    REM v2.22: one call does the whole renewal, log-aware on failure.
    call :tor_rotate
    if errorlevel 1 echo   [!] the new circuit did not come up - see "%TOR_DIR%\tor.log".
    if not errorlevel 1 echo   New circuit: Tor is serving on :%TOR_HTTP_PORT% again.
    pause
    goto :menu_loop
  )
  REM v2.22: a Tor this launcher did not start cannot be renewed from here.
  echo   TOR mode - this Tor was started outside the launcher.
  echo   Restart it yourself for a new circuit, or pick [1] WARP / [4] NONE.
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
if /i not "%APP_MODE%"=="DESKTOP" goto :launch_go
REM Desktop: no --continue (it is a CLI flag). A leftover app or sidecar was
REM born without the proxy env and would keep the old egress, so close both.
set "OC_EXE=%OC_DESKTOP%"
set "OC_FLAGS="
taskkill /f /im "OpenCode.exe" >nul 2>&1
taskkill /f /im "opencode-cli.exe" >nul 2>&1
timeout /t 2 /nobreak >nul 2>&1
:launch_go
set "OC_PIDF=%STATE_DIR%\tui.pid"
if exist "%OC_PIDF%" del /f /q "%OC_PIDF%" >nul 2>&1
REM Start-Process -ArgumentList treats one spaced string as ONE argument:
REM split the flags into tokens first (FLAGS is only --continue here).
REM PowerShell 5.1 REJECTS an empty -ArgumentList ("El argumento es NULL,
REM ..."): a fresh start has no --continue, so the plain-exe branch must
REM omit the parameter entirely when the list is empty.
REM .cmd and .bat files are started through cmd.exe, others are started directly.
REM v2.25: the .cmd/.bat branch used to pass @('/c',$exe)+$a, which never
REM quotes $exe: a path with a space ("C:\Users\John Smith\...") ran as
REM "C:\Users\John" and died. The whole line is now one string, wrapped in
REM the extra quote pair that /s strips, with the exe quoted inside it.
"%PSX%" -NoProfile -Command "$exe=$env:OC_EXE; $a=@(); if($env:OC_FLAGS){ $a=([string]$env:OC_FLAGS) -split [char]32; $a=@($a | Where-Object { $_ }) }; $p=$null; if($exe -match '[.](cmd|bat)$'){ $q=[char]34; $cl='/s /c '+$q+$q+$exe+$q; foreach($x in $a){ $cl+=' '+$x }; $cl+=$q; $p=Start-Process cmd.exe -ArgumentList $cl -NoNewWindow -PassThru } elseif($a.Count){ $p=Start-Process $exe -ArgumentList @($a) -NoNewWindow -PassThru } else { $p=Start-Process $exe -NoNewWindow -PassThru }; if(-not $p){ exit 1 }; $null=$p.Handle; Set-Content -LiteralPath $env:OC_PIDF -Value $p.Id; [void]$p.WaitForExit(); if($p.ExitCode -ne $null){ exit $p.ExitCode }; exit 1"
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
"%PSX%" -NoProfile -Command "$exe=$env:OC_EXE; $a=@('run'); if($env:OC_FL){ $a+=@($env:OC_FL -split [char]32 | Where-Object { $_ }) }; if($env:OC_MSG){ $a+=([char]34 + $env:OC_MSG + [char]34) }; $a=@($a | Where-Object { $_ }); $o=$env:OC_OUTF; $e=$env:OC_ERRF; if($exe -match '[.](cmd|bat)$'){ $q=[char]34; $cl='/s /c '+$q+$q+$exe+$q; foreach($x in $a){ $cl+=' '+$x }; $cl+=$q; $p=Start-Process cmd.exe -ArgumentList $cl -NoNewWindow -PassThru -RedirectStandardOutput $o -RedirectStandardError $e } else { $p=Start-Process $exe -ArgumentList $a -NoNewWindow -PassThru -RedirectStandardOutput $o -RedirectStandardError $e }; if(-not $p){ exit 1 }; $null=$p.Handle; if(-not $p.WaitForExit([int]$env:OC_TO*1000)){ Start-Process taskkill.exe -ArgumentList @('/T','/F','/PID',$p.Id) -WindowStyle Hidden -Wait; exit 124 }; exit $p.ExitCode"
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
REM v2.22: the egress watchdog writes here, and the launcher reads it back
REM after the TUI closes.
if exist "%STATE_DIR%\proxy_warn.txt" del /f /q "%STATE_DIR%\proxy_warn.txt" >nul 2>&1
if /i "%EGRESS%"=="NONE" goto :eof
if /i "%EGRESS%"=="WARP" if not defined WARP goto :eof
REM Paths and settings passed to the watcher through the environment.
set "OC_WPIDF=%STATE_DIR%\watch.pid"
set "OC_TPIDF=%STATE_DIR%\tui.pid"
set "OC_HITF=%STATE_DIR%\watch_hit.txt"
set "OC_LOGF=%LOGFILE%"
set "OC_OFF=%SIZE_BEFORE%"
set "OC_FATPAT=%OC_PAT%"
REM v2.22: proxy watchdog target (host:port). The watcher polls it every
REM minute and warns when the egress dies with the TUI open. It never kills
REM the TUI: a dead proxy is a warning, not a verdict on the session.
set "OC_WATCHP="
set "OC_PWARNF=%STATE_DIR%\proxy_warn.txt"
if /i "%EGRESS%"=="WARP" set "OC_WATCHP=127.0.0.1:%PROXY_PORT%"
if /i "%EGRESS%"=="TOR" set "OC_WATCHP=127.0.0.1:%TOR_HTTP_PORT%"
if /i "%EGRESS%"=="PROXY" if defined ACTIVE_PROXY set "OC_WATCHP=%ACTIVE_PROXY%"
REM Watcher body (PowerShell, one line). Its steps in order:
REM  1) save its own PID, 2) wait up to 60 s for the TUI PID,
REM  3) loop every 2 s: read new log bytes, look for a fatal pattern,
REM     re-read after 4 s, ignore it if INFO or DEBUG lines followed,
REM     otherwise write the hit marker and kill the TUI process tree.
start "" /b "%PSX%" -NoProfile -Command "$PID | Set-Content -LiteralPath $env:OC_WPIDF; $tpid=0; $off=0; $tick=0; $pfail=0; if($env:OC_OFF){$off=[int64]$env:OC_OFF}; $dl=(Get-Date).AddSeconds(60); while($tpid -eq 0){ if((Get-Date) -gt $dl){exit 0}; if(Test-Path -LiteralPath $env:OC_TPIDF){ $c=(Get-Content -LiteralPath $env:OC_TPIDF -ErrorAction SilentlyContinue | Select-Object -First 1); if($c){$tpid=[int]$c} }; if($tpid -eq 0){Start-Sleep -Seconds 1} }; while($true){ Start-Sleep -Seconds 2; $p=Get-Process -Id $tpid -ErrorAction SilentlyContinue; if(-not $p){exit 0}; $tick++; if($tick -ge 30){ $tick=0; if($env:OC_WATCHP){ try{ $hp=($env:OC_WATCHP -replace '^[A-Za-z0-9]+://',''); $ix=$hp.LastIndexOf([char]58); $ph=$hp.Substring(0,$ix); $pp=[int]$hp.Substring($ix+1); $c=New-Object Net.Sockets.TcpClient; $ar=$c.BeginConnect($ph,$pp,$null,$null); if($ar.AsyncWaitHandle.WaitOne(2500)){ $c.EndConnect($ar); $c.Close(); $pfail=0 } else { $pfail++ } }catch{ try{$c.Close()}catch{}; $pfail++ }; if($pfail -ge 3){ try{ Set-Content -LiteralPath $env:OC_PWARNF -Value ('egress proxy stopped answering: ' + $env:OC_WATCHP) }catch{}; $pfail=0 } } }; $t=''; try{ $fs=[IO.File]::Open($env:OC_LOGF,'Open','Read','ReadWrite'); if($fs.Length -lt $off){$off=0}; if($fs.Length -gt $off){ [void]$fs.Seek($off,'Begin'); $sr=New-Object IO.StreamReader($fs); $t=$sr.ReadToEnd(); $off=$fs.Length; $sr.Close() } else { $fs.Close() } }catch{ continue }; if(-not ($t -match $env:OC_FATPAT)){ continue }; Start-Sleep -Seconds 4; $t2=''; try{ $fs2=[IO.File]::Open($env:OC_LOGF,'Open','Read','ReadWrite'); if($fs2.Length -gt $off){ [void]$fs2.Seek($off,'Begin'); $sr2=New-Object IO.StreamReader($fs2); $t2=$sr2.ReadToEnd(); $off=$fs2.Length; $sr2.Close() } else { $fs2.Close() } }catch{}; $lines=($t+$t2) -split [char]10; $idx=-1; for($i=0;$i -lt $lines.Count;$i++){ if($lines[$i] -match $env:OC_FATPAT){$idx=$i} }; $rec=$false; if($idx -ge 0){ for($j=$idx+1;$j -lt $lines.Count;$j++){ if($lines[$j] -match 'level=(INFO|DEBUG)'){$rec=$true} } }; if($rec){ continue }; $p2=Get-Process -Id $tpid -ErrorAction SilentlyContinue; if($p2){ try{Set-Content -LiteralPath $env:OC_HITF -Value 'HIT'}catch{}; Start-Process taskkill.exe -ArgumentList @('/T','/F','/PID',$tpid) -WindowStyle Hidden -Wait; exit 1 } }"     
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
REM exit 0 = the IP can talk, exit 1 = failure. PCLASS is set for the caller:
REM "burned" = a limit-shaped answer, the IP is spent; "broken" = the probe
REM itself failed for another reason (a retired PROBE_MODEL id, an auth
REM error, a CLI change) and no rotation can fix that.
REM The probe NEVER rides the shared background service: on v2 a plain "run"
REM connects to the long-lived service process, which was born with the OLD
REM tunnel's sockets and proxy env. Every brand-new IP would then be probed
REM from the burned route and read as burned forever. When --standalone
REM exists (v2), the probe gets its own server born with THIS proxy env,
REM exactly like the resume does; v1 has no such flag and keeps the old call.
:probe_once
set "PCLASS=burned"
set "HTTP_PROXY=%PROXY%"
set "HTTPS_PROXY=%PROXY%"
set "POUTF=%STATE_DIR%\probe.out"
set "PERRF=%STATE_DIR%\probe.err"
set "PARGS=run -m %PROBE_MODEL% -s %OC_PROBE_ID% --auto"
if defined CAP_STANDALONE set "PARGS=%PARGS% --standalone"
if exist "%POUTF%" del /f /q "%POUTF%" >nul 2>&1
if exist "%PERRF%" del /f /q "%PERRF%" >nul 2>&1
REM No usable offset = no verdict from the log. Never scan the whole file:
REM it still holds every old quota error and would fail every probe.
set "PZB="
for %%S in ("%LOGFILE%") do if not "%%~zS"=="" set "PZB=%%~zS"
call "%OC_CMD%" %PARGS% "reply with just: ok" >"%POUTF%" 2>"%PERRF%"
set "PEC=%errorlevel%"
REM v2.23: restore the user's own proxy variables instead of deleting them.
call :restore_env
if not "%PEC%"=="0" goto :probe_classify
REM The CLI exited clean, but a limit answer can still reach the log a
REM moment later (flush race). Settle once, then judge only what arrived:
REM the log delta, and limit text inside the probe's own captured output.
set "PBURNED="
if defined PZB call :scan_log %PZB%
if defined FHIT set "PBURNED=1"
if not defined PBURNED if exist "%POUTF%" findstr /i /c:"free usage limit" /c:"usage limit reached" /c:"out of usage" /c:"insufficient credits" /c:"payment required" /c:"rate limit" "%POUTF%" >nul 2>&1 && set "PBURNED=1"
if defined PBURNED goto :probe_bad
REM pass: delete the probe session so --continue points at the chat
call "%OC_CMD%" session delete %OC_PROBE_ID% >nul 2>&1
exit /b 0
REM Failure: decide whether it was a limit error or a broken probe.
:probe_classify
set "PBURNED="
if exist "%PERRF%" findstr /i /c:"free usage limit" /c:"usage limit reached" /c:"out of usage" /c:"insufficient credits" /c:"payment required" /c:"rate limit" "%PERRF%" >nul 2>&1 && set "PBURNED=1"
if not defined PBURNED if exist "%POUTF%" findstr /i /c:"free usage limit" /c:"usage limit reached" /c:"out of usage" /c:"insufficient credits" /c:"payment required" /c:"rate limit" "%POUTF%" >nul 2>&1 && set "PBURNED=1"
REM v2.22 (defensive): a CLI that refuses the fixed probe session says so
REM in its own words. Catch that shape before the miss is filed as a
REM "broken probe", so the rotation loop can report it as what it is.
if not defined PBURNED if exist "%PERRF%" findstr /i /c:"session not found" /c:"no such session" /c:"session does not exist" /c:"unknown session" "%PERRF%" >nul 2>&1 && set "PCLASS=nosession"
if not defined PBURNED if exist "%POUTF%" findstr /i /c:"session not found" /c:"no such session" /c:"session does not exist" /c:"unknown session" "%POUTF%" >nul 2>&1 && set "PCLASS=nosession"
:probe_bad
if not defined PBURNED if /i not "%PCLASS%"=="nosession" set "PCLASS=broken"
REM Delete the probe session on both paths, so it never lingers as the
REM newest session while the hunt keeps going.
call "%OC_CMD%" session delete %OC_PROBE_ID% >nul 2>&1
exit /b 1

REM - show the last output the probe produced (failure reports only)
:probe_print
set "OC_TF=%STATE_DIR%\probe.err"
"%PSX%" -NoProfile -Command "if(Test-Path -LiteralPath $env:OC_TF){ Get-Content -LiteralPath $env:OC_TF -Tail 4 | ForEach-Object { '     ' + $_ } }"
set "OC_TF=%STATE_DIR%\probe.out"
"%PSX%" -NoProfile -Command "if(Test-Path -LiteralPath $env:OC_TF){ Get-Content -LiteralPath $env:OC_TF -Tail 4 | ForEach-Object { '     ' + $_ } }"
goto :eof

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
REM v2.22: WCLI_QUIET=1 silences one call (no console line, no wcli.log
REM entry). Used by the registration poll in :reg_drop, where a failure is
REM the expected answer and used to fill wcli.log with noise.
set "OC_QUIET="
if defined WCLI_QUIET set "OC_QUIET=1"
"%PSX%" -NoProfile -Command "$o=$env:OC_RRF; $p=Start-Process -FilePath $env:OC_EXE -ArgumentList $env:OC_ARGS -NoNewWindow -PassThru -RedirectStandardOutput $o -RedirectStandardError ($o+'.err'); if(-not $p){ exit 1 }; $null=$p.Handle; if(-not $p.WaitForExit([int]$env:OC_TO*1000)){ try{$p.Kill()}catch{}; try{Add-Content -LiteralPath $env:OC_LOG -Value (((Get-Date -Format o)+' TIMEOUT: '+$env:OC_ARGS))}catch{}; exit 1 }; if($p.ExitCode -eq $null){ exit 1 }; $rc=$p.ExitCode; if($rc -ne 0){ $why=''; foreach($f in @($o,($o+'.err'))){ if(Test-Path -LiteralPath $f){ $l=@(Get-Content -LiteralPath $f -ErrorAction SilentlyContinue | Where-Object { $_ }); if($l.Count){ $why=$l[$l.Count-1]; break } } }; $line=((Get-Date -Format o)+' exit '+$rc+': '+$env:OC_ARGS); if($why){ $line=$line+' :: '+$why }; if(-not $env:OC_QUIET){ try{Add-Content -LiteralPath $env:OC_LOG -Value $line}catch{} }; exit $rc }; exit 0" >nul 2>&1
if exist "%OC_RRF%" del /f /q "%OC_RRF%" >nul 2>&1
if exist "%OC_RRF%.err" del /f /q "%OC_RRF%.err" >nul 2>&1
set "WCLIRC=%errorlevel%"
if not "%WCLIRC%"=="0" if not defined WCLI_QUIET echo   [wcli] "%WCMD%" failed - see wcli.log
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
REM v2.28: the winget channel (SST.opencode) is frozen on 1.19.5, the old v1
REM line, so it is not used. The official build from opencode.ai goes first.
call :standalone
call :find_opencode
if defined OC_CMD goto :ioc_done
if defined OC_ABORT goto :eof
call :olog "standalone produced nothing, trying npm"
call :have_exe npm
if "%HAVE%"=="0" goto :eof
echo   [auto-install] the standalone build did not install, trying npm.
call :npm_install
call :find_opencode
if defined OC_CMD goto :ioc_done
call :olog "npm produced nothing"
goto :eof
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
call :npm_install opencode-ai
call :find_opencode
if defined OC_CMD (
  echo   [ok] opencode ready on 32-bit via npm.
  goto :eof
)
echo   ERROR: opencode could not be installed on 32-bit Windows.
echo          Install 32-bit node.js by hand from nodejs.org, then run:
echo          npm i -g opencode-ai
pause
REM v2.22: :standalone runs inside "call :install_opencode". A "goto :quit"
REM from here jumped out of the call, ran :quit and then returned into the
REM caller anyway. Raise a flag and return; the top-level caller exits.
set "OC_ABORT=1"
goto :eof

REM Download the standalone zip from the latest GitHub release.
:sa_ok
call :oc_cli_file
call :oc_api cli "%OC_AFILE%"
if defined OCA_URL goto :sa_have
echo   [!] could not read the official release info from opencode.ai.
goto :eof
:sa_have
set "OC_URL=%OCA_URL%"
set "OCZIP=%TEMP%\opencode-windows.zip"
set "OCBIN=%LOCALAPPDATA%\opencode\bin"
echo   [auto-install] downloading opencode %OCA_VER% ^(official build, %OC_AFILE%^)...
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
if not "%ZOK%"=="1" goto :sa_bad
call :oc_sha "%OCZIP%" "%OCA_SHA%"
if "%SHAOK%"=="1" goto :sa_unzip
echo     [!] checksum mismatch - the download is not the official file.
:sa_bad
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

REM - the one-line install trail: every hop a channel attempt makes is
REM written here, so a VM that refuses to install gives the reason.
:olog
>>"%STATE_DIR%\install.log" echo [%DATE% %TIME%] %~1
goto :eof

REM Install opencode with npm globally, then add the npm folder to PATH for this session.
:npm_install
REM v2.28: the v2 CLI is @opencode/cli (opencode-ai is the frozen v1 line, kept
REM only for 32-bit). npm 12 blocks its postinstall unless allowed, and without
REM it bin\opencode.exe stays a 229-byte stub that prints "postinstall script
REM was not run". The flag is harmless on older npm (an unknown-config warning).
set "NPMPKG=%~1"
if not defined NPMPKG set "NPMPKG=@opencode/cli"
echo   [auto-install] installing %NPMPKG% with npm...
call npm install -g %NPMPKG%@latest --allow-scripts=@opencode/cli
set "PATH=%PATH%;%ProgramFiles%\nodejs;%APPDATA%\npm"
call :npm_fixbin
goto :eof

REM - repair a blocked postinstall: run it by hand when the exe is still the stub
:npm_fixbin
set "NPMROOT="
for /f "usebackq delims=" %%r in (`npm root -g 2^>nul`) do set "NPMROOT=%%r"
if not defined NPMROOT set "NPMROOT=%APPDATA%\npm\node_modules"
set "NPMCLI=%NPMROOT%\@opencode\cli"
if not exist "%NPMCLI%\postinstall.mjs" goto :eof
for %%F in ("%NPMCLI%\bin\opencode.exe") do if %%~zF GTR 100000 goto :eof
echo   [npm] the install script was blocked - running it by hand...
node "%NPMCLI%\postinstall.mjs" >nul 2>&1
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
REM v2.22: 8 s was too short on a cold start, and empty output is
REM indistinguishable from a v1 CLI. 15 s, plus one retry when neither
REM marker was found.
set "OC_DCR=0"
:dc_run
set "OC_VEXE=%OC_CMD%"
set "OC_VF=%TEMP%\oc_caps_%RANDOM%%RANDOM%.txt"
set "OC_VTO=15"
if exist "%OC_VF%" del /f /q "%OC_VF%" >nul 2>&1
"%PSX%" -NoProfile -Command "$exe=$env:OC_VEXE; $o=$env:OC_VF; $to=[int]$env:OC_VTO*1000; $line='call '+[char]34+$exe+[char]34+' --help 2>&1'; $p=Start-Process cmd.exe -ArgumentList @('/c',$line) -NoNewWindow -PassThru -RedirectStandardOutput $o; if($p){ $null=$p.Handle; if(-not $p.WaitForExit($to)){ Start-Process taskkill.exe -ArgumentList @('/T','/F','/PID',$p.Id) -WindowStyle Hidden -Wait } }" >nul 2>&1
if not exist "%OC_VF%" goto :dc_retry
findstr /i /c:"--standalone" "%OC_VF%" >nul 2>&1 && set "CAP_STANDALONE=1"
REM v2.25: OpenCode v2 prints the subcommand as "service    Manage the
REM background server" and never the words "opencode service", so this flag
REM was never set and every service restart/stop in the launcher was dead
REM code. The legacy marker stays as a fallback.
findstr /i /c:"opencode service" "%OC_VF%" >nul 2>&1 && set "CAP_SERVICE=1"
if not defined CAP_SERVICE findstr /r /i /c:"^ *service  *Manage" "%OC_VF%" >nul 2>&1 && set "CAP_SERVICE=1"
if defined CAP_STANDALONE goto :dc_eof
if defined CAP_SERVICE goto :dc_eof
:dc_retry
if "%OC_DCR%"=="1" goto :dc_eof
set "OC_DCR=1"
if exist "%OC_VF%" del /f /q "%OC_VF%" >nul 2>&1
goto :dc_run
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
REM v2.22: 3 s was too short on a cold start (antivirus scanning the exe),
REM and an empty answer made the launcher treat a v2 binary as v1. 10 s,
REM plus one retry when nothing came back.
set "OC_VR=0"
:oc_ver_run
set "OC_VF=%TEMP%\oc_ver_%RANDOM%%RANDOM%.txt"
set "OC_VEXE=%OC_CAN%"
set "OC_VTO=10"
if exist "%OC_VF%" del /f /q "%OC_VF%" >nul 2>&1
"%PSX%" -NoProfile -Command "$exe=$env:OC_VEXE; $o=$env:OC_VF; $to=[int]$env:OC_VTO*1000; $line='call ' + [char]34 + $exe + [char]34 + ' --version 2>nul <nul'; $p=Start-Process cmd.exe -ArgumentList @('/c',$line) -NoNewWindow -PassThru -RedirectStandardOutput $o; if(-not $p){ exit 1 }; $null=$p.Handle; if(-not $p.WaitForExit($to)){ Start-Process taskkill.exe -ArgumentList @('/T','/F','/PID',$p.Id) -WindowStyle Hidden -Wait; exit 124 }; exit 0" >nul 2>&1
set "OC_VRC=%errorlevel%"
set "VLINE="
if exist "%OC_VF%" set /p VLINE=<"%OC_VF%"
if defined VLINE goto :oc_ver_read
REM v2.23: retry only after a TIMEOUT (124). A binary that answered and
REM printed nothing is a normal v1 answer; retrying it cost another 10 s
REM per candidate for nothing.
if not "%OC_VRC%"=="124" goto :oc_ver_eof
if "%OC_VR%"=="1" goto :oc_ver_eof
set "OC_VR=1"
if exist "%OC_VF%" del /f /q "%OC_VF%" >nul 2>&1
goto :oc_ver_run
:oc_ver_read
if exist "%OC_VF%" del /f /q "%OC_VF%" >nul 2>&1
for /f "tokens=2" %%v in ("%VLINE%") do if not defined CVER set "CVER=%%v"
if not defined CVER for /f "tokens=1" %%v in ("%VLINE%") do if not defined CVER set "CVER=%%v"
REM v2.28: "Error: ... postinstall script was not run" used to be taken as a
REM version. Only a token that starts with a digit (after an optional v) is one.
if not defined CVER goto :oc_ver_eof
set "CV=%CVER%"
if /i "%CV:~0,1%"=="v" set "CV=%CV:~1%"
set "CVD=%CV:~0,1%"
for /f "delims=0123456789" %%d in ("%CVD%") do set "CVER="
:oc_ver_eof
if exist "%OC_VF%" del /f /q "%OC_VF%" >nul 2>&1
REM v2.23: no second run for an unparsable line either - only a timeout.
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
set "A3=0"
set "B1=0"
set "B2=0"
set "B3=0"
REM v2.22: the third component (patch) is compared too. v2.21 stopped at
REM minor, so 2.2.1 and 2.2.9 ranked equal.
for /f "tokens=1,2,3 delims=." %%a in ("%VA%") do (set "A1=%%a" & set "A2=%%b" & set "A3=%%c")
for /f "tokens=1,2,3 delims=." %%a in ("%VB%") do (set "B1=%%a" & set "B2=%%b" & set "B3=%%c")
call :vnum A1
call :vnum A2
call :vnum A3
call :vnum B1
call :vnum B2
call :vnum B3
if %A1% GTR %B1% goto :vg_new
if %A1% LSS %B1% goto :eof
if %A2% GTR %B2% goto :vg_new
if %A2% LSS %B2% goto :eof
if %A3% GTR %B3% goto :vg_new
goto :eof
:vg_new
set "VGT=1"
goto :eof

REM - force a token to a non-negative integer
REM usage: call :vnum NAME; anything that is not a number becomes 0.
:vnum
set "NV=%~1"
call set "NRAW=%%%NV%%%"
REM v2.25: set /a reads a leading 0 as octal, so "08" and "09" failed and
REM ranked as 0. Leading zeros are stripped first.
REM An undefined NRAW (a one-part version like "2") must never reach the
REM substring syntax below: it is a syntax error in a batch file.
:vn_z
if not defined NRAW goto :vn_n
if not "%NRAW:~0,1%"=="0" goto :vn_n
if "%NRAW:~1%"=="" goto :vn_n
set "NRAW=%NRAW:~1%"
goto :vn_z
:vn_n
set "NN="
set /a NN=NRAW 2>nul
if not defined NN set "NN=0"
if %NN% LSS 0 set "NN=0"
set "%NV%=%NN%"
goto :eof

REM - offer a newer opencode, once per start, ask first
REM Installed version comes from "%OC_CMD% --version" (:oc_version), the
REM latest from the official release metadata (:oc_api) over a direct
REM connection: the proxy env is cleared so WARP is never in the path, and
REM the call is capped at 20 s. No network, a timeout or a bad answer all
REM leave the launcher running exactly as it was. The check is skipped
REM during an automatic resume and never installs without a Y.
:oc_update_check
if defined OCUPD goto :eof
set "OCUPD=1"
if not defined OC_CMD goto :eof
if defined RESUME goto :eof
call :trace oc_update
REM Installed version, read from the binary itself.
set "OC_CAN=%OC_CMD%"
call :oc_version
if not defined CVER goto :eof
set "OCUPD_CUR=%CVER%"
REM v2.28: latest from the official release metadata (direct, 20 s cap). The
REM old check asked npm for opencode-ai, the frozen v1 line, so it never saw v2.
call :oc_api cli ""
if not defined OCA_VER goto :eof
set "OCUPD_LAT=%OCA_VER%"
set "VGT=0"
call :ver_gt "%OCUPD_LAT%" "%OCUPD_CUR%"
if not "%VGT%"=="1" goto :eof
echo.
echo   opencode update available: %OCUPD_CUR% -^> %OCUPD_LAT%
echo   It closes every running opencode process first.
choice /c YN /n /m "   Update now? [Y/N]: "
REM errorlevel 0 (no stdin) and 2 (N) both skip the install.
if not errorlevel 1 goto :eof
if errorlevel 2 goto :eof
call :stop_opencode
REM Same channel as the running command: npm installs go through npm, the rest
REM through the official standalone build.
echo "%OC_CMD%" | findstr /i /c:"\npm" >nul 2>&1
if errorlevel 1 goto :ouc_standalone
echo   [update] npm i -g @opencode/cli@latest
call :npm_install
goto :ouc_after
:ouc_standalone
echo   [update] official standalone build %OCUPD_LAT%
call :standalone
:ouc_after
REM v2.22: resolve the command again. OC_CMD could still point at an old
REM exe, so the version read below came from the wrong binary. The newest wins.
call :find_opencode
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
echo       Update it:  npm i -g @opencode/cli@latest   ^(or accept the update offer^)
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
REM v2.22: this poll is EXPECTED to fail while the daemon tears the old
REM registration down. Quiet mode keeps that normal probe out of the
REM console and out of wcli.log.
set "WCLI_QUIET=1"
call :wcli registration show
set "WCLI_QUIET="
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

REM ============================================================
REM  4a) TOR portable auto-setup [2] ----------------------------
REM ============================================================
REM Option [2] TOR with nothing installed: download the portable
REM Tor Expert Bundle once (tar.gz, no installer, no UAC, no
REM service), start it hidden on TOR_SOCKS_PORT, and expose it as an
REM HTTP proxy on TOR_HTTP_PORT through a tiny built-in bridge
REM process, so no Privoxy install is needed. A Tor already running
REM (Tor Browser or a user tor on the SOCKS port) is used as it is and
REM never killed by the launcher: at exit :tor_stop only ever stops
REM processes running from inside TOR_DIR (v2.20 identity rule).

REM - one-stop gate for the TOR egress: 0 = usable, 1 = give up
:tor_gate
call :trace tor_gate
call :tor_ready
REM v2.24: a bridge that already answers short-circuits the gate. Recover
REM ownership here too, or "Change IP" treats our own Tor as a foreign one.
if not errorlevel 1 goto :tg_have
REM v2.22: look for a Tor that is already running BEFORE downloading the
REM portable bundle. The old order fetched the bundle even when a live Tor
REM (service on 9050, Tor Browser on 9150) was sitting on its SOCKS port.
call :tor_socks_up
if not errorlevel 1 goto :tg_existing
if not "%TOR_AUTO_INSTALL%"=="1" goto :tg_fail
echo   [tor] nothing answering on :%TOR_HTTP_PORT% - portable setup starting...
call :tor_install_if_missing
if not defined TOR_EXE goto :tg_missing
:tg_existing
call :tor_start_if_needed
if errorlevel 1 goto :tg_fail
call :tor_wait_up
call :tor_ready
if not errorlevel 1 goto :tg_ok
:tg_fail
echo   [!] Tor did not become ready - the reason is in "%TOR_DIR%\tor.log"
call :tor_log_tail
exit /b 1
:tg_missing
echo   [!] the Tor download did not land. Grab it by hand:
echo       https://dist.torproject.org/torbrowser/
echo       unpack the tor-expert-bundle tar.gz into "%TOR_DIR%",
echo       so that "%TOR_DIR%\Tor\tor.exe" exists, then run this again.
exit /b 1
REM v2.24: single place that records who owns the running Tor, whichever
REM branch reached a ready state.
:tg_have
call :tor_own_running
if not errorlevel 1 set "OURTOR=1"
:tg_ok
echo   [tor] ready: SOCKS :%TOR_SOCKS_PORT% - HTTP :%TOR_HTTP_PORT%.
exit /b 0

REM - locate tor.exe under TOR_DIR: fixed bundle layouts first, then one
REM bounded recurse. Sets TOR_EXE, or leaves it empty when nothing is there.
:tor_find_exe
if defined TOR_EXE goto :eof
set "TOR_EXE="
if exist "%TOR_DIR%\Tor\tor.exe" set "TOR_EXE=%TOR_DIR%\Tor\tor.exe"
if not defined TOR_EXE if exist "%TOR_DIR%\tor.exe" set "TOR_EXE=%TOR_DIR%\tor.exe"
if defined TOR_EXE goto :eof
set "OC_TORDIR=%TOR_DIR%"
for /f "usebackq delims=" %%t in (`%PSX% -NoProfile -Command "try{ $f=Get-ChildItem -LiteralPath $env:OC_TORDIR -Recurse -Filter tor.exe -ErrorAction SilentlyContinue | Select-Object -First 1; if($f){ $f.FullName } }catch{}"`) do set "TOR_EXE=%%t"
goto :eof

REM - download the portable Tor Expert Bundle once
REM Facts travel the Tor Browser updater downloads.json first: it carries
REM the exact current bundle filename, so no version is ever hard-coded.
REM A scrape of the dist folder index is the fallback. Size-gated like
REM every other download, unpacked with the Windows tar.exe, direct egress.
:tor_install_if_missing
set "TOR_EXE="
if exist "%TOR_DIR%\Tor\tor.exe" set "TOR_EXE=%TOR_DIR%\Tor\tor.exe"
if not defined TOR_EXE if exist "%TOR_DIR%\tor.exe" set "TOR_EXE=%TOR_DIR%\tor.exe"
if defined TOR_EXE echo   [tor] tor is already installed: %TOR_EXE%
if defined TOR_EXE goto :eof
call :trace tor_install
if not exist "%TOR_DIR%" mkdir "%TOR_DIR%" >nul 2>&1
set "TORPLAT=windows_x86_64"
set "TORFILE=windows-x86_64"
if /i "%PROCESSOR_ARCHITECTURE%"=="ARM64" set "TORPLAT=windows_arm64"
if /i "%PROCESSOR_ARCHITECTURE%"=="ARM64" set "TORFILE=windows-arm64"
if "%REAL86%"=="1" set "TORPLAT=windows_i686"
if "%REAL86%"=="1" set "TORFILE=windows-i686"
set "TGZ=%TEMP%\tor-expert-bundle.tar.gz"
if exist "%TGZ%" del /f /q "%TGZ%" >nul 2>&1
set "KEEP_HP=%HTTP_PROXY%"
set "KEEP_SP=%HTTPS_PROXY%"
set "HTTP_PROXY="
set "HTTPS_PROXY="
set "OC_TORDL=%TEMP%\oc_tor_url.txt"
set "OC_TPLAT=%TORPLAT%"
set "OC_TFILE=%TORFILE%"
set "OC_TOUT=%OC_TORDL%"
if exist "%OC_TORDL%" del /f /q "%OC_TORDL%" >nul 2>&1
"%PSX%" -NoProfile -Command "try{[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; $j=Invoke-RestMethod -Uri 'https://aus1.torproject.org/torbrowser/update_3/release/downloads.json' -TimeoutSec 30; $p=$j.projects.tor.platforms.($env:OC_TPLAT); $u=$null; if($p -and $p.download_url){ $u=([string]$p.download_url[0]).TrimEnd('/')+'/'+[string]$p.download_filename }; if(-not $u -or $u -notmatch '^https://'){ exit 1 }; [IO.File]::WriteAllText($env:OC_TOUT, $u); exit 0 }catch{ exit 1 }" >nul 2>&1
set "TGZURL="
if exist "%OC_TORDL%" for /f "usebackq delims=" %%u in ("%OC_TORDL%") do set "TGZURL=%%u"
if exist "%OC_TORDL%" del /f /q "%OC_TORDL%" >nul 2>&1
if defined TGZURL goto :tia_fetch
echo   [tor] updater JSON unavailable - falling back to the dist index...
"%PSX%" -NoProfile -Command "try{[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; $h=(Invoke-WebRequest -UseBasicParsing -Uri 'https://dist.torproject.org/torbrowser/' -TimeoutSec 30).Content; $vs=@(); foreach($m in [regex]::Matches($h, '(\d+\.\d+(?:\.\d+)?)/')){ if($vs -notcontains $m.Groups[1].Value){ $vs+=,$m.Groups[1].Value } }; $last=$null; foreach($v in $vs){ try{ if((-not $last) -or ([version]$v -gt [version]$last)){ $last=$v } }catch{} }; if(-not $last){ exit 1 }; $u='https://dist.torproject.org/torbrowser/'+$last+'/tor-expert-bundle-'+$env:OC_TFILE+'-'+$last+'.tar.gz'; [IO.File]::WriteAllText($env:OC_TOUT, $u); exit 0 }catch{ exit 1 }" >nul 2>&1
set "TGZURL="
if exist "%OC_TORDL%" for /f "usebackq delims=" %%u in ("%OC_TORDL%") do set "TGZURL=%%u"
if exist "%OC_TORDL%" del /f /q "%OC_TORDL%" >nul 2>&1
if not defined TGZURL goto :tia_restore
:tia_fetch
echo     %TGZURL%
set "OC_TURL=%TGZURL%"
set "OC_TGZ=%TGZ%"
if "%HAVE_CURL%"=="1" curl.exe -L -f -s --max-time 600 --noproxy "*" -o "%TGZ%" "%TGZURL%" >nul 2>&1
if exist "%TGZ%" for %%Z in ("%TGZ%") do if %%~zZ GEQ 4000000 goto :tia_up_ok
"%PSX%" -NoProfile -Command "try{[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -UseBasicParsing -Uri $env:OC_TURL -OutFile $env:OC_TGZ -TimeoutSec 600}catch{}" >nul 2>&1
if exist "%TGZ%" for %%Z in ("%TGZ%") do if %%~zZ GEQ 4000000 goto :tia_up_ok
:tia_restore
set "HTTP_PROXY=%KEEP_HP%"
set "HTTPS_PROXY=%KEEP_SP%"
echo   [!] the Tor bundle did not download.
goto :eof
:tia_up_ok
set "HTTP_PROXY=%KEEP_HP%"
set "HTTPS_PROXY=%KEEP_SP%"
echo   [tor] unpacking...
set "OC_TGZ=%TGZ%"
set "OC_TDIR=%TOR_DIR%"
REM v2.28: the Windows tar by full path - a GNU tar from Git/MSYS earlier in PATH
REM reads "C:\..." as host:file and unpacks nothing.
set "TAREXE=tar.exe"
if exist "%SystemRoot%\System32\tar.exe" set "TAREXE=%SystemRoot%\System32\tar.exe"
"%TAREXE%" -xzf "%TGZ%" -C "%TOR_DIR%" >nul 2>&1
if exist "%TGZ%" del /f /q "%TGZ%" >nul 2>&1
call :tor_find_exe
if defined TOR_EXE (
  REM v2.22: this echo used to contain a literal "(portable)". Inside an
  REM if (...) block that closing parenthesis ended the block right there,
  REM so the whole line was a syntax error at parse time.
  echo   [ok] Tor installed - portable - in "%TOR_DIR%".
) else (
  echo   [!] the bundle unpacked but tor.exe was not found in "%TOR_DIR%".
)
goto :eof

REM - start what is missing; never touch a Tor or bridge that already runs
REM A SOCKS port already answering belongs to a running Tor (for example
REM Tor Browser): it is used as it is. At exit :tor_stop (v2.20) stops
REM only tor processes whose image path lives inside TOR_DIR plus bridge
REM processes carrying the OC_TORBRIDGE_PS command-line marker, so what
REM gets stopped is always launcher-managed - also left over from a
REM past session - and a foreign Tor or bridge never is. An HTTP port
REM already answering is a working bridge (anyone's) and is used as it is.
:tor_start_if_needed
set "OURTOR="
set "OURBRIDGE="
REM v2.23: our own tor can still be alive after the bridge died. Recover
REM ownership from tor.pid so :tor_rotate can restart it, instead of
REM declaring it foreign and refusing to renew the circuit.
call :tor_own_running
if not errorlevel 1 set "OURTOR=1"
call :tor_socks_up
if errorlevel 1 goto :tsi_tor
echo   [tor] a Tor is already running on :%TOR_SOCKS_PORT% - using it as it is.
goto :tsi_bridge
:tsi_tor
call :tor_find_exe
if not defined TOR_EXE exit /b 1
if not exist "%TOR_DIR%\data" mkdir "%TOR_DIR%\data" >nul 2>&1
REM torrc written to a file instead of quoting trouble on the command
REM line. Quoted values must carry WINDOWS PATHS AS FORWARD SLASHES:
REM tor treats a backslash inside double quotes as the start of an
REM escape sequence, so a backslashed path dies parsing with
REM "Invalid escape sequence in quoted string". tor accepts
REM forward-slash Windows paths, so slashtify the directory once here.
set "OC_TDS=%TOR_DIR:\=/%"
>"%TOR_DIR%\torrc" echo SocksPort "127.0.0.1:%TOR_SOCKS_PORT%"
>>"%TOR_DIR%\torrc" echo DataDirectory "%OC_TDS%/data"
>>"%TOR_DIR%\torrc" echo Log "notice file %OC_TDS%/tor.log"
if exist "%TOR_DIR%\tor.log" del /f /q "%TOR_DIR%\tor.log" >nul 2>&1
if exist "%TOR_DIR%\tor.pid" del /f /q "%TOR_DIR%\tor.pid" >nul 2>&1
set "OC_TOREXE=%TOR_EXE%"
set "OC_TORRC=%TOR_DIR%\torrc"
set "OC_TORPID=%TOR_DIR%\tor.pid"
set "OC_TORLOG=%TOR_DIR%\tor.log"
set "OC_TORERR=%TOR_DIR%\tor_start.err"
if exist "%OC_TORERR%" del /f /q "%OC_TORERR%" >nul 2>&1
echo   [tor] starting tor (hidden window, log: "%OC_TORLOG%")...
REM tor's config switch is -f (a "--torrc" flag does not exist: tor
REM exits with "Unknown option 'torrc'"). stderr is captured so a tor
REM that refuses to start leaves its own reason in tor_start.err, and
REM the spawn is confirmed two seconds later: a process that died
REM immediately after Start-Process is a failed start, not an up one.
"%PSX%" -NoProfile -Command "try{ $si=New-Object System.Diagnostics.ProcessStartInfo; $si.FileName=$env:OC_TOREXE; $si.Arguments=('-f '+[char]34+$env:OC_TORRC+[char]34+' --quiet'); $si.UseShellExecute=$false; $si.CreateNoWindow=$true; $si.RedirectStandardError=$true; $p=[System.Diagnostics.Process]::Start($si); if(-not $p){ exit 1 }; [IO.File]::WriteAllText($env:OC_TORPID,[string]$p.Id); Start-Sleep -Seconds 2; if($p.HasExited){ try{ [IO.File]::WriteAllText($env:OC_TORERR, 'tor exited with code '+$p.ExitCode+': '+($p.StandardError.ReadToEnd())) }catch{}; exit 1 }; exit 0 }catch{ exit 1 }" >nul 2>&1
if errorlevel 1 (
  echo   [!] tor could not be started - see "%OC_TORERR%" and "%OC_TORLOG%".
  if exist "%OC_TORERR%" "%PSX%" -NoProfile -Command "Get-Content -LiteralPath $env:OC_TORERR -ErrorAction SilentlyContinue | Select-Object -First 4 | ForEach-Object { '     ' + [string]$_ }"
  exit /b 1
)
set "OURTOR=1"
:tsi_bridge
call :port_up %TOR_HTTP_PORT%
if not errorlevel 1 goto :tsi_done
REM v2.25: with a Tor that was already running, nothing had created TOR_DIR
REM yet, so the bridge could write neither bridge.log nor bridge.pid (it
REM printed a DirectoryNotFound error) and :tor_stop could never find the
REM bridge again: it kept running after the launcher exited.
if not exist "%TOR_DIR%" mkdir "%TOR_DIR%" >nul 2>&1
set "OC_BRPORT=%TOR_HTTP_PORT%"
set "OC_BRSOCKS=%TOR_SOCKS_PORT%"
set "OC_BRLOG=%TOR_DIR%\bridge.log"
set "OC_BRPIDF=%TOR_DIR%\bridge.pid"
if exist "%OC_BRLOG%" del /f /q "%OC_BRLOG%" >nul 2>&1
if exist "%OC_BRPIDF%" del /f /q "%OC_BRPIDF%" >nul 2>&1
echo   [tor] starting the built-in HTTP-^>SOCKS bridge on :%TOR_HTTP_PORT% (no Privoxy needed)...
start "" /b "%PSX%" -NoProfile -Command "$l=Get-Content -LiteralPath $env:OCI_SELF; $i=[Array]::IndexOf($l,'#>>>OC_TORBRIDGE_PS'); $e=[Array]::IndexOf($l,'#>>>OC_ENDTORBRIDGE'); if(($i -ge 0) -and ($e -gt $i)){ $BRTEXT=(($l[($i+1)..($e-1)]) -join [Environment]::NewLine); Invoke-Expression $BRTEXT }"
timeout /t 2 /nobreak >nul 2>&1
set "OURBRIDGE=1"
:tsi_done
exit /b 0

REM - wait until Tor routes THROUGH THE BRIDGE (v2.20): the run gate and
REM opencode itself use the HTTP proxy on TOR_HTTP_PORT, so the wait
REM checks the whole chain, not just a live SOCKS port - a Tor up with a
REM dead bridge must not be answered as ready. With curl: the real TRACE
REM probe through the bridge. Without curl: "Bootstrapped 100" in the
REM tor log plus both ports listening. Bounded.
:tor_wait_up
echo   [tor] bootstrapping, up to %TOR_BOOTSTRAP_WAIT%s (the first run takes longer)...
set /a TW_TRIES=0
:tw_loop
set /a TW_TRIES+=2
if %TW_TRIES% GTR %TOR_BOOTSTRAP_WAIT% goto :tw_timeout
timeout /t 2 /nobreak >nul 2>&1
call :tw_check
if not errorlevel 1 goto :tw_up
<nul set /p=.
goto :tw_loop
:tw_up
echo.
echo   [tor] Tor is up and routing through the bridge.
exit /b 0
:tw_timeout
echo.
echo   [tor] still not up after %TOR_BOOTSTRAP_WAIT%s.
exit /b 1
REM One wait check. Runtime-safe errorlevel handling throughout (the
REM old NEQ-style line read %errorlevel% as stale parse-time text).
:tw_check
if "%HAVE_CURL%"=="1" (
  curl.exe -sS -o nul -f --max-time 8 --noproxy "" --proxy "http://127.0.0.1:%TOR_HTTP_PORT%" "%TRACE_URL%" >nul 2>&1
  if errorlevel 1 exit /b 1
  exit /b 0
)
call :port_up %TOR_SOCKS_PORT%
if errorlevel 1 exit /b 1
call :port_up %TOR_HTTP_PORT%
if errorlevel 1 exit /b 1
if not exist "%TOR_DIR%\tor.log" exit /b 1
findstr /c:"Bootstrapped 100" "%TOR_DIR%\tor.log" >nul 2>&1
if errorlevel 1 exit /b 1
exit /b 0

REM - the last lines of tor.log, printed next to the failure message
:tor_log_tail
if not exist "%TOR_DIR%\tor.log" goto :eof
set "OC_TF=%TOR_DIR%\tor.log"
"%PSX%" -NoProfile -Command "if(Test-Path -LiteralPath $env:OC_TF){ Get-Content -LiteralPath $env:OC_TF -Tail 6 | ForEach-Object { '     ' + $_ } }"
goto :eof

REM - is a TCP port on 127.0.0.1 accepting connections?
REM usage: call :port_up 9050  -> errorlevel 0 when open, 1 when closed.
:port_up
set "OC_PU=%~1"
"%PSX%" -NoProfile -Command "try{$c=New-Object Net.Sockets.TcpClient;$a=$c.BeginConnect('127.0.0.1',[int]$env:OC_PU,$null,$null);if(-not $a.AsyncWaitHandle.WaitOne(1200)){exit 1};$c.EndConnect($a);$c.Close();exit 0}catch{exit 1}" >nul 2>&1
exit /b %errorlevel%

REM - stop only launcher-managed processes, never a recycled PID or a
REM foreign process behind a stale record (v2.20 rewrite):
REM   tor    - only if its ProcessName is tor AND its image path lives
REM            inside TOR_DIR, the private bundle dir only this launcher
REM            writes to. A user's Tor Browser or any foreign tor is
REM            never matched, whatever the pid file says.
REM   bridge - only if ProcessName is powershell/pwsh AND the process
REM            command line carries the OC_TORBRIDGE_PS marker that every
REM            launcher-spawned bridge process carries.
REM Final stop verification is by identity, not by pid alone; pid files
REM that match nothing are stale garbage and are deleted.
:tor_stop
set "OC_TORPID=%TOR_DIR%\tor.pid"
set "OC_BRPIDF=%TOR_DIR%\bridge.pid"
if not exist "%OC_TORPID%" if not exist "%OC_BRPIDF%" goto :eof
set "OC_TORDIR=%TOR_DIR%"
if exist "%OC_TORPID%" "%PSX%" -NoProfile -Command "$t=Get-Content -LiteralPath $env:OC_TORPID -ErrorAction SilentlyContinue | Select-Object -First 1; if($t){ try{ $p=Get-Process -Id ([int]$t) -ErrorAction Stop }catch{ $p=$null }; if($p -and $p.ProcessName -eq 'tor'){ $ok=$false; try{ $pd=$env:OC_TORDIR; if($p.Path){ $ok=($p.Path -ieq $pd) -or ($p.Path -like ($pd+'\*')) } }catch{}; if($ok){ try{ Stop-Process -Id $p.Id -Force }catch{} } } }" >nul 2>&1
if exist "%OC_BRPIDF%" "%PSX%" -NoProfile -Command "$t=Get-Content -LiteralPath $env:OC_BRPIDF -ErrorAction SilentlyContinue | Select-Object -First 1; if($t){ try{ $p=Get-Process -Id ([int]$t) -ErrorAction Stop }catch{ $p=$null }; if($p -and ($p.ProcessName -eq 'powershell' -or $p.ProcessName -eq 'pwsh')){ $ok=$false; try{ $cl=(Get-CimInstance Win32_Process -Filter ('ProcessId=' + [string]$p.Id)).CommandLine; if($cl -and $cl.Contains('OC_TORBRIDGE_PS')){ $ok=$true } }catch{}; if($ok){ try{ Stop-Process -Id $p.Id -Force }catch{} } } }" >nul 2>&1
del /f /q "%OC_TORPID%" "%OC_BRPIDF%" >nul 2>&1
set "OURTOR="
set "OURBRIDGE="
goto :eof

REM - is a Tor SOCKS port answering? (v2.22)
REM Checks TOR_SOCKS_PORT first, then Tor Browser's default (9150) and the
REM tor service default (9050). When one of those answers, TOR_SOCKS_PORT
REM is moved to it, so torrc and the bridge point at the live Tor.
REM exit 0 = a usable SOCKS port exists, 1 = none.
:tor_socks_up
call :port_up %TOR_SOCKS_PORT%
if not errorlevel 1 exit /b 0
call :port_up 9150
if not errorlevel 1 goto :tsu_9150
call :port_up 9050
if not errorlevel 1 goto :tsu_9050
exit /b 1
:tsu_9150
echo   [tor] found a Tor Browser SOCKS on :9150 - using it.
set "TOR_SOCKS_PORT=9150"
exit /b 0
:tsu_9050
echo   [tor] found a Tor SOCKS on :9050 - using it.
set "TOR_SOCKS_PORT=9050"
exit /b 0

REM - is the tor recorded in tor.pid ours and still running? (v2.23)
REM Identity rule of :tor_stop: only a tor process whose image path sits
REM inside TOR_DIR counts, whatever the pid file says.
REM exit 0 = ours and alive, 1 = not.
:tor_own_running
set "OC_TORPID=%TOR_DIR%\tor.pid"
if not exist "%OC_TORPID%" exit /b 1
set "OC_TORDIR=%TOR_DIR%"
"%PSX%" -NoProfile -Command "$t=Get-Content -LiteralPath $env:OC_TORPID -ErrorAction SilentlyContinue | Select-Object -First 1; if(-not $t){ exit 1 }; try{ $p=Get-Process -Id ([int]$t) -ErrorAction Stop }catch{ exit 1 }; if($p.ProcessName -ne 'tor'){ exit 1 }; try{ $pd=$env:OC_TORDIR; if($p.Path -and (($p.Path -ieq $pd) -or ($p.Path -like ($pd+'\*')))){ exit 0 } }catch{}; exit 1" >nul 2>&1
exit /b %errorlevel%

REM - renew the Tor circuit (v2.22)
REM Restarting the Tor the launcher started is a real circuit change: every
REM new process builds new circuits from a new guard. A Tor the launcher
REM did NOT start (Tor Browser, a tor service) is never touched. A NEWNYM
REM over ControlPort is not used: the torrc here has no ControlPort.
REM exit 0 = a live Tor answers again, 1 = cannot renew.
:tor_rotate
if not defined OURTOR goto :tr_foreign
call :tor_stop
call :tor_start_if_needed
if errorlevel 1 goto :tr_fail
call :tor_wait_up
if errorlevel 1 goto :tr_fail
call :tor_ready
if errorlevel 1 goto :tr_fail
exit /b 0
:tr_foreign
echo   [!] this Tor was not started by the launcher - it cannot be renewed
echo       from here. Restart Tor Browser yourself, or pick [1] WARP / [4] NONE.
exit /b 1
:tr_fail
call :tor_log_tail
exit /b 1

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
REM v2.22: WARP+ accounts answer warp=plus, not warp=on. Both mean the
REM trace came back THROUGH WARP, so plus is normalised to on here, at the
REM single point every caller reads the flag from (:getip2, :ensure_new_ip,
REM :rotate_loop, :rotate and the manual rotation all use this value).
if /i "%GFLAG%"=="plus" set "GFLAG=on"
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
REM v2.22: the header promises a service restart after every rotation and
REM this path never did it, so the next TUI could inherit the old tunnel's
REM sockets. v2 only: v1 has no shared service.
if defined CAP_SERVICE if defined OC_CMD if defined ACTIVE_PROXY call "%OC_CMD%" service restart >nul 2>&1
if defined ACTIVE_PROXY set "SVC_PROXIED=%ACTIVE_PROXY%"
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

REM - installed desktop version: DVER from the exe's file version (v2.28)
:desktop_version
set "DVER="
set "OC_DEXE=%OC_DESKTOP%"
for /f "usebackq delims=" %%v in (`%PSX% -NoProfile -Command "try{ (Get-Item -LiteralPath $env:OC_DEXE).VersionInfo.FileVersion }catch{}"`) do if not defined DVER set "DVER=%%v"
goto :eof

REM - offer a newer desktop app, once per start, ask first (v2.28)
REM The installed version comes from the exe, the latest from the official
REM release metadata (direct, no proxy). No network or an unreadable version
REM leaves everything as it was; nothing is replaced without a Y. The silent
REM installer upgrades the app in place, so chats and settings stay.
:desktop_update_check
if defined ODUPD goto :eof
set "ODUPD=1"
if not defined OC_DESKTOP goto :eof
call :desktop_version
if not defined DVER goto :eof
call :oc_api desktop ""
if not defined OCA_VER goto :eof
set "VGT=0"
call :ver_gt "%OCA_VER%" "%DVER%"
if not "%VGT%"=="1" goto :eof
echo.
echo   OpenCode desktop update available: %DVER% -^> %OCA_VER%
echo   It closes every OpenCode process first, the app and its service included.
choice /c YN /n /m "   Update now? [Y/N]: "
REM errorlevel 0 (no stdin) and 2 (N) both skip the install.
if not errorlevel 1 goto :eof
if errorlevel 2 goto :eof
taskkill /f /im "OpenCode.exe" >nul 2>&1
taskkill /f /im "opencode-cli.exe" >nul 2>&1
timeout /t 2 /nobreak >nul 2>&1
call :install_desktop
call :find_desktop_app
call :desktop_version
if defined DVER echo   [update] OpenCode desktop now reports %DVER%
goto :eof

REM - download and silently install the official desktop app (v2.27)
:install_desktop
set "OC_DESK_SCANNED="
if "%REAL86%"=="1" goto :id_no86
call :have_exe curl.exe
set "HAVE_CURL=%HAVE%"
set "ID_ARCH=x64"
if /i "%PROCESSOR_ARCHITECTURE%"=="ARM64" set "ID_ARCH=arm64"
if /i "%PROCESSOR_ARCHITEW6432%"=="ARM64" set "ID_ARCH=arm64"
set "ID_FILE=opencode-desktop-win-%ID_ARCH%.exe"
call :oc_api desktop "%ID_FILE%"
if not defined OCA_URL goto :id_noapi
set "ID_URL=%OCA_URL%"
set "ID_EXE=%TEMP%\opencode-desktop-setup.exe"
if exist "%ID_EXE%" del /f /q "%ID_EXE%" >nul 2>&1
REM download direct: the user's own proxy variables are put back below
set "ID_HP=%HTTP_PROXY%"
set "ID_SP=%HTTPS_PROXY%"
set "HTTP_PROXY="
set "HTTPS_PROXY="
set "OC_URL=%ID_URL%"
set "OC_OUT=%ID_EXE%"
echo   downloading the OpenCode desktop installer %OCA_VER%, about 250 MB...
if "%HAVE_CURL%"=="1" goto :id_curl
"%PSX%" -NoProfile -Command "try{[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -UseBasicParsing -Uri $env:OC_URL -OutFile $env:OC_OUT}catch{}" >nul 2>&1
goto :id_check
:id_curl
curl.exe -L -f -s --max-time 900 --noproxy "*" -o "%ID_EXE%" "%ID_URL%"
if not errorlevel 1 goto :id_check
REM Direct egress failed: retry through the Windows proxy settings.
"%PSX%" -NoProfile -Command "try{[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -UseBasicParsing -Uri $env:OC_URL -OutFile $env:OC_OUT}catch{}" >nul 2>&1
:id_check
set "HTTP_PROXY=%ID_HP%"
set "HTTPS_PROXY=%ID_SP%"
set "ID_OK=0"
if exist "%ID_EXE%" for %%M in ("%ID_EXE%") do if not "%%~zM"=="" if %%~zM GTR 50000000 set "ID_OK=1"
if not "%ID_OK%"=="1" goto :id_bad
call :oc_sha "%ID_EXE%" "%OCA_SHA%"
if "%SHAOK%"=="1" goto :id_run
echo   [!] checksum mismatch - the download is not the official file.
:id_bad
echo   [!] download failed.
echo       grab it by hand and run it: %ID_URL%
echo       or from the website: https://opencode.ai/download
if exist "%ID_EXE%" del /f /q "%ID_EXE%" >nul 2>&1
goto :eof
:id_run
echo   installing, accept the UAC prompt if one appears...
set "OC_ID=%ID_EXE%"
"%PSX%" -NoProfile -Command "try{Start-Process $env:OC_ID -ArgumentList '/S' -Wait}catch{}" >nul 2>&1
del /f /q "%ID_EXE%" >nul 2>&1
goto :eof
:id_noapi
echo   [!] could not read the official release info from opencode.ai.
echo       get the installer by hand: https://opencode.ai/download
goto :eof
:id_no86
echo   [!] the desktop app has no 32-bit Windows build.
goto :eof

REM - official release metadata (v2.28)
REM usage: call :oc_api <cli|desktop> "<file name or empty>"
REM Sets OCA_VER, and for a file name also OCA_URL / OCA_SHA / OCA_SIZE. All of
REM them stay empty when the answer is missing; the call is direct (no proxy).
:oc_api
set "OCA_VER="
set "OCA_URL="
set "OCA_SHA="
set "OCA_SIZE="
set "OC_AKIND=%~1"
set "OC_AFILE=%~2"
set "OC_AOUT=%TEMP%\oc_api_%RANDOM%%RANDOM%.txt"
if exist "%OC_AOUT%" del /f /q "%OC_AOUT%" >nul 2>&1
set "KEEP_HP=%HTTP_PROXY%"
set "KEEP_SP=%HTTPS_PROXY%"
set "HTTP_PROXY="
set "HTTPS_PROXY="
"%PSX%" -NoProfile -Command "try{[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; $j=Invoke-RestMethod -Uri ($env:OC_API_BASE+'/'+$env:OC_AKIND+'/opencode/') -TimeoutSec 20; $l=[string]$j.version; if($env:OC_AFILE){ $f=$j.metadata.files.($env:OC_AFILE); if($f){ $l+='|'+$f.url+'|'+$f.sha256+'|'+$f.size } else { $l='' } }; if($l){ [IO.File]::WriteAllText($env:OC_AOUT,$l) } }catch{}" >nul 2>&1
set "HTTP_PROXY=%KEEP_HP%"
set "HTTPS_PROXY=%KEEP_SP%"
if exist "%OC_AOUT%" for /f "usebackq tokens=1-4 delims=|" %%a in ("%OC_AOUT%") do (set "OCA_VER=%%a" & set "OCA_URL=%%b" & set "OCA_SHA=%%c" & set "OCA_SIZE=%%d")
if exist "%OC_AOUT%" del /f /q "%OC_AOUT%" >nul 2>&1
goto :eof

REM - SHA-256 of a download against the published one: SHAOK=1 when they match
REM usage: call :oc_sha "<file>" "<sha256>"
:oc_sha
set "SHAOK=0"
set "OC_SF=%~1"
set "OC_SX=%~2"
if not defined OC_SX goto :eof
"%PSX%" -NoProfile -Command "try{ if((Get-FileHash -LiteralPath $env:OC_SF -Algorithm SHA256).Hash -ieq $env:OC_SX){exit 0}else{exit 1} }catch{exit 1}" >nul 2>&1
if not errorlevel 1 set "SHAOK=1"
goto :eof

REM - the official Windows CLI zip for this CPU: sets OC_AFILE
REM x64 needs AVX2; older CPUs get the -baseline build (the npm script's rule).
:oc_cli_file
set "OCARCH=x64"
if /i "%PROCESSOR_ARCHITECTURE%"=="ARM64" set "OCARCH=arm64"
if /i "%PROCESSOR_ARCHITEW6432%"=="ARM64" set "OCARCH=arm64"
set "OC_AFILE=opencode-windows-%OCARCH%.zip"
if not "%OCARCH%"=="x64" goto :eof
set "AVX2="
for /f "usebackq delims=" %%v in (`%PSX% -NoProfile -Command "try{ $t=Add-Type -MemberDefinition ('[DllImport(' + [char]34 + 'kernel32.dll' + [char]34 + ')] public static extern bool IsProcessorFeaturePresent(int f);') -Name K32 -Namespace OCW -PassThru; if($t::IsProcessorFeaturePresent(40)){ 'yes' } }catch{ 'yes' }"`) do set "AVX2=%%v"
if not defined AVX2 set "OC_AFILE=opencode-windows-x64-baseline.zip"
goto :eof

REM - locate the OpenCode desktop exe (OC_APP first, then the usual installs)
:find_desktop_app
set "OC_DESKTOP="
if defined OC_APP if exist "%OC_APP%" set "OC_DESKTOP=%OC_APP%"
if defined OC_DESKTOP goto :eof
if not defined OC_DESKTOP call :fda_try "%LOCALAPPDATA%\Programs\ai.opencode.desktop\OpenCode.exe"
if not defined OC_DESKTOP call :fda_try "%LOCALAPPDATA%\Programs\@opencode-ai\desktop\OpenCode.exe"
if not defined OC_DESKTOP call :fda_try "%LOCALAPPDATA%\Programs@opencode-aidesktop\OpenCode.exe"
if not defined OC_DESKTOP call :fda_try "%LOCALAPPDATA%\Programs\opencode-desktop\OpenCode.exe"
if not defined OC_DESKTOP call :fda_try "%LOCALAPPDATA%\Programs\opencode\OpenCode.exe"
if not defined OC_DESKTOP call :fda_try "%LOCALAPPDATA%\Programs\OpenCode\OpenCode.exe"
if not defined OC_DESKTOP call :fda_try "%LOCALAPPDATA%\ai.opencode.desktop\OpenCode.exe"
if not defined OC_DESKTOP call :fda_try "%LOCALAPPDATA%\opencode-desktop\OpenCode.exe"
if not defined OC_DESKTOP call :fda_try "%LOCALAPPDATA%\OpenCode\OpenCode.exe"
if not defined OC_DESKTOP call :fda_try "%ProgramFiles%\ai.opencode.desktop\OpenCode.exe"
if not defined OC_DESKTOP call :fda_try "%ProgramFiles%\@opencode-ai\desktop\OpenCode.exe"
if not defined OC_DESKTOP call :fda_try "%ProgramFiles%\opencode-desktop\OpenCode.exe"
if not defined OC_DESKTOP call :fda_try "%ProgramFiles%\opencode\OpenCode.exe"
if not defined OC_DESKTOP call :fda_try "%ProgramFiles%\OpenCode\OpenCode.exe"
if not defined OC_DESKTOP call :fda_try "%ProgramFiles(x86)%\opencode\OpenCode.exe"
if not defined OC_DESKTOP call :fda_try "%ProgramFiles(x86)%\OpenCode\OpenCode.exe"
if defined OC_DESKTOP goto :eof
REM Not in a known folder: ask the uninstall registry keys (read only), a running
REM OpenCode.exe and a shallow search of the usual roots. Only an exe with
REM resources\app.asar next to it counts, so the CLI opencode.exe is never taken.
REM Done once per session; :install_desktop clears the flag.
if defined OC_DESK_SCANNED goto :eof
set "OC_DESK_SCANNED=1"
for /f "usebackq delims=" %%i in (`%PSX% -NoProfile -Command "$c=@(); foreach($r in 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'){ foreach($k in @(Get-ItemProperty $r -ErrorAction SilentlyContinue)){ if($k.DisplayName -like '*opencode*'){ if($k.InstallLocation){$c+=Join-Path $k.InstallLocation 'OpenCode.exe'}; if($k.DisplayIcon){$c+=(($k.DisplayIcon -replace ',\d+$','').Trim([char]34))} } } }; foreach($p in @(Get-Process -Name OpenCode -ErrorAction SilentlyContinue)){ if($p.Path){$c+=$p.Path} }; foreach($rd in @(@($env:LOCALAPPDATA+'\Programs',3),@($env:ProgramFiles,2),@(${env:ProgramFiles(x86)},2),@($env:LOCALAPPDATA,1),@($env:APPDATA,1))){ if($rd[0] -and (Test-Path -LiteralPath $rd[0])){ foreach($f in @(Get-ChildItem -LiteralPath $rd[0] -Filter OpenCode.exe -Recurse -Depth $rd[1] -ErrorAction SilentlyContinue)){ $c+=$f.FullName } } }; foreach($x in $c){ if($x -and (Test-Path -LiteralPath $x) -and (Test-Path -LiteralPath (Join-Path (Split-Path $x) 'resources\app.asar'))){ $x; break } }"`) do if not defined OC_DESKTOP set "OC_DESKTOP=%%i"
goto :eof
:fda_try
if exist "%~1" if exist "%~dp1resources\app.asar" set "OC_DESKTOP=%~1"
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
REM v2.22: auth.json is archived (copy, size check, delete) before it is
REM removed, exactly like the database files. It used to be deleted with no
REM copy, against what the header promises.
:clear_tokens
set "CACHE_DIR=%USERPROFILE%\.cache\opencode"
if exist "%CACHE_DIR%" rmdir /s /q "%CACHE_DIR%" >nul 2>&1
if exist "%DATA_DIR%\auth.json" call :archive_auth
echo   cache and tokens cleared.
goto :eof

REM - archive auth.json into this reset's folder, verify, then delete
:archive_auth
if not defined TARGET goto :aa_nodir
if not exist "%TARGET%" mkdir "%TARGET%" >nul 2>&1
copy /y "%DATA_DIR%\auth.json" "%TARGET%\auth.json" >nul 2>&1
if errorlevel 1 goto :aa_fail
set "SZS="
set "SZD="
for %%A in ("%DATA_DIR%\auth.json") do set "SZS=%%~zA"
for %%A in ("%TARGET%\auth.json") do set "SZD=%%~zA"
if not "%SZS%"=="%SZD%" goto :aa_bad
del /f /q "%DATA_DIR%\auth.json" >nul 2>&1
echo   auth.json archived in "%TARGET%".
goto :eof
:aa_bad
del /f /q "%TARGET%\auth.json" >nul 2>&1
echo   [!] the auth.json copy did not verify - tokens are left in place.
goto :eof
:aa_fail
echo   [!] could not copy auth.json - tokens are left in place.
goto :eof
:aa_nodir
echo   [!] no archive folder for this reset - auth.json is left in place.
goto :eof

REM - hand the WARP proxy to the child process only
REM Returns errorlevel 1 when the proxy is dead; the caller decides.
REM Sets HTTP_PROXY, HTTPS_PROXY and no_proxy so that child processes use the proxy.
:export_proxy
if not defined WARP goto :eof
call :proxy_ok
if errorlevel 1 exit /b 1
REM v2.23: OpenCode (Bun) does not speak SOCKS. When only the SOCKS5 side
REM of the WARP port answers there is no proxy that can carry opencode, and
REM exporting socks5h:// just made every request fail while looking fine.
REM Report it and return 1 so the caller asks whether to go direct.
if /i not "%PROXY_KIND%"=="socks" goto :ep_http
echo   [!] the WARP port answers SOCKS5 only, and OpenCode cannot use SOCKS.
echo       WARP is up, but no usable HTTP proxy can be handed to it.
exit /b 1
:ep_http
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

REM - put the user's own proxy variables back (v2.22)
REM The launcher overwrites HTTP_PROXY / HTTPS_PROXY / no_proxy for the
REM child tree. Before v2.22 it then emptied them, which deleted values
REM that were already set system-wide or by the user's shell.
:restore_env
set "HTTP_PROXY=%OC_HP0%"
set "HTTPS_PROXY=%OC_SP0%"
set "no_proxy=%OC_NP0%"
goto :eof

REM - can the proxy actually carry an https request?
REM With curl: try the HTTP proxy, then SOCKS5. Without curl: only check
REM that the port accepts a TCP connection (the 1.5 second wait).
:proxy_ok
REM v2.22: PROXY_KIND records WHICH form answered: http, socks or tcp.
REM :export_proxy needs it to hand opencode a URL that actually works.
set "PROXY_KIND="
if not "%HAVE_CURL%"=="1" goto :proxy_ok_tcp
curl.exe -sS -o nul -f --max-time 6 --noproxy "" --proxy "%PROXY%" "%TRACE_URL%" >nul 2>&1
if not errorlevel 1 goto :pok_http
curl.exe -sS -o nul -f --max-time 6 --noproxy "" --proxy "%SOCKS_PROXY%" "%TRACE_URL%" >nul 2>&1
if not errorlevel 1 goto :pok_socks
exit /b 1
:pok_http
set "PROXY_KIND=http"
exit /b 0
:pok_socks
set "PROXY_KIND=socks"
exit /b 0

REM TCP-only check, used when curl is missing.
:proxy_ok_tcp
"%PSX%" -NoProfile -Command "try{$c=New-Object Net.Sockets.TcpClient;$a=$c.BeginConnect('127.0.0.1',%PROXY_PORT%,$null,$null);if(-not $a.AsyncWaitHandle.WaitOne(1500)){exit 1};$c.EndConnect($a);$c.Close();exit 0}catch{exit 1}" >nul 2>&1
if errorlevel 1 exit /b 1
set "PROXY_KIND=tcp"
exit /b 0

REM - can this proxy URL still carry the trace request? (v2.22)
REM usage: call :proxy_alive <url>  -> errorlevel 0 when it answers.
REM Without curl there is nothing to test with: reported alive and left to
REM the gate, which is the old behaviour.
:proxy_alive
if not "%HAVE_CURL%"=="1" exit /b 0
set "OC_PA=%~1"
if not defined OC_PA exit /b 1
curl.exe -sS -o nul -f --max-time %PROXY_PROBE_TIMEOUT% --noproxy "" --proxy "%OC_PA%" "%TRACE_URL%" >nul 2>&1
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
REM v2.23: first candidate that passed the Cloudflare trace but not the
REM (unverified) API check. Offered at the end instead of failing the mode.
set "TRACE_ONLY="
set "PLIST=%STATE_DIR%\proxy_list.txt"
if exist "%PLIST%" del /f /q "%PLIST%" >nul 2>&1
echo   [proxy] reading the proxy list...
set "PRAW=%STATE_DIR%\proxy_list_raw.txt"
if exist "%PRAW%" del /f /q "%PRAW%" >nul 2>&1
set "PSRC="
if not defined PROXY_LIST_URL goto :pfp_nolist
set "PSRC=%PROXY_LIST_URL:"=%"
if not defined PSRC goto :pfp_nolist
if /i "%PSRC:~0,7%"=="http://" goto :pfp_url
if /i "%PSRC:~0,8%"=="https://" goto :pfp_url
if /i "%PSRC:~0,6%"=="ftp://" goto :pfp_url
if /i "%PSRC:~0,7%"=="file://" goto :pfp_url
REM anything else is a local file
copy /y "%PSRC%" "%PRAW%" >nul 2>&1
goto :pfp_norm
:pfp_url
set "KEEP_HP=%HTTP_PROXY%"
set "KEEP_SP=%HTTPS_PROXY%"
set "HTTP_PROXY="
set "HTTPS_PROXY="
if "%HAVE_CURL%"=="1" goto :pfp_curl
set "OC_URL=%PSRC%"
set "OC_OUT=%PRAW%"
"%PSX%" -NoProfile -Command "try{[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -UseBasicParsing -Uri $env:OC_URL -OutFile $env:OC_OUT -TimeoutSec 20}catch{}" >nul 2>&1
goto :pfp_dl_done
:pfp_curl
curl.exe -L -f -s --max-time 20 --noproxy "*" -o "%PRAW%" "%PSRC%" >nul 2>&1
:pfp_dl_done
set "HTTP_PROXY=%KEEP_HP%"
set "HTTPS_PROXY=%KEEP_SP%"
REM v2.21: an error page is not a list: PROXY_LIST_MIN_BYTES gates downloads
REM only; a short local list of one proxy is fine.
if not exist "%PRAW%" exit /b 1
set "PLSZ=0"
for %%F in ("%PRAW%") do set "PLSZ=%%~zF"
if %PLSZ% LSS %PROXY_LIST_MIN_BYTES% exit /b 1
:pfp_norm
if not exist "%PRAW%" goto :pfp_nolist
REM Read any list format and write one http://host:port per line (v2.28).
REM The normalizer lives at the end of this file (#>>>OC_PLIST_PS).
set "OC_PRAW=%PRAW%"
set "OC_PLIST=%PLIST%"
set "PCOUNT="
for /f "usebackq delims=" %%n in (`%PSX% -NoProfile -Command "$l=Get-Content -LiteralPath $env:OCI_SELF; $i=[Array]::IndexOf($l,'#>>>OC_PLIST_PS'); $e=[Array]::IndexOf($l,'#>>>OC_ENDPLIST'); if(($i -lt 0) -or ($e -le $i)){exit 1}; Invoke-Expression (($l[($i+1)..($e-1)]) -join [Environment]::NewLine)"`) do set "PCOUNT=%%n"
if not defined PCOUNT goto :pfp_nolist
echo   [proxy] %PCOUNT% proxies in the list
goto :pfp_listok
:pfp_nolist
echo   [!] no proxies found in "%PSRC%"
exit /b 1
:pfp_listok
set /a PTRY=0
for /f "usebackq delims=" %%p in ("%PLIST%") do (
  set "CAND=%%p"
  call :pfp_count
  if errorlevel 1 goto :pfp_fail
  if not defined PSKIP call :try_one_proxy
  if not defined PSKIP if not errorlevel 1 goto :pfp_ok
)
:pfp_fail
REM v2.23: every candidate that reached Cloudflare was rejected by the
REM second check, and that check depends on PROXY_API_CHECK_URL, which is
REM not verified. Offer the first proxy that did pass the trace instead of
REM killing PROXY mode outright.
if not defined TRACE_ONLY exit /b 1
echo   [!] no proxy passed the API check, but %TRACE_ONLY% did reach Cloudflare.
echo       PROXY_API_CHECK_URL may be wrong - see the settings block.
choice /c YN /n /m "   Use that proxy anyway? [Y/N]: "
if errorlevel 2 exit /b 1
set "ACTIVE_PROXY=%TRACE_ONLY%"
echo   [proxy] live: %ACTIVE_PROXY%
exit /b 0
:pfp_ok
exit /b 0

REM - count one list attempt and enforce PROXY_TRY_MAX
REM Called from the for body so the counter is not frozen by block expansion.
REM Comment lines (# or ;) are list headers: they do not count toward the
REM cap and never spend a probe (v2.21).
:pfp_count
set "PSKIP="
set "C1=%CAND:~0,1%"
if "%C1%"=="#" exit /b 0
if "%C1%"==";" exit /b 0
REM NEW: a proxy already burned is skipped and does not spend the try cap.
if not exist "%STATE_DIR%\proxy_burned.txt" goto :pfc_count
findstr /x /i /c:"%CAND%" "%STATE_DIR%\proxy_burned.txt" >nul 2>&1 && set "PSKIP=1"
findstr /x /i /c:"http://%CAND%" "%STATE_DIR%\proxy_burned.txt" >nul 2>&1 && set "PSKIP=1"
if defined PSKIP exit /b 0
:pfc_count
set /a PTRY+=1
if %PTRY% GTR %PROXY_TRY_MAX% exit /b 1
exit /b 0

REM - test one candidate from the free list (HTTP and HTTPS proxies)
:try_one_proxy
REM CAND is "ip:port", "http://ip:port" or "https://ip:port"; a comment
REM line is skipped before anything is probed (v2.21).
set "C=%CAND%"
set "C1=%CAND:~0,1%"
if "%C1%"=="#" exit /b 1
if "%C1%"==";" exit /b 1
echo %C% | findstr /i /b "http:// https://" >nul 2>&1
if errorlevel 1 set "C=http://%C%"
echo %C% | findstr /i "socks" >nul 2>&1
if not errorlevel 1 exit /b 1
if not "%HAVE_CURL%"=="1" exit /b 1
curl.exe -sS -o nul -f --max-time %PROXY_PROBE_TIMEOUT% --noproxy "" --proxy "%C%" "%TRACE_URL%" >nul 2>&1
if errorlevel 1 exit /b 1
REM v2.23: remember the first candidate that cleared the trace, in case the
REM API check rejects everything.
if not defined TRACE_ONLY set "TRACE_ONLY=%C%"
REM v2.22: the Cloudflare trace only proves the proxy reaches Cloudflare.
REM Check the API host opencode actually calls before accepting it. No -f,
REM so any HTTP status counts: only an unreachable route fails here.
if not "%PROXY_API_CHECK%"=="1" goto :top_ok
curl.exe -sS -o nul --max-time %PROXY_PROBE_TIMEOUT% --noproxy "" --proxy "%C%" "%PROXY_API_CHECK_URL%" >nul 2>&1
if errorlevel 1 exit /b 1
:top_ok
set "ACTIVE_PROXY=%C%"
echo   [proxy] live: %ACTIVE_PROXY%
exit /b 0

REM - one launcher at a time
REM The lock is a folder: creating it succeeds only for the first launcher.
REM A lock older than 2 hours is treated as stale and removed. A newer lock
REM triggers a question: continue anyway, or exit.
REM v2.22: staleness now reads the newest of the folder timestamp, the
REM stamp file inside it, and a live TUI pid. Rewriting a file inside a
REM folder does not bump the folder mtime on NTFS, and nothing refreshed
REM it while the TUI ran, so a live launcher looked 2 h old mid-session.
:lock_check
set "LOCKDIR=%STATE_DIR%\lock"
md "%LOCKDIR%" >nul 2>&1
if not errorlevel 1 goto :lk_take
set "OC_LOCK=%LOCKDIR%"
set "OC_LTPID=%STATE_DIR%\tui.pid"
REM v2.25: closing the window with X skips :quit and used to leave a lock
REM that blocked the next start with "Another launcher seems to be running"
REM for up to 2 hours. The lock now records the cmd.exe that took it (file
REM "owner"); an owner that is gone is a stale lock whatever its age.
"%PSX%" -NoProfile -Command "try{ $of=Join-Path $env:OC_LOCK 'owner'; if(Test-Path -LiteralPath $of){ $o=(Get-Content -LiteralPath $of -ErrorAction SilentlyContinue | Select-Object -First 1); $alive=$false; if($o){ $pr=Get-Process -Id ([int]$o) -ErrorAction SilentlyContinue; if($pr -and $pr.ProcessName -eq 'cmd'){ $alive=$true } }; if(-not $alive){ Remove-Item -LiteralPath $env:OC_LOCK -Recurse -Force; exit 0 } }; $d=Get-Item -LiteralPath $env:OC_LOCK -Force; $t=$d.LastWriteTime; $sf=Join-Path $env:OC_LOCK 'stamp'; if(Test-Path -LiteralPath $sf){ $s=(Get-Item -LiteralPath $sf -Force).LastWriteTime; if($s -gt $t){ $t=$s } }; if(((Get-Date)-$t).TotalHours -le 2){ exit 1 }; $live=$false; if(Test-Path -LiteralPath $env:OC_LTPID){ $c=(Get-Content -LiteralPath $env:OC_LTPID -ErrorAction SilentlyContinue | Select-Object -First 1); if($c){ if(Get-Process -Id ([int]$c) -ErrorAction SilentlyContinue){ $live=$true } } }; if($live){ exit 1 }; Remove-Item -LiteralPath $env:OC_LOCK -Recurse -Force; exit 0 }catch{ exit 0 }" >nul 2>&1
if not errorlevel 1 goto :lk_take
echo   [!] Another OpenCode launcher seems to be running.
choice /c YN /n /m "   Continue anyway? [Y/N]: "
if errorlevel 2 goto :quit_busy
rmdir /s /q "%LOCKDIR%" >nul 2>&1
:lk_take
md "%LOCKDIR%" >nul 2>&1
call :lock_touch
set "OC_LOCK=%LOCKDIR%"
"%PSX%" -NoProfile -Command "try{ $pp=(Get-CimInstance Win32_Process -Filter ('ProcessId='+$PID)).ParentProcessId; [IO.File]::WriteAllText((Join-Path $env:OC_LOCK 'owner'),[string]$pp) }catch{}" >nul 2>&1
goto :eof
REM User chose not to continue.
REM v2.22: this used to "goto :quit" from inside a called subroutine, so
REM the caller resumed with an emptied scope and the script kept running.
REM It sets a flag and returns now; the top-level caller does the exit.
REM LOCK_FOREIGN keeps :quit from deleting a lock that is not ours.
:quit_busy
echo   Exiting.
timeout /t 2 /nobreak >nul 2>&1
set "LOCK_FOREIGN=1"
set "LOCK_BUSY=1"
set "LOCKDIR="
exit /b

REM - refresh the lock timestamp (v2.22)
REM Removing and re-creating the stamp entry is what actually bumps the
REM folder's LastWriteTime on NTFS; rewriting it does not.
:lock_touch
if not defined LOCKDIR goto :eof
if not exist "%LOCKDIR%\" goto :eof
del /f /q "%LOCKDIR%\stamp" >nul 2>&1
>"%LOCKDIR%\stamp" echo %RANDOM%%RANDOM% %DATE% %TIME%
goto :eof

REM - startup trace: one line per stage, appended to startup.log -----
REM If the launcher freezes, the last line names the stage it froze in.
:trace
if not exist "%STATE_DIR%" goto :eof
>>"%STATE_DIR%\startup.log" echo %DATE% %TIME% %*
goto :eof

REM - keep an appended log bounded (v2.20): only rewrites the file once
REM it is bigger than MAXB bytes, keeping the last KEEP lines.
REM usage: call :trim_log FILE MAXB KEEP
:trim_log
if not exist "%~1" goto :eof
set "OC_TLF=%~1"
set "OC_TMAX=%~2"
set "OC_TKEEP=%~3"
"%PSX%" -NoProfile -Command "$i=Get-Item -LiteralPath $env:OC_TLF -ErrorAction SilentlyContinue; if($i -and $i.Length -gt [long]$env:OC_TMAX){ try{ $l=@(Get-Content -LiteralPath $env:OC_TLF | Select-Object -Last ([int]$env:OC_TKEEP)); if($l.Count){ Set-Content -LiteralPath $env:OC_TLF -Value $l -Encoding ascii } }catch{} }" >nul 2>&1
goto :eof

REM - self-update: newest launcher from the GitHub repo [upd] ---------
REM Once per start, before anything interactive. Steps:
REM   1) download the raw .bat (curl, else PowerShell), 30 s cap,
REM      direct (never through the WARP proxy), HTTP errors fail;
REM   2) size gate (this script is ~135 KB; an error page is not) plus
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
REM v2.20: mirror the result into the canonical HAVE_CURL flag and use
REM only that name below - the HAVE twin used to diverge from it.
set "HAVE_CURL=%HAVE%"
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
if "%HAVE_CURL%"=="1" goto :su_curl
"%PSX%" -NoProfile -Command "try{[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -UseBasicParsing -Uri $env:SU_URL -OutFile $env:SU_TMP -TimeoutSec 30}catch{exit 1}" >nul 2>&1
if errorlevel 1 goto :su_eof
goto :su_size
:su_curl
REM v2.20: download from SU_URL - the SHA-pinned URL when the API resolved
REM it - never from UPDATE_URL (raw main); the v2.12 never-stale pin never
REM reached this curl line before.
curl.exe -L -f -s --max-time 30 --noproxy "*" -o "%SU_TMP%" "%SU_URL%" >nul 2>&1
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
REM v2.22: compare numerically, not by string equality. A repo copy that
REM is OLDER used to be offered as an "update".
set "VGT=0"
call :ver_gt "%SU_RV%" "%SU_LV%"
if "%VGT%"=="1" goto :su_new
if /i "%SU_RV%"=="%SU_LV%" goto :su_same
echo   [upd] repo copy is %SU_RV%, older than %SU_LV% - keeping this one.
goto :su_delete
:su_same
echo   [upd] launcher matches the repo, %SU_LV%.
goto :su_delete
:su_new
echo   [upd] update found: local %SU_LV% - repo %SU_RV%
choice /c YN /n /m "   Replace this launcher with %SU_RV%? [Y/N]: "
if errorlevel 2 goto :su_delete
goto :su_apply
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
REM v2.23: a "second instance" exit must never kill the Tor and the bridge
REM the other launcher is using. :tor_stop only runs for our own session,
REM and the foreign lock is left alone as well.
if defined LOCK_FOREIGN goto :quit_nolock
call :tor_stop
REM v2.22: never delete a lock that belongs to another instance the user
REM chose not to interrupt.
if exist "%STATE_DIR%\lock\" rmdir /s /q "%STATE_DIR%\lock" >nul 2>&1
:quit_nolock
REM v2.22: put the console code page back the way it was found.
if defined OC_OLDCP chcp %OC_OLDCP% >nul 2>&1
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

#>>>OC_TORBRIDGE_PS
# Built-in HTTP->SOCKS bridge (replaces Privoxy). Started hidden by
# :tor_start_if_needed; reads OC_BRPORT / OC_BRSOCKS / OC_BRLOG /
# OC_BRPIDF from the environment; logs to bridge.log; killed through
# the PID in bridge.pid by :tor_stop. Loopback only.
# The same text serves two contexts: the starter runs it once (no
# $CLIENT variable) and it becomes the accept loop; every accepted
# connection gets its own runspace seeded with $CLIENT, where the
# same text sees $CLIENT and runs Handle-Client on this one socket.
# Threadpool callbacks cannot run PowerShell functions (worker
# threads have no runspace): handlers died silently on accept and
# every CONNECT waited for the client to reset. Tunnels need both
# directions live, so the client-to-target pump gets its own small
# runspace and the target-to-client pump runs in the handler here.
# v2.20 fixes: every SOCKS reply read is exact-length (Read-Exact helper)
# so a split or refused reply never leaves stale bytes for the TLS
# handshake, and the request-head read carries an 8s timeout so a silent
# local client cannot park its handler forever. The timeout is captured
# and restored before the pumps start: idle long-lived tunnels (SSE,
# websockets) must be allowed to stay open indefinitely.
$ErrorActionPreference = 'Continue'
try { [IO.File]::WriteAllText($env:OC_BRPIDF, [string]$PID) } catch { }
function Write-BridgeLog([string]$m) {
    try { Add-Content -LiteralPath $env:OC_BRLOG -Value ((Get-Date -Format o) + ' ' + $m) -ErrorAction SilentlyContinue } catch { }
}
# reads EXACTLY $total bytes or returns $null at EOF or error. SOCKS
# replies may arrive split across TCP reads; v2.20 consumes every reply
# with exact reads so no stale byte survives next in the stream.
function Read-Exact($n, $total) {
    $out = New-Object byte[] $total
    $got = 0
    while ($got -lt $total) {
        $r = $n.Read($out, $got, $total - $got)
        if ($r -le 0) { return $null }
        $got += $r
    }
    return $out
}
function Connect-Socks([string]$hostName, [int]$port) {
    try {
        $s = New-Object Net.Sockets.TcpClient
        $s.Connect('127.0.0.1', [int]$env:OC_BRSOCKS)
        $n = $s.GetStream()
        $n.Write([byte[]](5, 1, 0), 0, 3)
        $r = Read-Exact $n 2
        if (-not $r) { $s.Close(); return $null }
        if ($r[1] -ne 0) { $s.Close(); return $null }
        $h = [Text.Encoding]::ASCII.GetBytes($hostName)
        if ($h.Length -gt 255) { $s.Close(); return $null }
        $pb = New-Object byte[] 2
        $pb[0] = [byte](($port -shr 8) -band 255)
        $pb[1] = [byte]($port -band 255)
        $req = New-Object byte[] (5 + $h.Length + 2)
        $req[0] = 5; $req[1] = 1; $req[2] = 0; $req[3] = 3; $req[4] = $h.Length
        [Array]::Copy($h, 0, $req, 5, $h.Length)
        [Array]::Copy($pb, 0, $req, 5 + $h.Length, 2)
        $n.Write($req, 0, $req.Length)
        $resp = Read-Exact $n 4
        if (-not $resp) { $s.Close(); return $null }
        if ($resp[1] -ne 0) { $s.Close(); return $null }
        # consume the exact address bytes of the reply: for ATYP=1 (IPv4)
        # the address is fixed 4 bytes, for ATYP=4 it is fixed 16 bytes,
        # and for ATYP=3 (FQDN) the FIRST byte after the header is the
        # length. Reading them in exact chunks keeps the stream clean:
        # partial or stale bytes used to be read by the TLS handshake as
        # garbage (the SEC_E_INVALID_TOKEN failure).
        if ($resp[3] -eq 1) { $skipLen = 4 }
        elseif ($resp[3] -eq 4) { $skipLen = 16 }
        elseif ($resp[3] -eq 3) { $lb = Read-Exact $n 1; if (-not $lb) { $s.Close(); return $null }; $skipLen = [int]$lb[0] }
        else { $s.Close(); return $null }
        if ($skipLen -gt 0) { $sk = Read-Exact $n $skipLen; if (-not $sk) { $s.Close(); return $null } }
        $tail = Read-Exact $n 2
        if (-not $tail) { $s.Close(); return $null }
        return $s
    } catch { return $null }
}
function Pump($from, $to) {
    try {
        $buf = New-Object byte[] 65536
        while ($true) {
            $n = $from.Read($buf, 0, $buf.Length)
            if ($n -le 0) { break }
            $to.Write($buf, 0, $n)
        }
    } catch { }
    try { $to.Close() } catch { }
    try { $from.Close() } catch { }
}
# reverse-direction pump on its own little runspace (see header note)
function Spawn-Pump($from, $to, $code) {
    try {
        $rs2 = [runspacefactory]::CreateRunspace()
        $rs2.Open()
        $rs2.SessionStateProxy.SetVariable('FROM', $from)
        $rs2.SessionStateProxy.SetVariable('TO', $to)
        $pw2 = [powershell]::Create()
        $pw2.Runspace = $rs2
        [void]$pw2.AddScript($code)
        [void]($pw2.BeginInvoke())
    } catch {
        Write-BridgeLog ('pumpspawn: ' + $_.Exception.Message)
    }
}
$PUMP_CODE = 'try{ $buf = New-Object byte[] 65536; while ($true) { $x = $FROM.Read($buf, 0, 65536); if ($x -le 0) { break }; $TO.Write($buf, 0, $x) } } catch { }; try { $TO.Close() } catch { }; try { $FROM.Close() } catch { }'
function Handle-Client($client) {
    try {
        $st = $client.GetStream()
        # v2.20: bounded head read. A silent local client (connects and
        # never speaks) used to park its handler forever; with a timeout
        # set, Read throws IOException instead, the handler closes and
        # the runspace ends. Restore the previous value before pumping:
        # idle tunnels (SSE, websockets) must be allowed to sit open.
        $headT = 0
        try { $headT = $st.ReadTimeout } catch { }
        $st.ReadTimeout = 8000
        $head = New-Object 'System.Collections.Generic.List[byte]'
        while ($head.Count -lt 16384) {
            $b = $st.ReadByte()
            if ($b -lt 0) { $client.Close(); return }
            $head.Add([byte]$b)
            if ($head.Count -ge 4 -and $head[$head.Count - 4] -eq 13 -and $head[$head.Count - 3] -eq 10 -and $head[$head.Count - 2] -eq 13 -and $head[$head.Count - 1] -eq 10) { break }
        }
        try { $st.ReadTimeout = $headT } catch { }
        $headTxt = [Text.Encoding]::ASCII.GetString($head.ToArray())
        $line = ($headTxt -split "`r`n")[0]
        # CONNECT: TLS passthrough, the request head is already consumed
        if ($line -match '^CONNECT\s+(.+):(\d+)\s') {
            $hostName = $Matches[1]
            $port = [int]$Matches[2]
            if ($hostName -match '^\[(.+)\]$') { $hostName = $Matches[1] }
            $dst = Connect-Socks $hostName $port
            if (-not $dst) { Write-BridgeLog ('CONNECT refused: ' + $line); $client.Close(); return }
            $okReply = [Text.Encoding]::ASCII.GetBytes('HTTP/1.1 200 Connection established' + "`r`n`r`n")
            $st.Write($okReply, 0, $okReply.Length)
            $cs = $dst.GetStream()
            # both directions must live at once; see the header note
            Spawn-Pump $st $cs $PUMP_CODE
            Pump $cs $st
            return
        }
        # plain HTTP with an absolute URI: rewrite it to origin form and relay
        if ($line -match '^[A-Za-z]+\s+http://([^/:]+)(:\d+)?(/.*)?\s+HTTP/') {
            $hostName = $Matches[1]
            $port = 80
            if ($Matches[2]) { $port = [int]($Matches[2].Replace(':', '')) }
            $dst = Connect-Socks $hostName $port
            if (-not $dst) { Write-BridgeLog ('request refused: ' + $line); $client.Close(); return }
            $cs = $dst.GetStream()
            $rewritten = $headTxt -replace ('http://' + $hostName + ':' + $port), ''
            $rewritten = $rewritten -replace ('http://' + $hostName), ''
            # v2.22: force "Connection: close". Only the FIRST request of a
            # keep-alive stream carries an absolute URI; the second one
            # arrived in origin form and the relay had nothing to rewrite,
            # so the tunnel answered the wrong thing. Closing after one
            # exchange keeps every request on the rewrite path.
            $rewritten = [regex]::Replace($rewritten, '(?im)^Connection\s*:.*$', 'Connection: close')
            if ($rewritten -notmatch '(?im)^Connection\s*:') {
                $rewritten = $rewritten -replace "(`r`n`r`n)", "`r`nConnection: close`r`n`r`n"
            }
            $bytes = [Text.Encoding]::ASCII.GetBytes($rewritten)
            $cs.Write($bytes, 0, $bytes.Length)
            Spawn-Pump $st $cs $PUMP_CODE
            Pump $cs $st
            return
        }
        $client.Close()
    } catch {
        Write-BridgeLog ('handler: ' + $_.Exception.Message)
    }
    try { $client.Close() } catch { }
}
if (Get-Variable -Name CLIENT -ErrorAction SilentlyContinue) {
    Handle-Client $CLIENT
    return
}
try {
    Write-BridgeLog ('bridge up: 127.0.0.1:' + $env:OC_BRPORT + ' -> socks 127.0.0.1:' + $env:OC_BRSOCKS)
    $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, [int]$env:OC_BRPORT)
    $listener.Start()
    $pool = New-Object System.Collections.ArrayList
    while ($true) {
        $client = $listener.AcceptTcpClient()
        # reap finished per-connection runspaces, then spawn this one
        $alive = New-Object System.Collections.ArrayList
        foreach ($e in $pool) {
            $pstate = $e.ps.InvocationStateInfo.State
            if (($pstate -eq 'Running') -or ($pstate -eq 'NotStarted')) { [void]$alive.Add($e) } else { try { $e.rs.Dispose() } catch { } }
        }
        $pool = $alive
        # v2.22: cap concurrent connections. Every accepted socket opened a
        # runspace with no ceiling at all, so a browser burst could spawn
        # hundreds of them. Over the cap the connection is dropped instead.
        if ($pool.Count -ge 200) {
            Write-BridgeLog ('busy: connection cap reached, dropping a client')
            try { $client.Close() } catch { }
            continue
        }
        $rs = [runspacefactory]::CreateRunspace()
        $rs.Open()
        $rs.SessionStateProxy.SetVariable('CLIENT', $client)
        $pw = [powershell]::Create()
        $pw.Runspace = $rs
        [void]$pw.AddScript($BRTEXT)
        [void]($pw.BeginInvoke())
        [void]$pool.Add(@{ ps = $pw; rs = $rs })
    }
} catch {
    Write-BridgeLog ('listener: ' + $_.Exception.Message)
}
#>>>OC_ENDTORBRIDGE
#>>>OC_PLIST_PS
# Proxy list normalizer. Reads OC_PRAW (any text: plain, CSV, JSON, NDJSON,
# XML, HTML, sorted or not, ip:port or split fields), writes OC_PLIST with one
# http://host:port per line (first-seen order, no duplicates, no SOCKS) and
# prints the count. Prints nothing when no proxy was found.
try {
  $ErrorActionPreference = 'Stop'
  $b = [IO.File]::ReadAllBytes($env:OC_PRAW)
  if ($b.Length -ge 2 -and $b[0] -eq 0xFF -and $b[1] -eq 0xFE) { $t = [Text.Encoding]::Unicode.GetString($b, 2, $b.Length - 2) }
  elseif ($b.Length -ge 2 -and $b[0] -eq 0xFE -and $b[1] -eq 0xFF) { $t = [Text.Encoding]::BigEndianUnicode.GetString($b, 2, $b.Length - 2) }
  elseif ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) { $t = [Text.Encoding]::UTF8.GetString($b, 3, $b.Length - 3) }
  else { $t = [Text.Encoding]::UTF8.GetString($b) }
  $out = New-Object 'Collections.Generic.List[string]'
  $seen = New-Object 'Collections.Generic.HashSet[string]'
  $oct = '(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)'
  $ipPat = "(?:$oct\.){3}$oct"
  $hostPat = '[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)*\.[A-Za-z]{2,}'
  $sep = '[\s,;|"'']{1,6}'
  $hostRe = New-Object Text.RegularExpressions.Regex("^($ipPat|$hostPat)$")
  $credRe = New-Object Text.RegularExpressions.Regex('^[A-Za-z0-9._~%-]+:[A-Za-z0-9._~%-]+$')

  function Add-P($scheme, $cred, $h, $p) {
    $n = 0
    if (-not [int]::TryParse([string]$p, [ref]$n)) { return }
    if ($n -lt 1 -or $n -gt 65535) { return }
    $h = ([string]$h).Trim().ToLower()
    if (-not $hostRe.IsMatch($h)) { return }
    $s = ([string]$scheme).ToLower()
    if ($s -like 'socks*') { return }
    if ($s -ne 'https') { $s = 'http' }
    $u = ''
    if ($cred) {
      if (-not $credRe.IsMatch($cred)) { return }
      $u = $cred + '@'
    }
    if ($seen.Add($s + '://' + $u + $h + ':' + $n)) { $out.Add($s + '://' + $u + $h + ':' + $n) }
  }

  # Free text: scheme://user:pass@host:port, host:port, then "ip<sep>port"
  # (CSV, tables, tabs) and "port<sep>ip". A line that names socks is skipped
  # unless it carries an explicit http(s):// proxy.
  function Scan-Text([string]$s) {
    $s = $s -replace '<[^>]+>', ' ' -replace '&nbsp;|&#160;', ' '
    $re = "(?i)(?<![\w.@-])(?:(https?|socks[45]h?)://)?(?:([A-Za-z0-9._~%-]+:[A-Za-z0-9._~%-]+)@)?($ipPat|$hostPat):(\d{1,5})(?!\d)"
    $reB = "(?<![\d.])($ipPat)$sep(\d{2,5})(?![\d.A-Za-z])"
    $reC = "(?<![\d.])(\d{2,5})$sep($ipPat)(?![\d.])"
    $evA = [Text.RegularExpressions.MatchEvaluator]{
      param($m)
      $isIp = $m.Groups[3].Value -match "^$ipPat$"
      if ($isIp -or $m.Groups[1].Success -or $script:curLine -eq $m.Value) { Add-P $m.Groups[1].Value $m.Groups[2].Value $m.Groups[3].Value $m.Groups[4].Value; return ' ' }
      return $m.Value
    }
    $evB = [Text.RegularExpressions.MatchEvaluator]{ param($m) Add-P 'http' '' $m.Groups[1].Value $m.Groups[2].Value; return ' ' }
    $evC = [Text.RegularExpressions.MatchEvaluator]{ param($m) Add-P 'http' '' $m.Groups[2].Value $m.Groups[1].Value; return ' ' }
    foreach ($line in ($s -split '\r?\n')) {
      $line = $line.Trim()
      if (-not $line -or $line.StartsWith('#') -or $line.StartsWith(';')) { continue }
      $script:curLine = $line
      $rest = [regex]::Replace($line, $re, $evA)
      if ($rest -match '(?i)socks') { continue }
      $rest = [regex]::Replace($rest, $reB, $evB)
      [void][regex]::Replace($rest, $reC, $evC)
    }
  }

  $hostKeys = @('ip', 'ip_address', 'ipaddress', 'host', 'hostname', 'address', 'proxy_address', 'proxy_ip', 'proxyip', 'server')
  $portKeys = @('port', 'proxy_port', 'proxyport')
  $typeKeys = @('protocol', 'protocols', 'type', 'scheme', 'proxy_type', 'proxytype')
  function Pick($pairs, $keys) {
    foreach ($k in $keys) { foreach ($pr in $pairs) { if ($pr.Key -ieq $k -and $null -ne $pr.Value -and "$($pr.Value)" -ne '') { return $pr.Value } } }
    return $null
  }
  # one record = a flat list of @{Key;Value} pairs (JSON object or XML element)
  function Add-Record($pairs) {
    $h = Pick $pairs $hostKeys; $p = Pick $pairs $portKeys
    if ($null -eq $h -or $null -eq $p -or "$h" -match ':\d+$') { return $false }
    $ty = ''
    $tv = Pick $pairs $typeKeys
    if ($null -ne $tv) { foreach ($x in @($tv)) { $ty += " $x" } }
    if ($ty -match '(?i)socks' -and $ty -notmatch '(?i)http') { return $true }
    $us = Pick $pairs @('username', 'user'); $pw = Pick $pairs @('password', 'pass')
    $cred = ''
    if ($us -and $pw) { $cred = "$us`:$pw" }
    Add-P 'http' $cred $h $p
    return $true
  }
  $recKeys = $hostKeys + $portKeys + $typeKeys
  function Walk-Json($o) {
    if ($null -eq $o) { return }
    if ($o -is [string]) { Scan-Text $o; return }
    if ($o -is [System.Management.Automation.PSCustomObject]) {
      $pairs = @(); $flat = @()
      foreach ($pr in $o.PSObject.Properties) {
        $e = @{ Key = $pr.Name; Value = $pr.Value }
        $pairs += $e
        if ($pr.Value -isnot [System.Management.Automation.PSCustomObject]) { $flat += $e }
      }
      $used = Add-Record $flat
      foreach ($pr in $pairs) {
        $v = $pr.Value
        if ($v -is [string]) { if (-not ($used -and ($recKeys -contains $pr.Key))) { Scan-Text $v } }
        elseif ($v -is [System.Management.Automation.PSCustomObject] -or $v -is [array]) { Walk-Json $v }
      }
      return
    }
    if ($o -is [System.Collections.IEnumerable]) { foreach ($x in $o) { Walk-Json $x } }
  }
  function Walk-Xml($n) {
    if ($n.NodeType -ne 'Element') { return }
    $kids = @(); $pairs = @()
    foreach ($a in $n.Attributes) { $pairs += @{ Key = $a.Name; Value = $a.Value } }
    foreach ($k in $n.ChildNodes) {
      if ($k.NodeType -eq 'Element') {
        $kids += $k
        $leaf = $true
        foreach ($g in $k.ChildNodes) { if ($g.NodeType -eq 'Element') { $leaf = $false; break } }
        if ($leaf) { $pairs += @{ Key = $k.Name; Value = $k.InnerText } }
      }
    }
    [void](Add-Record $pairs)
    if ($kids.Count -eq 0) { Scan-Text $n.InnerText; return }
    foreach ($k in $kids) { Walk-Xml $k }
  }

  $tt = $t.TrimStart()
  if ($tt.StartsWith('{') -or $tt.StartsWith('[')) {
    $j = $null
    try { $j = $tt | ConvertFrom-Json } catch { $j = $null }
    if ($null -ne $j) { Walk-Json $j }
    else {
      foreach ($line in ($tt -split '\r?\n')) {
        $l = $line.Trim().TrimEnd(',')
        if ($l.StartsWith('{') -or $l.StartsWith('[')) { try { Walk-Json ($l | ConvertFrom-Json) } catch { } }
      }
    }
  }
  elseif ($tt.StartsWith('<')) {
    try { $x = New-Object Xml.XmlDocument; $x.LoadXml($tt); Walk-Xml $x.DocumentElement } catch { }
  }
  if ($out.Count -eq 0) { Scan-Text $t }
  if ($out.Count -gt 0) {
    [IO.File]::WriteAllLines($env:OC_PLIST, $out.ToArray(), (New-Object Text.UTF8Encoding($false)))
    Write-Output $out.Count
  }
} catch { }
#>>>OC_ENDPLIST

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
