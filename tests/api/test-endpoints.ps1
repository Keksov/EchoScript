# API contract tests
# Prerequisite: pwsh tests/start-test-orchestrator.ps1
# Run: pwsh tests/api/test-endpoints.ps1

param(
    [switch]$Smoke,
    [ValidateRange(0, 1000)]
    [int]$MaxAudioFiles = 0
)

. "$PSScriptRoot\..\helpers\common.ps1"

function Find-ListedJob {
    param(
        $JobsPayload,
        [string]$JobId
    )

    if ($null -eq $JobsPayload -or $null -eq $JobsPayload.jobs) {
        return $null
    }

    return @($JobsPayload.jobs | Where-Object { [string]$_.job_id -eq $JobId } | Select-Object -First 1)[0]
}

if (-not (Test-OrchestratorRunning)) {
    throw "Test orchestrator is not running"
}

$audioFiles = @(Select-TestAudioFiles -Smoke:$Smoke -MaxAudioFiles $MaxAudioFiles)

Write-TestHeader "GET / health"
$health = Invoke-Api -Method Get -Path "/"
Assert-True "health responds" $health.Ok
Assert-Equal "service name" "echoscript-orchestrator" $health.Data.service
Assert-Equal "health status" "ok" $health.Data.status
Assert-IsArray "running_models is array" $health.Data.running_models

Write-TestHeader "Audio fixtures"
Assert-GreaterThan "audio fixture count" $audioFiles.Count 0
if ($audioFiles.Count -eq 0) {
    Complete-TestRun
}
Write-TestStep "Selected audio fixtures: $($audioFiles.Count)"
if ($Smoke) {
    Write-TestStep "Smoke mode is enabled"
}

