@echo off
setlocal EnableExtensions
title OpenCode
REM ============================================================
REM  OpenCode launcher
REM  WARP egress rotation + dependency bootstrap.
REM
REM  Usage:
REM    double-click                     -> folder menu
REM    drag a folder onto this file     -> opens in that folder
REM    OpenCode.bat "D:\work\project"   -> opens in that folder
REM
REM  This script never moves, renames or deletes your chats, your
REM  history or any file of yours. It starts opencode, and rotates
REM  the WARP egress IP when you ask it to.
REM
REM  Everything is user-mode. UAC is only needed if WARP
REM  has to be installed, and WARP is optional: without it the
REM  launcher still starts opencode, only rotation is skipped.
REM ============================================================

REM ---------- settings (edit freely) --------------------------------
REM Rotation attempts when the quota looks used up.
set "ROTATE_TRIES_MAX=4"
REM Seconds to wait after (re)connecting WARP.
set "WARP_WAIT=6"

REM ---------- internal ---------------------------------------------
set "PROXY=http://127.0.0.1:40000"
set "TRACE_URL=https://www.cloudflare.com/cdn-cgi/trace"
set "HTTP_PROXY=%PROXY%"
set "HTTPS_PROXY=%PROXY%"
set "NO_PROXY=localhost,127.0.0.1,0.0.0.0"
set "no_proxy=%NO_PROXY%"

set "DATA_DIR=%USERPROFILE%\.local\share\opencode"
set "LOGFILE=%DATA_DIR%\log\opencode.log"
set "STATE_DIR=%LOCALAPPDATA%\opencode-launcher"
set "LASTFOLDER=%STATE_DIR%\lastfolder.txt"
set "RESUME="
set "COLD=0"
set "HAS_WARP=0"
set "WARP_UP=0"
set "QHIT="
set "IP="
set "WARP="
set "OC_CMD="

if not exist "%STATE_DIR%" mkdir "%STATE_DIR%" >nul 2>&1

REM ============================================================
REM  1) WORKING FOLDER
REM ============================================================
REM optional: folder dropped on the file, or passed as an argument
if not "%~1"=="" if exist "%~1\" (
  set "OPFOLDER=%~1"
  goto :folder_ok
)

:folder
cls
echo ============================================================
echo   OpenCode - choose a folder to work in
echo ============================================================
echo.
set "OPFOLDER="
set "LASTPATH="
if exist "%LASTFOLDER%" set /p LASTPATH=<"%LASTFOLDER%"
if defined LASTPATH if not exist "%LASTPATH%" set "LASTPATH="
echo.
if defined LASTPATH (
  echo   [1] Reopen the last folder
  echo       %LASTPATH%
) else (
  echo   [1] Reopen the last folder      ^(nothing saved yet^)
)
echo   [2] Use this folder
echo       %CD%
echo   [3] Browse for a folder...
echo   [4] Exit
echo.
echo   One key, no Enter.
echo.
choice /c 1234 /n /m "Pick: "
if errorlevel 4 goto :quit
if errorlevel 3 goto :pick_folder
if errorlevel 2 goto :use_current
if not defined LASTPATH (
  echo.
  echo   No folder saved yet. Use [2] or [3] this time.
  timeout /t 3 /nobreak >nul 2>&1
  goto :folder
)
set "OPFOLDER=%LASTPATH%"
goto :folder_ok

:use_current
set "OPFOLDER=%CD%"
goto :folder_ok

:pick_folder
echo.
echo   Choose a folder in the dialog...
set "OPFOLDER="
for /f "usebackq delims=" %%i in (`powershell -NoProfile -STA -Command "Add-Type -AssemblyName System.Windows.Forms; $d = New-Object System.Windows.Forms.FolderBrowserDialog; $d.Description = 'Folder to open OpenCode in'; $d.ShowNewFolderButton = $true; if ($d.ShowDialog() -eq 'OK') { $d.SelectedPath }"`) do set "OPFOLDER=%%i"
if not defined OPFOLDER (
  echo.
  echo   No folder selected.
  choice /c YN /n /m "   Try again? [Y/N]: "
  if not errorlevel 2 goto :pick_folder
  goto :folder
)
goto :folder_ok

