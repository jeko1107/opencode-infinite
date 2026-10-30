# OpenCode Infinite - launcher handbook (v2.26)

A single-file Windows batch launcher for OpenCode that adds multi-egress
(Cloudflare WARP, Tor, free/custom HTTP proxy lists, or direct), dependency
bootstrap, changed-IP auto-resume, watching of fatal errors, an UPD
self-updater and a one-click updater bootstrap.

 - File: `OpenCode Infinite.bat`
 - Target: Windows 10 / 11, **x64, ARM64, and x86 (32-bit) via npm + 32-bit node**
 - Admin required: only for optional installs (WARP MSI / node MSI). Everything
  else runs user-mode, no registry, no services, no scheduled tasks.

---

## 1. What problem it solves

Free-tier AI endpoints rate-limit **per egress IP** and **per session context**.
The launcher handles that:

1. launches OpenCode with the WARP proxy attached, so the provider sees
   Cloudflare's exit IP instead of yours;
2. on a bad run end (quota line in log, crash, Ctrl+C) it drops the WARP
   registration and requests a new one - which yields a different exit IP -
   then reopens the same session, no input;
3. probes every candidate IP with one cheap message on a throwaway session, so
   burned IPs are skipped (hunt can be unlimited with `IP_FIND_MAX=0`).

It also installs what it needs (WARP, OpenCode, 32-bit node) so it can start
from a bare machine.

---

## 2. One-command install

**PowerShell / Windows Terminal (recommended, single shell - no nested
PowerShell, no arg-passing quoting pitfalls):**

```powershell
[Net.ServicePointManager]::SecurityProtocol='Tls12'; iwr https://github.com/jeko1107/opencode-infinite/releases/latest/download/OpenCode-Infinite.bat -UseBasicParsing -OutFile "$env:TEMP\oci.bat"; Copy-Item "$env:TEMP\oci.bat" "$env:USERPROFILE\Desktop\OpenCode Infinite.bat" -Force; & "$env:TEMP\oci.bat"
```

**cmd (classic shell):** `curl.exe` ships with Windows 10 1803+ and Windows 11,
so this is one line whole:

```cmd
curl.exe -f -L https://github.com/jeko1107/opencode-infinite/releases/latest/download/OpenCode-Infinite.bat -o "%USERPROFILE%\Desktop\OpenCode Infinite.bat" && "%USERPROFILE%\Desktop\OpenCode Infinite.bat"
```

After the first run, the launcher verifies itself against the repo on every
start: if a newer copy is live on `main`, it says so and, with your approval,
backs itself up and swaps in the new version on a harmless restart - no laps
to keep provoking your memory.

**If a machine runs an OLD version (no [upd] block):** in the same folder, run
the repo companion file `Update launcher.bat`; it downloads the asset of the
**latest GitHub Release** (`OpenCode-Infinite.bat`) and replaces the old copy
(Beside, Desktop, or OneDrive-Desktop, first hit) with it. If the Release is not
reachable it falls back to the commit-pinned copy on `main`.

---

## 3. Quick start in the launcher

| How you start it | What happens |
|---|---|
| Double-click | Mode menu (CLI / Desktop), folder menu (CLI only), egress menu, then the main menu |
| Drag a folder onto the `.bat` | Jumps straight into that folder |
| `OpenCode Infinite.bat "D:\work\project"` | Same, from a shell |
| `OpenCode Infinite.bat \\server\share` | UNC paths work (`pushd`, not `cd /d`) |

If neither WARP nor OpenCode are installed, the script offers both fetches.
Nothing is installed silently (the UAC prompt is user-visible and once-only).

---

## 4. Files the launcher uses (all paths env-based, no hardcoded users)

