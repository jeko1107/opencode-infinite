# OpenCode Infinite — launcher handbook (v2.9)

A single-file Windows batch launcher for OpenCode that adds Cloudflare WARP
egress rotation, dependency bootstrap, changed-IP auto-resume, watching of
fatal errors, an UPD self-updater and a one-click updater bootstrap.

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
   registration and requests a new one — which yields a different exit IP —
   then reopens the same session, no input;
3. probes every candidate IP with one cheap message on a throwaway session, so
   burned IPs are skipped (hunt can be unlimited with `IP_FIND_MAX=0`).

It also installs what it needs (WARP, OpenCode, 32-bit node) so it can start
from a bare machine.

---

## 2. One-command install

**PowerShell / Windows Terminal (recommended):**

```powershell
iwr "https://raw.githubusercontent.com/jeko1107/opencode-infinite/main/OpenCode%20Infinite.bat" -UseBasicParsing -OutFile "$env:TEMP\oci.bat"; PowerShell -NoProfile -ExecutionPolicy Bypass -Command '[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -UseBasicParsing -Uri "https://raw.githubusercontent.com/jeko1107/opencode-infinite/main/OpenCode%20Infinite.bat" -OutFile "$env:USERPROFILE\Desktop\OpenCode Infinite.bat"'; & $env:TEMP\oci.bat
```

`cmd` (one window, classic shell):

```cmd
powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -UseBasicParsing -Uri 'https://raw.githubusercontent.com/jeko1107/opencode-infinite/main/OpenCode%%20Infinite.bat' -OutFile \"%USERPROFILE%\Desktop\OpenCode Infinite.bat\""
```

After the first run, the launcher verifies itself against the repo on every
start: if a newer copy is live on `main`, it says so and, with your approval,
backs itself up and swaps in the new version on a harmless restart — no laps
to keep provoking your memory.

**If a machine runs an OLD version (no [upd] block):** in the same folder, run
the repo companion file `Update launcher.bat`; it replaces the old copy
(Beside, Desktop, or OneDrive-Desktop, first hit) with the current one.

---

## 3. Quick start in the launcher

| How you start it | What happens |
|---|---|
| Double-click | Folder menu, then the main menu |
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
| `%ProgramFiles%\NodeJS%...` | node 32-bit (WSL/via winget/MSI) | launcher instruction |
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
| `[3]` | Change IP | rotates the WARP exit IP, back to menu |
| `[4]` | Folder | change working folder |
| `[5]` | Deep reset | kill OpenCode, archive chats to the Desktop, clear tokens, fresh session |
| `[6]` | Exit | closes the lock and leaves |

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

Search order in `:find_opencode` — all candidates are versioned and the
newest WIN (old v1-vs-v2 database mismatch reported instead of failing):

1. PATH lookup (opencode.exe / .cmd / .bat)
2. `%APPDATA%\npm\opencode.cmd` — npm shim
3. `%LOCALAPPDATA%\Programs\opencode\opencode.exe`
4. `%LOCALAPPDATA%\opencode\bin\opencode.exe` — standalone install by this script
5. `%USERPROFILE%\.opencode\bin\opencode.exe`

Install fallback:

> npm present → `npm install -g opencode-ai`
> npm absent → standalone build from GitHub releases (x64 or arm64)

### NEW in v2.9 — auto-rotate hardening (the "hit the limit, keep going" fix)

Cloudflare rate-limits rapid `registration new` bursts with HTTP 429. The old
rotate loop retried 4 times ~6 s apart, hit the throttle, and handed control
back with an error and a pause. v2.9:

- waits `ROTATE_COOLDOWN` (10 s) between rotate attempts — burst becomes
  spaced traffic the throttle accepts;
- after one failed cycle, cools down 60 s and runs **whole new rounds**
  (`ROTATE_ROUNDS` = 3) — minutes of throttle are ridden out without a
  single keystroke;
- only when every round is spent does it pause at the menu with the
  `wcli.log` pointer;
- the resume after a successful rotation still reopens the same session
  (`--continue`) with the auto-resume message, so the chat picks up where
  the quota error cut it.

### NEW in v2.8 — 32-bit Windows (x86) support

OpenCode publishes no x86 binary. On real 32-bit Windows the script goes:
bootstrap **32-bit node.js** first, then install OpenCode from npm.

- `:install_node_x86`:
  1. `winget install OpenJS.NodeJS.LTS` (10-min cap, silent)
  2. winget missing → pinned **nodejs.org v22 LTS x86 MSI** with the same
     size gate, Windows-proxy fallback, silent `/qn /norestart` after UAC
  3. PATH refresh, npm verification
