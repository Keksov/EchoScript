@echo off
REM ============================================================
REM EchoScript - Download: WhisperDaemon diarization assets
REM Downloads:
REM   - sherpa-onnx.dll (Windows x64 runtime)
REM   - segmentation.onnx
REM   - embedding.onnx
REM ============================================================
setlocal EnableExtensions

set "SCRIPT_DIR=%~dp0"
call "%SCRIPT_DIR%..\..\..\scripts\env.bat"

pushd "%SCRIPT_DIR%..\..\.."
if errorlevel 1 (
    echo [ERROR] Failed to enter repository root.
    exit /b 1
)

set "TARGET_RUNTIME_DIR=services\whisperdaemon\vendors\sherpa-onnx"
set "TARGET_MODELS_DIR=services\whisperdaemon\models\diarization"
set "TARGET_RUNTIME_DLL=%TARGET_RUNTIME_DIR%\sherpa-onnx.dll"
set "TARGET_ORT_DLL=%TARGET_RUNTIME_DIR%\onnxruntime.dll"
set "TARGET_ORT_SHARED_DLL=%TARGET_RUNTIME_DIR%\onnxruntime_providers_shared.dll"
set "TARGET_SEG_MODEL=%TARGET_MODELS_DIR%\segmentation.onnx"
set "TARGET_EMB_MODEL=%TARGET_MODELS_DIR%\embedding.onnx"

set "TMP_DIR=services\whisperdaemon\build\_tmp_diarize_download"
set "RUNTIME_ARCHIVE=%TMP_DIR%\sherpa-onnx-runtime.tar.bz2"
set "RUNTIME_EXTRACT_DIR=%TMP_DIR%\runtime_extract"
set "RUNTIME_URL_FILE=%TMP_DIR%\runtime_url.txt"
set "SEG_ARCHIVE=%TMP_DIR%\segmentation.tar.bz2"
set "SEG_EXTRACT_DIR=%TMP_DIR%\segmentation_extract"
set "EMB_TMP_FILE=%TMP_DIR%\embedding.onnx"

if not defined DIARIZE_SEG_URL set "DIARIZE_SEG_URL=https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/sherpa-onnx-reverb-diarization-v1.tar.bz2"
if not defined DIARIZE_EMB_URL set "DIARIZE_EMB_URL=https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx"

set "RUNTIME_URL=%SHERPA_ONNX_RUNTIME_URL%"
set "EXIT_CODE=1"

echo [INFO] Preparing directories...
if not exist "%TARGET_RUNTIME_DIR%" mkdir "%TARGET_RUNTIME_DIR%"
if errorlevel 1 (
    echo [ERROR] Failed to create directory: %TARGET_RUNTIME_DIR%
    goto :cleanup
)

if not exist "%TARGET_MODELS_DIR%" mkdir "%TARGET_MODELS_DIR%"
if errorlevel 1 (
    echo [ERROR] Failed to create directory: %TARGET_MODELS_DIR%
    goto :cleanup
)

if exist "%TMP_DIR%" rmdir /s /q "%TMP_DIR%" >nul 2>&1
mkdir "%TMP_DIR%"
if errorlevel 1 (
    echo [ERROR] Failed to create temp directory: %TMP_DIR%
    goto :cleanup
)

where tar >nul 2>&1
if errorlevel 1 (
    echo [ERROR] Required tool not found: tar
    echo [ERROR] Install bsdtar/tar and retry.
    goto :cleanup
)

if not defined RUNTIME_URL (
    echo [INFO] Resolving sherpa-onnx runtime asset URL...
    powershell -NoProfile -Command "$ErrorActionPreference='Stop'; $headers=@{'User-Agent'='EchoScript-WhisperDaemon-Downloader'}; $releaseApi = if ($env:SHERPA_ONNX_RUNTIME_TAG) { 'https://api.github.com/repos/k2-fsa/sherpa-onnx/releases/tags/' + $env:SHERPA_ONNX_RUNTIME_TAG } else { 'https://api.github.com/repos/k2-fsa/sherpa-onnx/releases/latest' }; $release = Invoke-RestMethod -Uri $releaseApi -Headers $headers; $pattern = if ($env:SHERPA_ONNX_RUNTIME_ASSET_PATTERN) { $env:SHERPA_ONNX_RUNTIME_ASSET_PATTERN } else { '^sherpa-onnx-v[\d.]+-win-x64-shared-MT-Release-lib\.tar\.bz2$' }; $asset = $release.assets | Where-Object { $_.name -match $pattern } | Select-Object -First 1; if (-not $asset) { throw ('Could not find runtime asset matching pattern: ' + $pattern) }; Set-Content -LiteralPath $env:RUNTIME_URL_FILE -Value $asset.browser_download_url -NoNewline"
    if errorlevel 1 (
        echo [ERROR] Failed to resolve runtime URL from GitHub API.
        goto :cleanup
    )

    set /p "RUNTIME_URL="<"%RUNTIME_URL_FILE%"
)

if not defined RUNTIME_URL (
    echo [ERROR] Failed to resolve runtime URL.
    echo [ERROR] Set SHERPA_ONNX_RUNTIME_URL manually and retry.
    goto :cleanup
)

echo [INFO] Runtime URL: %RUNTIME_URL%
echo [INFO] Segmentation URL: %DIARIZE_SEG_URL%
echo [INFO] Embedding URL: %DIARIZE_EMB_URL%
echo.

echo [INFO] Downloading sherpa-onnx runtime package...
powershell -NoProfile -Command "$ErrorActionPreference='Stop'; Invoke-WebRequest -Uri $env:RUNTIME_URL -OutFile $env:RUNTIME_ARCHIVE"
if errorlevel 1 (
    echo [ERROR] Failed to download sherpa-onnx runtime package.
    goto :cleanup
)

