@echo off
REM Stop the EchoScript orchestrator (kill process listening on its port).
setlocal

if not defined ECHOSCRIPT_PORT set "ECHOSCRIPT_PORT=3000"

pwsh -NoProfile -Command "$c = Get-NetTCPConnection -LocalPort %ECHOSCRIPT_PORT% -State Listen -ErrorAction SilentlyContinue; if ($c) { $c | ForEach-Object { Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue }; Write-Host 'orchestrator stopped' } else { Write-Host 'orchestrator not running' }"

endlocal & exit /b 0
