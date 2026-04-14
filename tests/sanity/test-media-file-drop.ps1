# Direct filesystem test: drop a media file into the model input directory and
# verify the Python service creates and completes a job automatically.
# Run: pwsh tests/sanity/test-media-file-drop.ps1

param(
    [string]$ModelName = "whisper_podlodka",
    [string]$AudioPath = "",
    [int]$StartupTimeoutSeconds = 120,
    [int]$WatcherStartupTimeoutSeconds = 15,
    [int]$WakeupThresholdMs = 2500,
    [int]$PollIntervalMs = 5000,
    [int]$CompletionTimeoutSeconds = 300
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\..\helpers\common.ps1"

function Read-JsonFile {
    param([string]$Path)

    return Get-Content -Raw $Path | ConvertFrom-Json
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

function Get-ExpectedJobStem {
    param([string]$FileName)

    $stem = [System.IO.Path]::GetFileNameWithoutExtension($FileName).ToLowerInvariant()
    $stem = [regex]::Replace($stem, "[^a-z0-9_-]+", "-").Trim("-_")
    if ($stem.Length -eq 0) {
        return $null
    }

    return $stem
}

Write-TestHeader "Media file drop"

$projectRoot = Get-TestProjectRoot
$configPath = Join-Path $projectRoot "config.json"
Assert-True "config.json exists" (Test-Path $configPath)
if (-not (Test-Path $configPath)) {
    Complete-TestRun
}

$config = Get-TestConfig
$modelProperty = $config.models.PSObject.Properties[$ModelName]
Assert-NotNull "model '$ModelName' exists in config" $modelProperty
if ($null -eq $modelProperty) {
    Complete-TestRun
}

$audioFilePath = if ($AudioPath.Length -gt 0) {
    [System.IO.Path]::GetFullPath($AudioPath)
} else {
    $preferredAudio = @(
        Get-TestAudioFiles | Where-Object {
            [System.IO.Path]::GetFileNameWithoutExtension($_) -match "^[A-Za-z0-9_-]+$"
        } | Select-Object -First 1
    )
    if ($preferredAudio.Count -gt 0) {
        [string]$preferredAudio[0]
    } else {
        [string](@(Get-TestAudioFiles | Select-Object -First 1)[0])
    }
}

$audioLabel = Get-TestAudioLabel -AudioPath $audioFilePath
$expectedJobStem = Get-ExpectedJobStem -FileName $audioLabel
$modelConfig = $modelProperty.Value
$pythonExecutable = Resolve-TestPythonExecutablePath -ProjectRoot $projectRoot -ConfiguredPath ([string]$modelConfig.python_executable)
$serviceDir = [System.IO.Path]::GetFullPath((Join-Path $projectRoot $modelConfig.service_dir))
$jobsRoot = Initialize-TestJobsRoot
$cleanupStats = Clear-TestSchedulerTransientState
$moduleName = [string]$modelConfig.module
$modelInputDir = Join-Path $jobsRoot (Join-Path "input" $ModelName)
$dataRoot = Join-Path $jobsRoot "data"
$outputDir = Join-Path $jobsRoot "output"
$stagingRoot = Join-Path $jobsRoot "staging"
$pidPath = Join-Path $projectRoot (Join-Path "services" "$ModelName.pid")
$logsRoot = Join-Path (Get-TestLogsRoot) "sanity"
$logId = "{0}_{1}_{2}" -f (Get-Date -Format "yyyyMMdd_HHmmss"), ([guid]::NewGuid().ToString("N").Substring(0, 8)), $ModelName
$stdoutLogPath = Join-Path $logsRoot "$logId.stdout.log"
$stderrLogPath = Join-Path $logsRoot "$logId.stderr.log"

Write-TestStep "Model: $ModelName"
Write-TestStep "Audio: $audioFilePath"
Write-TestStep "Python: $pythonExecutable"
Write-TestStep "Service dir: $serviceDir"
Write-TestStep "Jobs root: $jobsRoot"
Write-TestStep "Transient markers cleared: $($cleanupStats.TotalRemoved)"

Assert-True "audio file exists" (Test-Path $audioFilePath)
Assert-True "python executable exists" (Test-Path $pythonExecutable)
Assert-True "service directory exists" (Test-Path $serviceDir)
Assert-NotNull "module name exists" $moduleName

if (-not (Test-Path $audioFilePath) -or -not (Test-Path $pythonExecutable) -or -not (Test-Path $serviceDir) -or $moduleName.Length -eq 0) {
    Complete-TestRun
}

New-Item -ItemType Directory -Force -Path $modelInputDir | Out-Null
New-Item -ItemType Directory -Force -Path $dataRoot | Out-Null
New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
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
$dataDir = $null
$statusPath = $null
$resultPath = $null
$outputMarkerPath = $null
$processingSeen = $false
$processingLatencyMs = -1
$jobSucceeded = $false

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

    Write-TestHeader "Start service directly [$audioLabel]"
    $startProcessArgs = @{
        FilePath = $pythonExecutable
        ArgumentList = @(
            "-m",
            $moduleName,
            "--jobs-root",
            $jobsRoot,
            "--project-root",
            $projectRoot,
            "--model-name",
            $ModelName,
            "--poll-interval-ms",
            "$PollIntervalMs"
        )
        WorkingDirectory = $serviceDir
        RedirectStandardOutput = $stdoutLogPath
        RedirectStandardError = $stderrLogPath
        PassThru = $true
    }
    $serviceProcess = Start-Process @startProcessArgs

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

    Assert-True "service wrote pid file [$audioLabel]" $serviceStarted
    if (-not $serviceStarted) {
        Write-TestStep "stdout tail [$audioLabel]:"
        Write-Host (Get-LogTail -Path $stdoutLogPath)
        Write-TestStep "stderr tail [$audioLabel]:"
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

    Assert-True "watcher started [$audioLabel]" $watcherStarted
    if (-not $watcherStarted) {
        Write-TestStep "stderr tail [$audioLabel]:"
        Write-Host (Get-LogTail -Path $stderrLogPath)
        Complete-TestRun
    }

    Write-TestHeader "Drop media file [$audioLabel]"
    Copy-Item -Path $audioFilePath -Destination $stagedInputPath -Force
    $dropStartedAt = [DateTimeOffset]::UtcNow
    Move-Item -Path $stagedInputPath -Destination $droppedInputPath

    Assert-True "media file exists after drop [$audioLabel]" (Test-Path $droppedInputPath)

    $processingDeadline = $dropStartedAt.AddMilliseconds($WakeupThresholdMs)
    while ([DateTimeOffset]::UtcNow -lt $processingDeadline) {
        $serviceProcess.Refresh()
        if ($serviceProcess.HasExited) {
            break
        }

        $newDataDirs = @(
            Get-ChildItem -Path $dataRoot -Directory -ErrorAction SilentlyContinue |
                Where-Object { $existingDataDirs -notcontains $_.Name }
        )
        if ($newDataDirs.Count -gt 0) {
            $jobId = [string]$newDataDirs[0].Name
            $dataDir = [string]$newDataDirs[0].FullName
            $statusPath = Join-Path $dataDir "status.json"
            $resultPath = Join-Path $dataDir "result.json"
            $outputMarkerPath = Join-Path $outputDir "$jobId.json"

            if (Test-Path $statusPath) {
                $statusPayload = @(Read-JsonFile -Path $statusPath)
                $statusNames = @($statusPayload | ForEach-Object { $_.status })
                if ($statusNames -contains "processing") {
                    $processingSeen = $true
                    $processingLatencyMs = [math]::Round(([DateTimeOffset]::UtcNow - $dropStartedAt).TotalMilliseconds)
                    break
                }
            }
        }

        Start-Sleep -Milliseconds 100
    }

    Assert-NotNull "media drop created job_id [$audioLabel]" $jobId
    if ($null -eq $jobId -or $jobId.Length -eq 0) {
        Write-TestStep "stderr tail [$audioLabel]:"
        Write-Host (Get-LogTail -Path $stderrLogPath)
        Complete-TestRun
    }

    Assert-Contains "job_id contains model name [$audioLabel]" $jobId $ModelName
    if ($null -ne $expectedJobStem -and $expectedJobStem.Length -gt 0) {
        Assert-True "job_id ends with filename stem [$audioLabel]" $jobId.EndsWith("_$expectedJobStem")
    }

    Assert-True "processing reached before poll timeout [$audioLabel]" $processingSeen
    if (-not $processingSeen) {
        if ($null -ne $statusPath -and (Test-Path $statusPath)) {
            $statusPayload = @(Read-JsonFile -Path $statusPath)
            Write-TestStep "Last known statuses [$audioLabel]: $((@($statusPayload | ForEach-Object { $_.status })) -join ' -> ')"
        }
        Write-TestStep "stderr tail [$audioLabel]:"
        Write-Host (Get-LogTail -Path $stderrLogPath)
        Complete-TestRun
    }

    Write-TestStep "Processing latency [$audioLabel]: $processingLatencyMs ms"
    Assert-True "processing latency is under $WakeupThresholdMs ms [$audioLabel]" ($processingLatencyMs -lt $WakeupThresholdMs)

    Write-TestHeader "Wait for completion [$audioLabel]"
    $completionStartedAt = Get-Date
    $finalStatuses = @()
    while (((Get-Date) - $completionStartedAt).TotalSeconds -lt $CompletionTimeoutSeconds) {
        $serviceProcess.Refresh()
        if ($serviceProcess.HasExited) {
            break
        }

        if ($null -ne $statusPath -and (Test-Path $statusPath)) {
            $statusPayload = @(Read-JsonFile -Path $statusPath)
            if ($statusPayload.Count -gt 0) {
                $finalStatuses = $statusPayload
                $lastStatus = [string]$statusPayload[$statusPayload.Count - 1].status
                Write-TestStep "Job $jobId [$audioLabel] status: $lastStatus"

                if ($lastStatus -eq "ready" -and $null -ne $resultPath -and (Test-Path $resultPath) -and $null -ne $outputMarkerPath -and (Test-Path $outputMarkerPath)) {
                    $jobSucceeded = $true
                    break
                }

                if ($lastStatus -eq "failed") {
                    break
                }
            }
        }

        Start-Sleep -Seconds 1
    }

    Assert-True "job completed successfully [$audioLabel]" $jobSucceeded
    if (-not $jobSucceeded) {
        if ($finalStatuses.Count -gt 0) {
            Write-TestStep "Last known statuses [$audioLabel]: $((@($finalStatuses | ForEach-Object { $_.status })) -join ' -> ')"
            $lastEntry = $finalStatuses[$finalStatuses.Count - 1]
            if ($null -ne $lastEntry.error) {
                Write-TestStep "Last error [$audioLabel]: $($lastEntry.error)"
            }
        }
        Write-TestStep "stderr tail [$audioLabel]:"
        Write-Host (Get-LogTail -Path $stderrLogPath)
        Complete-TestRun
    }

    $resultPayload = Read-JsonFile -Path $resultPath
    $plainResultPath = Join-Path $dataDir "result_plain.txt"
    $timestampResultPath = Join-Path $dataDir "result_timestamp.txt"
    $statusNames = @($finalStatuses | ForEach-Object { $_.status })

    Assert-Contains "status progression includes processing [$audioLabel]" ($statusNames -join ",") "processing"
    Assert-Equal "final status is ready [$audioLabel]" "ready" $statusNames[$statusNames.Count - 1]
    Assert-True "drop file consumed from input dir [$audioLabel]" (-not (Test-Path $droppedInputPath))
    Assert-True "data dir input exists [$audioLabel]" (Test-Path (Join-Path $dataDir "input"))
    Assert-True "output marker exists [$audioLabel]" (Test-Path $outputMarkerPath)
    Assert-True "plain result exists [$audioLabel]" (Test-Path $plainResultPath)
    Assert-True "timestamp result exists [$audioLabel]" (Test-Path $timestampResultPath)
    Assert-NotNull "result normalized text exists [$audioLabel]" $resultPayload.normalized.text
    Assert-NotNull "result raw text exists [$audioLabel]" $resultPayload.raw.text

    $plainResultText = (Get-Content -Raw $plainResultPath).Trim()
    $timestampResultText = Get-Content -Raw $timestampResultPath
    Assert-Equal "plain result matches normalized text [$audioLabel]" ([string]$resultPayload.normalized.text).Trim() $plainResultText
    Assert-Contains "timestamp result contains range marker [$audioLabel]" $timestampResultText "-->"
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

    if ($null -ne $dataDir) {
        Write-TestStep "Artifacts preserved for inspection [$audioLabel]: $dataDir"
    }
    Write-TestStep "stdout log [$audioLabel]: $stdoutLogPath"
    Write-TestStep "stderr log [$audioLabel]: $stderrLogPath"
}

Complete-TestRun