:folder_ok
if not exist "%OPFOLDER%\" (
  echo.
  echo   Folder not found: "%OPFOLDER%"
  timeout /t 3 /nobreak >nul 2>&1
  goto :folder
)
REM pushd handles UNC paths, cd /d does not.
pushd "%OPFOLDER%" 2>nul
if errorlevel 1 (
  echo.
  echo   Cannot enter: "%OPFOLDER%"
  timeout /t 3 /nobreak >nul 2>&1
  goto :folder
)
set "POPPED=1"
>"%LASTFOLDER%" echo %CD%
title OpenCode
echo.
echo   Working in: %CD%
echo.

REM ============================================================
REM  2) DEPENDENCIES
REM ============================================================
set "HAVE_CURL=1"
where curl.exe >nul 2>&1
if errorlevel 1 set "HAVE_CURL=0"

REM ---------- WARP (optional) ----------
call :find_warp
if defined WARP goto :check_opencode

echo   [!] Cloudflare WARP not found - IP rotation will be disabled.
echo       Install it later from 1.1.1.1 if you want the rotation.
echo.
choice /c YN /n /m "   Try to download and install WARP now? [Y/N]: "
if errorlevel 2 goto :check_opencode
call :install_warp
call :find_warp
if defined WARP echo   [ok] WARP ready.
if not defined WARP echo   [!] WARP still not available - continuing without rotation.

REM ---------- opencode ----------
:check_opencode
call :find_opencode
if defined OC_CMD goto :ready

echo   [auto-install] opencode not found, installing with npm...
where npm >nul 2>&1
if errorlevel 1 goto :no_npm
goto :npm_install

:no_npm
where scoop >nul 2>&1
if errorlevel 1 (
  echo   [auto-install] npm and scoop missing.
  echo   Scoop installs into the user folder, no admin needed.
  choice /c YN /n /m "   Install scoop + node now? [Y/N]: "
  if errorlevel 2 (
    echo   ERROR: opencode cannot be installed without node/npm.
    echo   Install Node.js from nodejs.org, then run this again.
    pause
    goto :quit
  )
  powershell -NoProfile -ExecutionPolicy Bypass -Command "irm get.scoop.sh | iex"
  set "PATH=%PATH%;%USERPROFILE%\scoop\shims"
  where scoop >nul 2>&1
  if errorlevel 1 (
    echo   ERROR: scoop did not become available. Reopen this window and retry.
    pause
    goto :quit
  )
)
echo   [auto-install] installing nodejs with scoop...
call scoop install nodejs
where npm >nul 2>&1
if errorlevel 1 (
  echo   ERROR: node installed but npm is not on PATH. Reopen this window.
  pause
  goto :quit
)

:npm_install
call npm install -g opencode-ai
set "PATH=%PATH%;%APPDATA%\npm"
call :find_opencode
if not defined OC_CMD (
  echo   ERROR: opencode install failed or is not on PATH.
  pause
  goto :quit
)
echo   [ok] opencode ready.

:ready
timeout /t 1 /nobreak >nul 2>&1

REM ============================================================
REM  3) MENU
REM ============================================================
:menu_loop
cls
echo ============================================================
echo   OpenCode
echo.
echo   Folder : %CD%
if defined WARP (
  echo   WARP   : %WARP%
) else (
  echo   WARP   : none ^(rotation disabled^)
)
echo ============================================================
echo.

if not defined WARP goto :menu_ip
if "%WARP_UP%"=="1" goto :menu_ip
call :warp_up
set "WARP_UP=1"
:menu_ip
if defined WARP call :getip IP
if not defined IP set "IP=unknown"
echo   Exit IP: %IP%
echo.
echo   What do you want to do?
echo.
echo   [1] Fresh start   - get a new IP, then open OpenCode
echo                       (your chats and history stay untouched)
echo   [2] Continue      - same IP, open OpenCode as it was
echo   [3] Change IP     - rotate only, do not open OpenCode
echo   [4] Folder        - work in a different folder
echo   [5] Exit
echo.
echo   One key, no Enter.
echo.
choice /c 12345 /n /m "Pick: "
if errorlevel 5 goto :quit
if errorlevel 4 goto :folder
if errorlevel 3 goto :rotate
if errorlevel 2 goto :run_warm
goto :run_cold

