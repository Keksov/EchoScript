@echo off
setlocal

pushd "%~dp0\..\..\.."
if errorlevel 1 exit /b 1

call services\voskdaemon\app\scripts\build_x64.bat %*
set "RUN_EXIT=%ERRORLEVEL%"

popd
exit /b %RUN_EXIT%