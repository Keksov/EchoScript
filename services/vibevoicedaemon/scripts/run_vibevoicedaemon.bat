@echo off
setlocal

pushd "%~dp0\..\..\.."
if errorlevel 1 exit /b 1

REM --- Load local overrides if present ---
if exist "%~dp0.env.bat" call "%~dp0.env.bat"

REM --- Auto-resolve ffmpeg path when FFMPEG_BIN is not explicitly set ---
call "%~dp0..\..\..\scripts\ffmpeg.bat" ensure_ffmpeg_bin
call "%~dp0..\..\..\scripts\ffmpeg.bat" print_ffmpeg_diag

REM --- Apply defaults for any unset variables ---
if not defined VIBEVOICEDAEMON_HOST set "VIBEVOICEDAEMON_HOST=127.0.0.1"
if not defined VIBEVOICEDAEMON_PORT set "VIBEVOICEDAEMON_PORT=7802"

set "SERVICE_DIR=services\vibevoicedaemon"
set "PYTHON_EXE=%SERVICE_DIR%\venv\Scripts\python.exe"
set "LOG_DIR=%SERVICE_DIR%\logs"
set "STDOUT_LOG=%LOG_DIR%\vibevoicedaemon.stdout.log"

if not exist "%PYTHON_EXE%" (
    echo Python executable not found:
    echo   %SERVICE_DIR%\venv\Scripts\python.exe
    echo Run services\vibevoicedaemon\scripts\setup_vibevoicedaemon.bat first.
    popd
    exit /b 1
)

set "PYTHON_EXE_ABS=%CD%\%PYTHON_EXE%"

if not exist "%LOG_DIR%" mkdir "%LOG_DIR%"
if exist "%STDOUT_LOG%" del /q "%STDOUT_LOG%"

powershell -NoProfile -Command "$wd=(Get-Location).Path; $svcDir=Join-Path $wd 'services\vibevoicedaemon'; $python='%PYTHON_EXE_ABS%'; $out=Join-Path $wd 'services\vibevoicedaemon\logs\vibevoicedaemon.stdout.log'; $argList=@('-m','app.main','--host','%VIBEVOICEDAEMON_HOST%','--port','%VIBEVOICEDAEMON_PORT%','--warmup'); Write-Host ('vibevoicedaemon args: ' + ($argList -join ' ')); Push-Location $svcDir; & $python @argList 2>&1 | ForEach-Object { $_.ToString() } | Tee-Object -FilePath $out; $exitCode=$LASTEXITCODE; Pop-Location; exit $exitCode"
set "RUN_EXIT=%ERRORLEVEL%"

popd
exit /b %RUN_EXIT%
