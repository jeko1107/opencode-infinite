# OpenCode Infinite - launcher reference

A single-file Windows batch launcher for OpenCode that adds
Cloudflare WARP egress rotation, dependency bootstrap and a confirmation-gated reset.

- File: `OpenCode Infinite.bat`
- Size: 23,249 bytes, 646 lines, CRLF, ASCII only, no BOM
- SHA-256: `B367EBC6F022E8BB324084441A69D996360466200B188A5B410BC12F7F501955`
- Target: Windows 10 / 11, x64 or ARM64
- Admin required: only for the optional WARP install (UAC prompt once). Everything else is user mode.

---

## 1. What problem it solves

Free-tier AI endpoints usually rate-limit **per egress IP** and **per session context**.
The launcher does three things about that:

1. launches OpenCode with the WARP proxy attached, so the provider sees Cloudflare's exit IP
   instead of yours;
2. when a run ends badly (quota line in the log, crash, or you press Ctrl+C), asks WARP for a
   brand new registration, which yields a different exit IP, then reopens the session;
3. keeps doing that, one press at a time, until a run goes through.

It also installs what it needs (WARP, OpenCode) so it can run on a machine that has neither.

---

## 2. Quick start

| How you start it | What happens |
|---|---|
| Double-click | Folder menu, then the main menu |
| Drag a folder onto the `.bat` | Jumps straight into that folder |
| `OpenCode Infinite.bat "D:\work\project"` | Same, from a shell |
| `OpenCode Infinite.bat \\server\share` | UNC paths work (`pushd`, not `cd /d`) |

If neither WARP nor OpenCode are installed, the script offers to fetch both. Nothing is
installed silently and no system PATH is modified permanently.

---

## 3. Files and folders it uses

| Path | Purpose | Created by |
|---|---|---|
| `%USERPROFILE%\.local\share\opencode\` | OpenCode data dir: `opencode.db`, `opencode.db-wal`, `opencode.db-shm`, `auth.json` | OpenCode |
| `%USERPROFILE%\.local\share\opencode\log\opencode.log` | The log the quota check reads | OpenCode |
| `%USERPROFILE%\.cache\opencode\` | OpenCode cache, wiped only by Deep reset | OpenCode |
| `%LOCALAPPDATA%\opencode-launcher\lastfolder.txt` | Remembers the last working folder | This script |
| `%LOCALAPPDATA%\opencode-launcher\lastip.txt` | Remembers the last egress IP, so `[1]` never reuses it | This script |
| `%LOCALAPPDATA%\opencode\bin\opencode.exe` | Standalone OpenCode, when installed by this script | This script |
| `%USERPROFILE%\Desktop\opencode_chats_archiviate\<stamp>\` | Chat archive, only created by `[5] Deep reset` | This script |
| `%TEMP%\Cloudflare_WARP_x64.msi` | Download scratch, deleted after install | This script |
| `%TEMP%\opencode-windows.zip` | Download scratch, deleted after extract | This script |

---

## 4. Flow at a glance

```
start
  -> pick a working folder        (drag, argument, or folder menu)
  -> find WARP                    (optional, offers install)
  -> find OpenCode                (optional, offers install)
  -> main menu
       [1] Fresh start   -> rotate if the IP repeats, then launch
       [2] Continue      -> launch as-is
       [3] Change IP     -> rotate only, back to menu
       [4] Folder        -> change working folder
       [5] Deep reset    -> confirm, archive chats, wipe tokens, new session
       [6] Exit
  -> OpenCode runs
  -> it exits
       crash ................ rotate + reopen, no prompt
       quota line in log .... rotate + reopen, no prompt
       clean exit ........... 5 s window: [Y] rotate + reopen (default), [N] menu
```

---

## 5. Folder menu

| Key | Action |
|---|---|
| `[1]` | Reopen the last folder (disabled with a message if nothing is saved yet) |
| `[2]` | Use the folder the `.bat` is sitting in |
| `[3]` | Windows folder picker (`FolderBrowserDialog`) |
| `[4]` | Exit |

The chosen folder is written to `lastfolder.txt` and the window title is set to `OpenCode`.

---

## 6. Dependency bootstrap

### WARP (optional)

Search order for `warp-cli.exe`:

1. `where warp-cli.exe`
2. `%ProgramFiles%\Cloudflare\Cloudflare WARP\`
3. `%ProgramW6432%\Cloudflare\Cloudflare WARP\` (skipped on 32-bit Windows)
4. `%ProgramFiles(x86)%\Cloudflare\Cloudflare WARP\`
5. `%LOCALAPPDATA%\Cloudflare\Cloudflare WARP\`

If not found, the menu offers a download:

- URL: `https://downloads.cloudflareclient.com/v1/download/windows/ga`
  (redirects to the current release; the old `1.1.1.1/Cloudflare_WARP_x64.msi` path is dead)
