# API negative tests
# Prerequisite: pwsh tests/start-test-orchestrator.ps1
# Run: pwsh tests/api/test-errors.ps1

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

$primaryAudioFile = [string]$audioFiles[0]
$activeDeleteAudioFile = [string](@($audioFiles | Sort-Object { (Get-Item $_).Length } -Descending | Select-Object -First 1)[0])

Write-TestHeader "POST /add_body with empty payload"
$emptyBody = Invoke-Api -Method Post -Path "/add_body" -RawBody ([byte[]]@()) -ExpectError
Assert-Equal "empty body returns 400" 400 $emptyBody.StatusCode

Write-TestHeader "POST /add_body with unknown model"
$audioBytes = [System.IO.File]::ReadAllBytes($primaryAudioFile)
$unknownModel = Invoke-Api -Method Post -Path "/add_body" -Query @{ model = "unknown_model" } -RawBody $audioBytes -ExpectError
Assert-Equal "unknown model returns 400" 400 $unknownModel.StatusCode

Write-TestHeader "POST /add_file with missing file"
$missingFile = Invoke-Api -Method Post -Path "/add_file" -Body @{ path = "C:\missing\audio.wav" } -ExpectError
Assert-Equal "missing file returns 400" 400 $missingFile.StatusCode

Write-TestHeader "POST /add_file outside allowed roots"
$systemNotepadPath = Join-Path $env:WINDIR "System32\notepad.exe"
if (Test-Path $systemNotepadPath) {
    $outsideAllowedRoot = Invoke-Api -Method Post -Path "/add_file" -Body @{ path = $systemNotepadPath } -ExpectError
    Assert-Equal "outside allowed roots returns 400" 400 $outsideAllowedRoot.StatusCode
} else {
    Skip-Test "outside allowed roots returns 400" "System notepad executable was not found"
}

Write-TestHeader "POST /add_file with empty path"
$emptyPath = Invoke-Api -Method Post -Path "/add_file" -Body @{ path = "" } -ExpectError
Assert-Equal "empty path returns 400" 400 $emptyPath.StatusCode

Write-TestHeader "POST /add_file with unknown model"
$badFileModel = Invoke-Api -Method Post -Path "/add_file" -Body @{ path = $primaryAudioFile; model = "unknown_model" } -ExpectError
Assert-Equal "unknown add_file model returns 400" 400 $badFileModel.StatusCode

Write-TestHeader "POST /run_job with missing job"
$missingJob = Invoke-Api -Method Post -Path "/run_job" -Body @{ job_id = "0_0_fake" } -ExpectError
Assert-Equal "missing job returns 404" 404 $missingJob.StatusCode

Write-TestHeader "POST /run_job with empty job_id"
$emptyJobId = Invoke-Api -Method Post -Path "/run_job" -Body @{ job_id = "" } -ExpectError
Assert-Equal "empty job_id returns 400" 400 $emptyJobId.StatusCode

Write-TestHeader "POST /run_job with path traversal job_id"
$pathTraversalJob = Invoke-Api -Method Post -Path "/run_job" -Body @{ job_id = "..\..\config_x_y" } -ExpectError
Assert-Equal "path traversal job_id returns 400" 400 $pathTraversalJob.StatusCode

Write-TestHeader "GET /get_job_status without job_id"
$statusMissingId = Invoke-Api -Method Get -Path "/get_job_status" -ExpectError
Assert-Equal "missing job_id for status returns 400" 400 $statusMissingId.StatusCode

Write-TestHeader "GET /get_job_status for missing job"
$statusMissingJob = Invoke-Api -Method Get -Path "/get_job_status" -Query @{ job_id = "0_0_fake" } -ExpectError
Assert-Equal "missing job status returns 404" 404 $statusMissingJob.StatusCode

Write-TestHeader "GET /get_job_status with path traversal job_id"
$statusTraversalJob = Invoke-Api -Method Get -Path "/get_job_status" -Query @{ job_id = "../../config_x_y" } -ExpectError
Assert-Equal "path traversal status returns 400" 400 $statusTraversalJob.StatusCode

Write-TestHeader "GET /get_job_result without job_id"
$resultMissingId = Invoke-Api -Method Get -Path "/get_job_result" -ExpectError
Assert-Equal "missing job_id for result returns 400" 400 $resultMissingId.StatusCode

