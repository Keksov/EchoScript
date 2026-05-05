@echo off
REM ============================================================
REM EchoScript — Download: Russian speech assets
REM Manual bootstrap for command + dictation model assets.
REM ============================================================
setlocal

set "SCRIPT_DIR=%~dp0"
call "%SCRIPT_DIR%env.bat"

echo --- [1/2] Vosk RU command backend assets ---
call "%SCRIPT_DIR%..\services\vosk_ru_cmd\scripts\download_vosk_ru_cmd.bat"
if errorlevel 1 goto :fail

echo.
echo --- [2/2] Vosk RU dictation backend assets ---
call "%SCRIPT_DIR%..\services\vosk_ru\scripts\download_vosk_ru.bat"
if errorlevel 1 goto :fail

echo.
echo [OK] Russian speech assets downloaded.
goto :done

:fail
echo.
echo [FAIL] Russian speech asset download failed.
exit /b 1

:done
endlocal