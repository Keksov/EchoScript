@echo off
REM Smoke: build echotail, then exercise the arg contract.
setlocal

call "%~dp0build_x64.bat"
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%

pushd "%~dp0.."
set "EXE=build\x64\echotail.exe"

echo [smoke] echotail --version
"%EXE%" --version
if %ERRORLEVEL% neq 0 (
    echo SMOKE FAILED: version
    popd
    exit /b 1
)

echo [smoke] echotail --help
"%EXE%" --help
if %ERRORLEVEL% neq 0 (
    echo SMOKE FAILED: help
    popd
    exit /b 1
)

echo [smoke] echotail (no args) prints usage, exit 0
"%EXE%"
if %ERRORLEVEL% neq 0 (
    echo SMOKE FAILED: no-args should exit 0
    popd
    exit /b 1
)

echo [smoke] missing logpath via flags-only exits 2
"%EXE%" --tail 10
if %ERRORLEVEL% neq 2 (
    echo SMOKE FAILED: missing logpath should exit 2
    popd
    exit /b 1
)

popd
echo SMOKE OK
endlocal
exit /b 0
