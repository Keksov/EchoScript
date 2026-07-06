@echo off
REM Smoke: models list against the real manifest + on-disk state.
setlocal

call "%~dp0build_x64.bat"
if errorlevel 1 exit /b 1

pushd "%~dp0.."
set "CLI=build\x64\echoctl.exe"

echo [models] list exits 0
"%CLI%" models list || goto :fail

echo [models] list --json includes whisper entry
"%CLI%" models list --json | findstr /C:"whisper_en_turbo" >nul || goto :fail

echo [models] list --json includes vosk external entry
"%CLI%" models list --json | findstr /C:"vosk_ru" >nul || goto :fail

popd
echo MODELS SMOKE OK
endlocal
exit /b 0

:fail
popd
echo MODELS SMOKE FAILED
endlocal
exit /b 1
