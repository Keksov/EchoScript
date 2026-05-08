@echo off
setlocal

call "%~dp0..\app\scripts\build_x64.bat" %*
exit /b %ERRORLEVEL%