:run_cold
set "COLD=1"
goto :run

:run_warm
set "COLD=0"
goto :run

:run
echo.
if "%COLD%"=="1" echo --- fresh start ---------------------------------------------
if not "%COLD%"=="1" echo --- continue ------------------------------------------------
echo     %CD%

REM the free tier counts per egress IP: never launch a fresh start on
REM the same IP the previous run used. nothing else is touched.
if "%COLD%"=="1" if defined WARP call :ensure_new_ip

set "SIZE_BEFORE=0"
for %%S in ("%LOGFILE%") do if not "%%~zS"=="" set "SIZE_BEFORE=%%~zS"

set "FLAGS="
if defined RESUME set "FLAGS=--continue"
if defined RESUME echo   reopening the last session on the new IP...
set "RESUME="

REM opencode ships as a .cmd shim on npm installs: call is mandatory.
call "%OC_CMD%" %FLAGS%
set "EC=%errorlevel%"
echo.

if not "%EC%"=="0" goto :quota_rotate
if not defined WARP goto :closed
call :check_quota
if defined QHIT goto :quota_rotate

:closed
echo OpenCode closed normally.
if not defined WARP goto :menu_loop
choice /c YN /n /m "Reopen with a different IP? [Y/N]: "
if not errorlevel 2 goto :rotate
goto :menu_loop

:quota_rotate
echo OpenCode exited with code %EC%.
if not defined WARP goto :menu_loop
echo Getting a new IP before the next attempt...
timeout /t 3 /nobreak >nul 2>&1

:auto_rotate
set /a ROTATE_TRIES=0
:rotate_loop
set /a ROTATE_TRIES+=1
if %ROTATE_TRIES% gtr %ROTATE_TRIES_MAX% (
  echo.
  echo %ROTATE_TRIES_MAX% tries, same IP every time. Try again later.
  pause
  goto :menu_loop
)
echo [%ROTATE_TRIES%] disconnect...
"%WARP%" --accept-tos disconnect >nul 2>&1
echo [%ROTATE_TRIES%] new registration...
"%WARP%" --accept-tos registration new >nul 2>&1
echo [%ROTATE_TRIES%] reconnect...
call :warp_up
set "WARP_UP=1"
echo [%ROTATE_TRIES%] waiting %WARP_WAIT%s...
timeout /t %WARP_WAIT% /nobreak >nul 2>&1

call :getip IPN
if not defined IPN set "IPN=%IP%"
if /i "%IPN%"=="%IP%" (
  echo [%ROTATE_TRIES%] same IP ^(%IPN%^), retrying...
  goto :rotate_loop
)
echo [%ROTATE_TRIES%] new exit IP: %IPN%
set "IP=%IPN%"
set "RESUME=1"
goto :run

:rotate
if not defined WARP (
  echo.
  echo WARP is not available - nothing to rotate.
  pause
  goto :menu_loop
)
echo.
echo Requesting a new WARP registration...
"%WARP%" --accept-tos disconnect >nul 2>&1
"%WARP%" --accept-tos registration new >nul 2>&1
call :warp_up
set "WARP_UP=1"
echo waiting %WARP_WAIT%s...
timeout /t %WARP_WAIT% /nobreak >nul 2>&1
call :getip IPN
if not defined IPN set "IPN=%IP%"
echo New exit IP: %IPN%
echo.
pause
goto :menu_loop

REM ============================================================
REM  4) SUBROUTINES
REM ============================================================