- Download goes out with `--noproxy "*"`, because the proxy it configures later is WARP itself
  and nothing is listening on port 40000 yet.
- The download is validated **by size, not by exit code**: anything at or below 5 MB is
  rejected, so an HTML error page can never be installed as an MSI.
- Install runs `msiexec /i ... /qn` elevated. One UAC prompt.

Without WARP the launcher still works: no rotation, no proxy, everything else identical.

### OpenCode

Search order in `:find_opencode`:

1. `where opencode.exe`, then `.cmd`, then `.bat` (extension order matters: npm installs ship a
   `.cmd` shim next to a `.ps1`)
2. `%APPDATA%\npm\opencode.cmd`
3. `%LOCALAPPDATA%\Programs\opencode\opencode.exe`
4. `%LOCALAPPDATA%\opencode\bin\opencode.exe` (installed by this script)
5. `%USERPROFILE%\.opencode\bin\opencode.exe`

If nothing is found:

- **npm present** -> `npm install -g opencode-ai`. If that does not produce a runnable binary,
  it falls through to the standalone build instead of failing.
- **npm absent** -> straight to the standalone build.
- Standalone URL: `https://github.com/sst/opencode/releases/latest/download/opencode-windows-<arch>.zip`
  with `<arch>` = `x64`, or `arm64` when `%PROCESSOR_ARCHITECTURE%` is `ARM64`.
- Same download rules as WARP: `--noproxy "*"`, `-f`, 5 MB size gate, then `Expand-Archive`
  into `%LOCALAPPDATA%\opencode\bin` and that folder is appended to `PATH` for this session.

No Node.js, no Scoop, no package manager and no admin are required for the standalone route.

---

## 7. Main menu

| Key | Option | Files touched | Rotation |
|---|---|---|---|
| `[1]` | Fresh start | none | asks WARP for a new IP if the stored one repeats, then launches |
| `[2]` | Continue | none | none |
| `[3]` | Change IP | none | rotates, shows the new IP, back to menu |
| `[4]` | Folder | writes `lastfolder.txt` | none |
| `[5]` | Deep reset | **yes**, after `[Y/N]` | rotates as part of the reset |
| `[6]` | Exit | none | none |

The header of the menu shows the working folder and the current exit IP, measured through the
WARP proxy when the tunnel is up.

---

## 8. Rotation engine

Three call sites share the same primitives.

**`:getip`** - reads `https://www.cloudflare.com/cdn-cgi/trace` and takes the `ip=` field.
Forces IPv4 with `-4`; tries through the proxy first, falls back to a direct request. 10 s cap.

**`:warp_up`** - `warp-cli --accept-tos mode proxy`, then `--accept-tos connect`.

**The rotation itself** - `disconnect`, then `registration new`, then `warp_up`, then wait
`WARP_WAIT` seconds and measure again. `registration new` is the part that actually changes the
exit IP; a plain reconnect usually returns the same address.

| Call site | Tries | On failure |
|---|---|---|
| `[1] Fresh start` (`:ensure_new_ip`) | up to `ROTATE_TRIES_MAX` (4) | launches anyway on the current IP, with a message |
| `[3] Change IP` (`:rotate`) | one | shows the IP it got |
| after a run (`:auto_rotate`) | up to `ROTATE_TRIES_MAX` (4) | stops and returns to the menu |

A rotation that succeeds reopens OpenCode immediately with `--continue`, so the same
conversation comes back on the new IP.

---

## 9. Quota detection

After OpenCode exits with code 0, `:check_quota` reads **only the bytes written during this run**:

1. `SIZE_BEFORE` is the log size captured just before launch.
2. PowerShell opens the log, seeks to `SIZE_BEFORE`, reads to the end.
3. It looks for the exact string `free usage limit` (case-insensitive).
   That is what OpenCode writes: `AI.Error: Free usage limit reached`.
4. `HIT` / `NOHIT` goes to a temp file, which is read back and deleted.

Why the byte offset: the log is append-only and can be megabytes long. Without the offset, one
old quota line would trigger a rotation on every future launch.

Why the exact string: broader patterns like `quota` or `rate limit` appear in unrelated log
lines (MCP servers, tunnels) and would cause pointless rotations.

Note: this check runs **after** OpenCode exits. It does not watch the log live.

---

## 10. Ctrl+C behaviour

OpenCode exits when you press Ctrl+C. The launcher reacts to that exit:

