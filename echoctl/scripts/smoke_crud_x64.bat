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

echo [crud] add honors --set (settings persisted at create)
"%CLI%" daemons add --engine whisper --model whisper_en_turbo --port 7896 --name set_w --set vad=false --set gpu_device=1 --config "%TMP%" || goto :fail
"%CLI%" daemons list --json --config "%TMP%" | findstr /C:"gpu_device" >nul || goto :fail

echo [crud] add with unknown setting rejected (nothing created)
"%CLI%" daemons add --engine whisper --model whisper_en_turbo --port 7895 --name bad_set --set bogus=1 --config "%TMP%" && goto :fail
"%CLI%" daemons list --json --config "%TMP%" | findstr /C:"bad_set" >nul && goto :fail

echo [crud] add with out-of-range setting rejected (nothing created)
"%CLI%" daemons add --engine whisper --model whisper_en_turbo --port 7895 --name bad_rng --set vad_threshold=2 --config "%TMP%" && goto :fail
"%CLI%" daemons list --json --config "%TMP%" | findstr /C:"bad_rng" >nul && goto :fail

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

echo [crud] edit set settings
"%CLI%" daemons edit test_whisper --set vad_threshold=0.4 --set gpu=true --config "%TMP%" || goto :fail

echo [crud] settings appear in list
"%CLI%" daemons list --json --config "%TMP%" | findstr /C:"vad_threshold" >nul || goto :fail

echo [crud] edit change port
"%CLI%" daemons edit test_whisper --port 7888 --config "%TMP%" || goto :fail

echo [crud] edit unknown setting rejected
"%CLI%" daemons edit test_whisper --set bogus=1 --config "%TMP%" && goto :fail

echo [crud] edit out-of-range value rejected
"%CLI%" daemons edit test_whisper --set vad_threshold=2 --config "%TMP%" && goto :fail

echo [crud] edit port collision rejected
"%CLI%" daemons edit test_whisper --port 7801 --config "%TMP%" && goto :fail

echo [crud] edit non-existent rejected
"%CLI%" daemons edit nope --set gpu=true --config "%TMP%" && goto :fail

echo [crud] add whisper without port auto-allocates 7803
"%CLI%" daemons add --engine whisper --model whisper_en_turbo --lang en --name auto_w --config "%TMP%" || goto :fail
"%CLI%" daemons list --json --config "%TMP%" | findstr /C:"7803" >nul || goto :fail

echo [crud] add vosk without port auto-allocates 7701
"%CLI%" daemons add --engine vosk --model vosk_ru --lang ru --name auto_v --config "%TMP%" || goto :fail
"%CLI%" daemons list --json --config "%TMP%" | findstr /C:"7701" >nul || goto :fail

echo [crud] remove instance
"%CLI%" daemons remove test_whisper --config "%TMP%" || goto :fail

echo [crud] removed instance is gone
"%CLI%" daemons list --json --config "%TMP%" | findstr /C:"test_whisper" >nul && goto :fail

echo [crud] remove non-existent rejected
"%CLI%" daemons remove nope --config "%TMP%" && goto :fail

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
