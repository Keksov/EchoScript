@echo off
setlocal

for %%I in ("%~dp0.") do set "SERVICE_DIR=%%~fI"
for %%I in ("%SERVICE_DIR%\..\..") do set "PROJECT_ROOT=%%~fI"

if exist "%PROJECT_ROOT%\scripts\env.bat" call "%PROJECT_ROOT%\scripts\env.bat"

set "PYTHON_EXE=%SERVICE_DIR%\venv\Scripts\python.exe"
if not defined ECHOSCRIPT_JOBS_ROOT set "ECHOSCRIPT_JOBS_ROOT=%PROJECT_ROOT%\jobs"
if not defined ECHOSCRIPT_MODEL_NAME set "ECHOSCRIPT_MODEL_NAME=vosk_en"
if not defined ECHOSCRIPT_POLL_INTERVAL_MS set "ECHOSCRIPT_POLL_INTERVAL_MS=500"

if not exist "%PYTHON_EXE%" (
    echo Python executable not found: "%PYTHON_EXE%"
    exit /b 1
)

pushd "%SERVICE_DIR%"
"%PYTHON_EXE%" -m app.main --jobs-root "%ECHOSCRIPT_JOBS_ROOT%" --project-root "%PROJECT_ROOT%" --model-name "%ECHOSCRIPT_MODEL_NAME%" --poll-interval-ms "%ECHOSCRIPT_POLL_INTERVAL_MS%" %*
set "EXIT_CODE=%ERRORLEVEL%"
popd

exit /b %EXIT_CODE%
