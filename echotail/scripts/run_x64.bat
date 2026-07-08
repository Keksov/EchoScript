@echo off
setlocal

pushd "%~dp0.."
if errorlevel 1 exit /b 1

set "EXE=build\x64\echotail.exe"
if not exist "%EXE%" (
    echo Executable not found: %EXE%
    echo Run echotail\scripts\build_x64.bat first.
    popd
    exit /b 1
)

"%EXE%" %*
set "RUN_EXIT=%ERRORLEVEL%"

popd
exit /b %RUN_EXIT%