echo [INFO] Extracting sherpa-onnx runtime package...
if exist "%RUNTIME_EXTRACT_DIR%" rmdir /s /q "%RUNTIME_EXTRACT_DIR%" >nul 2>&1
mkdir "%RUNTIME_EXTRACT_DIR%"
if errorlevel 1 (
    echo [ERROR] Failed to create runtime extract directory.
    goto :cleanup
)

tar -xjf "%RUNTIME_ARCHIVE%" -C "%RUNTIME_EXTRACT_DIR%"
if errorlevel 1 (
    echo [ERROR] Failed to extract runtime archive: %RUNTIME_ARCHIVE%
    goto :cleanup
)

powershell -NoProfile -Command "$ErrorActionPreference='Stop'; $dll = Get-ChildItem -Path $env:RUNTIME_EXTRACT_DIR -Filter 'sherpa-onnx.dll' -File -Recurse | Select-Object -First 1; if (-not $dll) { $dll = Get-ChildItem -Path $env:RUNTIME_EXTRACT_DIR -Filter 'sherpa-onnx-c-api.dll' -File -Recurse | Select-Object -First 1 }; if (-not $dll) { throw 'Neither sherpa-onnx.dll nor sherpa-onnx-c-api.dll found in runtime archive' }; Copy-Item -LiteralPath $dll.FullName -Destination $env:TARGET_RUNTIME_DLL -Force; $ort = Get-ChildItem -Path $env:RUNTIME_EXTRACT_DIR -Filter 'onnxruntime.dll' -File -Recurse | Select-Object -First 1; if (-not $ort) { throw 'onnxruntime.dll not found in runtime archive' }; Copy-Item -LiteralPath $ort.FullName -Destination $env:TARGET_ORT_DLL -Force; $ortShared = Get-ChildItem -Path $env:RUNTIME_EXTRACT_DIR -Filter 'onnxruntime_providers_shared.dll' -File -Recurse | Select-Object -First 1; if (-not $ortShared) { throw 'onnxruntime_providers_shared.dll not found in runtime archive' }; Copy-Item -LiteralPath $ortShared.FullName -Destination $env:TARGET_ORT_SHARED_DLL -Force"
if errorlevel 1 (
    echo [ERROR] Failed to locate and stage sherpa-onnx runtime DLLs.
    goto :cleanup
)

echo [INFO] Downloading segmentation model archive...
powershell -NoProfile -Command "$ErrorActionPreference='Stop'; Invoke-WebRequest -Uri $env:DIARIZE_SEG_URL -OutFile $env:SEG_ARCHIVE"
if errorlevel 1 (
    echo [ERROR] Failed to download segmentation archive.
    goto :cleanup
)

echo [INFO] Extracting segmentation model...
if exist "%SEG_EXTRACT_DIR%" rmdir /s /q "%SEG_EXTRACT_DIR%" >nul 2>&1
mkdir "%SEG_EXTRACT_DIR%"
if errorlevel 1 (
    echo [ERROR] Failed to create segmentation extract directory.
    goto :cleanup
)

tar -xjf "%SEG_ARCHIVE%" -C "%SEG_EXTRACT_DIR%"
if errorlevel 1 (
    echo [ERROR] Failed to extract segmentation archive: %SEG_ARCHIVE%
    goto :cleanup
)

powershell -NoProfile -Command "$ErrorActionPreference='Stop'; $model = Get-ChildItem -Path $env:SEG_EXTRACT_DIR -Filter 'model.onnx' -File -Recurse | Select-Object -First 1; if (-not $model) { throw 'model.onnx not found in segmentation archive' }; Copy-Item -LiteralPath $model.FullName -Destination $env:TARGET_SEG_MODEL -Force"
if errorlevel 1 (
    echo [ERROR] Failed to locate and stage segmentation model.
    goto :cleanup
)

echo [INFO] Downloading embedding model...
powershell -NoProfile -Command "$ErrorActionPreference='Stop'; Invoke-WebRequest -Uri $env:DIARIZE_EMB_URL -OutFile $env:EMB_TMP_FILE"
if errorlevel 1 (
    echo [ERROR] Failed to download embedding model.
    goto :cleanup
)

copy /y "%EMB_TMP_FILE%" "%TARGET_EMB_MODEL%" >nul
if errorlevel 1 (
    echo [ERROR] Failed to stage embedding model: %TARGET_EMB_MODEL%
    goto :cleanup
)

echo [INFO] Validating downloaded assets...
powershell -NoProfile -Command "$ErrorActionPreference='Stop'; $paths=@($env:TARGET_RUNTIME_DLL,$env:TARGET_ORT_DLL,$env:TARGET_ORT_SHARED_DLL,$env:TARGET_SEG_MODEL,$env:TARGET_EMB_MODEL); foreach ($p in $paths) { if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { throw ('Missing file: ' + $p) }; $len = (Get-Item -LiteralPath $p).Length; if ($len -le 0) { throw ('File is empty: ' + $p) } }"
if errorlevel 1 (
    echo [ERROR] Asset validation failed.
    goto :cleanup
)

echo.
echo [OK] WhisperDaemon diarization assets are ready.
echo [OK] Runtime DLL: %TARGET_RUNTIME_DLL%
echo [OK] Runtime dependency: %TARGET_ORT_DLL%
echo [OK] Runtime dependency: %TARGET_ORT_SHARED_DLL%
echo [OK] Segmentation model: %TARGET_SEG_MODEL%
echo [OK] Embedding model: %TARGET_EMB_MODEL%
set "EXIT_CODE=0"

:cleanup
if exist "%TMP_DIR%" rmdir /s /q "%TMP_DIR%" >nul 2>&1
popd
exit /b %EXIT_CODE%