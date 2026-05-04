@echo off
setlocal

pushd "%~dp0.."
if errorlevel 1 exit /b 1

set "DAEMON_EXE=services\voskdaemon\build\x64\VoskDaemon.exe"
if not exist "%DAEMON_EXE%" (
    echo Executable not found:
    echo   %DAEMON_EXE%
    echo Run scripts\build_voskdaemon.bat first.
    popd
    exit /b 1
)

"%DAEMON_EXE%" --model-name vosk_ru_cmd --host 127.0.0.1 --port 7702
set "RUN_EXIT=%ERRORLEVEL%"

popd
exit /b %RUN_EXIT%