@echo off
REM ============================================================
REM EchoScript — Setup all services and orchestrator
REM ============================================================
setlocal

set "SCRIPT_DIR=%~dp0"
call "%SCRIPT_DIR%env.bat"

echo ============================================================
echo  EchoScript — Full Setup
echo ============================================================
echo.

echo --- [1/7] Orchestrator (Bun) ---
call "%SCRIPT_DIR%setup_orchestrator.bat"
if errorlevel 1 echo [WARN] Orchestrator setup had issues. & echo.

echo --- [2/7] Whisper Podlodka ---
call "%SCRIPT_DIR%setup_whisper_podlodka.bat"
if errorlevel 1 echo [WARN] whisper_podlodka setup had issues. & echo.

echo --- [3/7] Borealis ---
call "%SCRIPT_DIR%setup_borealis.bat"
if errorlevel 1 echo [WARN] borealis setup had issues. & echo.

echo --- [4/7] Gemma4 ---
call "%SCRIPT_DIR%setup_gemma4.bat"
if errorlevel 1 echo [WARN] gemma4 setup had issues. & echo.

echo --- [5/7] VibeVoice ---
call "%SCRIPT_DIR%setup_vibevoice.bat"
if errorlevel 1 echo [WARN] vibevoice setup had issues. & echo.

echo --- [6/7] Vosk RU ---
call "%SCRIPT_DIR%setup_vosk_ru.bat"
if errorlevel 1 echo [WARN] vosk_ru setup had issues. & echo.

echo --- [7/7] Vosk EN ---
call "%SCRIPT_DIR%setup_vosk_en.bat"
if errorlevel 1 echo [WARN] vosk_en setup had issues. & echo.

echo ============================================================
echo  Setup complete.
echo  Model weights are NOT downloaded yet.
echo  Use scripts\download_*.bat to download models individually.
echo ============================================================

endlocal
*** Add File: c:\projects\EchoScript\scripts\setup_vosk_ru.bat
@echo off
REM ============================================================
REM EchoScript — Setup: vosk_ru service
REM Creates venv and installs pip dependencies without torch.
REM ============================================================
setlocal enabledelayedexpansion

set "SCRIPT_DIR=%~dp0"
call "%SCRIPT_DIR%env.bat"
set "SERVICE_DIR=%SCRIPT_DIR%..\services\vosk_ru"
set "SKIP_TORCH=1"

call "%SCRIPT_DIR%_common.bat" create_venv "%SERVICE_DIR%"
if errorlevel 1 goto :fail
call "%SCRIPT_DIR%_common.bat" install_requirements "%SERVICE_DIR%"
if errorlevel 1 goto :fail

echo.
echo [OK] vosk_ru setup complete.
echo      Activate with: %SERVICE_DIR%\venv\Scripts\activate.bat
goto :done

:fail
echo.
echo [FAIL] vosk_ru setup failed.
exit /b 1

:done
endlocal
*** Add File: c:\projects\EchoScript\scripts\setup_vosk_en.bat
@echo off
REM ============================================================
REM EchoScript — Setup: vosk_en service
REM Creates venv and installs pip dependencies without torch.
REM ============================================================
setlocal enabledelayedexpansion

set "SCRIPT_DIR=%~dp0"
call "%SCRIPT_DIR%env.bat"
set "SERVICE_DIR=%SCRIPT_DIR%..\services\vosk_en"
set "SKIP_TORCH=1"

call "%SCRIPT_DIR%_common.bat" create_venv "%SERVICE_DIR%"
if errorlevel 1 goto :fail
call "%SCRIPT_DIR%_common.bat" install_requirements "%SERVICE_DIR%"
if errorlevel 1 goto :fail

echo.
echo [OK] vosk_en setup complete.
echo      Activate with: %SERVICE_DIR%\venv\Scripts\activate.bat
goto :done

:fail
echo.
echo [FAIL] vosk_en setup failed.
exit /b 1

:done
endlocal
*** Add File: c:\projects\EchoScript\scripts\download_vosk_model.py
from __future__ import annotations

import argparse
import shutil
import sys
import urllib.request
import zipfile
from pathlib import Path


def parse_args() -> argparse.Namespace:
	parser = argparse.ArgumentParser()
	parser.add_argument("--url", required=True)
	parser.add_argument("--target-root", required=True)
	parser.add_argument("--expected-dir", required=True)
	return parser.parse_args()