| Path | Purpose | Written by |
|---|---|---|
| `%USERPROFILE%\.local\share\opencode\` | OpenCode data dir | OpenCode |
| `%LOCALAPPDATA%\opencode-launcher\` | lastfolder, lastip, wcli.log, startup.log, backups | launcher |
| `%LOCALAPPDATA%\opencode\bin\opencode.exe` | standalone OpenCode install | launcher |
| `%ProgramFiles%\nodejs\` (winget or pinned x86 MSI) | node.js that the npm route runs on | launcher install |
| `%USERPROFILE%\Desktop\opencode_chats_archiviate\<stamp>\` | deep-reset archive | launcher |
| `%TEMP%\Cloudflare_WARP_x64.msi`, `%TEMP%\node_x86.msi` | installer scratch, deleted after use | launcher |
| `%STATE_DIR%\lock\` | single-instance JIT | launcher |

No `C:\Users\<name>` strings live anywhere in the file; everything routes via
environment variables, which is what keeps it universal.

---

## 5. The main menu

| Key | Option | What it touches |
|---|---|---|
| `[1]` | Fresh start | new IP (ensure-different) + open a new session |
| `[2]` | Continue | same IP, same session |
| `[3]` | Change IP | rotates the current egress: WARP exit IP, TOR fresh circuit, PROXY next candidate; mode NONE has nothing to rotate |
| `[4]` | Folder (CLI) / Mode (Desktop) | CLI: change working folder. Desktop: switch between CLI and Desktop |
| `[5]` | Deep reset | kill OpenCode, archive chats to the Desktop, clear tokens, fresh session |
| `[6]` | Exit | closes the lock and leaves |

The very first menu picks **CLI** (terminal TUI) or **Desktop** (the OpenCode
desktop app). The main menu header shows the active `Mode`.

Before the main menu appears, the launcher asks the **egress mode** once:
`[1] WARP`, `[2] TOR`, `[3] PROXY`, `[4] NONE` - the proxy lives only in
the opencode process environment, system traffic stays direct.

After **any** run exit, the launcher checks the log and, if this IP is dead:
rotates and reopens the session automatically. Full cycle needs **one Ctrl+C
and one keystroke** between IPs.

---

## 6. Dependency bootstrap

### WARP (optional)

Search order in `:find_warp`:

1. `where warp-cli.exe`
2. `%ProgramFiles%\Cloudflare\Cloudflare WARP\`
3. `%ProgramFiles(x86)%\Cloudflare\Cloudflare WARP\`
4. `%ProgramW6432%\Cloudflare\Cloudflare WARP\`
5. `%LOCALAPPDATA%\Cloudflare\Cloudflare WARP\`

WARP install (`:install_warp`) downloads 64-bit MSI from
`downloads.cloudflareclient.com`, size gate 5 MB, silent install with UAC.
**x86 note:** WARP publishes 64-bit only; on real 32-bit Windows the rotation
is disabled but everything else runs from the direct connection.

### OpenCode (any install shape)

Search order in `:find_opencode` - all candidates are versioned and the
newest WIN (old v1-vs-v2 database mismatch reported instead of failing):

1. PATH lookup (opencode.exe / .cmd / .bat)
2. `%APPDATA%\npm\opencode.cmd` - npm shim
3. `%LOCALAPPDATA%\Programs\opencode\opencode.exe`
4. `%LOCALAPPDATA%\opencode\bin\opencode.exe` - standalone install by this script
5. `%USERPROFILE%\.opencode\bin\opencode.exe`

Install fallback:

> npm present -> `npm install -g opencode-ai`
> npm absent -> standalone build from GitHub releases (x64 or arm64)

### NEW in v2.26 - CLI / Desktop mode menu

The first menu now asks how to run OpenCode. Nothing changes for **CLI**.

- **Desktop mode.** Launches `OpenCode.exe` through the same egress
  (WARP / TOR / PROXY / NONE). It looks for the exe in `OC_APP` (environment
  variable, your own path first), then `%LOCALAPPDATA%\Programs\ai.opencode.desktop\`,
  `...\Programs\@opencode-ai\desktop\`, `...\Programs\opencode\` and
  `%ProgramFiles%\opencode\`. The menu shows the path it found, or says it
  was not found.
- **No folder step in Desktop.** The app has its own project picker, so the
  folder menu is skipped. In the main menu `[4]` becomes **Mode** and goes back
  to the CLI / Desktop choice.
- **Rotation restarts the app.** After a new IP the launcher closes the app and
  its sidecar and opens it again under the new proxy env. The CLI "continue"
  message is not sent: the app reopens where it was and you continue yourself.
- **Closes every opencode process.** Before a Desktop launch it stops
  `OpenCode.exe` / `opencode-cli.exe` (taskkill is case-insensitive, so a
  standalone `opencode.exe` CLI left open by hand dies too).
- **Scope.** The proxy is set only in the environment of the launched app; no
  system proxy, registry or `setx` is touched.
- **Known limit.** The app's background service (`opencode-cli.exe`, the process
  that talks to the API) honours `HTTP_PROXY` and uses the egress. The Electron
  shell itself is Chromium, which ignores `HTTP_PROXY`, so its own traffic
  (interface, updates) leaves on your real IP. A `--proxy-server` argument for
  the shell is not wired yet.

### NEW in v2.22 - v2.25 - hardening pass, verified end to end

Every item below was reproduced first and checked after the fix (WARP, TOR and
direct runs against a stand-in `opencode`, so no real quota was spent).

- **Service detection (v2.25).** OpenCode v2 lists the subcommand as
  `service    Manage the background server`; the old marker `opencode service`
  never matched, so every `service restart` / `service stop` in the launcher
  was dead code. Both markers are searched now.
- **No more endless menu on closed stdin (v2.25).** `choice` answers 255 (not
  0) at EOF and 255 satisfies every `if errorlevel N`, so the main menu looped
  forever through the token-reset prompt. The three number menus now leave.
- **Paths with spaces (v2.25).** The TUI and the resume ran `cmd /c <exe>` with
  the exe unquoted, so `C:\Users\John Smith\...` failed. The command line is
  one string with the exe quoted inside the `/s /c` wrapper.
- **Service restarts under the proxy env (v2.25).** After a rotation the
  background service was restarted on the user's own env (direct), so later
  requests left on the real IP. The proxy env is exported around that call.
- **Tor already running (v2.25).** `TOR_DIR` did not exist yet, so the bridge
  could write neither `bridge.log` nor `bridge.pid` and survived the launcher.
- **Stale lock (v2.25).** Closing the window with the X skips the cleanup and
  blocked the next start for up to 2 hours. The lock records the owning
  `cmd.exe` (`lock\owner`); a dead owner is a stale lock at any age.
- **Version compare (v2.25).** Leading zeros (`2.08.1`) and one-part versions
  (`2`) no longer break `:ver_gt`.
- **v2.22 - v2.24.** Every fixed bug carries an inline `REM v2.2x:` note in
  the file; the biggest ones are the proxy-variable restore, the TOR circuit
  renewal with a bounded counter and the built-in HTTP-to-SOCKS bridge.
### NEW in v2.16 - v2.21 - TOR egress, custom proxy lists, hardening

**Egress modes (since v2.17).** After the working folder is fixed the menu
asks once: `[1] WARP` (Cloudflare WARP proxy mode, rotation supported),
`[2] TOR` (local Tor served as an HTTP proxy, auto-setup), `[3] PROXY`
(free HTTP list, or your own), `[4] NONE` (direct). The choice lives only
in the opencode process environment - system traffic always stays direct.

**TOR egress (v2.18, v2.19).** With nothing installed the launcher
downloads the portable **Tor Expert Bundle** once
(`aus1.torproject.org` downloads.json first, `dist.torproject.org` index
scrape as fallback, size-gated, unpacked by the built-in `tar.exe`), starts
it hidden on `TOR_SOCKS_PORT`, and exposes it as an **HTTP proxy on
`TOR_HTTP_PORT`** through a tiny built-in bridge process - so no Privoxy
install is needed. Details:

 - no installer, no UAC, no service; the bundle lives in
   `%LOCALAPPDATA%\opencode-launcher\tor\`;
 - a Tor already running (Tor Browser, or any user tor on the SOCKS port)
   is used as it is and **never killed**: at exit `:tor_stop` (v2.20) only
   stops tor processes whose image path lives inside that private bundle
   directory, plus bridge processes carrying the `OC_TORBRIDGE_PS`
   command-line marker - pid files that match nothing are stale garbage;
 - v2.19 passes `-f <torrc>` with forward-slash paths (any code page and
   spaces survive), the bridge is a per-connection runspace
   HTTP(S)-over-SOCKS5h forwarder - one stuck handler can never freeze
   the others - and the SOCKS reply address is consumed with the correct
   ATYP length handling;
 - the wait gate checks the whole chain **through the bridge** (a live
   SOCKS port with a dead bridge is not answered as ready), bounded by
   `TOR_BOOTSTRAP_WAIT`.

**Custom proxy list (v2.21).** Set `PROXY_LIST_URL` to a raw URL or a
local `file:///C:/path/lista.txt` and the PROXY mode eats that one:

 - one proxy per line; `ip:port`, `http://ip:port` and `https://ip:port`
   all work (an `https://` line is not mangled);
 - lines starting with `#` or `;` are comments - they are skipped without
   counting toward `PROXY_TRY_MAX` and without spending a probe;
 - a UTF-8 BOM written by Notepad is stripped before parsing, so the
   first line still parses;
 - the download size gate is now `PROXY_LIST_MIN_BYTES` (default 20,
   **0 = off**), so a short personal list is no longer rejected; an empty
   file still finds no candidates and is reported normally.

