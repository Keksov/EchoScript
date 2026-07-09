@echo off
REM Start the EchoScript orchestrator (file-daemon, Bun/Hono).
setlocal

for %%I in ("%~dp0..") do set "ORCH_DIR=%%~fI"
if not defined ECHOSCRIPT_PORT set "ECHOSCRIPT_PORT=3000"
set "LOGDIR=%ORCH_DIR%\logs"
if not exist "%LOGDIR%" mkdir "%LOGDIR%"

REM Interactive Windows Terminal session -> new tab in the current window; else minimized window.
pwsh -NoProfile -Command "$env:ECHOSCRIPT_PORT='%ECHOSCRIPT_PORT%'; $out=Join-Path '%LOGDIR%' 'orchestrator.stdout.log'; $err=Join-Path '%LOGDIR%' 'orchestrator.stderr.log'; & '%~dp0..\..\scripts\launch_tab.ps1' -Title 'orchestrator' -Exe 'bun' -ArgList 'run','src/index.ts' -WorkDir '%ORCH_DIR%' -StdoutLog $out -StderrLog $err -EnvNames 'ECHOSCRIPT_PORT' -WaitPort %ECHOSCRIPT_PORT%"

REM Manual start = dev (DT-D5): also re-open log tabs for daemons that are ALREADY running
REM (windowless daemons survive closing the WT window; this brings their tabs back).
set "ECHOCTL=%~dp0..\..\echoctl\build\x64\echoctl.exe"
if exist "%ECHOCTL%" "%ECHOCTL%" daemons tabs >nul 2>nul

endlocal & exit /b 0
