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

set "DEFAULT_SHERPA_DLL=services\whisperdaemon\vendors\sherpa-onnx\sherpa-onnx.dll"
set "DEFAULT_ORT_DLL=services\whisperdaemon\vendors\sherpa-onnx\onnxruntime.dll"
set "DEFAULT_ORT_SHARED_DLL=services\whisperdaemon\vendors\sherpa-onnx\onnxruntime_providers_shared.dll"
set "DEFAULT_SEG_MODEL=services\whisperdaemon\models\diarization\segmentation.onnx"
set "DEFAULT_EMB_MODEL=services\whisperdaemon\models\diarization\embedding.onnx"
set "STAGED_ORT_DLL=%DAEMON_DIR%\onnxruntime.dll"
set "STAGED_ORT_SHARED_DLL=%DAEMON_DIR%\onnxruntime_providers_shared.dll"

if not defined SHERPA_DLL_PATH set "SHERPA_DLL_PATH=%DEFAULT_SHERPA_DLL%"
if not defined DIARIZE_SEG_MODEL set "DIARIZE_SEG_MODEL=%DEFAULT_SEG_MODEL%"
if not defined DIARIZE_EMB_MODEL set "DIARIZE_EMB_MODEL=%DEFAULT_EMB_MODEL%"

if not exist "%SHERPA_DLL_PATH%" (
    echo Required diarization runtime not found:
    echo   %SHERPA_DLL_PATH%
    popd
    exit /b 1
)

if not exist "%DIARIZE_SEG_MODEL%" (
    echo Required diarization segmentation model not found:
    echo   %DIARIZE_SEG_MODEL%
    popd
    exit /b 1
)

if not exist "%DIARIZE_EMB_MODEL%" (
    echo Required diarization embedding model not found:
    echo   %DIARIZE_EMB_MODEL%
    popd
    exit /b 1
)

if not exist "%DEFAULT_ORT_DLL%" (
    echo Required ONNX Runtime DLL not found:
    echo   %DEFAULT_ORT_DLL%
    popd
    exit /b 1
)

if not exist "%DEFAULT_ORT_SHARED_DLL%" (
    echo Required ONNX Runtime provider DLL not found:
    echo   %DEFAULT_ORT_SHARED_DLL%
    popd
    exit /b 1
)

copy /y "%DEFAULT_ORT_DLL%" "%STAGED_ORT_DLL%" >nul
if errorlevel 1 (
    echo Failed to stage ONNX Runtime DLL:
    echo   %STAGED_ORT_DLL%
    popd
    exit /b 1
)

copy /y "%DEFAULT_ORT_SHARED_DLL%" "%STAGED_ORT_SHARED_DLL%" >nul
if errorlevel 1 (
    echo Failed to stage ONNX Runtime provider DLL:
    echo   %STAGED_ORT_SHARED_DLL%
    popd
    exit /b 1
)

if not exist "%LOG_DIR%" mkdir "%LOG_DIR%"
if exist "%STDOUT_LOG%" del /q "%STDOUT_LOG%"

powershell -NoProfile -Command "$wd=(Get-Location).Path; $exe=Join-Path $wd 'services\whisperdaemon\build\x64\WhisperDaemon.exe'; $out=Join-Path $wd 'services\whisperdaemon\logs\whisper_podlodka.stdout.log'; $modelsRoot=Join-Path $wd 'services\whisperdaemon\models'; $diarizeRoot=Join-Path $modelsRoot 'diarization'; $defaultSherpaDll=Join-Path $wd 'services\whisperdaemon\vendors\sherpa-onnx\sherpa-onnx.dll'; $defaultSegModel=Join-Path $diarizeRoot 'segmentation.onnx'; $defaultEmbModel=Join-Path $diarizeRoot 'embedding.onnx'; $env:WHISPER_MODELS_ROOT = $modelsRoot; if (-not $env:SHERPA_DLL_PATH -and (Test-Path $defaultSherpaDll)) { $env:SHERPA_DLL_PATH = $defaultSherpaDll }; if (-not $env:DIARIZE_SEG_MODEL -and (Test-Path $defaultSegModel)) { $env:DIARIZE_SEG_MODEL = $defaultSegModel }; if (-not $env:DIARIZE_EMB_MODEL -and (Test-Path $defaultEmbModel)) { $env:DIARIZE_EMB_MODEL = $defaultEmbModel }; if (($env:DIARIZE_SEG_MODEL -and -not $env:DIARIZE_EMB_MODEL) -or ($env:DIARIZE_EMB_MODEL -and -not $env:DIARIZE_SEG_MODEL)) { Write-Host 'Both DIARIZE_SEG_MODEL and DIARIZE_EMB_MODEL must be set together.'; exit 1 }; if ($env:DIARIZE_SEG_MODEL -and -not $env:SHERPA_DLL_PATH) { Write-Host 'SHERPA_DLL_PATH is required when diarization models are configured.'; exit 1 }; $argList=@('--model-name','whisper_podlodka','--host','127.0.0.1','--port','7801'); if ($env:WHISPER_USE_GPU -match '^(?i:1|true|yes|on)$') { $argList += '--gpu' }; if ($env:WHISPER_GPU_DEVICE) { $argList += @('--gpu-device',$env:WHISPER_GPU_DEVICE) }; if ($env:WHISPER_DLL_PATH) { $argList += @('--whisper-dll',$env:WHISPER_DLL_PATH) }; if ($env:WHISPER_RELEASE_TAG) { $argList += @('--release-tag',$env:WHISPER_RELEASE_TAG) }; if ($env:SHERPA_DLL_PATH) { $argList += @('--sherpa-dll',$env:SHERPA_DLL_PATH) }; if ($env:DIARIZE_SEG_MODEL) { $argList += @('--diarize-seg-model',$env:DIARIZE_SEG_MODEL) }; if ($env:DIARIZE_EMB_MODEL) { $argList += @('--diarize-emb-model',$env:DIARIZE_EMB_MODEL) }; if ($env:DIARIZE_NUM_SPEAKERS) { $argList += @('--num-speakers',$env:DIARIZE_NUM_SPEAKERS) }; if ($env:DIARIZE_CLUSTER_THRESHOLD) { $argList += @('--cluster-threshold',$env:DIARIZE_CLUSTER_THRESHOLD) }; if ($env:DIARIZE_MIN_DURATION_ON) { $argList += @('--diarize-min-duration-on',$env:DIARIZE_MIN_DURATION_ON) }; if ($env:DIARIZE_MIN_DURATION_OFF) { $argList += @('--diarize-min-duration-off',$env:DIARIZE_MIN_DURATION_OFF) }; Write-Host ('whisperdaemon args: ' + ($argList -join ' ')); & $exe @argList 2>&1 | ForEach-Object { $_.ToString() } | Tee-Object -FilePath $out; exit $LASTEXITCODE"
set "RUN_EXIT=%ERRORLEVEL%"

popd
exit /b %RUN_EXIT%