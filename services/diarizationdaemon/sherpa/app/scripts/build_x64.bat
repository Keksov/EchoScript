@echo off
setlocal

set "ROOT_FPC_HOME=%~dp0..\..\..\..\..\EchoRecorder\VendorsCore\fpc\fpc-main"
set "ROOT_FPC_BIN=%ROOT_FPC_HOME%\bin\x86_64-win64"
set "ROOT_FPC_UNITS=%ROOT_FPC_HOME%\units\x86_64-win64"
set "CFG_FILE=%~dp0fpc-x64.cfg"

set "FPC=%ROOT_FPC_BIN%\fpc.exe"
if defined FPC_EXE_x64 (
    set "FPC=%FPC_EXE_x64%"
)
if not exist "%FPC%" (
    echo ERROR: FPC compiler not found.
    echo   Expected: %FPC%
    exit /b 1
)

if not exist "%CFG_FILE%" (
    echo ERROR: FPC config not found.
    echo   Expected: %CFG_FILE%
    exit /b 1
)

if not exist "%ROOT_FPC_BIN%\ppcx64.exe" (
    echo ERROR: FPC backend not found: %ROOT_FPC_BIN%\ppcx64.exe
    exit /b 1
)

if not exist "%ROOT_FPC_UNITS%\rtl\system.ppu" (
    echo ERROR: FPC RTL units not found: %ROOT_FPC_UNITS%\rtl\system.ppu
    exit /b 1
)

set "PATH=%ROOT_FPC_BIN%;%PATH%"

pushd "%~dp0..\.."
if errorlevel 1 exit /b 1

if not exist build\x64\dcu mkdir build\x64\dcu

echo Using FPC: %FPC%
"%FPC%" -n @app\scripts\fpc-x64.cfg app\src\DiarizationDaemon.pas
if %ERRORLEVEL% neq 0 (
    echo BUILD FAILED
    popd
    exit /b %ERRORLEVEL%
)

popd
echo.
echo Build successful: services\diarizationdaemon\sherpa\build\x64\DiarizationDaemon.exe