- Then: `npm install -g opencode-ai`, the version lookup runs again.

### Downloads in v2.7+ — proxy fallback

Every download sites (self-update, WARP MSI, OpenCode zip, node MSI) tries:

1. direct `curl -f --noproxy "*"` first
2. if egress is blocked (firewalls, transparent proxies) → PowerShell
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
- **`:watch_start`** — background watcher tails `opencode.log` from the
  pre-launch byte offset every 2s looking for
  `Failed to drain Session / free usage limit / rate limit / ...`. It waits
  4 seconds and only kills the TUI if no INFO/DEBUG recovery lines arrived —
  so a self-healing stream never gets murdered. Only a stuck chat dies.
- **`:resume_run`** — resume message with hard `RESUME_TIMEOUT`, captured out
  and err files, `--standalone` server born under THIS proxy env (the old
  background server still holds the dead tunnel's sockets otherwise).
- Quota/fatal errors on the new IP cause **another rotation**, full auto.

---

## 8. `wcli.log` — every warp-cli failure with the daemon's own words

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
2. size ≥ 20 KB + `REM  OpenCode launcher` header gate (no HTML pages, no
   wrong resources)
3. version strings from `(vX.Y)` compared with the running file
4. equal → one clean line `[upd] launcher matches the repo`. Different →
   `[upd] update found: local v… - repo v…` and a `[Y/N]` prompt.
5. On `Y`: backup to `%STATE_DIR%\OpenCode Infinite backup <ver>.bat`, then a
   tiny helper waits for this cmd to release the .bat, swaps the new one in,
   restarts. The main script exits before anything reads the swapped file.

The check is silent when offline or when the repo is unreachable.

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
| `UPDATE_CHECK` | `1` | [upd] self-update on start |
| `PROXY_PORT` | `40000` | WARP local proxy port |

---

## 12. Compatibility notes

- ASCII-only file, CRLF, no BOM — same behavior in any code page;
  no `C:\Users` strings anywhere; all paths via environment.
- Windows 10 ≥1803 (with `curl.exe`) → full support. On older builds the
  PowerShell fallback covers everything needed.
- PowerShell 5.1 (System32) — the launcher never depends on a different
  install; `PSX` is absolute.
- x64 + arm64 native. **x86**: no WARP, but OpenCode runs (npm + 32-bit node).
- Any current WARP GA (2023.3+ command set). Old warp-cli → readable reason
  in wcli.log instead of silent failure.
- opencode v2 (winget, npm, standalone, portable) — chosen by newest version;
  v1-with-v2-DB is detected and reported, not run.

---

## 13. Troubleshooting

| Symptom | Fix |
|---|---|
| `Start-Process : El argumento es NULL` at fresh start | you are on pre-v2.6; run `Update launcher.bat` once in that folder |
| `wcli.log` full of `exit 1` with NO reason | pre-v2.6 also; v2.6+ prints the daemon's message |
| downloads fail everywhere (MSI/zip/self-update) | v2.7+ retries through Windows proxy; check the printed URLs in a browser |
| `IP already burned, rotating` loops | free-tier quota; Ctrl+C stops the hunt |
| `deep reset` stops at `nothing to archive` | OpenCode refused to die; kill the process window and repeat |
| `[upd]` says the repo copy failed to apply | the downloaded copy stays in `%STATE_DIR%\upd_remote.bat`; replace manually |
| `Invoke-WebRequest : No se encuentra ningún parámetro de posición que acepte el argumento 'Infinite.bat'` while installing | you copied the old README one-liner that nests `PowerShell -Command`; PS 5.1 strips the inner quotes and the URL arrives split. Use the one-line install in section 2 (single shell, `Copy-Item`, no nested `-Command`) |
| first paint shows `Another OpenCode launcher seems to be running. Continue anyway? [Y/N]` | a leftover lock in `%LOCALAPPDATA%\opencode-launcher\lock\` (usually a previous Ctrl+C). `Y` is safe — it is only an anti-double-open warning |
| `¿Desea terminar el trabajo por lotes (S/N)?` | Windows seen when Ctrl+C was pressed inside a batch context. `N` keeps the launcher running; `S` kills it there |

---

## 14. Verify the file

```
certutil -hashfile "OpenCode Infinite.bat" SHA256
```

Quick structural checks with findstr:

```
findstr /n "self_update" "OpenCode Infinite.bat"
findstr /n "install_node_x86" "OpenCode Infinite.bat"
findstr /n "UPDATE_URL" "OpenCode Infinite.bat"
```

---
**jeko1107** · https://github.com/jeko1107/opencode-infinite · launcher lives and keeps itself current.
