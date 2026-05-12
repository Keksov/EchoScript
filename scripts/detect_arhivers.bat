@echo off
setlocal EnableExtensions EnableDelayedExpansion

set "PROBE_ARCHIVE=%~1"
if not defined ES_ARCHIVER_VERBOSE set "ES_ARCHIVER_VERBOSE=0"
if /i "%~2"=="--verbose" set "ES_ARCHIVER_VERBOSE=1"
if /i "%UNTAR_VERBOSE%"=="1" set "ES_ARCHIVER_VERBOSE=1"

set "ES_ARCHIVER_KIND="
set "ES_ARCHIVER_CMD="
set "ES_ARCHIVER_ARGS="
set "ES_ARCHIVER_INFO="
set "ES_ARCHIVER_REASON="
set "ES_TAR_BZ2_SUPPORTED=0"

set "TAR_CANDIDATE="
set "TAR_DIAG=tar not checked"
set "SEVEN_Z_CANDIDATE="
set "SEVEN_Z_SOURCE="
set "PYTHON_CANDIDATE="
set "PYTHON_ARGS="
set "PYTHON_SOURCE="

call :find_tar
if defined TAR_CANDIDATE (
    call :log "Found tar: %TAR_CANDIDATE%"
    if exist "%PROBE_ARCHIVE%" (
        call :log "Probing tar bz2 support using archive: %PROBE_ARCHIVE%"
        call :probe_tar_bz2 "%PROBE_ARCHIVE%"
    ) else (
        call :log "Probe archive not provided. Checking tar --version and bzip2."
        call :guess_tar_bz2_support
    )
) else (
    set "TAR_DIAG=tar not found in PATH"
    call :log "%TAR_DIAG%"
)

if "%ES_TAR_BZ2_SUPPORTED%"=="1" (
    set "ES_ARCHIVER_KIND=TAR"
    set "ES_ARCHIVER_CMD=%TAR_CANDIDATE%"
    set "ES_ARCHIVER_ARGS="
    set "ES_ARCHIVER_INFO=system tar supports bz2"
    set "ES_ARCHIVER_REASON=%TAR_DIAG%"
    call :log "Selected TAR (!ES_ARCHIVER_REASON!)"
    goto :export_success
)
call :log "Tar rejected: %TAR_DIAG%"

call :find_7z
if defined SEVEN_Z_CANDIDATE (
    call :log "Found 7z: %SEVEN_Z_CANDIDATE% (%SEVEN_Z_SOURCE%)"
    set "ES_ARCHIVER_KIND=7Z"
    set "ES_ARCHIVER_CMD=%SEVEN_Z_CANDIDATE%"
    set "ES_ARCHIVER_ARGS="
    set "ES_ARCHIVER_INFO=7z.exe"
    set "ES_ARCHIVER_REASON=%TAR_DIAG%; using 7z (%SEVEN_Z_SOURCE%)"
    call :log "Selected 7Z (!ES_ARCHIVER_REASON!)"
    goto :export_success
)
call :log "7z not found via where and C:\Program Files\7-Zip"

call :find_python
if defined PYTHON_CANDIDATE (
    call :log "Found python: %PYTHON_CANDIDATE% (%PYTHON_SOURCE%)"
    set "ES_ARCHIVER_KIND=PYTHON"
    set "ES_ARCHIVER_CMD=%PYTHON_CANDIDATE%"
    set "ES_ARCHIVER_ARGS=%PYTHON_ARGS%"
    set "ES_ARCHIVER_INFO=python tarfile"
    set "ES_ARCHIVER_REASON=%TAR_DIAG%; 7z not found; using python (%PYTHON_SOURCE%)"
    call :log "Selected PYTHON (!ES_ARCHIVER_REASON!)"
    goto :export_success
)

set "ES_ARCHIVER_REASON=%TAR_DIAG%; 7z not found; python not found"
call :log "Detection failed (%ES_ARCHIVER_REASON%)"

echo [ERROR] No extractor available for tar.bz2
echo [ERROR] Checked: tar with bz2, 7z.exe, C:\Program Files\7-Zip\7z.exe, python
goto :export_fail