def download_archive(url: str, archive_path: Path) -> None:
	with urllib.request.urlopen(url) as response, archive_path.open("wb") as output_file:
		shutil.copyfileobj(response, output_file)


def main() -> int:
	args = parse_args()
	target_root = Path(args.target_root)
	target_root.mkdir(parents=True, exist_ok=True)

	expected_dir = target_root / args.expected_dir
	if expected_dir.exists():
		print(f"[INFO] Model already present: {expected_dir}")
		return 0

	archive_name = Path(args.url).name
	archive_path = target_root / archive_name
	temp_extract_root = target_root / f"{args.expected_dir}.extracting"

	if temp_extract_root.exists():
		shutil.rmtree(temp_extract_root)

	if archive_path.exists():
		archive_path.unlink()

	print(f"[INFO] Downloading {args.url}")
	print(f"[INFO] Target root: {target_root}")
	download_archive(args.url, archive_path)

	print(f"[INFO] Extracting {archive_path.name}")
	temp_extract_root.mkdir(parents=True, exist_ok=True)
	try:
		with zipfile.ZipFile(archive_path) as archive:
			archive.extractall(temp_extract_root)

		extracted_dir = temp_extract_root / args.expected_dir
		if not extracted_dir.exists():
			raise FileNotFoundError(f"Extracted model directory is missing: {extracted_dir}")

		extracted_dir.replace(expected_dir)
	finally:
		shutil.rmtree(temp_extract_root, ignore_errors=True)
		archive_path.unlink(missing_ok=True)

	print(f"[OK] Model available at {expected_dir}")
	return 0


if __name__ == "__main__":
	raise SystemExit(main())
*** Add File: c:\projects\EchoScript\scripts\download_vosk_ru.bat
@echo off
REM ============================================================
REM EchoScript — Download: vosk-model-ru-0.42
REM Requires: setup_vosk_ru.bat to be run first.
REM ============================================================
setlocal

set "SCRIPT_DIR=%~dp0"
call "%SCRIPT_DIR%env.bat"
set "VENV_DIR=%SCRIPT_DIR%..\services\vosk_ru\venv"

if not exist "%VENV_DIR%\Scripts\python.exe" (
	echo [ERROR] Virtual environment not found. Run setup_vosk_ru.bat first.
	exit /b 1
)

echo [INFO] Downloading vosk-model-ru-0.42 ...
echo [INFO] Model root: %VOSK_MODELS_ROOT%
echo.

"%VENV_DIR%\Scripts\python.exe" "%SCRIPT_DIR%download_vosk_model.py" --url "https://alphacephei.com/vosk/models/vosk-model-ru-0.42.zip" --target-root "%VOSK_MODELS_ROOT%" --expected-dir "vosk-model-ru-0.42"
if errorlevel 1 (
	echo [ERROR] Download failed.
	exit /b 1
)

echo.
echo [OK] vosk-model-ru-0.42 downloaded to %VOSK_MODELS_ROOT%

endlocal
*** Add File: c:\projects\EchoScript\scripts\download_vosk_en.bat
@echo off
REM ============================================================
REM EchoScript — Download: vosk-model-en-us-0.42-gigaspeech
REM Requires: setup_vosk_en.bat to be run first.
REM ============================================================
setlocal

set "SCRIPT_DIR=%~dp0"
call "%SCRIPT_DIR%env.bat"
set "VENV_DIR=%SCRIPT_DIR%..\services\vosk_en\venv"

if not exist "%VENV_DIR%\Scripts\python.exe" (
	echo [ERROR] Virtual environment not found. Run setup_vosk_en.bat first.
	exit /b 1
)

echo [INFO] Downloading vosk-model-en-us-0.42-gigaspeech ...
echo [INFO] Model root: %VOSK_MODELS_ROOT%
echo.

"%VENV_DIR%\Scripts\python.exe" "%SCRIPT_DIR%download_vosk_model.py" --url "https://alphacephei.com/vosk/models/vosk-model-en-us-0.42-gigaspeech.zip" --target-root "%VOSK_MODELS_ROOT%" --expected-dir "vosk-model-en-us-0.42-gigaspeech"
if errorlevel 1 (
	echo [ERROR] Download failed.
	exit /b 1
)

echo.
echo [OK] vosk-model-en-us-0.42-gigaspeech downloaded to %VOSK_MODELS_ROOT%

endlocal
