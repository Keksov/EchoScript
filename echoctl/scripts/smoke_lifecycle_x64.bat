@echo off
REM Smoke: daemons lifecycle. Error paths always run (fast). The happy path starts a
REM REAL vosk daemon (small model, ~15s warmup) and is guarded by prereqs, so this is
REM safe to run anywhere but only fully exercised where vosk is present.
setlocal

call "%~dp0build_x64.bat"
if errorlevel 1 exit /b 1

pushd "%~dp0.."
set "CLI=build\x64\echoctl.exe"
set "TMP=build\x64\lifecycle-config.json"

copy /Y "..\config.json" "%TMP%" >nul || goto :fail

echo [life] start non-existent rejected
"%CLI%" daemons start nope --config "%TMP%" && goto :fail

echo [life] stop non-existent rejected
"%CLI%" daemons stop nope --config "%TMP%" && goto :fail

if not exist "build\x64\..\..\..\services\voskdaemon\build\x64\VoskDaemon.exe" (
    echo [life] SKIP happy-path: VoskDaemon.exe not built
    goto :ok
)
if not exist "C:\var\vosk\vosk-model-small-ru-0.22" (
    echo [life] SKIP happy-path: vosk small model not present
    goto :ok
)

echo [life] add vosk instance
"%CLI%" daemons add --engine vosk --model vosk_ru_cmd --lang ru --name lifevosk --port 7785 --config "%TMP%" || goto :fail

echo [life] start (waits real warmup)
"%CLI%" daemons start lifevosk --config "%TMP%" || goto :fail

echo [life] start again is idempotent (already-running)
"%CLI%" daemons start lifevosk --config "%TMP%" || goto :fail

echo [life] stop
"%CLI%" daemons stop lifevosk --config "%TMP%" || goto :fail

:ok
del /Q "%TMP%" 2>nul
del /Q "%TMP%.tmp" 2>nul
popd
echo LIFECYCLE SMOKE OK
endlocal
exit /b 0

:fail
"%CLI%" daemons stop lifevosk --config "%TMP%" >nul 2>nul
del /Q "%TMP%" 2>nul
del /Q "%TMP%.tmp" 2>nul
popd
echo LIFECYCLE SMOKE FAILED
endlocal
exit /b 1
