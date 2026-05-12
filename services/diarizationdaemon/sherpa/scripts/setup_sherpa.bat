@echo off
REM ============================================================
REM EchoScript - Setup: DiarizationDaemon sherpa pipeline
REM Runs the full flow with skip checks:
REM   1) VendorsCore repository
REM   2) FPC x64 toolchain
REM   3) sherpa runtime/models download
REM   4) DiarizationDaemon build
REM ============================================================
setlocal EnableExtensions EnableDelayedExpansion

if /I "%~1"=="-h" goto :usage
if /I "%~1"=="--help" goto :usage

set "RUN_EXIT=1"
set "SCRIPT_DIR=%~dp0"

pushd "%SCRIPT_DIR%..\..\..\.."
if errorlevel 1 (
    echo [ERROR] Failed to enter repository root.
    exit /b 1
)

call "scripts\env.bat"

set "ECHORECORDER_VENDORSCORE_DIR=EchoRecorder\VendorsCore"
set "FPC_SETUP_SCRIPT=%ECHORECORDER_VENDORSCORE_DIR%\fpc\scripts\win_x64\fpc_release_setup.bat"
set "FPC_EXE=%ECHORECORDER_VENDORSCORE_DIR%\fpc\fpc-main\bin\x86_64-win64\fpc.exe"
if not defined VENDORSCORE_REPO_URL set "VENDORSCORE_REPO_URL=https://github.com/Keksov/VendorsCore.git"

set "TARGET_RUNTIME_DLL=services\diarizationdaemon\sherpa\vendors\sherpa-onnx\sherpa-onnx.dll"
set "TARGET_ORT_DLL=services\diarizationdaemon\sherpa\vendors\sherpa-onnx\onnxruntime.dll"
set "TARGET_ORT_SHARED_DLL=services\diarizationdaemon\sherpa\vendors\sherpa-onnx\onnxruntime_providers_shared.dll"
set "TARGET_SEG_MODEL=services\diarizationdaemon\sherpa\models\segmentation.onnx"
set "TARGET_EMB_MODEL=services\diarizationdaemon\sherpa\models\embedding.onnx"
set "TARGET_EXE=services\diarizationdaemon\sherpa\build\x64\DiarizationDaemon.exe"

echo [INFO] Checking VendorsCore repository...
call :ensure_vendorscore
set "RUN_EXIT=%ERRORLEVEL%"
if errorlevel 1 goto :fail

echo [INFO] Checking FPC toolchain...
call :ensure_fpc_toolchain
set "RUN_EXIT=%ERRORLEVEL%"
if errorlevel 1 goto :fail

echo [INFO] Checking sherpa assets...
set "ASSETS_READY=1"
call :file_ready "%TARGET_RUNTIME_DLL%"
if errorlevel 1 set "ASSETS_READY=0"
call :file_ready "%TARGET_ORT_DLL%"
if errorlevel 1 set "ASSETS_READY=0"
call :file_ready "%TARGET_ORT_SHARED_DLL%"
if errorlevel 1 set "ASSETS_READY=0"
call :file_ready "%TARGET_SEG_MODEL%"
if errorlevel 1 set "ASSETS_READY=0"
call :file_ready "%TARGET_EMB_MODEL%"
if errorlevel 1 set "ASSETS_READY=0"

if "%ASSETS_READY%"=="1" (
    echo [SKIP] sherpa assets are already present.
) else (
    echo [INFO] Some sherpa assets are missing. Downloading...
    call services\diarizationdaemon\sherpa\scripts\download_sherpa_assets.bat
    set "RUN_EXIT=%ERRORLEVEL%"
    if errorlevel 1 goto :fail
)

echo [INFO] Building DiarizationDaemon...
call services\diarizationdaemon\sherpa\scripts\build_diarizationdaemon.bat
set "RUN_EXIT=%ERRORLEVEL%"
if errorlevel 1 goto :fail

