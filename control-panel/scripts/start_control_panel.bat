@echo off
REM Start the EchoScript control panel (:3001) in THIS console so it runs in the user's
REM interactive session — required for the native folder/file picker dialogs to appear.
REM (A server launched from a service / non-interactive context renders dialogs on an
REM invisible window station.) Builds the UI bundle first if it is missing.
setlocal

pushd "%~dp0.."
if errorlevel 1 exit /b 1

if not exist "server\public\index.html" (
    echo [INFO] UI bundle missing — building ui...
    pushd ui
    call bun install
    call bun run build
    popd
)

echo [INFO] Starting control panel on http://127.0.0.1:3001 (Ctrl+C to stop)
pushd server
bun --env-file=server.env run server.ts
popd

popd
endlocal
