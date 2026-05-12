@echo off
REM ============================================================
REM EchoScript - Setup: WhisperDaemon podlodka pipeline
REM Runs the full flow with skip checks:
REM   1) diarization assets
REM   2) WhisperDaemon build
REM   3) model conversion/staging (if needed)
REM   4) ready-to-run daemon artifacts
REM
REM Usage:
REM   services\whisperdaemon\scripts\setup_whisperdaemon_podlodka.bat [path-to-openai-whisper-repo] [path-to-hf-snapshot]
REM If arg 1 is omitted and conversion is needed, the script auto-downloads
REM openai/whisper to services\whisperdaemon\vendors\openai-whisper.
REM ============================================================
setlocal EnableExtensions EnableDelayedExpansion

if /I "%~1"=="-h" goto :usage
if /I "%~1"=="--help" goto :usage

set "OPENAI_WHISPER_REPO=%~1"
set "MODEL_SNAPSHOT_DIR=%~2"
set "RUN_EXIT=1"

set "SCRIPT_DIR=%~dp0"
pushd "%SCRIPT_DIR%..\..\.."
if errorlevel 1 (
    echo [ERROR] Failed to enter repository root.
    exit /b 1
)

call "scripts\env.bat"

set "LOCAL_ENV_SCRIPT=services\whisperdaemon\scripts\.env.bat"
if exist "%LOCAL_ENV_SCRIPT%" (
    echo [INFO] Loading local whisperdaemon overrides: %LOCAL_ENV_SCRIPT%
    call "%LOCAL_ENV_SCRIPT%"
    if errorlevel 1 (
        echo [ERROR] Failed to load local config: %LOCAL_ENV_SCRIPT%
        exit /b 1
    )
)

set "ECHORECORDER_VENDORSCORE_DIR=EchoRecorder\VendorsCore"
set "FPC_SETUP_SCRIPT=%ECHORECORDER_VENDORSCORE_DIR%\fpc\scripts\win_x64\fpc_release_setup.bat"
if not defined VENDORSCORE_REPO_URL set "VENDORSCORE_REPO_URL=https://github.com/Keksov/VendorsCore.git"

echo [INFO] Checking VendorsCore repository...
call :ensure_vendorscore
set "RUN_EXIT=%ERRORLEVEL%"
if errorlevel 1 goto :fail

set "TARGET_RUNTIME_DLL=services\whisperdaemon\vendors\sherpa-onnx\sherpa-onnx.dll"
set "TARGET_ORT_DLL=services\whisperdaemon\vendors\sherpa-onnx\onnxruntime.dll"
set "TARGET_ORT_SHARED_DLL=services\whisperdaemon\vendors\sherpa-onnx\onnxruntime_providers_shared.dll"
set "TARGET_SEG_MODEL=services\whisperdaemon\models\diarization\segmentation.onnx"
set "TARGET_EMB_MODEL=services\whisperdaemon\models\diarization\embedding.onnx"

