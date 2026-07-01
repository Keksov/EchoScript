@echo off
REM Build everything for the Daemon Monitor: unit tests + CLI + GUI.
REM Order matters: CLI before GUI (GUI spawns the CLI at runtime).
setlocal

set "BASE=%~dp0.."

echo === [1/3] core unit tests ===
call "%BASE%\tests\build_x64.bat" || goto :fail

echo.
echo === [2/3] CLI (monitor.exe) ===
call "%BASE%\cli\scripts\build_x64.bat" || goto :fail

echo.
echo === [3/3] GUI (MonitorApp.exe, lazbuild) ===
call "%BASE%\app\scripts\build_x64.bat" || goto :fail

echo.
echo All monitor components built successfully.
endlocal & exit /b 0

:fail
echo.
echo BUILD ALL FAILED
endlocal & exit /b 1
