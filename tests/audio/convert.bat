@echo off

set "INPUT=1_fragment_3.mp4"

for %%i in ("%INPUT%") do set "INPUT_NAME=%%~ni"

ffmpeg -i "%~dp0%INPUT%" -acodec pcm_s16le -ac 1 -ar 16000 "%~dp0%INPUT_NAME%.wav"