@echo off
REM Build the monitor CLI (orchestrator/monitor/cli/src/monitor.pas).
setlocal

set "ROOT_FPC_BIN=%~dp0..\..\..\..\EchoRecorder\VendorsCore\fpc\fpc-main\bin\x86_64-win64"
set "FPC=%ROOT_FPC_BIN%\fpc.exe"
if defined FPC_EXE_x64 set "FPC=%FPC_EXE_x64%"
if not exist "%FPC%" (
    echo ERROR: FPC compiler not found: %FPC%
    exit /b 1
)

REM pushd to orchestrator/monitor so the shared fpc-x64.cfg paths resolve.
pushd "%~dp0..\.."
if errorlevel 1 exit /b 1
if not exist build\x64\dcu mkdir build\x64\dcu

echo Using FPC: %FPC%
"%FPC%" -n @scripts\fpc-x64.cfg cli\src\monitor.pas
if %ERRORLEVEL% neq 0 (
    echo BUILD FAILED
    popd
    exit /b %ERRORLEVEL%
)

popd
echo.
echo Build successful: orchestrator\monitor\build\x64\monitor.exe
endlocal
exit /b 0
