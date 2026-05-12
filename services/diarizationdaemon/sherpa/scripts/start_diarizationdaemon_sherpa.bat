@echo off
setlocal

pushd "%~dp0\..\..\..\.."
if errorlevel 1 exit /b 1

set "LOCAL_ENV_SCRIPT=services\diarizationdaemon\sherpa\scripts\.env.bat"
if exist "%LOCAL_ENV_SCRIPT%" (
    echo [INFO] Loading local diarizationdaemon overrides: %LOCAL_ENV_SCRIPT%
    call "%LOCAL_ENV_SCRIPT%"
    if errorlevel 1 (
        echo [ERROR] Failed to load local config: %LOCAL_ENV_SCRIPT%
        popd
        exit /b 1
    )
)

if not defined DIARIZATION_DAEMON_HOST set "DIARIZATION_DAEMON_HOST=127.0.0.1"
if not defined DIARIZATION_DAEMON_PORT set "DIARIZATION_DAEMON_PORT=7900"

set "DAEMON_DIR=services\diarizationdaemon\sherpa\build\x64"
set "DAEMON_EXE=services\diarizationdaemon\sherpa\build\x64\DiarizationDaemon.exe"
set "LOG_DIR=services\diarizationdaemon\sherpa\logs"
set "STDOUT_LOG=%LOG_DIR%\diarizationdaemon.stdout.log"
set "STDERR_LOG=%LOG_DIR%\diarizationdaemon.stderr.log"
set "DEFAULT_SHERPA_DLL=services\diarizationdaemon\sherpa\vendors\sherpa-onnx\sherpa-onnx.dll"
set "DEFAULT_ORT_DLL=services\diarizationdaemon\sherpa\vendors\sherpa-onnx\onnxruntime.dll"
set "DEFAULT_ORT_SHARED_DLL=services\diarizationdaemon\sherpa\vendors\sherpa-onnx\onnxruntime_providers_shared.dll"
set "STAGED_ORT_DLL=%DAEMON_DIR%\onnxruntime.dll"
set "STAGED_ORT_SHARED_DLL=%DAEMON_DIR%\onnxruntime_providers_shared.dll"

if not exist "%DAEMON_EXE%" (
    echo Executable not found:
    echo   %DAEMON_EXE%
    echo Run services\diarizationdaemon\sherpa\scripts\build_diarizationdaemon.bat first.
    popd
    exit /b 1
)

if not defined SHERPA_DLL_PATH set "SHERPA_DLL_PATH=%DEFAULT_SHERPA_DLL%"

if not exist "%SHERPA_DLL_PATH%" (
    echo Required sherpa runtime not found:
    echo   %SHERPA_DLL_PATH%
    popd
    exit /b 1
)

if not exist "%DEFAULT_ORT_DLL%" (
    echo Required ONNX Runtime DLL not found:
    echo   %DEFAULT_ORT_DLL%
    popd
    exit /b 1
)

if not exist "%DEFAULT_ORT_SHARED_DLL%" (
    echo Required ONNX Runtime provider DLL not found:
    echo   %DEFAULT_ORT_SHARED_DLL%
    popd
    exit /b 1
)

copy /y "%DEFAULT_ORT_DLL%" "%STAGED_ORT_DLL%" >nul
if errorlevel 1 (
    echo Failed to stage ONNX Runtime DLL:
    echo   %STAGED_ORT_DLL%
    popd
    exit /b 1
)

copy /y "%DEFAULT_ORT_SHARED_DLL%" "%STAGED_ORT_SHARED_DLL%" >nul
if errorlevel 1 (
    echo Failed to stage ONNX Runtime provider DLL:
    echo   %STAGED_ORT_SHARED_DLL%
    popd
    exit /b 1
)

pwsh -NoProfile -Command "$items = Get-CimInstance Win32_Process | Where-Object { $_.Name -ieq 'DiarizationDaemon.exe' }; if (@($items).Count -gt 0) { Write-Host 'DiarizationDaemon is already running.'; exit 1 }"
if errorlevel 1 (
    popd
    exit /b 1
)

if not exist "%LOG_DIR%" mkdir "%LOG_DIR%"
if exist "%STDOUT_LOG%" del /q "%STDOUT_LOG%"
if exist "%STDERR_LOG%" del /q "%STDERR_LOG%"

pwsh -NoProfile -Command "$wd=(Get-Location).Path; $exe=Join-Path $wd 'services\diarizationdaemon\sherpa\build\x64\DiarizationDaemon.exe'; $out=Join-Path $wd 'services\diarizationdaemon\sherpa\logs\diarizationdaemon.stdout.log'; $err=Join-Path $wd 'services\diarizationdaemon\sherpa\logs\diarizationdaemon.stderr.log'; $args = @('--host','127.0.0.1','--port','7900','--sherpa-dll',$env:SHERPA_DLL_PATH); $proc = Start-Process -FilePath $exe -ArgumentList $args -WorkingDirectory $wd -WindowStyle Minimized -RedirectStandardOutput $out -RedirectStandardError $err -PassThru; if ($proc.WaitForExit(1500)) { Write-Host ('DiarizationDaemon exited with code ' + $proc.ExitCode); if (Test-Path $err) { Get-Content -Path $err | ForEach-Object { Write-Host $_ } }; exit $proc.ExitCode }; Write-Host ('Started DiarizationDaemon PID ' + $proc.Id); Write-Host ('stdout: ' + $out); Write-Host ('stderr: ' + $err)"
set "RUN_EXIT=%ERRORLEVEL%"
if %RUN_EXIT% neq 0 (
    popd
    exit /b %RUN_EXIT%
)

pwsh -NoProfile -File "%~dp0wait_diarizationdaemon_ready.ps1"
set "RUN_EXIT=%ERRORLEVEL%"

popd
exit /b %RUN_EXIT%
