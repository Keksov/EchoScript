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

powershell -NoProfile -Command "$items = Get-CimInstance Win32_Process | Where-Object { $_.Name -ieq 'VoskDaemon.exe' -and $_.CommandLine -match '--model-name vosk_ru(\s|$)' }; if (@($items).Count -gt 0) { Write-Host 'voskdaemon_ru is already running.'; exit 1 }"
if errorlevel 1 (
    popd
    exit /b 1
)

if not exist "%LOG_DIR%" mkdir "%LOG_DIR%"
if exist "%STDOUT_LOG%" del /q "%STDOUT_LOG%"
if exist "%STDERR_LOG%" del /q "%STDERR_LOG%"

powershell -NoProfile -Command "$wd=(Get-Location).Path; $exe=Join-Path $wd 'services\voskdaemon\build\x64\VoskDaemon.exe'; $out=Join-Path $wd 'services\voskdaemon\logs\vosk_ru.stdout.log'; $err=Join-Path $wd 'services\voskdaemon\logs\vosk_ru.stderr.log'; $proc = Start-Process -FilePath $exe -ArgumentList '--model-name','vosk_ru','--host','127.0.0.1','--port','7701' -WorkingDirectory $wd -WindowStyle Minimized -RedirectStandardOutput $out -RedirectStandardError $err -PassThru; if ($proc.WaitForExit(1500)) { Write-Host ('voskdaemon_ru exited with code ' + $proc.ExitCode); if (Test-Path $err) { Get-Content -Path $err | ForEach-Object { Write-Host $_ } }; exit $proc.ExitCode }; Write-Host ('Started voskdaemon_ru PID ' + $proc.Id); Write-Host ('stdout: ' + $out); Write-Host ('stderr: ' + $err)"
set "RUN_EXIT=%ERRORLEVEL%"
if %RUN_EXIT% neq 0 (
    popd
    exit /b %RUN_EXIT%
)

powershell -NoProfile -File "%~dp0wait_voskdaemon_ready.ps1" -ModelName vosk_ru
set "RUN_EXIT=%ERRORLEVEL%"

popd
exit /b %RUN_EXIT%