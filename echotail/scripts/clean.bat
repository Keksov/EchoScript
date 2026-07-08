@echo off
setlocal

pushd "%~dp0.."
if errorlevel 1 exit /b 1

if exist build\x64 rmdir /s /q build\x64
if not exist build\x64\dcu mkdir build\x64\dcu

popd
echo Cleaned echotail\build\x64
