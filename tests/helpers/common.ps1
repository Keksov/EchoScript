# EchoScript test helpers
# Usage: . "$PSScriptRoot\..\helpers\common.ps1"

[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseApprovedVerbs", "", Justification = "Test helper names are intentional; stale analyzer warning references a removed symbol.")]
param()

$Script:ProjectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$Script:TestsRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$Script:TestJobsBaseRoot = Join-Path $Script:TestsRoot "jobs"
$Script:TestLogsRoot = Join-Path $Script:TestsRoot "logs"
$Script:AudioRoot = Join-Path $Script:TestsRoot "audio"
$Script:SupportedAudioExtensions = @(".aac", ".flac", ".m4a", ".mp3", ".mp4", ".oga", ".ogg", ".opus", ".wav", ".webm", ".wma")
$Script:BaseUrl = if ($env:ECHOSCRIPT_TEST_BASE_URL) {
    [string]$env:ECHOSCRIPT_TEST_BASE_URL
} else {
    "http://localhost:3001"
}
$Script:PollIntervalSeconds = 2
$Script:PollTimeoutSeconds = 300

$Script:TestsPassed = 0
$Script:TestsFailed = 0
$Script:TestsSkipped = 0

function Write-TestHeader {
    param([string]$Name)

    Write-Host ""
    Write-Host "=== $Name ===" -ForegroundColor Cyan
}

function Write-TestStep {
    param([string]$Message)

    Write-Host "  -> $Message" -ForegroundColor DarkGray
}

function Assert-True {
    param(
        [string]$TestName,
        [bool]$Condition,
        [string]$Message = ""
    )

    if ($Condition) {
        Write-Host "  PASS: $TestName" -ForegroundColor Green
        $Script:TestsPassed++
        return
    }

    $suffix = if ($Message.Length -gt 0) { " - $Message" } else { "" }
    Write-Host "  FAIL: $TestName$suffix" -ForegroundColor Red
    $Script:TestsFailed++
}

function Assert-Equal {
    param(
        [string]$TestName,
        $Expected,
        $Actual
    )

    if ($Expected -eq $Actual) {
        Write-Host "  PASS: $TestName" -ForegroundColor Green
        $Script:TestsPassed++
        return
    }

    Write-Host "  FAIL: $TestName - expected '$Expected', got '$Actual'" -ForegroundColor Red
    $Script:TestsFailed++
}

function Assert-NotNull {
    param(
        [string]$TestName,
        $Value
    )

    if ($null -ne $Value -and "$Value".Length -gt 0) {
        Write-Host "  PASS: $TestName" -ForegroundColor Green
        $Script:TestsPassed++
        return
    }

    Write-Host "  FAIL: $TestName - value is null or empty" -ForegroundColor Red
    $Script:TestsFailed++
}

function Assert-Null {
    param(
        [string]$TestName,
        $Value
    )

    if ($null -eq $Value -or "$Value".Length -eq 0) {
        Write-Host "  PASS: $TestName" -ForegroundColor Green
        $Script:TestsPassed++
        return
    }

    Write-Host "  FAIL: $TestName - expected null or empty, got '$Value'" -ForegroundColor Red
    $Script:TestsFailed++
}

function Assert-Contains {
    param(
        [string]$TestName,
        [string]$Haystack,
        [string]$Needle
    )

    if ([string]$Haystack.Contains([string]$Needle)) {
        Write-Host "  PASS: $TestName" -ForegroundColor Green
        $Script:TestsPassed++
        return
    }

    Write-Host "  FAIL: $TestName - '$Haystack' does not contain '$Needle'" -ForegroundColor Red
    $Script:TestsFailed++
}

function Assert-IsArray {
    param(
        [string]$TestName,
        $Value
    )

    if ($Value -is [System.Array]) {
        Write-Host "  PASS: $TestName" -ForegroundColor Green
        $Script:TestsPassed++
        return
    }

    Write-Host "  FAIL: $TestName - value is not an array" -ForegroundColor Red
    $Script:TestsFailed++
}

function Assert-GreaterThan {
    param(
        [string]$TestName,
        [double]$Actual,
        [double]$Threshold
    )

    if ($Actual -gt $Threshold) {
        Write-Host "  PASS: $TestName" -ForegroundColor Green
        $Script:TestsPassed++
        return
    }

    Write-Host "  FAIL: $TestName - $Actual is not greater than $Threshold" -ForegroundColor Red
    $Script:TestsFailed++
}

function Skip-Test {
    param(
        [string]$TestName,
        [string]$Reason
    )

    Write-Host "  SKIP: $TestName - $Reason" -ForegroundColor Yellow
    $Script:TestsSkipped++
}

function Complete-TestRun {
    Write-Host ""
    Write-Host "--- Summary ---" -ForegroundColor Cyan
    Write-Host "  Passed:  $Script:TestsPassed" -ForegroundColor Green
    if ($Script:TestsFailed -gt 0) {
        Write-Host "  Failed:  $Script:TestsFailed" -ForegroundColor Red
    } else {
        Write-Host "  Failed:  0" -ForegroundColor Green
    }
    if ($Script:TestsSkipped -gt 0) {
        Write-Host "  Skipped: $Script:TestsSkipped" -ForegroundColor Yellow
    }
    Write-Host ""

    if ($Script:TestsFailed -gt 0) {
        throw "Test failures detected"
    }
}

function Get-TestProjectRoot {
    return $Script:ProjectRoot
}

function Get-TestAudioFiles {
    $audioRoot = $Script:AudioRoot
    if (-not (Test-Path $audioRoot)) {
        return @()
    }

    $audioFiles = Get-ChildItem -Path $audioRoot -File | Where-Object {
        $Script:SupportedAudioExtensions -contains $_.Extension.ToLowerInvariant()
    } | Sort-Object Name | ForEach-Object {
        $_.FullName
    }

    return @($audioFiles)
}

function Select-TestAudioFiles {
    param(
        [switch]$Smoke,
        [ValidateRange(0, 1000)]
        [int]$MaxAudioFiles = 0
    )

    $audioFiles = @(Get-TestAudioFiles)
    if ($Smoke -and $MaxAudioFiles -eq 0) {
        $MaxAudioFiles = 1
    }

    if ($MaxAudioFiles -gt 0 -and $audioFiles.Count -gt $MaxAudioFiles) {
        $audioFiles = @($audioFiles | Select-Object -First $MaxAudioFiles)
    }

    return @($audioFiles)
}

function Get-PrimaryTestAudioFile {
    $audioFiles = @(Get-TestAudioFiles)
    if ($audioFiles.Count -eq 0) {
        throw "No audio fixtures found in $($Script:AudioRoot)"
    }

    return [string]$audioFiles[0]
}

function Get-TestAudioLabel {
    param([string]$AudioPath)

    return [System.IO.Path]::GetFileName($AudioPath)
}

function Get-TestRunId {
    if ($env:ECHOSCRIPT_TEST_RUN_ID) {
        return [string]$env:ECHOSCRIPT_TEST_RUN_ID
    }

    $generatedRunId = "{0}_{1}" -f (Get-Date -Format "yyyyMMdd_HHmmss"), ([guid]::NewGuid().ToString("N").Substring(0, 8))
    $env:ECHOSCRIPT_TEST_RUN_ID = $generatedRunId
    return $generatedRunId
}

function Get-TestJobsRoot {
    if ($env:ECHOSCRIPT_TEST_JOBS_ROOT) {
        return [string]$env:ECHOSCRIPT_TEST_JOBS_ROOT
    }

    return $Script:TestJobsBaseRoot
}

function Get-TestLogsRoot {
    return $Script:TestLogsRoot
}

function Get-TestBaseUrl {
    return $Script:BaseUrl
}

function Get-TestPort {
    return ([uri](Get-TestBaseUrl)).Port
}

function Get-ListeningPidsForPort {
    param([int]$Port)

    if ($IsWindows) {
        try {
            $listeners = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop
            return @($listeners | Select-Object -ExpandProperty OwningProcess -Unique)
        } catch {
            return @()
        }
    }

    try {
        $lsofCommand = Get-Command lsof -ErrorAction SilentlyContinue
        if ($null -eq $lsofCommand) {
            return @()
        }

        $output = & $lsofCommand.Source -t -iTCP:$Port -sTCP:LISTEN 2>$null
        if ($LASTEXITCODE -ne 0 -or $null -eq $output) {
            return @()
        }

        return @($output | ForEach-Object { [int]$_ } | Select-Object -Unique)
    } catch {
        return @()
    }
}

function Stop-ProcessesListeningOnPort {
    param([int]$Port)

    $listenerPids = @(Get-ListeningPidsForPort -Port $Port)
    if ($listenerPids.Count -eq 0) {
        return
    }

    foreach ($listenerPid in $listenerPids) {
        if ($listenerPid -eq $PID) {
            continue
        }

        try {
            Stop-Process -Id $listenerPid -Force -ErrorAction SilentlyContinue
            Wait-Process -Id $listenerPid -Timeout 10 -ErrorAction SilentlyContinue
        } catch {
        }
    }
}

function Get-TestConfig {
    $configPath = Join-Path (Get-TestProjectRoot) "config.json"
    return Get-Content -Raw $configPath | ConvertFrom-Json
}

function Resolve-TestPythonExecutablePath {
    param(
        [string]$ProjectRoot,
        [string]$ConfiguredPath
    )

    $resolvedPath = [System.IO.Path]::GetFullPath((Join-Path $ProjectRoot $ConfiguredPath))
    if (Test-Path $resolvedPath) {
        return $resolvedPath
    }

    if ($IsWindows -and $resolvedPath -match "venv[\\/]bin[\\/]python$") {
        $windowsFallback = ($resolvedPath -replace "venv[\\/]bin[\\/]python$", "venv\\Scripts\\python.exe")
        if (Test-Path $windowsFallback) {
            return $windowsFallback
        }
    }

    if (-not $IsWindows -and $resolvedPath -match "venv[\\/]Scripts[\\/]python\.exe$") {
        $posixFallback = ($resolvedPath -replace "venv[\\/]Scripts[\\/]python\.exe$", "venv/bin/python")
        if (Test-Path $posixFallback) {
            return $posixFallback
        }
    }

    return $resolvedPath
}

function Get-TestModelNames {
    $config = Get-TestConfig
    return @($config.models.PSObject.Properties.Name)
}

function Initialize-TestJobsRoot {
    $jobsRoot = Get-TestJobsRoot
    $inputRoot = Join-Path $jobsRoot "input"
    $queueRoot = Join-Path $jobsRoot "queue"
    $dataRoot = Join-Path $jobsRoot "data"
    $outputRoot = Join-Path $jobsRoot "output"

    foreach ($path in @($jobsRoot, $inputRoot, $queueRoot, $dataRoot, $outputRoot, (Get-TestLogsRoot))) {
        New-Item -ItemType Directory -Force -Path $path | Out-Null
    }

    foreach ($modelName in Get-TestModelNames) {
        New-Item -ItemType Directory -Force -Path (Join-Path $inputRoot $modelName) | Out-Null
    }

    return $jobsRoot
}

function Clear-TestSchedulerTransientState {
    $jobsRoot = Initialize-TestJobsRoot
    $queueRoot = Join-Path $jobsRoot "queue"
    $inputRoot = Join-Path $jobsRoot "input"
    $outputRoot = Join-Path $jobsRoot "output"

    $queueMarkers = @(
        Get-ChildItem -Path $queueRoot -File -Filter "*.json" -ErrorAction SilentlyContinue
    )
    if ($queueMarkers.Count -gt 0) {
        $queueMarkers | Remove-Item -Force -ErrorAction SilentlyContinue
    }

    $inputMarkers = @(
        Get-ChildItem -Path $inputRoot -File -Filter "*.json" -Recurse -ErrorAction SilentlyContinue
    )
    $inputLockMarkers = @(
        Get-ChildItem -Path $inputRoot -File -Filter "*.json.lock" -Recurse -ErrorAction SilentlyContinue
    )
    $allInputMarkers = @($inputMarkers + $inputLockMarkers)
    if ($allInputMarkers.Count -gt 0) {
        $allInputMarkers | Remove-Item -Force -ErrorAction SilentlyContinue
    }

    $outputMarkers = @(
        Get-ChildItem -Path $outputRoot -File -Filter "*.json" -ErrorAction SilentlyContinue
    )
    if ($outputMarkers.Count -gt 0) {
        $outputMarkers | Remove-Item -Force -ErrorAction SilentlyContinue
    }

    return @{
        QueueRemoved = $queueMarkers.Count
        InputRemoved = $allInputMarkers.Count
        OutputRemoved = $outputMarkers.Count
        TotalRemoved = $queueMarkers.Count + $allInputMarkers.Count + $outputMarkers.Count
    }
}

function Clear-TestJobsArtifacts {
    $cleanupStats = Clear-TestSchedulerTransientState
    $jobsRoot = Get-TestJobsRoot
    $dataRoot = Join-Path $jobsRoot "data"
    Write-TestStep "Preserving data artifacts in $dataRoot; cleared transient markers (queue=$($cleanupStats.QueueRemoved), input=$($cleanupStats.InputRemoved), output=$($cleanupStats.OutputRemoved))"
    return $jobsRoot
}

function New-TestJobId {
    param([string]$ModelName = "common")

    $suffix = if ($ModelName.Length -gt 0) { $ModelName } else { "common" }
    $randomId = [guid]::NewGuid().ToString("N")
    return "{0}_{1}_{2}" -f [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(), $randomId, $suffix
}

function Get-TestOrchestratorPidPath {
    return Join-Path (Get-TestLogsRoot) "test-orchestrator.pid"
}

function Get-TestOrchestratorStdoutPath {
    return Join-Path (Get-TestLogsRoot) "test-orchestrator.$(Get-TestRunId).stdout.log"
}

function Get-TestOrchestratorStderrPath {
    return Join-Path (Get-TestLogsRoot) "test-orchestrator.$(Get-TestRunId).stderr.log"
}

function Start-TestOrchestrator {
    param(
        [switch]$ResetJobsRoot,
        [int]$StartupTimeoutSeconds = 60
    )

    if ($ResetJobsRoot) {
        Write-TestStep "ResetJobsRoot requested; preserving data artifacts while cleaning transient scheduler markers"
    }

    Stop-TestOrchestrator | Out-Null

    $cleanupStats = Clear-TestSchedulerTransientState
    if ($cleanupStats.TotalRemoved -gt 0) {
        Write-TestStep "Cleared transient scheduler markers: queue=$($cleanupStats.QueueRemoved), input=$($cleanupStats.InputRemoved), output=$($cleanupStats.OutputRemoved)"
    }

    $jobsRoot = Get-TestJobsRoot
    $projectRoot = Get-TestProjectRoot
    $orchestratorDir = Join-Path $projectRoot "orchestrator"
    $stdoutPath = Get-TestOrchestratorStdoutPath
    $stderrPath = Get-TestOrchestratorStderrPath
    $pidPath = Get-TestOrchestratorPidPath
    $testPort = Get-TestPort

    Stop-ProcessesListeningOnPort -Port $testPort
    Remove-Item -Path $pidPath -Force -ErrorAction SilentlyContinue

    $escapedJobsRoot = $jobsRoot.Replace("'", "''")
    $escapedOrchestratorDir = $orchestratorDir.Replace("'", "''")
    $command = @(
        "`$env:ECHOSCRIPT_JOBS_ROOT = '$escapedJobsRoot'",
        "`$env:ECHOSCRIPT_PORT = '$testPort'",
        "Set-Location '$escapedOrchestratorDir'",
        "bun run start"
    ) -join "; "

    $startProcessArgs = @{
        FilePath = "pwsh"
        ArgumentList = @("-NoProfile", "-Command", $command)
        RedirectStandardOutput = $stdoutPath
        RedirectStandardError = $stderrPath
        PassThru = $true
    }
    $process = Start-Process @startProcessArgs

    Set-Content -Path $pidPath -Value $process.Id -Encoding UTF8

    $started = $false
    $startedAt = Get-Date
    while (((Get-Date) - $startedAt).TotalSeconds -lt $StartupTimeoutSeconds) {
        $process.Refresh()
        if ($process.HasExited) {
            break
        }

        try {
            $null = Invoke-RestMethod -Uri "$(Get-TestBaseUrl)/" -Method Get -TimeoutSec 5
            $started = $true
            break
        } catch {
            Start-Sleep -Seconds 1
        }
    }

    if (-not $started) {
        Stop-TestOrchestrator | Out-Null
        throw "Timed out starting test orchestrator. Stdout: $stdoutPath Stderr: $stderrPath"
    }

    return @{
        Process = $process
        JobsRoot = $jobsRoot
        BaseUrl = Get-TestBaseUrl
        StdoutPath = $stdoutPath
        StderrPath = $stderrPath
    }
}

function Stop-TestOrchestrator {
    $pidPath = Get-TestOrchestratorPidPath
    if (-not (Test-Path $pidPath)) {
        Stop-ProcessesListeningOnPort -Port (Get-TestPort)
        return $false
    }

    $pidText = (Get-Content -Raw $pidPath -ErrorAction SilentlyContinue).Trim()
    if ($pidText.Length -gt 0) {
        try {
            $processId = [int]$pidText
            Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
            Wait-Process -Id $processId -Timeout 15 -ErrorAction SilentlyContinue
        } catch {
        }
    }

    Remove-Item -Path $pidPath -Force -ErrorAction SilentlyContinue
    Stop-ProcessesListeningOnPort -Port (Get-TestPort)
    return $true
}

function Test-OrchestratorRunning {
    try {
        $null = Invoke-RestMethod -Uri "$(Get-TestBaseUrl)/" -Method Get -TimeoutSec 5
        return $true
    } catch {
        Write-Host "ERROR: Test orchestrator is not running at $(Get-TestBaseUrl)" -ForegroundColor Red
        Write-Host "Start it first: pwsh tests/start-test-orchestrator.ps1" -ForegroundColor Yellow
        return $false
    }
}

function Get-OrchestratorHealth {
    return Invoke-Api -Method Get -Path "/"
}

function Invoke-Api {
    param(
        [string]$Method,
        [string]$Path,
        [hashtable]$Query = @{},
        [object]$Body = $null,
        [string]$ContentType = "application/json",
        [byte[]]$RawBody = $null,
        [switch]$ExpectError
    )

    $uriBuilder = [System.UriBuilder]::new([uri](Get-TestBaseUrl))
    $uriBuilder.Path = if ($Path.StartsWith("/")) { $Path } else { "/$Path" }
    if ($Query.Count -gt 0) {
        $queryParts = @()
        foreach ($entry in $Query.GetEnumerator()) {
            $queryParts += "{0}={1}" -f [uri]::EscapeDataString([string]$entry.Key), [uri]::EscapeDataString([string]$entry.Value)
        }
        $uriBuilder.Query = $queryParts -join "&"
    } else {
        $uriBuilder.Query = ""
    }
    $uri = $uriBuilder.Uri.AbsoluteUri

    $params = @{
        Uri        = $uri
        Method     = $Method
        TimeoutSec = 30
    }

    if ($null -ne $RawBody) {
        $params.Body = $RawBody
        $params.ContentType = "application/octet-stream"
    } elseif ($null -ne $Body) {
        $params.Body = ($Body | ConvertTo-Json -Depth 10)
        $params.ContentType = $ContentType
    }

    try {
        $response = Invoke-WebRequest @params -SkipHttpErrorCheck
    } catch {
        if ($ExpectError) {
            return @{
                Ok = $false
                StatusCode = 0
                Error = $_.Exception.Message
            }
        }

        Write-Host "  HTTP ERROR 0 on $Method $Path" -ForegroundColor Red
        Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
        return @{
            Ok = $false
            StatusCode = 0
            Error = $_.Exception.Message
        }
    }

    $statusCode = [int]$response.StatusCode
    $responseBody = $null
    if ($null -ne $response.Content -and $response.Content.Length -gt 0) {
        $contentType = ""
        if ($null -ne $response.Headers) {
            $contentType = [string]@($response.Headers["Content-Type"] | Select-Object -First 1)
        }

        $trimmedContent = $response.Content.TrimStart()
        $looksLikeJson = $trimmedContent.StartsWith("{") -or $trimmedContent.StartsWith("[")
        $isJsonResponse = $contentType -match '(?i)^(application|text)/([a-z0-9.+-]*\+)?json(?:;|$)'

        if ($isJsonResponse -or $looksLikeJson) {
            try {
                $responseBody = $response.Content | ConvertFrom-Json -NoEnumerate
            } catch {
                $responseBody = $response.Content
            }
        } else {
            $responseBody = $response.Content
        }
    }

    if ($statusCode -ge 200 -and $statusCode -lt 300) {
        return @{
            Ok = $true
            Data = $responseBody
            StatusCode = $statusCode
        }
    }

    if ($ExpectError) {
        return @{
            Ok = $false
            StatusCode = $statusCode
            Error = $responseBody
        }
    }

    Write-Host "  HTTP ERROR $statusCode on $Method $Path" -ForegroundColor Red
    if ($null -ne $responseBody) {
        if ($responseBody -is [string]) {
            Write-Host "  $responseBody" -ForegroundColor Red
        } else {
            Write-Host "  $($responseBody | ConvertTo-Json -Compress)" -ForegroundColor Red
        }
    }

    return @{
        Ok = $false
        StatusCode = $statusCode
        Error = $responseBody
    }
}

function Add-BodyJob {
    param(
        [string]$AudioPath = "",
        [string]$Model = "",
        [string]$Source = ""
    )

    if ($AudioPath.Length -eq 0) {
        $AudioPath = Get-PrimaryTestAudioFile
    }

    $audioBytes = [System.IO.File]::ReadAllBytes($AudioPath)
    $query = @{}
    if ($Model.Length -gt 0) {
        $query["model"] = $Model
    }
    if ($Source.Length -gt 0) {
        $query["source"] = $Source
    }

    return Invoke-Api -Method Post -Path "/add_body" -Query $query -RawBody $audioBytes
}

function Add-FileJob {
    param(
        [string]$FilePath = "",
        [string]$Model = ""
    )

    if ($FilePath.Length -eq 0) {
        $FilePath = Get-PrimaryTestAudioFile
    }

    $payload = @{ path = $FilePath }
    if ($Model.Length -gt 0) {
        $payload["model"] = $Model
    }

    return Invoke-Api -Method Post -Path "/add_file" -Body $payload
}

function Start-JobRun {
    param(
        [string]$JobId,
        [hashtable]$Params = @{}
    )

    $payload = @{ job_id = $JobId }
    if ($Params.Count -gt 0) {
        $payload["params"] = $Params
    }

    return Invoke-Api -Method Post -Path "/run_job" -Body $payload
}

function Get-JobStatus {
    param([string]$JobId)

    return Invoke-Api -Method Get -Path "/get_job_status" -Query @{ job_id = $JobId }
}

function Get-Jobs {
    return Invoke-Api -Method Get -Path "/list_jobs"
}

function Wait-ForActiveJob {
    param(
        [string]$JobId,
        [int]$TimeoutSeconds = 60,
        [int]$IntervalSeconds = 1
    )

    $startedAt = Get-Date
    while (((Get-Date) - $startedAt).TotalSeconds -lt $TimeoutSeconds) {
        $healthResult = Get-OrchestratorHealth
        if ($healthResult.Ok -and [string]$healthResult.Data.active_job_id -eq $JobId) {
            return @{
                Ok = $true
                Data = $healthResult.Data
            }
        }

        Start-Sleep -Seconds $IntervalSeconds
    }

    return @{
        Ok = $false
        FinalStatus = "timeout"
        Error = "Timed out after $TimeoutSeconds seconds waiting for an active job"
    }
}

function Wait-ForJobCompletion {
    param(
        [string]$JobId,
        [int]$TimeoutSeconds = $Script:PollTimeoutSeconds,
        [int]$IntervalSeconds = $Script:PollIntervalSeconds
    )

    $startedAt = Get-Date
    while (((Get-Date) - $startedAt).TotalSeconds -lt $TimeoutSeconds) {
        $statusResult = Get-JobStatus -JobId $JobId
        if ($statusResult.Ok -and $statusResult.Data -is [System.Array] -and $statusResult.Data.Count -gt 0) {
            $lastStatus = $statusResult.Data[$statusResult.Data.Count - 1].status
            Write-TestStep "Job $JobId status: $lastStatus"

            if ($lastStatus -eq "ready") {
                return @{
                    Ok = $true
                    FinalStatus = $lastStatus
                    Statuses = $statusResult.Data
                }
            }

            if ($lastStatus -eq "failed") {
                return @{
                    Ok = $false
                    FinalStatus = $lastStatus
                    Error = $statusResult.Data[$statusResult.Data.Count - 1].error
                    Statuses = $statusResult.Data
                }
            }
        }

        Start-Sleep -Seconds $IntervalSeconds
    }

    return @{
        Ok = $false
        FinalStatus = "timeout"
        Error = "Timed out after $TimeoutSeconds seconds"
    }
}

function Get-JobResult {
    param(
        [string]$JobId,
        [string]$Type = ""
    )

    $query = @{ job_id = $JobId }
    if ($Type.Length -gt 0) {
        $query["type"] = $Type
    }

    return Invoke-Api -Method Get -Path "/get_job_result" -Query $query
}

function Remove-Job {
    param([string]$JobId)

    return Invoke-Api -Method Delete -Path "/delete_job" -Query @{ job_id = $JobId } -ExpectError
}

function Get-StatusNames {
    param([System.Array]$Statuses)

    return @($Statuses | ForEach-Object { $_.status })
}

function Get-StatusTimestamp {
    param(
        [System.Array]$Statuses,
        [string]$StatusName
    )

    $match = $Statuses | Where-Object { $_.status -eq $StatusName } | Select-Object -First 1
    if ($null -eq $match) {
        return $null
    }

    return [datetime]$match.updated_at
}

function Invoke-TestTranscriptionFlow {
    param(
        [string]$Label,
        [ValidateSet("body", "file")]
        [string]$InputMethod,
        [string]$AudioPath = "",
        [string]$Model = "",
        [hashtable]$Params = @{}
    )

    if ($AudioPath.Length -eq 0) {
        $AudioPath = Get-PrimaryTestAudioFile
    }

    Write-TestHeader $Label
    Write-TestStep "Audio path: $AudioPath"
    Write-TestStep "Input method: $InputMethod"

    if ($InputMethod -eq "body") {
        $addResult = Add-BodyJob -AudioPath $AudioPath -Model $Model -Source (Split-Path $AudioPath -Leaf)
    } else {
        $addResult = Add-FileJob -FilePath $AudioPath -Model $Model
    }

    Assert-True "$Label - job created" $addResult.Ok
    if (-not $addResult.Ok) {
        return $null
    }

    $jobId = [string]$addResult.Data.job_id
    Assert-NotNull "$Label - job_id returned" $jobId
    Write-TestStep "Job ID: $jobId"

    $runResult = Start-JobRun -JobId $jobId -Params $Params
    Assert-True "$Label - run_job succeeded" $runResult.Ok
    if (-not $runResult.Ok) {
        return $null
    }

    Assert-Equal "$Label - run_job status" "queued" $runResult.Data.status
    Assert-Equal "$Label - queue name" "queue" $runResult.Data.queue
    Assert-NotNull "$Label - target model" $runResult.Data.target_model

    $waitResult = Wait-ForJobCompletion -JobId $jobId
    Assert-True "$Label - job completed" $waitResult.Ok
    if (-not $waitResult.Ok) {
        Write-TestStep "Failure reason: $($waitResult.Error)"
        return @{
            JobId = $jobId
            WaitResult = $waitResult
            Result = $null
        }
    }

    $resultResponse = Get-JobResult -JobId $jobId
    Assert-True "$Label - result retrieved" $resultResponse.Ok
    if (-not $resultResponse.Ok) {
        return @{
            JobId = $jobId
            WaitResult = $waitResult
            Result = $null
        }
    }

    Assert-NotNull "$Label - normalized text" $resultResponse.Data.normalized.text
    Assert-NotNull "$Label - raw text" $resultResponse.Data.raw.text

    return @{
        JobId = $jobId
        WaitResult = $waitResult
        Result = $resultResponse.Data
        RunResult = $runResult.Data
    }
}