set "TARGET_MODEL=services\whisperdaemon\models\ggml-whisper_podlodka.bin"
set "SOURCE_MODEL=services\whisperdaemon\spikes\conversion-out\ggml-model.bin"
set "WHISPER_DLL_RELEASE_TAG=1.8.4"
if defined WHISPER_RELEASE_TAG set "WHISPER_DLL_RELEASE_TAG=%WHISPER_RELEASE_TAG%"
set "WHISPER_RELEASE_DIR=services\whisperdaemon\releases\%WHISPER_DLL_RELEASE_TAG%"
set "WHISPER_RUNTIME_DLL=%WHISPER_RELEASE_DIR%\whisper.dll"
set "WHISPER_RUNTIME_CLI=%WHISPER_RELEASE_DIR%\whisper-cli.exe"
set "WHISPER_BIN_ASSET=whisper-bin-x64.zip"
set "WHISPER_BIN_ARCHIVE=services\whisperdaemon\build\_tmp_whisper_bin\%WHISPER_BIN_ASSET%"
set "WHISPER_BIN_EXTRACT_DIR=services\whisperdaemon\build\_tmp_whisper_bin\extract"
set "WHISPER_SMOKE_WAV=services\whisperdaemon\build\_tmp_whisper_bin\smoke.wav"
set "WHISPER_SMOKE_OUT_PREFIX=services\whisperdaemon\build\_tmp_whisper_bin\smoke_out"
set "WHISPER_RUNTIME_MARKER=%WHISPER_RELEASE_DIR%\.whisper_runtime_ready"
set "WHISPER_COMPAT_BUILD_SCRIPT=services\whisperdaemon\scripts\build_x64_compatible.bat"
set "COMMON_WIN_DIR=EchoRecorder\VendorsCore\common\win"
set "PODLODKA_VENV=services\whisper_podlodka\venv\Scripts\python.exe"
set "SNAPSHOTS_ROOT=%HF_HUB_CACHE%\models--bond005--whisper-podlodka-turbo\snapshots"
set "AUTO_WHISPER_ROOT=services\whisperdaemon\vendors\openai-whisper"
set "AUTO_WHISPER_REPO=%AUTO_WHISPER_ROOT%\whisper-main"
set "AUTO_WHISPER_ZIP=%AUTO_WHISPER_ROOT%\whisper-main.zip"
set "WHISPER_CPP_VENDOR_DIR=services\whisperdaemon\vendors\whisper.cpp"
set "WHISPER_CPP_VENDOR_ROOT=%WHISPER_CPP_VENDOR_DIR%\whisper.cpp-master"
set "WHISPER_CPP_VENDOR_ARCHIVE=%WHISPER_CPP_VENDOR_DIR%\whisper.cpp-master.zip"
if not defined WHISPER_CPP_DOWNLOAD_URL set "WHISPER_CPP_DOWNLOAD_URL=https://github.com/ggml-org/whisper.cpp/archive/refs/heads/master.zip"

echo [INFO] Checking diarization assets...
set "DIARIZE_READY=1"
call :file_ready "%TARGET_RUNTIME_DLL%"
if errorlevel 1 set "DIARIZE_READY=0"
call :file_ready "%TARGET_ORT_DLL%"
if errorlevel 1 set "DIARIZE_READY=0"
call :file_ready "%TARGET_ORT_SHARED_DLL%"
if errorlevel 1 set "DIARIZE_READY=0"
call :file_ready "%TARGET_SEG_MODEL%"
if errorlevel 1 set "DIARIZE_READY=0"
call :file_ready "%TARGET_EMB_MODEL%"
if errorlevel 1 set "DIARIZE_READY=0"

if "%DIARIZE_READY%"=="1" (
    echo [SKIP] Diarization assets are already present.
) else (
    echo [INFO] Some diarization assets are missing. Downloading...
    call services\whisperdaemon\scripts\download_diarize_models.bat
    set "RUN_EXIT=%ERRORLEVEL%"
    if errorlevel 1 goto :fail
)

echo [INFO] Building WhisperDaemon...
call services\whisperdaemon\scripts\build_whisperdaemon.bat
set "RUN_EXIT=%ERRORLEVEL%"
if errorlevel 1 goto :fail

echo [INFO] Checking whisper runtime DLL...
call :ensure_whisper_runtime
set "RUN_EXIT=%ERRORLEVEL%"
if errorlevel 1 goto :fail

echo [INFO] Checking staged model...
call :file_ready "%TARGET_MODEL%"
if not errorlevel 1 (
    echo [SKIP] Staged model is already present: %TARGET_MODEL%
    echo [INFO] Running runtime smoke-test...
    call :ensure_whisper_runtime_smoke
    set "RUN_EXIT=%ERRORLEVEL%"
    if errorlevel 1 goto :fail
    goto :ready
)

