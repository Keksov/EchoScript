# Vosk API smoke for vosk_ru and vosk_en
# Prerequisite: pwsh tests/start-test-orchestrator.ps1
# Run: pwsh tests/api/test-vosk-smoke.ps1

param(
    [string]$AudioPath = "",
    [string]$RuAudioPath = "",
    [string]$EnAudioPath = "",
    [int]$TimeoutSeconds = 600,
    [int]$IntervalSeconds = 3
)

. "$PSScriptRoot\..\helpers\common.ps1"

if (-not (Test-OrchestratorRunning)) {
    throw "Test orchestrator is not running"
}

$fallbackAudioPath = if ($AudioPath.Length -gt 0) {
    [System.IO.Path]::GetFullPath($AudioPath)
} else {
    [System.IO.Path]::GetFullPath((Get-PrimaryTestAudioFile))
}

$resolvedRuAudioPath = if ($RuAudioPath.Length -gt 0) {
    [System.IO.Path]::GetFullPath($RuAudioPath)
} else {
    $fallbackAudioPath
}

$resolvedEnAudioPath = if ($EnAudioPath.Length -gt 0) {
    [System.IO.Path]::GetFullPath($EnAudioPath)
} else {
    $fallbackAudioPath
}

$models = @(
    @{
        Name = "vosk_ru"
        Language = "ru"
        RawModel = "vosk-model-ru-0.42"
        AudioPath = $resolvedRuAudioPath
    },
    @{
        Name = "vosk_en"
        Language = "en"
        RawModel = "vosk-model-en-us-0.42-gigaspeech"
        AudioPath = $resolvedEnAudioPath
    }
)

