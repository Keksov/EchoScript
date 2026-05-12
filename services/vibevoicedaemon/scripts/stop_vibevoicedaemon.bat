@echo off
setlocal

pushd "%~dp0\..\..\.."
if errorlevel 1 exit /b 1

pwsh -NoProfile -Command "$items = Get-CimInstance Win32_Process | Where-Object { $_.Name -ieq 'python.exe' -and $_.CommandLine -match 'app\.main.*--port\s+7802' }; if (@($items).Count -eq 0) { Write-Host 'No vibevoicedaemon process found.'; exit 0 }; $items | ForEach-Object { Stop-Process -Id $_.ProcessId -Force; Write-Host ('Stopped vibevoicedaemon PID ' + $_.ProcessId) }"
set "RUN_EXIT=%ERRORLEVEL%"

popd
exit /b %RUN_EXIT%