echo [INFO] Staged model is missing. Preparing conversion output...
call :file_ready "%SOURCE_MODEL%"
if errorlevel 1 (
    call :ensure_whisper_repo "%OPENAI_WHISPER_REPO%"
    if errorlevel 1 (
        echo [ERROR] OpenAI whisper repository assets are unavailable.
        echo [ERROR] Required file: whisper\assets\mel_filters.npz
        goto :conversionPrereqError
    )

    call :ensure_whisper_cpp
    if errorlevel 1 (
        echo [ERROR] Failed to prepare whisper.cpp converter.
        goto :conversionPrereqError
    )

    if exist "%PODLODKA_VENV%" (
        echo [SKIP] whisper_podlodka virtual environment is already present.
    ) else (
        echo [INFO] Setting up whisper_podlodka environment...
        call services\whisper_podlodka\scripts\setup_whisper_podlodka.bat
        set "RUN_EXIT=%ERRORLEVEL%"
        if errorlevel 1 goto :fail
    )

    call :resolve_snapshot "%MODEL_SNAPSHOT_DIR%"
    if errorlevel 1 (
        echo [INFO] Hugging Face snapshot not found in cache. Downloading whisper-podlodka weights...
        call services\whisper_podlodka\scripts\download_whisper_podlodka.bat
        set "RUN_EXIT=%ERRORLEVEL%"
        if errorlevel 1 goto :fail

        call :resolve_snapshot "%MODEL_SNAPSHOT_DIR%"
        if errorlevel 1 (
            echo [ERROR] Could not locate a valid whisper-podlodka snapshot after download.
            goto :conversionPrereqError
        )
    ) else (
        echo [SKIP] Reusing cached snapshot: !RESOLVED_SNAPSHOT!
    )

    echo [INFO] Converting whisper_podlodka snapshot to ggml...
    set "WHISPER_CPP_ROOT=!RESOLVED_WHISPER_CPP_ROOT!"
    call services\whisperdaemon\scripts\convert_whisper_podlodka_hf_to_ggml.bat "!RESOLVED_WHISPER_REPO!" "!RESOLVED_SNAPSHOT!"
    set "RUN_EXIT=%ERRORLEVEL%"
    if errorlevel 1 goto :fail
) else (
    echo [SKIP] Reusing existing conversion output: %SOURCE_MODEL%
)

echo [INFO] Staging model for WhisperDaemon...
call services\whisperdaemon\scripts\stage_whisperdaemon_model.bat
set "RUN_EXIT=%ERRORLEVEL%"
if errorlevel 1 goto :fail

echo [INFO] Running runtime smoke-test...
call :ensure_whisper_runtime_smoke
set "RUN_EXIT=%ERRORLEVEL%"
if errorlevel 1 goto :fail

:ready
echo [OK] WhisperDaemon artifacts are ready.
echo [OK] To run manually: services\whisperdaemon\scripts\run_whisperdaemon_podlodka.bat
set "RUN_EXIT=0"
goto :done

:conversionPrereqError
echo.
echo [HINT] The script auto-downloads openai/whisper and whisper.cpp when conversion is needed.
echo [HINT] If downloads are blocked, set WHISPER_OPENAI_REPO and/or WHISPER_CPP_ROOT.
echo [HINT] Example:
echo [HINT]   services\whisperdaemon\scripts\setup_whisperdaemon_podlodka.bat ..\whisper
set "RUN_EXIT=1"
goto :done

:fail
echo.
echo [FAIL] setup_whisperdaemon_podlodka failed with exit code %RUN_EXIT%.

:done
popd
exit /b %RUN_EXIT%

:ensure_vendorscore
if exist "%FPC_SETUP_SCRIPT%" (
    echo [SKIP] VendorsCore is already present: %ECHORECORDER_VENDORSCORE_DIR%
    exit /b 0
)

if exist "%ECHORECORDER_VENDORSCORE_DIR%" (
    echo [ERROR] VendorsCore directory exists but required script is missing:
    echo [ERROR]   %FPC_SETUP_SCRIPT%
    echo [ERROR] Resolve this directory and rerun setup.
    exit /b 1
)

