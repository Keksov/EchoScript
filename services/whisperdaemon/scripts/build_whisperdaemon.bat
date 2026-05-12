@echo off
setlocal

pushd "%~dp0\..\..\.."
if errorlevel 1 exit /b 1

set "FPC_EXE=EchoRecorder\VendorsCore\fpc\fpc-main\bin\x86_64-win64\fpc.exe"
set "FPC_SETUP_SCRIPT=EchoRecorder\VendorsCore\fpc\scripts\win_x64\fpc_release_setup.bat"

if not exist "%FPC_EXE%" (
	echo [INFO] FPC toolchain is missing. Provisioning vendor compiler...
	if not exist "%FPC_SETUP_SCRIPT%" (
		echo [ERROR] FPC setup script not found: %FPC_SETUP_SCRIPT%
		popd
		exit /b 1
	)

	call "%FPC_SETUP_SCRIPT%"
	if errorlevel 1 (
		echo [ERROR] Failed to provision FPC toolchain.
		echo [ERROR] See EchoRecorder\VendorsCore\fpc\README.md for manual setup options.
		popd
		exit /b 1
	)

	if not exist "%FPC_EXE%" (
		echo [ERROR] FPC provisioning finished but compiler is still missing:
		echo [ERROR]   %FPC_EXE%
		popd
		exit /b 1
	)

	echo [INFO] FPC toolchain is ready.
)

call services\whisperdaemon\app\scripts\build_x64.bat %*
set "RUN_EXIT=%ERRORLEVEL%"

popd
exit /b %RUN_EXIT%