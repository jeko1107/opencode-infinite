@echo off
setlocal EnableExtensions
title OpenCode-Infinite
REM ============================================================
REM  OpenCode launcher  (v2.30)
REM  Multi-egress (WARP / TOR / free HTTP) + dependency bootstrap
REM  + auto-resume.
REM  v2.22 - v2.29: every fixed bug carries an inline "REM v2.2x:"
REM  note.
REM
REM  Usage:
REM    double-click                          -> folder menu
REM    drag a folder onto this file          -> opens in that folder
REM    "OpenCode Infinite.bat" "D:\work\project"
REM                                          -> opens in that folder
REM    --run [opencode args]                 -> quick start with the saved
REM                                             connection (the "opencode"
REM                                             command and the shortcut)
REM    opencodeinf                           -> the menu (after setup)
REM    --verify / --renew                    -> hidden checks run by the UI
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
REM Automatic rotation hunt (see :auto_rotate). AUTO_ROTATE=0 leaves it to the menu.
set "AUTO_ROTATE=1"
REM Target of the hunt: a country code and/or an IP prefix. Both empty = any new IP.
set "TARGET_COUNTRY="
set "TARGET_PREFIX="
set "TARGET_TRIES=10"
set "TARGET_MINUTES=15"
set "TARGET_INTERVAL=15"
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
REM v2.29: the activity log. Every part of the launcher appends to launcher.log
REM (see :log); the UI can bundle it into a support report with personal data
REM removed. LOG_MAX_KB bounds the file; LOG_MASK_IP is read by the report.
set "LOG_ENABLED=1"
set "LOG_MAX_KB=1024"
set "LOG_MASK_IP=1"
REM v2.30: what happens when opencode closes: ask (R/M/Q, default) or quit (see Settings).
set "ON_CLOSE=ask"

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
set "TOR_DIR=%LOCALAPPDATA%\opencode-infinite\tor"
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
REM v2.30: own state folder, named after the launcher and not after OpenCode.
set "STATE_DIR=%LOCALAPPDATA%\opencode-infinite"
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

REM v2.29: settings saved by the UI (config.json -> config.env) override the
REM defaults above, and the opencode command added by setup (STATE_DIR\bin) is
REM taken out of PATH for this process so the launcher never finds its own shim.
if not defined OC_SID set "OC_SID=%RANDOM%%RANDOM%"
if exist "%STATE_DIR%\config.json" call :cfg_refresh
call :cfg_import
call set "PATH=%%PATH:%STATE_DIR%\bin;=%%"
call set "PATH=%%PATH:;%STATE_DIR%\bin=%%"

REM Validate the numeric settings: invalid values fall back to defaults.
call :numcfg ROTATE_TRIES_MAX 4
call :numcfg WARP_WAIT 6
call :numcfg ROTATE_COOLDOWN 10
call :numcfg TARGET_TRIES 10
call :numcfg TARGET_MINUTES 15
call :numcfg0 TARGET_INTERVAL 15
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
call :numcfg LOG_MAX_KB 1024

REM Create the state folder if it is missing, then check the single-instance lock.
if not exist "%STATE_DIR%" mkdir "%STATE_DIR%" >nul 2>&1
REM Fresh trace for this run: the last line names the stage that froze.
if exist "%STATE_DIR%\startup.log" del /f /q "%STATE_DIR%\startup.log" >nul 2>&1
REM v2.20: bound wcli.log too (it only grows on warp-cli failures, but a
REM dying daemon can fail for weeks - keep the last 400 lines above 200 KB)
call :trim_log "%STATE_DIR%\wcli.log" 200000 400
set /a LOG_MAXB=LOG_MAX_KB*1024
set /a LOG_KEEP=LOG_MAX_KB*8
if exist "%STATE_DIR%\launcher.log" for %%L in ("%STATE_DIR%\launcher.log") do if %%~zL GTR %LOG_MAXB% call :trim_log "%STATE_DIR%\launcher.log" %LOG_MAXB% %LOG_KEEP%
set "LOG_ARGS=%*"
if defined LOG_ARGS set "LOG_ARGS=%LOG_ARGS:"='%"
set "LOG_OSV="
for /f "tokens=*" %%v in ('ver') do if not defined LOG_OSV set "LOG_OSV=%%v"
call :log "start v2.30 args=[%LOG_ARGS%] cwd=%CD% arch=%PROCESSOR_ARCHITECTURE% %LOG_OSV%" boot
REM v2.30: one official copy. Setup copies this file to STATE_DIR\app and the opencode
REM command runs that copy. A duplicate (a second download, "(1)") hands over to it, or
REM replaces it when it is the newer one.
set "OFFICIAL=%STATE_DIR%\app\OpenCode Infinite.bat"
if /i "%~f0"=="%OFFICIAL%" goto :official_ok
if not exist "%OFFICIAL%" goto :official_ok
call :launcher_ver "%~f0" RUNVER
call :launcher_ver "%OFFICIAL%" OFFVER
if not defined RUNVER goto :official_ok
if not defined OFFVER goto :official_ok
call :ver_gt "%RUNVER%" "%OFFVER%"
if "%VGT%"=="1" (
    copy /y "%~f0" "%OFFICIAL%" >nul 2>&1
    call :log "official copy replaced by this newer launcher" boot
    goto :official_ok
)
echo   This copy is not the official one. Starting the official copy:
echo   %OFFICIAL%
call "%OFFICIAL%" %*
exit /b %errorlevel%
:official_ok
if /i "%~1"=="--verify" goto :verify_mode
if /i "%~1"=="--renew" goto :renew_mode
call :lock_check
REM v2.22: :lock_check no longer jumps to :quit from inside a called
REM subroutine (that returned to this caller with an emptied scope). It
REM sets LOCK_BUSY and returns; the exit happens here, at top level.
if defined LOCK_BUSY goto :quit

REM Once per start: check the repo for a newer launcher. Silent when
REM nothing to do or offline; asks before ever replacing this file.
if "%UPDATE_CHECK%"=="1" call :self_update

REM ============================================================
REM  00) HOME SCREEN (v2.29) and quick start
REM ============================================================
REM The UI lives at the end of this file (#>>>OC_TUI_PS). Launch continues to
REM the menus below; Exit leaves; no usable console falls back to them too.
REM --run is what the "opencode" command and the shortcut call: it skips every
REM menu and starts opencode in the current folder with the saved connection.
set "AUTO_RUN="
set "RUNARGS="
if /i "%~1"=="--run" goto :auto_run
if not "%~1"=="" goto :mode_menu
:home_start
call :tui home
set "TUIRC=%errorlevel%"
call :log "ui home rc=%TUIRC%" ui
set "TUI_PROBED=1"
if not "%TUIRC%"=="20" set "TUI_OK=1"
call :cfg_import
if "%TUIRC%"=="0" goto :quit
goto :mode_menu

:auto_run
set "AUTO_RUN=1"
REM shortcut: the arguments are split on spaces when they reach opencode, so
REM a quoted argument with spaces is not kept whole - use the full launcher then.
set "RUNARGS=%*"
set "RUNARGS=%RUNARGS:*--run=%"
set "APP_MODE=CLI"
set "OPFOLDER=%CD%"
goto :folder_ok

REM ============================================================
REM  0) APP MODE: CLI (terminal TUI) or the desktop app
REM ============================================================
REM v2.26: new. APP_MODE=CLI keeps the whole flow as it was. APP_MODE=DESKTOP launches
REM the OpenCode desktop exe through the same egress, and restarts it after
REM every rotation (there is no CLI chat to resume). OC_APP overrides the exe.
:mode_menu
if defined MODE_FORCE_ASK goto :mode_show
if /i not "%OC_MODE_DEFAULT%"=="CLI" goto :mode_chk_d
set "APP_MODE=CLI"
goto :mode_done
:mode_chk_d
if /i not "%OC_MODE_DEFAULT%"=="DESKTOP" goto :mode_show
call :find_desktop_app
if not defined OC_DESKTOP goto :mode_show
goto :mode_desktop_ok
:mode_show
call :find_desktop_app
call :tui_init
if not defined TUI_OK goto :mode_old
call :tui mode
set "TUIRC=%errorlevel%"
if "%TUIRC%"=="20" goto :mode_old
if "%TUIRC%"=="2" goto :mode_desktop
if "%TUIRC%"=="1" goto :mode_cli
goto :quit
:mode_cli
set "APP_MODE=CLI"
goto :mode_done
:mode_old
cls
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
call :pick 123 "Pick: "
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
echo %C_WARN%  [!] OpenCode desktop not found.%C_RST%
call :yn "   Download and install it now? [Y/N]: "
if errorlevel 100 goto :quit
if errorlevel 2 goto :mode_menu
call :install_desktop
call :find_desktop_app
if defined OC_DESKTOP goto :mode_desktop_ok
echo %C_WARN%  [!] still not found - set OC_APP to its OpenCode.exe.%C_RST%
call :pause_key
goto :mode_menu
:mode_desktop_ok
set "APP_MODE=DESKTOP"
echo.
echo   [app] DESKTOP "%OC_DESKTOP%"
call :desktop_update_check
:mode_done
call :log "run mode %APP_MODE%" menu
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
set "OPFOLDER="
set "LASTPATH="
if exist "%LASTFOLDER%" set /p LASTPATH=<"%LASTFOLDER%"
if defined LASTPATH set "LASTPATH=%LASTPATH:"=%"
if defined LASTPATH if not exist "%LASTPATH%\" set "LASTPATH="
call :tui_init
if not defined TUI_OK goto :folder_old
set "OC_LASTPATH=%LASTPATH%"
set "OC_CWD=%CD%"
call :tui folder
set "TUIRC=%errorlevel%"
if "%TUIRC%"=="20" goto :folder_old
if "%TUIRC%"=="1" goto :folder_1
if "%TUIRC%"=="2" goto :use_current
if "%TUIRC%"=="3" goto :pick_folder
goto :quit
:folder_old
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
call :pick 1234 "Pick: "
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
call :yn "   Try again? [Y/N]: "
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
title OpenCode-Infinite
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
if /i "%OC_EGRESS_DEFAULT%"=="WARP" goto :egress_cfg
if /i "%OC_EGRESS_DEFAULT%"=="TOR" goto :egress_cfg
if /i "%OC_EGRESS_DEFAULT%"=="PROXY" goto :egress_cfg
if /i "%OC_EGRESS_DEFAULT%"=="NONE" goto :egress_cfg
goto :egress_ask
:egress_cfg
set "EGRESS=%OC_EGRESS_DEFAULT%"
set "ACTIVE_PROXY="
set "WARP="
if /i "%EGRESS%"=="TOR" set "ACTIVE_PROXY=http://127.0.0.1:%TOR_HTTP_PORT%"
if /i "%EGRESS%"=="TOR" set "TOR_TRIES=0"
echo   [egress] %EGRESS% ^(from your settings^)
goto :egress_done
:egress_ask
call :tui_init
if not defined TUI_OK goto :egress_old
set "OC_H_FOLDER=%CD%"
call :tui egress
set "TUIRC=%errorlevel%"
if "%TUIRC%"=="20" goto :egress_old
if %TUIRC% LSS 1 goto :quit
if %TUIRC% GTR 4 goto :quit
cmd /c exit %TUIRC%
goto :egress_pick
:egress_old
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
call :pick 1234 "Pick egress: "
:egress_pick
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

echo %C_WARN%  [!] Cloudflare WARP not found - IP rotation will be disabled.%C_RST%
echo       Install it later from 1.1.1.1 if you want the rotation.
echo.
REM Offer the install. Answering N continues without rotation.
call :yn "   Try to download and install WARP now? [Y/N]: "
if errorlevel 2 goto :check_opencode
call :install_warp
call :find_warp
if defined WARP goto :warp_ready
echo %C_WARN%  [!] WARP still not available - continuing without rotation.%C_RST%
echo       warp-cli errors, if any, are in %STATE_DIR%\wcli.log
goto :check_opencode

REM Message shown on 32-bit systems, then continue without WARP.
:no_warp_32
echo %C_WARN%  [!] Cloudflare WARP publishes 64-bit Windows builds only.%C_RST%
echo       On this 32-bit system rotation is disabled.
goto :check_opencode

REM WARP was installed or found: confirm and continue.
:warp_ready
echo %C_OK%  [ok] WARP ready.%C_RST%

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
  echo %C_OK%  [ok] opencode ready.%C_RST%
  goto :ready
)
REM The install failed: show a manual link and stop.
echo %C_ERR%  ERROR: opencode install failed or is not on PATH.%C_RST%
echo   Get it by hand: https://github.com/sst/opencode/releases
call :pause_key
goto :quit

REM Both dependencies are ready. Probe what this CLI build supports,
REM then a short pause before the menu.
:ready
call :detect_caps
call :log "opencode: %OC_CMD% version=%OC_VER% service=%CAP_SERVICE% standalone=%CAP_STANDALONE%" deps
call :oc_update_check
call :trace ready
if not defined AUTO_RUN goto :ready_menu
set "COLD=0"
goto :run
:ready_menu
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
call :tui_init
if not defined TUI_OK goto :menu_hdr_old
cls
echo   Preparing the connection...
goto :menu_work
:menu_hdr_old
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

:menu_work
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
if not defined TUI_OK goto :menu_old_list
set "OC_H_FOLDER=%CD%"
set "OC_H_EGRESS=%EGRESS%"
set "OC_H_MODE=%APP_MODE%"
set "OC_H_PROXY=%ACTIVE_PROXY%"
set "OC_H_WARP="
if /i "%EGRESS%"=="WARP" set "OC_H_WARP=%WARP%"
if /i "%EGRESS%"=="WARP" if not defined WARP set "OC_H_WARP=none - rotation disabled"
set "OC_H_VER=%OC_VER%"
set "OC_H_IP=%IP%"
call :tui main
set "TUIRC=%errorlevel%"
if "%TUIRC%"=="20" set "TUI_OK="
if "%TUIRC%"=="20" goto :menu_loop
if %TUIRC% GTR 8 goto :menu_loop
cmd /c exit %TUIRC%
goto :menu_dispatch
:menu_old_list
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
echo   [8] Settings      - change any launcher setting, applied right away
echo.
echo   One key, no Enter.
echo.
REM Read the menu choice. Highest number is checked first.
call :pick 12345678 "Pick: "
:menu_dispatch
REM choice exits 0 on Ctrl+C: quit cleanly (v2.30), never guess option 1.
REM v2.25: with stdin closed (piped input, EOF) choice answers 255, not 0, and
REM 255 satisfies every "if errorlevel N" below, so the old guard looped here
REM forever through the token-reset prompt. No console to ask: leave.
if errorlevel 100 goto :quit
if not errorlevel 1 goto :quit
REM NEW: 7 is checked first (highest number first).
if errorlevel 8 goto :menu_settings
if errorlevel 7 goto :run_soft
if errorlevel 6 goto :quit
if errorlevel 5 goto :run_deep
if errorlevel 4 goto :menu_opt4
if errorlevel 3 goto :rotate
if errorlevel 2 goto :run_warm
goto :run_cold

REM Option 8: the settings screens; WARP_UP=0 re-applies the proxy port on the
REM next pass. Values that a running service cannot change say so in the UI.
:menu_settings
call :tui settings
call :cfg_import
set "WARP_UP=0"
goto :menu_loop

REM Option 4: the desktop app has no folder step, so it switches mode instead.
:menu_opt4
if /i "%APP_MODE%"=="DESKTOP" set "MODE_FORCE_ASK=1"
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
call :yn "  Do that now? [Y/N] "
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
call :yn "  Do that now? [Y/N] "
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
    echo %C_WARN%  [!] WARP proxy is not answering - rotation has no effect.%C_RST%
    echo       Going direct would run opencode on your real IP.
    call :yn "   Continue without WARP? [Y/N]: "
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
echo %C_WARN%  [!] Tor did not get ready.%C_RST%
call :yn "   Continue direct? [Y/N]: "
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
echo %C_WARN%  [!] no working free proxy found.%C_RST%
call :yn "   Continue direct? [Y/N]: "
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
if defined RUNARGS set "FLAGS=%FLAGS% %RUNARGS%"
set "RUNARGS="

REM Start the watcher, open the TUI, and stop the watcher when it closes.
call :watch_start
call :log "starting opencode: %OC_CMD% mode=%APP_MODE% egress=%EGRESS% cold=%COLD% continue=%FLAGS%" run
set "EC="
call :launch
REM v2.22: the TUI exit code is taken right after the launch. :launch stores
REM it in EC itself and the fallback read covers a build where it did not.
REM The old capture sat after :watch_stop, whose taskkill overwrote
REM errorlevel, so a crashed TUI was reported as a clean exit.
if not defined EC set "EC=%errorlevel%"
call :log "opencode exited code %EC% egress=%EGRESS%" run
call :watch_stop
REM v2.22: restore the user's own proxy variables instead of deleting them.
call :restore_env
REM v2.22: the watcher can flag a dead proxy/tunnel while the TUI is open
REM (WARP/TOR/PROXY). It never kills the TUI; the note is shown here.
if not exist "%STATE_DIR%\proxy_warn.txt" goto :run_warn_done
echo.
echo %C_WARN%  [!] the egress proxy stopped answering while OpenCode was open:%C_RST%
echo       %STATE_DIR%\proxy_warn.txt
>"%STATE_DIR%\renew_needed.txt" echo the egress proxy stopped answering
call :log "the egress proxy stopped answering while opencode was open" rotate
del /f /q "%STATE_DIR%\proxy_warn.txt" >nul 2>&1
:run_warn_done
echo.

REM the watcher firing outranks the exit code: a killed TUI exits
REM nonzero, but the marker tells us WHY and where to go.
REM If the watcher left a hit marker, it killed the TUI because of a fatal error.
if not exist "%STATE_DIR%\watch_hit.txt" goto :run_no_hit
del /f /q "%STATE_DIR%\watch_hit.txt" >nul 2>&1
echo %C_WARN%  [watch] a fatal error cut the chat - rotating and resuming it.%C_RST%
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

REM Normal close: R/M/Q, or quit at once when ON_CLOSE=quit.
:closed
echo OpenCode closed.
if /i "%ON_CLOSE%"=="quit" goto :quit
if /i "%EGRESS%"=="NONE" goto :menu_loop
if /i "%EGRESS%"=="WARP" if not defined WARP goto :menu_loop
echo.
echo   R = new IP and resume the chat   M = menu   Q = quit (Ctrl+C also quits)
REM v2.30: no timeout and no default: the prompt waits for a deliberate key.
call :flush_keys
call :pick RMQ "Pick: "
if errorlevel 3 goto :quit
if errorlevel 2 goto :menu_loop
if errorlevel 1 (
    set "WHY=stop"
    goto :quota_rotate
)
REM errorlevel 0 is Ctrl+C
goto :quit

REM v2.30: drops the keys already waiting in the console. Keys typed inside opencode,
REM and the terminal's replies to its queries (a cursor report ends in R), would pick
REM an option at the prompt. The wait lets the late replies arrive first.
:flush_keys
"%PSX%" -NoProfile -Command "try { for ($i = 0; $i -lt 2; $i++) { Start-Sleep -Milliseconds 300; while ([Console]::KeyAvailable) { [void][Console]::ReadKey($true) } } } catch { }" >nul 2>&1
exit /b 0

REM v2.30: one key, no Enter, read by PowerShell instead of choice. Ctrl+C reaches
REM PowerShell as a key, so cmd never raises its "Terminate batch job" prompt.
REM usage: call :pick KEYS "prompt" [seconds default_index]. Result in errorlevel:
REM 1-based index of the key, 0 = Ctrl+C, 255 = no console (stdin closed).
:pick
<nul set /p "=%~2"
set "OC_KEYS=%~1"
set "OC_TMO=%~3"
set "OC_DEF=%~4"
"%PSX%" -NoProfile -Command "$prev=$null; try{ $prev=[Console]::TreatControlCAsInput; [Console]::TreatControlCAsInput=$true; $k=$env:OC_KEYS.ToUpper(); $dl=$null; if($env:OC_TMO){ $dl=(Get-Date).AddSeconds([int]$env:OC_TMO) }; $rc=255; while($true){ if($dl -and -not [Console]::KeyAvailable){ if((Get-Date) -gt $dl){ $rc=[int]$env:OC_DEF; break }; Start-Sleep -Milliseconds 80; continue }; $ki=[Console]::ReadKey($true); if($ki.Key -eq 'C' -and ($ki.Modifiers -band [ConsoleModifiers]::Control)){ $rc=0; break }; $i=$k.IndexOf($ki.KeyChar.ToString().ToUpper()); if($i -ge 0){ $rc=$i+1; break } }; [Console]::TreatControlCAsInput=$prev; exit $rc }catch{ try{ [Console]::TreatControlCAsInput=$prev }catch{}; exit 255 }" 
set "PKRC=%errorlevel%"
echo.
exit /b %PKRC%

REM v2.30: "Press any key" for pause. Ctrl+C here is only a key, it does not quit.
:pause_key
echo Press any key to continue . . .
"%PSX%" -NoProfile -Command "$prev=$null; try{ $prev=[Console]::TreatControlCAsInput; [Console]::TreatControlCAsInput=$true; [void][Console]::ReadKey($true); [Console]::TreatControlCAsInput=$prev }catch{ try{ [Console]::TreatControlCAsInput=$prev }catch{} }" >nul 2>&1
echo.
exit /b 0

REM v2.30: launcher version of a copy, from its header line "(v2.30)". Result in %2.
:launcher_ver
set "%~2="
for /f "tokens=2 delims=()" %%v in ('findstr /b /c:"REM  OpenCode launcher  (v" "%~1" 2^>nul') do set "%~2=%%v"
exit /b 0


REM opencode exited with a nonzero code and the watcher did not catch it.
:exit_rotate
set "WHY=exit"

REM Common exit path for the egress retry. WHY is one of: exit, quota, stop, watcher.
REM Only the message for the current WHY value is shown.
:quota_rotate
call :log "rotating: reason=%WHY% egress=%EGRESS% opencode-exit=%EC%" rotate
if "%WHY%"=="exit" echo %C_WARN%OpenCode exited with code %EC%.%C_RST%
if "%WHY%"=="quota" echo %C_WARN%Free quota reached on this egress.%C_RST%
if "%WHY%"=="stop" echo Reopening on a new egress.
if "%WHY%"=="watcher" echo %C_WARN%Fatal error caught by the watcher - switching egress.%C_RST%

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
echo %C_OK%  [tor] new circuit - resuming.%C_RST%
set "RESUME=1"
set "COLD=0"
goto :resume_and_run
:tor_rotate_fail
echo %C_WARN%  [!] Tor could not be renewed - back to menu.%C_RST%
call :pause_key
goto :menu_loop
:tor_exhausted
echo %C_WARN%  [!] Tor could not get a usable circuit after %ROTATE_TRIES_MAX% attempts.%C_RST%
echo       The exit node may be blocked: try a new identity in Tor, or
echo       switch to [1] WARP. warp/tor notes: "%TOR_DIR%\tor.log"
set /a TOR_TRIES=0
>"%STATE_DIR%\renew_needed.txt" echo Tor could not get a usable circuit
call :log "Tor could not get a usable circuit" rotate
call :pause_key
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
echo %C_WARN%  [!] no free proxy is left that still works ^(they all hit the limit^).%C_RST%
echo       Free proxies are shared by many people, so their limit is often used up.
call :yn "   Switch to Tor and keep going? [Y/N]: "
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
>"%STATE_DIR%\renew_needed.txt" echo no free proxy still works
call :log "no free proxy still works" rotate
set "PROXY_ROT=0"
call :pause_key
goto :menu_loop
:qr_after_tor
if /i "%EGRESS%"=="NONE" goto :menu_loop
if not defined WARP goto :menu_loop
REM R at the closed prompt (WHY=stop) is an explicit request: it always rotates.
if "%AUTO_ROTATE%"=="0" if not "%WHY%"=="stop" (
    echo   Automatic rotation is off - the menu decides.
    goto :menu_loop
)
echo Getting a new IP before the next attempt...
timeout /t 3 /nobreak >nul 2>&1

REM ============================================================
REM  3b) ROTATION + PROBE + RESUME
REM ============================================================
REM Automatic rotation: a hunt for an IP that matches the target. TARGET_COUNTRY
REM and TARGET_PREFIX are both checked; both empty = any new IP. The hunt stops on
REM a match, the attempt cap (TARGET_TRIES), the time cap (TARGET_MINUTES), the
REM burned-IP cap (IP_FIND_MAX), or Esc / Q at the wait (Ctrl+C quits).
REM ROTATE_TRIES counts the registrations of this hunt, probe misses included.
:auto_rotate
set /a ROTATE_TRIES=0
set /a PROBE_TRIES=0
set "PBROKEN=0"
set "HUNT_SEEN="
set "HUNT_GOAL=a new IP"
if defined TARGET_PREFIX set "HUNT_GOAL=prefix %TARGET_PREFIX%"
if defined TARGET_COUNTRY set "HUNT_GOAL=country %TARGET_COUNTRY%"
if defined TARGET_COUNTRY if defined TARGET_PREFIX set "HUNT_GOAL=country %TARGET_COUNTRY% and prefix %TARGET_PREFIX%"
set /a HUNT_LIM=TARGET_MINUTES*60
call :nowsecs
set "HUNT_START=%NOWS%"
call :flush_keys
echo   [i] hunting for %HUNT_GOAL%: up to %TARGET_TRIES% attempts, %TARGET_MINUTES% min. Esc or Q stops.
:rotate_loop
if %ROTATE_TRIES% GEQ %TARGET_TRIES% (
    set "HUNT_WHY=tries"
    goto :rotate_fail
)
REM Space the attempts out: a plain burst of "registration new" is what
REM Cloudflare throttles. The wait is cancellable.
if %ROTATE_TRIES% GTR 0 (
    if %TARGET_INTERVAL% GTR 0 (
        call :napkey %TARGET_INTERVAL%
        if errorlevel 2 goto :quit
        if errorlevel 1 goto :hunt_stop
    )
)
call :hunt_clock
if %HUNT_EL% GEQ %HUNT_LIM% (
    set "HUNT_WHY=time"
    goto :rotate_fail
)
set /a ROTATE_TRIES+=1
REM Drop the current WARP connection and its registration.
echo [%ROTATE_TRIES%/%TARGET_TRIES%] dropping the old registration...
call :reg_drop
REM A new registration gets a new exit IP from Cloudflare.
echo [%ROTATE_TRIES%/%TARGET_TRIES%] new registration...
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
REM An IP already judged in this hunt does not count again.
echo ;%HUNT_SEEN%;| findstr /l /c:";%IPN%;" >nul
if not errorlevel 1 (
    echo [%ROTATE_TRIES%] %IPN% was already tried in this hunt, rotating again
    goto :rotate_loop
)
set "HUNT_SEEN=%HUNT_SEEN%;%IPN%;"
call :target_ok
set /a HUNT_LEFT=TARGET_TRIES-ROTATE_TRIES
echo [%ROTATE_TRIES%/%TARGET_TRIES%] exit IP %IPN% ^(country %GLOC%^), target %TMATCHTXT%, %HUNT_LEFT% attempt(s) left
if "%TMATCH%"=="0" goto :rotate_loop

REM probe: one cheap message on the throwaway session. burned IP ->
REM rotate again. With PROBE=0 the probe is skipped and the IP is accepted directly.
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
echo %C_WARN%  [!] probe failed for a reason that is NOT a limit - attempt %PBROKEN% of %PROBE_BROKEN_MAX%. Last output:%C_RST%
call :probe_print
if %PBROKEN% GEQ %PROBE_BROKEN_MAX% goto :probe_broken_stop
goto :rotate_loop
:probe_miss_burned
REM The probe hit the limit on this fresh IP: the IP is burned. The attempt
REM still counts toward the hunt's cap; burned IPs have their own cap.
set "PBROKEN=0"
set /a PROBE_TRIES+=1
REM IP_FIND_MAX=0 means no limit on burned IPs. Otherwise stop after the limit.
if "%IP_FIND_MAX%"=="0" goto :probe_endless
if %PROBE_TRIES% GTR %IP_FIND_MAX% goto :probe_exhausted
:probe_endless
echo [%PROBE_TRIES%] IP already burned, rotating again...
goto :rotate_loop
:probe_exhausted
echo.
echo %C_WARN%  [!] %PROBE_TRIES% IPs probed, every one of them already burned.%C_RST%
set "HUNT_WHY=burned"
goto :rotate_fail
:probe_broken_stop
echo.
echo %C_WARN%  [!] the probe failed %PBROKEN% times and none of them was a limit error.%C_RST%
echo       The probe itself is broken, not every IP: a retired PROBE_MODEL id,
echo       an auth error or a CLI change. Rotation cannot fix that.
echo       Check PROBE_MODEL in the settings block, or run the probe model once
echo       by hand to see the real error.
call :yn "   Continue WITHOUT the probe this session (IPs accepted untested)? [Y/N]: "
if errorlevel 2 goto :pbs_quit
echo   [i] probe off for this session - IPs are accepted on WARP-trace proof
echo       only, and the resume's own limit check keeps catching burned ones.
set "PROBE=0"
set "PBROKEN=0"
goto :rotate_loop
:pbs_quit
call "%OC_CMD%" session delete %OC_PROBE_ID% >nul 2>&1
call :pause_key
goto :menu_loop

REM v2.22 (defensive, unverified against real CLI behaviour): nothing here
REM creates the fixed probe session, so a build that REFUSES an unknown
REM "-s <id>" would fail the probe for every IP. That must never read as
REM "all IPs burned": the probe is switched off for this session, the
REM current IP is kept, and the reason is printed in plain text.
:probe_no_session
echo.
echo %C_WARN%  [!] the probe session "%OC_PROBE_ID%" does not exist and this%C_RST%
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
echo %C_OK%[%ROTATE_TRIES%] IP %IPN% works.%C_RST%
set "HUNT_WHY=success"
call :hunt_summary
call :log "rotation ok: new IP verified on try %ROTATE_TRIES%" rotate
if exist "%STATE_DIR%\renew_needed.txt" del /f /q "%STATE_DIR%\renew_needed.txt" >nul 2>&1
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

REM The hunt is over without a usable IP: summary, then the menu.
:rotate_fail
call :hunt_summary
goto :rotate_pause
:rotate_pause
REM never leave the probe session behind as the last session
call "%OC_CMD%" session delete %OC_PROBE_ID% >nul 2>&1
echo %C_WARN%  [!] no usable IP from this hunt. warp-cli errors, if any, are in %STATE_DIR%\wcli.log%C_RST%
>"%STATE_DIR%\renew_needed.txt" echo rotation hunt ended: %HUNT_WHY%
call :log "ROTATION HUNT ENDED (%HUNT_WHY%), see wcli.log" rotate
call :pause_key
goto :menu_loop

REM Esc or Q during the wait: stop the hunt and go to the menu. Chat not resumed.
:hunt_stop
set "HUNT_WHY=user"
call :hunt_summary
call "%OC_CMD%" session delete %OC_PROBE_ID% >nul 2>&1
goto :menu_loop

REM The summary of a hunt. HUNT_WHY says how it ended.
:hunt_summary
call :hunt_clock
echo.
if "%HUNT_WHY%"=="success" echo %C_OK%  [OK] target reached: %HUNT_GOAL%, IP %IPN%, attempt %ROTATE_TRIES% of %TARGET_TRIES%, %HUNT_EL% s.%C_RST%
if "%HUNT_WHY%"=="tries" echo %C_WARN%  [!] attempt limit reached: %TARGET_TRIES% attempts, no match for %HUNT_GOAL%. Last IP %IPN%.%C_RST%
if "%HUNT_WHY%"=="time" echo %C_WARN%  [!] time limit reached: %TARGET_MINUTES% min, %ROTATE_TRIES% attempts, no match for %HUNT_GOAL%.%C_RST%
if "%HUNT_WHY%"=="burned" echo %C_WARN%  [!] stopped: every probed IP was burned ^(IP_FIND_MAX^).%C_RST%
if "%HUNT_WHY%"=="user" echo   [i] stopped by you after %ROTATE_TRIES% attempts, %HUNT_EL% s. Last IP %IPN%.
exit /b 0

REM Seconds since midnight in NOWS. The time string has a leading space before 10 o'clock.
:nowsecs
set "NT=%TIME: =0%"
set /a NOWS=(1%NT:~0,2%-100)*3600+(1%NT:~3,2%-100)*60+(1%NT:~6,2%-100)
exit /b 0

REM Seconds since the hunt started in HUNT_EL. Midnight wraps.
:hunt_clock
call :nowsecs
set /a HUNT_EL=NOWS-HUNT_START
if %HUNT_EL% LSS 0 set /a HUNT_EL+=86400
exit /b 0

REM TMATCH=1 when the trace country and IP prefix match the target (empty = no test).
:target_ok
set "TMATCH=1"
set "TMATCHTXT=yes"
if not defined GLOC set "GLOC=?"
if defined TARGET_COUNTRY if /i not "%GLOC%"=="%TARGET_COUNTRY%" set "TMATCH=0"
if defined TARGET_PREFIX (
    echo %IPN%| findstr /b /l /c:"%TARGET_PREFIX%" >nul
    if errorlevel 1 set "TMATCH=0"
)
if "%TMATCH%"=="0" set "TMATCHTXT=no"
exit /b 0

REM Waits the given seconds, reading keys: Esc or Q exits 1 (stop the hunt), Ctrl+C exits 2
REM (quit). No console (piped run): plain sleep, exit 0.
:napkey
set "NK_SECS=%~1"
"%PSX%" -NoProfile -Command "$rc = 0; $old = $false; try { $old = [Console]::TreatControlCAsInput; [Console]::TreatControlCAsInput = $true; $end = (Get-Date).AddSeconds([int]$env:NK_SECS); while ((Get-Date) -lt $end) { if ([Console]::KeyAvailable) { $k = [Console]::ReadKey($true); if ($k.Key -eq 'Escape' -or $k.Key -eq 'Q') { $rc = 1; break }; if ($k.Key -eq 'C' -and ($k.Modifiers -band [ConsoleModifiers]::Control) -ne 0) { $rc = 2; break } }; Start-Sleep -Milliseconds 200 } } catch { Start-Sleep -Seconds ([int]$env:NK_SECS) } finally { try { [Console]::TreatControlCAsInput = $old } catch { } }; exit $rc" >nul 2>&1
exit /b %errorlevel%

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
    echo %C_WARN%  [!] proxy dead - retrying on the current egress instead of resuming.%C_RST%
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
call :log "resume finished code %REC%" resume
REM v2.22: restore the user's own proxy variables instead of deleting them.
call :restore_env
REM 124 is the watchdog code: the resume was killed for taking too long.
if "%REC%"=="124" (
    echo %C_WARN%  [!] no answer in %RESUME_TIMEOUT%s - this exit IP is dead.%C_RST%
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
echo %C_OK%  chat resumed on the new IP.%C_RST%
REM v2.23: a good resume clears the circuit counter. Without this TOR_TRIES
REM accumulated for the whole session and four clean renewals in a row sent
REM the fifth to the menu.
set /a TOR_TRIES=0
set "PROXY_ROT=0"
goto :run
REM The resume hit a limit: go back to the rotation with WHY=quota.
:resume_fatal
echo %C_WARN%  [!] the resume itself hit a limit - rotating again.%C_RST%
call :resume_tail
set "WHY=quota"
goto :quota_rotate

REM Option 3: rotate only, without opening opencode. Shows the result and waits.
:rotate
if /i "%EGRESS%"=="NONE" (
  echo.
  echo   Egress is NONE - nothing to rotate.
  call :pause_key
  goto :menu_loop
)
if /i "%EGRESS%"=="TOR" (
  echo.
  if defined OURTOR (
    echo   Restarting the launcher-managed Tor for a new circuit...
    REM v2.22: one call does the whole renewal, log-aware on failure.
    call :tor_rotate
    if errorlevel 1 echo %C_WARN%  [!] the new circuit did not come up - see "%TOR_DIR%\tor.log".%C_RST%
    if not errorlevel 1 echo   New circuit: Tor is serving on :%TOR_HTTP_PORT% again.
    call :pause_key
    goto :menu_loop
  )
  REM v2.22: a Tor this launcher did not start cannot be renewed from here.
  echo   TOR mode - this Tor was started outside the launcher.
  echo   Restart it yourself for a new circuit, or pick [1] WARP / [4] NONE.
  echo   Current bridge: http://127.0.0.1:%TOR_HTTP_PORT%
  call :pause_key
  goto :menu_loop
)
if /i "%EGRESS%"=="PROXY" (
  echo.
  echo   Picking a new free HTTP proxy...
  call :pick_free_proxy
  if errorlevel 1 (
    echo %C_WARN%  [!] no working free proxy found.%C_RST%
  ) else (
    echo   New proxy: %ACTIVE_PROXY%
  )
  call :pause_key
  goto :menu_loop
)
REM WARP path
if not defined WARP (
  echo.
  echo WARP is not available - nothing to rotate.
  call :pause_key
  goto :menu_loop
)
echo.
echo Requesting a new WARP registration...
call :reg_drop
call :reg_new
if "%REGNEW%"=="0" echo %C_WARN%  [!] the WARP daemon refused a new registration - see "%STATE_DIR%\wcli.log"%C_RST%
call :warp_up
set "WARP_UP=1"
echo waiting %WARP_WAIT%s...
timeout /t %WARP_WAIT% /nobreak >nul 2>&1
call :getip2 IPN WFLAG
if defined IPN if "%WFLAG%"=="on" goto :rotate_ok
REM Explain why the rotation failed: no answer or tunnel down.
echo %C_WARN%  [!] no verified WARP IP.%C_RST%
if defined IPN if not "%WFLAG%"=="on" echo       the trace answered but warp=off - the tunnel is not up.
if not defined IPN echo       no trace answer - the proxy on port %PROXY_PORT% is down.
echo       warp-cli errors land in %STATE_DIR%\wcli.log
call :pause_key
goto :menu_loop
REM Rotation succeeded. Report whether the IP changed or stayed the same.
:rotate_ok
if /i not "%IPN%"=="%IP%" goto :rotate_new
echo   same IP as before: %IPN%
goto :rotate_done
:rotate_new
echo %C_OK%  New exit IP: %IPN% ^(WARP verified^)%C_RST%
>"%STATE_DIR%\lastip.txt" echo %IPN%
set "IP=%IPN%"
:rotate_done
echo.
call :pause_key
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
call :ui_reset
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
call :ui_apply
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
if not "%WCLIRC%"=="0" if not defined WCLI_QUIET call :log "warp-cli %WCMD% failed rc=%WCLIRC%" wcli
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
echo %C_WARN%  [!] download failed.%C_RST%
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
  echo %C_OK%  [ok] opencode ready on 32-bit via npm.%C_RST%
  goto :eof
)
echo %C_ERR%  ERROR: opencode could not be installed on 32-bit Windows.%C_RST%
echo          Install 32-bit node.js by hand from nodejs.org, then run:
echo          npm i -g opencode-ai
call :pause_key
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
echo %C_WARN%  [!] could not read the official release info from opencode.ai.%C_RST%
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
echo %C_WARN%    [!] checksum mismatch - the download is not the official file.%C_RST%
:sa_bad
echo %C_WARN%    [!] download failed.%C_RST%
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
if exist "%OCBIN%\opencode.exe" echo %C_OK%  [ok] installed to %OCBIN%%C_RST%
goto :eof

REM - the one-line install trail: every hop a channel attempt makes is
REM written here, so a VM that refuses to install gives the reason.
:olog
>>"%STATE_DIR%\install.log" echo [%DATE% %TIME%] %~1
call :log "%~1" install
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
if "%HAVE%"=="0" echo %C_WARN%  [!] node.js is still not available - install the 32-bit build from nodejs.org.%C_RST%
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
if defined AUTO_RUN goto :eof
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
call :log "update check: opencode installed %OCUPD_CUR% latest %OCUPD_LAT%" update
set "VGT=0"
call :ver_gt "%OCUPD_LAT%" "%OCUPD_CUR%"
if not "%VGT%"=="1" goto :eof
echo.
echo   opencode update available: %OCUPD_CUR% -^> %OCUPD_LAT%
echo   It closes every running opencode process first.
call :yn "   Update now? [Y/N]: "
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
if defined OC_VER echo %C_OK%  [update] opencode now reports %OC_VER%%C_RST%
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
echo %C_WARN%  [!] "%OC_CMD%" reports %OC_VER% but this machine has a v2 database.%C_RST%
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
echo %C_WARN%  [!] WARP registration missing - creating a new one.%C_RST%
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
echo %C_WARN%  [!] Tor did not become ready - the reason is in "%TOR_DIR%\tor.log"%C_RST%
call :tor_log_tail
exit /b 1
:tg_missing
echo %C_WARN%  [!] the Tor download did not land. Grab it by hand:%C_RST%
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
echo %C_OK%  [tor] ready: SOCKS :%TOR_SOCKS_PORT% - HTTP :%TOR_HTTP_PORT%.%C_RST%
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
echo %C_WARN%  [!] the Tor bundle did not download.%C_RST%
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
  echo %C_OK%  [ok] Tor installed - portable - in "%TOR_DIR%".%C_RST%
) else (
  echo %C_WARN%  [!] the bundle unpacked but tor.exe was not found in "%TOR_DIR%".%C_RST%
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
  echo %C_WARN%  [!] tor could not be started - see "%OC_TORERR%" and "%OC_TORLOG%".%C_RST%
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
set "GLOC="
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
for /f "tokens=2 delims==" %%l in ('findstr /b "loc=" "%TFILE%"') do set "GLOC=%%l"
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
call :log "update check: desktop installed %DVER% latest %OCA_VER%" update
set "VGT=0"
call :ver_gt "%OCA_VER%" "%DVER%"
if not "%VGT%"=="1" goto :eof
echo.
echo   OpenCode desktop update available: %DVER% -^> %OCA_VER%
echo   It closes every OpenCode process first, the app and its service included.
call :yn "   Update now? [Y/N]: "
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

REM - the activity log (v2.29): usage call :log "message" source
REM One line per event in launcher.log: time, session id (shared with the hidden
REM child runs and the UI), source, message. Delayed expansion keeps &, | and >
REM in a message from running as commands; keep quotes out of the message.
:log
if "%LOG_ENABLED%"=="0" goto :eof
if not exist "%STATE_DIR%" goto :eof
setlocal EnableDelayedExpansion
set "LM=%~1"
>>"%STATE_DIR%\launcher.log" echo [%DATE% %TIME%] [%OC_SID%] [%~2] !LM!
endlocal
goto :eof

REM - the UI (v2.29): usage "call :tui home|settings|export"; exit code 0 = leave,
REM 10 = continue, 20 = no usable console. The script is read out of this file.
:tui
set "OC_TUI=%~1"
set "OC_STATE=%STATE_DIR%"
"%PSX%" -NoProfile -Command "$l=Get-Content -LiteralPath $env:OCI_SELF; $i=[Array]::IndexOf($l,'#>>>OC_TUI_PS'); $e=[Array]::IndexOf($l,'#>>>OC_ENDTUI'); if(($i -lt 0) -or ($e -le $i)){exit 20}; Invoke-Expression (($l[($i+1)..($e-1)]) -join [Environment]::NewLine)"
set "TUIX=%errorlevel%"
if not "%~1"=="probe" call :log "ui %~1 -> %TUIX%" ui
if not "%~1"=="probe" call :ui_apply
exit /b %TUIX%

REM - does a usable console exist for the interface? sets TUI_OK once per run
:tui_init
if defined TUI_PROBED goto :eof
set "TUI_PROBED=1"
call :tui probe
if "%errorlevel%"=="0" set "TUI_OK=1"
goto :eof

REM - yes/no in the interface style: errorlevel 1 = yes, 2 = no, like choice /c yn.
REM Anything else (Ctrl+C) counts as no. No usable console falls back to choice.
REM usage: call :yn "question [Y/N]" [seconds until the default answer, No]
:yn
call :tui_init
if not defined TUI_OK goto :yn_old
set "OC_Q=%~1"
set "OC_QT=%~2"
call :tui confirm
set "TUIRC=%errorlevel%"
set "OC_QT="
if "%TUIRC%"=="20" goto :yn_old
if "%TUIRC%"=="1" exit /b 1
exit /b 2
:yn_old
if "%~2"=="" call :pick yn "%~1 "
if not "%~2"=="" call :pick yn "%~1 " %~2 2
exit /b %errorlevel%

REM - colors for the launcher's own lines (v2.29): the same theme as the interface.
REM ui.env (written by the interface from a real console) says whether the console
REM understands ANSI colors and which accent the theme uses. The accent becomes the
REM default text color, so every plain line follows the theme; warnings, errors and
REM successes get yellow, red and green. Nothing is printed when colors are off.
:ui_style
set "C_RST="
set "C_OFF="
set "C_ACC="
set "C_OK="
set "C_ERR="
set "C_WARN="
set "C_DIM="
if not "%UI_COLOR%"=="1" goto :eof
if not defined ESC for /f "tokens=1,2 delims=#" %%a in ('"prompt #$H#$E# & echo on & for %%b in (1) do rem"') do set "ESC=%%b"
if not defined ESC goto :eof
set "C_OFF=%ESC%[0m"
set "C_OK=%ESC%[32m"
set "C_ERR=%ESC%[31m"
set "C_WARN=%ESC%[33m"
set "C_DIM=%ESC%[90m"
if defined UI_ACC if not "%UI_ACC%"=="0" set "C_ACC=%ESC%[%UI_ACC%m"
set "C_RST=%C_OFF%%C_ACC%"
goto :eof

REM - make the theme accent the current text color / put the console back to normal
:ui_apply
if defined C_ACC <nul set /p "=%C_ACC%"
goto :eof
:ui_reset
if defined C_OFF <nul set /p "=%C_OFF%"
goto :eof

REM - validate config.json and rewrite config.env (hand edits are checked here)
:cfg_refresh
call :tui export
goto :eof

REM - load config.env into this process; derived values follow the port
:cfg_import
if exist "%STATE_DIR%\ui.env" for /f "usebackq tokens=1* delims==" %%a in ("%STATE_DIR%\ui.env") do set "%%a=%%b"
call :ui_style
if not exist "%STATE_DIR%\config.env" goto :eof
for /f "usebackq tokens=1* delims==" %%a in ("%STATE_DIR%\config.env") do set "%%a=%%b"
set "PROXY=http://127.0.0.1:%PROXY_PORT%"
set "SOCKS_PROXY=socks5h://127.0.0.1:%PROXY_PORT%"
goto :eof

REM - --verify: does the saved connection work? exit 0 = yes. Run hidden by setup.
:verify_mode
set "UI_COLOR=0"
call :ui_style
call :have_exe curl.exe
set "HAVE_CURL=%HAVE%"
set "EGRESS=%OC_EGRESS_DEFAULT%"
if /i "%EGRESS%"=="ASK" set "EGRESS=WARP"
echo [verify] egress: %EGRESS%
call :log "verify start egress=%EGRESS%" verify
if /i "%EGRESS%"=="NONE" goto :vm_none
if /i "%EGRESS%"=="TOR" goto :vm_tor
if /i "%EGRESS%"=="PROXY" goto :vm_proxy
call :find_warp
if not defined WARP goto :vm_nowarp
call :warp_up
call :getip2 IPN WFLAG
echo [verify] ip=%IPN% warp=%WFLAG%
if defined IPN if "%WFLAG%"=="on" exit /b 0
exit /b 1
:vm_nowarp
echo [verify] Cloudflare WARP is not installed ^(warp-cli not found^).
exit /b 2
:vm_tor
call :tor_gate
set "VMRC=%errorlevel%"
call :tor_stop
exit /b %VMRC%
:vm_proxy
call :pick_free_proxy
exit /b %errorlevel%
:vm_none
curl.exe -s -f --max-time 10 --noproxy "*" -o nul "%TRACE_URL%"
exit /b %errorlevel%

REM - --renew: close opencode, archive and clear the saved tokens, get a new
REM egress. Run hidden by the UI after it asked; exit 0 = renewed.
:renew_mode
set "UI_COLOR=0"
call :ui_style
call :have_exe curl.exe
set "HAVE_CURL=%HAVE%"
set "EGRESS=%OC_EGRESS_DEFAULT%"
if /i "%EGRESS%"=="ASK" set "EGRESS=WARP"
echo [renew] egress: %EGRESS%
call :log "renew start egress=%EGRESS%" renew
call :find_opencode
call :detect_caps
call :stop_opencode
call :soft_target
call :clear_tokens
if /i "%EGRESS%"=="NONE" goto :rm_done
if /i "%EGRESS%"=="TOR" goto :rm_tor
if /i "%EGRESS%"=="PROXY" goto :rm_proxy
call :find_warp
if not defined WARP goto :rm_nowarp
set /a RM_TRY=0
:rm_warp_loop
set /a RM_TRY+=1
if %RM_TRY% GTR %ROTATE_TRIES_MAX% goto :rm_fail
if %RM_TRY% GTR 1 timeout /t %ROTATE_COOLDOWN% /nobreak >nul 2>&1
call :reg_drop
call :reg_new
call :warp_up
timeout /t %WARP_WAIT% /nobreak >nul 2>&1
call :getip2 IPN WFLAG
if not defined IPN goto :rm_warp_loop
if not "%WFLAG%"=="on" goto :rm_warp_loop
echo [renew] new exit IP: %IPN%
>"%STATE_DIR%\lastip.txt" echo %IPN%
goto :rm_done
:rm_nowarp
echo [renew] Cloudflare WARP is not installed ^(warp-cli not found^).
exit /b 2
:rm_tor
call :tor_gate
if errorlevel 1 goto :rm_fail
call :tor_rotate
set "RMRC=%errorlevel%"
call :tor_stop
if not "%RMRC%"=="0" goto :rm_fail
goto :rm_done
:rm_proxy
if exist "%STATE_DIR%\proxy_burned.txt" del /f /q "%STATE_DIR%\proxy_burned.txt" >nul 2>&1
call :pick_free_proxy
if errorlevel 1 goto :rm_fail
echo [renew] proxy: %ACTIVE_PROXY%
:rm_done
if exist "%STATE_DIR%\renew_needed.txt" del /f /q "%STATE_DIR%\renew_needed.txt" >nul 2>&1
echo [renew] done
exit /b 0
:rm_fail
echo [renew] could not get a working connection
exit /b 1

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
call :yn "   Use that proxy anyway? [Y/N]: "
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
"%PSX%" -NoProfile -Command "try{ $of=Join-Path $env:OC_LOCK 'owner'; if(Test-Path -LiteralPath $of){ $o=(Get-Content -LiteralPath $of -ErrorAction SilentlyContinue | Select-Object -First 1); $alive=$false; if($o){ $pr=Get-Process -Id ([int]$o) -ErrorAction SilentlyContinue; if($pr -and $pr.ProcessName -eq 'cmd' -and ((Get-CimInstance Win32_Process -Filter ('ProcessId='+$pr.Id)).CommandLine -match '\.bat')){ $alive=$true } }; if(-not $alive){ Remove-Item -LiteralPath $env:OC_LOCK -Recurse -Force; exit 0 } }; $d=Get-Item -LiteralPath $env:OC_LOCK -Force; $t=$d.LastWriteTime; $sf=Join-Path $env:OC_LOCK 'stamp'; if(Test-Path -LiteralPath $sf){ $s=(Get-Item -LiteralPath $sf -Force).LastWriteTime; if($s -gt $t){ $t=$s } }; if(((Get-Date)-$t).TotalHours -le 2){ exit 1 }; $live=$false; if(Test-Path -LiteralPath $env:OC_LTPID){ $c=(Get-Content -LiteralPath $env:OC_LTPID -ErrorAction SilentlyContinue | Select-Object -First 1); if($c){ if(Get-Process -Id ([int]$c) -ErrorAction SilentlyContinue){ $live=$true } } }; if($live){ exit 1 }; Remove-Item -LiteralPath $env:OC_LOCK -Recurse -Force; exit 0 }catch{ exit 0 }" >nul 2>&1
if not errorlevel 1 goto :lk_take
echo   [!] OpenCode-Infinite is already open in another window.
call :focus_owner
if errorlevel 1 (echo   Could not bring it to the front. Switch to that window yourself.) else (echo   Brought the open window to the front.)
goto :quit_busy
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

REM v2.30: brings the window of the launcher that owns the lock to the front. Its
REM console window first (classic console); under Windows Terminal that handle is
REM hidden, so the WindowsTerminal window above the owner is used instead. Exit 0 = done.
REM Limit: Windows Terminal has one window for all tabs, so the right tab is not picked.
:focus_owner
set "OC_LOCK=%LOCKDIR%"
"%PSX%" -NoProfile -Command "try{ $o=[int](Get-Content -LiteralPath (Join-Path $env:OC_LOCK 'owner') | Select-Object -First 1); Add-Type -Namespace OcFocus -Name W -MemberDefinition '[DllImport(\"user32.dll\")] public static extern bool ShowWindow(IntPtr h, int c); [DllImport(\"user32.dll\")] public static extern bool SetForegroundWindow(IntPtr h); [DllImport(\"user32.dll\")] public static extern bool IsWindowVisible(IntPtr h); [DllImport(\"user32.dll\")] public static extern void keybd_event(byte k, byte s, uint f, UIntPtr e); [DllImport(\"kernel32.dll\")] public static extern bool FreeConsole(); [DllImport(\"kernel32.dll\")] public static extern bool AttachConsole(uint p); [DllImport(\"kernel32.dll\")] public static extern IntPtr GetConsoleWindow();'; $hw=[IntPtr]::Zero; [void][OcFocus.W]::FreeConsole(); if([OcFocus.W]::AttachConsole([uint32]$o)){ $hw=[OcFocus.W]::GetConsoleWindow(); [void][OcFocus.W]::FreeConsole() }; if($hw -eq [IntPtr]::Zero -or -not [OcFocus.W]::IsWindowVisible($hw)){ $hw=[IntPtr]::Zero; $cur=$o; for($i=0; $i -lt 6 -and $cur; $i++){ $pr=Get-Process -Id $cur -ErrorAction SilentlyContinue; if($pr -and $pr.ProcessName -eq 'WindowsTerminal' -and $pr.MainWindowHandle -ne 0){ $hw=$pr.MainWindowHandle; break }; $cur=(Get-CimInstance Win32_Process -Filter ('ProcessId='+$cur)).ParentProcessId } }; if($hw -eq [IntPtr]::Zero){ exit 1 }; [void][OcFocus.W]::ShowWindow($hw, 9); [OcFocus.W]::keybd_event(18, 0, 0, [UIntPtr]::Zero); [OcFocus.W]::keybd_event(18, 0, 2, [UIntPtr]::Zero); if([OcFocus.W]::SetForegroundWindow($hw)){ exit 0 }; exit 1 }catch{ exit 1 }" >nul 2>&1
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
set "TRM=%*"
set "TRM=%TRM:"='%"
call :log "%TRM%" trace
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
call :yn "   Replace this launcher with %SU_RV%? [Y/N]: "
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
call :pause_key
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
call :log "quit" boot
call :ui_reset
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
REM v2.30: a double-click (no args, started by explorer) closes the window when the
REM batch ends. --run (shim and shortcut) keeps its own window; this keeps the rest.
if /i "%~1"=="--run" goto :main_end
REM A typed command has no /c in its command line, so nothing below runs for it. Explorer,
REM PowerShell and other shells start a bat with /c; only then :keep_open checks who started it.
set "OC_CL=%CMDCMDLINE%"
if "%OC_CL:/c=%"=="%OC_CL%" goto :main_end
call :keep_open
:main_end

REM ============================================================
REM  Embedded folder picker (PowerShell). :run_picker reads this
REM  file from the marker line down and runs the block with
REM  PowerShell; the batch body ends at exit /b and never reads
REM  these lines. OC_MODE=modern opens the Explorer-style
REM  IFileDialog picker; classic opens FolderBrowserDialog. Both
REM  print the chosen folder on stdout and print nothing on
exit /b

REM v2.30: waits for a key only when explorer started this window (double-click).
:keep_open
"%PSX%" -NoProfile -Command "$p=(Get-CimInstance Win32_Process -Filter ('ProcessId='+$PID)).ParentProcessId; $c=(Get-CimInstance Win32_Process -Filter ('ProcessId='+$p)).ParentProcessId; if ((Get-Process -Id $c -ErrorAction SilentlyContinue).ProcessName -eq 'explorer') { exit 0 } exit 1" >nul 2>&1
if errorlevel 1 exit /b 0
echo.
echo   Press any key to close this window.
call :pause_key
exit /b 0

REM ============================================================

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
#>>>OC_TUI_PS
# OpenCode Infinite UI (v2.29): home screen, settings, setup wizard, renew, uninstall.
# Modes (OC_TUI): home | settings | export. In: OC_STATE (state folder), OCI_SELF (launcher).
# Exit codes: 0 leave the launcher, 10 continue to the launcher, 20 no usable console.
# Test hooks: OC_TUI_KEYS (comma list of keys, or OC_TUI_KEYS_<MODE> per screen), OC_TUI_INPUT (; list of typed lines),
# OC_TUI_CHILD_EXIT (skip the child launcher, pretend it exited with this code).
$ErrorActionPreference = 'Stop'
$State = $env:OC_STATE
$Self = $env:OCI_SELF
$Mode = $env:OC_TUI
$CfgPath = Join-Path $State 'config.json'
$EnvPath = Join-Path $State 'config.env'
$BackDir = Join-Path $State 'backup'
$ShimDir = Join-Path $State 'bin'
$ShimPath = Join-Path $ShimDir 'opencode.cmd'
$ShimInfPath = Join-Path $ShimDir 'opencodeinf.cmd'
# v2.30: setup copies the launcher here; the commands and shortcuts run this copy, not the download.
$Official = Join-Path $State 'app\OpenCode Infinite.bat'
$RawUrl = 'https://raw.githubusercontent.com/jeko1107/opencode-infinite/main/OpenCode%%20Infinite.bat'
$Repo = 'https://github.com/jeko1107/opencode-infinite'
# OC_TUI_KEYS_<MODE> (for example OC_TUI_KEYS_MAIN) overrides OC_TUI_KEYS for that screen only, so a whole
# launcher run can be driven screen by screen.
$keySrc = [Environment]::GetEnvironmentVariable('OC_TUI_KEYS_' + ([string]$Mode).ToUpper())
if (-not $keySrc) { $keySrc = $env:OC_TUI_KEYS }
if ($keySrc -and $keySrc.Contains('|')) {
  # "a,b|c,d": one key list per call of this screen, the last one repeats (test hook)
  $parts = @($keySrc -split '\|')
  $cf = Join-Path $State ('seq_' + $Mode + '.n')
  $ci = 0
  try { if (Test-Path -LiteralPath $cf) { $ci = [int](Get-Content -LiteralPath $cf -TotalCount 1) } } catch { }
  try { New-Item -ItemType Directory -Force -Path $State | Out-Null; Set-Content -LiteralPath $cf -Value ($ci + 1) } catch { }
  $keySrc = $parts[[Math]::Min($ci, $parts.Count - 1)]
}
$Scripted = [bool]$keySrc
$KeyQ = New-Object 'Collections.Generic.Queue[string]'
if ($keySrc) { foreach ($k in ($keySrc -split ',')) { if ($k) { $KeyQ.Enqueue($k) } } }
$InQ = New-Object 'Collections.Generic.Queue[string]'
if ($null -ne $env:OC_TUI_INPUT) { foreach ($k in ($env:OC_TUI_INPUT -split ';')) { $InQ.Enqueue($k) } }
$esc = [string][char]27
function Log([string]$msg, [string]$src = 'ui') {
  try {
    if ($script:Cfg -and $script:Cfg.settings.ContainsKey('LOG_ENABLED') -and [int]$script:Cfg.settings['LOG_ENABLED'] -eq 0) { return }
    New-Item -ItemType Directory -Force -Path $State | Out-Null
    $sid = $env:OC_SID; if (-not $sid) { $sid = '-' }
    $line = '[' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.ff') + '] [' + $sid + '] [' + $src + '] ' + ($msg -replace '[\r\n]+', ' | ')
    [IO.File]::AppendAllText((Join-Path $State 'launcher.log'), $line + "`r`n", (New-Object Text.UTF8Encoding($false)))
  } catch { }
}

# ---------------------------------------------------------------- settings schema
function S($k, $g, $l, $t, $d, $h, $a = 'now', $min = 0, $max = 0, $vals = @()) {
  [pscustomobject]@{ Key = $k; Group = $g; Label = $l; Type = $t; Default = $d; Help = $h; Apply = $a; Min = $min; Max = $max; Values = $vals }
}
$Schema = @(
  S 'OC_EGRESS_DEFAULT' 'Connection' 'Connection method' 'enum' 'ASK' 'Egress used for opencode. ASK shows the picker at every start.' 'now' 0 0 @('ASK', 'WARP', 'TOR', 'PROXY', 'NONE')
  S 'OC_MODE_DEFAULT' 'Connection' 'Run mode' 'enum' 'ASK' 'CLI terminal, Desktop app, or ask at every start.' 'now' 0 0 @('ASK', 'CLI', 'DESKTOP')
  S 'PROXY_PORT' 'Connection' 'WARP proxy port' 'port' 40000 'Local port of the WARP proxy.' 'next WARP connect'
  S 'WARP_WAIT' 'Connection' 'WARP wait (s)' 'int' 6 'Seconds to wait after (re)connecting WARP.' 'now' 1 60
  S 'WARP_CALL_TIMEOUT' 'Connection' 'warp-cli timeout (s)' 'int' 15 'Seconds a single warp-cli call may take.' 'now' 5 300
  S 'PROXY_LIST_URL' 'Proxy list' 'Proxy list source' 'listsrc' 'https://api.proxyscrape.com/v4/free-proxy-list/get?request=display_proxies&protocol=http&proxy_format=protocolipport&format=text' 'URL or local file, any format (plain, CSV, JSON, XML, HTML).' 'now'
  S 'PROXY_LIST_MIN_BYTES' 'Proxy list' 'Minimum list size (bytes)' 'int' 20 'A downloaded list smaller than this is rejected. 0 = off.' 'now' 0 100000000
  S 'PROXY_TRY_MAX' 'Proxy list' 'Proxies tried per pick' 'int' 12 'How many proxies to test before giving up.' 'now' 1 500
  S 'PROXY_PROBE_TIMEOUT' 'Proxy list' 'Proxy test timeout (s)' 'int' 8 'Seconds a single proxy test may take.' 'now' 1 120
  S 'PROXY_ROT_MAX' 'Proxy list' 'Burned proxies before Tor offer' 'int' 10 'Burned proxies in a row before PROXY mode offers Tor.' 'now' 1 200
  S 'PROXY_API_CHECK' 'Proxy list' 'Check the API host' 'bool' 0 'A proxy must also reach the opencode API host.' 'now'
  S 'PROXY_API_CHECK_URL' 'Proxy list' 'API check URL' 'url' 'https://api.opencode.ai/' 'Host used by the API check.' 'now'
  S 'TOR_SOCKS_PORT' 'Tor' 'Tor SOCKS port' 'port' 9050 'SOCKS port of the Tor the launcher starts.' 'next Tor start'
  S 'TOR_HTTP_PORT' 'Tor' 'Tor HTTP bridge port' 'port' 8118 'HTTP port of the built-in bridge opencode uses.' 'next Tor start'
  S 'TOR_AUTO_INSTALL' 'Tor' 'Install Tor automatically' 'bool' 1 'Download the portable Tor bundle when nothing answers.' 'now'
  S 'TOR_BOOTSTRAP_WAIT' 'Tor' 'Tor bootstrap wait (s)' 'int' 120 'Seconds to wait for Tor to finish bootstrapping.' 'now' 30 900
  S 'ROTATE_TRIES_MAX' 'Rotation' 'Rotation attempts' 'int' 4 'Attempts per round when the tunnel is not up.' 'now' 1 20
  S 'ROTATE_COOLDOWN' 'Rotation' 'Cooldown between attempts (s)' 'int' 10 'Cloudflare throttles rapid registrations.' 'now' 0 300
  S 'ON_CLOSE' 'Rotation' 'After opencode closes' 'enum' 'ask' 'ask = R, M or Q: R gets a new IP and resumes the chat, M opens the menu, Q quits. quit = leave the launcher at once.' 'now' 0 0 @('ask', 'quit')
  S 'IP_FIND_MAX' 'Rotation' 'Burned IPs allowed' 'int' 0 'IPs the probe may reject before giving up. 0 = no limit.' 'now' 0 10000
  S 'AUTO_ROTATE' 'Rotation' 'Automatic rotation' 'bool' 1 'On: a limit or a closed opencode gets a new IP and the chat resumes. Off: the menu decides.' 'now'
  S 'TARGET_COUNTRY' 'Rotation' 'Target country' 'country' '' 'Keep asking for IPs until one is in this country, e.g. DE. Empty = any new IP.' 'now'
  S 'TARGET_PREFIX' 'Rotation' 'Target IP prefix' 'ipprefix' '' 'Keep asking until the IP starts with this, e.g. 104.28. Empty = not used.' 'now'
  S 'TARGET_TRIES' 'Rotation' 'Max attempts per hunt' 'int' 10 'New IPs requested in one hunt. The hunt stops at this count.' 'now' 1 100
  S 'TARGET_MINUTES' 'Rotation' 'Max minutes per hunt' 'int' 15 'The hunt stops after this many minutes.' 'now' 1 240
  S 'TARGET_INTERVAL' 'Rotation' 'Seconds between attempts' 'int' 15 'Pause between two attempts, so Cloudflare is not hit too fast.' 'now' 0 300
  S 'WATCH' 'Watcher' 'Watch the log' 'bool' 1 'Rotate when a fatal error appears while opencode runs.' 'now'
  S 'RESUME_MSG' 'Watcher' 'Resume message' 'string' 'continue' 'Sent automatically after a rotation.' 'now'
  S 'RESUME_AUTO' 'Watcher' 'Unattended resume' 'bool' 1 'The resume auto-approves tool permissions.' 'now'
  S 'RESUME_TIMEOUT' 'Watcher' 'Resume timeout (s)' 'int' 90 'Seconds before a silent resume counts as a dead IP.' 'now' 10 900
  S 'PROBE' 'Probe' 'Test every new IP' 'bool' 1 'Send one cheap message through each candidate IP.' 'now'
  S 'PROBE_MODEL' 'Probe' 'Probe model' 'string' 'opencode/deepseek-v4.1-flash-free' 'Model used by the IP probe.' 'now'
  S 'PROBE_BROKEN_MAX' 'Probe' 'Probe failures tolerated' 'int' 3 'Non-limit probe failures before the hunt stops.' 'now' 1 50
  S 'OC_APP' 'Paths' 'Desktop app path' 'path' '' 'Full path of OpenCode.exe. Empty = search automatically.' 'now'
  S 'OC_API_BASE' 'Paths' 'Release metadata URL' 'url' 'https://opencode.ai/update/api/latest' 'Where versions and checksums are read from.' 'now'
  S 'WHERE_TIMEOUT' 'Paths' 'PATH lookup timeout (s)' 'int' 5 'Seconds a single "where" lookup may take.' 'now' 1 120
  S 'UPDATE_CHECK' 'Updates' 'Launcher self-update' 'bool' 0 'Check GitHub for a newer launcher at every start.' 'next launch'
  S 'OCUI_THEME' 'Appearance' 'Color theme' 'enum' 'ocean' 'Accent colors of the interface.' 'now' 0 0 @('ocean', 'forest', 'sunset', 'mono')
  S 'OCUI_COLOR' 'Appearance' 'Colors' 'enum' 'auto' 'auto follows the terminal and NO_COLOR; off disables colors.' 'now' 0 0 @('auto', 'on', 'off')
  S 'OCUI_ICONS' 'Appearance' 'Icons and borders' 'enum' 'auto' 'emoji = modern terminals, unicode = classic console, ascii = anything.' 'now' 0 0 @('auto', 'emoji', 'unicode', 'ascii')
  S 'OCUI_LANG' 'Appearance' 'Language' 'enum' 'auto' 'Language of the menus and descriptions. auto follows Windows. Logs and the support report stay in English.' 'now' 0 0 @('auto', 'en', 'es', 'fr', 'de', 'pt', 'it', 'tr')
  S 'OCUI_FONT' 'Appearance' 'Terminal font' 'font' '' 'Font of the terminal text. Empty leaves the terminal as it is.' 'now'
  S 'OCUI_FONT_SIZE' 'Appearance' 'Font size' 'int' 16 'Size used with the chosen font.' 'now' 8 72
  S 'LOG_ENABLED' 'Support' 'Activity log' 'bool' 1 'Record what the launcher does in launcher.log so a problem can be diagnosed.' 'now'
  S 'LOG_MAX_KB' 'Support' 'Log size limit (KB)' 'int' 1024 'The log is cut to its newest part when it grows past this.' 'next launch' 64 10240
  S 'LOG_MASK_IP' 'Support' 'Hide IPs in reports' 'bool' 1 'Public IP addresses are masked in the support report.' 'now'
)
$Groups = @('Connection', 'Proxy list', 'Tor', 'Rotation', 'Watcher', 'Probe', 'Paths', 'Updates', 'Appearance', 'Support')
$GroupHelp = @{
  'Connection' = 'Default connection method and run mode, the WARP proxy port and the warp-cli timings.'
  'Proxy list' = 'Where proxies come from (URL or file, any format) and how each one is tested.'
  'Tor' = 'Ports and install behavior of the portable Tor the launcher starts for you.'
  'Rotation' = 'How many times, and how fast, a new IP is requested when the free limit is hit.'
  'Watcher' = 'Watching the opencode log and the automatic "continue" sent after a rotation.'
  'Probe' = 'The cheap test message sent through every new IP before it is trusted.'
  'Paths' = 'Desktop app location, release metadata URL and lookup timeouts.'
  'Updates' = 'Whether the launcher checks GitHub for a newer copy of itself at every start.'
  'Appearance' = 'Color theme, colors on or off, icon and border style, and the terminal font. Applied immediately.'
  'Support' = 'The activity log (launcher.log) and the support report: what is recorded, how big it may grow, whether IPs are masked.'
}

# ---------------------------------------------------------------- config file
function To-Hash($o) {
  if ($o -is [System.Management.Automation.PSCustomObject]) {
    $h = @{}
    foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = To-Hash $p.Value }
    return $h
  }
  if ($o -is [array]) { $r = @(); foreach ($x in $o) { $r += , (To-Hash $x) }; return , $r }
  return $o
}
function Get-Setting($key) { foreach ($s in $Schema) { if ($s.Key -eq $key) { return $s } } return $null }
function Get-Val($key) {
  $s = Get-Setting $key
  if ($script:Cfg.settings.ContainsKey($key)) { return $script:Cfg.settings[$key] }
  return $s.Default
}
function Load-Cfg {
  $script:Cfg = @{ version = 1; settings = @{}; setup = @{}; font = @{} }
  if (-not (Test-Path -LiteralPath $CfgPath)) { return }
  try {
    $j = To-Hash (Get-Content -LiteralPath $CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json)
    if ($j.settings -is [hashtable]) {
      foreach ($s in $Schema) {
        if ($j.settings.ContainsKey($s.Key)) {
          $r = Test-Val $s ([string]$j.settings[$s.Key]) $true
          if ($r.ok) { $script:Cfg.settings[$s.Key] = $r.v }
        }
      }
    }
    if ($j.setup -is [hashtable]) { $script:Cfg.setup = $j.setup }
    if ($j.font -is [hashtable]) { $script:Cfg.font = $j.font }
  } catch {
    # a hand-edited file that no longer parses is kept aside, never overwritten silently
    try { Copy-Item -LiteralPath $CfgPath -Destination ($CfgPath + '.broken') -Force } catch { }
    $script:Notice = @('warn', 'config.json could not be read; a copy was kept as config.json.broken and defaults are in use.')
  }
}
function Save-Cfg {
  New-Item -ItemType Directory -Force -Path $State | Out-Null
  $tmp = $CfgPath + '.tmp'
  [IO.File]::WriteAllText($tmp, ($script:Cfg | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
  Move-Item -LiteralPath $tmp -Destination $CfgPath -Force
  # every effective value, so a reset or a removed override also reaches a running launcher
  $lines = @()
  foreach ($s in $Schema) { $lines += ($s.Key + '=' + [string](Get-Val $s.Key)) }
  [IO.File]::WriteAllLines($EnvPath, [string[]]$lines, (New-Object Text.UTF8Encoding($false)))
  # What the batch needs to color its own lines like this interface. Only a real console writes it: a hidden
  # child (output redirected) must not switch colors off for the window that is actually on screen.
  if ($Scripted -or -not [Console]::IsOutputRedirected) {
    $ui = @(('UI_COLOR=' + $(if ($script:Color) { 1 } else { 0 })), ('UI_ACC=' + $script:Theme.Accent))
    [IO.File]::WriteAllLines((Join-Path $State 'ui.env'), [string[]]$ui, (New-Object Text.UTF8Encoding($false)))
  }
}
function Set-Val($s, $v) {
  if ([string]$v -eq [string]$s.Default) { [void]$script:Cfg.settings.Remove($s.Key) } else { $script:Cfg.settings[$s.Key] = $v }
  Save-Cfg
}

# ---------------------------------------------------------------- validation
function Fail($m) { return @{ ok = $false; err = $m } }
function Pass($v) { return @{ ok = $true; v = $v } }
function Test-Val($s, [string]$t, [bool]$loading = $false) {
  $t = $t.Trim()
  switch ($s.Type) {
    'bool' {
      if ($t -match '^(1|on|yes|true|y)$') { return Pass 1 }
      if ($t -match '^(0|off|no|false|n)$') { return Pass 0 }
      return Fail 'Use on or off.'
    }
    'int' {
      $n = 0
      if (-not [int]::TryParse($t, [ref]$n)) { return Fail 'Enter a whole number.' }
      if ($n -lt $s.Min -or $n -gt $s.Max) { return Fail (Tf 'Must be between {0} and {1}.' $s.Min $s.Max) }
      return Pass $n
    }
    'port' {
      $n = 0
      if (-not [int]::TryParse($t, [ref]$n) -or $n -lt 1 -or $n -gt 65535) { return Fail 'A port is a number from 1 to 65535.' }
      if (-not $loading) {
        foreach ($o in @('PROXY_PORT', 'TOR_SOCKS_PORT', 'TOR_HTTP_PORT')) {
          if ($o -ne $s.Key -and [int](Get-Val $o) -eq $n) { return Fail (Tf 'Port {0} is already used by {1}.' $n (T (Get-Setting $o).Label)) }
        }
      }
      return Pass $n
    }
    'enum' {
      foreach ($v in $s.Values) { if ($v -ieq $t) { return Pass $v } }
      return Fail (Tf 'Choose one of: {0}.' ($s.Values -join ', '))
    }
    'country' {
      if ($t -eq '') { return Pass '' }
      if ($t -notmatch '^[A-Za-z]{2}$') { return Fail 'Two letters, like DE or US. Empty = any country.' }
      return Pass $t.ToUpper()
    }
    'ipprefix' {
      if ($t -eq '') { return Pass '' }
      if ($t -notmatch '^\d{1,3}(\.\d{1,3}){0,3}\.?$') { return Fail 'The start of an IPv4 address, like 104.28. Empty = any IP.' }
      return Pass $t
    }
    'string' {
      if ($t -match '["\r\n]') { return Fail 'Quotes and line breaks are not allowed.' }
      if ($t.Length -lt 1 -or $t.Length -gt 200) { return Fail 'Use 1 to 200 characters.' }
      return Pass $t
    }
    'url' {
      if ($t -notmatch '^(https?|ftp|file)://[^\s"]+$') { return Fail 'Enter a full URL (http, https, ftp or file).' }
      return Pass $t
    }
    'listsrc' {
      if ($t -match '["\r\n]') { return Fail 'Quotes and line breaks are not allowed.' }
      if ($t -match '^[A-Za-z][A-Za-z0-9+.-]*://[^/\s]*:[^/\s]*@') { return Fail 'Credentials inside a URL are not stored. Use a local file instead.' }
      if ($t -match '^(https?|ftp|file)://[^\s]+$') { return Pass $t }
      if ($t -and (Test-Path -LiteralPath $t -PathType Leaf)) { return Pass $t }
      return Fail 'Not a URL, and no file exists at that path.'
    }
    'font' {
      if ($t -eq '') { return Pass '' }
      if ($t -match '["\\\r\n]' -or $t.Length -gt 31) { return Fail 'Use up to 31 characters, without quotes or backslashes.' }
      return Pass $t
    }
    'path' {
      if ($t -eq '') { return Pass '' }
      if ($t -match '["\r\n]') { return Fail 'Quotes and line breaks are not allowed.' }
      if ((Test-Path -LiteralPath $t -PathType Leaf) -and $t -match '\.exe$') { return Pass $t }
      return Fail 'No .exe file exists at that path.'
    }
  }
  return Fail 'Unknown setting type.'
}

# ---------------------------------------------------------------- terminal, colors, icons
function Enable-VT {
  if ($env:WT_SESSION -or $env:TERM_PROGRAM -or $env:ConEmuANSI -eq 'ON') { return $true }
  try {
    Add-Type -Namespace OCI -Name K32 -ErrorAction Stop -MemberDefinition '[DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int n); [DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr h, out int m); [DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr h, int m);'
    $h = [OCI.K32]::GetStdHandle(-11); $m = 0
    if (-not [OCI.K32]::GetConsoleMode($h, [ref]$m)) { return $false }
    return [OCI.K32]::SetConsoleMode($h, ($m -bor 4))
  } catch { return $false }
}
$Themes = @{
  ocean  = @{ Title = '1;96'; Accent = '36'; Sel = '30;46'; Border = '34'; Panel = '48;5;235' }
  forest = @{ Title = '1;92'; Accent = '32'; Sel = '30;42'; Border = '32'; Panel = '48;5;234' }
  sunset = @{ Title = '1;95'; Accent = '35'; Sel = '30;45'; Border = '35'; Panel = '48;5;236' }
  mono   = @{ Title = '1'; Accent = '0'; Sel = '7'; Border = '0'; Panel = '' }
}
# v2.30: the languages the interface knows; each one is a JSON file in langs/.
$Langs = @('en', 'es', 'fr', 'de', 'pt', 'it', 'tr')
$LangBase = if ($env:OC_LANG_BASE) { $env:OC_LANG_BASE } else { 'https://raw.githubusercontent.com/jeko1107/opencode-infinite/main/langs' }
# T looks a text up in the selected language; no entry means the English text is shown. Leading
# icons and spaces are kept. Tf fills {0} {1} after translating. OC_TUI_I18N_DUMP=<file> lists the misses.
$script:TrCache = @{}
function Get-Table([string]$lg) {
  if ($lg -eq 'en') { return @{} }
  if ($script:TrCache.ContainsKey($lg)) { return $script:TrCache[$lg] }
  $h = New-Object 'Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
  $file = Join-Path (Join-Path $State 'langs') ($lg + '.json')
  Update-Lang $lg $file
  # the copy on disk (refreshed from the repo) wins; the copy inside this launcher is the fallback
  $text = if (Test-Path -LiteralPath $file) { Get-Content -LiteralPath $file -Raw -Encoding UTF8 } else { Get-EmbeddedLang $lg }
  if ($text) {
    try { foreach ($p in (Read-Lang $text).GetEnumerator()) { $h[$p.Key] = $p.Value } }
    catch { Log ('language file unreadable, English is used: ' + $lg) }
  }
  $script:TrCache[$lg] = $h
  return $h
}
# The languages are stored inside the launcher as '#>>>LANG <code> <json>' lines at its end (embed_langs.py).
function Get-EmbeddedLang([string]$lg) {
  $pre = '#>>>LANG ' + $lg + ' '
  try {
    $line = Get-Content -LiteralPath $Self -Encoding UTF8 | Where-Object { $_.StartsWith($pre) } | Select-Object -First 1
    if ($line) { return $line.Substring($pre.Length) }
  } catch { }
  return $null
}
# Keys are case-sensitive here ('Yes' and 'yes' are both in the table); ConvertFrom-Json would merge them.
function Read-Lang([string]$text) {
  Add-Type -AssemblyName System.Web.Extensions
  $d = (New-Object System.Web.Script.Serialization.JavaScriptSerializer).DeserializeObject($text)
  if ($d -isnot [System.Collections.IDictionary]) { throw 'not a language object' }
  $h = New-Object 'Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
  foreach ($k in $d.Keys) { $h[[string]$k] = [string]$d[$k] }
  return $h
}
# The language file is refreshed from the repo at most once a day. No network, or a file that is not
# JSON, keeps the copy already on disk; with no copy at all the texts stay in English.
function Update-Lang([string]$lg, [string]$file) {
  if ((Test-Path -LiteralPath $file) -and ((Get-Date) - (Get-Item -LiteralPath $file).LastWriteTime).TotalHours -lt 24) { return }
  # a failed attempt is not repeated for an hour: every screen is a new process and would wait for the network again
  $fail = $file + '.failed'
  if ((Test-Path -LiteralPath $fail) -and ((Get-Date) - (Get-Item -LiteralPath $fail).LastWriteTime).TotalHours -lt 1) { return }
  $tmp = $file + '.tmp'
  try {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $file) | Out-Null
    $src = $LangBase + '/' + $lg + '.json'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    if ($src -match '^https://') { Invoke-WebRequest -Uri $src -OutFile $tmp -UseBasicParsing -TimeoutSec 8 } else { Copy-Item -LiteralPath $src -Destination $tmp -Force }
    [void](Read-Lang (Get-Content -LiteralPath $tmp -Raw -Encoding UTF8))
    Move-Item -LiteralPath $tmp -Destination $file -Force
    Remove-Item -LiteralPath $fail -Force -ErrorAction SilentlyContinue
    Log ('language ' + $lg + ' refreshed')
  } catch {
    Log ('language ' + $lg + ' not refreshed: ' + $_.Exception.Message)
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    [IO.File]::WriteAllText($fail, (Get-Date).ToString('s'))
  }
}
function T([string]$s) {
  if (-not $s -or $script:Lang -eq 'en') { return $s }
  if ($script:Tr.ContainsKey($s)) { return $script:Tr[$s] }
  # an icon in front ("[X] Exit", "~ Support report") stays as it is; icons such as [OK] contain letters
  foreach ($ic in $script:IconList) { if ($ic -and $s.StartsWith($ic + ' ')) { return $ic + ' ' + (T $s.Substring($ic.Length + 1)) } }
  $m = [regex]::Match($s, '^([^\p{L}\d]*)(.+)$')
  if ($m.Success -and $m.Groups[1].Value -and $script:Tr.ContainsKey($m.Groups[2].Value)) { return $m.Groups[1].Value + $script:Tr[$m.Groups[2].Value] }
  if ($env:OC_TUI_I18N_DUMP -and $s -match '\p{L}') { try { Add-Content -LiteralPath $env:OC_TUI_I18N_DUMP -Value $s -Encoding UTF8 } catch { } }
  return $s
}
function Detect-Lang {
  $uc = $(if ($env:OC_TUI_UILANG) { $env:OC_TUI_UILANG } else { (Get-UICulture).TwoLetterISOLanguageName })
  if ($Langs -contains $uc) { return $uc }
  return 'en'
}
function Tf([string]$fmt, [Parameter(ValueFromRemainingArguments = $true)]$a) { return ((T $fmt) -f @($a)) }
function Init-Ui {
  try { [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false) } catch { }
  $cm = Get-Val 'OCUI_COLOR'
  $script:Color = $false
  if ($cm -ne 'off' -and -not $env:NO_COLOR) {
    if ($Scripted -and $cm -eq 'on') { $script:Color = $true }
    elseif (-not [Console]::IsOutputRedirected) { $script:Color = ((Enable-VT) -or ($cm -eq 'on')) }
  }
  $script:Theme = $Themes[(Get-Val 'OCUI_THEME')]
  $lg = Get-Val 'OCUI_LANG'
  if ($lg -eq 'auto') { $lg = Detect-Lang }
  $script:Lang = $lg
  if (-not $Scripted) { try { [Console]::TreatControlCAsInput = $true } catch { } }
  $script:Tr = Get-Table $lg
  $im = Get-Val 'OCUI_ICONS'
  if ($im -eq 'auto') { if ($env:WT_SESSION -or $env:TERM_PROGRAM -or $env:VSCODE_PID) { $im = 'emoji' } else { $im = 'unicode' } }
  $script:IconMode = $im
  $c = { param($n) [string][char]$n }
  if ($im -eq 'emoji') {
    $script:I = @{ ok = (& $c 0x2714); err = (& $c 0x2716); warn = (& $c 0x26A0); gear = (& $c 0x2699); play = (& $c 0x25B6); link = (& $c 0x221E); renew = (& $c 0x21BB); trash = (& $c 0x2716); back = (& $c 0x2190); sel = (& $c 0x276F); up = (& $c 0x2191); down = (& $c 0x2193); info = (& $c 0x2139)
      renewE = [char]::ConvertFromUtf32(0x1F504); gearE = [char]::ConvertFromUtf32(0x2699) + [char]0xFE0F
      tl = (& $c 0x256D); tr = (& $c 0x256E); bl = (& $c 0x2570); br = (& $c 0x256F); h = (& $c 0x2500); v = (& $c 0x2502)
      spin = @(0x280B, 0x2819, 0x2839, 0x2838, 0x283C, 0x2834, 0x2826, 0x2827, 0x2807, 0x280F | ForEach-Object { [string][char]$_ }); bar = (& $c 0x2588); barOff = (& $c 0x2591) }
  } elseif ($im -eq 'unicode') {
    $script:I = @{ ok = '[OK]'; err = '[X]'; warn = '[!]'; gear = '[*]'; play = '>'; link = '~'; renew = '@'; trash = 'x'; back = '<'; sel = '>'; up = '^'; down = 'v'; info = 'i'
      renewE = '[~]'; gearE = '[*]'
      tl = (& $c 0x250C); tr = (& $c 0x2510); bl = (& $c 0x2514); br = (& $c 0x2518); h = (& $c 0x2500); v = (& $c 0x2502)
      spin = @('|', '/', '-', '\'); bar = (& $c 0x2588); barOff = (& $c 0x2591) }
  } else {
    $script:I = @{ ok = '[OK]'; err = '[X]'; warn = '[!]'; gear = '[*]'; play = '>'; link = '~'; renew = '@'; trash = 'x'; back = '<'; sel = '>'; up = '^'; down = 'v'; info = 'i'
      renewE = '[~]'; gearE = '[*]'
      tl = '+'; tr = '+'; bl = '+'; br = '+'; h = '-'; v = '|'
      spin = @('|', '/', '-', '\'); bar = '#'; barOff = '.' }
  }
  $script:IconList = @(@($script:I.ok, $script:I.err, $script:I.warn, $script:I.gear, $script:I.play, $script:I.link, $script:I.renew, $script:I.trash, $script:I.back, $script:I.renewE) | Where-Object { $_ } | Sort-Object { $_.Length } -Descending)
  # The interface is a block centered in the terminal: margin = free columns / 2.
  try { $cw = [Console]::WindowWidth; $script:TermH = [Console]::WindowHeight } catch { $cw = 80; $script:TermH = 30 }
  if ($env:OC_TUI_COLS) { $cw = [int]$env:OC_TUI_COLS }
  if ($cw -lt 20) { $cw = 80 }
  $script:Width = [Math]::Max(56, [Math]::Min(74, $cw - 2))
  $script:Margin = [Math]::Max(0, [int](($cw - $script:Width) / 2))
  $script:VPad = ((-not $Scripted) -or [bool]$env:OC_TUI_VPAD)
}
# A block background behind a line: re-applied after each color reset inside the line.
function Panel([string]$s) {
  if (-not $script:Color -or -not $script:Theme.Panel) { return $s }
  $p = $esc + '[' + $script:Theme.Panel + 'm'
  return $p + $s.Replace($esc + '[0m', $esc + '[0m' + $p) + $esc + '[0m'
}
function P($style, [string]$t) { if ($script:Color -and $style) { return $esc + '[' + $style + 'm' + $t + $esc + '[0m' } return $t }
function Style($name) {
  switch ($name) { 'ok' { '32' } 'err' { '31' } 'warn' { '33' } 'title' { $script:Theme.Title } 'accent' { $script:Theme.Accent } 'dim' { '90' } 'border' { $script:Theme.Border } default { '' } }
}
function W([string]$s) { [Console]::Write($s) }
function WL([string]$s = '') {
  foreach ($l in ($s -split "`r?`n")) { if ($l) { [Console]::WriteLine((' ' * $script:Margin) + $l) } else { [Console]::WriteLine() } }
}
function Wrap-Text([string]$text, [int]$w, [int]$max) {
  $lines = @(); $cur = ''
  foreach ($word in ($text -split '\s+')) {
    if (-not $word) { continue }
    while ($word.Length -gt $w) { if ($cur) { $lines += $cur; $cur = '' }; $lines += $word.Substring(0, $w); $word = $word.Substring($w) }
    if ($cur -and (($cur.Length + $word.Length + 1) -gt $w)) { $lines += $cur; $cur = $word }
    elseif ($cur) { $cur = $cur + ' ' + $word }
    else { $cur = $word }
  }
  if ($cur) { $lines += $cur }
  if ($lines.Count -gt $max) {
    $lines = @($lines[0..($max - 1)])
    $l = $lines[$max - 1]
    if ($l.Length -gt $w - 3) { $l = $l.Substring(0, $w - 3) }
    $lines[$max - 1] = $l + '...'
  }
  return $lines
}
function Clear-Screen { if ($Scripted) { WL ('-' * 20); return } try { [Console]::Clear() } catch { } }
function Pad([string]$s, [int]$n) { if ($s.Length -ge $n) { return $s.Substring(0, $n) } return $s + (' ' * ($n - $s.Length)) }
function Box-Top([string]$title) { return Panel (Box-Top0 $title) }
function Box-Top0([string]$title) {
  $in = $script:Width - 2
  $t = ' ' + $title + ' '
  $left = $script:I.tl + $script:I.h
  $fill = $script:I.h * [Math]::Max(0, $in - 1 - $t.Length)
  return (P (Style 'border') $left) + (P (Style 'title') $t) + (P (Style 'border') ($fill + $script:I.tr))
}
function Box-Bot { return Panel (P (Style 'border') ($script:I.bl + ($script:I.h * ($script:Width - 2)) + $script:I.br)) }
function Box-Line([string]$text, $style = '') {
  $in = $script:Width - 4
  return Panel ((P (Style 'border') $script:I.v) + ' ' + (P $style (Pad $text $in)) + ' ' + (P (Style 'border') $script:I.v))
}
function Get-Banner {
  $art = @(
    ' ___   ____   _____  _   _   ____  ___   ____   _____   ',
    '/ _ \ |  _ \ | ____|| \ | | / ___|/ _ \ |  _ \ | ____|  ',
    '| | | || |_) ||  _|  |  \| || |    | | | || | | ||  _|  ',
    '| |_| ||  __/ | |___ | |\  || |___ | |_| || |_| || |___ ',
    ' \___/ |_|    |_____||_| \_| \____| \___/ |____/ |_____|',
    ' ___  _   _  _____  ___  _   _  ___  _____  _____       ',
    '|_ _|| \ | ||  ___||_ _|| \ | ||_ _||_   _|| ____|      ',
    ' | | |  \| || |_    | | |  \| | | |   | |  |  _|        ',
    ' | | | |\  ||  _|   | | | |\  | | |   | |  | |___       ',
    '|___||_| \_||_|    |___||_| \_||___|  |_|  |_____|      ')
  $styles = @('1;96', '96', '36', '36', '34', '1;94', '1;96', '96', '36', '36', '34', '1;94', '1;96', '96', '36', '36', '34', '1;94')
  $w = 0; foreach ($a in $art) { if ($a.Length -gt $w) { $w = $a.Length } }
  $pad = [Math]::Max(0, [int](($script:Width - $w) / 2))
  $lead = ' ' * $pad
  $out = @()
  for ($r = 0; $r -lt $art.Count; $r++) { $out += (P $styles[$r % $styles.Count] ($lead + $art[$r])) }
  # the URL centers on the art block, not on its own length, so it sits under the logo
  $out += (P (Style 'accent') ($lead + (' ' * [Math]::Max(0, [int](($w - $Repo.Length) / 2))) + $Repo))
  return $out
}

# ---------------------------------------------------------------- input
function Get-Key {
  if ($Scripted) { if ($KeyQ.Count -eq 0) { throw 'keys exhausted' } return $KeyQ.Dequeue() }
  if ($script:KeyTimeout -gt 0) {
    # a prompt with a default answer: no key before the deadline means Esc
    $dl = (Get-Date).AddSeconds($script:KeyTimeout)
    while (-not [Console]::KeyAvailable) { if ((Get-Date) -gt $dl) { return 'Esc' }; Start-Sleep -Milliseconds 80 }
  }
  $ki = [Console]::ReadKey($true)
  if ($ki.Key -eq 'C' -and ($ki.Modifiers -band [ConsoleModifiers]::Control)) { throw 'ctrl-c' }
  switch ($ki.Key) {
    'UpArrow' { return 'Up' } 'DownArrow' { return 'Down' } 'LeftArrow' { return 'Left' } 'RightArrow' { return 'Right' }
    'Enter' { return 'Enter' } 'Escape' { return 'Esc' } 'Home' { return 'Home' } 'End' { return 'End' }
    default { return [string]$ki.KeyChar }
  }
}
function Read-Text([string]$prompt, [string]$current) {
  WL ''
  WL ((P (Style 'accent') (T $prompt)) + ' ' + (P (Style 'dim') (Tf '(Enter = keep "{0}")' $current)))
  W ((' ' * $script:Margin) + (P (Style 'accent') $script:I.sel) + ' ')
  if ($Scripted) { if ($InQ.Count -eq 0) { throw 'keys exhausted' } $r = $InQ.Dequeue(); WL $r; return $r }
  return [Console]::ReadLine()
}
function Say($kind, [string]$msg) {
  $ic = switch ($kind) { 'ok' { $script:I.ok } 'err' { $script:I.err } 'warn' { $script:I.warn } default { $script:I.gear } }
  WL ((P (Style $kind) $ic) + ' ' + (P (Style $kind) (T $msg)))
}
function Wait-Key { WL ''; WL (P (Style 'dim') (T 'Press any key to continue...')); [void](Get-Key) }

# Arrow-key menu. Items: @{L=label; V=value text; S=value style; D=disabled; H=what it does}.
# Returns the index, or -1 on Esc. The selected row's H is shown under the box.
function Show-Menu([string]$title, $items, $footer = $null, $head = $null, [int]$start = 0, [bool]$banner = $false, [bool]$inline = $false) {
  $i = $start
  if ($i -ge $items.Count) { $i = 0 }
  $top = -1
  while ($true) {
    $buf = New-Object 'Collections.Generic.List[string]'
    $fullVal = ''
    if ($banner) { foreach ($b in (Get-Banner)) { $buf.Add($b) }; $buf.Add('') }
    if ($head) { foreach ($h in $head) { $buf.Add([string]$h) } }
    $buf.Add((Box-Top (T $title)))
    $in = $script:Width - 4
    for ($n = 0; $n -lt $items.Count; $n++) {
      $it = $items[$n]
      $num = if ($n -lt 9) { [string]($n + 1) } else { ' ' }
      $mark = if ($n -eq $i) { $script:I.sel } else { ' ' }
      $lab = $mark + ' ' + $num + '  ' + (T ([string]$it.L))
      $val = T ([string]$it.V)
      $room = $in - $lab.Length - 1
      if ($val.Length -gt $room - 1) { if ($n -eq $i) { $fullVal = $val }; $val = $val.Substring(0, [Math]::Max(0, $room - 2)) + '..' }
      $gap = ' ' * [Math]::Max(1, $in - $lab.Length - $val.Length)
      if ($n -eq $i) {
        $buf.Add((Panel ((P (Style 'border') $script:I.v) + ' ' + (P $script:Theme.Sel (Pad ($lab + $gap + $val) $in)) + ' ' + (P (Style 'border') $script:I.v))))
      } else {
        $st = if ($it.D) { Style 'dim' } else { '' }
        $vs = if ($it.S) { Style $it.S } else { Style 'accent' }
        $pad = ' ' * [Math]::Max(0, $in - $lab.Length - $gap.Length - $val.Length)
        $buf.Add((Panel ((P (Style 'border') $script:I.v) + ' ' + (P $st $lab) + $gap + (P $vs $val) + $pad + ' ' + (P (Style 'border') $script:I.v))))
      }
    }
    $buf.Add((Box-Bot))
    $dtext = T ([string]$items[$i].H)
    if ($fullVal) { $dtext = (Tf 'Value: {0}' $fullVal) + '  ' + $dtext }
    $dl = @(Wrap-Text $dtext ($script:Width - 4) 3)
    for ($q = 0; $q -lt 3; $q++) {
      if ($q -lt $dl.Count) {
        $pre = if ($q -eq 0) { $script:I.info + ' ' } else { '  ' }
        $buf.Add((P (Style 'accent') (Pad ($pre + $dl[$q]) ($script:Width - 1))))
      } else { $buf.Add((' ' * ($script:Width - 1))) }
    }
    $buf.Add((P (Style 'dim') (Pad ($script:I.up + '/' + $script:I.down + (T ' move   Enter select   Esc back   1-9 or letter jump')) ($script:Width - 1))))
    foreach ($f in @($footer)) { if ($f) { foreach ($fl in (Wrap-Text (T ([string]$f)) ($script:Width - 1) 3)) { $buf.Add((Panel (P (Style 'dim') (Pad $fl ($script:Width - 1))))) } } }
    if ($inline) {
      # drawn under the text already on screen and redrawn in place
      if ($top -ge 0) { try { [Console]::SetCursorPosition(0, $top) } catch { } }
    } else { Clear-Screen }
    if ($script:VPad -and -not $inline) {
      $vp = [Math]::Max(0, [int](($script:TermH - $buf.Count - 1) / 2))
      for ($q = 0; $q -lt $vp; $q++) { WL '' }
    }
    foreach ($line in $buf) { WL $line }
    if ($inline) { try { $top = [Math]::Max(0, [Console]::CursorTop - $buf.Count) } catch { $top = -1 } }
    $k = Get-Key
    switch -Regex ($k) {
      '^Up$' { do { $i = ($i - 1 + $items.Count) % $items.Count } while ($items[$i].D -and $items.Count -gt 1); continue }
      '^Down$' { do { $i = ($i + 1) % $items.Count } while ($items[$i].D -and $items.Count -gt 1); continue }
      '^Home$' { $i = 0; continue }
      '^End$' { $i = $items.Count - 1; continue }
      '^Enter$' { if (-not $items[$i].D) { return $i } continue }
      '^Esc$' { return -1 }
      '^[1-9]$' { $n = [int]$k - 1; if ($n -lt $items.Count -and -not $items[$n].D) { return $n } continue }
      default { for ($q = 0; $q -lt $items.Count; $q++) { if ($items[$q].K -and ([string]$items[$q].K -ieq $k) -and -not $items[$q].D) { return $q } } }
    }
  }
}
function Confirm-Box([string]$question, [string[]]$lines = @()) {
  $head = @()
  $head += (P (Style 'warn') ($script:I.warn + ' ' + (T $question)))
  foreach ($l in $lines) { $head += (P (Style 'dim') ('   ' + (T $l))) }
  $head += ''
  $r = Show-Menu 'Confirm' @(@{ L = 'No, cancel'; H = 'Go back. Nothing is changed.' }, @{ L = 'Yes, continue'; S = 'warn'; H = 'Do it now.' }) $null $head 0
  return ($r -eq 1)
}
function Progress([int]$n, [int]$total, [string]$label) {
  $w = 24
  $fill = [int][Math]::Round($w * $n / [Math]::Max(1, $total))
  $bar = ($script:I.bar * $fill) + ($script:I.barOff * ($w - $fill))
  WL ((P (Style 'accent') ('[' + $bar + ']')) + ' ' + $n + '/' + $total + '  ' + (T $label))
}

# Runs the launcher itself in a hidden child (--verify / --renew) behind a spinner. Returns the exit code.
function Run-Child([string]$label, [string]$arg, [string]$log, [int]$timeout = 300) {
  $label = T $label
  if ($env:OC_TUI_CHILD_EXIT) { WL ((P (Style 'accent') $script:I.spin[0]) + ' ' + $label); return [int]$env:OC_TUI_CHILD_EXIT }
  if (Test-Path -LiteralPath $log) { Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue }
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = $env:SystemRoot + '\System32\cmd.exe'
  $psi.Arguments = '/d /c ""' + $Self + '" ' + $arg + ' < nul > "' + $log + '" 2>&1"'
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $p = [Diagnostics.Process]::Start($psi)
  $t0 = Get-Date; $f = 0
  while (-not $p.HasExited) {
    $frame = $script:I.spin[$f % $script:I.spin.Count]; $f++
    $sec = [int]((Get-Date) - $t0).TotalSeconds
    W ("`r" + (' ' * $script:Margin) + (P (Style 'accent') $frame) + ' ' + $label + ' ' + (P (Style 'dim') ($sec.ToString() + 's')) + '   ')
    Start-Sleep -Milliseconds 120
    if ($sec -gt $timeout) { try { Start-Process taskkill.exe -ArgumentList @('/T', '/F', '/PID', $p.Id) -WindowStyle Hidden -Wait } catch { }; break }
  }
  W ("`r" + (' ' * ($script:Margin + $label.Length + 12)) + "`r")
  if (-not $p.HasExited) { return 124 }
  return $p.ExitCode
}
function Show-LogTail([string]$log, [int]$n = 6) {
  if (-not (Test-Path -LiteralPath $log)) { return }
  $t = @(Get-Content -LiteralPath $log -Tail $n -ErrorAction SilentlyContinue | Where-Object { $_ -and $_.Trim() })
  foreach ($l in $t) { WL (P (Style 'dim') ('   ' + $l.Trim())) }
}

# ---------------------------------------------------------------- terminal font
# The classic console (cmd / PowerShell windows) takes a font through the Windows API and shows it at
# once. Windows Terminal keeps its font in settings.json: only profiles.defaults.font is touched, after a
# backup, and the file must still parse before it is written. Other terminals own their font.
function Installed-Fonts {
  if ($env:OC_TUI_FONTS) { return @($env:OC_TUI_FONTS -split ',') }
  try {
    Add-Type -AssemblyName System.Drawing
    $all = @((New-Object System.Drawing.Text.InstalledFontCollection).Families | ForEach-Object { $_.Name })
  } catch { return @() }
  $cand = @('Cascadia Mono', 'Cascadia Code', 'Consolas', 'Lucida Console', 'Courier New', 'JetBrains Mono', 'Fira Code', 'Fira Mono', 'Source Code Pro', 'Hack', 'Roboto Mono', 'Ubuntu Mono', 'DejaVu Sans Mono', 'IBM Plex Mono', 'Iosevka', 'Inconsolata', 'MS Gothic')
  return @($cand | Where-Object { $all -contains $_ })
}
function Pick-Font {
  $cur = [string](Get-Val 'OCUI_FONT')
  $items = @(@{ L = '(terminal default)'; V = $(if ($cur -eq '') { '*' } else { '' }); H = 'Leave the terminal font as it is. If the launcher changed it, the original font comes back.'; f = '' })
  foreach ($f in (Installed-Fonts)) { $items += @{ L = $f; V = $(if ($f -eq $cur) { '*' } else { '' }); H = (Tf 'Use {0} for the terminal text. Monospaced fonts only look right.' $f); f = $f } }
  $items += @{ L = 'Type a font name...'; H = 'Any installed font name, for example Cascadia Code.'; f = '<type>' }
  $items += @{ L = ($script:I.back + ' Back'); H = 'Keep the current font.'; f = '<back>' }
  $r = Show-Menu 'Terminal font' $items 'The font applies to the whole terminal window, not only to this launcher.'
  if ($r -eq -1) { return $null }
  $f = $items[$r].f
  if ($f -eq '<back>') { return $null }
  if ($f -eq '<type>') {
    while ($true) {
      $t = Read-Text 'Font name' $cur
      if ($t -eq '') { return $null }
      $v = Test-Val (Get-Setting 'OCUI_FONT') $t
      if ($v.ok) { return $v.v }
      Say 'err' $v.err
    }
  }
  return $f
}
function Strip-Jsonc([string]$s) {
  $sb = New-Object Text.StringBuilder; $i = 0; $n = $s.Length; $inStr = $false
  while ($i -lt $n) {
    $c = $s[$i]
    if ($inStr) {
      [void]$sb.Append($c)
      if ($c -eq [char]92) { $i++; if ($i -lt $n) { [void]$sb.Append($s[$i]) } } elseif ($c -eq [char]34) { $inStr = $false }
      $i++; continue
    }
    if ($c -eq [char]34) { $inStr = $true; [void]$sb.Append($c); $i++; continue }
    if ($c -eq '/' -and ($i + 1) -lt $n -and $s[$i + 1] -eq '/') { while ($i -lt $n -and $s[$i] -ne "`n") { $i++ }; continue }
    if ($c -eq '/' -and ($i + 1) -lt $n -and $s[$i + 1] -eq '*') { $i += 2; while (($i + 1) -lt $n -and -not ($s[$i] -eq '*' -and $s[$i + 1] -eq '/')) { $i++ }; $i += 2; continue }
    [void]$sb.Append($c); $i++
  }
  return [regex]::Replace($sb.ToString(), ',(\s*[}\]])', '$1')
}
function Get-WtPaths {
  if ($env:OC_TUI_WTPATHS) { return @($env:OC_TUI_WTPATHS -split ';' | Where-Object { $_ }) }
  $c = @((Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'),
    (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json'),
    (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\settings.json'))
  return @($c | Where-Object { Test-Path -LiteralPath $_ })
}
# $block is the text of the font entry ("font": { ... }) or $null to remove it. Returns the font text that
# was there before ('' when none) so a later reset can put it back, or $false when the file was not edited.
function Edit-WtFile([string]$path, $block) {
  $bytes = [IO.File]::ReadAllBytes($path)
  $bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
  $text = [Text.Encoding]::UTF8.GetString($bytes)
  if ($bom) { $text = $text.Substring(1) }
  $fontRe = '"font"\s*:\s*\{[^{}]*\}'
  $defRe = '(?s)("defaults"\s*:\s*\{)((?:[^{}]|\{[^{}]*\})*)(\})'
  $prior = ''
  $m = [regex]::Match($text, $defRe)
  if ($m.Success) {
    $body = $m.Groups[2].Value
    $fm = [regex]::Match($body, $fontRe)
    if ($fm.Success) { $prior = $fm.Value; $body = $body.Remove($fm.Index, $fm.Length); $body = [regex]::Replace($body, '^(\s*),', '$1', 'Singleline') }
    if ($block) {
      $sep = $(if ($body.Trim()) { ',' } else { '' })
      $nl = $(if ($text.Contains("`r`n")) { "`r`n" } else { "`n" })
      $im = [regex]::Match($body, '\n([ \t]+)\S')
      $ind = $(if ($im.Success) { $im.Groups[1].Value } else { '        ' })
      $body = $nl + $ind + $block + $sep + $body
    }
    $new = $text.Substring(0, $m.Groups[2].Index) + $body + $text.Substring($m.Groups[2].Index + $m.Groups[2].Length)
  } else {
    $pm = [regex]::Match($text, '"profiles"\s*:\s*\{')
    if (-not $pm.Success -or -not $block) { return $false }
    $new = $text.Insert($pm.Index + $pm.Length, "`r`n    ""defaults"": { " + $block + " },")
  }
  if ($new -eq $text) { return $prior }
  # the result must still be valid and must say what we meant
  try {
    $j = (Strip-Jsonc $new) | ConvertFrom-Json
    $got = $j.profiles.defaults.font
    if ($block) { if (-not $got) { return $false } } elseif ($got -and -not $prior) { return $false }
  } catch { return $false }
  $out = [Text.Encoding]::UTF8.GetBytes($new)
  if ($bom) { $out = [byte[]](0xEF, 0xBB, 0xBF) + $out }
  [IO.File]::WriteAllBytes($path, $out)
  return $prior
}
function Apply-WtFont([string]$face, [int]$size) {
  $paths = @(Get-WtPaths)
  if ($paths.Count -eq 0) { return @('warn', 'Windows Terminal settings.json was not found.') }
  if (-not $script:Cfg.font.ContainsKey('wt')) { $script:Cfg.font['wt'] = @{} }
  $done = 0
  foreach ($p in $paths) {
    $key = ($p -replace '[^A-Za-z0-9]', '_')
    $entry = $null
    if ($face) { $entry = '"font": { "face": "' + $face + '", "size": ' + $size + ' }' }
    elseif ($script:Cfg.font.wt.ContainsKey($key)) { $entry = [string]$script:Cfg.font.wt[$key].prior; if (-not $entry) { $entry = $null } }
    else { continue }
    New-Item -ItemType Directory -Force -Path $BackDir | Out-Null
    $bk = Join-Path $BackDir ('wt-settings-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + $done + '.json')
    Copy-Item -LiteralPath $p -Destination $bk -Force
    $prior = Edit-WtFile $p $entry
    if ($prior -is [bool] -and -not $prior) { Remove-Item -LiteralPath $bk -Force -ErrorAction SilentlyContinue; return @('err', 'settings.json was left untouched: the edit would not have kept it valid.') }
    if ($face -and -not $script:Cfg.font.wt.ContainsKey($key)) { $script:Cfg.font.wt[$key] = @{ prior = [string]$prior; backup = $bk } }
    if (-not $face) { [void]$script:Cfg.font.wt.Remove($key) }
    $done++
  }
  Save-Cfg
  if (-not $face) { return @('ok', 'Windows Terminal font put back as it was. Reopen the tab if it does not change.') }
  return @('ok', ('Windows Terminal font set to ' + $face + ' ' + $size + '. Backup of settings.json: ' + $BackDir))
}
function Get-ConsoleFonts {
  try {
    $k = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Console\TrueTypeFont' -ErrorAction Stop
    $n = @($k.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' -and $_.Value -match '^[A-Za-z]' } | ForEach-Object { [string]$_.Value })
    if ($n.Count) { return ($n -join ', ') }
  } catch { }
  return 'Consolas, Lucida Console'
}
function Apply-ConsoleFont([string]$face, [int]$size) {
  try {
    Add-Type -Namespace OCI -Name Fnt -ErrorAction Stop -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] public struct COORD { public short X; public short Y; }
[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] public struct CFI { public int cbSize; public int nFont; public COORD dwFontSize; public int FontFamily; public int FontWeight; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string FaceName; }
[DllImport("kernel32.dll", SetLastError = true)] public static extern IntPtr GetStdHandle(int n);
[DllImport("kernel32.dll", SetLastError = true)] public static extern bool GetCurrentConsoleFontEx(IntPtr h, bool max, ref CFI i);
[DllImport("kernel32.dll", SetLastError = true)] public static extern bool SetCurrentConsoleFontEx(IntPtr h, bool max, ref CFI i);
'@
  } catch { if (-not ('OCI.Fnt' -as [type])) { return @('err', 'The Windows font API could not be loaded.') } }
  $h = [OCI.Fnt]::GetStdHandle(-11)
  $cfi = New-Object 'OCI.Fnt+CFI'
  $cfi.cbSize = [Runtime.InteropServices.Marshal]::SizeOf([type]'OCI.Fnt+CFI')
  if (-not [OCI.Fnt]::GetCurrentConsoleFontEx($h, $false, [ref]$cfi)) { return @('err', 'This window does not allow changing the font from here.') }
  if ($face) {
    if (-not $script:Cfg.font.ContainsKey('orig')) { $script:Cfg.font['orig'] = @{ face = $cfi.FaceName; size = [int]$cfi.dwFontSize.Y }; Save-Cfg }
  } else {
    if (-not $script:Cfg.font.ContainsKey('orig')) { return @('ok', 'The font was never changed, nothing to restore.') }
    $face = [string]$script:Cfg.font.orig.face; $size = [int]$script:Cfg.font.orig.size
  }
  $c = New-Object 'OCI.Fnt+COORD'; $c.X = 0; $c.Y = [int16]$size
  $cfi.dwFontSize = $c; $cfi.FaceName = $face; $cfi.FontFamily = 54; $cfi.FontWeight = 400
  if (-not [OCI.Fnt]::SetCurrentConsoleFontEx($h, $false, [ref]$cfi)) { return @('err', 'Windows refused that font in this console.') }
  $chk = New-Object 'OCI.Fnt+CFI'
  $chk.cbSize = [Runtime.InteropServices.Marshal]::SizeOf([type]'OCI.Fnt+CFI')
  [void][OCI.Fnt]::GetCurrentConsoleFontEx($h, $false, [ref]$chk)
  if ($chk.FaceName -ne $face) {
    # put the old font back so the window is not left half changed
    if ($script:Cfg.font.ContainsKey('orig') -and $chk.FaceName -ne [string]$script:Cfg.font.orig.face) { $cfi.FaceName = [string]$script:Cfg.font.orig.face; $c.Y = [int16]$script:Cfg.font.orig.size; $cfi.dwFontSize = $c; [void][OCI.Fnt]::SetCurrentConsoleFontEx($h, $false, [ref]$cfi) }
    return @('warn', ('This console refused "' + $face + '" and kept "' + $chk.FaceName + '". Older classic consoles only take the fonts Windows registers for them (' + (Get-ConsoleFonts) + '). Windows Terminal accepts any installed font.'))
  }
  return @('ok', ('Console font set to ' + $face + ' ' + $size + '. It lasts while this window is open and is applied again at every launcher start.'))
}
function Apply-Font {
  $face = [string](Get-Val 'OCUI_FONT'); $size = [int](Get-Val 'OCUI_FONT_SIZE')
  try {
    if ($env:WT_SESSION -or $env:OC_TUI_WTPATHS) { return Apply-WtFont $face $size }
    if ($env:TERM_PROGRAM -or $env:VSCODE_PID) { return @('warn', 'This terminal keeps its font in its own settings (VS Code: terminal.integrated.fontFamily).') }
    return Apply-ConsoleFont $face $size
  } catch { return @('err', ('Could not change the font: ' + $_.Exception.Message)) }
}

# ---------------------------------------------------------------- settings screens
function Edit-Setting($s) {
  $cur = Get-Val $s.Key
  $new = $null
  if ($s.Type -eq 'bool') { $new = if ([int]$cur -eq 1) { 0 } else { 1 } }
  elseif ($s.Type -eq 'enum') {
    $ix = [Array]::IndexOf(@($s.Values), $cur)
    $new = $s.Values[($ix + 1) % $s.Values.Count]
  } elseif ($s.Type -eq 'font') {
    $new = Pick-Font
    if ($null -eq $new) { return $null }
  } else {
    while ($true) {
      $t = Read-Text ((T $s.Label) + ' - ' + (T $s.Help)) ([string]$cur)
      if ($t -eq '' -and $s.Type -ne 'path') { return $null }
      if ($t -eq '-' -and $s.Type -eq 'path') { $t = '' }
      $r = Test-Val $s $t
      if ($r.ok) { $new = $r.v; break }
      Say 'err' $r.err
    }
  }
  Set-Val $s $new
  Log ('setting ' + $s.Key + ' -> ' + (Safe-Val $s.Key))
  if ($s.Key -like 'OCUI_*') { Init-Ui }
  if ($s.Key -eq 'OCUI_FONT' -or $s.Key -eq 'OCUI_FONT_SIZE') {
    $script:FontMsg = Apply-Font
    Log ('font ' + $script:FontMsg[0] + ': ' + $script:FontMsg[1])
    if ($script:FontMsg[0] -ne 'ok') {
      # nothing changed on screen, so the saved value must not say otherwise
      Set-Val $s $cur
      $script:FontMsg = @($script:FontMsg[0], ($script:FontMsg[1] + ' The setting was not changed.'))
      return $null
    }
  }
  return $s
}
function Format-Val($s) {
  $v = Get-Val $s.Key
  switch ($s.Type) { 'bool' { if ([int]$v -eq 1) { return (T 'on') } else { return (T 'off') } } default { if ([string]$v -eq '') { return (T '(auto)') } if ($s.Key -eq 'OCUI_LANG') { return (Lang-Name $v) } return [string]$v } }
}
function Lang-Name([string]$c) {
  switch ($c) { 'auto' { return (T 'auto') } 'en' { return 'English' } 'es' { return ('Espa' + [char]0xF1 + 'ol') } 'fr' { return ('Fran' + [char]0xE7 + 'ais') } 'de' { return 'Deutsch' } 'pt' { return ('Portugu' + [char]0xEA + 's') } 'it' { return 'Italiano' } 'tr' { return ('T' + [char]0xFC + 'rk' + [char]0xE7 + 'e') } default { return $c } }
}
function Describe-Setting($s) {
  if ($s.Type -eq 'bool') { $dv = $(if ([int]$s.Default -eq 1) { T 'on' } else { T 'off' }) }
  elseif ([string]$s.Default -eq '') { $dv = T '(auto)' }
  elseif ($s.Key -eq 'OCUI_LANG') { $dv = Lang-Name ([string]$s.Default) }
  else { $dv = [string]$s.Default }
  $d = (T ([string]$s.Help)) + ' ' + (Tf 'Default: {0}.' $dv)
  if ($s.Type -eq 'bool') { $d += ' ' + (T 'Enter toggles it.') }
  elseif ($s.Type -eq 'enum') { $d += ' ' + (Tf 'Enter cycles: {0}.' (@($s.Values | ForEach-Object { if ($s.Key -eq 'OCUI_LANG') { Lang-Name $_ } else { $_ } }) -join ', ')) }
  elseif ($s.Type -eq 'int') { $d += ' ' + (Tf 'Range {0} to {1}.' $s.Min $s.Max) }
  if ($s.Apply -ne 'now') { $d += ' ' + (Tf 'Applies at the {0}.' (T $s.Apply)) }
  return $d
}
function Group-Menu([string]$group) {
  $list = @($Schema | Where-Object { $_.Group -eq $group })
  $pos = 0; $msg = $null
  while ($true) {
    $items = @()
    foreach ($s in $list) {
      $mod = if ($script:Cfg.settings.ContainsKey($s.Key)) { '*' } else { ' ' }
      $items += @{ L = ($mod + ' ' + $s.Label); V = (Format-Val $s); S = $(if ($mod -eq '*') { 'warn' } else { 'accent' }); H = (Describe-Setting $s) }
    }
    $items += @{ L = ($script:I.back + ' Back'); H = 'Return to the settings groups.' }
    $head = @(); if ($msg) { $head += $msg; $head += '' }
    $r = Show-Menu ($script:I.gear + ' ' + (T 'Settings') + ' - ' + (T $group)) $items '* = changed from the default. Enter edits or toggles the selected value.' $head $pos
    if ($r -eq -1 -or $r -eq $list.Count) { return }
    $pos = $r
    $s = $list[$r]
    $done = Edit-Setting $s
    if ($done) {
      $m = (P (Style 'ok') ($script:I.ok + ' ' + (Tf 'Saved: {0} = {1}' (T $s.Label) (Format-Val $s))))
      if ($s.Apply -ne 'now') { $m += "`n" + (P (Style 'warn') ($script:I.warn + ' ' + (Tf 'Takes effect at the {0}; a service already running keeps the old value until then.' (T $s.Apply)))) }
      if ($script:FontMsg) { $m += "`n" + (P (Style $script:FontMsg[0]) ($script:I.gear + ' ' + $script:FontMsg[1])); $script:FontMsg = $null }
      $msg = $m
    } else {
      $msg = (P (Style 'dim') (T 'No change.'))
      if ($script:FontMsg) { $msg += "`n" + (P (Style $script:FontMsg[0]) ($script:I.gear + ' ' + $script:FontMsg[1])); $script:FontMsg = $null }
    }
  }
}
function Settings-Menu {
  $pos = 0
  while ($true) {
    $items = @()
    foreach ($g in $Groups) {
      $n = @($Schema | Where-Object { $_.Group -eq $g -and $script:Cfg.settings.ContainsKey($_.Key) }).Count
      $items += @{ L = $g; V = $(if ($n) { Tf '{0} changed' $n } else { '' }); S = 'warn'; H = $GroupHelp[$g] }
    }
    $items += @{ L = 'Reset to default values'; S = 'err'; H = 'Put every setting back to its default. Your connection setup (command, shortcuts) is not touched. Asks first.' }
    $items += @{ L = ($script:I.back + ' Back'); H = 'Return to the main menu.' }
    $r = Show-Menu ($script:I.gear + ' Settings') $items (Tf 'Every change is saved at once to {0}' $CfgPath) $null $pos
    if ($r -eq -1 -or $r -eq $Groups.Count + 1) { return }
    $pos = $r
    if ($r -eq $Groups.Count) {
      if (Confirm-Box 'Reset every setting to its default?' @('Your connection setup (shim, shortcuts) is not touched.')) {
        $script:Cfg.settings = @{}; Save-Cfg; Init-Ui
        Log 'settings reset to defaults'
        [void](Apply-Font)
      }
      continue
    }
    Group-Menu $Groups[$r]
  }
}

# ---------------------------------------------------------------- setup / status / renew / uninstall
function Test-Configured { return (($script:Cfg.setup -is [hashtable]) -and ($script:Cfg.setup.done -eq $true) -and (Test-Path -LiteralPath $ShimPath)) }
function Get-UserPath {
  if ($env:OC_TUI_FAKEPATH) { if (Test-Path -LiteralPath $env:OC_TUI_FAKEPATH) { return [string](Get-Content -LiteralPath $env:OC_TUI_FAKEPATH -Raw).Trim() } return '' }
  return [string][Environment]::GetEnvironmentVariable('Path', 'User')
}
function Set-UserPath([string]$v) {
  if ($env:OC_TUI_FAKEPATH) { [IO.File]::WriteAllText($env:OC_TUI_FAKEPATH, $v); return }
  [Environment]::SetEnvironmentVariable('Path', $v, 'User')
}
function Get-LinkDirs {
  if ($env:OC_TUI_LNKDIRS) { return @($env:OC_TUI_LNKDIRS -split ';') }
  return @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Programs'))
}
function Remove-PathEntry([string]$dir) {
  $p = Get-UserPath
  $parts = @($p -split ';' | Where-Object { $_ -and ($_.TrimEnd('\') -ine $dir.TrimEnd('\')) })
  Set-UserPath ($parts -join ';')
}
function Pick-Method {
  $opts = @(
    @{ L = 'WARP'; V = 'Cloudflare WARP'; m = 'WARP'; H = 'Cloudflare WARP in local proxy mode. Every rotation asks for a new registration, which gives a new exit IP. Needs the WARP client (offered if missing).' },
    @{ L = 'TOR'; V = 'Portable Tor'; m = 'TOR'; H = 'Tor is downloaded once, run hidden and offered to opencode through a built-in HTTP bridge. Slower, but a new circuit is a new IP.' },
    @{ L = 'PROXY'; V = 'Free or your own list'; m = 'PROXY'; H = 'Public HTTP proxies from a list (yours, in any format, or the free default). Each one is tested first and burned ones are skipped.' },
    @{ L = 'NONE'; V = 'Direct, no proxy'; m = 'NONE'; H = 'No proxy: opencode uses your real connection and nothing is rotated.' })
  $r = Show-Menu 'Setup 1/3 - connection method' ($opts + @(@{ L = ($script:I.back + ' Cancel'); H = 'Leave the setup without changing anything.' })) 'The proxy lives only in the opencode process; the rest of the system stays direct.'
  if ($r -eq -1 -or $r -eq 4) { return $null }
  return $opts[$r].m
}
function Ask-Setting([string]$key, [string]$step) {
  $s = Get-Setting $key
  while ($true) {
    $t = Read-Text ((T $step) + ' ' + (T $s.Label) + ' - ' + (T $s.Help)) ([string](Get-Val $key))
    if ($t -eq '<') { return '<' }
    if ($t -eq '') { return [string](Get-Val $key) }
    $r = Test-Val $s $t
    if ($r.ok) { return $r.v }
    Say 'err' $r.err
  }
}
# The command file. It runs the fixed launcher copy; when that copy is gone it offers a fresh download.
function Shim-Text([string]$arg) {
  $dir = Split-Path -Parent $Official
  $l = @('@echo off', 'rem Added by OpenCode-Infinite setup. Uninstall in the launcher removes it.',
    ('if exist "' + $Official + '" goto go'),
    ('echo OpenCode-Infinite is not installed at: ' + ($Official -replace '([&|<>^])', '^$1')),
    'choice /c YN /n /m "Download it again now? "', 'if errorlevel 2 exit /b 1',
    ('if not exist "' + $dir + '" mkdir "' + $dir + '"'),
    ('curl.exe -fsSL -o "' + $Official + '.tmp" "' + $RawUrl + '" && move /y "' + $Official + '.tmp" "' + $Official + '" >nul'),
    ('if not exist "' + $Official + '" (echo Download failed. Check the connection and run this command again. & exit /b 1)'),
    ':go', ('call "' + $Official + '" ' + $arg + ' %*'), 'exit /b %errorlevel%')
  return (($l -join "`r`n") + "`r`n")
}
function Run-Setup {
  Log 'setup start'
  $ans = @{}
  $step = 0
  $method = $null
  while ($true) {
    if ($step -eq 0) {
      $method = Pick-Method
      if (-not $method) { return $false }
      $ans['OC_EGRESS_DEFAULT'] = $method
      $step = 1; continue
    }
    if ($step -eq 1) {
      Clear-Screen
      WL (P (Style 'title') (T 'Setup 2/3 - details'))
      WL (P (Style 'dim') (T 'Type < to go back. Enter keeps the value shown.'))
      $back = $false
      if ($method -eq 'WARP') {
        $v = Ask-Setting 'PROXY_PORT' 'WARP'
        if ($v -eq '<') { $back = $true } else { $ans['PROXY_PORT'] = $v }
      } elseif ($method -eq 'TOR') {
        $v = Ask-Setting 'TOR_SOCKS_PORT' 'Tor'
        if ($v -eq '<') { $back = $true } else {
          $ans['TOR_SOCKS_PORT'] = $v
          $v2 = Ask-Setting 'TOR_HTTP_PORT' 'Tor'
          if ($v2 -eq '<') { $back = $true } else { $ans['TOR_HTTP_PORT'] = $v2 }
        }
      } elseif ($method -eq 'PROXY') {
        $v = Ask-Setting 'PROXY_LIST_URL' 'Proxies'
        if ($v -eq '<') { $back = $true } else { $ans['PROXY_LIST_URL'] = $v }
      } else { Say 'ok' 'Nothing to ask for a direct connection.' }
      if ($back) { $step = 0; continue }
      $step = 2; continue
    }
    if ($step -eq 2) {
      $opts = @(@{ L = 'CLI'; V = 'terminal'; m = 'CLI'; H = 'The terminal interface. The opencode command and the shortcut always use it.' }, @{ L = 'Desktop'; V = 'OpenCode app'; m = 'DESKTOP'; H = 'The OpenCode desktop app; it is restarted after every new IP.' }, @{ L = 'Ask every time'; V = ''; m = 'ASK'; H = 'Show the CLI or Desktop choice every time the launcher opens.' })
      $r = Show-Menu 'Setup 3/3 - run mode' ($opts + @(@{ L = ($script:I.back + ' Back'); H = 'Return to the connection details.' })) 'The shortcut and the opencode command use the CLI; this is the launcher menu default.'
      if ($r -eq -1 -or $r -eq 3) { $step = 1; continue }
      $ans['OC_MODE_DEFAULT'] = $opts[$r].m
      $step = 3; continue
    }
    if ($step -eq 3) {
      $head = @((P (Style 'title') (T 'Review')), '')
      foreach ($k in $ans.Keys) { $head += ('   ' + (Pad (T (Get-Setting $k).Label) 26) + ' ' + (P (Style 'accent') ([string]$ans[$k]))) }
      $head += ''
      $head += (P (Style 'dim') ('   ' + (T 'Adds: opencode command (shim), two shortcuts, one PATH entry. Backups are kept.')))
      $r = Show-Menu 'Apply setup' @(@{ L = ($script:I.ok + ' Apply'); S = 'ok'; H = 'Save the settings, create the opencode command, the shortcuts and the PATH entry, then test the connection.' }, @{ L = ($script:I.back + ' Back'); H = 'Change an answer.' }) '' $head 0
      if ($r -eq -1 -or $r -eq 1) { $step = 2; continue }
      break
    }
  }
  Clear-Screen
  WL (P (Style 'title') ($script:I.link + ' ' + (T 'Connecting opencode')))
  WL ''
  $total = 6; $n = 0
  try {
    # 1 backup
    $n++; Progress $n $total 'Backing up the current configuration'
    New-Item -ItemType Directory -Force -Path $BackDir | Out-Null
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    if (Test-Path -LiteralPath $CfgPath) { Copy-Item -LiteralPath $CfgPath -Destination (Join-Path $BackDir ('config-' + $stamp + '.json')) -Force }
    $pathBk = Join-Path $BackDir 'user_path.txt'
    if (-not (Test-Path -LiteralPath $pathBk)) { [IO.File]::WriteAllText($pathBk, (Get-UserPath)) }
    $touched = @{}
    if ($script:Cfg.setup -is [hashtable] -and $script:Cfg.setup.touched -is [hashtable]) { $touched = $script:Cfg.setup.touched }
    foreach ($k in $ans.Keys) {
      if (-not $touched.ContainsKey($k)) { if ($script:Cfg.settings.ContainsKey($k)) { $touched[$k] = $script:Cfg.settings[$k] } else { $touched[$k] = $null } }
    }
    # 2 save
    $n++; Progress $n $total 'Saving config.json'
    foreach ($k in $ans.Keys) { Set-Val (Get-Setting $k) $ans[$k] }
    # 3 shim
    $n++; Progress $n $total 'Creating the opencode command'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Official) | Out-Null
    if ($Self -ne $Official) { Copy-Item -LiteralPath $Self -Destination $Official -Force }
    New-Item -ItemType Directory -Force -Path $ShimDir | Out-Null
    $utf8 = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($ShimPath, (Shim-Text '--run'), $utf8)
    [IO.File]::WriteAllText($ShimInfPath, (Shim-Text ''), $utf8)
    # 4 shortcuts
    $n++; Progress $n $total 'Creating shortcuts'
    $made = @()
    $wsh = New-Object -ComObject WScript.Shell
    foreach ($dir in (Get-LinkDirs)) {
      if (-not $dir) { continue }
      $lnk = Join-Path $dir 'OpenCode Infinite (egress).lnk'
      $sc = $wsh.CreateShortcut($lnk)
      $sc.TargetPath = $env:SystemRoot + '\System32\cmd.exe'
      $sc.Arguments = '/d /k ""' + $Official + '" --run"'
      $sc.WorkingDirectory = $env:USERPROFILE
      $sc.Description = 'Start opencode through your configured connection'
      $ico = Join-Path $env:LOCALAPPDATA 'Programs\ai.opencode.desktop\OpenCode.exe'
      if (Test-Path -LiteralPath $ico) { $sc.IconLocation = $ico }
      $sc.Save()
      $made += $lnk
    }
    # 5 PATH
    $n++; Progress $n $total 'Adding the command to your PATH'
    $pathAdded = $false
    $up = Get-UserPath
    if (-not (@($up -split ';') | Where-Object { $_.TrimEnd('\') -ieq $ShimDir.TrimEnd('\') })) {
      Set-UserPath (($ShimDir + ';' + $up).TrimEnd(';'))
      $pathAdded = $true
    } elseif ($script:Cfg.setup.pathAdded -eq $true) { $pathAdded = $true }
    $script:Cfg.setup = @{ done = $true; method = $method; launcher = $Official; shim = $ShimPath; shimInf = $ShimInfPath; shortcuts = $made; pathAdded = $pathAdded; touched = $touched; createdUtc = (Get-Date).ToUniversalTime().ToString('o'); verified = $false }
    Save-Cfg
    Log ('setup applied: method ' + $method + ', shim ' + $ShimPath)
  } catch {
    Log ('setup stopped: ' + $_.Exception.Message) 'error'
    Say 'err' (Tf 'Setup stopped: {0}' $_.Exception.Message)
    Say 'warn' 'Nothing was left half done that Uninstall cannot remove. Fix the problem and run setup again.'
    Wait-Key; return $false
  }
  # 6 verify
  $n++; Progress $n $total 'Checking that it works'
  $rc = Run-Child 'Checking the connection' '--verify' (Join-Path $State 'verify.log') 300
  Log ('setup verify rc=' + $rc)
  WL ''
  if ($rc -eq 0) {
    $script:Cfg.setup.verified = $true; $script:Cfg.setup.verifiedUtc = (Get-Date).ToUniversalTime().ToString('o'); Save-Cfg
    Remove-Item -LiteralPath (Join-Path $State 'renew_needed.txt') -Force -ErrorAction SilentlyContinue
    Say 'ok' (Tf 'Connected: opencode now starts through {0}.' $method)
  } else {
    Say 'err' (Tf 'The check failed (code {0}). Setup is saved; fix the cause and use Renew or Connect again.' $rc)
    Show-LogTail (Join-Path $State 'verify.log') 8
  }
  WL ''
  Say 'ok' 'Type "opencode" in a NEW terminal, or use the "OpenCode Infinite (egress)" shortcut.'
  Wait-Key
  return $true
}
function Show-Status {
  $s = $script:Cfg.setup
  $ok = { param($b) if ($b) { return (P (Style 'ok') ($script:I.ok + ' ' + (T 'yes'))) } return (P (Style 'err') ($script:I.err + ' ' + (T 'missing'))) }
  $head = @()
  $head += ('   ' + (Pad (T 'Method') 14) + (P (Style 'accent') ([string]$s.method)))
  $head += ('   ' + (Pad (T 'Run mode') 14) + (P (Style 'accent') ([string](Get-Val 'OC_MODE_DEFAULT'))))
  $head += ('   ' + (Pad (T 'Command') 14) + (& $ok (Test-Path -LiteralPath $ShimPath)) + '  ' + (P (Style 'dim') $ShimPath))
  $head += ('   ' + (Pad (T 'On PATH') 14) + (& $ok (@((Get-UserPath) -split ';') | Where-Object { $_.TrimEnd('\') -ieq $ShimDir.TrimEnd('\') })))
  $sc = 0; foreach ($l in @($s.shortcuts)) { if ($l -and (Test-Path -LiteralPath $l)) { $sc++ } }
  $head += ('   ' + (Pad (T 'Shortcuts') 14) + (Tf '{0} of {1}' $sc @($s.shortcuts).Count))
  $head += ('   ' + (Pad (T 'Launcher') 14) + (& $ok (Test-Path -LiteralPath $s.launcher)))
  $vs = if ($s.verified -eq $true) { P (Style 'ok') ($script:I.ok + ' ' + $s.verifiedUtc) } else { P (Style 'warn') ($script:I.warn + ' ' + (T 'not verified')) }
  $head += ('   ' + (Pad (T 'Last check') 14) + $vs)
  $head += ('   ' + (Pad (T 'Repository') 14) + (P (Style 'accent') $Repo))
  if ($s.launcher -ne $Official) { $head += ''; $head += (P (Style 'warn') ($script:I.warn + ' ' + (T 'This launcher is not the one that set it up. Reconfigure to repair the command.'))) }
  $head += ''
  $r = Show-Menu ($script:I.link + ' Connect with opencode') @(@{ L = 'Reconfigure (run setup again)'; H = 'Run the setup again to change the method or repair the opencode command.' }, @{ L = ($script:I.back + ' Back'); H = 'Return to the main menu.' }) '' $head 0
  if ($r -eq 0) { [void](Run-Setup) }
}
function Do-Renew {
  if (-not (Confirm-Box 'Renew the session?' @('Closes every running opencode process.', 'Copies auth.json to your Desktop, then clears the saved tokens.', 'Gets a new IP / WARP registration / Tor circuit / proxy.'))) { return }
  Clear-Screen
  WL (P (Style 'title') ($script:I.renew + ' ' + (T 'Renewing')))
  $log = Join-Path $State 'renew.log'
  Log 'renew start'
  $rc = Run-Child 'Renewing the session' '--renew' $log 420
  Log ('renew rc=' + $rc)
  WL ''
  if ($rc -eq 0) {
    Remove-Item -LiteralPath (Join-Path $State 'renew_needed.txt') -Force -ErrorAction SilentlyContinue
    Say 'ok' 'Renewed. Open opencode again; you may need to log in once more.'
  } else {
    Say 'err' (Tf 'Renew did not finish (code {0}).' $rc)
    Show-LogTail $log 8
    Say 'warn' 'Try again in a minute, or pick another connection method in Connect with opencode.'
  }
  Wait-Key
}
function Do-Uninstall {
  $s = $script:Cfg.setup
  if (-not (Confirm-Box 'Uninstall the opencode connection?' @('Removes only what setup added: the opencode command, the shortcuts and the PATH entry.', 'Restores the settings setup changed. Your other settings and your opencode files are kept.'))) { return }
  Clear-Screen
  WL (P (Style 'title') ($script:I.trash + ' ' + (T 'Uninstalling')))
  WL ''
  $total = 4; $n = 0
  try {
    $n++; Progress $n $total 'Removing shortcuts'
    foreach ($l in @($s.shortcuts)) { if ($l -and (Test-Path -LiteralPath $l)) { Remove-Item -LiteralPath $l -Force } }
    $n++; Progress $n $total 'Removing the opencode command'
    if (Test-Path -LiteralPath $ShimPath) { Remove-Item -LiteralPath $ShimPath -Force }
    if (Test-Path -LiteralPath $ShimInfPath) { Remove-Item -LiteralPath $ShimInfPath -Force }
    if ($Self -ne $Official -and (Test-Path -LiteralPath $Official)) { Remove-Item -LiteralPath $Official -Force; Remove-Item -LiteralPath (Split-Path -Parent $Official) -Force -ErrorAction SilentlyContinue }
    if ((Test-Path -LiteralPath $ShimDir) -and -not (Get-ChildItem -LiteralPath $ShimDir -Force)) { Remove-Item -LiteralPath $ShimDir -Force }
    $n++; Progress $n $total 'Restoring PATH'
    if ($s.pathAdded -eq $true) { Remove-PathEntry $ShimDir }
    $n++; Progress $n $total 'Restoring settings'
    if ($s.touched -is [hashtable]) {
      foreach ($k in $s.touched.Keys) {
        if ($null -eq $s.touched[$k]) { [void]$script:Cfg.settings.Remove($k) } else { $script:Cfg.settings[$k] = $s.touched[$k] }
      }
    }
    $script:Cfg.setup = @{}
    Save-Cfg
    Init-Ui
    WL ''
    Say 'ok' (Tf 'Uninstalled. Backups stay in {0}' $BackDir)
    Log 'uninstalled'
  } catch { Log ('uninstall stopped: ' + $_.Exception.Message) 'error'; Say 'err' (Tf 'Uninstall stopped: {0}' $_.Exception.Message) }
  Wait-Key
}


# ---------------------------------------------------------------- activity log and support report
# launcher.log is the one place every part of the launcher writes to (the batch through :log, this UI
# through Log). The support report gathers it with the system, versions and settings into one text file.
function Safe-Val($key) {
  $s = Get-Setting $key
  $v = [string](Get-Val $key)
  if ($s.Type -eq 'listsrc' -or $s.Type -eq 'url') {
    $v = $v -replace '(://)[^/\s:@]+:[^/\s@]+@', '$1***@'
    $v = $v -replace '\?.*$', '?...'
  }
  return $v
}
function Probe-Cmd([string]$exe, [string]$cmdArgs, [int]$ms = 6000) {
  try {
    $psi = New-Object Diagnostics.ProcessStartInfo
    if ($exe -match '\.(cmd|bat)$') { $psi.FileName = $env:SystemRoot + '\System32\cmd.exe'; $psi.Arguments = '/d /s /c ""' + $exe + '" ' + $cmdArgs + '"' }
    else { $psi.FileName = $exe; $psi.Arguments = $cmdArgs }
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.RedirectStandardInput = $true
    $p = [Diagnostics.Process]::Start($psi)
    $p.StandardInput.Close()
    $out = $p.StandardOutput.ReadToEndAsync(); $err = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($ms)) { try { $p.Kill() } catch { }; return ('(no answer in ' + [int]($ms / 1000) + 's)') }
    $t = ([string]$out.Result + ' ' + [string]$err.Result).Trim()
    if (-not $t) { return '(no output)' }
    return ((@($t -split '\r?\n' | Where-Object { $_.Trim() } | Select-Object -First 3)) -join ' | ')
  } catch { return ('(could not run: ' + $_.Exception.Message + ')') }
}
function Redact([string]$text) {
  $t = $text
  $up = [string]$env:USERPROFILE
  if ($up) { $t = [regex]::Replace($t, [regex]::Escape($up), '%USERPROFILE%', 'IgnoreCase') }
  foreach ($pair in @(@($env:USERNAME, '<user>'), @($env:COMPUTERNAME, '<pc>'))) {
    if ($pair[0] -and ([string]$pair[0]).Length -ge 3) { $t = [regex]::Replace($t, '\b' + [regex]::Escape([string]$pair[0]) + '\b', $pair[1], 'IgnoreCase') }
  }
  $t = [regex]::Replace($t, '(://)[^/\s:@]+:[^/\s@]+@', '$1***@')
  $t = [regex]::Replace($t, '[\w.+-]+@[\w-]+\.[\w.-]+', '<email>')
  $t = [regex]::Replace($t, '(?i)(bearer\s+)[A-Za-z0-9._~+/=-]{12,}', '$1<token>')
  $t = [regex]::Replace($t, '\b(?:sk|pk|ghp|gho|ghu|ghs|xox[bap])[-_][A-Za-z0-9_-]{16,}\b', '<token>')
  $t = [regex]::Replace($t, 'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}', '<jwt>')
  $t = [regex]::Replace($t, '(?i)([?&](?:key|token|api_key|apikey|auth|password|pass|secret)=)[^&\s"]+', '$1***')
  if ([int](Get-Val 'LOG_MASK_IP') -eq 1) {
    $ev = [Text.RegularExpressions.MatchEvaluator] {
      param($m)
      $o = @($m.Groups[1].Value, $m.Groups[2].Value, $m.Groups[3].Value, $m.Groups[4].Value) | ForEach-Object { [int]$_ }
      if (($o | Where-Object { $_ -gt 255 }).Count) { return $m.Value }
      if ($o[0] -eq 127 -or $o[0] -eq 10 -or $o[0] -eq 0 -or $o[0] -eq 255 -or ($o[0] -eq 192 -and $o[1] -eq 168) -or ($o[0] -eq 172 -and $o[1] -ge 16 -and $o[1] -le 31) -or ($o[0] -eq 169 -and $o[1] -eq 254)) { return $m.Value }
      return ([string]$o[0] + '.' + [string]$o[1] + '.x.x')
    }
    $lines = @()
    foreach ($l in ($t -split "`r?`n")) {
      # version numbers look like IPs: lines that talk about a version are left alone
      if ($l -match '(?i)version|build|v\d+\.\d+') { $lines += $l } else { $lines += [regex]::Replace($l, '(?<![\d.])(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})(?![\d.])', $ev) }
    }
    $t = $lines -join "`r`n"
    $t = [regex]::Replace($t, '\b(?:[0-9A-Fa-f]{1,4}:){5,7}[0-9A-Fa-f]{1,4}\b|\b(?:[0-9A-Fa-f]{1,4}:){1,6}:(?:[0-9A-Fa-f]{1,4})?\b', '<ipv6>')
  }
  return $t
}
function Tail-Of([string]$path, [int]$n) {
  if (-not (Test-Path -LiteralPath $path)) { return '(missing)' }
  $t = @(Get-Content -LiteralPath $path -Tail $n -ErrorAction SilentlyContinue)
  if (-not $t.Count) { return '(empty)' }
  return ($t -join "`r`n")
}
function Safe-Section([scriptblock]$body, $A) {
  try { & $body } catch { & $A ('(this section failed: ' + $_.Exception.Message + ')'); Log ('report section failed: ' + $_.Exception.Message) 'error' }
}
function New-Report {
  $sb = New-Object Text.StringBuilder
  $A = { param($s) [void]$sb.AppendLine([string]$s) }
  $H = { param($s) [void]$sb.AppendLine(''); [void]$sb.AppendLine('=== ' + $s + ' ==='); }
  $noProbe = [bool]$env:OC_TUI_NOPROBE
  $total = 6
  & $A 'OpenCode Infinite - support report'
  & $A ('Generated   ' + (Get-Date).ToString('o'))
  & $A 'Launcher    v2.29'
  & $A ('File        ' + $Self)
  try { $fi = Get-Item -LiteralPath $Self; & $A ('Size/date   ' + $fi.Length + ' bytes, ' + $fi.LastWriteTime.ToString('s')); & $A ('SHA-256     ' + (Get-FileHash -LiteralPath $Self -Algorithm SHA256).Hash) } catch { }
  & $A 'Personal data (user name, PC name, e-mails, tokens, passwords, and by default public IPs) is removed from this file. Read it before sharing.'

  Progress 1 $total 'System'
  & $H 'System'
  try {
    $os = Get-CimInstance Win32_OperatingSystem
    & $A ('Windows     ' + $os.Caption + ' ' + $os.Version + ' (build ' + $os.BuildNumber + ') ' + $os.OSArchitecture)
  } catch { & $A 'Windows     (unknown)' }
  & $A ('PowerShell  ' + $PSVersionTable.PSVersion + '   process arch ' + $env:PROCESSOR_ARCHITECTURE)
  & $A ('Culture     ' + (Get-Culture).Name + ' / UI ' + (Get-UICulture).Name + '   time zone ' + (Get-TimeZone).Id)
  $term = 'classic console'
  if ($env:WT_SESSION) { $term = 'Windows Terminal' } elseif ($env:TERM_PROGRAM) { $term = $env:TERM_PROGRAM } elseif ($env:VSCODE_PID) { $term = 'VS Code' }
  & $A ('Terminal    ' + $term + '   code page ' + [Console]::OutputEncoding.CodePage + '   colors ' + $script:Color + '   icons ' + $script:IconMode + '   width ' + $script:Width)
  & $A ('Elevated    ' + ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))

  Progress 2 $total 'Tools and versions'
  & $H 'Tools and versions'
  Safe-Section {
  if ($noProbe) { & $A '(tool probes skipped)' } else {
    $oc = @(Get-Command opencode, opencode.cmd, opencode.exe -All -ErrorAction SilentlyContinue | Where-Object { $_.Source -match '\.(exe|cmd|bat)$' } | Select-Object -ExpandProperty Source -Unique | Select-Object -First 4)
    if (-not $oc.Count) { & $A 'opencode    not found on PATH' }
    foreach ($o in $oc) { & $A ('opencode    ' + $o + '  ->  ' + (Probe-Cmd $o '--version' 8000)) }
    $stub = Join-Path $env:APPDATA 'npm\node_modules\@opencode\cli\bin\opencode.exe'
    if (Test-Path -LiteralPath $stub) { $len = (Get-Item -LiteralPath $stub).Length; & $A ('npm @opencode/cli exe  ' + $len + ' bytes' + $(if ($len -lt 100000) { '   <-- a stub: its postinstall did not run' } else { '' })) }
    $dsk = Join-Path $env:LOCALAPPDATA 'Programs\ai.opencode.desktop\OpenCode.exe'
    if (Test-Path -LiteralPath $dsk) { & $A ('desktop app ' + $dsk + '  version ' + (Get-Item -LiteralPath $dsk).VersionInfo.FileVersion) } else { & $A 'desktop app not in the default folder' }
    $wc = Join-Path $env:ProgramFiles 'Cloudflare\Cloudflare WARP\warp-cli.exe'
    if (Test-Path -LiteralPath $wc) { & $A ('warp-cli    ' + (Probe-Cmd $wc '--version' 5000)); & $A ('WARP status ' + (Probe-Cmd $wc '--accept-tos status' 5000)) } else { & $A 'warp-cli    not installed' }
    $tor = @(Get-ChildItem -LiteralPath (Join-Path $State 'tor') -Recurse -Filter tor.exe -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($tor.Count) { & $A ('tor         ' + (Probe-Cmd $tor[0].FullName '--version' 5000)) } else { & $A 'tor         not installed by the launcher' }
    foreach ($pair in @(@('node', '--version'), @('npm.cmd', '--version'), @('curl.exe', '--version'))) {
      $c = Get-Command $pair[0] -ErrorAction SilentlyContinue
      if ($c) { & $A (($pair[0].PadRight(11)) + ' ' + (Probe-Cmd $c.Source $pair[1] 5000)) } else { & $A (($pair[0].PadRight(11)) + ' not found') }
    }
  }
  } $A

  Progress 3 $total 'Connection'
  & $H 'Connection'
  Safe-Section {
  $ports = @(40000, 9050, 9150, 8118, [int](Get-Val 'PROXY_PORT'), [int](Get-Val 'TOR_SOCKS_PORT'), [int](Get-Val 'TOR_HTTP_PORT')) | Sort-Object -Unique
  try {
    $ls = @(Get-NetTCPConnection -State Listen -ErrorAction Stop | Where-Object { $ports -contains $_.LocalPort })
    foreach ($pt in $ports) {
      $m = @($ls | Where-Object { $_.LocalPort -eq $pt } | Select-Object -First 1)
      if ($m.Count) { $pn = (Get-Process -Id $m[0].OwningProcess -ErrorAction SilentlyContinue).ProcessName; & $A ('port ' + $pt + ' listening (' + $pn + ')') } else { & $A ('port ' + $pt + ' not listening') }
    }
  } catch { & $A '(listening ports unavailable)' }
  $pr = @(Get-Process -Name opencode, OpenCode, opencode-cli, warp-svc, 'Cloudflare WARP', tor -ErrorAction SilentlyContinue)
  if ($pr.Count) {
    foreach ($x in $pr) {
      $since = ''
      try { $since = ' since ' + $x.StartTime.ToString('s') } catch { }
      & $A ('process ' + $x.ProcessName + ' pid ' + $x.Id + $since)
    }
  } else { & $A 'no opencode / WARP / Tor process running' }
  $mk = Join-Path $State 'renew_needed.txt'
  if (Test-Path -LiteralPath $mk) { & $A ('renew needed: ' + (Get-Content -LiteralPath $mk -TotalCount 1)) }
  } $A

  Progress 4 $total 'Settings and setup'
  & $H 'Settings changed from the default'
  $n = 0
  foreach ($s in $Schema) { if ($script:Cfg.settings.ContainsKey($s.Key)) { & $A ($s.Key + ' = ' + (Safe-Val $s.Key)); $n++ } }
  if (-not $n) { & $A '(none: every setting is at its default)' }
  & $H 'Setup'
  $su = $script:Cfg.setup
  if ($su -is [hashtable] -and $su.done -eq $true) {
    & $A ('configured: method ' + $su.method + ', verified ' + $su.verified + ', created ' + $su.createdUtc)
    & $A ('command ' + (Test-Path -LiteralPath $ShimPath) + ', on PATH ' + ([bool](@((Get-UserPath) -split ';') | Where-Object { $_.TrimEnd('\') -ieq $ShimDir.TrimEnd('\') })) + ', launcher still there ' + (Test-Path -LiteralPath $su.launcher))
  } else { & $A 'not configured' }
  if ($script:Cfg.font.Count) { & $A ('font changes recorded: ' + (($script:Cfg.font.Keys) -join ', ')) }

  Progress 5 $total 'Logs'
  & $H 'launcher.log (newest 400 lines)'
  & $A (Tail-Of (Join-Path $State 'launcher.log') 400)
  foreach ($f in @('startup.log', 'install.log', 'wcli.log', 'verify.log', 'renew.log', 'resume.err', 'probe.err')) {
    & $H ($f + ' (newest 60 lines)')
    & $A (Tail-Of (Join-Path $State $f) 60)
  }
  foreach ($f in @('tor\tor.log', 'tor\bridge.log')) {
    & $H ($f + ' (newest 60 lines)')
    & $A (Tail-Of (Join-Path $State $f) 60)
  }

  Progress 6 $total 'Writing the report'
  $dir = Join-Path $State 'reports'
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $out = Join-Path $dir ('support-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.txt')
  [IO.File]::WriteAllText($out, (Redact $sb.ToString()), (New-Object Text.UTF8Encoding($false)))
  Log ('support report written: ' + $out) 'report'
  return $out
}
function Show-Report {
  Clear-Screen
  WL (P (Style 'title') ($script:I.gear + ' ' + (T 'Support report')))
  WL ''
  $path = New-Report
  WL ''
  Say 'ok' 'Report ready. Personal data was removed; read it once before you share it.'
  WL (P (Style 'dim') ('   ' + $path))
  $items = @(
    @{ L = 'Open the folder'; H = 'Show the report in Explorer so you can attach or paste it.' },
    @{ L = 'Copy the file path'; H = 'Put the full path on the clipboard.' },
    @{ L = ($script:I.back + ' Back'); H = 'Return to the main menu.' })
  while ($true) {
    $r = Show-Menu 'Support report' $items $null @('', ('   ' + (P (Style 'dim') $path)), '') 0
    if ($r -eq -1 -or $r -eq 2) { return }
    if ($r -eq 0) { if (-not $Scripted) { try { Start-Process explorer.exe -ArgumentList ('/select,"' + $path + '"') } catch { } } }
    if ($r -eq 1) { try { Set-Clipboard -Value $path } catch { } }
  }
}

# ---------------------------------------------------------------- launcher menus (v2.29)
# One screen per call. The exit code is the number of the chosen row, what `choice` returned in the old
# menus, so the batch keeps its own dispatch. 20 = no usable console (the batch falls back to `choice`).
function Header-Lines {
  $h = @()
  foreach ($p in @(@('Folder', $env:OC_H_FOLDER), @('Egress', $env:OC_H_EGRESS), @('Mode', $env:OC_H_MODE), @('Proxy', $env:OC_H_PROXY), @('WARP', $env:OC_H_WARP), @('Version', $env:OC_H_VER), @('Exit IP', $env:OC_H_IP))) {
    if ($p[1]) { $h += ('   ' + (P (Style 'dim') (Pad (T $p[0]) 9)) + (P (Style 'accent') ([string]$p[1]))) }
  }
  if ($h.Count) { $h += '' }
  return $h
}
function Menu-Mode {
  $dsk = [string]$env:OC_DESKTOP
  $items = @(
    @{ L = ($script:I.play + ' CLI'); V = 'terminal'; H = 'Run opencode in this terminal. After a new IP the chat resumes by itself.' },
    @{ L = ($script:I.link + ' Desktop app'); V = $(if ($dsk) { 'installed' } else { 'not installed' }); S = $(if ($dsk) { 'ok' } else { 'warn' })
       H = $(if ($dsk) { Tf 'Run the OpenCode desktop app ({0}). It is restarted after every new IP.' $dsk } else { 'The OpenCode desktop app was not found. Choosing this offers to download and install it.' }) },
    @{ L = ($script:I.err + ' Exit'); H = 'Close the launcher.' })
  $r = Show-Menu 'How do you want to run OpenCode?' $items $null $null 0
  if ($r -eq -1) { exit 3 }
  exit ($r + 1)
}
function Menu-Folder {
  $last = [string]$env:OC_LASTPATH; $cwd = [string]$env:OC_CWD
  $items = @(
    @{ L = 'Reopen the last folder'; V = $(if ($last) { $last } else { '(nothing saved yet)' }); D = (-not $last); H = $(if ($last) { Tf 'Work in {0}' $last } else { 'There is no saved folder yet. Use one of the other options once.' }) },
    @{ L = 'Use this folder'; V = $cwd; H = (Tf 'Work in the folder the launcher was started from: {0}' $cwd) },
    @{ L = 'Browse for a folder...'; H = 'Open the Windows folder picker and choose where to work.' },
    @{ L = ($script:I.err + ' Exit'); H = 'Close the launcher.' })
  $r = Show-Menu 'Choose a folder to work in' $items $null $null $(if ($last) { 0 } else { 1 })
  if ($r -eq -1) { exit 4 }
  exit ($r + 1)
}
function Menu-Egress {
  $items = @(
    @{ L = 'WARP'; V = 'Cloudflare'; H = 'Cloudflare WARP in proxy mode. A new registration gives a new exit IP. Rotation supported.' },
    @{ L = 'TOR'; V = ('bridge :' + $env:TOR_HTTP_PORT); H = 'Local Tor with a built-in HTTP bridge. A portable Tor is installed automatically if missing.' },
    @{ L = 'PROXY'; V = 'free list'; H = 'Free HTTP proxies from your list (any format) or the default one. Each is tested before use.' },
    @{ L = 'NONE'; V = 'direct'; H = 'No proxy: opencode uses your real connection and nothing is rotated.' })
  $head = @((P (Style 'dim') ('   ' + (T 'Only opencode uses it; the rest of the system stays direct.'))), '')
  if ($env:OC_H_FOLDER) { $head = @(('   ' + (P (Style 'dim') (Pad (T 'Folder') 9)) + (P (Style 'accent') $env:OC_H_FOLDER))) + $head }
  while ($true) {
    $r = Show-Menu 'Choose the connection for OpenCode' $items $null $head 0
    if ($r -ne -1) { exit ($r + 1) }
  }
}
function Menu-Main {
  $desk = ($env:OC_H_MODE -eq 'DESKTOP')
  $items = @(
    @{ L = 'Fresh start'; V = 'new IP'; H = 'Get a new IP or proxy, then open OpenCode. Your chats and history stay untouched.' },
    @{ L = 'Continue'; V = 'same IP'; H = 'Keep the current connection and open OpenCode as it was.' },
    @{ L = 'Change IP'; H = 'Rotate the connection only (new WARP registration, Tor circuit or proxy) without opening OpenCode.' },
    $(if ($desk) { @{ L = 'Mode'; V = 'CLI / Desktop'; H = 'Switch between the terminal and the desktop app.' } } else { @{ L = 'Folder'; H = 'Work in a different folder.' } }),
    @{ L = 'Deep reset'; V = 'asks first'; S = 'err'; H = 'Kill opencode, move your chats to the Desktop, clear the saved tokens and open a fresh session.' },
    @{ L = ($script:I.err + ' Exit'); H = 'Close the launcher.' },
    @{ L = 'Token reset'; V = 'asks first'; S = 'warn'; H = 'Kill opencode and clear the saved tokens, keeping your chats where they are.' },
    @{ L = ($script:I.gear + ' Settings'); H = 'Change any launcher setting: connection, proxies, Tor, rotation, themes, font. Applied right away.' })
  $head = Header-Lines
  while ($true) {
    $r = Show-Menu 'OpenCode' $items ('v2.30   ' + $Repo) $head 0
    if ($r -ne -1) { exit ($r + 1) }
  }
}
# Yes/No under the text already printed by the batch. Exit 1 = yes, 2 = no (what `choice /c yn` returned).
function Menu-Confirm {
  $q = T (([string]$env:OC_Q -replace '\s*\[Y/N\]:?\s*$', '').Trim())
  $head = @('', (P (Style 'warn') ($script:I.warn + ' ' + $q)))
  if ($env:OC_QT) { $script:KeyTimeout = [int]$env:OC_QT; $head += (P (Style 'dim') ('   ' + (Tf 'No answer in {0}s counts as No.' $env:OC_QT))) }
  $items = @(@{ L = 'Yes'; K = 'y'; S = 'warn'; H = 'Go ahead.' }, @{ L = 'No'; K = 'n'; H = 'Cancel. Nothing is changed.' })
  $r = Show-Menu 'Confirm' $items $null $head 1 $false $true
  if ($r -eq 0) { exit 1 }
  exit 2
}

# ---------------------------------------------------------------- home
# First start only. The detected language comes first and is selected; "Automatic" follows Windows on every start.
function First-Lang {
  $mark = Join-Path $State 'lang.chosen'
  if (Test-Path -LiteralPath $mark) { return }
  $det = Detect-Lang
  $codes = @($det, 'auto') + @($Langs | Where-Object { $_ -ne $det -and $_ -ne 'en' })
  $items = @()
  foreach ($c in $codes) {
    if ($c -eq 'auto') { $items += @{ L = 'Automatic (follow Windows)'; H = 'Use the language Windows is set to on every start; English when there is no translation.' } }
    elseif ($c -eq $det) { $items += @{ L = ((Lang-Name $c) + ' (detected)'); H = 'Detected from Windows and selected. You can change it in Settings, Appearance.' } }
    else { $items += @{ L = (Lang-Name $c); H = 'You can change it in Settings, Appearance.' } }
  }
  $r = Show-Menu 'Choose your language' $items $null $null 0
  $pick = if ($r -lt 0) { 'auto' } else { $codes[$r] }
  Set-Val (Get-Setting 'OCUI_LANG') $pick
  New-Item -ItemType Directory -Force -Path $State | Out-Null
  [IO.File]::WriteAllText($mark, $pick)
  Init-Ui
}
function Home-Loop {
  $pos = 0
  while ($true) {
    $conf = Test-Configured
    $items = @(); $acts = @()
    $items += @{ L = ($script:I.play + ' Launch OpenCode'); H = 'Open the launcher menus: pick a folder and a connection method, then start the opencode CLI or the desktop app.' }; $acts += 'launch'
    if ($conf) { $items += @{ L = ($script:I.link + ' Connect with opencode'); V = (Tf 'Configured - {0}' $script:Cfg.setup.method); S = 'ok'; H = 'See what the setup installed (command, shortcuts, PATH) and run it again to change the method.' } }
    else { $items += @{ L = ($script:I.link + ' Connect with opencode'); V = 'Not configured'; S = 'warn'; H = 'Guided setup: choose WARP, Tor, a proxy list or direct, then get an "opencode" command and a shortcut that start with it. It is tested at the end.' } }
    $acts += 'connect'
    if ($conf) {
      $items += @{ L = ($script:I.renew + ' Renew session'); H = 'Use it when the free limit is hit or the login expired: closes opencode, saves and clears the saved tokens, and gets a new IP, WARP registration, Tor circuit or proxy.' }; $acts += 'renew'
      $items += @{ L = ($script:I.trash + ' Uninstall'); S = 'err'; H = 'Removes only what the setup added (command, shortcuts, PATH entry) and restores the settings it changed. Backups are kept. Asks first.' }; $acts += 'uninstall'
    }
    $items += @{ L = ($script:I.gear + ' Settings'); H = 'View and change every launcher option: connection, proxies, Tor, rotation, themes. Saved instantly, no files to edit.' }; $acts += 'settings'
    $items += @{ L = ($script:I.link + ' Support report'); H = 'Collect system info, versions, settings and the recent log into one text file you can send for help. Passwords, tokens, your user name and (by default) IPs are removed first.' }; $acts += 'report'
    $items += @{ L = ($script:I.err + ' Exit'); H = 'Close the launcher.' }; $acts += 'exit'
    $head = @()
    $marker = Join-Path $State 'renew_needed.txt'
    if ($conf -and (Test-Path -LiteralPath $marker)) {
      $why = (Get-Content -LiteralPath $marker -TotalCount 1 -ErrorAction SilentlyContinue)
      $head += (P (Style 'warn') ($script:I.renewE + ' ' + $script:I.warn + ' ' + (Tf 'Your session needs renewing: {0}' $why)))
      $head += (P (Style 'warn') ('   ' + (T 'Choose "Renew session" below. It gets a new IP and clears the saved login;')))
      $head += (P (Style 'warn') ('   ' + (T 'no other step is needed.')))
      $head += ''
    }
    if ($script:Notice) { $head += (P (Style $script:Notice[0]) ($script:I.warn + ' ' + (T $script:Notice[1]))); $head += ''; $script:Notice = $null }
    $r = Show-Menu 'Main menu' $items ('v2.30   ' + $Self) $head $pos $true
    if ($r -eq -1) { continue }
    $pos = $r
    Log ('home -> ' + $acts[$r])
    switch ($acts[$r]) {
      'launch' { return 10 }
      'report' { Show-Report }
      'connect' { if ($conf) { Show-Status } else { [void](Run-Setup) } }
      'renew' { Do-Renew }
      'uninstall' { Do-Uninstall }
      'settings' { Settings-Menu }
      'exit' { return 0 }
    }
  }
}

# Every setting must accept a good value, reject a bad one and reach config.env (OC_TUI=selftest).
function Self-Test {
  $fails = 0; $i = 0
  foreach ($s in $Schema) {
    $i++
    $good = ''; $bad = 'zzz'
    switch ($s.Type) {
      'bool' { $good = $(if ([int]$s.Default -eq 1) { 'off' } else { 'on' }); $bad = 'maybe' }
      'int' { $good = [string][Math]::Min([int]$s.Max, [Math]::Max([int]$s.Min, [int]$s.Default + 1)); if ($good -eq [string]$s.Default) { $good = [string]$s.Min }; $bad = [string]([int]$s.Max + 1) }
      'port' { $good = [string](41000 + $i); $bad = '70000' }
      'enum' { $good = [string]($s.Values | Where-Object { $_ -ne $s.Default } | Select-Object -First 1); $bad = 'zzz' }
      'string' { $good = 'test value'; $bad = 'a"b' }
      'url' { $good = 'https://example.com/x'; $bad = 'not a url' }
      'listsrc' { $good = 'https://example.com/list.json'; $bad = 'C:\definitely\missing.txt' }
      'path' { $good = ''; $bad = 'C:\definitely\missing.exe' }
      'country' { $good = 'DE'; $bad = '1x' }
      'ipprefix' { $good = '104.28.'; $bad = 'abc' }
      'font' { $good = 'Consolas'; $bad = 'a"b' }
    }
    $r = Test-Val $s $good
    $r2 = Test-Val $s $bad
    if ($r.ok -and -not $r2.ok) { Set-Val $s $r.v; [Console]::WriteLine('PASS ' + $s.Key + ' [' + $s.Type + '] ' + $good + ' (bad rejected: ' + $r2.err + ')') }
    else { $fails++; [Console]::WriteLine('FAIL ' + $s.Key + ' [' + $s.Type + '] good=' + $good + ' ok=' + $r.ok + ' bad=' + $bad + ' badOk=' + $r2.ok) }
  }
  return $fails
}

# ---------------------------------------------------------------- main
if ($Mode -eq 'probe') { if ([Console]::IsInputRedirected -and -not $Scripted) { exit 20 } else { exit 0 } }
# Reading keys from a redirected stdin leaves the console input in a state that makes the batch
# `choice` wait forever, so with no real console the UI steps aside before touching it.
if (-not $Scripted -and $Mode -ne 'export' -and $Mode -ne 'selftest' -and [Console]::IsInputRedirected) { exit 20 }
try {
  Load-Cfg
  Init-Ui
  Log ('ui ' + $Mode + ' start; color ' + $script:Color + ', icons ' + $script:IconMode + ', width ' + $script:Width)
  if ((Get-Val 'OCUI_FONT') -and -not $env:WT_SESSION -and -not $env:TERM_PROGRAM -and -not $Scripted) { try { [void](Apply-ConsoleFont ([string](Get-Val 'OCUI_FONT')) ([int](Get-Val 'OCUI_FONT_SIZE'))) } catch { } }
  switch ($Mode) {
    'export' { Save-Cfg; exit 0 }
    'selftest' { exit (Self-Test) }
    'settings' { Settings-Menu; exit 0 }
    'mode' { Menu-Mode }
    'folder' { Menu-Folder }
    'egress' { Menu-Egress }
    'main' { Menu-Main }
    'confirm' { Menu-Confirm }
    default { First-Lang; $rc = Home-Loop; exit $rc }
  }
} catch {
  if ($_.Exception.Message -eq 'keys exhausted') { exit 30 }
  if ($_.Exception.Message -eq 'ctrl-c') { try { [Console]::TreatControlCAsInput = $false } catch { }; Log 'ctrl-c: leaving'; exit 0 }
  Log ('ui error: ' + $_.Exception.Message + ' at line ' + $_.InvocationInfo.ScriptLineNumber) 'error'
  [Console]::Error.WriteLine('ui: ' + $_.Exception.Message)
  exit 20
}
#>>>OC_ENDTUI
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
#>>>LANG de {" move   Enter select   Esc back   1-9 or letter jump":" bewegen   Enter w\u00e4hlen   Esc zur\u00fcck   1-9 oder Buchstabe zum Springen","(Enter = keep \"{0}\")":"(Enter = \"{0}\" behalten)","(auto)":"(auto)","(nothing saved yet)":"(noch nichts gespeichert)","(terminal default)":"(Standard des Terminals)","* = changed from the default. Enter edits or toggles the selected value.":"* = vom Standard abweichend. Enter bearbeitet oder schaltet den gew\u00e4hlten Wert um.","A downloaded list smaller than this is rejected. 0 = off.":"Eine heruntergeladene Liste, die kleiner ist, wird abgelehnt. 0 = aus.","A port is a number from 1 to 65535.":"Ein Port ist eine Zahl von 1 bis 65535.","A proxy must also reach the opencode API host.":"Ein Proxy muss auch den API-Server von opencode erreichen.","API check URL":"URL der API-Pr\u00fcfung","Accent colors of the interface.":"Akzentfarben der Oberfl\u00e4che.","Adding the command to your PATH":"Befehl wird zum PATH hinzugef\u00fcgt","Adds: opencode command (shim), two shortcuts, one PATH entry. Backups are kept.":"F\u00fcgt hinzu: den opencode-Befehl (Shim), zwei Verkn\u00fcpfungen und einen PATH-Eintrag. Sicherungen bleiben erhalten.","Any installed font name, for example Cascadia Code.":"Jeder Name einer installierten Schrift, zum Beispiel Cascadia Code.","Appearance":"Darstellung","Applies at the {0}.":"Gilt ab: {0}.","Apply":"Anwenden","Apply setup":"Einrichtung anwenden","Ask every time":"Jedes Mal fragen","Attempts per round when the tunnel is not up.":"Versuche pro Runde, wenn der Tunnel nicht steht.","Back":"Zur\u00fcck","Backing up the current configuration":"Aktuelle Konfiguration wird gesichert","Browse for a folder...":"Ordner durchsuchen...","Burned IPs allowed":"Erlaubte verbrannte IPs","Burned proxies before Tor offer":"Verbrannte Proxys vor dem Tor-Angebot","Burned proxies in a row before PROXY mode offers Tor.":"Verbrannte Proxys in Folge, bevor der PROXY-Modus Tor anbietet.","CLI terminal, Desktop app, or ask at every start.":"CLI im Terminal, Desktop-App oder bei jedem Start fragen.","Cancel":"Abbrechen","Cancel. Nothing is changed.":"Abbrechen. Nichts wird ge\u00e4ndert.","Change IP":"IP wechseln","Change an answer.":"Eine Antwort \u00e4ndern.","Change any launcher setting: connection, proxies, Tor, rotation, themes, font. Applied right away.":"\u00c4ndert jede Launcher-Einstellung: Verbindung, Proxys, Tor, Rotation, Designs, Schrift. Wird sofort angewendet.","Check GitHub for a newer launcher at every start.":"Sucht bei jedem Start auf GitHub nach einem neueren Launcher.","Check the API host":"API-Server pr\u00fcfen","Checking that it works":"Funktion wird gepr\u00fcft","Checking the connection":"Verbindung wird gepr\u00fcft","Choose \"Renew session\" below. It gets a new IP and clears the saved login;":"W\u00e4hle unten \"Sitzung erneuern\". Das holt eine neue IP und l\u00f6scht die gespeicherte Anmeldung;","Choose a folder to work in":"W\u00e4hle einen Arbeitsordner","Choose one of: {0}.":"W\u00e4hle einen von: {0}.","Choose the connection for OpenCode":"W\u00e4hle die Verbindung f\u00fcr OpenCode","Close the launcher.":"Den Launcher schlie\u00dfen.","Closes every running opencode process.":"Schlie\u00dft alle laufenden opencode-Prozesse.","Cloudflare WARP in local proxy mode. Every rotation asks for a new registration, which gives a new exit IP. Needs the WARP client (offered if missing).":"Cloudflare WARP im lokalen Proxy-Modus. Jede Rotation fordert eine neue Registrierung an, die eine neue Ausgangs-IP liefert. Ben\u00f6tigt den WARP-Client (wird angeboten, falls er fehlt).","Cloudflare WARP in proxy mode. A new registration gives a new exit IP. Rotation supported.":"Cloudflare WARP im Proxy-Modus. Eine neue Registrierung liefert eine neue Ausgangs-IP. Rotation wird unterst\u00fctzt.","Cloudflare throttles rapid registrations.":"Cloudflare drosselt schnell aufeinanderfolgende Registrierungen.","Collect system info, versions, settings and the recent log into one text file you can send for help. Passwords, tokens, your user name and (by default) IPs are removed first.":"Sammelt Systeminfos, Versionen, Einstellungen und das aktuelle Protokoll in einer Textdatei, die du f\u00fcr Hilfe senden kannst. Passw\u00f6rter, Tokens, dein Benutzername und (standardm\u00e4\u00dfig) IPs werden vorher entfernt.","Color theme":"Farbdesign","Color theme, colors on or off, icon and border style, and the terminal font. Applied immediately.":"Farbdesign, Farben an oder aus, Symbol- und Rahmenstil, Sprache und Terminal-Schrift. Wird sofort angewendet.","Colors":"Farben","Command":"Befehl","Configured - {0}":"Eingerichtet - {0}","Confirm":"Best\u00e4tigen","Connect with opencode":"Mit opencode verbinden","Connected: opencode now starts through {0}.":"Verbunden: opencode startet jetzt \u00fcber {0}.","Connecting opencode":"opencode wird verbunden","Connection":"Verbindung","Connection method":"Verbindungsmethode","Continue":"Fortsetzen","Continue WITHOUT the probe this session (IPs accepted untested)?":"In dieser Sitzung OHNE Test fortfahren (IPs ungepr\u00fcft akzeptiert)?","Continue anyway?":"Trotzdem fortfahren?","Continue direct?":"Direkt fortfahren?","Continue without WARP?":"Ohne WARP fortfahren?","Cooldown between attempts (s)":"Pause zwischen Versuchen (s)","Copies auth.json to your Desktop, then clears the saved tokens.":"Kopiert auth.json auf deinen Desktop und l\u00f6scht dann die gespeicherten Tokens.","Copy the file path":"Dateipfad kopieren","Creating shortcuts":"Verkn\u00fcpfungen werden erstellt","Creating the opencode command":"opencode-Befehl wird erstellt","Credentials inside a URL are not stored. Use a local file instead.":"Zugangsdaten in einer URL werden nicht gespeichert. Nutze stattdessen eine lokale Datei.","Deep reset":"Vollst\u00e4ndiger Reset","Default connection method and run mode, the WARP proxy port and the warp-cli timings.":"Standard-Verbindungsmethode und Ausf\u00fchrungsmodus, WARP-Proxy-Port und warp-cli-Zeiten.","Default: {0}.":"Standard: {0}.","Desktop":"Desktop","Desktop app":"Desktop-App","Desktop app location, release metadata URL and lookup timeouts.":"Ort der Desktop-App, URL der Versionsmetadaten und Suchzeiten.","Desktop app path":"Pfad der Desktop-App","Direct, no proxy":"Direkt, ohne Proxy","Do it now.":"Jetzt ausf\u00fchren.","Do that now?":"Jetzt ausf\u00fchren?","Download and install it now?":"Jetzt herunterladen und installieren?","Download the portable Tor bundle when nothing answers.":"L\u00e4dt das portable Tor herunter, wenn nichts antwortet.","Egress":"Ausgang","Egress used for opencode. ASK shows the picker at every start.":"Ausgang, den opencode nutzt. ASK zeigt die Auswahl bei jedem Start.","Enter a full URL (http, https, ftp or file).":"Gib eine vollst\u00e4ndige URL ein (http, https, ftp oder file).","Enter a whole number.":"Gib eine ganze Zahl ein.","Enter cycles: {0}.":"Enter wechselt durch: {0}.","Enter toggles it.":"Enter schaltet um.","Every change is saved at once to {0}":"Jede \u00c4nderung wird sofort in {0} gespeichert","Exit":"Beenden","Exit IP":"Ausgangs-IP","Extra rounds (60 s apart) before giving up.":"Zus\u00e4tzliche Runden (60 s Abstand), bevor aufgegeben wird.","Folder":"Ordner","Font name":"Schriftname","Font of the terminal text. Empty leaves the terminal as it is.":"Schrift des Terminaltexts. Leer l\u00e4sst das Terminal unver\u00e4ndert.","Font size":"Schriftgr\u00f6\u00dfe","Free HTTP proxies from your list (any format) or the default one. Each is tested before use.":"Kostenlose HTTP-Proxys aus deiner Liste (beliebiges Format) oder der Standardliste. Jeder wird vor der Nutzung getestet.","Free or your own list":"Frei oder eigene Liste","Fresh start":"Neustart","Full path of OpenCode.exe. Empty = search automatically.":"Vollst\u00e4ndiger Pfad von OpenCode.exe. Leer = automatisch suchen.","Get a new IP or proxy, then open OpenCode. Your chats and history stay untouched.":"Holt eine neue IP oder einen neuen Proxy und \u00f6ffnet dann OpenCode. Deine Chats und dein Verlauf bleiben unber\u00fchrt.","Gets a new IP / WARP registration / Tor circuit / proxy.":"Holt eine neue IP / WARP-Registrierung / Tor-Verbindung / einen neuen Proxy.","Go ahead.":"Los geht's.","Go back. Nothing is changed.":"Zur\u00fcck. Nichts wird ge\u00e4ndert.","Guided setup: choose WARP, Tor, a proxy list or direct, then get an \"opencode\" command and a shortcut that start with it. It is tested at the end.":"Gef\u00fchrte Einrichtung: w\u00e4hle WARP, Tor, eine Proxy-Liste oder direkt und erhalte einen \"opencode\"-Befehl und eine Verkn\u00fcpfung, die damit starten. Am Ende wird getestet.","HTTP port of the built-in bridge opencode uses.":"HTTP-Port der integrierten Br\u00fccke, die opencode nutzt.","Host used by the API check.":"Server, den die API-Pr\u00fcfung nutzt.","How do you want to run OpenCode?":"Wie m\u00f6chtest du OpenCode ausf\u00fchren?","How many proxies to test before giving up.":"Wie viele Proxys getestet werden, bevor aufgegeben wird.","How many times, and how fast, a new IP is requested when the free limit is hit.":"Wie oft und wie schnell eine neue IP angefordert wird, wenn das kostenlose Limit erreicht ist.","IPs the probe may reject before giving up. 0 = no limit.":"IPs, die der Test ablehnen darf, bevor aufgegeben wird. 0 = unbegrenzt.","Icons and borders":"Symbole und Rahmen","Install Tor automatically":"Tor automatisch installieren","Keep the current connection and open OpenCode as it was.":"Beh\u00e4lt die aktuelle Verbindung und \u00f6ffnet OpenCode wie zuvor.","Keep the current font.":"Aktuelle Schrift behalten.","Kill opencode and clear the saved tokens, keeping your chats where they are.":"Beendet opencode und l\u00f6scht die gespeicherten Tokens; deine Chats bleiben, wo sie sind.","Kill opencode, move your chats to the Desktop, clear the saved tokens and open a fresh session.":"Beendet opencode, verschiebt deine Chats auf den Desktop, l\u00f6scht die gespeicherten Tokens und \u00f6ffnet eine neue Sitzung.","Language":"Sprache","Language of the menus and descriptions. auto follows Windows. Logs and the support report stay in English.":"Sprache der Men\u00fcs und Beschreibungen. auto folgt Windows. Protokolle und der Support-Bericht bleiben auf Englisch.","Last check":"Letzte Pr\u00fcfung","Launch OpenCode":"OpenCode starten","Launcher":"Launcher","Launcher self-update":"Launcher-Selbstupdate","Leave the setup without changing anything.":"Die Einrichtung verlassen, ohne etwas zu \u00e4ndern.","Leave the terminal font as it is. If the launcher changed it, the original font comes back.":"L\u00e4sst die Terminal-Schrift unver\u00e4ndert. Hat der Launcher sie ge\u00e4ndert, kommt die urspr\u00fcngliche zur\u00fcck.","Local Tor with a built-in HTTP bridge. A portable Tor is installed automatically if missing.":"Lokales Tor mit integrierter HTTP-Br\u00fccke. Fehlt es, wird automatisch ein portables Tor installiert.","Local port of the WARP proxy.":"Lokaler Port des WARP-Proxys.","Logs":"Protokolle","Main menu":"Hauptmen\u00fc","Method":"Methode","Minimum list size (bytes)":"Minimale Listengr\u00f6\u00dfe (Bytes)","Mode":"Modus","Model used by the IP probe.":"Modell, das der IP-Test nutzt.","Must be between {0} and {1}.":"Muss zwischen {0} und {1} liegen.","New IP and resume in 5s":"Neue IP und Fortsetzen in 5 s","No":"Nein","No .exe file exists at that path.":"An diesem Pfad gibt es keine .exe-Datei.","No answer in {0}s counts as No.":"Keine Antwort in {0} s z\u00e4hlt als Nein.","No change.":"Keine \u00c4nderung.","No proxy: opencode uses your real connection and nothing is rotated.":"Kein Proxy: opencode nutzt deine echte Verbindung und nichts wird rotiert.","No, cancel":"Nein, abbrechen","Non-limit probe failures before the hunt stops.":"Test-Fehler, die nicht das Limit betreffen, bevor die Suche stoppt.","Not a URL, and no file exists at that path.":"Keine URL, und an diesem Pfad gibt es keine Datei.","Not configured":"Nicht eingerichtet","Nothing to ask for a direct connection.":"Bei einer direkten Verbindung gibt es nichts zu fragen.","Nothing was left half done that Uninstall cannot remove. Fix the problem and run setup again.":"Es ist nichts halb fertig geblieben, was Deinstallieren nicht entfernen kann. Behebe das Problem und f\u00fchre die Einrichtung erneut aus.","On PATH":"Im PATH","Only opencode uses it; the rest of the system stays direct.":"Nur opencode nutzt sie; der Rest des Systems bleibt direkt.","Open the Windows folder picker and choose where to work.":"\u00d6ffnet die Windows-Ordnerauswahl, um den Arbeitsort zu w\u00e4hlen.","Open the folder":"Ordner \u00f6ffnen","Open the launcher menus: pick a folder and a connection method, then start the opencode CLI or the desktop app.":"\u00d6ffnet die Launcher-Men\u00fcs: Ordner und Verbindungsmethode w\u00e4hlen, dann die opencode-CLI oder die Desktop-App starten.","OpenCode app":"OpenCode-App","PATH lookup timeout (s)":"Zeitlimit der PATH-Suche (s)","Paths":"Pfade","Port {0} is already used by {1}.":"Port {0} wird bereits von {1} verwendet.","Ports and install behavior of the portable Tor the launcher starts for you.":"Ports und Installation des portablen Tor, das der Launcher f\u00fcr dich startet.","Press any key to continue...":"Beliebige Taste zum Fortfahren...","Probe":"Test","Probe failures tolerated":"Tolerierte Testfehler","Probe model":"Testmodell","Proxies tried per pick":"Proxys pro Auswahl","Proxy":"Proxy","Proxy list":"Proxy-Liste","Proxy list source":"Quelle der Proxy-Liste","Proxy test timeout (s)":"Zeitlimit eines Proxy-Tests (s)","Public HTTP proxies from a list (yours, in any format, or the free default). Each one is tested first and burned ones are skipped.":"\u00d6ffentliche HTTP-Proxys aus einer Liste (deiner, in beliebigem Format, oder der freien Standardliste). Jeder wird zuerst getestet, verbrannte werden \u00fcbersprungen.","Put every setting back to its default. Your connection setup (command, shortcuts) is not touched. Asks first.":"Setzt alle Einstellungen auf ihren Standard zur\u00fcck. Deine Verbindungseinrichtung (Befehl, Verkn\u00fcpfungen) bleibt unber\u00fchrt. Fragt vorher.","Put the full path on the clipboard.":"Legt den vollst\u00e4ndigen Pfad in die Zwischenablage.","Quotes and line breaks are not allowed.":"Anf\u00fchrungszeichen und Zeilenumbr\u00fcche sind nicht erlaubt.","Range {0} to {1}.":"Bereich {0} bis {1}.","Reconfigure (run setup again)":"Neu einrichten (Einrichtung erneut ausf\u00fchren)","Release metadata URL":"URL der Versionsmetadaten","Removes only what setup added: the opencode command, the shortcuts and the PATH entry.":"Entfernt nur, was die Einrichtung hinzugef\u00fcgt hat: den opencode-Befehl, die Verkn\u00fcpfungen und den PATH-Eintrag.","Removes only what the setup added (command, shortcuts, PATH entry) and restores the settings it changed. Backups are kept. Asks first.":"Entfernt nur, was die Einrichtung hinzugef\u00fcgt hat (Befehl, Verkn\u00fcpfungen, PATH-Eintrag), und stellt die ge\u00e4nderten Einstellungen wieder her. Sicherungen bleiben erhalten. Fragt vorher.","Removing shortcuts":"Verkn\u00fcpfungen werden entfernt","Removing the opencode command":"opencode-Befehl wird entfernt","Renew did not finish (code {0}).":"Die Erneuerung wurde nicht abgeschlossen (Code {0}).","Renew session":"Sitzung erneuern","Renew the session?":"Sitzung erneuern?","Renewed. Open opencode again; you may need to log in once more.":"Erneuert. \u00d6ffne opencode erneut; eventuell musst du dich noch einmal anmelden.","Renewing":"Wird erneuert","Renewing the session":"Sitzung wird erneuert","Reopen the last folder":"Letzten Ordner erneut \u00f6ffnen","Report ready. Personal data was removed; read it once before you share it.":"Bericht fertig. Pers\u00f6nliche Daten wurden entfernt; lies ihn einmal durch, bevor du ihn teilst.","Repository":"Repository","Reset every setting to its default?":"Alle Einstellungen auf den Standard zur\u00fccksetzen?","Reset to default values":"Auf Standardwerte zur\u00fccksetzen","Restores the settings setup changed. Your other settings and your opencode files are kept.":"Stellt die von der Einrichtung ge\u00e4nderten Einstellungen wieder her. Deine anderen Einstellungen und deine opencode-Dateien bleiben erhalten.","Restoring PATH":"PATH wird wiederhergestellt","Restoring settings":"Einstellungen werden wiederhergestellt","Resume message":"Fortsetzungsnachricht","Resume timeout (s)":"Zeitlimit der Fortsetzung (s)","Return to the connection details.":"Zur\u00fcck zu den Verbindungsdetails.","Return to the main menu.":"Zur\u00fcck zum Hauptmen\u00fc.","Return to the settings groups.":"Zur\u00fcck zu den Einstellungsgruppen.","Review":"Zusammenfassung","Rotate the connection only (new WARP registration, Tor circuit or proxy) without opening OpenCode.":"Rotiert nur die Verbindung (neue WARP-Registrierung, Tor-Verbindung oder Proxy), ohne OpenCode zu \u00f6ffnen.","Rotate when a fatal error appears while opencode runs.":"Rotiert, wenn w\u00e4hrend der Ausf\u00fchrung von opencode ein schwerer Fehler auftritt.","Rotation":"Rotation","Rotation attempts":"Rotationsversuche","Rotation rounds":"Rotationsrunden","Run mode":"Ausf\u00fchrungsmodus","Run opencode in this terminal. After a new IP the chat resumes by itself.":"F\u00fchrt opencode in diesem Terminal aus. Nach einer neuen IP setzt sich der Chat von selbst fort.","Run the OpenCode desktop app ({0}). It is restarted after every new IP.":"F\u00fchrt die OpenCode-Desktop-App aus ({0}). Sie wird nach jeder neuen IP neu gestartet.","Run the setup again to change the method or repair the opencode command.":"F\u00fchrt die Einrichtung erneut aus, um die Methode zu \u00e4ndern oder den opencode-Befehl zu reparieren.","SOCKS port of the Tor the launcher starts.":"SOCKS-Port des Tor, das der Launcher startet.","Save the settings, create the opencode command, the shortcuts and the PATH entry, then test the connection.":"Speichert die Einstellungen, erstellt den opencode-Befehl, die Verkn\u00fcpfungen und den PATH-Eintrag und testet dann die Verbindung.","Saved: {0} = {1}":"Gespeichert: {0} = {1}","Saving config.json":"config.json wird gespeichert","Seconds a single \"where\" lookup may take.":"Sekunden, die eine einzelne \"where\"-Suche dauern darf.","Seconds a single proxy test may take.":"Sekunden, die ein einzelner Proxy-Test dauern darf.","Seconds a single warp-cli call may take.":"Sekunden, die ein einzelner warp-cli-Aufruf dauern darf.","Seconds before a silent resume counts as a dead IP.":"Sekunden, bevor eine stumme Fortsetzung als tote IP z\u00e4hlt.","Seconds to wait after (re)connecting WARP.":"Sekunden Wartezeit nach dem (erneuten) Verbinden von WARP.","Seconds to wait for Tor to finish bootstrapping.":"Sekunden Wartezeit, bis Tor fertig gestartet ist.","See what the setup installed (command, shortcuts, PATH) and run it again to change the method.":"Zeigt, was die Einrichtung installiert hat (Befehl, Verkn\u00fcpfungen, PATH), und f\u00fchrt sie erneut aus, um die Methode zu \u00e4ndern.","Send one cheap message through each candidate IP.":"Sendet eine g\u00fcnstige Nachricht \u00fcber jede Kandidaten-IP.","Sent automatically after a rotation.":"Wird nach einer Rotation automatisch gesendet.","Settings":"Einstellungen","Settings and setup":"Einstellungen und Einrichtung","Setup 1/3 - connection method":"Einrichtung 1/3 - Verbindungsmethode","Setup 2/3 - details":"Einrichtung 2/3 - Details","Setup 3/3 - run mode":"Einrichtung 3/3 - Ausf\u00fchrungsmodus","Setup stopped: {0}":"Die Einrichtung wurde angehalten: {0}","Shortcuts":"Verkn\u00fcpfungen","Show the CLI or Desktop choice every time the launcher opens.":"Zeigt die Wahl CLI oder Desktop bei jedem \u00d6ffnen des Launchers.","Show the report in Explorer so you can attach or paste it.":"Zeigt den Bericht im Explorer, damit du ihn anh\u00e4ngen oder einf\u00fcgen kannst.","Size used with the chosen font.":"Gr\u00f6\u00dfe, die mit der gew\u00e4hlten Schrift verwendet wird.","Support":"Support","Support report":"Support-Bericht","Switch between the terminal and the desktop app.":"Zwischen Terminal und Desktop-App wechseln.","Switch to Tor and keep going?":"Zu Tor wechseln und weitermachen?","System":"System","Takes effect at the {0}; a service already running keeps the old value until then.":"Gilt ab: {0}; ein bereits laufender Dienst beh\u00e4lt bis dahin den alten Wert.","Terminal font":"Terminal-Schrift","Test every new IP":"Jede neue IP testen","The OpenCode desktop app was not found. Choosing this offers to download and install it.":"Die OpenCode-Desktop-App wurde nicht gefunden. Bei dieser Auswahl wird angeboten, sie herunterzuladen und zu installieren.","The OpenCode desktop app; it is restarted after every new IP.":"Die OpenCode-Desktop-App; sie wird nach jeder neuen IP neu gestartet.","The activity log (launcher.log) and the support report: what is recorded, how big it may grow, whether IPs are masked.":"Das Aktivit\u00e4tsprotokoll (launcher.log) und der Support-Bericht: was aufgezeichnet wird, wie gro\u00df es werden darf und ob IPs maskiert werden.","The cheap test message sent through every new IP before it is trusted.":"Die g\u00fcnstige Testnachricht, die \u00fcber jede neue IP gesendet wird, bevor ihr vertraut wird.","The check failed (code {0}). Setup is saved; fix the cause and use Renew or Connect again.":"Die Pr\u00fcfung ist fehlgeschlagen (Code {0}). Die Einrichtung ist gespeichert; behebe die Ursache und nutze Erneuern oder Verbinden erneut.","The font applies to the whole terminal window, not only to this launcher.":"Die Schrift gilt f\u00fcr das ganze Terminalfenster, nicht nur f\u00fcr diesen Launcher.","The proxy lives only in the opencode process; the rest of the system stays direct.":"Der Proxy gilt nur im opencode-Prozess; der Rest des Systems bleibt direkt.","The resume auto-approves tool permissions.":"Die Fortsetzung genehmigt Werkzeugberechtigungen automatisch.","The shortcut and the opencode command use the CLI; this is the launcher menu default.":"Die Verkn\u00fcpfung und der opencode-Befehl nutzen die CLI; dies ist der Standard im Launcher-Men\u00fc.","The terminal interface. The opencode command and the shortcut always use it.":"Die Terminal-Oberfl\u00e4che. Der opencode-Befehl und die Verkn\u00fcpfung nutzen immer sie.","This launcher is not the one that set it up. Reconfigure to repair the command.":"Dieser Launcher ist nicht der, der es eingerichtet hat. Richte neu ein, um den Befehl zu reparieren.","Token reset":"Token-Reset","Tools and versions":"Werkzeuge und Versionen","Tor HTTP bridge port":"Port der Tor-HTTP-Br\u00fccke","Tor SOCKS port":"Tor-SOCKS-Port","Tor bootstrap wait (s)":"Wartezeit f\u00fcr den Tor-Start (s)","Tor is downloaded once, run hidden and offered to opencode through a built-in HTTP bridge. Slower, but a new circuit is a new IP.":"Tor wird einmal heruntergeladen, versteckt ausgef\u00fchrt und opencode \u00fcber eine integrierte HTTP-Br\u00fccke angeboten. Langsamer, aber eine neue Verbindung ist eine neue IP.","Try again in a minute, or pick another connection method in Connect with opencode.":"Versuche es in einer Minute erneut oder w\u00e4hle unter \"Mit opencode verbinden\" eine andere Verbindungsmethode.","Try again?":"Erneut versuchen?","Try to download and install WARP now?":"WARP jetzt herunterladen und installieren?","Type \"opencode\" in a NEW terminal, or use the \"OpenCode Infinite (egress)\" shortcut.":"Gib \"opencode\" in einem NEUEN Terminal ein oder nutze die Verkn\u00fcpfung \"OpenCode Infinite (egress)\".","Type < to go back. Enter keeps the value shown.":"Gib < ein, um zur\u00fcckzugehen. Enter beh\u00e4lt den angezeigten Wert.","Type a font name...":"Schriftnamen eingeben...","URL or local file, any format (plain, CSV, JSON, XML, HTML).":"URL oder lokale Datei, beliebiges Format (Text, CSV, JSON, XML, HTML).","Unattended resume":"Unbeaufsichtigte Fortsetzung","Uninstall":"Deinstallieren","Uninstall stopped: {0}":"Die Deinstallation wurde angehalten: {0}","Uninstall the opencode connection?":"Die opencode-Verbindung deinstallieren?","Uninstalled. Backups stay in {0}":"Deinstalliert. Sicherungen bleiben in {0}","Uninstalling":"Wird deinstalliert","Update now?":"Jetzt aktualisieren?","Updates":"Updates","Use 1 to 200 characters.":"Verwende 1 bis 200 Zeichen.","Use it when the free limit is hit or the login expired: closes opencode, saves and clears the saved tokens, and gets a new IP, WARP registration, Tor circuit or proxy.":"Nutze es, wenn das kostenlose Limit erreicht ist oder die Anmeldung abgelaufen ist: beendet opencode, sichert und l\u00f6scht die gespeicherten Tokens und holt eine neue IP, WARP-Registrierung, Tor-Verbindung oder einen neuen Proxy.","Use on or off.":"Verwende on oder off.","Use that proxy anyway?":"Diesen Proxy trotzdem verwenden?","Use this folder":"Diesen Ordner verwenden","Use up to 31 characters, without quotes or backslashes.":"Verwende bis zu 31 Zeichen, ohne Anf\u00fchrungszeichen oder Backslashes.","Use {0} for the terminal text. Monospaced fonts only look right.":"Verwendet {0} f\u00fcr den Terminaltext. Nur Schriften mit fester Breite sehen richtig aus.","Version":"Version","View and change every launcher option: connection, proxies, Tor, rotation, themes. Saved instantly, no files to edit.":"Zeigt und \u00e4ndert jede Launcher-Option: Verbindung, Proxys, Tor, Rotation, Designs. Wird sofort gespeichert, keine Dateien zu bearbeiten.","WARP proxy port":"WARP-Proxy-Port","WARP wait (s)":"WARP-Wartezeit (s)","Watch the log":"Protokoll \u00fcberwachen","Watcher":"\u00dcberwachung","Watching the opencode log and the automatic \"continue\" sent after a rotation.":"\u00dcberwachung des opencode-Protokolls und das automatische \"continue\" nach einer Rotation.","Where proxies come from (URL or file, any format) and how each one is tested.":"Woher die Proxys kommen (URL oder Datei, beliebiges Format) und wie jeder getestet wird.","Where versions and checksums are read from.":"Woher Versionen und Pr\u00fcfsummen gelesen werden.","Whether the launcher checks GitHub for a newer copy of itself at every start.":"Ob der Launcher bei jedem Start auf GitHub nach einer neueren Kopie seiner selbst sucht.","Work in a different folder.":"In einem anderen Ordner arbeiten.","Work in the folder the launcher was started from: {0}":"In dem Ordner arbeiten, aus dem der Launcher gestartet wurde: {0}","Work in {0}":"In {0} arbeiten","Writing the report":"Bericht wird geschrieben","Yes":"Ja","Yes, continue":"Ja, fortfahren","Your connection setup (shim, shortcuts) is not touched.":"Deine Verbindungseinrichtung (Shim, Verkn\u00fcpfungen) bleibt unber\u00fchrt.","Your session needs renewing: {0}":"Deine Sitzung muss erneuert werden: {0}","asks first":"fragt vorher","auto":"auto","auto follows the terminal and NO_COLOR; off disables colors.":"auto folgt dem Terminal und NO_COLOR; off schaltet Farben ab.","direct":"direkt","emoji = modern terminals, unicode = classic console, ascii = anything.":"emoji = moderne Terminals, unicode = klassische Konsole, ascii = alles.","free list":"freie Liste","installed":"installiert","missing":"fehlt","new IP":"neue IP","next Tor start":"n\u00e4chsten Tor-Start","next WARP connect":"n\u00e4chste WARP-Verbindung","next launch":"n\u00e4chsten Start","no other step is needed.":"es ist kein weiterer Schritt n\u00f6tig.","not installed":"nicht installiert","not verified":"nicht gepr\u00fcft","off":"aus","on":"an","same IP":"gleiche IP","terminal":"Terminal","warp-cli timeout (s)":"warp-cli-Zeitlimit (s)","yes":"ja","{0} changed":"{0} ge\u00e4ndert","{0} of {1}":"{0} von {1}","After opencode closes":"Nach dem Schlie\u00dfen von opencode","ask = R, M or Q: R gets a new IP and resumes the chat, M opens the menu, Q quits. quit = leave the launcher at once.":"ask = R, M oder Q: R holt eine neue IP und setzt den Chat fort, M \u00f6ffnet das Men\u00fc, Q beendet. quit = Launcher sofort beenden."}
#>>>LANG es {" move   Enter select   Esc back   1-9 or letter jump":" mover   Intro elegir   Esc volver   1-9 o letra para saltar","(Enter = keep \"{0}\")":"(Intro = mantener \"{0}\")","(auto)":"(auto)","(nothing saved yet)":"(nada guardado todav\u00eda)","(terminal default)":"(predeterminada del terminal)","* = changed from the default. Enter edits or toggles the selected value.":"* = distinto del valor por defecto. Intro edita o alterna el valor seleccionado.","A downloaded list smaller than this is rejected. 0 = off.":"Una lista descargada m\u00e1s peque\u00f1a que esto se rechaza. 0 = desactivado.","A port is a number from 1 to 65535.":"Un puerto es un n\u00famero del 1 al 65535.","A proxy must also reach the opencode API host.":"Un proxy debe alcanzar tambi\u00e9n el servidor de la API de opencode.","API check URL":"URL de comprobaci\u00f3n de la API","Accent colors of the interface.":"Colores de acento de la interfaz.","Adding the command to your PATH":"A\u00f1adiendo el comando al PATH","Adds: opencode command (shim), two shortcuts, one PATH entry. Backups are kept.":"A\u00f1ade: el comando opencode (shim), dos accesos directos y una entrada en el PATH. Se guardan copias de seguridad.","Any installed font name, for example Cascadia Code.":"Cualquier nombre de fuente instalada, por ejemplo Cascadia Code.","Appearance":"Apariencia","Applies at the {0}.":"Se aplica en: {0}.","Apply":"Aplicar","Apply setup":"Aplicar configuraci\u00f3n","Ask every time":"Preguntar siempre","Attempts per round when the tunnel is not up.":"Intentos por ronda cuando el t\u00fanel no est\u00e1 activo.","Back":"Volver","Backing up the current configuration":"Copia de seguridad de la configuraci\u00f3n actual","Browse for a folder...":"Buscar una carpeta...","Burned IPs allowed":"IPs quemadas permitidas","Burned proxies before Tor offer":"Proxies quemados antes de ofrecer Tor","Burned proxies in a row before PROXY mode offers Tor.":"Proxies quemados seguidos antes de que el modo PROXY ofrezca Tor.","CLI terminal, Desktop app, or ask at every start.":"Terminal CLI, aplicaci\u00f3n de escritorio, o preguntar en cada inicio.","Cancel":"Cancelar","Cancel. Nothing is changed.":"Cancelar. No se cambia nada.","Change IP":"Cambiar IP","Change an answer.":"Cambiar una respuesta.","Change any launcher setting: connection, proxies, Tor, rotation, themes, font. Applied right away.":"Cambia cualquier ajuste del launcher: conexi\u00f3n, proxies, Tor, rotaci\u00f3n, temas, fuente. Se aplica al instante.","Check GitHub for a newer launcher at every start.":"Busca en GitHub un launcher m\u00e1s nuevo en cada inicio.","Check the API host":"Comprobar el servidor de la API","Checking that it works":"Comprobando que funciona","Checking the connection":"Comprobando la conexi\u00f3n","Choose \"Renew session\" below. It gets a new IP and clears the saved login;":"Elige \"Renovar sesi\u00f3n\" abajo. Obtiene una IP nueva y borra el inicio de sesi\u00f3n guardado;","Choose a folder to work in":"Elige una carpeta de trabajo","Choose one of: {0}.":"Elige uno de: {0}.","Choose the connection for OpenCode":"Elige la conexi\u00f3n para OpenCode","Close the launcher.":"Cerrar el launcher.","Closes every running opencode process.":"Cierra todos los procesos de opencode en ejecuci\u00f3n.","Cloudflare WARP in local proxy mode. Every rotation asks for a new registration, which gives a new exit IP. Needs the WARP client (offered if missing).":"Cloudflare WARP en modo proxy local. Cada rotaci\u00f3n pide un registro nuevo, que da una IP de salida nueva. Necesita el cliente WARP (se ofrece si falta).","Cloudflare WARP in proxy mode. A new registration gives a new exit IP. Rotation supported.":"Cloudflare WARP en modo proxy. Un registro nuevo da una IP de salida nueva. Admite rotaci\u00f3n.","Cloudflare throttles rapid registrations.":"Cloudflare limita los registros seguidos.","Collect system info, versions, settings and the recent log into one text file you can send for help. Passwords, tokens, your user name and (by default) IPs are removed first.":"Re\u00fane informaci\u00f3n del sistema, versiones, ajustes y el registro reciente en un archivo de texto que puedes enviar para pedir ayuda. Antes se eliminan contrase\u00f1as, tokens, tu nombre de usuario y (por defecto) las IPs.","Color theme":"Tema de color","Color theme, colors on or off, icon and border style, and the terminal font. Applied immediately.":"Tema de color, colores activados o no, estilo de iconos y bordes, idioma y fuente del terminal. Se aplica al instante.","Colors":"Colores","Command":"Comando","Configured - {0}":"Configurado - {0}","Confirm":"Confirmar","Connect with opencode":"Conectar con opencode","Connected: opencode now starts through {0}.":"Conectado: opencode ahora arranca a trav\u00e9s de {0}.","Connecting opencode":"Conectando opencode","Connection":"Conexi\u00f3n","Connection method":"M\u00e9todo de conexi\u00f3n","Continue":"Continuar","Continue WITHOUT the probe this session (IPs accepted untested)?":"\u00bfContinuar SIN la prueba en esta sesi\u00f3n (IPs aceptadas sin probar)?","Continue anyway?":"\u00bfContinuar de todos modos?","Continue direct?":"\u00bfContinuar en directo?","Continue without WARP?":"\u00bfContinuar sin WARP?","Cooldown between attempts (s)":"Espera entre intentos (s)","Copies auth.json to your Desktop, then clears the saved tokens.":"Copia auth.json a tu Escritorio y borra los tokens guardados.","Copy the file path":"Copiar la ruta del archivo","Creating shortcuts":"Creando accesos directos","Creating the opencode command":"Creando el comando opencode","Credentials inside a URL are not stored. Use a local file instead.":"Las credenciales dentro de una URL no se guardan. Usa un archivo local.","Deep reset":"Reinicio total","Default connection method and run mode, the WARP proxy port and the warp-cli timings.":"M\u00e9todo de conexi\u00f3n y modo de ejecuci\u00f3n por defecto, puerto del proxy WARP y tiempos de warp-cli.","Default: {0}.":"Por defecto: {0}.","Desktop":"Escritorio","Desktop app":"Aplicaci\u00f3n de escritorio","Desktop app location, release metadata URL and lookup timeouts.":"Ubicaci\u00f3n de la aplicaci\u00f3n de escritorio, URL de metadatos de versiones y tiempos de b\u00fasqueda.","Desktop app path":"Ruta de la aplicaci\u00f3n de escritorio","Direct, no proxy":"Directo, sin proxy","Do it now.":"Hacerlo ahora.","Do that now?":"\u00bfHacerlo ahora?","Download and install it now?":"\u00bfDescargarla e instalarla ahora?","Download the portable Tor bundle when nothing answers.":"Descarga el Tor portable cuando nada responde.","Egress":"Salida","Egress used for opencode. ASK shows the picker at every start.":"Salida que usa opencode. ASK muestra el selector en cada inicio.","Enter a full URL (http, https, ftp or file).":"Escribe una URL completa (http, https, ftp o file).","Enter a whole number.":"Escribe un n\u00famero entero.","Enter cycles: {0}.":"Intro recorre: {0}.","Enter toggles it.":"Intro lo activa o desactiva.","Every change is saved at once to {0}":"Cada cambio se guarda al instante en {0}","Exit":"Salir","Exit IP":"IP de salida","Extra rounds (60 s apart) before giving up.":"Rondas extra (con 60 s de separaci\u00f3n) antes de rendirse.","Folder":"Carpeta","Font name":"Nombre de la fuente","Font of the terminal text. Empty leaves the terminal as it is.":"Fuente del texto del terminal. Vac\u00edo deja el terminal como est\u00e1.","Font size":"Tama\u00f1o de fuente","Free HTTP proxies from your list (any format) or the default one. Each is tested before use.":"Proxies HTTP gratuitos de tu lista (cualquier formato) o de la lista por defecto. Cada uno se prueba antes de usarlo.","Free or your own list":"Gratuita o tu propia lista","Fresh start":"Inicio nuevo","Full path of OpenCode.exe. Empty = search automatically.":"Ruta completa de OpenCode.exe. Vac\u00edo = buscar autom\u00e1ticamente.","Get a new IP or proxy, then open OpenCode. Your chats and history stay untouched.":"Obtiene una IP o proxy nuevo y abre OpenCode. Tus chats e historial no se tocan.","Gets a new IP / WARP registration / Tor circuit / proxy.":"Obtiene una IP nueva / registro WARP / circuito Tor / proxy.","Go ahead.":"Adelante.","Go back. Nothing is changed.":"Volver. No se cambia nada.","Guided setup: choose WARP, Tor, a proxy list or direct, then get an \"opencode\" command and a shortcut that start with it. It is tested at the end.":"Asistente: elige WARP, Tor, una lista de proxies o conexi\u00f3n directa, y obt\u00e9n un comando \"opencode\" y un acceso directo que arrancan con ella. Se prueba al final.","HTTP port of the built-in bridge opencode uses.":"Puerto HTTP del puente integrado que usa opencode.","Host used by the API check.":"Servidor que usa la comprobaci\u00f3n de la API.","How do you want to run OpenCode?":"\u00bfC\u00f3mo quieres ejecutar OpenCode?","How many proxies to test before giving up.":"Cu\u00e1ntos proxies probar antes de rendirse.","How many times, and how fast, a new IP is requested when the free limit is hit.":"Cu\u00e1ntas veces y a qu\u00e9 ritmo se pide una IP nueva al llegar al l\u00edmite gratuito.","IPs the probe may reject before giving up. 0 = no limit.":"IPs que la prueba puede rechazar antes de rendirse. 0 = sin l\u00edmite.","Icons and borders":"Iconos y bordes","Install Tor automatically":"Instalar Tor autom\u00e1ticamente","Keep the current connection and open OpenCode as it was.":"Mantiene la conexi\u00f3n actual y abre OpenCode como estaba.","Keep the current font.":"Mantener la fuente actual.","Kill opencode and clear the saved tokens, keeping your chats where they are.":"Cierra opencode y borra los tokens guardados, dejando tus chats donde est\u00e1n.","Kill opencode, move your chats to the Desktop, clear the saved tokens and open a fresh session.":"Cierra opencode, mueve tus chats al Escritorio, borra los tokens guardados y abre una sesi\u00f3n nueva.","Language":"Idioma","Language of the menus and descriptions. auto follows Windows. Logs and the support report stay in English.":"Idioma de los men\u00fas y descripciones. auto sigue a Windows. Los registros y el informe de soporte se quedan en ingl\u00e9s.","Last check":"\u00daltima comprobaci\u00f3n","Launch OpenCode":"Iniciar OpenCode","Launcher":"Launcher","Launcher self-update":"Autoactualizaci\u00f3n del launcher","Leave the setup without changing anything.":"Salir del asistente sin cambiar nada.","Leave the terminal font as it is. If the launcher changed it, the original font comes back.":"Deja la fuente del terminal como est\u00e1. Si el launcher la cambi\u00f3, vuelve la original.","Local Tor with a built-in HTTP bridge. A portable Tor is installed automatically if missing.":"Tor local con un puente HTTP integrado. Si falta, se instala un Tor portable autom\u00e1ticamente.","Local port of the WARP proxy.":"Puerto local del proxy WARP.","Logs":"Registros","Main menu":"Men\u00fa principal","Method":"M\u00e9todo","Minimum list size (bytes)":"Tama\u00f1o m\u00ednimo de la lista (bytes)","Mode":"Modo","Model used by the IP probe.":"Modelo que usa la prueba de IP.","Must be between {0} and {1}.":"Debe estar entre {0} y {1}.","New IP and resume in 5s":"IP nueva y reanudar en 5 s","No":"No","No .exe file exists at that path.":"No hay ning\u00fan archivo .exe en esa ruta.","No answer in {0}s counts as No.":"Sin respuesta en {0} s cuenta como No.","No change.":"Sin cambios.","No proxy: opencode uses your real connection and nothing is rotated.":"Sin proxy: opencode usa tu conexi\u00f3n real y no se rota nada.","No, cancel":"No, cancelar","Non-limit probe failures before the hunt stops.":"Fallos de la prueba que no son del l\u00edmite antes de parar la b\u00fasqueda.","Not a URL, and no file exists at that path.":"No es una URL y no existe ning\u00fan archivo en esa ruta.","Not configured":"Sin configurar","Nothing to ask for a direct connection.":"No hay nada que preguntar para una conexi\u00f3n directa.","Nothing was left half done that Uninstall cannot remove. Fix the problem and run setup again.":"No qued\u00f3 nada a medias que Desinstalar no pueda quitar. Arregla el problema y ejecuta el asistente otra vez.","On PATH":"En el PATH","Only opencode uses it; the rest of the system stays direct.":"Solo opencode la usa; el resto del sistema sigue en directo.","Open the Windows folder picker and choose where to work.":"Abre el selector de carpetas de Windows para elegir d\u00f3nde trabajar.","Open the folder":"Abrir la carpeta","Open the launcher menus: pick a folder and a connection method, then start the opencode CLI or the desktop app.":"Abre los men\u00fas del launcher: elige carpeta y m\u00e9todo de conexi\u00f3n, y arranca la CLI de opencode o la aplicaci\u00f3n de escritorio.","OpenCode app":"App de OpenCode","PATH lookup timeout (s)":"Tiempo m\u00e1ximo de b\u00fasqueda en el PATH (s)","Paths":"Rutas","Port {0} is already used by {1}.":"El puerto {0} ya lo usa {1}.","Ports and install behavior of the portable Tor the launcher starts for you.":"Puertos e instalaci\u00f3n del Tor portable que el launcher arranca por ti.","Press any key to continue...":"Pulsa una tecla para continuar...","Probe":"Prueba","Probe failures tolerated":"Fallos de prueba tolerados","Probe model":"Modelo de prueba","Proxies tried per pick":"Proxies probados por elecci\u00f3n","Proxy":"Proxy","Proxy list":"Lista de proxies","Proxy list source":"Origen de la lista de proxies","Proxy test timeout (s)":"Tiempo m\u00e1ximo de prueba de un proxy (s)","Public HTTP proxies from a list (yours, in any format, or the free default). Each one is tested first and burned ones are skipped.":"Proxies HTTP p\u00fablicos de una lista (la tuya, en cualquier formato, o la gratuita por defecto). Cada uno se prueba primero y los quemados se saltan.","Put every setting back to its default. Your connection setup (command, shortcuts) is not touched. Asks first.":"Devuelve todos los ajustes a su valor por defecto. Tu configuraci\u00f3n de conexi\u00f3n (comando, accesos directos) no se toca. Pide confirmaci\u00f3n.","Put the full path on the clipboard.":"Pone la ruta completa en el portapapeles.","Quotes and line breaks are not allowed.":"No se permiten comillas ni saltos de l\u00ednea.","Range {0} to {1}.":"Rango de {0} a {1}.","Reconfigure (run setup again)":"Reconfigurar (ejecutar el asistente otra vez)","Release metadata URL":"URL de metadatos de versiones","Removes only what setup added: the opencode command, the shortcuts and the PATH entry.":"Elimina solo lo que a\u00f1adi\u00f3 el asistente: el comando opencode, los accesos directos y la entrada del PATH.","Removes only what the setup added (command, shortcuts, PATH entry) and restores the settings it changed. Backups are kept. Asks first.":"Elimina solo lo que a\u00f1adi\u00f3 el asistente (comando, accesos directos, entrada del PATH) y restaura los ajustes que cambi\u00f3. Se conservan las copias de seguridad. Pide confirmaci\u00f3n.","Removing shortcuts":"Eliminando accesos directos","Removing the opencode command":"Eliminando el comando opencode","Renew did not finish (code {0}).":"La renovaci\u00f3n no termin\u00f3 (c\u00f3digo {0}).","Renew session":"Renovar sesi\u00f3n","Renew the session?":"\u00bfRenovar la sesi\u00f3n?","Renewed. Open opencode again; you may need to log in once more.":"Renovada. Abre opencode otra vez; quiz\u00e1 tengas que iniciar sesi\u00f3n de nuevo.","Renewing":"Renovando","Renewing the session":"Renovando la sesi\u00f3n","Reopen the last folder":"Reabrir la \u00faltima carpeta","Report ready. Personal data was removed; read it once before you share it.":"Informe listo. Se eliminaron los datos personales; l\u00e9elo una vez antes de compartirlo.","Repository":"Repositorio","Reset every setting to its default?":"\u00bfDevolver todos los ajustes a su valor por defecto?","Reset to default values":"Restablecer valores por defecto","Restores the settings setup changed. Your other settings and your opencode files are kept.":"Restaura los ajustes que cambi\u00f3 el asistente. Tus otros ajustes y tus archivos de opencode se conservan.","Restoring PATH":"Restaurando el PATH","Restoring settings":"Restaurando ajustes","Resume message":"Mensaje de reanudaci\u00f3n","Resume timeout (s)":"Tiempo m\u00e1ximo de reanudaci\u00f3n (s)","Return to the connection details.":"Volver a los detalles de la conexi\u00f3n.","Return to the main menu.":"Volver al men\u00fa principal.","Return to the settings groups.":"Volver a los grupos de ajustes.","Review":"Resumen","Rotate the connection only (new WARP registration, Tor circuit or proxy) without opening OpenCode.":"Rota solo la conexi\u00f3n (registro WARP, circuito Tor o proxy nuevo) sin abrir OpenCode.","Rotate when a fatal error appears while opencode runs.":"Rota cuando aparece un error grave mientras opencode se ejecuta.","Rotation":"Rotaci\u00f3n","Rotation attempts":"Intentos de rotaci\u00f3n","Rotation rounds":"Rondas de rotaci\u00f3n","Run mode":"Modo de ejecuci\u00f3n","Run opencode in this terminal. After a new IP the chat resumes by itself.":"Ejecuta opencode en este terminal. Tras una IP nueva el chat se reanuda solo.","Run the OpenCode desktop app ({0}). It is restarted after every new IP.":"Ejecuta la aplicaci\u00f3n de escritorio de OpenCode ({0}). Se reinicia tras cada IP nueva.","Run the setup again to change the method or repair the opencode command.":"Ejecuta el asistente otra vez para cambiar el m\u00e9todo o reparar el comando opencode.","SOCKS port of the Tor the launcher starts.":"Puerto SOCKS del Tor que arranca el launcher.","Save the settings, create the opencode command, the shortcuts and the PATH entry, then test the connection.":"Guarda los ajustes, crea el comando opencode, los accesos directos y la entrada del PATH, y prueba la conexi\u00f3n.","Saved: {0} = {1}":"Guardado: {0} = {1}","Saving config.json":"Guardando config.json","Seconds a single \"where\" lookup may take.":"Segundos que puede tardar una b\u00fasqueda con \"where\".","Seconds a single proxy test may take.":"Segundos que puede tardar la prueba de un proxy.","Seconds a single warp-cli call may take.":"Segundos que puede tardar una llamada a warp-cli.","Seconds before a silent resume counts as a dead IP.":"Segundos antes de que una reanudaci\u00f3n sin respuesta cuente como IP muerta.","Seconds to wait after (re)connecting WARP.":"Segundos de espera tras (re)conectar WARP.","Seconds to wait for Tor to finish bootstrapping.":"Segundos de espera a que Tor termine de arrancar.","See what the setup installed (command, shortcuts, PATH) and run it again to change the method.":"Mira lo que instal\u00f3 el asistente (comando, accesos directos, PATH) y ejec\u00fatalo otra vez para cambiar el m\u00e9todo.","Send one cheap message through each candidate IP.":"Env\u00eda un mensaje barato por cada IP candidata.","Sent automatically after a rotation.":"Se env\u00eda autom\u00e1ticamente tras una rotaci\u00f3n.","Settings":"Ajustes","Settings and setup":"Ajustes y configuraci\u00f3n","Setup 1/3 - connection method":"Configuraci\u00f3n 1/3 - m\u00e9todo de conexi\u00f3n","Setup 2/3 - details":"Configuraci\u00f3n 2/3 - detalles","Setup 3/3 - run mode":"Configuraci\u00f3n 3/3 - modo de ejecuci\u00f3n","Setup stopped: {0}":"El asistente se detuvo: {0}","Shortcuts":"Accesos directos","Show the CLI or Desktop choice every time the launcher opens.":"Muestra la elecci\u00f3n CLI o Escritorio cada vez que se abre el launcher.","Show the report in Explorer so you can attach or paste it.":"Muestra el informe en el Explorador para que puedas adjuntarlo o pegarlo.","Size used with the chosen font.":"Tama\u00f1o que se usa con la fuente elegida.","Support":"Soporte","Support report":"Informe de soporte","Switch between the terminal and the desktop app.":"Cambia entre el terminal y la aplicaci\u00f3n de escritorio.","Switch to Tor and keep going?":"\u00bfCambiar a Tor y seguir?","System":"Sistema","Takes effect at the {0}; a service already running keeps the old value until then.":"Surte efecto en: {0}; un servicio que ya est\u00e9 en marcha conserva el valor anterior hasta entonces.","Terminal font":"Fuente del terminal","Test every new IP":"Probar cada IP nueva","The OpenCode desktop app was not found. Choosing this offers to download and install it.":"No se encontr\u00f3 la aplicaci\u00f3n de escritorio de OpenCode. Al elegirla se ofrece descargarla e instalarla.","The OpenCode desktop app; it is restarted after every new IP.":"La aplicaci\u00f3n de escritorio de OpenCode; se reinicia tras cada IP nueva.","The activity log (launcher.log) and the support report: what is recorded, how big it may grow, whether IPs are masked.":"El registro de actividad (launcher.log) y el informe de soporte: qu\u00e9 se guarda, cu\u00e1nto puede crecer y si se ocultan las IPs.","The cheap test message sent through every new IP before it is trusted.":"El mensaje de prueba barato que se env\u00eda por cada IP nueva antes de fiarse de ella.","The check failed (code {0}). Setup is saved; fix the cause and use Renew or Connect again.":"La comprobaci\u00f3n fall\u00f3 (c\u00f3digo {0}). La configuraci\u00f3n est\u00e1 guardada; arregla la causa y usa Renovar o Conectar otra vez.","The font applies to the whole terminal window, not only to this launcher.":"La fuente se aplica a toda la ventana del terminal, no solo a este launcher.","The proxy lives only in the opencode process; the rest of the system stays direct.":"El proxy vive solo en el proceso de opencode; el resto del sistema sigue en directo.","The resume auto-approves tool permissions.":"La reanudaci\u00f3n aprueba sola los permisos de las herramientas.","The shortcut and the opencode command use the CLI; this is the launcher menu default.":"El acceso directo y el comando opencode usan la CLI; esto es lo predeterminado del men\u00fa del launcher.","The terminal interface. The opencode command and the shortcut always use it.":"La interfaz de terminal. El comando opencode y el acceso directo siempre la usan.","This launcher is not the one that set it up. Reconfigure to repair the command.":"Este launcher no es el que lo configur\u00f3. Reconfigura para reparar el comando.","Token reset":"Reinicio de tokens","Tools and versions":"Herramientas y versiones","Tor HTTP bridge port":"Puerto del puente HTTP de Tor","Tor SOCKS port":"Puerto SOCKS de Tor","Tor bootstrap wait (s)":"Espera de arranque de Tor (s)","Tor is downloaded once, run hidden and offered to opencode through a built-in HTTP bridge. Slower, but a new circuit is a new IP.":"Tor se descarga una vez, se ejecuta oculto y se ofrece a opencode mediante un puente HTTP integrado. M\u00e1s lento, pero un circuito nuevo es una IP nueva.","Try again in a minute, or pick another connection method in Connect with opencode.":"Int\u00e9ntalo de nuevo en un minuto, o elige otro m\u00e9todo de conexi\u00f3n en Conectar con opencode.","Try again?":"\u00bfIntentarlo de nuevo?","Try to download and install WARP now?":"\u00bfIntentar descargar e instalar WARP ahora?","Type \"opencode\" in a NEW terminal, or use the \"OpenCode Infinite (egress)\" shortcut.":"Escribe \"opencode\" en un terminal NUEVO, o usa el acceso directo \"OpenCode Infinite (egress)\".","Type < to go back. Enter keeps the value shown.":"Escribe < para volver. Intro mantiene el valor mostrado.","Type a font name...":"Escribir el nombre de una fuente...","URL or local file, any format (plain, CSV, JSON, XML, HTML).":"URL o archivo local, en cualquier formato (texto plano, CSV, JSON, XML, HTML).","Unattended resume":"Reanudaci\u00f3n desatendida","Uninstall":"Desinstalar","Uninstall stopped: {0}":"La desinstalaci\u00f3n se detuvo: {0}","Uninstall the opencode connection?":"\u00bfDesinstalar la conexi\u00f3n de opencode?","Uninstalled. Backups stay in {0}":"Desinstalado. Las copias de seguridad quedan en {0}","Uninstalling":"Desinstalando","Update now?":"\u00bfActualizar ahora?","Updates":"Actualizaciones","Use 1 to 200 characters.":"Usa de 1 a 200 caracteres.","Use it when the free limit is hit or the login expired: closes opencode, saves and clears the saved tokens, and gets a new IP, WARP registration, Tor circuit or proxy.":"\u00dasala cuando se alcance el l\u00edmite gratuito o caduque el inicio de sesi\u00f3n: cierra opencode, guarda y borra los tokens guardados, y obtiene una IP, registro WARP, circuito Tor o proxy nuevo.","Use on or off.":"Usa on u off.","Use that proxy anyway?":"\u00bfUsar ese proxy de todos modos?","Use this folder":"Usar esta carpeta","Use up to 31 characters, without quotes or backslashes.":"Usa hasta 31 caracteres, sin comillas ni barras invertidas.","Use {0} for the terminal text. Monospaced fonts only look right.":"Usa {0} para el texto del terminal. Solo las fuentes monoespaciadas se ven bien.","Version":"Versi\u00f3n","View and change every launcher option: connection, proxies, Tor, rotation, themes. Saved instantly, no files to edit.":"Mira y cambia cualquier opci\u00f3n del launcher: conexi\u00f3n, proxies, Tor, rotaci\u00f3n, temas. Se guarda al instante, sin editar archivos.","WARP proxy port":"Puerto del proxy WARP","WARP wait (s)":"Espera de WARP (s)","Watch the log":"Vigilar el registro","Watcher":"Vigilante","Watching the opencode log and the automatic \"continue\" sent after a rotation.":"Vigilancia del registro de opencode y del \"continue\" autom\u00e1tico tras una rotaci\u00f3n.","Where proxies come from (URL or file, any format) and how each one is tested.":"De d\u00f3nde vienen los proxies (URL o archivo, cualquier formato) y c\u00f3mo se prueba cada uno.","Where versions and checksums are read from.":"De d\u00f3nde se leen las versiones y las sumas de verificaci\u00f3n.","Whether the launcher checks GitHub for a newer copy of itself at every start.":"Si el launcher busca en GitHub una copia m\u00e1s nueva de s\u00ed mismo en cada inicio.","Work in a different folder.":"Trabajar en otra carpeta.","Work in the folder the launcher was started from: {0}":"Trabajar en la carpeta desde la que se inici\u00f3 el launcher: {0}","Work in {0}":"Trabajar en {0}","Writing the report":"Escribiendo el informe","Yes":"S\u00ed","Yes, continue":"S\u00ed, continuar","Your connection setup (shim, shortcuts) is not touched.":"Tu configuraci\u00f3n de conexi\u00f3n (shim, accesos directos) no se toca.","Your session needs renewing: {0}":"Tu sesi\u00f3n necesita renovarse: {0}","asks first":"pide confirmaci\u00f3n","auto":"auto","auto follows the terminal and NO_COLOR; off disables colors.":"auto sigue al terminal y a NO_COLOR; off desactiva los colores.","direct":"directo","emoji = modern terminals, unicode = classic console, ascii = anything.":"emoji = terminales modernos, unicode = consola cl\u00e1sica, ascii = cualquiera.","free list":"lista gratuita","installed":"instalada","missing":"falta","new IP":"IP nueva","next Tor start":"pr\u00f3ximo arranque de Tor","next WARP connect":"pr\u00f3xima conexi\u00f3n de WARP","next launch":"pr\u00f3ximo inicio","no other step is needed.":"no hace falta ning\u00fan otro paso.","not installed":"no instalada","not verified":"sin verificar","off":"desactivado","on":"activado","same IP":"misma IP","terminal":"terminal","warp-cli timeout (s)":"Tiempo m\u00e1ximo de warp-cli (s)","yes":"s\u00ed","{0} changed":"{0} cambiados","{0} of {1}":"{0} de {1}","After opencode closes":"opencode al cerrarse","ask = R, M or Q: R gets a new IP and resumes the chat, M opens the menu, Q quits. quit = leave the launcher at once.":"ask = R, M o Q: R pide una IP nueva y retoma el chat, M abre el men\u00fa, Q sale. quit = cierra el lanzador de inmediato."}
#>>>LANG fr {" move   Enter select   Esc back   1-9 or letter jump":" d\u00e9placer   Entr\u00e9e choisir   \u00c9chap retour   1-9 ou lettre pour sauter","(Enter = keep \"{0}\")":"(Entr\u00e9e = garder \"{0}\")","(auto)":"(auto)","(nothing saved yet)":"(rien d'enregistr\u00e9 pour l'instant)","(terminal default)":"(police par d\u00e9faut du terminal)","* = changed from the default. Enter edits or toggles the selected value.":"* = diff\u00e9rent de la valeur par d\u00e9faut. Entr\u00e9e modifie ou bascule la valeur s\u00e9lectionn\u00e9e.","A downloaded list smaller than this is rejected. 0 = off.":"Une liste t\u00e9l\u00e9charg\u00e9e plus petite que cela est rejet\u00e9e. 0 = d\u00e9sactiv\u00e9.","A port is a number from 1 to 65535.":"Un port est un nombre de 1 \u00e0 65535.","A proxy must also reach the opencode API host.":"Un proxy doit aussi atteindre le serveur de l'API d'opencode.","API check URL":"URL de v\u00e9rification de l'API","Accent colors of the interface.":"Couleurs d'accent de l'interface.","Adding the command to your PATH":"Ajout de la commande au PATH","Adds: opencode command (shim), two shortcuts, one PATH entry. Backups are kept.":"Ajoute : la commande opencode (shim), deux raccourcis et une entr\u00e9e PATH. Les sauvegardes sont conserv\u00e9es.","Any installed font name, for example Cascadia Code.":"N'importe quel nom de police install\u00e9e, par exemple Cascadia Code.","Appearance":"Apparence","Applies at the {0}.":"S'applique \u00e0 : {0}.","Apply":"Appliquer","Apply setup":"Appliquer la configuration","Ask every time":"Demander \u00e0 chaque fois","Attempts per round when the tunnel is not up.":"Tentatives par tour quand le tunnel n'est pas actif.","Back":"Retour","Backing up the current configuration":"Sauvegarde de la configuration actuelle","Browse for a folder...":"Choisir un dossier...","Burned IPs allowed":"IP grill\u00e9es autoris\u00e9es","Burned proxies before Tor offer":"Proxys grill\u00e9s avant de proposer Tor","Burned proxies in a row before PROXY mode offers Tor.":"Proxys grill\u00e9s d'affil\u00e9e avant que le mode PROXY propose Tor.","CLI terminal, Desktop app, or ask at every start.":"Terminal CLI, application de bureau, ou demander \u00e0 chaque d\u00e9marrage.","Cancel":"Annuler","Cancel. Nothing is changed.":"Annuler. Rien n'est modifi\u00e9.","Change IP":"Changer d'IP","Change an answer.":"Modifier une r\u00e9ponse.","Change any launcher setting: connection, proxies, Tor, rotation, themes, font. Applied right away.":"Modifie n'importe quel r\u00e9glage du launcher : connexion, proxys, Tor, rotation, th\u00e8mes, police. Appliqu\u00e9 imm\u00e9diatement.","Check GitHub for a newer launcher at every start.":"Cherche sur GitHub un launcher plus r\u00e9cent \u00e0 chaque d\u00e9marrage.","Check the API host":"V\u00e9rifier le serveur de l'API","Checking that it works":"V\u00e9rification du fonctionnement","Checking the connection":"V\u00e9rification de la connexion","Choose \"Renew session\" below. It gets a new IP and clears the saved login;":"Choisissez \u00ab Renouveler la session \u00bb ci-dessous. Cela obtient une nouvelle IP et efface la connexion enregistr\u00e9e ;","Choose a folder to work in":"Choisissez un dossier de travail","Choose one of: {0}.":"Choisissez parmi : {0}.","Choose the connection for OpenCode":"Choisissez la connexion pour OpenCode","Close the launcher.":"Fermer le launcher.","Closes every running opencode process.":"Ferme tous les processus opencode en cours.","Cloudflare WARP in local proxy mode. Every rotation asks for a new registration, which gives a new exit IP. Needs the WARP client (offered if missing).":"Cloudflare WARP en mode proxy local. Chaque rotation demande une nouvelle inscription, ce qui donne une nouvelle IP de sortie. N\u00e9cessite le client WARP (propos\u00e9 s'il manque).","Cloudflare WARP in proxy mode. A new registration gives a new exit IP. Rotation supported.":"Cloudflare WARP en mode proxy. Une nouvelle inscription donne une nouvelle IP de sortie. Rotation prise en charge.","Cloudflare throttles rapid registrations.":"Cloudflare limite les inscriptions rapproch\u00e9es.","Collect system info, versions, settings and the recent log into one text file you can send for help. Passwords, tokens, your user name and (by default) IPs are removed first.":"Rassemble les infos syst\u00e8me, les versions, les r\u00e9glages et le journal r\u00e9cent dans un fichier texte \u00e0 envoyer pour obtenir de l'aide. Mots de passe, jetons, nom d'utilisateur et (par d\u00e9faut) IP sont supprim\u00e9s au pr\u00e9alable.","Color theme":"Th\u00e8me de couleurs","Color theme, colors on or off, icon and border style, and the terminal font. Applied immediately.":"Th\u00e8me de couleurs, couleurs activ\u00e9es ou non, style des ic\u00f4nes et bordures, langue et police du terminal. Appliqu\u00e9 imm\u00e9diatement.","Colors":"Couleurs","Command":"Commande","Configured - {0}":"Configur\u00e9 - {0}","Confirm":"Confirmer","Connect with opencode":"Connecter opencode","Connected: opencode now starts through {0}.":"Connect\u00e9 : opencode d\u00e9marre maintenant via {0}.","Connecting opencode":"Connexion d'opencode","Connection":"Connexion","Connection method":"M\u00e9thode de connexion","Continue":"Continuer","Continue WITHOUT the probe this session (IPs accepted untested)?":"Continuer SANS le test pour cette session (IP accept\u00e9es sans test) ?","Continue anyway?":"Continuer quand m\u00eame ?","Continue direct?":"Continuer en direct ?","Continue without WARP?":"Continuer sans WARP ?","Cooldown between attempts (s)":"D\u00e9lai entre les tentatives (s)","Copies auth.json to your Desktop, then clears the saved tokens.":"Copie auth.json sur votre Bureau, puis efface les jetons enregistr\u00e9s.","Copy the file path":"Copier le chemin du fichier","Creating shortcuts":"Cr\u00e9ation des raccourcis","Creating the opencode command":"Cr\u00e9ation de la commande opencode","Credentials inside a URL are not stored. Use a local file instead.":"Les identifiants dans une URL ne sont pas enregistr\u00e9s. Utilisez plut\u00f4t un fichier local.","Deep reset":"R\u00e9initialisation compl\u00e8te","Default connection method and run mode, the WARP proxy port and the warp-cli timings.":"M\u00e9thode de connexion et mode d'ex\u00e9cution par d\u00e9faut, port du proxy WARP et d\u00e9lais de warp-cli.","Default: {0}.":"Par d\u00e9faut : {0}.","Desktop":"Bureau","Desktop app":"Application de bureau","Desktop app location, release metadata URL and lookup timeouts.":"Emplacement de l'application de bureau, URL des m\u00e9tadonn\u00e9es de versions et d\u00e9lais de recherche.","Desktop app path":"Chemin de l'application de bureau","Direct, no proxy":"Direct, sans proxy","Do it now.":"Le faire maintenant.","Do that now?":"Le faire maintenant ?","Download and install it now?":"La t\u00e9l\u00e9charger et l'installer maintenant ?","Download the portable Tor bundle when nothing answers.":"T\u00e9l\u00e9charge Tor portable quand rien ne r\u00e9pond.","Egress":"Sortie","Egress used for opencode. ASK shows the picker at every start.":"Sortie utilis\u00e9e par opencode. ASK affiche le s\u00e9lecteur \u00e0 chaque d\u00e9marrage.","Enter a full URL (http, https, ftp or file).":"Saisissez une URL compl\u00e8te (http, https, ftp ou file).","Enter a whole number.":"Saisissez un nombre entier.","Enter cycles: {0}.":"Entr\u00e9e parcourt : {0}.","Enter toggles it.":"Entr\u00e9e l'active ou le d\u00e9sactive.","Every change is saved at once to {0}":"Chaque modification est enregistr\u00e9e aussit\u00f4t dans {0}","Exit":"Quitter","Exit IP":"IP de sortie","Extra rounds (60 s apart) before giving up.":"Tours suppl\u00e9mentaires (espac\u00e9s de 60 s) avant d'abandonner.","Folder":"Dossier","Font name":"Nom de la police","Font of the terminal text. Empty leaves the terminal as it is.":"Police du texte du terminal. Vide laisse le terminal tel quel.","Font size":"Taille de police","Free HTTP proxies from your list (any format) or the default one. Each is tested before use.":"Proxys HTTP gratuits de votre liste (n'importe quel format) ou de la liste par d\u00e9faut. Chacun est test\u00e9 avant usage.","Free or your own list":"Gratuite ou votre liste","Fresh start":"Nouveau d\u00e9part","Full path of OpenCode.exe. Empty = search automatically.":"Chemin complet d'OpenCode.exe. Vide = recherche automatique.","Get a new IP or proxy, then open OpenCode. Your chats and history stay untouched.":"Obtient une nouvelle IP ou un nouveau proxy, puis ouvre OpenCode. Vos conversations et votre historique restent intacts.","Gets a new IP / WARP registration / Tor circuit / proxy.":"Obtient une nouvelle IP / inscription WARP / circuit Tor / proxy.","Go ahead.":"Allez-y.","Go back. Nothing is changed.":"Revenir. Rien n'est modifi\u00e9.","Guided setup: choose WARP, Tor, a proxy list or direct, then get an \"opencode\" command and a shortcut that start with it. It is tested at the end.":"Assistant : choisissez WARP, Tor, une liste de proxys ou la connexion directe, puis obtenez une commande \u00ab opencode \u00bb et un raccourci qui d\u00e9marrent avec elle. Un test est fait \u00e0 la fin.","HTTP port of the built-in bridge opencode uses.":"Port HTTP du pont int\u00e9gr\u00e9 qu'utilise opencode.","Host used by the API check.":"Serveur utilis\u00e9 par la v\u00e9rification de l'API.","How do you want to run OpenCode?":"Comment voulez-vous lancer OpenCode ?","How many proxies to test before giving up.":"Combien de proxys tester avant d'abandonner.","How many times, and how fast, a new IP is requested when the free limit is hit.":"Combien de fois, et \u00e0 quel rythme, une nouvelle IP est demand\u00e9e quand la limite gratuite est atteinte.","IPs the probe may reject before giving up. 0 = no limit.":"IP que le test peut rejeter avant d'abandonner. 0 = sans limite.","Icons and borders":"Ic\u00f4nes et bordures","Install Tor automatically":"Installer Tor automatiquement","Keep the current connection and open OpenCode as it was.":"Garde la connexion actuelle et ouvre OpenCode tel qu'il \u00e9tait.","Keep the current font.":"Garder la police actuelle.","Kill opencode and clear the saved tokens, keeping your chats where they are.":"Ferme opencode et efface les jetons enregistr\u00e9s, en laissant vos conversations en place.","Kill opencode, move your chats to the Desktop, clear the saved tokens and open a fresh session.":"Ferme opencode, d\u00e9place vos conversations sur le Bureau, efface les jetons enregistr\u00e9s et ouvre une nouvelle session.","Language":"Langue","Language of the menus and descriptions. auto follows Windows. Logs and the support report stay in English.":"Langue des menus et des descriptions. auto suit Windows. Les journaux et le rapport de support restent en anglais.","Last check":"Derni\u00e8re v\u00e9rification","Launch OpenCode":"Lancer OpenCode","Launcher":"Launcher","Launcher self-update":"Mise \u00e0 jour automatique du launcher","Leave the setup without changing anything.":"Quitter l'assistant sans rien changer.","Leave the terminal font as it is. If the launcher changed it, the original font comes back.":"Laisse la police du terminal telle quelle. Si le launcher l'a chang\u00e9e, la police d'origine revient.","Local Tor with a built-in HTTP bridge. A portable Tor is installed automatically if missing.":"Tor local avec un pont HTTP int\u00e9gr\u00e9. Un Tor portable est install\u00e9 automatiquement s'il manque.","Local port of the WARP proxy.":"Port local du proxy WARP.","Logs":"Journaux","Main menu":"Menu principal","Method":"M\u00e9thode","Minimum list size (bytes)":"Taille minimale de la liste (octets)","Mode":"Mode","Model used by the IP probe.":"Mod\u00e8le utilis\u00e9 par le test d'IP.","Must be between {0} and {1}.":"Doit \u00eatre compris entre {0} et {1}.","New IP and resume in 5s":"Nouvelle IP et reprise dans 5 s","No":"Non","No .exe file exists at that path.":"Aucun fichier .exe n'existe \u00e0 ce chemin.","No answer in {0}s counts as No.":"Sans r\u00e9ponse en {0} s, c'est Non.","No change.":"Aucun changement.","No proxy: opencode uses your real connection and nothing is rotated.":"Sans proxy : opencode utilise votre vraie connexion et rien n'est renouvel\u00e9.","No, cancel":"Non, annuler","Non-limit probe failures before the hunt stops.":"\u00c9checs du test sans rapport avec la limite avant l'arr\u00eat de la recherche.","Not a URL, and no file exists at that path.":"Ce n'est pas une URL et aucun fichier n'existe \u00e0 ce chemin.","Not configured":"Non configur\u00e9","Nothing to ask for a direct connection.":"Rien \u00e0 demander pour une connexion directe.","Nothing was left half done that Uninstall cannot remove. Fix the problem and run setup again.":"Rien n'est rest\u00e9 \u00e0 moiti\u00e9 fait que D\u00e9sinstaller ne puisse retirer. Corrigez le probl\u00e8me et relancez l'assistant.","On PATH":"Dans le PATH","Only opencode uses it; the rest of the system stays direct.":"Seul opencode l'utilise ; le reste du syst\u00e8me reste en direct.","Open the Windows folder picker and choose where to work.":"Ouvre le s\u00e9lecteur de dossiers de Windows pour choisir o\u00f9 travailler.","Open the folder":"Ouvrir le dossier","Open the launcher menus: pick a folder and a connection method, then start the opencode CLI or the desktop app.":"Ouvre les menus du launcher : choisissez un dossier et une m\u00e9thode de connexion, puis d\u00e9marrez la CLI opencode ou l'application de bureau.","OpenCode app":"App OpenCode","PATH lookup timeout (s)":"D\u00e9lai de recherche dans le PATH (s)","Paths":"Chemins","Port {0} is already used by {1}.":"Le port {0} est d\u00e9j\u00e0 utilis\u00e9 par {1}.","Ports and install behavior of the portable Tor the launcher starts for you.":"Ports et installation du Tor portable que le launcher d\u00e9marre pour vous.","Press any key to continue...":"Appuyez sur une touche pour continuer...","Probe":"Test","Probe failures tolerated":"\u00c9checs de test tol\u00e9r\u00e9s","Probe model":"Mod\u00e8le de test","Proxies tried per pick":"Proxys essay\u00e9s par s\u00e9lection","Proxy":"Proxy","Proxy list":"Liste de proxys","Proxy list source":"Source de la liste de proxys","Proxy test timeout (s)":"D\u00e9lai du test d'un proxy (s)","Public HTTP proxies from a list (yours, in any format, or the free default). Each one is tested first and burned ones are skipped.":"Proxys HTTP publics d'une liste (la v\u00f4tre, n'importe quel format, ou la liste gratuite par d\u00e9faut). Chacun est test\u00e9 d'abord et les grill\u00e9s sont ignor\u00e9s.","Put every setting back to its default. Your connection setup (command, shortcuts) is not touched. Asks first.":"Remet tous les r\u00e9glages \u00e0 leur valeur par d\u00e9faut. Votre configuration de connexion (commande, raccourcis) n'est pas touch\u00e9e. Demande confirmation.","Put the full path on the clipboard.":"Met le chemin complet dans le presse-papiers.","Quotes and line breaks are not allowed.":"Les guillemets et les sauts de ligne ne sont pas autoris\u00e9s.","Range {0} to {1}.":"Plage de {0} \u00e0 {1}.","Reconfigure (run setup again)":"Reconfigurer (relancer l'assistant)","Release metadata URL":"URL des m\u00e9tadonn\u00e9es de versions","Removes only what setup added: the opencode command, the shortcuts and the PATH entry.":"Supprime uniquement ce que l'assistant a ajout\u00e9 : la commande opencode, les raccourcis et l'entr\u00e9e PATH.","Removes only what the setup added (command, shortcuts, PATH entry) and restores the settings it changed. Backups are kept. Asks first.":"Supprime uniquement ce que l'assistant a ajout\u00e9 (commande, raccourcis, entr\u00e9e PATH) et restaure les r\u00e9glages qu'il a modifi\u00e9s. Les sauvegardes sont conserv\u00e9es. Demande confirmation.","Removing shortcuts":"Suppression des raccourcis","Removing the opencode command":"Suppression de la commande opencode","Renew did not finish (code {0}).":"Le renouvellement ne s'est pas termin\u00e9 (code {0}).","Renew session":"Renouveler la session","Renew the session?":"Renouveler la session ?","Renewed. Open opencode again; you may need to log in once more.":"Renouvel\u00e9. Rouvrez opencode ; il faudra peut-\u00eatre vous reconnecter.","Renewing":"Renouvellement","Renewing the session":"Renouvellement de la session","Reopen the last folder":"Rouvrir le dernier dossier","Report ready. Personal data was removed; read it once before you share it.":"Rapport pr\u00eat. Les donn\u00e9es personnelles ont \u00e9t\u00e9 supprim\u00e9es ; relisez-le avant de le partager.","Repository":"D\u00e9p\u00f4t","Reset every setting to its default?":"Remettre tous les r\u00e9glages \u00e0 leur valeur par d\u00e9faut ?","Reset to default values":"R\u00e9tablir les valeurs par d\u00e9faut","Restores the settings setup changed. Your other settings and your opencode files are kept.":"Restaure les r\u00e9glages modifi\u00e9s par l'assistant. Vos autres r\u00e9glages et vos fichiers opencode sont conserv\u00e9s.","Restoring PATH":"Restauration du PATH","Restoring settings":"Restauration des r\u00e9glages","Resume message":"Message de reprise","Resume timeout (s)":"D\u00e9lai de reprise (s)","Return to the connection details.":"Revenir aux d\u00e9tails de la connexion.","Return to the main menu.":"Revenir au menu principal.","Return to the settings groups.":"Revenir aux groupes de r\u00e9glages.","Review":"R\u00e9capitulatif","Rotate the connection only (new WARP registration, Tor circuit or proxy) without opening OpenCode.":"Renouvelle seulement la connexion (nouvelle inscription WARP, circuit Tor ou proxy) sans ouvrir OpenCode.","Rotate when a fatal error appears while opencode runs.":"Renouvelle quand une erreur fatale appara\u00eet pendant l'ex\u00e9cution d'opencode.","Rotation":"Rotation","Rotation attempts":"Tentatives de rotation","Rotation rounds":"Tours de rotation","Run mode":"Mode d'ex\u00e9cution","Run opencode in this terminal. After a new IP the chat resumes by itself.":"Ex\u00e9cute opencode dans ce terminal. Apr\u00e8s une nouvelle IP, la conversation reprend toute seule.","Run the OpenCode desktop app ({0}). It is restarted after every new IP.":"Ex\u00e9cute l'application de bureau OpenCode ({0}). Elle red\u00e9marre apr\u00e8s chaque nouvelle IP.","Run the setup again to change the method or repair the opencode command.":"Relancez l'assistant pour changer de m\u00e9thode ou r\u00e9parer la commande opencode.","SOCKS port of the Tor the launcher starts.":"Port SOCKS du Tor que d\u00e9marre le launcher.","Save the settings, create the opencode command, the shortcuts and the PATH entry, then test the connection.":"Enregistre les r\u00e9glages, cr\u00e9e la commande opencode, les raccourcis et l'entr\u00e9e PATH, puis teste la connexion.","Saved: {0} = {1}":"Enregistr\u00e9 : {0} = {1}","Saving config.json":"Enregistrement de config.json","Seconds a single \"where\" lookup may take.":"Secondes maximum pour une recherche \u00ab where \u00bb.","Seconds a single proxy test may take.":"Secondes maximum pour le test d'un proxy.","Seconds a single warp-cli call may take.":"Secondes maximum pour un appel \u00e0 warp-cli.","Seconds before a silent resume counts as a dead IP.":"Secondes avant qu'une reprise sans r\u00e9ponse compte comme une IP morte.","Seconds to wait after (re)connecting WARP.":"Secondes d'attente apr\u00e8s la (re)connexion de WARP.","Seconds to wait for Tor to finish bootstrapping.":"Secondes d'attente pour que Tor finisse de d\u00e9marrer.","See what the setup installed (command, shortcuts, PATH) and run it again to change the method.":"Voir ce que l'assistant a install\u00e9 (commande, raccourcis, PATH) et le relancer pour changer de m\u00e9thode.","Send one cheap message through each candidate IP.":"Envoie un message peu co\u00fbteux par chaque IP candidate.","Sent automatically after a rotation.":"Envoy\u00e9 automatiquement apr\u00e8s une rotation.","Settings":"R\u00e9glages","Settings and setup":"R\u00e9glages et configuration","Setup 1/3 - connection method":"Configuration 1/3 - m\u00e9thode de connexion","Setup 2/3 - details":"Configuration 2/3 - d\u00e9tails","Setup 3/3 - run mode":"Configuration 3/3 - mode d'ex\u00e9cution","Setup stopped: {0}":"L'assistant s'est arr\u00eat\u00e9 : {0}","Shortcuts":"Raccourcis","Show the CLI or Desktop choice every time the launcher opens.":"Affiche le choix CLI ou Bureau \u00e0 chaque ouverture du launcher.","Show the report in Explorer so you can attach or paste it.":"Affiche le rapport dans l'Explorateur pour le joindre ou le coller.","Size used with the chosen font.":"Taille utilis\u00e9e avec la police choisie.","Support":"Support","Support report":"Rapport de support","Switch between the terminal and the desktop app.":"Basculer entre le terminal et l'application de bureau.","Switch to Tor and keep going?":"Passer \u00e0 Tor et continuer ?","System":"Syst\u00e8me","Takes effect at the {0}; a service already running keeps the old value until then.":"Prend effet \u00e0 : {0} ; un service d\u00e9j\u00e0 en cours garde l'ancienne valeur jusque-l\u00e0.","Terminal font":"Police du terminal","Test every new IP":"Tester chaque nouvelle IP","The OpenCode desktop app was not found. Choosing this offers to download and install it.":"L'application de bureau OpenCode est introuvable. La choisir propose de la t\u00e9l\u00e9charger et de l'installer.","The OpenCode desktop app; it is restarted after every new IP.":"L'application de bureau OpenCode ; elle red\u00e9marre apr\u00e8s chaque nouvelle IP.","The activity log (launcher.log) and the support report: what is recorded, how big it may grow, whether IPs are masked.":"Le journal d'activit\u00e9 (launcher.log) et le rapport de support : ce qui est enregistr\u00e9, sa taille maximale et le masquage des IP.","The cheap test message sent through every new IP before it is trusted.":"Le message de test peu co\u00fbteux envoy\u00e9 par chaque nouvelle IP avant de lui faire confiance.","The check failed (code {0}). Setup is saved; fix the cause and use Renew or Connect again.":"La v\u00e9rification a \u00e9chou\u00e9 (code {0}). La configuration est enregistr\u00e9e ; corrigez la cause et utilisez Renouveler ou Connecter \u00e0 nouveau.","The font applies to the whole terminal window, not only to this launcher.":"La police s'applique \u00e0 toute la fen\u00eatre du terminal, pas seulement \u00e0 ce launcher.","The proxy lives only in the opencode process; the rest of the system stays direct.":"Le proxy n'existe que dans le processus opencode ; le reste du syst\u00e8me reste en direct.","The resume auto-approves tool permissions.":"La reprise approuve automatiquement les autorisations des outils.","The shortcut and the opencode command use the CLI; this is the launcher menu default.":"Le raccourci et la commande opencode utilisent la CLI ; c'est la valeur par d\u00e9faut du menu du launcher.","The terminal interface. The opencode command and the shortcut always use it.":"L'interface terminal. La commande opencode et le raccourci l'utilisent toujours.","This launcher is not the one that set it up. Reconfigure to repair the command.":"Ce launcher n'est pas celui qui l'a configur\u00e9. Reconfigurez pour r\u00e9parer la commande.","Token reset":"R\u00e9initialisation des jetons","Tools and versions":"Outils et versions","Tor HTTP bridge port":"Port du pont HTTP de Tor","Tor SOCKS port":"Port SOCKS de Tor","Tor bootstrap wait (s)":"Attente du d\u00e9marrage de Tor (s)","Tor is downloaded once, run hidden and offered to opencode through a built-in HTTP bridge. Slower, but a new circuit is a new IP.":"Tor est t\u00e9l\u00e9charg\u00e9 une fois, lanc\u00e9 en cach\u00e9 et propos\u00e9 \u00e0 opencode via un pont HTTP int\u00e9gr\u00e9. Plus lent, mais un nouveau circuit donne une nouvelle IP.","Try again in a minute, or pick another connection method in Connect with opencode.":"R\u00e9essayez dans une minute, ou choisissez une autre m\u00e9thode de connexion dans Connecter opencode.","Try again?":"R\u00e9essayer ?","Try to download and install WARP now?":"Essayer de t\u00e9l\u00e9charger et d'installer WARP maintenant ?","Type \"opencode\" in a NEW terminal, or use the \"OpenCode Infinite (egress)\" shortcut.":"Tapez \u00ab opencode \u00bb dans un NOUVEAU terminal, ou utilisez le raccourci \u00ab OpenCode Infinite (egress) \u00bb.","Type < to go back. Enter keeps the value shown.":"Tapez < pour revenir. Entr\u00e9e garde la valeur affich\u00e9e.","Type a font name...":"Saisir le nom d'une police...","URL or local file, any format (plain, CSV, JSON, XML, HTML).":"URL ou fichier local, n'importe quel format (texte brut, CSV, JSON, XML, HTML).","Unattended resume":"Reprise sans surveillance","Uninstall":"D\u00e9sinstaller","Uninstall stopped: {0}":"La d\u00e9sinstallation s'est arr\u00eat\u00e9e : {0}","Uninstall the opencode connection?":"D\u00e9sinstaller la connexion opencode ?","Uninstalled. Backups stay in {0}":"D\u00e9sinstall\u00e9. Les sauvegardes restent dans {0}","Uninstalling":"D\u00e9sinstallation","Update now?":"Mettre \u00e0 jour maintenant ?","Updates":"Mises \u00e0 jour","Use 1 to 200 characters.":"Utilisez de 1 \u00e0 200 caract\u00e8res.","Use it when the free limit is hit or the login expired: closes opencode, saves and clears the saved tokens, and gets a new IP, WARP registration, Tor circuit or proxy.":"\u00c0 utiliser quand la limite gratuite est atteinte ou que la connexion a expir\u00e9 : ferme opencode, sauvegarde et efface les jetons enregistr\u00e9s, et obtient une nouvelle IP, inscription WARP, circuit Tor ou proxy.","Use on or off.":"Utilisez on ou off.","Use that proxy anyway?":"Utiliser ce proxy quand m\u00eame ?","Use this folder":"Utiliser ce dossier","Use up to 31 characters, without quotes or backslashes.":"Utilisez jusqu'\u00e0 31 caract\u00e8res, sans guillemets ni barres obliques inverses.","Use {0} for the terminal text. Monospaced fonts only look right.":"Utilise {0} pour le texte du terminal. Seules les polices \u00e0 chasse fixe s'affichent bien.","Version":"Version","View and change every launcher option: connection, proxies, Tor, rotation, themes. Saved instantly, no files to edit.":"Voir et modifier toutes les options du launcher : connexion, proxys, Tor, rotation, th\u00e8mes. Enregistr\u00e9 aussit\u00f4t, sans fichier \u00e0 \u00e9diter.","WARP proxy port":"Port du proxy WARP","WARP wait (s)":"Attente WARP (s)","Watch the log":"Surveiller le journal","Watcher":"Surveillance","Watching the opencode log and the automatic \"continue\" sent after a rotation.":"Surveillance du journal d'opencode et du \u00ab continue \u00bb automatique envoy\u00e9 apr\u00e8s une rotation.","Where proxies come from (URL or file, any format) and how each one is tested.":"D'o\u00f9 viennent les proxys (URL ou fichier, n'importe quel format) et comment chacun est test\u00e9.","Where versions and checksums are read from.":"D'o\u00f9 sont lues les versions et les sommes de contr\u00f4le.","Whether the launcher checks GitHub for a newer copy of itself at every start.":"Indique si le launcher cherche sur GitHub une copie plus r\u00e9cente de lui-m\u00eame \u00e0 chaque d\u00e9marrage.","Work in a different folder.":"Travailler dans un autre dossier.","Work in the folder the launcher was started from: {0}":"Travailler dans le dossier d'o\u00f9 le launcher a \u00e9t\u00e9 lanc\u00e9 : {0}","Work in {0}":"Travailler dans {0}","Writing the report":"\u00c9criture du rapport","Yes":"Oui","Yes, continue":"Oui, continuer","Your connection setup (shim, shortcuts) is not touched.":"Votre configuration de connexion (shim, raccourcis) n'est pas touch\u00e9e.","Your session needs renewing: {0}":"Votre session doit \u00eatre renouvel\u00e9e : {0}","asks first":"demande confirmation","auto":"auto","auto follows the terminal and NO_COLOR; off disables colors.":"auto suit le terminal et NO_COLOR ; off d\u00e9sactive les couleurs.","direct":"direct","emoji = modern terminals, unicode = classic console, ascii = anything.":"emoji = terminaux modernes, unicode = console classique, ascii = n'importe lequel.","free list":"liste gratuite","installed":"install\u00e9e","missing":"manquant","new IP":"nouvelle IP","next Tor start":"prochain d\u00e9marrage de Tor","next WARP connect":"prochaine connexion WARP","next launch":"prochain d\u00e9marrage","no other step is needed.":"aucune autre \u00e9tape n'est n\u00e9cessaire.","not installed":"non install\u00e9e","not verified":"non v\u00e9rifi\u00e9","off":"d\u00e9sactiv\u00e9","on":"activ\u00e9","same IP":"m\u00eame IP","terminal":"terminal","warp-cli timeout (s)":"D\u00e9lai de warp-cli (s)","yes":"oui","{0} changed":"{0} modifi\u00e9s","{0} of {1}":"{0} sur {1}","After opencode closes":"Apr\u00e8s la fermeture d'opencode","ask = R, M or Q: R gets a new IP and resumes the chat, M opens the menu, Q quits. quit = leave the launcher at once.":"ask = R, M ou Q : R prend une nouvelle IP et reprend le chat, M ouvre le menu, Q quitte. quit = quitter le lanceur imm\u00e9diatement."}
#>>>LANG it {" move   Enter select   Esc back   1-9 or letter jump":" sposta   Invio scegli   Esc indietro   1-9 o lettera per saltare","(Enter = keep \"{0}\")":"(Invio = mantieni \"{0}\")","(auto)":"(auto)","(nothing saved yet)":"(ancora nulla di salvato)","(terminal default)":"(predefinito del terminale)","* = changed from the default. Enter edits or toggles the selected value.":"* = diverso dal predefinito. Invio modifica o alterna il valore selezionato.","A downloaded list smaller than this is rejected. 0 = off.":"Un elenco scaricato pi\u00f9 piccolo di questo viene rifiutato. 0 = disattivato.","A port is a number from 1 to 65535.":"Una porta \u00e8 un numero da 1 a 65535.","A proxy must also reach the opencode API host.":"Un proxy deve raggiungere anche il server API di opencode.","API check URL":"URL di verifica dell'API","Accent colors of the interface.":"Colori di accento dell'interfaccia.","Adding the command to your PATH":"Aggiunta del comando al PATH","Adds: opencode command (shim), two shortcuts, one PATH entry. Backups are kept.":"Aggiunge: il comando opencode (shim), due collegamenti e una voce nel PATH. I backup vengono conservati.","Any installed font name, for example Cascadia Code.":"Qualsiasi nome di carattere installato, per esempio Cascadia Code.","Appearance":"Aspetto","Applies at the {0}.":"Si applica a: {0}.","Apply":"Applica","Apply setup":"Applica la configurazione","Ask every time":"Chiedi ogni volta","Attempts per round when the tunnel is not up.":"Tentativi per giro quando il tunnel non \u00e8 attivo.","Back":"Indietro","Backing up the current configuration":"Backup della configurazione attuale","Browse for a folder...":"Scegli una cartella...","Burned IPs allowed":"IP bruciati ammessi","Burned proxies before Tor offer":"Proxy bruciati prima di offrire Tor","Burned proxies in a row before PROXY mode offers Tor.":"Proxy bruciati di fila prima che la modalit\u00e0 PROXY offra Tor.","CLI terminal, Desktop app, or ask at every start.":"Terminale CLI, app desktop, oppure chiedi a ogni avvio.","Cancel":"Annulla","Cancel. Nothing is changed.":"Annulla. Non viene modificato nulla.","Change IP":"Cambia IP","Change an answer.":"Cambia una risposta.","Change any launcher setting: connection, proxies, Tor, rotation, themes, font. Applied right away.":"Modifica qualsiasi impostazione del launcher: connessione, proxy, Tor, rotazione, temi, carattere. Applicata subito.","Check GitHub for a newer launcher at every start.":"Cerca su GitHub un launcher pi\u00f9 recente a ogni avvio.","Check the API host":"Verifica il server API","Checking that it works":"Verifica del funzionamento","Checking the connection":"Verifica della connessione","Choose \"Renew session\" below. It gets a new IP and clears the saved login;":"Scegli \u00abRinnova sessione\u00bb qui sotto. Ottiene un nuovo IP e cancella l'accesso salvato;","Choose a folder to work in":"Scegli una cartella di lavoro","Choose one of: {0}.":"Scegli uno tra: {0}.","Choose the connection for OpenCode":"Scegli la connessione per OpenCode","Close the launcher.":"Chiudi il launcher.","Closes every running opencode process.":"Chiude tutti i processi opencode in esecuzione.","Cloudflare WARP in local proxy mode. Every rotation asks for a new registration, which gives a new exit IP. Needs the WARP client (offered if missing).":"Cloudflare WARP in modalit\u00e0 proxy locale. Ogni rotazione chiede una nuova registrazione, che d\u00e0 un nuovo IP di uscita. Richiede il client WARP (offerto se manca).","Cloudflare WARP in proxy mode. A new registration gives a new exit IP. Rotation supported.":"Cloudflare WARP in modalit\u00e0 proxy. Una nuova registrazione d\u00e0 un nuovo IP di uscita. Rotazione supportata.","Cloudflare throttles rapid registrations.":"Cloudflare limita le registrazioni ravvicinate.","Collect system info, versions, settings and the recent log into one text file you can send for help. Passwords, tokens, your user name and (by default) IPs are removed first.":"Raccoglie info di sistema, versioni, impostazioni e il registro recente in un file di testo da inviare per chiedere aiuto. Prima vengono rimossi password, token, nome utente e (per impostazione predefinita) gli IP.","Color theme":"Tema colori","Color theme, colors on or off, icon and border style, and the terminal font. Applied immediately.":"Tema colori, colori attivi o no, stile di icone e bordi, lingua e carattere del terminale. Applicato subito.","Colors":"Colori","Command":"Comando","Configured - {0}":"Configurato - {0}","Confirm":"Conferma","Connect with opencode":"Collega opencode","Connected: opencode now starts through {0}.":"Connesso: opencode ora si avvia tramite {0}.","Connecting opencode":"Collegamento di opencode","Connection":"Connessione","Connection method":"Metodo di connessione","Continue":"Continua","Continue WITHOUT the probe this session (IPs accepted untested)?":"Continuare SENZA il test in questa sessione (IP accettati senza prova)?","Continue anyway?":"Continuare comunque?","Continue direct?":"Continuare in diretta?","Continue without WARP?":"Continuare senza WARP?","Cooldown between attempts (s)":"Attesa tra i tentativi (s)","Copies auth.json to your Desktop, then clears the saved tokens.":"Copia auth.json sul Desktop, poi cancella i token salvati.","Copy the file path":"Copia il percorso del file","Creating shortcuts":"Creazione dei collegamenti","Creating the opencode command":"Creazione del comando opencode","Credentials inside a URL are not stored. Use a local file instead.":"Le credenziali dentro un URL non vengono salvate. Usa invece un file locale.","Deep reset":"Ripristino completo","Default connection method and run mode, the WARP proxy port and the warp-cli timings.":"Metodo di connessione e modalit\u00e0 di esecuzione predefiniti, porta del proxy WARP e tempi di warp-cli.","Default: {0}.":"Predefinito: {0}.","Desktop":"Desktop","Desktop app":"App desktop","Desktop app location, release metadata URL and lookup timeouts.":"Posizione dell'app desktop, URL dei metadati delle versioni e tempi di ricerca.","Desktop app path":"Percorso dell'app desktop","Direct, no proxy":"Diretta, senza proxy","Do it now.":"Fallo ora.","Do that now?":"Farlo ora?","Download and install it now?":"Scaricarla e installarla ora?","Download the portable Tor bundle when nothing answers.":"Scarica Tor portatile quando nulla risponde.","Egress":"Uscita","Egress used for opencode. ASK shows the picker at every start.":"Uscita usata da opencode. ASK mostra il selettore a ogni avvio.","Enter a full URL (http, https, ftp or file).":"Inserisci un URL completo (http, https, ftp o file).","Enter a whole number.":"Inserisci un numero intero.","Enter cycles: {0}.":"Invio scorre: {0}.","Enter toggles it.":"Invio lo attiva o disattiva.","Every change is saved at once to {0}":"Ogni modifica viene salvata subito in {0}","Exit":"Esci","Exit IP":"IP di uscita","Extra rounds (60 s apart) before giving up.":"Giri extra (a 60 s di distanza) prima di rinunciare.","Folder":"Cartella","Font name":"Nome del carattere","Font of the terminal text. Empty leaves the terminal as it is.":"Carattere del testo del terminale. Vuoto lascia il terminale com'\u00e8.","Font size":"Dimensione del carattere","Free HTTP proxies from your list (any format) or the default one. Each is tested before use.":"Proxy HTTP gratuiti dal tuo elenco (qualsiasi formato) o da quello predefinito. Ognuno viene provato prima dell'uso.","Free or your own list":"Gratuita o il tuo elenco","Fresh start":"Nuovo avvio","Full path of OpenCode.exe. Empty = search automatically.":"Percorso completo di OpenCode.exe. Vuoto = cerca automaticamente.","Get a new IP or proxy, then open OpenCode. Your chats and history stay untouched.":"Ottiene un nuovo IP o proxy e poi apre OpenCode. Chat e cronologia restano intatte.","Gets a new IP / WARP registration / Tor circuit / proxy.":"Ottiene un nuovo IP / registrazione WARP / circuito Tor / proxy.","Go ahead.":"Procedi.","Go back. Nothing is changed.":"Torna indietro. Non viene modificato nulla.","Guided setup: choose WARP, Tor, a proxy list or direct, then get an \"opencode\" command and a shortcut that start with it. It is tested at the end.":"Procedura guidata: scegli WARP, Tor, un elenco di proxy o la connessione diretta e ottieni un comando \u00abopencode\u00bb e un collegamento che partono con essa. Alla fine viene provata.","HTTP port of the built-in bridge opencode uses.":"Porta HTTP del ponte integrato usato da opencode.","Host used by the API check.":"Server usato dalla verifica dell'API.","How do you want to run OpenCode?":"Come vuoi eseguire OpenCode?","How many proxies to test before giving up.":"Quanti proxy provare prima di rinunciare.","How many times, and how fast, a new IP is requested when the free limit is hit.":"Quante volte e con che ritmo si chiede un nuovo IP quando si raggiunge il limite gratuito.","IPs the probe may reject before giving up. 0 = no limit.":"IP che il test pu\u00f2 rifiutare prima di rinunciare. 0 = nessun limite.","Icons and borders":"Icone e bordi","Install Tor automatically":"Installa Tor automaticamente","Keep the current connection and open OpenCode as it was.":"Mantiene la connessione attuale e apre OpenCode com'era.","Keep the current font.":"Mantieni il carattere attuale.","Kill opencode and clear the saved tokens, keeping your chats where they are.":"Chiude opencode e cancella i token salvati, lasciando le chat dove sono.","Kill opencode, move your chats to the Desktop, clear the saved tokens and open a fresh session.":"Chiude opencode, sposta le chat sul Desktop, cancella i token salvati e apre una sessione nuova.","Language":"Lingua","Language of the menus and descriptions. auto follows Windows. Logs and the support report stay in English.":"Lingua dei menu e delle descrizioni. auto segue Windows. I registri e il rapporto di supporto restano in inglese.","Last check":"Ultima verifica","Launch OpenCode":"Avvia OpenCode","Launcher":"Launcher","Launcher self-update":"Aggiornamento automatico del launcher","Leave the setup without changing anything.":"Esci dalla procedura senza cambiare nulla.","Leave the terminal font as it is. If the launcher changed it, the original font comes back.":"Lascia il carattere del terminale com'\u00e8. Se il launcher lo ha cambiato, torna l'originale.","Local Tor with a built-in HTTP bridge. A portable Tor is installed automatically if missing.":"Tor locale con un ponte HTTP integrato. Se manca, viene installato automaticamente un Tor portatile.","Local port of the WARP proxy.":"Porta locale del proxy WARP.","Logs":"Registri","Main menu":"Menu principale","Method":"Metodo","Minimum list size (bytes)":"Dimensione minima dell'elenco (byte)","Mode":"Modalit\u00e0","Model used by the IP probe.":"Modello usato dal test dell'IP.","Must be between {0} and {1}.":"Deve essere compreso tra {0} e {1}.","New IP and resume in 5s":"Nuovo IP e ripresa tra 5 s","No":"No","No .exe file exists at that path.":"Nessun file .exe esiste in quel percorso.","No answer in {0}s counts as No.":"Nessuna risposta in {0} s vale come No.","No change.":"Nessuna modifica.","No proxy: opencode uses your real connection and nothing is rotated.":"Nessun proxy: opencode usa la tua connessione reale e nulla viene ruotato.","No, cancel":"No, annulla","Non-limit probe failures before the hunt stops.":"Errori del test non legati al limite prima che la ricerca si fermi.","Not a URL, and no file exists at that path.":"Non \u00e8 un URL e in quel percorso non esiste alcun file.","Not configured":"Non configurato","Nothing to ask for a direct connection.":"Non c'\u00e8 nulla da chiedere per una connessione diretta.","Nothing was left half done that Uninstall cannot remove. Fix the problem and run setup again.":"Non \u00e8 rimasto nulla a met\u00e0 che Disinstalla non possa rimuovere. Risolvi il problema e rilancia la procedura.","On PATH":"Nel PATH","Only opencode uses it; the rest of the system stays direct.":"Solo opencode la usa; il resto del sistema resta diretto.","Open the Windows folder picker and choose where to work.":"Apre il selettore cartelle di Windows per scegliere dove lavorare.","Open the folder":"Apri la cartella","Open the launcher menus: pick a folder and a connection method, then start the opencode CLI or the desktop app.":"Apre i menu del launcher: scegli cartella e metodo di connessione, poi avvia la CLI di opencode o l'app desktop.","OpenCode app":"App OpenCode","PATH lookup timeout (s)":"Tempo massimo di ricerca nel PATH (s)","Paths":"Percorsi","Port {0} is already used by {1}.":"La porta {0} \u00e8 gi\u00e0 usata da {1}.","Ports and install behavior of the portable Tor the launcher starts for you.":"Porte e installazione del Tor portatile che il launcher avvia per te.","Press any key to continue...":"Premi un tasto per continuare...","Probe":"Test","Probe failures tolerated":"Errori di test tollerati","Probe model":"Modello di test","Proxies tried per pick":"Proxy provati per scelta","Proxy":"Proxy","Proxy list":"Elenco proxy","Proxy list source":"Origine dell'elenco proxy","Proxy test timeout (s)":"Tempo massimo del test di un proxy (s)","Public HTTP proxies from a list (yours, in any format, or the free default). Each one is tested first and burned ones are skipped.":"Proxy HTTP pubblici da un elenco (il tuo, in qualsiasi formato, o quello gratuito predefinito). Ognuno viene provato prima e quelli bruciati vengono saltati.","Put every setting back to its default. Your connection setup (command, shortcuts) is not touched. Asks first.":"Riporta tutte le impostazioni ai valori predefiniti. La configurazione della connessione (comando, collegamenti) non viene toccata. Chiede conferma.","Put the full path on the clipboard.":"Mette il percorso completo negli appunti.","Quotes and line breaks are not allowed.":"Virgolette e a capo non sono ammessi.","Range {0} to {1}.":"Intervallo da {0} a {1}.","Reconfigure (run setup again)":"Riconfigura (rilancia la procedura)","Release metadata URL":"URL dei metadati delle versioni","Removes only what setup added: the opencode command, the shortcuts and the PATH entry.":"Rimuove solo ci\u00f2 che la procedura ha aggiunto: il comando opencode, i collegamenti e la voce nel PATH.","Removes only what the setup added (command, shortcuts, PATH entry) and restores the settings it changed. Backups are kept. Asks first.":"Rimuove solo ci\u00f2 che la procedura ha aggiunto (comando, collegamenti, voce nel PATH) e ripristina le impostazioni modificate. I backup vengono conservati. Chiede conferma.","Removing shortcuts":"Rimozione dei collegamenti","Removing the opencode command":"Rimozione del comando opencode","Renew did not finish (code {0}).":"Il rinnovo non \u00e8 terminato (codice {0}).","Renew session":"Rinnova sessione","Renew the session?":"Rinnovare la sessione?","Renewed. Open opencode again; you may need to log in once more.":"Rinnovata. Riapri opencode; potrebbe servire accedere di nuovo.","Renewing":"Rinnovo","Renewing the session":"Rinnovo della sessione","Reopen the last folder":"Riapri l'ultima cartella","Report ready. Personal data was removed; read it once before you share it.":"Rapporto pronto. I dati personali sono stati rimossi; leggilo una volta prima di condividerlo.","Repository":"Repository","Reset every setting to its default?":"Riportare tutte le impostazioni ai valori predefiniti?","Reset to default values":"Ripristina i valori predefiniti","Restores the settings setup changed. Your other settings and your opencode files are kept.":"Ripristina le impostazioni modificate dalla procedura. Le altre impostazioni e i file di opencode restano.","Restoring PATH":"Ripristino del PATH","Restoring settings":"Ripristino delle impostazioni","Resume message":"Messaggio di ripresa","Resume timeout (s)":"Tempo massimo di ripresa (s)","Return to the connection details.":"Torna ai dettagli della connessione.","Return to the main menu.":"Torna al menu principale.","Return to the settings groups.":"Torna ai gruppi di impostazioni.","Review":"Riepilogo","Rotate the connection only (new WARP registration, Tor circuit or proxy) without opening OpenCode.":"Ruota solo la connessione (nuova registrazione WARP, circuito Tor o proxy) senza aprire OpenCode.","Rotate when a fatal error appears while opencode runs.":"Ruota quando compare un errore grave mentre opencode \u00e8 in esecuzione.","Rotation":"Rotazione","Rotation attempts":"Tentativi di rotazione","Rotation rounds":"Giri di rotazione","Run mode":"Modalit\u00e0 di esecuzione","Run opencode in this terminal. After a new IP the chat resumes by itself.":"Esegue opencode in questo terminale. Dopo un nuovo IP la chat riprende da sola.","Run the OpenCode desktop app ({0}). It is restarted after every new IP.":"Esegue l'app desktop di OpenCode ({0}). Viene riavviata dopo ogni nuovo IP.","Run the setup again to change the method or repair the opencode command.":"Rilancia la procedura per cambiare metodo o riparare il comando opencode.","SOCKS port of the Tor the launcher starts.":"Porta SOCKS del Tor avviato dal launcher.","Save the settings, create the opencode command, the shortcuts and the PATH entry, then test the connection.":"Salva le impostazioni, crea il comando opencode, i collegamenti e la voce nel PATH, poi prova la connessione.","Saved: {0} = {1}":"Salvato: {0} = {1}","Saving config.json":"Salvataggio di config.json","Seconds a single \"where\" lookup may take.":"Secondi che pu\u00f2 durare una ricerca con \"where\".","Seconds a single proxy test may take.":"Secondi che pu\u00f2 durare il test di un proxy.","Seconds a single warp-cli call may take.":"Secondi che pu\u00f2 durare una chiamata a warp-cli.","Seconds before a silent resume counts as a dead IP.":"Secondi prima che una ripresa senza risposta valga come IP morto.","Seconds to wait after (re)connecting WARP.":"Secondi di attesa dopo la (ri)connessione di WARP.","Seconds to wait for Tor to finish bootstrapping.":"Secondi di attesa perch\u00e9 Tor finisca di avviarsi.","See what the setup installed (command, shortcuts, PATH) and run it again to change the method.":"Vedi cosa ha installato la procedura (comando, collegamenti, PATH) e rilanciala per cambiare metodo.","Send one cheap message through each candidate IP.":"Invia un messaggio economico da ogni IP candidato.","Sent automatically after a rotation.":"Inviato automaticamente dopo una rotazione.","Settings":"Impostazioni","Settings and setup":"Impostazioni e configurazione","Setup 1/3 - connection method":"Configurazione 1/3 - metodo di connessione","Setup 2/3 - details":"Configurazione 2/3 - dettagli","Setup 3/3 - run mode":"Configurazione 3/3 - modalit\u00e0 di esecuzione","Setup stopped: {0}":"La procedura si \u00e8 fermata: {0}","Shortcuts":"Collegamenti","Show the CLI or Desktop choice every time the launcher opens.":"Mostra la scelta CLI o Desktop a ogni apertura del launcher.","Show the report in Explorer so you can attach or paste it.":"Mostra il rapporto in Esplora risorse per allegarlo o incollarlo.","Size used with the chosen font.":"Dimensione usata con il carattere scelto.","Support":"Supporto","Support report":"Rapporto di supporto","Switch between the terminal and the desktop app.":"Passa tra il terminale e l'app desktop.","Switch to Tor and keep going?":"Passare a Tor e continuare?","System":"Sistema","Takes effect at the {0}; a service already running keeps the old value until then.":"Ha effetto a: {0}; un servizio gi\u00e0 in esecuzione mantiene il valore precedente fino ad allora.","Terminal font":"Carattere del terminale","Test every new IP":"Prova ogni nuovo IP","The OpenCode desktop app was not found. Choosing this offers to download and install it.":"L'app desktop di OpenCode non \u00e8 stata trovata. Scegliendola si offre di scaricarla e installarla.","The OpenCode desktop app; it is restarted after every new IP.":"L'app desktop di OpenCode; viene riavviata dopo ogni nuovo IP.","The activity log (launcher.log) and the support report: what is recorded, how big it may grow, whether IPs are masked.":"Il registro attivit\u00e0 (launcher.log) e il rapporto di supporto: cosa viene registrato, quanto pu\u00f2 crescere e se gli IP vengono nascosti.","The cheap test message sent through every new IP before it is trusted.":"Il messaggio di prova economico inviato da ogni nuovo IP prima di fidarsene.","The check failed (code {0}). Setup is saved; fix the cause and use Renew or Connect again.":"La verifica \u00e8 fallita (codice {0}). La configurazione \u00e8 salvata; risolvi la causa e usa di nuovo Rinnova o Collega.","The font applies to the whole terminal window, not only to this launcher.":"Il carattere vale per tutta la finestra del terminale, non solo per questo launcher.","The proxy lives only in the opencode process; the rest of the system stays direct.":"Il proxy esiste solo nel processo opencode; il resto del sistema resta diretto.","The resume auto-approves tool permissions.":"La ripresa approva da sola i permessi degli strumenti.","The shortcut and the opencode command use the CLI; this is the launcher menu default.":"Il collegamento e il comando opencode usano la CLI; questo \u00e8 il predefinito del menu del launcher.","The terminal interface. The opencode command and the shortcut always use it.":"L'interfaccia da terminale. Il comando opencode e il collegamento la usano sempre.","This launcher is not the one that set it up. Reconfigure to repair the command.":"Questo launcher non \u00e8 quello che l'ha configurato. Riconfigura per riparare il comando.","Token reset":"Ripristino dei token","Tools and versions":"Strumenti e versioni","Tor HTTP bridge port":"Porta del ponte HTTP di Tor","Tor SOCKS port":"Porta SOCKS di Tor","Tor bootstrap wait (s)":"Attesa avvio di Tor (s)","Tor is downloaded once, run hidden and offered to opencode through a built-in HTTP bridge. Slower, but a new circuit is a new IP.":"Tor viene scaricato una volta, eseguito nascosto e offerto a opencode tramite un ponte HTTP integrato. Pi\u00f9 lento, ma un nuovo circuito \u00e8 un nuovo IP.","Try again in a minute, or pick another connection method in Connect with opencode.":"Riprova tra un minuto, oppure scegli un altro metodo di connessione in Collega opencode.","Try again?":"Riprovare?","Try to download and install WARP now?":"Provare a scaricare e installare WARP ora?","Type \"opencode\" in a NEW terminal, or use the \"OpenCode Infinite (egress)\" shortcut.":"Scrivi \u00abopencode\u00bb in un terminale NUOVO, oppure usa il collegamento \u00abOpenCode Infinite (egress)\u00bb.","Type < to go back. Enter keeps the value shown.":"Scrivi < per tornare indietro. Invio mantiene il valore mostrato.","Type a font name...":"Scrivi il nome di un carattere...","URL or local file, any format (plain, CSV, JSON, XML, HTML).":"URL o file locale, in qualsiasi formato (testo semplice, CSV, JSON, XML, HTML).","Unattended resume":"Ripresa non presidiata","Uninstall":"Disinstalla","Uninstall stopped: {0}":"La disinstallazione si \u00e8 fermata: {0}","Uninstall the opencode connection?":"Disinstallare la connessione di opencode?","Uninstalled. Backups stay in {0}":"Disinstallato. I backup restano in {0}","Uninstalling":"Disinstallazione","Update now?":"Aggiornare ora?","Updates":"Aggiornamenti","Use 1 to 200 characters.":"Usa da 1 a 200 caratteri.","Use it when the free limit is hit or the login expired: closes opencode, saves and clears the saved tokens, and gets a new IP, WARP registration, Tor circuit or proxy.":"Usalo quando si raggiunge il limite gratuito o l'accesso \u00e8 scaduto: chiude opencode, salva e cancella i token salvati e ottiene un nuovo IP, registrazione WARP, circuito Tor o proxy.","Use on or off.":"Usa on oppure off.","Use that proxy anyway?":"Usare comunque quel proxy?","Use this folder":"Usa questa cartella","Use up to 31 characters, without quotes or backslashes.":"Usa fino a 31 caratteri, senza virgolette n\u00e9 barre rovesciate.","Use {0} for the terminal text. Monospaced fonts only look right.":"Usa {0} per il testo del terminale. Solo i caratteri a spaziatura fissa si vedono bene.","Version":"Versione","View and change every launcher option: connection, proxies, Tor, rotation, themes. Saved instantly, no files to edit.":"Vedi e modifica ogni opzione del launcher: connessione, proxy, Tor, rotazione, temi. Salvato subito, nessun file da modificare.","WARP proxy port":"Porta del proxy WARP","WARP wait (s)":"Attesa WARP (s)","Watch the log":"Sorveglia il registro","Watcher":"Sorveglianza","Watching the opencode log and the automatic \"continue\" sent after a rotation.":"Sorveglianza del registro di opencode e del \u00abcontinue\u00bb automatico inviato dopo una rotazione.","Where proxies come from (URL or file, any format) and how each one is tested.":"Da dove arrivano i proxy (URL o file, qualsiasi formato) e come ciascuno viene provato.","Where versions and checksums are read from.":"Da dove si leggono versioni e checksum.","Whether the launcher checks GitHub for a newer copy of itself at every start.":"Se il launcher cerca su GitHub una copia pi\u00f9 recente di s\u00e9 a ogni avvio.","Work in a different folder.":"Lavora in un'altra cartella.","Work in the folder the launcher was started from: {0}":"Lavora nella cartella da cui \u00e8 stato avviato il launcher: {0}","Work in {0}":"Lavora in {0}","Writing the report":"Scrittura del rapporto","Yes":"S\u00ec","Yes, continue":"S\u00ec, continua","Your connection setup (shim, shortcuts) is not touched.":"La configurazione della connessione (shim, collegamenti) non viene toccata.","Your session needs renewing: {0}":"La sessione va rinnovata: {0}","asks first":"chiede conferma","auto":"auto","auto follows the terminal and NO_COLOR; off disables colors.":"auto segue il terminale e NO_COLOR; off disattiva i colori.","direct":"diretta","emoji = modern terminals, unicode = classic console, ascii = anything.":"emoji = terminali moderni, unicode = console classica, ascii = qualsiasi.","free list":"elenco gratuito","installed":"installata","missing":"mancante","new IP":"nuovo IP","next Tor start":"prossimo avvio di Tor","next WARP connect":"prossima connessione WARP","next launch":"prossimo avvio","no other step is needed.":"non serve nessun altro passaggio.","not installed":"non installata","not verified":"non verificato","off":"disattivato","on":"attivato","same IP":"stesso IP","terminal":"terminale","warp-cli timeout (s)":"Tempo massimo di warp-cli (s)","yes":"s\u00ec","{0} changed":"{0} modificati","{0} of {1}":"{0} di {1}","After opencode closes":"Dopo la chiusura di opencode","ask = R, M or Q: R gets a new IP and resumes the chat, M opens the menu, Q quits. quit = leave the launcher at once.":"ask = R, M o Q: R richiede un nuovo IP e riprende la chat, M apre il menu, Q esce. quit = chiude subito il launcher."}
#>>>LANG pt {" move   Enter select   Esc back   1-9 or letter jump":" mover   Enter escolher   Esc voltar   1-9 ou letra para saltar","(Enter = keep \"{0}\")":"(Enter = manter \"{0}\")","(auto)":"(auto)","(nothing saved yet)":"(nada guardado ainda)","(terminal default)":"(predefinida do terminal)","* = changed from the default. Enter edits or toggles the selected value.":"* = diferente do valor predefinido. Enter edita ou alterna o valor selecionado.","A downloaded list smaller than this is rejected. 0 = off.":"Uma lista descarregada menor do que isto \u00e9 rejeitada. 0 = desativado.","A port is a number from 1 to 65535.":"Uma porta \u00e9 um n\u00famero de 1 a 65535.","A proxy must also reach the opencode API host.":"Um proxy tamb\u00e9m tem de alcan\u00e7ar o servidor da API do opencode.","API check URL":"URL de verifica\u00e7\u00e3o da API","Accent colors of the interface.":"Cores de destaque da interface.","Adding the command to your PATH":"A adicionar o comando ao PATH","Adds: opencode command (shim), two shortcuts, one PATH entry. Backups are kept.":"Adiciona: o comando opencode (shim), dois atalhos e uma entrada no PATH. As c\u00f3pias de seguran\u00e7a s\u00e3o mantidas.","Any installed font name, for example Cascadia Code.":"Qualquer nome de tipo de letra instalado, por exemplo Cascadia Code.","Appearance":"Apar\u00eancia","Applies at the {0}.":"Aplica-se em: {0}.","Apply":"Aplicar","Apply setup":"Aplicar configura\u00e7\u00e3o","Ask every time":"Perguntar sempre","Attempts per round when the tunnel is not up.":"Tentativas por ronda quando o t\u00fanel n\u00e3o est\u00e1 ativo.","Back":"Voltar","Backing up the current configuration":"A guardar c\u00f3pia da configura\u00e7\u00e3o atual","Browse for a folder...":"Procurar uma pasta...","Burned IPs allowed":"IPs queimados permitidos","Burned proxies before Tor offer":"Proxies queimados antes de oferecer o Tor","Burned proxies in a row before PROXY mode offers Tor.":"Proxies queimados seguidos antes de o modo PROXY oferecer o Tor.","CLI terminal, Desktop app, or ask at every start.":"Terminal CLI, aplica\u00e7\u00e3o de ambiente de trabalho, ou perguntar em cada arranque.","Cancel":"Cancelar","Cancel. Nothing is changed.":"Cancelar. Nada \u00e9 alterado.","Change IP":"Mudar de IP","Change an answer.":"Alterar uma resposta.","Change any launcher setting: connection, proxies, Tor, rotation, themes, font. Applied right away.":"Altera qualquer defini\u00e7\u00e3o do launcher: liga\u00e7\u00e3o, proxies, Tor, rota\u00e7\u00e3o, temas, tipo de letra. Aplica-se de imediato.","Check GitHub for a newer launcher at every start.":"Procura no GitHub um launcher mais recente em cada arranque.","Check the API host":"Verificar o servidor da API","Checking that it works":"A verificar se funciona","Checking the connection":"A verificar a liga\u00e7\u00e3o","Choose \"Renew session\" below. It gets a new IP and clears the saved login;":"Escolhe \"Renovar sess\u00e3o\" abaixo. Obt\u00e9m um IP novo e apaga o in\u00edcio de sess\u00e3o guardado;","Choose a folder to work in":"Escolhe uma pasta de trabalho","Choose one of: {0}.":"Escolhe um de: {0}.","Choose the connection for OpenCode":"Escolhe a liga\u00e7\u00e3o para o OpenCode","Close the launcher.":"Fechar o launcher.","Closes every running opencode process.":"Fecha todos os processos do opencode em execu\u00e7\u00e3o.","Cloudflare WARP in local proxy mode. Every rotation asks for a new registration, which gives a new exit IP. Needs the WARP client (offered if missing).":"Cloudflare WARP em modo de proxy local. Cada rota\u00e7\u00e3o pede um novo registo, que d\u00e1 um novo IP de sa\u00edda. Precisa do cliente WARP (oferecido se faltar).","Cloudflare WARP in proxy mode. A new registration gives a new exit IP. Rotation supported.":"Cloudflare WARP em modo de proxy. Um novo registo d\u00e1 um novo IP de sa\u00edda. Suporta rota\u00e7\u00e3o.","Cloudflare throttles rapid registrations.":"A Cloudflare limita registos seguidos.","Collect system info, versions, settings and the recent log into one text file you can send for help. Passwords, tokens, your user name and (by default) IPs are removed first.":"Re\u00fane informa\u00e7\u00e3o do sistema, vers\u00f5es, defini\u00e7\u00f5es e o registo recente num ficheiro de texto que podes enviar para pedir ajuda. Antes s\u00e3o removidos palavras-passe, tokens, o teu nome de utilizador e (por defeito) os IPs.","Color theme":"Tema de cores","Color theme, colors on or off, icon and border style, and the terminal font. Applied immediately.":"Tema de cores, cores ligadas ou n\u00e3o, estilo de \u00edcones e bordas, idioma e tipo de letra do terminal. Aplica-se de imediato.","Colors":"Cores","Command":"Comando","Configured - {0}":"Configurado - {0}","Confirm":"Confirmar","Connect with opencode":"Ligar ao opencode","Connected: opencode now starts through {0}.":"Ligado: o opencode agora arranca atrav\u00e9s de {0}.","Connecting opencode":"A ligar o opencode","Connection":"Liga\u00e7\u00e3o","Connection method":"M\u00e9todo de liga\u00e7\u00e3o","Continue":"Continuar","Continue WITHOUT the probe this session (IPs accepted untested)?":"Continuar SEM o teste nesta sess\u00e3o (IPs aceites sem testar)?","Continue anyway?":"Continuar mesmo assim?","Continue direct?":"Continuar em direto?","Continue without WARP?":"Continuar sem WARP?","Cooldown between attempts (s)":"Espera entre tentativas (s)","Copies auth.json to your Desktop, then clears the saved tokens.":"Copia o auth.json para o teu Ambiente de trabalho e depois apaga os tokens guardados.","Copy the file path":"Copiar o caminho do ficheiro","Creating shortcuts":"A criar atalhos","Creating the opencode command":"A criar o comando opencode","Credentials inside a URL are not stored. Use a local file instead.":"As credenciais dentro de um URL n\u00e3o s\u00e3o guardadas. Usa antes um ficheiro local.","Deep reset":"Rein\u00edcio total","Default connection method and run mode, the WARP proxy port and the warp-cli timings.":"M\u00e9todo de liga\u00e7\u00e3o e modo de execu\u00e7\u00e3o predefinidos, porta do proxy WARP e tempos do warp-cli.","Default: {0}.":"Predefini\u00e7\u00e3o: {0}.","Desktop":"Ambiente de trabalho","Desktop app":"Aplica\u00e7\u00e3o de ambiente de trabalho","Desktop app location, release metadata URL and lookup timeouts.":"Localiza\u00e7\u00e3o da aplica\u00e7\u00e3o de ambiente de trabalho, URL dos metadados de vers\u00f5es e tempos de procura.","Desktop app path":"Caminho da aplica\u00e7\u00e3o de ambiente de trabalho","Direct, no proxy":"Direto, sem proxy","Do it now.":"Fazer agora.","Do that now?":"Fazer isso agora?","Download and install it now?":"Descarregar e instalar agora?","Download the portable Tor bundle when nothing answers.":"Descarrega o Tor port\u00e1til quando nada responde.","Egress":"Sa\u00edda","Egress used for opencode. ASK shows the picker at every start.":"Sa\u00edda usada pelo opencode. ASK mostra o seletor em cada arranque.","Enter a full URL (http, https, ftp or file).":"Escreve um URL completo (http, https, ftp ou file).","Enter a whole number.":"Escreve um n\u00famero inteiro.","Enter cycles: {0}.":"Enter percorre: {0}.","Enter toggles it.":"Enter ativa ou desativa.","Every change is saved at once to {0}":"Cada altera\u00e7\u00e3o \u00e9 guardada de imediato em {0}","Exit":"Sair","Exit IP":"IP de sa\u00edda","Extra rounds (60 s apart) before giving up.":"Rondas extra (com 60 s de intervalo) antes de desistir.","Folder":"Pasta","Font name":"Nome do tipo de letra","Font of the terminal text. Empty leaves the terminal as it is.":"Tipo de letra do texto do terminal. Vazio deixa o terminal como est\u00e1.","Font size":"Tamanho da letra","Free HTTP proxies from your list (any format) or the default one. Each is tested before use.":"Proxies HTTP gratuitos da tua lista (qualquer formato) ou da lista predefinida. Cada um \u00e9 testado antes de usar.","Free or your own list":"Gratuita ou a tua lista","Fresh start":"In\u00edcio novo","Full path of OpenCode.exe. Empty = search automatically.":"Caminho completo do OpenCode.exe. Vazio = procurar automaticamente.","Get a new IP or proxy, then open OpenCode. Your chats and history stay untouched.":"Obt\u00e9m um IP ou proxy novo e abre o OpenCode. As tuas conversas e hist\u00f3rico ficam intactos.","Gets a new IP / WARP registration / Tor circuit / proxy.":"Obt\u00e9m um novo IP / registo WARP / circuito Tor / proxy.","Go ahead.":"Avan\u00e7a.","Go back. Nothing is changed.":"Voltar. Nada \u00e9 alterado.","Guided setup: choose WARP, Tor, a proxy list or direct, then get an \"opencode\" command and a shortcut that start with it. It is tested at the end.":"Assistente: escolhe WARP, Tor, uma lista de proxies ou liga\u00e7\u00e3o direta e obt\u00e9m um comando \"opencode\" e um atalho que arrancam com ela. \u00c9 testado no fim.","HTTP port of the built-in bridge opencode uses.":"Porta HTTP da ponte integrada que o opencode usa.","Host used by the API check.":"Servidor usado pela verifica\u00e7\u00e3o da API.","How do you want to run OpenCode?":"Como queres executar o OpenCode?","How many proxies to test before giving up.":"Quantos proxies testar antes de desistir.","How many times, and how fast, a new IP is requested when the free limit is hit.":"Quantas vezes e a que ritmo se pede um IP novo quando o limite gratuito \u00e9 atingido.","IPs the probe may reject before giving up. 0 = no limit.":"IPs que o teste pode rejeitar antes de desistir. 0 = sem limite.","Icons and borders":"\u00cdcones e bordas","Install Tor automatically":"Instalar o Tor automaticamente","Keep the current connection and open OpenCode as it was.":"Mant\u00e9m a liga\u00e7\u00e3o atual e abre o OpenCode como estava.","Keep the current font.":"Manter o tipo de letra atual.","Kill opencode and clear the saved tokens, keeping your chats where they are.":"Fecha o opencode e apaga os tokens guardados, deixando as tuas conversas onde est\u00e3o.","Kill opencode, move your chats to the Desktop, clear the saved tokens and open a fresh session.":"Fecha o opencode, move as tuas conversas para o Ambiente de trabalho, apaga os tokens guardados e abre uma sess\u00e3o nova.","Language":"Idioma","Language of the menus and descriptions. auto follows Windows. Logs and the support report stay in English.":"Idioma dos menus e das descri\u00e7\u00f5es. auto segue o Windows. Os registos e o relat\u00f3rio de suporte ficam em ingl\u00eas.","Last check":"\u00daltima verifica\u00e7\u00e3o","Launch OpenCode":"Iniciar o OpenCode","Launcher":"Launcher","Launcher self-update":"Atualiza\u00e7\u00e3o autom\u00e1tica do launcher","Leave the setup without changing anything.":"Sair do assistente sem alterar nada.","Leave the terminal font as it is. If the launcher changed it, the original font comes back.":"Deixa o tipo de letra do terminal como est\u00e1. Se o launcher o alterou, volta o original.","Local Tor with a built-in HTTP bridge. A portable Tor is installed automatically if missing.":"Tor local com uma ponte HTTP integrada. Se faltar, \u00e9 instalado automaticamente um Tor port\u00e1til.","Local port of the WARP proxy.":"Porta local do proxy WARP.","Logs":"Registos","Main menu":"Menu principal","Method":"M\u00e9todo","Minimum list size (bytes)":"Tamanho m\u00ednimo da lista (bytes)","Mode":"Modo","Model used by the IP probe.":"Modelo usado pelo teste de IP.","Must be between {0} and {1}.":"Tem de estar entre {0} e {1}.","New IP and resume in 5s":"IP novo e retomar em 5 s","No":"N\u00e3o","No .exe file exists at that path.":"N\u00e3o existe nenhum ficheiro .exe nesse caminho.","No answer in {0}s counts as No.":"Sem resposta em {0} s conta como N\u00e3o.","No change.":"Sem altera\u00e7\u00f5es.","No proxy: opencode uses your real connection and nothing is rotated.":"Sem proxy: o opencode usa a tua liga\u00e7\u00e3o real e nada \u00e9 rodado.","No, cancel":"N\u00e3o, cancelar","Non-limit probe failures before the hunt stops.":"Falhas do teste que n\u00e3o s\u00e3o do limite antes de a procura parar.","Not a URL, and no file exists at that path.":"N\u00e3o \u00e9 um URL e n\u00e3o existe nenhum ficheiro nesse caminho.","Not configured":"N\u00e3o configurado","Nothing to ask for a direct connection.":"N\u00e3o h\u00e1 nada a perguntar para uma liga\u00e7\u00e3o direta.","Nothing was left half done that Uninstall cannot remove. Fix the problem and run setup again.":"N\u00e3o ficou nada a meio que Desinstalar n\u00e3o consiga remover. Corrige o problema e executa o assistente outra vez.","On PATH":"No PATH","Only opencode uses it; the rest of the system stays direct.":"S\u00f3 o opencode a usa; o resto do sistema continua em direto.","Open the Windows folder picker and choose where to work.":"Abre o seletor de pastas do Windows para escolher onde trabalhar.","Open the folder":"Abrir a pasta","Open the launcher menus: pick a folder and a connection method, then start the opencode CLI or the desktop app.":"Abre os menus do launcher: escolhe uma pasta e um m\u00e9todo de liga\u00e7\u00e3o e inicia a CLI do opencode ou a aplica\u00e7\u00e3o de ambiente de trabalho.","OpenCode app":"App do OpenCode","PATH lookup timeout (s)":"Tempo limite da procura no PATH (s)","Paths":"Caminhos","Port {0} is already used by {1}.":"A porta {0} j\u00e1 \u00e9 usada por {1}.","Ports and install behavior of the portable Tor the launcher starts for you.":"Portas e instala\u00e7\u00e3o do Tor port\u00e1til que o launcher inicia por ti.","Press any key to continue...":"Prime uma tecla para continuar...","Probe":"Teste","Probe failures tolerated":"Falhas de teste toleradas","Probe model":"Modelo de teste","Proxies tried per pick":"Proxies testados por escolha","Proxy":"Proxy","Proxy list":"Lista de proxies","Proxy list source":"Origem da lista de proxies","Proxy test timeout (s)":"Tempo limite do teste de um proxy (s)","Public HTTP proxies from a list (yours, in any format, or the free default). Each one is tested first and burned ones are skipped.":"Proxies HTTP p\u00fablicos de uma lista (a tua, em qualquer formato, ou a gratuita por defeito). Cada um \u00e9 testado primeiro e os queimados s\u00e3o ignorados.","Put every setting back to its default. Your connection setup (command, shortcuts) is not touched. Asks first.":"Rep\u00f5e todas as defini\u00e7\u00f5es nos valores predefinidos. A tua configura\u00e7\u00e3o de liga\u00e7\u00e3o (comando, atalhos) n\u00e3o \u00e9 tocada. Pede confirma\u00e7\u00e3o.","Put the full path on the clipboard.":"Coloca o caminho completo na \u00e1rea de transfer\u00eancia.","Quotes and line breaks are not allowed.":"N\u00e3o s\u00e3o permitidas aspas nem quebras de linha.","Range {0} to {1}.":"Intervalo de {0} a {1}.","Reconfigure (run setup again)":"Reconfigurar (executar o assistente outra vez)","Release metadata URL":"URL dos metadados de vers\u00f5es","Removes only what setup added: the opencode command, the shortcuts and the PATH entry.":"Remove apenas o que o assistente adicionou: o comando opencode, os atalhos e a entrada no PATH.","Removes only what the setup added (command, shortcuts, PATH entry) and restores the settings it changed. Backups are kept. Asks first.":"Remove apenas o que o assistente adicionou (comando, atalhos, entrada no PATH) e restaura as defini\u00e7\u00f5es que alterou. As c\u00f3pias de seguran\u00e7a s\u00e3o mantidas. Pede confirma\u00e7\u00e3o.","Removing shortcuts":"A remover atalhos","Removing the opencode command":"A remover o comando opencode","Renew did not finish (code {0}).":"A renova\u00e7\u00e3o n\u00e3o terminou (c\u00f3digo {0}).","Renew session":"Renovar sess\u00e3o","Renew the session?":"Renovar a sess\u00e3o?","Renewed. Open opencode again; you may need to log in once more.":"Renovada. Abre o opencode outra vez; talvez tenhas de iniciar sess\u00e3o de novo.","Renewing":"A renovar","Renewing the session":"A renovar a sess\u00e3o","Reopen the last folder":"Reabrir a \u00faltima pasta","Report ready. Personal data was removed; read it once before you share it.":"Relat\u00f3rio pronto. Os dados pessoais foram removidos; l\u00ea-o uma vez antes de o partilhares.","Repository":"Reposit\u00f3rio","Reset every setting to its default?":"Repor todas as defini\u00e7\u00f5es nos valores predefinidos?","Reset to default values":"Repor valores predefinidos","Restores the settings setup changed. Your other settings and your opencode files are kept.":"Restaura as defini\u00e7\u00f5es que o assistente alterou. As tuas outras defini\u00e7\u00f5es e os teus ficheiros do opencode s\u00e3o mantidos.","Restoring PATH":"A restaurar o PATH","Restoring settings":"A restaurar defini\u00e7\u00f5es","Resume message":"Mensagem de retoma","Resume timeout (s)":"Tempo limite da retoma (s)","Return to the connection details.":"Voltar aos detalhes da liga\u00e7\u00e3o.","Return to the main menu.":"Voltar ao menu principal.","Return to the settings groups.":"Voltar aos grupos de defini\u00e7\u00f5es.","Review":"Resumo","Rotate the connection only (new WARP registration, Tor circuit or proxy) without opening OpenCode.":"Roda s\u00f3 a liga\u00e7\u00e3o (novo registo WARP, circuito Tor ou proxy) sem abrir o OpenCode.","Rotate when a fatal error appears while opencode runs.":"Roda quando surge um erro grave enquanto o opencode corre.","Rotation":"Rota\u00e7\u00e3o","Rotation attempts":"Tentativas de rota\u00e7\u00e3o","Rotation rounds":"Rondas de rota\u00e7\u00e3o","Run mode":"Modo de execu\u00e7\u00e3o","Run opencode in this terminal. After a new IP the chat resumes by itself.":"Executa o opencode neste terminal. Depois de um IP novo a conversa retoma sozinha.","Run the OpenCode desktop app ({0}). It is restarted after every new IP.":"Executa a aplica\u00e7\u00e3o de ambiente de trabalho do OpenCode ({0}). \u00c9 reiniciada ap\u00f3s cada IP novo.","Run the setup again to change the method or repair the opencode command.":"Executa o assistente outra vez para mudar o m\u00e9todo ou reparar o comando opencode.","SOCKS port of the Tor the launcher starts.":"Porta SOCKS do Tor que o launcher inicia.","Save the settings, create the opencode command, the shortcuts and the PATH entry, then test the connection.":"Guarda as defini\u00e7\u00f5es, cria o comando opencode, os atalhos e a entrada no PATH e depois testa a liga\u00e7\u00e3o.","Saved: {0} = {1}":"Guardado: {0} = {1}","Saving config.json":"A guardar config.json","Seconds a single \"where\" lookup may take.":"Segundos que uma procura com \"where\" pode demorar.","Seconds a single proxy test may take.":"Segundos que o teste de um proxy pode demorar.","Seconds a single warp-cli call may take.":"Segundos que uma chamada ao warp-cli pode demorar.","Seconds before a silent resume counts as a dead IP.":"Segundos at\u00e9 uma retoma sem resposta contar como IP morto.","Seconds to wait after (re)connecting WARP.":"Segundos de espera ap\u00f3s (re)ligar o WARP.","Seconds to wait for Tor to finish bootstrapping.":"Segundos de espera at\u00e9 o Tor terminar de arrancar.","See what the setup installed (command, shortcuts, PATH) and run it again to change the method.":"V\u00ea o que o assistente instalou (comando, atalhos, PATH) e executa-o outra vez para mudar o m\u00e9todo.","Send one cheap message through each candidate IP.":"Envia uma mensagem barata por cada IP candidato.","Sent automatically after a rotation.":"Enviada automaticamente ap\u00f3s uma rota\u00e7\u00e3o.","Settings":"Defini\u00e7\u00f5es","Settings and setup":"Defini\u00e7\u00f5es e configura\u00e7\u00e3o","Setup 1/3 - connection method":"Configura\u00e7\u00e3o 1/3 - m\u00e9todo de liga\u00e7\u00e3o","Setup 2/3 - details":"Configura\u00e7\u00e3o 2/3 - detalhes","Setup 3/3 - run mode":"Configura\u00e7\u00e3o 3/3 - modo de execu\u00e7\u00e3o","Setup stopped: {0}":"O assistente parou: {0}","Shortcuts":"Atalhos","Show the CLI or Desktop choice every time the launcher opens.":"Mostra a escolha CLI ou Ambiente de trabalho sempre que o launcher abre.","Show the report in Explorer so you can attach or paste it.":"Mostra o relat\u00f3rio no Explorador para o poderes anexar ou colar.","Size used with the chosen font.":"Tamanho usado com o tipo de letra escolhido.","Support":"Suporte","Support report":"Relat\u00f3rio de suporte","Switch between the terminal and the desktop app.":"Alternar entre o terminal e a aplica\u00e7\u00e3o de ambiente de trabalho.","Switch to Tor and keep going?":"Mudar para o Tor e continuar?","System":"Sistema","Takes effect at the {0}; a service already running keeps the old value until then.":"Tem efeito em: {0}; um servi\u00e7o que j\u00e1 esteja a correr mant\u00e9m o valor antigo at\u00e9 l\u00e1.","Terminal font":"Tipo de letra do terminal","Test every new IP":"Testar cada IP novo","The OpenCode desktop app was not found. Choosing this offers to download and install it.":"A aplica\u00e7\u00e3o de ambiente de trabalho do OpenCode n\u00e3o foi encontrada. Ao escolh\u00ea-la \u00e9 oferecido descarreg\u00e1-la e instal\u00e1-la.","The OpenCode desktop app; it is restarted after every new IP.":"A aplica\u00e7\u00e3o de ambiente de trabalho do OpenCode; \u00e9 reiniciada ap\u00f3s cada IP novo.","The activity log (launcher.log) and the support report: what is recorded, how big it may grow, whether IPs are masked.":"O registo de atividade (launcher.log) e o relat\u00f3rio de suporte: o que \u00e9 guardado, quanto pode crescer e se os IPs s\u00e3o ocultados.","The cheap test message sent through every new IP before it is trusted.":"A mensagem de teste barata enviada por cada IP novo antes de confiar nele.","The check failed (code {0}). Setup is saved; fix the cause and use Renew or Connect again.":"A verifica\u00e7\u00e3o falhou (c\u00f3digo {0}). A configura\u00e7\u00e3o est\u00e1 guardada; corrige a causa e usa Renovar ou Ligar outra vez.","The font applies to the whole terminal window, not only to this launcher.":"O tipo de letra aplica-se a toda a janela do terminal, n\u00e3o s\u00f3 a este launcher.","The proxy lives only in the opencode process; the rest of the system stays direct.":"O proxy existe s\u00f3 no processo do opencode; o resto do sistema continua em direto.","The resume auto-approves tool permissions.":"A retoma aprova sozinha as permiss\u00f5es das ferramentas.","The shortcut and the opencode command use the CLI; this is the launcher menu default.":"O atalho e o comando opencode usam a CLI; isto \u00e9 o predefinido do menu do launcher.","The terminal interface. The opencode command and the shortcut always use it.":"A interface de terminal. O comando opencode e o atalho usam-na sempre.","This launcher is not the one that set it up. Reconfigure to repair the command.":"Este launcher n\u00e3o \u00e9 o que o configurou. Reconfigura para reparar o comando.","Token reset":"Rein\u00edcio de tokens","Tools and versions":"Ferramentas e vers\u00f5es","Tor HTTP bridge port":"Porta da ponte HTTP do Tor","Tor SOCKS port":"Porta SOCKS do Tor","Tor bootstrap wait (s)":"Espera do arranque do Tor (s)","Tor is downloaded once, run hidden and offered to opencode through a built-in HTTP bridge. Slower, but a new circuit is a new IP.":"O Tor \u00e9 descarregado uma vez, executado oculto e oferecido ao opencode atrav\u00e9s de uma ponte HTTP integrada. Mais lento, mas um circuito novo \u00e9 um IP novo.","Try again in a minute, or pick another connection method in Connect with opencode.":"Tenta de novo dentro de um minuto, ou escolhe outro m\u00e9todo de liga\u00e7\u00e3o em Ligar ao opencode.","Try again?":"Tentar de novo?","Try to download and install WARP now?":"Tentar descarregar e instalar o WARP agora?","Type \"opencode\" in a NEW terminal, or use the \"OpenCode Infinite (egress)\" shortcut.":"Escreve \"opencode\" num terminal NOVO, ou usa o atalho \"OpenCode Infinite (egress)\".","Type < to go back. Enter keeps the value shown.":"Escreve < para voltar. Enter mant\u00e9m o valor mostrado.","Type a font name...":"Escrever o nome de um tipo de letra...","URL or local file, any format (plain, CSV, JSON, XML, HTML).":"URL ou ficheiro local, em qualquer formato (texto simples, CSV, JSON, XML, HTML).","Unattended resume":"Retoma sem supervis\u00e3o","Uninstall":"Desinstalar","Uninstall stopped: {0}":"A desinstala\u00e7\u00e3o parou: {0}","Uninstall the opencode connection?":"Desinstalar a liga\u00e7\u00e3o do opencode?","Uninstalled. Backups stay in {0}":"Desinstalado. As c\u00f3pias de seguran\u00e7a ficam em {0}","Uninstalling":"A desinstalar","Update now?":"Atualizar agora?","Updates":"Atualiza\u00e7\u00f5es","Use 1 to 200 characters.":"Usa de 1 a 200 caracteres.","Use it when the free limit is hit or the login expired: closes opencode, saves and clears the saved tokens, and gets a new IP, WARP registration, Tor circuit or proxy.":"Usa quando o limite gratuito for atingido ou o in\u00edcio de sess\u00e3o expirar: fecha o opencode, guarda e apaga os tokens guardados e obt\u00e9m um IP, registo WARP, circuito Tor ou proxy novo.","Use on or off.":"Usa on ou off.","Use that proxy anyway?":"Usar esse proxy mesmo assim?","Use this folder":"Usar esta pasta","Use up to 31 characters, without quotes or backslashes.":"Usa at\u00e9 31 caracteres, sem aspas nem barras invertidas.","Use {0} for the terminal text. Monospaced fonts only look right.":"Usa {0} para o texto do terminal. S\u00f3 os tipos de letra monoespa\u00e7ados ficam bem.","Version":"Vers\u00e3o","View and change every launcher option: connection, proxies, Tor, rotation, themes. Saved instantly, no files to edit.":"V\u00ea e altera todas as op\u00e7\u00f5es do launcher: liga\u00e7\u00e3o, proxies, Tor, rota\u00e7\u00e3o, temas. Guardado de imediato, sem editar ficheiros.","WARP proxy port":"Porta do proxy WARP","WARP wait (s)":"Espera do WARP (s)","Watch the log":"Vigiar o registo","Watcher":"Vigilante","Watching the opencode log and the automatic \"continue\" sent after a rotation.":"Vigil\u00e2ncia do registo do opencode e do \"continue\" autom\u00e1tico enviado ap\u00f3s uma rota\u00e7\u00e3o.","Where proxies come from (URL or file, any format) and how each one is tested.":"De onde v\u00eam os proxies (URL ou ficheiro, qualquer formato) e como cada um \u00e9 testado.","Where versions and checksums are read from.":"De onde se leem as vers\u00f5es e as somas de verifica\u00e7\u00e3o.","Whether the launcher checks GitHub for a newer copy of itself at every start.":"Se o launcher procura no GitHub uma c\u00f3pia mais recente de si pr\u00f3prio em cada arranque.","Work in a different folder.":"Trabalhar noutra pasta.","Work in the folder the launcher was started from: {0}":"Trabalhar na pasta de onde o launcher foi iniciado: {0}","Work in {0}":"Trabalhar em {0}","Writing the report":"A escrever o relat\u00f3rio","Yes":"Sim","Yes, continue":"Sim, continuar","Your connection setup (shim, shortcuts) is not touched.":"A tua configura\u00e7\u00e3o de liga\u00e7\u00e3o (shim, atalhos) n\u00e3o \u00e9 tocada.","Your session needs renewing: {0}":"A tua sess\u00e3o precisa de ser renovada: {0}","asks first":"pede confirma\u00e7\u00e3o","auto":"auto","auto follows the terminal and NO_COLOR; off disables colors.":"auto segue o terminal e o NO_COLOR; off desativa as cores.","direct":"direto","emoji = modern terminals, unicode = classic console, ascii = anything.":"emoji = terminais modernos, unicode = consola cl\u00e1ssica, ascii = qualquer um.","free list":"lista gratuita","installed":"instalada","missing":"em falta","new IP":"IP novo","next Tor start":"pr\u00f3ximo arranque do Tor","next WARP connect":"pr\u00f3xima liga\u00e7\u00e3o do WARP","next launch":"pr\u00f3ximo arranque","no other step is needed.":"n\u00e3o \u00e9 preciso nenhum outro passo.","not installed":"n\u00e3o instalada","not verified":"n\u00e3o verificado","off":"desativado","on":"ativado","same IP":"mesmo IP","terminal":"terminal","warp-cli timeout (s)":"Tempo limite do warp-cli (s)","yes":"sim","{0} changed":"{0} alterados","{0} of {1}":"{0} de {1}","After opencode closes":"Depois que o opencode fechar","ask = R, M or Q: R gets a new IP and resumes the chat, M opens the menu, Q quits. quit = leave the launcher at once.":"ask = R, M ou Q: R pede um novo IP e retoma o chat, M abre o menu, Q sai. quit = fecha o launcher imediatamente."}
#>>>LANG tr {" move   Enter select   Esc back   1-9 or letter jump":" ta\u015f\u0131   Enter se\u00e7   Esc geri   1-9 veya harf ile atla","(Enter = keep \"{0}\")":"(Enter = \"{0}\" kals\u0131n)","(auto)":"(otomatik)","(nothing saved yet)":"(hen\u00fcz kay\u0131t yok)","(terminal default)":"(terminal varsay\u0131lan\u0131)","* = changed from the default. Enter edits or toggles the selected value.":"* = varsay\u0131landan de\u011fi\u015ftirildi. Enter se\u00e7ili de\u011feri d\u00fczenler ya da de\u011fi\u015ftirir.","A downloaded list smaller than this is rejected. 0 = off.":"Bundan k\u00fc\u00e7\u00fck indirilen liste reddedilir. 0 = kapal\u0131.","A port is a number from 1 to 65535.":"Ba\u011flant\u0131 noktas\u0131 1 ile 65535 aras\u0131nda bir say\u0131d\u0131r.","A proxy must also reach the opencode API host.":"Bir proxy ayr\u0131ca opencode API sunucusuna da ula\u015fmal\u0131d\u0131r.","API check URL":"API kontrol adresi","Accent colors of the interface.":"Aray\u00fcz\u00fcn vurgu renkleri.","Adding the command to your PATH":"Komut PATH'e ekleniyor","Adds: opencode command (shim), two shortcuts, one PATH entry. Backups are kept.":"Eklenir: opencode komutu (shim), iki k\u0131sayol, bir PATH girdisi. Yedekler saklan\u0131r.","Any installed font name, for example Cascadia Code.":"Y\u00fckl\u00fc herhangi bir yaz\u0131 tipi ad\u0131, \u00f6rne\u011fin Cascadia Code.","Appearance":"G\u00f6r\u00fcn\u00fcm","Applies at the {0}.":"{0} an\u0131nda uygulan\u0131r.","Apply":"Uygula","Apply setup":"Kurulumu uygula","Ask every time":"Her seferinde sor","Attempts per round when the tunnel is not up.":"T\u00fcnel a\u00e7\u0131k de\u011filse tur ba\u015f\u0131na deneme say\u0131s\u0131.","Back":"Geri","Backing up the current configuration":"Mevcut yap\u0131land\u0131rma yedekleniyor","Browse for a folder...":"Klas\u00f6r se\u00e7...","Burned IPs allowed":"Yak\u0131lan IP'lere izin verilen","Burned proxies before Tor offer":"Tor \u00f6nerisinden \u00f6nce yak\u0131lan proxy say\u0131s\u0131","Burned proxies in a row before PROXY mode offers Tor.":"PROXY modunun Tor \u00f6nermesi i\u00e7in art arda yak\u0131lmas\u0131 gereken proxy say\u0131s\u0131.","CLI terminal, Desktop app, or ask at every start.":"CLI terminali, Masa\u00fcst\u00fc uygulamas\u0131 veya her ba\u015flang\u0131\u00e7ta sor.","Cancel":"\u0130ptal","Cancel. Nothing is changed.":"\u0130ptal. Hi\u00e7bir \u015fey de\u011fi\u015fmedi.","Change IP":"IP de\u011fi\u015ftir","Change an answer.":"Bir yan\u0131t\u0131 de\u011fi\u015ftir.","Change any launcher setting: connection, proxies, Tor, rotation, themes, font. Applied right away.":"Ba\u015flat\u0131c\u0131n\u0131n her ayar\u0131n\u0131 de\u011fi\u015ftir: ba\u011flant\u0131, proxy'ler, Tor, rotasyon, temalar, yaz\u0131 tipi. Hemen uygulan\u0131r.","Check GitHub for a newer launcher at every start.":"Her ba\u015flang\u0131\u00e7ta GitHub'da daha yeni bir ba\u015flat\u0131c\u0131 olup olmad\u0131\u011f\u0131n\u0131 kontrol et.","Check the API host":"API sunucusunu kontrol et","Checking that it works":"\u00c7al\u0131\u015ft\u0131\u011f\u0131 kontrol ediliyor","Checking the connection":"Ba\u011flant\u0131 kontrol ediliyor","Choose \"Renew session\" below. It gets a new IP and clears the saved login;":"A\u015fa\u011f\u0131dan \"Oturumu yenile\"yi se\u00e7. Yeni bir IP al\u0131r ve kay\u0131tl\u0131 giri\u015fi temizler;","Choose a folder to work in":"\u00c7al\u0131\u015f\u0131lacak bir klas\u00f6r se\u00e7","Choose one of: {0}.":"\u015eunlardan birini se\u00e7: {0}.","Choose the connection for OpenCode":"OpenCode i\u00e7in ba\u011flant\u0131y\u0131 se\u00e7","Close the launcher.":"Ba\u015flat\u0131c\u0131y\u0131 kapat.","Closes every running opencode process.":"\u00c7al\u0131\u015fan t\u00fcm opencode s\u00fcre\u00e7lerini kapat\u0131r.","Cloudflare WARP in local proxy mode. Every rotation asks for a new registration, which gives a new exit IP. Needs the WARP client (offered if missing).":"Yerel proxy modunda Cloudflare WARP. Her rotasyon yeni bir kay\u0131t ister ve yeni bir \u00e7\u0131k\u0131\u015f IP'si verir. WARP istemcisi gerekir (yoksa \u00f6nerilir).","Cloudflare WARP in proxy mode. A new registration gives a new exit IP. Rotation supported.":"Proxy modunda Cloudflare WARP. Yeni bir kay\u0131t yeni bir \u00e7\u0131k\u0131\u015f IP'si verir. Rotasyon destekleniyor.","Cloudflare throttles rapid registrations.":"Cloudflare h\u0131zl\u0131 kay\u0131tlar\u0131 k\u0131s\u0131tlar.","Collect system info, versions, settings and the recent log into one text file you can send for help. Passwords, tokens, your user name and (by default) IPs are removed first.":"Sistem bilgisi, s\u00fcr\u00fcmler, ayarlar ve son g\u00fcnl\u00fc\u011f\u00fc yard\u0131m i\u00e7in g\u00f6nderebilece\u011fin tek bir metin dosyas\u0131nda topla. Parolalar, belirte\u00e7ler, kullan\u0131c\u0131 ad\u0131n ve (varsay\u0131lan olarak) IP'ler \u00f6nce silinir.","Color theme":"Renk temas\u0131","Color theme, colors on or off, icon and border style, and the terminal font. Applied immediately.":"Renk temas\u0131, renkler a\u00e7\u0131k veya kapal\u0131, simge ve kenarl\u0131k stili ve terminal yaz\u0131 tipi. Hemen uygulan\u0131r.","Colors":"Renkler","Command":"Komut","Configured - {0}":"Yap\u0131land\u0131r\u0131ld\u0131 - {0}","Confirm":"Onayla","Connect with opencode":"opencode ile ba\u011flan","Connected: opencode now starts through {0}.":"Ba\u011fland\u0131: opencode art\u0131k {0} \u00fczerinden ba\u015fl\u0131yor.","Connecting opencode":"opencode ba\u011flan\u0131yor","Connection":"Ba\u011flant\u0131","Connection method":"Ba\u011flant\u0131 y\u00f6ntemi","Continue":"Devam et","Continue WITHOUT the probe this session (IPs accepted untested)?":"Bu oturumda test OLMADAN devam edilsin mi (IP'ler test edilmeden kabul edilir)?","Continue anyway?":"Yine de devam edilsin mi?","Continue direct?":"Do\u011frudan devam edilsin mi?","Continue without WARP?":"WARP olmadan devam edilsin mi?","Cooldown between attempts (s)":"Denemeler aras\u0131 bekleme (sn)","Copies auth.json to your Desktop, then clears the saved tokens.":"auth.json dosyas\u0131n\u0131 Masa\u00fcst\u00fcne kopyalar, ard\u0131ndan kay\u0131tl\u0131 belirte\u00e7leri temizler.","Copy the file path":"Dosya yolunu kopyala","Creating shortcuts":"K\u0131sayollar olu\u015fturuluyor","Creating the opencode command":"opencode komutu olu\u015fturuluyor","Credentials inside a URL are not stored. Use a local file instead.":"Bir adresin i\u00e7indeki kimlik bilgileri kaydedilmez. Bunun yerine yerel bir dosya kullan.","Deep reset":"Derin s\u0131f\u0131rlama","Default connection method and run mode, the WARP proxy port and the warp-cli timings.":"Varsay\u0131lan ba\u011flant\u0131 y\u00f6ntemi ve \u00e7al\u0131\u015fma modu, WARP proxy ba\u011flant\u0131 noktas\u0131 ve warp-cli s\u00fcreleri.","Default: {0}.":"Varsay\u0131lan: {0}.","Desktop":"Masa\u00fcst\u00fc","Desktop app":"Masa\u00fcst\u00fc uygulamas\u0131","Desktop app location, release metadata URL and lookup timeouts.":"Masa\u00fcst\u00fc uygulamas\u0131n\u0131n konumu, s\u00fcr\u00fcm bilgisi adresi ve arama zaman a\u015f\u0131mlar\u0131.","Desktop app path":"Masa\u00fcst\u00fc uygulamas\u0131 yolu","Direct, no proxy":"Do\u011frudan, proxy yok","Do it now.":"\u015eimdi yap.","Do that now?":"\u015eimdi yap\u0131ls\u0131n m\u0131?","Download and install it now?":"\u015eimdi indirilip kurulsun mu?","Download the portable Tor bundle when nothing answers.":"Hi\u00e7bir \u015fey yan\u0131t vermedi\u011finde ta\u015f\u0131nabilir Tor paketini indir.","Egress":"\u00c7\u0131k\u0131\u015f","Egress used for opencode. ASK shows the picker at every start.":"opencode i\u00e7in kullan\u0131lan \u00e7\u0131k\u0131\u015f. ASK her ba\u015flang\u0131\u00e7ta se\u00e7iciyi g\u00f6sterir.","Enter a full URL (http, https, ftp or file).":"Tam bir adres gir (http, https, ftp veya file).","Enter a whole number.":"Tam say\u0131 gir.","Enter cycles: {0}.":"Enter ile d\u00f6n\u00fc\u015f\u00fcr: {0}.","Enter toggles it.":"Enter ile a\u00e7\u0131l\u0131p kapan\u0131r.","Every change is saved at once to {0}":"Her de\u011fi\u015fiklik hemen {0} dosyas\u0131na kaydedilir","Exit":"\u00c7\u0131k\u0131\u015f","Exit IP":"\u00c7\u0131k\u0131\u015f IP'si","Extra rounds (60 s apart) before giving up.":"Vazge\u00e7meden \u00f6nce ek turlar (60 sn arayla).","Folder":"Klas\u00f6r","Font name":"Yaz\u0131 tipi ad\u0131","Font of the terminal text. Empty leaves the terminal as it is.":"Terminal metninin yaz\u0131 tipi. Bo\u015f b\u0131rak\u0131l\u0131rsa terminal oldu\u011fu gibi kal\u0131r.","Font size":"Yaz\u0131 tipi boyutu","Free HTTP proxies from your list (any format) or the default one. Each is tested before use.":"Kendi listenden (herhangi bir bi\u00e7imde) veya varsay\u0131lan listeden \u00fccretsiz HTTP proxy'ler. Her biri kullan\u0131lmadan \u00f6nce test edilir.","Free or your own list":"\u00dccretsiz veya kendi listen","Fresh start":"Yeni ba\u015flang\u0131\u00e7","Full path of OpenCode.exe. Empty = search automatically.":"OpenCode.exe'nin tam yolu. Bo\u015f = otomatik ara.","Get a new IP or proxy, then open OpenCode. Your chats and history stay untouched.":"Yeni bir IP veya proxy al, sonra OpenCode'u a\u00e7. Sohbetlerin ve ge\u00e7mi\u015fin oldu\u011fu gibi kal\u0131r.","Gets a new IP / WARP registration / Tor circuit / proxy.":"Yeni bir IP / WARP kayd\u0131 / Tor devresi / proxy al\u0131r.","Go ahead.":"Devam et.","Go back. Nothing is changed.":"Geri d\u00f6n. Hi\u00e7bir \u015fey de\u011fi\u015fmez.","Guided setup: choose WARP, Tor, a proxy list or direct, then get an \"opencode\" command and a shortcut that start with it. It is tested at the end.":"Y\u00f6nlendirmeli kurulum: WARP, Tor, bir proxy listesi veya do\u011frudan ba\u011flant\u0131 se\u00e7, ard\u0131ndan onunla ba\u015flayan bir \"opencode\" komutu ve bir k\u0131sayol al. Sonunda test edilir.","HTTP port of the built-in bridge opencode uses.":"opencode'un kulland\u0131\u011f\u0131 yerle\u015fik k\u00f6pr\u00fcn\u00fcn HTTP ba\u011flant\u0131 noktas\u0131.","Host used by the API check.":"API kontrol\u00fcnde kullan\u0131lan sunucu.","How do you want to run OpenCode?":"OpenCode'u nas\u0131l \u00e7al\u0131\u015ft\u0131rmak istersin?","How many proxies to test before giving up.":"Vazge\u00e7meden \u00f6nce ka\u00e7 proxy test edilsin.","How many times, and how fast, a new IP is requested when the free limit is hit.":"\u00dccretsiz limite ula\u015f\u0131ld\u0131\u011f\u0131nda yeni bir IP ka\u00e7 kez ve ne kadar h\u0131zl\u0131 istensin.","IPs the probe may reject before giving up. 0 = no limit.":"Vazge\u00e7meden \u00f6nce test'in reddedebilece\u011fi IP say\u0131s\u0131. 0 = s\u0131n\u0131r yok.","Icons and borders":"Simgeler ve kenarl\u0131klar","Install Tor automatically":"Tor'u otomatik kur","Keep the current connection and open OpenCode as it was.":"Mevcut ba\u011flant\u0131y\u0131 koru ve OpenCode'u eskisi gibi a\u00e7.","Keep the current font.":"Mevcut yaz\u0131 tipini koru.","Kill opencode and clear the saved tokens, keeping your chats where they are.":"opencode'u kapat ve kay\u0131tl\u0131 belirte\u00e7leri temizle; sohbetlerin oldu\u011fu yerde kal\u0131r.","Kill opencode, move your chats to the Desktop, clear the saved tokens and open a fresh session.":"opencode'u kapat, sohbetlerini Masa\u00fcst\u00fcne ta\u015f\u0131, kay\u0131tl\u0131 belirte\u00e7leri temizle ve yeni bir oturum a\u00e7.","Language":"Dil","Language of the menus and descriptions. auto follows Windows. Logs and the support report stay in English.":"Men\u00fclerin ve a\u00e7\u0131klamalar\u0131n dili. auto Windows'u izler. G\u00fcnl\u00fckler ve destek raporu \u0130ngilizce kal\u0131r.","Last check":"Son kontrol","Launch OpenCode":"OpenCode'u ba\u015flat","Launcher":"Ba\u015flat\u0131c\u0131","Launcher self-update":"Ba\u015flat\u0131c\u0131n\u0131n kendini g\u00fcncellemesi","Leave the setup without changing anything.":"Kurulumdan hi\u00e7bir \u015fey de\u011fi\u015ftirmeden \u00e7\u0131k.","Leave the terminal font as it is. If the launcher changed it, the original font comes back.":"Terminal yaz\u0131 tipini oldu\u011fu gibi b\u0131rak. Ba\u015flat\u0131c\u0131 de\u011fi\u015ftirdiyse, \u00f6zg\u00fcn yaz\u0131 tipi geri gelir.","Local Tor with a built-in HTTP bridge. A portable Tor is installed automatically if missing.":"Yerle\u015fik HTTP k\u00f6pr\u00fcl\u00fc yerel Tor. Yoksa ta\u015f\u0131nabilir bir Tor otomatik kurulur.","Local port of the WARP proxy.":"WARP proxy'sinin yerel ba\u011flant\u0131 noktas\u0131.","Logs":"G\u00fcnl\u00fckler","Main menu":"Ana men\u00fc","Method":"Y\u00f6ntem","Minimum list size (bytes)":"En k\u00fc\u00e7\u00fck liste boyutu (bayt)","Mode":"Mod","Model used by the IP probe.":"IP testinde kullan\u0131lan model.","Must be between {0} and {1}.":"{0} ile {1} aras\u0131nda olmal\u0131.","New IP and resume in 5s":"5 sn i\u00e7inde yeni IP ve devam","No":"Hay\u0131r","No .exe file exists at that path.":"Bu yolda bir .exe dosyas\u0131 yok.","No answer in {0}s counts as No.":"{0} sn i\u00e7inde yan\u0131t yoksa Hay\u0131r say\u0131l\u0131r.","No change.":"De\u011fi\u015fiklik yok.","No proxy: opencode uses your real connection and nothing is rotated.":"Proxy yok: opencode ger\u00e7ek ba\u011flant\u0131n\u0131 kullan\u0131r ve hi\u00e7bir \u015fey d\u00f6nd\u00fcr\u00fclmez.","No, cancel":"Hay\u0131r, iptal et","Non-limit probe failures before the hunt stops.":"Arama durmadan \u00f6nce s\u0131n\u0131r d\u0131\u015f\u0131 test hatalar\u0131.","Not a URL, and no file exists at that path.":"Bu bir adres de\u011fil ve bu yolda bir dosya yok.","Not configured":"Yap\u0131land\u0131r\u0131lmad\u0131","Nothing to ask for a direct connection.":"Do\u011frudan ba\u011flant\u0131 i\u00e7in sorulacak bir \u015fey yok.","Nothing was left half done that Uninstall cannot remove. Fix the problem and run setup again.":"Kald\u0131rma i\u015fleminin silemeyece\u011fi yar\u0131m kalm\u0131\u015f bir \u015fey yok. Sorunu d\u00fczelt ve kurulumu yeniden \u00e7al\u0131\u015ft\u0131r.","On PATH":"PATH'te","Only opencode uses it; the rest of the system stays direct.":"Yaln\u0131zca opencode kullan\u0131r; sistemin geri kalan\u0131 do\u011frudan ba\u011fl\u0131 kal\u0131r.","Open the Windows folder picker and choose where to work.":"Windows klas\u00f6r se\u00e7icisini a\u00e7 ve nerede \u00e7al\u0131\u015f\u0131laca\u011f\u0131n\u0131 se\u00e7.","Open the folder":"Klas\u00f6r\u00fc a\u00e7","Open the launcher menus: pick a folder and a connection method, then start the opencode CLI or the desktop app.":"Ba\u015flat\u0131c\u0131 men\u00fclerini a\u00e7: bir klas\u00f6r ve ba\u011flant\u0131 y\u00f6ntemi se\u00e7, sonra opencode CLI'yi veya masa\u00fcst\u00fc uygulamas\u0131n\u0131 ba\u015flat.","OpenCode app":"OpenCode uygulamas\u0131","PATH lookup timeout (s)":"PATH arama zaman a\u015f\u0131m\u0131 (sn)","Paths":"Yollar","Port {0} is already used by {1}.":"{0} ba\u011flant\u0131 noktas\u0131 zaten {1} taraf\u0131ndan kullan\u0131l\u0131yor.","Ports and install behavior of the portable Tor the launcher starts for you.":"Ba\u015flat\u0131c\u0131n\u0131n senin i\u00e7in ba\u015flatt\u0131\u011f\u0131 ta\u015f\u0131nabilir Tor'un ba\u011flant\u0131 noktalar\u0131 ve kurulum davran\u0131\u015f\u0131.","Press any key to continue...":"Devam etmek i\u00e7in bir tu\u015fa bas...","Probe":"Test","Probe failures tolerated":"Tolere edilen test hatalar\u0131","Probe model":"Test modeli","Proxies tried per pick":"Se\u00e7im ba\u015f\u0131na denenen proxy say\u0131s\u0131","Proxy":"Proxy","Proxy list":"Proxy listesi","Proxy list source":"Proxy listesi kayna\u011f\u0131","Proxy test timeout (s)":"Proxy test zaman a\u015f\u0131m\u0131 (sn)","Public HTTP proxies from a list (yours, in any format, or the free default). Each one is tested first and burned ones are skipped.":"Bir listeden genel HTTP proxy'ler (senin listen, herhangi bir bi\u00e7imde, veya \u00fccretsiz varsay\u0131lan). Her biri \u00f6nce test edilir ve yak\u0131lanlar atlan\u0131r.","Put every setting back to its default. Your connection setup (command, shortcuts) is not touched. Asks first.":"Her ayar\u0131 varsay\u0131lan\u0131na geri getir. Ba\u011flant\u0131 kurulumun (komut, k\u0131sayollar) de\u011fi\u015fmez. \u00d6nce sorar.","Put the full path on the clipboard.":"Tam yolu panoya koy.","Quotes and line breaks are not allowed.":"T\u0131rnak i\u015faretleri ve sat\u0131r sonlar\u0131 kullan\u0131lamaz.","Range {0} to {1}.":"Aral\u0131k {0} ile {1} aras\u0131.","Reconfigure (run setup again)":"Yeniden yap\u0131land\u0131r (kurulumu tekrar \u00e7al\u0131\u015ft\u0131r)","Release metadata URL":"S\u00fcr\u00fcm bilgisi adresi","Removes only what setup added: the opencode command, the shortcuts and the PATH entry.":"Yaln\u0131zca kurulumun eklediklerini kald\u0131r\u0131r: opencode komutu, k\u0131sayollar ve PATH girdisi.","Removes only what the setup added (command, shortcuts, PATH entry) and restores the settings it changed. Backups are kept. Asks first.":"Yaln\u0131zca kurulumun eklediklerini (komut, k\u0131sayollar, PATH girdisi) kald\u0131r\u0131r ve de\u011fi\u015ftirdi\u011fi ayarlar\u0131 geri y\u00fckler. Yedekler saklan\u0131r. \u00d6nce sorar.","Removing shortcuts":"K\u0131sayollar kald\u0131r\u0131l\u0131yor","Removing the opencode command":"opencode komutu kald\u0131r\u0131l\u0131yor","Renew did not finish (code {0}).":"Yenileme tamamlanmad\u0131 (kod {0}).","Renew session":"Oturumu yenile","Renew the session?":"Oturum yenilensin mi?","Renewed. Open opencode again; you may need to log in once more.":"Yenilendi. opencode'u yeniden a\u00e7; bir kez daha giri\u015f yapman gerekebilir.","Renewing":"Yenileniyor","Renewing the session":"Oturum yenileniyor","Reopen the last folder":"Son klas\u00f6r\u00fc yeniden a\u00e7","Report ready. Personal data was removed; read it once before you share it.":"Rapor haz\u0131r. Ki\u015fisel veriler silindi; payla\u015fmadan \u00f6nce bir kez oku.","Repository":"Depo","Reset every setting to its default?":"Her ayar varsay\u0131lan\u0131na s\u0131f\u0131rlans\u0131n m\u0131?","Reset to default values":"Varsay\u0131lan de\u011ferlere s\u0131f\u0131rla","Restores the settings setup changed. Your other settings and your opencode files are kept.":"Kurulumun de\u011fi\u015ftirdi\u011fi ayarlar\u0131 geri y\u00fckler. Di\u011fer ayarlar\u0131n ve opencode dosyalar\u0131n korunur.","Restoring PATH":"PATH geri y\u00fckleniyor","Restoring settings":"Ayarlar geri y\u00fckleniyor","Resume message":"Devam mesaj\u0131","Resume timeout (s)":"Devam zaman a\u015f\u0131m\u0131 (sn)","Return to the connection details.":"Ba\u011flant\u0131 ayr\u0131nt\u0131lar\u0131na d\u00f6n.","Return to the main menu.":"Ana men\u00fcye d\u00f6n.","Return to the settings groups.":"Ayar gruplar\u0131na d\u00f6n.","Review":"G\u00f6zden ge\u00e7ir","Rotate the connection only (new WARP registration, Tor circuit or proxy) without opening OpenCode.":"OpenCode'u a\u00e7madan yaln\u0131zca ba\u011flant\u0131y\u0131 de\u011fi\u015ftir (yeni WARP kayd\u0131, Tor devresi veya proxy).","Rotate when a fatal error appears while opencode runs.":"opencode \u00e7al\u0131\u015f\u0131rken \u00f6l\u00fcmc\u00fcl bir hata \u00e7\u0131kt\u0131\u011f\u0131nda d\u00f6nd\u00fcr.","Rotation":"Rotasyon","Rotation attempts":"Rotasyon denemeleri","Rotation rounds":"Rotasyon turlar\u0131","Run mode":"\u00c7al\u0131\u015fma modu","Run opencode in this terminal. After a new IP the chat resumes by itself.":"opencode'u bu terminalde \u00e7al\u0131\u015ft\u0131r. Yeni bir IP'den sonra sohbet kendili\u011finden devam eder.","Run the OpenCode desktop app ({0}). It is restarted after every new IP.":"OpenCode masa\u00fcst\u00fc uygulamas\u0131n\u0131 \u00e7al\u0131\u015ft\u0131r ({0}). Her yeni IP'den sonra yeniden ba\u015flat\u0131l\u0131r.","Run the setup again to change the method or repair the opencode command.":"Y\u00f6ntemi de\u011fi\u015ftirmek veya opencode komutunu onarmak i\u00e7in kurulumu tekrar \u00e7al\u0131\u015ft\u0131r.","SOCKS port of the Tor the launcher starts.":"Ba\u015flat\u0131c\u0131n\u0131n ba\u015flatt\u0131\u011f\u0131 Tor'un SOCKS ba\u011flant\u0131 noktas\u0131.","Save the settings, create the opencode command, the shortcuts and the PATH entry, then test the connection.":"Ayarlar\u0131 kaydet, opencode komutunu, k\u0131sayollar\u0131 ve PATH girdisini olu\u015ftur, sonra ba\u011flant\u0131y\u0131 test et.","Saved: {0} = {1}":"Kaydedildi: {0} = {1}","Saving config.json":"config.json kaydediliyor","Seconds a single \"where\" lookup may take.":"Tek bir \"where\" aramas\u0131n\u0131n alabilece\u011fi saniye.","Seconds a single proxy test may take.":"Tek bir proxy testinin alabilece\u011fi saniye.","Seconds a single warp-cli call may take.":"Tek bir warp-cli \u00e7a\u011fr\u0131s\u0131n\u0131n alabilece\u011fi saniye.","Seconds before a silent resume counts as a dead IP.":"Sessiz bir devam\u0131n \u00f6l\u00fc IP say\u0131lmas\u0131 i\u00e7in ge\u00e7ecek saniye.","Seconds to wait after (re)connecting WARP.":"WARP yeniden ba\u011fland\u0131ktan sonra beklenecek saniye.","Seconds to wait for Tor to finish bootstrapping.":"Tor'un ba\u015flat\u0131lmas\u0131n\u0131n tamamlanmas\u0131 i\u00e7in beklenecek saniye.","See what the setup installed (command, shortcuts, PATH) and run it again to change the method.":"Kurulumun neleri y\u00fckledi\u011fine bak (komut, k\u0131sayollar, PATH) ve y\u00f6ntemi de\u011fi\u015ftirmek i\u00e7in yeniden \u00e7al\u0131\u015ft\u0131r.","Send one cheap message through each candidate IP.":"Her aday IP \u00fczerinden tek ve ucuz bir mesaj g\u00f6nder.","Sent automatically after a rotation.":"Bir rotasyondan sonra otomatik g\u00f6nderilir.","Settings":"Ayarlar","Settings and setup":"Ayarlar ve kurulum","Setup 1/3 - connection method":"Kurulum 1/3 - ba\u011flant\u0131 y\u00f6ntemi","Setup 2/3 - details":"Kurulum 2/3 - ayr\u0131nt\u0131lar","Setup 3/3 - run mode":"Kurulum 3/3 - \u00e7al\u0131\u015fma modu","Setup stopped: {0}":"Kurulum durduruldu: {0}","Shortcuts":"K\u0131sayollar","Show the CLI or Desktop choice every time the launcher opens.":"Ba\u015flat\u0131c\u0131 her a\u00e7\u0131ld\u0131\u011f\u0131nda CLI veya Masa\u00fcst\u00fc se\u00e7imini g\u00f6ster.","Show the report in Explorer so you can attach or paste it.":"Raporu Gezgin'de g\u00f6ster; ekleyebilmen veya yap\u0131\u015ft\u0131rabilmen i\u00e7in.","Size used with the chosen font.":"Se\u00e7ilen yaz\u0131 tipiyle kullan\u0131lan boyut.","Support":"Destek","Support report":"Destek raporu","Switch between the terminal and the desktop app.":"Terminal ile masa\u00fcst\u00fc uygulamas\u0131 aras\u0131nda ge\u00e7i\u015f yap.","Switch to Tor and keep going?":"Tor'a ge\u00e7ilip devam edilsin mi?","System":"Sistem","Takes effect at the {0}; a service already running keeps the old value until then.":"{0} an\u0131nda etkili olur; zaten \u00e7al\u0131\u015fan bir hizmet o zamana kadar eski de\u011feri korur.","Terminal font":"Terminal yaz\u0131 tipi","Test every new IP":"Her yeni IP'yi test et","The OpenCode desktop app was not found. Choosing this offers to download and install it.":"OpenCode masa\u00fcst\u00fc uygulamas\u0131 bulunamad\u0131. Bunu se\u00e7ersen indirip kurmay\u0131 \u00f6nerir.","The OpenCode desktop app; it is restarted after every new IP.":"OpenCode masa\u00fcst\u00fc uygulamas\u0131; her yeni IP'den sonra yeniden ba\u015flat\u0131l\u0131r.","The activity log (launcher.log) and the support report: what is recorded, how big it may grow, whether IPs are masked.":"Etkinlik g\u00fcnl\u00fc\u011f\u00fc (launcher.log) ve destek raporu: neyin kaydedildi\u011fi, ne kadar b\u00fcy\u00fcyebilece\u011fi, IP'lerin maskelenip maskelenmedi\u011fi.","The cheap test message sent through every new IP before it is trusted.":"G\u00fcvenilmeden \u00f6nce her yeni IP \u00fczerinden g\u00f6nderilen ucuz test mesaj\u0131.","The check failed (code {0}). Setup is saved; fix the cause and use Renew or Connect again.":"Kontrol ba\u015far\u0131s\u0131z oldu (kod {0}). Kurulum kaydedildi; nedeni d\u00fczelt ve Yenile ya da Ba\u011flan'\u0131 yeniden kullan.","The font applies to the whole terminal window, not only to this launcher.":"Yaz\u0131 tipi yaln\u0131zca bu ba\u015flat\u0131c\u0131ya de\u011fil, t\u00fcm terminal penceresine uygulan\u0131r.","The proxy lives only in the opencode process; the rest of the system stays direct.":"Proxy yaln\u0131zca opencode s\u00fcrecinde ya\u015far; sistemin geri kalan\u0131 do\u011frudan ba\u011fl\u0131 kal\u0131r.","The resume auto-approves tool permissions.":"Devam, ara\u00e7 izinlerini otomatik onaylar.","The shortcut and the opencode command use the CLI; this is the launcher menu default.":"K\u0131sayol ve opencode komutu CLI'yi kullan\u0131r; ba\u015flat\u0131c\u0131 men\u00fcs\u00fcn\u00fcn varsay\u0131lan\u0131 budur.","The terminal interface. The opencode command and the shortcut always use it.":"Terminal aray\u00fcz\u00fc. opencode komutu ve k\u0131sayol her zaman bunu kullan\u0131r.","This launcher is not the one that set it up. Reconfigure to repair the command.":"Bu ba\u015flat\u0131c\u0131 kurulumu yapan de\u011fil. Komutu onarmak i\u00e7in yeniden yap\u0131land\u0131r.","Token reset":"Belirte\u00e7 s\u0131f\u0131rlama","Tools and versions":"Ara\u00e7lar ve s\u00fcr\u00fcmler","Tor HTTP bridge port":"Tor HTTP k\u00f6pr\u00fc ba\u011flant\u0131 noktas\u0131","Tor SOCKS port":"Tor SOCKS ba\u011flant\u0131 noktas\u0131","Tor bootstrap wait (s)":"Tor ba\u015flatma beklemesi (sn)","Tor is downloaded once, run hidden and offered to opencode through a built-in HTTP bridge. Slower, but a new circuit is a new IP.":"Tor bir kez indirilir, gizli \u00e7al\u0131\u015ft\u0131r\u0131l\u0131r ve yerle\u015fik bir HTTP k\u00f6pr\u00fcs\u00fc \u00fczerinden opencode'a sunulur. Daha yava\u015ft\u0131r, ama yeni bir devre yeni bir IP demektir.","Try again in a minute, or pick another connection method in Connect with opencode.":"Bir dakika sonra tekrar dene veya opencode ile ba\u011flan'da ba\u015fka bir ba\u011flant\u0131 y\u00f6ntemi se\u00e7.","Try again?":"Tekrar denensin mi?","Try to download and install WARP now?":"WARP \u015fimdi indirilip kurulmaya \u00e7al\u0131\u015f\u0131ls\u0131n m\u0131?","Type \"opencode\" in a NEW terminal, or use the \"OpenCode Infinite (egress)\" shortcut.":"YEN\u0130 bir terminalde \"opencode\" yaz veya \"OpenCode Infinite (egress)\" k\u0131sayolunu kullan.","Type < to go back. Enter keeps the value shown.":"Geri d\u00f6nmek i\u00e7in < yaz. Enter g\u00f6sterilen de\u011feri korur.","Type a font name...":"Bir yaz\u0131 tipi ad\u0131 yaz...","URL or local file, any format (plain, CSV, JSON, XML, HTML).":"Adres veya yerel dosya, herhangi bir bi\u00e7imde (d\u00fcz metin, CSV, JSON, XML, HTML).","Unattended resume":"G\u00f6zetimsiz devam","Uninstall":"Kald\u0131r","Uninstall stopped: {0}":"Kald\u0131rma durduruldu: {0}","Uninstall the opencode connection?":"opencode ba\u011flant\u0131s\u0131 kald\u0131r\u0131ls\u0131n m\u0131?","Uninstalled. Backups stay in {0}":"Kald\u0131r\u0131ld\u0131. Yedekler \u015furada kal\u0131r: {0}","Uninstalling":"Kald\u0131r\u0131l\u0131yor","Update now?":"\u015eimdi g\u00fcncellensin mi?","Updates":"G\u00fcncellemeler","Use 1 to 200 characters.":"1 ile 200 karakter kullan.","Use it when the free limit is hit or the login expired: closes opencode, saves and clears the saved tokens, and gets a new IP, WARP registration, Tor circuit or proxy.":"\u00dccretsiz limite ula\u015f\u0131ld\u0131\u011f\u0131nda veya giri\u015fin s\u00fcresi doldu\u011funda kullan: opencode'u kapat\u0131r, kay\u0131tl\u0131 belirte\u00e7leri kaydedip temizler ve yeni bir IP, WARP kayd\u0131, Tor devresi veya proxy al\u0131r.","Use on or off.":"A\u00e7\u0131k veya kapal\u0131 kullan.","Use that proxy anyway?":"Yine de bu proxy kullan\u0131ls\u0131n m\u0131?","Use this folder":"Bu klas\u00f6r\u00fc kullan","Use up to 31 characters, without quotes or backslashes.":"En fazla 31 karakter kullan; t\u0131rnak veya ters e\u011fik \u00e7izgi olmadan.","Use {0} for the terminal text. Monospaced fonts only look right.":"Terminal metni i\u00e7in {0} kullan. Yaln\u0131zca sabit geni\u015flikli yaz\u0131 tipleri do\u011fru g\u00f6r\u00fcn\u00fcr.","Version":"S\u00fcr\u00fcm","View and change every launcher option: connection, proxies, Tor, rotation, themes. Saved instantly, no files to edit.":"Ba\u015flat\u0131c\u0131n\u0131n her se\u00e7ene\u011fini g\u00f6r\u00fcnt\u00fcle ve de\u011fi\u015ftir: ba\u011flant\u0131, proxy'ler, Tor, rotasyon, temalar. An\u0131nda kaydedilir, d\u00fczenlenecek dosya yok.","WARP proxy port":"WARP proxy ba\u011flant\u0131 noktas\u0131","WARP wait (s)":"WARP bekleme (sn)","Watch the log":"G\u00fcnl\u00fc\u011f\u00fc izle","Watcher":"\u0130zleyici","Watching the opencode log and the automatic \"continue\" sent after a rotation.":"opencode g\u00fcnl\u00fc\u011f\u00fcn\u00fc ve bir rotasyondan sonra g\u00f6nderilen otomatik \"continue\" mesaj\u0131n\u0131 izler.","Where proxies come from (URL or file, any format) and how each one is tested.":"Proxy'lerin nereden geldi\u011fi (adres veya dosya, herhangi bir bi\u00e7imde) ve her birinin nas\u0131l test edildi\u011fi.","Where versions and checksums are read from.":"S\u00fcr\u00fcmlerin ve sa\u011flama toplamlar\u0131n\u0131n nereden okundu\u011fu.","Whether the launcher checks GitHub for a newer copy of itself at every start.":"Ba\u015flat\u0131c\u0131n\u0131n her ba\u015flang\u0131\u00e7ta GitHub'da kendisinin daha yeni bir kopyas\u0131 olup olmad\u0131\u011f\u0131n\u0131 kontrol edip etmedi\u011fi.","Work in a different folder.":"Farkl\u0131 bir klas\u00f6rde \u00e7al\u0131\u015f.","Work in the folder the launcher was started from: {0}":"Ba\u015flat\u0131c\u0131n\u0131n a\u00e7\u0131ld\u0131\u011f\u0131 klas\u00f6rde \u00e7al\u0131\u015f: {0}","Work in {0}":"{0} klas\u00f6r\u00fcnde \u00e7al\u0131\u015f","Writing the report":"Rapor yaz\u0131l\u0131yor","Yes":"Evet","Yes, continue":"Evet, devam et","Your connection setup (shim, shortcuts) is not touched.":"Ba\u011flant\u0131 kurulumun (shim, k\u0131sayollar) de\u011fi\u015fmez.","Your session needs renewing: {0}":"Oturumunun yenilenmesi gerekiyor: {0}","asks first":"\u00f6nce sorar","auto":"otomatik","auto follows the terminal and NO_COLOR; off disables colors.":"auto terminali ve NO_COLOR'u izler; off renkleri kapat\u0131r.","direct":"do\u011frudan","emoji = modern terminals, unicode = classic console, ascii = anything.":"emoji = modern terminaller, unicode = klasik konsol, ascii = her \u015fey.","free list":"\u00fccretsiz liste","installed":"kurulu","missing":"eksik","new IP":"yeni IP","next Tor start":"bir sonraki Tor ba\u015flatmas\u0131","next WARP connect":"bir sonraki WARP ba\u011flant\u0131s\u0131","next launch":"bir sonraki ba\u015flatma","no other step is needed.":"ba\u015fka bir ad\u0131m gerekmez.","not installed":"kurulu de\u011fil","not verified":"do\u011frulanmad\u0131","off":"kapal\u0131","on":"a\u00e7\u0131k","same IP":"ayn\u0131 IP","terminal":"terminal","warp-cli timeout (s)":"warp-cli zaman a\u015f\u0131m\u0131 (sn)","yes":"evet","{0} changed":"{0} de\u011fi\u015fti","{0} of {1}":"{0} / {1}","After opencode closes":"opencode kapand\u0131\u011f\u0131nda","ask = R, M or Q: R gets a new IP and resumes the chat, M opens the menu, Q quits. quit = leave the launcher at once.":"ask = R, M veya Q: R yeni bir IP al\u0131r ve sohbeti s\u00fcrd\u00fcr\u00fcr, M men\u00fcy\u00fc a\u00e7ar, Q \u00e7\u0131kar. quit = ba\u015flat\u0131c\u0131dan hemen \u00e7\u0131k."}