Write-TestHeader "GET /get_job_result before completion"
$createdJob = Add-BodyJob -AudioPath $primaryAudioFile -Source "error-test"
Assert-True "setup job for result precheck succeeds" $createdJob.Ok
if ($createdJob.Ok) {
    $createdJobId = [string]$createdJob.Data.job_id
    $resultBeforeReady = Invoke-Api -Method Get -Path "/get_job_result" -Query @{ job_id = $createdJobId } -ExpectError
    Assert-Equal "result before ready returns 404" 404 $resultBeforeReady.StatusCode

    $deleteSetupJob = Remove-Job -JobId $createdJobId
    Assert-Equal "cleanup precheck job returns 200" 200 $deleteSetupJob.StatusCode
}

Write-TestHeader "GET /get_job_result with path traversal job_id"
$resultTraversalJob = Invoke-Api -Method Get -Path "/get_job_result" -Query @{ job_id = "..\..\config_x_y" } -ExpectError
Assert-Equal "path traversal result returns 400" 400 $resultTraversalJob.StatusCode

Write-TestHeader "GET /get_job_result with unsupported type"
$resultUnsupportedType = Invoke-Api -Method Get -Path "/get_job_result" -Query @{ job_id = "0_0_fake"; type = "unsupported" } -ExpectError
Assert-Equal "unsupported result type returns 400" 400 $resultUnsupportedType.StatusCode

Write-TestHeader "DELETE /delete_job without job_id"
$deleteMissingId = Invoke-Api -Method Delete -Path "/delete_job" -ExpectError
Assert-Equal "missing job_id for delete returns 400" 400 $deleteMissingId.StatusCode

Write-TestHeader "DELETE /delete_job for missing job"
$deleteMissingJob = Remove-Job -JobId "0_0_fake"
Assert-Equal "missing delete returns 404" 404 $deleteMissingJob.StatusCode

Write-TestHeader "DELETE /delete_job for active job"
if ($Smoke) {
    Skip-Test "delete active job returns 409" "Smoke mode skips long-running active-job delete coverage"
} else {
    $activeDeleteJob = Add-BodyJob -AudioPath $activeDeleteAudioFile -Source "active-delete"
    Assert-True "setup active-delete job succeeds" $activeDeleteJob.Ok
    if ($activeDeleteJob.Ok) {
        $activeDeleteJobId = [string]$activeDeleteJob.Data.job_id
        $activeDeleteRun = Start-JobRun -JobId $activeDeleteJobId -Params @{ language = "ru"; timestamps = $true }
        Assert-True "run active-delete job succeeds" $activeDeleteRun.Ok

        if ($activeDeleteRun.Ok) {
            $activeDeleteWait = Wait-ForActiveJob -JobId $activeDeleteJobId -TimeoutSeconds 90 -IntervalSeconds 1
            if ($activeDeleteWait.Ok) {
                $deleteActiveJob = Remove-Job -JobId $activeDeleteJobId
                Assert-Equal "delete active job returns 409" 409 $deleteActiveJob.StatusCode
                if ($deleteActiveJob.StatusCode -eq 409 -and $null -ne $deleteActiveJob.Error -and $null -ne $deleteActiveJob.Error.error) {
                    Assert-Contains "delete active job error mentions active state" ([string]$deleteActiveJob.Error.error) "active"
                }

                $statusAfterRejectedDelete = Get-JobStatus -JobId $activeDeleteJobId
                Assert-True "active-delete job status remains accessible after rejected delete" $statusAfterRejectedDelete.Ok

                $completionAfterDeleteAttempt = Wait-ForJobCompletion -JobId $activeDeleteJobId -TimeoutSeconds 180
                Assert-True "active-delete job reaches terminal state after rejected delete" ($completionAfterDeleteAttempt.FinalStatus -ne "timeout")
                if ($completionAfterDeleteAttempt.FinalStatus -ne "timeout") {
                    $cleanupActiveDeleteJob = Remove-Job -JobId $activeDeleteJobId
                    Assert-Equal "cleanup active-delete job returns 200" 200 $cleanupActiveDeleteJob.StatusCode
                }
            } else {
                Skip-Test "delete active job returns 409" $activeDeleteWait.Error
                $settledActiveDeleteJob = Wait-ForJobCompletion -JobId $activeDeleteJobId -TimeoutSeconds 180
                if ($settledActiveDeleteJob.Ok) {
                    $cleanupActiveDeleteJob = Remove-Job -JobId $activeDeleteJobId
                    Assert-Equal "cleanup active-delete job after skip returns 200" 200 $cleanupActiveDeleteJob.StatusCode
                }
            }
        }
    }
}

Write-TestHeader "DELETE /delete_job with path traversal job_id"
$deleteTraversalJob = Remove-Job -JobId "..\..\config_x_y"
Assert-Equal "path traversal delete returns 400" 400 $deleteTraversalJob.StatusCode

Complete-TestRun

