@echo off
REM ============================================================
REM EchoScript — Setup: gemma4 service
REM Creates venv, installs torch (GPU/CPU), pip dependencies.
REM ============================================================
setlocal enabledelayedexpansion

set "SCRIPT_DIR=%~dp0"
set "SERVICE_DIR=%SCRIPT_DIR%..\services\gemma4"

call "%SCRIPT_DIR%_common.bat" detect_gpu
call "%SCRIPT_DIR%_common.bat" create_venv "%SERVICE_DIR%"
if errorlevel 1 goto :fail
call "%SCRIPT_DIR%_common.bat" install_requirements "%SERVICE_DIR%"
if errorlevel 1 goto :fail

echo.
echo [OK] gemma4 setup complete.
echo      Activate with: %SERVICE_DIR%\venv\Scripts\activate.bat
goto :done

:fail
echo.
echo [FAIL] gemma4 setup failed.
exit /b 1

:done
endlocal
