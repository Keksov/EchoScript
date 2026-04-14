# E2E FIFO scheduler test
# Prerequisite: pwsh tests/start-test-orchestrator.ps1
# Run: pwsh tests/e2e/test-queue-fifo.ps1

. "$PSScriptRoot\..\helpers\common.ps1"

if (-not (Test-OrchestratorRunning)) {
    throw "Test orchestrator is not running"
}

$audioFiles = @(Get-TestAudioFiles)

Write-TestHeader "Audio fixtures"
Assert-GreaterThan "audio fixture count" $audioFiles.Count 0
if ($audioFiles.Count -eq 0) {
    Complete-TestRun
}

Write-TestHeader "Create jobs for each audio file"
$jobs = @()
$jobIndex = 0
foreach ($audioPath in $audioFiles) {
    $jobIndex++
    $audioLabel = Get-TestAudioLabel -AudioPath $audioPath

    if (($jobIndex % 2) -eq 0) {
        $createdJob = Add-FileJob -FilePath $audioPath -Model "whisper_podlodka"
        $createdLabel = "file job created [$audioLabel]"
        $inputMethod = "file"
    } else {
        $createdJob = Add-BodyJob -AudioPath $audioPath -Source "fifo-$jobIndex-$audioLabel"
        $createdLabel = "body job created [$audioLabel]"
        $inputMethod = "body"
    }

    Assert-True $createdLabel $createdJob.Ok
    if (-not $createdJob.Ok) {
        continue
    }

    $jobId = [string]$createdJob.Data.job_id
    $jobs += @{
        AudioLabel = $audioLabel
        InputMethod = $inputMethod
        JobId = $jobId
    }
    Write-TestStep "Job $jobIndex [$audioLabel/$inputMethod]: $jobId"
}

if ($jobs.Count -ne $audioFiles.Count) {
    Complete-TestRun
}

Write-TestHeader "Enqueue jobs"
foreach ($job in $jobs) {
    $runResult = Start-JobRun -JobId $job.JobId -Params @{ language = "ru"; timestamps = $true }
    Assert-True "job queued [$($job.AudioLabel)]" $runResult.Ok
}

Write-TestHeader "Wait for all jobs"
$waitResults = @()
foreach ($job in $jobs) {
    $waitResult = Wait-ForJobCompletion -JobId $job.JobId
    Assert-True "job completed [$($job.AudioLabel)]" $waitResult.Ok
    $waitResults += @{
        AudioLabel = $job.AudioLabel
        JobId = $job.JobId
        WaitResult = $waitResult
    }
}

if ((@($waitResults | Where-Object { -not $_.WaitResult.Ok })).Count -eq 0) {
    Write-TestHeader "Status lifecycle"
    $readyEntries = @()

    foreach ($entry in $waitResults) {
        $statusNames = Get-StatusNames -Statuses $entry.WaitResult.Statuses
        $audioLabel = $entry.AudioLabel

        Assert-Equal "first status dispatching [$audioLabel]" "dispatching" $statusNames[0]
        Assert-Contains "contains queued [$audioLabel]" ($statusNames -join ",") "queued"
        Assert-Contains "contains pending [$audioLabel]" ($statusNames -join ",") "pending"
        Assert-Contains "contains processing [$audioLabel]" ($statusNames -join ",") "processing"
        Assert-Equal "final status ready [$audioLabel]" "ready" $statusNames[$statusNames.Count - 1]

        $readyTimestamp = Get-StatusTimestamp -Statuses $entry.WaitResult.Statuses -StatusName "ready"
        Assert-NotNull "ready timestamp [$audioLabel]" $readyTimestamp
        if ($null -ne $readyTimestamp) {
            $readyEntries += @{
                AudioLabel = $audioLabel
                Timestamp = $readyTimestamp
            }
        }
    }

    if ($readyEntries.Count -gt 1) {
        for ($index = 0; $index -lt $readyEntries.Count - 1; $index++) {
            $currentEntry = $readyEntries[$index]
            $nextEntry = $readyEntries[$index + 1]
            Assert-True "FIFO $($currentEntry.AudioLabel) <= $($nextEntry.AudioLabel)" ($currentEntry.Timestamp -le $nextEntry.Timestamp)
        }
    } else {
        Skip-Test "FIFO ordering" "need at least two completed jobs"
    }
}

Write-TestHeader "Artifacts"
foreach ($entry in $waitResults) {
    Write-TestStep "Preserved artifacts for job [$($entry.AudioLabel)]: $($entry.JobId)"
}

Complete-TestRun

