@echo off
REM ============================================================
REM EchoScript — Setup: vibevoicedaemon service
REM Creates venv, installs torch, pip deps, and VibeVoice package.
REM Reuses the VibeVoice vendor clone from the vibevoice service.
REM ============================================================
setlocal enabledelayedexpansion

set "SCRIPT_DIR=%~dp0"
call "%SCRIPT_DIR%..\..\..\scripts\env.bat"
set "SERVICE_DIR=%SCRIPT_DIR%.."
set "VIBEVOICE_VENDOR_DIR=%SCRIPT_DIR%..\..\..\services\vibevoice\vendor\VibeVoice"

call "%SCRIPT_DIR%..\..\..\scripts\_common.bat" detect_gpu
call "%SCRIPT_DIR%..\..\..\scripts\_common.bat" create_venv "%SERVICE_DIR%"
if errorlevel 1 goto :fail
call "%SCRIPT_DIR%..\..\..\scripts\_common.bat" install_requirements "%SERVICE_DIR%"
if errorlevel 1 goto :fail

REM --- Install accelerate, safetensors, transformers (model loading deps) ---
echo [INFO] Installing model loading dependencies ...
"%SERVICE_DIR%\venv\Scripts\pip.exe" install accelerate safetensors transformers huggingface_hub --quiet
if errorlevel 1 (
    echo [ERROR] Failed to install model loading dependencies.
    goto :fail
)

REM --- Install VibeVoice from the shared vendor clone ---
if not exist "%VIBEVOICE_VENDOR_DIR%\.git" (
    echo [ERROR] VibeVoice vendor clone not found: %VIBEVOICE_VENDOR_DIR%
    echo         Run services\vibevoice\scripts\setup_vibevoice.bat first.
    goto :fail
)

echo [INFO] Installing VibeVoice in editable mode from %VIBEVOICE_VENDOR_DIR% ...
"%SERVICE_DIR%\venv\Scripts\pip.exe" install -e "%VIBEVOICE_VENDOR_DIR%" --quiet
if errorlevel 1 (
    echo [ERROR] Failed to install VibeVoice.
    goto :fail
)

REM --- Install flash-attn only if GPU is available ---
if "%HAS_GPU%"=="1" (
    echo [INFO] Installing flash-attn (GPU detected) ...
    "%SERVICE_DIR%\venv\Scripts\pip.exe" install flash-attn --no-build-isolation --quiet
    if errorlevel 1 (
        echo [WARN] flash-attn installation failed. vibevoicedaemon may still work without it.
    )
)

echo.
echo [OK] vibevoicedaemon setup complete.
echo      Activate with: %SERVICE_DIR%\venv\Scripts\activate.bat
goto :done

:fail
echo.
echo [FAIL] vibevoicedaemon setup failed.
exit /b 1

:done
endlocal
