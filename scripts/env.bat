@echo off
set "HF_HOME=c:\var\huggingface"
set "HF_HUB_CACHE=%HF_HOME%\hub"
set "HUGGINGFACE_HUB_CACHE=%HF_HUB_CACHE%"
set "TRANSFORMERS_CACHE=%HF_HUB_CACHE%"
set "HF_ASSETS_CACHE=%HF_HOME%\assets"
set "HF_XET_CACHE=%HF_HOME%\xet"
set "VOSK_MODELS_ROOT=c:\var\vosk"

call "%~dp0proxy.bat"

if not exist "%HF_HOME%" mkdir "%HF_HOME%" >nul 2>&1
if not exist "%HF_HUB_CACHE%" mkdir "%HF_HUB_CACHE%" >nul 2>&1
if not exist "%HF_ASSETS_CACHE%" mkdir "%HF_ASSETS_CACHE%" >nul 2>&1
if not exist "%HF_XET_CACHE%" mkdir "%HF_XET_CACHE%" >nul 2>&1
if not exist "%VOSK_MODELS_ROOT%" mkdir "%VOSK_MODELS_ROOT%" >nul 2>&1

goto :eof
