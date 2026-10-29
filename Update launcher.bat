@echo off
setlocal EnableExtensions
title OpenCode launcher updater
REM ============================================================
REM  Updates the OpenCode launcher from the repo, on any machine,
REM  anywhere. Runs the SAME logic on every Windows 10/11 box:
REM  no local paths, user folders and temp via environment only.
REM
REM  Where it looks for the file to replace, in order:
REM    1) next to this bootstrap      (%~dp0)
REM    2) on the current user Desktop (%USERPROFILE%\Desktop)
REM    3) OneDrive Desktop redirection, when it exists
REM  If the launcher is nowhere, it is written fresh to the Desktop.
REM ============================================================

set "REMOTE=https://raw.githubusercontent.com/jeko1107/opencode-infinite/main/OpenCode%%20Infinite.bat"
set "TMPBAT=%TEMP%\opencode_infinite_latest.bat"
if exist "%TMPBAT%" del /f /q "%TMPBAT%" >nul 2>&1

echo Downloading the newest launcher...
curl.exe -L -f -s --max-time 60 -o "%TMPBAT%" "%REMOTE%" >nul 2>&1
if not errorlevel 1 goto size_gate
REM curl.exe exists on Windows 10/11; the branch below still covers
REM anything stripped of it (Server editions, older images).
powershell -NoProfile -Command "try{[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -UseBasicParsing -Uri $env:REMOTE -OutFile $env:TMPBAT -TimeoutSec 60}catch{exit 1}" >nul 2>&1
if errorlevel 1 goto fail_net

:size_gate
set "SIZEOK="
if exist "%TMPBAT%" for %%s in ("%TMPBAT%") do if %%~zs GEQ 20000 set "SIZEOK=1"
if not defined SIZEOK goto fail_net
REM Content gate: it must be the launcher file, never an error page.
findstr /b /c:"REM  OpenCode launcher" "%TMPBAT%" >nul 2>&1
if errorlevel 1 goto fail_bad

set "TARGET="
if exist "%~dp0OpenCode Infinite.bat" set "TARGET=%~dp0OpenCode Infinite.bat"
if not defined TARGET if exist "%USERPROFILE%\Desktop\OpenCode Infinite.bat" set "TARGET=%USERPROFILE%\Desktop\OpenCode Infinite.bat"
if not defined TARGET if exist "%USERPROFILE%\OneDrive\Desktop\OpenCode Infinite.bat" set "TARGET=%USERPROFILE%\OneDrive\Desktop\OpenCode Infinite.bat"
if not defined TARGET set "TARGET=%USERPROFILE%\Desktop\OpenCode Infinite.bat"

echo Newest copy is ok. Replacing:
echo   "%TARGET%"
REM The launcher cannot be replaced while one of its windows is open:
REM ping-retry up to 5 s, then the failure speaks clearly.
set "TRI=0"
:retry
copy /y "%TMPBAT%" "%TARGET%" >nul 2>&1
if not errorlevel 1 goto done
set /a TRI+=1
if %TRI% GEQ 5 goto fail_locked
echo   trying again (%TRI%/5) - close any open OpenCode window...
ping -n 2 127.0.0.1 >nul
goto retry

:done
del /f /q "%TMPBAT%" >nul 2>&1
echo.
echo   Updated. Run "%TARGET%" now - it will keep updating itself
echo   with this same repo at every start, no laps needed.
echo.
pause
exit /b 0

:fail_locked
echo.
echo   [!] Could not replace the file: an OpenCode window still has it
echo       open. Close every OpenCode window and run this again.
del /f /q "%TMPBAT%" >nul 2>&1
pause
exit /b 1

:fail_net
echo.
echo   [!] Download failed - check the connection or try again later.
del /f /q "%TMPBAT%" >nul 2>&1
pause
exit /b 1

:fail_bad
echo.
echo   [!] The download does not look like the launcher - discarded.
del /f /q "%TMPBAT%" >nul 2>&1
pause
exit /b 1