| Exit condition | What the launcher does |
|---|---|
| Non-zero exit code | `OpenCode exited with code N` -> rotate -> reopen, no prompt |
| Exit 0, quota line in this run's log | `Free quota reached on this IP` -> rotate -> reopen, no prompt |
| Exit 0, clean log | 5 second window: `[Y]` (default) rotate and reopen, `[N]` back to the menu |

The 5 second window is `choice /c yn /n /t 5 /d y`. With no key pressed, `choice` returns the
default (`Y`) and rotation proceeds, so one Ctrl+C is one new IP without any further input.
Pressing `N` is the way out of the loop.

Each launch after a rotation clears `RESUME`, then sets it again, so the relaunch uses
`--continue`: history survives the rotation.

---

## 11. Proxy handling

The proxy is **not** exported at startup. If it were, every download would be sent to
`127.0.0.1:40000` before WARP exists, and nothing listens there.

`:export_proxy` runs immediately before `call "%OC_CMD%"` and does this:

1. If WARP is not present, export nothing.
2. Probe the proxy with one real HTTPS request through it
   (`curl --max-time 5 --noproxy "" --proxy http://127.0.0.1:40000`).
   Without curl, fall back to a 1.5 s TCP connect via PowerShell.
3. If the probe fails, **do not export** and print
   `[!] WARP proxy is not answering - using the direct connection.`
4. Only then set `HTTP_PROXY`, `HTTPS_PROXY` and `no_proxy`.

This is what prevents the `ECONNRESET` storm: a `warp-cli.exe` on disk is not proof of a
working tunnel, and a dead proxy that accepts connections and then resets them is worse than
no proxy at all.

`no_proxy` is set to `localhost,127.0.0.1,0.0.0.0`.

---

## 12. Deep reset (`[5]`)

The only option that touches user files, and it asks first:
`Do that now? [Y/N]` - `N` returns to the menu without a single write.

When confirmed:

1. **`:stop_opencode`** - `opencode service stop`, then `taskkill /f` on `OpenCode.exe`,
   `opencode.exe`, `opencode-cli.exe`. The database is locked while OpenCode runs, so this is
   required before moving it.
2. **`:deep_archive`** - moves `storage\` (if it exists), `opencode.db`, `opencode.db-wal`,
   `opencode.db-shm` into
   `Desktop\opencode_chats_archiviate\<yyyyMMdd-HHmmss>\`.
   The timestamp makes every archive unique; nothing is ever overwritten. If there was nothing
   to move, the empty folder is removed again.
3. **`:clear_tokens`** - deletes `%USERPROFILE%\.cache\opencode\` and
   `%USERPROFILE%\.local\share\opencode\auth.json`.
   This is a real deletion: you will have to sign in to your provider again.
4. **`:prime_spoof`** - sets the three variables the original Discord script used.
5. Starts OpenCode on a new session (no `--continue`).

Desktop detection uses `[Environment]::GetFolderPath('Desktop')` first, because OneDrive
redirection and non-English profile names break the naive `%USERPROFILE%\Desktop` assumption.
It falls back to `OneDrive\Escritorio`, `OneDrive\Desktop`, `Desktop`, then `%USERPROFILE%`.

### Restoring an archive

```
move "%USERPROFILE%\Desktop\opencode_chats_archiviate\20261027-192335\opencode.db" "%USERPROFILE%\.local\share\opencode\"
```

Do the same for `opencode.db-wal` and `opencode.db-shm` if they were archived. Open OpenCode
afterwards and the sessions are back.

---

## 13. The promise: options 1-4 touch nothing

`[1]`, `[2]`, `[3]` and `[4]` contain no `move`, no `del`, no `rmdir` and no `taskkill`.
This is enforced, not just claimed: a static checker walks the whole `:run` block and fails if
any of those verbs appears in it.

Every `move` in the file lives inside `:deep_archive`, every `taskkill` inside `:stop_opencode`,
every `rmdir` in the reset path. The only `del` calls remove temp downloads, the temp quota
file, and the tokens during a reset.

---

## 14. Settings you can edit

Top of the file, section `settings (edit freely)`:

| Variable | Default | Meaning |
|---|---|---|
| `ROTATE_TRIES_MAX` | `4` | Rotation attempts before giving up and staying on the current IP |
| `WARP_WAIT` | `6` | Seconds to wait after a WARP reconnect before measuring the IP |

Internal, change only if you know why:

| Variable | Default | Meaning |
|---|---|---|
| `PROXY_PORT` | `40000` | WARP local proxy port, used to build `PROXY` |
| `TRACE_URL` | `cloudflare.com/cdn-cgi/trace` | Where the exit IP is read from |
| `WARP_MSI_URL` | `downloads.cloudflareclient.com/.../ga` | WARP installer URL |
| `NO_PROXY` | `localhost,127.0.0.1,0.0.0.0` | Exclusions handed to the child |

---

## 15. Environment handed to OpenCode

| Variable | When | Value |
|---|---|---|
| `HTTP_PROXY` | only if the proxy probe succeeded | `http://127.0.0.1:40000` |
| `HTTPS_PROXY` | same | `http://127.0.0.1:40000` |
| `no_proxy` | same | `localhost,127.0.0.1,0.0.0.0` |
| `OPENCODE_SYNTHESIZE_CLI_HEADERS` | after Deep reset | `true` |
| `OPENCODE_CLIENT_UA` | after Deep reset | `opencode/1.18.25` |
| `OPENCODE_SESSION_ID` | after Deep reset | `msg_<random>` |

