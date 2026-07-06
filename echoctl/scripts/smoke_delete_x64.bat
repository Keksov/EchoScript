@echo off
REM Smoke: models delete (refuse / dry-run / --force cascade) on a FAKE model,
REM so real model files are never touched.
setlocal

call "%~dp0build_x64.bat"
if errorlevel 1 exit /b 1

pushd "%~dp0.."
set "CLI=build\x64\echoctl.exe"
set "MAN=tests\fixtures\delete-manifest.json"
set "CFG=build\x64\delete-config.json"
set "FAKE=build\x64\fake-model.bin"

echo fake-model-bytes> "%FAKE%"
copy /Y "tests\fixtures\delete-config.json" "%CFG%" >nul || goto :fail
if not exist "%FAKE%" goto :fail

echo [delete] refuse when referenced (no --force)
"%CLI%" models delete faketest --manifest "%MAN%" --config "%CFG%" && goto :fail
if not exist "%FAKE%" goto :fail

echo [delete] dry-run --force previews, deletes nothing
"%CLI%" models delete faketest --dry-run --force --manifest "%MAN%" --config "%CFG%" || goto :fail
if not exist "%FAKE%" goto :fail

echo [delete] --force deletes file and cascades instance
"%CLI%" models delete faketest --force --manifest "%MAN%" --config "%CFG%" || goto :fail
if exist "%FAKE%" goto :fail
findstr /C:"fake_inst" "%CFG%" >nul && goto :fail

echo [delete] unknown id rejected
"%CLI%" models delete bogus --manifest "%MAN%" --config "%CFG%" && goto :fail

del /Q "%FAKE%" 2>nul
del /Q "%CFG%" 2>nul
del /Q "%CFG%.tmp" 2>nul
popd
echo DELETE SMOKE OK
endlocal
exit /b 0

:fail
del /Q "%FAKE%" 2>nul
del /Q "%CFG%" 2>nul
del /Q "%CFG%.tmp" 2>nul
popd
echo DELETE SMOKE FAILED
endlocal
exit /b 1
