@echo off
REM Build & run echoctl unit tests (config round-trip).
setlocal

set "ROOT_FPC_BIN=%~dp0..\..\EchoRecorder\VendorsCore\fpc\fpc-main\bin\x86_64-win64"
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
"%FPC%" -n @scripts\fpc-x64.cfg tests\test_config.pas
if %ERRORLEVEL% neq 0 (
    echo BUILD FAILED
    popd
    exit /b %ERRORLEVEL%
)

echo.
echo [test] config round-trip
build\x64\test_config.exe "%~dp0..\..\config.json"
set "RUN_EXIT=%ERRORLEVEL%"

popd
if %RUN_EXIT% neq 0 (
    echo TESTS FAILED
    exit /b %RUN_EXIT%
)
echo TESTS OK
endlocal
exit /b 0
