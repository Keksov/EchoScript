@echo off
REM Start the EchoScript stack. In an interactive Windows Terminal session each service
REM opens as a NEW TAB of the current window (scripts\launch_tab.ps1); otherwise each
REM opens as a minimized window. Edit the list below to taste.
setlocal
set "ROOT=%~dp0.."

echo [start_all] orchestrator ...
call "%ROOT%\orchestrator\scripts\start_orchestrator.bat"

echo [start_all] whisperdaemon_en ...
call "%ROOT%\services\whisperdaemon\scripts\start_whisperdaemon_en.bat"

echo [start_all] voskdaemon_ru_cmd ...
call "%ROOT%\services\voskdaemon\scripts\start_voskdaemon_ru_cmd.bat"

REM Heavier / optional — uncomment as needed (RAM: podlodka + vosk_ru are large):
REM call "%ROOT%\services\whisperdaemon\scripts\start_whisperdaemon_podlodka.bat"
REM call "%ROOT%\services\voskdaemon\scripts\start_voskdaemon_ru.bat"

echo.
echo [start_all] done — tabs of this window if interactive, minimized windows otherwise.
echo [start_all] control panel: control-panel\scripts\start_control_panel.bat (:3001)
endlocal
