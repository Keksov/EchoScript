# API full-cycle integration tests via Bun orchestrator
# Prerequisite: pwsh tests/start-test-orchestrator.ps1
# Run: pwsh tests/api/test-full-cycle.ps1

param(
    [switch]$Smoke,
    [ValidateRange(0, 1000)]
    [int]$MaxAudioFiles = 0
)

. "$PSScriptRoot\..\helpers\common.ps1"

if (-not (Test-OrchestratorRunning)) {
    throw "Test orchestrator is not running"
}

$audioFiles = @(Select-TestAudioFiles -Smoke:$Smoke -MaxAudioFiles $MaxAudioFiles)

Write-TestHeader "Audio fixtures"
Assert-GreaterThan "audio fixture count" $audioFiles.Count 0
if ($audioFiles.Count -eq 0) {
    Complete-TestRun
}
Write-TestStep "Selected audio fixtures: $($audioFiles.Count)"
if ($Smoke) {
    Write-TestStep "Smoke mode is enabled"
}

$cases = @()
foreach ($audioPath in $audioFiles) {
    $audioLabel = Get-TestAudioLabel -AudioPath $audioPath

    $cases += @{
        Label = "body + $audioLabel"
        InputMethod = "body"
        AudioPath = $audioPath
        Model = ""
        Params = @{ language = "ru"; timestamps = $true; word_timestamps = $false }
    }

    $cases += @{
        Label = "file + $audioLabel"
        InputMethod = "file"
        AudioPath = $audioPath
        Model = "whisper_podlodka"
        Params = @{ language = "ru"; timestamps = $true; word_timestamps = $false }
    }
}

foreach ($case in $cases) {
    $label = [string]$case.Label
    Write-TestHeader "Full API cycle [$label]"

    $health = Invoke-Api -Method Get -Path "/"
    Assert-True "$label - health responds" $health.Ok
    if ($health.Ok) {
        Assert-Equal "$label - health status" "ok" $health.Data.status
    }

    if ($case.InputMethod -eq "body") {
        $created = Add-BodyJob -AudioPath $case.AudioPath -Model $case.Model -Source "full-cycle-$label"
        Assert-Equal "$label - add_body returns 201" 201 $created.StatusCode
    } else {
        $created = Add-FileJob -FilePath $case.AudioPath -Model $case.Model
        Assert-Equal "$label - add_file returns 201" 201 $created.StatusCode
    }

    Assert-True "$label - create job succeeds" $created.Ok
    Assert-NotNull "$label - created job_id" $created.Data.job_id
    if (-not $created.Ok) {
        continue
    }

    $jobId = [string]$created.Data.job_id
    Write-TestStep "Job ID [$label]: $jobId"

    $statusBeforeRun = Get-JobStatus -JobId $jobId
    Assert-True "$label - get_job_status before run succeeds" $statusBeforeRun.Ok
    if ($statusBeforeRun.Ok) {
        Assert-IsArray "$label - status before run is array" $statusBeforeRun.Data
        Assert-GreaterThan "$label - status before run has events" $statusBeforeRun.Data.Count 0
        Assert-Equal "$label - first status is dispatching" "dispatching" $statusBeforeRun.Data[0].status
    }

    $runResult = Start-JobRun -JobId $jobId -Params $case.Params
    Assert-True "$label - run_job succeeds" $runResult.Ok
    Assert-Equal "$label - run_job returns 202" 202 $runResult.StatusCode
    if (-not $runResult.Ok) {
        continue
    }

    Assert-Equal "$label - run_job status is queued" "queued" $runResult.Data.status
    Assert-Equal "$label - run_job queue is queue" "queue" $runResult.Data.queue
    Assert-NotNull "$label - run_job target model" $runResult.Data.target_model

    $waitResult = Wait-ForJobCompletion -JobId $jobId
    Assert-True "$label - wait_for_job_completion succeeds" $waitResult.Ok
    if (-not $waitResult.Ok) {
        continue
    }

    $statusAfterRun = Get-JobStatus -JobId $jobId
    Assert-True "$label - get_job_status after run succeeds" $statusAfterRun.Ok
    if ($statusAfterRun.Ok) {
        $statusNames = (Get-StatusNames -Statuses $statusAfterRun.Data) -join ","
        Assert-Contains "$label - status includes queued" $statusNames "queued"
        Assert-Contains "$label - status includes pending" $statusNames "pending"
        Assert-Contains "$label - status includes processing" $statusNames "processing"
        Assert-Contains "$label - status includes ready" $statusNames "ready"
    }

    $result = Get-JobResult -JobId $jobId
    Assert-True "$label - get_job_result succeeds" $result.Ok
    if ($result.Ok) {
        Assert-NotNull "$label - normalized text exists" $result.Data.normalized.text
        Assert-NotNull "$label - raw text exists" $result.Data.raw.text
        Assert-IsArray "$label - normalized segments is array" $result.Data.normalized.segments
    }

    $deleted = Remove-Job -JobId $jobId
    Assert-Equal "$label - delete_job returns 200" 200 $deleted.StatusCode
    if ($deleted.Ok) {
        Assert-True "$label - delete_job deleted flag is true" ([bool]$deleted.Data.deleted)
    }

    $statusAfterDelete = Invoke-Api -Method Get -Path "/get_job_status" -Query @{ job_id = $jobId } -ExpectError
    Assert-Equal "$label - get_job_status after delete returns 404" 404 $statusAfterDelete.StatusCode

    $resultAfterDelete = Invoke-Api -Method Get -Path "/get_job_result" -Query @{ job_id = $jobId } -ExpectError
    Assert-Equal "$label - get_job_result after delete returns 404" 404 $resultAfterDelete.StatusCode

    $deleteAgain = Remove-Job -JobId $jobId
    Assert-Equal "$label - second delete returns 404" 404 $deleteAgain.StatusCode
}

Complete-TestRun
