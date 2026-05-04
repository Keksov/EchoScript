@echo off
setlocal

pushd "%~dp0.."
if errorlevel 1 exit /b 1

set "DAEMON_EXE=services\whisperdaemon\build\x64\WhisperDaemon.exe"
set "MODEL_FILE=services\whisperdaemon\models\ggml-whisper_podlodka.bin"
set "LOG_DIR=services\whisperdaemon\logs"
set "STDOUT_LOG=%LOG_DIR%\whisper_podlodka.stdout.log"
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

if not exist "%LOG_DIR%" mkdir "%LOG_DIR%"
if exist "%STDOUT_LOG%" del /q "%STDOUT_LOG%"

powershell -NoProfile -Command "$wd=(Get-Location).Path; $exe=Join-Path $wd 'services\whisperdaemon\build\x64\WhisperDaemon.exe'; $out=Join-Path $wd 'services\whisperdaemon\logs\whisper_podlodka.stdout.log'; $env:WHISPER_MODELS_ROOT = Join-Path $wd 'services\whisperdaemon\models'; & $exe '--model-name' 'whisper_podlodka' '--host' '127.0.0.1' '--port' '7801' 2>&1 | ForEach-Object { $_.ToString() } | Tee-Object -FilePath $out; exit $LASTEXITCODE"
set "RUN_EXIT=%ERRORLEVEL%"

popd
exit /b %RUN_EXIT%