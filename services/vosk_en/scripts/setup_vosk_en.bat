@echo off
REM ============================================================
REM EchoScript — Setup: vosk_en service
REM Creates venv and installs pip dependencies with torch.
REM ============================================================
setlocal enabledelayedexpansion

set "SCRIPT_DIR=%~dp0"
call "%SCRIPT_DIR%..\..\..\scripts\env.bat"
set "SERVICE_DIR=%SCRIPT_DIR%.."

call "%SCRIPT_DIR%..\..\..\scripts\_common.bat" detect_gpu
if errorlevel 1 goto :fail

call "%SCRIPT_DIR%..\..\..\scripts\_common.bat" create_venv "%SERVICE_DIR%"
if errorlevel 1 goto :fail
call "%SCRIPT_DIR%..\..\..\scripts\_common.bat" install_requirements "%SERVICE_DIR%"
if errorlevel 1 goto :fail

echo.
echo [OK] vosk_en setup complete.
echo      Activate with: %SERVICE_DIR%\venv\Scripts\activate.bat
goto :done

:fail
echo.
echo [FAIL] vosk_en setup failed.
exit /b 1

:done
endlocal