where git >nul 2>&1
if errorlevel 1 (
    echo [ERROR] git.exe was not found in PATH.
    echo [ERROR] Install Git or clone %VENDORSCORE_REPO_URL% into %ECHORECORDER_VENDORSCORE_DIR%.
    exit /b 1
)

echo [INFO] VendorsCore repository is missing. Cloning...
git clone "%VENDORSCORE_REPO_URL%" "%ECHORECORDER_VENDORSCORE_DIR%"
if errorlevel 1 (
    echo [ERROR] Failed to clone VendorsCore from %VENDORSCORE_REPO_URL%.
    exit /b 1
)

if not exist "%FPC_SETUP_SCRIPT%" (
    echo [ERROR] VendorsCore clone completed but required script is missing:
    echo [ERROR]   %FPC_SETUP_SCRIPT%
    exit /b 1
)

echo [INFO] VendorsCore repository is ready.
exit /b 0

:ensure_whisper_runtime
call :file_ready "%WHISPER_RUNTIME_DLL%"
if not errorlevel 1 (
    if exist "%WHISPER_RUNTIME_MARKER%" (
        echo [SKIP] whisper runtime is already present: %WHISPER_RELEASE_DIR%
        exit /b 0
    )
)

if not exist "%COMMON_WIN_DIR%\release_asset_download.bat" (
    echo [ERROR] Missing helper script: %COMMON_WIN_DIR%\release_asset_download.bat
    exit /b 1
)

for %%I in ("%WHISPER_BIN_ARCHIVE%") do set "WHISPER_BIN_DIR=%%~dpI"
if not exist "%WHISPER_BIN_DIR%" (
    mkdir "%WHISPER_BIN_DIR%"
    if errorlevel 1 (
        echo [ERROR] Failed to create directory: %WHISPER_BIN_DIR%
        exit /b 1
    )
)

if not exist "%WHISPER_RELEASE_DIR%" (
    mkdir "%WHISPER_RELEASE_DIR%"
    if errorlevel 1 (
        echo [ERROR] Failed to create directory: %WHISPER_RELEASE_DIR%
        exit /b 1
    )
)

echo [INFO] Downloading whisper runtime asset %WHISPER_BIN_ASSET% (tag v%WHISPER_DLL_RELEASE_TAG%)...
call "%COMMON_WIN_DIR%\release_asset_download.bat" --repo "ggml-org/whisper.cpp" --asset "%WHISPER_BIN_ASSET%" --out "%WHISPER_BIN_ARCHIVE%" --tag "v%WHISPER_DLL_RELEASE_TAG%"
if errorlevel 1 (
    echo [ERROR] Failed to download %WHISPER_BIN_ASSET%.
    exit /b 1
)

if exist "%WHISPER_BIN_EXTRACT_DIR%" rmdir /s /q "%WHISPER_BIN_EXTRACT_DIR%" >nul 2>&1
mkdir "%WHISPER_BIN_EXTRACT_DIR%" >nul 2>&1
if errorlevel 1 (
    echo [ERROR] Failed to create extraction directory: %WHISPER_BIN_EXTRACT_DIR%
    exit /b 1
)

powershell -NoProfile -Command "$ErrorActionPreference='Stop'; Expand-Archive -LiteralPath $env:WHISPER_BIN_ARCHIVE -DestinationPath $env:WHISPER_BIN_EXTRACT_DIR -Force"
if errorlevel 1 (
    echo [ERROR] Failed to extract archive into: %WHISPER_BIN_EXTRACT_DIR%
    exit /b 1
)

