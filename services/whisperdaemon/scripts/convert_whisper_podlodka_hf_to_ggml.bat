@echo off
setlocal

REM Convert the downloaded Hugging Face whisper_podlodka snapshot into the
REM ggml binary format consumed by WhisperDaemon / whisper.cpp.
REM
REM Why this script exists:
REM - services\whisper_podlodka\scripts\download_whisper_podlodka.bat fetches a Hugging Face snapshot.
REM - WhisperDaemon.exe expects a ggml .bin model under services\whisperdaemon\models.
REM - The vendored whisper.cpp converter also needs a local clone of the
REM   original openai/whisper repository for tokenizer and mel-filter assets.
REM
REM Typical flow:
REM 1. Run services\whisper_podlodka\scripts\setup_whisper_podlodka.bat
REM 2. Run services\whisper_podlodka\scripts\download_whisper_podlodka.bat
REM 3. Run this conversion script
REM 4. Run services\whisperdaemon\scripts\stage_whisperdaemon_model.bat

pushd "%~dp0\..\..\.."
if errorlevel 1 exit /b 1

call "scripts\env.bat"

set "PYTHON_EXE=services\whisper_podlodka\venv\Scripts\python.exe"
set "CONVERTER_SCRIPT="
set "DEFAULT_WHISPER_CPP_ROOT=services\whisperdaemon\whisper.cpp"
set "VENDOR_WHISPER_CPP_ROOT=services\whisperdaemon\vendors\whisper.cpp\whisper.cpp-master"
set "OUTPUT_DIR=services\whisperdaemon\spikes\conversion-out"
set "OUTPUT_FILE=%OUTPUT_DIR%\ggml-model.bin"
set "SNAPSHOTS_DIR=%HF_HUB_CACHE%\models--bond005--whisper-podlodka-turbo\snapshots"

set "OPENAI_WHISPER_REPO=%~1"
set "MODEL_DIR=%~2"

REM Allow the caller to provide stable defaults via environment variables.
if not defined OPENAI_WHISPER_REPO (
    if defined WHISPER_OPENAI_REPO set "OPENAI_WHISPER_REPO=%WHISPER_OPENAI_REPO%"
)

if not defined OPENAI_WHISPER_REPO (
    if exist "..\whisper\whisper\assets\mel_filters.npz" set "OPENAI_WHISPER_REPO=..\whisper"
)

if not defined MODEL_DIR (
    if defined WHISPER_PODLODKA_SNAPSHOT_DIR set "MODEL_DIR=%WHISPER_PODLODKA_SNAPSHOT_DIR%"
)

REM If the snapshot is not provided explicitly, pick the newest cached one.
if not defined MODEL_DIR (
    for /f "delims=" %%D in ('dir /b /ad /o-d "%SNAPSHOTS_DIR%" 2^>nul') do (
        set "MODEL_DIR=%SNAPSHOTS_DIR%\%%D"
        goto :modelDirResolved
    )
)

:modelDirResolved
if not defined OPENAI_WHISPER_REPO goto :usage
if not defined MODEL_DIR goto :usage

if not exist "%PYTHON_EXE%" (
    echo Python environment not found:
    echo   %PYTHON_EXE%
    echo Run services\whisper_podlodka\scripts\setup_whisper_podlodka.bat first.
    popd
    exit /b 1
)

call :resolve_converter_script
if errorlevel 1 (
    echo Converter script not found.
    echo Checked roots:
    echo   %DEFAULT_WHISPER_CPP_ROOT%
    echo   %VENDOR_WHISPER_CPP_ROOT%
    echo Run services\whisperdaemon\scripts\setup_whisperdaemon_podlodka.bat first.
    popd
    exit /b 1
)

if not exist "%OPENAI_WHISPER_REPO%\whisper\assets\mel_filters.npz" (
    echo OpenAI whisper repo is missing required assets:
    echo   %OPENAI_WHISPER_REPO%\whisper\assets\mel_filters.npz
    echo Pass the path to a local clone of github.com/openai/whisper as arg 1.
    popd
    exit /b 1
)

