@echo off
REM ============================================================
REM EchoScript — Download: vibevoicedaemon weights
REM Requires: setup_vibevoicedaemon.bat to be run first.
REM Downloads:
REM   - microsoft/VibeVoice-ASR
REM   - Qwen/Qwen2.5-7B (vendor demo tokenizer dependency)
REM ============================================================
setlocal

set "SCRIPT_DIR=%~dp0"
call "%SCRIPT_DIR%..\..\..\scripts\env.bat"
for %%I in ("%SCRIPT_DIR%..") do set "VENV_DIR=%%~fI\venv"

if not exist "%VENV_DIR%\Scripts\python.exe" (
    echo [ERROR] Virtual environment not found. Run setup_vibevoicedaemon.bat first.
    exit /b 1
)

echo [INFO] Downloading vibevoicedaemon model dependencies ...
echo [INFO] Cache directory: %HF_HUB_CACHE%
echo [INFO] Models:
echo        - microsoft/VibeVoice-ASR
echo        - Qwen/Qwen2.5-7B
echo.

"%VENV_DIR%\Scripts\python.exe" -c "import os; from huggingface_hub import snapshot_download; cache_dir = os.environ['HF_HUB_CACHE']; snapshot_download('microsoft/VibeVoice-ASR', cache_dir=cache_dir); snapshot_download('Qwen/Qwen2.5-7B', cache_dir=cache_dir)"
if errorlevel 1 (
    echo [ERROR] Download failed.
    exit /b 1
)

REM --- Post-process: create preprocessor_config.json in VibeVoice-ASR snapshot ---
REM The upstream microsoft/VibeVoice-ASR repository does not ship preprocessor_config.json.
REM Without it, VibeVoiceASRProcessor.from_pretrained() falls back to defaults and logs two
REM WARNING lines on every startup. We create the file with those same defaults so the
REM processor finds it and loads silently.
echo [INFO] Creating preprocessor_config.json in VibeVoice-ASR snapshot ...
"%VENV_DIR%\Scripts\python.exe" -c "import os, json; from huggingface_hub import snapshot_download; cache_dir = os.environ['HF_HUB_CACHE']; snap = snapshot_download('microsoft/VibeVoice-ASR', cache_dir=cache_dir, local_files_only=True); cfg_path = os.path.join(snap, 'preprocessor_config.json'); cfg = {'processor_class': 'VibeVoiceASRProcessor', 'speech_tok_compress_ratio': 3200, 'target_sample_rate': 24000, 'normalize_audio': True, 'target_dB_FS': -25, 'eps': 1e-6}; json.dump(cfg, open(cfg_path, 'w'), indent=2); print('[INFO] Written:', cfg_path)"
if errorlevel 1 (
    echo [WARN] Could not create preprocessor_config.json. Startup warnings may appear.
)

echo.
echo [OK] VibeVoice-ASR and Qwen/Qwen2.5-7B downloaded to %HF_HUB_CACHE%

endlocal