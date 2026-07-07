@echo off
setlocal

pushd "%~dp0\..\..\.."
if errorlevel 1 exit /b 1

set "LOCAL_ENV_SCRIPT=services\whisperdaemon\scripts\.env.bat"
if exist "%LOCAL_ENV_SCRIPT%" (
    echo [INFO] Loading local whisperdaemon overrides: %LOCAL_ENV_SCRIPT%
    call "%LOCAL_ENV_SCRIPT%"
    if errorlevel 1 (
        echo [ERROR] Failed to load local config: %LOCAL_ENV_SCRIPT%
        popd
        exit /b 1
    )
)

if not defined WHISPER_DAEMON_HOST set "WHISPER_DAEMON_HOST=127.0.0.1"
if not defined WHISPER_DAEMON_PORT set "WHISPER_DAEMON_PORT=7801"

set "DAEMON_DIR=services\whisperdaemon\build\x64"
set "DAEMON_EXE=%DAEMON_DIR%\WhisperDaemon.exe"
set "MODEL_FILE=services\whisperdaemon\models\ggml-whisper_podlodka.bin"
set "LOG_DIR=services\whisperdaemon\logs"
set "STDOUT_LOG=%LOG_DIR%\whisper_podlodka.stdout.log"
set "STDERR_LOG=%LOG_DIR%\whisper_podlodka.stderr.log"
if not exist "%DAEMON_EXE%" (
    echo Executable not found:
    echo   %DAEMON_EXE%
    echo Run services\whisperdaemon\scripts\build_whisperdaemon.bat first.
    popd
    exit /b 1
)

if not exist "%MODEL_FILE%" (
    echo Model file not found:
    echo   %MODEL_FILE%
    echo Run services\whisperdaemon\scripts\stage_whisperdaemon_model.bat first.
    popd
    exit /b 1
)

pwsh -NoProfile -Command "$items = Get-CimInstance Win32_Process | Where-Object { $_.Name -ieq 'WhisperDaemon.exe' -and $_.CommandLine -match '--model-name whisper_podlodka(\s|$)' }; if (@($items).Count -gt 0) { Write-Host 'whisperdaemon_podlodka is already running.'; exit 1 }"
if errorlevel 1 (
    popd
    exit /b 1
)

if not exist "%LOG_DIR%" mkdir "%LOG_DIR%"
if exist "%STDOUT_LOG%" del /q "%STDOUT_LOG%"
if exist "%STDERR_LOG%" del /q "%STDERR_LOG%"

REM Interactive Windows Terminal -> tab in the current window; else minimized window.
pwsh -NoProfile -Command "$wd=(Get-Location).Path; $exe=Join-Path $wd 'services\whisperdaemon\build\x64\WhisperDaemon.exe'; $out=Join-Path $wd 'services\whisperdaemon\logs\whisper_podlodka.stdout.log'; $err=Join-Path $wd 'services\whisperdaemon\logs\whisper_podlodka.stderr.log'; $modelsRoot=Join-Path $wd 'services\whisperdaemon\models'; $env:WHISPER_MODELS_ROOT = $modelsRoot; $argList=@('--model-name','whisper_podlodka','--host',$env:WHISPER_DAEMON_HOST,'--port',$env:WHISPER_DAEMON_PORT); if ($env:WHISPER_USE_GPU -match '^(?i:1|true|yes|on)$') { $argList += '--gpu' }; if ($env:WHISPER_GPU_DEVICE) { $argList += @('--gpu-device',$env:WHISPER_GPU_DEVICE) }; if ($env:WHISPER_DLL_PATH) { $argList += @('--whisper-dll',$env:WHISPER_DLL_PATH) }; if ($env:WHISPER_RELEASE_TAG) { $argList += @('--release-tag',$env:WHISPER_RELEASE_TAG) }; Write-Host ('whisperdaemon args: ' + ($argList -join ' ')); & (Join-Path $wd 'scripts\launch_tab.ps1') -Title 'whisperdaemon_podlodka' -Exe $exe -ArgList $argList -WorkDir $wd -StdoutLog $out -StderrLog $err -EnvNames 'WHISPER_MODELS_ROOT' -WaitPort ([int]$env:WHISPER_DAEMON_PORT)"
set "RUN_EXIT=%ERRORLEVEL%"
if %RUN_EXIT% neq 0 (
    popd
    exit /b %RUN_EXIT%
)

REM Tab mode: warmup is visible live in the tab — don't block here.
if exist "%LOCALAPPDATA%\Microsoft\WindowsApps\wt.exe" if not "%WT_TABS%"=="0" (
    popd
    exit /b 0
)

pwsh -NoProfile -File "%~dp0wait_whisperdaemon_ready.ps1" -ModelName whisper_podlodka
set "RUN_EXIT=%ERRORLEVEL%"

popd
exit /b %RUN_EXIT%