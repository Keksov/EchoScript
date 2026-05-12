@echo off
setlocal EnableExtensions

if "%~2"=="" goto :usage
if not "%~3"=="" if /i not "%~3"=="--verbose" goto :usage

if not defined UNTAR_VERBOSE set "UNTAR_VERBOSE=0"
if /i "%~3"=="--verbose" set "UNTAR_VERBOSE=1"

set "ARCHIVE_PATH=%~1"
set "DEST_DIR=%~2"
set "EXIT_CODE=1"

if not exist "%ARCHIVE_PATH%" (
    echo [ERROR] Archive file not found: %ARCHIVE_PATH%
    goto :done
)

if not exist "%DEST_DIR%" (
    mkdir "%DEST_DIR%"
    if errorlevel 1 (
        echo [ERROR] Failed to create extraction directory: %DEST_DIR%
        goto :done
    )
)

if /i "%UNTAR_VERBOSE%"=="1" (
    call "scripts\detect_arhivers.bat" "%ARCHIVE_PATH%" --verbose
) else (
    call "scripts\detect_arhivers.bat" "%ARCHIVE_PATH%"
)
if errorlevel 1 (
    echo [ERROR] Could not detect extractor for: %ARCHIVE_PATH%
    if defined ES_ARCHIVER_REASON call echo [ERROR] untar: reason: %%ES_ARCHIVER_REASON%%
    goto :done
)

echo [INFO] untar: using %ES_ARCHIVER_KIND% (%ES_ARCHIVER_CMD% %ES_ARCHIVER_ARGS%)
if /i "%UNTAR_VERBOSE%"=="1" (
    if defined ES_ARCHIVER_REASON call echo [INFO] untar: reason: %%ES_ARCHIVER_REASON%%
)

if /i "%ES_ARCHIVER_KIND%"=="TAR" goto :extract_with_tar
if /i "%ES_ARCHIVER_KIND%"=="7Z" goto :extract_with_7z
if /i "%ES_ARCHIVER_KIND%"=="PYTHON" goto :extract_with_python

echo [ERROR] Unsupported extractor kind: %ES_ARCHIVER_KIND%
goto :done

:extract_with_tar
"%ES_ARCHIVER_CMD%" -xjf "%ARCHIVE_PATH%" -C "%DEST_DIR%"
if errorlevel 1 (
    echo [ERROR] tar extraction failed: %ARCHIVE_PATH%
    goto :done
)
set "EXIT_CODE=0"
goto :done

:extract_with_7z
call :untar_with_7z "%ARCHIVE_PATH%" "%DEST_DIR%"
if errorlevel 1 (
    echo [ERROR] 7z extraction failed: %ARCHIVE_PATH%
    goto :done
)
set "EXIT_CODE=0"
goto :done

:extract_with_python
call :untar_with_python "%ARCHIVE_PATH%" "%DEST_DIR%"
if errorlevel 1 (
    echo [ERROR] python extraction failed: %ARCHIVE_PATH%
    goto :done
)
set "EXIT_CODE=0"
goto :done

:untar_with_7z
setlocal
set "IN_ARCHIVE=%~1"
set "IN_DEST=%~2"
set "TMP_TAR=%TEMP%\echoscript_untar_%RANDOM%_%RANDOM%.tar"

"%ES_ARCHIVER_CMD%" x -y -so "%IN_ARCHIVE%" > "%TMP_TAR%"
if errorlevel 1 (
    if exist "%TMP_TAR%" del /q "%TMP_TAR%" >nul 2>&1
    endlocal & exit /b 1
)

if not exist "%TMP_TAR%" (
    endlocal & exit /b 1
)

"%ES_ARCHIVER_CMD%" x -y "-o%IN_DEST%" "%TMP_TAR%" >nul
set "SEVEN_Z_EXIT=%ERRORLEVEL%"

if exist "%TMP_TAR%" del /q "%TMP_TAR%" >nul 2>&1
endlocal & exit /b %SEVEN_Z_EXIT%

:untar_with_python
setlocal
set "IN_ARCHIVE=%~1"
set "IN_DEST=%~2"

if defined ES_ARCHIVER_ARGS (
    "%ES_ARCHIVER_CMD%" %ES_ARCHIVER_ARGS% -c "import tarfile,sys; tarfile.open(sys.argv[1], 'r:bz2').extractall(sys.argv[2])" "%IN_ARCHIVE%" "%IN_DEST%"
) else (
    "%ES_ARCHIVER_CMD%" -c "import tarfile,sys; tarfile.open(sys.argv[1], 'r:bz2').extractall(sys.argv[2])" "%IN_ARCHIVE%" "%IN_DEST%"
)

set "PY_EXIT=%ERRORLEVEL%"
endlocal & exit /b %PY_EXIT%

:usage
echo Usage:
echo   scripts\untar.bat ^<archive.tar.bz2^> ^<destination-directory^> [--verbose]
echo.
echo You can also set UNTAR_VERBOSE=1 for script-driven diagnostics.
exit /b 1

:done
exit /b %EXIT_CODE%
