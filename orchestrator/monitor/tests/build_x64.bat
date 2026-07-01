@echo off
REM Build + run monitor-core unit tests (test_monitor_core.pas).
setlocal

set "ROOT_FPC_BIN=%~dp0..\..\..\EchoRecorder\VendorsCore\fpc\fpc-main\bin\x86_64-win64"
set "FPC=%ROOT_FPC_BIN%\fpc.exe"
if defined FPC_EXE_x64 set "FPC=%FPC_EXE_x64%"
if not exist "%FPC%" (
    echo ERROR: FPC compiler not found: %FPC%
    exit /b 1
)

pushd "%~dp0.."
if errorlevel 1 exit /b 1
if not exist build\x64\dcu mkdir build\x64\dcu

echo Using FPC: %FPC%
"%FPC%" -n @scripts\fpc-x64.cfg tests\test_monitor_core.pas
if %ERRORLEVEL% neq 0 (
    echo BUILD FAILED
    popd
    exit /b %ERRORLEVEL%
)

echo.
echo Running test_monitor_core ...
build\x64\test_monitor_core.exe
set "EC=%ERRORLEVEL%"
popd
endlocal
exit /b %EC%