set "RUNTIME_CONTENT_DIR="
if exist "%WHISPER_BIN_EXTRACT_DIR%\Releases\whisper.dll" set "RUNTIME_CONTENT_DIR=%WHISPER_BIN_EXTRACT_DIR%\Releases"
if not defined RUNTIME_CONTENT_DIR if exist "%WHISPER_BIN_EXTRACT_DIR%\Release\whisper.dll" set "RUNTIME_CONTENT_DIR=%WHISPER_BIN_EXTRACT_DIR%\Release"
if not defined RUNTIME_CONTENT_DIR if exist "%WHISPER_BIN_EXTRACT_DIR%\Relases\whisper.dll" set "RUNTIME_CONTENT_DIR=%WHISPER_BIN_EXTRACT_DIR%\Relases"
if not defined RUNTIME_CONTENT_DIR if exist "%WHISPER_BIN_EXTRACT_DIR%\whisper.dll" set "RUNTIME_CONTENT_DIR=%WHISPER_BIN_EXTRACT_DIR%"

if not defined RUNTIME_CONTENT_DIR (
    for /r "%WHISPER_BIN_EXTRACT_DIR%" %%F in (whisper.dll) do (
        if not defined RUNTIME_CONTENT_DIR set "RUNTIME_CONTENT_DIR=%%~dpF"
    )
)

if not defined RUNTIME_CONTENT_DIR (
    echo [ERROR] whisper.dll was not found in archive: %WHISPER_BIN_ARCHIVE%
    exit /b 1
)

for %%I in ("!RUNTIME_CONTENT_DIR!") do set "RUNTIME_CONTENT_DIR=%%~fI"
echo [INFO] Runtime content source: !RUNTIME_CONTENT_DIR!

robocopy "!RUNTIME_CONTENT_DIR!" "%WHISPER_RELEASE_DIR%" /E /NFL /NDL /NJH /NJS /NC /NS /NP >nul
if errorlevel 8 (
    echo [ERROR] Failed to stage runtime contents with robocopy.
    exit /b 1
)

if exist "%WHISPER_RELEASE_DIR%\Release" rmdir /s /q "%WHISPER_RELEASE_DIR%\Release" >nul 2>&1
if exist "%WHISPER_RELEASE_DIR%\Releases" rmdir /s /q "%WHISPER_RELEASE_DIR%\Releases" >nul 2>&1
if exist "%WHISPER_RELEASE_DIR%\Relases" rmdir /s /q "%WHISPER_RELEASE_DIR%\Relases" >nul 2>&1

call :file_ready "%WHISPER_RUNTIME_DLL%"
if errorlevel 1 (
    echo [ERROR] whisper.dll is missing or empty after staging: %WHISPER_RUNTIME_DLL%
    exit /b 1
)

> "%WHISPER_RUNTIME_MARKER%" echo whisper-runtime-v%WHISPER_DLL_RELEASE_TAG%
if exist "%WHISPER_BIN_EXTRACT_DIR%" rmdir /s /q "%WHISPER_BIN_EXTRACT_DIR%" >nul 2>&1

echo [OK] whisper runtime is ready: %WHISPER_RELEASE_DIR%
exit /b 0

:ensure_whisper_runtime_smoke
call :resolve_smoke_model
if errorlevel 1 (
    echo [WARN] Runtime smoke-test skipped: no prepared model file found.
    exit /b 0
)

call :run_whisper_runtime_smoke_test "!RESOLVED_SMOKE_MODEL!"
if not errorlevel 1 (
    echo [OK] Runtime smoke-test passed.
    exit /b 0
)

echo [WARN] Runtime smoke-test failed. Building compatible x64 runtime...
if not exist "%WHISPER_COMPAT_BUILD_SCRIPT%" (
    echo [ERROR] Missing compatible build script: %WHISPER_COMPAT_BUILD_SCRIPT%
    exit /b 1
)

call :ensure_whisper_cpp
if errorlevel 1 (
    echo [ERROR] Cannot prepare whisper.cpp source for compatible build.
    exit /b 1
)

call "%WHISPER_COMPAT_BUILD_SCRIPT%" "!RESOLVED_WHISPER_CPP_ROOT!"
if errorlevel 1 (
    echo [ERROR] Compatible runtime build failed.
    exit /b 1
)

echo [INFO] Re-running runtime smoke-test after compatible build...
call :run_whisper_runtime_smoke_test "!RESOLVED_SMOKE_MODEL!"
if errorlevel 1 (
    echo [ERROR] Runtime smoke-test is still failing after compatible build.
    exit /b 1
)

