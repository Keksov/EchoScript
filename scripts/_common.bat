
@echo off
REM ============================================================
REM EchoScript — common setup utilities
REM Usage: call _common.bat <command> [args...]
REM Commands: detect_gpu, create_venv <dir>, install_requirements <dir>
REM ============================================================

set "PYTHON_EXE=C:\Python313\python.exe"
set "HF_HOME=c:\var\huggingface"
set "PIP_DISABLE_PIP_VERSION_CHECK=1"

REM Torch index URLs
set "TORCH_CPU_INDEX=https://download.pytorch.org/whl/cpu"
set "TORCH_CUDA_INDEX=https://download.pytorch.org/whl/cu124"

REM --- Dispatch to requested command ---
if "%~1"=="" goto :eof
set "_CMD=%~1"
shift
goto :%_CMD%

REM ============================================================
:detect_gpu
REM Sets HAS_GPU=1 if nvidia-smi succeeds, else HAS_GPU=0
REM ============================================================
nvidia-smi >nul 2>&1
if %errorlevel% equ 0 (
    set "HAS_GPU=1"
    echo [INFO] NVIDIA GPU detected — will install CUDA-enabled torch.
) else (
    set "HAS_GPU=0"
    echo [INFO] No NVIDIA GPU detected — will install CPU-only torch.
)
goto :eof

REM ============================================================
:create_venv
REM Usage: call :create_venv <service_dir>
REM Creates venv in <service_dir>\venv and installs torch.
REM Requires HAS_GPU to be set (call :detect_gpu first).
REM ============================================================
set "SERVICE_DIR=%~1"
set "VENV_DIR=%SERVICE_DIR%\venv"
set "VENV_PIP=%VENV_DIR%\Scripts\pip.exe"

if not exist "%VENV_DIR%\Scripts\python.exe" (
    echo [INFO] Creating virtual environment in %VENV_DIR% ...
    "%PYTHON_EXE%" -m venv "%VENV_DIR%"
    if errorlevel 1 (
        echo [ERROR] Failed to create venv.
        exit /b 1
    )
) else (
    echo [INFO] Virtual environment already exists: %VENV_DIR%
)

echo [INFO] Ensuring pip is available ...
"%VENV_DIR%\Scripts\python.exe" -m ensurepip --upgrade --default-pip 2>nul
"%VENV_DIR%\Scripts\python.exe" -m pip install --upgrade pip --quiet

echo [INFO] Installing torch ...
if "%HAS_GPU%"=="1" (
    "%VENV_PIP%" install torch torchaudio --index-url "%TORCH_CUDA_INDEX%" --quiet
) else (
    "%VENV_PIP%" install torch torchaudio --index-url "%TORCH_CPU_INDEX%" --quiet
)
if errorlevel 1 (
    echo [ERROR] Failed to install torch.
    exit /b 1
)

goto :eof

REM ============================================================
:install_requirements
REM Usage: call :install_requirements <service_dir>
REM Installs requirements.txt + shared package in editable mode.
REM ============================================================
set "SERVICE_DIR=%~1"
set "VENV_PIP=%SERVICE_DIR%\venv\Scripts\pip.exe"

echo [INFO] Installing requirements from %SERVICE_DIR%\requirements.txt ...
"%VENV_PIP%" install -r "%SERVICE_DIR%\requirements.txt" --quiet
if errorlevel 1 (
    echo [ERROR] Failed to install requirements.
    exit /b 1
)

echo [INFO] Installing echoscript-shared in editable mode ...
"%VENV_PIP%" install -e "%~dp0..\shared" --quiet
if errorlevel 1 (
    echo [ERROR] Failed to install echoscript-shared.
    exit /b 1
)

goto :eof
