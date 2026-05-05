@echo off
REM ============================================================
REM EchoScript — Setup: vosk_ru_cmd service
REM Creates venv and installs command-mode Vosk dependencies.
REM ============================================================
setlocal enabledelayedexpansion

set "SCRIPT_DIR=%~dp0"
call "%SCRIPT_DIR%..\..\..\scripts\env.bat"
set "SERVICE_DIR=%SCRIPT_DIR%.."
set "SKIP_TORCH=1"

call "%SCRIPT_DIR%..\..\..\scripts\_common.bat" create_venv "%SERVICE_DIR%"
if errorlevel 1 goto :fail
call "%SCRIPT_DIR%..\..\..\scripts\_common.bat" install_requirements "%SERVICE_DIR%"
if errorlevel 1 goto :fail

echo.
echo [OK] vosk_ru_cmd setup complete.
echo      Activate with: %SERVICE_DIR%\venv\Scripts\activate.bat
goto :done

:fail
echo.
echo [FAIL] vosk_ru_cmd setup failed.
exit /b 1

:done
endlocal