> "%WHISPER_RUNTIME_MARKER%" echo whisper-runtime-v%WHISPER_DLL_RELEASE_TAG%-compatible
echo [OK] Runtime smoke-test passed after compatible build.
exit /b 0

:resolve_smoke_model
set "RESOLVED_SMOKE_MODEL="
call :file_ready "%TARGET_MODEL%"
if not errorlevel 1 set "RESOLVED_SMOKE_MODEL=%TARGET_MODEL%"

if not defined RESOLVED_SMOKE_MODEL (
    call :file_ready "%SOURCE_MODEL%"
    if not errorlevel 1 set "RESOLVED_SMOKE_MODEL=%SOURCE_MODEL%"
)

if defined RESOLVED_SMOKE_MODEL exit /b 0
exit /b 1

:run_whisper_runtime_smoke_test
if not exist "%WHISPER_RUNTIME_CLI%" (
    echo [WARN] Runtime smoke-test failed: %WHISPER_RUNTIME_CLI% not found.
    exit /b 1
)

call :ensure_smoke_wav
if errorlevel 1 exit /b 1

if exist "%WHISPER_SMOKE_OUT_PREFIX%.txt" del /q "%WHISPER_SMOKE_OUT_PREFIX%.txt" >nul 2>&1

"%WHISPER_RUNTIME_CLI%" -m "%~1" -f "%WHISPER_SMOKE_WAV%" -otxt -of "%WHISPER_SMOKE_OUT_PREFIX%" >nul 2>&1
set "SMOKE_EXIT=%ERRORLEVEL%"
if not "%SMOKE_EXIT%"=="0" (
    echo [WARN] Runtime smoke-test command exited with code %SMOKE_EXIT%.
    exit /b 1
)

exit /b 0

:ensure_smoke_wav
for %%I in ("%WHISPER_SMOKE_WAV%") do set "WHISPER_SMOKE_DIR=%%~dpI"
if not exist "%WHISPER_SMOKE_DIR%" (
    mkdir "%WHISPER_SMOKE_DIR%"
    if errorlevel 1 (
        echo [ERROR] Failed to create smoke-test directory: %WHISPER_SMOKE_DIR%
        exit /b 1
    )
)

call :file_ready "%WHISPER_SMOKE_WAV%"
if not errorlevel 1 exit /b 0

powershell -NoProfile -Command "$ErrorActionPreference='Stop'; $path=$env:WHISPER_SMOKE_WAV; $sampleRate=16000; $samples=$sampleRate; $channels=1; $bits=16; $blockAlign=[int]($channels * $bits / 8); $byteRate=[int]($sampleRate * $blockAlign); $dataSize=[int]($samples * $blockAlign); $chunkSize=[int](36 + $dataSize); $dir=Split-Path -Parent $path; if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }; $fs=[System.IO.File]::Open($path,[System.IO.FileMode]::Create,[System.IO.FileAccess]::Write,[System.IO.FileShare]::None); try { $bw=New-Object System.IO.BinaryWriter($fs); try { $enc=[System.Text.Encoding]::ASCII; $bw.Write($enc.GetBytes('RIFF')); $bw.Write($chunkSize); $bw.Write($enc.GetBytes('WAVE')); $bw.Write($enc.GetBytes('fmt ')); $bw.Write([int]16); $bw.Write([int16]1); $bw.Write([int16]$channels); $bw.Write([int]$sampleRate); $bw.Write([int]$byteRate); $bw.Write([int16]$blockAlign); $bw.Write([int16]$bits); $bw.Write($enc.GetBytes('data')); $bw.Write([int]$dataSize); for ($i = 0; $i -lt $samples; $i++) { $bw.Write([int16]0) } } finally { $bw.Dispose() } } finally { $fs.Dispose() }"
if errorlevel 1 (
    echo [ERROR] Failed to prepare smoke-test WAV file: %WHISPER_SMOKE_WAV%
    exit /b 1
)

