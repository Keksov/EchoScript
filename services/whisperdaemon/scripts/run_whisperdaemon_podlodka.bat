@echo off
setlocal

pushd "%~dp0\..\..\.."
if errorlevel 1 exit /b 1

set "DAEMON_DIR=services\whisperdaemon\build\x64"
set "DAEMON_EXE=%DAEMON_DIR%\WhisperDaemon.exe"
set "MODEL_FILE=services\whisperdaemon\models\ggml-whisper_podlodka.bin"
set "LOG_DIR=services\whisperdaemon\logs"
set "STDOUT_LOG=%LOG_DIR%\whisper_podlodka.stdout.log"
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

if not exist "%LOG_DIR%" mkdir "%LOG_DIR%"
if exist "%STDOUT_LOG%" del /q "%STDOUT_LOG%"

powershell -NoProfile -Command "$wd=(Get-Location).Path; $exe=Join-Path $wd 'services\whisperdaemon\build\x64\WhisperDaemon.exe'; $out=Join-Path $wd 'services\whisperdaemon\logs\whisper_podlodka.stdout.log'; $modelsRoot=Join-Path $wd 'services\whisperdaemon\models'; $env:WHISPER_MODELS_ROOT = $modelsRoot; $argList=@('--model-name','whisper_podlodka','--host','127.0.0.1','--port','7801'); if ($env:WHISPER_USE_GPU -match '^(?i:1|true|yes|on)$') { $argList += '--gpu' }; if ($env:WHISPER_GPU_DEVICE) { $argList += @('--gpu-device',$env:WHISPER_GPU_DEVICE) }; if ($env:WHISPER_DLL_PATH) { $argList += @('--whisper-dll',$env:WHISPER_DLL_PATH) }; if ($env:WHISPER_RELEASE_TAG) { $argList += @('--release-tag',$env:WHISPER_RELEASE_TAG) }; Write-Host ('whisperdaemon args: ' + ($argList -join ' ')); & $exe @argList 2>&1 | ForEach-Object { $_.ToString() } | Tee-Object -FilePath $out; exit $LASTEXITCODE"
set "RUN_EXIT=%ERRORLEVEL%"

popd
exit /b %RUN_EXIT%