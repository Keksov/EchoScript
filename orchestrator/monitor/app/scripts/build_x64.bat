@echo off
REM Build the Daemon Monitor GUI (Lazarus + Pixie) via lazbuild.
setlocal

if not defined LAZARUS_DIR set "LAZARUS_DIR=c:\bin\lazarus\4.6"
set "LAZBUILD=%LAZARUS_DIR%\lazbuild.exe"
if not exist "%LAZBUILD%" (
    echo ERROR: lazbuild not found: %LAZBUILD%
    echo Set LAZARUS_DIR to your Lazarus 4.6 install.
    exit /b 1
)

pushd "%~dp0.."
if errorlevel 1 exit /b 1

echo Using lazbuild: %LAZBUILD%
"%LAZBUILD%" MonitorApp.lpi
set "EC=%ERRORLEVEL%"
popd

if %EC% neq 0 (
    echo BUILD FAILED
    endlocal & exit /b 1
)
echo.
echo Build successful: orchestrator\monitor\app\build\x64\MonitorApp.exe
endlocal & exit /b 0
