# API discovery tests for Bun visibility into jobs created outside the API flow.
# Prerequisite: pwsh tests/start-test-orchestrator.ps1
# Run: pwsh tests/api/test-job-discovery.ps1

param(
    [string]$ModelName = "whisper_podlodka",
    [string]$AudioPath = "",
    [int]$StartupTimeoutSeconds = 120,
    [int]$WatcherStartupTimeoutSeconds = 60,
    [int]$DiscoveryTimeoutSeconds = 30,
    [int]$PollIntervalMs = 5000
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\..\helpers\common.ps1"

function Test-IsVoskModel {
    param([string]$Name)

    return $Name.StartsWith("vosk_", [System.StringComparison]::OrdinalIgnoreCase)
}

if (Test-IsVoskModel -Name $ModelName) {
    if (-not $PSBoundParameters.ContainsKey("StartupTimeoutSeconds")) {
        $StartupTimeoutSeconds = 180
    }

    if (-not $PSBoundParameters.ContainsKey("WatcherStartupTimeoutSeconds")) {
        $WatcherStartupTimeoutSeconds = 300
    }
}

function Get-LogTail {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        return "<log file missing>"
    }

    return (Get-Content -Path $Path -Tail 60) -join [Environment]::NewLine
}

function Test-LogContains {
    param(
        [string]$Path,
        [string]$Text
    )

    if (-not (Test-Path $Path)) {
        return $false
    }

    try {
        return (Get-Content -Raw $Path).Contains($Text)
    } catch {
        return $false
    }
}

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

Write-TestHeader "GET /list_jobs includes API-created job"
$audioFilePath = if ($AudioPath.Length -gt 0) {
    [System.IO.Path]::GetFullPath($AudioPath)
} else {
    [string](@(Get-TestAudioFiles | Select-Object -First 1)[0])
}

Assert-True "audio file exists" (Test-Path $audioFilePath)
if (-not (Test-Path $audioFilePath)) {
    Complete-TestRun
}

$apiCreatedJob = Add-BodyJob -AudioPath $audioFilePath -Source "job-discovery-api"
Assert-True "setup API-created job succeeds" $apiCreatedJob.Ok
Assert-NotNull "API-created job returns job_id" $apiCreatedJob.Data.job_id

if ($apiCreatedJob.Ok) {
    $apiCreatedJobId = [string]$apiCreatedJob.Data.job_id
    $listedJobs = Get-Jobs
    Assert-True "list_jobs succeeds for API-created job" $listedJobs.Ok
    if ($listedJobs.Ok) {
        $listedApiJob = Find-ListedJob -JobsPayload $listedJobs.Data -JobId $apiCreatedJobId
        Assert-NotNull "list_jobs includes API-created job" $listedApiJob
        if ($null -ne $listedApiJob) {
            Assert-Equal "API-created job current status is dispatching" "dispatching" ([string]$listedApiJob.current_status)
            Assert-Equal "API-created job source is preserved" "job-discovery-api" ([string]$listedApiJob.source)
            Assert-Equal "API-created body job created_from is api_body" "api_body" ([string]$listedApiJob.created_from)
            Assert-True "API-created job has no result before run" (-not [bool]$listedApiJob.has_result)
        }
    }

    $cleanupApiJob = Remove-Job -JobId $apiCreatedJobId
    Assert-Equal "cleanup API-created job returns 200" 200 $cleanupApiJob.StatusCode
}

Write-TestHeader "GET /list_jobs includes API file job"
$apiFileJob = Add-FileJob -FilePath $audioFilePath -Model $ModelName
Assert-True "setup API file job succeeds" $apiFileJob.Ok
Assert-NotNull "API file job returns job_id" $apiFileJob.Data.job_id

if ($apiFileJob.Ok) {
    $apiFileJobId = [string]$apiFileJob.Data.job_id
    $listedJobs = Get-Jobs
    Assert-True "list_jobs succeeds for API file job" $listedJobs.Ok
    if ($listedJobs.Ok) {
        $listedApiFileJob = Find-ListedJob -JobsPayload $listedJobs.Data -JobId $apiFileJobId
        Assert-NotNull "list_jobs includes API file job" $listedApiFileJob
        if ($null -ne $listedApiFileJob) {
            Assert-Equal "API file job current status is dispatching" "dispatching" ([string]$listedApiFileJob.current_status)
            Assert-Equal "API file job created_from is api_file" "api_file" ([string]$listedApiFileJob.created_from)
            Assert-True "API file job has no result before run" (-not [bool]$listedApiFileJob.has_result)
        }
    }

    $cleanupApiFileJob = Remove-Job -JobId $apiFileJobId
    Assert-Equal "cleanup API file job returns 200" 200 $cleanupApiFileJob.StatusCode
}

