@echo off
setlocal

pushd "%~dp0.."
if errorlevel 1 exit /b 1

set "DAEMON_EXE=services\whisperdaemon\build\x64\WhisperDaemon.exe"
set "MODEL_FILE=services\whisperdaemon\models\ggml-whisper_podlodka.bin"
set "LOG_DIR=services\whisperdaemon\logs"
set "STDOUT_LOG=%LOG_DIR%\whisper_podlodka.stdout.log"
set "STDERR_LOG=%LOG_DIR%\whisper_podlodka.stderr.log"
if not exist "%DAEMON_EXE%" (
    echo Executable not found:
    echo   %DAEMON_EXE%
    echo Run scripts\build_whisperdaemon.bat first.
    popd
    exit /b 1
)

if not exist "%MODEL_FILE%" (
    echo Model file not found:
    echo   %MODEL_FILE%
    echo Run scripts\stage_whisperdaemon_model.bat first.
    popd
    exit /b 1
)

powershell -NoProfile -Command "$items = Get-CimInstance Win32_Process | Where-Object { $_.Name -ieq 'WhisperDaemon.exe' -and $_.CommandLine -match '--model-name whisper_podlodka(\s|$)' }; if (@($items).Count -gt 0) { Write-Host 'whisperdaemon_podlodka is already running.'; exit 1 }"
if errorlevel 1 (
    popd
    exit /b 1
)

if not exist "%LOG_DIR%" mkdir "%LOG_DIR%"
if exist "%STDOUT_LOG%" del /q "%STDOUT_LOG%"
if exist "%STDERR_LOG%" del /q "%STDERR_LOG%"

powershell -NoProfile -Command "$wd=(Get-Location).Path; $exe=Join-Path $wd 'services\whisperdaemon\build\x64\WhisperDaemon.exe'; $out=Join-Path $wd 'services\whisperdaemon\logs\whisper_podlodka.stdout.log'; $err=Join-Path $wd 'services\whisperdaemon\logs\whisper_podlodka.stderr.log'; $env:WHISPER_MODELS_ROOT = Join-Path $wd 'services\whisperdaemon\models'; $proc = Start-Process -FilePath $exe -ArgumentList '--model-name','whisper_podlodka','--host','127.0.0.1','--port','7801' -WorkingDirectory $wd -WindowStyle Minimized -RedirectStandardOutput $out -RedirectStandardError $err -PassThru; if ($proc.WaitForExit(1500)) { Write-Host ('whisperdaemon_podlodka exited with code ' + $proc.ExitCode); if (Test-Path $err) { Get-Content -Path $err | ForEach-Object { Write-Host $_ } }; exit $proc.ExitCode }; Write-Host ('Started whisperdaemon_podlodka PID ' + $proc.Id); Write-Host ('stdout: ' + $out); Write-Host ('stderr: ' + $err)"
set "RUN_EXIT=%ERRORLEVEL%"
if %RUN_EXIT% neq 0 (
    popd
    exit /b %RUN_EXIT%
)

powershell -NoProfile -File ".\scripts\wait_whisperdaemon_ready.ps1" -ModelName whisper_podlodka
set "RUN_EXIT=%ERRORLEVEL%"

popd
exit /b %RUN_EXIT%