:find_tar
for /f "delims=" %%I in ('where tar 2^>nul') do (
    if not defined TAR_CANDIDATE set "TAR_CANDIDATE=%%I"
)
exit /b 0

:probe_tar_bz2
set "ARCHIVE_TO_TEST=%~1"
if not exist "%ARCHIVE_TO_TEST%" (
    set "TAR_DIAG=probe archive not found"
    exit /b 0
)
"%TAR_CANDIDATE%" -tjf "%ARCHIVE_TO_TEST%" >nul 2>&1
if not errorlevel 1 (
    set "ES_TAR_BZ2_SUPPORTED=1"
    set "TAR_DIAG=tar -tjf succeeded"
) else (
    set "TAR_DIAG=tar -tjf failed (bz2 unsupported or archive invalid)"
)
exit /b 0

:guess_tar_bz2_support
set "TAR_DIAG=tar --version did not report bz2 support"
for /f "delims=" %%I in ('"%TAR_CANDIDATE%" --version 2^>nul') do (
    echo %%I | findstr /i "bz2 bzip2" >nul
    if not errorlevel 1 (
        set "ES_TAR_BZ2_SUPPORTED=1"
        set "TAR_DIAG=tar --version reports bz2 support"
    )
)
if "%ES_TAR_BZ2_SUPPORTED%"=="1" exit /b 0

where bzip2 >nul 2>&1
if not errorlevel 1 (
    set "ES_TAR_BZ2_SUPPORTED=1"
    set "TAR_DIAG=external bzip2 found in PATH"
) else (
    set "TAR_DIAG=no bz2 support detected in tar and no bzip2 in PATH"
)
exit /b 0

:find_7z
for /f "delims=" %%I in ('where 7z.exe 2^>nul') do (
    if not defined SEVEN_Z_CANDIDATE (
        set "SEVEN_Z_CANDIDATE=%%I"
        set "SEVEN_Z_SOURCE=PATH"
    )
)
if defined SEVEN_Z_CANDIDATE exit /b 0

if exist "C:\Program Files\7-Zip\7z.exe" (
    set "SEVEN_Z_CANDIDATE=C:\Program Files\7-Zip\7z.exe"
    set "SEVEN_Z_SOURCE=C:\Program Files\7-Zip"
)
exit /b 0

:find_python
for /f "delims=" %%I in ('where python 2^>nul') do (
    if not defined PYTHON_CANDIDATE (
        set "PYTHON_CANDIDATE=%%I"
        set "PYTHON_ARGS="
        set "PYTHON_SOURCE=PATH"
    )
)
if defined PYTHON_CANDIDATE exit /b 0

py -3 -c "import sys; sys.exit(0)" >nul 2>&1
if not errorlevel 1 (
    set "PYTHON_CANDIDATE=py"
    set "PYTHON_ARGS=-3"
    set "PYTHON_SOURCE=py launcher -3"
    exit /b 0
)

py -c "import sys; sys.exit(0)" >nul 2>&1
if not errorlevel 1 (
    set "PYTHON_CANDIDATE=py"
    set "PYTHON_ARGS="
    set "PYTHON_SOURCE=py launcher"
)
exit /b 0

:log
if /i "%ES_ARCHIVER_VERBOSE%"=="1" echo [ARCHIVER] %~1
exit /b 0

:export_success
endlocal & (
    set "ES_ARCHIVER_KIND=%ES_ARCHIVER_KIND%"
    set "ES_ARCHIVER_CMD=%ES_ARCHIVER_CMD%"
    set "ES_ARCHIVER_ARGS=%ES_ARCHIVER_ARGS%"
    set "ES_ARCHIVER_INFO=%ES_ARCHIVER_INFO%"
    set "ES_ARCHIVER_REASON=%ES_ARCHIVER_REASON%"
    set "ES_TAR_BZ2_SUPPORTED=%ES_TAR_BZ2_SUPPORTED%"
)
exit /b 0

:export_fail
endlocal & (
    set "ES_ARCHIVER_REASON=%ES_ARCHIVER_REASON%"
)
exit /b 1
