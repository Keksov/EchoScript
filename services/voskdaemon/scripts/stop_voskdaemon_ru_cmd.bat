@echo off
setlocal

pushd "%~dp0\..\..\.."
if errorlevel 1 exit /b 1

powershell -NoProfile -Command "$items = Get-CimInstance Win32_Process | Where-Object { $_.Name -ieq 'VoskDaemon.exe' -and $_.CommandLine -match '--model-name vosk_ru_cmd' }; if (@($items).Count -eq 0) { Write-Host 'No voskdaemon_ru_cmd process found.'; exit 0 }; $items | ForEach-Object { Stop-Process -Id $_.ProcessId -Force; Write-Host ('Stopped voskdaemon_ru_cmd PID ' + $_.ProcessId) }"
set "RUN_EXIT=%ERRORLEVEL%"

popd
exit /b %RUN_EXIT%