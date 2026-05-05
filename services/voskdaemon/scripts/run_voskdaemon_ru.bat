@echo off
setlocal

pushd "%~dp0\..\..\.."
if errorlevel 1 exit /b 1

set "DAEMON_EXE=services\voskdaemon\build\x64\VoskDaemon.exe"
set "LOG_DIR=services\voskdaemon\logs"
set "STDOUT_LOG=%LOG_DIR%\vosk_ru.stdout.log"
if not exist "%DAEMON_EXE%" (
    echo Executable not found:
    echo   %DAEMON_EXE%
    echo Run services\voskdaemon\scripts\build_voskdaemon.bat first.
    popd
    exit /b 1
)

if not exist "%LOG_DIR%" mkdir "%LOG_DIR%"
if exist "%STDOUT_LOG%" del /q "%STDOUT_LOG%"

powershell -NoProfile -Command "$wd=(Get-Location).Path; $exe=Join-Path $wd 'services\voskdaemon\build\x64\VoskDaemon.exe'; $out=Join-Path $wd 'services\voskdaemon\logs\vosk_ru.stdout.log'; & $exe '--model-name' 'vosk_ru' '--host' '127.0.0.1' '--port' '7701' 2>&1 | ForEach-Object { $_.ToString() } | Tee-Object -FilePath $out; exit $LASTEXITCODE"
set "RUN_EXIT=%ERRORLEVEL%"

popd
exit /b %RUN_EXIT%