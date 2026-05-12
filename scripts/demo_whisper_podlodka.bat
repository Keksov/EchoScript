@echo off
setlocal

pushd "%~dp0.."
if errorlevel 1 exit /b 1

where ffmpeg >nul 2>&1
if errorlevel 1 (
    echo ERROR: ffmpeg not found in PATH.
    popd
    exit /b 1
)

set "CLI_EXE=EchoRecorder\cli\build\x64\EchoRecorderCore.exe"
set "FIXTURE="

for %%F in ("EchoRecorder\tests\*_ogg.ogg") do (
    if not defined FIXTURE set "FIXTURE=%%~fF"
)

if not exist "%CLI_EXE%" (
    echo Executable not found:
    echo   %CLI_EXE%
    echo Run EchoRecorder\cli\scripts\build_x64.bat first.
    popd
    exit /b 1
)

if not defined FIXTURE (
    echo Fixture not found: EchoRecorder\tests\*_ogg.ogg
    popd
    exit /b 1
)

pwsh -NoProfile -Command "$items = Get-CimInstance Win32_Process | Where-Object { $_.Name -ieq 'WhisperDaemon.exe' -and $_.CommandLine -match '--model-name whisper_podlodka(\s|$)' }; if (@($items).Count -gt 0) { exit 0 } else { exit 1 }"
if errorlevel 1 (
    call ".\services\whisperdaemon\scripts\start_whisperdaemon_podlodka.bat"
    if errorlevel 1 (
        popd
        exit /b 1
    )
) else (
    pwsh -NoProfile -File ".\services\whisperdaemon\scripts\wait_whisperdaemon_ready.ps1" -ModelName whisper_podlodka
    if errorlevel 1 (
        popd
        exit /b 1
    )
)

ffmpeg -re -hide_banner -loglevel error -i "%FIXTURE%" -f s16le -ar 16000 -ac 1 - | "%CLI_EXE%" --backend daemon --mode dictation --language ru --daemon-host 127.0.0.1 --daemon-port 7801 -f pcm16le -i - --log=plain:stdout
set "RUN_EXIT=%ERRORLEVEL%"

popd
exit /b %RUN_EXIT%