foreach ($model in $models) {
    $modelName = [string]$model.Name
    $language = [string]$model.Language
    $rawModelName = [string]$model.RawModel
    $audioPath = [string]$model.AudioPath
    $audioLabel = Get-TestAudioLabel -AudioPath $audioPath

    $run = Invoke-TestTranscriptionFlow `
        -Label "$modelName smoke [$audioLabel]" `
        -InputMethod body `
        -AudioPath $audioPath `
        -Model $modelName `
        -Params @{ language = $language; timestamps = $true; word_timestamps = $true } `
        -TimeoutSeconds $TimeoutSeconds `
        -IntervalSeconds $IntervalSeconds

    Assert-NotNull "$modelName smoke payload exists [$audioLabel]" $run
    if ($null -eq $run -or $null -eq $run.Result) {
        continue
    }

    $segments = @($run.Result.normalized.segments)
    Assert-GreaterThan "$modelName segment count [$audioLabel]" $segments.Count 0
    Assert-Equal "$modelName normalized language [$audioLabel]" $language ([string]$run.Result.normalized.language)
    Assert-NotNull "$modelName normalized text [$audioLabel]" $run.Result.normalized.text

    if ($segments.Count -gt 0) {
        $firstSegment = $segments[0]
        $firstSegmentWords = @($firstSegment.words)
        Assert-NotNull "$modelName first segment text [$audioLabel]" $firstSegment.text
        Assert-NotNull "$modelName first segment start [$audioLabel]" $firstSegment.start
        Assert-NotNull "$modelName first segment end [$audioLabel]" $firstSegment.end
        Assert-IsArray "$modelName first segment words array [$audioLabel]" $firstSegment.words
        Assert-GreaterThan "$modelName first segment words count [$audioLabel]" $firstSegmentWords.Count 0
    }

    $rawKeys = @($run.Result.raw.PSObject.Properties.Name)
    Assert-Contains "$modelName raw contains recognizer_results [$audioLabel]" ($rawKeys -join ",") "recognizer_results"
    Assert-Contains "$modelName raw contains model [$audioLabel]" ($rawKeys -join ",") "model"
    Assert-Equal "$modelName raw model name [$audioLabel]" $rawModelName ([string]$run.Result.raw.model)
    Assert-IsArray "$modelName raw recognizer results array [$audioLabel]" $run.Result.raw.recognizer_results

    $defaultNormalizedText = ([string]$run.Result.normalized.text).Trim()
    $defaultRawText = ([string]$run.Result.raw.text).Trim()
    $defaultSpeakerPayloads = @($run.Result.raw.recognizer_results | Where-Object { $_.PSObject.Properties.Name -contains "spk" })
    Assert-Equal "$modelName punctuation disabled by default for API jobs [$audioLabel]" $defaultRawText $defaultNormalizedText
    Assert-Equal "$modelName speaker embeddings disabled by default for API jobs [$audioLabel]" 0 $defaultSpeakerPayloads.Count

    $normalizedOnly = Get-JobResult -JobId $run.JobId -Type "normalized"
    Assert-True "$modelName normalized-only fetch succeeds [$audioLabel]" $normalizedOnly.Ok
    if ($normalizedOnly.Ok) {
        Assert-IsArray "$modelName normalized-only segments array [$audioLabel]" $normalizedOnly.Data.segments
    }

    $rawOnly = Get-JobResult -JobId $run.JobId -Type "raw"
    Assert-True "$modelName raw-only fetch succeeds [$audioLabel]" $rawOnly.Ok
    if ($rawOnly.Ok) {
        Assert-Equal "$modelName raw-only model name [$audioLabel]" $rawModelName ([string]$rawOnly.Data.model)
        Assert-IsArray "$modelName raw-only recognizer results array [$audioLabel]" $rawOnly.Data.recognizer_results
    }

    $plainResult = Get-JobResult -JobId $run.JobId -Type "plain"
    Assert-True "$modelName plain result fetch succeeds [$audioLabel]" $plainResult.Ok
    if ($plainResult.Ok) {
        Assert-True "$modelName plain result is string [$audioLabel]" ($plainResult.Data -is [string])
        Assert-Contains "$modelName plain result contains transcript [$audioLabel]" ([string]$plainResult.Data) ([string]$run.Result.normalized.text).Trim().Substring(0, [Math]::Min(24, ([string]$run.Result.normalized.text).Trim().Length))
    }

    $timestampResult = Get-JobResult -JobId $run.JobId -Type "timestamp"
    Assert-True "$modelName timestamp result fetch succeeds [$audioLabel]" $timestampResult.Ok
    if ($timestampResult.Ok) {
        Assert-True "$modelName timestamp result is string [$audioLabel]" ($timestampResult.Data -is [string])
        Assert-Contains "$modelName timestamp result contains range marker [$audioLabel]" ([string]$timestampResult.Data) "-->"
    }

    $noTimestampRun = Invoke-TestTranscriptionFlow `
        -Label "$modelName timestamps disabled [$audioLabel]" `
        -InputMethod body `
        -AudioPath $audioPath `
        -Model $modelName `
        -Params @{ language = $language; timestamps = $false; word_timestamps = $true } `
        -TimeoutSeconds $TimeoutSeconds `
        -IntervalSeconds $IntervalSeconds

    Assert-NotNull "$modelName no-timestamps payload exists [$audioLabel]" $noTimestampRun
    if ($null -eq $noTimestampRun -or $null -eq $noTimestampRun.Result) {
        continue
    }

    Assert-Equal "$modelName no-timestamps segment count [$audioLabel]" 0 (@($noTimestampRun.Result.normalized.segments)).Count
    Assert-NotNull "$modelName no-timestamps text [$audioLabel]" $noTimestampRun.Result.normalized.text

    $phaseTwoRun = Invoke-TestTranscriptionFlow `
        -Label "$modelName phase2 opt-in [$audioLabel]" `
        -InputMethod body `
        -AudioPath $audioPath `
        -Model $modelName `
        -Params @{ language = $language; timestamps = $true; word_timestamps = $true; punctuation = $true; speaker_embeddings = $true } `
        -TimeoutSeconds $TimeoutSeconds `
        -IntervalSeconds $IntervalSeconds

    Assert-NotNull "$modelName phase2 opt-in payload exists [$audioLabel]" $phaseTwoRun
    if ($null -eq $phaseTwoRun -or $null -eq $phaseTwoRun.Result) {
        continue
    }

    $phaseTwoNormalizedText = ([string]$phaseTwoRun.Result.normalized.text).Trim()
    $phaseTwoRawText = ([string]$phaseTwoRun.Result.raw.text).Trim()
    $phaseTwoSpeakerPayloads = @($phaseTwoRun.Result.raw.recognizer_results | Where-Object { $_.PSObject.Properties.Name -contains "spk" })
    Assert-True "$modelName punctuation opt-in affects normalized text [$audioLabel]" ($phaseTwoNormalizedText.Length -gt 0 -and ($phaseTwoNormalizedText -ne $phaseTwoRawText -or $phaseTwoNormalizedText -match '[\.!\?]$'))
    Assert-GreaterThan "$modelName speaker embeddings opt-in returns payloads [$audioLabel]" $phaseTwoSpeakerPayloads.Count 0
    if ($phaseTwoSpeakerPayloads.Count -gt 0) {
        Assert-IsArray "$modelName speaker embedding vector is an array [$audioLabel]" $phaseTwoSpeakerPayloads[0].spk
        Assert-NotNull "$modelName speaker embedding frame count exists [$audioLabel]" $phaseTwoSpeakerPayloads[0].spk_frames
    }
}

Complete-TestRun
