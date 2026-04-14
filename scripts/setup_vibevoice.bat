@echo off
REM ============================================================
REM EchoScript — Setup: vibevoice service
REM Creates venv, installs torch, pip deps, clones VibeVoice repo.
REM ============================================================
setlocal enabledelayedexpansion

set "SCRIPT_DIR=%~dp0"
call "%SCRIPT_DIR%env.bat"
set "SERVICE_DIR=%SCRIPT_DIR%..\services\vibevoice"

call "%SCRIPT_DIR%_common.bat" detect_gpu
call "%SCRIPT_DIR%_common.bat" create_venv "%SERVICE_DIR%"
if errorlevel 1 goto :fail
call "%SCRIPT_DIR%_common.bat" install_requirements "%SERVICE_DIR%"
if errorlevel 1 goto :fail

REM --- Clone VibeVoice repo into vendor/ ---
set "VENDOR_DIR=%SERVICE_DIR%\vendor\VibeVoice"
if not exist "%VENDOR_DIR%\.git" (
    echo [INFO] Cloning VibeVoice repository ...
    git clone https://github.com/microsoft/VibeVoice.git "%VENDOR_DIR%"
    if errorlevel 1 (
        echo [ERROR] Failed to clone VibeVoice.
        goto :fail
    )
) else (
    echo [INFO] VibeVoice already cloned: %VENDOR_DIR%
)

echo [INFO] Installing VibeVoice in editable mode ...
"%SERVICE_DIR%\venv\Scripts\pip.exe" install -e "%VENDOR_DIR%" --quiet
if errorlevel 1 (
    echo [ERROR] Failed to install VibeVoice.
    goto :fail
)

REM --- Install flash-attn only if GPU is available ---
if "%HAS_GPU%"=="1" (
    echo [INFO] Installing flash-attn (GPU detected) ...
    "%SERVICE_DIR%\venv\Scripts\pip.exe" install flash-attn --no-build-isolation --quiet
    if errorlevel 1 (
        echo [WARN] flash-attn installation failed. VibeVoice may still work without it.
    )
)

echo.
echo [OK] vibevoice setup complete.
echo      Activate with: %SERVICE_DIR%\venv\Scripts\activate.bat
goto :done

:fail
echo.
echo [FAIL] vibevoice setup failed.
exit /b 1

:done
endlocal
