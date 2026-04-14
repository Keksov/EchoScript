@echo off
REM ============================================================
REM EchoScript — Setup: whisper_podlodka service
REM Creates venv, installs torch (GPU/CPU), pip dependencies.
REM ============================================================
setlocal enabledelayedexpansion

set "SCRIPT_DIR=%~dp0"
call "%SCRIPT_DIR%env.bat"
set "SERVICE_DIR=%SCRIPT_DIR%..\services\whisper_podlodka"

call "%SCRIPT_DIR%_common.bat" detect_gpu
call "%SCRIPT_DIR%_common.bat" create_venv "%SERVICE_DIR%"
if errorlevel 1 goto :fail
call "%SCRIPT_DIR%_common.bat" install_requirements "%SERVICE_DIR%"
if errorlevel 1 goto :fail

echo.
echo [OK] whisper_podlodka setup complete.
echo      Activate with: %SERVICE_DIR%\venv\Scripts\activate.bat
goto :done

:fail
echo.
echo [FAIL] whisper_podlodka setup failed.
exit /b 1

:done
endlocal
