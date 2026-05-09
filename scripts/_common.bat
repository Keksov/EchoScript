
@echo off
REM ============================================================
REM EchoScript — common setup utilities
REM Usage: call _common.bat <command> [args...]
REM Commands: detect_gpu, create_venv <dir>, install_requirements <dir>
REM ============================================================

set "COMMON_SCRIPT_DIR=%~dp0"
call "%COMMON_SCRIPT_DIR%env.bat"

set "PIP_DISABLE_PIP_VERSION_CHECK=1"
set "PYTHON_ARGS="

REM Torch index URLs
set "TORCH_CPU_INDEX=https://download.pytorch.org/whl/cpu"
set "TORCH_CUDA_INDEX=https://download.pytorch.org/whl/cu124"

call :resolve_python
if errorlevel 1 exit /b 1
if /I "%ECHOSCRIPT_SETUP_DIAG%"=="1" (
    if defined PYTHON_ARGS (
        echo [DIAG] Resolved Python interpreter: "%PYTHON_EXE%" %PYTHON_ARGS%
    ) else (
        echo [DIAG] Resolved Python interpreter: "%PYTHON_EXE%"
    )
)

REM --- Dispatch to requested command ---
if "%~1"=="" goto :eof
set "_CMD=%~1"
shift
goto :%_CMD%

REM ============================================================
:resolve_python
REM Resolves a base Python interpreter for venv creation.
REM Honors PYTHON_EXE if already provided by the caller.
REM ============================================================
if defined PYTHON_EXE exit /b 0

if exist "C:\Python313\python.exe" (
    set "PYTHON_EXE=C:\Python313\python.exe"
    exit /b 0
)

for %%I in (python.exe) do if not "%%~$PATH:I"=="" set "PYTHON_EXE=%%~$PATH:I"
if defined PYTHON_EXE exit /b 0

set "PYTHON_LAUNCHER="
for %%I in (py.exe) do if not "%%~$PATH:I"=="" set "PYTHON_LAUNCHER=%%~$PATH:I"
if defined PYTHON_LAUNCHER (
    "%PYTHON_LAUNCHER%" -3.13 -c "import sys" >nul 2>&1
    if not errorlevel 1 (
        set "PYTHON_EXE=%PYTHON_LAUNCHER%"
        set "PYTHON_ARGS=-3.13"
        exit /b 0
    )

    "%PYTHON_LAUNCHER%" -3 -c "import sys" >nul 2>&1
    if not errorlevel 1 (
        set "PYTHON_EXE=%PYTHON_LAUNCHER%"
        set "PYTHON_ARGS=-3"
        exit /b 0
    )
)

echo [ERROR] Base Python interpreter not found.
echo         Install Python 3.13 or ensure python.exe / py.exe is available on PATH.
exit /b 1

REM ============================================================
:detect_gpu
REM Sets HAS_GPU=1 if nvidia-smi succeeds, else HAS_GPU=0
REM ============================================================
nvidia-smi >nul 2>&1
if %errorlevel% equ 0 (
    set "HAS_GPU=1"
    echo [INFO] NVIDIA GPU detected - will install CUDA-enabled torch.
) else (
    set "HAS_GPU=0"
    echo [INFO] No NVIDIA GPU detected - will install CPU-only torch.
)
exit /b 0

REM ============================================================
:create_venv
REM Usage: call :create_venv <service_dir>
REM Creates venv in <service_dir>\venv and installs torch unless SKIP_TORCH=1.
REM Requires HAS_GPU to be set unless SKIP_TORCH=1.
REM ============================================================
set "TARGET_SERVICE_DIR=%~1"
set "TARGET_VENV_DIR=%TARGET_SERVICE_DIR%\venv"
set "TARGET_VENV_PIP=%TARGET_VENV_DIR%\Scripts\pip.exe"

if /I "%ECHOSCRIPT_SETUP_DIAG%"=="1" (
    echo [DIAG] create_venv SERVICE_DIR=%TARGET_SERVICE_DIR%
    echo [DIAG] create_venv VENV_DIR=%TARGET_VENV_DIR%
)

if not exist "%TARGET_SERVICE_DIR%" (
    echo [ERROR] Service directory not found: %TARGET_SERVICE_DIR%
    exit /b 1
)

if not exist "%TARGET_VENV_DIR%\Scripts\python.exe" (
    echo [INFO] Creating virtual environment in %TARGET_VENV_DIR% ...
    if defined PYTHON_ARGS (
        if /I "%ECHOSCRIPT_SETUP_DIAG%"=="1" echo [DIAG] Running: "%PYTHON_EXE%" %PYTHON_ARGS% -m venv "%TARGET_VENV_DIR%"
        "%PYTHON_EXE%" %PYTHON_ARGS% -m venv "%TARGET_VENV_DIR%"
    ) else (
        if /I "%ECHOSCRIPT_SETUP_DIAG%"=="1" echo [DIAG] Running: "%PYTHON_EXE%" -m venv "%TARGET_VENV_DIR%"
        "%PYTHON_EXE%" -m venv "%TARGET_VENV_DIR%"
    )
    if errorlevel 1 (
        echo [ERROR] Failed to create venv.
        if defined PYTHON_ARGS (
            if /I "%ECHOSCRIPT_SETUP_DIAG%"=="1" echo [DIAG] create_venv command failed: "%PYTHON_EXE%" %PYTHON_ARGS% -m venv "%TARGET_VENV_DIR%"
        ) else (
            if /I "%ECHOSCRIPT_SETUP_DIAG%"=="1" echo [DIAG] create_venv command failed: "%PYTHON_EXE%" -m venv "%TARGET_VENV_DIR%"
        )
        exit /b 1
    )
) else (
    echo [INFO] Virtual environment already exists: %TARGET_VENV_DIR%
)

echo [INFO] Ensuring pip is available ...
"%TARGET_VENV_DIR%\Scripts\python.exe" -m ensurepip --upgrade --default-pip 2>nul
"%TARGET_VENV_DIR%\Scripts\python.exe" -m pip install --upgrade pip --quiet

if /I "%SKIP_TORCH%"=="1" (
    echo [INFO] SKIP_TORCH=1, skipping torch installation.
    goto :eof
)

echo [INFO] Installing torch ...
if "%HAS_GPU%"=="1" (
    "%TARGET_VENV_PIP%" install torch torchaudio --index-url "%TORCH_CUDA_INDEX%" --quiet
) else (
    "%TARGET_VENV_PIP%" install torch torchaudio --index-url "%TORCH_CPU_INDEX%" --quiet
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
set "TARGET_SERVICE_DIR=%~1"
set "TARGET_VENV_PIP=%TARGET_SERVICE_DIR%\venv\Scripts\pip.exe"

echo [INFO] Installing requirements from %TARGET_SERVICE_DIR%\requirements.txt ...
"%TARGET_VENV_PIP%" install -r "%TARGET_SERVICE_DIR%\requirements.txt" --quiet
if errorlevel 1 (
    echo [ERROR] Failed to install requirements.
    exit /b 1
)

echo [INFO] Installing echoscript-shared in editable mode ...
"%TARGET_VENV_PIP%" install -e "%COMMON_SCRIPT_DIR%..\shared" --quiet
if errorlevel 1 (
    echo [ERROR] Failed to install echoscript-shared.
    exit /b 1
)

goto :eof
