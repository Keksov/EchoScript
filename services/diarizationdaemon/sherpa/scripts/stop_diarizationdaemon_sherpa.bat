@echo off
setlocal

pushd "%~dp0\..\..\..\.."
if errorlevel 1 exit /b 1

powershell -NoProfile -Command "$items = Get-CimInstance Win32_Process | Where-Object { $_.Name -ieq 'DiarizationDaemon.exe' }; if (@($items).Count -eq 0) { Write-Host 'No DiarizationDaemon process found.'; exit 0 }; $items | ForEach-Object { Stop-Process -Id $_.ProcessId -Force; Write-Host ('Stopped DiarizationDaemon PID ' + $_.ProcessId) }"
set "RUN_EXIT=%ERRORLEVEL%"

popd
exit /b %RUN_EXIT%
