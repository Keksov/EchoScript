@echo off
setlocal

pushd "%~dp0.."
if errorlevel 1 exit /b 1

set "SOURCE_MODEL=services\whisperdaemon\spikes\conversion-out\ggml-model.bin"
set "TARGET_DIR=services\whisperdaemon\models"
set "TARGET_MODEL=%TARGET_DIR%\ggml-whisper_podlodka.bin"

if not exist "%SOURCE_MODEL%" (
    echo Converted ggml model not found:
    echo   %SOURCE_MODEL%
    echo Run the whisper podlodka ggml conversion first.
    popd
    exit /b 1
)

if not exist "%TARGET_DIR%" mkdir "%TARGET_DIR%"

copy /y "%SOURCE_MODEL%" "%TARGET_MODEL%" >nul
if errorlevel 1 (
    echo Failed to stage model:
    echo   %TARGET_MODEL%
    popd
    exit /b 1
)

echo Staged whisperdaemon model:
echo   %TARGET_MODEL%

popd
exit /b 0