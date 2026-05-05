@echo off
REM ============================================================
REM EchoScript — Download: vosk-model-en-us-0.42-gigaspeech + Phase 2 assets
REM Requires: setup_vosk_en.bat to be run first.
REM ============================================================
setlocal

set "SCRIPT_DIR=%~dp0"
call "%SCRIPT_DIR%..\..\..\scripts\env.bat"
set "VENV_DIR=%SCRIPT_DIR%..\venv"

if not exist "%VENV_DIR%\Scripts\python.exe" (
    echo [ERROR] Virtual environment not found. Run setup_vosk_en.bat first.
    exit /b 1
)

echo [INFO] Downloading vosk-model-en-us-0.42-gigaspeech ...
echo [INFO] Model root: %VOSK_MODELS_ROOT%
echo.

"%VENV_DIR%\Scripts\python.exe" "%SCRIPT_DIR%..\..\..\scripts\download_vosk_model.py" --url "https://alphacephei.com/vosk/models/vosk-model-en-us-0.42-gigaspeech.zip" --target-root "%VOSK_MODELS_ROOT%" --expected-dir "vosk-model-en-us-0.42-gigaspeech"
if errorlevel 1 (
    echo [ERROR] Download failed.
    exit /b 1
)

echo.
echo [INFO] Downloading vosk-model-spk-0.4 ...
"%VENV_DIR%\Scripts\python.exe" "%SCRIPT_DIR%..\..\..\scripts\download_vosk_model.py" --hf-repo "Derur/vosk-models" --hf-path "speaker_indentification/vosk-model-spk-0.4" --target-root "%VOSK_MODELS_ROOT%" --expected-dir "vosk-model-spk-0.4"
if errorlevel 1 (
    echo [ERROR] Speaker model download failed.
    exit /b 1
)

echo.
echo [INFO] Downloading vosk-recasepunc-en-0.22 ...
"%VENV_DIR%\Scripts\python.exe" "%SCRIPT_DIR%..\..\..\scripts\download_vosk_model.py" --hf-repo "Derur/vosk-models" --hf-path "punctuation/vosk-recasepunc-en-0.22" --target-root "%VOSK_MODELS_ROOT%" --expected-dir "vosk-recasepunc-en-0.22"
if errorlevel 1 (
    echo [ERROR] Punctuation model download failed.
    exit /b 1
)

echo.
echo [INFO] Prefetching bert-base-uncased for punctuation runtime ...
"%VENV_DIR%\Scripts\python.exe" "%SCRIPT_DIR%..\..\..\scripts\prefetch_hf_model.py" --model-id "bert-base-uncased"
if errorlevel 1 (
    echo [ERROR] Hugging Face backbone prefetch failed.
    exit /b 1
)

echo.
echo [OK] vosk_en assets downloaded to %VOSK_MODELS_ROOT%

endlocal