Write-TestHeader "GET /list_jobs includes direct media drop job"
$projectRoot = Get-TestProjectRoot
$config = Get-TestConfig
$modelProperty = $config.models.PSObject.Properties[$ModelName]
Assert-NotNull "model '$ModelName' exists in config" $modelProperty
if ($null -eq $modelProperty) {
    Complete-TestRun
}

$audioLabel = Get-TestAudioLabel -AudioPath $audioFilePath
$modelConfig = $modelProperty.Value
$pythonExecutable = Resolve-TestPythonExecutablePath -ProjectRoot $projectRoot -ConfiguredPath ([string]$modelConfig.python_executable)
$serviceDir = [System.IO.Path]::GetFullPath((Join-Path $projectRoot $modelConfig.service_dir))
$jobsRoot = Get-TestJobsRoot
$modelInputDir = Join-Path $jobsRoot (Join-Path "input" $ModelName)
$dataRoot = Join-Path $jobsRoot "data"
$stagingRoot = Join-Path $jobsRoot "staging"
$pidPath = Join-Path $projectRoot (Join-Path "services" "$ModelName.pid")
$logsRoot = Join-Path (Get-TestLogsRoot) "api"
$logId = "{0}_{1}_{2}" -f (Get-Date -Format "yyyyMMdd_HHmmss"), ([guid]::NewGuid().ToString("N").Substring(0, 8)), $ModelName
$stdoutLogPath = Join-Path $logsRoot "$logId.stdout.log"
$stderrLogPath = Join-Path $logsRoot "$logId.stderr.log"

Assert-True "python executable exists" (Test-Path $pythonExecutable)
Assert-True "service directory exists" (Test-Path $serviceDir)
Assert-NotNull "module name exists" ([string]$modelConfig.module)

if (-not (Test-Path $pythonExecutable) -or -not (Test-Path $serviceDir) -or ([string]$modelConfig.module).Length -eq 0) {
    Complete-TestRun
}

New-Item -ItemType Directory -Force -Path $modelInputDir | Out-Null
New-Item -ItemType Directory -Force -Path $dataRoot | Out-Null
New-Item -ItemType Directory -Force -Path $stagingRoot | Out-Null
New-Item -ItemType Directory -Force -Path $logsRoot | Out-Null

$existingDataDirs = @(
    Get-ChildItem -Path $dataRoot -Directory -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty Name
)

$droppedFileName = [System.IO.Path]::GetFileName($audioFilePath)
$stagedInputPath = Join-Path $stagingRoot $droppedFileName
$droppedInputPath = Join-Path $modelInputDir $droppedFileName
$serviceProcess = $null
$serviceStarted = $false
$watcherStarted = $false
$jobId = $null

