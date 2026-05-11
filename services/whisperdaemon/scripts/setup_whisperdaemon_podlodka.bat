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

set "TARGET_RUNTIME_DLL=services\whisperdaemon\vendors\sherpa-onnx\sherpa-onnx.dll"
set "TARGET_ORT_DLL=services\whisperdaemon\vendors\sherpa-onnx\onnxruntime.dll"
set "TARGET_ORT_SHARED_DLL=services\whisperdaemon\vendors\sherpa-onnx\onnxruntime_providers_shared.dll"
set "TARGET_SEG_MODEL=services\whisperdaemon\models\diarization\segmentation.onnx"
set "TARGET_EMB_MODEL=services\whisperdaemon\models\diarization\embedding.onnx"

set "TARGET_MODEL=services\whisperdaemon\models\ggml-whisper_podlodka.bin"
set "SOURCE_MODEL=services\whisperdaemon\spikes\conversion-out\ggml-model.bin"
set "PODLODKA_VENV=services\whisper_podlodka\venv\Scripts\python.exe"
set "SNAPSHOTS_ROOT=%HF_HUB_CACHE%\models--bond005--whisper-podlodka-turbo\snapshots"
set "AUTO_WHISPER_ROOT=services\whisperdaemon\vendors\openai-whisper"
set "AUTO_WHISPER_REPO=%AUTO_WHISPER_ROOT%\whisper-main"
set "AUTO_WHISPER_ZIP=%AUTO_WHISPER_ROOT%\whisper-main.zip"

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
    if %RUN_EXIT% neq 0 goto :fail
)

echo [INFO] Building WhisperDaemon...
call services\whisperdaemon\scripts\build_whisperdaemon.bat
set "RUN_EXIT=%ERRORLEVEL%"
if %RUN_EXIT% neq 0 goto :fail

echo [INFO] Checking staged model...
call :file_ready "%TARGET_MODEL%"
if not errorlevel 1 (
    echo [SKIP] Staged model is already present: %TARGET_MODEL%
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

    if exist "%PODLODKA_VENV%" (
        echo [SKIP] whisper_podlodka virtual environment is already present.
    ) else (
        echo [INFO] Setting up whisper_podlodka environment...
        call services\whisper_podlodka\scripts\setup_whisper_podlodka.bat
        set "RUN_EXIT=%ERRORLEVEL%"
        if %RUN_EXIT% neq 0 goto :fail
    )

    call :resolve_snapshot "%MODEL_SNAPSHOT_DIR%"
    if errorlevel 1 (
        echo [INFO] Hugging Face snapshot not found in cache. Downloading whisper-podlodka weights...
        call services\whisper_podlodka\scripts\download_whisper_podlodka.bat
        set "RUN_EXIT=%ERRORLEVEL%"
        if %RUN_EXIT% neq 0 goto :fail

        call :resolve_snapshot "%MODEL_SNAPSHOT_DIR%"
        if errorlevel 1 (
            echo [ERROR] Could not locate a valid whisper-podlodka snapshot after download.
            goto :conversionPrereqError
        )
    ) else (
        echo [SKIP] Reusing cached snapshot: !RESOLVED_SNAPSHOT!
    )

    echo [INFO] Converting whisper_podlodka snapshot to ggml...
    call services\whisperdaemon\scripts\convert_whisper_podlodka_hf_to_ggml.bat "!RESOLVED_WHISPER_REPO!" "!RESOLVED_SNAPSHOT!"
    set "RUN_EXIT=%ERRORLEVEL%"
    if %RUN_EXIT% neq 0 goto :fail
) else (
    echo [SKIP] Reusing existing conversion output: %SOURCE_MODEL%
)

echo [INFO] Staging model for WhisperDaemon...
call services\whisperdaemon\scripts\stage_whisperdaemon_model.bat
set "RUN_EXIT=%ERRORLEVEL%"
if %RUN_EXIT% neq 0 goto :fail

:ready
echo [OK] WhisperDaemon artifacts are ready.
echo [OK] To run manually: services\whisperdaemon\scripts\run_whisperdaemon_podlodka.bat
set "RUN_EXIT=0"
goto :done

:conversionPrereqError
echo.
echo [HINT] The script auto-downloads openai/whisper when conversion is needed.
echo [HINT] If that download is blocked, pass local repo as arg 1 or set WHISPER_OPENAI_REPO.
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
echo   - Missing openai/whisper assets are downloaded automatically when needed.
echo   - Arg 1 is optional and can override the auto-downloaded whisper repo path.
exit /b 0
