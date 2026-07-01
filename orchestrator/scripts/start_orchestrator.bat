@echo off
REM Start the EchoScript orchestrator (file-daemon, Bun/Hono).
setlocal

for %%I in ("%~dp0..") do set "ORCH_DIR=%%~fI"
if not defined ECHOSCRIPT_PORT set "ECHOSCRIPT_PORT=3000"
set "LOGDIR=%ORCH_DIR%\logs"
if not exist "%LOGDIR%" mkdir "%LOGDIR%"

pwsh -NoProfile -Command "$env:ECHOSCRIPT_PORT='%ECHOSCRIPT_PORT%'; $out=Join-Path '%LOGDIR%' 'orchestrator.stdout.log'; $err=Join-Path '%LOGDIR%' 'orchestrator.stderr.log'; Start-Process -FilePath 'bun' -ArgumentList 'run','src/index.ts' -WorkingDirectory '%ORCH_DIR%' -WindowStyle Minimized -RedirectStandardOutput $out -RedirectStandardError $err | Out-Null; Write-Host ('orchestrator started on port %ECHOSCRIPT_PORT%')"

endlocal & exit /b 0