call :file_ready "%WHISPER_SMOKE_WAV%"
if errorlevel 1 (
    echo [ERROR] Smoke-test WAV file is missing or empty: %WHISPER_SMOKE_WAV%
    exit /b 1
)

exit /b 0

:ensure_whisper_cpp
set "RESOLVED_WHISPER_CPP_ROOT="

if defined WHISPER_CPP_ROOT (
    if exist "%WHISPER_CPP_ROOT%\models\convert-h5-to-ggml.py" set "RESOLVED_WHISPER_CPP_ROOT=%WHISPER_CPP_ROOT%"
)

if not defined RESOLVED_WHISPER_CPP_ROOT (
    if exist "%WHISPER_CPP_VENDOR_ROOT%\models\convert-h5-to-ggml.py" set "RESOLVED_WHISPER_CPP_ROOT=%WHISPER_CPP_VENDOR_ROOT%"
)

if not defined RESOLVED_WHISPER_CPP_ROOT (
    if exist "services\whisperdaemon\whisper.cpp\models\convert-h5-to-ggml.py" set "RESOLVED_WHISPER_CPP_ROOT=services\whisperdaemon\whisper.cpp"
)

if defined RESOLVED_WHISPER_CPP_ROOT (
    echo [SKIP] whisper.cpp converter already present: !RESOLVED_WHISPER_CPP_ROOT!
    exit /b 0
)

echo [INFO] whisper.cpp converter not found locally. Downloading from GitHub...

if not exist "%WHISPER_CPP_VENDOR_DIR%" mkdir "%WHISPER_CPP_VENDOR_DIR%"
if errorlevel 1 (
    echo [ERROR] Failed to create directory: %WHISPER_CPP_VENDOR_DIR%
    exit /b 1
)

if exist "%WHISPER_CPP_VENDOR_ARCHIVE%" del /q "%WHISPER_CPP_VENDOR_ARCHIVE%" >nul 2>&1

powershell -NoProfile -Command "$ErrorActionPreference='Stop'; Invoke-WebRequest -Uri $env:WHISPER_CPP_DOWNLOAD_URL -OutFile $env:WHISPER_CPP_VENDOR_ARCHIVE; Expand-Archive -LiteralPath $env:WHISPER_CPP_VENDOR_ARCHIVE -DestinationPath $env:WHISPER_CPP_VENDOR_DIR -Force"
if errorlevel 1 (
    echo [ERROR] Failed to download or extract whisper.cpp.
    exit /b 1
)

if exist "%WHISPER_CPP_VENDOR_ARCHIVE%" del /q "%WHISPER_CPP_VENDOR_ARCHIVE%" >nul 2>&1

if exist "%WHISPER_CPP_VENDOR_ROOT%\models\convert-h5-to-ggml.py" (
    set "RESOLVED_WHISPER_CPP_ROOT=%WHISPER_CPP_VENDOR_ROOT%"
    exit /b 0
)

echo [ERROR] whisper.cpp downloaded but converter script not found.
exit /b 1

:ensure_whisper_repo
call :resolve_whisper_repo "%~1"
if not errorlevel 1 exit /b 0

echo [INFO] OpenAI whisper repo not found locally. Downloading from GitHub...
if not exist "%AUTO_WHISPER_ROOT%" mkdir "%AUTO_WHISPER_ROOT%"
if errorlevel 1 (
    echo [ERROR] Failed to create directory: %AUTO_WHISPER_ROOT%
    exit /b 1
)

if exist "%AUTO_WHISPER_ZIP%" del /q "%AUTO_WHISPER_ZIP%" >nul 2>&1

powershell -NoProfile -Command "$ErrorActionPreference='Stop'; Invoke-WebRequest -Uri 'https://github.com/openai/whisper/archive/refs/heads/main.zip' -OutFile $env:AUTO_WHISPER_ZIP; Expand-Archive -LiteralPath $env:AUTO_WHISPER_ZIP -DestinationPath $env:AUTO_WHISPER_ROOT -Force"
if errorlevel 1 (
    echo [ERROR] Failed to download or extract openai/whisper snapshot.
    exit /b 1
)