REM -- locate warp-cli anywhere reasonable ---------------------------
:find_warp
set "WARP="
for /f "delims=" %%w in ('where warp-cli.exe 2^>nul') do if not defined WARP set "WARP=%%w"
if defined WARP goto :eof
if exist "%ProgramFiles%\Cloudflare\Cloudflare WARP\warp-cli.exe" set "WARP=%ProgramFiles%\Cloudflare\Cloudflare WARP\warp-cli.exe"
REM ProgramW6432 and ProgramFiles(x86) are undefined on 32-bit windows
if not defined WARP if defined ProgramW6432 if exist "%ProgramW6432%\Cloudflare\Cloudflare WARP\warp-cli.exe" set "WARP=%ProgramW6432%\Cloudflare\Cloudflare WARP\warp-cli.exe"
if not defined WARP if defined ProgramFiles(x86) if exist "%ProgramFiles(x86)%\Cloudflare\Cloudflare WARP\warp-cli.exe" set "WARP=%ProgramFiles(x86)%\Cloudflare\Cloudflare WARP\warp-cli.exe"
if not defined WARP if exist "%LOCALAPPDATA%\Cloudflare\Cloudflare WARP\warp-cli.exe" set "WARP=%LOCALAPPDATA%\Cloudflare\Cloudflare WARP\warp-cli.exe"
if defined WARP set "HAS_WARP=1"
goto :eof

REM -- install WARP (UAC once) --------------------------------------
:install_warp
set "MSI=%TEMP%\Cloudflare_WARP_x64.msi"
if exist "%MSI%" del /f /q "%MSI%" >nul 2>&1
if "%HAVE_CURL%"=="1" (
  curl.exe -L -s -o "%MSI%" "https://1.1.1.1/Cloudflare_WARP_x64.msi"
) else (
  powershell -NoProfile -Command "try{[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri 'https://1.1.1.1/Cloudflare_WARP_x64.msi' -OutFile '%MSI%'}catch{}" >nul 2>&1
)
if not exist "%MSI%" (
  echo   [!] download failed.
  goto :eof
)
powershell -NoProfile -Command "try{Start-Process msiexec.exe -ArgumentList '/i','%MSI%','/qn' -Verb RunAs -Wait}catch{}" >nul 2>&1
del /f /q "%MSI%" >nul 2>&1
goto :eof

REM -- locate opencode anywhere reasonable --------------------------
:find_opencode
set "OC_CMD="
REM where returns the .ps1 shim first on npm installs, so pick by extension.
for /f "delims=" %%o in ('where opencode.exe 2^>nul') do if not defined OC_CMD set "OC_CMD=%%o"
if not defined OC_CMD for /f "delims=" %%o in ('where opencode.cmd 2^>nul') do if not defined OC_CMD set "OC_CMD=%%o"
if not defined OC_CMD for /f "delims=" %%o in ('where opencode.bat 2^>nul') do if not defined OC_CMD set "OC_CMD=%%o"
if not defined OC_CMD if exist "%APPDATA%\npm\opencode.cmd" set "OC_CMD=%APPDATA%\npm\opencode.cmd"
if not defined OC_CMD if exist "%USERPROFILE%\scoop\shims\opencode.cmd" set "OC_CMD=%USERPROFILE%\scoop\shims\opencode.cmd"
if not defined OC_CMD if exist "%LOCALAPPDATA%\Programs\opencode\opencode.exe" set "OC_CMD=%LOCALAPPDATA%\Programs\opencode\opencode.exe"
if not defined OC_CMD if exist "%LOCALAPPDATA%\opencode\bin\opencode.exe" set "OC_CMD=%LOCALAPPDATA%\opencode\bin\opencode.exe"
if not defined OC_CMD if exist "%USERPROFILE%\.opencode\bin\opencode.exe" set "OC_CMD=%USERPROFILE%\.opencode\bin\opencode.exe"
goto :eof

REM -- WARP into proxy mode and connected --------------------------
:warp_up
"%WARP%" --accept-tos mode proxy >nul 2>&1
"%WARP%" --accept-tos connect >nul 2>&1
timeout /t 2 /nobreak >nul 2>&1
goto :eof

