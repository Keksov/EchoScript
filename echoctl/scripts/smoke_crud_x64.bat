@echo off
REM Smoke: daemons CRUD against a throwaway copy of config.json.
setlocal

call "%~dp0build_x64.bat"
if errorlevel 1 exit /b 1

pushd "%~dp0.."
set "CLI=build\x64\echoctl.exe"
set "TMP=build\x64\test-config.json"

copy /Y "..\config.json" "%TMP%" >nul || goto :fail

echo [crud] add valid instance
"%CLI%" daemons add --engine whisper --model whisper_en_turbo --port 7899 --lang en --name test_whisper --config "%TMP%" || goto :fail

echo [crud] added instance appears in list
"%CLI%" daemons list --json --config "%TMP%" | findstr /C:"test_whisper" >nul || goto :fail

echo [crud] duplicate name rejected
"%CLI%" daemons add --engine whisper --model whisper_en_turbo --port 7898 --lang en --name test_whisper --config "%TMP%" && goto :fail

echo [crud] port collision rejected
"%CLI%" daemons add --engine whisper --model whisper_en_turbo --port 7899 --lang en --name other --config "%TMP%" && goto :fail

echo [crud] unknown engine rejected
"%CLI%" daemons add --engine bogus --model whisper_en_turbo --port 7897 --config "%TMP%" && goto :fail

echo [crud] unknown model rejected
"%CLI%" daemons add --engine whisper --model nope --port 7897 --config "%TMP%" && goto :fail

echo [crud] bad port rejected
"%CLI%" daemons add --engine whisper --model whisper_en_turbo --port 99999 --config "%TMP%" && goto :fail

echo [crud] missing engine rejected
"%CLI%" daemons add --model whisper_en_turbo --port 7896 --config "%TMP%" && goto :fail

del /Q "%TMP%" 2>nul
del /Q "%TMP%.tmp" 2>nul
popd
echo CRUD SMOKE OK
endlocal
exit /b 0

:fail
del /Q "%TMP%" 2>nul
del /Q "%TMP%.tmp" 2>nul
popd
echo CRUD SMOKE FAILED
endlocal
exit /b 1
