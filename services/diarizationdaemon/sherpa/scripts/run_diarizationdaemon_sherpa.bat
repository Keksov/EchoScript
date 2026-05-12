@echo off
setlocal

pushd "%~dp0\..\..\..\.."
if errorlevel 1 exit /b 1

set "DAEMON_DIR=services\diarizationdaemon\sherpa\build\x64"
set "DAEMON_EXE=services\diarizationdaemon\sherpa\build\x64\DiarizationDaemon.exe"
set "LOG_DIR=services\diarizationdaemon\sherpa\logs"
set "STDOUT_LOG=%LOG_DIR%\diarizationdaemon.stdout.log"
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

if not exist "%LOG_DIR%" mkdir "%LOG_DIR%"
if exist "%STDOUT_LOG%" del /q "%STDOUT_LOG%"

pwsh -NoProfile -Command "$wd=(Get-Location).Path; $exe=Join-Path $wd 'services\diarizationdaemon\sherpa\build\x64\DiarizationDaemon.exe'; $out=Join-Path $wd 'services\diarizationdaemon\sherpa\logs\diarizationdaemon.stdout.log'; $args = @('--host','127.0.0.1','--port','7900','--sherpa-dll',$env:SHERPA_DLL_PATH); & $exe @args 2>&1 | ForEach-Object { $_.ToString() } | Tee-Object -FilePath $out; exit $LASTEXITCODE"
set "RUN_EXIT=%ERRORLEVEL%"

popd
exit /b %RUN_EXIT%