if exist "%AUTO_WHISPER_ZIP%" del /q "%AUTO_WHISPER_ZIP%" >nul 2>&1

call :resolve_whisper_repo "%~1"
if not errorlevel 1 exit /b 0

echo [ERROR] openai/whisper snapshot downloaded but required assets were not found.
exit /b 1

:resolve_whisper_repo
set "RESOLVED_WHISPER_REPO="
if not "%~1"=="" (
    if exist "%~1\whisper\assets\mel_filters.npz" set "RESOLVED_WHISPER_REPO=%~1"
)

if not defined RESOLVED_WHISPER_REPO (
    if defined WHISPER_OPENAI_REPO (
        if exist "%WHISPER_OPENAI_REPO%\whisper\assets\mel_filters.npz" set "RESOLVED_WHISPER_REPO=%WHISPER_OPENAI_REPO%"
    )
)

if not defined RESOLVED_WHISPER_REPO (
    if exist "..\whisper\whisper\assets\mel_filters.npz" set "RESOLVED_WHISPER_REPO=..\whisper"
)

if not defined RESOLVED_WHISPER_REPO (
    if exist "%AUTO_WHISPER_REPO%\whisper\assets\mel_filters.npz" set "RESOLVED_WHISPER_REPO=%AUTO_WHISPER_REPO%"
)

if defined RESOLVED_WHISPER_REPO exit /b 0
exit /b 1

:resolve_snapshot
set "RESOLVED_SNAPSHOT="
if not "%~1"=="" (
    if exist "%~1\config.json" (
        if exist "%~1\vocab.json" set "RESOLVED_SNAPSHOT=%~1"
    )
)

if not defined RESOLVED_SNAPSHOT (
    if defined WHISPER_PODLODKA_SNAPSHOT_DIR (
        if exist "%WHISPER_PODLODKA_SNAPSHOT_DIR%\config.json" (
            if exist "%WHISPER_PODLODKA_SNAPSHOT_DIR%\vocab.json" set "RESOLVED_SNAPSHOT=%WHISPER_PODLODKA_SNAPSHOT_DIR%"
        )
    )
)

if not defined RESOLVED_SNAPSHOT (
    for /f "delims=" %%D in ('dir /b /ad /o-d "%SNAPSHOTS_ROOT%" 2^>nul') do (
        set "CANDIDATE_SNAPSHOT=%SNAPSHOTS_ROOT%\%%D"
        if exist "!CANDIDATE_SNAPSHOT!\config.json" (
            if exist "!CANDIDATE_SNAPSHOT!\vocab.json" (
                set "RESOLVED_SNAPSHOT=!CANDIDATE_SNAPSHOT!"
                goto :snapshotResolved
            )
        )
    )
)

:snapshotResolved
if defined RESOLVED_SNAPSHOT exit /b 0
exit /b 1

:file_ready
if not exist "%~1" exit /b 1
for %%F in ("%~1") do (
    if %%~zF LEQ 0 exit /b 1
)
exit /b 0

:usage
echo Usage:
echo   services\whisperdaemon\scripts\setup_whisperdaemon_podlodka.bat [path-to-openai-whisper-repo] [path-to-hf-snapshot]
echo.
echo Notes:
echo   - The script skips already prepared files and cached assets.
echo   - Missing EchoRecorder\VendorsCore is cloned automatically.
echo   - Missing openai/whisper assets are downloaded automatically when needed.
echo   - Missing whisper runtime is downloaded from ggml-org/whisper.cpp release assets.
echo   - If runtime smoke-test fails, compatible runtime is rebuilt via build_x64_compatible.bat.
echo   - If present, services\whisperdaemon\scripts\.env.bat is loaded for local overrides.
echo   - Arg 1 is optional and can override the auto-downloaded whisper repo path.
exit /b 0
