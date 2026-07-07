@echo off
setlocal

pushd "%~dp0\..\..\.."
if errorlevel 1 exit /b 1

set "DAEMON_EXE=services\voskdaemon\build\x64\VoskDaemon.exe"
set "LOG_DIR=services\voskdaemon\logs"
set "STDOUT_LOG=%LOG_DIR%\vosk_ru.stdout.log"
set "STDERR_LOG=%LOG_DIR%\vosk_ru.stderr.log"
if not exist "%DAEMON_EXE%" (
    echo Executable not found:
    echo   %DAEMON_EXE%
    echo Run services\voskdaemon\scripts\build_voskdaemon.bat first.
    popd
    exit /b 1
)

pwsh -NoProfile -Command "$items = Get-CimInstance Win32_Process | Where-Object { $_.Name -ieq 'VoskDaemon.exe' -and $_.CommandLine -match '--model-name vosk_ru(\s|$)' }; if (@($items).Count -gt 0) { Write-Host 'voskdaemon_ru is already running.'; exit 1 }"
if errorlevel 1 (
    popd
    exit /b 1
)

if not exist "%LOG_DIR%" mkdir "%LOG_DIR%"
if exist "%STDOUT_LOG%" del /q "%STDOUT_LOG%"
if exist "%STDERR_LOG%" del /q "%STDERR_LOG%"

REM Interactive Windows Terminal -> tab in the current window; else minimized window.
pwsh -NoProfile -Command "$wd=(Get-Location).Path; $exe=Join-Path $wd 'services\voskdaemon\build\x64\VoskDaemon.exe'; $out=Join-Path $wd 'services\voskdaemon\logs\vosk_ru.stdout.log'; $err=Join-Path $wd 'services\voskdaemon\logs\vosk_ru.stderr.log'; & (Join-Path $wd 'scripts\launch_tab.ps1') -Title 'voskdaemon_ru' -Exe $exe -ArgList '--model-name','vosk_ru','--host','127.0.0.1','--port','7701' -WorkDir $wd -StdoutLog $out -StderrLog $err -WaitPort 7701"
set "RUN_EXIT=%ERRORLEVEL%"
if %RUN_EXIT% neq 0 (
    popd
    exit /b %RUN_EXIT%
)

REM Tab mode: the daemon shows its own warmup live in the tab — don't block here.
if exist "%LOCALAPPDATA%\Microsoft\WindowsApps\wt.exe" if not "%WT_TABS%"=="0" (
    popd
    exit /b 0
)

pwsh -NoProfile -File "%~dp0wait_voskdaemon_ready.ps1" -ModelName vosk_ru
set "RUN_EXIT=%ERRORLEVEL%"

popd
exit /b %RUN_EXIT%