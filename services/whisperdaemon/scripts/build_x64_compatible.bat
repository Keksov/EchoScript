@echo off
REM ============================================================
REM EchoScript - Build compatible x64 whisper runtime
REM Builds whisper.dll and companion binaries from whisper.cpp
REM with conservative CPU flags for broad x64 compatibility.
REM
REM Usage:
REM   services\whisperdaemon\scripts\build_x64_compatible.bat [path-to-whisper-cpp-root]
REM ============================================================
setlocal EnableExtensions EnableDelayedExpansion

set "SCRIPT_DIR=%~dp0"
pushd "%SCRIPT_DIR%..\..\.."
if errorlevel 1 (
    echo [ERROR] Failed to enter repository root.
    exit /b 1
)

call "scripts\env.bat"

set "WHISPER_CPP_ROOT=%~1"
if not defined WHISPER_CPP_ROOT if defined WHISPER_CPP_VENDOR_ROOT set "WHISPER_CPP_ROOT=%WHISPER_CPP_VENDOR_ROOT%"
if not defined WHISPER_CPP_ROOT set "WHISPER_CPP_ROOT=services\whisperdaemon\vendors\whisper.cpp\whisper.cpp-master"

if not exist "%WHISPER_CPP_ROOT%\CMakeLists.txt" (
    echo [ERROR] whisper.cpp source is missing: %WHISPER_CPP_ROOT%
    echo [ERROR] Run setup_whisperdaemon_podlodka.bat first to download whisper.cpp.
    popd
    exit /b 1
)

if defined WHISPER_RELEASE_TAG (
    set "WHISPER_DLL_RELEASE_TAG=%WHISPER_RELEASE_TAG%"
) else (
    if not defined WHISPER_DLL_RELEASE_TAG set "WHISPER_DLL_RELEASE_TAG=1.8.4"
)

set "BUILD_DIR=services\whisperdaemon\build\_tmp_whisper_compatible"
set "RELEASE_DIR=services\whisperdaemon\releases\%WHISPER_DLL_RELEASE_TAG%"
set "TARGET_DLL=%RELEASE_DIR%\whisper.dll"

if exist "%BUILD_DIR%" rmdir /s /q "%BUILD_DIR%" >nul 2>&1
if not exist "%BUILD_DIR%" mkdir "%BUILD_DIR%"
if errorlevel 1 (
    echo [ERROR] Failed to create build directory: %BUILD_DIR%
    popd
    exit /b 1
)

if not exist "%RELEASE_DIR%" mkdir "%RELEASE_DIR%"
if errorlevel 1 (
    echo [ERROR] Failed to create release directory: %RELEASE_DIR%
    popd
    exit /b 1
)

set "CMAKE_EXE="
for %%V in (Community Professional Enterprise BuildTools) do (
    if not defined CMAKE_EXE (
        if exist "C:\Program Files\Microsoft Visual Studio\2022\%%V\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe" (
            set "CMAKE_EXE=C:\Program Files\Microsoft Visual Studio\2022\%%V\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"
        )
    )
)

if not defined CMAKE_EXE (
    for /f "delims=" %%P in ('where cmake 2^>nul') do (
        if not defined CMAKE_EXE set "CMAKE_EXE=%%P"
    )
)

if not defined CMAKE_EXE (
    echo [ERROR] cmake.exe not found. Install Visual Studio 2022 C++ tools.
    popd
    exit /b 1
)

echo [INFO] Configuring compatible whisper.cpp build...
"%CMAKE_EXE%" -S "%WHISPER_CPP_ROOT%" -B "%BUILD_DIR%" -G "Visual Studio 17 2022" -A x64 -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON -DGGML_BACKEND_DL=OFF -DGGML_NATIVE=OFF -DGGML_CPU_ALL_VARIANTS=OFF -DGGML_SSE42=OFF -DGGML_AVX=OFF -DGGML_AVX_VNNI=OFF -DGGML_AVX2=OFF -DGGML_BMI2=OFF -DGGML_FMA=OFF -DGGML_F16C=OFF -DGGML_AVX512=OFF -DGGML_AVX512_VBMI=OFF -DGGML_AVX512_VNNI=OFF -DGGML_AVX512_BF16=OFF -DGGML_AMX_TILE=OFF -DGGML_AMX_INT8=OFF -DGGML_AMX_BF16=OFF -DWHISPER_BUILD_EXAMPLES=ON -DWHISPER_BUILD_SERVER=OFF -DWHISPER_BUILD_TESTS=OFF
if errorlevel 1 (
    echo [ERROR] CMake configure failed for compatible build.
    popd
    exit /b 1
)

echo [INFO] Building compatible whisper runtime...
"%CMAKE_EXE%" --build "%BUILD_DIR%" --config Release --parallel
if errorlevel 1 (
    echo [ERROR] CMake build failed for compatible runtime.
    popd
    exit /b 1
)

echo [INFO] Staging runtime artifacts into %RELEASE_DIR%...
powershell -NoProfile -Command "$ErrorActionPreference='Stop'; $build=$env:BUILD_DIR; $dst=$env:RELEASE_DIR; $releaseItems = Get-ChildItem -Path $build -Recurse -File | Where-Object { $_.FullName -match '\\Release\\' }; if (-not $releaseItems) { $releaseItems = Get-ChildItem -Path $build -Recurse -File }; $dlls = $releaseItems | Where-Object { $_.Extension -ieq '.dll' }; foreach ($f in $dlls) { Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $dst $f.Name) -Force }; $cli = $releaseItems | Where-Object { $_.Name -ieq 'whisper-cli.exe' } | Select-Object -First 1; if ($cli) { Copy-Item -LiteralPath $cli.FullName -Destination (Join-Path $dst 'whisper-cli.exe') -Force }"
if errorlevel 1 (
    echo [ERROR] Failed to stage compatible runtime artifacts.
    popd
    exit /b 1
)

if not exist "%TARGET_DLL%" (
    echo [ERROR] whisper.dll was not produced by compatible build.
    popd
    exit /b 1
)

echo [OK] Compatible runtime build completed: %TARGET_DLL%
popd
exit /b 0