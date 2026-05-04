@echo off
setlocal

pushd "%~dp0.."
if errorlevel 1 exit /b 1

powershell -NoProfile -Command "$items = Get-CimInstance Win32_Process | Where-Object { $_.Name -ieq 'WhisperDaemon.exe' -and $_.CommandLine -match '--model-name whisper_podlodka(\s|$)' }; if (@($items).Count -eq 0) { Write-Host 'No whisperdaemon_podlodka process found.'; exit 0 }; $items | ForEach-Object { Stop-Process -Id $_.ProcessId -Force; Write-Host ('Stopped whisperdaemon_podlodka PID ' + $_.ProcessId) }"
set "RUN_EXIT=%ERRORLEVEL%"

popd
exit /b %RUN_EXIT%