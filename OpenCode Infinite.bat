@echo off
setlocal EnableExtensions
title OpenCode-Infinite
REM ============================================================
REM  OpenCode launcher  (v2.34)
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
set "TARGET_TRIES=1"
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
set "PROBE_MODEL=opencode/big-pickle"
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
REM v3.1: ON again. Without it the opencode command and the shortcut kept running the
REM copy saved at setup, so a newer download was never used. Asks before it replaces.
REM The complete [upd] block is unchanged; set this to 1 to re-enable it.
set "UPDATE_CHECK=1"
REM v2.29: the activity log. Every part of the launcher appends to launcher.log
REM (see :log); the UI can bundle it into a support report with personal data
REM removed. LOG_MAX_KB bounds the file; LOG_MASK_IP is read by the report.
set "LOG_ENABLED=1"
set "LOG_MAX_KB=1024"
set "LOG_MASK_IP=1"
REM v2.30: what happens when opencode closes: ask (R/M/Q, default) or quit (see Settings).
set "ON_CLOSE=ask"
REM v3.1: the three letters of the closed-opencode prompt (Settings, Shortcuts).
set "KEY_ROTATE=R"
set "KEY_MENU=M"
set "KEY_QUIT=Q"

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
set "T_1=  This copy is not the official one. Starting the official copy:"
set "T_2=  OpenCode - how do you want to run it?"
set "T_3=  [1] CLI      - terminal TUI ^(chat resumes on every new IP^)"
set "T_4=  [2] Desktop  - the OpenCode desktop app ^(restarted on every new IP^)"
set "T_5=  [3] Exit"
set "T_6=  One key, no Enter."
set "T_7=%%C_WARN%%  [*] OpenCode desktop not found.%%C_RST%%"
set "T_8=%%C_WARN%%  [*] still not found - set OC_APP to its OpenCode.exe.%%C_RST%%"
set "T_9=  [app] DESKTOP "%%OC_DESKTOP%%""
set "T_10=  OpenCode - choose a folder to work in"
set "T_11=  [1] Reopen the last folder"
set "T_12=      ^(nothing saved yet^)"
set "T_13=  [2] Use this folder"
set "T_14=  [3] Browse for a folder..."
set "T_15=  [4] Exit"
set "T_16=  No folder saved yet. Use [2] or [3] this time."
set "T_17=  Choose a folder in the dialog..."
set "T_18=  Opening the classic folder picker..."
set "T_19=  No folder selected."
set "T_20=  Folder not found: "%%OPFOLDER%%""
set "T_21=  Cannot enter: "%%OPFOLDER%%""
set "T_22=  Working in: "%%CD%%""
set "T_23=  [egress] %%EGRESS%% ^(from your settings^)"
set "T_24=  Choose egress for OpenCode only (system traffic stays direct)"
set "T_25=  [1] WARP     - Cloudflare WARP proxy mode (rotation supported)"
set "T_26=  [2] TOR      - local Tor + built-in bridge on :%%TOR_HTTP_PORT%%"
set "T_27=                 (auto-installs a portable Tor, nothing to set up)"
set "T_28=  [3] PROXY    - free HTTP proxies (ProxyScrape list)"
set "T_29=  [4] NONE     - direct, no proxy"
set "T_30=  [egress] NONE - direct."
set "T_31=  [egress] PROXY - free HTTP list."
set "T_32=  [egress] TOR - portable Tor + built-in bridge on :%%TOR_HTTP_PORT%%, auto-setup."
set "T_33=  [egress] WARP."
set "T_34=  [dep] curl"
set "T_35=  [dep] warp"
set "T_36=%%C_WARN%%  [*] Cloudflare WARP not found - IP rotation will be disabled.%%C_RST%%"
set "T_37=      Install it later from 1.1.1.1 if you want the rotation."
set "T_38=%%C_WARN%%  [*] WARP still not available - continuing without rotation.%%C_RST%%"
set "T_39=      warp-cli errors, if any, are in %%STATE_DIR%%\wcli.log"
set "T_40=%%C_WARN%%  [*] Cloudflare WARP publishes 64-bit Windows builds only.%%C_RST%%"
set "T_41=      On this 32-bit system rotation is disabled."
set "T_42=%%C_OK%%  [ok] WARP ready.%%C_RST%%"
set "T_43=  [dep] opencode"
set "T_44=  [auto-install] opencode not found, fetching it..."
set "T_45=%%C_OK%%  [ok] opencode ready.%%C_RST%%"
set "T_46=%%C_ERR%%  ERROR: opencode install failed or is not on PATH.%%C_RST%%"
set "T_47=  Get it by hand: https://github.com/sst/opencode/releases"
set "T_48=  Preparing the connection..."
set "T_49=  OpenCode"
set "T_50=  Folder : "%%CD%%""
set "T_51=  Egress : %%EGRESS%%"
set "T_52=  Mode   : %%APP_MODE%%"
set "T_53=  WARP   : none ^(rotation disabled^)"
set "T_54=  WARP   : "%%WARP%%""
set "T_55=  Version: %%OC_VER%%  "%%OC_CMD%%""
set "T_56=  Exit IP: %%IP%%"
set "T_57=  What do you want to do?"
set "T_58=  [1] Fresh start   - get a new IP / proxy, then open OpenCode"
set "T_59=                      (your chats and history stay untouched)"
set "T_60=  [2] Continue      - same egress, open OpenCode as it was"
set "T_61=  [3] Change IP     - rotate / pick new proxy only"
set "T_62=  [5] Deep reset    - kill opencode, move chats to the Desktop,"
set "T_63=                      clear saved tokens, open a fresh session"
set "T_64=  [6] Exit"
set "T_65=  [7] Token reset   - kill opencode, clear saved tokens, keep chats"
set "T_66=                      where they are, open a fresh session"
set "T_67=  [8] Settings      - change any launcher setting, applied right away"
set "T_265=  [9] Sessions      - continue a chat from this folder"
set "T_68=--- deep reset -----------------------------------------------"
set "T_69=  This closes opencode, moves your chats to the Desktop,"
set "T_70=  clears the saved tokens and opens a brand new session."
set "T_71=  It is the only action in this script that touches your files."
set "T_72=  It also kills EVERY opencode process on this computer,"
set "T_73=  including windows opened by hand or by another launcher."
set "T_74=--- token reset ----------------------------------------------"
set "T_75=  This closes opencode, clears the saved tokens and opens a"
set "T_76=  brand new session. Your chats are NOT moved."
set "T_77=  auth.json is copied to the Desktop first, then removed."
set "T_78=    egress: %%EGRESS%%"
set "T_79=%%C_WARN%%  [*] WARP proxy is not answering - rotation has no effect.%%C_RST%%"
set "T_80=      Going direct would run opencode on your real IP."
set "T_81=%%C_WARN%%  [*] Tor did not get ready.%%C_RST%%"
set "T_82=%%C_WARN%%  [*] no working free proxy found.%%C_RST%%"
set "T_83=%%C_WARN%%  [*] the egress proxy stopped answering while OpenCode was open:%%C_RST%%"
set "T_84=      %%STATE_DIR%%\proxy_warn.txt"
set "T_85=%%C_WARN%%  [watch] a fatal error cut the chat - rotating and resuming it.%%C_RST%%"
set "T_86=OpenCode closed."
set "T_87=  %%KEY_ROTATE%% = new IP and resume the chat   %%KEY_MENU%% = menu   %%KEY_QUIT%% = quit (Ctrl+C also quits)"
set "T_88=Press any key to continue . . ."
set "T_89=  [tor] renewing the circuit, attempt %%TOR_TRIES%% of %%ROTATE_TRIES_MAX%%..."
set "T_90=%%C_OK%%  [tor] new circuit - resuming.%%C_RST%%"
set "T_91=%%C_WARN%%  [*] Tor could not be renewed - back to menu.%%C_RST%%"
set "T_92=%%C_WARN%%  [*] Tor could not get a usable circuit after %%ROTATE_TRIES_MAX%% attempts.%%C_RST%%"
set "T_93=      The exit node may be blocked: try a new identity in Tor, or"
set "T_94=      switch to [1] WARP. warp/tor notes: "%%TOR_DIR%%\tor.log""
set "T_95=  [proxy] %%ACTIVE_PROXY%% is burned - attempt %%PROXY_ROT%% of %%PROXY_ROT_MAX%%, picking another..."
set "T_96=  [proxy] picking a fresh free proxy before resume..."
set "T_97=%%C_WARN%%  [*] no free proxy is left that still works ^(they all hit the limit^).%%C_RST%%"
set "T_98=      Free proxies are shared by many people, so their limit is often used up."
set "T_99=  Automatic rotation is off - the menu decides."
set "T_100=Getting a new IP before the next attempt..."
set "T_101=  [i] hunting for %%HUNT_GOAL%%: up to %%TARGET_TRIES%% attempts, %%TARGET_MINUTES%% min. Esc or Q stops."
set "T_102=[%%ROTATE_TRIES%%/%%TARGET_TRIES%%] dropping the old registration..."
set "T_103=[%%ROTATE_TRIES%%/%%TARGET_TRIES%%] new registration..."
set "T_104=[%%ROTATE_TRIES%%] reconnect..."
set "T_105=[%%ROTATE_TRIES%%] waiting %%WARP_WAIT%%s..."
set "T_106=[%%ROTATE_TRIES%%] %%IPN%% was already tried in this hunt, rotating again"
set "T_107=[%%ROTATE_TRIES%%/%%TARGET_TRIES%%] exit IP %%IPN%% ^(country %%GLOC%%^), target %%TMATCHTXT%%, %%HUNT_LEFT%% attempt(s) left"
set "T_108=[%%ROTATE_TRIES%%] probing if this IP can still talk..."
set "T_109=%%C_WARN%%  [*] probe failed for a reason that is NOT a limit - attempt %%PBROKEN%% of %%PROBE_BROKEN_MAX%%. Last output:%%C_RST%%"
set "T_110=[%%PROBE_TRIES%%] IP already burned, rotating again..."
set "T_111=%%C_WARN%%  [*] %%PROBE_TRIES%% IPs probed, every one of them already burned.%%C_RST%%"
set "T_112=%%C_WARN%%  [*] the probe failed %%PBROKEN%% times and none of them was a limit error.%%C_RST%%"
set "T_113=      The probe itself is broken, not every IP: a retired PROBE_MODEL id,"
set "T_114=      an auth error or a CLI change. Rotation cannot fix that."
set "T_115=      Check PROBE_MODEL in the settings block, or run the probe model once"
set "T_116=      by hand to see the real error."
set "T_117=  [i] probe off for this session - IPs are accepted on WARP-trace proof"
set "T_118=      only, and the resume's own limit check keeps catching burned ones."
set "T_119=%%C_WARN%%  [*] the probe session "%%OC_PROBE_ID%%" does not exist and this%%C_RST%%"
set "T_120=      opencode build refused it. That is a probe problem, NOT a"
set "T_121=      burned IP - no rotation can fix it."
set "T_122=  [i] the probe is off for this session: IPs are accepted on"
set "T_123=      WARP-trace proof only, and the resume's own limit check still"
set "T_124=      catches a burned one. To keep the probe, create the session by"
set "T_125=      hand once, or clear PROBE in the settings block."
set "T_126=%%C_OK%%[%%ROTATE_TRIES%%] IP %%IPN%% works.%%C_RST%%"
set "T_127=[%%ROTATE_TRIES%%] no verified WARP IP yet, retrying..."
set "T_128=%%C_WARN%%  [*] no usable IP from this hunt. warp-cli errors, if any, are in %%STATE_DIR%%\wcli.log%%C_RST%%"
set "T_129=  restarting the desktop app on the new egress..."
set "T_130=  sending "%%RESUME_MSG%%" so the chat picks up where it stopped..."
set "T_131=%%C_WARN%%  [*] proxy dead - retrying on the current egress instead of resuming.%%C_RST%%"
set "T_132=%%C_WARN%%  [*] no answer in %%RESUME_TIMEOUT%%s - this exit IP is dead.%%C_RST%%"
set "T_133=%%C_OK%%  chat resumed on the new IP.%%C_RST%%"
set "T_134=%%C_WARN%%  [*] the resume itself hit a limit - rotating again.%%C_RST%%"
set "T_135=  Egress is NONE - nothing to rotate."
set "T_136=  Restarting the launcher-managed Tor for a new circuit..."
set "T_137=  TOR mode - this Tor was started outside the launcher."
set "T_138=  Restart it yourself for a new circuit, or pick [1] WARP / [4] NONE."
set "T_139=  Current bridge: http://127.0.0.1:%%TOR_HTTP_PORT%%"
set "T_140=  Picking a new free HTTP proxy..."
set "T_141=  New proxy: %%ACTIVE_PROXY%%"
set "T_142=WARP is not available - nothing to rotate."
set "T_143=Requesting a new WARP registration..."
set "T_144=waiting %%WARP_WAIT%%s..."
set "T_145=%%C_WARN%%  [*] no verified WARP IP.%%C_RST%%"
set "T_146=      warp-cli errors land in %%STATE_DIR%%\wcli.log"
set "T_147=  same IP as before: %%IPN%%"
set "T_148=%%C_OK%%  New exit IP: %%IPN%% ^(WARP verified^)%%C_RST%%"
set "T_149=  --- resume stderr ---"
set "T_150=  --- resume stdout ---"
set "T_151=  downloading the WARP installer, about 60 MB..."
set "T_152=%%C_WARN%%  [*] download failed.%%C_RST%%"
set "T_153=      grab it by hand and run it: %%WARP_MSI_URL%%"
set "T_154=  installing, accept the UAC prompt..."
set "T_155=  [auto-install] the standalone build did not install, trying npm."
set "T_156=  [i] 32-bit Windows: no standalone build - installing via npm."
set "T_157=%%C_OK%%  [ok] opencode ready on 32-bit via npm.%%C_RST%%"
set "T_158=%%C_ERR%%  ERROR: opencode could not be installed on 32-bit Windows.%%C_RST%%"
set "T_159=         Install 32-bit node.js by hand from nodejs.org, then run:"
set "T_160=         npm i -g opencode-ai"
set "T_161=%%C_WARN%%  [*] could not read the official release info from opencode.ai.%%C_RST%%"
set "T_162=  [auto-install] downloading opencode %%OCA_VER%% ^(official build, %%OC_AFILE%%^)..."
set "T_163=%%C_WARN%%    [*] checksum mismatch - the download is not the official file.%%C_RST%%"
set "T_164=%%C_WARN%%    [*] download failed.%%C_RST%%"
set "T_165=  [auto-install] unpacking, about 200 MB on disk..."
set "T_166=  [auto-install] installing %%NPMPKG%% with npm..."
set "T_167=  [npm] the install script was blocked - running it by hand..."
set "T_168=  [auto-install] node.js (32-bit) is missing - installing it..."
set "T_169=    via winget..."
set "T_170=  [i] this can take a few minutes on its first run."
set "T_171=    winget failed - trying the MSI installer from nodejs.org..."
set "T_172=    downloading %%NODE_MSI_URL%% ..."
set "T_173=    direct download failed - retrying through the Windows proxy settings..."
set "T_174=    installing, accept the UAC prompt..."
set "T_175=  opencode update available: %%OCUPD_CUR%% -^> %%OCUPD_LAT%%"
set "T_176=  It closes every running opencode process first."
set "T_177=  [update] npm i -g @opencode/cli@latest"
set "T_178=  [update] official standalone build %%OCUPD_LAT%%"
set "T_179=%%C_WARN%%  [*] "%%OC_CMD%%" reports %%OC_VER%% but this machine has a v2 database.%%C_RST%%"
set "T_180=      A v1 binary cannot open it: "Database is not empty and has no session table"."
set "T_181=      Update it:  npm i -g @opencode/cli@latest   ^(or accept the update offer^)"
set "T_182=%%C_WARN%%  [*] WARP registration missing - creating a new one.%%C_RST%%"
set "T_183=  [tor] nothing answering on :%%TOR_HTTP_PORT%% - portable setup starting..."
set "T_184=%%C_WARN%%  [*] Tor did not become ready - the reason is in "%%TOR_DIR%%\tor.log"%%C_RST%%"
set "T_185=%%C_WARN%%  [*] the Tor download did not land. Grab it by hand:%%C_RST%%"
set "T_186=      https://dist.torproject.org/torbrowser/"
set "T_187=      unpack the tor-expert-bundle tar.gz into "%%TOR_DIR%%","
set "T_188=      so that "%%TOR_DIR%%\Tor\tor.exe" exists, then run this again."
set "T_189=%%C_OK%%  [tor] ready: SOCKS :%%TOR_SOCKS_PORT%% - HTTP :%%TOR_HTTP_PORT%%.%%C_RST%%"
set "T_190=  [tor] updater JSON unavailable - falling back to the dist index..."
set "T_191=%%C_WARN%%  [*] the Tor bundle did not download.%%C_RST%%"
set "T_192=  [tor] unpacking..."
set "T_193=%%C_OK%%  [ok] Tor installed - portable - in "%%TOR_DIR%%".%%C_RST%%"
set "T_194=%%C_WARN%%  [*] the bundle unpacked but tor.exe was not found in "%%TOR_DIR%%".%%C_RST%%"
set "T_195=  [tor] a Tor is already running on :%%TOR_SOCKS_PORT%% - using it as it is."
set "T_196=  [tor] starting tor (hidden window, log: "%%OC_TORLOG%%")..."
set "T_197=%%C_WARN%%  [*] tor could not be started - see "%%OC_TORERR%%" and "%%OC_TORLOG%%".%%C_RST%%"
set "T_198=  [tor] starting the built-in HTTP-^>SOCKS bridge on :%%TOR_HTTP_PORT%% (no Privoxy needed)..."
set "T_199=  [tor] bootstrapping, up to %%TOR_BOOTSTRAP_WAIT%%s (the first run takes longer)..."
set "T_200=  [tor] Tor is up and routing through the bridge."
set "T_201=  [tor] still not up after %%TOR_BOOTSTRAP_WAIT%%s."
set "T_202=  [tor] found a Tor Browser SOCKS on :9150 - using it."
set "T_203=  [tor] found a Tor SOCKS on :9050 - using it."
set "T_204=  [*] this Tor was not started by the launcher - it cannot be renewed"
set "T_205=      from here. Restart Tor Browser yourself, or pick [1] WARP / [4] NONE."
set "T_206=  WARP proxy is not answering - cannot verify the exit IP."
set "T_207=  same IP as the last run, requesting a new registration..."
set "T_208=  [%%EN_TRIES%%] dropping the old registration..."
set "T_209=  [%%EN_TRIES%%] new registration..."
set "T_210=  [%%EN_TRIES%%] reconnecting WARP proxy..."
set "T_211=  [%%EN_TRIES%%] waiting %%WARP_WAIT%%s..."
set "T_212=  exit IP: %%CUR%%"
set "T_213=  no new IP after %%ROTATE_TRIES_MAX%% tries, launching on the current one."
set "T_214=  [note] opencode log not found: "%%LOGFILE%%""
set "T_215=         auto-detect stays off until the log appears."
set "T_216=  OpenCode desktop update available: %%DVER%% -^> %%OCA_VER%%"
set "T_217=  It closes every OpenCode process first, the app and its service included."
set "T_218=  downloading the OpenCode desktop installer %%OCA_VER%%, about 250 MB..."
set "T_219=  [*] checksum mismatch - the download is not the official file."
set "T_220=  [*] download failed."
set "T_221=      grab it by hand and run it: %%ID_URL%%"
set "T_222=      or from the website: https://opencode.ai/download"
set "T_223=  installing, accept the UAC prompt if one appears..."
set "T_224=  [*] could not read the official release info from opencode.ai."
set "T_225=      get the installer by hand: https://opencode.ai/download"
set "T_226=  [*] the desktop app has no 32-bit Windows build."
set "T_227=[verify] egress: %%EGRESS%%"
set "T_228=[verify] ip=%%IPN%% warp=%%WFLAG%%"
set "T_229=[verify] Cloudflare WARP is not installed ^(warp-cli not found^)."
set "T_230=[renew] egress: %%EGRESS%%"
set "T_231=[renew] new exit IP: %%IPN%%"
set "T_232=[renew] Cloudflare WARP is not installed ^(warp-cli not found^)."
set "T_233=[renew] proxy: %%ACTIVE_PROXY%%"
set "T_234=[renew] done"
set "T_235=[renew] could not get a working connection"
set "T_236=  archiving chats to:"
set "T_237=  nothing to archive."
set "T_238=  archived."
set "T_239=  [*] could not move the storage folder - it stays where it is."
set "T_240=  [*] could not copy %%1 - it stays where it is."
set "T_241=  [*] size mismatch on %%1 - the bad copy is deleted, the original stays."
set "T_242=  cache and tokens cleared."
set "T_243=  auth.json archived in "%%TARGET%%"."
set "T_244=  [*] the auth.json copy did not verify - tokens are left in place."
set "T_245=  [*] could not copy auth.json - tokens are left in place."
set "T_246=  [*] no archive folder for this reset - auth.json is left in place."
set "T_247=  [*] the WARP port answers SOCKS5 only, and OpenCode cannot use SOCKS."
set "T_248=      WARP is up, but no usable HTTP proxy can be handed to it."
set "T_249=  [proxy] process-only: %%ACTIVE_PROXY%%"
set "T_250=  [proxy] reading the proxy list..."
set "T_251=  [proxy] %%PCOUNT%% proxies in the list"
set "T_252=  [*] no proxies found in "%%PSRC%%""
set "T_253=  [*] no proxy passed the API check, but %%TRACE_ONLY%% did reach Cloudflare."
set "T_254=      PROXY_API_CHECK_URL may be wrong - see the settings block."
set "T_255=  [proxy] live: %%ACTIVE_PROXY%%"
set "T_256=  [*] OpenCode-Infinite is already open in another window."
set "T_257=  Exiting."
set "T_258=  [upd] repo copy is %%SU_RV%%, older than %%SU_LV%% - keeping this one."
set "T_259=  [upd] launcher matches the repo, %%SU_LV%%."
set "T_260=  [upd] update found: local %%SU_LV%% - repo %%SU_RV%%"
set "T_261=  [upd] swapping in %%SU_RV%% - this window closes now."
set "T_262=  [upd] the swap could not be prepared - keeping %%SU_LV%%."
set "T_263=        The downloaded copy is in "%%SU_TMP%%"."
set "T_264=  Press any key to close this window."
set "T_270=  Nothing to restore in that backup."
set "T_271=  Restore the chats from:"
set "T_272=  The chats in place now are moved to the Desktop first. Nothing is deleted."
set "T_273=  [*] some storage files did not copy. The backup is untouched."
set "T_274=  Chats restored. The previous ones are in:"
REM v2.31: batch messages are translated from langs\<code>.json; i18n.cmd is written by the UI.
set "OC_TUI=mki18n"
set "OC_STATE=%STATE_DIR%"
"%PSX%" -NoProfile -Command "$l=Get-Content -LiteralPath $env:OCI_SELF; $i=[Array]::IndexOf($l,'#>>>OC_TUI_PS'); $e=[Array]::IndexOf($l,'#>>>OC_ENDTUI'); if(($i -lt 0) -or ($e -le $i)){exit 20}; Invoke-Expression (($l[($i+1)..($e-1)]) -join [Environment]::NewLine)"
set "OC_TUI="
if exist "%STATE_DIR%\i18n.cmd" call "%STATE_DIR%\i18n.cmd"
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
call :numcfg TARGET_TRIES 1
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
call :log "start v2.34 args=[%LOG_ARGS%] cwd=%CD% arch=%PROCESSOR_ARCHITECTURE% %LOG_OSV%" boot
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
call echo %T_1%
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
if "%UPDATE_CHECK%"=="1" if /i not "%UPDATE_ASK%"=="never" call :self_update

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
if /i "%OC_MODE_DEFAULT%"=="DESKTOP" call :find_desktop_app
if /i "%OC_MODE_DEFAULT%"=="DESKTOP" if defined OC_DESKTOP goto :mode_desktop_ok
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
REM v3.1: Esc (3) goes back to the home screen, it does not quit.
if "%TUIRC%"=="3" goto :home_start
goto :quit
:mode_cli
set "APP_MODE=CLI"
goto :mode_done
:mode_old
cls
echo ============================================================
call echo %T_2%
echo ============================================================
echo.
call echo %T_3%
call echo %T_4%
if defined OC_DESKTOP echo       "%OC_DESKTOP%"
if not defined OC_DESKTOP echo       ^(not found - [2] offers to install it^)
call echo %T_5%
echo.
call echo %T_6%
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
call echo %T_7%
call :yn "   Download and install it now? [Y/N]: "
if errorlevel 100 goto :quit
if errorlevel 2 goto :mode_menu
call :install_desktop
call :find_desktop_app
if defined OC_DESKTOP goto :mode_desktop_ok
call echo %T_8%
call :pause_key
goto :mode_menu
:mode_desktop_ok
set "APP_MODE=DESKTOP"
echo.
call echo %T_9%
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
REM v3.1: Esc (5) goes back to the home screen; 4 is the Exit row.
if "%TUIRC%"=="5" goto :home_start
goto :quit
:folder_old
cls
echo ============================================================
call echo %T_10%
echo ============================================================
echo.
set "OPFOLDER="
set "LASTPATH="
REM Read the saved folder path, strip quotes, and drop it if it no longer exists.
if exist "%LASTFOLDER%" set /p LASTPATH=<"%LASTFOLDER%"
if defined LASTPATH set "LASTPATH=%LASTPATH:"=%"
if defined LASTPATH if not exist "%LASTPATH%\" set "LASTPATH="
echo.
call echo %T_11%
REM Show the saved path only when there is one; otherwise show a placeholder.
if defined LASTPATH goto :folder_lp
call echo %T_12%
goto :folder_m2
:folder_lp
echo       "%LASTPATH%"
:folder_m2
call echo %T_13%
echo       "%CD%"
call echo %T_14%
call echo %T_15%
echo.
call echo %T_6%
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
  call echo %T_16%
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
call echo %T_17%
set "OPFOLDER="
REM Both dialogs open where the user last worked, when that folder exists.
set "OC_START=%USERPROFILE%"
if defined LASTPATH if exist "%LASTPATH%\" set "OC_START=%LASTPATH%"
set "OC_MODE=modern"
call :run_picker
if defined OPFOLDER goto :pick_done
REM Modern dialog cancelled (ESC/X) or unable to start: classic fallback.
call echo %T_18%
set "OC_MODE=classic"
call :run_picker
if defined OPFOLDER goto :pick_done
echo.
call echo %T_19%
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
call echo %T_20%
timeout /t 3 /nobreak >nul 2>&1
goto :folder

REM Enter the folder. pushd is used because it also accepts UNC (network) paths.
:folder_ok2
pushd "%OPFOLDER%" 2>nul
if not errorlevel 1 goto :folder_ok3
echo.
call echo %T_21%
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
call echo %T_22%
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
call echo %T_23%
goto :egress_done
:egress_ask
call :tui_init
if not defined TUI_OK goto :egress_old
set "OC_H_FOLDER=%CD%"
call :tui egress
set "TUIRC=%errorlevel%"
if "%TUIRC%"=="20" goto :egress_old
if %TUIRC% LSS 1 goto :quit
REM v3.1: Esc (5) goes back to the folder screen.
if "%TUIRC%"=="5" goto :folder
if %TUIRC% GTR 4 goto :quit
cmd /c exit %TUIRC%
goto :egress_pick
:egress_old
echo ============================================================
call echo %T_24%
echo ============================================================
echo.
call echo %T_25%
call echo %T_26%
call echo %T_27%
call echo %T_28%
call echo %T_29%
echo.
call echo %T_6%
echo.
call :pick 1234 "Pick egress: "
:egress_pick
REM v2.25: stdin closed answers 255; do not silently pick NONE.
if errorlevel 100 goto :quit
if errorlevel 4 (
  set "EGRESS=NONE"
  set "ACTIVE_PROXY="
  set "WARP="
  call echo %T_30%
  goto :egress_done
)
if errorlevel 3 (
  set "EGRESS=PROXY"
  set "ACTIVE_PROXY="
  set "WARP="
  call echo %T_31%
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
  call echo %T_32%
  goto :egress_done
)
set "EGRESS=WARP"
set "ACTIVE_PROXY="
call echo %T_33%
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
call echo %T_34%
call :have_exe curl.exe
set "HAVE_CURL=%HAVE%"

REM - WARP (optional, only when EGRESS=WARP)
if /i not "%EGRESS%"=="WARP" goto :check_opencode
REM Look for warp-cli. If found, skip the WARP setup and go to opencode.
call :trace dep_warp
call echo %T_35%
call :find_warp
if defined WARP goto :check_opencode

REM 32-bit systems cannot run the WARP installer: skip the offer.
if "%REAL86%"=="1" goto :no_warp_32

call echo %T_36%
call echo %T_37%
echo.
REM Offer the install. Answering N continues without rotation.
call :yn "   Try to download and install WARP now? [Y/N]: "
if errorlevel 2 goto :check_opencode
call :install_warp
call :find_warp
if defined WARP goto :warp_ready
call echo %T_38%
call echo %T_39%
goto :check_opencode

REM Message shown on 32-bit systems, then continue without WARP.
:no_warp_32
call echo %T_40%
call echo %T_41%
goto :check_opencode

REM WARP was installed or found: confirm and continue.
:warp_ready
call echo %T_42%

REM - opencode
REM Look for the opencode command. If found, go to the menu.
:check_opencode
call :trace dep_opencode
call echo %T_43%
call :find_opencode
call :db_guard
if defined OC_CMD goto :ready

REM Not found: install it (npm first, then the standalone build).
call echo %T_44%
call :install_opencode
REM v2.22: :install_opencode can abort (32-bit with no route) - exit from
REM here, at top level, where :quit is safe to reach with goto.
if defined OC_ABORT goto :quit
call :find_opencode
if defined OC_CMD (
  call echo %T_45%
  goto :ready
)
REM The install failed: show a manual link and stop.
call echo %T_46%
call echo %T_47%
call :pause_key
goto :quit

REM Both dependencies are ready. Probe what this CLI build supports,
REM then a short pause before the menu.
:ready
call :detect_caps
call :log "opencode: %OC_CMD% version=%OC_VER% service=%CAP_SERVICE% standalone=%CAP_STANDALONE%" deps
REM CLI update check only in CLI mode; desktop mode checks its own update right after it is picked.
if /i not "%APP_MODE%"=="DESKTOP" call :oc_update_check
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
call echo %T_48%
goto :menu_work
:menu_hdr_old
cls
echo ============================================================
call echo %T_49%
echo.
call echo %T_50%
call echo %T_51%
call echo %T_52%
if defined ACTIVE_PROXY echo   Proxy  : %ACTIVE_PROXY%
REM Show the WARP path only in WARP mode; otherwise say rotation is off.
if /i not "%EGRESS%"=="WARP" goto :menu_warp_done
if defined WARP goto :menu_warp_path
call echo %T_53%
goto :menu_warp_done
:menu_warp_path
call echo %T_54%
:menu_warp_done
if not defined OC_VER goto :menu_ver_done
call echo %T_55%
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
REM v3.1: Esc (10) on the main menu goes back to the home screen.
if "%TUIRC%"=="10" goto :home_start
if %TUIRC% GTR 9 goto :menu_loop
cmd /c exit %TUIRC%
goto :menu_dispatch
:menu_old_list
call echo %T_56%
echo.
call echo %T_57%
echo.
call echo %T_58%
call echo %T_59%
call echo %T_60%
call echo %T_61%
if /i not "%APP_MODE%"=="DESKTOP" echo   [4] Folder        - work in a different folder
if /i "%APP_MODE%"=="DESKTOP" echo   [4] Mode          - switch between CLI and Desktop
call echo %T_62%
call echo %T_63%
call echo %T_64%
REM NEW: option 7 is like [5] but leaves the chats where they are.
call echo %T_65%
call echo %T_66%
call echo %T_67%
call echo %T_265%
echo.
call echo %T_6%
echo.
REM Read the menu choice. Highest number is checked first.
call :pick 123456789 "Pick: "
:menu_dispatch
REM choice exits 0 on Ctrl+C: quit cleanly (v2.30), never guess option 1.
REM v2.25: with stdin closed (piped input, EOF) choice answers 255, not 0, and
REM 255 satisfies every "if errorlevel N" below, so the old guard looped here
REM forever through the token-reset prompt. No console to ask: leave.
if errorlevel 100 goto :quit
if not errorlevel 1 goto :quit
REM NEW: 7 is checked first (highest number first).
REM Main menu codes 1 new IP, 7 clear tokens, 3 change IP, 4 deep submenu, 9 mode, 6 exit.
if errorlevel 9 goto :menu_mode
if errorlevel 7 goto :run_soft
if errorlevel 6 goto :quit
if errorlevel 4 goto :menu_deep
if errorlevel 3 goto :rotate
goto :run_cold

REM Option 9 (Sessions): pick a chat from this folder and continue it with --session.
REM The picker writes the id to session_pick.txt; exit 1 = a session was picked. CLI only.
:menu_sessions
set "SESS_PICK=%STATE_DIR%\session_pick.txt"
if exist "%SESS_PICK%" del /f /q "%SESS_PICK%" >nul 2>&1
call :tui sessions
set "SESSRC=%errorlevel%"
if not "%SESSRC%"=="1" goto :menu_loop
set "SESSID="
if exist "%SESS_PICK%" for /f "usebackq delims=" %%s in ("%SESS_PICK%") do set "SESSID=%%s"
if not defined SESSID goto :menu_loop
set "RUNARGS=--session %SESSID%"
set "COLD=0"
goto :run

REM Option 8: the settings screens; WARP_UP=0 re-applies the proxy port on the
REM next pass. Values that a running service cannot change say so in the UI.
:menu_settings
call :tui settings
call :cfg_import
set "WARP_UP=0"
goto :menu_loop

REM Deep reset or restore chats: its own submenu. 1 = deep reset, 2 = restore.
:menu_deep
call :tui deep
set "DRC=%errorlevel%"
if "%DRC%"=="1" goto :run_deep
if "%DRC%"=="2" goto :restore_chats
goto :menu_loop

REM Mode (CLI or Desktop) from the main menu.
:menu_mode
set "MODE_FORCE_ASK=1"
goto :mode_menu

REM Restore chats from an archived deep reset. Auth is not restored.
REM The chats in place now are moved aside to the Desktop, never deleted.
:restore_chats
set "RS_PICK=%STATE_DIR%\restore_pick.txt"
if exist "%RS_PICK%" del /f /q "%RS_PICK%" >nul 2>&1
if not defined DESKTOP call :find_desktop
set "OC_ARCH=%DESKTOP%\opencode_chats_archiviate"
call :tui restore
set "RSRC=%errorlevel%"
if not "%RSRC%"=="1" goto :menu_deep
set "RS_SRC="
if exist "%RS_PICK%" for /f "usebackq delims=" %%s in ("%RS_PICK%") do set "RS_SRC=%%s"
if not defined RS_SRC goto :menu_deep
if not exist "%RS_SRC%\opencode.db" if not exist "%RS_SRC%\storage" (
  call echo %T_270%
  goto :menu_deep
)
echo.
call echo %T_271%
echo     "%RS_SRC%"
call echo %T_272%
echo.
call :yn "  Restore now? [Y/N] "
if errorlevel 2 goto :menu_deep
call :stop_opencode
set "RS_KEEP=%DESKTOP%\opencode_chats_before_restore\%RANDOM%%RANDOM%"
if not exist "%RS_KEEP%" mkdir "%RS_KEEP%" >nul 2>&1
for %%F in (opencode.db opencode.db-wal opencode.db-shm) do if exist "%DATA_DIR%\%%F" move /y "%DATA_DIR%\%%F" "%RS_KEEP%\%%F" >nul
if exist "%DATA_DIR%\storage" robocopy "%DATA_DIR%\storage" "%RS_KEEP%\storage" /e /move /r:1 /w:1 /nfl /ndl /njh /njs /np >nul
for %%F in (opencode.db opencode.db-wal opencode.db-shm) do if exist "%RS_SRC%\%%F" copy /y "%RS_SRC%\%%F" "%DATA_DIR%\%%F" >nul
if exist "%RS_SRC%\storage" robocopy "%RS_SRC%\storage" "%DATA_DIR%\storage" /e /r:1 /w:1 /nfl /ndl /njh /njs /np >nul
if errorlevel 8 call echo %T_273%
call echo %T_274%
echo     "%RS_KEEP%"
set "RESUME="
set "COLD=0"
goto :run

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
call echo %T_68%
call echo %T_69%
call echo %T_70%
call echo %T_71%
REM v2.22: :stop_opencode kills every opencode.exe on the machine, not only
REM this session's. Say so before asking.
call echo %T_72%
call echo %T_73%
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
call echo %T_74%
call echo %T_75%
call echo %T_76%
call echo %T_77%
call echo %T_72%
call echo %T_73%
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
call echo %T_78%

REM never launch through a dead proxy, and never "rotate" into a
REM direct connection: the gate asks instead of leaking silently.
if /i "%EGRESS%"=="NONE" goto :run_noproxy
if /i "%EGRESS%"=="WARP" if not defined WARP goto :run_noproxy

REM Prepare ACTIVE_PROXY for the chosen mode (process-only).
if /i "%EGRESS%"=="WARP" (
  set "ACTIVE_PROXY=%PROXY%"
  call :export_proxy
  if errorlevel 1 (
    call echo %T_79%
    call echo %T_80%
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
call echo %T_81%
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
call echo %T_82%
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
call echo %T_83%
call echo %T_84%
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
call echo %T_85%
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
call echo %T_86%
if /i "%ON_CLOSE%"=="quit" goto :quit
if /i "%EGRESS%"=="NONE" goto :menu_loop
if /i "%EGRESS%"=="WARP" if not defined WARP goto :menu_loop
echo.
call echo %T_87%
REM v2.30: no timeout and no default: the prompt waits for a deliberate key.
call :flush_keys
call :pick %KEY_ROTATE%%KEY_MENU%%KEY_QUIT% "Pick: "
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
call echo %T_88%
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
call echo %T_89%
call :tor_rotate
if errorlevel 1 goto :tor_rotate_fail
call :tor_gate
if errorlevel 1 goto :tor_rotate_fail
call echo %T_90%
set "RESUME=1"
set "COLD=0"
goto :resume_and_run
:tor_rotate_fail
call echo %T_91%
call :pause_key
goto :menu_loop
:tor_exhausted
call echo %T_92%
call echo %T_93%
call echo %T_94%
set /a TOR_TRIES=0
>"%STATE_DIR%\renew_needed.txt" echo Tor could not get a usable circuit
call :log "Tor could not get a usable circuit" rotate
call :pause_key
goto :menu_loop
:qr_proxy
if defined ACTIVE_PROXY >>"%STATE_DIR%\proxy_burned.txt" echo %ACTIVE_PROXY%
set /a PROXY_ROT+=1
if %PROXY_ROT% GTR %PROXY_ROT_MAX% goto :proxy_exhausted
call echo %T_95%
call echo %T_96%
call :pick_free_proxy
if errorlevel 1 goto :proxy_exhausted
set "RESUME=1"
set "COLD=0"
goto :resume_and_run
:proxy_exhausted
call echo %T_97%
call echo %T_98%
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
    call echo %T_99%
    goto :menu_loop
)
call echo %T_100%
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
call echo %T_101%
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
call echo %T_102%
call :reg_drop
REM A new registration gets a new exit IP from Cloudflare.
call echo %T_103%
call :reg_new
if "%REGNEW%"=="0" echo [%ROTATE_TRIES%] the daemon refused a new registration - see wcli.log
call echo %T_104%
call :warp_up
set "WARP_UP=1"
call echo %T_105%
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
    call echo %T_106%
    goto :rotate_loop
)
set "HUNT_SEEN=%HUNT_SEEN%;%IPN%;"
call :target_ok
set /a HUNT_LEFT=TARGET_TRIES-ROTATE_TRIES
call echo %T_107%
if "%TMATCH%"=="0" goto :rotate_loop

REM probe: one cheap message on the throwaway session. burned IP ->
REM rotate again. With PROBE=0 the probe is skipped and the IP is accepted directly.
if "%PROBE%"=="0" goto :rotate_good
call echo %T_108%
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
call echo %T_109%
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
call echo %T_110%
goto :rotate_loop
:probe_exhausted
echo.
call echo %T_111%
set "HUNT_WHY=burned"
goto :rotate_fail
:probe_broken_stop
echo.
call echo %T_112%
call echo %T_113%
call echo %T_114%
call echo %T_115%
call echo %T_116%
call :yn "   Continue WITHOUT the probe this session (IPs accepted untested)? [Y/N]: "
if errorlevel 2 goto :pbs_quit
call echo %T_117%
call echo %T_118%
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
call echo %T_119%
call echo %T_120%
call echo %T_121%
call echo %T_122%
call echo %T_123%
call echo %T_124%
call echo %T_125%
set "PROBE=0"
set "PBROKEN=0"
REM v2.23: the IP itself was fine, only the probe could not run. Rotating
REM again burned a fresh Cloudflare registration for nothing; accept this
REM IP and resume.
goto :rotate_good

REM A verified IP that passed the probe: save it, mark the resume, and resume the chat.
:rotate_good
call echo %T_126%
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
call echo %T_127%
goto :rotate_loop

REM The hunt is over without a usable IP: summary, then the menu.
:rotate_fail
call :hunt_summary
goto :rotate_pause
:rotate_pause
REM never leave the probe session behind as the last session
call "%OC_CMD%" session delete %OC_PROBE_ID% >nul 2>&1
call echo %T_128%
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
call echo %T_129%
set "RESUME="
goto :run
:resume_cli
call echo %T_130%
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
    call echo %T_131%
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
    call echo %T_132%
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
call echo %T_133%
REM v2.23: a good resume clears the circuit counter. Without this TOR_TRIES
REM accumulated for the whole session and four clean renewals in a row sent
REM the fifth to the menu.
set /a TOR_TRIES=0
set "PROXY_ROT=0"
goto :run
REM The resume hit a limit: go back to the rotation with WHY=quota.
:resume_fatal
call echo %T_134%
call :resume_tail
set "WHY=quota"
goto :quota_rotate

REM Option 3: rotate only, without opening opencode. Shows the result and waits.
:rotate
if /i "%EGRESS%"=="NONE" (
  echo.
  call echo %T_135%
  call :pause_key
  goto :menu_loop
)
if /i "%EGRESS%"=="TOR" (
  echo.
  if defined OURTOR (
    call echo %T_136%
    REM v2.22: one call does the whole renewal, log-aware on failure.
    call :tor_rotate
    if errorlevel 1 echo %C_WARN%  [!] the new circuit did not come up - see "%TOR_DIR%\tor.log".%C_RST%
    if not errorlevel 1 echo   New circuit: Tor is serving on :%TOR_HTTP_PORT% again.
    call :pause_key
    goto :menu_loop
  )
  REM v2.22: a Tor this launcher did not start cannot be renewed from here.
  call echo %T_137%
  call echo %T_138%
  call echo %T_139%
  call :pause_key
  goto :menu_loop
)
if /i "%EGRESS%"=="PROXY" (
  echo.
  call echo %T_140%
  call :pick_free_proxy
  if errorlevel 1 (
    call echo %T_82%
  ) else (
    call echo %T_141%
  )
  call :pause_key
  goto :menu_loop
)
REM WARP path
if not defined WARP (
  echo.
  call echo %T_142%
  call :pause_key
  goto :menu_loop
)
echo.
call echo %T_143%
call :reg_drop
call :reg_new
if "%REGNEW%"=="0" echo %C_WARN%  [!] the WARP daemon refused a new registration - see "%STATE_DIR%\wcli.log"%C_RST%
call :warp_up
set "WARP_UP=1"
call echo %T_144%
timeout /t %WARP_WAIT% /nobreak >nul 2>&1
call :getip2 IPN WFLAG
if defined IPN if "%WFLAG%"=="on" goto :rotate_ok
REM Explain why the rotation failed: no answer or tunnel down.
call echo %T_145%
if defined IPN if not "%WFLAG%"=="on" echo       the trace answered but warp=off - the tunnel is not up.
if not defined IPN echo       no trace answer - the proxy on port %PROXY_PORT% is down.
call echo %T_146%
call :pause_key
goto :menu_loop
REM Rotation succeeded. Report whether the IP changed or stayed the same.
:rotate_ok
if /i not "%IPN%"=="%IP%" goto :rotate_new
call echo %T_147%
goto :rotate_done
:rotate_new
call echo %T_148%
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
call echo %T_149%
set "OC_TF=%STATE_DIR%\resume.err"
"%PSX%" -NoProfile -Command "if(Test-Path -LiteralPath $env:OC_TF){ Get-Content -LiteralPath $env:OC_TF -Tail 8 | ForEach-Object { '     ' + $_ } }"
call echo %T_150%
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
call echo %T_151%
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
call echo %T_152%
call echo %T_153%
if exist "%MSI%" del /f /q "%MSI%" >nul 2>&1
goto :eof
REM Install silently; the UAC prompt appears here. Remove the MSI afterwards.
:iw_install
call echo %T_154%
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
call echo %T_155%
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
call echo %T_156%
call :install_node_x86
call :npm_install opencode-ai
call :find_opencode
if defined OC_CMD (
  call echo %T_157%
  goto :eof
)
call echo %T_158%
call echo %T_159%
call echo %T_160%
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
call echo %T_161%
goto :eof
:sa_have
set "OC_URL=%OCA_URL%"
set "OCZIP=%TEMP%\opencode-windows.zip"
set "OCBIN=%LOCALAPPDATA%\opencode\bin"
call echo %T_162%
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
call echo %T_163%
:sa_bad
call echo %T_164%
if exist "%OCZIP%" del /f /q "%OCZIP%" >nul 2>&1
goto :eof
REM Unpack the zip into the bin folder, then add that folder to PATH for this session.
:sa_unzip
if not exist "%OCBIN%" mkdir "%OCBIN%" >nul 2>&1
call echo %T_165%
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
call echo %T_166%
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
call echo %T_167%
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
call echo %T_168%
call :have_exe winget.exe
if "%HAVE%"=="1" goto :node_winget
goto :node_msi
:node_winget
call echo %T_169%
call echo %T_170%
"%PSX%" -NoProfile -Command "$p=Start-Process -FilePath winget.exe -ArgumentList @('install','--id','OpenJS.NodeJS.LTS','--silent','--accept-package-agreements','--accept-source-agreements','--disable-interactivity') -NoNewWindow -PassThru; $null=$p.Handle; if(-not $p.WaitForExit(600000)){ try{$p.Kill()}catch{}; exit 1 }; exit $p.ExitCode" >nul 2>&1
if not errorlevel 1 goto :node_done
call echo %T_171%
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
call echo %T_172%
if "%HAVE_CURL%"=="1" goto :nx_curl
"%PSX%" -NoProfile -Command "try{[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -UseBasicParsing -Uri $env:OC_URL -OutFile $env:OC_OUT -TimeoutSec 900}catch{}" >nul 2>&1
goto :nx_check
:nx_curl
curl.exe -L -f -s --max-time 900 --noproxy "*" -o "%NODE_MSI%" "%NODE_MSI_URL%"
if not errorlevel 1 goto :nx_check
call echo %T_173%
"%PSX%" -NoProfile -Command "try{[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -UseBasicParsing -Uri $env:OC_URL -OutFile $env:OC_OUT -TimeoutSec 900}catch{}" >nul 2>&1
REM Restore the proxy variables and check the MSI size.
:nx_check
set "HTTP_PROXY=%KEEP_HP%"
set "HTTPS_PROXY=%KEEP_SP%"
set "NOK=0"
if exist "%NODE_MSI%" for %%M in ("%NODE_MSI%") do if not "%%~zM"=="" if %%~zM GTR 1000000 set "NOK=1"
if not "%NOK%"=="1" goto :node_done
call echo %T_174%
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
if /i "%UPDATE_ASK%"=="never" goto :eof
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
call echo %T_175%
call echo %T_176%
call :yn_upd "   Update now? [Y/N]: "
REM errorlevel 0 (no stdin) and 2 (N) both skip the install.
if not errorlevel 1 goto :eof
if errorlevel 2 goto :eof
call :stop_opencode
REM Same channel as the running command: npm installs go through npm, the rest
REM through the official standalone build.
echo "%OC_CMD%" | findstr /i /c:"\npm" >nul 2>&1
if errorlevel 1 goto :ouc_standalone
call echo %T_177%
call :npm_install
goto :ouc_after
:ouc_standalone
call echo %T_178%
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
call echo %T_179%
call echo %T_180%
call echo %T_181%
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
call echo %T_182%
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
call echo %T_183%
call :tor_install_if_missing
if not defined TOR_EXE goto :tg_missing
:tg_existing
call :tor_start_if_needed
if errorlevel 1 goto :tg_fail
call :tor_wait_up
call :tor_ready
if not errorlevel 1 goto :tg_ok
:tg_fail
call echo %T_184%
call :tor_log_tail
exit /b 1
:tg_missing
call echo %T_185%
call echo %T_186%
call echo %T_187%
call echo %T_188%
exit /b 1
REM v2.24: single place that records who owns the running Tor, whichever
REM branch reached a ready state.
:tg_have
call :tor_own_running
if not errorlevel 1 set "OURTOR=1"
:tg_ok
call echo %T_189%
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
call echo %T_190%
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
call echo %T_191%
goto :eof
:tia_up_ok
set "HTTP_PROXY=%KEEP_HP%"
set "HTTPS_PROXY=%KEEP_SP%"
call echo %T_192%
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
  call echo %T_193%
) else (
  call echo %T_194%
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
call echo %T_195%
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
call echo %T_196%
REM tor's config switch is -f (a "--torrc" flag does not exist: tor
REM exits with "Unknown option 'torrc'"). stderr is captured so a tor
REM that refuses to start leaves its own reason in tor_start.err, and
REM the spawn is confirmed two seconds later: a process that died
REM immediately after Start-Process is a failed start, not an up one.
"%PSX%" -NoProfile -Command "try{ $si=New-Object System.Diagnostics.ProcessStartInfo; $si.FileName=$env:OC_TOREXE; $si.Arguments=('-f '+[char]34+$env:OC_TORRC+[char]34+' --quiet'); $si.UseShellExecute=$false; $si.CreateNoWindow=$true; $si.RedirectStandardError=$true; $p=[System.Diagnostics.Process]::Start($si); if(-not $p){ exit 1 }; [IO.File]::WriteAllText($env:OC_TORPID,[string]$p.Id); Start-Sleep -Seconds 2; if($p.HasExited){ try{ [IO.File]::WriteAllText($env:OC_TORERR, 'tor exited with code '+$p.ExitCode+': '+($p.StandardError.ReadToEnd())) }catch{}; exit 1 }; exit 0 }catch{ exit 1 }" >nul 2>&1
if errorlevel 1 (
  call echo %T_197%
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
call echo %T_198%
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
call echo %T_199%
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
call echo %T_200%
exit /b 0
:tw_timeout
echo.
call echo %T_201%
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
call echo %T_202%
set "TOR_SOCKS_PORT=9150"
exit /b 0
:tsu_9050
call echo %T_203%
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
call echo %T_204%
call echo %T_205%
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
call echo %T_206%
goto :eof
REM Current IP is verified: compare it with the last one.
:ens_have
if not defined LASTIP goto :remember_ip
if /i not "%CUR%"=="%LASTIP%" goto :remember_ip
call echo %T_207%
set /a EN_TRIES=0

REM Loop: new registration until the IP differs or the limit is reached.
:ens_loop
set /a EN_TRIES+=1
if %EN_TRIES% GTR %ROTATE_TRIES_MAX% goto :ens_giveup
call echo %T_208%
call :reg_drop
call echo %T_209%
call :reg_new
if "%REGNEW%"=="0" echo   [%EN_TRIES%] the daemon refused a new registration - see wcli.log
call echo %T_210%
call :warp_up
set "WARP_UP=1"
call echo %T_211%
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
call echo %T_212%
goto :eof
REM Limit reached without a new IP: continue with the current one.
:ens_giveup
call echo %T_213%
goto :remember_ip

REM - did this run write a fatal line to the log?
REM Sets QHIT=1 when the log part written during this run has a fatal line.
REM If the log does not exist, warns once and leaves auto-detection off.
:check_quota
set "QHIT="
if exist "%LOGFILE%" goto :cq_run
if defined QWARNED goto :eof
set "QWARNED=1"
call echo %T_214%
call echo %T_215%
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
if /i "%UPDATE_ASK%"=="never" goto :eof
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
call echo %T_216%
call echo %T_217%
call :yn_upd "   Update now? [Y/N]: "
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
call echo %T_218%
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
call echo %T_219%
:id_bad
call echo %T_220%
call echo %T_221%
call echo %T_222%
if exist "%ID_EXE%" del /f /q "%ID_EXE%" >nul 2>&1
goto :eof
:id_run
call echo %T_223%
set "OC_ID=%ID_EXE%"
"%PSX%" -NoProfile -Command "try{Start-Process $env:OC_ID -ArgumentList '/S' -Wait}catch{}" >nul 2>&1
del /f /q "%ID_EXE%" >nul 2>&1
goto :eof
:id_noapi
call echo %T_224%
call echo %T_225%
goto :eof
:id_no86
call echo %T_226%
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
if exist "%STATE_DIR%\i18n.cmd" call "%STATE_DIR%\i18n.cmd"
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
if "%TUIRC%"=="3" exit /b 3
exit /b 2
:yn_upd
set "OC_UPD=1"
call :yn %1
set "YU_RC=%errorlevel%"
set "OC_UPD="
exit /b %YU_RC%
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
call echo %T_227%
call :log "verify start egress=%EGRESS%" verify
if /i "%EGRESS%"=="NONE" goto :vm_none
if /i "%EGRESS%"=="TOR" goto :vm_tor
if /i "%EGRESS%"=="PROXY" goto :vm_proxy
call :find_warp
if not defined WARP goto :vm_nowarp
call :warp_up
call :getip2 IPN WFLAG
call echo %T_228%
if defined IPN if "%WFLAG%"=="on" exit /b 0
exit /b 1
:vm_nowarp
call echo %T_229%
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
call echo %T_230%
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
call echo %T_231%
>"%STATE_DIR%\lastip.txt" echo %IPN%
goto :rm_done
:rm_nowarp
call echo %T_232%
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
call echo %T_233%
:rm_done
if exist "%STATE_DIR%\renew_needed.txt" del /f /q "%STATE_DIR%\renew_needed.txt" >nul 2>&1
call echo %T_234%
exit /b 0
:rm_fail
call echo %T_235%
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
call echo %T_236%
echo     "%TARGET%"
set "MOVED=0"
if exist "%DATA_DIR%\storage" call :archive_storage
for %%F in (opencode.db opencode.db-wal opencode.db-shm) do call :archive_file %%F
if not "%MOVED%"=="0" goto :arch_done
if exist "%TARGET%" rmdir "%TARGET%" >nul 2>&1
call echo %T_237%
goto :eof
REM Something was moved: report it.
:arch_done
call echo %T_238%
goto :eof

REM robocopy does not care about volumes and deletes the source
REM only after the copy is complete.
REM Move the storage folder with robocopy. Exit codes 8 and above mean failure.
:archive_storage
if not exist "%TARGET%" mkdir "%TARGET%" >nul 2>&1
robocopy "%DATA_DIR%\storage" "%TARGET%\storage" /e /move /r:1 /w:1 /nfl /ndl /njh /njs /np >nul
if errorlevel 8 (
  call echo %T_239%
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
  call echo %T_240%
  goto :eof
)
set "SZS="
set "SZD="
for %%A in ("%DATA_DIR%\%1") do set "SZS=%%~zA"
for %%A in ("%TARGET%\%1") do set "SZD=%%~zA"
if "%SZS%"=="%SZD%" goto :af_del
call echo %T_241%
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
call echo %T_242%
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
call echo %T_243%
goto :eof
:aa_bad
del /f /q "%TARGET%\auth.json" >nul 2>&1
call echo %T_244%
goto :eof
:aa_fail
call echo %T_245%
goto :eof
:aa_nodir
call echo %T_246%
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
call echo %T_247%
call echo %T_248%
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
call echo %T_249%
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
call echo %T_250%
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
call echo %T_251%
goto :pfp_listok
:pfp_nolist
call echo %T_252%
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
call echo %T_253%
call echo %T_254%
call :yn "   Use that proxy anyway? [Y/N]: "
if errorlevel 2 exit /b 1
set "ACTIVE_PROXY=%TRACE_ONLY%"
call echo %T_255%
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
call echo %T_255%
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
"%PSX%" -NoProfile -Command "try{ $of=Join-Path $env:OC_LOCK 'owner'; if(Test-Path -LiteralPath $of){ $o=(Get-Content -LiteralPath $of -ErrorAction SilentlyContinue | Select-Object -First 1); $alive=$false; if($o){ $pr=Get-Process -Id ([int]$o) -ErrorAction SilentlyContinue; if($pr -and $pr.ProcessName -eq 'cmd' -and ((Get-CimInstance Win32_Process -Filter ('ProcessId='+$pr.Id)).CommandLine -match '\.bat')){ $alive=$true } }; if(-not $alive){ Remove-Item -LiteralPath $env:OC_LOCK -Recurse -Force; exit 0 } }; $d=Get-Item -LiteralPath $env:OC_LOCK -Force; $t=$d.LastWriteTime; $sf=Join-Path $env:OC_LOCK 'stamp'; if(Test-Path -LiteralPath $sf){ $s=(Get-Item -LiteralPath $sf -Force).LastWriteTime; if($s -gt $t){ $t=$s } }; $live=$false; $dead=$false; if(Test-Path -LiteralPath $env:OC_LTPID){ $c=(Get-Content -LiteralPath $env:OC_LTPID -ErrorAction SilentlyContinue | Select-Object -First 1); if($c){ if(Get-Process -Id ([int]$c) -ErrorAction SilentlyContinue){ $live=$true } else { $dead=$true } } }; if($live){ exit 1 }; $h=((Get-Date)-$t).TotalHours; if((-not $dead -or $h -lt 0.0167) -and $h -le 2){ exit 1 }; Remove-Item -LiteralPath $env:OC_LOCK -Recurse -Force; exit 0 }catch{ exit 0 }" >nul 2>&1
if not errorlevel 1 goto :lk_take
call echo %T_256%
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
call echo %T_257%
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
call echo %T_258%
goto :su_delete
:su_same
call echo %T_259%
goto :su_delete
:su_new
call echo %T_260%
call :yn_upd "   Replace this launcher with %SU_RV%? [Y/N]: "
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
call echo %T_261%
call :trace upd_launch
start "" "%SU_HELP%" "%SU_TMP%" "%~f0"
REM Exit now: nothing here is read after the file is replaced.
timeout /t 2 /nobreak >nul 2>&1
exit
:su_fail
call echo %T_262%
call echo %T_263%
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
call echo %T_264%
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
$ShimOcPath = Join-Path $ShimDir 'opencodeoc.cmd'
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
  S 'TARGET_TRIES' 'Rotation' 'Max attempts per hunt' 'int' 1 'New IPs requested in one hunt. The hunt stops at this count.' 'now' 1 100
  S 'TARGET_MINUTES' 'Rotation' 'Max minutes per hunt' 'int' 15 'The hunt stops after this many minutes.' 'now' 1 240
  S 'TARGET_INTERVAL' 'Rotation' 'Seconds between attempts' 'int' 15 'Pause between two attempts, so Cloudflare is not hit too fast.' 'now' 0 300
  S 'WATCH' 'Watcher' 'Watch the log' 'bool' 1 'Rotate when a fatal error appears while opencode runs.' 'now'
  S 'RESUME_MSG' 'Watcher' 'Resume message' 'string' 'continue' 'Sent automatically after a rotation.' 'now'
  S 'RESUME_AUTO' 'Watcher' 'Unattended resume' 'bool' 1 'The resume auto-approves tool permissions.' 'now'
  S 'RESUME_TIMEOUT' 'Watcher' 'Resume timeout (s)' 'int' 90 'Seconds before a silent resume counts as a dead IP.' 'now' 10 900
  S 'PROBE' 'Probe' 'Test every new IP' 'bool' 1 'Send one cheap message through each candidate IP.' 'now'
  S 'PROBE_MODEL' 'Probe' 'Probe model' 'string' 'opencode/big-pickle' 'Model used by the IP probe.' 'now'
  S 'PROBE_BROKEN_MAX' 'Probe' 'Probe failures tolerated' 'int' 3 'Non-limit probe failures before the hunt stops.' 'now' 1 50
  S 'OC_APP' 'Paths' 'Desktop app path' 'path' '' 'Full path of OpenCode.exe. Empty = search automatically.' 'now'
  S 'OC_API_BASE' 'Paths' 'Release metadata URL' 'url' 'https://opencode.ai/update/api/latest' 'Where versions and checksums are read from.' 'now'
  S 'WHERE_TIMEOUT' 'Paths' 'PATH lookup timeout (s)' 'int' 5 'Seconds a single "where" lookup may take.' 'now' 1 120
  S 'UPDATE_CHECK' 'Updates' 'Launcher self-update' 'bool' 1 'Check GitHub for a newer launcher at every start.' 'next launch'
  S 'UPDATE_ASK' 'Updates' 'Update prompts' 'enum' 'ask' 'ask = offer newer versions at start (launcher, opencode, desktop app). never = no update checks and no prompts.' 'now' 0 0 @('ask', 'never')
  S 'OCUI_THEME' 'Appearance' 'Color theme' 'enum' 'ocean' 'Accent colors of the interface.' 'now' 0 0 @('ocean', 'forest', 'sunset', 'mono', 'rainbow')
  S 'OCUI_COLOR' 'Appearance' 'Colors' 'enum' 'auto' 'auto follows the terminal and NO_COLOR; off disables colors.' 'now' 0 0 @('auto', 'on', 'off')
  S 'OCUI_ICONS' 'Appearance' 'Icons and borders' 'enum' 'auto' 'emoji = modern terminals, unicode = classic console, ascii = anything.' 'now' 0 0 @('auto', 'emoji', 'unicode', 'ascii')
  S 'OCUI_LANG' 'Appearance' 'Language' 'enum' 'auto' 'Language of the menus and descriptions. auto follows Windows. Logs and the support report stay in English.' 'now' 0 0 @('auto', 'en', 'es', 'fr', 'de', 'pt', 'it', 'tr')
  S 'OCUI_FONT' 'Appearance' 'Terminal font' 'font' '' 'Font of the terminal text. Empty leaves the terminal as it is.' 'now'
  S 'OCUI_FONT_SIZE' 'Appearance' 'Font size' 'int' 16 'Size used with the chosen font.' 'now' 8 72
  S 'KEY_ROTATE' 'Shortcuts' 'Rotate key' 'key' 'R' 'Closed-opencode prompt: new IP and resume the chat.' 'now'
  S 'KEY_MENU' 'Shortcuts' 'Menu key' 'key' 'M' 'Closed-opencode prompt: open the menu.' 'now'
  S 'KEY_QUIT' 'Shortcuts' 'Quit key' 'key' 'Q' 'Closed-opencode prompt: quit. Ctrl+C always quits too.' 'now'
  S 'LOG_ENABLED' 'Support' 'Activity log' 'bool' 1 'Record what the launcher does in launcher.log so a problem can be diagnosed.' 'now'
  S 'LOG_MAX_KB' 'Support' 'Log size limit (KB)' 'int' 1024 'The log is cut to its newest part when it grows past this.' 'next launch' 64 10240
  S 'LOG_MASK_IP' 'Support' 'Hide IPs in reports' 'bool' 1 'Public IP addresses are masked in the support report.' 'now'
)
$Groups = @('Connection', 'Proxy list', 'Tor', 'Rotation', 'Watcher', 'Probe', 'Paths', 'Updates', 'Appearance', 'Shortcuts', 'Support')
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
  'Shortcuts' = 'The keys of the launcher and the terminal commands. Fixed keys are listed for reference; the three letters can be changed.'
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
    'key' {
      if ($t -notmatch '^[A-Za-z]$') { return Fail 'One letter, like R.' }
      $u = $t.ToUpper()
      if (-not $loading) { foreach ($o in @('KEY_ROTATE', 'KEY_MENU', 'KEY_QUIT')) { if ($o -ne $s.Key -and ([string](Get-Val $o)).ToUpper() -eq $u) { return Fail (Tf 'Key {0} is already used by {1}.' $u (T (Get-Setting $o).Label)) } } }
      return Pass $u
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
  rainbow = @{ Title = '1'; Accent = '36'; Sel = '30;46'; Border = '35'; Panel = ''; Rainbow = $true }
}
# rainbow: the phase moves a little every frame, so the colors flow like LEDs (see Anim-Key)
$script:RainPhase = 0
function Hue-Rgb([double]$h) {
  $h = (($h % 360) + 360) % 360; $x = 1 - [Math]::Abs((($h / 60) % 2) - 1)
  switch ([int][Math]::Floor($h / 60)) { 0 { $r = 1; $g = $x; $b = 0 } 1 { $r = $x; $g = 1; $b = 0 } 2 { $r = 0; $g = 1; $b = $x } 3 { $r = 0; $g = $x; $b = 1 } 4 { $r = $x; $g = 0; $b = 1 } default { $r = 1; $g = 0; $b = $x } }
  return ('{0};{1};{2}' -f [int]($r * 255), [int]($g * 255), [int]($b * 255))
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
function Strip-Icon([string]$s) {
  foreach ($ic in $script:IconList) { if ($ic -and $s.StartsWith($ic + ' ')) { return $s.Substring($ic.Length + 1) } }
  return $s
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
# rainbow theme: each letter takes the next hue of a moving gradient, spaces are left alone
function Rainbow([string]$t) {
  $o = ''; $i = 0
  foreach ($c in $t.ToCharArray()) { if ($c -eq ' ') { $o += ' ' } else { $o += $esc + '[38;2;' + (Hue-Rgb ($script:RainPhase * 8 + $i * 28)) + 'm' + $c; $i++ } }
  return $o + $esc + '[0m'
}
# the selected row and the borders take one moving hue (rainbow only)
function SelStyle { if ($script:Theme.Rainbow) { return '30;48;2;' + (Hue-Rgb ($script:RainPhase * 8 + 180)) } return $script:Theme.Sel }
function P($style, [string]$t) {
  if ($script:Color -and $style -eq 'rainbow') { return Rainbow $t }
  if ($script:Color -and $style) { return $esc + '[' + $style + 'm' + $t + $esc + '[0m' } return $t
}
function Style($name) {
  switch ($name) { 'ok' { '32' } 'err' { '31' } 'warn' { '33' } 'title' { if ($script:Theme.Rainbow) { 'rainbow' } else { $script:Theme.Title } } 'accent' { if ($script:Theme.Rainbow) { 'rainbow' } else { $script:Theme.Accent } }'dim' { '90' } 'border' { if ($script:Theme.Rainbow) { '38;2;' + (Hue-Rgb ($script:RainPhase * 8)) } else { $script:Theme.Border } } default { '' } }
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
function Disp-W([string]$s) {
  $w = 0
  for ($i = 0; $i -lt $s.Length; $i++) {
    $c = [int]$s[$i]
    if ($c -ge 0xD800 -and $c -le 0xDBFF) { $w += 2; $i++ } elseif ($c -eq 0xFE0F -or ($c -ge 0x0300 -and $c -le 0x036F)) { } else { $w++ }
  }
  return $w
}
function Pad([string]$s, [int]$n) { if ($s.Length -ge $n) { return $s.Substring(0, $n) } return $s + (' ' * [Math]::Max(0, $n - (Disp-W $s))) }
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
  $pad = 0
  $lead = ' ' * $pad
  $out = @()
  for ($r = 0; $r -lt $art.Count; $r++) { $out += (P $styles[$r % $styles.Count] ($lead + $art[$r])) }
  $out += (P (Style 'accent') ($lead + $Repo))
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
  # Esc gives '<' (back), the same as in a menu. Enter ends the line.
  $sb = New-Object Text.StringBuilder
  while ($true) {
    $ki = [Console]::ReadKey($true)
    if ($ki.Key -eq 'Enter') { WL ''; return $sb.ToString() }
    if ($ki.Key -eq 'Escape') { WL ''; return '<' }
    if ($ki.Key -eq 'C' -and ($ki.Modifiers -band [ConsoleModifiers]::Control)) { throw 'ctrl-c' }
    if ($ki.Key -eq 'Backspace') { if ($sb.Length) { $sb.Length = $sb.Length - 1; W "`b `b" }; continue }
    if ($ki.KeyChar -ge ' ') { [void]$sb.Append($ki.KeyChar); W ([string]$ki.KeyChar) }
  }
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
  $top = -1; $frame = -1
  while ($true) {
    $buf = New-Object 'Collections.Generic.List[string]'
    $fullVal = ''
    if ($banner) { foreach ($b in (Get-Banner)) { $buf.Add($b) }; $buf.Add('') }
    if ($head) { foreach ($h in $head) { $buf.Add([string]$h) } }
    $buf.Add((Box-Top (T (Strip-Icon $title))))
    $in = $script:Width - 4
    for ($n = 0; $n -lt $items.Count; $n++) {
      $it = $items[$n]
      $num = ([string]($n + 1) + '.').PadRight(3)
      $mark = if ($n -eq $i) { '>' } else { ' ' }
      $lab = $mark + ' ' + $num + ' ' + (T (Strip-Icon ([string]$it.L)))
      $val = T ([string]$it.V)
      $room = $in - $lab.Length - 1
      if ($val.Length -gt $room - 1) { if ($n -eq $i) { $fullVal = $val }; $val = $val.Substring(0, [Math]::Max(0, $room - 2)) + '..' }
      $gap = ' ' * [Math]::Max(1, $in - (Disp-W $lab) - (Disp-W $val))
      if ($n -eq $i) {
        $buf.Add((Panel ((P (Style 'border') $script:I.v) + ' ' + (P (SelStyle) (Pad ($lab + $gap + $val) $in)) + ' ' + (P (Style 'border') $script:I.v))))
      } else {
        $st = if ($it.D) { Style 'dim' } else { '' }
        $vs = if ($it.S) { Style $it.S } else { Style 'accent' }
        $pad = ' ' * [Math]::Max(0, $in - (Disp-W $lab) - $gap.Length - (Disp-W $val))
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
    $buf.Add((P (Style 'dim') (Pad ('arrows' + (T ' move   Enter select   Esc back   1-9 or letter jump')) ($script:Width - 1))))
    foreach ($f in @($footer)) { if ($f) { foreach ($fl in (Wrap-Text (T ([string]$f)) ($script:Width - 1) 3)) { $buf.Add((Panel (P (Style 'dim') (Pad $fl ($script:Width - 1))))) } } }
    # rainbow redraws in place, one frame per color step; the other themes draw once per key
    $anim = [bool]($script:Theme.Rainbow -and $script:Color -and -not $Scripted)
    if ($anim -and $frame -ge 0) { try { [Console]::SetCursorPosition(0, $frame) } catch { } }
    elseif ($inline) {
      # drawn under the text already on screen and redrawn in place
      if ($top -ge 0) { try { [Console]::SetCursorPosition(0, $top) } catch { } }
    } else { Clear-Screen }
    if ($anim -and $frame -lt 0) { try { $frame = [Console]::CursorTop } catch { $frame = -1 } }
    if ($script:VPad -and -not $inline) {
      $vp = [Math]::Max(0, [int](($script:TermH - $buf.Count - 1) / 2))
      for ($q = 0; $q -lt $vp; $q++) { WL '' }
    }
    $eol = if ($anim) { $esc + '[K' } else { '' }
    foreach ($line in $buf) { WL ($line + $eol) }
    if ($anim) { W ($esc + '[J') }
    if ($inline) { try { $top = [Math]::Max(0, [Console]::CursorTop - $buf.Count) } catch { $top = -1 } }
    if ($anim) { $k = Anim-Key } else { $k = Get-Key }
    if ($null -eq $k) { continue }
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
# rainbow wait: about 90 ms per frame; no key in that time advances the colors and returns nothing
function Anim-Key {
  $dl = (Get-Date).AddMilliseconds(90)
  while ((Get-Date) -lt $dl) { if ([Console]::KeyAvailable) { return Get-Key }; Start-Sleep -Milliseconds 15 }
  $script:RainPhase++
  return $null
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
      if ($t -eq '' -or $t -eq '<') { return $null }
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
# keeps the face of an existing font entry when only the size is changed
function Merge-FontFace($block, [string]$existing) {
  if (-not $block -or $block -match '"face"' -or $existing -notmatch '"face"\s*:\s*"[^"]*"') { return $block }
  return ($block -replace '^"font"\s*:\s*\{\s*', ('"font": { ' + [regex]::Match($existing, '"face"\s*:\s*"[^"]*"').Value + ', '))
}
# The font of the profile this tab runs (WT_PROFILE_ID). A profile's own font wins over profiles.defaults.
# Returns @(text, prior font text) or $null when that profile is not in profiles.list.
function Set-ProfFont([string]$text, [string]$guid, $block) {
  $gm = [regex]::Match($text, '"guid"\s*:\s*"' + [regex]::Escape($guid) + '"', 'IgnoreCase')
  if (-not $gm.Success) { return $null }
  $open = -1; $depth = 0
  for ($i = $gm.Index; $i -ge 0 -and $open -lt 0; $i--) {
    if ($text[$i] -eq '}') { $depth++ } elseif ($text[$i] -eq '{') { if ($depth -eq 0) { $open = $i } else { $depth-- } }
  }
  if ($open -lt 0) { return $null }
  $close = -1; $depth = 0
  for ($i = $open; $i -lt $text.Length -and $close -lt 0; $i++) {
    if ($text[$i] -eq '{') { $depth++ } elseif ($text[$i] -eq '}') { $depth--; if ($depth -eq 0) { $close = $i } }
  }
  if ($close -lt 0) { return $null }
  $obj = $text.Substring($open, $close - $open + 1)
  $fontRe = '"font"\s*:\s*\{[^{}]*\}'
  $fm = [regex]::Match($obj, $fontRe)
  $prior = ''
  if ($fm.Success) {
    $prior = $fm.Value
    if ($block) { $obj = $obj.Remove($fm.Index, $fm.Length).Insert($fm.Index, (Merge-FontFace $block $prior)) }
    elseif ($obj -match (',\s*' + $fontRe)) { $obj = [regex]::Replace($obj, ',\s*' + $fontRe, '', 'None', 1) }
    else { $obj = [regex]::Replace($obj, $fontRe + '\s*,?', '', 'None', 1) }
  } elseif ($block) {
    $obj = '{' + "`r`n            " + $block + ',' + $obj.Substring(1)
  }
  return @(($text.Substring(0, $open) + $obj + $text.Substring($close + 1)), $prior)
}
function Edit-WtFile([string]$path, $block, [bool]$pTouch = $false, $pblock = $null) {
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
    $block = Merge-FontFace $block $prior
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
  $script:ProfFound = $false; $script:ProfPrior = ''
  if ($pTouch -and $env:WT_PROFILE_ID) {
    $pr = Set-ProfFont $new $env:WT_PROFILE_ID $pblock
    if ($pr) { $new = $pr[0]; $script:ProfFound = $true; $script:ProfPrior = $pr[1] }
  }
  if ($new -eq $text) { return $prior }
  # the result must still be valid and must say what we meant
  try {
    $j = (Strip-Jsonc $new) | ConvertFrom-Json
    $got = $j.profiles.defaults.font
    if ($block) { if (-not $got) { return $false } } elseif ($got -and -not $prior) { return $false }
    if ($script:ProfFound -and $pblock) { $pp = @($j.profiles.list | Where-Object { $_.guid -eq $env:WT_PROFILE_ID }); if ($pp.Count -and -not $pp[0].font) { return $false } }
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
    $restore = (-not $face) -and $script:Cfg.font.wt.ContainsKey($key) -and [bool]$script:Cfg.font.wt[$key].face
    $entry = $null
    if ($face) { $entry = '"font": { "face": "' + $face + '", "size": ' + $size + ' }' }
    elseif ($restore) { $entry = [string]$script:Cfg.font.wt[$key].prior; if (-not $entry) { $entry = $null } }
    else { $entry = '"font": { "size": ' + $size + ' }' }
    New-Item -ItemType Directory -Force -Path $BackDir | Out-Null
    $bk = Join-Path $BackDir ('wt-settings-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + $done + '.json')
    Copy-Item -LiteralPath $p -Destination $bk -Force
    $pentry = $entry
    if ($restore) { $pentry = [string]$script:Cfg.font.wt[$key].pprior; if (-not $pentry) { $pentry = $null } }
    $ptouch = if ($restore) { [bool]$script:Cfg.font.wt[$key].ptouched } else { $true }
    $prior = Edit-WtFile $p $entry $ptouch $pentry
    if ($prior -is [bool] -and -not $prior) { Remove-Item -LiteralPath $bk -Force -ErrorAction SilentlyContinue; return @('err', 'settings.json was left untouched: the edit would not have kept it valid.') }
    if ($restore) { [void]$script:Cfg.font.wt.Remove($key) }
    else {
      if (-not $script:Cfg.font.wt.ContainsKey($key)) { $script:Cfg.font.wt[$key] = @{ prior = [string]$prior; backup = $bk; ptouched = [bool]$script:ProfFound; pprior = [string]$script:ProfPrior } }
      $script:Cfg.font.wt[$key].face = $face
    }
    $done++
  }
  Save-Cfg
  if (-not $face -and $paths.Count -gt 0 -and $done -gt 0 -and -not $script:Cfg.font.wt.Count) { return @('ok', 'Windows Terminal font put back as it was. Reopen the tab if it does not change.') }
  if (-not $face) { return @('ok', (Tf 'Windows Terminal font size set to {0}. Reopen the tab if it does not change.' $size)) }
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
  } elseif ($script:Cfg.font.ContainsKey('orig')) { $face = [string]$script:Cfg.font.orig.face }
  else { $face = [string]$cfi.FaceName }
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
  if ($s.Key -eq 'OCUI_LANG') {
    # a list to pick from; Init-Ui then loads only the chosen language
    $codes = @('auto') + @($Langs)
    $items = @()
    foreach ($c in $codes) { $items += @{ L = (Lang-Name $c); V = $(if ($c -eq [string]$cur) { '*' } else { '' }); H = $(if ($c -eq 'auto') { 'Follow the language Windows uses.' } else { 'Use this language for every menu and message.' }) } }
    $items += @{ L = ($script:I.back + ' Back'); H = 'Keep the current language.' }
    $r = Show-Menu 'Language' $items 'Only the chosen language is downloaded from the langs folder of the repository.' $null ([Array]::IndexOf($codes, [string]$cur))
    if ($r -lt 0 -or $r -ge $codes.Count) { return $null }
    $new = $codes[$r]
    if ($new -eq [string]$cur) { return $null }
  }
  elseif ($s.Type -eq 'bool') { $new = if ([int]$cur -eq 1) { 0 } else { 1 } }
  elseif ($s.Type -eq 'enum') {
    $ix = [Array]::IndexOf(@($s.Values), $cur)
    $new = $s.Values[($ix + 1) % $s.Values.Count]
  } elseif ($s.Type -eq 'font') {
    $new = Pick-Font
    if ($null -eq $new) { return $null }
  } else {
    while ($true) {
      $t = Read-Text ((T $s.Label) + ' - ' + (T $s.Help)) ([string]$cur)
      if ($t -eq '<') { return $null }
      if ($t -eq '' -and $s.Type -ne 'path') { return $null }
      if ($t -eq '-' -and $s.Type -eq 'path') { $t = '' }
      $r = Test-Val $s $t
      if ($r.ok) { $new = $r.v; break }
      Say 'err' $r.err
    }
  }
  Set-Val $s $new
  Log ('setting ' + $s.Key + ' -> ' + (Safe-Val $s.Key))
  if ($s.Key -eq 'OCUI_LANG') { Init-Ui; Write-I18n }
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
# Fixed keys and terminal commands: listed under the Shortcuts group, dimmed, never selected.
function Shortcut-Info {
  @(
    @{ L = 'Esc'; V = 'back to the previous screen'; D = $true; H = 'Fixed. In a menu or a text prompt Esc goes back; it never closes the launcher.' },
    @{ L = 'Enter, arrows'; V = 'select and move'; D = $true; H = 'Fixed. Digits 1-9 jump straight to a row.' },
    @{ L = 'Ctrl+C'; V = 'quit the launcher'; D = $true; H = 'Fixed. Stops the processes it started and leaves the terminal open, no Y/N question.' },
    @{ L = 'opencode'; V = 'start with the connection'; D = $true; H = 'Terminal command from any folder. The Start menu shortcut does the same.' },
    @{ L = 'opencodeinf'; V = 'open this menu'; D = $true; H = 'Terminal command: opens the launcher menu again, as many times as you need.' },
    @{ L = 'opencodeoc'; V = 'original OpenCode'; D = $true; H = 'Terminal command: starts the OpenCode you installed, without the launcher or the connection. Use it when the launcher breaks.' }
  )
}
function Group-Menu([string]$group) {
  $list = @($Schema | Where-Object { $_.Group -eq $group })
  $pos = 0; $msg = $null
  while ($true) {
    $items = @()
    foreach ($s in $list) {
      $items += @{ L = $s.Label; V = (Format-Val $s); S = $(if ($script:Cfg.settings.ContainsKey($s.Key)) { 'warn' } else { 'accent' }); H = (Describe-Setting $s) }
    }
    if ($group -eq 'Shortcuts') { $items += Shortcut-Info }
    $backAt = $items.Count
    $items += @{ L = ($script:I.back + ' Back'); H = 'Return to the settings groups.' }
    $head = @(); if ($msg) { $head += $msg; $head += '' }
    $r = Show-Menu ((T 'Settings') + ' - ' + (T $group)) $items 'Changed values are yellow. Enter edits or toggles the selected value.' $head $pos
    if ($r -eq -1 -or $r -eq $backAt) { return }
    $pos = $r
    if ($r -ge $list.Count) { continue }
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
# Export: the changed settings only, as one JSON file. Import: every value is checked first, and
# one wrong value stops the whole import, so the settings are never half changed.
function Export-Settings {
  $def = Join-Path ([Environment]::GetFolderPath('Desktop')) 'opencode-infinite-settings.json'
  $t = Read-Text (T 'File to write (Enter = Desktop, Esc = back)') $def
  if ($t -eq '<') { return }
  if ($t -eq '') { $t = $def }
  if ($t -notmatch '\.json$') { $t += '.json' }
  $dir = Split-Path -Parent $t
  if (-not $dir -or -not (Test-Path -LiteralPath $dir -PathType Container)) { Say 'err' (T 'That folder does not exist.'); Wait-Key; return }
  if ((Test-Path -LiteralPath $t) -and -not (Confirm-Box 'Replace the file that is already there?' @($t))) { return }
  $obj = [ordered]@{ format = 'opencode-infinite-settings'; version = 1; settings = [ordered]@{} }
  foreach ($s in $Schema) { if ($script:Cfg.settings.ContainsKey($s.Key)) { $obj.settings[$s.Key] = [string]$script:Cfg.settings[$s.Key] } }
  [IO.File]::WriteAllText($t, ($obj | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false)))
  Log ('settings exported: ' + $obj.settings.Count + ' changed')
  Say 'ok' (Tf 'Exported {0} changed setting(s) to {1}' $obj.settings.Count $t)
  Wait-Key
}
function Import-Settings {
  $t = Read-Text (T 'File to read (Esc = back)') ''
  if ($t -eq '<' -or $t -eq '') { return }
  if (-not (Test-Path -LiteralPath $t -PathType Leaf)) { Say 'err' (T 'No file at that path.'); Wait-Key; return }
  $j = $null
  try { $j = Get-Content -LiteralPath $t -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
  if (-not $j -or $j.format -ne 'opencode-infinite-settings' -or -not $j.settings) { Say 'err' (T 'This is not an OpenCode Infinite settings file.'); Wait-Key; return }
  $take = @{}; $bad = @(); $skip = 0
  foreach ($p in $j.settings.PSObject.Properties) {
    $s = Get-Setting $p.Name
    if (-not $s) { $skip++; continue }
    $r = Test-Val $s ([string]$p.Value)
    if ($r.ok) { $take[$p.Name] = $r.v } else { $bad += ($p.Name + ': ' + $r.err) }
  }
  if ($bad.Count) {
    Say 'err' (T 'Nothing was imported. These values are not valid:')
    foreach ($x in $bad) { WL (P (Style 'dim') ('   ' + $x)) }
    Wait-Key; return
  }
  $extra = @(); if ($skip) { $extra = @(Tf '{0} setting(s) of this file are unknown here and are skipped.' $skip) }
  if (-not (Confirm-Box (Tf 'Import {0} setting(s)? Their current values are replaced.' $take.Count) $extra)) { return }
  foreach ($k in $take.Keys) { Set-Val (Get-Setting $k) $take[$k] }
  Init-Ui
  if ($take.ContainsKey('OCUI_FONT') -or $take.ContainsKey('OCUI_FONT_SIZE')) { [void](Apply-Font) }
  Log ('settings imported: ' + $take.Count + ' from ' + $t)
  Say 'ok' (Tf 'Imported {0} setting(s).' $take.Count)
  Wait-Key
}
function Settings-Menu {
  $pos = 0
  while ($true) {
    $items = @()
    foreach ($g in $Groups) {
      $n = @($Schema | Where-Object { $_.Group -eq $g -and $script:Cfg.settings.ContainsKey($_.Key) }).Count
      $items += @{ L = $g; V = $(if ($n) { Tf '{0} changed' $n } else { '' }); S = 'warn'; H = $GroupHelp[$g] }
    }
    $items += @{ L = 'Export settings to a file'; H = 'Save every changed setting to one .json file, to keep a backup or copy them to another PC.' }
    $items += @{ L = 'Import settings from a file'; H = 'Load a file made by Export. Every value is checked first; if one is wrong, nothing changes.' }
    $items += @{ L = 'Reset to default values'; S = 'err'; H = 'Put every setting back to its default. Your connection setup (command, shortcuts) is not touched. Asks first.' }
    $items += @{ L = ($script:I.back + ' Back'); H = 'Return to the main menu.' }
    $iExp = $Groups.Count; $iImp = $iExp + 1; $iRes = $iExp + 2; $iBack = $iExp + 3
    $r = Show-Menu ($script:I.gear + ' ' + (T 'Settings')) $items (Tf 'Every change is saved at once to {0}' $CfgPath) $null $pos
    if ($r -eq -1 -or $r -eq $iBack) { return }
    $pos = $r
    if ($r -eq $iExp) { Export-Settings; continue }
    if ($r -eq $iImp) { Import-Settings; continue }
    if ($r -eq $iRes) {
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
# The OpenCode that was installed before the launcher: the first opencode on PATH outside the launcher's folder.
function Find-Original-Oc {
  $c = @(Get-Command opencode -All -ErrorAction SilentlyContinue | Where-Object { $_.Source -match '\.(exe|cmd)$' -and -not $_.Source.StartsWith($ShimDir, [StringComparison]::OrdinalIgnoreCase) })
  if ($c.Count) { return [string]$c[0].Source }
  return ''
}
function Shim-Original([string]$exe) {
  if (-not $exe) { return "@echo off`r`necho OpenCode was not found outside the launcher. Install it, then run Connect with opencode again.`r`nexit /b 1`r`n" }
  return "@echo off`r`nrem Original OpenCode: no launcher and no connection change.`r`n`"$exe`" %*`r`nexit /b %errorlevel%`r`n"
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
      $opts = @(@{ L = 'CLI'; V = 'terminal'; m = 'CLI'; H = 'The terminal interface. The opencode command and the shortcut open it.' }, @{ L = 'Desktop'; V = 'OpenCode app'; m = 'DESKTOP'; H = 'The OpenCode desktop app; it is restarted after every new IP.' }, @{ L = 'Ask every time'; V = ''; m = 'ASK'; H = 'Show the CLI or Desktop choice every time the launcher opens.' })
      $r = Show-Menu 'Setup 3/3 - run mode' ($opts + @(@{ L = ($script:I.back + ' Back'); H = 'Return to the connection details.' })) 'The opencode command and the shortcut open this mode. Ask every time uses the CLI there. Change it later in Settings, Connection.'
      if ($r -eq -1 -or $r -eq 3) { $step = 1; continue }
      $ans['OC_MODE_DEFAULT'] = $opts[$r].m
      $step = 3; continue
    }
    if ($step -eq 3) {
      $head = @((P (Style 'title') (T 'Review')), '')
      foreach ($k in $ans.Keys) { $head += ('   ' + (Pad (T (Get-Setting $k).Label) 26) + ' ' + (P (Style 'accent') ([string]$ans[$k]))) }
      $head += ''
      $head += (P (Style 'dim') ('   ' + (T 'Adds: the opencode, opencodeinf and opencodeoc commands, two shortcuts, one PATH entry. Backups are kept.')))
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
    [IO.File]::WriteAllText($ShimOcPath, (Shim-Original (Find-Original-Oc)), $utf8)
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
    $script:Cfg.setup = @{ done = $true; method = $method; launcher = $Official; shim = $ShimPath; shimInf = $ShimInfPath; shimOc = $ShimOcPath; shortcuts = $made; pathAdded = $pathAdded; touched = $touched; createdUtc = (Get-Date).ToUniversalTime().ToString('o'); verified = $false }
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
  $head += ('   ' + (Pad (T 'Commands') 14) + (P (Style 'accent') 'opencode, opencodeinf, opencodeoc'))
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
    if (Test-Path -LiteralPath $ShimOcPath) { Remove-Item -LiteralPath $ShimOcPath -Force }
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
  # 4 = the Exit row, 5 = Esc (back to the previous screen; never a quit)
  if ($r -eq -1) { exit 5 }
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
  $r = Show-Menu 'Choose the connection for OpenCode' $items $null $head 0
  if ($r -eq -1) { exit 5 }
  exit ($r + 1)
}
function Menu-Main {
  # C = the exit code the batch dispatches on. Esc and "Back" are 10 (back to the home screen).
  $items = @(
    @{ L = 'New IP and start OpenCode'; V = 'new IP'; C = 1; H = 'Get a new IP or proxy, then open OpenCode. Your chats and history stay untouched.' },
    @{ L = 'Clear tokens and cache, then start'; V = 'keeps chats'; S = 'warn'; C = 7; H = 'Kill opencode, save the login file to the Desktop, clear the cache, then open OpenCode. Chats stay where they are.' },
    @{ L = 'Change IP (test)'; C = 3; H = 'Rotate the connection only, without opening OpenCode.' },
    @{ L = 'Deep reset or restore chats'; V = 'submenu'; C = 4; H = 'Deep reset moves your chats to the Desktop and clears tokens and cache. Restore brings chats back from an earlier reset.' },
    @{ L = 'Mode (CLI or Desktop)'; C = 9; H = 'Switch between the terminal and the desktop app.' },
    @{ L = ($script:I.back + ' Back'); C = 10; H = 'Return to the home screen.' },
    @{ L = ($script:I.err + ' Exit'); C = 6; H = 'Close the launcher.' })
  $head = Header-Lines
  $r = Show-Menu 'OpenCode' $items ('v2.34   ' + $Repo) $head 0
  if ($r -eq -1) { exit 10 }
  exit $items[$r].C
}
# Deep reset or restore chats. 1 = deep reset, 2 = restore, 10 = back.
function Menu-Deep {
  $items = @(
    @{ L = 'Deep reset'; V = 'asks first'; S = 'err'; H = 'Move your chats to the Desktop archive, clear tokens and cache, then start fresh.' },
    @{ L = 'Restore chats'; V = 'from the Desktop'; H = 'Bring chats back from an earlier deep reset.' },
    @{ L = ($script:I.back + ' Back'); H = 'Return to the main menu.' })
  $r = Show-Menu 'Deep reset or restore chats' $items $null (Header-Lines) 0
  if ($r -eq 0) { exit 1 }
  if ($r -eq 1) { exit 2 }
  exit 10
}
# Pick an archived backup (one folder per deep reset). Exit 1 = picked, its path is in restore_pick.txt; 10 = back.
function Menu-Restore {
  $root = [string]$env:OC_ARCH
  $pick = Join-Path ([string]$env:OC_STATE) 'restore_pick.txt'
  $dirs = @()
  if ($root -and (Test-Path -LiteralPath $root)) { $dirs = @(Get-ChildItem -LiteralPath $root -Directory | Sort-Object Name -Descending) }
  $items = @()
  foreach ($d in $dirs) {
    $n = @(Get-ChildItem -LiteralPath $d.FullName -Recurse -File -ErrorAction SilentlyContinue).Count
    $items += @{ L = $d.Name; V = $(if ($n -eq 1) { Tf '{0} file' $n } else { Tf '{0} files' $n }); H = $d.FullName }
  }
  $items += @{ L = ($script:I.back + ' Back'); H = 'Return to the deep reset menu.' }
  $head = Header-Lines
  if ($dirs.Count -eq 0) { $head = @((P (Style 'warn') (T 'No archived chats yet. A deep reset creates one on the Desktop.')), '') + $head }
  $r = Show-Menu 'Restore chats from a backup' $items $null $head 0
  if ($r -lt 0 -or $r -ge $dirs.Count) { exit 10 }
  [IO.File]::WriteAllText($pick, [string]$dirs[$r].FullName)
  exit 1
}
# Sessions of the folder the batch is working in (its cwd). Exit 1 = a session was
# picked and its id is in session_pick.txt; 0 = back.
function Menu-Sessions {
  $pick = Join-Path ([string]$env:OC_STATE) 'session_pick.txt'
  $exe = [string]$env:OC_CMD; if (-not $exe) { $exe = 'opencode' }
  $head = Header-Lines; $msg = $null; $list = @()
  if ($env:OC_H_MODE -eq 'DESKTOP') { $msg = T 'The desktop app has no session list. Switch to CLI to pick a chat.' }
  else {
    $raw = (& $exe session list --format json -n 30 2>&1 | Out-String).Trim()
    try { $parsed = ConvertFrom-Json -InputObject $raw; $list = @($parsed | Where-Object { $_ -and $_.id }) } catch { $msg = Tf 'Could not read the sessions: {0}' $raw }
    if (-not $msg -and $list.Count -eq 0) { $msg = T 'No sessions in this folder yet.' }
  }
  $items = @()
  foreach ($x in $list) {
    $t = if ($x.title) { [string]$x.title } else { T 'Untitled session' }
    $when = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$x.updated).LocalDateTime.ToString('yyyy-MM-dd HH:mm')
    $items += @{ L = $t; V = $when; H = [string]$x.id }
  }
  $items += @{ L = ($script:I.back + ' Back'); H = 'Return to the main menu.' }
  if ($msg) { $head = @((P (Style 'warn') $msg), '') + $head }
  $r = Show-Menu (T 'Sessions in this folder') $items $null $head 0
  if ($r -lt 0 -or $r -ge $list.Count) { exit 0 }
  [IO.File]::WriteAllText($pick, [string]$list[$r].id)
  exit 1
}
# Yes/No under the text already printed by the batch. Exit 1 = yes, 2 = no (what `choice /c yn` returned).
function Menu-Confirm {
  $q = T (([string]$env:OC_Q -replace '\s*\[Y/N\]:?\s*$', '').Trim())
  $head = @('', (P (Style 'warn') ($script:I.warn + ' ' + $q)))
  if ($env:OC_QT) { $script:KeyTimeout = [int]$env:OC_QT; $head += (P (Style 'dim') ('   ' + (Tf 'No answer in {0}s counts as No.' $env:OC_QT))) }
  $items = @(@{ L = 'Yes'; K = 'y'; S = 'warn'; H = 'Go ahead.' }, @{ L = 'No'; K = 'n'; H = 'Cancel. Nothing is changed.' })
  if ($env:OC_UPD) { $items += @{ L = 'No, never ask about updates'; H = 'Stop the update checks and prompts. Change it back in Settings, Updates.' } }
  $r = Show-Menu 'Confirm' $items $null $head 1 $false $true
  if ($r -eq 0) { exit 1 }
  if ($r -eq 2) { Set-Val (Get-Setting 'UPDATE_ASK') 'never'; exit 3 }
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
    $items += @{ L = ($script:I.gear + ' ' + (T 'Settings')); H = 'View and change every launcher option: connection, proxies, Tor, rotation, themes. Saved instantly, no files to edit.' }; $acts += 'settings'
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
    $r = Show-Menu 'Main menu' $items ('v2.34   ' + $Self) $head $pos $true
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
      'key' { $good = @{ KEY_ROTATE = 'J'; KEY_MENU = 'K'; KEY_QUIT = 'L' }[$s.Key]; $bad = 'zzz' }
    }
    $r = Test-Val $s $good
    $r2 = Test-Val $s $bad
    if ($r.ok -and -not $r2.ok) { Set-Val $s $r.v; [Console]::WriteLine('PASS ' + $s.Key + ' [' + $s.Type + '] ' + $good + ' (bad rejected: ' + $r2.err + ')') }
    else { $fails++; [Console]::WriteLine('FAIL ' + $s.Key + ' [' + $s.Type + '] good=' + $good + ' ok=' + $r.ok + ' bad=' + $bad + ' badOk=' + $r2.ok) }
  }
  return $fails
}

# ---------------------------------------------------------------- batch messages
# v2.31: the launcher's own echo lines read their text from i18n.cmd, one 'set "T_n=..."' per line,
# written here from the same language table as the menus. Values are escaped for cmd (% doubled,
# ^ before & | < > ( )); a message without a translation keeps its English default in the launcher.
function Write-I18n {
  $tmp = Join-Path $State 'i18n.cmd.tmp'
  $out = New-Object Collections.Generic.List[string]
  foreach ($l in [IO.File]::ReadAllLines($Self)) {
    if ($l -notmatch '^set "(T_\d+)=(.*)"$') { continue }
    $name = $Matches[1]; $raw = $Matches[2]
    $key = ($raw -replace '%%', '%') -replace '\^(.)', '$1'
    if ($script:Tr.ContainsKey($key)) {
      $v = ($script:Tr[$key] -replace '%', '%%') -replace '([\^&|<>()])', '^$1'
      $out.Add('set "' + $name + '=' + $v + '"')
    } else { $out.Add($l) }
  }
  New-Item -ItemType Directory -Force -Path $State | Out-Null
  [IO.File]::WriteAllLines($tmp, [string[]]$out, (New-Object Text.UTF8Encoding($false)))
  Move-Item -LiteralPath $tmp -Destination (Join-Path $State 'i18n.cmd') -Force
}

# ---------------------------------------------------------------- main
if ($Mode -eq 'probe') { if ([Console]::IsInputRedirected -and -not $Scripted) { exit 20 } else { exit 0 } }
if ($Mode -eq 'mki18n') { try { Load-Cfg; Init-Ui; Write-I18n; exit 0 } catch { exit 0 } }
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
    'sessions' { Menu-Sessions }
    'egress' { Menu-Egress }
    'main' { Menu-Main }
    'deep' { Menu-Deep }
    'restore' { Menu-Restore }
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
#>>>LANG de {" move   Enter select   Esc back   1-9 or letter jump":" bewegen   Enter w\u00e4hlen   Esc zur\u00fcck   1-9 oder Buchstabe zum Springen","(Enter = keep \"{0}\")":"(Enter = \"{0}\" behalten)","(auto)":"(auto)","(nothing saved yet)":"(noch nichts gespeichert)","(terminal default)":"(Standard des Terminals)","* = changed from the default. Enter edits or toggles the selected value.":"* = vom Standard abweichend. Enter bearbeitet oder schaltet den gew\u00e4hlten Wert um.","A downloaded list smaller than this is rejected. 0 = off.":"Eine heruntergeladene Liste, die kleiner ist, wird abgelehnt. 0 = aus.","A port is a number from 1 to 65535.":"Ein Port ist eine Zahl von 1 bis 65535.","A proxy must also reach the opencode API host.":"Ein Proxy muss auch den API-Server von opencode erreichen.","API check URL":"URL der API-Pr\u00fcfung","Accent colors of the interface.":"Akzentfarben der Oberfl\u00e4che.","Adding the command to your PATH":"Befehl wird zum PATH hinzugef\u00fcgt","Adds: opencode command (shim), two shortcuts, one PATH entry. Backups are kept.":"F\u00fcgt hinzu: den opencode-Befehl (Shim), zwei Verkn\u00fcpfungen und einen PATH-Eintrag. Sicherungen bleiben erhalten.","Any installed font name, for example Cascadia Code.":"Jeder Name einer installierten Schrift, zum Beispiel Cascadia Code.","Appearance":"Darstellung","Applies at the {0}.":"Gilt ab: {0}.","Apply":"Anwenden","Apply setup":"Einrichtung anwenden","Ask every time":"Jedes Mal fragen","Attempts per round when the tunnel is not up.":"Versuche pro Runde, wenn der Tunnel nicht steht.","Back":"Zur\u00fcck","Backing up the current configuration":"Aktuelle Konfiguration wird gesichert","Browse for a folder...":"Ordner durchsuchen...","Burned IPs allowed":"Erlaubte verbrannte IPs","Burned proxies before Tor offer":"Verbrannte Proxys vor dem Tor-Angebot","Burned proxies in a row before PROXY mode offers Tor.":"Verbrannte Proxys in Folge, bevor der PROXY-Modus Tor anbietet.","CLI terminal, Desktop app, or ask at every start.":"CLI im Terminal, Desktop-App oder bei jedem Start fragen.","Cancel":"Abbrechen","Cancel. Nothing is changed.":"Abbrechen. Nichts wird ge\u00e4ndert.","Change IP":"IP wechseln","Change an answer.":"Eine Antwort \u00e4ndern.","Change any launcher setting: connection, proxies, Tor, rotation, themes, font. Applied right away.":"\u00c4ndert jede Launcher-Einstellung: Verbindung, Proxys, Tor, Rotation, Designs, Schrift. Wird sofort angewendet.","Check GitHub for a newer launcher at every start.":"Sucht bei jedem Start auf GitHub nach einem neueren Launcher.","Check the API host":"API-Server pr\u00fcfen","Checking that it works":"Funktion wird gepr\u00fcft","Checking the connection":"Verbindung wird gepr\u00fcft","Choose \"Renew session\" below. It gets a new IP and clears the saved login;":"W\u00e4hle unten \"Sitzung erneuern\". Das holt eine neue IP und l\u00f6scht die gespeicherte Anmeldung;","Choose a folder to work in":"W\u00e4hle einen Arbeitsordner","Choose one of: {0}.":"W\u00e4hle einen von: {0}.","Choose the connection for OpenCode":"W\u00e4hle die Verbindung f\u00fcr OpenCode","Close the launcher.":"Den Launcher schlie\u00dfen.","Closes every running opencode process.":"Schlie\u00dft alle laufenden opencode-Prozesse.","Cloudflare WARP in local proxy mode. Every rotation asks for a new registration, which gives a new exit IP. Needs the WARP client (offered if missing).":"Cloudflare WARP im lokalen Proxy-Modus. Jede Rotation fordert eine neue Registrierung an, die eine neue Ausgangs-IP liefert. Ben\u00f6tigt den WARP-Client (wird angeboten, falls er fehlt).","Cloudflare WARP in proxy mode. A new registration gives a new exit IP. Rotation supported.":"Cloudflare WARP im Proxy-Modus. Eine neue Registrierung liefert eine neue Ausgangs-IP. Rotation wird unterst\u00fctzt.","Cloudflare throttles rapid registrations.":"Cloudflare drosselt schnell aufeinanderfolgende Registrierungen.","Collect system info, versions, settings and the recent log into one text file you can send for help. Passwords, tokens, your user name and (by default) IPs are removed first.":"Sammelt Systeminfos, Versionen, Einstellungen und das aktuelle Protokoll in einer Textdatei, die du f\u00fcr Hilfe senden kannst. Passw\u00f6rter, Tokens, dein Benutzername und (standardm\u00e4\u00dfig) IPs werden vorher entfernt.","Color theme":"Farbdesign","Color theme, colors on or off, icon and border style, and the terminal font. Applied immediately.":"Farbdesign, Farben an oder aus, Symbol- und Rahmenstil, Sprache und Terminal-Schrift. Wird sofort angewendet.","Colors":"Farben","Command":"Befehl","Configured - {0}":"Eingerichtet - {0}","Confirm":"Best\u00e4tigen","Connect with opencode":"Mit opencode verbinden","Connected: opencode now starts through {0}.":"Verbunden: opencode startet jetzt \u00fcber {0}.","Connecting opencode":"opencode wird verbunden","Connection":"Verbindung","Connection method":"Verbindungsmethode","Continue":"Fortsetzen","Continue WITHOUT the probe this session (IPs accepted untested)?":"In dieser Sitzung OHNE Test fortfahren (IPs ungepr\u00fcft akzeptiert)?","Continue anyway?":"Trotzdem fortfahren?","Continue direct?":"Direkt fortfahren?","Continue without WARP?":"Ohne WARP fortfahren?","Cooldown between attempts (s)":"Pause zwischen Versuchen (s)","Copies auth.json to your Desktop, then clears the saved tokens.":"Kopiert auth.json auf deinen Desktop und l\u00f6scht dann die gespeicherten Tokens.","Copy the file path":"Dateipfad kopieren","Creating shortcuts":"Verkn\u00fcpfungen werden erstellt","Creating the opencode command":"opencode-Befehl wird erstellt","Credentials inside a URL are not stored. Use a local file instead.":"Zugangsdaten in einer URL werden nicht gespeichert. Nutze stattdessen eine lokale Datei.","Deep reset":"Vollst\u00e4ndiger Reset","Default connection method and run mode, the WARP proxy port and the warp-cli timings.":"Standard-Verbindungsmethode und Ausf\u00fchrungsmodus, WARP-Proxy-Port und warp-cli-Zeiten.","Default: {0}.":"Standard: {0}.","Desktop":"Desktop","Desktop app":"Desktop-App","Desktop app location, release metadata URL and lookup timeouts.":"Ort der Desktop-App, URL der Versionsmetadaten und Suchzeiten.","Desktop app path":"Pfad der Desktop-App","Direct, no proxy":"Direkt, ohne Proxy","Do it now.":"Jetzt ausf\u00fchren.","Do that now?":"Jetzt ausf\u00fchren?","Download and install it now?":"Jetzt herunterladen und installieren?","Download the portable Tor bundle when nothing answers.":"L\u00e4dt das portable Tor herunter, wenn nichts antwortet.","Egress":"Ausgang","Egress used for opencode. ASK shows the picker at every start.":"Ausgang, den opencode nutzt. ASK zeigt die Auswahl bei jedem Start.","Enter a full URL (http, https, ftp or file).":"Gib eine vollst\u00e4ndige URL ein (http, https, ftp oder file).","Enter a whole number.":"Gib eine ganze Zahl ein.","Enter cycles: {0}.":"Enter wechselt durch: {0}.","Enter toggles it.":"Enter schaltet um.","Every change is saved at once to {0}":"Jede \u00c4nderung wird sofort in {0} gespeichert","Exit":"Beenden","Exit IP":"Ausgangs-IP","Extra rounds (60 s apart) before giving up.":"Zus\u00e4tzliche Runden (60 s Abstand), bevor aufgegeben wird.","Folder":"Ordner","Font name":"Schriftname","Font of the terminal text. Empty leaves the terminal as it is.":"Schrift des Terminaltexts. Leer l\u00e4sst das Terminal unver\u00e4ndert.","Font size":"Schriftgr\u00f6\u00dfe","Free HTTP proxies from your list (any format) or the default one. Each is tested before use.":"Kostenlose HTTP-Proxys aus deiner Liste (beliebiges Format) oder der Standardliste. Jeder wird vor der Nutzung getestet.","Free or your own list":"Frei oder eigene Liste","Fresh start":"Neustart","Full path of OpenCode.exe. Empty = search automatically.":"Vollst\u00e4ndiger Pfad von OpenCode.exe. Leer = automatisch suchen.","Get a new IP or proxy, then open OpenCode. Your chats and history stay untouched.":"Holt eine neue IP oder einen neuen Proxy und \u00f6ffnet OpenCode. Chats und Verlauf bleiben unver\u00e4ndert.","Gets a new IP / WARP registration / Tor circuit / proxy.":"Holt eine neue IP / WARP-Registrierung / Tor-Verbindung / einen neuen Proxy.","Go ahead.":"Los geht's.","Go back. Nothing is changed.":"Zur\u00fcck. Nichts wird ge\u00e4ndert.","Guided setup: choose WARP, Tor, a proxy list or direct, then get an \"opencode\" command and a shortcut that start with it. It is tested at the end.":"Gef\u00fchrte Einrichtung: w\u00e4hle WARP, Tor, eine Proxy-Liste oder direkt und erhalte einen \"opencode\"-Befehl und eine Verkn\u00fcpfung, die damit starten. Am Ende wird getestet.","HTTP port of the built-in bridge opencode uses.":"HTTP-Port der integrierten Br\u00fccke, die opencode nutzt.","Host used by the API check.":"Server, den die API-Pr\u00fcfung nutzt.","How do you want to run OpenCode?":"Wie m\u00f6chtest du OpenCode ausf\u00fchren?","How many proxies to test before giving up.":"Wie viele Proxys getestet werden, bevor aufgegeben wird.","How many times, and how fast, a new IP is requested when the free limit is hit.":"Wie oft und wie schnell eine neue IP angefordert wird, wenn das kostenlose Limit erreicht ist.","IPs the probe may reject before giving up. 0 = no limit.":"IPs, die der Test ablehnen darf, bevor aufgegeben wird. 0 = unbegrenzt.","Icons and borders":"Symbole und Rahmen","Install Tor automatically":"Tor automatisch installieren","Keep the current connection and open OpenCode as it was.":"Beh\u00e4lt die aktuelle Verbindung und \u00f6ffnet OpenCode wie zuvor.","Keep the current font.":"Aktuelle Schrift behalten.","Kill opencode and clear the saved tokens, keeping your chats where they are.":"Beendet opencode und l\u00f6scht die gespeicherten Tokens; deine Chats bleiben, wo sie sind.","Kill opencode, move your chats to the Desktop, clear the saved tokens and open a fresh session.":"Beendet opencode, verschiebt deine Chats auf den Desktop, l\u00f6scht die gespeicherten Tokens und \u00f6ffnet eine neue Sitzung.","Language":"Sprache","Language of the menus and descriptions. auto follows Windows. Logs and the support report stay in English.":"Sprache der Men\u00fcs und Beschreibungen. auto folgt Windows. Protokolle und der Support-Bericht bleiben auf Englisch.","Last check":"Letzte Pr\u00fcfung","Launch OpenCode":"OpenCode starten","Launcher":"Launcher","Launcher self-update":"Launcher-Selbstupdate","Leave the setup without changing anything.":"Die Einrichtung verlassen, ohne etwas zu \u00e4ndern.","Leave the terminal font as it is. If the launcher changed it, the original font comes back.":"L\u00e4sst die Terminal-Schrift unver\u00e4ndert. Hat der Launcher sie ge\u00e4ndert, kommt die urspr\u00fcngliche zur\u00fcck.","Local Tor with a built-in HTTP bridge. A portable Tor is installed automatically if missing.":"Lokales Tor mit integrierter HTTP-Br\u00fccke. Fehlt es, wird automatisch ein portables Tor installiert.","Local port of the WARP proxy.":"Lokaler Port des WARP-Proxys.","Logs":"Protokolle","Main menu":"Hauptmen\u00fc","Method":"Methode","Minimum list size (bytes)":"Minimale Listengr\u00f6\u00dfe (Bytes)","Mode":"Modus","Model used by the IP probe.":"Modell, das der IP-Test nutzt.","Must be between {0} and {1}.":"Muss zwischen {0} und {1} liegen.","New IP and resume in 5s":"Neue IP und Fortsetzen in 5 s","No":"Nein","No .exe file exists at that path.":"An diesem Pfad gibt es keine .exe-Datei.","No answer in {0}s counts as No.":"Keine Antwort in {0} s z\u00e4hlt als Nein.","No change.":"Keine \u00c4nderung.","No proxy: opencode uses your real connection and nothing is rotated.":"Kein Proxy: opencode nutzt deine echte Verbindung und nichts wird rotiert.","No, cancel":"Nein, abbrechen","Non-limit probe failures before the hunt stops.":"Test-Fehler, die nicht das Limit betreffen, bevor die Suche stoppt.","Not a URL, and no file exists at that path.":"Keine URL, und an diesem Pfad gibt es keine Datei.","Not configured":"Nicht eingerichtet","Nothing to ask for a direct connection.":"Bei einer direkten Verbindung gibt es nichts zu fragen.","Nothing was left half done that Uninstall cannot remove. Fix the problem and run setup again.":"Es ist nichts halb fertig geblieben, was Deinstallieren nicht entfernen kann. Behebe das Problem und f\u00fchre die Einrichtung erneut aus.","On PATH":"Im PATH","Only opencode uses it; the rest of the system stays direct.":"Nur opencode nutzt sie; der Rest des Systems bleibt direkt.","Open the Windows folder picker and choose where to work.":"\u00d6ffnet die Windows-Ordnerauswahl, um den Arbeitsort zu w\u00e4hlen.","Open the folder":"Ordner \u00f6ffnen","Open the launcher menus: pick a folder and a connection method, then start the opencode CLI or the desktop app.":"\u00d6ffnet die Launcher-Men\u00fcs: Ordner und Verbindungsmethode w\u00e4hlen, dann die opencode-CLI oder die Desktop-App starten.","OpenCode app":"OpenCode-App","PATH lookup timeout (s)":"Zeitlimit der PATH-Suche (s)","Paths":"Pfade","Port {0} is already used by {1}.":"Port {0} wird bereits von {1} verwendet.","Ports and install behavior of the portable Tor the launcher starts for you.":"Ports und Installation des portablen Tor, das der Launcher f\u00fcr dich startet.","Press any key to continue...":"Beliebige Taste zum Fortfahren...","Probe":"Test","Probe failures tolerated":"Tolerierte Testfehler","Probe model":"Testmodell","Proxies tried per pick":"Proxys pro Auswahl","Proxy":"Proxy","Proxy list":"Proxy-Liste","Proxy list source":"Quelle der Proxy-Liste","Proxy test timeout (s)":"Zeitlimit eines Proxy-Tests (s)","Public HTTP proxies from a list (yours, in any format, or the free default). Each one is tested first and burned ones are skipped.":"\u00d6ffentliche HTTP-Proxys aus einer Liste (deiner, in beliebigem Format, oder der freien Standardliste). Jeder wird zuerst getestet, verbrannte werden \u00fcbersprungen.","Put every setting back to its default. Your connection setup (command, shortcuts) is not touched. Asks first.":"Setzt alle Einstellungen auf ihren Standard zur\u00fcck. Deine Verbindungseinrichtung (Befehl, Verkn\u00fcpfungen) bleibt unber\u00fchrt. Fragt vorher.","Put the full path on the clipboard.":"Legt den vollst\u00e4ndigen Pfad in die Zwischenablage.","Quotes and line breaks are not allowed.":"Anf\u00fchrungszeichen und Zeilenumbr\u00fcche sind nicht erlaubt.","Range {0} to {1}.":"Bereich {0} bis {1}.","Reconfigure (run setup again)":"Neu einrichten (Einrichtung erneut ausf\u00fchren)","Release metadata URL":"URL der Versionsmetadaten","Removes only what setup added: the opencode command, the shortcuts and the PATH entry.":"Entfernt nur, was die Einrichtung hinzugef\u00fcgt hat: den opencode-Befehl, die Verkn\u00fcpfungen und den PATH-Eintrag.","Removes only what the setup added (command, shortcuts, PATH entry) and restores the settings it changed. Backups are kept. Asks first.":"Entfernt nur, was die Einrichtung hinzugef\u00fcgt hat (Befehl, Verkn\u00fcpfungen, PATH-Eintrag), und stellt die ge\u00e4nderten Einstellungen wieder her. Sicherungen bleiben erhalten. Fragt vorher.","Removing shortcuts":"Verkn\u00fcpfungen werden entfernt","Removing the opencode command":"opencode-Befehl wird entfernt","Renew did not finish (code {0}).":"Die Erneuerung wurde nicht abgeschlossen (Code {0}).","Renew session":"Sitzung erneuern","Renew the session?":"Sitzung erneuern?","Renewed. Open opencode again; you may need to log in once more.":"Erneuert. \u00d6ffne opencode erneut; eventuell musst du dich noch einmal anmelden.","Renewing":"Wird erneuert","Renewing the session":"Sitzung wird erneuert","Reopen the last folder":"Letzten Ordner erneut \u00f6ffnen","Report ready. Personal data was removed; read it once before you share it.":"Bericht fertig. Pers\u00f6nliche Daten wurden entfernt; lies ihn einmal durch, bevor du ihn teilst.","Repository":"Repository","Reset every setting to its default?":"Alle Einstellungen auf den Standard zur\u00fccksetzen?","Reset to default values":"Auf Standardwerte zur\u00fccksetzen","Restores the settings setup changed. Your other settings and your opencode files are kept.":"Stellt die von der Einrichtung ge\u00e4nderten Einstellungen wieder her. Deine anderen Einstellungen und deine opencode-Dateien bleiben erhalten.","Restoring PATH":"PATH wird wiederhergestellt","Restoring settings":"Einstellungen werden wiederhergestellt","Resume message":"Fortsetzungsnachricht","Resume timeout (s)":"Zeitlimit der Fortsetzung (s)","Return to the connection details.":"Zur\u00fcck zu den Verbindungsdetails.","Return to the main menu.":"Zur\u00fcck zum Hauptmen\u00fc.","Return to the settings groups.":"Zur\u00fcck zu den Einstellungsgruppen.","Review":"Zusammenfassung","Rotate the connection only (new WARP registration, Tor circuit or proxy) without opening OpenCode.":"Rotiert nur die Verbindung (neue WARP-Registrierung, Tor-Verbindung oder Proxy), ohne OpenCode zu \u00f6ffnen.","Rotate when a fatal error appears while opencode runs.":"Rotiert, wenn w\u00e4hrend der Ausf\u00fchrung von opencode ein schwerer Fehler auftritt.","Rotation":"Rotation","Rotation attempts":"Rotationsversuche","Rotation rounds":"Rotationsrunden","Run mode":"Ausf\u00fchrungsmodus","Run opencode in this terminal. After a new IP the chat resumes by itself.":"F\u00fchrt opencode in diesem Terminal aus. Nach einer neuen IP setzt sich der Chat von selbst fort.","Run the OpenCode desktop app ({0}). It is restarted after every new IP.":"F\u00fchrt die OpenCode-Desktop-App aus ({0}). Sie wird nach jeder neuen IP neu gestartet.","Run the setup again to change the method or repair the opencode command.":"F\u00fchrt die Einrichtung erneut aus, um die Methode zu \u00e4ndern oder den opencode-Befehl zu reparieren.","SOCKS port of the Tor the launcher starts.":"SOCKS-Port des Tor, das der Launcher startet.","Save the settings, create the opencode command, the shortcuts and the PATH entry, then test the connection.":"Speichert die Einstellungen, erstellt den opencode-Befehl, die Verkn\u00fcpfungen und den PATH-Eintrag und testet dann die Verbindung.","Saved: {0} = {1}":"Gespeichert: {0} = {1}","Saving config.json":"config.json wird gespeichert","Seconds a single \"where\" lookup may take.":"Sekunden, die eine einzelne \"where\"-Suche dauern darf.","Seconds a single proxy test may take.":"Sekunden, die ein einzelner Proxy-Test dauern darf.","Seconds a single warp-cli call may take.":"Sekunden, die ein einzelner warp-cli-Aufruf dauern darf.","Seconds before a silent resume counts as a dead IP.":"Sekunden, bevor eine stumme Fortsetzung als tote IP z\u00e4hlt.","Seconds to wait after (re)connecting WARP.":"Sekunden Wartezeit nach dem (erneuten) Verbinden von WARP.","Seconds to wait for Tor to finish bootstrapping.":"Sekunden Wartezeit, bis Tor fertig gestartet ist.","See what the setup installed (command, shortcuts, PATH) and run it again to change the method.":"Zeigt, was die Einrichtung installiert hat (Befehl, Verkn\u00fcpfungen, PATH), und f\u00fchrt sie erneut aus, um die Methode zu \u00e4ndern.","Send one cheap message through each candidate IP.":"Sendet eine g\u00fcnstige Nachricht \u00fcber jede Kandidaten-IP.","Sent automatically after a rotation.":"Wird nach einer Rotation automatisch gesendet.","Settings":"Einstellungen","Settings and setup":"Einstellungen und Einrichtung","Setup 1/3 - connection method":"Einrichtung 1/3 - Verbindungsmethode","Setup 2/3 - details":"Einrichtung 2/3 - Details","Setup 3/3 - run mode":"Einrichtung 3/3 - Ausf\u00fchrungsmodus","Setup stopped: {0}":"Die Einrichtung wurde angehalten: {0}","Shortcuts":"Verkn\u00fcpfungen","Show the CLI or Desktop choice every time the launcher opens.":"Zeigt die Wahl CLI oder Desktop bei jedem \u00d6ffnen des Launchers.","Show the report in Explorer so you can attach or paste it.":"Zeigt den Bericht im Explorer, damit du ihn anh\u00e4ngen oder einf\u00fcgen kannst.","Size used with the chosen font.":"Gr\u00f6\u00dfe, die mit der gew\u00e4hlten Schrift verwendet wird.","Support":"Support","Support report":"Support-Bericht","Switch between the terminal and the desktop app.":"Zwischen Terminal und Desktop-App wechseln.","Switch to Tor and keep going?":"Zu Tor wechseln und weitermachen?","System":"System","Takes effect at the {0}; a service already running keeps the old value until then.":"Gilt ab: {0}; ein bereits laufender Dienst beh\u00e4lt bis dahin den alten Wert.","Terminal font":"Terminal-Schrift","Test every new IP":"Jede neue IP testen","The OpenCode desktop app was not found. Choosing this offers to download and install it.":"Die OpenCode-Desktop-App wurde nicht gefunden. Bei dieser Auswahl wird angeboten, sie herunterzuladen und zu installieren.","The OpenCode desktop app; it is restarted after every new IP.":"Die OpenCode-Desktop-App; sie wird nach jeder neuen IP neu gestartet.","The activity log (launcher.log) and the support report: what is recorded, how big it may grow, whether IPs are masked.":"Das Aktivit\u00e4tsprotokoll (launcher.log) und der Support-Bericht: was aufgezeichnet wird, wie gro\u00df es werden darf und ob IPs maskiert werden.","The cheap test message sent through every new IP before it is trusted.":"Die g\u00fcnstige Testnachricht, die \u00fcber jede neue IP gesendet wird, bevor ihr vertraut wird.","The check failed (code {0}). Setup is saved; fix the cause and use Renew or Connect again.":"Die Pr\u00fcfung ist fehlgeschlagen (Code {0}). Die Einrichtung ist gespeichert; behebe die Ursache und nutze Erneuern oder Verbinden erneut.","The font applies to the whole terminal window, not only to this launcher.":"Die Schrift gilt f\u00fcr das ganze Terminalfenster, nicht nur f\u00fcr diesen Launcher.","The proxy lives only in the opencode process; the rest of the system stays direct.":"Der Proxy gilt nur im opencode-Prozess; der Rest des Systems bleibt direkt.","The resume auto-approves tool permissions.":"Die Fortsetzung genehmigt Werkzeugberechtigungen automatisch.","The shortcut and the opencode command use the CLI; this is the launcher menu default.":"Die Verkn\u00fcpfung und der opencode-Befehl nutzen die CLI; dies ist der Standard im Launcher-Men\u00fc.","The terminal interface. The opencode command and the shortcut always use it.":"Die Terminal-Oberfl\u00e4che. Der opencode-Befehl und die Verkn\u00fcpfung nutzen immer sie.","This launcher is not the one that set it up. Reconfigure to repair the command.":"Dieser Launcher ist nicht der, der es eingerichtet hat. Richte neu ein, um den Befehl zu reparieren.","Token reset":"Token-Reset","Tools and versions":"Werkzeuge und Versionen","Tor HTTP bridge port":"Port der Tor-HTTP-Br\u00fccke","Tor SOCKS port":"Tor-SOCKS-Port","Tor bootstrap wait (s)":"Wartezeit f\u00fcr den Tor-Start (s)","Tor is downloaded once, run hidden and offered to opencode through a built-in HTTP bridge. Slower, but a new circuit is a new IP.":"Tor wird einmal heruntergeladen, versteckt ausgef\u00fchrt und opencode \u00fcber eine integrierte HTTP-Br\u00fccke angeboten. Langsamer, aber eine neue Verbindung ist eine neue IP.","Try again in a minute, or pick another connection method in Connect with opencode.":"Versuche es in einer Minute erneut oder w\u00e4hle unter \"Mit opencode verbinden\" eine andere Verbindungsmethode.","Try again?":"Erneut versuchen?","Try to download and install WARP now?":"WARP jetzt herunterladen und installieren?","Type \"opencode\" in a NEW terminal, or use the \"OpenCode Infinite (egress)\" shortcut.":"Gib \"opencode\" in einem NEUEN Terminal ein oder nutze die Verkn\u00fcpfung \"OpenCode Infinite (egress)\".","Type < to go back. Enter keeps the value shown.":"Gib < ein, um zur\u00fcckzugehen. Enter beh\u00e4lt den angezeigten Wert.","Type a font name...":"Schriftnamen eingeben...","URL or local file, any format (plain, CSV, JSON, XML, HTML).":"URL oder lokale Datei, beliebiges Format (Text, CSV, JSON, XML, HTML).","Unattended resume":"Unbeaufsichtigte Fortsetzung","Uninstall":"Deinstallieren","Uninstall stopped: {0}":"Die Deinstallation wurde angehalten: {0}","Uninstall the opencode connection?":"Die opencode-Verbindung deinstallieren?","Uninstalled. Backups stay in {0}":"Deinstalliert. Sicherungen bleiben in {0}","Uninstalling":"Wird deinstalliert","Update now?":"Jetzt aktualisieren?","Updates":"Updates","Use 1 to 200 characters.":"Verwende 1 bis 200 Zeichen.","Use it when the free limit is hit or the login expired: closes opencode, saves and clears the saved tokens, and gets a new IP, WARP registration, Tor circuit or proxy.":"Nutze es, wenn das kostenlose Limit erreicht ist oder die Anmeldung abgelaufen ist: beendet opencode, sichert und l\u00f6scht die gespeicherten Tokens und holt eine neue IP, WARP-Registrierung, Tor-Verbindung oder einen neuen Proxy.","Use on or off.":"Verwende on oder off.","Use that proxy anyway?":"Diesen Proxy trotzdem verwenden?","Use this folder":"Diesen Ordner verwenden","Use up to 31 characters, without quotes or backslashes.":"Verwende bis zu 31 Zeichen, ohne Anf\u00fchrungszeichen oder Backslashes.","Use {0} for the terminal text. Monospaced fonts only look right.":"Verwendet {0} f\u00fcr den Terminaltext. Nur Schriften mit fester Breite sehen richtig aus.","Version":"Version","View and change every launcher option: connection, proxies, Tor, rotation, themes. Saved instantly, no files to edit.":"Zeigt und \u00e4ndert jede Launcher-Option: Verbindung, Proxys, Tor, Rotation, Designs. Wird sofort gespeichert, keine Dateien zu bearbeiten.","WARP proxy port":"WARP-Proxy-Port","WARP wait (s)":"WARP-Wartezeit (s)","Watch the log":"Protokoll \u00fcberwachen","Watcher":"\u00dcberwachung","Watching the opencode log and the automatic \"continue\" sent after a rotation.":"\u00dcberwachung des opencode-Protokolls und das automatische \"continue\" nach einer Rotation.","Where proxies come from (URL or file, any format) and how each one is tested.":"Woher die Proxys kommen (URL oder Datei, beliebiges Format) und wie jeder getestet wird.","Where versions and checksums are read from.":"Woher Versionen und Pr\u00fcfsummen gelesen werden.","Whether the launcher checks GitHub for a newer copy of itself at every start.":"Ob der Launcher bei jedem Start auf GitHub nach einer neueren Kopie seiner selbst sucht.","Work in a different folder.":"In einem anderen Ordner arbeiten.","Work in the folder the launcher was started from: {0}":"In dem Ordner arbeiten, aus dem der Launcher gestartet wurde: {0}","Work in {0}":"In {0} arbeiten","Writing the report":"Bericht wird geschrieben","Yes":"Ja","Yes, continue":"Ja, fortfahren","Your connection setup (shim, shortcuts) is not touched.":"Deine Verbindungseinrichtung (Shim, Verkn\u00fcpfungen) bleibt unber\u00fchrt.","Your session needs renewing: {0}":"Deine Sitzung muss erneuert werden: {0}","asks first":"fragt vorher","auto":"auto","auto follows the terminal and NO_COLOR; off disables colors.":"auto folgt dem Terminal und NO_COLOR; off schaltet Farben ab.","direct":"direkt","emoji = modern terminals, unicode = classic console, ascii = anything.":"emoji = moderne Terminals, unicode = klassische Konsole, ascii = alles.","free list":"freie Liste","installed":"installiert","missing":"fehlt","new IP":"neue IP","next Tor start":"n\u00e4chsten Tor-Start","next WARP connect":"n\u00e4chste WARP-Verbindung","next launch":"n\u00e4chsten Start","no other step is needed.":"es ist kein weiterer Schritt n\u00f6tig.","not installed":"nicht installiert","not verified":"nicht gepr\u00fcft","off":"aus","on":"an","same IP":"gleiche IP","terminal":"Terminal","warp-cli timeout (s)":"warp-cli-Zeitlimit (s)","yes":"ja","{0} changed":"{0} ge\u00e4ndert","{0} of {1}":"{0} von {1}","After opencode closes":"Nach dem Schlie\u00dfen von opencode","ask = R, M or Q: R gets a new IP and resumes the chat, M opens the menu, Q quits. quit = leave the launcher at once.":"ask = R, M oder Q: R holt eine neue IP und setzt den Chat fort, M \u00f6ffnet das Men\u00fc, Q beendet. quit = Launcher sofort beenden.","Rotate key":"Taste f\u00fcr Rotation","Menu key":"Men\u00fc-Taste","Quit key":"Beenden-Taste","Closed-opencode prompt: new IP and resume the chat.":"Abfrage nach dem Schlie\u00dfen von opencode: neue IP und Chat fortsetzen.","Closed-opencode prompt: open the menu.":"Abfrage nach dem Schlie\u00dfen: Men\u00fc \u00f6ffnen.","Closed-opencode prompt: quit. Ctrl+C always quits too.":"Abfrage nach dem Schlie\u00dfen: beenden. Strg+C beendet immer.","The keys of the launcher and the terminal commands. Fixed keys are listed for reference; the three letters can be changed.":"Die Tasten des Starters und die Terminal-Befehle. Feste Tasten werden zur Information angezeigt; die drei Buchstaben sind \u00e4nderbar.","One letter, like R.":"Ein Buchstabe, z. B. R.","Key {0} is already used by {1}.":"Die Taste {0} wird schon von {1} verwendet.","Only the chosen language is downloaded from the langs folder of the repository.":"Nur die gew\u00e4hlte Sprache wird aus dem langs-Ordner des Repositorys geladen.","Follow the language Windows uses.":"Folgt der Sprache von Windows.","Use this language for every menu and message.":"Diese Sprache f\u00fcr alle Men\u00fcs und Meldungen verwenden.","Keep the current language.":"Aktuelle Sprache behalten.","File to write (Enter = Desktop, Esc = back)":"Zu schreibende Datei (Enter = Desktop, Esc = zur\u00fcck)","File to read (Esc = back)":"Zu lesende Datei (Esc = zur\u00fcck)","That folder does not exist.":"Dieser Ordner existiert nicht.","Replace the file that is already there?":"Vorhandene Datei ersetzen?","Exported {0} changed setting(s) to {1}":"{0} ge\u00e4nderte Einstellung(en) nach {1} exportiert","Import {0} setting(s)? Their current values are replaced.":"{0} Einstellung(en) importieren? Ihre aktuellen Werte werden ersetzt.","{0} setting(s) of this file are unknown here and are skipped.":"{0} Einstellung(en) dieser Datei sind hier unbekannt und werden \u00fcbersprungen.","No file at that path.":"Unter diesem Pfad gibt es keine Datei.","This is not an OpenCode Infinite settings file.":"Das ist keine Einstellungsdatei von OpenCode Infinite.","Nothing was imported. These values are not valid:":"Nichts wurde importiert. Diese Werte sind ung\u00fcltig:","Imported {0} setting(s).":"{0} Einstellung(en) importiert.","Export settings to a file":"Einstellungen in eine Datei exportieren","Save every changed setting to one .json file, to keep a backup or copy them to another PC.":"Speichert alle ge\u00e4nderten Einstellungen in einer .json-Datei, als Sicherung oder f\u00fcr einen anderen PC.","Import settings from a file":"Einstellungen aus einer Datei importieren","Load a file made by Export. Every value is checked first; if one is wrong, nothing changes.":"L\u00e4dt eine mit Exportieren erstellte Datei. Jeder Wert wird zuerst gepr\u00fcft; ist einer falsch, \u00e4ndert sich nichts.","back to the previous screen":"zur\u00fcck zum vorigen Bildschirm","Fixed. In a menu or a text prompt Esc goes back; it never closes the launcher.":"Fest. In einem Men\u00fc oder Textfeld geht Esc zur\u00fcck; es beendet den Starter nie.","select and move":"ausw\u00e4hlen und bewegen","Fixed. Digits 1-9 jump straight to a row.":"Fest. Die Ziffern 1-9 springen direkt zu einer Zeile.","quit the launcher":"Starter beenden","Fixed. Stops the processes it started and leaves the terminal open, no Y/N question.":"Fest. Beendet die gestarteten Prozesse und l\u00e4sst das Terminal offen, ohne J/N-Frage.","start with the connection":"mit der Verbindung starten","Terminal command from any folder. The Start menu shortcut does the same.":"Terminal-Befehl aus jedem Ordner. Die Verkn\u00fcpfung im Startmen\u00fc macht dasselbe.","open this menu":"dieses Men\u00fc \u00f6ffnen","Terminal command: opens the launcher menu again, as many times as you need.":"Terminal-Befehl: \u00f6ffnet das Starter-Men\u00fc erneut, so oft wie n\u00f6tig.","original OpenCode":"OpenCode im Original","Terminal command: starts the OpenCode you installed, without the launcher or the connection. Use it when the launcher breaks.":"Terminal-Befehl: startet das installierte OpenCode ohne Starter und ohne Verbindung. Nutzen, wenn der Starter nicht funktioniert.","Commands":"Befehle","Adds: the opencode, opencodeinf and opencodeoc commands, two shortcuts, one PATH entry. Backups are kept.":"F\u00fcgt die Befehle opencode, opencodeinf und opencodeoc, zwei Verkn\u00fcpfungen und einen PATH-Eintrag hinzu. Sicherungen bleiben erhalten.","  This copy is not the official one. Starting the official copy:":"  Diese Kopie ist nicht die offizielle. Starte die offizielle Kopie:","  OpenCode - how do you want to run it?":"  OpenCode - wie m\u00f6chtest du es starten?","  [1] CLI      - terminal TUI (chat resumes on every new IP)":"  [1] CLI      - Terminal-TUI (der Chat wird bei jeder neuen IP fortgesetzt)","  [2] Desktop  - the OpenCode desktop app (restarted on every new IP)":"  [2] Desktop  - die OpenCode-Desktop-App (wird bei jeder neuen IP neu gestartet)","  [3] Exit":"  [3] Beenden","  One key, no Enter.":"  Eine Taste, ohne Enter.","%C_WARN%  [*] OpenCode desktop not found.%C_RST%":"%C_WARN%  [*] OpenCode-Desktop-App nicht gefunden.%C_RST%","%C_WARN%  [*] still not found - set OC_APP to its OpenCode.exe.%C_RST%":"%C_WARN%  [*] Immer noch nicht gefunden - setze OC_APP auf den Pfad zu OpenCode.exe.%C_RST%","  [app] DESKTOP \"%OC_DESKTOP%\"":"  [app] DESKTOP \"%OC_DESKTOP%\"","  OpenCode - choose a folder to work in":"  OpenCode - w\u00e4hle einen Ordner zum Arbeiten","  [1] Reopen the last folder":"  [1] Letzten Ordner wieder \u00f6ffnen","      (nothing saved yet)":"      (noch nichts gespeichert)","  [2] Use this folder":"  [2] Diesen Ordner verwenden","  [3] Browse for a folder...":"  [3] Ordner durchsuchen...","  [4] Exit":"  [4] Beenden","  No folder saved yet. Use [2] or [3] this time.":"  Noch kein Ordner gespeichert. Verwende diesmal [2] oder [3].","  Choose a folder in the dialog...":"  W\u00e4hle einen Ordner im Dialog...","  Opening the classic folder picker...":"  Klassische Ordnerauswahl wird ge\u00f6ffnet...","  No folder selected.":"  Kein Ordner ausgew\u00e4hlt.","  Folder not found: \"%OPFOLDER%\"":"  Ordner nicht gefunden: \"%OPFOLDER%\"","  Cannot enter: \"%OPFOLDER%\"":"  Kann nicht \u00f6ffnen: \"%OPFOLDER%\"","  Working in: \"%CD%\"":"  Arbeite in: \"%CD%\"","  [egress] %EGRESS% (from your settings)":"  [egress] %EGRESS% (aus deinen Einstellungen)","  Choose egress for OpenCode only (system traffic stays direct)":"  Ausgang nur f\u00fcr OpenCode w\u00e4hlen (der Systemverkehr bleibt direkt)","  [1] WARP     - Cloudflare WARP proxy mode (rotation supported)":"  [1] WARP     - Cloudflare-WARP-Proxymodus (Rotation m\u00f6glich)","  [2] TOR      - local Tor + built-in bridge on :%TOR_HTTP_PORT%":"  [2] TOR      - lokales Tor + eingebaute Br\u00fccke auf :%TOR_HTTP_PORT%","                 (auto-installs a portable Tor, nothing to set up)":"                 (portables Tor wird automatisch installiert, nichts einzurichten)","  [3] PROXY    - free HTTP proxies (ProxyScrape list)":"  [3] PROXY    - kostenlose HTTP-Proxys (ProxyScrape-Liste)","  [4] NONE     - direct, no proxy":"  [4] NONE     - direkt, ohne Proxy","  [egress] NONE - direct.":"  [egress] NONE - direkt.","  [egress] PROXY - free HTTP list.":"  [egress] PROXY - kostenlose HTTP-Liste.","  [egress] TOR - portable Tor + built-in bridge on :%TOR_HTTP_PORT%, auto-setup.":"  [egress] TOR - portables Tor + eingebaute Br\u00fccke auf :%TOR_HTTP_PORT%, automatische Einrichtung.","  [egress] WARP.":"  [egress] WARP.","  [dep] curl":"  [dep] curl","  [dep] warp":"  [dep] warp","%C_WARN%  [*] Cloudflare WARP not found - IP rotation will be disabled.%C_RST%":"%C_WARN%  [*] Cloudflare WARP nicht gefunden - IP-Rotation wird deaktiviert.%C_RST%","      Install it later from 1.1.1.1 if you want the rotation.":"      Installiere es sp\u00e4ter \u00fcber 1.1.1.1, wenn du die Rotation willst.","%C_WARN%  [*] WARP still not available - continuing without rotation.%C_RST%":"%C_WARN%  [*] WARP weiterhin nicht verf\u00fcgbar - es geht ohne Rotation weiter.%C_RST%","      warp-cli errors, if any, are in %STATE_DIR%\\wcli.log":"      warp-cli-Fehler, falls vorhanden, stehen in %STATE_DIR%\\wcli.log","%C_WARN%  [*] Cloudflare WARP publishes 64-bit Windows builds only.%C_RST%":"%C_WARN%  [*] Cloudflare WARP gibt es nur als 64-Bit-Version f\u00fcr Windows.%C_RST%","      On this 32-bit system rotation is disabled.":"      Auf diesem 32-Bit-System ist die Rotation deaktiviert.","%C_OK%  [ok] WARP ready.%C_RST%":"%C_OK%  [ok] WARP bereit.%C_RST%","  [dep] opencode":"  [dep] opencode","  [auto-install] opencode not found, fetching it...":"  [auto-install] opencode nicht gefunden, wird geladen...","%C_OK%  [ok] opencode ready.%C_RST%":"%C_OK%  [ok] opencode bereit.%C_RST%","%C_ERR%  ERROR: opencode install failed or is not on PATH.%C_RST%":"%C_ERR%  FEHLER: Installation von opencode fehlgeschlagen oder nicht im PATH.%C_RST%","  Get it by hand: https://github.com/sst/opencode/releases":"  Manuell holen: https://github.com/sst/opencode/releases","  Preparing the connection...":"  Verbindung wird vorbereitet...","  OpenCode":"  OpenCode","  Folder : \"%CD%\"":"  Ordner : \"%CD%\"","  Egress : %EGRESS%":"  Ausgang: %EGRESS%","  Mode   : %APP_MODE%":"  Modus  : %APP_MODE%","  WARP   : none (rotation disabled)":"  WARP   : keiner (Rotation deaktiviert)","  WARP   : \"%WARP%\"":"  WARP   : \"%WARP%\"","  Version: %OC_VER%  \"%OC_CMD%\"":"  Version: %OC_VER%  \"%OC_CMD%\"","  Exit IP: %IP%":"  Exit-IP: %IP%","  What do you want to do?":"  Was m\u00f6chtest du tun?","  [1] Fresh start   - get a new IP / proxy, then open OpenCode":"  [1] Frischer Start - neue IP / neuer Proxy, dann OpenCode \u00f6ffnen","                      (your chats and history stay untouched)":"                      (deine Chats und dein Verlauf bleiben unber\u00fchrt)","  [2] Continue      - same egress, open OpenCode as it was":"  [2] Fortsetzen    - gleicher Ausgang, OpenCode wie zuvor \u00f6ffnen","  [3] Change IP     - rotate / pick new proxy only":"  [3] IP wechseln   - nur rotieren / neuen Proxy w\u00e4hlen","  [5] Deep reset    - kill opencode, move chats to the Desktop,":"  [5] Komplett-Reset - opencode beenden, Chats auf den Desktop verschieben,","                      clear saved tokens, open a fresh session":"                      gespeicherte Tokens l\u00f6schen, neue Sitzung \u00f6ffnen","  [6] Exit":"  [6] Beenden","  [7] Token reset   - kill opencode, clear saved tokens, keep chats":"  [7] Token-Reset   - opencode beenden, gespeicherte Tokens l\u00f6schen,","                      where they are, open a fresh session":"                      Chats bleiben, wo sie sind, neue Sitzung \u00f6ffnen","  [8] Settings      - change any launcher setting, applied right away":"  [8] Einstellungen - jede Einstellung \u00e4ndern, sofort wirksam","--- deep reset -----------------------------------------------":"--- Komplett-Reset ---------------------------------------------","  This closes opencode, moves your chats to the Desktop,":"  Das beendet opencode, verschiebt deine Chats auf den Desktop,","  clears the saved tokens and opens a brand new session.":"  l\u00f6scht die gespeicherten Tokens und \u00f6ffnet eine neue Sitzung.","  It is the only action in this script that touches your files.":"  Es ist die einzige Aktion in diesem Skript, die deine Dateien anfasst.","  It also kills EVERY opencode process on this computer,":"  Es beendet au\u00dferdem ALLE opencode-Prozesse auf diesem Computer,","  including windows opened by hand or by another launcher.":"  auch Fenster, die von Hand oder von einem anderen Launcher ge\u00f6ffnet wurden.","--- token reset ----------------------------------------------":"--- Token-Reset ------------------------------------------------","  This closes opencode, clears the saved tokens and opens a":"  Das beendet opencode, l\u00f6scht die gespeicherten Tokens und \u00f6ffnet","  brand new session. Your chats are NOT moved.":"  eine neue Sitzung. Deine Chats werden NICHT verschoben.","  auth.json is copied to the Desktop first, then removed.":"  auth.json wird zuerst auf den Desktop kopiert und dann gel\u00f6scht.","    egress: %EGRESS%":"    Ausgang: %EGRESS%","%C_WARN%  [*] WARP proxy is not answering - rotation has no effect.%C_RST%":"%C_WARN%  [*] WARP-Proxy antwortet nicht - Rotation hat keine Wirkung.%C_RST%","      Going direct would run opencode on your real IP.":"      Direkt zu gehen w\u00fcrde opencode mit deiner echten IP laufen lassen.","%C_WARN%  [*] Tor did not get ready.%C_RST%":"%C_WARN%  [*] Tor wurde nicht bereit.%C_RST%","%C_WARN%  [*] no working free proxy found.%C_RST%":"%C_WARN%  [*] kein funktionierender kostenloser Proxy gefunden.%C_RST%","%C_WARN%  [*] the egress proxy stopped answering while OpenCode was open:%C_RST%":"%C_WARN%  [*] der Ausgangs-Proxy hat w\u00e4hrend OpenCode lief aufgeh\u00f6rt zu antworten:%C_RST%","      %STATE_DIR%\\proxy_warn.txt":"      %STATE_DIR%\\proxy_warn.txt","%C_WARN%  [watch] a fatal error cut the chat - rotating and resuming it.%C_RST%":"%C_WARN%  [watch] ein fataler Fehler hat den Chat unterbrochen - wird rotiert und fortgesetzt.%C_RST%","OpenCode closed.":"OpenCode beendet.","  %KEY_ROTATE% = new IP and resume the chat   %KEY_MENU% = menu   %KEY_QUIT% = quit (Ctrl+C also quits)":"  %KEY_ROTATE% = neue IP und Chat fortsetzen   %KEY_MENU% = Men\u00fc   %KEY_QUIT% = beenden (Strg+C beendet auch)","Press any key to continue . . .":"Zum Fortfahren eine beliebige Taste dr\u00fccken . . .","  [tor] renewing the circuit, attempt %TOR_TRIES% of %ROTATE_TRIES_MAX%...":"  [tor] Schaltkreis wird erneuert, Versuch %TOR_TRIES% von %ROTATE_TRIES_MAX%...","%C_OK%  [tor] new circuit - resuming.%C_RST%":"%C_OK%  [tor] neuer Schaltkreis - wird fortgesetzt.%C_RST%","%C_WARN%  [*] Tor could not be renewed - back to menu.%C_RST%":"%C_WARN%  [*] Tor konnte nicht erneuert werden - zur\u00fcck zum Men\u00fc.%C_RST%","%C_WARN%  [*] Tor could not get a usable circuit after %ROTATE_TRIES_MAX% attempts.%C_RST%":"%C_WARN%  [*] Tor hat nach %ROTATE_TRIES_MAX% Versuchen keinen brauchbaren Schaltkreis bekommen.%C_RST%","      The exit node may be blocked: try a new identity in Tor, or":"      Der Exit-Knoten ist vielleicht gesperrt: versuche eine neue Identit\u00e4t in Tor oder","      switch to [1] WARP. warp/tor notes: \"%TOR_DIR%\\tor.log\"":"      wechsle zu [1] WARP. warp-/tor-Hinweise: \"%TOR_DIR%\\tor.log\"","  [proxy] %ACTIVE_PROXY% is burned - attempt %PROXY_ROT% of %PROXY_ROT_MAX%, picking another...":"  [proxy] %ACTIVE_PROXY% ist verbrannt - Versuch %PROXY_ROT% von %PROXY_ROT_MAX%, es wird ein anderer gesucht...","  [proxy] picking a fresh free proxy before resume...":"  [proxy] ein neuer kostenloser Proxy wird vor dem Fortsetzen gesucht...","%C_WARN%  [*] no free proxy is left that still works (they all hit the limit).%C_RST%":"%C_WARN%  [*] kein kostenloser Proxy mehr \u00fcbrig, der funktioniert (alle haben das Limit erreicht).%C_RST%","      Free proxies are shared by many people, so their limit is often used up.":"      Kostenlose Proxys werden von vielen geteilt, ihr Limit ist oft aufgebraucht.","  Automatic rotation is off - the menu decides.":"  Automatische Rotation ist aus - das Men\u00fc entscheidet.","Getting a new IP before the next attempt...":"Neue IP wird vor dem n\u00e4chsten Versuch geholt...","  [i] hunting for %HUNT_GOAL%: up to %TARGET_TRIES% attempts, %TARGET_MINUTES% min. Esc or Q stops.":"  [i] Suche nach %HUNT_GOAL%: bis zu %TARGET_TRIES% Versuche, %TARGET_MINUTES% Min. Esc oder Q stoppt.","[%ROTATE_TRIES%/%TARGET_TRIES%] dropping the old registration...":"[%ROTATE_TRIES%/%TARGET_TRIES%] alte Registrierung wird gel\u00f6scht...","[%ROTATE_TRIES%/%TARGET_TRIES%] new registration...":"[%ROTATE_TRIES%/%TARGET_TRIES%] neue Registrierung...","[%ROTATE_TRIES%] reconnect...":"[%ROTATE_TRIES%] neu verbinden...","[%ROTATE_TRIES%] waiting %WARP_WAIT%s...":"[%ROTATE_TRIES%] warte %WARP_WAIT%s...","[%ROTATE_TRIES%] %IPN% was already tried in this hunt, rotating again":"[%ROTATE_TRIES%] %IPN% wurde in dieser Suche schon probiert, es wird erneut rotiert","[%ROTATE_TRIES%/%TARGET_TRIES%] exit IP %IPN% (country %GLOC%), target %TMATCHTXT%, %HUNT_LEFT% attempt(s) left":"[%ROTATE_TRIES%/%TARGET_TRIES%] Exit-IP %IPN% (Land %GLOC%), Ziel %TMATCHTXT%, noch %HUNT_LEFT% Versuch(e)","[%ROTATE_TRIES%] probing if this IP can still talk...":"[%ROTATE_TRIES%] pr\u00fcfe, ob diese IP noch verbinden kann...","%C_WARN%  [*] probe failed for a reason that is NOT a limit - attempt %PBROKEN% of %PROBE_BROKEN_MAX%. Last output:%C_RST%":"%C_WARN%  [*] Pr\u00fcfung fehlgeschlagen aus einem Grund, der KEIN Limit ist - Versuch %PBROKEN% von %PROBE_BROKEN_MAX%. Letzte Ausgabe:%C_RST%","[%PROBE_TRIES%] IP already burned, rotating again...":"[%PROBE_TRIES%] IP schon verbrannt, es wird erneut rotiert...","%C_WARN%  [*] %PROBE_TRIES% IPs probed, every one of them already burned.%C_RST%":"%C_WARN%  [*] %PROBE_TRIES% IPs gepr\u00fcft, alle schon verbrannt.%C_RST%","%C_WARN%  [*] the probe failed %PBROKEN% times and none of them was a limit error.%C_RST%":"%C_WARN%  [*] die Pr\u00fcfung ist %PBROKEN% Mal fehlgeschlagen, keiner davon war ein Limit-Fehler.%C_RST%","      The probe itself is broken, not every IP: a retired PROBE_MODEL id,":"      Die Pr\u00fcfung selbst ist kaputt, nicht jede IP: eine abgel\u00f6ste PROBE_MODEL-ID,","      an auth error or a CLI change. Rotation cannot fix that.":"      ein Authentifizierungsfehler oder eine CLI-\u00c4nderung.","      Check PROBE_MODEL in the settings block, or run the probe model once":"      Pr\u00fcfe PROBE_MODEL im Einstellungsblock oder starte das Pr\u00fcfmodell","      by hand to see the real error.":"      einmal von Hand, um den echten Fehler zu sehen.","  [i] probe off for this session - IPs are accepted on WARP-trace proof":"  [i] Pr\u00fcfung f\u00fcr diese Sitzung aus - IPs werden nur durch den WARP-Trace best\u00e4tigt,","      only, and the resume's own limit check keeps catching burned ones.":"      und die Limit-Pr\u00fcfung beim Fortsetzen erkennt verbrannte weiterhin.","%C_WARN%  [*] the probe session \"%OC_PROBE_ID%\" does not exist and this%C_RST%":"%C_WARN%  [*] die Pr\u00fcfsitzung \"%OC_PROBE_ID%\" existiert nicht, und diese%C_RST%","      opencode build refused it. That is a probe problem, NOT a":"      opencode-Version hat sie abgelehnt. Das ist ein Pr\u00fcfproblem, KEINE","      burned IP - no rotation can fix it.":"      verbrannte IP - keine Rotation kann das beheben.","  [i] the probe is off for this session: IPs are accepted on":"  [i] die Pr\u00fcfung ist f\u00fcr diese Sitzung aus: IPs werden nur durch den WARP-Trace","      WARP-trace proof only, and the resume's own limit check still":"      best\u00e4tigt, und die Limit-Pr\u00fcfung beim Fortsetzen erkennt weiterhin eine verbrannte.","      catches a burned one. To keep the probe, create the session by":"      Um sie zu behalten, erstelle die Sitzung einmal von Hand","      hand once, or clear PROBE in the settings block.":"      oder l\u00f6sche PROBE im Einstellungsblock.","%C_OK%[%ROTATE_TRIES%] IP %IPN% works.%C_RST%":"%C_OK%[%ROTATE_TRIES%] IP %IPN% funktioniert.%C_RST%","[%ROTATE_TRIES%] no verified WARP IP yet, retrying...":"[%ROTATE_TRIES%] noch keine verifizierte WARP-IP, neuer Versuch...","%C_WARN%  [*] no usable IP from this hunt. warp-cli errors, if any, are in %STATE_DIR%\\wcli.log%C_RST%":"%C_WARN%  [*] keine brauchbare IP aus dieser Suche. warp-cli-Fehler, falls vorhanden, stehen in %STATE_DIR%\\wcli.log%C_RST%","  restarting the desktop app on the new egress...":"  Desktop-App wird auf dem neuen Ausgang neu gestartet...","  sending \"%RESUME_MSG%\" so the chat picks up where it stopped...":"  \"%RESUME_MSG%\" wird gesendet, damit der Chat dort weitermacht, wo er aufgeh\u00f6rt hat...","%C_WARN%  [*] proxy dead - retrying on the current egress instead of resuming.%C_RST%":"%C_WARN%  [*] Proxy tot - neuer Versuch auf dem aktuellen Ausgang statt Fortsetzen.%C_RST%","%C_WARN%  [*] no answer in %RESUME_TIMEOUT%s - this exit IP is dead.%C_RST%":"%C_WARN%  [*] keine Antwort in %RESUME_TIMEOUT%s - diese Exit-IP ist tot.%C_RST%","%C_OK%  chat resumed on the new IP.%C_RST%":"%C_OK%  Chat auf der neuen IP fortgesetzt.%C_RST%","%C_WARN%  [*] the resume itself hit a limit - rotating again.%C_RST%":"%C_WARN%  [*] das Fortsetzen selbst hat ein Limit erreicht - erneut rotiert.%C_RST%","  Egress is NONE - nothing to rotate.":"  Ausgang ist NONE - nichts zum Rotieren.","  Restarting the launcher-managed Tor for a new circuit...":"  Vom Launcher verwaltetes Tor wird f\u00fcr einen neuen Schaltkreis neu gestartet...","  TOR mode - this Tor was started outside the launcher.":"  TOR-Modus - dieses Tor wurde au\u00dferhalb des Launchers gestartet.","  Restart it yourself for a new circuit, or pick [1] WARP / [4] NONE.":"  Starte es selbst f\u00fcr einen neuen Schaltkreis neu oder w\u00e4hle [1] WARP / [4] NONE.","  Current bridge: http://127.0.0.1:%TOR_HTTP_PORT%":"  Aktuelle Br\u00fccke: http://127.0.0.1:%TOR_HTTP_PORT%","  Picking a new free HTTP proxy...":"  Neuer kostenloser HTTP-Proxy wird gesucht...","  New proxy: %ACTIVE_PROXY%":"  Neuer Proxy: %ACTIVE_PROXY%","WARP is not available - nothing to rotate.":"WARP ist nicht verf\u00fcgbar - nichts zu rotieren.","Requesting a new WARP registration...":"Neue WARP-Registrierung wird angefordert...","waiting %WARP_WAIT%s...":"warte %WARP_WAIT%s...","%C_WARN%  [*] no verified WARP IP.%C_RST%":"%C_WARN%  [*] keine verifizierte WARP-IP.%C_RST%","      warp-cli errors land in %STATE_DIR%\\wcli.log":"      warp-cli-Fehler landen in %STATE_DIR%\\wcli.log","  same IP as before: %IPN%":"  gleiche IP wie zuvor: %IPN%","%C_OK%  New exit IP: %IPN% (WARP verified)%C_RST%":"%C_OK%  Neue Exit-IP: %IPN% (WARP verifiziert)%C_RST%","  --- resume stderr ---":"  --- stderr des Fortsetzens ---","  --- resume stdout ---":"  --- stdout des Fortsetzens ---","  downloading the WARP installer, about 60 MB...":"  WARP-Installer wird geladen, ca. 60 MB...","%C_WARN%  [*] download failed.%C_RST%":"%C_WARN%  [*] Download fehlgeschlagen.%C_RST%","      grab it by hand and run it: %WARP_MSI_URL%":"      lade ihn manuell herunter und starte ihn: %WARP_MSI_URL%","  installing, accept the UAC prompt...":"  Installation, best\u00e4tige die UAC-Abfrage...","  [auto-install] the standalone build did not install, trying npm.":"  [auto-install] die eigenst\u00e4ndige Version wurde nicht installiert, es wird npm versucht.","  [i] 32-bit Windows: no standalone build - installing via npm.":"  [i] 32-Bit-Windows: keine eigenst\u00e4ndige Version - Installation \u00fcber npm.","%C_OK%  [ok] opencode ready on 32-bit via npm.%C_RST%":"%C_OK%  [ok] opencode auf 32 Bit \u00fcber npm bereit.%C_RST%","%C_ERR%  ERROR: opencode could not be installed on 32-bit Windows.%C_RST%":"%C_ERR%  FEHLER: opencode konnte auf 32-Bit-Windows nicht installiert werden.%C_RST%","         Install 32-bit node.js by hand from nodejs.org, then run:":"         Installiere node.js 32 Bit manuell von nodejs.org und f\u00fchre dann aus:","         npm i -g opencode-ai":"         npm i -g opencode-ai","%C_WARN%  [*] could not read the official release info from opencode.ai.%C_RST%":"%C_WARN%  [*] offizielle Versionsinfos von opencode.ai konnten nicht gelesen werden.%C_RST%","  [auto-install] downloading opencode %OCA_VER% (official build, %OC_AFILE%)...":"  [auto-install] opencode %OCA_VER% (offizielle Version, %OC_AFILE%) wird geladen...","%C_WARN%    [*] checksum mismatch - the download is not the official file.%C_RST%":"%C_WARN%    [*] Pr\u00fcfsumme stimmt nicht - der Download ist nicht die offizielle Datei.%C_RST%","%C_WARN%    [*] download failed.%C_RST%":"%C_WARN%    [*] Download fehlgeschlagen.%C_RST%","  [auto-install] unpacking, about 200 MB on disk...":"  [auto-install] wird entpackt, ca. 200 MB auf der Festplatte...","  [auto-install] installing %NPMPKG% with npm...":"  [auto-install] %NPMPKG% wird mit npm installiert...","  [npm] the install script was blocked - running it by hand...":"  [npm] das Installationsskript wurde blockiert - wird von Hand ausgef\u00fchrt...","  [auto-install] node.js (32-bit) is missing - installing it...":"  [auto-install] node.js (32 Bit) fehlt - wird installiert...","    via winget...":"    \u00fcber winget...","  [i] this can take a few minutes on its first run.":"  [i] das kann beim ersten Mal ein paar Minuten dauern.","    winget failed - trying the MSI installer from nodejs.org...":"    winget fehlgeschlagen - es wird das MSI von nodejs.org versucht...","    downloading %NODE_MSI_URL% ...":"    %NODE_MSI_URL% wird geladen ...","    direct download failed - retrying through the Windows proxy settings...":"    direkter Download fehlgeschlagen - erneuter Versuch \u00fcber die Windows-Proxy-Einstellungen...","    installing, accept the UAC prompt...":"    Installation, best\u00e4tige die UAC-Abfrage...","  opencode update available: %OCUPD_CUR% -> %OCUPD_LAT%":"  opencode-Update verf\u00fcgbar: %OCUPD_CUR% -> %OCUPD_LAT%","  It closes every running opencode process first.":"  Es schlie\u00dft zuerst alle laufenden opencode-Prozesse.","  [update] npm i -g @opencode/cli@latest":"  [update] npm i -g @opencode/cli@latest","  [update] official standalone build %OCUPD_LAT%":"  [update] offizielle eigenst\u00e4ndige Version %OCUPD_LAT%","%C_WARN%  [*] \"%OC_CMD%\" reports %OC_VER% but this machine has a v2 database.%C_RST%":"%C_WARN%  [*] \"%OC_CMD%\" meldet %OC_VER%, aber dieser Rechner hat eine v2-Datenbank.%C_RST%","      A v1 binary cannot open it: \"Database is not empty and has no session table\".":"      Ein v1-Programm kann sie nicht \u00f6ffnen: \"Database is not empty and has no session table\".","      Update it:  npm i -g @opencode/cli@latest   (or accept the update offer)":"      Aktualisiere es:  npm i -g @opencode/cli@latest   (oder nimm das Update-Angebot an)","%C_WARN%  [*] WARP registration missing - creating a new one.%C_RST%":"%C_WARN%  [*] WARP-Registrierung fehlt - eine neue wird erstellt.%C_RST%","  [tor] nothing answering on :%TOR_HTTP_PORT% - portable setup starting...":"  [tor] nichts antwortet auf :%TOR_HTTP_PORT% - portable Einrichtung startet...","%C_WARN%  [*] Tor did not become ready - the reason is in \"%TOR_DIR%\\tor.log\"%C_RST%":"%C_WARN%  [*] Tor wurde nicht bereit - der Grund steht in \"%TOR_DIR%\\tor.log\"%C_RST%","%C_WARN%  [*] the Tor download did not land. Grab it by hand:%C_RST%":"%C_WARN%  [*] der Tor-Download ist nicht angekommen. Lade ihn manuell herunter:%C_RST%","      https://dist.torproject.org/torbrowser/":"      https://dist.torproject.org/torbrowser/","      unpack the tor-expert-bundle tar.gz into \"%TOR_DIR%\",":"      entpacke das tor-expert-bundle tar.gz nach \"%TOR_DIR%\",","      so that \"%TOR_DIR%\\Tor\\tor.exe\" exists, then run this again.":"      sodass \"%TOR_DIR%\\Tor\\tor.exe\" existiert, und starte dann erneut.","%C_OK%  [tor] ready: SOCKS :%TOR_SOCKS_PORT% - HTTP :%TOR_HTTP_PORT%.%C_RST%":"%C_OK%  [tor] bereit: SOCKS :%TOR_SOCKS_PORT% - HTTP :%TOR_HTTP_PORT%.%C_RST%","  [tor] updater JSON unavailable - falling back to the dist index...":"  [tor] Updater-JSON nicht verf\u00fcgbar - R\u00fcckgriff auf den Verteilungsindex...","%C_WARN%  [*] the Tor bundle did not download.%C_RST%":"%C_WARN%  [*] das Tor-Paket wurde nicht geladen.%C_RST%","  [tor] unpacking...":"  [tor] wird entpackt...","%C_OK%  [ok] Tor installed - portable - in \"%TOR_DIR%\".%C_RST%":"%C_OK%  [ok] Tor installiert - portabel - in \"%TOR_DIR%\".%C_RST%","%C_WARN%  [*] the bundle unpacked but tor.exe was not found in \"%TOR_DIR%\".%C_RST%":"%C_WARN%  [*] das Paket wurde entpackt, aber tor.exe wurde in \"%TOR_DIR%\" nicht gefunden.%C_RST%","  [tor] a Tor is already running on :%TOR_SOCKS_PORT% - using it as it is.":"  [tor] ein Tor l\u00e4uft bereits auf :%TOR_SOCKS_PORT% - wird so verwendet.","  [tor] starting tor (hidden window, log: \"%OC_TORLOG%\")...":"  [tor] tor wird gestartet (verstecktes Fenster, Protokoll: \"%OC_TORLOG%\")...","%C_WARN%  [*] tor could not be started - see \"%OC_TORERR%\" and \"%OC_TORLOG%\".%C_RST%":"%C_WARN%  [*] tor konnte nicht gestartet werden - siehe \"%OC_TORERR%\" und \"%OC_TORLOG%\".%C_RST%","  [tor] starting the built-in HTTP->SOCKS bridge on :%TOR_HTTP_PORT% (no Privoxy needed)...":"  [tor] eingebaute HTTP->SOCKS-Br\u00fccke auf :%TOR_HTTP_PORT% wird gestartet (ohne Privoxy)...","  [tor] bootstrapping, up to %TOR_BOOTSTRAP_WAIT%s (the first run takes longer)...":"  [tor] Verbindungsaufbau, bis zu %TOR_BOOTSTRAP_WAIT%s (das erste Mal dauert l\u00e4nger)...","  [tor] Tor is up and routing through the bridge.":"  [tor] Tor l\u00e4uft und leitet \u00fcber die Br\u00fccke.","  [tor] still not up after %TOR_BOOTSTRAP_WAIT%s.":"  [tor] nach %TOR_BOOTSTRAP_WAIT%s noch nicht bereit.","  [tor] found a Tor Browser SOCKS on :9150 - using it.":"  [tor] Tor-Browser-SOCKS auf :9150 gefunden - wird verwendet.","  [tor] found a Tor SOCKS on :9050 - using it.":"  [tor] Tor-SOCKS auf :9050 gefunden - wird verwendet.","  [*] this Tor was not started by the launcher - it cannot be renewed":"  [*] dieses Tor wurde nicht vom Launcher gestartet - es kann von hier aus","      from here. Restart Tor Browser yourself, or pick [1] WARP / [4] NONE.":"      nicht erneuert werden. Starte den Tor Browser selbst neu oder w\u00e4hle [1] WARP / [4] NONE.","  WARP proxy is not answering - cannot verify the exit IP.":"  WARP-Proxy antwortet nicht - Exit-IP kann nicht gepr\u00fcft werden.","  same IP as the last run, requesting a new registration...":"  gleiche IP wie beim letzten Mal, neue Registrierung wird angefordert...","  [%EN_TRIES%] dropping the old registration...":"  [%EN_TRIES%] alte Registrierung wird gel\u00f6scht...","  [%EN_TRIES%] new registration...":"  [%EN_TRIES%] neue Registrierung...","  [%EN_TRIES%] reconnecting WARP proxy...":"  [%EN_TRIES%] WARP-Proxy wird neu verbunden...","  [%EN_TRIES%] waiting %WARP_WAIT%s...":"  [%EN_TRIES%] warte %WARP_WAIT%s...","  exit IP: %CUR%":"  Exit-IP: %CUR%","  no new IP after %ROTATE_TRIES_MAX% tries, launching on the current one.":"  keine neue IP nach %ROTATE_TRIES_MAX% Versuchen, Start mit der aktuellen.","  [note] opencode log not found: \"%LOGFILE%\"":"  [note] opencode-Protokoll nicht gefunden: \"%LOGFILE%\"","         auto-detect stays off until the log appears.":"         die automatische Erkennung bleibt aus, bis das Protokoll erscheint.","  OpenCode desktop update available: %DVER% -> %OCA_VER%":"  Update der OpenCode-Desktop-App verf\u00fcgbar: %DVER% -> %OCA_VER%","  It closes every OpenCode process first, the app and its service included.":"  Es schlie\u00dft zuerst alle OpenCode-Prozesse, auch die App und ihren Dienst.","  downloading the OpenCode desktop installer %OCA_VER%, about 250 MB...":"  OpenCode-Desktop-Installer %OCA_VER% wird geladen, ca. 250 MB...","  [*] checksum mismatch - the download is not the official file.":"  [*] Pr\u00fcfsumme stimmt nicht - der Download ist nicht die offizielle Datei.","  [*] download failed.":"  [*] Download fehlgeschlagen.","      grab it by hand and run it: %ID_URL%":"      lade ihn manuell herunter und starte ihn: %ID_URL%","      or from the website: https://opencode.ai/download":"      oder von der Website: https://opencode.ai/download","  installing, accept the UAC prompt if one appears...":"  Installation, best\u00e4tige die UAC-Abfrage, falls sie erscheint...","  [*] could not read the official release info from opencode.ai.":"  [*] offizielle Versionsinfos von opencode.ai konnten nicht gelesen werden.","      get the installer by hand: https://opencode.ai/download":"      hol den Installer manuell: https://opencode.ai/download","  [*] the desktop app has no 32-bit Windows build.":"  [*] die Desktop-App gibt es nicht f\u00fcr 32-Bit-Windows.","[verify] egress: %EGRESS%":"[verify] Ausgang: %EGRESS%","[verify] ip=%IPN% warp=%WFLAG%":"[verify] ip=%IPN% warp=%WFLAG%","[verify] Cloudflare WARP is not installed (warp-cli not found).":"[verify] Cloudflare WARP ist nicht installiert (warp-cli nicht gefunden).","[renew] egress: %EGRESS%":"[renew] Ausgang: %EGRESS%","[renew] new exit IP: %IPN%":"[renew] neue Exit-IP: %IPN%","[renew] Cloudflare WARP is not installed (warp-cli not found).":"[renew] Cloudflare WARP ist nicht installiert (warp-cli nicht gefunden).","[renew] proxy: %ACTIVE_PROXY%":"[renew] Proxy: %ACTIVE_PROXY%","[renew] done":"[renew] fertig","[renew] could not get a working connection":"[renew] keine funktionierende Verbindung erhalten","  archiving chats to:":"  Chats werden archiviert in:","  nothing to archive.":"  nichts zu archivieren.","  archived.":"  archiviert.","  [*] could not move the storage folder - it stays where it is.":"  [*] Speicherordner konnte nicht verschoben werden - er bleibt, wo er ist.","  [*] could not copy %1 - it stays where it is.":"  [*] %1 konnte nicht kopiert werden - er bleibt, wo er ist.","  [*] size mismatch on %1 - the bad copy is deleted, the original stays.":"  [*] Gr\u00f6\u00dfe bei %1 stimmt nicht - die fehlerhafte Kopie wird gel\u00f6scht, das Original bleibt.","  cache and tokens cleared.":"  Cache und Tokens gel\u00f6scht.","  auth.json archived in \"%TARGET%\".":"  auth.json archiviert in \"%TARGET%\".","  [*] the auth.json copy did not verify - tokens are left in place.":"  [*] die Kopie von auth.json lie\u00df sich nicht pr\u00fcfen - Tokens bleiben an Ort und Stelle.","  [*] could not copy auth.json - tokens are left in place.":"  [*] auth.json konnte nicht kopiert werden - Tokens bleiben an Ort und Stelle.","  [*] no archive folder for this reset - auth.json is left in place.":"  [*] kein Archivordner f\u00fcr diesen Reset - auth.json bleibt an Ort und Stelle.","  [*] the WARP port answers SOCKS5 only, and OpenCode cannot use SOCKS.":"  [*] der WARP-Port spricht nur SOCKS5, und OpenCode kann kein SOCKS.","      WARP is up, but no usable HTTP proxy can be handed to it.":"      WARP l\u00e4uft, aber es kann kein brauchbarer HTTP-Proxy an OpenCode \u00fcbergeben werden.","  [proxy] process-only: %ACTIVE_PROXY%":"  [proxy] nur Prozess: %ACTIVE_PROXY%","  [proxy] reading the proxy list...":"  [proxy] Proxy-Liste wird gelesen...","  [proxy] %PCOUNT% proxies in the list":"  [proxy] %PCOUNT% Proxys in der Liste","  [*] no proxies found in \"%PSRC%\"":"  [*] keine Proxys in \"%PSRC%\" gefunden","  [*] no proxy passed the API check, but %TRACE_ONLY% did reach Cloudflare.":"  [*] kein Proxy hat die API-Pr\u00fcfung bestanden, aber %TRACE_ONLY% hat Cloudflare erreicht.","      PROXY_API_CHECK_URL may be wrong - see the settings block.":"      PROXY_API_CHECK_URL ist vielleicht falsch - siehe Einstellungsblock.","  [proxy] live: %ACTIVE_PROXY%":"  [proxy] aktiv: %ACTIVE_PROXY%","  [*] OpenCode-Infinite is already open in another window.":"  [*] OpenCode-Infinite ist schon in einem anderen Fenster ge\u00f6ffnet.","  Exiting.":"  Beende.","  [upd] repo copy is %SU_RV%, older than %SU_LV% - keeping this one.":"  [upd] die Repo-Kopie ist %SU_RV%, \u00e4lter als %SU_LV% - diese wird behalten.","  [upd] launcher matches the repo, %SU_LV%.":"  [upd] Launcher entspricht dem Repo, %SU_LV%.","  [upd] update found: local %SU_LV% - repo %SU_RV%":"  [upd] Update gefunden: lokal %SU_LV% - Repo %SU_RV%","  [upd] swapping in %SU_RV% - this window closes now.":"  [upd] Austausch gegen %SU_RV% - dieses Fenster schlie\u00dft jetzt.","  [upd] the swap could not be prepared - keeping %SU_LV%.":"  [upd] der Austausch konnte nicht vorbereitet werden - %SU_LV% bleibt.","        The downloaded copy is in \"%SU_TMP%\".":"        Die heruntergeladene Kopie liegt in \"%SU_TMP%\".","  Press any key to close this window.":"  Beliebige Taste dr\u00fccken, um dieses Fenster zu schlie\u00dfen.","Automatic rotation":"Automatische Rotation","On: a limit or a closed opencode gets a new IP and the chat resumes. Off: the menu decides.":"An: Ein Limit oder ein geschlossenes opencode bekommt eine neue IP, und der Chat wird fortgesetzt. Aus: das Men\u00fc entscheidet.","Target country":"Zielland","Keep asking for IPs until one is in this country, e.g. DE. Empty = any new IP.":"Weiter IPs anfordern, bis eine in diesem Land ist, z. B. DE. Leer = jede neue IP.","Target IP prefix":"Ziel-IP-Pr\u00e4fix","Keep asking until the IP starts with this, e.g. 104.28. Empty = not used.":"Weiter fragen, bis die IP damit beginnt, z. B. 104.28. Leer = nicht verwendet.","Max attempts per hunt":"Max. Versuche pro Suche","New IPs requested in one hunt. The hunt stops at this count.":"Neue IPs, die in einer Suche angefordert werden. Die Suche stoppt bei dieser Anzahl.","Max minutes per hunt":"Max. Minuten pro Suche","The hunt stops after this many minutes.":"Die Suche stoppt nach so vielen Minuten.","Seconds between attempts":"Sekunden zwischen den Versuchen","Pause between two attempts, so Cloudflare is not hit too fast.":"Pause zwischen zwei Versuchen, damit Cloudflare nicht zu schnell angefragt wird.","Activity log":"Aktivit\u00e4tsprotokoll","Record what the launcher does in launcher.log so a problem can be diagnosed.":"Schreibt, was der Launcher tut, in launcher.log, damit sich ein Problem diagnostizieren l\u00e4sst.","Log size limit (KB)":"Gr\u00f6\u00dfenlimit des Protokolls (KB)","The log is cut to its newest part when it grows past this.":"Das Protokoll wird auf den neuesten Teil gek\u00fcrzt, wenn es dar\u00fcber hinaus w\u00e4chst.","Hide IPs in reports":"IPs in Berichten ausblenden","Public IP addresses are masked in the support report.":"\u00d6ffentliche IP-Adressen werden im Support-Bericht maskiert.","config.json could not be read; a copy was kept as config.json.broken and defaults are in use.":"config.json konnte nicht gelesen werden; eine Kopie wurde als config.json.broken gespeichert, und es werden Standardwerte verwendet.","Two letters, like DE or US. Empty = any country.":"Zwei Buchstaben, wie DE oder US. Leer = jedes Land.","The start of an IPv4 address, like 104.28. Empty = any IP.":"Der Anfang einer IPv4-Adresse, wie 104.28. Leer = jede IP.","Value: {0}":"Wert: {0}"," Back":" Zur\u00fcck","Windows Terminal settings.json was not found.":"Windows-Terminal-settings.json nicht gefunden.","settings.json was left untouched: the edit would not have kept it valid.":"settings.json blieb unver\u00e4ndert: die \u00c4nderung h\u00e4tte sie ung\u00fcltig gemacht.","Windows Terminal font put back as it was. Reopen the tab if it does not change.":"Windows-Terminal-Schrift zur\u00fcckgesetzt. \u00d6ffne den Tab neu, wenn sich nichts \u00e4ndert.","Windows Terminal font set to ":"Windows-Terminal-Schrift gesetzt auf",". Backup of settings.json: ":". Sicherung von settings.json:","The Windows font API could not be loaded.":"Die Windows-Schrift-API konnte nicht geladen werden.","This window does not allow changing the font from here.":"Dieses Fenster erlaubt hier keine Schrift\u00e4nderung.","The font was never changed, nothing to restore.":"Die Schrift wurde nie ge\u00e4ndert, es gibt nichts zur\u00fcckzusetzen.","Windows refused that font in this console.":"Windows hat diese Schrift in dieser Konsole abgelehnt.","This console refused \"":"Diese Konsole hat \"","\" and kept \"":"\" abgelehnt und \"","\". Older classic consoles only take the fonts Windows registers for them (":"\" behalten. \u00c4ltere klassische Konsolen akzeptieren nur die Schriften, die Windows f\u00fcr sie registriert (","). Windows Terminal accepts any installed font.":"). Windows Terminal akzeptiert jede installierte Schrift.","Console font set to ":"Konsolenschrift gesetzt auf",". It lasts while this window is open and is applied again at every launcher start.":". Sie gilt, solange dieses Fenster offen ist, und wird bei jedem Start des Launchers erneut angewendet.","This terminal keeps its font in its own settings (VS Code: terminal.integrated.fontFamily).":"Dieses Terminal speichert seine Schrift in den eigenen Einstellungen (VS Code: terminal.integrated.fontFamily).","Could not change the font: ":"Schrift konnte nicht ge\u00e4ndert werden:"," The setting was not changed.":" Die Einstellung wurde nicht ge\u00e4ndert.","Enter, arrows":"Enter, Pfeile"," Connect with opencode":" Mit opencode verbinden"," CLI":" CLI"," Desktop app":" Desktop-App"," Exit":" Beenden","There is no saved folder yet. Use one of the other options once.":"Noch kein Ordner gespeichert. Verwende einmal eine der anderen Optionen.","Cloudflare":"Cloudflare","bridge :":"Br\u00fccke :","CLI / Desktop":"CLI / Desktop","Automatic (follow Windows)":"Automatisch (wie Windows)","Use the language Windows is set to on every start; English when there is no translation.":"Verwendet bei jedem Start die Sprache von Windows; Englisch, wenn es keine \u00dcbersetzung gibt."," (detected)":" (erkannt)","Detected from Windows and selected. You can change it in Settings, Appearance.":"Aus Windows erkannt und ausgew\u00e4hlt. Du kannst es unter Einstellungen, Darstellung \u00e4ndern.","You can change it in Settings, Appearance.":"Du kannst es unter Einstellungen, Darstellung \u00e4ndern.","Choose your language":"W\u00e4hle deine Sprache"," Launch OpenCode":" OpenCode starten"," Renew session":" Sitzung erneuern"," Uninstall":" Deinstallieren"," Support report":" Support-Bericht","not a url":"keine URL","Sessions":"Sitzungen","Pick a chat from this folder and continue it. CLI only.":"W\u00e4hle einen Chat aus diesem Ordner und setze ihn fort. Nur CLI.","The desktop app has no session list. Switch to CLI to pick a chat.":"Die Desktop-App hat keine Sitzungsliste. Wechsle zu CLI, um einen Chat auszuw\u00e4hlen.","Could not read the sessions: {0}":"Sitzungen konnten nicht gelesen werden: {0}","No sessions in this folder yet.":"In diesem Ordner gibt es noch keine Sitzungen.","Untitled session":"Sitzung ohne Titel","Sessions in this folder":"Sitzungen in diesem Ordner","  [9] Sessions      - continue a chat from this folder":"  [9] Sitzungen      - einen Chat aus diesem Ordner fortsetzen","Change IP (test)":"IP wechseln (Test)","Clear tokens and cache, then start":"Tokens und Cache l\u00f6schen, dann starten","keeps chats":"Chats bleiben","Deep reset or restore chats":"Tiefes Zur\u00fccksetzen oder Chats wiederherstellen","submenu":"Untermen\u00fc","Mode (CLI or Desktop)":"Modus (CLI oder Desktop)","New IP and start OpenCode":"Neue IP und OpenCode starten","Kill opencode, save the login file to the Desktop, clear the cache, then open OpenCode. Chats stay where they are.":"Beendet opencode, speichert die Anmeldedatei auf dem Desktop, leert den Cache und \u00f6ffnet OpenCode. Chats bleiben, wo sie sind.","Rotate the connection only, without opening OpenCode.":"Wechselt nur die Verbindung, ohne OpenCode zu \u00f6ffnen.","Deep reset moves your chats to the Desktop and clears tokens and cache. Restore brings chats back from an earlier reset.":"Tiefes Zur\u00fccksetzen verschiebt deine Chats auf den Desktop und l\u00f6scht Tokens und Cache. Wiederherstellen holt Chats aus einem fr\u00fcheren Zur\u00fccksetzen zur\u00fcck.","Move your chats to the Desktop archive, clear tokens and cache, then start fresh.":"Verschiebt deine Chats ins Desktop-Archiv, l\u00f6scht Tokens und Cache und startet neu.","Restore chats":"Chats wiederherstellen","from the Desktop":"vom Desktop","Bring chats back from an earlier deep reset.":"Holt Chats aus einem fr\u00fcheren tiefen Zur\u00fccksetzen zur\u00fcck.","Return to the deep reset menu.":"Zur\u00fcck zum Men\u00fc f\u00fcr tiefes Zur\u00fccksetzen.","Return to the home screen.":"Zur\u00fcck zum Startbildschirm.","Restore chats from a backup":"Chats aus einer Sicherung wiederherstellen","No archived chats yet. A deep reset creates one on the Desktop.":"Noch keine archivierten Chats. Ein tiefes Zur\u00fccksetzen legt einen auf dem Desktop an.","{0} file":"{0} Datei","{0} files":"{0} Dateien","Windows Terminal font size set to {0}. Reopen the tab if it does not change.":"Schriftgr\u00f6\u00dfe von Windows Terminal auf {0} gesetzt. Tab neu \u00f6ffnen, wenn sich nichts \u00e4ndert.","Restore now?":"Jetzt wiederherstellen?","  Nothing to restore in that backup.":"  In dieser Sicherung gibt es nichts wiederherzustellen.","  Restore the chats from:":"  Chats wiederherstellen aus:","  The chats in place now are moved to the Desktop first. Nothing is deleted.":"  Die aktuellen Chats werden zuerst auf den Desktop verschoben. Nichts wird gel\u00f6scht.","  [*] some storage files did not copy. The backup is untouched.":"  [*] einige Speicherdateien wurden nicht kopiert. Die Sicherung ist unver\u00e4ndert.","  Chats restored. The previous ones are in:":"  Chats wiederhergestellt. Die vorherigen liegen in:"}
#>>>LANG es {" move   Enter select   Esc back   1-9 or letter jump":" mover   Intro elegir   Esc volver   1-9 o letra para saltar","(Enter = keep \"{0}\")":"(Intro = mantener \"{0}\")","(auto)":"(auto)","(nothing saved yet)":"(nada guardado todav\u00eda)","(terminal default)":"(predeterminada del terminal)","* = changed from the default. Enter edits or toggles the selected value.":"* = distinto del valor por defecto. Intro edita o alterna el valor seleccionado.","A downloaded list smaller than this is rejected. 0 = off.":"Una lista descargada m\u00e1s peque\u00f1a que esto se rechaza. 0 = desactivado.","A port is a number from 1 to 65535.":"Un puerto es un n\u00famero del 1 al 65535.","A proxy must also reach the opencode API host.":"Un proxy debe alcanzar tambi\u00e9n el servidor de la API de opencode.","API check URL":"URL de comprobaci\u00f3n de la API","Accent colors of the interface.":"Colores de acento de la interfaz.","Adding the command to your PATH":"A\u00f1adiendo el comando al PATH","Adds: opencode command (shim), two shortcuts, one PATH entry. Backups are kept.":"A\u00f1ade: el comando opencode (shim), dos accesos directos y una entrada en el PATH. Se guardan copias de seguridad.","Any installed font name, for example Cascadia Code.":"Cualquier nombre de fuente instalada, por ejemplo Cascadia Code.","Appearance":"Apariencia","Applies at the {0}.":"Se aplica en: {0}.","Apply":"Aplicar","Apply setup":"Aplicar configuraci\u00f3n","Ask every time":"Preguntar siempre","Attempts per round when the tunnel is not up.":"Intentos por ronda cuando el t\u00fanel no est\u00e1 activo.","Back":"Volver","Backing up the current configuration":"Copia de seguridad de la configuraci\u00f3n actual","Browse for a folder...":"Buscar una carpeta...","Burned IPs allowed":"IPs quemadas permitidas","Burned proxies before Tor offer":"Proxies quemados antes de ofrecer Tor","Burned proxies in a row before PROXY mode offers Tor.":"Proxies quemados seguidos antes de que el modo PROXY ofrezca Tor.","CLI terminal, Desktop app, or ask at every start.":"Terminal CLI, aplicaci\u00f3n de escritorio, o preguntar en cada inicio.","Cancel":"Cancelar","Cancel. Nothing is changed.":"Cancelar. No se cambia nada.","Change IP":"Cambiar IP","Change an answer.":"Cambiar una respuesta.","Change any launcher setting: connection, proxies, Tor, rotation, themes, font. Applied right away.":"Cambia cualquier ajuste del launcher: conexi\u00f3n, proxies, Tor, rotaci\u00f3n, temas, fuente. Se aplica al instante.","Check GitHub for a newer launcher at every start.":"Busca en GitHub un launcher m\u00e1s nuevo en cada inicio.","Check the API host":"Comprobar el servidor de la API","Checking that it works":"Comprobando que funciona","Checking the connection":"Comprobando la conexi\u00f3n","Choose \"Renew session\" below. It gets a new IP and clears the saved login;":"Elige \"Renovar sesi\u00f3n\" abajo. Obtiene una IP nueva y borra el inicio de sesi\u00f3n guardado;","Choose a folder to work in":"Elige una carpeta de trabajo","Choose one of: {0}.":"Elige uno de: {0}.","Choose the connection for OpenCode":"Elige la conexi\u00f3n para OpenCode","Close the launcher.":"Cerrar el launcher.","Closes every running opencode process.":"Cierra todos los procesos de opencode en ejecuci\u00f3n.","Cloudflare WARP in local proxy mode. Every rotation asks for a new registration, which gives a new exit IP. Needs the WARP client (offered if missing).":"Cloudflare WARP en modo proxy local. Cada rotaci\u00f3n pide un registro nuevo, que da una IP de salida nueva. Necesita el cliente WARP (se ofrece si falta).","Cloudflare WARP in proxy mode. A new registration gives a new exit IP. Rotation supported.":"Cloudflare WARP en modo proxy. Un registro nuevo da una IP de salida nueva. Admite rotaci\u00f3n.","Cloudflare throttles rapid registrations.":"Cloudflare limita los registros seguidos.","Collect system info, versions, settings and the recent log into one text file you can send for help. Passwords, tokens, your user name and (by default) IPs are removed first.":"Re\u00fane informaci\u00f3n del sistema, versiones, ajustes y el registro reciente en un archivo de texto que puedes enviar para pedir ayuda. Antes se eliminan contrase\u00f1as, tokens, tu nombre de usuario y (por defecto) las IPs.","Color theme":"Tema de color","Color theme, colors on or off, icon and border style, and the terminal font. Applied immediately.":"Tema de color, colores activados o no, estilo de iconos y bordes, idioma y fuente del terminal. Se aplica al instante.","Colors":"Colores","Command":"Comando","Configured - {0}":"Configurado - {0}","Confirm":"Confirmar","Connect with opencode":"Conectar con opencode","Connected: opencode now starts through {0}.":"Conectado: opencode ahora arranca a trav\u00e9s de {0}.","Connecting opencode":"Conectando opencode","Connection":"Conexi\u00f3n","Connection method":"M\u00e9todo de conexi\u00f3n","Continue":"Continuar","Continue WITHOUT the probe this session (IPs accepted untested)?":"\u00bfContinuar SIN la prueba en esta sesi\u00f3n (IPs aceptadas sin probar)?","Continue anyway?":"\u00bfContinuar de todos modos?","Continue direct?":"\u00bfContinuar en directo?","Continue without WARP?":"\u00bfContinuar sin WARP?","Cooldown between attempts (s)":"Espera entre intentos (s)","Copies auth.json to your Desktop, then clears the saved tokens.":"Copia auth.json a tu Escritorio y borra los tokens guardados.","Copy the file path":"Copiar la ruta del archivo","Creating shortcuts":"Creando accesos directos","Creating the opencode command":"Creando el comando opencode","Credentials inside a URL are not stored. Use a local file instead.":"Las credenciales dentro de una URL no se guardan. Usa un archivo local.","Deep reset":"Reinicio total","Default connection method and run mode, the WARP proxy port and the warp-cli timings.":"M\u00e9todo de conexi\u00f3n y modo de ejecuci\u00f3n por defecto, puerto del proxy WARP y tiempos de warp-cli.","Default: {0}.":"Por defecto: {0}.","Desktop":"Escritorio","Desktop app":"Aplicaci\u00f3n de escritorio","Desktop app location, release metadata URL and lookup timeouts.":"Ubicaci\u00f3n de la aplicaci\u00f3n de escritorio, URL de metadatos de versiones y tiempos de b\u00fasqueda.","Desktop app path":"Ruta de la aplicaci\u00f3n de escritorio","Direct, no proxy":"Directo, sin proxy","Do it now.":"Hacerlo ahora.","Do that now?":"\u00bfHacerlo ahora?","Download and install it now?":"\u00bfDescargarla e instalarla ahora?","Download the portable Tor bundle when nothing answers.":"Descarga el Tor portable cuando nada responde.","Egress":"Salida","Egress used for opencode. ASK shows the picker at every start.":"Salida que usa opencode. ASK muestra el selector en cada inicio.","Enter a full URL (http, https, ftp or file).":"Escribe una URL completa (http, https, ftp o file).","Enter a whole number.":"Escribe un n\u00famero entero.","Enter cycles: {0}.":"Intro recorre: {0}.","Enter toggles it.":"Intro lo activa o desactiva.","Every change is saved at once to {0}":"Cada cambio se guarda al instante en {0}","Exit":"Salir","Exit IP":"IP de salida","Extra rounds (60 s apart) before giving up.":"Rondas extra (con 60 s de separaci\u00f3n) antes de rendirse.","Folder":"Carpeta","Font name":"Nombre de la fuente","Font of the terminal text. Empty leaves the terminal as it is.":"Fuente del texto del terminal. Vac\u00edo deja el terminal como est\u00e1.","Font size":"Tama\u00f1o de fuente","Free HTTP proxies from your list (any format) or the default one. Each is tested before use.":"Proxies HTTP gratuitos de tu lista (cualquier formato) o de la lista por defecto. Cada uno se prueba antes de usarlo.","Free or your own list":"Gratuita o tu propia lista","Fresh start":"Inicio nuevo","Full path of OpenCode.exe. Empty = search automatically.":"Ruta completa de OpenCode.exe. Vac\u00edo = buscar autom\u00e1ticamente.","Get a new IP or proxy, then open OpenCode. Your chats and history stay untouched.":"Obt\u00e9n una IP o proxy nuevo y abre OpenCode. Tus chats e historial no cambian.","Gets a new IP / WARP registration / Tor circuit / proxy.":"Obtiene una IP nueva / registro WARP / circuito Tor / proxy.","Go ahead.":"Adelante.","Go back. Nothing is changed.":"Volver. No se cambia nada.","Guided setup: choose WARP, Tor, a proxy list or direct, then get an \"opencode\" command and a shortcut that start with it. It is tested at the end.":"Asistente: elige WARP, Tor, una lista de proxies o conexi\u00f3n directa, y obt\u00e9n un comando \"opencode\" y un acceso directo que arrancan con ella. Se prueba al final.","HTTP port of the built-in bridge opencode uses.":"Puerto HTTP del puente integrado que usa opencode.","Host used by the API check.":"Servidor que usa la comprobaci\u00f3n de la API.","How do you want to run OpenCode?":"\u00bfC\u00f3mo quieres ejecutar OpenCode?","How many proxies to test before giving up.":"Cu\u00e1ntos proxies probar antes de rendirse.","How many times, and how fast, a new IP is requested when the free limit is hit.":"Cu\u00e1ntas veces y a qu\u00e9 ritmo se pide una IP nueva al llegar al l\u00edmite gratuito.","IPs the probe may reject before giving up. 0 = no limit.":"IPs que la prueba puede rechazar antes de rendirse. 0 = sin l\u00edmite.","Icons and borders":"Iconos y bordes","Install Tor automatically":"Instalar Tor autom\u00e1ticamente","Keep the current connection and open OpenCode as it was.":"Mantiene la conexi\u00f3n actual y abre OpenCode como estaba.","Keep the current font.":"Mantener la fuente actual.","Kill opencode and clear the saved tokens, keeping your chats where they are.":"Cierra opencode y borra los tokens guardados, dejando tus chats donde est\u00e1n.","Kill opencode, move your chats to the Desktop, clear the saved tokens and open a fresh session.":"Cierra opencode, mueve tus chats al Escritorio, borra los tokens guardados y abre una sesi\u00f3n nueva.","Language":"Idioma","Language of the menus and descriptions. auto follows Windows. Logs and the support report stay in English.":"Idioma de los men\u00fas y descripciones. auto sigue a Windows. Los registros y el informe de soporte se quedan en ingl\u00e9s.","Last check":"\u00daltima comprobaci\u00f3n","Launch OpenCode":"Iniciar OpenCode","Launcher":"Launcher","Launcher self-update":"Autoactualizaci\u00f3n del launcher","Leave the setup without changing anything.":"Salir del asistente sin cambiar nada.","Leave the terminal font as it is. If the launcher changed it, the original font comes back.":"Deja la fuente del terminal como est\u00e1. Si el launcher la cambi\u00f3, vuelve la original.","Local Tor with a built-in HTTP bridge. A portable Tor is installed automatically if missing.":"Tor local con un puente HTTP integrado. Si falta, se instala un Tor portable autom\u00e1ticamente.","Local port of the WARP proxy.":"Puerto local del proxy WARP.","Logs":"Registros","Main menu":"Men\u00fa principal","Method":"M\u00e9todo","Minimum list size (bytes)":"Tama\u00f1o m\u00ednimo de la lista (bytes)","Mode":"Modo","Model used by the IP probe.":"Modelo que usa la prueba de IP.","Must be between {0} and {1}.":"Debe estar entre {0} y {1}.","New IP and resume in 5s":"IP nueva y reanudar en 5 s","No":"No","No .exe file exists at that path.":"No hay ning\u00fan archivo .exe en esa ruta.","No answer in {0}s counts as No.":"Sin respuesta en {0} s cuenta como No.","No change.":"Sin cambios.","No proxy: opencode uses your real connection and nothing is rotated.":"Sin proxy: opencode usa tu conexi\u00f3n real y no se rota nada.","No, cancel":"No, cancelar","Non-limit probe failures before the hunt stops.":"Fallos de la prueba que no son del l\u00edmite antes de parar la b\u00fasqueda.","Not a URL, and no file exists at that path.":"No es una URL y no existe ning\u00fan archivo en esa ruta.","Not configured":"Sin configurar","Nothing to ask for a direct connection.":"No hay nada que preguntar para una conexi\u00f3n directa.","Nothing was left half done that Uninstall cannot remove. Fix the problem and run setup again.":"No qued\u00f3 nada a medias que Desinstalar no pueda quitar. Arregla el problema y ejecuta el asistente otra vez.","On PATH":"En el PATH","Only opencode uses it; the rest of the system stays direct.":"Solo opencode la usa; el resto del sistema sigue en directo.","Open the Windows folder picker and choose where to work.":"Abre el selector de carpetas de Windows para elegir d\u00f3nde trabajar.","Open the folder":"Abrir la carpeta","Open the launcher menus: pick a folder and a connection method, then start the opencode CLI or the desktop app.":"Abre los men\u00fas del launcher: elige carpeta y m\u00e9todo de conexi\u00f3n, y arranca la CLI de opencode o la aplicaci\u00f3n de escritorio.","OpenCode app":"App de OpenCode","PATH lookup timeout (s)":"Tiempo m\u00e1ximo de b\u00fasqueda en el PATH (s)","Paths":"Rutas","Port {0} is already used by {1}.":"El puerto {0} ya lo usa {1}.","Ports and install behavior of the portable Tor the launcher starts for you.":"Puertos e instalaci\u00f3n del Tor portable que el launcher arranca por ti.","Press any key to continue...":"Pulsa una tecla para continuar...","Probe":"Prueba","Probe failures tolerated":"Fallos de prueba tolerados","Probe model":"Modelo de prueba","Proxies tried per pick":"Proxies probados por elecci\u00f3n","Proxy":"Proxy","Proxy list":"Lista de proxies","Proxy list source":"Origen de la lista de proxies","Proxy test timeout (s)":"Tiempo m\u00e1ximo de prueba de un proxy (s)","Public HTTP proxies from a list (yours, in any format, or the free default). Each one is tested first and burned ones are skipped.":"Proxies HTTP p\u00fablicos de una lista (la tuya, en cualquier formato, o la gratuita por defecto). Cada uno se prueba primero y los quemados se saltan.","Put every setting back to its default. Your connection setup (command, shortcuts) is not touched. Asks first.":"Devuelve todos los ajustes a su valor por defecto. Tu configuraci\u00f3n de conexi\u00f3n (comando, accesos directos) no se toca. Pide confirmaci\u00f3n.","Put the full path on the clipboard.":"Pone la ruta completa en el portapapeles.","Quotes and line breaks are not allowed.":"No se permiten comillas ni saltos de l\u00ednea.","Range {0} to {1}.":"Rango de {0} a {1}.","Reconfigure (run setup again)":"Reconfigurar (ejecutar el asistente otra vez)","Release metadata URL":"URL de metadatos de versiones","Removes only what setup added: the opencode command, the shortcuts and the PATH entry.":"Elimina solo lo que a\u00f1adi\u00f3 el asistente: el comando opencode, los accesos directos y la entrada del PATH.","Removes only what the setup added (command, shortcuts, PATH entry) and restores the settings it changed. Backups are kept. Asks first.":"Elimina solo lo que a\u00f1adi\u00f3 el asistente (comando, accesos directos, entrada del PATH) y restaura los ajustes que cambi\u00f3. Se conservan las copias de seguridad. Pide confirmaci\u00f3n.","Removing shortcuts":"Eliminando accesos directos","Removing the opencode command":"Eliminando el comando opencode","Renew did not finish (code {0}).":"La renovaci\u00f3n no termin\u00f3 (c\u00f3digo {0}).","Renew session":"Renovar sesi\u00f3n","Renew the session?":"\u00bfRenovar la sesi\u00f3n?","Renewed. Open opencode again; you may need to log in once more.":"Renovada. Abre opencode otra vez; quiz\u00e1 tengas que iniciar sesi\u00f3n de nuevo.","Renewing":"Renovando","Renewing the session":"Renovando la sesi\u00f3n","Reopen the last folder":"Reabrir la \u00faltima carpeta","Report ready. Personal data was removed; read it once before you share it.":"Informe listo. Se eliminaron los datos personales; l\u00e9elo una vez antes de compartirlo.","Repository":"Repositorio","Reset every setting to its default?":"\u00bfDevolver todos los ajustes a su valor por defecto?","Reset to default values":"Restablecer valores por defecto","Restores the settings setup changed. Your other settings and your opencode files are kept.":"Restaura los ajustes que cambi\u00f3 el asistente. Tus otros ajustes y tus archivos de opencode se conservan.","Restoring PATH":"Restaurando el PATH","Restoring settings":"Restaurando ajustes","Resume message":"Mensaje de reanudaci\u00f3n","Resume timeout (s)":"Tiempo m\u00e1ximo de reanudaci\u00f3n (s)","Return to the connection details.":"Volver a los detalles de la conexi\u00f3n.","Return to the main menu.":"Volver al men\u00fa principal.","Return to the settings groups.":"Volver a los grupos de ajustes.","Review":"Resumen","Rotate the connection only (new WARP registration, Tor circuit or proxy) without opening OpenCode.":"Rota solo la conexi\u00f3n (registro WARP, circuito Tor o proxy nuevo) sin abrir OpenCode.","Rotate when a fatal error appears while opencode runs.":"Rota cuando aparece un error grave mientras opencode se ejecuta.","Rotation":"Rotaci\u00f3n","Rotation attempts":"Intentos de rotaci\u00f3n","Rotation rounds":"Rondas de rotaci\u00f3n","Run mode":"Modo de ejecuci\u00f3n","Run opencode in this terminal. After a new IP the chat resumes by itself.":"Ejecuta opencode en este terminal. Tras una IP nueva el chat se reanuda solo.","Run the OpenCode desktop app ({0}). It is restarted after every new IP.":"Ejecuta la aplicaci\u00f3n de escritorio de OpenCode ({0}). Se reinicia tras cada IP nueva.","Run the setup again to change the method or repair the opencode command.":"Ejecuta el asistente otra vez para cambiar el m\u00e9todo o reparar el comando opencode.","SOCKS port of the Tor the launcher starts.":"Puerto SOCKS del Tor que arranca el launcher.","Save the settings, create the opencode command, the shortcuts and the PATH entry, then test the connection.":"Guarda los ajustes, crea el comando opencode, los accesos directos y la entrada del PATH, y prueba la conexi\u00f3n.","Saved: {0} = {1}":"Guardado: {0} = {1}","Saving config.json":"Guardando config.json","Seconds a single \"where\" lookup may take.":"Segundos que puede tardar una b\u00fasqueda con \"where\".","Seconds a single proxy test may take.":"Segundos que puede tardar la prueba de un proxy.","Seconds a single warp-cli call may take.":"Segundos que puede tardar una llamada a warp-cli.","Seconds before a silent resume counts as a dead IP.":"Segundos antes de que una reanudaci\u00f3n sin respuesta cuente como IP muerta.","Seconds to wait after (re)connecting WARP.":"Segundos de espera tras (re)conectar WARP.","Seconds to wait for Tor to finish bootstrapping.":"Segundos de espera a que Tor termine de arrancar.","See what the setup installed (command, shortcuts, PATH) and run it again to change the method.":"Mira lo que instal\u00f3 el asistente (comando, accesos directos, PATH) y ejec\u00fatalo otra vez para cambiar el m\u00e9todo.","Send one cheap message through each candidate IP.":"Env\u00eda un mensaje barato por cada IP candidata.","Sent automatically after a rotation.":"Se env\u00eda autom\u00e1ticamente tras una rotaci\u00f3n.","Settings":"Ajustes","Settings and setup":"Ajustes y configuraci\u00f3n","Setup 1/3 - connection method":"Configuraci\u00f3n 1/3 - m\u00e9todo de conexi\u00f3n","Setup 2/3 - details":"Configuraci\u00f3n 2/3 - detalles","Setup 3/3 - run mode":"Configuraci\u00f3n 3/3 - modo de ejecuci\u00f3n","Setup stopped: {0}":"El asistente se detuvo: {0}","Shortcuts":"Accesos directos","Show the CLI or Desktop choice every time the launcher opens.":"Muestra la elecci\u00f3n CLI o Escritorio cada vez que se abre el launcher.","Show the report in Explorer so you can attach or paste it.":"Muestra el informe en el Explorador para que puedas adjuntarlo o pegarlo.","Size used with the chosen font.":"Tama\u00f1o que se usa con la fuente elegida.","Support":"Soporte","Support report":"Informe de soporte","Switch between the terminal and the desktop app.":"Cambia entre el terminal y la aplicaci\u00f3n de escritorio.","Switch to Tor and keep going?":"\u00bfCambiar a Tor y seguir?","System":"Sistema","Takes effect at the {0}; a service already running keeps the old value until then.":"Surte efecto en: {0}; un servicio que ya est\u00e9 en marcha conserva el valor anterior hasta entonces.","Terminal font":"Fuente del terminal","Test every new IP":"Probar cada IP nueva","The OpenCode desktop app was not found. Choosing this offers to download and install it.":"No se encontr\u00f3 la aplicaci\u00f3n de escritorio de OpenCode. Al elegirla se ofrece descargarla e instalarla.","The OpenCode desktop app; it is restarted after every new IP.":"La aplicaci\u00f3n de escritorio de OpenCode; se reinicia tras cada IP nueva.","The activity log (launcher.log) and the support report: what is recorded, how big it may grow, whether IPs are masked.":"El registro de actividad (launcher.log) y el informe de soporte: qu\u00e9 se guarda, cu\u00e1nto puede crecer y si se ocultan las IPs.","The cheap test message sent through every new IP before it is trusted.":"El mensaje de prueba barato que se env\u00eda por cada IP nueva antes de fiarse de ella.","The check failed (code {0}). Setup is saved; fix the cause and use Renew or Connect again.":"La comprobaci\u00f3n fall\u00f3 (c\u00f3digo {0}). La configuraci\u00f3n est\u00e1 guardada; arregla la causa y usa Renovar o Conectar otra vez.","The font applies to the whole terminal window, not only to this launcher.":"La fuente se aplica a toda la ventana del terminal, no solo a este launcher.","The proxy lives only in the opencode process; the rest of the system stays direct.":"El proxy vive solo en el proceso de opencode; el resto del sistema sigue en directo.","The resume auto-approves tool permissions.":"La reanudaci\u00f3n aprueba sola los permisos de las herramientas.","The shortcut and the opencode command use the CLI; this is the launcher menu default.":"El acceso directo y el comando opencode usan la CLI; esto es lo predeterminado del men\u00fa del launcher.","The terminal interface. The opencode command and the shortcut always use it.":"La interfaz de terminal. El comando opencode y el acceso directo siempre la usan.","This launcher is not the one that set it up. Reconfigure to repair the command.":"Este launcher no es el que lo configur\u00f3. Reconfigura para reparar el comando.","Token reset":"Reinicio de tokens","Tools and versions":"Herramientas y versiones","Tor HTTP bridge port":"Puerto del puente HTTP de Tor","Tor SOCKS port":"Puerto SOCKS de Tor","Tor bootstrap wait (s)":"Espera de arranque de Tor (s)","Tor is downloaded once, run hidden and offered to opencode through a built-in HTTP bridge. Slower, but a new circuit is a new IP.":"Tor se descarga una vez, se ejecuta oculto y se ofrece a opencode mediante un puente HTTP integrado. M\u00e1s lento, pero un circuito nuevo es una IP nueva.","Try again in a minute, or pick another connection method in Connect with opencode.":"Int\u00e9ntalo de nuevo en un minuto, o elige otro m\u00e9todo de conexi\u00f3n en Conectar con opencode.","Try again?":"\u00bfIntentarlo de nuevo?","Try to download and install WARP now?":"\u00bfIntentar descargar e instalar WARP ahora?","Type \"opencode\" in a NEW terminal, or use the \"OpenCode Infinite (egress)\" shortcut.":"Escribe \"opencode\" en un terminal NUEVO, o usa el acceso directo \"OpenCode Infinite (egress)\".","Type < to go back. Enter keeps the value shown.":"Escribe < para volver. Intro mantiene el valor mostrado.","Type a font name...":"Escribir el nombre de una fuente...","URL or local file, any format (plain, CSV, JSON, XML, HTML).":"URL o archivo local, en cualquier formato (texto plano, CSV, JSON, XML, HTML).","Unattended resume":"Reanudaci\u00f3n desatendida","Uninstall":"Desinstalar","Uninstall stopped: {0}":"La desinstalaci\u00f3n se detuvo: {0}","Uninstall the opencode connection?":"\u00bfDesinstalar la conexi\u00f3n de opencode?","Uninstalled. Backups stay in {0}":"Desinstalado. Las copias de seguridad quedan en {0}","Uninstalling":"Desinstalando","Update now?":"\u00bfActualizar ahora?","Updates":"Actualizaciones","Use 1 to 200 characters.":"Usa de 1 a 200 caracteres.","Use it when the free limit is hit or the login expired: closes opencode, saves and clears the saved tokens, and gets a new IP, WARP registration, Tor circuit or proxy.":"\u00dasala cuando se alcance el l\u00edmite gratuito o caduque el inicio de sesi\u00f3n: cierra opencode, guarda y borra los tokens guardados, y obtiene una IP, registro WARP, circuito Tor o proxy nuevo.","Use on or off.":"Usa on u off.","Use that proxy anyway?":"\u00bfUsar ese proxy de todos modos?","Use this folder":"Usar esta carpeta","Use up to 31 characters, without quotes or backslashes.":"Usa hasta 31 caracteres, sin comillas ni barras invertidas.","Use {0} for the terminal text. Monospaced fonts only look right.":"Usa {0} para el texto del terminal. Solo las fuentes monoespaciadas se ven bien.","Version":"Versi\u00f3n","View and change every launcher option: connection, proxies, Tor, rotation, themes. Saved instantly, no files to edit.":"Mira y cambia cualquier opci\u00f3n del launcher: conexi\u00f3n, proxies, Tor, rotaci\u00f3n, temas. Se guarda al instante, sin editar archivos.","WARP proxy port":"Puerto del proxy WARP","WARP wait (s)":"Espera de WARP (s)","Watch the log":"Vigilar el registro","Watcher":"Vigilante","Watching the opencode log and the automatic \"continue\" sent after a rotation.":"Vigilancia del registro de opencode y del \"continue\" autom\u00e1tico tras una rotaci\u00f3n.","Where proxies come from (URL or file, any format) and how each one is tested.":"De d\u00f3nde vienen los proxies (URL o archivo, cualquier formato) y c\u00f3mo se prueba cada uno.","Where versions and checksums are read from.":"De d\u00f3nde se leen las versiones y las sumas de verificaci\u00f3n.","Whether the launcher checks GitHub for a newer copy of itself at every start.":"Si el launcher busca en GitHub una copia m\u00e1s nueva de s\u00ed mismo en cada inicio.","Work in a different folder.":"Trabajar en otra carpeta.","Work in the folder the launcher was started from: {0}":"Trabajar en la carpeta desde la que se inici\u00f3 el launcher: {0}","Work in {0}":"Trabajar en {0}","Writing the report":"Escribiendo el informe","Yes":"S\u00ed","Yes, continue":"S\u00ed, continuar","Your connection setup (shim, shortcuts) is not touched.":"Tu configuraci\u00f3n de conexi\u00f3n (shim, accesos directos) no se toca.","Your session needs renewing: {0}":"Tu sesi\u00f3n necesita renovarse: {0}","asks first":"pide confirmaci\u00f3n","auto":"auto","auto follows the terminal and NO_COLOR; off disables colors.":"auto sigue al terminal y a NO_COLOR; off desactiva los colores.","direct":"directo","emoji = modern terminals, unicode = classic console, ascii = anything.":"emoji = terminales modernos, unicode = consola cl\u00e1sica, ascii = cualquiera.","free list":"lista gratuita","installed":"instalada","missing":"falta","new IP":"IP nueva","next Tor start":"pr\u00f3ximo arranque de Tor","next WARP connect":"pr\u00f3xima conexi\u00f3n de WARP","next launch":"pr\u00f3ximo inicio","no other step is needed.":"no hace falta ning\u00fan otro paso.","not installed":"no instalada","not verified":"sin verificar","off":"desactivado","on":"activado","same IP":"misma IP","terminal":"terminal","warp-cli timeout (s)":"Tiempo m\u00e1ximo de warp-cli (s)","yes":"s\u00ed","{0} changed":"{0} cambiados","{0} of {1}":"{0} de {1}","After opencode closes":"opencode al cerrarse","ask = R, M or Q: R gets a new IP and resumes the chat, M opens the menu, Q quits. quit = leave the launcher at once.":"ask = R, M o Q: R pide una IP nueva y retoma el chat, M abre el men\u00fa, Q sale. quit = cierra el lanzador de inmediato.","Rotate key":"Tecla de rotar","Menu key":"Tecla de men\u00fa","Quit key":"Tecla de salir","Closed-opencode prompt: new IP and resume the chat.":"Aviso al cerrar opencode: nueva IP y seguir el chat.","Closed-opencode prompt: open the menu.":"Aviso al cerrar opencode: abrir el men\u00fa.","Closed-opencode prompt: quit. Ctrl+C always quits too.":"Aviso al cerrar opencode: salir. Ctrl+C tambi\u00e9n sale siempre.","The keys of the launcher and the terminal commands. Fixed keys are listed for reference; the three letters can be changed.":"Teclas del lanzador y comandos de terminal. Las teclas fijas se muestran como referencia; las tres letras se pueden cambiar.","One letter, like R.":"Una letra, como R.","Key {0} is already used by {1}.":"La tecla {0} ya la usa {1}.","Only the chosen language is downloaded from the langs folder of the repository.":"Solo se descarga el idioma elegido de la carpeta langs del repositorio.","Follow the language Windows uses.":"Usa el idioma de Windows.","Use this language for every menu and message.":"Usa este idioma en todos los men\u00fas y mensajes.","Keep the current language.":"Mantener el idioma actual.","File to write (Enter = Desktop, Esc = back)":"Archivo a escribir (Intro = Escritorio, Esc = volver)","File to read (Esc = back)":"Archivo a leer (Esc = volver)","That folder does not exist.":"Esa carpeta no existe.","Replace the file that is already there?":"\u00bfReemplazar el archivo que ya existe?","Exported {0} changed setting(s) to {1}":"Se exportaron {0} ajuste(s) cambiado(s) a {1}","Import {0} setting(s)? Their current values are replaced.":"\u00bfImportar {0} ajuste(s)? Sus valores actuales se reemplazan.","{0} setting(s) of this file are unknown here and are skipped.":"{0} ajuste(s) de este archivo no existen aqu\u00ed y se omiten.","No file at that path.":"No hay archivo en esa ruta.","This is not an OpenCode Infinite settings file.":"Este archivo no es de ajustes de OpenCode Infinite.","Nothing was imported. These values are not valid:":"No se import\u00f3 nada. Estos valores no son v\u00e1lidos:","Imported {0} setting(s).":"Se importaron {0} ajuste(s).","Export settings to a file":"Exportar ajustes a un archivo","Save every changed setting to one .json file, to keep a backup or copy them to another PC.":"Guarda todos los ajustes cambiados en un archivo .json, para copia de seguridad o para otro PC.","Import settings from a file":"Importar ajustes desde un archivo","Load a file made by Export. Every value is checked first; if one is wrong, nothing changes.":"Carga un archivo hecho con Exportar. Antes se revisa cada valor; si uno es incorrecto, no cambia nada.","back to the previous screen":"volver a la pantalla anterior","Fixed. In a menu or a text prompt Esc goes back; it never closes the launcher.":"Fija. En un men\u00fa o en un campo de texto, Esc vuelve atr\u00e1s; nunca cierra el lanzador.","select and move":"elegir y mover","Fixed. Digits 1-9 jump straight to a row.":"Fija. Los n\u00fameros 1-9 saltan directamente a una fila.","quit the launcher":"cerrar el lanzador","Fixed. Stops the processes it started and leaves the terminal open, no Y/N question.":"Fija. Detiene los procesos que inici\u00f3 y deja la terminal abierta, sin preguntar Y/N.","start with the connection":"iniciar con la conexi\u00f3n","Terminal command from any folder. The Start menu shortcut does the same.":"Comando de terminal desde cualquier carpeta. El acceso directo del men\u00fa Inicio hace lo mismo.","open this menu":"abrir este men\u00fa","Terminal command: opens the launcher menu again, as many times as you need.":"Comando de terminal: vuelve a abrir el men\u00fa del lanzador, tantas veces como haga falta.","original OpenCode":"OpenCode original","Terminal command: starts the OpenCode you installed, without the launcher or the connection. Use it when the launcher breaks.":"Comando de terminal: inicia el OpenCode que instalaste, sin lanzador ni conexi\u00f3n. \u00dasalo si el lanzador falla.","Commands":"Comandos","Adds: the opencode, opencodeinf and opencodeoc commands, two shortcuts, one PATH entry. Backups are kept.":"A\u00f1ade los comandos opencode, opencodeinf y opencodeoc, dos accesos directos y una entrada en PATH. Las copias se conservan.","  This copy is not the official one. Starting the official copy:":"  Esta copia no es la oficial. Iniciando la copia oficial:","  OpenCode - how do you want to run it?":"  OpenCode - \u00bfc\u00f3mo quieres ejecutarlo?","  [1] CLI      - terminal TUI (chat resumes on every new IP)":"  [1] CLI      - TUI de terminal (el chat se reanuda con cada IP nueva)","  [2] Desktop  - the OpenCode desktop app (restarted on every new IP)":"  [2] Desktop  - la app de escritorio de OpenCode (se reinicia con cada IP nueva)","  [3] Exit":"  [3] Salir","  One key, no Enter.":"  Una tecla, sin Enter.","%C_WARN%  [*] OpenCode desktop not found.%C_RST%":"%C_WARN%  [*] No se encontr\u00f3 la app de escritorio de OpenCode.%C_RST%","%C_WARN%  [*] still not found - set OC_APP to its OpenCode.exe.%C_RST%":"%C_WARN%  [*] Sigue sin encontrarse - define OC_APP con la ruta a su OpenCode.exe.%C_RST%","  [app] DESKTOP \"%OC_DESKTOP%\"":"  [app] DESKTOP \"%OC_DESKTOP%\"","  OpenCode - choose a folder to work in":"  OpenCode - elige una carpeta para trabajar","  [1] Reopen the last folder":"  [1] Reabrir la \u00faltima carpeta","      (nothing saved yet)":"      (a\u00fan no hay nada guardado)","  [2] Use this folder":"  [2] Usar esta carpeta","  [3] Browse for a folder...":"  [3] Buscar una carpeta...","  [4] Exit":"  [4] Salir","  No folder saved yet. Use [2] or [3] this time.":"  A\u00fan no hay carpeta guardada. Usa [2] o [3] esta vez.","  Choose a folder in the dialog...":"  Elige una carpeta en el di\u00e1logo...","  Opening the classic folder picker...":"  Abriendo el selector de carpetas cl\u00e1sico...","  No folder selected.":"  No se seleccion\u00f3 ninguna carpeta.","  Folder not found: \"%OPFOLDER%\"":"  No se encuentra la carpeta: \"%OPFOLDER%\"","  Cannot enter: \"%OPFOLDER%\"":"  No se puede entrar en: \"%OPFOLDER%\"","  Working in: \"%CD%\"":"  Trabajando en: \"%CD%\"","  [egress] %EGRESS% (from your settings)":"  [egress] %EGRESS% (de tus ajustes)","  Choose egress for OpenCode only (system traffic stays direct)":"  Elige la salida solo para OpenCode (el tr\u00e1fico del sistema sigue directo)","  [1] WARP     - Cloudflare WARP proxy mode (rotation supported)":"  [1] WARP     - modo proxy de Cloudflare WARP (admite rotaci\u00f3n)","  [2] TOR      - local Tor + built-in bridge on :%TOR_HTTP_PORT%":"  [2] TOR      - Tor local + puente integrado en :%TOR_HTTP_PORT%","                 (auto-installs a portable Tor, nothing to set up)":"                 (se instala un Tor portable, no hay nada que configurar)","  [3] PROXY    - free HTTP proxies (ProxyScrape list)":"  [3] PROXY    - proxies HTTP gratuitos (lista de ProxyScrape)","  [4] NONE     - direct, no proxy":"  [4] NONE     - directo, sin proxy","  [egress] NONE - direct.":"  [egress] NONE - directo.","  [egress] PROXY - free HTTP list.":"  [egress] PROXY - lista HTTP gratuita.","  [egress] TOR - portable Tor + built-in bridge on :%TOR_HTTP_PORT%, auto-setup.":"  [egress] TOR - Tor portable + puente integrado en :%TOR_HTTP_PORT%, configuraci\u00f3n autom\u00e1tica.","  [egress] WARP.":"  [egress] WARP.","  [dep] curl":"  [dep] curl","  [dep] warp":"  [dep] warp","%C_WARN%  [*] Cloudflare WARP not found - IP rotation will be disabled.%C_RST%":"%C_WARN%  [*] No se encontr\u00f3 Cloudflare WARP - la rotaci\u00f3n de IP quedar\u00e1 desactivada.%C_RST%","      Install it later from 1.1.1.1 if you want the rotation.":"      Inst\u00e1lalo m\u00e1s tarde desde 1.1.1.1 si quieres la rotaci\u00f3n.","%C_WARN%  [*] WARP still not available - continuing without rotation.%C_RST%":"%C_WARN%  [*] WARP sigue sin estar disponible - se contin\u00faa sin rotaci\u00f3n.%C_RST%","      warp-cli errors, if any, are in %STATE_DIR%\\wcli.log":"      Los errores de warp-cli, si los hay, est\u00e1n en %STATE_DIR%\\wcli.log","%C_WARN%  [*] Cloudflare WARP publishes 64-bit Windows builds only.%C_RST%":"%C_WARN%  [*] Cloudflare WARP solo publica versiones de 64 bits para Windows.%C_RST%","      On this 32-bit system rotation is disabled.":"      En este sistema de 32 bits la rotaci\u00f3n est\u00e1 desactivada.","%C_OK%  [ok] WARP ready.%C_RST%":"%C_OK%  [ok] WARP listo.%C_RST%","  [dep] opencode":"  [dep] opencode","  [auto-install] opencode not found, fetching it...":"  [auto-install] no se encontr\u00f3 opencode, descarg\u00e1ndolo...","%C_OK%  [ok] opencode ready.%C_RST%":"%C_OK%  [ok] opencode listo.%C_RST%","%C_ERR%  ERROR: opencode install failed or is not on PATH.%C_RST%":"%C_ERR%  ERROR: la instalaci\u00f3n de opencode fall\u00f3 o no est\u00e1 en PATH.%C_RST%","  Get it by hand: https://github.com/sst/opencode/releases":"  Inst\u00e1lalo a mano: https://github.com/sst/opencode/releases","  Preparing the connection...":"  Preparando la conexi\u00f3n...","  OpenCode":"  OpenCode","  Folder : \"%CD%\"":"  Carpeta : \"%CD%\"","  Egress : %EGRESS%":"  Salida  : %EGRESS%","  Mode   : %APP_MODE%":"  Modo    : %APP_MODE%","  WARP   : none (rotation disabled)":"  WARP    : ninguno (rotaci\u00f3n desactivada)","  WARP   : \"%WARP%\"":"  WARP    : \"%WARP%\"","  Version: %OC_VER%  \"%OC_CMD%\"":"  Versi\u00f3n : %OC_VER%  \"%OC_CMD%\"","  Exit IP: %IP%":"  IP de salida: %IP%","  What do you want to do?":"  \u00bfQu\u00e9 quieres hacer?","  [1] Fresh start   - get a new IP / proxy, then open OpenCode":"  [1] Inicio nuevo - obtener una IP / proxy nuevo, luego abrir OpenCode","                      (your chats and history stay untouched)":"                      (tus chats e historial no se tocan)","  [2] Continue      - same egress, open OpenCode as it was":"  [2] Continuar    - misma salida, abrir OpenCode como estaba","  [3] Change IP     - rotate / pick new proxy only":"  [3] Cambiar IP   - solo rotar / elegir un proxy nuevo","  [5] Deep reset    - kill opencode, move chats to the Desktop,":"  [5] Reinicio total - cerrar opencode, mover los chats al Escritorio,","                      clear saved tokens, open a fresh session":"                      borrar los tokens guardados, abrir una sesi\u00f3n nueva","  [6] Exit":"  [6] Salir","  [7] Token reset   - kill opencode, clear saved tokens, keep chats":"  [7] Reinicio de tokens - cerrar opencode, borrar los tokens guardados,","                      where they are, open a fresh session":"                      los chats se quedan donde est\u00e1n, abrir una sesi\u00f3n nueva","  [8] Settings      - change any launcher setting, applied right away":"  [8] Ajustes      - cambiar cualquier ajuste, se aplica al momento","--- deep reset -----------------------------------------------":"--- reinicio total ---------------------------------------------","  This closes opencode, moves your chats to the Desktop,":"  Esto cierra opencode, mueve tus chats al Escritorio,","  clears the saved tokens and opens a brand new session.":"  borra los tokens guardados y abre una sesi\u00f3n nueva.","  It is the only action in this script that touches your files.":"  Es la \u00fanica acci\u00f3n de este script que toca tus archivos.","  It also kills EVERY opencode process on this computer,":"  Tambi\u00e9n cierra TODOS los procesos opencode de este equipo,","  including windows opened by hand or by another launcher.":"  incluidas las ventanas abiertas a mano o por otro launcher.","--- token reset ----------------------------------------------":"--- reinicio de tokens ------------------------------------------","  This closes opencode, clears the saved tokens and opens a":"  Esto cierra opencode, borra los tokens guardados y abre una","  brand new session. Your chats are NOT moved.":"  sesi\u00f3n nueva. Tus chats NO se mueven.","  auth.json is copied to the Desktop first, then removed.":"  auth.json se copia primero al Escritorio y luego se borra.","    egress: %EGRESS%":"    salida: %EGRESS%","%C_WARN%  [*] WARP proxy is not answering - rotation has no effect.%C_RST%":"%C_WARN%  [*] El proxy de WARP no responde - la rotaci\u00f3n no tiene efecto.%C_RST%","      Going direct would run opencode on your real IP.":"      Salir directo har\u00eda que opencode use tu IP real.","%C_WARN%  [*] Tor did not get ready.%C_RST%":"%C_WARN%  [*] Tor no se prepar\u00f3.%C_RST%","%C_WARN%  [*] no working free proxy found.%C_RST%":"%C_WARN%  [*] no se encontr\u00f3 ning\u00fan proxy gratuito que funcione.%C_RST%","%C_WARN%  [*] the egress proxy stopped answering while OpenCode was open:%C_RST%":"%C_WARN%  [*] el proxy de salida dej\u00f3 de responder mientras OpenCode estaba abierto:%C_RST%","      %STATE_DIR%\\proxy_warn.txt":"      %STATE_DIR%\\proxy_warn.txt","%C_WARN%  [watch] a fatal error cut the chat - rotating and resuming it.%C_RST%":"%C_WARN%  [watch] un error fatal cort\u00f3 el chat - rotando y reanud\u00e1ndolo.%C_RST%","OpenCode closed.":"OpenCode cerrado.","  %KEY_ROTATE% = new IP and resume the chat   %KEY_MENU% = menu   %KEY_QUIT% = quit (Ctrl+C also quits)":"  %KEY_ROTATE% = nueva IP y reanudar el chat   %KEY_MENU% = men\u00fa   %KEY_QUIT% = salir (Ctrl+C tambi\u00e9n sale)","Press any key to continue . . .":"Pulsa cualquier tecla para continuar . . .","  [tor] renewing the circuit, attempt %TOR_TRIES% of %ROTATE_TRIES_MAX%...":"  [tor] renovando el circuito, intento %TOR_TRIES% de %ROTATE_TRIES_MAX%...","%C_OK%  [tor] new circuit - resuming.%C_RST%":"%C_OK%  [tor] circuito nuevo - reanudando.%C_RST%","%C_WARN%  [*] Tor could not be renewed - back to menu.%C_RST%":"%C_WARN%  [*] No se pudo renovar Tor - vuelvo al men\u00fa.%C_RST%","%C_WARN%  [*] Tor could not get a usable circuit after %ROTATE_TRIES_MAX% attempts.%C_RST%":"%C_WARN%  [*] Tor no consigui\u00f3 un circuito utilizable tras %ROTATE_TRIES_MAX% intentos.%C_RST%","      The exit node may be blocked: try a new identity in Tor, or":"      El nodo de salida puede estar bloqueado: prueba una identidad nueva en Tor, o","      switch to [1] WARP. warp/tor notes: \"%TOR_DIR%\\tor.log\"":"      cambia a [1] WARP. Notas de warp/tor: \"%TOR_DIR%\\tor.log\"","  [proxy] %ACTIVE_PROXY% is burned - attempt %PROXY_ROT% of %PROXY_ROT_MAX%, picking another...":"  [proxy] %ACTIVE_PROXY% est\u00e1 quemado - intento %PROXY_ROT% de %PROXY_ROT_MAX%, buscando otro...","  [proxy] picking a fresh free proxy before resume...":"  [proxy] buscando un proxy gratuito nuevo antes de reanudar...","%C_WARN%  [*] no free proxy is left that still works (they all hit the limit).%C_RST%":"%C_WARN%  [*] no queda ning\u00fan proxy gratuito que funcione (todos alcanzaron el l\u00edmite).%C_RST%","      Free proxies are shared by many people, so their limit is often used up.":"      Los proxies gratuitos los usa mucha gente, y su l\u00edmite suele estar agotado.","  Automatic rotation is off - the menu decides.":"  La rotaci\u00f3n autom\u00e1tica est\u00e1 desactivada - decide el men\u00fa.","Getting a new IP before the next attempt...":"Obteniendo una IP nueva antes del siguiente intento...","  [i] hunting for %HUNT_GOAL%: up to %TARGET_TRIES% attempts, %TARGET_MINUTES% min. Esc or Q stops.":"  [i] buscando %HUNT_GOAL%: hasta %TARGET_TRIES% intentos, %TARGET_MINUTES% min. Esc o Q para parar.","[%ROTATE_TRIES%/%TARGET_TRIES%] dropping the old registration...":"[%ROTATE_TRIES%/%TARGET_TRIES%] eliminando el registro anterior...","[%ROTATE_TRIES%/%TARGET_TRIES%] new registration...":"[%ROTATE_TRIES%/%TARGET_TRIES%] registro nuevo...","[%ROTATE_TRIES%] reconnect...":"[%ROTATE_TRIES%] reconectando...","[%ROTATE_TRIES%] waiting %WARP_WAIT%s...":"[%ROTATE_TRIES%] esperando %WARP_WAIT%s...","[%ROTATE_TRIES%] %IPN% was already tried in this hunt, rotating again":"[%ROTATE_TRIES%] %IPN% ya se prob\u00f3 en esta b\u00fasqueda, rotando otra vez","[%ROTATE_TRIES%/%TARGET_TRIES%] exit IP %IPN% (country %GLOC%), target %TMATCHTXT%, %HUNT_LEFT% attempt(s) left":"[%ROTATE_TRIES%/%TARGET_TRIES%] IP de salida %IPN% (pa\u00eds %GLOC%), objetivo %TMATCHTXT%, quedan %HUNT_LEFT% intento(s)","[%ROTATE_TRIES%] probing if this IP can still talk...":"[%ROTATE_TRIES%] comprobando si esta IP todav\u00eda puede conectar...","%C_WARN%  [*] probe failed for a reason that is NOT a limit - attempt %PBROKEN% of %PROBE_BROKEN_MAX%. Last output:%C_RST%":"%C_WARN%  [*] la comprobaci\u00f3n fall\u00f3 por una raz\u00f3n que NO es un l\u00edmite - intento %PBROKEN% de %PROBE_BROKEN_MAX%. \u00daltima salida:%C_RST%","[%PROBE_TRIES%] IP already burned, rotating again...":"[%PROBE_TRIES%] IP ya quemada, rotando otra vez...","%C_WARN%  [*] %PROBE_TRIES% IPs probed, every one of them already burned.%C_RST%":"%C_WARN%  [*] %PROBE_TRIES% IPs comprobadas, todas ya quemadas.%C_RST%","%C_WARN%  [*] the probe failed %PBROKEN% times and none of them was a limit error.%C_RST%":"%C_WARN%  [*] la comprobaci\u00f3n fall\u00f3 %PBROKEN% veces y ninguna fue un error de l\u00edmite.%C_RST%","      The probe itself is broken, not every IP: a retired PROBE_MODEL id,":"      El fallo est\u00e1 en la comprobaci\u00f3n, no en todas las IPs: un ID de PROBE_MODEL","      an auth error or a CLI change. Rotation cannot fix that.":"      retirado, un error de autenticaci\u00f3n o un cambio de la CLI.","      Check PROBE_MODEL in the settings block, or run the probe model once":"      Revisa PROBE_MODEL en el bloque de ajustes, o ejecuta el modelo de prueba","      by hand to see the real error.":"      a mano una vez para ver el error real.","  [i] probe off for this session - IPs are accepted on WARP-trace proof":"  [i] comprobaci\u00f3n desactivada en esta sesi\u00f3n - las IPs se aceptan solo","      only, and the resume's own limit check keeps catching burned ones.":"      con la prueba de WARP, y la comprobaci\u00f3n de l\u00edmite al reanudar sigue","%C_WARN%  [*] the probe session \"%OC_PROBE_ID%\" does not exist and this%C_RST%":"%C_WARN%  [*] la sesi\u00f3n de comprobaci\u00f3n \"%OC_PROBE_ID%\" no existe y esta%C_RST%","      opencode build refused it. That is a probe problem, NOT a":"      versi\u00f3n de opencode la rechaz\u00f3. Es un problema de la comprobaci\u00f3n, NO","      burned IP - no rotation can fix it.":"      una IP quemada - ninguna rotaci\u00f3n lo arregla.","  [i] the probe is off for this session: IPs are accepted on":"  [i] la comprobaci\u00f3n est\u00e1 desactivada en esta sesi\u00f3n: las IPs se aceptan","      WARP-trace proof only, and the resume's own limit check still":"      solo con la prueba de WARP, y la comprobaci\u00f3n de l\u00edmite al reanudar","      catches a burned one. To keep the probe, create the session by":"      sigue detectando una quemada. Para mantenerla, crea la sesi\u00f3n a mano","      hand once, or clear PROBE in the settings block.":"      una vez, o borra PROBE en el bloque de ajustes.","%C_OK%[%ROTATE_TRIES%] IP %IPN% works.%C_RST%":"%C_OK%[%ROTATE_TRIES%] la IP %IPN% funciona.%C_RST%","[%ROTATE_TRIES%] no verified WARP IP yet, retrying...":"[%ROTATE_TRIES%] a\u00fan no hay una IP de WARP verificada, reintentando...","%C_WARN%  [*] no usable IP from this hunt. warp-cli errors, if any, are in %STATE_DIR%\\wcli.log%C_RST%":"%C_WARN%  [*] ninguna IP utilizable en esta b\u00fasqueda. Los errores de warp-cli, si los hay, est\u00e1n en %STATE_DIR%\\wcli.log%C_RST%","  restarting the desktop app on the new egress...":"  reiniciando la app de escritorio con la nueva salida...","  sending \"%RESUME_MSG%\" so the chat picks up where it stopped...":"  enviando \"%RESUME_MSG%\" para que el chat contin\u00fae donde se qued\u00f3...","%C_WARN%  [*] proxy dead - retrying on the current egress instead of resuming.%C_RST%":"%C_WARN%  [*] proxy ca\u00eddo - reintentando con la salida actual en lugar de reanudar.%C_RST%","%C_WARN%  [*] no answer in %RESUME_TIMEOUT%s - this exit IP is dead.%C_RST%":"%C_WARN%  [*] sin respuesta en %RESUME_TIMEOUT%s - esta IP de salida est\u00e1 ca\u00edda.%C_RST%","%C_OK%  chat resumed on the new IP.%C_RST%":"%C_OK%  chat reanudado con la nueva IP.%C_RST%","%C_WARN%  [*] the resume itself hit a limit - rotating again.%C_RST%":"%C_WARN%  [*] la reanudaci\u00f3n misma alcanz\u00f3 un l\u00edmite - rotando otra vez.%C_RST%","  Egress is NONE - nothing to rotate.":"  La salida es NONE - no hay nada que rotar.","  Restarting the launcher-managed Tor for a new circuit...":"  Reiniciando el Tor gestionado por el launcher para un circuito nuevo...","  TOR mode - this Tor was started outside the launcher.":"  Modo TOR - este Tor se inici\u00f3 fuera del launcher.","  Restart it yourself for a new circuit, or pick [1] WARP / [4] NONE.":"  Rein\u00edcialo t\u00fa para un circuito nuevo, o elige [1] WARP / [4] NONE.","  Current bridge: http://127.0.0.1:%TOR_HTTP_PORT%":"  Puente actual: http://127.0.0.1:%TOR_HTTP_PORT%","  Picking a new free HTTP proxy...":"  Buscando un proxy HTTP gratuito nuevo...","  New proxy: %ACTIVE_PROXY%":"  Nuevo proxy: %ACTIVE_PROXY%","WARP is not available - nothing to rotate.":"WARP no est\u00e1 disponible - nada que rotar.","Requesting a new WARP registration...":"Pidiendo un registro nuevo de WARP...","waiting %WARP_WAIT%s...":"esperando %WARP_WAIT%s...","%C_WARN%  [*] no verified WARP IP.%C_RST%":"%C_WARN%  [*] no hay una IP de WARP verificada.%C_RST%","      warp-cli errors land in %STATE_DIR%\\wcli.log":"      los errores de warp-cli quedan en %STATE_DIR%\\wcli.log","  same IP as before: %IPN%":"  misma IP que antes: %IPN%","%C_OK%  New exit IP: %IPN% (WARP verified)%C_RST%":"%C_OK%  Nueva IP de salida: %IPN% (WARP verificado)%C_RST%","  --- resume stderr ---":"  --- stderr de la reanudaci\u00f3n ---","  --- resume stdout ---":"  --- stdout de la reanudaci\u00f3n ---","  downloading the WARP installer, about 60 MB...":"  descargando el instalador de WARP, unos 60 MB...","%C_WARN%  [*] download failed.%C_RST%":"%C_WARN%  [*] la descarga fall\u00f3.%C_RST%","      grab it by hand and run it: %WARP_MSI_URL%":"      desc\u00e1rgalo a mano y ejec\u00fatalo: %WARP_MSI_URL%","  installing, accept the UAC prompt...":"  instalando, acepta el aviso de UAC...","  [auto-install] the standalone build did not install, trying npm.":"  [auto-install] la versi\u00f3n independiente no se instal\u00f3, probando con npm.","  [i] 32-bit Windows: no standalone build - installing via npm.":"  [i] Windows de 32 bits: no hay versi\u00f3n independiente - instalando con npm.","%C_OK%  [ok] opencode ready on 32-bit via npm.%C_RST%":"%C_OK%  [ok] opencode listo en 32 bits v\u00eda npm.%C_RST%","%C_ERR%  ERROR: opencode could not be installed on 32-bit Windows.%C_RST%":"%C_ERR%  ERROR: no se pudo instalar opencode en Windows de 32 bits.%C_RST%","         Install 32-bit node.js by hand from nodejs.org, then run:":"         Instala node.js de 32 bits a mano desde nodejs.org, y luego ejecuta:","         npm i -g opencode-ai":"         npm i -g opencode-ai","%C_WARN%  [*] could not read the official release info from opencode.ai.%C_RST%":"%C_WARN%  [*] no se pudo leer la informaci\u00f3n de la versi\u00f3n oficial de opencode.ai.%C_RST%","  [auto-install] downloading opencode %OCA_VER% (official build, %OC_AFILE%)...":"  [auto-install] descargando opencode %OCA_VER% (compilaci\u00f3n oficial, %OC_AFILE%)...","%C_WARN%    [*] checksum mismatch - the download is not the official file.%C_RST%":"%C_WARN%    [*] la suma de comprobaci\u00f3n no coincide - la descarga no es el archivo oficial.%C_RST%","%C_WARN%    [*] download failed.%C_RST%":"%C_WARN%    [*] la descarga fall\u00f3.%C_RST%","  [auto-install] unpacking, about 200 MB on disk...":"  [auto-install] descomprimiendo, unos 200 MB en disco...","  [auto-install] installing %NPMPKG% with npm...":"  [auto-install] instalando %NPMPKG% con npm...","  [npm] the install script was blocked - running it by hand...":"  [npm] el script de instalaci\u00f3n fue bloqueado - ejecut\u00e1ndolo a mano...","  [auto-install] node.js (32-bit) is missing - installing it...":"  [auto-install] falta node.js (32 bits) - instal\u00e1ndolo...","    via winget...":"    v\u00eda winget...","  [i] this can take a few minutes on its first run.":"  [i] esto puede tardar unos minutos la primera vez.","    winget failed - trying the MSI installer from nodejs.org...":"    winget fall\u00f3 - probando con el instalador MSI de nodejs.org...","    downloading %NODE_MSI_URL% ...":"    descargando %NODE_MSI_URL% ...","    direct download failed - retrying through the Windows proxy settings...":"    la descarga directa fall\u00f3 - reintentando con la configuraci\u00f3n de proxy de Windows...","    installing, accept the UAC prompt...":"    instalando, acepta el aviso de UAC...","  opencode update available: %OCUPD_CUR% -> %OCUPD_LAT%":"  hay una actualizaci\u00f3n de opencode: %OCUPD_CUR% -> %OCUPD_LAT%","  It closes every running opencode process first.":"  Antes cierra todos los procesos de opencode en ejecuci\u00f3n.","  [update] npm i -g @opencode/cli@latest":"  [update] npm i -g @opencode/cli@latest","  [update] official standalone build %OCUPD_LAT%":"  [update] compilaci\u00f3n independiente oficial %OCUPD_LAT%","%C_WARN%  [*] \"%OC_CMD%\" reports %OC_VER% but this machine has a v2 database.%C_RST%":"%C_WARN%  [*] \"%OC_CMD%\" informa %OC_VER% pero este equipo tiene una base de datos v2.%C_RST%","      A v1 binary cannot open it: \"Database is not empty and has no session table\".":"      Un binario v1 no puede abrirla: \"Database is not empty and has no session table\".","      Update it:  npm i -g @opencode/cli@latest   (or accept the update offer)":"      Actual\u00edzalo:  npm i -g @opencode/cli@latest   (o acepta la oferta de actualizaci\u00f3n)","%C_WARN%  [*] WARP registration missing - creating a new one.%C_RST%":"%C_WARN%  [*] falta el registro de WARP - creando uno nuevo.%C_RST%","  [tor] nothing answering on :%TOR_HTTP_PORT% - portable setup starting...":"  [tor] nada responde en :%TOR_HTTP_PORT% - iniciando la configuraci\u00f3n portable...","%C_WARN%  [*] Tor did not become ready - the reason is in \"%TOR_DIR%\\tor.log\"%C_RST%":"%C_WARN%  [*] Tor no se prepar\u00f3 - el motivo est\u00e1 en \"%TOR_DIR%\\tor.log\"%C_RST%","%C_WARN%  [*] the Tor download did not land. Grab it by hand:%C_RST%":"%C_WARN%  [*] la descarga de Tor no se complet\u00f3. Desc\u00e1rgalo a mano:%C_RST%","      https://dist.torproject.org/torbrowser/":"      https://dist.torproject.org/torbrowser/","      unpack the tor-expert-bundle tar.gz into \"%TOR_DIR%\",":"      descomprime el tor-expert-bundle tar.gz en \"%TOR_DIR%\",","      so that \"%TOR_DIR%\\Tor\\tor.exe\" exists, then run this again.":"      para que exista \"%TOR_DIR%\\Tor\\tor.exe\", y luego ejecuta esto otra vez.","%C_OK%  [tor] ready: SOCKS :%TOR_SOCKS_PORT% - HTTP :%TOR_HTTP_PORT%.%C_RST%":"%C_OK%  [tor] listo: SOCKS :%TOR_SOCKS_PORT% - HTTP :%TOR_HTTP_PORT%.%C_RST%","  [tor] updater JSON unavailable - falling back to the dist index...":"  [tor] JSON del actualizador no disponible - usando el \u00edndice de distribuci\u00f3n...","%C_WARN%  [*] the Tor bundle did not download.%C_RST%":"%C_WARN%  [*] el paquete de Tor no se descarg\u00f3.%C_RST%","  [tor] unpacking...":"  [tor] descomprimiendo...","%C_OK%  [ok] Tor installed - portable - in \"%TOR_DIR%\".%C_RST%":"%C_OK%  [ok] Tor instalado - portable - en \"%TOR_DIR%\".%C_RST%","%C_WARN%  [*] the bundle unpacked but tor.exe was not found in \"%TOR_DIR%\".%C_RST%":"%C_WARN%  [*] el paquete se descomprimi\u00f3 pero no se encontr\u00f3 tor.exe en \"%TOR_DIR%\".%C_RST%","  [tor] a Tor is already running on :%TOR_SOCKS_PORT% - using it as it is.":"  [tor] ya hay un Tor en marcha en :%TOR_SOCKS_PORT% - us\u00e1ndolo tal cual.","  [tor] starting tor (hidden window, log: \"%OC_TORLOG%\")...":"  [tor] iniciando tor (ventana oculta, registro: \"%OC_TORLOG%\")...","%C_WARN%  [*] tor could not be started - see \"%OC_TORERR%\" and \"%OC_TORLOG%\".%C_RST%":"%C_WARN%  [*] no se pudo iniciar tor - mira \"%OC_TORERR%\" y \"%OC_TORLOG%\".%C_RST%","  [tor] starting the built-in HTTP->SOCKS bridge on :%TOR_HTTP_PORT% (no Privoxy needed)...":"  [tor] iniciando el puente HTTP->SOCKS integrado en :%TOR_HTTP_PORT% (sin Privoxy)...","  [tor] bootstrapping, up to %TOR_BOOTSTRAP_WAIT%s (the first run takes longer)...":"  [tor] conectando, hasta %TOR_BOOTSTRAP_WAIT%s (la primera vez tarda m\u00e1s)...","  [tor] Tor is up and routing through the bridge.":"  [tor] Tor est\u00e1 activo y enrutando por el puente.","  [tor] still not up after %TOR_BOOTSTRAP_WAIT%s.":"  [tor] todav\u00eda no est\u00e1 activo tras %TOR_BOOTSTRAP_WAIT%s.","  [tor] found a Tor Browser SOCKS on :9150 - using it.":"  [tor] se encontr\u00f3 un SOCKS de Tor Browser en :9150 - us\u00e1ndolo.","  [tor] found a Tor SOCKS on :9050 - using it.":"  [tor] se encontr\u00f3 un SOCKS de Tor en :9050 - us\u00e1ndolo.","  [*] this Tor was not started by the launcher - it cannot be renewed":"  [*] este Tor no lo inici\u00f3 el launcher - no se puede renovar","      from here. Restart Tor Browser yourself, or pick [1] WARP / [4] NONE.":"      desde aqu\u00ed. Reinicia Tor Browser t\u00fa mismo, o elige [1] WARP / [4] NONE.","  WARP proxy is not answering - cannot verify the exit IP.":"  El proxy de WARP no responde - no se puede verificar la IP de salida.","  same IP as the last run, requesting a new registration...":"  misma IP que la \u00faltima vez, pidiendo un registro nuevo...","  [%EN_TRIES%] dropping the old registration...":"  [%EN_TRIES%] eliminando el registro anterior...","  [%EN_TRIES%] new registration...":"  [%EN_TRIES%] registro nuevo...","  [%EN_TRIES%] reconnecting WARP proxy...":"  [%EN_TRIES%] reconectando el proxy de WARP...","  [%EN_TRIES%] waiting %WARP_WAIT%s...":"  [%EN_TRIES%] esperando %WARP_WAIT%s...","  exit IP: %CUR%":"  IP de salida: %CUR%","  no new IP after %ROTATE_TRIES_MAX% tries, launching on the current one.":"  no hay IP nueva tras %ROTATE_TRIES_MAX% intentos, se lanza con la actual.","  [note] opencode log not found: \"%LOGFILE%\"":"  [note] no se encontr\u00f3 el registro de opencode: \"%LOGFILE%\"","         auto-detect stays off until the log appears.":"         la detecci\u00f3n autom\u00e1tica se mantiene desactivada hasta que aparezca el registro.","  OpenCode desktop update available: %DVER% -> %OCA_VER%":"  hay una actualizaci\u00f3n de la app de escritorio de OpenCode: %DVER% -> %OCA_VER%","  It closes every OpenCode process first, the app and its service included.":"  Antes cierra todos los procesos de OpenCode, la app y su servicio incluidos.","  downloading the OpenCode desktop installer %OCA_VER%, about 250 MB...":"  descargando el instalador de la app de escritorio de OpenCode %OCA_VER%, unos 250 MB...","  [*] checksum mismatch - the download is not the official file.":"  [*] la suma de comprobaci\u00f3n no coincide - la descarga no es el archivo oficial.","  [*] download failed.":"  [*] la descarga fall\u00f3.","      grab it by hand and run it: %ID_URL%":"      desc\u00e1rgalo a mano y ejec\u00fatalo: %ID_URL%","      or from the website: https://opencode.ai/download":"      o desde la web: https://opencode.ai/download","  installing, accept the UAC prompt if one appears...":"  instalando, acepta el aviso de UAC si aparece uno...","  [*] could not read the official release info from opencode.ai.":"  [*] no se pudo leer la informaci\u00f3n de la versi\u00f3n oficial de opencode.ai.","      get the installer by hand: https://opencode.ai/download":"      consigue el instalador a mano: https://opencode.ai/download","  [*] the desktop app has no 32-bit Windows build.":"  [*] la app de escritorio no tiene versi\u00f3n para Windows de 32 bits.","[verify] egress: %EGRESS%":"[verify] salida: %EGRESS%","[verify] ip=%IPN% warp=%WFLAG%":"[verify] ip=%IPN% warp=%WFLAG%","[verify] Cloudflare WARP is not installed (warp-cli not found).":"[verify] Cloudflare WARP no est\u00e1 instalado (no se encontr\u00f3 warp-cli).","[renew] egress: %EGRESS%":"[renew] salida: %EGRESS%","[renew] new exit IP: %IPN%":"[renew] nueva IP de salida: %IPN%","[renew] Cloudflare WARP is not installed (warp-cli not found).":"[renew] Cloudflare WARP no est\u00e1 instalado (no se encontr\u00f3 warp-cli).","[renew] proxy: %ACTIVE_PROXY%":"[renew] proxy: %ACTIVE_PROXY%","[renew] done":"[renew] listo","[renew] could not get a working connection":"[renew] no se pudo obtener una conexi\u00f3n que funcione","  archiving chats to:":"  archivando los chats en:","  nothing to archive.":"  nada que archivar.","  archived.":"  archivado.","  [*] could not move the storage folder - it stays where it is.":"  [*] no se pudo mover la carpeta de almacenamiento - se queda donde est\u00e1.","  [*] could not copy %1 - it stays where it is.":"  [*] no se pudo copiar %1 - se queda donde est\u00e1.","  [*] size mismatch on %1 - the bad copy is deleted, the original stays.":"  [*] el tama\u00f1o no coincide en %1 - la copia mala se borra, el original se queda.","  cache and tokens cleared.":"  cach\u00e9 y tokens borrados.","  auth.json archived in \"%TARGET%\".":"  auth.json archivado en \"%TARGET%\".","  [*] the auth.json copy did not verify - tokens are left in place.":"  [*] la copia de auth.json no se verific\u00f3 - los tokens se quedan donde est\u00e1n.","  [*] could not copy auth.json - tokens are left in place.":"  [*] no se pudo copiar auth.json - los tokens se quedan donde est\u00e1n.","  [*] no archive folder for this reset - auth.json is left in place.":"  [*] no hay carpeta de archivo para este reinicio - auth.json se queda donde est\u00e1.","  [*] the WARP port answers SOCKS5 only, and OpenCode cannot use SOCKS.":"  [*] el puerto de WARP solo responde SOCKS5, y OpenCode no puede usar SOCKS.","      WARP is up, but no usable HTTP proxy can be handed to it.":"      WARP est\u00e1 activo, pero no se puede entregar a OpenCode ning\u00fan proxy HTTP utilizable.","  [proxy] process-only: %ACTIVE_PROXY%":"  [proxy] solo este proceso: %ACTIVE_PROXY%","  [proxy] reading the proxy list...":"  [proxy] leyendo la lista de proxies...","  [proxy] %PCOUNT% proxies in the list":"  [proxy] %PCOUNT% proxies en la lista","  [*] no proxies found in \"%PSRC%\"":"  [*] no se encontraron proxies en \"%PSRC%\"","  [*] no proxy passed the API check, but %TRACE_ONLY% did reach Cloudflare.":"  [*] ning\u00fan proxy pas\u00f3 la comprobaci\u00f3n de la API, pero %TRACE_ONLY% s\u00ed lleg\u00f3 a Cloudflare.","      PROXY_API_CHECK_URL may be wrong - see the settings block.":"      PROXY_API_CHECK_URL puede estar mal - revisa el bloque de ajustes.","  [proxy] live: %ACTIVE_PROXY%":"  [proxy] en vivo: %ACTIVE_PROXY%","  [*] OpenCode-Infinite is already open in another window.":"  [*] OpenCode-Infinite ya est\u00e1 abierto en otra ventana.","  Exiting.":"  Saliendo.","  [upd] repo copy is %SU_RV%, older than %SU_LV% - keeping this one.":"  [upd] la copia del repo es %SU_RV%, m\u00e1s antigua que %SU_LV% - se conserva esta.","  [upd] launcher matches the repo, %SU_LV%.":"  [upd] el launcher coincide con el repo, %SU_LV%.","  [upd] update found: local %SU_LV% - repo %SU_RV%":"  [upd] actualizaci\u00f3n encontrada: local %SU_LV% - repo %SU_RV%","  [upd] swapping in %SU_RV% - this window closes now.":"  [upd] cambiando a %SU_RV% - esta ventana se cierra ahora.","  [upd] the swap could not be prepared - keeping %SU_LV%.":"  [upd] no se pudo preparar el cambio - se conserva %SU_LV%.","        The downloaded copy is in \"%SU_TMP%\".":"        La copia descargada est\u00e1 en \"%SU_TMP%\".","  Press any key to close this window.":"  Pulsa cualquier tecla para cerrar esta ventana.","Automatic rotation":"Rotaci\u00f3n autom\u00e1tica","On: a limit or a closed opencode gets a new IP and the chat resumes. Off: the menu decides.":"Activada: un l\u00edmite o un opencode cerrado obtiene una IP nueva y el chat se reanuda. Desactivada: decide el men\u00fa.","Target country":"Pa\u00eds objetivo","Keep asking for IPs until one is in this country, e.g. DE. Empty = any new IP.":"Sigue pidiendo IPs hasta que una est\u00e9 en este pa\u00eds, p. ej. DE. Vac\u00edo = cualquier IP nueva.","Target IP prefix":"Prefijo de IP objetivo","Keep asking until the IP starts with this, e.g. 104.28. Empty = not used.":"Sigue pidiendo hasta que la IP empiece por esto, p. ej. 104.28. Vac\u00edo = no se usa.","Max attempts per hunt":"M\u00e1ximo de intentos por b\u00fasqueda","New IPs requested in one hunt. The hunt stops at this count.":"IPs nuevas pedidas en una b\u00fasqueda. La b\u00fasqueda para en este n\u00famero.","Max minutes per hunt":"M\u00e1ximo de minutos por b\u00fasqueda","The hunt stops after this many minutes.":"La b\u00fasqueda para despu\u00e9s de estos minutos.","Seconds between attempts":"Segundos entre intentos","Pause between two attempts, so Cloudflare is not hit too fast.":"Pausa entre dos intentos, para no golpear Cloudflare demasiado r\u00e1pido.","Activity log":"Registro de actividad","Record what the launcher does in launcher.log so a problem can be diagnosed.":"Guarda lo que hace el launcher en launcher.log para poder diagnosticar un problema.","Log size limit (KB)":"L\u00edmite de tama\u00f1o del registro (KB)","The log is cut to its newest part when it grows past this.":"El registro se recorta a su parte m\u00e1s nueva cuando supera este tama\u00f1o.","Hide IPs in reports":"Ocultar IPs en los informes","Public IP addresses are masked in the support report.":"Las IPs p\u00fablicas se enmascaran en el informe de soporte.","config.json could not be read; a copy was kept as config.json.broken and defaults are in use.":"No se pudo leer config.json; se guard\u00f3 una copia como config.json.broken y se usan los valores por defecto.","Two letters, like DE or US. Empty = any country.":"Dos letras, como DE o US. Vac\u00edo = cualquier pa\u00eds.","The start of an IPv4 address, like 104.28. Empty = any IP.":"El inicio de una direcci\u00f3n IPv4, como 104.28. Vac\u00edo = cualquier IP.","Value: {0}":"Valor: {0}"," Back":" Volver","Windows Terminal settings.json was not found.":"No se encontr\u00f3 settings.json de Windows Terminal.","settings.json was left untouched: the edit would not have kept it valid.":"settings.json no se toc\u00f3: el cambio no lo habr\u00eda dejado v\u00e1lido.","Windows Terminal font put back as it was. Reopen the tab if it does not change.":"La fuente de Windows Terminal se restaur\u00f3. Vuelve a abrir la pesta\u00f1a si no cambia.","Windows Terminal font set to ":"Fuente de Windows Terminal cambiada a",". Backup of settings.json: ":". Copia de seguridad de settings.json:","The Windows font API could not be loaded.":"No se pudo cargar la API de fuentes de Windows.","This window does not allow changing the font from here.":"Esta ventana no permite cambiar la fuente desde aqu\u00ed.","The font was never changed, nothing to restore.":"La fuente nunca se cambi\u00f3, no hay nada que restaurar.","Windows refused that font in this console.":"Windows rechaz\u00f3 esa fuente en esta consola.","This console refused \"":"Esta consola rechaz\u00f3 \"","\" and kept \"":"\" y mantuvo \"","\". Older classic consoles only take the fonts Windows registers for them (":"\". Las consolas cl\u00e1sicas antiguas solo aceptan las fuentes que Windows registra para ellas (","). Windows Terminal accepts any installed font.":"). Windows Terminal acepta cualquier fuente instalada.","Console font set to ":"Fuente de la consola cambiada a",". It lasts while this window is open and is applied again at every launcher start.":". Dura mientras esta ventana est\u00e9 abierta y se vuelve a aplicar en cada inicio del launcher.","This terminal keeps its font in its own settings (VS Code: terminal.integrated.fontFamily).":"Esta terminal guarda su fuente en sus propios ajustes (VS Code: terminal.integrated.fontFamily).","Could not change the font: ":"No se pudo cambiar la fuente:"," The setting was not changed.":" El ajuste no se cambi\u00f3.","Enter, arrows":"Enter, flechas"," Connect with opencode":" Conectar con opencode"," CLI":" CLI"," Desktop app":" App de escritorio"," Exit":" Salir","There is no saved folder yet. Use one of the other options once.":"A\u00fan no hay carpeta guardada. Usa una de las otras opciones una vez.","Cloudflare":"Cloudflare","bridge :":"puente :","CLI / Desktop":"CLI / Escritorio","Automatic (follow Windows)":"Autom\u00e1tico (seg\u00fan Windows)","Use the language Windows is set to on every start; English when there is no translation.":"Usa el idioma de Windows en cada inicio; ingl\u00e9s cuando no hay traducci\u00f3n."," (detected)":" (detectado)","Detected from Windows and selected. You can change it in Settings, Appearance.":"Detectado desde Windows y seleccionado. Puedes cambiarlo en Ajustes, Apariencia.","You can change it in Settings, Appearance.":"Puedes cambiarlo en Ajustes, Apariencia.","Choose your language":"Elige tu idioma"," Launch OpenCode":" Iniciar OpenCode"," Renew session":" Renovar sesi\u00f3n"," Uninstall":" Desinstalar"," Support report":" Informe de soporte","not a url":"no es una URL","Sessions":"Sesiones","Pick a chat from this folder and continue it. CLI only.":"Elige un chat de esta carpeta y contin\u00faalo. Solo CLI.","The desktop app has no session list. Switch to CLI to pick a chat.":"La app de escritorio no tiene lista de sesiones. Cambia a CLI para elegir un chat.","Could not read the sessions: {0}":"No se pudieron leer las sesiones: {0}","No sessions in this folder yet.":"Todav\u00eda no hay sesiones en esta carpeta.","Untitled session":"Sesi\u00f3n sin t\u00edtulo","Sessions in this folder":"Sesiones de esta carpeta","  [9] Sessions      - continue a chat from this folder":"  [9] Sesiones      - contin\u00faa un chat de esta carpeta","Change IP (test)":"Cambiar IP (prueba)","Clear tokens and cache, then start":"Borrar tokens y cach\u00e9 y arrancar","keeps chats":"conserva los chats","Deep reset or restore chats":"Reinicio profundo o restaurar chats","submenu":"submen\u00fa","Mode (CLI or Desktop)":"Modo (CLI o Escritorio)","New IP and start OpenCode":"Nueva IP e iniciar OpenCode","Kill opencode, save the login file to the Desktop, clear the cache, then open OpenCode. Chats stay where they are.":"Cierra opencode, guarda el archivo de inicio de sesi\u00f3n en el Escritorio, borra la cach\u00e9 y abre OpenCode. Los chats se quedan donde est\u00e1n.","Rotate the connection only, without opening OpenCode.":"Cambia solo la conexi\u00f3n, sin abrir OpenCode.","Deep reset moves your chats to the Desktop and clears tokens and cache. Restore brings chats back from an earlier reset.":"El reinicio profundo mueve tus chats al Escritorio y borra tokens y cach\u00e9. Restaurar devuelve chats de un reinicio anterior.","Move your chats to the Desktop archive, clear tokens and cache, then start fresh.":"Mueve tus chats al archivo del Escritorio, borra tokens y cach\u00e9, y empieza de cero.","Restore chats":"Restaurar chats","from the Desktop":"desde el Escritorio","Bring chats back from an earlier deep reset.":"Devuelve chats de un reinicio profundo anterior.","Return to the deep reset menu.":"Vuelve al men\u00fa de reinicio profundo.","Return to the home screen.":"Vuelve a la pantalla de inicio.","Restore chats from a backup":"Restaurar chats desde una copia","No archived chats yet. A deep reset creates one on the Desktop.":"A\u00fan no hay chats archivados. Un reinicio profundo crea uno en el Escritorio.","{0} file":"{0} archivo","{0} files":"{0} archivos","Windows Terminal font size set to {0}. Reopen the tab if it does not change.":"El tama\u00f1o de fuente de Windows Terminal es {0}. Vuelve a abrir la pesta\u00f1a si no cambia.","Restore now?":"\u00bfRestaurar ahora?","  Nothing to restore in that backup.":"  No hay nada que restaurar en esa copia.","  Restore the chats from:":"  Restaurar los chats desde:","  The chats in place now are moved to the Desktop first. Nothing is deleted.":"  Los chats actuales se mueven antes al Escritorio. No se borra nada.","  [*] some storage files did not copy. The backup is untouched.":"  [*] algunos archivos de almacenamiento no se copiaron. La copia de seguridad no se ha tocado.","  Chats restored. The previous ones are in:":"  Chats restaurados. Los anteriores est\u00e1n en:"}
#>>>LANG fr {" move   Enter select   Esc back   1-9 or letter jump":" d\u00e9placer   Entr\u00e9e choisir   \u00c9chap retour   1-9 ou lettre pour sauter","(Enter = keep \"{0}\")":"(Entr\u00e9e = garder \"{0}\")","(auto)":"(auto)","(nothing saved yet)":"(rien d'enregistr\u00e9 pour l'instant)","(terminal default)":"(police par d\u00e9faut du terminal)","* = changed from the default. Enter edits or toggles the selected value.":"* = diff\u00e9rent de la valeur par d\u00e9faut. Entr\u00e9e modifie ou bascule la valeur s\u00e9lectionn\u00e9e.","A downloaded list smaller than this is rejected. 0 = off.":"Une liste t\u00e9l\u00e9charg\u00e9e plus petite que cela est rejet\u00e9e. 0 = d\u00e9sactiv\u00e9.","A port is a number from 1 to 65535.":"Un port est un nombre de 1 \u00e0 65535.","A proxy must also reach the opencode API host.":"Un proxy doit aussi atteindre le serveur de l'API d'opencode.","API check URL":"URL de v\u00e9rification de l'API","Accent colors of the interface.":"Couleurs d'accent de l'interface.","Adding the command to your PATH":"Ajout de la commande au PATH","Adds: opencode command (shim), two shortcuts, one PATH entry. Backups are kept.":"Ajoute : la commande opencode (shim), deux raccourcis et une entr\u00e9e PATH. Les sauvegardes sont conserv\u00e9es.","Any installed font name, for example Cascadia Code.":"N'importe quel nom de police install\u00e9e, par exemple Cascadia Code.","Appearance":"Apparence","Applies at the {0}.":"S'applique \u00e0 : {0}.","Apply":"Appliquer","Apply setup":"Appliquer la configuration","Ask every time":"Demander \u00e0 chaque fois","Attempts per round when the tunnel is not up.":"Tentatives par tour quand le tunnel n'est pas actif.","Back":"Retour","Backing up the current configuration":"Sauvegarde de la configuration actuelle","Browse for a folder...":"Choisir un dossier...","Burned IPs allowed":"IP grill\u00e9es autoris\u00e9es","Burned proxies before Tor offer":"Proxys grill\u00e9s avant de proposer Tor","Burned proxies in a row before PROXY mode offers Tor.":"Proxys grill\u00e9s d'affil\u00e9e avant que le mode PROXY propose Tor.","CLI terminal, Desktop app, or ask at every start.":"Terminal CLI, application de bureau, ou demander \u00e0 chaque d\u00e9marrage.","Cancel":"Annuler","Cancel. Nothing is changed.":"Annuler. Rien n'est modifi\u00e9.","Change IP":"Changer d'IP","Change an answer.":"Modifier une r\u00e9ponse.","Change any launcher setting: connection, proxies, Tor, rotation, themes, font. Applied right away.":"Modifie n'importe quel r\u00e9glage du launcher : connexion, proxys, Tor, rotation, th\u00e8mes, police. Appliqu\u00e9 imm\u00e9diatement.","Check GitHub for a newer launcher at every start.":"Cherche sur GitHub un launcher plus r\u00e9cent \u00e0 chaque d\u00e9marrage.","Check the API host":"V\u00e9rifier le serveur de l'API","Checking that it works":"V\u00e9rification du fonctionnement","Checking the connection":"V\u00e9rification de la connexion","Choose \"Renew session\" below. It gets a new IP and clears the saved login;":"Choisissez \u00ab Renouveler la session \u00bb ci-dessous. Cela obtient une nouvelle IP et efface la connexion enregistr\u00e9e ;","Choose a folder to work in":"Choisissez un dossier de travail","Choose one of: {0}.":"Choisissez parmi : {0}.","Choose the connection for OpenCode":"Choisissez la connexion pour OpenCode","Close the launcher.":"Fermer le launcher.","Closes every running opencode process.":"Ferme tous les processus opencode en cours.","Cloudflare WARP in local proxy mode. Every rotation asks for a new registration, which gives a new exit IP. Needs the WARP client (offered if missing).":"Cloudflare WARP en mode proxy local. Chaque rotation demande une nouvelle inscription, ce qui donne une nouvelle IP de sortie. N\u00e9cessite le client WARP (propos\u00e9 s'il manque).","Cloudflare WARP in proxy mode. A new registration gives a new exit IP. Rotation supported.":"Cloudflare WARP en mode proxy. Une nouvelle inscription donne une nouvelle IP de sortie. Rotation prise en charge.","Cloudflare throttles rapid registrations.":"Cloudflare limite les inscriptions rapproch\u00e9es.","Collect system info, versions, settings and the recent log into one text file you can send for help. Passwords, tokens, your user name and (by default) IPs are removed first.":"Rassemble les infos syst\u00e8me, les versions, les r\u00e9glages et le journal r\u00e9cent dans un fichier texte \u00e0 envoyer pour obtenir de l'aide. Mots de passe, jetons, nom d'utilisateur et (par d\u00e9faut) IP sont supprim\u00e9s au pr\u00e9alable.","Color theme":"Th\u00e8me de couleurs","Color theme, colors on or off, icon and border style, and the terminal font. Applied immediately.":"Th\u00e8me de couleurs, couleurs activ\u00e9es ou non, style des ic\u00f4nes et bordures, langue et police du terminal. Appliqu\u00e9 imm\u00e9diatement.","Colors":"Couleurs","Command":"Commande","Configured - {0}":"Configur\u00e9 - {0}","Confirm":"Confirmer","Connect with opencode":"Connecter opencode","Connected: opencode now starts through {0}.":"Connect\u00e9 : opencode d\u00e9marre maintenant via {0}.","Connecting opencode":"Connexion d'opencode","Connection":"Connexion","Connection method":"M\u00e9thode de connexion","Continue":"Continuer","Continue WITHOUT the probe this session (IPs accepted untested)?":"Continuer SANS le test pour cette session (IP accept\u00e9es sans test) ?","Continue anyway?":"Continuer quand m\u00eame ?","Continue direct?":"Continuer en direct ?","Continue without WARP?":"Continuer sans WARP ?","Cooldown between attempts (s)":"D\u00e9lai entre les tentatives (s)","Copies auth.json to your Desktop, then clears the saved tokens.":"Copie auth.json sur votre Bureau, puis efface les jetons enregistr\u00e9s.","Copy the file path":"Copier le chemin du fichier","Creating shortcuts":"Cr\u00e9ation des raccourcis","Creating the opencode command":"Cr\u00e9ation de la commande opencode","Credentials inside a URL are not stored. Use a local file instead.":"Les identifiants dans une URL ne sont pas enregistr\u00e9s. Utilisez plut\u00f4t un fichier local.","Deep reset":"R\u00e9initialisation compl\u00e8te","Default connection method and run mode, the WARP proxy port and the warp-cli timings.":"M\u00e9thode de connexion et mode d'ex\u00e9cution par d\u00e9faut, port du proxy WARP et d\u00e9lais de warp-cli.","Default: {0}.":"Par d\u00e9faut : {0}.","Desktop":"Bureau","Desktop app":"Application de bureau","Desktop app location, release metadata URL and lookup timeouts.":"Emplacement de l'application de bureau, URL des m\u00e9tadonn\u00e9es de versions et d\u00e9lais de recherche.","Desktop app path":"Chemin de l'application de bureau","Direct, no proxy":"Direct, sans proxy","Do it now.":"Le faire maintenant.","Do that now?":"Le faire maintenant ?","Download and install it now?":"La t\u00e9l\u00e9charger et l'installer maintenant ?","Download the portable Tor bundle when nothing answers.":"T\u00e9l\u00e9charge Tor portable quand rien ne r\u00e9pond.","Egress":"Sortie","Egress used for opencode. ASK shows the picker at every start.":"Sortie utilis\u00e9e par opencode. ASK affiche le s\u00e9lecteur \u00e0 chaque d\u00e9marrage.","Enter a full URL (http, https, ftp or file).":"Saisissez une URL compl\u00e8te (http, https, ftp ou file).","Enter a whole number.":"Saisissez un nombre entier.","Enter cycles: {0}.":"Entr\u00e9e parcourt : {0}.","Enter toggles it.":"Entr\u00e9e l'active ou le d\u00e9sactive.","Every change is saved at once to {0}":"Chaque modification est enregistr\u00e9e aussit\u00f4t dans {0}","Exit":"Quitter","Exit IP":"IP de sortie","Extra rounds (60 s apart) before giving up.":"Tours suppl\u00e9mentaires (espac\u00e9s de 60 s) avant d'abandonner.","Folder":"Dossier","Font name":"Nom de la police","Font of the terminal text. Empty leaves the terminal as it is.":"Police du texte du terminal. Vide laisse le terminal tel quel.","Font size":"Taille de police","Free HTTP proxies from your list (any format) or the default one. Each is tested before use.":"Proxys HTTP gratuits de votre liste (n'importe quel format) ou de la liste par d\u00e9faut. Chacun est test\u00e9 avant usage.","Free or your own list":"Gratuite ou votre liste","Fresh start":"Nouveau d\u00e9part","Full path of OpenCode.exe. Empty = search automatically.":"Chemin complet d'OpenCode.exe. Vide = recherche automatique.","Get a new IP or proxy, then open OpenCode. Your chats and history stay untouched.":"Obtient une nouvelle IP ou un proxy, puis ouvre OpenCode. Vos chats et l'historique restent intacts.","Gets a new IP / WARP registration / Tor circuit / proxy.":"Obtient une nouvelle IP / inscription WARP / circuit Tor / proxy.","Go ahead.":"Allez-y.","Go back. Nothing is changed.":"Revenir. Rien n'est modifi\u00e9.","Guided setup: choose WARP, Tor, a proxy list or direct, then get an \"opencode\" command and a shortcut that start with it. It is tested at the end.":"Assistant : choisissez WARP, Tor, une liste de proxys ou la connexion directe, puis obtenez une commande \u00ab opencode \u00bb et un raccourci qui d\u00e9marrent avec elle. Un test est fait \u00e0 la fin.","HTTP port of the built-in bridge opencode uses.":"Port HTTP du pont int\u00e9gr\u00e9 qu'utilise opencode.","Host used by the API check.":"Serveur utilis\u00e9 par la v\u00e9rification de l'API.","How do you want to run OpenCode?":"Comment voulez-vous lancer OpenCode ?","How many proxies to test before giving up.":"Combien de proxys tester avant d'abandonner.","How many times, and how fast, a new IP is requested when the free limit is hit.":"Combien de fois, et \u00e0 quel rythme, une nouvelle IP est demand\u00e9e quand la limite gratuite est atteinte.","IPs the probe may reject before giving up. 0 = no limit.":"IP que le test peut rejeter avant d'abandonner. 0 = sans limite.","Icons and borders":"Ic\u00f4nes et bordures","Install Tor automatically":"Installer Tor automatiquement","Keep the current connection and open OpenCode as it was.":"Garde la connexion actuelle et ouvre OpenCode tel qu'il \u00e9tait.","Keep the current font.":"Garder la police actuelle.","Kill opencode and clear the saved tokens, keeping your chats where they are.":"Ferme opencode et efface les jetons enregistr\u00e9s, en laissant vos conversations en place.","Kill opencode, move your chats to the Desktop, clear the saved tokens and open a fresh session.":"Ferme opencode, d\u00e9place vos conversations sur le Bureau, efface les jetons enregistr\u00e9s et ouvre une nouvelle session.","Language":"Langue","Language of the menus and descriptions. auto follows Windows. Logs and the support report stay in English.":"Langue des menus et des descriptions. auto suit Windows. Les journaux et le rapport de support restent en anglais.","Last check":"Derni\u00e8re v\u00e9rification","Launch OpenCode":"Lancer OpenCode","Launcher":"Launcher","Launcher self-update":"Mise \u00e0 jour automatique du launcher","Leave the setup without changing anything.":"Quitter l'assistant sans rien changer.","Leave the terminal font as it is. If the launcher changed it, the original font comes back.":"Laisse la police du terminal telle quelle. Si le launcher l'a chang\u00e9e, la police d'origine revient.","Local Tor with a built-in HTTP bridge. A portable Tor is installed automatically if missing.":"Tor local avec un pont HTTP int\u00e9gr\u00e9. Un Tor portable est install\u00e9 automatiquement s'il manque.","Local port of the WARP proxy.":"Port local du proxy WARP.","Logs":"Journaux","Main menu":"Menu principal","Method":"M\u00e9thode","Minimum list size (bytes)":"Taille minimale de la liste (octets)","Mode":"Mode","Model used by the IP probe.":"Mod\u00e8le utilis\u00e9 par le test d'IP.","Must be between {0} and {1}.":"Doit \u00eatre compris entre {0} et {1}.","New IP and resume in 5s":"Nouvelle IP et reprise dans 5 s","No":"Non","No .exe file exists at that path.":"Aucun fichier .exe n'existe \u00e0 ce chemin.","No answer in {0}s counts as No.":"Sans r\u00e9ponse en {0} s, c'est Non.","No change.":"Aucun changement.","No proxy: opencode uses your real connection and nothing is rotated.":"Sans proxy : opencode utilise votre vraie connexion et rien n'est renouvel\u00e9.","No, cancel":"Non, annuler","Non-limit probe failures before the hunt stops.":"\u00c9checs du test sans rapport avec la limite avant l'arr\u00eat de la recherche.","Not a URL, and no file exists at that path.":"Ce n'est pas une URL et aucun fichier n'existe \u00e0 ce chemin.","Not configured":"Non configur\u00e9","Nothing to ask for a direct connection.":"Rien \u00e0 demander pour une connexion directe.","Nothing was left half done that Uninstall cannot remove. Fix the problem and run setup again.":"Rien n'est rest\u00e9 \u00e0 moiti\u00e9 fait que D\u00e9sinstaller ne puisse retirer. Corrigez le probl\u00e8me et relancez l'assistant.","On PATH":"Dans le PATH","Only opencode uses it; the rest of the system stays direct.":"Seul opencode l'utilise ; le reste du syst\u00e8me reste en direct.","Open the Windows folder picker and choose where to work.":"Ouvre le s\u00e9lecteur de dossiers de Windows pour choisir o\u00f9 travailler.","Open the folder":"Ouvrir le dossier","Open the launcher menus: pick a folder and a connection method, then start the opencode CLI or the desktop app.":"Ouvre les menus du launcher : choisissez un dossier et une m\u00e9thode de connexion, puis d\u00e9marrez la CLI opencode ou l'application de bureau.","OpenCode app":"App OpenCode","PATH lookup timeout (s)":"D\u00e9lai de recherche dans le PATH (s)","Paths":"Chemins","Port {0} is already used by {1}.":"Le port {0} est d\u00e9j\u00e0 utilis\u00e9 par {1}.","Ports and install behavior of the portable Tor the launcher starts for you.":"Ports et installation du Tor portable que le launcher d\u00e9marre pour vous.","Press any key to continue...":"Appuyez sur une touche pour continuer...","Probe":"Test","Probe failures tolerated":"\u00c9checs de test tol\u00e9r\u00e9s","Probe model":"Mod\u00e8le de test","Proxies tried per pick":"Proxys essay\u00e9s par s\u00e9lection","Proxy":"Proxy","Proxy list":"Liste de proxys","Proxy list source":"Source de la liste de proxys","Proxy test timeout (s)":"D\u00e9lai du test d'un proxy (s)","Public HTTP proxies from a list (yours, in any format, or the free default). Each one is tested first and burned ones are skipped.":"Proxys HTTP publics d'une liste (la v\u00f4tre, n'importe quel format, ou la liste gratuite par d\u00e9faut). Chacun est test\u00e9 d'abord et les grill\u00e9s sont ignor\u00e9s.","Put every setting back to its default. Your connection setup (command, shortcuts) is not touched. Asks first.":"Remet tous les r\u00e9glages \u00e0 leur valeur par d\u00e9faut. Votre configuration de connexion (commande, raccourcis) n'est pas touch\u00e9e. Demande confirmation.","Put the full path on the clipboard.":"Met le chemin complet dans le presse-papiers.","Quotes and line breaks are not allowed.":"Les guillemets et les sauts de ligne ne sont pas autoris\u00e9s.","Range {0} to {1}.":"Plage de {0} \u00e0 {1}.","Reconfigure (run setup again)":"Reconfigurer (relancer l'assistant)","Release metadata URL":"URL des m\u00e9tadonn\u00e9es de versions","Removes only what setup added: the opencode command, the shortcuts and the PATH entry.":"Supprime uniquement ce que l'assistant a ajout\u00e9 : la commande opencode, les raccourcis et l'entr\u00e9e PATH.","Removes only what the setup added (command, shortcuts, PATH entry) and restores the settings it changed. Backups are kept. Asks first.":"Supprime uniquement ce que l'assistant a ajout\u00e9 (commande, raccourcis, entr\u00e9e PATH) et restaure les r\u00e9glages qu'il a modifi\u00e9s. Les sauvegardes sont conserv\u00e9es. Demande confirmation.","Removing shortcuts":"Suppression des raccourcis","Removing the opencode command":"Suppression de la commande opencode","Renew did not finish (code {0}).":"Le renouvellement ne s'est pas termin\u00e9 (code {0}).","Renew session":"Renouveler la session","Renew the session?":"Renouveler la session ?","Renewed. Open opencode again; you may need to log in once more.":"Renouvel\u00e9. Rouvrez opencode ; il faudra peut-\u00eatre vous reconnecter.","Renewing":"Renouvellement","Renewing the session":"Renouvellement de la session","Reopen the last folder":"Rouvrir le dernier dossier","Report ready. Personal data was removed; read it once before you share it.":"Rapport pr\u00eat. Les donn\u00e9es personnelles ont \u00e9t\u00e9 supprim\u00e9es ; relisez-le avant de le partager.","Repository":"D\u00e9p\u00f4t","Reset every setting to its default?":"Remettre tous les r\u00e9glages \u00e0 leur valeur par d\u00e9faut ?","Reset to default values":"R\u00e9tablir les valeurs par d\u00e9faut","Restores the settings setup changed. Your other settings and your opencode files are kept.":"Restaure les r\u00e9glages modifi\u00e9s par l'assistant. Vos autres r\u00e9glages et vos fichiers opencode sont conserv\u00e9s.","Restoring PATH":"Restauration du PATH","Restoring settings":"Restauration des r\u00e9glages","Resume message":"Message de reprise","Resume timeout (s)":"D\u00e9lai de reprise (s)","Return to the connection details.":"Revenir aux d\u00e9tails de la connexion.","Return to the main menu.":"Revenir au menu principal.","Return to the settings groups.":"Revenir aux groupes de r\u00e9glages.","Review":"R\u00e9capitulatif","Rotate the connection only (new WARP registration, Tor circuit or proxy) without opening OpenCode.":"Renouvelle seulement la connexion (nouvelle inscription WARP, circuit Tor ou proxy) sans ouvrir OpenCode.","Rotate when a fatal error appears while opencode runs.":"Renouvelle quand une erreur fatale appara\u00eet pendant l'ex\u00e9cution d'opencode.","Rotation":"Rotation","Rotation attempts":"Tentatives de rotation","Rotation rounds":"Tours de rotation","Run mode":"Mode d'ex\u00e9cution","Run opencode in this terminal. After a new IP the chat resumes by itself.":"Ex\u00e9cute opencode dans ce terminal. Apr\u00e8s une nouvelle IP, la conversation reprend toute seule.","Run the OpenCode desktop app ({0}). It is restarted after every new IP.":"Ex\u00e9cute l'application de bureau OpenCode ({0}). Elle red\u00e9marre apr\u00e8s chaque nouvelle IP.","Run the setup again to change the method or repair the opencode command.":"Relancez l'assistant pour changer de m\u00e9thode ou r\u00e9parer la commande opencode.","SOCKS port of the Tor the launcher starts.":"Port SOCKS du Tor que d\u00e9marre le launcher.","Save the settings, create the opencode command, the shortcuts and the PATH entry, then test the connection.":"Enregistre les r\u00e9glages, cr\u00e9e la commande opencode, les raccourcis et l'entr\u00e9e PATH, puis teste la connexion.","Saved: {0} = {1}":"Enregistr\u00e9 : {0} = {1}","Saving config.json":"Enregistrement de config.json","Seconds a single \"where\" lookup may take.":"Secondes maximum pour une recherche \u00ab where \u00bb.","Seconds a single proxy test may take.":"Secondes maximum pour le test d'un proxy.","Seconds a single warp-cli call may take.":"Secondes maximum pour un appel \u00e0 warp-cli.","Seconds before a silent resume counts as a dead IP.":"Secondes avant qu'une reprise sans r\u00e9ponse compte comme une IP morte.","Seconds to wait after (re)connecting WARP.":"Secondes d'attente apr\u00e8s la (re)connexion de WARP.","Seconds to wait for Tor to finish bootstrapping.":"Secondes d'attente pour que Tor finisse de d\u00e9marrer.","See what the setup installed (command, shortcuts, PATH) and run it again to change the method.":"Voir ce que l'assistant a install\u00e9 (commande, raccourcis, PATH) et le relancer pour changer de m\u00e9thode.","Send one cheap message through each candidate IP.":"Envoie un message peu co\u00fbteux par chaque IP candidate.","Sent automatically after a rotation.":"Envoy\u00e9 automatiquement apr\u00e8s une rotation.","Settings":"R\u00e9glages","Settings and setup":"R\u00e9glages et configuration","Setup 1/3 - connection method":"Configuration 1/3 - m\u00e9thode de connexion","Setup 2/3 - details":"Configuration 2/3 - d\u00e9tails","Setup 3/3 - run mode":"Configuration 3/3 - mode d'ex\u00e9cution","Setup stopped: {0}":"L'assistant s'est arr\u00eat\u00e9 : {0}","Shortcuts":"Raccourcis","Show the CLI or Desktop choice every time the launcher opens.":"Affiche le choix CLI ou Bureau \u00e0 chaque ouverture du launcher.","Show the report in Explorer so you can attach or paste it.":"Affiche le rapport dans l'Explorateur pour le joindre ou le coller.","Size used with the chosen font.":"Taille utilis\u00e9e avec la police choisie.","Support":"Support","Support report":"Rapport de support","Switch between the terminal and the desktop app.":"Basculer entre le terminal et l'application de bureau.","Switch to Tor and keep going?":"Passer \u00e0 Tor et continuer ?","System":"Syst\u00e8me","Takes effect at the {0}; a service already running keeps the old value until then.":"Prend effet \u00e0 : {0} ; un service d\u00e9j\u00e0 en cours garde l'ancienne valeur jusque-l\u00e0.","Terminal font":"Police du terminal","Test every new IP":"Tester chaque nouvelle IP","The OpenCode desktop app was not found. Choosing this offers to download and install it.":"L'application de bureau OpenCode est introuvable. La choisir propose de la t\u00e9l\u00e9charger et de l'installer.","The OpenCode desktop app; it is restarted after every new IP.":"L'application de bureau OpenCode ; elle red\u00e9marre apr\u00e8s chaque nouvelle IP.","The activity log (launcher.log) and the support report: what is recorded, how big it may grow, whether IPs are masked.":"Le journal d'activit\u00e9 (launcher.log) et le rapport de support : ce qui est enregistr\u00e9, sa taille maximale et le masquage des IP.","The cheap test message sent through every new IP before it is trusted.":"Le message de test peu co\u00fbteux envoy\u00e9 par chaque nouvelle IP avant de lui faire confiance.","The check failed (code {0}). Setup is saved; fix the cause and use Renew or Connect again.":"La v\u00e9rification a \u00e9chou\u00e9 (code {0}). La configuration est enregistr\u00e9e ; corrigez la cause et utilisez Renouveler ou Connecter \u00e0 nouveau.","The font applies to the whole terminal window, not only to this launcher.":"La police s'applique \u00e0 toute la fen\u00eatre du terminal, pas seulement \u00e0 ce launcher.","The proxy lives only in the opencode process; the rest of the system stays direct.":"Le proxy n'existe que dans le processus opencode ; le reste du syst\u00e8me reste en direct.","The resume auto-approves tool permissions.":"La reprise approuve automatiquement les autorisations des outils.","The shortcut and the opencode command use the CLI; this is the launcher menu default.":"Le raccourci et la commande opencode utilisent la CLI ; c'est la valeur par d\u00e9faut du menu du launcher.","The terminal interface. The opencode command and the shortcut always use it.":"L'interface terminal. La commande opencode et le raccourci l'utilisent toujours.","This launcher is not the one that set it up. Reconfigure to repair the command.":"Ce launcher n'est pas celui qui l'a configur\u00e9. Reconfigurez pour r\u00e9parer la commande.","Token reset":"R\u00e9initialisation des jetons","Tools and versions":"Outils et versions","Tor HTTP bridge port":"Port du pont HTTP de Tor","Tor SOCKS port":"Port SOCKS de Tor","Tor bootstrap wait (s)":"Attente du d\u00e9marrage de Tor (s)","Tor is downloaded once, run hidden and offered to opencode through a built-in HTTP bridge. Slower, but a new circuit is a new IP.":"Tor est t\u00e9l\u00e9charg\u00e9 une fois, lanc\u00e9 en cach\u00e9 et propos\u00e9 \u00e0 opencode via un pont HTTP int\u00e9gr\u00e9. Plus lent, mais un nouveau circuit donne une nouvelle IP.","Try again in a minute, or pick another connection method in Connect with opencode.":"R\u00e9essayez dans une minute, ou choisissez une autre m\u00e9thode de connexion dans Connecter opencode.","Try again?":"R\u00e9essayer ?","Try to download and install WARP now?":"Essayer de t\u00e9l\u00e9charger et d'installer WARP maintenant ?","Type \"opencode\" in a NEW terminal, or use the \"OpenCode Infinite (egress)\" shortcut.":"Tapez \u00ab opencode \u00bb dans un NOUVEAU terminal, ou utilisez le raccourci \u00ab OpenCode Infinite (egress) \u00bb.","Type < to go back. Enter keeps the value shown.":"Tapez < pour revenir. Entr\u00e9e garde la valeur affich\u00e9e.","Type a font name...":"Saisir le nom d'une police...","URL or local file, any format (plain, CSV, JSON, XML, HTML).":"URL ou fichier local, n'importe quel format (texte brut, CSV, JSON, XML, HTML).","Unattended resume":"Reprise sans surveillance","Uninstall":"D\u00e9sinstaller","Uninstall stopped: {0}":"La d\u00e9sinstallation s'est arr\u00eat\u00e9e : {0}","Uninstall the opencode connection?":"D\u00e9sinstaller la connexion opencode ?","Uninstalled. Backups stay in {0}":"D\u00e9sinstall\u00e9. Les sauvegardes restent dans {0}","Uninstalling":"D\u00e9sinstallation","Update now?":"Mettre \u00e0 jour maintenant ?","Updates":"Mises \u00e0 jour","Use 1 to 200 characters.":"Utilisez de 1 \u00e0 200 caract\u00e8res.","Use it when the free limit is hit or the login expired: closes opencode, saves and clears the saved tokens, and gets a new IP, WARP registration, Tor circuit or proxy.":"\u00c0 utiliser quand la limite gratuite est atteinte ou que la connexion a expir\u00e9 : ferme opencode, sauvegarde et efface les jetons enregistr\u00e9s, et obtient une nouvelle IP, inscription WARP, circuit Tor ou proxy.","Use on or off.":"Utilisez on ou off.","Use that proxy anyway?":"Utiliser ce proxy quand m\u00eame ?","Use this folder":"Utiliser ce dossier","Use up to 31 characters, without quotes or backslashes.":"Utilisez jusqu'\u00e0 31 caract\u00e8res, sans guillemets ni barres obliques inverses.","Use {0} for the terminal text. Monospaced fonts only look right.":"Utilise {0} pour le texte du terminal. Seules les polices \u00e0 chasse fixe s'affichent bien.","Version":"Version","View and change every launcher option: connection, proxies, Tor, rotation, themes. Saved instantly, no files to edit.":"Voir et modifier toutes les options du launcher : connexion, proxys, Tor, rotation, th\u00e8mes. Enregistr\u00e9 aussit\u00f4t, sans fichier \u00e0 \u00e9diter.","WARP proxy port":"Port du proxy WARP","WARP wait (s)":"Attente WARP (s)","Watch the log":"Surveiller le journal","Watcher":"Surveillance","Watching the opencode log and the automatic \"continue\" sent after a rotation.":"Surveillance du journal d'opencode et du \u00ab continue \u00bb automatique envoy\u00e9 apr\u00e8s une rotation.","Where proxies come from (URL or file, any format) and how each one is tested.":"D'o\u00f9 viennent les proxys (URL ou fichier, n'importe quel format) et comment chacun est test\u00e9.","Where versions and checksums are read from.":"D'o\u00f9 sont lues les versions et les sommes de contr\u00f4le.","Whether the launcher checks GitHub for a newer copy of itself at every start.":"Indique si le launcher cherche sur GitHub une copie plus r\u00e9cente de lui-m\u00eame \u00e0 chaque d\u00e9marrage.","Work in a different folder.":"Travailler dans un autre dossier.","Work in the folder the launcher was started from: {0}":"Travailler dans le dossier d'o\u00f9 le launcher a \u00e9t\u00e9 lanc\u00e9 : {0}","Work in {0}":"Travailler dans {0}","Writing the report":"\u00c9criture du rapport","Yes":"Oui","Yes, continue":"Oui, continuer","Your connection setup (shim, shortcuts) is not touched.":"Votre configuration de connexion (shim, raccourcis) n'est pas touch\u00e9e.","Your session needs renewing: {0}":"Votre session doit \u00eatre renouvel\u00e9e : {0}","asks first":"demande confirmation","auto":"auto","auto follows the terminal and NO_COLOR; off disables colors.":"auto suit le terminal et NO_COLOR ; off d\u00e9sactive les couleurs.","direct":"direct","emoji = modern terminals, unicode = classic console, ascii = anything.":"emoji = terminaux modernes, unicode = console classique, ascii = n'importe lequel.","free list":"liste gratuite","installed":"install\u00e9e","missing":"manquant","new IP":"nouvelle IP","next Tor start":"prochain d\u00e9marrage de Tor","next WARP connect":"prochaine connexion WARP","next launch":"prochain d\u00e9marrage","no other step is needed.":"aucune autre \u00e9tape n'est n\u00e9cessaire.","not installed":"non install\u00e9e","not verified":"non v\u00e9rifi\u00e9","off":"d\u00e9sactiv\u00e9","on":"activ\u00e9","same IP":"m\u00eame IP","terminal":"terminal","warp-cli timeout (s)":"D\u00e9lai de warp-cli (s)","yes":"oui","{0} changed":"{0} modifi\u00e9s","{0} of {1}":"{0} sur {1}","After opencode closes":"Apr\u00e8s la fermeture d'opencode","ask = R, M or Q: R gets a new IP and resumes the chat, M opens the menu, Q quits. quit = leave the launcher at once.":"ask = R, M ou Q : R prend une nouvelle IP et reprend le chat, M ouvre le menu, Q quitte. quit = quitter le lanceur imm\u00e9diatement.","Rotate key":"Touche de rotation","Menu key":"Touche du menu","Quit key":"Touche de sortie","Closed-opencode prompt: new IP and resume the chat.":"Invite \u00e0 la fermeture d'opencode : nouvelle IP et reprise du chat.","Closed-opencode prompt: open the menu.":"Invite \u00e0 la fermeture : ouvrir le menu.","Closed-opencode prompt: quit. Ctrl+C always quits too.":"Invite \u00e0 la fermeture : quitter. Ctrl+C quitte aussi.","The keys of the launcher and the terminal commands. Fixed keys are listed for reference; the three letters can be changed.":"Touches du lanceur et commandes du terminal. Les touches fixes sont list\u00e9es \u00e0 titre indicatif ; les trois lettres peuvent \u00eatre chang\u00e9es.","One letter, like R.":"Une lettre, comme R.","Key {0} is already used by {1}.":"La touche {0} est d\u00e9j\u00e0 utilis\u00e9e par {1}.","Only the chosen language is downloaded from the langs folder of the repository.":"Seule la langue choisie est t\u00e9l\u00e9charg\u00e9e depuis le dossier langs du d\u00e9p\u00f4t.","Follow the language Windows uses.":"Suit la langue de Windows.","Use this language for every menu and message.":"Utilise cette langue pour tous les menus et messages.","Keep the current language.":"Garder la langue actuelle.","File to write (Enter = Desktop, Esc = back)":"Fichier \u00e0 \u00e9crire (Entr\u00e9e = Bureau, \u00c9chap = retour)","File to read (Esc = back)":"Fichier \u00e0 lire (\u00c9chap = retour)","That folder does not exist.":"Ce dossier n'existe pas.","Replace the file that is already there?":"Remplacer le fichier existant ?","Exported {0} changed setting(s) to {1}":"{0} r\u00e9glage(s) modifi\u00e9(s) export\u00e9(s) vers {1}","Import {0} setting(s)? Their current values are replaced.":"Importer {0} r\u00e9glage(s) ? Leurs valeurs actuelles sont remplac\u00e9es.","{0} setting(s) of this file are unknown here and are skipped.":"{0} r\u00e9glage(s) de ce fichier sont inconnus ici et seront ignor\u00e9s.","No file at that path.":"Aucun fichier \u00e0 ce chemin.","This is not an OpenCode Infinite settings file.":"Ce fichier n'est pas un fichier de r\u00e9glages d'OpenCode Infinite.","Nothing was imported. These values are not valid:":"Rien n'a \u00e9t\u00e9 import\u00e9. Ces valeurs ne sont pas valides :","Imported {0} setting(s).":"{0} r\u00e9glage(s) import\u00e9(s).","Export settings to a file":"Exporter les r\u00e9glages vers un fichier","Save every changed setting to one .json file, to keep a backup or copy them to another PC.":"Enregistre tous les r\u00e9glages modifi\u00e9s dans un fichier .json, pour une sauvegarde ou un autre PC.","Import settings from a file":"Importer les r\u00e9glages depuis un fichier","Load a file made by Export. Every value is checked first; if one is wrong, nothing changes.":"Charge un fichier cr\u00e9\u00e9 par Exporter. Chaque valeur est v\u00e9rifi\u00e9e d'abord ; si une est fausse, rien ne change.","back to the previous screen":"retour \u00e0 l'\u00e9cran pr\u00e9c\u00e9dent","Fixed. In a menu or a text prompt Esc goes back; it never closes the launcher.":"Fixe. Dans un menu ou un champ de texte, \u00c9chap revient en arri\u00e8re ; il ne ferme jamais le lanceur.","select and move":"choisir et d\u00e9placer","Fixed. Digits 1-9 jump straight to a row.":"Fixe. Les chiffres 1-9 vont directement \u00e0 une ligne.","quit the launcher":"quitter le lanceur","Fixed. Stops the processes it started and leaves the terminal open, no Y/N question.":"Fixe. Arr\u00eate les processus lanc\u00e9s et laisse le terminal ouvert, sans question O/N.","start with the connection":"d\u00e9marrer avec la connexion","Terminal command from any folder. The Start menu shortcut does the same.":"Commande de terminal depuis n'importe quel dossier. Le raccourci du menu D\u00e9marrer fait la m\u00eame chose.","open this menu":"ouvrir ce menu","Terminal command: opens the launcher menu again, as many times as you need.":"Commande de terminal : rouvre le menu du lanceur, autant de fois que n\u00e9cessaire.","original OpenCode":"OpenCode d'origine","Terminal command: starts the OpenCode you installed, without the launcher or the connection. Use it when the launcher breaks.":"Commande de terminal : d\u00e9marre l'OpenCode install\u00e9, sans lanceur ni connexion. \u00c0 utiliser si le lanceur tombe en panne.","Commands":"Commandes","Adds: the opencode, opencodeinf and opencodeoc commands, two shortcuts, one PATH entry. Backups are kept.":"Ajoute les commandes opencode, opencodeinf et opencodeoc, deux raccourcis et une entr\u00e9e PATH. Les sauvegardes sont conserv\u00e9es.","  This copy is not the official one. Starting the official copy:":"  Cette copie n'est pas la version officielle. Lancement de la copie officielle :","  OpenCode - how do you want to run it?":"  OpenCode - comment voulez-vous le lancer ?","  [1] CLI      - terminal TUI (chat resumes on every new IP)":"  [1] CLI      - TUI dans le terminal (le chat reprend \u00e0 chaque nouvelle IP)","  [2] Desktop  - the OpenCode desktop app (restarted on every new IP)":"  [2] Desktop  - l'application de bureau OpenCode (red\u00e9marr\u00e9e \u00e0 chaque nouvelle IP)","  [3] Exit":"  [3] Quitter","  One key, no Enter.":"  Une touche, sans Entr\u00e9e.","%C_WARN%  [*] OpenCode desktop not found.%C_RST%":"%C_WARN%  [*] Application de bureau OpenCode introuvable.%C_RST%","%C_WARN%  [*] still not found - set OC_APP to its OpenCode.exe.%C_RST%":"%C_WARN%  [*] Toujours introuvable - d\u00e9finissez OC_APP avec le chemin de OpenCode.exe.%C_RST%","  [app] DESKTOP \"%OC_DESKTOP%\"":"  [app] DESKTOP \"%OC_DESKTOP%\"","  OpenCode - choose a folder to work in":"  OpenCode - choisissez un dossier de travail","  [1] Reopen the last folder":"  [1] Rouvrir le dernier dossier","      (nothing saved yet)":"      (rien d'enregistr\u00e9 pour l'instant)","  [2] Use this folder":"  [2] Utiliser ce dossier","  [3] Browse for a folder...":"  [3] Parcourir un dossier...","  [4] Exit":"  [4] Quitter","  No folder saved yet. Use [2] or [3] this time.":"  Aucun dossier enregistr\u00e9. Utilisez [2] ou [3] cette fois.","  Choose a folder in the dialog...":"  Choisissez un dossier dans la fen\u00eatre...","  Opening the classic folder picker...":"  Ouverture du s\u00e9lecteur de dossiers classique...","  No folder selected.":"  Aucun dossier s\u00e9lectionn\u00e9.","  Folder not found: \"%OPFOLDER%\"":"  Dossier introuvable : \"%OPFOLDER%\"","  Cannot enter: \"%OPFOLDER%\"":"  Impossible d'entrer dans : \"%OPFOLDER%\"","  Working in: \"%CD%\"":"  Travail dans : \"%CD%\"","  [egress] %EGRESS% (from your settings)":"  [egress] %EGRESS% (depuis vos r\u00e9glages)","  Choose egress for OpenCode only (system traffic stays direct)":"  Choisissez la sortie r\u00e9seau pour OpenCode seulement (le trafic syst\u00e8me reste direct)","  [1] WARP     - Cloudflare WARP proxy mode (rotation supported)":"  [1] WARP     - mode proxy Cloudflare WARP (rotation possible)","  [2] TOR      - local Tor + built-in bridge on :%TOR_HTTP_PORT%":"  [2] TOR      - Tor local + pont int\u00e9gr\u00e9 sur :%TOR_HTTP_PORT%","                 (auto-installs a portable Tor, nothing to set up)":"                 (Tor portable install\u00e9 automatiquement, rien \u00e0 configurer)","  [3] PROXY    - free HTTP proxies (ProxyScrape list)":"  [3] PROXY    - proxies HTTP gratuits (liste ProxyScrape)","  [4] NONE     - direct, no proxy":"  [4] NONE     - direct, sans proxy","  [egress] NONE - direct.":"  [egress] NONE - direct.","  [egress] PROXY - free HTTP list.":"  [egress] PROXY - liste HTTP gratuite.","  [egress] TOR - portable Tor + built-in bridge on :%TOR_HTTP_PORT%, auto-setup.":"  [egress] TOR - Tor portable + pont int\u00e9gr\u00e9 sur :%TOR_HTTP_PORT%, installation automatique.","  [egress] WARP.":"  [egress] WARP.","  [dep] curl":"  [dep] curl","  [dep] warp":"  [dep] warp","%C_WARN%  [*] Cloudflare WARP not found - IP rotation will be disabled.%C_RST%":"%C_WARN%  [*] Cloudflare WARP introuvable - la rotation d'IP sera d\u00e9sactiv\u00e9e.%C_RST%","      Install it later from 1.1.1.1 if you want the rotation.":"      Installez-le plus tard depuis 1.1.1.1 si vous voulez la rotation.","%C_WARN%  [*] WARP still not available - continuing without rotation.%C_RST%":"%C_WARN%  [*] WARP toujours indisponible - on continue sans rotation.%C_RST%","      warp-cli errors, if any, are in %STATE_DIR%\\wcli.log":"      Les erreurs warp-cli \u00e9ventuelles sont dans %STATE_DIR%\\wcli.log","%C_WARN%  [*] Cloudflare WARP publishes 64-bit Windows builds only.%C_RST%":"%C_WARN%  [*] Cloudflare WARP ne publie que des versions 64 bits pour Windows.%C_RST%","      On this 32-bit system rotation is disabled.":"      Sur ce syst\u00e8me 32 bits, la rotation est d\u00e9sactiv\u00e9e.","%C_OK%  [ok] WARP ready.%C_RST%":"%C_OK%  [ok] WARP pr\u00eat.%C_RST%","  [dep] opencode":"  [dep] opencode","  [auto-install] opencode not found, fetching it...":"  [auto-install] opencode introuvable, t\u00e9l\u00e9chargement en cours...","%C_OK%  [ok] opencode ready.%C_RST%":"%C_OK%  [ok] opencode pr\u00eat.%C_RST%","%C_ERR%  ERROR: opencode install failed or is not on PATH.%C_RST%":"%C_ERR%  ERREUR : l'installation d'opencode a \u00e9chou\u00e9 ou il n'est pas dans PATH.%C_RST%","  Get it by hand: https://github.com/sst/opencode/releases":"  Installez-le \u00e0 la main : https://github.com/sst/opencode/releases","  Preparing the connection...":"  Pr\u00e9paration de la connexion...","  OpenCode":"  OpenCode","  Folder : \"%CD%\"":"  Dossier : \"%CD%\"","  Egress : %EGRESS%":"  Sortie  : %EGRESS%","  Mode   : %APP_MODE%":"  Mode    : %APP_MODE%","  WARP   : none (rotation disabled)":"  WARP    : aucun (rotation d\u00e9sactiv\u00e9e)","  WARP   : \"%WARP%\"":"  WARP    : \"%WARP%\"","  Version: %OC_VER%  \"%OC_CMD%\"":"  Version : %OC_VER%  \"%OC_CMD%\"","  Exit IP: %IP%":"  IP de sortie : %IP%","  What do you want to do?":"  Que voulez-vous faire ?","  [1] Fresh start   - get a new IP / proxy, then open OpenCode":"  [1] Nouveau d\u00e9part - obtenir une nouvelle IP / un proxy, puis ouvrir OpenCode","                      (your chats and history stay untouched)":"                      (vos chats et votre historique restent intacts)","  [2] Continue      - same egress, open OpenCode as it was":"  [2] Continuer    - m\u00eame sortie, rouvrir OpenCode comme il \u00e9tait","  [3] Change IP     - rotate / pick new proxy only":"  [3] Changer d'IP - seulement changer d'IP / de proxy","  [5] Deep reset    - kill opencode, move chats to the Desktop,":"  [5] R\u00e9initialisation compl\u00e8te - arr\u00eater opencode, d\u00e9placer les chats sur le Bureau,","                      clear saved tokens, open a fresh session":"                      effacer les jetons enregistr\u00e9s, ouvrir une session neuve","  [6] Exit":"  [6] Quitter","  [7] Token reset   - kill opencode, clear saved tokens, keep chats":"  [7] R\u00e9init. des jetons - arr\u00eater opencode, effacer les jetons enregistr\u00e9s,","                      where they are, open a fresh session":"                      garder les chats l\u00e0 o\u00f9 ils sont, ouvrir une session neuve","  [8] Settings      - change any launcher setting, applied right away":"  [8] R\u00e9glages     - modifier n'importe quel r\u00e9glage, appliqu\u00e9 imm\u00e9diatement","--- deep reset -----------------------------------------------":"--- r\u00e9initialisation compl\u00e8te -----------------------------------","  This closes opencode, moves your chats to the Desktop,":"  Ceci arr\u00eate opencode, d\u00e9place vos chats sur le Bureau,","  clears the saved tokens and opens a brand new session.":"  efface les jetons enregistr\u00e9s et ouvre une session neuve.","  It is the only action in this script that touches your files.":"  C'est la seule action de ce script qui touche \u00e0 vos fichiers.","  It also kills EVERY opencode process on this computer,":"  Elle arr\u00eate AUSSI TOUS les processus opencode de cet ordinateur,","  including windows opened by hand or by another launcher.":"  y compris les fen\u00eatres ouvertes \u00e0 la main ou par un autre launcher.","--- token reset ----------------------------------------------":"--- r\u00e9initialisation des jetons ---------------------------------","  This closes opencode, clears the saved tokens and opens a":"  Ceci arr\u00eate opencode, efface les jetons enregistr\u00e9s et ouvre une","  brand new session. Your chats are NOT moved.":"  session neuve. Vos chats NE sont PAS d\u00e9plac\u00e9s.","  auth.json is copied to the Desktop first, then removed.":"  auth.json est d'abord copi\u00e9 sur le Bureau, puis supprim\u00e9.","    egress: %EGRESS%":"    sortie : %EGRESS%","%C_WARN%  [*] WARP proxy is not answering - rotation has no effect.%C_RST%":"%C_WARN%  [*] Le proxy WARP ne r\u00e9pond pas - la rotation est sans effet.%C_RST%","      Going direct would run opencode on your real IP.":"      Passer en direct ferait utiliser votre vraie IP \u00e0 opencode.","%C_WARN%  [*] Tor did not get ready.%C_RST%":"%C_WARN%  [*] Tor n'a pas \u00e9t\u00e9 pr\u00eat.%C_RST%","%C_WARN%  [*] no working free proxy found.%C_RST%":"%C_WARN%  [*] aucun proxy gratuit fonctionnel trouv\u00e9.%C_RST%","%C_WARN%  [*] the egress proxy stopped answering while OpenCode was open:%C_RST%":"%C_WARN%  [*] le proxy de sortie a cess\u00e9 de r\u00e9pondre pendant qu'OpenCode \u00e9tait ouvert :%C_RST%","      %STATE_DIR%\\proxy_warn.txt":"      %STATE_DIR%\\proxy_warn.txt","%C_WARN%  [watch] a fatal error cut the chat - rotating and resuming it.%C_RST%":"%C_WARN%  [watch] une erreur fatale a coup\u00e9 le chat - rotation et reprise.%C_RST%","OpenCode closed.":"OpenCode ferm\u00e9.","  %KEY_ROTATE% = new IP and resume the chat   %KEY_MENU% = menu   %KEY_QUIT% = quit (Ctrl+C also quits)":"  %KEY_ROTATE% = nouvelle IP et reprise du chat   %KEY_MENU% = menu   %KEY_QUIT% = quitter (Ctrl+C quitte aussi)","Press any key to continue . . .":"Appuyez sur une touche pour continuer . . .","  [tor] renewing the circuit, attempt %TOR_TRIES% of %ROTATE_TRIES_MAX%...":"  [tor] renouvellement du circuit, essai %TOR_TRIES% sur %ROTATE_TRIES_MAX%...","%C_OK%  [tor] new circuit - resuming.%C_RST%":"%C_OK%  [tor] nouveau circuit - reprise.%C_RST%","%C_WARN%  [*] Tor could not be renewed - back to menu.%C_RST%":"%C_WARN%  [*] Tor n'a pas pu \u00eatre renouvel\u00e9 - retour au menu.%C_RST%","%C_WARN%  [*] Tor could not get a usable circuit after %ROTATE_TRIES_MAX% attempts.%C_RST%":"%C_WARN%  [*] Tor n'a pas obtenu de circuit utilisable apr\u00e8s %ROTATE_TRIES_MAX% essais.%C_RST%","      The exit node may be blocked: try a new identity in Tor, or":"      Le n\u0153ud de sortie est peut-\u00eatre bloqu\u00e9 : essayez une nouvelle identit\u00e9 dans Tor, ou","      switch to [1] WARP. warp/tor notes: \"%TOR_DIR%\\tor.log\"":"      passez \u00e0 [1] WARP. Notes warp/tor : \"%TOR_DIR%\\tor.log\"","  [proxy] %ACTIVE_PROXY% is burned - attempt %PROXY_ROT% of %PROXY_ROT_MAX%, picking another...":"  [proxy] %ACTIVE_PROXY% est grill\u00e9 - essai %PROXY_ROT% sur %PROXY_ROT_MAX%, recherche d'un autre...","  [proxy] picking a fresh free proxy before resume...":"  [proxy] recherche d'un proxy gratuit neuf avant la reprise...","%C_WARN%  [*] no free proxy is left that still works (they all hit the limit).%C_RST%":"%C_WARN%  [*] plus aucun proxy gratuit fonctionnel (ils ont tous atteint la limite).%C_RST%","      Free proxies are shared by many people, so their limit is often used up.":"      Les proxies gratuits sont partag\u00e9s par beaucoup de monde, leur limite est souvent atteinte.","  Automatic rotation is off - the menu decides.":"  La rotation automatique est d\u00e9sactiv\u00e9e - c'est le menu qui d\u00e9cide.","Getting a new IP before the next attempt...":"Obtention d'une nouvelle IP avant le prochain essai...","  [i] hunting for %HUNT_GOAL%: up to %TARGET_TRIES% attempts, %TARGET_MINUTES% min. Esc or Q stops.":"  [i] recherche de %HUNT_GOAL% : jusqu'\u00e0 %TARGET_TRIES% essais, %TARGET_MINUTES% min. \u00c9chap ou Q pour arr\u00eater.","[%ROTATE_TRIES%/%TARGET_TRIES%] dropping the old registration...":"[%ROTATE_TRIES%/%TARGET_TRIES%] suppression de l'ancien enregistrement...","[%ROTATE_TRIES%/%TARGET_TRIES%] new registration...":"[%ROTATE_TRIES%/%TARGET_TRIES%] nouvel enregistrement...","[%ROTATE_TRIES%] reconnect...":"[%ROTATE_TRIES%] reconnexion...","[%ROTATE_TRIES%] waiting %WARP_WAIT%s...":"[%ROTATE_TRIES%] attente de %WARP_WAIT%s...","[%ROTATE_TRIES%] %IPN% was already tried in this hunt, rotating again":"[%ROTATE_TRIES%] %IPN% d\u00e9j\u00e0 essay\u00e9e pendant cette recherche, nouvelle rotation","[%ROTATE_TRIES%/%TARGET_TRIES%] exit IP %IPN% (country %GLOC%), target %TMATCHTXT%, %HUNT_LEFT% attempt(s) left":"[%ROTATE_TRIES%/%TARGET_TRIES%] IP de sortie %IPN% (pays %GLOC%), cible %TMATCHTXT%, %HUNT_LEFT% essai(s) restant(s)","[%ROTATE_TRIES%] probing if this IP can still talk...":"[%ROTATE_TRIES%] v\u00e9rification que cette IP peut encore se connecter...","%C_WARN%  [*] probe failed for a reason that is NOT a limit - attempt %PBROKEN% of %PROBE_BROKEN_MAX%. Last output:%C_RST%":"%C_WARN%  [*] la v\u00e9rification a \u00e9chou\u00e9 pour une raison qui n'est PAS une limite - essai %PBROKEN% sur %PROBE_BROKEN_MAX%. Derni\u00e8re sortie :%C_RST%","[%PROBE_TRIES%] IP already burned, rotating again...":"[%PROBE_TRIES%] IP d\u00e9j\u00e0 grill\u00e9e, nouvelle rotation...","%C_WARN%  [*] %PROBE_TRIES% IPs probed, every one of them already burned.%C_RST%":"%C_WARN%  [*] %PROBE_TRIES% IP v\u00e9rifi\u00e9es, toutes d\u00e9j\u00e0 grill\u00e9es.%C_RST%","%C_WARN%  [*] the probe failed %PBROKEN% times and none of them was a limit error.%C_RST%":"%C_WARN%  [*] la v\u00e9rification a \u00e9chou\u00e9 %PBROKEN% fois et aucune n'\u00e9tait une erreur de limite.%C_RST%","      The probe itself is broken, not every IP: a retired PROBE_MODEL id,":"      Le probl\u00e8me vient de la v\u00e9rification, pas de toutes les IP : un identifiant PROBE_MODEL","      an auth error or a CLI change. Rotation cannot fix that.":"      retir\u00e9, une erreur d'authentification ou un changement de CLI.","      Check PROBE_MODEL in the settings block, or run the probe model once":"      V\u00e9rifiez PROBE_MODEL dans le bloc des r\u00e9glages, ou lancez le mod\u00e8le de test","      by hand to see the real error.":"      \u00e0 la main une fois pour voir la vraie erreur.","  [i] probe off for this session - IPs are accepted on WARP-trace proof":"  [i] v\u00e9rification d\u00e9sactiv\u00e9e pour cette session - les IP sont accept\u00e9es sur la seule","      only, and the resume's own limit check keeps catching burned ones.":"      preuve WARP, et la v\u00e9rification de limite \u00e0 la reprise continue de rep\u00e9rer les grill\u00e9es.","%C_WARN%  [*] the probe session \"%OC_PROBE_ID%\" does not exist and this%C_RST%":"%C_WARN%  [*] la session de v\u00e9rification \"%OC_PROBE_ID%\" n'existe pas et cette%C_RST%","      opencode build refused it. That is a probe problem, NOT a":"      version d'opencode l'a refus\u00e9e. C'est un probl\u00e8me de v\u00e9rification, PAS","      burned IP - no rotation can fix it.":"      une IP grill\u00e9e - aucune rotation ne peut le corriger.","  [i] the probe is off for this session: IPs are accepted on":"  [i] la v\u00e9rification est d\u00e9sactiv\u00e9e pour cette session : les IP sont accept\u00e9es sur la seule","      WARP-trace proof only, and the resume's own limit check still":"      preuve WARP, et la v\u00e9rification de limite \u00e0 la reprise rep\u00e8re toujours une grill\u00e9e.","      catches a burned one. To keep the probe, create the session by":"      Pour la garder, cr\u00e9ez la session \u00e0 la main une fois,","      hand once, or clear PROBE in the settings block.":"      ou effacez PROBE dans le bloc des r\u00e9glages.","%C_OK%[%ROTATE_TRIES%] IP %IPN% works.%C_RST%":"%C_OK%[%ROTATE_TRIES%] l'IP %IPN% fonctionne.%C_RST%","[%ROTATE_TRIES%] no verified WARP IP yet, retrying...":"[%ROTATE_TRIES%] pas encore d'IP WARP v\u00e9rifi\u00e9e, nouvel essai...","%C_WARN%  [*] no usable IP from this hunt. warp-cli errors, if any, are in %STATE_DIR%\\wcli.log%C_RST%":"%C_WARN%  [*] aucune IP utilisable pour cette recherche. Les erreurs warp-cli \u00e9ventuelles sont dans %STATE_DIR%\\wcli.log%C_RST%","  restarting the desktop app on the new egress...":"  red\u00e9marrage de l'application de bureau sur la nouvelle sortie...","  sending \"%RESUME_MSG%\" so the chat picks up where it stopped...":"  envoi de \"%RESUME_MSG%\" pour que le chat reprenne l\u00e0 o\u00f9 il s'est arr\u00eat\u00e9...","%C_WARN%  [*] proxy dead - retrying on the current egress instead of resuming.%C_RST%":"%C_WARN%  [*] proxy mort - nouvel essai sur la sortie actuelle au lieu de reprendre.%C_RST%","%C_WARN%  [*] no answer in %RESUME_TIMEOUT%s - this exit IP is dead.%C_RST%":"%C_WARN%  [*] pas de r\u00e9ponse en %RESUME_TIMEOUT%s - cette IP de sortie est morte.%C_RST%","%C_OK%  chat resumed on the new IP.%C_RST%":"%C_OK%  chat repris sur la nouvelle IP.%C_RST%","%C_WARN%  [*] the resume itself hit a limit - rotating again.%C_RST%":"%C_WARN%  [*] la reprise elle-m\u00eame a atteint une limite - nouvelle rotation.%C_RST%","  Egress is NONE - nothing to rotate.":"  La sortie est NONE - rien \u00e0 faire tourner.","  Restarting the launcher-managed Tor for a new circuit...":"  Red\u00e9marrage du Tor g\u00e9r\u00e9 par le launcher pour un nouveau circuit...","  TOR mode - this Tor was started outside the launcher.":"  Mode TOR - ce Tor a \u00e9t\u00e9 lanc\u00e9 hors du launcher.","  Restart it yourself for a new circuit, or pick [1] WARP / [4] NONE.":"  Red\u00e9marrez-le vous-m\u00eame pour un nouveau circuit, ou choisissez [1] WARP / [4] NONE.","  Current bridge: http://127.0.0.1:%TOR_HTTP_PORT%":"  Pont actuel : http://127.0.0.1:%TOR_HTTP_PORT%","  Picking a new free HTTP proxy...":"  Recherche d'un nouveau proxy HTTP gratuit...","  New proxy: %ACTIVE_PROXY%":"  Nouveau proxy : %ACTIVE_PROXY%","WARP is not available - nothing to rotate.":"WARP n'est pas disponible - rien \u00e0 faire tourner.","Requesting a new WARP registration...":"Demande d'un nouvel enregistrement WARP...","waiting %WARP_WAIT%s...":"attente de %WARP_WAIT%s...","%C_WARN%  [*] no verified WARP IP.%C_RST%":"%C_WARN%  [*] aucune IP WARP v\u00e9rifi\u00e9e.%C_RST%","      warp-cli errors land in %STATE_DIR%\\wcli.log":"      les erreurs warp-cli sont dans %STATE_DIR%\\wcli.log","  same IP as before: %IPN%":"  m\u00eame IP qu'avant : %IPN%","%C_OK%  New exit IP: %IPN% (WARP verified)%C_RST%":"%C_OK%  Nouvelle IP de sortie : %IPN% (WARP v\u00e9rifi\u00e9)%C_RST%","  --- resume stderr ---":"  --- stderr de la reprise ---","  --- resume stdout ---":"  --- stdout de la reprise ---","  downloading the WARP installer, about 60 MB...":"  t\u00e9l\u00e9chargement de l'installateur WARP, environ 60 Mo...","%C_WARN%  [*] download failed.%C_RST%":"%C_WARN%  [*] le t\u00e9l\u00e9chargement a \u00e9chou\u00e9.%C_RST%","      grab it by hand and run it: %WARP_MSI_URL%":"      t\u00e9l\u00e9chargez-le \u00e0 la main et lancez-le : %WARP_MSI_URL%","  installing, accept the UAC prompt...":"  installation, acceptez l'invite UAC...","  [auto-install] the standalone build did not install, trying npm.":"  [auto-install] la version autonome n'a pas \u00e9t\u00e9 install\u00e9e, essai avec npm.","  [i] 32-bit Windows: no standalone build - installing via npm.":"  [i] Windows 32 bits : pas de version autonome - installation via npm.","%C_OK%  [ok] opencode ready on 32-bit via npm.%C_RST%":"%C_OK%  [ok] opencode pr\u00eat sur 32 bits via npm.%C_RST%","%C_ERR%  ERROR: opencode could not be installed on 32-bit Windows.%C_RST%":"%C_ERR%  ERREUR : opencode n'a pas pu \u00eatre install\u00e9 sur Windows 32 bits.%C_RST%","         Install 32-bit node.js by hand from nodejs.org, then run:":"         Installez node.js 32 bits \u00e0 la main depuis nodejs.org, puis lancez :","         npm i -g opencode-ai":"         npm i -g opencode-ai","%C_WARN%  [*] could not read the official release info from opencode.ai.%C_RST%":"%C_WARN%  [*] impossible de lire les informations de version officielles sur opencode.ai.%C_RST%","  [auto-install] downloading opencode %OCA_VER% (official build, %OC_AFILE%)...":"  [auto-install] t\u00e9l\u00e9chargement d'opencode %OCA_VER% (version officielle, %OC_AFILE%)...","%C_WARN%    [*] checksum mismatch - the download is not the official file.%C_RST%":"%C_WARN%    [*] somme de contr\u00f4le incorrecte - le fichier n'est pas le fichier officiel.%C_RST%","%C_WARN%    [*] download failed.%C_RST%":"%C_WARN%    [*] le t\u00e9l\u00e9chargement a \u00e9chou\u00e9.%C_RST%","  [auto-install] unpacking, about 200 MB on disk...":"  [auto-install] d\u00e9compression, environ 200 Mo sur le disque...","  [auto-install] installing %NPMPKG% with npm...":"  [auto-install] installation de %NPMPKG% avec npm...","  [npm] the install script was blocked - running it by hand...":"  [npm] le script d'installation a \u00e9t\u00e9 bloqu\u00e9 - ex\u00e9cution \u00e0 la main...","  [auto-install] node.js (32-bit) is missing - installing it...":"  [auto-install] node.js (32 bits) manquant - installation...","    via winget...":"    via winget...","  [i] this can take a few minutes on its first run.":"  [i] cela peut prendre quelques minutes la premi\u00e8re fois.","    winget failed - trying the MSI installer from nodejs.org...":"    winget a \u00e9chou\u00e9 - essai avec l'installateur MSI de nodejs.org...","    downloading %NODE_MSI_URL% ...":"    t\u00e9l\u00e9chargement de %NODE_MSI_URL% ...","    direct download failed - retrying through the Windows proxy settings...":"    t\u00e9l\u00e9chargement direct \u00e9chou\u00e9 - nouvel essai avec les param\u00e8tres proxy de Windows...","    installing, accept the UAC prompt...":"    installation, acceptez l'invite UAC...","  opencode update available: %OCUPD_CUR% -> %OCUPD_LAT%":"  mise \u00e0 jour d'opencode disponible : %OCUPD_CUR% -> %OCUPD_LAT%","  It closes every running opencode process first.":"  Tous les processus opencode en cours seront d'abord ferm\u00e9s.","  [update] npm i -g @opencode/cli@latest":"  [update] npm i -g @opencode/cli@latest","  [update] official standalone build %OCUPD_LAT%":"  [update] version autonome officielle %OCUPD_LAT%","%C_WARN%  [*] \"%OC_CMD%\" reports %OC_VER% but this machine has a v2 database.%C_RST%":"%C_WARN%  [*] \"%OC_CMD%\" annonce %OC_VER% mais cette machine a une base de donn\u00e9es v2.%C_RST%","      A v1 binary cannot open it: \"Database is not empty and has no session table\".":"      Un binaire v1 ne peut pas l'ouvrir : \"Database is not empty and has no session table\".","      Update it:  npm i -g @opencode/cli@latest   (or accept the update offer)":"      Mettez-le \u00e0 jour :  npm i -g @opencode/cli@latest   (ou acceptez la proposition de mise \u00e0 jour)","%C_WARN%  [*] WARP registration missing - creating a new one.%C_RST%":"%C_WARN%  [*] enregistrement WARP absent - cr\u00e9ation d'un nouveau.%C_RST%","  [tor] nothing answering on :%TOR_HTTP_PORT% - portable setup starting...":"  [tor] rien ne r\u00e9pond sur :%TOR_HTTP_PORT% - d\u00e9marrage de l'installation portable...","%C_WARN%  [*] Tor did not become ready - the reason is in \"%TOR_DIR%\\tor.log\"%C_RST%":"%C_WARN%  [*] Tor n'a pas \u00e9t\u00e9 pr\u00eat - la raison est dans \"%TOR_DIR%\\tor.log\"%C_RST%","%C_WARN%  [*] the Tor download did not land. Grab it by hand:%C_RST%":"%C_WARN%  [*] le t\u00e9l\u00e9chargement de Tor n'a pas abouti. T\u00e9l\u00e9chargez-le \u00e0 la main :%C_RST%","      https://dist.torproject.org/torbrowser/":"      https://dist.torproject.org/torbrowser/","      unpack the tor-expert-bundle tar.gz into \"%TOR_DIR%\",":"      d\u00e9compressez le tor-expert-bundle tar.gz dans \"%TOR_DIR%\",","      so that \"%TOR_DIR%\\Tor\\tor.exe\" exists, then run this again.":"      pour que \"%TOR_DIR%\\Tor\\tor.exe\" existe, puis relancez ceci.","%C_OK%  [tor] ready: SOCKS :%TOR_SOCKS_PORT% - HTTP :%TOR_HTTP_PORT%.%C_RST%":"%C_OK%  [tor] pr\u00eat : SOCKS :%TOR_SOCKS_PORT% - HTTP :%TOR_HTTP_PORT%.%C_RST%","  [tor] updater JSON unavailable - falling back to the dist index...":"  [tor] JSON de mise \u00e0 jour indisponible - utilisation de l'index de distribution...","%C_WARN%  [*] the Tor bundle did not download.%C_RST%":"%C_WARN%  [*] le paquet Tor n'a pas \u00e9t\u00e9 t\u00e9l\u00e9charg\u00e9.%C_RST%","  [tor] unpacking...":"  [tor] d\u00e9compression...","%C_OK%  [ok] Tor installed - portable - in \"%TOR_DIR%\".%C_RST%":"%C_OK%  [ok] Tor install\u00e9 - portable - dans \"%TOR_DIR%\".%C_RST%","%C_WARN%  [*] the bundle unpacked but tor.exe was not found in \"%TOR_DIR%\".%C_RST%":"%C_WARN%  [*] le paquet est d\u00e9compress\u00e9 mais tor.exe est introuvable dans \"%TOR_DIR%\".%C_RST%","  [tor] a Tor is already running on :%TOR_SOCKS_PORT% - using it as it is.":"  [tor] un Tor tourne d\u00e9j\u00e0 sur :%TOR_SOCKS_PORT% - utilisation telle quelle.","  [tor] starting tor (hidden window, log: \"%OC_TORLOG%\")...":"  [tor] d\u00e9marrage de tor (fen\u00eatre cach\u00e9e, journal : \"%OC_TORLOG%\")...","%C_WARN%  [*] tor could not be started - see \"%OC_TORERR%\" and \"%OC_TORLOG%\".%C_RST%":"%C_WARN%  [*] impossible de d\u00e9marrer tor - voir \"%OC_TORERR%\" et \"%OC_TORLOG%\".%C_RST%","  [tor] starting the built-in HTTP->SOCKS bridge on :%TOR_HTTP_PORT% (no Privoxy needed)...":"  [tor] d\u00e9marrage du pont HTTP->SOCKS int\u00e9gr\u00e9 sur :%TOR_HTTP_PORT% (sans Privoxy)...","  [tor] bootstrapping, up to %TOR_BOOTSTRAP_WAIT%s (the first run takes longer)...":"  [tor] connexion, jusqu'\u00e0 %TOR_BOOTSTRAP_WAIT%s (la premi\u00e8re fois est plus longue)...","  [tor] Tor is up and routing through the bridge.":"  [tor] Tor est actif et passe par le pont.","  [tor] still not up after %TOR_BOOTSTRAP_WAIT%s.":"  [tor] toujours pas actif apr\u00e8s %TOR_BOOTSTRAP_WAIT%s.","  [tor] found a Tor Browser SOCKS on :9150 - using it.":"  [tor] un SOCKS de Tor Browser trouv\u00e9 sur :9150 - utilisation.","  [tor] found a Tor SOCKS on :9050 - using it.":"  [tor] un SOCKS de Tor trouv\u00e9 sur :9050 - utilisation.","  [*] this Tor was not started by the launcher - it cannot be renewed":"  [*] ce Tor n'a pas \u00e9t\u00e9 lanc\u00e9 par le launcher - impossible de le renouveler","      from here. Restart Tor Browser yourself, or pick [1] WARP / [4] NONE.":"      d'ici. Red\u00e9marrez Tor Browser vous-m\u00eame, ou choisissez [1] WARP / [4] NONE.","  WARP proxy is not answering - cannot verify the exit IP.":"  Le proxy WARP ne r\u00e9pond pas - impossible de v\u00e9rifier l'IP de sortie.","  same IP as the last run, requesting a new registration...":"  m\u00eame IP que la derni\u00e8re fois, demande d'un nouvel enregistrement...","  [%EN_TRIES%] dropping the old registration...":"  [%EN_TRIES%] suppression de l'ancien enregistrement...","  [%EN_TRIES%] new registration...":"  [%EN_TRIES%] nouvel enregistrement...","  [%EN_TRIES%] reconnecting WARP proxy...":"  [%EN_TRIES%] reconnexion du proxy WARP...","  [%EN_TRIES%] waiting %WARP_WAIT%s...":"  [%EN_TRIES%] attente de %WARP_WAIT%s...","  exit IP: %CUR%":"  IP de sortie : %CUR%","  no new IP after %ROTATE_TRIES_MAX% tries, launching on the current one.":"  pas de nouvelle IP apr\u00e8s %ROTATE_TRIES_MAX% essais, lancement sur l'actuelle.","  [note] opencode log not found: \"%LOGFILE%\"":"  [note] journal opencode introuvable : \"%LOGFILE%\"","         auto-detect stays off until the log appears.":"         la d\u00e9tection automatique reste d\u00e9sactiv\u00e9e tant que le journal n'appara\u00eet pas.","  OpenCode desktop update available: %DVER% -> %OCA_VER%":"  mise \u00e0 jour de l'application de bureau OpenCode disponible : %DVER% -> %OCA_VER%","  It closes every OpenCode process first, the app and its service included.":"  Tous les processus OpenCode seront d'abord ferm\u00e9s, l'application et son service compris.","  downloading the OpenCode desktop installer %OCA_VER%, about 250 MB...":"  t\u00e9l\u00e9chargement de l'installateur de l'application de bureau OpenCode %OCA_VER%, environ 250 Mo...","  [*] checksum mismatch - the download is not the official file.":"  [*] somme de contr\u00f4le incorrecte - le fichier n'est pas le fichier officiel.","  [*] download failed.":"  [*] le t\u00e9l\u00e9chargement a \u00e9chou\u00e9.","      grab it by hand and run it: %ID_URL%":"      t\u00e9l\u00e9chargez-le \u00e0 la main et lancez-le : %ID_URL%","      or from the website: https://opencode.ai/download":"      ou depuis le site : https://opencode.ai/download","  installing, accept the UAC prompt if one appears...":"  installation, acceptez l'invite UAC si elle appara\u00eet...","  [*] could not read the official release info from opencode.ai.":"  [*] impossible de lire les informations de version officielles sur opencode.ai.","      get the installer by hand: https://opencode.ai/download":"      obtenez l'installateur \u00e0 la main : https://opencode.ai/download","  [*] the desktop app has no 32-bit Windows build.":"  [*] l'application de bureau n'a pas de version Windows 32 bits.","[verify] egress: %EGRESS%":"[verify] sortie : %EGRESS%","[verify] ip=%IPN% warp=%WFLAG%":"[verify] ip=%IPN% warp=%WFLAG%","[verify] Cloudflare WARP is not installed (warp-cli not found).":"[verify] Cloudflare WARP n'est pas install\u00e9 (warp-cli introuvable).","[renew] egress: %EGRESS%":"[renew] sortie : %EGRESS%","[renew] new exit IP: %IPN%":"[renew] nouvelle IP de sortie : %IPN%","[renew] Cloudflare WARP is not installed (warp-cli not found).":"[renew] Cloudflare WARP n'est pas install\u00e9 (warp-cli introuvable).","[renew] proxy: %ACTIVE_PROXY%":"[renew] proxy : %ACTIVE_PROXY%","[renew] done":"[renew] termin\u00e9","[renew] could not get a working connection":"[renew] impossible d'obtenir une connexion fonctionnelle","  archiving chats to:":"  archivage des chats dans :","  nothing to archive.":"  rien \u00e0 archiver.","  archived.":"  archiv\u00e9.","  [*] could not move the storage folder - it stays where it is.":"  [*] impossible de d\u00e9placer le dossier de stockage - il reste \u00e0 sa place.","  [*] could not copy %1 - it stays where it is.":"  [*] impossible de copier %1 - il reste \u00e0 sa place.","  [*] size mismatch on %1 - the bad copy is deleted, the original stays.":"  [*] taille diff\u00e9rente pour %1 - la mauvaise copie est supprim\u00e9e, l'original reste.","  cache and tokens cleared.":"  cache et jetons effac\u00e9s.","  auth.json archived in \"%TARGET%\".":"  auth.json archiv\u00e9 dans \"%TARGET%\".","  [*] the auth.json copy did not verify - tokens are left in place.":"  [*] la copie d'auth.json n'a pas \u00e9t\u00e9 v\u00e9rifi\u00e9e - les jetons restent en place.","  [*] could not copy auth.json - tokens are left in place.":"  [*] impossible de copier auth.json - les jetons restent en place.","  [*] no archive folder for this reset - auth.json is left in place.":"  [*] aucun dossier d'archive pour cette r\u00e9initialisation - auth.json reste en place.","  [*] the WARP port answers SOCKS5 only, and OpenCode cannot use SOCKS.":"  [*] le port WARP ne r\u00e9pond qu'en SOCKS5, et OpenCode ne peut pas utiliser SOCKS.","      WARP is up, but no usable HTTP proxy can be handed to it.":"      WARP est actif, mais aucun proxy HTTP utilisable ne peut \u00eatre transmis \u00e0 OpenCode.","  [proxy] process-only: %ACTIVE_PROXY%":"  [proxy] processus seul : %ACTIVE_PROXY%","  [proxy] reading the proxy list...":"  [proxy] lecture de la liste de proxies...","  [proxy] %PCOUNT% proxies in the list":"  [proxy] %PCOUNT% proxies dans la liste","  [*] no proxies found in \"%PSRC%\"":"  [*] aucun proxy trouv\u00e9 dans \"%PSRC%\"","  [*] no proxy passed the API check, but %TRACE_ONLY% did reach Cloudflare.":"  [*] aucun proxy n'a pass\u00e9 le test de l'API, mais %TRACE_ONLY% a bien atteint Cloudflare.","      PROXY_API_CHECK_URL may be wrong - see the settings block.":"      PROXY_API_CHECK_URL est peut-\u00eatre faux - voir le bloc des r\u00e9glages.","  [proxy] live: %ACTIVE_PROXY%":"  [proxy] en service : %ACTIVE_PROXY%","  [*] OpenCode-Infinite is already open in another window.":"  [*] OpenCode-Infinite est d\u00e9j\u00e0 ouvert dans une autre fen\u00eatre.","  Exiting.":"  Fermeture.","  [upd] repo copy is %SU_RV%, older than %SU_LV% - keeping this one.":"  [upd] la copie du d\u00e9p\u00f4t est %SU_RV%, plus ancienne que %SU_LV% - celle-ci est conserv\u00e9e.","  [upd] launcher matches the repo, %SU_LV%.":"  [upd] le launcher correspond au d\u00e9p\u00f4t, %SU_LV%.","  [upd] update found: local %SU_LV% - repo %SU_RV%":"  [upd] mise \u00e0 jour trouv\u00e9e : locale %SU_LV% - d\u00e9p\u00f4t %SU_RV%","  [upd] swapping in %SU_RV% - this window closes now.":"  [upd] remplacement par %SU_RV% - cette fen\u00eatre se ferme maintenant.","  [upd] the swap could not be prepared - keeping %SU_LV%.":"  [upd] le remplacement n'a pas pu \u00eatre pr\u00e9par\u00e9 - %SU_LV% est conserv\u00e9.","        The downloaded copy is in \"%SU_TMP%\".":"        La copie t\u00e9l\u00e9charg\u00e9e est dans \"%SU_TMP%\".","  Press any key to close this window.":"  Appuyez sur une touche pour fermer cette fen\u00eatre.","Automatic rotation":"Rotation automatique","On: a limit or a closed opencode gets a new IP and the chat resumes. Off: the menu decides.":"Activ\u00e9e : une limite ou un opencode ferm\u00e9 obtient une nouvelle IP et le chat reprend. D\u00e9sactiv\u00e9e : c'est le menu qui d\u00e9cide.","Target country":"Pays cible","Keep asking for IPs until one is in this country, e.g. DE. Empty = any new IP.":"Continuer \u00e0 demander des IP jusqu'\u00e0 en obtenir une dans ce pays, p. ex. DE. Vide = n'importe quelle nouvelle IP.","Target IP prefix":"Pr\u00e9fixe d'IP cible","Keep asking until the IP starts with this, e.g. 104.28. Empty = not used.":"Continuer \u00e0 demander jusqu'\u00e0 ce que l'IP commence par ceci, p. ex. 104.28. Vide = non utilis\u00e9.","Max attempts per hunt":"Nombre max. d'essais par recherche","New IPs requested in one hunt. The hunt stops at this count.":"Nouvelles IP demand\u00e9es dans une recherche. La recherche s'arr\u00eate \u00e0 ce nombre.","Max minutes per hunt":"Minutes max. par recherche","The hunt stops after this many minutes.":"La recherche s'arr\u00eate apr\u00e8s ce nombre de minutes.","Seconds between attempts":"Secondes entre les essais","Pause between two attempts, so Cloudflare is not hit too fast.":"Pause entre deux essais, pour ne pas solliciter Cloudflare trop vite.","Activity log":"Journal d'activit\u00e9","Record what the launcher does in launcher.log so a problem can be diagnosed.":"Enregistre ce que fait le launcher dans launcher.log pour diagnostiquer un probl\u00e8me.","Log size limit (KB)":"Taille max. du journal (Ko)","The log is cut to its newest part when it grows past this.":"Le journal est coup\u00e9 \u00e0 sa partie la plus r\u00e9cente quand il d\u00e9passe cette taille.","Hide IPs in reports":"Masquer les IP dans les rapports","Public IP addresses are masked in the support report.":"Les adresses IP publiques sont masqu\u00e9es dans le rapport de support.","config.json could not be read; a copy was kept as config.json.broken and defaults are in use.":"config.json n'a pas pu \u00eatre lu ; une copie a \u00e9t\u00e9 gard\u00e9e sous config.json.broken et les valeurs par d\u00e9faut sont utilis\u00e9es.","Two letters, like DE or US. Empty = any country.":"Deux lettres, comme DE ou US. Vide = n'importe quel pays.","The start of an IPv4 address, like 104.28. Empty = any IP.":"Le d\u00e9but d'une adresse IPv4, comme 104.28. Vide = n'importe quelle IP.","Value: {0}":"Valeur : {0}"," Back":" Retour","Windows Terminal settings.json was not found.":"settings.json de Windows Terminal introuvable.","settings.json was left untouched: the edit would not have kept it valid.":"settings.json n'a pas \u00e9t\u00e9 modifi\u00e9 : la modification ne l'aurait pas laiss\u00e9 valide.","Windows Terminal font put back as it was. Reopen the tab if it does not change.":"La police de Windows Terminal a \u00e9t\u00e9 remise en place. Rouvrez l'onglet si rien ne change.","Windows Terminal font set to ":"Police de Windows Terminal d\u00e9finie sur",". Backup of settings.json: ":". Sauvegarde de settings.json :","The Windows font API could not be loaded.":"L'API de polices de Windows n'a pas pu \u00eatre charg\u00e9e.","This window does not allow changing the font from here.":"Cette fen\u00eatre ne permet pas de changer la police d'ici.","The font was never changed, nothing to restore.":"La police n'a jamais \u00e9t\u00e9 chang\u00e9e, rien \u00e0 restaurer.","Windows refused that font in this console.":"Windows a refus\u00e9 cette police dans cette console.","This console refused \"":"Cette console a refus\u00e9 \"","\" and kept \"":"\" et gard\u00e9 \"","\". Older classic consoles only take the fonts Windows registers for them (":"\". Les anciennes consoles classiques n'acceptent que les polices enregistr\u00e9es par Windows pour elles (","). Windows Terminal accepts any installed font.":"). Windows Terminal accepte toute police install\u00e9e.","Console font set to ":"Police de la console d\u00e9finie sur",". It lasts while this window is open and is applied again at every launcher start.":". Elle reste tant que cette fen\u00eatre est ouverte et est r\u00e9appliqu\u00e9e \u00e0 chaque d\u00e9marrage du launcher.","This terminal keeps its font in its own settings (VS Code: terminal.integrated.fontFamily).":"Ce terminal garde sa police dans ses propres r\u00e9glages (VS Code : terminal.integrated.fontFamily).","Could not change the font: ":"Impossible de changer la police :"," The setting was not changed.":" Le r\u00e9glage n'a pas \u00e9t\u00e9 modifi\u00e9.","Enter, arrows":"Entr\u00e9e, fl\u00e8ches"," Connect with opencode":" Connecter avec opencode"," CLI":" CLI"," Desktop app":" Application de bureau"," Exit":" Quitter","There is no saved folder yet. Use one of the other options once.":"Aucun dossier enregistr\u00e9 pour l'instant. Utilisez une des autres options une fois.","Cloudflare":"Cloudflare","bridge :":"pont :","CLI / Desktop":"CLI / Bureau","Automatic (follow Windows)":"Automatique (selon Windows)","Use the language Windows is set to on every start; English when there is no translation.":"Utilise la langue de Windows \u00e0 chaque d\u00e9marrage ; anglais s'il n'y a pas de traduction."," (detected)":" (d\u00e9tect\u00e9)","Detected from Windows and selected. You can change it in Settings, Appearance.":"D\u00e9tect\u00e9 depuis Windows et s\u00e9lectionn\u00e9. Vous pouvez le changer dans R\u00e9glages, Apparence.","You can change it in Settings, Appearance.":"Vous pouvez le changer dans R\u00e9glages, Apparence.","Choose your language":"Choisissez votre langue"," Launch OpenCode":" Lancer OpenCode"," Renew session":" Renouveler la session"," Uninstall":" D\u00e9sinstaller"," Support report":" Rapport de support","not a url":"pas une URL","Sessions":"Sessions","Pick a chat from this folder and continue it. CLI only.":"Choisissez un chat de ce dossier et reprenez-le. CLI uniquement.","The desktop app has no session list. Switch to CLI to pick a chat.":"L'app de bureau n'a pas de liste de sessions. Passez en CLI pour choisir un chat.","Could not read the sessions: {0}":"Impossible de lire les sessions : {0}","No sessions in this folder yet.":"Aucune session dans ce dossier pour le moment.","Untitled session":"Session sans titre","Sessions in this folder":"Sessions de ce dossier","  [9] Sessions      - continue a chat from this folder":"  [9] Sessions      - reprendre un chat de ce dossier","Change IP (test)":"Changer d'IP (test)","Clear tokens and cache, then start":"Effacer les tokens et le cache, puis lancer","keeps chats":"garde les chats","Deep reset or restore chats":"R\u00e9initialisation profonde ou restauration des chats","submenu":"sous-menu","Mode (CLI or Desktop)":"Mode (CLI ou Bureau)","New IP and start OpenCode":"Nouvelle IP et lancer OpenCode","Kill opencode, save the login file to the Desktop, clear the cache, then open OpenCode. Chats stay where they are.":"Ferme opencode, enregistre le fichier de connexion sur le Bureau, vide le cache, puis ouvre OpenCode. Les chats restent en place.","Rotate the connection only, without opening OpenCode.":"Change seulement la connexion, sans ouvrir OpenCode.","Deep reset moves your chats to the Desktop and clears tokens and cache. Restore brings chats back from an earlier reset.":"La r\u00e9initialisation profonde d\u00e9place vos chats sur le Bureau et efface les tokens et le cache. La restauration rapporte les chats d'une r\u00e9initialisation pr\u00e9c\u00e9dente.","Move your chats to the Desktop archive, clear tokens and cache, then start fresh.":"D\u00e9place vos chats dans l'archive du Bureau, efface les tokens et le cache, puis repart de z\u00e9ro.","Restore chats":"Restaurer les chats","from the Desktop":"depuis le Bureau","Bring chats back from an earlier deep reset.":"Rapporte les chats d'une r\u00e9initialisation profonde pr\u00e9c\u00e9dente.","Return to the deep reset menu.":"Retour au menu de r\u00e9initialisation profonde.","Return to the home screen.":"Retour \u00e0 l'\u00e9cran d'accueil.","Restore chats from a backup":"Restaurer les chats depuis une sauvegarde","No archived chats yet. A deep reset creates one on the Desktop.":"Aucun chat archiv\u00e9 pour l'instant. Une r\u00e9initialisation profonde en cr\u00e9e un sur le Bureau.","{0} file":"{0} fichier","{0} files":"{0} fichiers","Windows Terminal font size set to {0}. Reopen the tab if it does not change.":"La taille de police de Windows Terminal est r\u00e9gl\u00e9e sur {0}. Rouvrez l'onglet si rien ne change.","Restore now?":"Restaurer maintenant ?","  Nothing to restore in that backup.":"  Rien \u00e0 restaurer dans cette sauvegarde.","  Restore the chats from:":"  Restaurer les chats depuis :","  The chats in place now are moved to the Desktop first. Nothing is deleted.":"  Les chats actuels sont d'abord d\u00e9plac\u00e9s sur le Bureau. Rien n'est supprim\u00e9.","  [*] some storage files did not copy. The backup is untouched.":"  [*] certains fichiers de stockage n'ont pas \u00e9t\u00e9 copi\u00e9s. La sauvegarde est intacte.","  Chats restored. The previous ones are in:":"  Chats restaur\u00e9s. Les pr\u00e9c\u00e9dents se trouvent dans :"}
#>>>LANG it {" move   Enter select   Esc back   1-9 or letter jump":" sposta   Invio scegli   Esc indietro   1-9 o lettera per saltare","(Enter = keep \"{0}\")":"(Invio = mantieni \"{0}\")","(auto)":"(auto)","(nothing saved yet)":"(ancora nulla di salvato)","(terminal default)":"(predefinito del terminale)","* = changed from the default. Enter edits or toggles the selected value.":"* = diverso dal predefinito. Invio modifica o alterna il valore selezionato.","A downloaded list smaller than this is rejected. 0 = off.":"Un elenco scaricato pi\u00f9 piccolo di questo viene rifiutato. 0 = disattivato.","A port is a number from 1 to 65535.":"Una porta \u00e8 un numero da 1 a 65535.","A proxy must also reach the opencode API host.":"Un proxy deve raggiungere anche il server API di opencode.","API check URL":"URL di verifica dell'API","Accent colors of the interface.":"Colori di accento dell'interfaccia.","Adding the command to your PATH":"Aggiunta del comando al PATH","Adds: opencode command (shim), two shortcuts, one PATH entry. Backups are kept.":"Aggiunge: il comando opencode (shim), due collegamenti e una voce nel PATH. I backup vengono conservati.","Any installed font name, for example Cascadia Code.":"Qualsiasi nome di carattere installato, per esempio Cascadia Code.","Appearance":"Aspetto","Applies at the {0}.":"Si applica a: {0}.","Apply":"Applica","Apply setup":"Applica la configurazione","Ask every time":"Chiedi ogni volta","Attempts per round when the tunnel is not up.":"Tentativi per giro quando il tunnel non \u00e8 attivo.","Back":"Indietro","Backing up the current configuration":"Backup della configurazione attuale","Browse for a folder...":"Scegli una cartella...","Burned IPs allowed":"IP bruciati ammessi","Burned proxies before Tor offer":"Proxy bruciati prima di offrire Tor","Burned proxies in a row before PROXY mode offers Tor.":"Proxy bruciati di fila prima che la modalit\u00e0 PROXY offra Tor.","CLI terminal, Desktop app, or ask at every start.":"Terminale CLI, app desktop, oppure chiedi a ogni avvio.","Cancel":"Annulla","Cancel. Nothing is changed.":"Annulla. Non viene modificato nulla.","Change IP":"Cambia IP","Change an answer.":"Cambia una risposta.","Change any launcher setting: connection, proxies, Tor, rotation, themes, font. Applied right away.":"Modifica qualsiasi impostazione del launcher: connessione, proxy, Tor, rotazione, temi, carattere. Applicata subito.","Check GitHub for a newer launcher at every start.":"Cerca su GitHub un launcher pi\u00f9 recente a ogni avvio.","Check the API host":"Verifica il server API","Checking that it works":"Verifica del funzionamento","Checking the connection":"Verifica della connessione","Choose \"Renew session\" below. It gets a new IP and clears the saved login;":"Scegli \u00abRinnova sessione\u00bb qui sotto. Ottiene un nuovo IP e cancella l'accesso salvato;","Choose a folder to work in":"Scegli una cartella di lavoro","Choose one of: {0}.":"Scegli uno tra: {0}.","Choose the connection for OpenCode":"Scegli la connessione per OpenCode","Close the launcher.":"Chiudi il launcher.","Closes every running opencode process.":"Chiude tutti i processi opencode in esecuzione.","Cloudflare WARP in local proxy mode. Every rotation asks for a new registration, which gives a new exit IP. Needs the WARP client (offered if missing).":"Cloudflare WARP in modalit\u00e0 proxy locale. Ogni rotazione chiede una nuova registrazione, che d\u00e0 un nuovo IP di uscita. Richiede il client WARP (offerto se manca).","Cloudflare WARP in proxy mode. A new registration gives a new exit IP. Rotation supported.":"Cloudflare WARP in modalit\u00e0 proxy. Una nuova registrazione d\u00e0 un nuovo IP di uscita. Rotazione supportata.","Cloudflare throttles rapid registrations.":"Cloudflare limita le registrazioni ravvicinate.","Collect system info, versions, settings and the recent log into one text file you can send for help. Passwords, tokens, your user name and (by default) IPs are removed first.":"Raccoglie info di sistema, versioni, impostazioni e il registro recente in un file di testo da inviare per chiedere aiuto. Prima vengono rimossi password, token, nome utente e (per impostazione predefinita) gli IP.","Color theme":"Tema colori","Color theme, colors on or off, icon and border style, and the terminal font. Applied immediately.":"Tema colori, colori attivi o no, stile di icone e bordi, lingua e carattere del terminale. Applicato subito.","Colors":"Colori","Command":"Comando","Configured - {0}":"Configurato - {0}","Confirm":"Conferma","Connect with opencode":"Collega opencode","Connected: opencode now starts through {0}.":"Connesso: opencode ora si avvia tramite {0}.","Connecting opencode":"Collegamento di opencode","Connection":"Connessione","Connection method":"Metodo di connessione","Continue":"Continua","Continue WITHOUT the probe this session (IPs accepted untested)?":"Continuare SENZA il test in questa sessione (IP accettati senza prova)?","Continue anyway?":"Continuare comunque?","Continue direct?":"Continuare in diretta?","Continue without WARP?":"Continuare senza WARP?","Cooldown between attempts (s)":"Attesa tra i tentativi (s)","Copies auth.json to your Desktop, then clears the saved tokens.":"Copia auth.json sul Desktop, poi cancella i token salvati.","Copy the file path":"Copia il percorso del file","Creating shortcuts":"Creazione dei collegamenti","Creating the opencode command":"Creazione del comando opencode","Credentials inside a URL are not stored. Use a local file instead.":"Le credenziali dentro un URL non vengono salvate. Usa invece un file locale.","Deep reset":"Ripristino completo","Default connection method and run mode, the WARP proxy port and the warp-cli timings.":"Metodo di connessione e modalit\u00e0 di esecuzione predefiniti, porta del proxy WARP e tempi di warp-cli.","Default: {0}.":"Predefinito: {0}.","Desktop":"Desktop","Desktop app":"App desktop","Desktop app location, release metadata URL and lookup timeouts.":"Posizione dell'app desktop, URL dei metadati delle versioni e tempi di ricerca.","Desktop app path":"Percorso dell'app desktop","Direct, no proxy":"Diretta, senza proxy","Do it now.":"Fallo ora.","Do that now?":"Farlo ora?","Download and install it now?":"Scaricarla e installarla ora?","Download the portable Tor bundle when nothing answers.":"Scarica Tor portatile quando nulla risponde.","Egress":"Uscita","Egress used for opencode. ASK shows the picker at every start.":"Uscita usata da opencode. ASK mostra il selettore a ogni avvio.","Enter a full URL (http, https, ftp or file).":"Inserisci un URL completo (http, https, ftp o file).","Enter a whole number.":"Inserisci un numero intero.","Enter cycles: {0}.":"Invio scorre: {0}.","Enter toggles it.":"Invio lo attiva o disattiva.","Every change is saved at once to {0}":"Ogni modifica viene salvata subito in {0}","Exit":"Esci","Exit IP":"IP di uscita","Extra rounds (60 s apart) before giving up.":"Giri extra (a 60 s di distanza) prima di rinunciare.","Folder":"Cartella","Font name":"Nome del carattere","Font of the terminal text. Empty leaves the terminal as it is.":"Carattere del testo del terminale. Vuoto lascia il terminale com'\u00e8.","Font size":"Dimensione del carattere","Free HTTP proxies from your list (any format) or the default one. Each is tested before use.":"Proxy HTTP gratuiti dal tuo elenco (qualsiasi formato) o da quello predefinito. Ognuno viene provato prima dell'uso.","Free or your own list":"Gratuita o il tuo elenco","Fresh start":"Nuovo avvio","Full path of OpenCode.exe. Empty = search automatically.":"Percorso completo di OpenCode.exe. Vuoto = cerca automaticamente.","Get a new IP or proxy, then open OpenCode. Your chats and history stay untouched.":"Ottiene un nuovo IP o proxy e apre OpenCode. Chat e cronologia restano intatti.","Gets a new IP / WARP registration / Tor circuit / proxy.":"Ottiene un nuovo IP / registrazione WARP / circuito Tor / proxy.","Go ahead.":"Procedi.","Go back. Nothing is changed.":"Torna indietro. Non viene modificato nulla.","Guided setup: choose WARP, Tor, a proxy list or direct, then get an \"opencode\" command and a shortcut that start with it. It is tested at the end.":"Procedura guidata: scegli WARP, Tor, un elenco di proxy o la connessione diretta e ottieni un comando \u00abopencode\u00bb e un collegamento che partono con essa. Alla fine viene provata.","HTTP port of the built-in bridge opencode uses.":"Porta HTTP del ponte integrato usato da opencode.","Host used by the API check.":"Server usato dalla verifica dell'API.","How do you want to run OpenCode?":"Come vuoi eseguire OpenCode?","How many proxies to test before giving up.":"Quanti proxy provare prima di rinunciare.","How many times, and how fast, a new IP is requested when the free limit is hit.":"Quante volte e con che ritmo si chiede un nuovo IP quando si raggiunge il limite gratuito.","IPs the probe may reject before giving up. 0 = no limit.":"IP che il test pu\u00f2 rifiutare prima di rinunciare. 0 = nessun limite.","Icons and borders":"Icone e bordi","Install Tor automatically":"Installa Tor automaticamente","Keep the current connection and open OpenCode as it was.":"Mantiene la connessione attuale e apre OpenCode com'era.","Keep the current font.":"Mantieni il carattere attuale.","Kill opencode and clear the saved tokens, keeping your chats where they are.":"Chiude opencode e cancella i token salvati, lasciando le chat dove sono.","Kill opencode, move your chats to the Desktop, clear the saved tokens and open a fresh session.":"Chiude opencode, sposta le chat sul Desktop, cancella i token salvati e apre una sessione nuova.","Language":"Lingua","Language of the menus and descriptions. auto follows Windows. Logs and the support report stay in English.":"Lingua dei menu e delle descrizioni. auto segue Windows. I registri e il rapporto di supporto restano in inglese.","Last check":"Ultima verifica","Launch OpenCode":"Avvia OpenCode","Launcher":"Launcher","Launcher self-update":"Aggiornamento automatico del launcher","Leave the setup without changing anything.":"Esci dalla procedura senza cambiare nulla.","Leave the terminal font as it is. If the launcher changed it, the original font comes back.":"Lascia il carattere del terminale com'\u00e8. Se il launcher lo ha cambiato, torna l'originale.","Local Tor with a built-in HTTP bridge. A portable Tor is installed automatically if missing.":"Tor locale con un ponte HTTP integrato. Se manca, viene installato automaticamente un Tor portatile.","Local port of the WARP proxy.":"Porta locale del proxy WARP.","Logs":"Registri","Main menu":"Menu principale","Method":"Metodo","Minimum list size (bytes)":"Dimensione minima dell'elenco (byte)","Mode":"Modalit\u00e0","Model used by the IP probe.":"Modello usato dal test dell'IP.","Must be between {0} and {1}.":"Deve essere compreso tra {0} e {1}.","New IP and resume in 5s":"Nuovo IP e ripresa tra 5 s","No":"No","No .exe file exists at that path.":"Nessun file .exe esiste in quel percorso.","No answer in {0}s counts as No.":"Nessuna risposta in {0} s vale come No.","No change.":"Nessuna modifica.","No proxy: opencode uses your real connection and nothing is rotated.":"Nessun proxy: opencode usa la tua connessione reale e nulla viene ruotato.","No, cancel":"No, annulla","Non-limit probe failures before the hunt stops.":"Errori del test non legati al limite prima che la ricerca si fermi.","Not a URL, and no file exists at that path.":"Non \u00e8 un URL e in quel percorso non esiste alcun file.","Not configured":"Non configurato","Nothing to ask for a direct connection.":"Non c'\u00e8 nulla da chiedere per una connessione diretta.","Nothing was left half done that Uninstall cannot remove. Fix the problem and run setup again.":"Non \u00e8 rimasto nulla a met\u00e0 che Disinstalla non possa rimuovere. Risolvi il problema e rilancia la procedura.","On PATH":"Nel PATH","Only opencode uses it; the rest of the system stays direct.":"Solo opencode la usa; il resto del sistema resta diretto.","Open the Windows folder picker and choose where to work.":"Apre il selettore cartelle di Windows per scegliere dove lavorare.","Open the folder":"Apri la cartella","Open the launcher menus: pick a folder and a connection method, then start the opencode CLI or the desktop app.":"Apre i menu del launcher: scegli cartella e metodo di connessione, poi avvia la CLI di opencode o l'app desktop.","OpenCode app":"App OpenCode","PATH lookup timeout (s)":"Tempo massimo di ricerca nel PATH (s)","Paths":"Percorsi","Port {0} is already used by {1}.":"La porta {0} \u00e8 gi\u00e0 usata da {1}.","Ports and install behavior of the portable Tor the launcher starts for you.":"Porte e installazione del Tor portatile che il launcher avvia per te.","Press any key to continue...":"Premi un tasto per continuare...","Probe":"Test","Probe failures tolerated":"Errori di test tollerati","Probe model":"Modello di test","Proxies tried per pick":"Proxy provati per scelta","Proxy":"Proxy","Proxy list":"Elenco proxy","Proxy list source":"Origine dell'elenco proxy","Proxy test timeout (s)":"Tempo massimo del test di un proxy (s)","Public HTTP proxies from a list (yours, in any format, or the free default). Each one is tested first and burned ones are skipped.":"Proxy HTTP pubblici da un elenco (il tuo, in qualsiasi formato, o quello gratuito predefinito). Ognuno viene provato prima e quelli bruciati vengono saltati.","Put every setting back to its default. Your connection setup (command, shortcuts) is not touched. Asks first.":"Riporta tutte le impostazioni ai valori predefiniti. La configurazione della connessione (comando, collegamenti) non viene toccata. Chiede conferma.","Put the full path on the clipboard.":"Mette il percorso completo negli appunti.","Quotes and line breaks are not allowed.":"Virgolette e a capo non sono ammessi.","Range {0} to {1}.":"Intervallo da {0} a {1}.","Reconfigure (run setup again)":"Riconfigura (rilancia la procedura)","Release metadata URL":"URL dei metadati delle versioni","Removes only what setup added: the opencode command, the shortcuts and the PATH entry.":"Rimuove solo ci\u00f2 che la procedura ha aggiunto: il comando opencode, i collegamenti e la voce nel PATH.","Removes only what the setup added (command, shortcuts, PATH entry) and restores the settings it changed. Backups are kept. Asks first.":"Rimuove solo ci\u00f2 che la procedura ha aggiunto (comando, collegamenti, voce nel PATH) e ripristina le impostazioni modificate. I backup vengono conservati. Chiede conferma.","Removing shortcuts":"Rimozione dei collegamenti","Removing the opencode command":"Rimozione del comando opencode","Renew did not finish (code {0}).":"Il rinnovo non \u00e8 terminato (codice {0}).","Renew session":"Rinnova sessione","Renew the session?":"Rinnovare la sessione?","Renewed. Open opencode again; you may need to log in once more.":"Rinnovata. Riapri opencode; potrebbe servire accedere di nuovo.","Renewing":"Rinnovo","Renewing the session":"Rinnovo della sessione","Reopen the last folder":"Riapri l'ultima cartella","Report ready. Personal data was removed; read it once before you share it.":"Rapporto pronto. I dati personali sono stati rimossi; leggilo una volta prima di condividerlo.","Repository":"Repository","Reset every setting to its default?":"Riportare tutte le impostazioni ai valori predefiniti?","Reset to default values":"Ripristina i valori predefiniti","Restores the settings setup changed. Your other settings and your opencode files are kept.":"Ripristina le impostazioni modificate dalla procedura. Le altre impostazioni e i file di opencode restano.","Restoring PATH":"Ripristino del PATH","Restoring settings":"Ripristino delle impostazioni","Resume message":"Messaggio di ripresa","Resume timeout (s)":"Tempo massimo di ripresa (s)","Return to the connection details.":"Torna ai dettagli della connessione.","Return to the main menu.":"Torna al menu principale.","Return to the settings groups.":"Torna ai gruppi di impostazioni.","Review":"Riepilogo","Rotate the connection only (new WARP registration, Tor circuit or proxy) without opening OpenCode.":"Ruota solo la connessione (nuova registrazione WARP, circuito Tor o proxy) senza aprire OpenCode.","Rotate when a fatal error appears while opencode runs.":"Ruota quando compare un errore grave mentre opencode \u00e8 in esecuzione.","Rotation":"Rotazione","Rotation attempts":"Tentativi di rotazione","Rotation rounds":"Giri di rotazione","Run mode":"Modalit\u00e0 di esecuzione","Run opencode in this terminal. After a new IP the chat resumes by itself.":"Esegue opencode in questo terminale. Dopo un nuovo IP la chat riprende da sola.","Run the OpenCode desktop app ({0}). It is restarted after every new IP.":"Esegue l'app desktop di OpenCode ({0}). Viene riavviata dopo ogni nuovo IP.","Run the setup again to change the method or repair the opencode command.":"Rilancia la procedura per cambiare metodo o riparare il comando opencode.","SOCKS port of the Tor the launcher starts.":"Porta SOCKS del Tor avviato dal launcher.","Save the settings, create the opencode command, the shortcuts and the PATH entry, then test the connection.":"Salva le impostazioni, crea il comando opencode, i collegamenti e la voce nel PATH, poi prova la connessione.","Saved: {0} = {1}":"Salvato: {0} = {1}","Saving config.json":"Salvataggio di config.json","Seconds a single \"where\" lookup may take.":"Secondi che pu\u00f2 durare una ricerca con \"where\".","Seconds a single proxy test may take.":"Secondi che pu\u00f2 durare il test di un proxy.","Seconds a single warp-cli call may take.":"Secondi che pu\u00f2 durare una chiamata a warp-cli.","Seconds before a silent resume counts as a dead IP.":"Secondi prima che una ripresa senza risposta valga come IP morto.","Seconds to wait after (re)connecting WARP.":"Secondi di attesa dopo la (ri)connessione di WARP.","Seconds to wait for Tor to finish bootstrapping.":"Secondi di attesa perch\u00e9 Tor finisca di avviarsi.","See what the setup installed (command, shortcuts, PATH) and run it again to change the method.":"Vedi cosa ha installato la procedura (comando, collegamenti, PATH) e rilanciala per cambiare metodo.","Send one cheap message through each candidate IP.":"Invia un messaggio economico da ogni IP candidato.","Sent automatically after a rotation.":"Inviato automaticamente dopo una rotazione.","Settings":"Impostazioni","Settings and setup":"Impostazioni e configurazione","Setup 1/3 - connection method":"Configurazione 1/3 - metodo di connessione","Setup 2/3 - details":"Configurazione 2/3 - dettagli","Setup 3/3 - run mode":"Configurazione 3/3 - modalit\u00e0 di esecuzione","Setup stopped: {0}":"La procedura si \u00e8 fermata: {0}","Shortcuts":"Collegamenti","Show the CLI or Desktop choice every time the launcher opens.":"Mostra la scelta CLI o Desktop a ogni apertura del launcher.","Show the report in Explorer so you can attach or paste it.":"Mostra il rapporto in Esplora risorse per allegarlo o incollarlo.","Size used with the chosen font.":"Dimensione usata con il carattere scelto.","Support":"Supporto","Support report":"Rapporto di supporto","Switch between the terminal and the desktop app.":"Passa tra il terminale e l'app desktop.","Switch to Tor and keep going?":"Passare a Tor e continuare?","System":"Sistema","Takes effect at the {0}; a service already running keeps the old value until then.":"Ha effetto a: {0}; un servizio gi\u00e0 in esecuzione mantiene il valore precedente fino ad allora.","Terminal font":"Carattere del terminale","Test every new IP":"Prova ogni nuovo IP","The OpenCode desktop app was not found. Choosing this offers to download and install it.":"L'app desktop di OpenCode non \u00e8 stata trovata. Scegliendola si offre di scaricarla e installarla.","The OpenCode desktop app; it is restarted after every new IP.":"L'app desktop di OpenCode; viene riavviata dopo ogni nuovo IP.","The activity log (launcher.log) and the support report: what is recorded, how big it may grow, whether IPs are masked.":"Il registro attivit\u00e0 (launcher.log) e il rapporto di supporto: cosa viene registrato, quanto pu\u00f2 crescere e se gli IP vengono nascosti.","The cheap test message sent through every new IP before it is trusted.":"Il messaggio di prova economico inviato da ogni nuovo IP prima di fidarsene.","The check failed (code {0}). Setup is saved; fix the cause and use Renew or Connect again.":"La verifica \u00e8 fallita (codice {0}). La configurazione \u00e8 salvata; risolvi la causa e usa di nuovo Rinnova o Collega.","The font applies to the whole terminal window, not only to this launcher.":"Il carattere vale per tutta la finestra del terminale, non solo per questo launcher.","The proxy lives only in the opencode process; the rest of the system stays direct.":"Il proxy esiste solo nel processo opencode; il resto del sistema resta diretto.","The resume auto-approves tool permissions.":"La ripresa approva da sola i permessi degli strumenti.","The shortcut and the opencode command use the CLI; this is the launcher menu default.":"Il collegamento e il comando opencode usano la CLI; questo \u00e8 il predefinito del menu del launcher.","The terminal interface. The opencode command and the shortcut always use it.":"L'interfaccia da terminale. Il comando opencode e il collegamento la usano sempre.","This launcher is not the one that set it up. Reconfigure to repair the command.":"Questo launcher non \u00e8 quello che l'ha configurato. Riconfigura per riparare il comando.","Token reset":"Ripristino dei token","Tools and versions":"Strumenti e versioni","Tor HTTP bridge port":"Porta del ponte HTTP di Tor","Tor SOCKS port":"Porta SOCKS di Tor","Tor bootstrap wait (s)":"Attesa avvio di Tor (s)","Tor is downloaded once, run hidden and offered to opencode through a built-in HTTP bridge. Slower, but a new circuit is a new IP.":"Tor viene scaricato una volta, eseguito nascosto e offerto a opencode tramite un ponte HTTP integrato. Pi\u00f9 lento, ma un nuovo circuito \u00e8 un nuovo IP.","Try again in a minute, or pick another connection method in Connect with opencode.":"Riprova tra un minuto, oppure scegli un altro metodo di connessione in Collega opencode.","Try again?":"Riprovare?","Try to download and install WARP now?":"Provare a scaricare e installare WARP ora?","Type \"opencode\" in a NEW terminal, or use the \"OpenCode Infinite (egress)\" shortcut.":"Scrivi \u00abopencode\u00bb in un terminale NUOVO, oppure usa il collegamento \u00abOpenCode Infinite (egress)\u00bb.","Type < to go back. Enter keeps the value shown.":"Scrivi < per tornare indietro. Invio mantiene il valore mostrato.","Type a font name...":"Scrivi il nome di un carattere...","URL or local file, any format (plain, CSV, JSON, XML, HTML).":"URL o file locale, in qualsiasi formato (testo semplice, CSV, JSON, XML, HTML).","Unattended resume":"Ripresa non presidiata","Uninstall":"Disinstalla","Uninstall stopped: {0}":"La disinstallazione si \u00e8 fermata: {0}","Uninstall the opencode connection?":"Disinstallare la connessione di opencode?","Uninstalled. Backups stay in {0}":"Disinstallato. I backup restano in {0}","Uninstalling":"Disinstallazione","Update now?":"Aggiornare ora?","Updates":"Aggiornamenti","Use 1 to 200 characters.":"Usa da 1 a 200 caratteri.","Use it when the free limit is hit or the login expired: closes opencode, saves and clears the saved tokens, and gets a new IP, WARP registration, Tor circuit or proxy.":"Usalo quando si raggiunge il limite gratuito o l'accesso \u00e8 scaduto: chiude opencode, salva e cancella i token salvati e ottiene un nuovo IP, registrazione WARP, circuito Tor o proxy.","Use on or off.":"Usa on oppure off.","Use that proxy anyway?":"Usare comunque quel proxy?","Use this folder":"Usa questa cartella","Use up to 31 characters, without quotes or backslashes.":"Usa fino a 31 caratteri, senza virgolette n\u00e9 barre rovesciate.","Use {0} for the terminal text. Monospaced fonts only look right.":"Usa {0} per il testo del terminale. Solo i caratteri a spaziatura fissa si vedono bene.","Version":"Versione","View and change every launcher option: connection, proxies, Tor, rotation, themes. Saved instantly, no files to edit.":"Vedi e modifica ogni opzione del launcher: connessione, proxy, Tor, rotazione, temi. Salvato subito, nessun file da modificare.","WARP proxy port":"Porta del proxy WARP","WARP wait (s)":"Attesa WARP (s)","Watch the log":"Sorveglia il registro","Watcher":"Sorveglianza","Watching the opencode log and the automatic \"continue\" sent after a rotation.":"Sorveglianza del registro di opencode e del \u00abcontinue\u00bb automatico inviato dopo una rotazione.","Where proxies come from (URL or file, any format) and how each one is tested.":"Da dove arrivano i proxy (URL o file, qualsiasi formato) e come ciascuno viene provato.","Where versions and checksums are read from.":"Da dove si leggono versioni e checksum.","Whether the launcher checks GitHub for a newer copy of itself at every start.":"Se il launcher cerca su GitHub una copia pi\u00f9 recente di s\u00e9 a ogni avvio.","Work in a different folder.":"Lavora in un'altra cartella.","Work in the folder the launcher was started from: {0}":"Lavora nella cartella da cui \u00e8 stato avviato il launcher: {0}","Work in {0}":"Lavora in {0}","Writing the report":"Scrittura del rapporto","Yes":"S\u00ec","Yes, continue":"S\u00ec, continua","Your connection setup (shim, shortcuts) is not touched.":"La configurazione della connessione (shim, collegamenti) non viene toccata.","Your session needs renewing: {0}":"La sessione va rinnovata: {0}","asks first":"chiede conferma","auto":"auto","auto follows the terminal and NO_COLOR; off disables colors.":"auto segue il terminale e NO_COLOR; off disattiva i colori.","direct":"diretta","emoji = modern terminals, unicode = classic console, ascii = anything.":"emoji = terminali moderni, unicode = console classica, ascii = qualsiasi.","free list":"elenco gratuito","installed":"installata","missing":"mancante","new IP":"IP nuovo","next Tor start":"prossimo avvio di Tor","next WARP connect":"prossima connessione WARP","next launch":"prossimo avvio","no other step is needed.":"non serve nessun altro passaggio.","not installed":"non installata","not verified":"non verificato","off":"disattivato","on":"attivato","same IP":"stesso IP","terminal":"terminale","warp-cli timeout (s)":"Tempo massimo di warp-cli (s)","yes":"s\u00ec","{0} changed":"{0} modificati","{0} of {1}":"{0} di {1}","After opencode closes":"Dopo la chiusura di opencode","ask = R, M or Q: R gets a new IP and resumes the chat, M opens the menu, Q quits. quit = leave the launcher at once.":"ask = R, M o Q: R richiede un nuovo IP e riprende la chat, M apre il menu, Q esce. quit = chiude subito il launcher.","Rotate key":"Tasto di rotazione","Menu key":"Tasto del menu","Quit key":"Tasto di uscita","Closed-opencode prompt: new IP and resume the chat.":"Richiesta alla chiusura di opencode: nuovo IP e riprende la chat.","Closed-opencode prompt: open the menu.":"Richiesta a chiusura: apre il menu.","Closed-opencode prompt: quit. Ctrl+C always quits too.":"Richiesta a chiusura: esci. Ctrl+C esce sempre.","The keys of the launcher and the terminal commands. Fixed keys are listed for reference; the three letters can be changed.":"Tasti del launcher e comandi del terminale. I tasti fissi sono solo informativi; le tre lettere si possono cambiare.","One letter, like R.":"Una lettera, come R.","Key {0} is already used by {1}.":"Il tasto {0} \u00e8 gi\u00e0 usato da {1}.","Only the chosen language is downloaded from the langs folder of the repository.":"Viene scaricata solo la lingua scelta dalla cartella langs del repository.","Follow the language Windows uses.":"Segue la lingua di Windows.","Use this language for every menu and message.":"Usa questa lingua per tutti i menu e i messaggi.","Keep the current language.":"Mantieni la lingua attuale.","File to write (Enter = Desktop, Esc = back)":"File da scrivere (Invio = Desktop, Esc = indietro)","File to read (Esc = back)":"File da leggere (Esc = indietro)","That folder does not exist.":"La cartella non esiste.","Replace the file that is already there?":"Sostituire il file gi\u00e0 esistente?","Exported {0} changed setting(s) to {1}":"{0} impostazione/i modificata/e esportata/e in {1}","Import {0} setting(s)? Their current values are replaced.":"Importare {0} impostazione/i? I valori attuali vengono sostituiti.","{0} setting(s) of this file are unknown here and are skipped.":"{0} impostazione/i di questo file non esistono qui e vengono saltate.","No file at that path.":"Nessun file in quel percorso.","This is not an OpenCode Infinite settings file.":"Questo file non \u00e8 di impostazioni di OpenCode Infinite.","Nothing was imported. These values are not valid:":"Non \u00e8 stato importato nulla. Questi valori non sono validi:","Imported {0} setting(s).":"{0} impostazione/i importata/e.","Export settings to a file":"Esporta impostazioni in un file","Save every changed setting to one .json file, to keep a backup or copy them to another PC.":"Salva tutte le impostazioni modificate in un file .json, come backup o per un altro PC.","Import settings from a file":"Importa impostazioni da un file","Load a file made by Export. Every value is checked first; if one is wrong, nothing changes.":"Carica un file creato con Esporta. Ogni valore viene controllato prima; se uno \u00e8 sbagliato, non cambia nulla.","back to the previous screen":"torna alla schermata precedente","Fixed. In a menu or a text prompt Esc goes back; it never closes the launcher.":"Fisso. In un menu o in un campo di testo Esc torna indietro; non chiude mai il launcher.","select and move":"scegli e muovi","Fixed. Digits 1-9 jump straight to a row.":"Fisso. I numeri 1-9 vanno direttamente a una riga.","quit the launcher":"esci dal launcher","Fixed. Stops the processes it started and leaves the terminal open, no Y/N question.":"Fisso. Ferma i processi avviati e lascia aperto il terminale, senza domande S/N.","start with the connection":"avvia con la connessione","Terminal command from any folder. The Start menu shortcut does the same.":"Comando da terminale da qualsiasi cartella. La scorciatoia del menu Start fa lo stesso.","open this menu":"apri questo menu","Terminal command: opens the launcher menu again, as many times as you need.":"Comando da terminale: riapre il menu del launcher, quante volte serve.","original OpenCode":"OpenCode originale","Terminal command: starts the OpenCode you installed, without the launcher or the connection. Use it when the launcher breaks.":"Comando da terminale: avvia l'OpenCode installato, senza launcher n\u00e9 connessione. Usalo se il launcher si rompe.","Commands":"Comandi","Adds: the opencode, opencodeinf and opencodeoc commands, two shortcuts, one PATH entry. Backups are kept.":"Aggiunge i comandi opencode, opencodeinf e opencodeoc, due scorciatoie e una voce PATH. I backup restano.","  This copy is not the official one. Starting the official copy:":"  Questa copia non \u00e8 quella ufficiale. Avvio della copia ufficiale:","  OpenCode - how do you want to run it?":"  OpenCode - come vuoi avviarlo?","  [1] CLI      - terminal TUI (chat resumes on every new IP)":"  [1] CLI      - TUI nel terminale (la chat riprende a ogni nuovo IP)","  [2] Desktop  - the OpenCode desktop app (restarted on every new IP)":"  [2] Desktop  - l'app desktop di OpenCode (riavviata a ogni nuovo IP)","  [3] Exit":"  [3] Esci","  One key, no Enter.":"  Un tasto, senza Invio.","%C_WARN%  [*] OpenCode desktop not found.%C_RST%":"%C_WARN%  [*] App desktop di OpenCode non trovata.%C_RST%","%C_WARN%  [*] still not found - set OC_APP to its OpenCode.exe.%C_RST%":"%C_WARN%  [*] Ancora non trovata - imposta OC_APP con il percorso di OpenCode.exe.%C_RST%","  [app] DESKTOP \"%OC_DESKTOP%\"":"  [app] DESKTOP \"%OC_DESKTOP%\"","  OpenCode - choose a folder to work in":"  OpenCode - scegli una cartella di lavoro","  [1] Reopen the last folder":"  [1] Riapri l'ultima cartella","      (nothing saved yet)":"      (nessuna cartella salvata finora)","  [2] Use this folder":"  [2] Usa questa cartella","  [3] Browse for a folder...":"  [3] Sfoglia una cartella...","  [4] Exit":"  [4] Esci","  No folder saved yet. Use [2] or [3] this time.":"  Nessuna cartella salvata. Usa [2] o [3] questa volta.","  Choose a folder in the dialog...":"  Scegli una cartella nella finestra...","  Opening the classic folder picker...":"  Apertura del selettore di cartelle classico...","  No folder selected.":"  Nessuna cartella selezionata.","  Folder not found: \"%OPFOLDER%\"":"  Cartella non trovata: \"%OPFOLDER%\"","  Cannot enter: \"%OPFOLDER%\"":"  Impossibile entrare in: \"%OPFOLDER%\"","  Working in: \"%CD%\"":"  Lavoro in: \"%CD%\"","  [egress] %EGRESS% (from your settings)":"  [egress] %EGRESS% (dalle tue impostazioni)","  Choose egress for OpenCode only (system traffic stays direct)":"  Scegli l'uscita solo per OpenCode (il traffico di sistema resta diretto)","  [1] WARP     - Cloudflare WARP proxy mode (rotation supported)":"  [1] WARP     - modalit\u00e0 proxy Cloudflare WARP (supporta la rotazione)","  [2] TOR      - local Tor + built-in bridge on :%TOR_HTTP_PORT%":"  [2] TOR      - Tor locale + bridge integrato su :%TOR_HTTP_PORT%","                 (auto-installs a portable Tor, nothing to set up)":"                 (installa un Tor portatile, non c'\u00e8 nulla da configurare)","  [3] PROXY    - free HTTP proxies (ProxyScrape list)":"  [3] PROXY    - proxy HTTP gratuiti (elenco ProxyScrape)","  [4] NONE     - direct, no proxy":"  [4] NONE     - diretto, senza proxy","  [egress] NONE - direct.":"  [egress] NONE - diretto.","  [egress] PROXY - free HTTP list.":"  [egress] PROXY - elenco HTTP gratuito.","  [egress] TOR - portable Tor + built-in bridge on :%TOR_HTTP_PORT%, auto-setup.":"  [egress] TOR - Tor portatile + bridge integrato su :%TOR_HTTP_PORT%, configurazione automatica.","  [egress] WARP.":"  [egress] WARP.","  [dep] curl":"  [dep] curl","  [dep] warp":"  [dep] warp","%C_WARN%  [*] Cloudflare WARP not found - IP rotation will be disabled.%C_RST%":"%C_WARN%  [*] Cloudflare WARP non trovato - la rotazione dell'IP sar\u00e0 disattivata.%C_RST%","      Install it later from 1.1.1.1 if you want the rotation.":"      Installalo pi\u00f9 tardi da 1.1.1.1 se vuoi la rotazione.","%C_WARN%  [*] WARP still not available - continuing without rotation.%C_RST%":"%C_WARN%  [*] WARP ancora non disponibile - si continua senza rotazione.%C_RST%","      warp-cli errors, if any, are in %STATE_DIR%\\wcli.log":"      Gli eventuali errori di warp-cli sono in %STATE_DIR%\\wcli.log","%C_WARN%  [*] Cloudflare WARP publishes 64-bit Windows builds only.%C_RST%":"%C_WARN%  [*] Cloudflare WARP \u00e8 disponibile solo in versione a 64 bit per Windows.%C_RST%","      On this 32-bit system rotation is disabled.":"      Su questo sistema a 32 bit la rotazione \u00e8 disattivata.","%C_OK%  [ok] WARP ready.%C_RST%":"%C_OK%  [ok] WARP pronto.%C_RST%","  [dep] opencode":"  [dep] opencode","  [auto-install] opencode not found, fetching it...":"  [auto-install] opencode non trovato, download in corso...","%C_OK%  [ok] opencode ready.%C_RST%":"%C_OK%  [ok] opencode pronto.%C_RST%","%C_ERR%  ERROR: opencode install failed or is not on PATH.%C_RST%":"%C_ERR%  ERRORE: installazione di opencode fallita o non presente nel PATH.%C_RST%","  Get it by hand: https://github.com/sst/opencode/releases":"  Installalo a mano: https://github.com/sst/opencode/releases","  Preparing the connection...":"  Preparazione della connessione...","  OpenCode":"  OpenCode","  Folder : \"%CD%\"":"  Cartella : \"%CD%\"","  Egress : %EGRESS%":"  Uscita   : %EGRESS%","  Mode   : %APP_MODE%":"  Modalit\u00e0 : %APP_MODE%","  WARP   : none (rotation disabled)":"  WARP     : nessuno (rotazione disattivata)","  WARP   : \"%WARP%\"":"  WARP     : \"%WARP%\"","  Version: %OC_VER%  \"%OC_CMD%\"":"  Versione : %OC_VER%  \"%OC_CMD%\"","  Exit IP: %IP%":"  IP in uscita: %IP%","  What do you want to do?":"  Cosa vuoi fare?","  [1] Fresh start   - get a new IP / proxy, then open OpenCode":"  [1] Nuovo avvio - ottieni un nuovo IP / proxy, poi apri OpenCode","                      (your chats and history stay untouched)":"                      (chat e cronologia restano intatte)","  [2] Continue      - same egress, open OpenCode as it was":"  [2] Continua     - stessa uscita, apri OpenCode com'era","  [3] Change IP     - rotate / pick new proxy only":"  [3] Cambia IP    - solo ruota / scegli un nuovo proxy","  [5] Deep reset    - kill opencode, move chats to the Desktop,":"  [5] Reset completo - chiudi opencode, sposta le chat sul Desktop,","                      clear saved tokens, open a fresh session":"                      cancella i token salvati, apri una sessione nuova","  [6] Exit":"  [6] Esci","  [7] Token reset   - kill opencode, clear saved tokens, keep chats":"  [7] Reset token  - chiudi opencode, cancella i token salvati,","                      where they are, open a fresh session":"                      le chat restano dove sono, apri una sessione nuova","  [8] Settings      - change any launcher setting, applied right away":"  [8] Impostazioni - cambia qualsiasi impostazione, applicata subito","--- deep reset -----------------------------------------------":"--- reset completo ---------------------------------------------","  This closes opencode, moves your chats to the Desktop,":"  Questo chiude opencode, sposta le tue chat sul Desktop,","  clears the saved tokens and opens a brand new session.":"  cancella i token salvati e apre una sessione nuova.","  It is the only action in this script that touches your files.":"  \u00c8 l'unica azione di questo script che tocca i tuoi file.","  It also kills EVERY opencode process on this computer,":"  Chiude anche TUTTI i processi opencode di questo computer,","  including windows opened by hand or by another launcher.":"  incluse le finestre aperte a mano o da un altro launcher.","--- token reset ----------------------------------------------":"--- reset dei token ---------------------------------------------","  This closes opencode, clears the saved tokens and opens a":"  Questo chiude opencode, cancella i token salvati e apre una","  brand new session. Your chats are NOT moved.":"  sessione nuova. Le tue chat NON vengono spostate.","  auth.json is copied to the Desktop first, then removed.":"  auth.json viene prima copiato sul Desktop e poi rimosso.","    egress: %EGRESS%":"    uscita: %EGRESS%","%C_WARN%  [*] WARP proxy is not answering - rotation has no effect.%C_RST%":"%C_WARN%  [*] Il proxy WARP non risponde - la rotazione non ha effetto.%C_RST%","      Going direct would run opencode on your real IP.":"      Andare diretti farebbe usare a opencode il tuo IP reale.","%C_WARN%  [*] Tor did not get ready.%C_RST%":"%C_WARN%  [*] Tor non \u00e8 pronto.%C_RST%","%C_WARN%  [*] no working free proxy found.%C_RST%":"%C_WARN%  [*] nessun proxy gratuito funzionante trovato.%C_RST%","%C_WARN%  [*] the egress proxy stopped answering while OpenCode was open:%C_RST%":"%C_WARN%  [*] il proxy di uscita ha smesso di rispondere mentre OpenCode era aperto:%C_RST%","      %STATE_DIR%\\proxy_warn.txt":"      %STATE_DIR%\\proxy_warn.txt","%C_WARN%  [watch] a fatal error cut the chat - rotating and resuming it.%C_RST%":"%C_WARN%  [watch] un errore fatale ha interrotto la chat - rotazione e ripresa.%C_RST%","OpenCode closed.":"OpenCode chiuso.","  %KEY_ROTATE% = new IP and resume the chat   %KEY_MENU% = menu   %KEY_QUIT% = quit (Ctrl+C also quits)":"  %KEY_ROTATE% = nuovo IP e riprendi la chat   %KEY_MENU% = menu   %KEY_QUIT% = esci (anche Ctrl+C)","Press any key to continue . . .":"Premi un tasto per continuare . . .","  [tor] renewing the circuit, attempt %TOR_TRIES% of %ROTATE_TRIES_MAX%...":"  [tor] rinnovo del circuito, tentativo %TOR_TRIES% di %ROTATE_TRIES_MAX%...","%C_OK%  [tor] new circuit - resuming.%C_RST%":"%C_OK%  [tor] nuovo circuito - ripresa.%C_RST%","%C_WARN%  [*] Tor could not be renewed - back to menu.%C_RST%":"%C_WARN%  [*] Impossibile rinnovare Tor - torno al menu.%C_RST%","%C_WARN%  [*] Tor could not get a usable circuit after %ROTATE_TRIES_MAX% attempts.%C_RST%":"%C_WARN%  [*] Tor non ha ottenuto un circuito utilizzabile dopo %ROTATE_TRIES_MAX% tentativi.%C_RST%","      The exit node may be blocked: try a new identity in Tor, or":"      Il nodo di uscita potrebbe essere bloccato: prova una nuova identit\u00e0 in Tor, oppure","      switch to [1] WARP. warp/tor notes: \"%TOR_DIR%\\tor.log\"":"      passa a [1] WARP. Note warp/tor: \"%TOR_DIR%\\tor.log\"","  [proxy] %ACTIVE_PROXY% is burned - attempt %PROXY_ROT% of %PROXY_ROT_MAX%, picking another...":"  [proxy] %ACTIVE_PROXY% \u00e8 bruciato - tentativo %PROXY_ROT% di %PROXY_ROT_MAX%, ne cerco un altro...","  [proxy] picking a fresh free proxy before resume...":"  [proxy] cerco un nuovo proxy gratuito prima della ripresa...","%C_WARN%  [*] no free proxy is left that still works (they all hit the limit).%C_RST%":"%C_WARN%  [*] non resta nessun proxy gratuito funzionante (hanno tutti raggiunto il limite).%C_RST%","      Free proxies are shared by many people, so their limit is often used up.":"      I proxy gratuiti sono condivisi da molti, quindi il loro limite \u00e8 spesso esaurito.","  Automatic rotation is off - the menu decides.":"  La rotazione automatica \u00e8 disattivata - decide il menu.","Getting a new IP before the next attempt...":"Ottengo un nuovo IP prima del prossimo tentativo...","  [i] hunting for %HUNT_GOAL%: up to %TARGET_TRIES% attempts, %TARGET_MINUTES% min. Esc or Q stops.":"  [i] ricerca di %HUNT_GOAL%: fino a %TARGET_TRIES% tentativi, %TARGET_MINUTES% min. Esc o Q per fermare.","[%ROTATE_TRIES%/%TARGET_TRIES%] dropping the old registration...":"[%ROTATE_TRIES%/%TARGET_TRIES%] elimino la vecchia registrazione...","[%ROTATE_TRIES%/%TARGET_TRIES%] new registration...":"[%ROTATE_TRIES%/%TARGET_TRIES%] nuova registrazione...","[%ROTATE_TRIES%] reconnect...":"[%ROTATE_TRIES%] riconnessione...","[%ROTATE_TRIES%] waiting %WARP_WAIT%s...":"[%ROTATE_TRIES%] attesa di %WARP_WAIT%s...","[%ROTATE_TRIES%] %IPN% was already tried in this hunt, rotating again":"[%ROTATE_TRIES%] %IPN% gi\u00e0 provato in questa ricerca, ruoto di nuovo","[%ROTATE_TRIES%/%TARGET_TRIES%] exit IP %IPN% (country %GLOC%), target %TMATCHTXT%, %HUNT_LEFT% attempt(s) left":"[%ROTATE_TRIES%/%TARGET_TRIES%] IP di uscita %IPN% (paese %GLOC%), obiettivo %TMATCHTXT%, restano %HUNT_LEFT% tentativo/i","[%ROTATE_TRIES%] probing if this IP can still talk...":"[%ROTATE_TRIES%] verifico se questo IP pu\u00f2 ancora connettersi...","%C_WARN%  [*] probe failed for a reason that is NOT a limit - attempt %PBROKEN% of %PROBE_BROKEN_MAX%. Last output:%C_RST%":"%C_WARN%  [*] verifica fallita per un motivo che NON \u00e8 un limite - tentativo %PBROKEN% di %PROBE_BROKEN_MAX%. Ultimo output:%C_RST%","[%PROBE_TRIES%] IP already burned, rotating again...":"[%PROBE_TRIES%] IP gi\u00e0 bruciato, ruoto di nuovo...","%C_WARN%  [*] %PROBE_TRIES% IPs probed, every one of them already burned.%C_RST%":"%C_WARN%  [*] %PROBE_TRIES% IP verificati, tutti gi\u00e0 bruciati.%C_RST%","%C_WARN%  [*] the probe failed %PBROKEN% times and none of them was a limit error.%C_RST%":"%C_WARN%  [*] la verifica \u00e8 fallita %PBROKEN% volte e nessuna era un errore di limite.%C_RST%","      The probe itself is broken, not every IP: a retired PROBE_MODEL id,":"      Il problema \u00e8 nella verifica, non in tutti gli IP: un ID PROBE_MODEL","      an auth error or a CLI change. Rotation cannot fix that.":"      ritirato, un errore di autenticazione o una modifica della CLI.","      Check PROBE_MODEL in the settings block, or run the probe model once":"      Controlla PROBE_MODEL nel blocco impostazioni, oppure esegui il modello di prova","      by hand to see the real error.":"      a mano una volta per vedere l'errore reale.","  [i] probe off for this session - IPs are accepted on WARP-trace proof":"  [i] verifica disattivata per questa sessione - gli IP sono accettati solo","      only, and the resume's own limit check keeps catching burned ones.":"      con la prova WARP, e il controllo del limite alla ripresa continua a intercettare quelli bruciati.","%C_WARN%  [*] the probe session \"%OC_PROBE_ID%\" does not exist and this%C_RST%":"%C_WARN%  [*] la sessione di verifica \"%OC_PROBE_ID%\" non esiste e questa%C_RST%","      opencode build refused it. That is a probe problem, NOT a":"      versione di opencode l'ha rifiutata. \u00c8 un problema della verifica, NON","      burned IP - no rotation can fix it.":"      un IP bruciato - nessuna rotazione pu\u00f2 risolverlo.","  [i] the probe is off for this session: IPs are accepted on":"  [i] la verifica \u00e8 disattivata per questa sessione: gli IP sono accettati solo","      WARP-trace proof only, and the resume's own limit check still":"      con la prova WARP, e il controllo del limite alla ripresa intercetta comunque uno bruciato.","      catches a burned one. To keep the probe, create the session by":"      Per mantenerla, crea la sessione a mano una volta,","      hand once, or clear PROBE in the settings block.":"      oppure cancella PROBE nel blocco impostazioni.","%C_OK%[%ROTATE_TRIES%] IP %IPN% works.%C_RST%":"%C_OK%[%ROTATE_TRIES%] l'IP %IPN% funziona.%C_RST%","[%ROTATE_TRIES%] no verified WARP IP yet, retrying...":"[%ROTATE_TRIES%] ancora nessun IP WARP verificato, nuovo tentativo...","%C_WARN%  [*] no usable IP from this hunt. warp-cli errors, if any, are in %STATE_DIR%\\wcli.log%C_RST%":"%C_WARN%  [*] nessun IP utilizzabile da questa ricerca. Gli eventuali errori di warp-cli sono in %STATE_DIR%\\wcli.log%C_RST%","  restarting the desktop app on the new egress...":"  riavvio dell'app desktop sulla nuova uscita...","  sending \"%RESUME_MSG%\" so the chat picks up where it stopped...":"  invio di \"%RESUME_MSG%\" perch\u00e9 la chat riprenda da dove si era fermata...","%C_WARN%  [*] proxy dead - retrying on the current egress instead of resuming.%C_RST%":"%C_WARN%  [*] proxy morto - nuovo tentativo sull'uscita attuale invece di riprendere.%C_RST%","%C_WARN%  [*] no answer in %RESUME_TIMEOUT%s - this exit IP is dead.%C_RST%":"%C_WARN%  [*] nessuna risposta in %RESUME_TIMEOUT%s - questo IP di uscita \u00e8 morto.%C_RST%","%C_OK%  chat resumed on the new IP.%C_RST%":"%C_OK%  chat ripresa sul nuovo IP.%C_RST%","%C_WARN%  [*] the resume itself hit a limit - rotating again.%C_RST%":"%C_WARN%  [*] la ripresa stessa ha raggiunto un limite - ruoto di nuovo.%C_RST%","  Egress is NONE - nothing to rotate.":"  L'uscita \u00e8 NONE - niente da ruotare.","  Restarting the launcher-managed Tor for a new circuit...":"  Riavvio del Tor gestito dal launcher per un nuovo circuito...","  TOR mode - this Tor was started outside the launcher.":"  Modalit\u00e0 TOR - questo Tor \u00e8 stato avviato fuori dal launcher.","  Restart it yourself for a new circuit, or pick [1] WARP / [4] NONE.":"  Riavvialo tu per un nuovo circuito, oppure scegli [1] WARP / [4] NONE.","  Current bridge: http://127.0.0.1:%TOR_HTTP_PORT%":"  Bridge attuale: http://127.0.0.1:%TOR_HTTP_PORT%","  Picking a new free HTTP proxy...":"  Cerco un nuovo proxy HTTP gratuito...","  New proxy: %ACTIVE_PROXY%":"  Nuovo proxy: %ACTIVE_PROXY%","WARP is not available - nothing to rotate.":"WARP non \u00e8 disponibile - niente da ruotare.","Requesting a new WARP registration...":"Richiesta di una nuova registrazione WARP...","waiting %WARP_WAIT%s...":"attesa di %WARP_WAIT%s...","%C_WARN%  [*] no verified WARP IP.%C_RST%":"%C_WARN%  [*] nessun IP WARP verificato.%C_RST%","      warp-cli errors land in %STATE_DIR%\\wcli.log":"      gli errori di warp-cli finiscono in %STATE_DIR%\\wcli.log","  same IP as before: %IPN%":"  stesso IP di prima: %IPN%","%C_OK%  New exit IP: %IPN% (WARP verified)%C_RST%":"%C_OK%  Nuovo IP di uscita: %IPN% (WARP verificato)%C_RST%","  --- resume stderr ---":"  --- stderr della ripresa ---","  --- resume stdout ---":"  --- stdout della ripresa ---","  downloading the WARP installer, about 60 MB...":"  download dell'installer di WARP, circa 60 MB...","%C_WARN%  [*] download failed.%C_RST%":"%C_WARN%  [*] download fallito.%C_RST%","      grab it by hand and run it: %WARP_MSI_URL%":"      scaricalo a mano ed eseguilo: %WARP_MSI_URL%","  installing, accept the UAC prompt...":"  installazione, accetta la richiesta UAC...","  [auto-install] the standalone build did not install, trying npm.":"  [auto-install] la versione standalone non \u00e8 stata installata, provo con npm.","  [i] 32-bit Windows: no standalone build - installing via npm.":"  [i] Windows a 32 bit: nessuna versione standalone - installazione tramite npm.","%C_OK%  [ok] opencode ready on 32-bit via npm.%C_RST%":"%C_OK%  [ok] opencode pronto su 32 bit tramite npm.%C_RST%","%C_ERR%  ERROR: opencode could not be installed on 32-bit Windows.%C_RST%":"%C_ERR%  ERRORE: impossibile installare opencode su Windows a 32 bit.%C_RST%","         Install 32-bit node.js by hand from nodejs.org, then run:":"         Installa node.js a 32 bit a mano da nodejs.org, poi esegui:","         npm i -g opencode-ai":"         npm i -g opencode-ai","%C_WARN%  [*] could not read the official release info from opencode.ai.%C_RST%":"%C_WARN%  [*] impossibile leggere le informazioni di rilascio ufficiali da opencode.ai.%C_RST%","  [auto-install] downloading opencode %OCA_VER% (official build, %OC_AFILE%)...":"  [auto-install] download di opencode %OCA_VER% (build ufficiale, %OC_AFILE%)...","%C_WARN%    [*] checksum mismatch - the download is not the official file.%C_RST%":"%C_WARN%    [*] checksum non corrispondente - il download non \u00e8 il file ufficiale.%C_RST%","%C_WARN%    [*] download failed.%C_RST%":"%C_WARN%    [*] download fallito.%C_RST%","  [auto-install] unpacking, about 200 MB on disk...":"  [auto-install] decompressione, circa 200 MB su disco...","  [auto-install] installing %NPMPKG% with npm...":"  [auto-install] installazione di %NPMPKG% con npm...","  [npm] the install script was blocked - running it by hand...":"  [npm] lo script di installazione \u00e8 stato bloccato - lo eseguo a mano...","  [auto-install] node.js (32-bit) is missing - installing it...":"  [auto-install] node.js (32 bit) mancante - installazione...","    via winget...":"    tramite winget...","  [i] this can take a few minutes on its first run.":"  [i] la prima volta pu\u00f2 richiedere alcuni minuti.","    winget failed - trying the MSI installer from nodejs.org...":"    winget fallito - provo con l'installer MSI da nodejs.org...","    downloading %NODE_MSI_URL% ...":"    download di %NODE_MSI_URL% ...","    direct download failed - retrying through the Windows proxy settings...":"    download diretto fallito - riprovo con le impostazioni proxy di Windows...","    installing, accept the UAC prompt...":"    installazione, accetta la richiesta UAC...","  opencode update available: %OCUPD_CUR% -> %OCUPD_LAT%":"  aggiornamento di opencode disponibile: %OCUPD_CUR% -> %OCUPD_LAT%","  It closes every running opencode process first.":"  Chiude prima tutti i processi opencode in esecuzione.","  [update] npm i -g @opencode/cli@latest":"  [update] npm i -g @opencode/cli@latest","  [update] official standalone build %OCUPD_LAT%":"  [update] build standalone ufficiale %OCUPD_LAT%","%C_WARN%  [*] \"%OC_CMD%\" reports %OC_VER% but this machine has a v2 database.%C_RST%":"%C_WARN%  [*] \"%OC_CMD%\" riporta %OC_VER% ma questo computer ha un database v2.%C_RST%","      A v1 binary cannot open it: \"Database is not empty and has no session table\".":"      Un binario v1 non pu\u00f2 aprirlo: \"Database is not empty and has no session table\".","      Update it:  npm i -g @opencode/cli@latest   (or accept the update offer)":"      Aggiornalo:  npm i -g @opencode/cli@latest   (o accetta l'offerta di aggiornamento)","%C_WARN%  [*] WARP registration missing - creating a new one.%C_RST%":"%C_WARN%  [*] registrazione WARP mancante - ne creo una nuova.%C_RST%","  [tor] nothing answering on :%TOR_HTTP_PORT% - portable setup starting...":"  [tor] niente risponde su :%TOR_HTTP_PORT% - avvio della configurazione portatile...","%C_WARN%  [*] Tor did not become ready - the reason is in \"%TOR_DIR%\\tor.log\"%C_RST%":"%C_WARN%  [*] Tor non \u00e8 pronto - il motivo \u00e8 in \"%TOR_DIR%\\tor.log\"%C_RST%","%C_WARN%  [*] the Tor download did not land. Grab it by hand:%C_RST%":"%C_WARN%  [*] il download di Tor non \u00e8 andato a buon fine. Scaricalo a mano:%C_RST%","      https://dist.torproject.org/torbrowser/":"      https://dist.torproject.org/torbrowser/","      unpack the tor-expert-bundle tar.gz into \"%TOR_DIR%\",":"      estrai il tor-expert-bundle tar.gz in \"%TOR_DIR%\",","      so that \"%TOR_DIR%\\Tor\\tor.exe\" exists, then run this again.":"      in modo che esista \"%TOR_DIR%\\Tor\\tor.exe\", poi esegui di nuovo questo.","%C_OK%  [tor] ready: SOCKS :%TOR_SOCKS_PORT% - HTTP :%TOR_HTTP_PORT%.%C_RST%":"%C_OK%  [tor] pronto: SOCKS :%TOR_SOCKS_PORT% - HTTP :%TOR_HTTP_PORT%.%C_RST%","  [tor] updater JSON unavailable - falling back to the dist index...":"  [tor] JSON dell'aggiornatore non disponibile - uso l'indice di distribuzione...","%C_WARN%  [*] the Tor bundle did not download.%C_RST%":"%C_WARN%  [*] il pacchetto di Tor non \u00e8 stato scaricato.%C_RST%","  [tor] unpacking...":"  [tor] estrazione...","%C_OK%  [ok] Tor installed - portable - in \"%TOR_DIR%\".%C_RST%":"%C_OK%  [ok] Tor installato - portatile - in \"%TOR_DIR%\".%C_RST%","%C_WARN%  [*] the bundle unpacked but tor.exe was not found in \"%TOR_DIR%\".%C_RST%":"%C_WARN%  [*] il pacchetto \u00e8 stato estratto ma tor.exe non \u00e8 stato trovato in \"%TOR_DIR%\".%C_RST%","  [tor] a Tor is already running on :%TOR_SOCKS_PORT% - using it as it is.":"  [tor] un Tor \u00e8 gi\u00e0 in esecuzione su :%TOR_SOCKS_PORT% - lo uso cos\u00ec com'\u00e8.","  [tor] starting tor (hidden window, log: \"%OC_TORLOG%\")...":"  [tor] avvio di tor (finestra nascosta, log: \"%OC_TORLOG%\")...","%C_WARN%  [*] tor could not be started - see \"%OC_TORERR%\" and \"%OC_TORLOG%\".%C_RST%":"%C_WARN%  [*] impossibile avviare tor - vedi \"%OC_TORERR%\" e \"%OC_TORLOG%\".%C_RST%","  [tor] starting the built-in HTTP->SOCKS bridge on :%TOR_HTTP_PORT% (no Privoxy needed)...":"  [tor] avvio del bridge HTTP->SOCKS integrato su :%TOR_HTTP_PORT% (senza Privoxy)...","  [tor] bootstrapping, up to %TOR_BOOTSTRAP_WAIT%s (the first run takes longer)...":"  [tor] connessione, fino a %TOR_BOOTSTRAP_WAIT%s (la prima volta richiede di pi\u00f9)...","  [tor] Tor is up and routing through the bridge.":"  [tor] Tor \u00e8 attivo e instrada tramite il bridge.","  [tor] still not up after %TOR_BOOTSTRAP_WAIT%s.":"  [tor] non ancora attivo dopo %TOR_BOOTSTRAP_WAIT%s.","  [tor] found a Tor Browser SOCKS on :9150 - using it.":"  [tor] trovato un SOCKS di Tor Browser su :9150 - lo uso.","  [tor] found a Tor SOCKS on :9050 - using it.":"  [tor] trovato un SOCKS di Tor su :9050 - lo uso.","  [*] this Tor was not started by the launcher - it cannot be renewed":"  [*] questo Tor non \u00e8 stato avviato dal launcher - non pu\u00f2 essere rinnovato","      from here. Restart Tor Browser yourself, or pick [1] WARP / [4] NONE.":"      da qui. Riavvia tu Tor Browser, oppure scegli [1] WARP / [4] NONE.","  WARP proxy is not answering - cannot verify the exit IP.":"  Il proxy WARP non risponde - impossibile verificare l'IP di uscita.","  same IP as the last run, requesting a new registration...":"  stesso IP dell'ultima volta, richiedo una nuova registrazione...","  [%EN_TRIES%] dropping the old registration...":"  [%EN_TRIES%] elimino la vecchia registrazione...","  [%EN_TRIES%] new registration...":"  [%EN_TRIES%] nuova registrazione...","  [%EN_TRIES%] reconnecting WARP proxy...":"  [%EN_TRIES%] riconnessione del proxy WARP...","  [%EN_TRIES%] waiting %WARP_WAIT%s...":"  [%EN_TRIES%] attesa di %WARP_WAIT%s...","  exit IP: %CUR%":"  IP di uscita: %CUR%","  no new IP after %ROTATE_TRIES_MAX% tries, launching on the current one.":"  nessun IP nuovo dopo %ROTATE_TRIES_MAX% tentativi, avvio con quello attuale.","  [note] opencode log not found: \"%LOGFILE%\"":"  [note] log di opencode non trovato: \"%LOGFILE%\"","         auto-detect stays off until the log appears.":"         il rilevamento automatico resta disattivato finch\u00e9 il log non compare.","  OpenCode desktop update available: %DVER% -> %OCA_VER%":"  aggiornamento dell'app desktop di OpenCode disponibile: %DVER% -> %OCA_VER%","  It closes every OpenCode process first, the app and its service included.":"  Chiude prima tutti i processi di OpenCode, app e servizio inclusi.","  downloading the OpenCode desktop installer %OCA_VER%, about 250 MB...":"  download dell'installer dell'app desktop di OpenCode %OCA_VER%, circa 250 MB...","  [*] checksum mismatch - the download is not the official file.":"  [*] checksum non corrispondente - il download non \u00e8 il file ufficiale.","  [*] download failed.":"  [*] download fallito.","      grab it by hand and run it: %ID_URL%":"      scaricalo a mano ed eseguilo: %ID_URL%","      or from the website: https://opencode.ai/download":"      oppure dal sito: https://opencode.ai/download","  installing, accept the UAC prompt if one appears...":"  installazione, accetta la richiesta UAC se compare...","  [*] could not read the official release info from opencode.ai.":"  [*] impossibile leggere le informazioni di rilascio ufficiali da opencode.ai.","      get the installer by hand: https://opencode.ai/download":"      prendi l'installer a mano: https://opencode.ai/download","  [*] the desktop app has no 32-bit Windows build.":"  [*] l'app desktop non ha una versione per Windows a 32 bit.","[verify] egress: %EGRESS%":"[verify] uscita: %EGRESS%","[verify] ip=%IPN% warp=%WFLAG%":"[verify] ip=%IPN% warp=%WFLAG%","[verify] Cloudflare WARP is not installed (warp-cli not found).":"[verify] Cloudflare WARP non installato (warp-cli non trovato).","[renew] egress: %EGRESS%":"[renew] uscita: %EGRESS%","[renew] new exit IP: %IPN%":"[renew] nuovo IP di uscita: %IPN%","[renew] Cloudflare WARP is not installed (warp-cli not found).":"[renew] Cloudflare WARP non installato (warp-cli non trovato).","[renew] proxy: %ACTIVE_PROXY%":"[renew] proxy: %ACTIVE_PROXY%","[renew] done":"[renew] fatto","[renew] could not get a working connection":"[renew] nessuna connessione funzionante ottenuta","  archiving chats to:":"  archiviazione delle chat in:","  nothing to archive.":"  niente da archiviare.","  archived.":"  archiviato.","  [*] could not move the storage folder - it stays where it is.":"  [*] impossibile spostare la cartella di archiviazione - resta dov'\u00e8.","  [*] could not copy %1 - it stays where it is.":"  [*] impossibile copiare %1 - resta dov'\u00e8.","  [*] size mismatch on %1 - the bad copy is deleted, the original stays.":"  [*] dimensione diversa per %1 - la copia errata viene cancellata, l'originale resta.","  cache and tokens cleared.":"  cache e token cancellati.","  auth.json archived in \"%TARGET%\".":"  auth.json archiviato in \"%TARGET%\".","  [*] the auth.json copy did not verify - tokens are left in place.":"  [*] la copia di auth.json non \u00e8 stata verificata - i token restano dove sono.","  [*] could not copy auth.json - tokens are left in place.":"  [*] impossibile copiare auth.json - i token restano dove sono.","  [*] no archive folder for this reset - auth.json is left in place.":"  [*] nessuna cartella di archivio per questo reset - auth.json resta dov'\u00e8.","  [*] the WARP port answers SOCKS5 only, and OpenCode cannot use SOCKS.":"  [*] la porta WARP risponde solo SOCKS5, e OpenCode non pu\u00f2 usare SOCKS.","      WARP is up, but no usable HTTP proxy can be handed to it.":"      WARP \u00e8 attivo, ma non \u00e8 possibile passare a OpenCode un proxy HTTP utilizzabile.","  [proxy] process-only: %ACTIVE_PROXY%":"  [proxy] solo processo: %ACTIVE_PROXY%","  [proxy] reading the proxy list...":"  [proxy] lettura dell'elenco proxy...","  [proxy] %PCOUNT% proxies in the list":"  [proxy] %PCOUNT% proxy nell'elenco","  [*] no proxies found in \"%PSRC%\"":"  [*] nessun proxy trovato in \"%PSRC%\"","  [*] no proxy passed the API check, but %TRACE_ONLY% did reach Cloudflare.":"  [*] nessun proxy ha superato il controllo API, ma %TRACE_ONLY% ha raggiunto Cloudflare.","      PROXY_API_CHECK_URL may be wrong - see the settings block.":"      PROXY_API_CHECK_URL potrebbe essere errato - vedi il blocco impostazioni.","  [proxy] live: %ACTIVE_PROXY%":"  [proxy] attivo: %ACTIVE_PROXY%","  [*] OpenCode-Infinite is already open in another window.":"  [*] OpenCode-Infinite \u00e8 gi\u00e0 aperto in un'altra finestra.","  Exiting.":"  Chiusura.","  [upd] repo copy is %SU_RV%, older than %SU_LV% - keeping this one.":"  [upd] la copia nel repo \u00e8 %SU_RV%, pi\u00f9 vecchia di %SU_LV% - tengo questa.","  [upd] launcher matches the repo, %SU_LV%.":"  [upd] il launcher corrisponde al repo, %SU_LV%.","  [upd] update found: local %SU_LV% - repo %SU_RV%":"  [upd] aggiornamento trovato: locale %SU_LV% - repo %SU_RV%","  [upd] swapping in %SU_RV% - this window closes now.":"  [upd] sostituzione con %SU_RV% - questa finestra si chiude ora.","  [upd] the swap could not be prepared - keeping %SU_LV%.":"  [upd] impossibile preparare la sostituzione - resta %SU_LV%.","        The downloaded copy is in \"%SU_TMP%\".":"        La copia scaricata \u00e8 in \"%SU_TMP%\".","  Press any key to close this window.":"  Premi un tasto per chiudere questa finestra.","Automatic rotation":"Rotazione automatica","On: a limit or a closed opencode gets a new IP and the chat resumes. Off: the menu decides.":"Attiva: un limite o un opencode chiuso ottiene un nuovo IP e la chat riprende. Disattiva: decide il menu.","Target country":"Paese di destinazione","Keep asking for IPs until one is in this country, e.g. DE. Empty = any new IP.":"Continua a chiedere IP finch\u00e9 uno non \u00e8 in questo paese, es. DE. Vuoto = qualsiasi nuovo IP.","Target IP prefix":"Prefisso IP di destinazione","Keep asking until the IP starts with this, e.g. 104.28. Empty = not used.":"Continua a chiedere finch\u00e9 l'IP non inizia con questo, es. 104.28. Vuoto = non usato.","Max attempts per hunt":"Tentativi massimi per ricerca","New IPs requested in one hunt. The hunt stops at this count.":"Nuovi IP richiesti in una ricerca. La ricerca si ferma a questo numero.","Max minutes per hunt":"Minuti massimi per ricerca","The hunt stops after this many minutes.":"La ricerca si ferma dopo questo numero di minuti.","Seconds between attempts":"Secondi tra i tentativi","Pause between two attempts, so Cloudflare is not hit too fast.":"Pausa tra due tentativi, per non colpire Cloudflare troppo in fretta.","Activity log":"Registro attivit\u00e0","Record what the launcher does in launcher.log so a problem can be diagnosed.":"Registra in launcher.log ci\u00f2 che fa il launcher, per diagnosticare un problema.","Log size limit (KB)":"Limite di dimensione del registro (KB)","The log is cut to its newest part when it grows past this.":"Il registro viene tagliato alla parte pi\u00f9 recente quando supera questa dimensione.","Hide IPs in reports":"Nascondi gli IP nei report","Public IP addresses are masked in the support report.":"Gli IP pubblici vengono mascherati nel report di supporto.","config.json could not be read; a copy was kept as config.json.broken and defaults are in use.":"Impossibile leggere config.json; una copia \u00e8 stata salvata come config.json.broken e vengono usati i valori predefiniti.","Two letters, like DE or US. Empty = any country.":"Due lettere, come DE o US. Vuoto = qualsiasi paese.","The start of an IPv4 address, like 104.28. Empty = any IP.":"L'inizio di un indirizzo IPv4, come 104.28. Vuoto = qualsiasi IP.","Value: {0}":"Valore: {0}"," Back":" Indietro","Windows Terminal settings.json was not found.":"settings.json di Windows Terminal non trovato.","settings.json was left untouched: the edit would not have kept it valid.":"settings.json non modificato: la modifica non lo avrebbe lasciato valido.","Windows Terminal font put back as it was. Reopen the tab if it does not change.":"Carattere di Windows Terminal ripristinato. Riapri la scheda se non cambia.","Windows Terminal font set to ":"Carattere di Windows Terminal impostato su",". Backup of settings.json: ":". Backup di settings.json:","The Windows font API could not be loaded.":"Impossibile caricare l'API dei caratteri di Windows.","This window does not allow changing the font from here.":"Questa finestra non permette di cambiare il carattere da qui.","The font was never changed, nothing to restore.":"Il carattere non \u00e8 mai stato cambiato, nulla da ripristinare.","Windows refused that font in this console.":"Windows ha rifiutato quel carattere in questa console.","This console refused \"":"Questa console ha rifiutato \"","\" and kept \"":"\" e mantenuto \"","\". Older classic consoles only take the fonts Windows registers for them (":"\". Le vecchie console classiche accettano solo i caratteri registrati da Windows per loro (","). Windows Terminal accepts any installed font.":"). Windows Terminal accetta qualsiasi carattere installato.","Console font set to ":"Carattere della console impostato su",". It lasts while this window is open and is applied again at every launcher start.":". Resta finch\u00e9 questa finestra \u00e8 aperta e viene riapplicato a ogni avvio del launcher.","This terminal keeps its font in its own settings (VS Code: terminal.integrated.fontFamily).":"Questo terminale conserva il carattere nelle proprie impostazioni (VS Code: terminal.integrated.fontFamily).","Could not change the font: ":"Impossibile cambiare il carattere:"," The setting was not changed.":" L'impostazione non \u00e8 stata cambiata.","Enter, arrows":"Invio, frecce"," Connect with opencode":" Connetti con opencode"," CLI":" CLI"," Desktop app":" App desktop"," Exit":" Esci","There is no saved folder yet. Use one of the other options once.":"Nessuna cartella salvata. Usa una delle altre opzioni una volta.","Cloudflare":"Cloudflare","bridge :":"bridge :","CLI / Desktop":"CLI / Desktop","Automatic (follow Windows)":"Automatico (segue Windows)","Use the language Windows is set to on every start; English when there is no translation.":"Usa la lingua di Windows a ogni avvio; inglese se non c'\u00e8 una traduzione."," (detected)":" (rilevata)","Detected from Windows and selected. You can change it in Settings, Appearance.":"Rilevata da Windows e selezionata. Puoi cambiarla in Impostazioni, Aspetto.","You can change it in Settings, Appearance.":"Puoi cambiarla in Impostazioni, Aspetto.","Choose your language":"Scegli la lingua"," Launch OpenCode":" Avvia OpenCode"," Renew session":" Rinnova sessione"," Uninstall":" Disinstalla"," Support report":" Report di supporto","not a url":"non \u00e8 un URL","Sessions":"Sessioni","Pick a chat from this folder and continue it. CLI only.":"Scegli una chat di questa cartella e continuala. Solo CLI.","The desktop app has no session list. Switch to CLI to pick a chat.":"L'app desktop non ha un elenco di sessioni. Passa a CLI per scegliere una chat.","Could not read the sessions: {0}":"Impossibile leggere le sessioni: {0}","No sessions in this folder yet.":"Non ci sono ancora sessioni in questa cartella.","Untitled session":"Sessione senza titolo","Sessions in this folder":"Sessioni di questa cartella","  [9] Sessions      - continue a chat from this folder":"  [9] Sessioni      - riprendi una chat di questa cartella","Change IP (test)":"Cambia IP (prova)","Clear tokens and cache, then start":"Cancella token e cache, poi avvia","keeps chats":"conserva le chat","Deep reset or restore chats":"Reset profondo o ripristino chat","submenu":"sottomenu","Mode (CLI or Desktop)":"Modalit\u00e0 (CLI o Desktop)","New IP and start OpenCode":"Nuovo IP e avvia OpenCode","Kill opencode, save the login file to the Desktop, clear the cache, then open OpenCode. Chats stay where they are.":"Chiude opencode, salva il file di accesso sul Desktop, svuota la cache e apre OpenCode. Le chat restano dove sono.","Rotate the connection only, without opening OpenCode.":"Cambia solo la connessione, senza aprire OpenCode.","Deep reset moves your chats to the Desktop and clears tokens and cache. Restore brings chats back from an earlier reset.":"Il reset profondo sposta le chat sul Desktop e cancella token e cache. Il ripristino riporta le chat da un reset precedente.","Move your chats to the Desktop archive, clear tokens and cache, then start fresh.":"Sposta le chat nell'archivio del Desktop, cancella token e cache e riparte da zero.","Restore chats":"Ripristina chat","from the Desktop":"dal Desktop","Bring chats back from an earlier deep reset.":"Riporta le chat da un reset profondo precedente.","Return to the deep reset menu.":"Torna al menu del reset profondo.","Return to the home screen.":"Torna alla schermata iniziale.","Restore chats from a backup":"Ripristina chat da un backup","No archived chats yet. A deep reset creates one on the Desktop.":"Nessuna chat archiviata. Un reset profondo ne crea una sul Desktop.","{0} file":"{0} file","{0} files":"{0} file","Windows Terminal font size set to {0}. Reopen the tab if it does not change.":"Dimensione del font di Windows Terminal impostata a {0}. Riapri la scheda se non cambia.","Restore now?":"Ripristinare ora?","  Nothing to restore in that backup.":"  Nulla da ripristinare in quel backup.","  Restore the chats from:":"  Ripristina le chat da:","  The chats in place now are moved to the Desktop first. Nothing is deleted.":"  Le chat attuali vengono prima spostate sul Desktop. Non si cancella nulla.","  [*] some storage files did not copy. The backup is untouched.":"  [*] alcuni file di archiviazione non sono stati copiati. Il backup \u00e8 intatto.","  Chats restored. The previous ones are in:":"  Chat ripristinate. Le precedenti sono in:"}
#>>>LANG pt {" move   Enter select   Esc back   1-9 or letter jump":" mover   Enter escolher   Esc voltar   1-9 ou letra para saltar","(Enter = keep \"{0}\")":"(Enter = manter \"{0}\")","(auto)":"(auto)","(nothing saved yet)":"(nada guardado ainda)","(terminal default)":"(predefinida do terminal)","* = changed from the default. Enter edits or toggles the selected value.":"* = diferente do valor predefinido. Enter edita ou alterna o valor selecionado.","A downloaded list smaller than this is rejected. 0 = off.":"Uma lista descarregada menor do que isto \u00e9 rejeitada. 0 = desativado.","A port is a number from 1 to 65535.":"Uma porta \u00e9 um n\u00famero de 1 a 65535.","A proxy must also reach the opencode API host.":"Um proxy tamb\u00e9m tem de alcan\u00e7ar o servidor da API do opencode.","API check URL":"URL de verifica\u00e7\u00e3o da API","Accent colors of the interface.":"Cores de destaque da interface.","Adding the command to your PATH":"A adicionar o comando ao PATH","Adds: opencode command (shim), two shortcuts, one PATH entry. Backups are kept.":"Adiciona: o comando opencode (shim), dois atalhos e uma entrada no PATH. As c\u00f3pias de seguran\u00e7a s\u00e3o mantidas.","Any installed font name, for example Cascadia Code.":"Qualquer nome de tipo de letra instalado, por exemplo Cascadia Code.","Appearance":"Apar\u00eancia","Applies at the {0}.":"Aplica-se em: {0}.","Apply":"Aplicar","Apply setup":"Aplicar configura\u00e7\u00e3o","Ask every time":"Perguntar sempre","Attempts per round when the tunnel is not up.":"Tentativas por ronda quando o t\u00fanel n\u00e3o est\u00e1 ativo.","Back":"Voltar","Backing up the current configuration":"A guardar c\u00f3pia da configura\u00e7\u00e3o atual","Browse for a folder...":"Procurar uma pasta...","Burned IPs allowed":"IPs queimados permitidos","Burned proxies before Tor offer":"Proxies queimados antes de oferecer o Tor","Burned proxies in a row before PROXY mode offers Tor.":"Proxies queimados seguidos antes de o modo PROXY oferecer o Tor.","CLI terminal, Desktop app, or ask at every start.":"Terminal CLI, aplica\u00e7\u00e3o de ambiente de trabalho, ou perguntar em cada arranque.","Cancel":"Cancelar","Cancel. Nothing is changed.":"Cancelar. Nada \u00e9 alterado.","Change IP":"Mudar de IP","Change an answer.":"Alterar uma resposta.","Change any launcher setting: connection, proxies, Tor, rotation, themes, font. Applied right away.":"Altera qualquer defini\u00e7\u00e3o do launcher: liga\u00e7\u00e3o, proxies, Tor, rota\u00e7\u00e3o, temas, tipo de letra. Aplica-se de imediato.","Check GitHub for a newer launcher at every start.":"Procura no GitHub um launcher mais recente em cada arranque.","Check the API host":"Verificar o servidor da API","Checking that it works":"A verificar se funciona","Checking the connection":"A verificar a liga\u00e7\u00e3o","Choose \"Renew session\" below. It gets a new IP and clears the saved login;":"Escolhe \"Renovar sess\u00e3o\" abaixo. Obt\u00e9m um IP novo e apaga o in\u00edcio de sess\u00e3o guardado;","Choose a folder to work in":"Escolhe uma pasta de trabalho","Choose one of: {0}.":"Escolhe um de: {0}.","Choose the connection for OpenCode":"Escolhe a liga\u00e7\u00e3o para o OpenCode","Close the launcher.":"Fechar o launcher.","Closes every running opencode process.":"Fecha todos os processos do opencode em execu\u00e7\u00e3o.","Cloudflare WARP in local proxy mode. Every rotation asks for a new registration, which gives a new exit IP. Needs the WARP client (offered if missing).":"Cloudflare WARP em modo de proxy local. Cada rota\u00e7\u00e3o pede um novo registo, que d\u00e1 um novo IP de sa\u00edda. Precisa do cliente WARP (oferecido se faltar).","Cloudflare WARP in proxy mode. A new registration gives a new exit IP. Rotation supported.":"Cloudflare WARP em modo de proxy. Um novo registo d\u00e1 um novo IP de sa\u00edda. Suporta rota\u00e7\u00e3o.","Cloudflare throttles rapid registrations.":"A Cloudflare limita registos seguidos.","Collect system info, versions, settings and the recent log into one text file you can send for help. Passwords, tokens, your user name and (by default) IPs are removed first.":"Re\u00fane informa\u00e7\u00e3o do sistema, vers\u00f5es, defini\u00e7\u00f5es e o registo recente num ficheiro de texto que podes enviar para pedir ajuda. Antes s\u00e3o removidos palavras-passe, tokens, o teu nome de utilizador e (por defeito) os IPs.","Color theme":"Tema de cores","Color theme, colors on or off, icon and border style, and the terminal font. Applied immediately.":"Tema de cores, cores ligadas ou n\u00e3o, estilo de \u00edcones e bordas, idioma e tipo de letra do terminal. Aplica-se de imediato.","Colors":"Cores","Command":"Comando","Configured - {0}":"Configurado - {0}","Confirm":"Confirmar","Connect with opencode":"Ligar ao opencode","Connected: opencode now starts through {0}.":"Ligado: o opencode agora arranca atrav\u00e9s de {0}.","Connecting opencode":"A ligar o opencode","Connection":"Liga\u00e7\u00e3o","Connection method":"M\u00e9todo de liga\u00e7\u00e3o","Continue":"Continuar","Continue WITHOUT the probe this session (IPs accepted untested)?":"Continuar SEM o teste nesta sess\u00e3o (IPs aceites sem testar)?","Continue anyway?":"Continuar mesmo assim?","Continue direct?":"Continuar em direto?","Continue without WARP?":"Continuar sem WARP?","Cooldown between attempts (s)":"Espera entre tentativas (s)","Copies auth.json to your Desktop, then clears the saved tokens.":"Copia o auth.json para o teu Ambiente de trabalho e depois apaga os tokens guardados.","Copy the file path":"Copiar o caminho do ficheiro","Creating shortcuts":"A criar atalhos","Creating the opencode command":"A criar o comando opencode","Credentials inside a URL are not stored. Use a local file instead.":"As credenciais dentro de um URL n\u00e3o s\u00e3o guardadas. Usa antes um ficheiro local.","Deep reset":"Rein\u00edcio total","Default connection method and run mode, the WARP proxy port and the warp-cli timings.":"M\u00e9todo de liga\u00e7\u00e3o e modo de execu\u00e7\u00e3o predefinidos, porta do proxy WARP e tempos do warp-cli.","Default: {0}.":"Predefini\u00e7\u00e3o: {0}.","Desktop":"Ambiente de trabalho","Desktop app":"Aplica\u00e7\u00e3o de ambiente de trabalho","Desktop app location, release metadata URL and lookup timeouts.":"Localiza\u00e7\u00e3o da aplica\u00e7\u00e3o de ambiente de trabalho, URL dos metadados de vers\u00f5es e tempos de procura.","Desktop app path":"Caminho da aplica\u00e7\u00e3o de ambiente de trabalho","Direct, no proxy":"Direto, sem proxy","Do it now.":"Fazer agora.","Do that now?":"Fazer isso agora?","Download and install it now?":"Descarregar e instalar agora?","Download the portable Tor bundle when nothing answers.":"Descarrega o Tor port\u00e1til quando nada responde.","Egress":"Sa\u00edda","Egress used for opencode. ASK shows the picker at every start.":"Sa\u00edda usada pelo opencode. ASK mostra o seletor em cada arranque.","Enter a full URL (http, https, ftp or file).":"Escreve um URL completo (http, https, ftp ou file).","Enter a whole number.":"Escreve um n\u00famero inteiro.","Enter cycles: {0}.":"Enter percorre: {0}.","Enter toggles it.":"Enter ativa ou desativa.","Every change is saved at once to {0}":"Cada altera\u00e7\u00e3o \u00e9 guardada de imediato em {0}","Exit":"Sair","Exit IP":"IP de sa\u00edda","Extra rounds (60 s apart) before giving up.":"Rondas extra (com 60 s de intervalo) antes de desistir.","Folder":"Pasta","Font name":"Nome do tipo de letra","Font of the terminal text. Empty leaves the terminal as it is.":"Tipo de letra do texto do terminal. Vazio deixa o terminal como est\u00e1.","Font size":"Tamanho da letra","Free HTTP proxies from your list (any format) or the default one. Each is tested before use.":"Proxies HTTP gratuitos da tua lista (qualquer formato) ou da lista predefinida. Cada um \u00e9 testado antes de usar.","Free or your own list":"Gratuita ou a tua lista","Fresh start":"In\u00edcio novo","Full path of OpenCode.exe. Empty = search automatically.":"Caminho completo do OpenCode.exe. Vazio = procurar automaticamente.","Get a new IP or proxy, then open OpenCode. Your chats and history stay untouched.":"Obt\u00e9m um novo IP ou proxy e abre o OpenCode. Seus chats e hist\u00f3rico ficam intactos.","Gets a new IP / WARP registration / Tor circuit / proxy.":"Obt\u00e9m um novo IP / registo WARP / circuito Tor / proxy.","Go ahead.":"Avan\u00e7a.","Go back. Nothing is changed.":"Voltar. Nada \u00e9 alterado.","Guided setup: choose WARP, Tor, a proxy list or direct, then get an \"opencode\" command and a shortcut that start with it. It is tested at the end.":"Assistente: escolhe WARP, Tor, uma lista de proxies ou liga\u00e7\u00e3o direta e obt\u00e9m um comando \"opencode\" e um atalho que arrancam com ela. \u00c9 testado no fim.","HTTP port of the built-in bridge opencode uses.":"Porta HTTP da ponte integrada que o opencode usa.","Host used by the API check.":"Servidor usado pela verifica\u00e7\u00e3o da API.","How do you want to run OpenCode?":"Como queres executar o OpenCode?","How many proxies to test before giving up.":"Quantos proxies testar antes de desistir.","How many times, and how fast, a new IP is requested when the free limit is hit.":"Quantas vezes e a que ritmo se pede um IP novo quando o limite gratuito \u00e9 atingido.","IPs the probe may reject before giving up. 0 = no limit.":"IPs que o teste pode rejeitar antes de desistir. 0 = sem limite.","Icons and borders":"\u00cdcones e bordas","Install Tor automatically":"Instalar o Tor automaticamente","Keep the current connection and open OpenCode as it was.":"Mant\u00e9m a liga\u00e7\u00e3o atual e abre o OpenCode como estava.","Keep the current font.":"Manter o tipo de letra atual.","Kill opencode and clear the saved tokens, keeping your chats where they are.":"Fecha o opencode e apaga os tokens guardados, deixando as tuas conversas onde est\u00e3o.","Kill opencode, move your chats to the Desktop, clear the saved tokens and open a fresh session.":"Fecha o opencode, move as tuas conversas para o Ambiente de trabalho, apaga os tokens guardados e abre uma sess\u00e3o nova.","Language":"Idioma","Language of the menus and descriptions. auto follows Windows. Logs and the support report stay in English.":"Idioma dos menus e das descri\u00e7\u00f5es. auto segue o Windows. Os registos e o relat\u00f3rio de suporte ficam em ingl\u00eas.","Last check":"\u00daltima verifica\u00e7\u00e3o","Launch OpenCode":"Iniciar o OpenCode","Launcher":"Launcher","Launcher self-update":"Atualiza\u00e7\u00e3o autom\u00e1tica do launcher","Leave the setup without changing anything.":"Sair do assistente sem alterar nada.","Leave the terminal font as it is. If the launcher changed it, the original font comes back.":"Deixa o tipo de letra do terminal como est\u00e1. Se o launcher o alterou, volta o original.","Local Tor with a built-in HTTP bridge. A portable Tor is installed automatically if missing.":"Tor local com uma ponte HTTP integrada. Se faltar, \u00e9 instalado automaticamente um Tor port\u00e1til.","Local port of the WARP proxy.":"Porta local do proxy WARP.","Logs":"Registos","Main menu":"Menu principal","Method":"M\u00e9todo","Minimum list size (bytes)":"Tamanho m\u00ednimo da lista (bytes)","Mode":"Modo","Model used by the IP probe.":"Modelo usado pelo teste de IP.","Must be between {0} and {1}.":"Tem de estar entre {0} e {1}.","New IP and resume in 5s":"IP novo e retomar em 5 s","No":"N\u00e3o","No .exe file exists at that path.":"N\u00e3o existe nenhum ficheiro .exe nesse caminho.","No answer in {0}s counts as No.":"Sem resposta em {0} s conta como N\u00e3o.","No change.":"Sem altera\u00e7\u00f5es.","No proxy: opencode uses your real connection and nothing is rotated.":"Sem proxy: o opencode usa a tua liga\u00e7\u00e3o real e nada \u00e9 rodado.","No, cancel":"N\u00e3o, cancelar","Non-limit probe failures before the hunt stops.":"Falhas do teste que n\u00e3o s\u00e3o do limite antes de a procura parar.","Not a URL, and no file exists at that path.":"N\u00e3o \u00e9 um URL e n\u00e3o existe nenhum ficheiro nesse caminho.","Not configured":"N\u00e3o configurado","Nothing to ask for a direct connection.":"N\u00e3o h\u00e1 nada a perguntar para uma liga\u00e7\u00e3o direta.","Nothing was left half done that Uninstall cannot remove. Fix the problem and run setup again.":"N\u00e3o ficou nada a meio que Desinstalar n\u00e3o consiga remover. Corrige o problema e executa o assistente outra vez.","On PATH":"No PATH","Only opencode uses it; the rest of the system stays direct.":"S\u00f3 o opencode a usa; o resto do sistema continua em direto.","Open the Windows folder picker and choose where to work.":"Abre o seletor de pastas do Windows para escolher onde trabalhar.","Open the folder":"Abrir a pasta","Open the launcher menus: pick a folder and a connection method, then start the opencode CLI or the desktop app.":"Abre os menus do launcher: escolhe uma pasta e um m\u00e9todo de liga\u00e7\u00e3o e inicia a CLI do opencode ou a aplica\u00e7\u00e3o de ambiente de trabalho.","OpenCode app":"App do OpenCode","PATH lookup timeout (s)":"Tempo limite da procura no PATH (s)","Paths":"Caminhos","Port {0} is already used by {1}.":"A porta {0} j\u00e1 \u00e9 usada por {1}.","Ports and install behavior of the portable Tor the launcher starts for you.":"Portas e instala\u00e7\u00e3o do Tor port\u00e1til que o launcher inicia por ti.","Press any key to continue...":"Prime uma tecla para continuar...","Probe":"Teste","Probe failures tolerated":"Falhas de teste toleradas","Probe model":"Modelo de teste","Proxies tried per pick":"Proxies testados por escolha","Proxy":"Proxy","Proxy list":"Lista de proxies","Proxy list source":"Origem da lista de proxies","Proxy test timeout (s)":"Tempo limite do teste de um proxy (s)","Public HTTP proxies from a list (yours, in any format, or the free default). Each one is tested first and burned ones are skipped.":"Proxies HTTP p\u00fablicos de uma lista (a tua, em qualquer formato, ou a gratuita por defeito). Cada um \u00e9 testado primeiro e os queimados s\u00e3o ignorados.","Put every setting back to its default. Your connection setup (command, shortcuts) is not touched. Asks first.":"Rep\u00f5e todas as defini\u00e7\u00f5es nos valores predefinidos. A tua configura\u00e7\u00e3o de liga\u00e7\u00e3o (comando, atalhos) n\u00e3o \u00e9 tocada. Pede confirma\u00e7\u00e3o.","Put the full path on the clipboard.":"Coloca o caminho completo na \u00e1rea de transfer\u00eancia.","Quotes and line breaks are not allowed.":"N\u00e3o s\u00e3o permitidas aspas nem quebras de linha.","Range {0} to {1}.":"Intervalo de {0} a {1}.","Reconfigure (run setup again)":"Reconfigurar (executar o assistente outra vez)","Release metadata URL":"URL dos metadados de vers\u00f5es","Removes only what setup added: the opencode command, the shortcuts and the PATH entry.":"Remove apenas o que o assistente adicionou: o comando opencode, os atalhos e a entrada no PATH.","Removes only what the setup added (command, shortcuts, PATH entry) and restores the settings it changed. Backups are kept. Asks first.":"Remove apenas o que o assistente adicionou (comando, atalhos, entrada no PATH) e restaura as defini\u00e7\u00f5es que alterou. As c\u00f3pias de seguran\u00e7a s\u00e3o mantidas. Pede confirma\u00e7\u00e3o.","Removing shortcuts":"A remover atalhos","Removing the opencode command":"A remover o comando opencode","Renew did not finish (code {0}).":"A renova\u00e7\u00e3o n\u00e3o terminou (c\u00f3digo {0}).","Renew session":"Renovar sess\u00e3o","Renew the session?":"Renovar a sess\u00e3o?","Renewed. Open opencode again; you may need to log in once more.":"Renovada. Abre o opencode outra vez; talvez tenhas de iniciar sess\u00e3o de novo.","Renewing":"A renovar","Renewing the session":"A renovar a sess\u00e3o","Reopen the last folder":"Reabrir a \u00faltima pasta","Report ready. Personal data was removed; read it once before you share it.":"Relat\u00f3rio pronto. Os dados pessoais foram removidos; l\u00ea-o uma vez antes de o partilhares.","Repository":"Reposit\u00f3rio","Reset every setting to its default?":"Repor todas as defini\u00e7\u00f5es nos valores predefinidos?","Reset to default values":"Repor valores predefinidos","Restores the settings setup changed. Your other settings and your opencode files are kept.":"Restaura as defini\u00e7\u00f5es que o assistente alterou. As tuas outras defini\u00e7\u00f5es e os teus ficheiros do opencode s\u00e3o mantidos.","Restoring PATH":"A restaurar o PATH","Restoring settings":"A restaurar defini\u00e7\u00f5es","Resume message":"Mensagem de retoma","Resume timeout (s)":"Tempo limite da retoma (s)","Return to the connection details.":"Voltar aos detalhes da liga\u00e7\u00e3o.","Return to the main menu.":"Voltar ao menu principal.","Return to the settings groups.":"Voltar aos grupos de defini\u00e7\u00f5es.","Review":"Resumo","Rotate the connection only (new WARP registration, Tor circuit or proxy) without opening OpenCode.":"Roda s\u00f3 a liga\u00e7\u00e3o (novo registo WARP, circuito Tor ou proxy) sem abrir o OpenCode.","Rotate when a fatal error appears while opencode runs.":"Roda quando surge um erro grave enquanto o opencode corre.","Rotation":"Rota\u00e7\u00e3o","Rotation attempts":"Tentativas de rota\u00e7\u00e3o","Rotation rounds":"Rondas de rota\u00e7\u00e3o","Run mode":"Modo de execu\u00e7\u00e3o","Run opencode in this terminal. After a new IP the chat resumes by itself.":"Executa o opencode neste terminal. Depois de um IP novo a conversa retoma sozinha.","Run the OpenCode desktop app ({0}). It is restarted after every new IP.":"Executa a aplica\u00e7\u00e3o de ambiente de trabalho do OpenCode ({0}). \u00c9 reiniciada ap\u00f3s cada IP novo.","Run the setup again to change the method or repair the opencode command.":"Executa o assistente outra vez para mudar o m\u00e9todo ou reparar o comando opencode.","SOCKS port of the Tor the launcher starts.":"Porta SOCKS do Tor que o launcher inicia.","Save the settings, create the opencode command, the shortcuts and the PATH entry, then test the connection.":"Guarda as defini\u00e7\u00f5es, cria o comando opencode, os atalhos e a entrada no PATH e depois testa a liga\u00e7\u00e3o.","Saved: {0} = {1}":"Guardado: {0} = {1}","Saving config.json":"A guardar config.json","Seconds a single \"where\" lookup may take.":"Segundos que uma procura com \"where\" pode demorar.","Seconds a single proxy test may take.":"Segundos que o teste de um proxy pode demorar.","Seconds a single warp-cli call may take.":"Segundos que uma chamada ao warp-cli pode demorar.","Seconds before a silent resume counts as a dead IP.":"Segundos at\u00e9 uma retoma sem resposta contar como IP morto.","Seconds to wait after (re)connecting WARP.":"Segundos de espera ap\u00f3s (re)ligar o WARP.","Seconds to wait for Tor to finish bootstrapping.":"Segundos de espera at\u00e9 o Tor terminar de arrancar.","See what the setup installed (command, shortcuts, PATH) and run it again to change the method.":"V\u00ea o que o assistente instalou (comando, atalhos, PATH) e executa-o outra vez para mudar o m\u00e9todo.","Send one cheap message through each candidate IP.":"Envia uma mensagem barata por cada IP candidato.","Sent automatically after a rotation.":"Enviada automaticamente ap\u00f3s uma rota\u00e7\u00e3o.","Settings":"Defini\u00e7\u00f5es","Settings and setup":"Defini\u00e7\u00f5es e configura\u00e7\u00e3o","Setup 1/3 - connection method":"Configura\u00e7\u00e3o 1/3 - m\u00e9todo de liga\u00e7\u00e3o","Setup 2/3 - details":"Configura\u00e7\u00e3o 2/3 - detalhes","Setup 3/3 - run mode":"Configura\u00e7\u00e3o 3/3 - modo de execu\u00e7\u00e3o","Setup stopped: {0}":"O assistente parou: {0}","Shortcuts":"Atalhos","Show the CLI or Desktop choice every time the launcher opens.":"Mostra a escolha CLI ou Ambiente de trabalho sempre que o launcher abre.","Show the report in Explorer so you can attach or paste it.":"Mostra o relat\u00f3rio no Explorador para o poderes anexar ou colar.","Size used with the chosen font.":"Tamanho usado com o tipo de letra escolhido.","Support":"Suporte","Support report":"Relat\u00f3rio de suporte","Switch between the terminal and the desktop app.":"Alternar entre o terminal e a aplica\u00e7\u00e3o de ambiente de trabalho.","Switch to Tor and keep going?":"Mudar para o Tor e continuar?","System":"Sistema","Takes effect at the {0}; a service already running keeps the old value until then.":"Tem efeito em: {0}; um servi\u00e7o que j\u00e1 esteja a correr mant\u00e9m o valor antigo at\u00e9 l\u00e1.","Terminal font":"Tipo de letra do terminal","Test every new IP":"Testar cada IP novo","The OpenCode desktop app was not found. Choosing this offers to download and install it.":"A aplica\u00e7\u00e3o de ambiente de trabalho do OpenCode n\u00e3o foi encontrada. Ao escolh\u00ea-la \u00e9 oferecido descarreg\u00e1-la e instal\u00e1-la.","The OpenCode desktop app; it is restarted after every new IP.":"A aplica\u00e7\u00e3o de ambiente de trabalho do OpenCode; \u00e9 reiniciada ap\u00f3s cada IP novo.","The activity log (launcher.log) and the support report: what is recorded, how big it may grow, whether IPs are masked.":"O registo de atividade (launcher.log) e o relat\u00f3rio de suporte: o que \u00e9 guardado, quanto pode crescer e se os IPs s\u00e3o ocultados.","The cheap test message sent through every new IP before it is trusted.":"A mensagem de teste barata enviada por cada IP novo antes de confiar nele.","The check failed (code {0}). Setup is saved; fix the cause and use Renew or Connect again.":"A verifica\u00e7\u00e3o falhou (c\u00f3digo {0}). A configura\u00e7\u00e3o est\u00e1 guardada; corrige a causa e usa Renovar ou Ligar outra vez.","The font applies to the whole terminal window, not only to this launcher.":"O tipo de letra aplica-se a toda a janela do terminal, n\u00e3o s\u00f3 a este launcher.","The proxy lives only in the opencode process; the rest of the system stays direct.":"O proxy existe s\u00f3 no processo do opencode; o resto do sistema continua em direto.","The resume auto-approves tool permissions.":"A retoma aprova sozinha as permiss\u00f5es das ferramentas.","The shortcut and the opencode command use the CLI; this is the launcher menu default.":"O atalho e o comando opencode usam a CLI; isto \u00e9 o predefinido do menu do launcher.","The terminal interface. The opencode command and the shortcut always use it.":"A interface de terminal. O comando opencode e o atalho usam-na sempre.","This launcher is not the one that set it up. Reconfigure to repair the command.":"Este launcher n\u00e3o \u00e9 o que o configurou. Reconfigura para reparar o comando.","Token reset":"Rein\u00edcio de tokens","Tools and versions":"Ferramentas e vers\u00f5es","Tor HTTP bridge port":"Porta da ponte HTTP do Tor","Tor SOCKS port":"Porta SOCKS do Tor","Tor bootstrap wait (s)":"Espera do arranque do Tor (s)","Tor is downloaded once, run hidden and offered to opencode through a built-in HTTP bridge. Slower, but a new circuit is a new IP.":"O Tor \u00e9 descarregado uma vez, executado oculto e oferecido ao opencode atrav\u00e9s de uma ponte HTTP integrada. Mais lento, mas um circuito novo \u00e9 um IP novo.","Try again in a minute, or pick another connection method in Connect with opencode.":"Tenta de novo dentro de um minuto, ou escolhe outro m\u00e9todo de liga\u00e7\u00e3o em Ligar ao opencode.","Try again?":"Tentar de novo?","Try to download and install WARP now?":"Tentar descarregar e instalar o WARP agora?","Type \"opencode\" in a NEW terminal, or use the \"OpenCode Infinite (egress)\" shortcut.":"Escreve \"opencode\" num terminal NOVO, ou usa o atalho \"OpenCode Infinite (egress)\".","Type < to go back. Enter keeps the value shown.":"Escreve < para voltar. Enter mant\u00e9m o valor mostrado.","Type a font name...":"Escrever o nome de um tipo de letra...","URL or local file, any format (plain, CSV, JSON, XML, HTML).":"URL ou ficheiro local, em qualquer formato (texto simples, CSV, JSON, XML, HTML).","Unattended resume":"Retoma sem supervis\u00e3o","Uninstall":"Desinstalar","Uninstall stopped: {0}":"A desinstala\u00e7\u00e3o parou: {0}","Uninstall the opencode connection?":"Desinstalar a liga\u00e7\u00e3o do opencode?","Uninstalled. Backups stay in {0}":"Desinstalado. As c\u00f3pias de seguran\u00e7a ficam em {0}","Uninstalling":"A desinstalar","Update now?":"Atualizar agora?","Updates":"Atualiza\u00e7\u00f5es","Use 1 to 200 characters.":"Usa de 1 a 200 caracteres.","Use it when the free limit is hit or the login expired: closes opencode, saves and clears the saved tokens, and gets a new IP, WARP registration, Tor circuit or proxy.":"Usa quando o limite gratuito for atingido ou o in\u00edcio de sess\u00e3o expirar: fecha o opencode, guarda e apaga os tokens guardados e obt\u00e9m um IP, registo WARP, circuito Tor ou proxy novo.","Use on or off.":"Usa on ou off.","Use that proxy anyway?":"Usar esse proxy mesmo assim?","Use this folder":"Usar esta pasta","Use up to 31 characters, without quotes or backslashes.":"Usa at\u00e9 31 caracteres, sem aspas nem barras invertidas.","Use {0} for the terminal text. Monospaced fonts only look right.":"Usa {0} para o texto do terminal. S\u00f3 os tipos de letra monoespa\u00e7ados ficam bem.","Version":"Vers\u00e3o","View and change every launcher option: connection, proxies, Tor, rotation, themes. Saved instantly, no files to edit.":"V\u00ea e altera todas as op\u00e7\u00f5es do launcher: liga\u00e7\u00e3o, proxies, Tor, rota\u00e7\u00e3o, temas. Guardado de imediato, sem editar ficheiros.","WARP proxy port":"Porta do proxy WARP","WARP wait (s)":"Espera do WARP (s)","Watch the log":"Vigiar o registo","Watcher":"Vigilante","Watching the opencode log and the automatic \"continue\" sent after a rotation.":"Vigil\u00e2ncia do registo do opencode e do \"continue\" autom\u00e1tico enviado ap\u00f3s uma rota\u00e7\u00e3o.","Where proxies come from (URL or file, any format) and how each one is tested.":"De onde v\u00eam os proxies (URL ou ficheiro, qualquer formato) e como cada um \u00e9 testado.","Where versions and checksums are read from.":"De onde se leem as vers\u00f5es e as somas de verifica\u00e7\u00e3o.","Whether the launcher checks GitHub for a newer copy of itself at every start.":"Se o launcher procura no GitHub uma c\u00f3pia mais recente de si pr\u00f3prio em cada arranque.","Work in a different folder.":"Trabalhar noutra pasta.","Work in the folder the launcher was started from: {0}":"Trabalhar na pasta de onde o launcher foi iniciado: {0}","Work in {0}":"Trabalhar em {0}","Writing the report":"A escrever o relat\u00f3rio","Yes":"Sim","Yes, continue":"Sim, continuar","Your connection setup (shim, shortcuts) is not touched.":"A tua configura\u00e7\u00e3o de liga\u00e7\u00e3o (shim, atalhos) n\u00e3o \u00e9 tocada.","Your session needs renewing: {0}":"A tua sess\u00e3o precisa de ser renovada: {0}","asks first":"pede confirma\u00e7\u00e3o","auto":"auto","auto follows the terminal and NO_COLOR; off disables colors.":"auto segue o terminal e o NO_COLOR; off desativa as cores.","direct":"direto","emoji = modern terminals, unicode = classic console, ascii = anything.":"emoji = terminais modernos, unicode = consola cl\u00e1ssica, ascii = qualquer um.","free list":"lista gratuita","installed":"instalada","missing":"em falta","new IP":"IP nova","next Tor start":"pr\u00f3ximo arranque do Tor","next WARP connect":"pr\u00f3xima liga\u00e7\u00e3o do WARP","next launch":"pr\u00f3ximo arranque","no other step is needed.":"n\u00e3o \u00e9 preciso nenhum outro passo.","not installed":"n\u00e3o instalada","not verified":"n\u00e3o verificado","off":"desativado","on":"ativado","same IP":"mesmo IP","terminal":"terminal","warp-cli timeout (s)":"Tempo limite do warp-cli (s)","yes":"sim","{0} changed":"{0} alterados","{0} of {1}":"{0} de {1}","After opencode closes":"Depois que o opencode fechar","ask = R, M or Q: R gets a new IP and resumes the chat, M opens the menu, Q quits. quit = leave the launcher at once.":"ask = R, M ou Q: R pede um novo IP e retoma o chat, M abre o menu, Q sai. quit = fecha o launcher imediatamente.","Rotate key":"Tecla de rota\u00e7\u00e3o","Menu key":"Tecla do menu","Quit key":"Tecla de sair","Closed-opencode prompt: new IP and resume the chat.":"Pergunta ao fechar o opencode: novo IP e continuar o chat.","Closed-opencode prompt: open the menu.":"Pergunta ao fechar: abrir o menu.","Closed-opencode prompt: quit. Ctrl+C always quits too.":"Pergunta ao fechar: sair. Ctrl+C tamb\u00e9m sai sempre.","The keys of the launcher and the terminal commands. Fixed keys are listed for reference; the three letters can be changed.":"Teclas do lan\u00e7ador e comandos do terminal. As teclas fixas aparecem para refer\u00eancia; as tr\u00eas letras podem ser alteradas.","One letter, like R.":"Uma letra, como R.","Key {0} is already used by {1}.":"A tecla {0} j\u00e1 \u00e9 usada por {1}.","Only the chosen language is downloaded from the langs folder of the repository.":"S\u00f3 o idioma escolhido \u00e9 baixado da pasta langs do reposit\u00f3rio.","Follow the language Windows uses.":"Segue o idioma do Windows.","Use this language for every menu and message.":"Usa este idioma em todos os menus e mensagens.","Keep the current language.":"Manter o idioma atual.","File to write (Enter = Desktop, Esc = back)":"Arquivo a gravar (Enter = \u00c1rea de Trabalho, Esc = voltar)","File to read (Esc = back)":"Arquivo a ler (Esc = voltar)","That folder does not exist.":"Essa pasta n\u00e3o existe.","Replace the file that is already there?":"Substituir o arquivo que j\u00e1 existe?","Exported {0} changed setting(s) to {1}":"{0} ajuste(s) alterado(s) exportado(s) para {1}","Import {0} setting(s)? Their current values are replaced.":"Importar {0} ajuste(s)? Os valores atuais ser\u00e3o substitu\u00eddos.","{0} setting(s) of this file are unknown here and are skipped.":"{0} ajuste(s) deste arquivo s\u00e3o desconhecidos aqui e ser\u00e3o ignorados.","No file at that path.":"N\u00e3o h\u00e1 arquivo nesse caminho.","This is not an OpenCode Infinite settings file.":"Este arquivo n\u00e3o \u00e9 de ajustes do OpenCode Infinite.","Nothing was imported. These values are not valid:":"Nada foi importado. Estes valores n\u00e3o s\u00e3o v\u00e1lidos:","Imported {0} setting(s).":"{0} ajuste(s) importado(s).","Export settings to a file":"Exportar ajustes para um arquivo","Save every changed setting to one .json file, to keep a backup or copy them to another PC.":"Salva todos os ajustes alterados em um arquivo .json, como c\u00f3pia de seguran\u00e7a ou para outro PC.","Import settings from a file":"Importar ajustes de um arquivo","Load a file made by Export. Every value is checked first; if one is wrong, nothing changes.":"Carrega um arquivo feito com Exportar. Cada valor \u00e9 verificado antes; se um estiver errado, nada muda.","back to the previous screen":"voltar \u00e0 tela anterior","Fixed. In a menu or a text prompt Esc goes back; it never closes the launcher.":"Fixa. Em um menu ou campo de texto, Esc volta; nunca fecha o lan\u00e7ador.","select and move":"escolher e mover","Fixed. Digits 1-9 jump straight to a row.":"Fixa. Os n\u00fameros 1-9 v\u00e3o direto a uma linha.","quit the launcher":"fechar o lan\u00e7ador","Fixed. Stops the processes it started and leaves the terminal open, no Y/N question.":"Fixa. Para os processos iniciados e deixa o terminal aberto, sem pergunta S/N.","start with the connection":"iniciar com a conex\u00e3o","Terminal command from any folder. The Start menu shortcut does the same.":"Comando de terminal de qualquer pasta. O atalho do menu Iniciar faz o mesmo.","open this menu":"abrir este menu","Terminal command: opens the launcher menu again, as many times as you need.":"Comando de terminal: abre o menu do lan\u00e7ador de novo, quantas vezes precisar.","original OpenCode":"OpenCode original","Terminal command: starts the OpenCode you installed, without the launcher or the connection. Use it when the launcher breaks.":"Comando de terminal: inicia o OpenCode que voc\u00ea instalou, sem o lan\u00e7ador nem a conex\u00e3o. Use se o lan\u00e7ador falhar.","Commands":"Comandos","Adds: the opencode, opencodeinf and opencodeoc commands, two shortcuts, one PATH entry. Backups are kept.":"Adiciona os comandos opencode, opencodeinf e opencodeoc, dois atalhos e uma entrada no PATH. As c\u00f3pias de seguran\u00e7a s\u00e3o mantidas.","  This copy is not the official one. Starting the official copy:":"  Esta c\u00f3pia n\u00e3o \u00e9 a oficial. A iniciar a c\u00f3pia oficial:","  OpenCode - how do you want to run it?":"  OpenCode - como quer execut\u00e1-lo?","  [1] CLI      - terminal TUI (chat resumes on every new IP)":"  [1] CLI      - TUI no terminal (o chat retoma a cada IP nova)","  [2] Desktop  - the OpenCode desktop app (restarted on every new IP)":"  [2] Desktop  - a app de desktop do OpenCode (reiniciada a cada IP nova)","  [3] Exit":"  [3] Sair","  One key, no Enter.":"  Uma tecla, sem Enter.","%C_WARN%  [*] OpenCode desktop not found.%C_RST%":"%C_WARN%  [*] App de desktop do OpenCode n\u00e3o encontrada.%C_RST%","%C_WARN%  [*] still not found - set OC_APP to its OpenCode.exe.%C_RST%":"%C_WARN%  [*] Continua sem encontrar - defina OC_APP com o caminho para o OpenCode.exe.%C_RST%","  [app] DESKTOP \"%OC_DESKTOP%\"":"  [app] DESKTOP \"%OC_DESKTOP%\"","  OpenCode - choose a folder to work in":"  OpenCode - escolha uma pasta para trabalhar","  [1] Reopen the last folder":"  [1] Reabrir a \u00faltima pasta","      (nothing saved yet)":"      (ainda n\u00e3o h\u00e1 nada guardado)","  [2] Use this folder":"  [2] Usar esta pasta","  [3] Browse for a folder...":"  [3] Procurar uma pasta...","  [4] Exit":"  [4] Sair","  No folder saved yet. Use [2] or [3] this time.":"  Ainda n\u00e3o h\u00e1 pasta guardada. Use [2] ou [3] desta vez.","  Choose a folder in the dialog...":"  Escolha uma pasta na janela...","  Opening the classic folder picker...":"  A abrir o seletor de pastas cl\u00e1ssico...","  No folder selected.":"  Nenhuma pasta selecionada.","  Folder not found: \"%OPFOLDER%\"":"  Pasta n\u00e3o encontrada: \"%OPFOLDER%\"","  Cannot enter: \"%OPFOLDER%\"":"  N\u00e3o \u00e9 poss\u00edvel entrar em: \"%OPFOLDER%\"","  Working in: \"%CD%\"":"  A trabalhar em: \"%CD%\"","  [egress] %EGRESS% (from your settings)":"  [egress] %EGRESS% (das suas defini\u00e7\u00f5es)","  Choose egress for OpenCode only (system traffic stays direct)":"  Escolha a sa\u00edda s\u00f3 para o OpenCode (o tr\u00e1fego do sistema continua direto)","  [1] WARP     - Cloudflare WARP proxy mode (rotation supported)":"  [1] WARP     - modo proxy Cloudflare WARP (suporta rota\u00e7\u00e3o)","  [2] TOR      - local Tor + built-in bridge on :%TOR_HTTP_PORT%":"  [2] TOR      - Tor local + ponte integrada em :%TOR_HTTP_PORT%","                 (auto-installs a portable Tor, nothing to set up)":"                 (instala um Tor port\u00e1til, n\u00e3o h\u00e1 nada a configurar)","  [3] PROXY    - free HTTP proxies (ProxyScrape list)":"  [3] PROXY    - proxies HTTP gratuitos (lista ProxyScrape)","  [4] NONE     - direct, no proxy":"  [4] NONE     - direto, sem proxy","  [egress] NONE - direct.":"  [egress] NONE - direto.","  [egress] PROXY - free HTTP list.":"  [egress] PROXY - lista HTTP gratuita.","  [egress] TOR - portable Tor + built-in bridge on :%TOR_HTTP_PORT%, auto-setup.":"  [egress] TOR - Tor port\u00e1til + ponte integrada em :%TOR_HTTP_PORT%, configura\u00e7\u00e3o autom\u00e1tica.","  [egress] WARP.":"  [egress] WARP.","  [dep] curl":"  [dep] curl","  [dep] warp":"  [dep] warp","%C_WARN%  [*] Cloudflare WARP not found - IP rotation will be disabled.%C_RST%":"%C_WARN%  [*] Cloudflare WARP n\u00e3o encontrado - a rota\u00e7\u00e3o de IP fica desativada.%C_RST%","      Install it later from 1.1.1.1 if you want the rotation.":"      Instale-o mais tarde a partir de 1.1.1.1 se quiser a rota\u00e7\u00e3o.","%C_WARN%  [*] WARP still not available - continuing without rotation.%C_RST%":"%C_WARN%  [*] WARP continua indispon\u00edvel - a continuar sem rota\u00e7\u00e3o.%C_RST%","      warp-cli errors, if any, are in %STATE_DIR%\\wcli.log":"      Os erros do warp-cli, se houver, est\u00e3o em %STATE_DIR%\\wcli.log","%C_WARN%  [*] Cloudflare WARP publishes 64-bit Windows builds only.%C_RST%":"%C_WARN%  [*] O Cloudflare WARP s\u00f3 tem vers\u00f5es de 64 bits para Windows.%C_RST%","      On this 32-bit system rotation is disabled.":"      Neste sistema de 32 bits a rota\u00e7\u00e3o est\u00e1 desativada.","%C_OK%  [ok] WARP ready.%C_RST%":"%C_OK%  [ok] WARP pronto.%C_RST%","  [dep] opencode":"  [dep] opencode","  [auto-install] opencode not found, fetching it...":"  [auto-install] opencode n\u00e3o encontrado, a transferir...","%C_OK%  [ok] opencode ready.%C_RST%":"%C_OK%  [ok] opencode pronto.%C_RST%","%C_ERR%  ERROR: opencode install failed or is not on PATH.%C_RST%":"%C_ERR%  ERRO: a instala\u00e7\u00e3o do opencode falhou ou n\u00e3o est\u00e1 no PATH.%C_RST%","  Get it by hand: https://github.com/sst/opencode/releases":"  Obtenha-o manualmente: https://github.com/sst/opencode/releases","  Preparing the connection...":"  A preparar a liga\u00e7\u00e3o...","  OpenCode":"  OpenCode","  Folder : \"%CD%\"":"  Pasta : \"%CD%\"","  Egress : %EGRESS%":"  Sa\u00edda  : %EGRESS%","  Mode   : %APP_MODE%":"  Modo   : %APP_MODE%","  WARP   : none (rotation disabled)":"  WARP   : nenhum (rota\u00e7\u00e3o desativada)","  WARP   : \"%WARP%\"":"  WARP   : \"%WARP%\"","  Version: %OC_VER%  \"%OC_CMD%\"":"  Vers\u00e3o : %OC_VER%  \"%OC_CMD%\"","  Exit IP: %IP%":"  IP de sa\u00edda: %IP%","  What do you want to do?":"  O que quer fazer?","  [1] Fresh start   - get a new IP / proxy, then open OpenCode":"  [1] Come\u00e7ar do zero - obter um IP / proxy novo, depois abrir o OpenCode","                      (your chats and history stay untouched)":"                      (os seus chats e hist\u00f3rico n\u00e3o s\u00e3o alterados)","  [2] Continue      - same egress, open OpenCode as it was":"  [2] Continuar    - mesma sa\u00edda, abrir o OpenCode como estava","  [3] Change IP     - rotate / pick new proxy only":"  [3] Mudar IP     - apenas rodar / escolher um proxy novo","  [5] Deep reset    - kill opencode, move chats to the Desktop,":"  [5] Rein\u00edcio total - fechar o opencode, mover os chats para o Ambiente de Trabalho,","                      clear saved tokens, open a fresh session":"                      limpar os tokens guardados, abrir uma sess\u00e3o nova","  [6] Exit":"  [6] Sair","  [7] Token reset   - kill opencode, clear saved tokens, keep chats":"  [7] Repor tokens - fechar o opencode, limpar os tokens guardados,","                      where they are, open a fresh session":"                      os chats ficam onde est\u00e3o, abrir uma sess\u00e3o nova","  [8] Settings      - change any launcher setting, applied right away":"  [8] Defini\u00e7\u00f5es   - alterar qualquer defini\u00e7\u00e3o, aplicada de imediato","--- deep reset -----------------------------------------------":"--- rein\u00edcio total ---------------------------------------------","  This closes opencode, moves your chats to the Desktop,":"  Isto fecha o opencode, move os seus chats para o Ambiente de Trabalho,","  clears the saved tokens and opens a brand new session.":"  limpa os tokens guardados e abre uma sess\u00e3o nova.","  It is the only action in this script that touches your files.":"  \u00c9 a \u00fanica a\u00e7\u00e3o deste script que mexe nos seus ficheiros.","  It also kills EVERY opencode process on this computer,":"  Tamb\u00e9m termina TODOS os processos opencode deste computador,","  including windows opened by hand or by another launcher.":"  incluindo janelas abertas \u00e0 m\u00e3o ou por outro launcher.","--- token reset ----------------------------------------------":"--- repor tokens -----------------------------------------------","  This closes opencode, clears the saved tokens and opens a":"  Isto fecha o opencode, limpa os tokens guardados e abre uma","  brand new session. Your chats are NOT moved.":"  sess\u00e3o nova. Os seus chats N\u00c3O s\u00e3o movidos.","  auth.json is copied to the Desktop first, then removed.":"  O auth.json \u00e9 primeiro copiado para o Ambiente de Trabalho e depois removido.","    egress: %EGRESS%":"    sa\u00edda: %EGRESS%","%C_WARN%  [*] WARP proxy is not answering - rotation has no effect.%C_RST%":"%C_WARN%  [*] O proxy do WARP n\u00e3o responde - a rota\u00e7\u00e3o n\u00e3o tem efeito.%C_RST%","      Going direct would run opencode on your real IP.":"      Sair diretamente faria o opencode usar o seu IP real.","%C_WARN%  [*] Tor did not get ready.%C_RST%":"%C_WARN%  [*] O Tor n\u00e3o ficou pronto.%C_RST%","%C_WARN%  [*] no working free proxy found.%C_RST%":"%C_WARN%  [*] n\u00e3o foi encontrado nenhum proxy gratuito que funcione.%C_RST%","%C_WARN%  [*] the egress proxy stopped answering while OpenCode was open:%C_RST%":"%C_WARN%  [*] o proxy de sa\u00edda deixou de responder enquanto o OpenCode estava aberto:%C_RST%","      %STATE_DIR%\\proxy_warn.txt":"      %STATE_DIR%\\proxy_warn.txt","%C_WARN%  [watch] a fatal error cut the chat - rotating and resuming it.%C_RST%":"%C_WARN%  [watch] um erro fatal cortou o chat - a rodar e a retom\u00e1-lo.%C_RST%","OpenCode closed.":"OpenCode fechado.","  %KEY_ROTATE% = new IP and resume the chat   %KEY_MENU% = menu   %KEY_QUIT% = quit (Ctrl+C also quits)":"  %KEY_ROTATE% = novo IP e retomar o chat   %KEY_MENU% = menu   %KEY_QUIT% = sair (Ctrl+C tamb\u00e9m sai)","Press any key to continue . . .":"Prima uma tecla para continuar . . .","  [tor] renewing the circuit, attempt %TOR_TRIES% of %ROTATE_TRIES_MAX%...":"  [tor] a renovar o circuito, tentativa %TOR_TRIES% de %ROTATE_TRIES_MAX%...","%C_OK%  [tor] new circuit - resuming.%C_RST%":"%C_OK%  [tor] circuito novo - a retomar.%C_RST%","%C_WARN%  [*] Tor could not be renewed - back to menu.%C_RST%":"%C_WARN%  [*] N\u00e3o foi poss\u00edvel renovar o Tor - de volta ao menu.%C_RST%","%C_WARN%  [*] Tor could not get a usable circuit after %ROTATE_TRIES_MAX% attempts.%C_RST%":"%C_WARN%  [*] O Tor n\u00e3o obteve um circuito utiliz\u00e1vel ap\u00f3s %ROTATE_TRIES_MAX% tentativas.%C_RST%","      The exit node may be blocked: try a new identity in Tor, or":"      O n\u00f3 de sa\u00edda pode estar bloqueado: experimente uma identidade nova no Tor, ou","      switch to [1] WARP. warp/tor notes: \"%TOR_DIR%\\tor.log\"":"      mude para [1] WARP. Notas de warp/tor: \"%TOR_DIR%\\tor.log\"","  [proxy] %ACTIVE_PROXY% is burned - attempt %PROXY_ROT% of %PROXY_ROT_MAX%, picking another...":"  [proxy] %ACTIVE_PROXY% est\u00e1 queimado - tentativa %PROXY_ROT% de %PROXY_ROT_MAX%, a procurar outro...","  [proxy] picking a fresh free proxy before resume...":"  [proxy] a procurar um proxy gratuito novo antes de retomar...","%C_WARN%  [*] no free proxy is left that still works (they all hit the limit).%C_RST%":"%C_WARN%  [*] n\u00e3o resta nenhum proxy gratuito que funcione (todos atingiram o limite).%C_RST%","      Free proxies are shared by many people, so their limit is often used up.":"      Os proxies gratuitos s\u00e3o partilhados por muita gente, por isso o limite costuma estar esgotado.","  Automatic rotation is off - the menu decides.":"  A rota\u00e7\u00e3o autom\u00e1tica est\u00e1 desativada - o menu decide.","Getting a new IP before the next attempt...":"A obter um IP novo antes da pr\u00f3xima tentativa...","  [i] hunting for %HUNT_GOAL%: up to %TARGET_TRIES% attempts, %TARGET_MINUTES% min. Esc or Q stops.":"  [i] a procurar %HUNT_GOAL%: at\u00e9 %TARGET_TRIES% tentativas, %TARGET_MINUTES% min. Esc ou Q para parar.","[%ROTATE_TRIES%/%TARGET_TRIES%] dropping the old registration...":"[%ROTATE_TRIES%/%TARGET_TRIES%] a eliminar o registo anterior...","[%ROTATE_TRIES%/%TARGET_TRIES%] new registration...":"[%ROTATE_TRIES%/%TARGET_TRIES%] registo novo...","[%ROTATE_TRIES%] reconnect...":"[%ROTATE_TRIES%] a religar...","[%ROTATE_TRIES%] waiting %WARP_WAIT%s...":"[%ROTATE_TRIES%] a aguardar %WARP_WAIT%s...","[%ROTATE_TRIES%] %IPN% was already tried in this hunt, rotating again":"[%ROTATE_TRIES%] %IPN% j\u00e1 foi testado nesta pesquisa, a rodar outra vez","[%ROTATE_TRIES%/%TARGET_TRIES%] exit IP %IPN% (country %GLOC%), target %TMATCHTXT%, %HUNT_LEFT% attempt(s) left":"[%ROTATE_TRIES%/%TARGET_TRIES%] IP de sa\u00edda %IPN% (pa\u00eds %GLOC%), alvo %TMATCHTXT%, faltam %HUNT_LEFT% tentativa(s)","[%ROTATE_TRIES%] probing if this IP can still talk...":"[%ROTATE_TRIES%] a verificar se este IP ainda consegue ligar...","%C_WARN%  [*] probe failed for a reason that is NOT a limit - attempt %PBROKEN% of %PROBE_BROKEN_MAX%. Last output:%C_RST%":"%C_WARN%  [*] a verifica\u00e7\u00e3o falhou por um motivo que N\u00c3O \u00e9 um limite - tentativa %PBROKEN% de %PROBE_BROKEN_MAX%. \u00daltima sa\u00edda:%C_RST%","[%PROBE_TRIES%] IP already burned, rotating again...":"[%PROBE_TRIES%] IP j\u00e1 queimado, a rodar outra vez...","%C_WARN%  [*] %PROBE_TRIES% IPs probed, every one of them already burned.%C_RST%":"%C_WARN%  [*] %PROBE_TRIES% IPs verificados, todos j\u00e1 queimados.%C_RST%","%C_WARN%  [*] the probe failed %PBROKEN% times and none of them was a limit error.%C_RST%":"%C_WARN%  [*] a verifica\u00e7\u00e3o falhou %PBROKEN% vezes e nenhuma foi um erro de limite.%C_RST%","      The probe itself is broken, not every IP: a retired PROBE_MODEL id,":"      A pr\u00f3pria verifica\u00e7\u00e3o est\u00e1 avariada, n\u00e3o todos os IPs: um ID de PROBE_MODEL","      an auth error or a CLI change. Rotation cannot fix that.":"      retirado, um erro de autentica\u00e7\u00e3o ou uma altera\u00e7\u00e3o da CLI.","      Check PROBE_MODEL in the settings block, or run the probe model once":"      Verifique PROBE_MODEL no bloco de defini\u00e7\u00f5es, ou execute o modelo de teste","      by hand to see the real error.":"      \u00e0 m\u00e3o uma vez para ver o erro real.","  [i] probe off for this session - IPs are accepted on WARP-trace proof":"  [i] verifica\u00e7\u00e3o desligada nesta sess\u00e3o - os IPs s\u00e3o aceites apenas com a prova do WARP,","      only, and the resume's own limit check keeps catching burned ones.":"      e a verifica\u00e7\u00e3o de limite ao retomar continua a apanhar os queimados.","%C_WARN%  [*] the probe session \"%OC_PROBE_ID%\" does not exist and this%C_RST%":"%C_WARN%  [*] a sess\u00e3o de verifica\u00e7\u00e3o \"%OC_PROBE_ID%\" n\u00e3o existe e esta%C_RST%","      opencode build refused it. That is a probe problem, NOT a":"      vers\u00e3o do opencode recusou-a. \u00c9 um problema da verifica\u00e7\u00e3o, N\u00c3O","      burned IP - no rotation can fix it.":"      um IP queimado - nenhuma rota\u00e7\u00e3o o resolve.","  [i] the probe is off for this session: IPs are accepted on":"  [i] a verifica\u00e7\u00e3o est\u00e1 desligada nesta sess\u00e3o: os IPs s\u00e3o aceites s\u00f3 com a prova do WARP,","      WARP-trace proof only, and the resume's own limit check still":"      e a verifica\u00e7\u00e3o de limite ao retomar continua a apanhar um queimado.","      catches a burned one. To keep the probe, create the session by":"      Para a manter, crie a sess\u00e3o \u00e0 m\u00e3o uma vez,","      hand once, or clear PROBE in the settings block.":"      ou apague PROBE no bloco de defini\u00e7\u00f5es.","%C_OK%[%ROTATE_TRIES%] IP %IPN% works.%C_RST%":"%C_OK%[%ROTATE_TRIES%] o IP %IPN% funciona.%C_RST%","[%ROTATE_TRIES%] no verified WARP IP yet, retrying...":"[%ROTATE_TRIES%] ainda sem IP WARP verificado, a tentar de novo...","%C_WARN%  [*] no usable IP from this hunt. warp-cli errors, if any, are in %STATE_DIR%\\wcli.log%C_RST%":"%C_WARN%  [*] nenhum IP utiliz\u00e1vel nesta pesquisa. Os erros do warp-cli, se houver, est\u00e3o em %STATE_DIR%\\wcli.log%C_RST%","  restarting the desktop app on the new egress...":"  a reiniciar a app de desktop na nova sa\u00edda...","  sending \"%RESUME_MSG%\" so the chat picks up where it stopped...":"  a enviar \"%RESUME_MSG%\" para o chat continuar de onde parou...","%C_WARN%  [*] proxy dead - retrying on the current egress instead of resuming.%C_RST%":"%C_WARN%  [*] proxy morto - a tentar de novo na sa\u00edda atual em vez de retomar.%C_RST%","%C_WARN%  [*] no answer in %RESUME_TIMEOUT%s - this exit IP is dead.%C_RST%":"%C_WARN%  [*] sem resposta em %RESUME_TIMEOUT%s - este IP de sa\u00edda est\u00e1 morto.%C_RST%","%C_OK%  chat resumed on the new IP.%C_RST%":"%C_OK%  chat retomado no novo IP.%C_RST%","%C_WARN%  [*] the resume itself hit a limit - rotating again.%C_RST%":"%C_WARN%  [*] a pr\u00f3pria retoma atingiu um limite - a rodar outra vez.%C_RST%","  Egress is NONE - nothing to rotate.":"  A sa\u00edda \u00e9 NONE - nada para rodar.","  Restarting the launcher-managed Tor for a new circuit...":"  A reiniciar o Tor gerido pelo launcher para um circuito novo...","  TOR mode - this Tor was started outside the launcher.":"  Modo TOR - este Tor foi iniciado fora do launcher.","  Restart it yourself for a new circuit, or pick [1] WARP / [4] NONE.":"  Reinicie-o voc\u00ea mesmo para um circuito novo, ou escolha [1] WARP / [4] NONE.","  Current bridge: http://127.0.0.1:%TOR_HTTP_PORT%":"  Ponte atual: http://127.0.0.1:%TOR_HTTP_PORT%","  Picking a new free HTTP proxy...":"  A procurar um proxy HTTP gratuito novo...","  New proxy: %ACTIVE_PROXY%":"  Novo proxy: %ACTIVE_PROXY%","WARP is not available - nothing to rotate.":"WARP n\u00e3o est\u00e1 dispon\u00edvel - nada para rodar.","Requesting a new WARP registration...":"A pedir um registo novo do WARP...","waiting %WARP_WAIT%s...":"a aguardar %WARP_WAIT%s...","%C_WARN%  [*] no verified WARP IP.%C_RST%":"%C_WARN%  [*] nenhum IP WARP verificado.%C_RST%","      warp-cli errors land in %STATE_DIR%\\wcli.log":"      os erros do warp-cli ficam em %STATE_DIR%\\wcli.log","  same IP as before: %IPN%":"  mesmo IP de antes: %IPN%","%C_OK%  New exit IP: %IPN% (WARP verified)%C_RST%":"%C_OK%  Novo IP de sa\u00edda: %IPN% (WARP verificado)%C_RST%","  --- resume stderr ---":"  --- stderr da retoma ---","  --- resume stdout ---":"  --- stdout da retoma ---","  downloading the WARP installer, about 60 MB...":"  a transferir o instalador do WARP, cerca de 60 MB...","%C_WARN%  [*] download failed.%C_RST%":"%C_WARN%  [*] a transfer\u00eancia falhou.%C_RST%","      grab it by hand and run it: %WARP_MSI_URL%":"      transfira-o \u00e0 m\u00e3o e execute-o: %WARP_MSI_URL%","  installing, accept the UAC prompt...":"  a instalar, aceite o pedido do UAC...","  [auto-install] the standalone build did not install, trying npm.":"  [auto-install] a vers\u00e3o aut\u00f3noma n\u00e3o foi instalada, a tentar com o npm.","  [i] 32-bit Windows: no standalone build - installing via npm.":"  [i] Windows de 32 bits: sem vers\u00e3o aut\u00f3noma - a instalar com o npm.","%C_OK%  [ok] opencode ready on 32-bit via npm.%C_RST%":"%C_OK%  [ok] opencode pronto em 32 bits via npm.%C_RST%","%C_ERR%  ERROR: opencode could not be installed on 32-bit Windows.%C_RST%":"%C_ERR%  ERRO: n\u00e3o foi poss\u00edvel instalar o opencode no Windows de 32 bits.%C_RST%","         Install 32-bit node.js by hand from nodejs.org, then run:":"         Instale o node.js de 32 bits \u00e0 m\u00e3o a partir de nodejs.org e depois execute:","         npm i -g opencode-ai":"         npm i -g opencode-ai","%C_WARN%  [*] could not read the official release info from opencode.ai.%C_RST%":"%C_WARN%  [*] n\u00e3o foi poss\u00edvel ler as informa\u00e7\u00f5es oficiais de vers\u00e3o em opencode.ai.%C_RST%","  [auto-install] downloading opencode %OCA_VER% (official build, %OC_AFILE%)...":"  [auto-install] a transferir o opencode %OCA_VER% (vers\u00e3o oficial, %OC_AFILE%)...","%C_WARN%    [*] checksum mismatch - the download is not the official file.%C_RST%":"%C_WARN%    [*] a soma de verifica\u00e7\u00e3o n\u00e3o coincide - a transfer\u00eancia n\u00e3o \u00e9 o ficheiro oficial.%C_RST%","%C_WARN%    [*] download failed.%C_RST%":"%C_WARN%    [*] a transfer\u00eancia falhou.%C_RST%","  [auto-install] unpacking, about 200 MB on disk...":"  [auto-install] a descomprimir, cerca de 200 MB no disco...","  [auto-install] installing %NPMPKG% with npm...":"  [auto-install] a instalar %NPMPKG% com o npm...","  [npm] the install script was blocked - running it by hand...":"  [npm] o script de instala\u00e7\u00e3o foi bloqueado - a execut\u00e1-lo \u00e0 m\u00e3o...","  [auto-install] node.js (32-bit) is missing - installing it...":"  [auto-install] o node.js (32 bits) est\u00e1 em falta - a instalar...","    via winget...":"    via winget...","  [i] this can take a few minutes on its first run.":"  [i] isto pode demorar alguns minutos na primeira vez.","    winget failed - trying the MSI installer from nodejs.org...":"    o winget falhou - a tentar o instalador MSI de nodejs.org...","    downloading %NODE_MSI_URL% ...":"    a transferir %NODE_MSI_URL% ...","    direct download failed - retrying through the Windows proxy settings...":"    a transfer\u00eancia direta falhou - a tentar novamente com as defini\u00e7\u00f5es de proxy do Windows...","    installing, accept the UAC prompt...":"    a instalar, aceite o pedido do UAC...","  opencode update available: %OCUPD_CUR% -> %OCUPD_LAT%":"  atualiza\u00e7\u00e3o do opencode dispon\u00edvel: %OCUPD_CUR% -> %OCUPD_LAT%","  It closes every running opencode process first.":"  Antes fecha todos os processos opencode em execu\u00e7\u00e3o.","  [update] npm i -g @opencode/cli@latest":"  [update] npm i -g @opencode/cli@latest","  [update] official standalone build %OCUPD_LAT%":"  [update] vers\u00e3o aut\u00f3noma oficial %OCUPD_LAT%","%C_WARN%  [*] \"%OC_CMD%\" reports %OC_VER% but this machine has a v2 database.%C_RST%":"%C_WARN%  [*] \"%OC_CMD%\" indica %OC_VER% mas este computador tem uma base de dados v2.%C_RST%","      A v1 binary cannot open it: \"Database is not empty and has no session table\".":"      Um bin\u00e1rio v1 n\u00e3o a consegue abrir: \"Database is not empty and has no session table\".","      Update it:  npm i -g @opencode/cli@latest   (or accept the update offer)":"      Atualize:  npm i -g @opencode/cli@latest   (ou aceite a oferta de atualiza\u00e7\u00e3o)","%C_WARN%  [*] WARP registration missing - creating a new one.%C_RST%":"%C_WARN%  [*] registo do WARP em falta - a criar um novo.%C_RST%","  [tor] nothing answering on :%TOR_HTTP_PORT% - portable setup starting...":"  [tor] nada responde em :%TOR_HTTP_PORT% - a iniciar a configura\u00e7\u00e3o port\u00e1til...","%C_WARN%  [*] Tor did not become ready - the reason is in \"%TOR_DIR%\\tor.log\"%C_RST%":"%C_WARN%  [*] O Tor n\u00e3o ficou pronto - o motivo est\u00e1 em \"%TOR_DIR%\\tor.log\"%C_RST%","%C_WARN%  [*] the Tor download did not land. Grab it by hand:%C_RST%":"%C_WARN%  [*] o download do Tor n\u00e3o chegou. Transfira-o \u00e0 m\u00e3o:%C_RST%","      https://dist.torproject.org/torbrowser/":"      https://dist.torproject.org/torbrowser/","      unpack the tor-expert-bundle tar.gz into \"%TOR_DIR%\",":"      descomprima o tor-expert-bundle tar.gz em \"%TOR_DIR%\",","      so that \"%TOR_DIR%\\Tor\\tor.exe\" exists, then run this again.":"      para que \"%TOR_DIR%\\Tor\\tor.exe\" exista, e depois execute isto de novo.","%C_OK%  [tor] ready: SOCKS :%TOR_SOCKS_PORT% - HTTP :%TOR_HTTP_PORT%.%C_RST%":"%C_OK%  [tor] pronto: SOCKS :%TOR_SOCKS_PORT% - HTTP :%TOR_HTTP_PORT%.%C_RST%","  [tor] updater JSON unavailable - falling back to the dist index...":"  [tor] JSON do atualizador indispon\u00edvel - a usar o \u00edndice de distribui\u00e7\u00e3o...","%C_WARN%  [*] the Tor bundle did not download.%C_RST%":"%C_WARN%  [*] o pacote do Tor n\u00e3o foi transferido.%C_RST%","  [tor] unpacking...":"  [tor] a descomprimir...","%C_OK%  [ok] Tor installed - portable - in \"%TOR_DIR%\".%C_RST%":"%C_OK%  [ok] Tor instalado - port\u00e1til - em \"%TOR_DIR%\".%C_RST%","%C_WARN%  [*] the bundle unpacked but tor.exe was not found in \"%TOR_DIR%\".%C_RST%":"%C_WARN%  [*] o pacote foi descomprimido mas o tor.exe n\u00e3o foi encontrado em \"%TOR_DIR%\".%C_RST%","  [tor] a Tor is already running on :%TOR_SOCKS_PORT% - using it as it is.":"  [tor] j\u00e1 h\u00e1 um Tor a correr em :%TOR_SOCKS_PORT% - a us\u00e1-lo como est\u00e1.","  [tor] starting tor (hidden window, log: \"%OC_TORLOG%\")...":"  [tor] a iniciar o tor (janela oculta, registo: \"%OC_TORLOG%\")...","%C_WARN%  [*] tor could not be started - see \"%OC_TORERR%\" and \"%OC_TORLOG%\".%C_RST%":"%C_WARN%  [*] n\u00e3o foi poss\u00edvel iniciar o tor - veja \"%OC_TORERR%\" e \"%OC_TORLOG%\".%C_RST%","  [tor] starting the built-in HTTP->SOCKS bridge on :%TOR_HTTP_PORT% (no Privoxy needed)...":"  [tor] a iniciar a ponte HTTP->SOCKS integrada em :%TOR_HTTP_PORT% (sem Privoxy)...","  [tor] bootstrapping, up to %TOR_BOOTSTRAP_WAIT%s (the first run takes longer)...":"  [tor] a ligar, at\u00e9 %TOR_BOOTSTRAP_WAIT%s (a primeira vez demora mais)...","  [tor] Tor is up and routing through the bridge.":"  [tor] O Tor est\u00e1 ativo e a encaminhar pela ponte.","  [tor] still not up after %TOR_BOOTSTRAP_WAIT%s.":"  [tor] ainda n\u00e3o ativo ap\u00f3s %TOR_BOOTSTRAP_WAIT%s.","  [tor] found a Tor Browser SOCKS on :9150 - using it.":"  [tor] encontrado um SOCKS do Tor Browser em :9150 - a usar.","  [tor] found a Tor SOCKS on :9050 - using it.":"  [tor] encontrado um SOCKS do Tor em :9050 - a usar.","  [*] this Tor was not started by the launcher - it cannot be renewed":"  [*] este Tor n\u00e3o foi iniciado pelo launcher - n\u00e3o pode ser renovado","      from here. Restart Tor Browser yourself, or pick [1] WARP / [4] NONE.":"      daqui. Reinicie o Tor Browser voc\u00ea mesmo, ou escolha [1] WARP / [4] NONE.","  WARP proxy is not answering - cannot verify the exit IP.":"  O proxy do WARP n\u00e3o responde - n\u00e3o \u00e9 poss\u00edvel verificar o IP de sa\u00edda.","  same IP as the last run, requesting a new registration...":"  mesmo IP da \u00faltima vez, a pedir um registo novo...","  [%EN_TRIES%] dropping the old registration...":"  [%EN_TRIES%] a eliminar o registo anterior...","  [%EN_TRIES%] new registration...":"  [%EN_TRIES%] registo novo...","  [%EN_TRIES%] reconnecting WARP proxy...":"  [%EN_TRIES%] a religar o proxy do WARP...","  [%EN_TRIES%] waiting %WARP_WAIT%s...":"  [%EN_TRIES%] a aguardar %WARP_WAIT%s...","  exit IP: %CUR%":"  IP de sa\u00edda: %CUR%","  no new IP after %ROTATE_TRIES_MAX% tries, launching on the current one.":"  nenhum IP novo ap\u00f3s %ROTATE_TRIES_MAX% tentativas, a iniciar com o atual.","  [note] opencode log not found: \"%LOGFILE%\"":"  [note] registo do opencode n\u00e3o encontrado: \"%LOGFILE%\"","         auto-detect stays off until the log appears.":"         a dete\u00e7\u00e3o autom\u00e1tica fica desligada at\u00e9 o registo aparecer.","  OpenCode desktop update available: %DVER% -> %OCA_VER%":"  atualiza\u00e7\u00e3o da app de desktop do OpenCode dispon\u00edvel: %DVER% -> %OCA_VER%","  It closes every OpenCode process first, the app and its service included.":"  Fecha primeiro todos os processos do OpenCode, incluindo a app e o respetivo servi\u00e7o.","  downloading the OpenCode desktop installer %OCA_VER%, about 250 MB...":"  a transferir o instalador da app de desktop do OpenCode %OCA_VER%, cerca de 250 MB...","  [*] checksum mismatch - the download is not the official file.":"  [*] a soma de verifica\u00e7\u00e3o n\u00e3o coincide - a transfer\u00eancia n\u00e3o \u00e9 o ficheiro oficial.","  [*] download failed.":"  [*] a transfer\u00eancia falhou.","      grab it by hand and run it: %ID_URL%":"      transfira-o \u00e0 m\u00e3o e execute-o: %ID_URL%","      or from the website: https://opencode.ai/download":"      ou no site: https://opencode.ai/download","  installing, accept the UAC prompt if one appears...":"  a instalar, aceite o pedido do UAC se aparecer...","  [*] could not read the official release info from opencode.ai.":"  [*] n\u00e3o foi poss\u00edvel ler as informa\u00e7\u00f5es oficiais de vers\u00e3o em opencode.ai.","      get the installer by hand: https://opencode.ai/download":"      obtenha o instalador \u00e0 m\u00e3o: https://opencode.ai/download","  [*] the desktop app has no 32-bit Windows build.":"  [*] a app de desktop n\u00e3o tem vers\u00e3o para Windows de 32 bits.","[verify] egress: %EGRESS%":"[verify] sa\u00edda: %EGRESS%","[verify] ip=%IPN% warp=%WFLAG%":"[verify] ip=%IPN% warp=%WFLAG%","[verify] Cloudflare WARP is not installed (warp-cli not found).":"[verify] o Cloudflare WARP n\u00e3o est\u00e1 instalado (warp-cli n\u00e3o encontrado).","[renew] egress: %EGRESS%":"[renew] sa\u00edda: %EGRESS%","[renew] new exit IP: %IPN%":"[renew] novo IP de sa\u00edda: %IPN%","[renew] Cloudflare WARP is not installed (warp-cli not found).":"[renew] o Cloudflare WARP n\u00e3o est\u00e1 instalado (warp-cli n\u00e3o encontrado).","[renew] proxy: %ACTIVE_PROXY%":"[renew] proxy: %ACTIVE_PROXY%","[renew] done":"[renew] conclu\u00eddo","[renew] could not get a working connection":"[renew] n\u00e3o foi poss\u00edvel obter uma liga\u00e7\u00e3o que funcione","  archiving chats to:":"  a arquivar os chats em:","  nothing to archive.":"  nada para arquivar.","  archived.":"  arquivado.","  [*] could not move the storage folder - it stays where it is.":"  [*] n\u00e3o foi poss\u00edvel mover a pasta de armazenamento - fica onde est\u00e1.","  [*] could not copy %1 - it stays where it is.":"  [*] n\u00e3o foi poss\u00edvel copiar %1 - fica onde est\u00e1.","  [*] size mismatch on %1 - the bad copy is deleted, the original stays.":"  [*] o tamanho n\u00e3o coincide em %1 - a c\u00f3pia errada \u00e9 apagada, o original fica.","  cache and tokens cleared.":"  cache e tokens limpos.","  auth.json archived in \"%TARGET%\".":"  auth.json arquivado em \"%TARGET%\".","  [*] the auth.json copy did not verify - tokens are left in place.":"  [*] a c\u00f3pia do auth.json n\u00e3o foi verificada - os tokens ficam onde est\u00e3o.","  [*] could not copy auth.json - tokens are left in place.":"  [*] n\u00e3o foi poss\u00edvel copiar o auth.json - os tokens ficam onde est\u00e3o.","  [*] no archive folder for this reset - auth.json is left in place.":"  [*] n\u00e3o h\u00e1 pasta de arquivo para esta reposi\u00e7\u00e3o - o auth.json fica onde est\u00e1.","  [*] the WARP port answers SOCKS5 only, and OpenCode cannot use SOCKS.":"  [*] a porta do WARP s\u00f3 responde em SOCKS5, e o OpenCode n\u00e3o consegue usar SOCKS.","      WARP is up, but no usable HTTP proxy can be handed to it.":"      O WARP est\u00e1 ativo, mas n\u00e3o \u00e9 poss\u00edvel entregar ao OpenCode nenhum proxy HTTP utiliz\u00e1vel.","  [proxy] process-only: %ACTIVE_PROXY%":"  [proxy] s\u00f3 processo: %ACTIVE_PROXY%","  [proxy] reading the proxy list...":"  [proxy] a ler a lista de proxies...","  [proxy] %PCOUNT% proxies in the list":"  [proxy] %PCOUNT% proxies na lista","  [*] no proxies found in \"%PSRC%\"":"  [*] nenhum proxy encontrado em \"%PSRC%\"","  [*] no proxy passed the API check, but %TRACE_ONLY% did reach Cloudflare.":"  [*] nenhum proxy passou na verifica\u00e7\u00e3o da API, mas %TRACE_ONLY% chegou ao Cloudflare.","      PROXY_API_CHECK_URL may be wrong - see the settings block.":"      PROXY_API_CHECK_URL pode estar errado - veja o bloco de defini\u00e7\u00f5es.","  [proxy] live: %ACTIVE_PROXY%":"  [proxy] ativo: %ACTIVE_PROXY%","  [*] OpenCode-Infinite is already open in another window.":"  [*] OpenCode-Infinite j\u00e1 est\u00e1 aberto noutra janela.","  Exiting.":"  A sair.","  [upd] repo copy is %SU_RV%, older than %SU_LV% - keeping this one.":"  [upd] a c\u00f3pia do repo \u00e9 %SU_RV%, mais antiga que %SU_LV% - fica esta.","  [upd] launcher matches the repo, %SU_LV%.":"  [upd] o launcher corresponde ao repo, %SU_LV%.","  [upd] update found: local %SU_LV% - repo %SU_RV%":"  [upd] atualiza\u00e7\u00e3o encontrada: local %SU_LV% - repo %SU_RV%","  [upd] swapping in %SU_RV% - this window closes now.":"  [upd] a trocar por %SU_RV% - esta janela fecha agora.","  [upd] the swap could not be prepared - keeping %SU_LV%.":"  [upd] n\u00e3o foi poss\u00edvel preparar a troca - fica %SU_LV%.","        The downloaded copy is in \"%SU_TMP%\".":"        A c\u00f3pia transferida est\u00e1 em \"%SU_TMP%\".","  Press any key to close this window.":"  Prima uma tecla para fechar esta janela.","Automatic rotation":"Rota\u00e7\u00e3o autom\u00e1tica","On: a limit or a closed opencode gets a new IP and the chat resumes. Off: the menu decides.":"Ligada: um limite ou um opencode fechado obt\u00e9m um IP novo e o chat retoma. Desligada: decide o menu.","Target country":"Pa\u00eds alvo","Keep asking for IPs until one is in this country, e.g. DE. Empty = any new IP.":"Continuar a pedir IPs at\u00e9 um estar neste pa\u00eds, p. ex. DE. Vazio = qualquer IP novo.","Target IP prefix":"Prefixo de IP alvo","Keep asking until the IP starts with this, e.g. 104.28. Empty = not used.":"Continuar a pedir at\u00e9 o IP come\u00e7ar por isto, p. ex. 104.28. Vazio = n\u00e3o usado.","Max attempts per hunt":"M\u00e1ximo de tentativas por pesquisa","New IPs requested in one hunt. The hunt stops at this count.":"Novos IPs pedidos numa pesquisa. A pesquisa para neste n\u00famero.","Max minutes per hunt":"M\u00e1ximo de minutos por pesquisa","The hunt stops after this many minutes.":"A pesquisa para depois destes minutos.","Seconds between attempts":"Segundos entre tentativas","Pause between two attempts, so Cloudflare is not hit too fast.":"Pausa entre duas tentativas, para n\u00e3o sobrecarregar o Cloudflare.","Activity log":"Registo de atividade","Record what the launcher does in launcher.log so a problem can be diagnosed.":"Guarda o que o launcher faz em launcher.log para poder diagnosticar um problema.","Log size limit (KB)":"Limite de tamanho do registo (KB)","The log is cut to its newest part when it grows past this.":"O registo \u00e9 cortado para a parte mais recente quando passa deste tamanho.","Hide IPs in reports":"Ocultar IPs nos relat\u00f3rios","Public IP addresses are masked in the support report.":"Os endere\u00e7os IP p\u00fablicos s\u00e3o mascarados no relat\u00f3rio de suporte.","config.json could not be read; a copy was kept as config.json.broken and defaults are in use.":"N\u00e3o foi poss\u00edvel ler o config.json; foi guardada uma c\u00f3pia como config.json.broken e s\u00e3o usados os valores predefinidos.","Two letters, like DE or US. Empty = any country.":"Duas letras, como DE ou US. Vazio = qualquer pa\u00eds.","The start of an IPv4 address, like 104.28. Empty = any IP.":"O in\u00edcio de um endere\u00e7o IPv4, como 104.28. Vazio = qualquer IP.","Value: {0}":"Valor: {0}"," Back":" Voltar","Windows Terminal settings.json was not found.":"settings.json do Windows Terminal n\u00e3o encontrado.","settings.json was left untouched: the edit would not have kept it valid.":"O settings.json n\u00e3o foi alterado: a edi\u00e7\u00e3o n\u00e3o o deixaria v\u00e1lido.","Windows Terminal font put back as it was. Reopen the tab if it does not change.":"Tipo de letra do Windows Terminal reposto. Reabra o separador se n\u00e3o mudar.","Windows Terminal font set to ":"Tipo de letra do Windows Terminal definido para",". Backup of settings.json: ":". C\u00f3pia de seguran\u00e7a do settings.json:","The Windows font API could not be loaded.":"N\u00e3o foi poss\u00edvel carregar a API de tipos de letra do Windows.","This window does not allow changing the font from here.":"Esta janela n\u00e3o permite alterar o tipo de letra daqui.","The font was never changed, nothing to restore.":"O tipo de letra nunca foi alterado, nada para repor.","Windows refused that font in this console.":"O Windows recusou esse tipo de letra nesta consola.","This console refused \"":"Esta consola recusou \"","\" and kept \"":"\" e manteve \"","\". Older classic consoles only take the fonts Windows registers for them (":"\". As consolas cl\u00e1ssicas antigas s\u00f3 aceitam os tipos de letra que o Windows lhes regista (","). Windows Terminal accepts any installed font.":"). O Windows Terminal aceita qualquer tipo de letra instalado.","Console font set to ":"Tipo de letra da consola definido para",". It lasts while this window is open and is applied again at every launcher start.":". Dura enquanto esta janela estiver aberta e \u00e9 reaplicado em cada arranque do launcher.","This terminal keeps its font in its own settings (VS Code: terminal.integrated.fontFamily).":"Este terminal guarda o tipo de letra nas suas pr\u00f3prias defini\u00e7\u00f5es (VS Code: terminal.integrated.fontFamily).","Could not change the font: ":"N\u00e3o foi poss\u00edvel alterar o tipo de letra:"," The setting was not changed.":" A defini\u00e7\u00e3o n\u00e3o foi alterada.","Enter, arrows":"Enter, setas"," Connect with opencode":" Ligar ao opencode"," CLI":" CLI"," Desktop app":" App de desktop"," Exit":" Sair","There is no saved folder yet. Use one of the other options once.":"Ainda n\u00e3o h\u00e1 pasta guardada. Use uma das outras op\u00e7\u00f5es uma vez.","Cloudflare":"Cloudflare","bridge :":"ponte :","CLI / Desktop":"CLI / Desktop","Automatic (follow Windows)":"Autom\u00e1tico (segue o Windows)","Use the language Windows is set to on every start; English when there is no translation.":"Usa o idioma do Windows em cada arranque; ingl\u00eas quando n\u00e3o h\u00e1 tradu\u00e7\u00e3o."," (detected)":" (detetado)","Detected from Windows and selected. You can change it in Settings, Appearance.":"Detetado a partir do Windows e selecionado. Pode alterar em Defini\u00e7\u00f5es, Apar\u00eancia.","You can change it in Settings, Appearance.":"Pode alterar em Defini\u00e7\u00f5es, Apar\u00eancia.","Choose your language":"Escolha o seu idioma"," Launch OpenCode":" Iniciar OpenCode"," Renew session":" Renovar sess\u00e3o"," Uninstall":" Desinstalar"," Support report":" Relat\u00f3rio de suporte","not a url":"n\u00e3o \u00e9 um URL","Sessions":"Sess\u00f5es","Pick a chat from this folder and continue it. CLI only.":"Escolha um chat desta pasta e continue-o. S\u00f3 CLI.","The desktop app has no session list. Switch to CLI to pick a chat.":"A app de desktop n\u00e3o tem lista de sess\u00f5es. Mude para CLI para escolher um chat.","Could not read the sessions: {0}":"N\u00e3o foi poss\u00edvel ler as sess\u00f5es: {0}","No sessions in this folder yet.":"Ainda n\u00e3o h\u00e1 sess\u00f5es nesta pasta.","Untitled session":"Sess\u00e3o sem t\u00edtulo","Sessions in this folder":"Sess\u00f5es desta pasta","  [9] Sessions      - continue a chat from this folder":"  [9] Sess\u00f5es      - continuar um chat desta pasta","Change IP (test)":"Trocar IP (teste)","Clear tokens and cache, then start":"Limpar tokens e cache e iniciar","keeps chats":"mant\u00e9m os chats","Deep reset or restore chats":"Reset profundo ou restaurar chats","submenu":"submenu","Mode (CLI or Desktop)":"Modo (CLI ou Desktop)","New IP and start OpenCode":"Nova IP e iniciar o OpenCode","Kill opencode, save the login file to the Desktop, clear the cache, then open OpenCode. Chats stay where they are.":"Encerra o opencode, salva o arquivo de login na \u00c1rea de Trabalho, limpa o cache e abre o OpenCode. Os chats ficam onde est\u00e3o.","Rotate the connection only, without opening OpenCode.":"Troca s\u00f3 a conex\u00e3o, sem abrir o OpenCode.","Deep reset moves your chats to the Desktop and clears tokens and cache. Restore brings chats back from an earlier reset.":"O reset profundo move seus chats para a \u00c1rea de Trabalho e apaga tokens e cache. Restaurar traz de volta os chats de um reset anterior.","Move your chats to the Desktop archive, clear tokens and cache, then start fresh.":"Move seus chats para o arquivo da \u00c1rea de Trabalho, apaga tokens e cache e come\u00e7a do zero.","Restore chats":"Restaurar chats","from the Desktop":"da \u00c1rea de Trabalho","Bring chats back from an earlier deep reset.":"Traz de volta chats de um reset profundo anterior.","Return to the deep reset menu.":"Volta ao menu do reset profundo.","Return to the home screen.":"Volta \u00e0 tela inicial.","Restore chats from a backup":"Restaurar chats de um backup","No archived chats yet. A deep reset creates one on the Desktop.":"Ainda n\u00e3o h\u00e1 chats arquivados. Um reset profundo cria um na \u00c1rea de Trabalho.","{0} file":"{0} arquivo","{0} files":"{0} arquivos","Windows Terminal font size set to {0}. Reopen the tab if it does not change.":"Tamanho da fonte do Windows Terminal definido para {0}. Reabra a aba se n\u00e3o mudar.","Restore now?":"Restaurar agora?","  Nothing to restore in that backup.":"  Nada para restaurar nesse backup.","  Restore the chats from:":"  Restaurar os chats de:","  The chats in place now are moved to the Desktop first. Nothing is deleted.":"  Os chats atuais s\u00e3o movidos antes para a \u00c1rea de Trabalho. Nada \u00e9 apagado.","  [*] some storage files did not copy. The backup is untouched.":"  [*] alguns arquivos de armazenamento n\u00e3o foram copiados. O backup n\u00e3o foi alterado.","  Chats restored. The previous ones are in:":"  Chats restaurados. Os anteriores est\u00e3o em:"}
#>>>LANG tr {" move   Enter select   Esc back   1-9 or letter jump":" ta\u015f\u0131   Enter se\u00e7   Esc geri   1-9 veya harf ile atla","(Enter = keep \"{0}\")":"(Enter = \"{0}\" kals\u0131n)","(auto)":"(otomatik)","(nothing saved yet)":"(hen\u00fcz kay\u0131t yok)","(terminal default)":"(terminal varsay\u0131lan\u0131)","* = changed from the default. Enter edits or toggles the selected value.":"* = varsay\u0131landan de\u011fi\u015ftirildi. Enter se\u00e7ili de\u011feri d\u00fczenler ya da de\u011fi\u015ftirir.","A downloaded list smaller than this is rejected. 0 = off.":"Bundan k\u00fc\u00e7\u00fck indirilen liste reddedilir. 0 = kapal\u0131.","A port is a number from 1 to 65535.":"Ba\u011flant\u0131 noktas\u0131 1 ile 65535 aras\u0131nda bir say\u0131d\u0131r.","A proxy must also reach the opencode API host.":"Bir proxy ayr\u0131ca opencode API sunucusuna da ula\u015fmal\u0131d\u0131r.","API check URL":"API kontrol adresi","Accent colors of the interface.":"Aray\u00fcz\u00fcn vurgu renkleri.","Adding the command to your PATH":"Komut PATH'e ekleniyor","Adds: opencode command (shim), two shortcuts, one PATH entry. Backups are kept.":"Eklenir: opencode komutu (shim), iki k\u0131sayol, bir PATH girdisi. Yedekler saklan\u0131r.","Any installed font name, for example Cascadia Code.":"Y\u00fckl\u00fc herhangi bir yaz\u0131 tipi ad\u0131, \u00f6rne\u011fin Cascadia Code.","Appearance":"G\u00f6r\u00fcn\u00fcm","Applies at the {0}.":"{0} an\u0131nda uygulan\u0131r.","Apply":"Uygula","Apply setup":"Kurulumu uygula","Ask every time":"Her seferinde sor","Attempts per round when the tunnel is not up.":"T\u00fcnel a\u00e7\u0131k de\u011filse tur ba\u015f\u0131na deneme say\u0131s\u0131.","Back":"Geri","Backing up the current configuration":"Mevcut yap\u0131land\u0131rma yedekleniyor","Browse for a folder...":"Klas\u00f6r se\u00e7...","Burned IPs allowed":"Yak\u0131lan IP'lere izin verilen","Burned proxies before Tor offer":"Tor \u00f6nerisinden \u00f6nce yak\u0131lan proxy say\u0131s\u0131","Burned proxies in a row before PROXY mode offers Tor.":"PROXY modunun Tor \u00f6nermesi i\u00e7in art arda yak\u0131lmas\u0131 gereken proxy say\u0131s\u0131.","CLI terminal, Desktop app, or ask at every start.":"CLI terminali, Masa\u00fcst\u00fc uygulamas\u0131 veya her ba\u015flang\u0131\u00e7ta sor.","Cancel":"\u0130ptal","Cancel. Nothing is changed.":"\u0130ptal. Hi\u00e7bir \u015fey de\u011fi\u015fmedi.","Change IP":"IP de\u011fi\u015ftir","Change an answer.":"Bir yan\u0131t\u0131 de\u011fi\u015ftir.","Change any launcher setting: connection, proxies, Tor, rotation, themes, font. Applied right away.":"Ba\u015flat\u0131c\u0131n\u0131n her ayar\u0131n\u0131 de\u011fi\u015ftir: ba\u011flant\u0131, proxy'ler, Tor, rotasyon, temalar, yaz\u0131 tipi. Hemen uygulan\u0131r.","Check GitHub for a newer launcher at every start.":"Her ba\u015flang\u0131\u00e7ta GitHub'da daha yeni bir ba\u015flat\u0131c\u0131 olup olmad\u0131\u011f\u0131n\u0131 kontrol et.","Check the API host":"API sunucusunu kontrol et","Checking that it works":"\u00c7al\u0131\u015ft\u0131\u011f\u0131 kontrol ediliyor","Checking the connection":"Ba\u011flant\u0131 kontrol ediliyor","Choose \"Renew session\" below. It gets a new IP and clears the saved login;":"A\u015fa\u011f\u0131dan \"Oturumu yenile\"yi se\u00e7. Yeni bir IP al\u0131r ve kay\u0131tl\u0131 giri\u015fi temizler;","Choose a folder to work in":"\u00c7al\u0131\u015f\u0131lacak bir klas\u00f6r se\u00e7","Choose one of: {0}.":"\u015eunlardan birini se\u00e7: {0}.","Choose the connection for OpenCode":"OpenCode i\u00e7in ba\u011flant\u0131y\u0131 se\u00e7","Close the launcher.":"Ba\u015flat\u0131c\u0131y\u0131 kapat.","Closes every running opencode process.":"\u00c7al\u0131\u015fan t\u00fcm opencode s\u00fcre\u00e7lerini kapat\u0131r.","Cloudflare WARP in local proxy mode. Every rotation asks for a new registration, which gives a new exit IP. Needs the WARP client (offered if missing).":"Yerel proxy modunda Cloudflare WARP. Her rotasyon yeni bir kay\u0131t ister ve yeni bir \u00e7\u0131k\u0131\u015f IP'si verir. WARP istemcisi gerekir (yoksa \u00f6nerilir).","Cloudflare WARP in proxy mode. A new registration gives a new exit IP. Rotation supported.":"Proxy modunda Cloudflare WARP. Yeni bir kay\u0131t yeni bir \u00e7\u0131k\u0131\u015f IP'si verir. Rotasyon destekleniyor.","Cloudflare throttles rapid registrations.":"Cloudflare h\u0131zl\u0131 kay\u0131tlar\u0131 k\u0131s\u0131tlar.","Collect system info, versions, settings and the recent log into one text file you can send for help. Passwords, tokens, your user name and (by default) IPs are removed first.":"Sistem bilgisi, s\u00fcr\u00fcmler, ayarlar ve son g\u00fcnl\u00fc\u011f\u00fc yard\u0131m i\u00e7in g\u00f6nderebilece\u011fin tek bir metin dosyas\u0131nda topla. Parolalar, belirte\u00e7ler, kullan\u0131c\u0131 ad\u0131n ve (varsay\u0131lan olarak) IP'ler \u00f6nce silinir.","Color theme":"Renk temas\u0131","Color theme, colors on or off, icon and border style, and the terminal font. Applied immediately.":"Renk temas\u0131, renkler a\u00e7\u0131k veya kapal\u0131, simge ve kenarl\u0131k stili ve terminal yaz\u0131 tipi. Hemen uygulan\u0131r.","Colors":"Renkler","Command":"Komut","Configured - {0}":"Yap\u0131land\u0131r\u0131ld\u0131 - {0}","Confirm":"Onayla","Connect with opencode":"opencode ile ba\u011flan","Connected: opencode now starts through {0}.":"Ba\u011fland\u0131: opencode art\u0131k {0} \u00fczerinden ba\u015fl\u0131yor.","Connecting opencode":"opencode ba\u011flan\u0131yor","Connection":"Ba\u011flant\u0131","Connection method":"Ba\u011flant\u0131 y\u00f6ntemi","Continue":"Devam et","Continue WITHOUT the probe this session (IPs accepted untested)?":"Bu oturumda test OLMADAN devam edilsin mi (IP'ler test edilmeden kabul edilir)?","Continue anyway?":"Yine de devam edilsin mi?","Continue direct?":"Do\u011frudan devam edilsin mi?","Continue without WARP?":"WARP olmadan devam edilsin mi?","Cooldown between attempts (s)":"Denemeler aras\u0131 bekleme (sn)","Copies auth.json to your Desktop, then clears the saved tokens.":"auth.json dosyas\u0131n\u0131 Masa\u00fcst\u00fcne kopyalar, ard\u0131ndan kay\u0131tl\u0131 belirte\u00e7leri temizler.","Copy the file path":"Dosya yolunu kopyala","Creating shortcuts":"K\u0131sayollar olu\u015fturuluyor","Creating the opencode command":"opencode komutu olu\u015fturuluyor","Credentials inside a URL are not stored. Use a local file instead.":"Bir adresin i\u00e7indeki kimlik bilgileri kaydedilmez. Bunun yerine yerel bir dosya kullan.","Deep reset":"Derin s\u0131f\u0131rlama","Default connection method and run mode, the WARP proxy port and the warp-cli timings.":"Varsay\u0131lan ba\u011flant\u0131 y\u00f6ntemi ve \u00e7al\u0131\u015fma modu, WARP proxy ba\u011flant\u0131 noktas\u0131 ve warp-cli s\u00fcreleri.","Default: {0}.":"Varsay\u0131lan: {0}.","Desktop":"Masa\u00fcst\u00fc","Desktop app":"Masa\u00fcst\u00fc uygulamas\u0131","Desktop app location, release metadata URL and lookup timeouts.":"Masa\u00fcst\u00fc uygulamas\u0131n\u0131n konumu, s\u00fcr\u00fcm bilgisi adresi ve arama zaman a\u015f\u0131mlar\u0131.","Desktop app path":"Masa\u00fcst\u00fc uygulamas\u0131 yolu","Direct, no proxy":"Do\u011frudan, proxy yok","Do it now.":"\u015eimdi yap.","Do that now?":"\u015eimdi yap\u0131ls\u0131n m\u0131?","Download and install it now?":"\u015eimdi indirilip kurulsun mu?","Download the portable Tor bundle when nothing answers.":"Hi\u00e7bir \u015fey yan\u0131t vermedi\u011finde ta\u015f\u0131nabilir Tor paketini indir.","Egress":"\u00c7\u0131k\u0131\u015f","Egress used for opencode. ASK shows the picker at every start.":"opencode i\u00e7in kullan\u0131lan \u00e7\u0131k\u0131\u015f. ASK her ba\u015flang\u0131\u00e7ta se\u00e7iciyi g\u00f6sterir.","Enter a full URL (http, https, ftp or file).":"Tam bir adres gir (http, https, ftp veya file).","Enter a whole number.":"Tam say\u0131 gir.","Enter cycles: {0}.":"Enter ile d\u00f6n\u00fc\u015f\u00fcr: {0}.","Enter toggles it.":"Enter ile a\u00e7\u0131l\u0131p kapan\u0131r.","Every change is saved at once to {0}":"Her de\u011fi\u015fiklik hemen {0} dosyas\u0131na kaydedilir","Exit":"\u00c7\u0131k\u0131\u015f","Exit IP":"\u00c7\u0131k\u0131\u015f IP'si","Extra rounds (60 s apart) before giving up.":"Vazge\u00e7meden \u00f6nce ek turlar (60 sn arayla).","Folder":"Klas\u00f6r","Font name":"Yaz\u0131 tipi ad\u0131","Font of the terminal text. Empty leaves the terminal as it is.":"Terminal metninin yaz\u0131 tipi. Bo\u015f b\u0131rak\u0131l\u0131rsa terminal oldu\u011fu gibi kal\u0131r.","Font size":"Yaz\u0131 tipi boyutu","Free HTTP proxies from your list (any format) or the default one. Each is tested before use.":"Kendi listenden (herhangi bir bi\u00e7imde) veya varsay\u0131lan listeden \u00fccretsiz HTTP proxy'ler. Her biri kullan\u0131lmadan \u00f6nce test edilir.","Free or your own list":"\u00dccretsiz veya kendi listen","Fresh start":"Yeni ba\u015flang\u0131\u00e7","Full path of OpenCode.exe. Empty = search automatically.":"OpenCode.exe'nin tam yolu. Bo\u015f = otomatik ara.","Get a new IP or proxy, then open OpenCode. Your chats and history stay untouched.":"Yeni bir IP veya proxy al\u0131r, sonra OpenCode'u a\u00e7ar. Sohbetleriniz ve ge\u00e7mi\u015finiz de\u011fi\u015fmez.","Gets a new IP / WARP registration / Tor circuit / proxy.":"Yeni bir IP / WARP kayd\u0131 / Tor devresi / proxy al\u0131r.","Go ahead.":"Devam et.","Go back. Nothing is changed.":"Geri d\u00f6n. Hi\u00e7bir \u015fey de\u011fi\u015fmez.","Guided setup: choose WARP, Tor, a proxy list or direct, then get an \"opencode\" command and a shortcut that start with it. It is tested at the end.":"Y\u00f6nlendirmeli kurulum: WARP, Tor, bir proxy listesi veya do\u011frudan ba\u011flant\u0131 se\u00e7, ard\u0131ndan onunla ba\u015flayan bir \"opencode\" komutu ve bir k\u0131sayol al. Sonunda test edilir.","HTTP port of the built-in bridge opencode uses.":"opencode'un kulland\u0131\u011f\u0131 yerle\u015fik k\u00f6pr\u00fcn\u00fcn HTTP ba\u011flant\u0131 noktas\u0131.","Host used by the API check.":"API kontrol\u00fcnde kullan\u0131lan sunucu.","How do you want to run OpenCode?":"OpenCode'u nas\u0131l \u00e7al\u0131\u015ft\u0131rmak istersin?","How many proxies to test before giving up.":"Vazge\u00e7meden \u00f6nce ka\u00e7 proxy test edilsin.","How many times, and how fast, a new IP is requested when the free limit is hit.":"\u00dccretsiz limite ula\u015f\u0131ld\u0131\u011f\u0131nda yeni bir IP ka\u00e7 kez ve ne kadar h\u0131zl\u0131 istensin.","IPs the probe may reject before giving up. 0 = no limit.":"Vazge\u00e7meden \u00f6nce test'in reddedebilece\u011fi IP say\u0131s\u0131. 0 = s\u0131n\u0131r yok.","Icons and borders":"Simgeler ve kenarl\u0131klar","Install Tor automatically":"Tor'u otomatik kur","Keep the current connection and open OpenCode as it was.":"Mevcut ba\u011flant\u0131y\u0131 koru ve OpenCode'u eskisi gibi a\u00e7.","Keep the current font.":"Mevcut yaz\u0131 tipini koru.","Kill opencode and clear the saved tokens, keeping your chats where they are.":"opencode'u kapat ve kay\u0131tl\u0131 belirte\u00e7leri temizle; sohbetlerin oldu\u011fu yerde kal\u0131r.","Kill opencode, move your chats to the Desktop, clear the saved tokens and open a fresh session.":"opencode'u kapat, sohbetlerini Masa\u00fcst\u00fcne ta\u015f\u0131, kay\u0131tl\u0131 belirte\u00e7leri temizle ve yeni bir oturum a\u00e7.","Language":"Dil","Language of the menus and descriptions. auto follows Windows. Logs and the support report stay in English.":"Men\u00fclerin ve a\u00e7\u0131klamalar\u0131n dili. auto Windows'u izler. G\u00fcnl\u00fckler ve destek raporu \u0130ngilizce kal\u0131r.","Last check":"Son kontrol","Launch OpenCode":"OpenCode'u ba\u015flat","Launcher":"Ba\u015flat\u0131c\u0131","Launcher self-update":"Ba\u015flat\u0131c\u0131n\u0131n kendini g\u00fcncellemesi","Leave the setup without changing anything.":"Kurulumdan hi\u00e7bir \u015fey de\u011fi\u015ftirmeden \u00e7\u0131k.","Leave the terminal font as it is. If the launcher changed it, the original font comes back.":"Terminal yaz\u0131 tipini oldu\u011fu gibi b\u0131rak. Ba\u015flat\u0131c\u0131 de\u011fi\u015ftirdiyse, \u00f6zg\u00fcn yaz\u0131 tipi geri gelir.","Local Tor with a built-in HTTP bridge. A portable Tor is installed automatically if missing.":"Yerle\u015fik HTTP k\u00f6pr\u00fcl\u00fc yerel Tor. Yoksa ta\u015f\u0131nabilir bir Tor otomatik kurulur.","Local port of the WARP proxy.":"WARP proxy'sinin yerel ba\u011flant\u0131 noktas\u0131.","Logs":"G\u00fcnl\u00fckler","Main menu":"Ana men\u00fc","Method":"Y\u00f6ntem","Minimum list size (bytes)":"En k\u00fc\u00e7\u00fck liste boyutu (bayt)","Mode":"Mod","Model used by the IP probe.":"IP testinde kullan\u0131lan model.","Must be between {0} and {1}.":"{0} ile {1} aras\u0131nda olmal\u0131.","New IP and resume in 5s":"5 sn i\u00e7inde yeni IP ve devam","No":"Hay\u0131r","No .exe file exists at that path.":"Bu yolda bir .exe dosyas\u0131 yok.","No answer in {0}s counts as No.":"{0} sn i\u00e7inde yan\u0131t yoksa Hay\u0131r say\u0131l\u0131r.","No change.":"De\u011fi\u015fiklik yok.","No proxy: opencode uses your real connection and nothing is rotated.":"Proxy yok: opencode ger\u00e7ek ba\u011flant\u0131n\u0131 kullan\u0131r ve hi\u00e7bir \u015fey d\u00f6nd\u00fcr\u00fclmez.","No, cancel":"Hay\u0131r, iptal et","Non-limit probe failures before the hunt stops.":"Arama durmadan \u00f6nce s\u0131n\u0131r d\u0131\u015f\u0131 test hatalar\u0131.","Not a URL, and no file exists at that path.":"Bu bir adres de\u011fil ve bu yolda bir dosya yok.","Not configured":"Yap\u0131land\u0131r\u0131lmad\u0131","Nothing to ask for a direct connection.":"Do\u011frudan ba\u011flant\u0131 i\u00e7in sorulacak bir \u015fey yok.","Nothing was left half done that Uninstall cannot remove. Fix the problem and run setup again.":"Kald\u0131rma i\u015fleminin silemeyece\u011fi yar\u0131m kalm\u0131\u015f bir \u015fey yok. Sorunu d\u00fczelt ve kurulumu yeniden \u00e7al\u0131\u015ft\u0131r.","On PATH":"PATH'te","Only opencode uses it; the rest of the system stays direct.":"Yaln\u0131zca opencode kullan\u0131r; sistemin geri kalan\u0131 do\u011frudan ba\u011fl\u0131 kal\u0131r.","Open the Windows folder picker and choose where to work.":"Windows klas\u00f6r se\u00e7icisini a\u00e7 ve nerede \u00e7al\u0131\u015f\u0131laca\u011f\u0131n\u0131 se\u00e7.","Open the folder":"Klas\u00f6r\u00fc a\u00e7","Open the launcher menus: pick a folder and a connection method, then start the opencode CLI or the desktop app.":"Ba\u015flat\u0131c\u0131 men\u00fclerini a\u00e7: bir klas\u00f6r ve ba\u011flant\u0131 y\u00f6ntemi se\u00e7, sonra opencode CLI'yi veya masa\u00fcst\u00fc uygulamas\u0131n\u0131 ba\u015flat.","OpenCode app":"OpenCode uygulamas\u0131","PATH lookup timeout (s)":"PATH arama zaman a\u015f\u0131m\u0131 (sn)","Paths":"Yollar","Port {0} is already used by {1}.":"{0} ba\u011flant\u0131 noktas\u0131 zaten {1} taraf\u0131ndan kullan\u0131l\u0131yor.","Ports and install behavior of the portable Tor the launcher starts for you.":"Ba\u015flat\u0131c\u0131n\u0131n senin i\u00e7in ba\u015flatt\u0131\u011f\u0131 ta\u015f\u0131nabilir Tor'un ba\u011flant\u0131 noktalar\u0131 ve kurulum davran\u0131\u015f\u0131.","Press any key to continue...":"Devam etmek i\u00e7in bir tu\u015fa bas...","Probe":"Test","Probe failures tolerated":"Tolere edilen test hatalar\u0131","Probe model":"Test modeli","Proxies tried per pick":"Se\u00e7im ba\u015f\u0131na denenen proxy say\u0131s\u0131","Proxy":"Proxy","Proxy list":"Proxy listesi","Proxy list source":"Proxy listesi kayna\u011f\u0131","Proxy test timeout (s)":"Proxy test zaman a\u015f\u0131m\u0131 (sn)","Public HTTP proxies from a list (yours, in any format, or the free default). Each one is tested first and burned ones are skipped.":"Bir listeden genel HTTP proxy'ler (senin listen, herhangi bir bi\u00e7imde, veya \u00fccretsiz varsay\u0131lan). Her biri \u00f6nce test edilir ve yak\u0131lanlar atlan\u0131r.","Put every setting back to its default. Your connection setup (command, shortcuts) is not touched. Asks first.":"Her ayar\u0131 varsay\u0131lan\u0131na geri getir. Ba\u011flant\u0131 kurulumun (komut, k\u0131sayollar) de\u011fi\u015fmez. \u00d6nce sorar.","Put the full path on the clipboard.":"Tam yolu panoya koy.","Quotes and line breaks are not allowed.":"T\u0131rnak i\u015faretleri ve sat\u0131r sonlar\u0131 kullan\u0131lamaz.","Range {0} to {1}.":"Aral\u0131k {0} ile {1} aras\u0131.","Reconfigure (run setup again)":"Yeniden yap\u0131land\u0131r (kurulumu tekrar \u00e7al\u0131\u015ft\u0131r)","Release metadata URL":"S\u00fcr\u00fcm bilgisi adresi","Removes only what setup added: the opencode command, the shortcuts and the PATH entry.":"Yaln\u0131zca kurulumun eklediklerini kald\u0131r\u0131r: opencode komutu, k\u0131sayollar ve PATH girdisi.","Removes only what the setup added (command, shortcuts, PATH entry) and restores the settings it changed. Backups are kept. Asks first.":"Yaln\u0131zca kurulumun eklediklerini (komut, k\u0131sayollar, PATH girdisi) kald\u0131r\u0131r ve de\u011fi\u015ftirdi\u011fi ayarlar\u0131 geri y\u00fckler. Yedekler saklan\u0131r. \u00d6nce sorar.","Removing shortcuts":"K\u0131sayollar kald\u0131r\u0131l\u0131yor","Removing the opencode command":"opencode komutu kald\u0131r\u0131l\u0131yor","Renew did not finish (code {0}).":"Yenileme tamamlanmad\u0131 (kod {0}).","Renew session":"Oturumu yenile","Renew the session?":"Oturum yenilensin mi?","Renewed. Open opencode again; you may need to log in once more.":"Yenilendi. opencode'u yeniden a\u00e7; bir kez daha giri\u015f yapman gerekebilir.","Renewing":"Yenileniyor","Renewing the session":"Oturum yenileniyor","Reopen the last folder":"Son klas\u00f6r\u00fc yeniden a\u00e7","Report ready. Personal data was removed; read it once before you share it.":"Rapor haz\u0131r. Ki\u015fisel veriler silindi; payla\u015fmadan \u00f6nce bir kez oku.","Repository":"Depo","Reset every setting to its default?":"Her ayar varsay\u0131lan\u0131na s\u0131f\u0131rlans\u0131n m\u0131?","Reset to default values":"Varsay\u0131lan de\u011ferlere s\u0131f\u0131rla","Restores the settings setup changed. Your other settings and your opencode files are kept.":"Kurulumun de\u011fi\u015ftirdi\u011fi ayarlar\u0131 geri y\u00fckler. Di\u011fer ayarlar\u0131n ve opencode dosyalar\u0131n korunur.","Restoring PATH":"PATH geri y\u00fckleniyor","Restoring settings":"Ayarlar geri y\u00fckleniyor","Resume message":"Devam mesaj\u0131","Resume timeout (s)":"Devam zaman a\u015f\u0131m\u0131 (sn)","Return to the connection details.":"Ba\u011flant\u0131 ayr\u0131nt\u0131lar\u0131na d\u00f6n.","Return to the main menu.":"Ana men\u00fcye d\u00f6n.","Return to the settings groups.":"Ayar gruplar\u0131na d\u00f6n.","Review":"G\u00f6zden ge\u00e7ir","Rotate the connection only (new WARP registration, Tor circuit or proxy) without opening OpenCode.":"OpenCode'u a\u00e7madan yaln\u0131zca ba\u011flant\u0131y\u0131 de\u011fi\u015ftir (yeni WARP kayd\u0131, Tor devresi veya proxy).","Rotate when a fatal error appears while opencode runs.":"opencode \u00e7al\u0131\u015f\u0131rken \u00f6l\u00fcmc\u00fcl bir hata \u00e7\u0131kt\u0131\u011f\u0131nda d\u00f6nd\u00fcr.","Rotation":"Rotasyon","Rotation attempts":"Rotasyon denemeleri","Rotation rounds":"Rotasyon turlar\u0131","Run mode":"\u00c7al\u0131\u015fma modu","Run opencode in this terminal. After a new IP the chat resumes by itself.":"opencode'u bu terminalde \u00e7al\u0131\u015ft\u0131r. Yeni bir IP'den sonra sohbet kendili\u011finden devam eder.","Run the OpenCode desktop app ({0}). It is restarted after every new IP.":"OpenCode masa\u00fcst\u00fc uygulamas\u0131n\u0131 \u00e7al\u0131\u015ft\u0131r ({0}). Her yeni IP'den sonra yeniden ba\u015flat\u0131l\u0131r.","Run the setup again to change the method or repair the opencode command.":"Y\u00f6ntemi de\u011fi\u015ftirmek veya opencode komutunu onarmak i\u00e7in kurulumu tekrar \u00e7al\u0131\u015ft\u0131r.","SOCKS port of the Tor the launcher starts.":"Ba\u015flat\u0131c\u0131n\u0131n ba\u015flatt\u0131\u011f\u0131 Tor'un SOCKS ba\u011flant\u0131 noktas\u0131.","Save the settings, create the opencode command, the shortcuts and the PATH entry, then test the connection.":"Ayarlar\u0131 kaydet, opencode komutunu, k\u0131sayollar\u0131 ve PATH girdisini olu\u015ftur, sonra ba\u011flant\u0131y\u0131 test et.","Saved: {0} = {1}":"Kaydedildi: {0} = {1}","Saving config.json":"config.json kaydediliyor","Seconds a single \"where\" lookup may take.":"Tek bir \"where\" aramas\u0131n\u0131n alabilece\u011fi saniye.","Seconds a single proxy test may take.":"Tek bir proxy testinin alabilece\u011fi saniye.","Seconds a single warp-cli call may take.":"Tek bir warp-cli \u00e7a\u011fr\u0131s\u0131n\u0131n alabilece\u011fi saniye.","Seconds before a silent resume counts as a dead IP.":"Sessiz bir devam\u0131n \u00f6l\u00fc IP say\u0131lmas\u0131 i\u00e7in ge\u00e7ecek saniye.","Seconds to wait after (re)connecting WARP.":"WARP yeniden ba\u011fland\u0131ktan sonra beklenecek saniye.","Seconds to wait for Tor to finish bootstrapping.":"Tor'un ba\u015flat\u0131lmas\u0131n\u0131n tamamlanmas\u0131 i\u00e7in beklenecek saniye.","See what the setup installed (command, shortcuts, PATH) and run it again to change the method.":"Kurulumun neleri y\u00fckledi\u011fine bak (komut, k\u0131sayollar, PATH) ve y\u00f6ntemi de\u011fi\u015ftirmek i\u00e7in yeniden \u00e7al\u0131\u015ft\u0131r.","Send one cheap message through each candidate IP.":"Her aday IP \u00fczerinden tek ve ucuz bir mesaj g\u00f6nder.","Sent automatically after a rotation.":"Bir rotasyondan sonra otomatik g\u00f6nderilir.","Settings":"Ayarlar","Settings and setup":"Ayarlar ve kurulum","Setup 1/3 - connection method":"Kurulum 1/3 - ba\u011flant\u0131 y\u00f6ntemi","Setup 2/3 - details":"Kurulum 2/3 - ayr\u0131nt\u0131lar","Setup 3/3 - run mode":"Kurulum 3/3 - \u00e7al\u0131\u015fma modu","Setup stopped: {0}":"Kurulum durduruldu: {0}","Shortcuts":"K\u0131sayollar","Show the CLI or Desktop choice every time the launcher opens.":"Ba\u015flat\u0131c\u0131 her a\u00e7\u0131ld\u0131\u011f\u0131nda CLI veya Masa\u00fcst\u00fc se\u00e7imini g\u00f6ster.","Show the report in Explorer so you can attach or paste it.":"Raporu Gezgin'de g\u00f6ster; ekleyebilmen veya yap\u0131\u015ft\u0131rabilmen i\u00e7in.","Size used with the chosen font.":"Se\u00e7ilen yaz\u0131 tipiyle kullan\u0131lan boyut.","Support":"Destek","Support report":"Destek raporu","Switch between the terminal and the desktop app.":"Terminal ile masa\u00fcst\u00fc uygulamas\u0131 aras\u0131nda ge\u00e7i\u015f yap.","Switch to Tor and keep going?":"Tor'a ge\u00e7ilip devam edilsin mi?","System":"Sistem","Takes effect at the {0}; a service already running keeps the old value until then.":"{0} an\u0131nda etkili olur; zaten \u00e7al\u0131\u015fan bir hizmet o zamana kadar eski de\u011feri korur.","Terminal font":"Terminal yaz\u0131 tipi","Test every new IP":"Her yeni IP'yi test et","The OpenCode desktop app was not found. Choosing this offers to download and install it.":"OpenCode masa\u00fcst\u00fc uygulamas\u0131 bulunamad\u0131. Bunu se\u00e7ersen indirip kurmay\u0131 \u00f6nerir.","The OpenCode desktop app; it is restarted after every new IP.":"OpenCode masa\u00fcst\u00fc uygulamas\u0131; her yeni IP'den sonra yeniden ba\u015flat\u0131l\u0131r.","The activity log (launcher.log) and the support report: what is recorded, how big it may grow, whether IPs are masked.":"Etkinlik g\u00fcnl\u00fc\u011f\u00fc (launcher.log) ve destek raporu: neyin kaydedildi\u011fi, ne kadar b\u00fcy\u00fcyebilece\u011fi, IP'lerin maskelenip maskelenmedi\u011fi.","The cheap test message sent through every new IP before it is trusted.":"G\u00fcvenilmeden \u00f6nce her yeni IP \u00fczerinden g\u00f6nderilen ucuz test mesaj\u0131.","The check failed (code {0}). Setup is saved; fix the cause and use Renew or Connect again.":"Kontrol ba\u015far\u0131s\u0131z oldu (kod {0}). Kurulum kaydedildi; nedeni d\u00fczelt ve Yenile ya da Ba\u011flan'\u0131 yeniden kullan.","The font applies to the whole terminal window, not only to this launcher.":"Yaz\u0131 tipi yaln\u0131zca bu ba\u015flat\u0131c\u0131ya de\u011fil, t\u00fcm terminal penceresine uygulan\u0131r.","The proxy lives only in the opencode process; the rest of the system stays direct.":"Proxy yaln\u0131zca opencode s\u00fcrecinde ya\u015far; sistemin geri kalan\u0131 do\u011frudan ba\u011fl\u0131 kal\u0131r.","The resume auto-approves tool permissions.":"Devam, ara\u00e7 izinlerini otomatik onaylar.","The shortcut and the opencode command use the CLI; this is the launcher menu default.":"K\u0131sayol ve opencode komutu CLI'yi kullan\u0131r; ba\u015flat\u0131c\u0131 men\u00fcs\u00fcn\u00fcn varsay\u0131lan\u0131 budur.","The terminal interface. The opencode command and the shortcut always use it.":"Terminal aray\u00fcz\u00fc. opencode komutu ve k\u0131sayol her zaman bunu kullan\u0131r.","This launcher is not the one that set it up. Reconfigure to repair the command.":"Bu ba\u015flat\u0131c\u0131 kurulumu yapan de\u011fil. Komutu onarmak i\u00e7in yeniden yap\u0131land\u0131r.","Token reset":"Belirte\u00e7 s\u0131f\u0131rlama","Tools and versions":"Ara\u00e7lar ve s\u00fcr\u00fcmler","Tor HTTP bridge port":"Tor HTTP k\u00f6pr\u00fc ba\u011flant\u0131 noktas\u0131","Tor SOCKS port":"Tor SOCKS ba\u011flant\u0131 noktas\u0131","Tor bootstrap wait (s)":"Tor ba\u015flatma beklemesi (sn)","Tor is downloaded once, run hidden and offered to opencode through a built-in HTTP bridge. Slower, but a new circuit is a new IP.":"Tor bir kez indirilir, gizli \u00e7al\u0131\u015ft\u0131r\u0131l\u0131r ve yerle\u015fik bir HTTP k\u00f6pr\u00fcs\u00fc \u00fczerinden opencode'a sunulur. Daha yava\u015ft\u0131r, ama yeni bir devre yeni bir IP demektir.","Try again in a minute, or pick another connection method in Connect with opencode.":"Bir dakika sonra tekrar dene veya opencode ile ba\u011flan'da ba\u015fka bir ba\u011flant\u0131 y\u00f6ntemi se\u00e7.","Try again?":"Tekrar denensin mi?","Try to download and install WARP now?":"WARP \u015fimdi indirilip kurulmaya \u00e7al\u0131\u015f\u0131ls\u0131n m\u0131?","Type \"opencode\" in a NEW terminal, or use the \"OpenCode Infinite (egress)\" shortcut.":"YEN\u0130 bir terminalde \"opencode\" yaz veya \"OpenCode Infinite (egress)\" k\u0131sayolunu kullan.","Type < to go back. Enter keeps the value shown.":"Geri d\u00f6nmek i\u00e7in < yaz. Enter g\u00f6sterilen de\u011feri korur.","Type a font name...":"Bir yaz\u0131 tipi ad\u0131 yaz...","URL or local file, any format (plain, CSV, JSON, XML, HTML).":"Adres veya yerel dosya, herhangi bir bi\u00e7imde (d\u00fcz metin, CSV, JSON, XML, HTML).","Unattended resume":"G\u00f6zetimsiz devam","Uninstall":"Kald\u0131r","Uninstall stopped: {0}":"Kald\u0131rma durduruldu: {0}","Uninstall the opencode connection?":"opencode ba\u011flant\u0131s\u0131 kald\u0131r\u0131ls\u0131n m\u0131?","Uninstalled. Backups stay in {0}":"Kald\u0131r\u0131ld\u0131. Yedekler \u015furada kal\u0131r: {0}","Uninstalling":"Kald\u0131r\u0131l\u0131yor","Update now?":"\u015eimdi g\u00fcncellensin mi?","Updates":"G\u00fcncellemeler","Use 1 to 200 characters.":"1 ile 200 karakter kullan.","Use it when the free limit is hit or the login expired: closes opencode, saves and clears the saved tokens, and gets a new IP, WARP registration, Tor circuit or proxy.":"\u00dccretsiz limite ula\u015f\u0131ld\u0131\u011f\u0131nda veya giri\u015fin s\u00fcresi doldu\u011funda kullan: opencode'u kapat\u0131r, kay\u0131tl\u0131 belirte\u00e7leri kaydedip temizler ve yeni bir IP, WARP kayd\u0131, Tor devresi veya proxy al\u0131r.","Use on or off.":"A\u00e7\u0131k veya kapal\u0131 kullan.","Use that proxy anyway?":"Yine de bu proxy kullan\u0131ls\u0131n m\u0131?","Use this folder":"Bu klas\u00f6r\u00fc kullan","Use up to 31 characters, without quotes or backslashes.":"En fazla 31 karakter kullan; t\u0131rnak veya ters e\u011fik \u00e7izgi olmadan.","Use {0} for the terminal text. Monospaced fonts only look right.":"Terminal metni i\u00e7in {0} kullan. Yaln\u0131zca sabit geni\u015flikli yaz\u0131 tipleri do\u011fru g\u00f6r\u00fcn\u00fcr.","Version":"S\u00fcr\u00fcm","View and change every launcher option: connection, proxies, Tor, rotation, themes. Saved instantly, no files to edit.":"Ba\u015flat\u0131c\u0131n\u0131n her se\u00e7ene\u011fini g\u00f6r\u00fcnt\u00fcle ve de\u011fi\u015ftir: ba\u011flant\u0131, proxy'ler, Tor, rotasyon, temalar. An\u0131nda kaydedilir, d\u00fczenlenecek dosya yok.","WARP proxy port":"WARP proxy ba\u011flant\u0131 noktas\u0131","WARP wait (s)":"WARP bekleme (sn)","Watch the log":"G\u00fcnl\u00fc\u011f\u00fc izle","Watcher":"\u0130zleyici","Watching the opencode log and the automatic \"continue\" sent after a rotation.":"opencode g\u00fcnl\u00fc\u011f\u00fcn\u00fc ve bir rotasyondan sonra g\u00f6nderilen otomatik \"continue\" mesaj\u0131n\u0131 izler.","Where proxies come from (URL or file, any format) and how each one is tested.":"Proxy'lerin nereden geldi\u011fi (adres veya dosya, herhangi bir bi\u00e7imde) ve her birinin nas\u0131l test edildi\u011fi.","Where versions and checksums are read from.":"S\u00fcr\u00fcmlerin ve sa\u011flama toplamlar\u0131n\u0131n nereden okundu\u011fu.","Whether the launcher checks GitHub for a newer copy of itself at every start.":"Ba\u015flat\u0131c\u0131n\u0131n her ba\u015flang\u0131\u00e7ta GitHub'da kendisinin daha yeni bir kopyas\u0131 olup olmad\u0131\u011f\u0131n\u0131 kontrol edip etmedi\u011fi.","Work in a different folder.":"Farkl\u0131 bir klas\u00f6rde \u00e7al\u0131\u015f.","Work in the folder the launcher was started from: {0}":"Ba\u015flat\u0131c\u0131n\u0131n a\u00e7\u0131ld\u0131\u011f\u0131 klas\u00f6rde \u00e7al\u0131\u015f: {0}","Work in {0}":"{0} klas\u00f6r\u00fcnde \u00e7al\u0131\u015f","Writing the report":"Rapor yaz\u0131l\u0131yor","Yes":"Evet","Yes, continue":"Evet, devam et","Your connection setup (shim, shortcuts) is not touched.":"Ba\u011flant\u0131 kurulumun (shim, k\u0131sayollar) de\u011fi\u015fmez.","Your session needs renewing: {0}":"Oturumunun yenilenmesi gerekiyor: {0}","asks first":"\u00f6nce sorar","auto":"otomatik","auto follows the terminal and NO_COLOR; off disables colors.":"auto terminali ve NO_COLOR'u izler; off renkleri kapat\u0131r.","direct":"do\u011frudan","emoji = modern terminals, unicode = classic console, ascii = anything.":"emoji = modern terminaller, unicode = klasik konsol, ascii = her \u015fey.","free list":"\u00fccretsiz liste","installed":"kurulu","missing":"eksik","new IP":"yeni IP","next Tor start":"bir sonraki Tor ba\u015flatmas\u0131","next WARP connect":"bir sonraki WARP ba\u011flant\u0131s\u0131","next launch":"bir sonraki ba\u015flatma","no other step is needed.":"ba\u015fka bir ad\u0131m gerekmez.","not installed":"kurulu de\u011fil","not verified":"do\u011frulanmad\u0131","off":"kapal\u0131","on":"a\u00e7\u0131k","same IP":"ayn\u0131 IP","terminal":"terminal","warp-cli timeout (s)":"warp-cli zaman a\u015f\u0131m\u0131 (sn)","yes":"evet","{0} changed":"{0} de\u011fi\u015fti","{0} of {1}":"{0} / {1}","After opencode closes":"opencode kapand\u0131\u011f\u0131nda","ask = R, M or Q: R gets a new IP and resumes the chat, M opens the menu, Q quits. quit = leave the launcher at once.":"ask = R, M veya Q: R yeni bir IP al\u0131r ve sohbeti s\u00fcrd\u00fcr\u00fcr, M men\u00fcy\u00fc a\u00e7ar, Q \u00e7\u0131kar. quit = ba\u015flat\u0131c\u0131dan hemen \u00e7\u0131k.","Rotate key":"D\u00f6nd\u00fcrme tu\u015fu","Menu key":"Men\u00fc tu\u015fu","Quit key":"\u00c7\u0131k\u0131\u015f tu\u015fu","Closed-opencode prompt: new IP and resume the chat.":"opencode kapan\u0131nca sorulur: yeni IP ve sohbete devam.","Closed-opencode prompt: open the menu.":"Kapan\u0131\u015f sorusu: men\u00fcy\u00fc a\u00e7.","Closed-opencode prompt: quit. Ctrl+C always quits too.":"Kapan\u0131\u015f sorusu: \u00e7\u0131k. Ctrl+C her zaman \u00e7\u0131kar.","The keys of the launcher and the terminal commands. Fixed keys are listed for reference; the three letters can be changed.":"Ba\u015flat\u0131c\u0131n\u0131n tu\u015flar\u0131 ve terminal komutlar\u0131. Sabit tu\u015flar bilgi i\u00e7in g\u00f6sterilir; \u00fc\u00e7 harf de\u011fi\u015ftirilebilir.","One letter, like R.":"Tek harf, \u00f6rne\u011fin R.","Key {0} is already used by {1}.":"{0} tu\u015fu zaten {1} taraf\u0131ndan kullan\u0131l\u0131yor.","Only the chosen language is downloaded from the langs folder of the repository.":"Depodaki langs klas\u00f6r\u00fcnden yaln\u0131zca se\u00e7ilen dil indirilir.","Follow the language Windows uses.":"Windows dilini izler.","Use this language for every menu and message.":"T\u00fcm men\u00fc ve iletiler i\u00e7in bu dili kullan.","Keep the current language.":"Mevcut dili koru.","File to write (Enter = Desktop, Esc = back)":"Yaz\u0131lacak dosya (Enter = Masa\u00fcst\u00fc, Esc = geri)","File to read (Esc = back)":"Okunacak dosya (Esc = geri)","That folder does not exist.":"Bu klas\u00f6r yok.","Replace the file that is already there?":"Var olan dosya de\u011fi\u015ftirilsin mi?","Exported {0} changed setting(s) to {1}":"{0} de\u011fi\u015ftirilmi\u015f ayar {1} dosyas\u0131na aktar\u0131ld\u0131","Import {0} setting(s)? Their current values are replaced.":"{0} ayar i\u00e7e aktar\u0131ls\u0131n m\u0131? Mevcut de\u011ferleri de\u011fi\u015ftirilecek.","{0} setting(s) of this file are unknown here and are skipped.":"Bu dosyadaki {0} ayar burada tan\u0131nm\u0131yor ve atlanacak.","No file at that path.":"Bu yolda dosya yok.","This is not an OpenCode Infinite settings file.":"Bu dosya bir OpenCode Infinite ayar dosyas\u0131 de\u011fil.","Nothing was imported. These values are not valid:":"Hi\u00e7bir \u015fey i\u00e7e aktar\u0131lmad\u0131. Bu de\u011ferler ge\u00e7ersiz:","Imported {0} setting(s).":"{0} ayar i\u00e7e aktar\u0131ld\u0131.","Export settings to a file":"Ayarlar\u0131 bir dosyaya aktar","Save every changed setting to one .json file, to keep a backup or copy them to another PC.":"De\u011fi\u015ftirilmi\u015f t\u00fcm ayarlar\u0131 bir .json dosyas\u0131na yazar; yedek veya ba\u015fka bir bilgisayar i\u00e7in.","Import settings from a file":"Ayarlar\u0131 bir dosyadan i\u00e7e aktar","Load a file made by Export. Every value is checked first; if one is wrong, nothing changes.":"D\u0131\u015fa aktar ile yap\u0131lm\u0131\u015f bir dosyay\u0131 y\u00fckler. \u00d6nce her de\u011fer denetlenir; biri yanl\u0131\u015fsa hi\u00e7bir \u015fey de\u011fi\u015fmez.","back to the previous screen":"\u00f6nceki ekrana d\u00f6n","Fixed. In a menu or a text prompt Esc goes back; it never closes the launcher.":"Sabit. Men\u00fcde veya metin alan\u0131nda Esc geri d\u00f6ner; ba\u015flat\u0131c\u0131y\u0131 asla kapatmaz.","select and move":"se\u00e7 ve hareket et","Fixed. Digits 1-9 jump straight to a row.":"Sabit. 1-9 rakamlar\u0131 do\u011frudan bir sat\u0131ra gider.","quit the launcher":"ba\u015flat\u0131c\u0131dan \u00e7\u0131k","Fixed. Stops the processes it started and leaves the terminal open, no Y/N question.":"Sabit. Ba\u015flatt\u0131\u011f\u0131 s\u00fcre\u00e7leri durdurur, terminali a\u00e7\u0131k b\u0131rak\u0131r; E/H sorusu sormaz.","start with the connection":"ba\u011flant\u0131yla ba\u015flat","Terminal command from any folder. The Start menu shortcut does the same.":"Her klas\u00f6rden terminal komutu. Ba\u015flat men\u00fcs\u00fcndeki k\u0131sayol da ayn\u0131s\u0131n\u0131 yapar.","open this menu":"bu men\u00fcy\u00fc a\u00e7","Terminal command: opens the launcher menu again, as many times as you need.":"Terminal komutu: ba\u015flat\u0131c\u0131 men\u00fcs\u00fcn\u00fc istedi\u011fin kadar tekrar a\u00e7ar.","original OpenCode":"\u00d6zg\u00fcn OpenCode","Terminal command: starts the OpenCode you installed, without the launcher or the connection. Use it when the launcher breaks.":"Terminal komutu: kurulu OpenCode'u ba\u015flat\u0131c\u0131 ve ba\u011flant\u0131 olmadan a\u00e7ar. Ba\u015flat\u0131c\u0131 bozulursa kullan.","Commands":"Komutlar","Adds: the opencode, opencodeinf and opencodeoc commands, two shortcuts, one PATH entry. Backups are kept.":"opencode, opencodeinf ve opencodeoc komutlar\u0131n\u0131, iki k\u0131sayolu ve bir PATH girdisini ekler. Yedekler saklan\u0131r.","  This copy is not the official one. Starting the official copy:":"  Bu kopya resmi olan de\u011fil. Resmi kopya ba\u015flat\u0131l\u0131yor:","  OpenCode - how do you want to run it?":"  OpenCode - nas\u0131l \u00e7al\u0131\u015ft\u0131rmak istersiniz?","  [1] CLI      - terminal TUI (chat resumes on every new IP)":"  [1] CLI      - terminal TUI (sohbet her yeni IP'de devam eder)","  [2] Desktop  - the OpenCode desktop app (restarted on every new IP)":"  [2] Desktop  - OpenCode masa\u00fcst\u00fc uygulamas\u0131 (her yeni IP'de yeniden ba\u015flat\u0131l\u0131r)","  [3] Exit":"  [3] \u00c7\u0131k\u0131\u015f","  One key, no Enter.":"  Bir tu\u015f, Enter gerekmez.","%C_WARN%  [*] OpenCode desktop not found.%C_RST%":"%C_WARN%  [*] OpenCode masa\u00fcst\u00fc uygulamas\u0131 bulunamad\u0131.%C_RST%","%C_WARN%  [*] still not found - set OC_APP to its OpenCode.exe.%C_RST%":"%C_WARN%  [*] H\u00e2l\u00e2 bulunamad\u0131 - OC_APP de\u011ferini OpenCode.exe yoluna ayarlay\u0131n.%C_RST%","  [app] DESKTOP \"%OC_DESKTOP%\"":"  [app] DESKTOP \"%OC_DESKTOP%\"","  OpenCode - choose a folder to work in":"  OpenCode - \u00e7al\u0131\u015fmak i\u00e7in bir klas\u00f6r se\u00e7in","  [1] Reopen the last folder":"  [1] Son klas\u00f6r\u00fc yeniden a\u00e7","      (nothing saved yet)":"      (hen\u00fcz kay\u0131tl\u0131 bir \u015fey yok)","  [2] Use this folder":"  [2] Bu klas\u00f6r\u00fc kullan","  [3] Browse for a folder...":"  [3] Klas\u00f6re g\u00f6z at...","  [4] Exit":"  [4] \u00c7\u0131k\u0131\u015f","  No folder saved yet. Use [2] or [3] this time.":"  Hen\u00fcz kay\u0131tl\u0131 klas\u00f6r yok. Bu sefer [2] veya [3] kullan\u0131n.","  Choose a folder in the dialog...":"  \u0130leti\u015fim kutusunda bir klas\u00f6r se\u00e7in...","  Opening the classic folder picker...":"  Klasik klas\u00f6r se\u00e7ici a\u00e7\u0131l\u0131yor...","  No folder selected.":"  Klas\u00f6r se\u00e7ilmedi.","  Folder not found: \"%OPFOLDER%\"":"  Klas\u00f6r bulunamad\u0131: \"%OPFOLDER%\"","  Cannot enter: \"%OPFOLDER%\"":"  Girilemiyor: \"%OPFOLDER%\"","  Working in: \"%CD%\"":"  \u00c7al\u0131\u015f\u0131lan klas\u00f6r: \"%CD%\"","  [egress] %EGRESS% (from your settings)":"  [egress] %EGRESS% (ayarlar\u0131n\u0131zdan)","  Choose egress for OpenCode only (system traffic stays direct)":"  Yaln\u0131zca OpenCode i\u00e7in \u00e7\u0131k\u0131\u015f se\u00e7in (sistem trafi\u011fi do\u011frudan kal\u0131r)","  [1] WARP     - Cloudflare WARP proxy mode (rotation supported)":"  [1] WARP     - Cloudflare WARP proxy modu (d\u00f6nd\u00fcrme destekli)","  [2] TOR      - local Tor + built-in bridge on :%TOR_HTTP_PORT%":"  [2] TOR      - yerel Tor + :%TOR_HTTP_PORT% \u00fczerinde yerle\u015fik k\u00f6pr\u00fc","                 (auto-installs a portable Tor, nothing to set up)":"                 (ta\u015f\u0131nabilir Tor otomatik kurulur, ayarlanacak bir \u015fey yok)","  [3] PROXY    - free HTTP proxies (ProxyScrape list)":"  [3] PROXY    - \u00fccretsiz HTTP proxy'leri (ProxyScrape listesi)","  [4] NONE     - direct, no proxy":"  [4] NONE     - do\u011frudan, proxy yok","  [egress] NONE - direct.":"  [egress] NONE - do\u011frudan.","  [egress] PROXY - free HTTP list.":"  [egress] PROXY - \u00fccretsiz HTTP listesi.","  [egress] TOR - portable Tor + built-in bridge on :%TOR_HTTP_PORT%, auto-setup.":"  [egress] TOR - ta\u015f\u0131nabilir Tor + :%TOR_HTTP_PORT% \u00fczerinde yerle\u015fik k\u00f6pr\u00fc, otomatik kurulum.","  [egress] WARP.":"  [egress] WARP.","  [dep] curl":"  [dep] curl","  [dep] warp":"  [dep] warp","%C_WARN%  [*] Cloudflare WARP not found - IP rotation will be disabled.%C_RST%":"%C_WARN%  [*] Cloudflare WARP bulunamad\u0131 - IP d\u00f6nd\u00fcrme devre d\u0131\u015f\u0131 b\u0131rak\u0131lacak.%C_RST%","      Install it later from 1.1.1.1 if you want the rotation.":"      D\u00f6nd\u00fcrme istiyorsan\u0131z daha sonra 1.1.1.1 \u00fczerinden kurun.","%C_WARN%  [*] WARP still not available - continuing without rotation.%C_RST%":"%C_WARN%  [*] WARP h\u00e2l\u00e2 kullan\u0131lam\u0131yor - d\u00f6nd\u00fcrme olmadan devam ediliyor.%C_RST%","      warp-cli errors, if any, are in %STATE_DIR%\\wcli.log":"      Varsa warp-cli hatalar\u0131 %STATE_DIR%\\wcli.log dosyas\u0131nda.","%C_WARN%  [*] Cloudflare WARP publishes 64-bit Windows builds only.%C_RST%":"%C_WARN%  [*] Cloudflare WARP yaln\u0131zca Windows i\u00e7in 64 bit s\u00fcr\u00fcm sunuyor.%C_RST%","      On this 32-bit system rotation is disabled.":"      Bu 32 bit sistemde d\u00f6nd\u00fcrme devre d\u0131\u015f\u0131.","%C_OK%  [ok] WARP ready.%C_RST%":"%C_OK%  [ok] WARP haz\u0131r.%C_RST%","  [dep] opencode":"  [dep] opencode","  [auto-install] opencode not found, fetching it...":"  [auto-install] opencode bulunamad\u0131, indiriliyor...","%C_OK%  [ok] opencode ready.%C_RST%":"%C_OK%  [ok] opencode haz\u0131r.%C_RST%","%C_ERR%  ERROR: opencode install failed or is not on PATH.%C_RST%":"%C_ERR%  HATA: opencode kurulumu ba\u015far\u0131s\u0131z oldu veya PATH \u00fczerinde de\u011fil.%C_RST%","  Get it by hand: https://github.com/sst/opencode/releases":"  Elle indirin: https://github.com/sst/opencode/releases","  Preparing the connection...":"  Ba\u011flant\u0131 haz\u0131rlan\u0131yor...","  OpenCode":"  OpenCode","  Folder : \"%CD%\"":"  Klas\u00f6r : \"%CD%\"","  Egress : %EGRESS%":"  \u00c7\u0131k\u0131\u015f  : %EGRESS%","  Mode   : %APP_MODE%":"  Mod    : %APP_MODE%","  WARP   : none (rotation disabled)":"  WARP   : yok (d\u00f6nd\u00fcrme devre d\u0131\u015f\u0131)","  WARP   : \"%WARP%\"":"  WARP   : \"%WARP%\"","  Version: %OC_VER%  \"%OC_CMD%\"":"  S\u00fcr\u00fcm  : %OC_VER%  \"%OC_CMD%\"","  Exit IP: %IP%":"  \u00c7\u0131k\u0131\u015f IP: %IP%","  What do you want to do?":"  Ne yapmak istersiniz?","  [1] Fresh start   - get a new IP / proxy, then open OpenCode":"  [1] Yeni ba\u015flang\u0131\u00e7 - yeni IP / proxy al, sonra OpenCode'u a\u00e7","                      (your chats and history stay untouched)":"                      (sohbetleriniz ve ge\u00e7mi\u015finiz korunur)","  [2] Continue      - same egress, open OpenCode as it was":"  [2] Devam et     - ayn\u0131 \u00e7\u0131k\u0131\u015f, OpenCode'u kald\u0131\u011f\u0131 yerden a\u00e7","  [3] Change IP     - rotate / pick new proxy only":"  [3] IP de\u011fi\u015ftir  - yaln\u0131zca d\u00f6nd\u00fcr / yeni proxy se\u00e7","  [5] Deep reset    - kill opencode, move chats to the Desktop,":"  [5] Tam s\u0131f\u0131rlama - opencode'u kapat, sohbetleri Masa\u00fcst\u00fc'ne ta\u015f\u0131,","                      clear saved tokens, open a fresh session":"                      kay\u0131tl\u0131 token'lar\u0131 temizle, yeni oturum a\u00e7","  [6] Exit":"  [6] \u00c7\u0131k\u0131\u015f","  [7] Token reset   - kill opencode, clear saved tokens, keep chats":"  [7] Token s\u0131f\u0131rlama - opencode'u kapat, kay\u0131tl\u0131 token'lar\u0131 temizle,","                      where they are, open a fresh session":"                      sohbetler yerinde kal\u0131r, yeni oturum a\u00e7","  [8] Settings      - change any launcher setting, applied right away":"  [8] Ayarlar      - herhangi bir ayar\u0131 de\u011fi\u015ftir, hemen uygulan\u0131r","--- deep reset -----------------------------------------------":"--- tam s\u0131f\u0131rlama ----------------------------------------------","  This closes opencode, moves your chats to the Desktop,":"  Bu i\u015flem opencode'u kapat\u0131r, sohbetlerinizi Masa\u00fcst\u00fc'ne ta\u015f\u0131r,","  clears the saved tokens and opens a brand new session.":"  kay\u0131tl\u0131 token'lar\u0131 siler ve yeni bir oturum a\u00e7ar.","  It is the only action in this script that touches your files.":"  Bu betikteki dosyalar\u0131n\u0131za dokunan tek i\u015flemdir.","  It also kills EVERY opencode process on this computer,":"  Ayr\u0131ca bu bilgisayardaki T\u00dcM opencode i\u015flemlerini sonland\u0131r\u0131r,","  including windows opened by hand or by another launcher.":"  elle veya ba\u015fka bir launcher ile a\u00e7\u0131lan pencereler dahil.","--- token reset ----------------------------------------------":"--- token s\u0131f\u0131rlama ---------------------------------------------","  This closes opencode, clears the saved tokens and opens a":"  Bu i\u015flem opencode'u kapat\u0131r, kay\u0131tl\u0131 token'lar\u0131 temizler ve","  brand new session. Your chats are NOT moved.":"  yeni bir oturum a\u00e7ar. Sohbetleriniz TA\u015eINMAZ.","  auth.json is copied to the Desktop first, then removed.":"  auth.json \u00f6nce Masa\u00fcst\u00fc'ne kopyalan\u0131r, sonra silinir.","    egress: %EGRESS%":"    \u00e7\u0131k\u0131\u015f: %EGRESS%","%C_WARN%  [*] WARP proxy is not answering - rotation has no effect.%C_RST%":"%C_WARN%  [*] WARP proxy yan\u0131t vermiyor - d\u00f6nd\u00fcrmenin etkisi yok.%C_RST%","      Going direct would run opencode on your real IP.":"      Do\u011frudan \u00e7\u0131kmak opencode'un ger\u00e7ek IP'nizle \u00e7al\u0131\u015fmas\u0131na neden olur.","%C_WARN%  [*] Tor did not get ready.%C_RST%":"%C_WARN%  [*] Tor haz\u0131r olmad\u0131.%C_RST%","%C_WARN%  [*] no working free proxy found.%C_RST%":"%C_WARN%  [*] \u00e7al\u0131\u015fan \u00fccretsiz proxy bulunamad\u0131.%C_RST%","%C_WARN%  [*] the egress proxy stopped answering while OpenCode was open:%C_RST%":"%C_WARN%  [*] OpenCode a\u00e7\u0131kken \u00e7\u0131k\u0131\u015f proxy'si yan\u0131t vermeyi b\u0131rakt\u0131:%C_RST%","      %STATE_DIR%\\proxy_warn.txt":"      %STATE_DIR%\\proxy_warn.txt","%C_WARN%  [watch] a fatal error cut the chat - rotating and resuming it.%C_RST%":"%C_WARN%  [watch] \u00f6l\u00fcmc\u00fcl bir hata sohbeti kesti - d\u00f6nd\u00fcr\u00fcl\u00fcp s\u00fcrd\u00fcr\u00fcl\u00fcyor.%C_RST%","OpenCode closed.":"OpenCode kapand\u0131.","  %KEY_ROTATE% = new IP and resume the chat   %KEY_MENU% = menu   %KEY_QUIT% = quit (Ctrl+C also quits)":"  %KEY_ROTATE% = yeni IP ve sohbete devam   %KEY_MENU% = men\u00fc   %KEY_QUIT% = \u00e7\u0131k\u0131\u015f (Ctrl+C de \u00e7\u0131kar)","Press any key to continue . . .":"Devam etmek i\u00e7in bir tu\u015fa bas\u0131n . . .","  [tor] renewing the circuit, attempt %TOR_TRIES% of %ROTATE_TRIES_MAX%...":"  [tor] devre yenileniyor, deneme %TOR_TRIES% / %ROTATE_TRIES_MAX%...","%C_OK%  [tor] new circuit - resuming.%C_RST%":"%C_OK%  [tor] yeni devre - devam ediliyor.%C_RST%","%C_WARN%  [*] Tor could not be renewed - back to menu.%C_RST%":"%C_WARN%  [*] Tor yenilenemedi - men\u00fcye d\u00f6n\u00fcl\u00fcyor.%C_RST%","%C_WARN%  [*] Tor could not get a usable circuit after %ROTATE_TRIES_MAX% attempts.%C_RST%":"%C_WARN%  [*] Tor, %ROTATE_TRIES_MAX% denemeden sonra kullan\u0131labilir bir devre alamad\u0131.%C_RST%","      The exit node may be blocked: try a new identity in Tor, or":"      \u00c7\u0131k\u0131\u015f d\u00fc\u011f\u00fcm\u00fc engellenmi\u015f olabilir: Tor'da yeni bir kimlik deneyin veya","      switch to [1] WARP. warp/tor notes: \"%TOR_DIR%\\tor.log\"":"      [1] WARP'a ge\u00e7in. warp/tor notlar\u0131: \"%TOR_DIR%\\tor.log\"","  [proxy] %ACTIVE_PROXY% is burned - attempt %PROXY_ROT% of %PROXY_ROT_MAX%, picking another...":"  [proxy] %ACTIVE_PROXY% yak\u0131ld\u0131 - deneme %PROXY_ROT% / %PROXY_ROT_MAX%, ba\u015fka biri aran\u0131yor...","  [proxy] picking a fresh free proxy before resume...":"  [proxy] devam etmeden \u00f6nce yeni bir \u00fccretsiz proxy aran\u0131yor...","%C_WARN%  [*] no free proxy is left that still works (they all hit the limit).%C_RST%":"%C_WARN%  [*] \u00e7al\u0131\u015fan \u00fccretsiz proxy kalmad\u0131 (hepsi limite ula\u015ft\u0131).%C_RST%","      Free proxies are shared by many people, so their limit is often used up.":"      \u00dccretsiz proxy'ler \u00e7ok ki\u015fi taraf\u0131ndan payla\u015f\u0131l\u0131yor, limitleri genellikle dolu olur.","  Automatic rotation is off - the menu decides.":"  Otomatik d\u00f6nd\u00fcrme kapal\u0131 - karar men\u00fcde.","Getting a new IP before the next attempt...":"Bir sonraki denemeden \u00f6nce yeni IP al\u0131n\u0131yor...","  [i] hunting for %HUNT_GOAL%: up to %TARGET_TRIES% attempts, %TARGET_MINUTES% min. Esc or Q stops.":"  [i] %HUNT_GOAL% aran\u0131yor: en fazla %TARGET_TRIES% deneme, %TARGET_MINUTES% dk. Durdurmak i\u00e7in Esc veya Q.","[%ROTATE_TRIES%/%TARGET_TRIES%] dropping the old registration...":"[%ROTATE_TRIES%/%TARGET_TRIES%] eski kay\u0131t siliniyor...","[%ROTATE_TRIES%/%TARGET_TRIES%] new registration...":"[%ROTATE_TRIES%/%TARGET_TRIES%] yeni kay\u0131t...","[%ROTATE_TRIES%] reconnect...":"[%ROTATE_TRIES%] yeniden ba\u011flan\u0131l\u0131yor...","[%ROTATE_TRIES%] waiting %WARP_WAIT%s...":"[%ROTATE_TRIES%] %WARP_WAIT%s bekleniyor...","[%ROTATE_TRIES%] %IPN% was already tried in this hunt, rotating again":"[%ROTATE_TRIES%] %IPN% bu aramada zaten denendi, yeniden d\u00f6nd\u00fcr\u00fcl\u00fcyor","[%ROTATE_TRIES%/%TARGET_TRIES%] exit IP %IPN% (country %GLOC%), target %TMATCHTXT%, %HUNT_LEFT% attempt(s) left":"[%ROTATE_TRIES%/%TARGET_TRIES%] \u00e7\u0131k\u0131\u015f IP'si %IPN% (\u00fclke %GLOC%), hedef %TMATCHTXT%, kalan deneme: %HUNT_LEFT%","[%ROTATE_TRIES%] probing if this IP can still talk...":"[%ROTATE_TRIES%] bu IP'nin h\u00e2l\u00e2 ba\u011flan\u0131p ba\u011flanamad\u0131\u011f\u0131 kontrol ediliyor...","%C_WARN%  [*] probe failed for a reason that is NOT a limit - attempt %PBROKEN% of %PROBE_BROKEN_MAX%. Last output:%C_RST%":"%C_WARN%  [*] kontrol limit olmayan bir nedenle ba\u015far\u0131s\u0131z oldu - deneme %PBROKEN% / %PROBE_BROKEN_MAX%. Son \u00e7\u0131kt\u0131:%C_RST%","[%PROBE_TRIES%] IP already burned, rotating again...":"[%PROBE_TRIES%] IP zaten yak\u0131lm\u0131\u015f, yeniden d\u00f6nd\u00fcr\u00fcl\u00fcyor...","%C_WARN%  [*] %PROBE_TRIES% IPs probed, every one of them already burned.%C_RST%":"%C_WARN%  [*] %PROBE_TRIES% IP kontrol edildi, hepsi zaten yak\u0131lm\u0131\u015f.%C_RST%","%C_WARN%  [*] the probe failed %PBROKEN% times and none of them was a limit error.%C_RST%":"%C_WARN%  [*] kontrol %PBROKEN% kez ba\u015far\u0131s\u0131z oldu ve hi\u00e7biri limit hatas\u0131 de\u011fildi.%C_RST%","      The probe itself is broken, not every IP: a retired PROBE_MODEL id,":"      Sorun kontrol\u00fcn kendisinde, her IP'de de\u011fil: emekli bir PROBE_MODEL kimli\u011fi,","      an auth error or a CLI change. Rotation cannot fix that.":"      bir kimlik do\u011frulama hatas\u0131 veya bir CLI de\u011fi\u015fikli\u011fi.","      Check PROBE_MODEL in the settings block, or run the probe model once":"      Ayarlar blo\u011fundaki PROBE_MODEL'i kontrol edin ya da ger\u00e7ek hatay\u0131 g\u00f6rmek i\u00e7in","      by hand to see the real error.":"      test modelini bir kez elle \u00e7al\u0131\u015ft\u0131r\u0131n.","  [i] probe off for this session - IPs are accepted on WARP-trace proof":"  [i] bu oturum i\u00e7in kontrol kapal\u0131 - IP'ler yaln\u0131zca WARP izi kan\u0131t\u0131yla kabul edilir,","      only, and the resume's own limit check keeps catching burned ones.":"      ve devam ederken yap\u0131lan limit kontrol\u00fc yak\u0131lm\u0131\u015flar\u0131 yakalamaya devam eder.","%C_WARN%  [*] the probe session \"%OC_PROBE_ID%\" does not exist and this%C_RST%":"%C_WARN%  [*] \"%OC_PROBE_ID%\" kontrol oturumu yok ve bu%C_RST%","      opencode build refused it. That is a probe problem, NOT a":"      opencode s\u00fcr\u00fcm\u00fc onu reddetti. Bu bir kontrol sorunu, yak\u0131lm\u0131\u015f bir IP DE\u011e\u0130L -","      burned IP - no rotation can fix it.":"      hi\u00e7bir d\u00f6nd\u00fcrme bunu d\u00fczeltemez.","  [i] the probe is off for this session: IPs are accepted on":"  [i] bu oturum i\u00e7in kontrol kapal\u0131: IP'ler yaln\u0131zca WARP izi kan\u0131t\u0131yla kabul edilir,","      WARP-trace proof only, and the resume's own limit check still":"      devam ederken yap\u0131lan limit kontrol\u00fc yine de yak\u0131lm\u0131\u015f birini yakalar.","      catches a burned one. To keep the probe, create the session by":"      Tutmak i\u00e7in oturumu bir kez elle olu\u015fturun","      hand once, or clear PROBE in the settings block.":"      veya ayarlar blo\u011funda PROBE'u silin.","%C_OK%[%ROTATE_TRIES%] IP %IPN% works.%C_RST%":"%C_OK%[%ROTATE_TRIES%] %IPN% IP'si \u00e7al\u0131\u015f\u0131yor.%C_RST%","[%ROTATE_TRIES%] no verified WARP IP yet, retrying...":"[%ROTATE_TRIES%] hen\u00fcz do\u011frulanm\u0131\u015f WARP IP'si yok, yeniden deneniyor...","%C_WARN%  [*] no usable IP from this hunt. warp-cli errors, if any, are in %STATE_DIR%\\wcli.log%C_RST%":"%C_WARN%  [*] bu aramadan kullan\u0131labilir IP \u00e7\u0131kmad\u0131. Varsa warp-cli hatalar\u0131 %STATE_DIR%\\wcli.log dosyas\u0131nda.%C_RST%","  restarting the desktop app on the new egress...":"  masa\u00fcst\u00fc uygulamas\u0131 yeni \u00e7\u0131k\u0131\u015fta yeniden ba\u015flat\u0131l\u0131yor...","  sending \"%RESUME_MSG%\" so the chat picks up where it stopped...":"  sohbetin kald\u0131\u011f\u0131 yerden devam etmesi i\u00e7in \"%RESUME_MSG%\" g\u00f6nderiliyor...","%C_WARN%  [*] proxy dead - retrying on the current egress instead of resuming.%C_RST%":"%C_WARN%  [*] proxy \u00f6ld\u00fc - devam etmek yerine mevcut \u00e7\u0131k\u0131\u015fta yeniden deneniyor.%C_RST%","%C_WARN%  [*] no answer in %RESUME_TIMEOUT%s - this exit IP is dead.%C_RST%":"%C_WARN%  [*] %RESUME_TIMEOUT%s i\u00e7inde yan\u0131t yok - bu \u00e7\u0131k\u0131\u015f IP'si \u00f6ld\u00fc.%C_RST%","%C_OK%  chat resumed on the new IP.%C_RST%":"%C_OK%  sohbet yeni IP'de devam etti.%C_RST%","%C_WARN%  [*] the resume itself hit a limit - rotating again.%C_RST%":"%C_WARN%  [*] devam etme i\u015flemi kendisi bir limite ula\u015ft\u0131 - yeniden d\u00f6nd\u00fcr\u00fcl\u00fcyor.%C_RST%","  Egress is NONE - nothing to rotate.":"  \u00c7\u0131k\u0131\u015f NONE - d\u00f6nd\u00fcr\u00fclecek bir \u015fey yok.","  Restarting the launcher-managed Tor for a new circuit...":"  Launcher taraf\u0131ndan y\u00f6netilen Tor, yeni bir devre i\u00e7in yeniden ba\u015flat\u0131l\u0131yor...","  TOR mode - this Tor was started outside the launcher.":"  TOR modu - bu Tor launcher d\u0131\u015f\u0131nda ba\u015flat\u0131ld\u0131.","  Restart it yourself for a new circuit, or pick [1] WARP / [4] NONE.":"  Yeni bir devre i\u00e7in kendiniz yeniden ba\u015flat\u0131n veya [1] WARP / [4] NONE se\u00e7in.","  Current bridge: http://127.0.0.1:%TOR_HTTP_PORT%":"  Ge\u00e7erli k\u00f6pr\u00fc: http://127.0.0.1:%TOR_HTTP_PORT%","  Picking a new free HTTP proxy...":"  Yeni \u00fccretsiz bir HTTP proxy'si aran\u0131yor...","  New proxy: %ACTIVE_PROXY%":"  Yeni proxy: %ACTIVE_PROXY%","WARP is not available - nothing to rotate.":"WARP kullan\u0131lam\u0131yor - d\u00f6nd\u00fcr\u00fclecek bir \u015fey yok.","Requesting a new WARP registration...":"Yeni bir WARP kayd\u0131 isteniyor...","waiting %WARP_WAIT%s...":"%WARP_WAIT%s bekleniyor...","%C_WARN%  [*] no verified WARP IP.%C_RST%":"%C_WARN%  [*] do\u011frulanm\u0131\u015f WARP IP'si yok.%C_RST%","      warp-cli errors land in %STATE_DIR%\\wcli.log":"      warp-cli hatalar\u0131 %STATE_DIR%\\wcli.log dosyas\u0131na yaz\u0131l\u0131r","  same IP as before: %IPN%":"  \u00f6nceki ile ayn\u0131 IP: %IPN%","%C_OK%  New exit IP: %IPN% (WARP verified)%C_RST%":"%C_OK%  Yeni \u00e7\u0131k\u0131\u015f IP'si: %IPN% (WARP do\u011fruland\u0131)%C_RST%","  --- resume stderr ---":"  --- devam etmenin stderr \u00e7\u0131kt\u0131s\u0131 ---","  --- resume stdout ---":"  --- devam etmenin stdout \u00e7\u0131kt\u0131s\u0131 ---","  downloading the WARP installer, about 60 MB...":"  WARP kurulum dosyas\u0131 indiriliyor, yakla\u015f\u0131k 60 MB...","%C_WARN%  [*] download failed.%C_RST%":"%C_WARN%  [*] indirme ba\u015far\u0131s\u0131z oldu.%C_RST%","      grab it by hand and run it: %WARP_MSI_URL%":"      elle indirip \u00e7al\u0131\u015ft\u0131r\u0131n: %WARP_MSI_URL%","  installing, accept the UAC prompt...":"  kuruluyor, UAC istemini onaylay\u0131n...","  [auto-install] the standalone build did not install, trying npm.":"  [auto-install] ba\u011f\u0131ms\u0131z s\u00fcr\u00fcm kurulamad\u0131, npm deneniyor.","  [i] 32-bit Windows: no standalone build - installing via npm.":"  [i] 32 bit Windows: ba\u011f\u0131ms\u0131z s\u00fcr\u00fcm yok - npm ile kuruluyor.","%C_OK%  [ok] opencode ready on 32-bit via npm.%C_RST%":"%C_OK%  [ok] opencode 32 bit olarak npm ile haz\u0131r.%C_RST%","%C_ERR%  ERROR: opencode could not be installed on 32-bit Windows.%C_RST%":"%C_ERR%  HATA: opencode 32 bit Windows'a kurulamad\u0131.%C_RST%","         Install 32-bit node.js by hand from nodejs.org, then run:":"         32 bit node.js'i nodejs.org'dan elle kurun, sonra \u00e7al\u0131\u015ft\u0131r\u0131n:","         npm i -g opencode-ai":"         npm i -g opencode-ai","%C_WARN%  [*] could not read the official release info from opencode.ai.%C_RST%":"%C_WARN%  [*] opencode.ai \u00fczerinden resmi s\u00fcr\u00fcm bilgileri okunamad\u0131.%C_RST%","  [auto-install] downloading opencode %OCA_VER% (official build, %OC_AFILE%)...":"  [auto-install] opencode %OCA_VER% indiriliyor (resmi s\u00fcr\u00fcm, %OC_AFILE%)...","%C_WARN%    [*] checksum mismatch - the download is not the official file.%C_RST%":"%C_WARN%    [*] sa\u011flama toplam\u0131 e\u015fle\u015fmiyor - indirilen dosya resmi dosya de\u011fil.%C_RST%","%C_WARN%    [*] download failed.%C_RST%":"%C_WARN%    [*] indirme ba\u015far\u0131s\u0131z oldu.%C_RST%","  [auto-install] unpacking, about 200 MB on disk...":"  [auto-install] a\u00e7\u0131l\u0131yor, diskte yakla\u015f\u0131k 200 MB...","  [auto-install] installing %NPMPKG% with npm...":"  [auto-install] %NPMPKG% npm ile kuruluyor...","  [npm] the install script was blocked - running it by hand...":"  [npm] kurulum beti\u011fi engellendi - elle \u00e7al\u0131\u015ft\u0131r\u0131l\u0131yor...","  [auto-install] node.js (32-bit) is missing - installing it...":"  [auto-install] node.js (32 bit) eksik - kuruluyor...","    via winget...":"    winget ile...","  [i] this can take a few minutes on its first run.":"  [i] ilk seferde birka\u00e7 dakika s\u00fcrebilir.","    winget failed - trying the MSI installer from nodejs.org...":"    winget ba\u015far\u0131s\u0131z - nodejs.org'dan MSI kurulumu deneniyor...","    downloading %NODE_MSI_URL% ...":"    %NODE_MSI_URL% indiriliyor ...","    direct download failed - retrying through the Windows proxy settings...":"    do\u011frudan indirme ba\u015far\u0131s\u0131z - Windows proxy ayarlar\u0131yla yeniden deneniyor...","    installing, accept the UAC prompt...":"    kuruluyor, UAC istemini onaylay\u0131n...","  opencode update available: %OCUPD_CUR% -> %OCUPD_LAT%":"  opencode g\u00fcncellemesi var: %OCUPD_CUR% -> %OCUPD_LAT%","  It closes every running opencode process first.":"  \u00d6nce \u00e7al\u0131\u015fan t\u00fcm opencode i\u015flemlerini kapat\u0131r.","  [update] npm i -g @opencode/cli@latest":"  [update] npm i -g @opencode/cli@latest","  [update] official standalone build %OCUPD_LAT%":"  [update] resmi ba\u011f\u0131ms\u0131z s\u00fcr\u00fcm %OCUPD_LAT%","%C_WARN%  [*] \"%OC_CMD%\" reports %OC_VER% but this machine has a v2 database.%C_RST%":"%C_WARN%  [*] \"%OC_CMD%\" %OC_VER% bildiriyor ama bu bilgisayarda v2 veritaban\u0131 var.%C_RST%","      A v1 binary cannot open it: \"Database is not empty and has no session table\".":"      v1 program\u0131 bunu a\u00e7amaz: \"Database is not empty and has no session table\".","      Update it:  npm i -g @opencode/cli@latest   (or accept the update offer)":"      G\u00fcncelleyin:  npm i -g @opencode/cli@latest   (ya da g\u00fcncelleme teklifini kabul edin)","%C_WARN%  [*] WARP registration missing - creating a new one.%C_RST%":"%C_WARN%  [*] WARP kayd\u0131 eksik - yenisi olu\u015fturuluyor.%C_RST%","  [tor] nothing answering on :%TOR_HTTP_PORT% - portable setup starting...":"  [tor] :%TOR_HTTP_PORT% \u00fczerinde yan\u0131t yok - ta\u015f\u0131nabilir kurulum ba\u015fl\u0131yor...","%C_WARN%  [*] Tor did not become ready - the reason is in \"%TOR_DIR%\\tor.log\"%C_RST%":"%C_WARN%  [*] Tor haz\u0131r olmad\u0131 - nedeni \"%TOR_DIR%\\tor.log\" i\u00e7inde%C_RST%","%C_WARN%  [*] the Tor download did not land. Grab it by hand:%C_RST%":"%C_WARN%  [*] Tor indirmesi tamamlanmad\u0131. Elle indirin:%C_RST%","      https://dist.torproject.org/torbrowser/":"      https://dist.torproject.org/torbrowser/","      unpack the tor-expert-bundle tar.gz into \"%TOR_DIR%\",":"      tor-expert-bundle tar.gz dosyas\u0131n\u0131 \"%TOR_DIR%\" i\u00e7ine a\u00e7\u0131n,","      so that \"%TOR_DIR%\\Tor\\tor.exe\" exists, then run this again.":"      b\u00f6ylece \"%TOR_DIR%\\Tor\\tor.exe\" olu\u015fsun, sonra bunu yeniden \u00e7al\u0131\u015ft\u0131r\u0131n.","%C_OK%  [tor] ready: SOCKS :%TOR_SOCKS_PORT% - HTTP :%TOR_HTTP_PORT%.%C_RST%":"%C_OK%  [tor] haz\u0131r: SOCKS :%TOR_SOCKS_PORT% - HTTP :%TOR_HTTP_PORT%.%C_RST%","  [tor] updater JSON unavailable - falling back to the dist index...":"  [tor] g\u00fcncelleyici JSON'u yok - da\u011f\u0131t\u0131m dizinine d\u00f6n\u00fcl\u00fcyor...","%C_WARN%  [*] the Tor bundle did not download.%C_RST%":"%C_WARN%  [*] Tor paketi indirilmedi.%C_RST%","  [tor] unpacking...":"  [tor] a\u00e7\u0131l\u0131yor...","%C_OK%  [ok] Tor installed - portable - in \"%TOR_DIR%\".%C_RST%":"%C_OK%  [ok] Tor kuruldu - ta\u015f\u0131nabilir - \"%TOR_DIR%\" i\u00e7inde.%C_RST%","%C_WARN%  [*] the bundle unpacked but tor.exe was not found in \"%TOR_DIR%\".%C_RST%":"%C_WARN%  [*] paket a\u00e7\u0131ld\u0131 ama \"%TOR_DIR%\" i\u00e7inde tor.exe bulunamad\u0131.%C_RST%","  [tor] a Tor is already running on :%TOR_SOCKS_PORT% - using it as it is.":"  [tor] :%TOR_SOCKS_PORT% \u00fczerinde zaten \u00e7al\u0131\u015fan bir Tor var - oldu\u011fu gibi kullan\u0131l\u0131yor.","  [tor] starting tor (hidden window, log: \"%OC_TORLOG%\")...":"  [tor] tor ba\u015flat\u0131l\u0131yor (gizli pencere, g\u00fcnl\u00fck: \"%OC_TORLOG%\")...","%C_WARN%  [*] tor could not be started - see \"%OC_TORERR%\" and \"%OC_TORLOG%\".%C_RST%":"%C_WARN%  [*] tor ba\u015flat\u0131lamad\u0131 - \"%OC_TORERR%\" ve \"%OC_TORLOG%\" dosyalar\u0131na bak\u0131n.%C_RST%","  [tor] starting the built-in HTTP->SOCKS bridge on :%TOR_HTTP_PORT% (no Privoxy needed)...":"  [tor] :%TOR_HTTP_PORT% \u00fczerinde yerle\u015fik HTTP->SOCKS k\u00f6pr\u00fcs\u00fc ba\u015flat\u0131l\u0131yor (Privoxy gerekmez)...","  [tor] bootstrapping, up to %TOR_BOOTSTRAP_WAIT%s (the first run takes longer)...":"  [tor] %TOR_BOOTSTRAP_WAIT%s'ye kadar ba\u011flan\u0131l\u0131yor (ilk seferde daha uzun s\u00fcrer)...","  [tor] Tor is up and routing through the bridge.":"  [tor] Tor \u00e7al\u0131\u015f\u0131yor ve k\u00f6pr\u00fc \u00fczerinden y\u00f6nlendiriyor.","  [tor] still not up after %TOR_BOOTSTRAP_WAIT%s.":"  [tor] %TOR_BOOTSTRAP_WAIT%s sonra h\u00e2l\u00e2 \u00e7al\u0131\u015fm\u0131yor.","  [tor] found a Tor Browser SOCKS on :9150 - using it.":"  [tor] :9150 \u00fczerinde bir Tor Browser SOCKS'u bulundu - kullan\u0131l\u0131yor.","  [tor] found a Tor SOCKS on :9050 - using it.":"  [tor] :9050 \u00fczerinde bir Tor SOCKS'u bulundu - kullan\u0131l\u0131yor.","  [*] this Tor was not started by the launcher - it cannot be renewed":"  [*] bu Tor launcher taraf\u0131ndan ba\u015flat\u0131lmad\u0131 - buradan yeniden ba\u015flat\u0131lamaz.","      from here. Restart Tor Browser yourself, or pick [1] WARP / [4] NONE.":"      Tor Browser'\u0131 kendiniz yeniden ba\u015flat\u0131n ya da [1] WARP / [4] NONE se\u00e7in.","  WARP proxy is not answering - cannot verify the exit IP.":"  WARP proxy yan\u0131t vermiyor - \u00e7\u0131k\u0131\u015f IP'si do\u011frulanam\u0131yor.","  same IP as the last run, requesting a new registration...":"  ge\u00e7en seferki ile ayn\u0131 IP, yeni bir kay\u0131t isteniyor...","  [%EN_TRIES%] dropping the old registration...":"  [%EN_TRIES%] eski kay\u0131t siliniyor...","  [%EN_TRIES%] new registration...":"  [%EN_TRIES%] yeni kay\u0131t...","  [%EN_TRIES%] reconnecting WARP proxy...":"  [%EN_TRIES%] WARP proxy'ye yeniden ba\u011flan\u0131l\u0131yor...","  [%EN_TRIES%] waiting %WARP_WAIT%s...":"  [%EN_TRIES%] %WARP_WAIT%s bekleniyor...","  exit IP: %CUR%":"  \u00e7\u0131k\u0131\u015f IP'si: %CUR%","  no new IP after %ROTATE_TRIES_MAX% tries, launching on the current one.":"  %ROTATE_TRIES_MAX% denemeden sonra yeni IP yok, mevcut olanla ba\u015flat\u0131l\u0131yor.","  [note] opencode log not found: \"%LOGFILE%\"":"  [note] opencode g\u00fcnl\u00fc\u011f\u00fc bulunamad\u0131: \"%LOGFILE%\"","         auto-detect stays off until the log appears.":"         g\u00fcnl\u00fck g\u00f6r\u00fcnene kadar otomatik alg\u0131lama kapal\u0131 kal\u0131r.","  OpenCode desktop update available: %DVER% -> %OCA_VER%":"  OpenCode masa\u00fcst\u00fc g\u00fcncellemesi var: %DVER% -> %OCA_VER%","  It closes every OpenCode process first, the app and its service included.":"  \u00d6nce uygulama ve servisi dahil t\u00fcm OpenCode i\u015flemlerini kapat\u0131r.","  downloading the OpenCode desktop installer %OCA_VER%, about 250 MB...":"  OpenCode masa\u00fcst\u00fc kurulum dosyas\u0131 %OCA_VER% indiriliyor, yakla\u015f\u0131k 250 MB...","  [*] checksum mismatch - the download is not the official file.":"  [*] sa\u011flama toplam\u0131 e\u015fle\u015fmiyor - indirilen dosya resmi dosya de\u011fil.","  [*] download failed.":"  [*] indirme ba\u015far\u0131s\u0131z oldu.","      grab it by hand and run it: %ID_URL%":"      elle indirip \u00e7al\u0131\u015ft\u0131r\u0131n: %ID_URL%","      or from the website: https://opencode.ai/download":"      ya da web sitesinden: https://opencode.ai/download","  installing, accept the UAC prompt if one appears...":"  kuruluyor, \u00e7\u0131karsa UAC istemini onaylay\u0131n...","  [*] could not read the official release info from opencode.ai.":"  [*] opencode.ai \u00fczerinden resmi s\u00fcr\u00fcm bilgileri okunamad\u0131.","      get the installer by hand: https://opencode.ai/download":"      kurulum dosyas\u0131n\u0131 elle al\u0131n: https://opencode.ai/download","  [*] the desktop app has no 32-bit Windows build.":"  [*] masa\u00fcst\u00fc uygulamas\u0131n\u0131n 32 bit Windows s\u00fcr\u00fcm\u00fc yok.","[verify] egress: %EGRESS%":"[verify] \u00e7\u0131k\u0131\u015f: %EGRESS%","[verify] ip=%IPN% warp=%WFLAG%":"[verify] ip=%IPN% warp=%WFLAG%","[verify] Cloudflare WARP is not installed (warp-cli not found).":"[verify] Cloudflare WARP kurulu de\u011fil (warp-cli bulunamad\u0131).","[renew] egress: %EGRESS%":"[renew] \u00e7\u0131k\u0131\u015f: %EGRESS%","[renew] new exit IP: %IPN%":"[renew] yeni \u00e7\u0131k\u0131\u015f IP'si: %IPN%","[renew] Cloudflare WARP is not installed (warp-cli not found).":"[renew] Cloudflare WARP kurulu de\u011fil (warp-cli bulunamad\u0131).","[renew] proxy: %ACTIVE_PROXY%":"[renew] proxy: %ACTIVE_PROXY%","[renew] done":"[renew] tamamland\u0131","[renew] could not get a working connection":"[renew] \u00e7al\u0131\u015fan bir ba\u011flant\u0131 al\u0131namad\u0131","  archiving chats to:":"  sohbetler \u015furaya ar\u015fivleniyor:","  nothing to archive.":"  ar\u015fivlenecek bir \u015fey yok.","  archived.":"  ar\u015fivlendi.","  [*] could not move the storage folder - it stays where it is.":"  [*] depolama klas\u00f6r\u00fc ta\u015f\u0131namad\u0131 - oldu\u011fu yerde kal\u0131yor.","  [*] could not copy %1 - it stays where it is.":"  [*] %1 kopyalanamad\u0131 - oldu\u011fu yerde kal\u0131yor.","  [*] size mismatch on %1 - the bad copy is deleted, the original stays.":"  [*] %1 \u00fczerinde boyut uyu\u015fmuyor - bozuk kopya silindi, orijinal kald\u0131.","  cache and tokens cleared.":"  \u00f6nbellek ve token'lar temizlendi.","  auth.json archived in \"%TARGET%\".":"  auth.json \"%TARGET%\" i\u00e7ine ar\u015fivlendi.","  [*] the auth.json copy did not verify - tokens are left in place.":"  [*] auth.json kopyas\u0131 do\u011frulanamad\u0131 - token'lar yerinde b\u0131rak\u0131ld\u0131.","  [*] could not copy auth.json - tokens are left in place.":"  [*] auth.json kopyalanamad\u0131 - token'lar yerinde b\u0131rak\u0131ld\u0131.","  [*] no archive folder for this reset - auth.json is left in place.":"  [*] bu s\u0131f\u0131rlama i\u00e7in ar\u015fiv klas\u00f6r\u00fc yok - auth.json yerinde b\u0131rak\u0131ld\u0131.","  [*] the WARP port answers SOCKS5 only, and OpenCode cannot use SOCKS.":"  [*] WARP portu yaln\u0131zca SOCKS5 yan\u0131t veriyor ve OpenCode SOCKS kullanam\u0131yor.","      WARP is up, but no usable HTTP proxy can be handed to it.":"      WARP \u00e7al\u0131\u015f\u0131yor, ancak OpenCode'a kullan\u0131labilir bir HTTP proxy verilemiyor.","  [proxy] process-only: %ACTIVE_PROXY%":"  [proxy] yaln\u0131zca i\u015flem: %ACTIVE_PROXY%","  [proxy] reading the proxy list...":"  [proxy] proxy listesi okunuyor...","  [proxy] %PCOUNT% proxies in the list":"  [proxy] listede %PCOUNT% proxy var","  [*] no proxies found in \"%PSRC%\"":"  [*] \"%PSRC%\" i\u00e7inde proxy bulunamad\u0131","  [*] no proxy passed the API check, but %TRACE_ONLY% did reach Cloudflare.":"  [*] hi\u00e7bir proxy API kontrol\u00fcn\u00fc ge\u00e7emedi, ama %TRACE_ONLY% Cloudflare'a ula\u015ft\u0131.","      PROXY_API_CHECK_URL may be wrong - see the settings block.":"      PROXY_API_CHECK_URL yanl\u0131\u015f olabilir - ayarlar blo\u011funa bak\u0131n.","  [proxy] live: %ACTIVE_PROXY%":"  [proxy] canl\u0131: %ACTIVE_PROXY%","  [*] OpenCode-Infinite is already open in another window.":"  [*] OpenCode-Infinite zaten ba\u015fka bir pencerede a\u00e7\u0131k.","  Exiting.":"  \u00c7\u0131k\u0131l\u0131yor.","  [upd] repo copy is %SU_RV%, older than %SU_LV% - keeping this one.":"  [upd] depo kopyas\u0131 %SU_RV%, %SU_LV% s\u00fcr\u00fcm\u00fcnden eski - bu kopya tutuluyor.","  [upd] launcher matches the repo, %SU_LV%.":"  [upd] launcher depoyla e\u015fle\u015fiyor, %SU_LV%.","  [upd] update found: local %SU_LV% - repo %SU_RV%":"  [upd] g\u00fcncelleme bulundu: yerel %SU_LV% - depo %SU_RV%","  [upd] swapping in %SU_RV% - this window closes now.":"  [upd] %SU_RV% ile de\u011fi\u015ftiriliyor - bu pencere \u015fimdi kapanacak.","  [upd] the swap could not be prepared - keeping %SU_LV%.":"  [upd] de\u011fi\u015ftirme haz\u0131rlanamad\u0131 - %SU_LV% kal\u0131yor.","        The downloaded copy is in \"%SU_TMP%\".":"        \u0130ndirilen kopya \"%SU_TMP%\" i\u00e7inde.","  Press any key to close this window.":"  Bu pencereyi kapatmak i\u00e7in bir tu\u015fa bas\u0131n.","Automatic rotation":"Otomatik d\u00f6nd\u00fcrme","On: a limit or a closed opencode gets a new IP and the chat resumes. Off: the menu decides.":"A\u00e7\u0131k: bir limit ya da kapanm\u0131\u015f bir opencode yeni IP al\u0131r ve sohbet devam eder. Kapal\u0131: karar men\u00fcde.","Target country":"Hedef \u00fclke","Keep asking for IPs until one is in this country, e.g. DE. Empty = any new IP.":"Bu \u00fclkede bir IP \u00e7\u0131kana kadar IP istemeye devam et, \u00f6rn. DE. Bo\u015f = herhangi yeni IP.","Target IP prefix":"Hedef IP \u00f6neki","Keep asking until the IP starts with this, e.g. 104.28. Empty = not used.":"IP bununla ba\u015flayana kadar istemeye devam et, \u00f6rn. 104.28. Bo\u015f = kullan\u0131lmaz.","Max attempts per hunt":"Arama ba\u015f\u0131na en fazla deneme","New IPs requested in one hunt. The hunt stops at this count.":"Bir aramada istenen yeni IP say\u0131s\u0131. Arama bu say\u0131da durur.","Max minutes per hunt":"Arama ba\u015f\u0131na en fazla dakika","The hunt stops after this many minutes.":"Arama bu kadar dakikadan sonra durur.","Seconds between attempts":"Denemeler aras\u0131 saniye","Pause between two attempts, so Cloudflare is not hit too fast.":"\u0130ki deneme aras\u0131ndaki bekleme, Cloudflare'a \u00e7ok h\u0131zl\u0131 istek gitmesin diye.","Activity log":"Etkinlik g\u00fcnl\u00fc\u011f\u00fc","Record what the launcher does in launcher.log so a problem can be diagnosed.":"Bir sorunu te\u015fhis edebilmek i\u00e7in launcher'\u0131n yapt\u0131klar\u0131n\u0131 launcher.log dosyas\u0131na kaydeder.","Log size limit (KB)":"G\u00fcnl\u00fck boyut s\u0131n\u0131r\u0131 (KB)","The log is cut to its newest part when it grows past this.":"G\u00fcnl\u00fck bu boyutu a\u015f\u0131nca en yeni k\u0131sm\u0131na k\u0131rp\u0131l\u0131r.","Hide IPs in reports":"Raporlarda IP'leri gizle","Public IP addresses are masked in the support report.":"Genel IP adresleri destek raporunda maskelenir.","config.json could not be read; a copy was kept as config.json.broken and defaults are in use.":"config.json okunamad\u0131; bir kopyas\u0131 config.json.broken olarak sakland\u0131 ve varsay\u0131lan de\u011ferler kullan\u0131l\u0131yor.","Two letters, like DE or US. Empty = any country.":"DE veya US gibi iki harf. Bo\u015f = herhangi bir \u00fclke.","The start of an IPv4 address, like 104.28. Empty = any IP.":"104.28 gibi bir IPv4 adresinin ba\u015flang\u0131c\u0131. Bo\u015f = herhangi bir IP.","Value: {0}":"De\u011fer: {0}"," Back":" Geri","Windows Terminal settings.json was not found.":"Windows Terminal settings.json bulunamad\u0131.","settings.json was left untouched: the edit would not have kept it valid.":"settings.json de\u011fi\u015ftirilmedi: d\u00fczenleme ge\u00e7erli kalmas\u0131n\u0131 sa\u011flamazd\u0131.","Windows Terminal font put back as it was. Reopen the tab if it does not change.":"Windows Terminal yaz\u0131 tipi eski haline d\u00f6nd\u00fcr\u00fcld\u00fc. De\u011fi\u015fmezse sekmeyi yeniden a\u00e7\u0131n.","Windows Terminal font set to ":"Windows Terminal yaz\u0131 tipi \u015funa ayarland\u0131:",". Backup of settings.json: ":". settings.json yede\u011fi:","The Windows font API could not be loaded.":"Windows yaz\u0131 tipi API'si y\u00fcklenemedi.","This window does not allow changing the font from here.":"Bu pencere yaz\u0131 tipini buradan de\u011fi\u015ftirmeye izin vermiyor.","The font was never changed, nothing to restore.":"Yaz\u0131 tipi hi\u00e7 de\u011fi\u015ftirilmedi, geri al\u0131nacak bir \u015fey yok.","Windows refused that font in this console.":"Windows bu konsolda bu yaz\u0131 tipini reddetti.","This console refused \"":"Bu konsol \u015funu reddetti: \"","\" and kept \"":"\" ve \u015funu tuttu: \"","\". Older classic consoles only take the fonts Windows registers for them (":"\". Eski klasik konsollar yaln\u0131zca Windows'un onlar i\u00e7in kaydetti\u011fi yaz\u0131 tiplerini kabul eder (","). Windows Terminal accepts any installed font.":"). Windows Terminal kurulu her yaz\u0131 tipini kabul eder.","Console font set to ":"Konsol yaz\u0131 tipi \u015funa ayarland\u0131:",". It lasts while this window is open and is applied again at every launcher start.":". Bu pencere a\u00e7\u0131k kald\u0131\u011f\u0131 s\u00fcrece ge\u00e7erlidir ve launcher her ba\u015flad\u0131\u011f\u0131nda yeniden uygulan\u0131r.","This terminal keeps its font in its own settings (VS Code: terminal.integrated.fontFamily).":"Bu terminal yaz\u0131 tipini kendi ayarlar\u0131nda tutar (VS Code: terminal.integrated.fontFamily).","Could not change the font: ":"Yaz\u0131 tipi de\u011fi\u015ftirilemedi:"," The setting was not changed.":" Ayar de\u011fi\u015ftirilmedi.","Enter, arrows":"Enter, oklar"," Connect with opencode":" opencode ile ba\u011flan"," CLI":" CLI"," Desktop app":" Masa\u00fcst\u00fc uygulamas\u0131"," Exit":" \u00c7\u0131k\u0131\u015f","There is no saved folder yet. Use one of the other options once.":"Hen\u00fcz kay\u0131tl\u0131 klas\u00f6r yok. Di\u011fer se\u00e7eneklerden birini bir kez kullan\u0131n.","Cloudflare":"Cloudflare","bridge :":"k\u00f6pr\u00fc :","CLI / Desktop":"CLI / Masa\u00fcst\u00fc","Automatic (follow Windows)":"Otomatik (Windows'u izler)","Use the language Windows is set to on every start; English when there is no translation.":"Her ba\u015flang\u0131\u00e7ta Windows'un dilini kullan\u0131r; \u00e7eviri yoksa \u0130ngilizce."," (detected)":" (alg\u0131land\u0131)","Detected from Windows and selected. You can change it in Settings, Appearance.":"Windows'tan alg\u0131land\u0131 ve se\u00e7ildi. Ayarlar, G\u00f6r\u00fcn\u00fcm b\u00f6l\u00fcm\u00fcnden de\u011fi\u015ftirebilirsiniz.","You can change it in Settings, Appearance.":"Ayarlar, G\u00f6r\u00fcn\u00fcm b\u00f6l\u00fcm\u00fcnden de\u011fi\u015ftirebilirsiniz.","Choose your language":"Dilinizi se\u00e7in"," Launch OpenCode":" OpenCode'u ba\u015flat"," Renew session":" Oturumu yenile"," Uninstall":" Kald\u0131r"," Support report":" Destek raporu","not a url":"bir URL de\u011fil","Sessions":"Oturumlar","Pick a chat from this folder and continue it. CLI only.":"Bu klas\u00f6rdeki bir sohbeti se\u00e7ip devam et. Yaln\u0131zca CLI.","The desktop app has no session list. Switch to CLI to pick a chat.":"Masa\u00fcst\u00fc uygulamas\u0131nda oturum listesi yok. Sohbet se\u00e7mek i\u00e7in CLI'a ge\u00e7.","Could not read the sessions: {0}":"Oturumlar okunamad\u0131: {0}","No sessions in this folder yet.":"Bu klas\u00f6rde hen\u00fcz oturum yok.","Untitled session":"Ba\u015fl\u0131ks\u0131z oturum","Sessions in this folder":"Bu klas\u00f6rdeki oturumlar","  [9] Sessions      - continue a chat from this folder":"  [9] Oturumlar      - bu klas\u00f6rdeki bir sohbete devam et","Change IP (test)":"IP de\u011fi\u015ftir (test)","Clear tokens and cache, then start":"Token ve \u00f6nbelle\u011fi temizle, sonra ba\u015flat","keeps chats":"sohbetler kal\u0131r","Deep reset or restore chats":"Derin s\u0131f\u0131rlama veya sohbetleri geri y\u00fckle","submenu":"alt men\u00fc","Mode (CLI or Desktop)":"Mod (CLI veya Masa\u00fcst\u00fc)","New IP and start OpenCode":"Yeni IP ve OpenCode'u ba\u015flat","Kill opencode, save the login file to the Desktop, clear the cache, then open OpenCode. Chats stay where they are.":"opencode'u kapat\u0131r, giri\u015f dosyas\u0131n\u0131 Masa\u00fcst\u00fc'ne kaydeder, \u00f6nbelle\u011fi temizler ve OpenCode'u a\u00e7ar. Sohbetler oldu\u011fu yerde kal\u0131r.","Rotate the connection only, without opening OpenCode.":"Yaln\u0131zca ba\u011flant\u0131y\u0131 de\u011fi\u015ftirir, OpenCode'u a\u00e7maz.","Deep reset moves your chats to the Desktop and clears tokens and cache. Restore brings chats back from an earlier reset.":"Derin s\u0131f\u0131rlama sohbetlerinizi Masa\u00fcst\u00fc'ne ta\u015f\u0131r ve token ile \u00f6nbelle\u011fi siler. Geri y\u00fckleme \u00f6nceki bir s\u0131f\u0131rlamadan sohbetleri geri getirir.","Move your chats to the Desktop archive, clear tokens and cache, then start fresh.":"Sohbetleri Masa\u00fcst\u00fc ar\u015fivine ta\u015f\u0131r, token ve \u00f6nbelle\u011fi siler ve s\u0131f\u0131rdan ba\u015flar.","Restore chats":"Sohbetleri geri y\u00fckle","from the Desktop":"Masa\u00fcst\u00fc'nden","Bring chats back from an earlier deep reset.":"\u00d6nceki bir derin s\u0131f\u0131rlamadaki sohbetleri geri getirir.","Return to the deep reset menu.":"Derin s\u0131f\u0131rlama men\u00fcs\u00fcne d\u00f6ner.","Return to the home screen.":"Ana ekrana d\u00f6ner.","Restore chats from a backup":"Sohbetleri bir yedekten geri y\u00fckle","No archived chats yet. A deep reset creates one on the Desktop.":"Hen\u00fcz ar\u015fivlenmi\u015f sohbet yok. Derin s\u0131f\u0131rlama Masa\u00fcst\u00fc'nde bir tane olu\u015fturur.","{0} file":"{0} dosya","{0} files":"{0} dosya","Windows Terminal font size set to {0}. Reopen the tab if it does not change.":"Windows Terminal yaz\u0131 boyutu {0} olarak ayarland\u0131. De\u011fi\u015fmezse sekmeyi yeniden a\u00e7\u0131n.","Restore now?":"\u015eimdi geri y\u00fcklensin mi?","  Nothing to restore in that backup.":"  Bu yedekte geri y\u00fcklenecek bir \u015fey yok.","  Restore the chats from:":"  Sohbetleri \u015furadan geri y\u00fckle:","  The chats in place now are moved to the Desktop first. Nothing is deleted.":"  Mevcut sohbetler \u00f6nce Masa\u00fcst\u00fc'ne ta\u015f\u0131n\u0131r. Hi\u00e7bir \u015fey silinmez.","  [*] some storage files did not copy. The backup is untouched.":"  [*] baz\u0131 depolama dosyalar\u0131 kopyalanamad\u0131. Yede\u011fe dokunulmad\u0131.","  Chats restored. The previous ones are in:":"  Sohbetler geri y\u00fcklendi. \u00d6nceki sohbetler \u015furada:"}
