@echo off
REM ============================================================
REM EchoScript — Download: vosk_ru_cmd command assets
REM Requires: setup_vosk_ru_cmd.bat to be run first.
REM ============================================================
setlocal

set "SCRIPT_DIR=%~dp0"
call "%SCRIPT_DIR%env.bat"
set "VENV_DIR=%SCRIPT_DIR%..\services\vosk_ru_cmd\venv"

if not exist "%VENV_DIR%\Scripts\python.exe" (
    echo [ERROR] Virtual environment not found. Run setup_vosk_ru_cmd.bat first.
    exit /b 1
)

echo [INFO] Downloading vosk_ru_cmd small acoustic model ...
echo [INFO] Model root: %VOSK_MODELS_ROOT%
echo.

"%VENV_DIR%\Scripts\python.exe" "%SCRIPT_DIR%download_vosk_model.py" --url "https://alphacephei.com/vosk/models/vosk-model-small-ru-0.22.zip" --target-root "%VOSK_MODELS_ROOT%" --expected-dir "vosk-model-small-ru-0.22"
if errorlevel 1 (
    echo [ERROR] Command model download failed.
    exit /b 1
)

echo.
echo [OK] vosk_ru_cmd assets downloaded to %VOSK_MODELS_ROOT%

endlocal