**Hardening (v2.20).** The self-update curl branch now downloads the same
SHA-pinned URL as everything else; every SOCKS reply read in the bridge is
exact-length (a split reply cannot leave stale bytes for the TLS
handshake - the old `SEC_E_INVALID_TOKEN` class of failure); the request
head read carries an 8 s timeout so a silent local client cannot park its
handler (the value is restored before the pumps, so idle SSE/websocket
tunnels still sit open indefinitely); appended `wcli.log` is bounded by a
trim step (last 400 lines above 200 KB).

**Self-update is opt-in (v2.16).** `UPDATE_CHECK` defaults to `0`; run
`[upd]`, `Update launcher.bat`, or set `UPDATE_CHECK=1` to keep it on.

### NEW in v2.12 - update channel is CDN-proof, picker ESC chain, picker logs

 - **`[upd]` and `Update launcher.bat` pin the exact commit.** Both now ask
   the GitHub API for the newest SHA on `main` and download
   `raw.githubusercontent.com/jeko1107/opencode-infinite/<SHA>/OpenCode%20Infinite.bat`.
   A raw/main URL can serve a stale CDN copy for minutes after a push - that
   is exactly why someone running `[upd]` right after a release could stay on
   the previous version. A SHA-pinned URL is always the exact bytes of that
   commit. If the API is unreachable, both fall back to the plain main URL,
   so nothing is ever harder than it was.
 - **ESC/Cancel in the folder dialog is safe.** Closing the picker (ESC, the
   X, or `Cancel`) reaches the usual `Try again? [Y/N]` question: `Y` reopens
   it, `N` returns to the menu. Nothing is silently accepted.
 - **`install.log` records the pick trail**: `picker: dialog starting` /
   `picker: dialog finished` - so a "it never picked" report is one log read
   away from a cause.

