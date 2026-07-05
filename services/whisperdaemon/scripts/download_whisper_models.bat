@echo off
REM ============================================================
REM EchoScript - Download: WhisperDaemon language models (ggml)
REM
REM Language -> model manifest (extensible). Downloads the official ggml build for
REM each requested language into services\whisperdaemon\models\ggml-<model_name>.bin,
REM which is the file name the daemon resolves from --model-name (ggml-<name>.bin).
REM
REM Usage:
REM   download_whisper_models.bat [lang ...]     (default: en)
REM   set WHISPER_MODEL_FORCE=1 to re-download even if present
REM   set WHISPER_MODEL_URL_<LANG> to override a language's source URL
REM
REM Note: ru (whisper_podlodka) is a locally fine-tuned model staged by the
REM convert/stage scripts, not downloaded here.
REM ============================================================
setlocal EnableExtensions

pushd "%~dp0\..\..\.."
if errorlevel 1 (
    echo [ERROR] Failed to enter repository root.
    exit /b 1
)

set "WHISPER_MODEL_LANGS=%*"
if not defined WHISPER_MODEL_LANGS set "WHISPER_MODEL_LANGS=en"

set "WHISPER_MODELS_DIR=services\whisperdaemon\models"
if not exist "%WHISPER_MODELS_DIR%" mkdir "%WHISPER_MODELS_DIR%"

pwsh -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ErrorActionPreference='Stop';" ^
  "$manifest = @{ en = @{ model = 'whisper_en_turbo'; url = 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin'; minMb = 100 }; vad = @{ model = 'silero-v5.1.2'; url = 'https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin'; minMb = 0 } };" ^
  "$modelsDir = Join-Path (Get-Location).Path $env:WHISPER_MODELS_DIR;" ^
  "$force = $env:WHISPER_MODEL_FORCE -match '^(?i:1|true|yes|on)$';" ^
  "$langs = ($env:WHISPER_MODEL_LANGS -split '\s+') | Where-Object { $_ };" ^
  "$fail = 0;" ^
  "foreach ($lang in $langs) {" ^
  "  $key = $lang.ToLower();" ^
  "  if (-not $manifest.ContainsKey($key)) { Write-Host ('[ERROR] Unknown language in manifest: ' + $lang); $fail = 1; continue }" ^
  "  $entry = $manifest[$key];" ^
  "  $override = [Environment]::GetEnvironmentVariable('WHISPER_MODEL_URL_' + $key.ToUpper());" ^
  "  $url = if ($override) { $override } else { $entry.url };" ^
  "  $target = Join-Path $modelsDir ('ggml-' + $entry.model + '.bin');" ^
  "  if ((Test-Path -LiteralPath $target) -and -not $force) { $mb = [math]::Round((Get-Item -LiteralPath $target).Length / 1MB, 1); Write-Host ('[SKIP] ' + $lang + ' -> ' + $entry.model + ' already present (' + $mb + ' MB): ' + $target); continue }" ^
  "  Write-Host ('[INFO] Downloading ' + $lang + ' -> ' + $entry.model); Write-Host ('[INFO]   from ' + $url); Write-Host ('[INFO]   to   ' + $target);" ^
  "  $tmp = $target + '.download';" ^
  "  if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }" ^
  "  try { Invoke-WebRequest -Uri $url -OutFile $tmp -Headers @{ 'User-Agent' = 'EchoScript-WhisperDaemon-Downloader' } } catch { Write-Host ('[ERROR] Download failed for ' + $lang + ': ' + $_.Exception.Message); if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }; $fail = 1; continue }" ^
  "  $len = (Get-Item -LiteralPath $tmp).Length;" ^
  "  $minMb = if ($entry.ContainsKey('minMb')) { [long]$entry.minMb } else { 100 };" ^
  "  if (($len -lt 100KB) -or ($len -lt ($minMb * 1MB))) { Write-Host ('[ERROR] Downloaded file suspiciously small (' + $len + ' bytes, min ' + $minMb + ' MB) for ' + $lang); Remove-Item -LiteralPath $tmp -Force; $fail = 1; continue }" ^
  "  Move-Item -LiteralPath $tmp -Destination $target -Force;" ^
  "  $mb = [math]::Round($len / 1MB, 1); Write-Host ('[OK] ' + $lang + ' -> ' + $entry.model + ' ready (' + $mb + ' MB)');" ^
  "}" ^
  "if ($fail -ne 0) { exit 1 }"

set "EXIT_CODE=%ERRORLEVEL%"
popd
if %EXIT_CODE% neq 0 (
    echo [ERROR] One or more whisper model downloads failed.
) else (
    echo [OK] Whisper language models ready.
)
exit /b %EXIT_CODE%