if not exist "%MODEL_DIR%\config.json" (
    echo Hugging Face model snapshot not found or incomplete:
    echo   %MODEL_DIR%
    echo Pass the snapshot directory as arg 2 or run services\whisper_podlodka\scripts\download_whisper_podlodka.bat first.
    popd
    exit /b 1
)

if not exist "%MODEL_DIR%\vocab.json" (
    echo Hugging Face model snapshot is missing vocab.json:
    echo   %MODEL_DIR%
    popd
    exit /b 1
)

if not exist "%OUTPUT_DIR%" mkdir "%OUTPUT_DIR%"

echo Converting whisper_podlodka Hugging Face snapshot to ggml...
echo   model dir: %MODEL_DIR%
echo   whisper repo: %OPENAI_WHISPER_REPO%
echo   output dir: %OUTPUT_DIR%
echo.

"%PYTHON_EXE%" "%CONVERTER_SCRIPT%" "%MODEL_DIR%" "%OPENAI_WHISPER_REPO%" "%OUTPUT_DIR%"
set "RUN_EXIT=%ERRORLEVEL%"
if %RUN_EXIT% neq 0 (
    echo.
    echo Conversion failed with exit code %RUN_EXIT%.
    popd
    exit /b %RUN_EXIT%
)

if not exist "%OUTPUT_FILE%" (
    echo.
    echo Conversion finished but output file was not created:
    echo   %OUTPUT_FILE%
    popd
    exit /b 1
)

REM Staging is intentionally separate so the raw conversion output stays in
REM spikes\conversion-out for inspection and re-runs.
echo.
echo Converted model:
echo   %OUTPUT_FILE%
echo Next step:
echo   services\whisperdaemon\scripts\stage_whisperdaemon_model.bat

popd
exit /b 0

:resolve_converter_script
set "CONVERTER_SCRIPT="

if defined WHISPER_CPP_ROOT (
    if exist "%WHISPER_CPP_ROOT%\models\convert-h5-to-ggml.py" set "CONVERTER_SCRIPT=%WHISPER_CPP_ROOT%\models\convert-h5-to-ggml.py"
)

if not defined CONVERTER_SCRIPT (
    if exist "%DEFAULT_WHISPER_CPP_ROOT%\models\convert-h5-to-ggml.py" set "CONVERTER_SCRIPT=%DEFAULT_WHISPER_CPP_ROOT%\models\convert-h5-to-ggml.py"
)

if not defined CONVERTER_SCRIPT (
    if exist "%VENDOR_WHISPER_CPP_ROOT%\models\convert-h5-to-ggml.py" set "CONVERTER_SCRIPT=%VENDOR_WHISPER_CPP_ROOT%\models\convert-h5-to-ggml.py"
)

if defined CONVERTER_SCRIPT exit /b 0
exit /b 1

:usage
echo Usage:
echo   services\whisperdaemon\scripts\convert_whisper_podlodka_hf_to_ggml.bat ^<path-to-openai-whisper-repo^> [path-to-hf-snapshot]
echo.
echo Examples:
echo   services\whisperdaemon\scripts\convert_whisper_podlodka_hf_to_ggml.bat ..\whisper
echo   services\whisperdaemon\scripts\convert_whisper_podlodka_hf_to_ggml.bat ..\whisper ..\huggingface\bond005-whisper-podlodka-turbo
echo.
echo If arg 2 is omitted, the latest snapshot under:
echo   %SNAPSHOTS_DIR%
echo is used automatically.
echo.
echo You can also set WHISPER_OPENAI_REPO, WHISPER_PODLODKA_SNAPSHOT_DIR,
echo and optionally WHISPER_CPP_ROOT.
echo.
echo Run services\whisperdaemon\scripts\setup_whisperdaemon_podlodka.bat to prepare all dependencies automatically.

popd
exit /b 1