try {
    if (Test-Path $pidPath) {
        Remove-Item -Path $pidPath -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path $stagedInputPath) {
        Remove-Item -Path $stagedInputPath -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path $droppedInputPath) {
        Remove-Item -Path $droppedInputPath -Force -ErrorAction SilentlyContinue
    }

    $serviceProcess = Start-Process -FilePath $pythonExecutable -ArgumentList @(
        "-m",
        [string]$modelConfig.module,
        "--jobs-root",
        $jobsRoot,
        "--project-root",
        $projectRoot,
        "--model-name",
        $ModelName,
        "--poll-interval-ms",
        "$PollIntervalMs"
    ) -WorkingDirectory $serviceDir -RedirectStandardOutput $stdoutLogPath -RedirectStandardError $stderrLogPath -PassThru

    $startupStartedAt = Get-Date
    while (((Get-Date) - $startupStartedAt).TotalSeconds -lt $StartupTimeoutSeconds) {
        $serviceProcess.Refresh()
        if ($serviceProcess.HasExited) {
            break
        }

        if (Test-Path $pidPath) {
            $pidValue = (Get-Content -Raw $pidPath -ErrorAction SilentlyContinue).Trim()
            if ($pidValue.Length -gt 0) {
                $serviceStarted = $true
                break
            }
        }

        Start-Sleep -Seconds 1
    }

    Assert-True "direct-drop service wrote pid file" $serviceStarted
    if (-not $serviceStarted) {
        Write-TestStep "stdout tail:"
        Write-Host (Get-LogTail -Path $stdoutLogPath)
        Write-TestStep "stderr tail:"
        Write-Host (Get-LogTail -Path $stderrLogPath)
        Complete-TestRun
    }

    $watcherStartedAt = Get-Date
    while (((Get-Date) - $watcherStartedAt).TotalSeconds -lt $WatcherStartupTimeoutSeconds) {
        $serviceProcess.Refresh()
        if ($serviceProcess.HasExited) {
            break
        }

        if (Test-LogContains -Path $stderrLogPath -Text "Watching model queue for wake-up hints") {
            $watcherStarted = $true
            break
        }

        Start-Sleep -Milliseconds 200
    }

    Assert-True "direct-drop watcher started" $watcherStarted
    if (-not $watcherStarted) {
        Write-TestStep "stderr tail:"
        Write-Host (Get-LogTail -Path $stderrLogPath)
        Complete-TestRun
    }

    Copy-Item -Path $audioFilePath -Destination $stagedInputPath -Force
    Move-Item -Path $stagedInputPath -Destination $droppedInputPath

    $discoveryStartedAt = Get-Date
    $listedDirectJob = $null
    $directJobListedWithMetadata = $false
    while (((Get-Date) - $discoveryStartedAt).TotalSeconds -lt $DiscoveryTimeoutSeconds) {
        $serviceProcess.Refresh()
        if ($serviceProcess.HasExited) {
            break
        }

        $newDataDirs = @(
            Get-ChildItem -Path $dataRoot -Directory -ErrorAction SilentlyContinue |
                Where-Object { $existingDataDirs -notcontains $_.Name }
        )
        if ($newDataDirs.Count -gt 0 -and $null -eq $jobId) {
            $jobId = [string]$newDataDirs[0].Name
        }

        if ($null -ne $jobId) {
            $listedJobs = Get-Jobs
            if ($listedJobs.Ok) {
                $candidateJob = Find-ListedJob -JobsPayload $listedJobs.Data -JobId $jobId
                if (
                    $null -ne $candidateJob -and
                    [string]$candidateJob.model -eq $ModelName -and
                    [string]$candidateJob.source -eq "input" -and
                    [string]$candidateJob.original_filename -eq $audioLabel -and
                    @("dispatching", "pending", "processing", "ready") -contains [string]$candidateJob.current_status
                ) {
                    $listedDirectJob = $candidateJob
                    $directJobListedWithMetadata = $true
                    break
                }
            }
        }

        Start-Sleep -Milliseconds 250
    }

    Assert-NotNull "direct media drop created job_id" $jobId
    Assert-True "list_jobs includes direct-drop job" $directJobListedWithMetadata
    if ($null -ne $listedDirectJob) {
        Assert-Equal "direct-drop listed model" $ModelName ([string]$listedDirectJob.model)
        Assert-Equal "direct-drop listed source" "input" ([string]$listedDirectJob.source)
        Assert-Equal "direct-drop listed original filename" $audioLabel ([string]$listedDirectJob.original_filename)
        Assert-Equal "direct-drop created_from is file_drop" "file_drop" ([string]$listedDirectJob.created_from)
        Assert-True "direct-drop listed status is present" (@("dispatching", "pending", "processing", "ready") -contains [string]$listedDirectJob.current_status)
    }
} finally {
    if ($null -ne $serviceProcess) {
        try {
            $serviceProcess.Refresh()
            if (-not $serviceProcess.HasExited) {
                Stop-Process -Id $serviceProcess.Id -Force -ErrorAction SilentlyContinue
                Wait-Process -Id $serviceProcess.Id -Timeout 10 -ErrorAction SilentlyContinue
            }
        } catch {
        }
    }

    if (Test-Path $pidPath) {
        Remove-Item -Path $pidPath -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path $stagedInputPath) {
        Remove-Item -Path $stagedInputPath -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path $droppedInputPath) {
        Remove-Item -Path $droppedInputPath -Force -ErrorAction SilentlyContinue
    }

    if ($null -ne $jobId -and $jobId.Length -gt 0) {
        try {
            Remove-Job -JobId $jobId | Out-Null
        } catch {
        }
    }
}

Complete-TestRun