REM -- exit IP, through the proxy when WARP is there ---------------
:getip
set "%~1="
if not defined WARP goto :getip_direct
call :getip_via_proxy "%~1"
if defined %~1 goto :eof
:getip_direct
if "%HAVE_CURL%"=="1" (
  for /f "tokens=2 delims==" %%i in ('curl.exe -4 -s --max-time 10 "%TRACE_URL%" 2^>nul ^| findstr /b "ip="') do set "%~1=%%i"
) else (
  for /f "tokens=2 delims== " %%i in ('powershell -NoProfile -Command "try{(Invoke-RestMethod -Uri '%TRACE_URL%' -TimeoutSec 10) -replace [char]13,[char]10}catch{}" ^| findstr /b "ip="') do set "%~1=%%i"
)
goto :eof

:getip_via_proxy
if "%HAVE_CURL%"=="1" (
  for /f "tokens=2 delims==" %%i in ('curl.exe -4 -s --max-time 10 -x %PROXY% %TRACE_URL% 2^>nul ^| findstr /b "ip="') do set "%~1=%%i"
) else (
  for /f "tokens=2 delims== " %%i in ('powershell -NoProfile -Command "try{(Invoke-RestMethod -Uri '%TRACE_URL%' -Proxy '%PROXY%' -TimeoutSec 10) -replace [char]13,[char]10}catch{}" ^| findstr /b "ip="') do set "%~1=%%i"
)
goto :eof

REM -- make sure this launch does not reuse the last egress IP ------
:ensure_new_ip
set "LASTIP="
if exist "%STATE_DIR%\lastip.txt" set /p LASTIP=<"%STATE_DIR%\lastip.txt"
call :getip CUR
if not defined CUR goto :eof
if /i not "%CUR%"=="%LASTIP%" goto :remember_ip
echo   same IP as the last run, requesting a new registration...
set /a EN_TRIES=0

:ensure_loop
set /a EN_TRIES+=1
if %EN_TRIES% gtr %ROTATE_TRIES_MAX% (
  echo   no new IP after %ROTATE_TRIES_MAX% tries, launching on the current one.
  goto :remember_ip
)
echo   [%EN_TRIES%] disconnect...
"%WARP%" --accept-tos disconnect >nul 2>&1
echo   [%EN_TRIES%] new registration...
"%WARP%" --accept-tos registration new >nul 2>&1
call :warp_up
set "WARP_UP=1"
echo   [%EN_TRIES%] waiting %WARP_WAIT%s...
timeout /t %WARP_WAIT% /nobreak >nul 2>&1
call :getip CUR
if not defined CUR goto :ensure_loop
if /i "%CUR%"=="%LASTIP%" goto :ensure_loop

:remember_ip
>"%STATE_DIR%\lastip.txt" echo %CUR%
set "IP=%CUR%"
echo   exit IP: %CUR%
goto :eof

REM -- did this run write a quota line to the log? ------------------
:check_quota
set "QHIT="
set "QOUT=%TEMP%\opencode_quota.txt"
if exist "%QOUT%" del /f /q "%QOUT%" >nul 2>&1
powershell -NoProfile -Command "try{ $fs=[IO.File]::Open('%LOGFILE%','Open','Read','ReadWrite'); [void]$fs.Seek(%SIZE_BEFORE%,'Begin'); $sr=New-Object IO.StreamReader($fs); $t=$sr.ReadToEnd(); $sr.Close(); if($t -match '(?i)free usage limit|usage limit|quota|rate limit'){Set-Content -LiteralPath '%QOUT%' -Value 'HIT'}else{Set-Content -LiteralPath '%QOUT%' -Value 'NOHIT'} }catch{Set-Content -LiteralPath '%QOUT%' -Value 'NOHIT'}" >nul 2>&1
if exist "%QOUT%" for /f "usebackq delims=" %%q in ("%QOUT%") do if /i "%%q"=="HIT" set "QHIT=1"
if exist "%QOUT%" del /f /q "%QOUT%" >nul 2>&1
goto :eof

:quit
if defined POPPED popd
endlocal
