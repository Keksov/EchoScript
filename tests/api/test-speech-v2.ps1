# Buffered speech v2 smoke for Russian command and dictation modes.
# Prerequisite: pwsh tests/start-test-orchestrator.ps1
# Run: pwsh tests/api/test-speech-v2.ps1

param(
    [string]$CommandAudioPath = "",
    [string]$DictationAudioPath = "",
    [string]$NonCommandAudioPath = "",
    [int]$TimeoutSeconds = 300
)

. "$PSScriptRoot\..\helpers\common.ps1"

function Invoke-SpeechV2Recognize {
    param(
        [string]$Mode,
        [string]$AudioPath,
        [int]$TimeoutSeconds,
        [switch]$ExpectError
    )

    $audioBytes = [System.IO.File]::ReadAllBytes($AudioPath)
    $uriBuilder = [System.UriBuilder]::new([uri](Get-TestBaseUrl))
    $uriBuilder.Path = "/api/v2/speech/recognize"
    $uriBuilder.Query = "mode=$([uri]::EscapeDataString($Mode))&language=ru"

    try {
        $response = Invoke-WebRequest -Uri $uriBuilder.Uri.AbsoluteUri -Method Post -Body $audioBytes -ContentType "application/octet-stream" -TimeoutSec $TimeoutSeconds -SkipHttpErrorCheck
    } catch {
        return @{
            Ok = $false
            StatusCode = 0
            Error = $_.Exception.Message
        }
    }

    $payload = $null
    if ($null -ne $response.Content -and $response.Content.Length -gt 0) {
        try {
            $payload = $response.Content | ConvertFrom-Json -NoEnumerate
        } catch {
            $payload = $response.Content
        }
    }

    if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 300) {
        return @{
            Ok = $true
            Data = $payload
            StatusCode = [int]$response.StatusCode
        }
    }

    if ($ExpectError) {
        return @{
            Ok = $false
            Error = $payload
            StatusCode = [int]$response.StatusCode
        }
    }

    return @{
        Ok = $false
        Error = $payload
        StatusCode = [int]$response.StatusCode
    }
}

function Resolve-PreferredAudioPath {
    param(
        [string]$RequestedPath,
        [string]$PreferredFileName
    )

    if ($RequestedPath.Length -gt 0) {
        return [System.IO.Path]::GetFullPath($RequestedPath)
    }

    $preferredPath = Join-Path (Join-Path (Get-TestProjectRoot) "tests") (Join-Path "audio" $PreferredFileName)
    if (Test-Path $preferredPath) {
        return [System.IO.Path]::GetFullPath($preferredPath)
    }

    return [System.IO.Path]::GetFullPath((Get-PrimaryTestAudioFile))
}

function Resolve-DefaultCommandAudioPath {
    $commandAudioRoot = Join-Path (Join-Path (Join-Path (Get-TestProjectRoot) "tests") "audio") "commands\ru"
    if (-not (Test-Path $commandAudioRoot)) {
        return ""
    }

    $commandAudioFile = Get-ChildItem -Path $commandAudioRoot -File | Where-Object {
        $Script:SupportedAudioExtensions -contains $_.Extension.ToLowerInvariant()
    } | Sort-Object Name | Select-Object -First 1

    if ($null -eq $commandAudioFile) {
        return ""
    }

    return [System.IO.Path]::GetFullPath($commandAudioFile.FullName)
}

if (-not (Test-OrchestratorRunning)) {
    throw "Test orchestrator is not running"
}

$resolvedCommandAudioPath = if ($CommandAudioPath.Length -gt 0) {
    Resolve-PreferredAudioPath -RequestedPath $CommandAudioPath -PreferredFileName ""
} else {
    $defaultCommandAudioPath = Resolve-DefaultCommandAudioPath
    if ($defaultCommandAudioPath.Length -gt 0) {
        $defaultCommandAudioPath
    } else {
        Resolve-PreferredAudioPath -RequestedPath $CommandAudioPath -PreferredFileName "Вверх, вниз.ogg"
    }
}
$resolvedDictationAudioPath = Resolve-PreferredAudioPath -RequestedPath $DictationAudioPath -PreferredFileName "Мама мыла раму.ogg"
$resolvedNonCommandAudioPath = Resolve-PreferredAudioPath -RequestedPath $NonCommandAudioPath -PreferredFileName "Мама мыла раму.ogg"

Assert-True "command audio exists" (Test-Path $resolvedCommandAudioPath)
Assert-True "dictation audio exists" (Test-Path $resolvedDictationAudioPath)
Assert-True "non-command audio exists" (Test-Path $resolvedNonCommandAudioPath)
if (-not (Test-Path $resolvedCommandAudioPath) -or -not (Test-Path $resolvedDictationAudioPath) -or -not (Test-Path $resolvedNonCommandAudioPath)) {
    Complete-TestRun
}

