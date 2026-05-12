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
set "STDERR_LOG=%LOG_DIR%\vibevoicedaemon.stderr.log"

if not exist "%PYTHON_EXE%" (
    echo Python executable not found:
    echo   %SERVICE_DIR%\venv\Scripts\python.exe
    echo Run services\vibevoicedaemon\scripts\setup_vibevoicedaemon.bat first.
    popd
    exit /b 1
)

set "PYTHON_EXE_ABS=%CD%\%PYTHON_EXE%"

pwsh -NoProfile -Command "$port='%VIBEVOICEDAEMON_PORT%'; $items = Get-CimInstance Win32_Process | Where-Object { $_.Name -ieq 'python.exe' -and $_.CommandLine -match ('app\.main.*--port\s+' + $port) }; if (@($items).Count -gt 0) { Write-Host 'vibevoicedaemon is already running.'; exit 1 }"
if errorlevel 1 (
    popd
    exit /b 1
)

if not exist "%LOG_DIR%" mkdir "%LOG_DIR%"
if exist "%STDOUT_LOG%" del /q "%STDOUT_LOG%"
if exist "%STDERR_LOG%" del /q "%STDERR_LOG%"

pwsh -NoProfile -Command "$wd=(Get-Location).Path; $python='%PYTHON_EXE_ABS%'; $svcDir=Join-Path $wd 'services\vibevoicedaemon'; $out=Join-Path $wd 'services\vibevoicedaemon\logs\vibevoicedaemon.stdout.log'; $err=Join-Path $wd 'services\vibevoicedaemon\logs\vibevoicedaemon.stderr.log'; $argList=@('-m','app.main','--host','%VIBEVOICEDAEMON_HOST%','--port','%VIBEVOICEDAEMON_PORT%','--warmup'); $proc=Start-Process -FilePath $python -ArgumentList $argList -WorkingDirectory $svcDir -WindowStyle Minimized -RedirectStandardOutput $out -RedirectStandardError $err -PassThru; if ($proc.WaitForExit(1500)) { Write-Host ('vibevoicedaemon exited with code ' + $proc.ExitCode); if (Test-Path $err) { Get-Content -Path $err | ForEach-Object { Write-Host $_ } }; exit $proc.ExitCode }; Write-Host ('Started vibevoicedaemon PID ' + $proc.Id); Write-Host ('stdout: ' + $out); Write-Host ('stderr: ' + $err)"
set "RUN_EXIT=%ERRORLEVEL%"
if %RUN_EXIT% neq 0 (
    popd
    exit /b %RUN_EXIT%
)

pwsh -NoProfile -File "%~dp0wait_vibevoicedaemon_ready.ps1"
set "RUN_EXIT=%ERRORLEVEL%"

popd
exit /b %RUN_EXIT%
