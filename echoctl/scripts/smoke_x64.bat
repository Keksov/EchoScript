@echo off
REM Smoke: build echoctl, then exercise the skeleton dispatcher contract.
setlocal

call "%~dp0build_x64.bat"
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%

pushd "%~dp0.."
set "CLI_EXE=build\x64\echoctl.exe"

echo [smoke] echoctl version
"%CLI_EXE%" version
if %ERRORLEVEL% neq 0 (
    echo SMOKE FAILED: version
    popd
    exit /b 1
)

echo [smoke] echoctl help
"%CLI_EXE%" help
if %ERRORLEVEL% neq 0 (
    echo SMOKE FAILED: help
    popd
    exit /b 1
)

echo [smoke] echoctl (no args) prints usage, exit 0
"%CLI_EXE%"
if %ERRORLEVEL% neq 0 (
    echo SMOKE FAILED: no-args should exit 0
    popd
    exit /b 1
)

echo [smoke] unknown group exits non-zero
"%CLI_EXE%" bogus
if %ERRORLEVEL% equ 0 (
    echo SMOKE FAILED: unknown group should exit non-zero
    popd
    exit /b 1
)

echo [smoke] recognized-but-stub command exits 3 (not implemented)
"%CLI_EXE%" daemons list
if %ERRORLEVEL% neq 3 (
    echo SMOKE FAILED: stub should exit 3
    popd
    exit /b 1
)

popd
echo SMOKE OK
endlocal
exit /b 0