Command line: `--continue` when resuming after a rotation, nothing otherwise.

---

## 16. Compatibility notes

- **ASCII only.** No accents, no BOM, CRLF. This is why the same file renders identically on
  any Windows locale; accented `echo` lines break under a different code page.
- **`pushd` for folders**, not `cd /d`, so UNC paths work.
- **`call "%OC_CMD%"`**, not `"%OC_CMD%"`: npm installs OpenCode as a `.cmd` shim and calling it
  directly would terminate the batch.
- **PowerShell by absolute path** (`%PSX%`) for every helper call, so a broken `PATH` cannot
  silently turn into a no-op.
- **curl** is used when present (Windows 10 1803+), PowerShell otherwise.
- **No admin, no services, no scheduled tasks, no registry writes.** The only elevated step is
  the optional WARP MSI install.

---

## 17. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Retry due - ECONNRESET` inside OpenCode | A model stream was cut mid-response (provider congestion, CDN, antivirus, VPN). Not the launcher. | Press Ctrl+C and let the launcher rotate; if it repeats on every model, check antivirus HTTPS inspection |
| `AI.Error: Free usage limit reached` | Per-IP free quota exhausted | Ctrl+C -> the launcher rotates and reopens |
| `[!] WARP proxy is not answering` | WARP binary exists but the tunnel is down | The run continues on the direct connection; restart WARP for rotation |
| `[auto-install] npm did not deliver it, going standalone` | npm present but `opencode-ai` did not install | Nothing to do, the standalone build takes over |
| `[!] download failed` with a URL below | Network blocked the release host, or a proxy interfered | Open the printed URL in a browser and install by hand |
| `[!] Cloudflare WARP not found` | WARP not installed | Accept the install offer, or install from 1.1.1.1 |
| Rotation says `same IP every time` | WARP refused to hand out a new address | Wait and retry later; the launcher stops instead of looping forever |
| `Terminate batch job (Y/N)?` after Ctrl+C | Windows asking if the script itself should die | Answer `N` so the rotation can run |

---

## 18. Known limits

- The rotation cannot be verified from a session that itself egresses through WARP: running
  `registration new` kills that session's own tunnel mid-answer. What is verified is the logic,
  not the physical IP change.
- The quota check only evaluates **after** OpenCode exits; it never watches the log live.
- The `Retry due` banner is a TUI string and is **not** written to `opencode.log`; that is why
  the trigger is the exit itself, not a log pattern. The only network errors that appear in the
  log are local service restarts, which would cause false rotations.
- Deep reset needs OpenCode to be closable; if the process refuses to die, the database stays
  locked and the move fails with `nothing to archive`.

---

## 19. Verifying the file yourself

```
certutil -hashfile "OpenCode Infinite.bat" SHA256
```

Expect `b367ebc6f022e8bb324084441a69d996360466200b188a5b410bc12f7f501955`.

Quick structural checks with Notepad or `findstr`:

```
findstr /n ":proxy_ok" "OpenCode Infinite.bat"
findstr /n ":deep_archive" "OpenCode Infinite.bat"
findstr /n "PROXY_PORT" "OpenCode Infinite.bat"
```

---

## 20. Build fingerprint

| Field | Value |
|---|---|
| Bytes | 23,249 |
| Lines | 646 |
| Encoding | ASCII, CRLF, no BOM |
| SHA-256 | `B367EBC6F022E8BB324084441A69D996360466200B188A5B410BC12F7F501955` |
| Static assertions | 56 passing |
| Sandbox assertions | 34 passing |

Sandbox tests include byte-identical checks that `opencode.db`, `opencode.db-wal`,
`opencode.db-shm` and `auth.json` are unchanged after every subroutine that is not the reset,
and that a simulated Deep reset archives inside the sandbox without ever touching the real
Desktop.
