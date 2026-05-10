@echo off
REM ============================================================
REM EchoScript — Setup: vibevoicedaemon service
REM Creates venv, installs torch, pip deps, and VibeVoice package.
REM ============================================================
setlocal enabledelayedexpansion

set "SCRIPT_DIR=%~dp0"
call "%SCRIPT_DIR%..\..\..\scripts\env.bat"
set "SERVICE_DIR=%SCRIPT_DIR%.."
set "VIBEVOICE_VENDOR_DIR=%SERVICE_DIR%\vendor\VibeVoice"
set "ECHOSCRIPT_SETUP_DIAG=1"

echo [DIAG] setup_vibevoicedaemon SCRIPT_DIR=%SCRIPT_DIR%
echo [DIAG] setup_vibevoicedaemon SERVICE_DIR=%SERVICE_DIR%
echo [DIAG] setup_vibevoicedaemon VIBEVOICE_VENDOR_DIR=%VIBEVOICE_VENDOR_DIR%

echo [DIAG] Calling detect_gpu ...
call "%SCRIPT_DIR%..\..\..\scripts\_common.bat" detect_gpu
echo [DIAG] Calling create_venv ...
call "%SCRIPT_DIR%..\..\..\scripts\_common.bat" create_venv "%SERVICE_DIR%"
if errorlevel 1 goto :fail
echo [DIAG] Calling install_requirements ...
call "%SCRIPT_DIR%..\..\..\scripts\_common.bat" install_requirements "%SERVICE_DIR%"
if errorlevel 1 goto :fail

REM --- Clone VibeVoice repo into vendor/ ---
if not exist "%VIBEVOICE_VENDOR_DIR%\.git" (
    if not exist "%SERVICE_DIR%\vendor" mkdir "%SERVICE_DIR%\vendor"
    if errorlevel 1 (
        echo [ERROR] Failed to create vendor directory.
        goto :fail
    )

    echo [INFO] Cloning VibeVoice repository into %VIBEVOICE_VENDOR_DIR% ...
    git clone https://github.com/microsoft/VibeVoice.git "%VIBEVOICE_VENDOR_DIR%"
    if errorlevel 1 (
        echo [ERROR] Failed to clone VibeVoice into local daemon vendor.
        goto :fail
    )
) else (
    echo [INFO] VibeVoice already cloned: %VIBEVOICE_VENDOR_DIR%
)

echo [INFO] Installing VibeVoice in editable mode from %VIBEVOICE_VENDOR_DIR% (without upstream deps) ...
if /I "%ECHOSCRIPT_SETUP_DIAG%"=="1" echo [DIAG] Running: "%SERVICE_DIR%\venv\Scripts\pip.exe" install -e "%VIBEVOICE_VENDOR_DIR%" --no-deps --quiet
"%SERVICE_DIR%\venv\Scripts\pip.exe" install -e "%VIBEVOICE_VENDOR_DIR%" --no-deps --quiet
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
