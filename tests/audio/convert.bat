@echo off

set "INPUT=1_Orientation.flac"
set TIME_FRAME=-ss 10 -t 100

for %%i in ("%INPUT%") do set "INPUT_NAME=%%~ni"

ffmpeg -i "%~dp0%INPUT%" -acodec pcm_s16le -ac 1 -ar 16000 %TIME_FRAME% "%~dp0%INPUT_NAME%.wav"