Write-TestHeader "POST /api/v2/speech/recognize command"
$commandResponse = Invoke-SpeechV2Recognize -Mode "command" -AudioPath $resolvedCommandAudioPath -TimeoutSeconds $TimeoutSeconds
Assert-True "command request succeeds" $commandResponse.Ok
if (-not $commandResponse.Ok) {
    Write-TestStep "command failure: status=$($commandResponse.StatusCode) error=$($commandResponse.Error | ConvertTo-Json -Compress)"
}
if ($commandResponse.Ok) {
    Assert-Equal "command returns 200" 200 $commandResponse.StatusCode
    Assert-Equal "command mode is preserved" "command" ([string]$commandResponse.Data.mode)
    Assert-Equal "command transport is buffered_http" "buffered_http" ([string]$commandResponse.Data.transport)
    Assert-Equal "command target model is vosk_ru_cmd" "vosk_ru_cmd" ([string]$commandResponse.Data.target_model)
    Assert-Equal "command status is matched" "matched" ([string]$commandResponse.Data.command_status)
    Assert-True "command result is final" ([bool]$commandResponse.Data.is_final)
    Assert-Equal "command language is ru" "ru" ([string]$commandResponse.Data.language)
    Assert-NotNull "command text exists" $commandResponse.Data.text
    Assert-NotNull "command normalized text exists" $commandResponse.Data.normalized.text
    Assert-NotNull "command raw text exists" $commandResponse.Data.raw.text
    Assert-Equal "command normalized text matches top-level text" ([string]$commandResponse.Data.normalized.text) ([string]$commandResponse.Data.text)
    Assert-Equal "command leaves punctuation disabled" ([string]$commandResponse.Data.raw.text).Trim() ([string]$commandResponse.Data.normalized.text).Trim()
}

Write-TestHeader "POST /api/v2/speech/recognize command fallback for non-command speech"
$nonCommandResponse = Invoke-SpeechV2Recognize -Mode "command" -AudioPath $resolvedNonCommandAudioPath -TimeoutSeconds $TimeoutSeconds
Assert-True "non-command request succeeds" $nonCommandResponse.Ok
if (-not $nonCommandResponse.Ok) {
    Write-TestStep "non-command failure: status=$($nonCommandResponse.StatusCode) error=$($nonCommandResponse.Error | ConvertTo-Json -Compress)"
}
if ($nonCommandResponse.Ok) {
    Assert-Equal "non-command returns 200" 200 $nonCommandResponse.StatusCode
    Assert-Equal "non-command mode is preserved" "command" ([string]$nonCommandResponse.Data.mode)
    Assert-Equal "non-command transport is buffered_http" "buffered_http" ([string]$nonCommandResponse.Data.transport)
    Assert-Equal "non-command falls back to vosk_ru" "vosk_ru" ([string]$nonCommandResponse.Data.target_model)
    Assert-Equal "non-command status is not_command" "not_command" ([string]$nonCommandResponse.Data.command_status)
    Assert-True "non-command result is final" ([bool]$nonCommandResponse.Data.is_final)
    Assert-Equal "non-command language is ru" "ru" ([string]$nonCommandResponse.Data.language)
    Assert-NotNull "non-command text exists" $nonCommandResponse.Data.text
    Assert-NotNull "non-command normalized text exists" $nonCommandResponse.Data.normalized.text
    Assert-NotNull "non-command raw text exists" $nonCommandResponse.Data.raw.text
    Assert-IsArray "non-command segments array exists" $nonCommandResponse.Data.segments
    Assert-GreaterThan "non-command segment count is positive" (@($nonCommandResponse.Data.segments)).Count 0
    Assert-True "non-command transcript is not empty" (([string]$nonCommandResponse.Data.text).Trim().Length -gt 0)
}

Write-TestHeader "POST /api/v2/speech/recognize dictation"
$dictationResponse = Invoke-SpeechV2Recognize -Mode "dictation" -AudioPath $resolvedDictationAudioPath -TimeoutSeconds $TimeoutSeconds
Assert-True "dictation request succeeds" $dictationResponse.Ok
if (-not $dictationResponse.Ok) {
    Write-TestStep "dictation failure: status=$($dictationResponse.StatusCode) error=$($dictationResponse.Error | ConvertTo-Json -Compress)"
}
if ($dictationResponse.Ok) {
    Assert-Equal "dictation returns 200" 200 $dictationResponse.StatusCode
    Assert-Equal "dictation mode is preserved" "dictation" ([string]$dictationResponse.Data.mode)
    Assert-Equal "dictation transport is buffered_http" "buffered_http" ([string]$dictationResponse.Data.transport)
    Assert-Equal "dictation target model is vosk_ru" "vosk_ru" ([string]$dictationResponse.Data.target_model)
    Assert-Null "dictation command status is empty" $dictationResponse.Data.command_status
    Assert-True "dictation result is final" ([bool]$dictationResponse.Data.is_final)
    Assert-Equal "dictation language is ru" "ru" ([string]$dictationResponse.Data.language)
    Assert-NotNull "dictation text exists" $dictationResponse.Data.text
    Assert-NotNull "dictation normalized text exists" $dictationResponse.Data.normalized.text
    Assert-NotNull "dictation raw text exists" $dictationResponse.Data.raw.text
    Assert-IsArray "dictation segments array exists" $dictationResponse.Data.segments
    Assert-GreaterThan "dictation segment count is positive" (@($dictationResponse.Data.segments)).Count 0

    $dictationNormalizedText = ([string]$dictationResponse.Data.normalized.text).Trim()
    $dictationRawText = ([string]$dictationResponse.Data.raw.text).Trim()
    Assert-True "dictation applies punctuation in final text" ($dictationNormalizedText.Length -gt 0 -and ($dictationNormalizedText -ne $dictationRawText -or $dictationNormalizedText -match '[\.!\?]$'))
}

Write-TestHeader "POST /api/v2/speech/recognize rejects invalid mode"
$invalidModeResponse = Invoke-SpeechV2Recognize -Mode "invalid" -AudioPath $resolvedCommandAudioPath -TimeoutSeconds 30 -ExpectError
Assert-True "invalid mode returns non-2xx" (-not $invalidModeResponse.Ok)
Assert-Equal "invalid mode returns 400" 400 $invalidModeResponse.StatusCode

Complete-TestRun
