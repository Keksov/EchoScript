@echo off
setlocal

pushd "%~dp0\..\..\.."
if errorlevel 1 exit /b 1

set "DAEMON_EXE=services\voskdaemon\build\x64\VoskDaemon.exe"
if not exist "%DAEMON_EXE%" (
    echo Executable not found:
    echo   %DAEMON_EXE%
    echo Run services\voskdaemon\scripts\build_voskdaemon.bat first.
    popd
    exit /b 1
)

REM Interactive Windows Terminal -> tab in the current window; else minimized window.
pwsh -NoProfile -Command "$wd=(Get-Location).Path; $exe=Join-Path $wd 'services\voskdaemon\build\x64\VoskDaemon.exe'; $logDir=Join-Path $wd 'services\voskdaemon\logs'; New-Item -ItemType Directory -Force $logDir | Out-Null; $out=Join-Path $logDir 'vosk_ru_cmd.stdout.log'; $err=Join-Path $logDir 'vosk_ru_cmd.stderr.log'; & (Join-Path $wd 'scripts\launch_tab.ps1') -Title 'voskdaemon_ru_cmd' -Exe $exe -ArgList '--model-name','vosk_ru_cmd','--host','127.0.0.1','--port','7702' -WorkDir $wd -StdoutLog $out -StderrLog $err -WaitPort 7702"
set "RUN_EXIT=%ERRORLEVEL%"

popd
exit /b %RUN_EXIT%