echo [INFO] Validating setup artifacts...
call :file_ready "%TARGET_RUNTIME_DLL%"
if errorlevel 1 (
    echo [ERROR] Missing runtime DLL after setup: %TARGET_RUNTIME_DLL%
    set "RUN_EXIT=1"
    goto :fail
)
call :file_ready "%TARGET_ORT_DLL%"
if errorlevel 1 (
    echo [ERROR] Missing runtime dependency after setup: %TARGET_ORT_DLL%
    set "RUN_EXIT=1"
    goto :fail
)
call :file_ready "%TARGET_ORT_SHARED_DLL%"
if errorlevel 1 (
    echo [ERROR] Missing runtime dependency after setup: %TARGET_ORT_SHARED_DLL%
    set "RUN_EXIT=1"
    goto :fail
)
call :file_ready "%TARGET_SEG_MODEL%"
if errorlevel 1 (
    echo [ERROR] Missing segmentation model after setup: %TARGET_SEG_MODEL%
    set "RUN_EXIT=1"
    goto :fail
)
call :file_ready "%TARGET_EMB_MODEL%"
if errorlevel 1 (
    echo [ERROR] Missing embedding model after setup: %TARGET_EMB_MODEL%
    set "RUN_EXIT=1"
    goto :fail
)
call :file_ready "%TARGET_EXE%"
if errorlevel 1 (
    echo [ERROR] Missing DiarizationDaemon executable after setup: %TARGET_EXE%
    set "RUN_EXIT=1"
    goto :fail
)

echo.
echo [OK] DiarizationDaemon sherpa setup completed.
echo [OK] To run foreground: services\diarizationdaemon\sherpa\scripts\run_diarizationdaemon_sherpa.bat
echo [OK] To run background: services\diarizationdaemon\sherpa\scripts\start_diarizationdaemon_sherpa.bat
set "RUN_EXIT=0"
goto :done

:fail
echo.
echo [FAIL] setup_sherpa failed with exit code %RUN_EXIT%.

:done
popd
exit /b %RUN_EXIT%

:ensure_vendorscore
if exist "%FPC_SETUP_SCRIPT%" (
    echo [SKIP] VendorsCore is already present: %ECHORECORDER_VENDORSCORE_DIR%
    exit /b 0
)

if exist "%ECHORECORDER_VENDORSCORE_DIR%" (
    echo [ERROR] VendorsCore directory exists but required script is missing:
    echo [ERROR]   %FPC_SETUP_SCRIPT%
    echo [ERROR] Resolve this directory and rerun setup.
    exit /b 1
)

where git >nul 2>&1
if errorlevel 1 (
    echo [ERROR] git.exe was not found in PATH.
    echo [ERROR] Install Git or clone %VENDORSCORE_REPO_URL% into %ECHORECORDER_VENDORSCORE_DIR%.
    exit /b 1
)

echo [INFO] VendorsCore repository is missing. Cloning...
git clone "%VENDORSCORE_REPO_URL%" "%ECHORECORDER_VENDORSCORE_DIR%"
if errorlevel 1 (
    echo [ERROR] Failed to clone VendorsCore from %VENDORSCORE_REPO_URL%.
    exit /b 1
)

if not exist "%FPC_SETUP_SCRIPT%" (
    echo [ERROR] VendorsCore clone completed but required script is missing:
    echo [ERROR]   %FPC_SETUP_SCRIPT%
    exit /b 1
)

echo [INFO] VendorsCore repository is ready.
exit /b 0

:ensure_fpc_toolchain
if exist "%FPC_EXE%" (
    echo [SKIP] FPC toolchain is already present.
    exit /b 0
)

if not exist "%FPC_SETUP_SCRIPT%" (
    echo [ERROR] FPC setup script not found: %FPC_SETUP_SCRIPT%
    exit /b 1
)

echo [INFO] FPC toolchain is missing. Provisioning vendor compiler...
call "%FPC_SETUP_SCRIPT%"
if errorlevel 1 (
    echo [ERROR] Failed to provision FPC toolchain.
    echo [ERROR] See EchoRecorder\VendorsCore\fpc\README.md for manual setup options.
    exit /b 1
)

if not exist "%FPC_EXE%" (
    echo [ERROR] FPC provisioning finished but compiler is still missing:
    echo [ERROR]   %FPC_EXE%
    exit /b 1
)

echo [INFO] FPC toolchain is ready.
exit /b 0

:file_ready
if not exist "%~1" exit /b 1
for %%F in ("%~1") do (
    if %%~zF LEQ 0 exit /b 1
)
exit /b 0

:usage
echo Usage:
echo   services\diarizationdaemon\sherpa\scripts\setup_sherpa.bat
echo.
echo Notes:
echo   - The script prepares VendorsCore and FPC toolchain if missing.
echo   - The script downloads sherpa runtime/models when required.
echo   - The script builds DiarizationDaemon executable.
exit /b 0