foreach ($audioPath in $audioFiles) {
    $audioLabel = Get-TestAudioLabel -AudioPath $audioPath

    Write-TestHeader "POST /add_body [$audioLabel]"
    $addBody = Add-BodyJob -AudioPath $audioPath -Source "api-endpoints-$audioLabel"
    Assert-True "add_body succeeds [$audioLabel]" $addBody.Ok
    Assert-NotNull "add_body returns job_id [$audioLabel]" $addBody.Data.job_id
    if (-not $addBody.Ok) {
        continue
    }
    $bodyJobId = [string]$addBody.Data.job_id

    Write-TestHeader "GET /list_jobs includes created job [$audioLabel]"
    $listedJobs = Get-Jobs
    Assert-True "list_jobs succeeds [$audioLabel]" $listedJobs.Ok
    if ($listedJobs.Ok) {
        $listedBodyJob = Find-ListedJob -JobsPayload $listedJobs.Data -JobId $bodyJobId
        Assert-NotNull "list_jobs includes created job [$audioLabel]" $listedBodyJob
        if ($null -ne $listedBodyJob) {
            Assert-Equal "listed job current status [$audioLabel]" "dispatching" ([string]$listedBodyJob.current_status)
            Assert-Equal "listed job source [$audioLabel]" "api-endpoints-$audioLabel" ([string]$listedBodyJob.source)
            Assert-True "listed job has no result before run [$audioLabel]" (-not [bool]$listedBodyJob.has_result)
        }
    }

    Write-TestHeader "POST /add_file [$audioLabel]"
    $addFile = Add-FileJob -FilePath $audioPath -Model "whisper_podlodka"
    Assert-True "add_file succeeds [$audioLabel]" $addFile.Ok
    Assert-NotNull "add_file returns job_id [$audioLabel]" $addFile.Data.job_id
    if ($addFile.Ok) {
        Assert-Contains "add_file job_id contains model [$audioLabel]" ([string]$addFile.Data.job_id) "whisper_podlodka"
    }

    Write-TestHeader "GET /get_job_status before run [$audioLabel]"
    $statusBefore = Get-JobStatus -JobId $bodyJobId
    Assert-True "status before run succeeds [$audioLabel]" $statusBefore.Ok
    if (-not $statusBefore.Ok) {
        continue
    }
    Assert-IsArray "status before run is array [$audioLabel]" $statusBefore.Data
    Assert-GreaterThan "status has first event [$audioLabel]" $statusBefore.Data.Count 0
    Assert-Equal "first status is dispatching [$audioLabel]" "dispatching" $statusBefore.Data[0].status

    Write-TestHeader "POST /run_job [$audioLabel]"
    $runResult = Start-JobRun -JobId $bodyJobId -Params @{ language = "ru"; timestamps = $true }
    Assert-True "run_job succeeds [$audioLabel]" $runResult.Ok
    if (-not $runResult.Ok) {
        continue
    }
    Assert-Equal "run_job status queued [$audioLabel]" "queued" $runResult.Data.status
    Assert-Equal "run_job queue name [$audioLabel]" "queue" $runResult.Data.queue
    Assert-Equal "run_job target model [$audioLabel]" "whisper_podlodka" $runResult.Data.target_model

    Write-TestHeader "GET /get_job_status after run [$audioLabel]"
    Start-Sleep -Seconds 1
    $statusAfter = Get-JobStatus -JobId $bodyJobId
    Assert-True "status after run succeeds [$audioLabel]" $statusAfter.Ok
    if (-not $statusAfter.Ok) {
        continue
    }
    Assert-IsArray "status after run is array [$audioLabel]" $statusAfter.Data
    Assert-GreaterThan "status count increased [$audioLabel]" $statusAfter.Data.Count 1
    Assert-Contains "status progression contains queued [$audioLabel]" ((Get-StatusNames -Statuses $statusAfter.Data) -join ",") "queued"

    Write-TestHeader "GET /get_job_result after completion [$audioLabel]"
    $waitResult = Wait-ForJobCompletion -JobId $bodyJobId
    Assert-True "job completes [$audioLabel]" $waitResult.Ok
    if ($waitResult.Ok) {
        $result = Get-JobResult -JobId $bodyJobId
        Assert-True "result fetch succeeds [$audioLabel]" $result.Ok
        if ($result.Ok) {
            Assert-NotNull "normalized.text exists [$audioLabel]" $result.Data.normalized.text
            Assert-NotNull "raw.text exists [$audioLabel]" $result.Data.raw.text

            $normalizedOnly = Get-JobResult -JobId $bodyJobId -Type "normalized"
            Assert-True "normalized-only result fetch succeeds [$audioLabel]" $normalizedOnly.Ok
            if ($normalizedOnly.Ok) {
                Assert-NotNull "normalized-only text exists [$audioLabel]" $normalizedOnly.Data.text
                Assert-True "normalized-only omits raw wrapper [$audioLabel]" (-not ($normalizedOnly.Data.PSObject.Properties.Name -contains "raw"))
            }

            $rawOnly = Get-JobResult -JobId $bodyJobId -Type "raw"
            Assert-True "raw-only result fetch succeeds [$audioLabel]" $rawOnly.Ok
            if ($rawOnly.Ok) {
                Assert-NotNull "raw-only text exists [$audioLabel]" $rawOnly.Data.text
                Assert-True "raw-only omits normalized wrapper [$audioLabel]" (-not ($rawOnly.Data.PSObject.Properties.Name -contains "normalized"))
            }

            $plainResult = Get-JobResult -JobId $bodyJobId -Type "plain"
            Assert-True "plain result fetch succeeds [$audioLabel]" $plainResult.Ok
            if ($plainResult.Ok) {
                $plainText = [string]$plainResult.Data
                $normalizedText = [string]$result.Data.normalized.text
                $normalizedPreview = if ($normalizedText.Trim().Length -gt 24) { $normalizedText.Trim().Substring(0, 24) } else { $normalizedText.Trim() }
                Assert-True "plain result is string [$audioLabel]" ($plainResult.Data -is [string])
                Assert-Contains "plain result contains transcript text [$audioLabel]" $plainText $normalizedPreview
            }

            $timestampResult = Get-JobResult -JobId $bodyJobId -Type "timestamp"
            Assert-True "timestamp result fetch succeeds [$audioLabel]" $timestampResult.Ok
            if ($timestampResult.Ok) {
                Assert-True "timestamp result is string [$audioLabel]" ($timestampResult.Data -is [string])
                Assert-Contains "timestamp result contains range marker [$audioLabel]" ([string]$timestampResult.Data) "-->"
            }
        }
        Write-TestStep "Artifacts preserved for job [$audioLabel]: $bodyJobId"
    }
}

Complete-TestRun

