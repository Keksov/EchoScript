@echo off
REM Smoke: models list + download validation (no real network downloads).
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

echo [models] download non-downloadable (podlodka) rejected
"%CLI%" models download podlodka && goto :fail

echo [models] download external (vosk_ru) rejected
"%CLI%" models download vosk_ru && goto :fail

echo [models] download unknown id rejected
"%CLI%" models download bogus && goto :fail

popd
echo MODELS SMOKE OK
endlocal
exit /b 0

:fail
popd
echo MODELS SMOKE FAILED
endlocal
exit /b 1