### NEW in v2.15 - the modern Explorer picker is back, classic on ESC

The v2.14 note below is history: the modern dialog was never the problem. The
interop definition was. `Add-Type` compiled the C# `IFileDialog`/`IShellItem`
types as internal (warning: `the generated type is not public`), PowerShell
could not see `[IFileDialog]`, the cast died inside a silent `try/catch`, and
every attempt looked like "nothing picked". v2.15 fixes that for real:

 - **Types are `public`, and the COM cast happens in C#.** PowerShell 5.1
   cannot cast the `FileOpenDialog` RCW to the interface (`Cannot convert
   value ... to type IFileDialog`), so a `public static Shell.PickFolder`
   does the cast, `SetOptions(FOS_PICKFOLDERS)`, `Show`, and `GetResult`,
   and returns the path as a string.
 - **No helper files, no temp results.** The picker code lives at the end of
   this same `.bat`, after `exit /b`; `:run_picker` reads the file back from
   the `#>>>OC_PICKER_PS` marker and runs it with PowerShell. The chosen
   folder returns on stdout and is captured with `for /f`. Nothing is
   written to `%TEMP%` for the pick.
 - **[3] opens the modern Explorer dialog.** ESC or X on it opens the classic
   `FolderBrowserDialog` right after; cancelling that one reaches the usual
   `Try again? [Y/N]`. Both dialogs open in the last used folder.
 - **`install.log` names every hop**: `picker: modern dialog starting` then
   `picker: modern returned a folder` or `returned nothing`, and the same
   pair for `classic`.

