@echo off
REM Build + run monitor-core unit tests.
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

call :build_run test_monitor_core || goto :fail
call :build_run test_monitor_status || goto :fail

popd
endlocal
echo.
echo All monitor-core tests passed.
exit /b 0

:build_run
echo.
echo === building %1 ===
"%FPC%" -n @scripts\fpc-x64.cfg tests\%1.pas
if errorlevel 1 (
    echo BUILD FAILED: %1
    exit /b 1
)
echo === running %1 ===
build\x64\%1.exe
if errorlevel 1 (
    echo TEST FAILED: %1
    exit /b 1
)
exit /b 0

:fail
popd
endlocal
exit /b 1
