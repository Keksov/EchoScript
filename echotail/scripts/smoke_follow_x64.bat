@echo off
REM Smoke: build echotail, then follow + colour test (pwsh-driven for reliable timing).
setlocal

call "%~dp0build_x64.bat"
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%

pwsh -NoProfile -File "%~dp0smoke_follow.ps1"
exit /b %ERRORLEVEL%
