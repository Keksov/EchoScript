@echo off
REM ============================================================
REM EchoScript — Setup: Russian speech stack
REM Manual bootstrap for orchestrator + dictation + command services.
REM ============================================================
setlocal

set "SCRIPT_DIR=%~dp0"
call "%SCRIPT_DIR%env.bat"

echo --- [1/3] Orchestrator ---
call "%SCRIPT_DIR%..\orchestrator\scripts\setup_orchestrator.bat"
if errorlevel 1 goto :fail

echo.
echo --- [2/3] Vosk RU dictation backend ---
call "%SCRIPT_DIR%..\services\vosk_ru\scripts\setup_vosk_ru.bat"
if errorlevel 1 goto :fail

echo.
echo --- [3/3] Vosk RU command backend ---
call "%SCRIPT_DIR%..\services\vosk_ru_cmd\scripts\setup_vosk_ru_cmd.bat"
if errorlevel 1 goto :fail

echo.
echo [OK] Russian speech setup complete.
echo      Next step: run scripts\download_speech_ru.bat
goto :done

:fail
echo.
echo [FAIL] Russian speech setup failed.
exit /b 1

:done
endlocal