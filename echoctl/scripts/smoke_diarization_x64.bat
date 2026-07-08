@echo off
REM Smoke: diarization engine lifecycle. Error paths always run (fast). The happy path
REM starts a REAL DiarizationDaemon (sherpa + ONNX, ~seconds) and is guarded by prereqs,
REM so it is safe to run anywhere but only fully exercised where the sherpa assets exist.
setlocal

call "%~dp0build_x64.bat"
if errorlevel 1 exit /b 1

pushd "%~dp0.."
set "CLI=build\x64\echoctl.exe"
set "TMP=build\x64\diarization-config.json"
set "SHERPA=..\services\diarizationdaemon\sherpa"

copy /Y "..\config.json" "%TMP%" >nul || goto :fail

echo [diar] unknown engine rejected
"%CLI%" daemons add --engine bogus --model x --config "%TMP%" && goto :fail

echo [diar] start non-existent rejected
"%CLI%" daemons start nope --config "%TMP%" && goto :fail

if not exist "%SHERPA%\build\x64\DiarizationDaemon.exe" (
    echo [diar] SKIP happy-path: DiarizationDaemon.exe not built
    goto :ok
)
if not exist "%SHERPA%\models\segmentation.onnx" (
    echo [diar] SKIP happy-path: sherpa models not present
    goto :ok
)
if not exist "%SHERPA%\vendors\sherpa-onnx\sherpa-onnx.dll" (
    echo [diar] SKIP happy-path: sherpa-onnx.dll not present
    goto :ok
)

echo [diar] add diarization instance (model diarization_sherpa from manifest)
"%CLI%" daemons add --engine diarization --model diarization_sherpa --name diarsmoke --port 7911 --config "%TMP%" || goto :fail

echo [diar] settings round-trip (cluster_threshold)
"%CLI%" daemons edit diarsmoke --set cluster_threshold=0.7 --config "%TMP%" || goto :fail

echo [diar] start (waits real warmup ready)
"%CLI%" daemons start diarsmoke --config "%TMP%" || goto :fail

echo [diar] start again is idempotent (already-running)
"%CLI%" daemons start diarsmoke --config "%TMP%" || goto :fail

echo [diar] stop
"%CLI%" daemons stop diarsmoke --config "%TMP%" || goto :fail

:ok
del /Q "%TMP%" 2>nul
del /Q "%TMP%.tmp" 2>nul
popd
echo DIARIZATION SMOKE OK
endlocal
exit /b 0

:fail
"%CLI%" daemons stop diarsmoke --config "%TMP%" >nul 2>nul
del /Q "%TMP%" 2>nul
del /Q "%TMP%.tmp" 2>nul
popd
echo DIARIZATION SMOKE FAILED
endlocal
exit /b 1
