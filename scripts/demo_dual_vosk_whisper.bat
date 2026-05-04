@echo off
setlocal

pushd "%~dp0.."
if errorlevel 1 exit /b 1

where ffmpeg >nul 2>&1
if errorlevel 1 (
	echo ERROR: ffmpeg not found in PATH.
	popd
	exit /b 1
)

set "CLI_EXE=EchoRecorder\cli\build\x64\EchoRecorderCore.exe"
set "FIXTURE="

for %%F in ("EchoRecorder\tests\*_ogg.ogg") do (
	if not defined FIXTURE set "FIXTURE=%%~fF"
)

if not exist "%CLI_EXE%" (
	echo Executable not found:
	echo   %CLI_EXE%
	echo Run EchoRecorder\cli\scripts\build_x64.bat first.
	popd
	exit /b 1
)

if not defined FIXTURE (
	echo Fixture not found: EchoRecorder\tests\*_ogg.ogg
	popd
	exit /b 1
)

ffmpeg -re -hide_banner -loglevel error -i "%FIXTURE%" -f s16le -ar 16000 -ac 1 - | "%CLI_EXE%" --backend daemon --mode dictation --language ru --daemon-host 127.0.0.1 --daemon vosk:7701 --daemon whisper:7801 -f pcm16le -i - %*
set "_ec=%errorlevel%"
popd
exit /b %_ec%
