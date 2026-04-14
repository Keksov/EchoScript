# E2E input format coverage for body/file across all audio fixtures
# Prerequisite: pwsh tests/start-test-orchestrator.ps1
# Run: pwsh tests/e2e/test-input-formats.ps1

. "$PSScriptRoot\..\helpers\common.ps1"

if (-not (Test-OrchestratorRunning)) {
    throw "Test orchestrator is not running"
}

$audioFiles = @(Get-TestAudioFiles)
$cases = @()

Write-TestHeader "Audio fixtures"
Assert-GreaterThan "audio fixture count" $audioFiles.Count 0
if ($audioFiles.Count -eq 0) {
    Complete-TestRun
}

foreach ($audioPath in $audioFiles) {
    $audioLabel = Get-TestAudioLabel -AudioPath $audioPath
    $cases += @{
        Label = "body + $audioLabel + default model"
        InputMethod = "body"
        AudioPath = $audioPath
        Model = ""
    }
    $cases += @{
        Label = "file + $audioLabel + explicit model"
        InputMethod = "file"
        AudioPath = $audioPath
        Model = "whisper_podlodka"
    }
}

foreach ($case in $cases) {
    $run = Invoke-TestTranscriptionFlow -Label $case.Label -InputMethod $case.InputMethod -AudioPath $case.AudioPath -Model $case.Model -Params @{ language = "ru"; timestamps = $true }
    if ($null -eq $run -or $null -eq $run.Result) {
        continue
    }

    Assert-NotNull "$($case.Label) - normalized text" $run.Result.normalized.text
    Assert-NotNull "$($case.Label) - raw text" $run.Result.raw.text
    Assert-IsArray "$($case.Label) - segments array" $run.Result.normalized.segments
    Assert-GreaterThan "$($case.Label) - segment count" (@($run.Result.normalized.segments)).Count 0
    Assert-Equal "$($case.Label) - target model" "whisper_podlodka" $run.RunResult.target_model

    Write-TestStep "Artifacts preserved for job [$((Get-TestAudioLabel -AudioPath $case.AudioPath))]: $($run.JobId)"
}

Complete-TestRun


