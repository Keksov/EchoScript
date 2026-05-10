@echo off
REM ============================================================
REM EchoScript — common ffmpeg utilities
REM Usage: call scripts\ffmpeg.bat <command>
REM Commands: ensure_ffmpeg_bin, print_ffmpeg_diag
REM ============================================================

if "%~1"=="" goto :ensure_ffmpeg_bin
set "_CMD=%~1"
shift
goto :%_CMD%

:ensure_ffmpeg_bin
if not defined FFMPEG_BIN (
    for /f "delims=" %%I in ('where ffmpeg.exe 2^>nul') do (
        if not defined FFMPEG_BIN set "FFMPEG_BIN=%%~fI"
    )
)
exit /b 0

:print_ffmpeg_diag
if defined FFMPEG_BIN (
    echo [DIAG] FFMPEG_BIN=%FFMPEG_BIN%
) else (
    echo [DIAG] FFMPEG_BIN is not set ^(soundfile fallback mode^)
)
exit /b 0
