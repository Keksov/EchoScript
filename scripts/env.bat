@echo off
set "HF_HOME=c:\var\huggingface"
set "HF_HUB_CACHE=%HF_HOME%\hub"
set "HUGGINGFACE_HUB_CACHE=%HF_HUB_CACHE%"
set "TRANSFORMERS_CACHE=%HF_HUB_CACHE%"
set "HF_ASSETS_CACHE=%HF_HOME%\assets"
set "HF_XET_CACHE=%HF_HOME%\xet"
set "VOSK_MODELS_ROOT=c:\var\vosk"

if defined ECHOSCRIPT_PROXY_CONFIGURED goto :after_proxy

set "ECHOSCRIPT_PROXY_CONFIGURED=1"
set "ECHOSCRIPT_PROXY_SOURCE=none"
set "ECHOSCRIPT_PROXY_AUTO_CONFIG="
set "RAW_HTTP_PROXY="
set "RAW_HTTPS_PROXY="
set "PROXY_RAW="
set "WINDOWS_PROXY_ENABLE="
set "WINDOWS_PROXY_SERVER="
set "WINDOWS_AUTO_CONFIG_URL="
set "WINDOWS_AUTO_DETECT="

if defined HTTP_PROXY set "RAW_HTTP_PROXY=%HTTP_PROXY%"
if not defined RAW_HTTP_PROXY if defined http_proxy set "RAW_HTTP_PROXY=%http_proxy%"
if defined HTTPS_PROXY set "RAW_HTTPS_PROXY=%HTTPS_PROXY%"
if not defined RAW_HTTPS_PROXY if defined https_proxy set "RAW_HTTPS_PROXY=%https_proxy%"

if defined RAW_HTTP_PROXY goto :use_existing_proxy_env
if defined RAW_HTTPS_PROXY goto :use_existing_proxy_env

for /f "skip=2 tokens=1,2,*" %%A in ('reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyEnable 2^>nul') do if /I "%%A"=="ProxyEnable" set "WINDOWS_PROXY_ENABLE=%%C"
for /f "skip=2 tokens=1,2,*" %%A in ('reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyServer 2^>nul') do if /I "%%A"=="ProxyServer" set "WINDOWS_PROXY_SERVER=%%C"
for /f "skip=2 tokens=1,2,*" %%A in ('reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v AutoConfigURL 2^>nul') do if /I "%%A"=="AutoConfigURL" set "WINDOWS_AUTO_CONFIG_URL=%%C"
for /f "skip=2 tokens=1,2,*" %%A in ('reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v AutoDetect 2^>nul') do if /I "%%A"=="AutoDetect" set "WINDOWS_AUTO_DETECT=%%C"

if /I "%WINDOWS_PROXY_ENABLE%"=="0x1" if defined WINDOWS_PROXY_SERVER set "PROXY_RAW=%WINDOWS_PROXY_SERVER%"
if defined PROXY_RAW goto :use_windows_proxy

if defined WINDOWS_AUTO_CONFIG_URL (
	set "ECHOSCRIPT_PROXY_SOURCE=windows-auto-config"
	set "ECHOSCRIPT_PROXY_AUTO_CONFIG=%WINDOWS_AUTO_CONFIG_URL%"
	echo [DIAG] Proxy source: Windows automatic proxy config detected: %ECHOSCRIPT_PROXY_AUTO_CONFIG%
	echo [DIAG] No static proxy server was exported to HTTP_PROXY/HTTPS_PROXY.
	goto :after_proxy
)

if /I "%WINDOWS_AUTO_DETECT%"=="0x1" (
	set "ECHOSCRIPT_PROXY_SOURCE=windows-auto-config"
	set "ECHOSCRIPT_PROXY_AUTO_CONFIG=WPAD"
	echo [DIAG] Proxy source: Windows automatic proxy config detected: %ECHOSCRIPT_PROXY_AUTO_CONFIG%
	echo [DIAG] No static proxy server was exported to HTTP_PROXY/HTTPS_PROXY.
	goto :after_proxy
)

echo [DIAG] Proxy source: none detected.
goto :after_proxy

:use_existing_proxy_env
if not defined RAW_HTTP_PROXY set "RAW_HTTP_PROXY=%RAW_HTTPS_PROXY%"
if not defined RAW_HTTPS_PROXY set "RAW_HTTPS_PROXY=%RAW_HTTP_PROXY%"

set "HTTP_PROXY=%RAW_HTTP_PROXY%"
set "HTTPS_PROXY=%RAW_HTTPS_PROXY%"
set "http_proxy=%HTTP_PROXY%"
set "https_proxy=%HTTPS_PROXY%"
set "ECHOSCRIPT_PROXY_SOURCE=environment"

echo [DIAG] Proxy source: environment variables.
echo [DIAG] HTTP_PROXY/HTTPS_PROXY preserved from the current shell.
goto :after_proxy

:use_windows_proxy
for /f "tokens=1,* delims==" %%A in ('powershell -NoProfile -Command "$raw = $env:PROXY_RAW; $http = $null; $https = $null; foreach ($part in ($raw -split ';')) { $segment = $part.Trim(); if (-not $segment) { continue } if ($segment -match '^(?<scheme>[^=]+)=(?<value>.+)$') { $scheme = $Matches['scheme'].Trim().ToLowerInvariant(); $value = $Matches['value'].Trim(); if ($value -and $value -notmatch '^[A-Za-z][A-Za-z0-9+.-]*://') { $value = 'http://' + $value }; if ($scheme -eq 'http') { $http = $value } elseif ($scheme -eq 'https') { $https = $value } } elseif (-not $http -and -not $https) { $value = $segment; if ($value -and $value -notmatch '^[A-Za-z][A-Za-z0-9+.-]*://') { $value = 'http://' + $value }; $http = $value; $https = $value } }; if (-not $http) { $http = $https }; if (-not $https) { $https = $http }; if ($http) { Write-Output ('HTTP_PROXY=' + $http) }; if ($https) { Write-Output ('HTTPS_PROXY=' + $https) }"') do set "%%A=%%B"

set "http_proxy=%HTTP_PROXY%"
set "https_proxy=%HTTPS_PROXY%"
set "ECHOSCRIPT_PROXY_SOURCE=windows-internet-settings"

echo [DIAG] Proxy source: Windows Internet Settings static proxy.
echo [DIAG] HTTP_PROXY/HTTPS_PROXY exported from the system proxy server.

:after_proxy

if not exist "%HF_HOME%" mkdir "%HF_HOME%" >nul 2>&1
if not exist "%HF_HUB_CACHE%" mkdir "%HF_HUB_CACHE%" >nul 2>&1
if not exist "%HF_ASSETS_CACHE%" mkdir "%HF_ASSETS_CACHE%" >nul 2>&1
if not exist "%HF_XET_CACHE%" mkdir "%HF_XET_CACHE%" >nul 2>&1
if not exist "%VOSK_MODELS_ROOT%" mkdir "%VOSK_MODELS_ROOT%" >nul 2>&1

goto :eof