### NEW in v2.14 - the Windows folder dialog owns the pick (superseded by v2.15)

v2.14 removed the modern Explorer-style picker. The compiled C# interop never
returned a pick reliably (`pick` -> `nothing from the modern dialog` on every
try, with no exception to name), while the classic Windows folder dialog
opened, picked, and handed back the path every single time. The launcher used
that one dialog, opened in the last folder you picked, and `Cancel` asked the
usual `Try again? [Y/N]`. v2.15 restored the modern dialog after finding the
actual cause (non-public interop types plus the PowerShell-side cast) and kept
the classic dialog as the ESC/X fallback.

### NEW in v2.11 - ESC key, no auto-yank after quit

Three fixes to the mouse-and-keyboard side, zero new settings:

 - **Folder picker (`[3]`) kept its Windows dialog** and gained the
   remember-last-folder behavior the modern dialog promised (v2.14 later
   made that the only picker - see its note above). `[3]` never dies.
 - **ESC works in the folder menu.** The folder menu now reads the console
   key directly; ESC exits the launcher, any other key remains `[1]-[4]`, and
   unknown keys just redraw the menu. On redirected stdin (non-interactive
   consoles) it falls back to the classic `choice` line, so piped flows are
   untouched.
 - **ESC no longer yanks you back.** Pressing ESC inside OpenCode quits it -
   that is OpenCode's own keymap and cannot be changed by the launcher. But
   when OpenCode closes, the old 5-second `choice /d y` auto-relaunched the
   session right away. The default is `N` in v2.11: a clean quit lands in
   the menu; press Y within the 5s window if you want the IP + resume
   (the automatic rotation paths keep their behavior).

### NEW in v2.9 - auto-rotate hardening (the "hit the limit, keep going" fix)

Cloudflare rate-limits rapid `registration new` bursts with HTTP 429. The old
rotate loop retried 4 times ~6 s apart, hit the throttle, and handed control
back with an error and a pause. v2.9:

 - waits `ROTATE_COOLDOWN` (10 s) between rotate attempts - burst becomes
  spaced traffic the throttle accepts;
 - after one failed cycle, cools down 60 s and runs **whole new rounds**
  (`ROTATE_ROUNDS` = 3) - minutes of throttle are ridden out without a
  single keystroke;
 - only when every round is spent does it pause at the menu with the
  `wcli.log` pointer;
 - the resume after a successful rotation still reopens the same session
  (`--continue`) with the auto-resume message, so the chat picks up where
  the quota error cut it.

### NEW in v2.8 - 32-bit Windows (x86) support

OpenCode publishes no x86 binary. On real 32-bit Windows the script goes:
bootstrap **32-bit node.js** first, then install OpenCode from npm.

 - `:install_node_x86`:
  1. `winget install OpenJS.NodeJS.LTS` (10-min cap, silent)
  2. winget missing -> pinned **nodejs.org v22 LTS x86 MSI** with the same
     size gate, Windows-proxy fallback, silent `/qn /norestart` after UAC
  3. PATH refresh, npm verification
 - Then: `npm install -g opencode-ai`, the version lookup runs again.

### Downloads in v2.7+ - proxy fallback

Every download sites (self-update, WARP MSI, OpenCode zip, node MSI) tries:

1. direct `curl -f --noproxy "*"` first
2. if egress is blocked (firewalls, transparent proxies) -> PowerShell
   `Invoke-WebRequest`, which reads the **Windows system proxy settings**
   itself, so it succeeds wherever the browser-level network works.

Size gates and header markers make it impossible for an HTML error page,
truncated file, or wrong resource to slip in.

---

## 7. PID-tracked TUI and the watcher

 - **`:launch`** spawns OpenCode inside the launcher's console through a tiny
  PowerShell host; its exact PID is written to `tui.pid` so the watcher can
  kill precisely the tree it owns (works for .exe, .cmd shim, and .bat alike).
  PS 5.1 nuance handled: an empty `-ArgumentList` is rejected, so the fresh
  start path (no flags) calls `Start-Process` without the parameter.
 - **`:watch_start`** - background watcher tails `opencode.log` from the
  pre-launch byte offset every 2s looking for
  `Failed to drain Session / free usage limit / rate limit / ...`. It waits
  4 seconds and only kills the TUI if no INFO/DEBUG recovery lines arrived -
  so a self-healing stream never gets murdered. Only a stuck chat dies.
 - **`:resume_run`** - resume message with hard `RESUME_TIMEOUT`, captured out
  and err files, `--standalone` server born under THIS proxy env (the old
  background server still holds the dead tunnel's sockets otherwise).
 - Quota/fatal errors on the new IP cause **another rotation**, full auto.

---

## 8. `wcli.log` - every warp-cli failure with the daemon's own words

`:wcli` wraps all warp-cli calls with a 15s cap, captures stdout+stderr, and
on failure logs a line like:

```
2026-10-29T08:48:09+01:00 exit 1: --accept-tos registration new :: Registration missing
```

So instead of a flood of unreadable `exit 1`, the daemon says its reason
directly (`Old registration is still around`, `Unable to reach the API`,
`Registration missing`, `unrecognized subcommand`, ...).

---

## 9. Self-update (`[upd]`)

On every start, before anything interactive:

1. newest script is fetched from
   `raw.githubusercontent.com/jeko1107/opencode-infinite/main/OpenCode%20Infinite.bat`
   (30s cap, direct first, Windows proxy fallback)
2. size ? 20 KB + `REM  OpenCode launcher` header gate (no HTML pages, no
   wrong resources)
3. version strings from `(vX.Y)` compared with the running file
4. equal -> one clean line `[upd] launcher matches the repo`. Different ->
   `[upd] update found: local v... - repo v...` and a `[Y/N]` prompt.
5. On `Y`: backup to `%STATE_DIR%\OpenCode Infinite backup <ver>.bat`, then a
   tiny helper waits for this cmd to release the .bat, swaps the new one in,
   restarts. The main script exits before anything reads the swapped file.

The check is silent when offline or when the repo is unreachable.

Since v2.16 the check ships OFF (`UPDATE_CHECK=0` in the settings block): the
launcher only touches the network for itself when you set it to `1`.

---

## 10. Deep reset (`[5]`)

The only option that touches user files, and it asks first.

1. stop OpenCode (`service stop` then `taskkill` on its oldest
   PIDs; the database must be lockable)
2. archive `opencode.db`, `opencode.db-wal`, `opencode.db-shm` with plain
   `move`, and `storage\` via **robocopy** (`:archive_storage`, exit codes
   >=8 mean failure) into
   `Desktop\opencode_chats_archiviate\<yyyyMMdd-HHmmss>\`; a timestamped
   folder per reset, nothing overwritten
3. clear tokens (`%USERPROFILE%\.cache\opencode\` + `auth.json`)
4. start a fresh session with the synth header variables set

Desktop detection uses `GetFolderPath('Desktop')` first, with fallbacks
(`OneDrive\Desktop`, `OneDrive\Escritorio`, `%USERPROFILE%\Desktop`).

### Restoring

```
move "%USERPROFILE%\Desktop\opencode_chats_archiviate\<stamp>\opencode.db" "%USERPROFILE%\.local\share\opencode\"
```

---

## 11. Settings (top of file, edit freely)

| Variable | Default | Meaning |
|---|---|---|
| `ROTATE_TRIES_MAX` | `4` | infrastructure rotation attempts |
| `ROTATE_COOLDOWN` | `10` s | wait between rotate attempts (Cloudflare throttles rapid `registration new` bursts with 429) |
| `ROTATE_ROUNDS` | `3` | full rotate cycles with a 60 s cool-down between them before giving up (0 = one cycle) |
| `IP_FIND_MAX` | `0` | hunt-limit: 0 = until one works (Ctrl+C stops) |
| `WARP_WAIT` | `6` s | settle time after reconnect |
| `WARP_CALL_TIMEOUT` | `15` s | one warp-cli call cap |
| `WHERE_TIMEOUT` | `5` s | one `where` lookup cap |
| `WATCH` | `1` | log watcher on/off |
| `RESUME_MSG` | `continue` | auto-message for resume |
| `RESUME_AUTO` | `1` | auto-approve tool permissions during resume |
| `RESUME_TIMEOUT` | `90` s | hard cap on the resume message |
| `PROBE_MODEL` | `opencode/deepseek-v4.1-flash-free` | cheap model for the IP probe |
| `PROBE` | `1` | probe candidate IPs |
| `UPDATE_CHECK` | `0` | self-update on start (`[upd]` and `Update launcher.bat` always update, whatever this says) |
| `PROXY_PORT` | `40000` | WARP local proxy port |
| `TOR_SOCKS_PORT` | `9050` | portable Tor SOCKS port (auto-skip: a tor already listening here is used as it is) |
| `TOR_HTTP_PORT` | `8118` | local HTTP proxy that fronts the SOCKS port (the built-in bridge, or any Privoxy) |
| `TOR_AUTO_INSTALL` | `1` | download the portable Tor bundle when nothing answers on the ports |
| `TOR_BOOTSTRAP_WAIT` | `120` s | bootstrap wait cap before failing the TOR setup |
| `PROXY_LIST_URL` | ProxyScrape free list | your own list: a raw URL, or `file:///C:/path/lista.txt`; `ip:port` / `http(s)://ip:port` lines, `#`/`;` comments skipped |
| `PROXY_LIST_MIN_BYTES` | `20` | download size gate for the list; `0` = off, so a short custom list is accepted |
| `PROXY_TRY_MAX` | `12` | candidates tried per rotation before giving up |
| `PROXY_PROBE_TIMEOUT` | `8` s | one probe against one candidate proxy |

---

## 12. Compatibility notes

 - ASCII-only file, CRLF, no BOM - same behavior in any code page;
  no `C:\Users` strings anywhere; all paths via environment.
 - Windows 10 ?1803 (with `curl.exe`) -> full support. On older builds the
  PowerShell fallback covers everything needed.
 - PowerShell 5.1 (System32) - the launcher never depends on a different
  install; `PSX` is absolute.
 - x64 + arm64 native. **x86**: no WARP, but OpenCode runs (npm + 32-bit node).
 - Any current WARP GA (2023.3+ command set). Old warp-cli -> readable reason
  in wcli.log instead of silent failure.
 - opencode v2 (winget, npm, standalone, portable) - chosen by newest version;
  v1-with-v2-DB is detected and reported, not run.

---

## 13. Troubleshooting

| Symptom | Fix |
|---|---|
| `Start-Process : argument is NULL` at fresh start | you are on pre-v2.6; run `Update launcher.bat` once in that folder |
| `wcli.log` full of `exit 1` with NO reason | pre-v2.6 also; v2.6+ prints the daemon's message |
| downloads fail everywhere (MSI/zip/self-update) | v2.7+ retries through Windows proxy; check the printed URLs in a browser |
| `IP already burned, rotating` loops | free-tier quota; Ctrl+C stops the hunt |
| `deep reset` stops at `nothing to archive` | OpenCode refused to die; kill the process window and repeat |
| `[upd]` says the repo copy failed to apply | the downloaded copy stays in `%STATE_DIR%\upd_remote.bat`; replace manually |
| [upd] says the launcher matches the repo right after a release | you hit the stale raw/main CDN window (fixed in v2.12 - the updater now pins the commit SHA). Run [upd] again, or fetch a pinned commit copy with Update launcher.bat |
| `[3]` opens the modern dialog, ESC closes it and the classic opens right after | expected v2.15 behaviour: the modern cancel is the classic fallback. `install.log` shows `picker: modern returned nothing` followed by `picker: classic dialog starting`; cancelling the classic asks `Try again? [Y/N]` |
| `install.log` keeps saying `picker: nothing from the modern dialog` | you are on pre-v2.15, where the interop types were internal and the modern pick never landed. Update with `[upd]` (or `Update launcher.bat`) |
| `Invoke-WebRequest : positional parameter not found` while installing | you copied the old README one-liner that nests `PowerShell -Command`; PS 5.1 strips the inner quotes and the URL arrives split. Use the one-line install in section 2 (single shell, `Copy-Item`, no nested `-Command`) |
| my custom `PROXY_LIST_URL` list is ignored / "proxy list too small" | one proxy per line, `ip:port` or `http(s)://ip:port`; a short personal list hits the download gate - set `PROXY_LIST_MIN_BYTES=0`. `#`/`;` comment lines and a Notepad UTF-8 BOM are handled (v2.21) |
| TOR mode: `still not up after 120s` | the first bootstrap can be slower than the cap - raise `TOR_BOOTSTRAP_WAIT`. The last tor.log lines are printed next to the message; the log lives in `%LOCALAPPDATA%\opencode-launcher\tor\` |
| first paint shows `Another OpenCode launcher seems to be running. Continue anyway? [Y/N]` | a leftover lock in `%LOCALAPPDATA%\opencode-launcher\lock\` (usually a previous Ctrl+C). `Y` is safe - it is only an anti-double-open warning |
| `Terminate batch job (Y/N)?` | Windows is asking because Ctrl+C was pressed inside a batch context. Answer no - on a Spanish system the keys are S/N, and pressing N is what keeps the launcher running while S kills it there |

---

## 14. Verify the file

```
certutil -hashfile "OpenCode Infinite.bat" SHA256
```

The v2.26 file hashes to
`D7A42A71B33E9A9A36A789ADF20731C012AF1559C567F5D667CD87CE94810C33`.
A different hash means you are not on the shipped copy - re-download it
with the one-line install in section 2. Stale copies usually trace back
to mid-download truncation, or someone else's half-broken mirror.

### Why antivirus may flag it

One engine classically names this file `BAT.Obfuscated.10`. It is a heuristic,
not a signature: the scanner sees batch patterns that malware droppers also
use, and those patterns are here because a working launcher needs them:

| Pattern in this launcher | Why it exists here | Why AV flags it |
|---|---|---|
| `%TEMP%\oc_*.txt` scratch + `%RANDOM%` names (11 sites) | temp result files for the watcher, resume, probe and version checks; random names prevent two launcher instances trampling each other | files appear in %TEMP% with random names - the dropper signature |
| download to `%TEMP%` then execute | this is exactly how the launcher installs WARP/node/OpenCode when missing | download-and-execute is the textbook dropper flow |
| `start "" /b "%PSX%" ...` detached PowerShell children | the TUI wrapper, the watcher, every helper call | spawning hidden PowerShell from a batch |
| `if ... ( ... )` blocks with delayed expansion, `^|` `^&` escapes, `>nul 2>&1` | batch needs this to be robust inside `if`/`for` blocks | "obfuscated" = lots of escapes in one file |
| one ~3,100-line `.bat` with ~100 `call :label` targets | every feature lives in its own subroutine | size + goto density beats the scanner's normal-file heuristics |

The complete outbound footprint is these public hosts -
`raw.githubusercontent.com` + `github.com` (launcher updates, OpenCode
release zip), `downloads.cloudflareclient.com` (WARP MSI), `nodejs.org`
(32-bit node MSI), `aus1.torproject.org` + `dist.torproject.org`
(portable Tor bundle, TOR mode only), `www.cloudflare.com` (the
`cdn-cgi/trace` IP check), `api.proxyscrape.com` or whatever
`PROXY_LIST_URL` points to (PROXY mode - your own list, your own host).
No base64/`-EncodedCommand` blobs, no registry writes, no persistence keys,
no startup folders, no scheduled tasks, no self-copy into system paths,
and it deletes its own `%TEMP%` scratch on every exit.

If your selected engine still dislikes the file, the practical answer is:
hash-verify your copy, then submit the hash as a false positive to that
engine's portal (Microsoft, Avira, DrWeb all accept submissions).

Quick structural checks with findstr:

```
findstr /n "self_update" "OpenCode Infinite.bat"
findstr /n "install_node_x86" "OpenCode Infinite.bat"
findstr /n "UPDATE_URL" "OpenCode Infinite.bat"
```

---
**jeko1107** - https://github.com/jeko1107/opencode-infinite - launcher lives and keeps itself current.
