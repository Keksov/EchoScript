# Direct filesystem test: start Python service, create job files manually, wait for completion.
# Run: pwsh tests/sanity/test-direct-model-job.ps1
# Optional: pwsh tests/sanity/test-direct-model-job.ps1 -ModelName whisper_podlodka

param(
    [string]$ModelName = "whisper_podlodka",
    [string]$AudioPath = "",
    [int]$StartupTimeoutSeconds = 120,
    [int]$ProcessingTimeoutSeconds = 300
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\..\helpers\common.ps1"

function Read-JsonFile {
    param([string]$Path)

    return Get-Content -Raw $Path | ConvertFrom-Json
}

function Write-JsonFile {
    param(
        [string]$Path,
        [object]$Payload
    )

    $Payload | ConvertTo-Json -Depth 10 | Set-Content -Path $Path -Encoding UTF8
}

function Get-LogTail {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        return "<log file missing>"
    }

    return (Get-Content -Path $Path -Tail 40) -join [Environment]::NewLine
}

Write-TestHeader "Direct filesystem model job"

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

$audioFilePaths = if ($AudioPath.Length -gt 0) {
    @([System.IO.Path]::GetFullPath($AudioPath))
} else {
    @(Get-TestAudioFiles)
}

$modelConfig = $modelProperty.Value
$pythonExecutable = Resolve-TestPythonExecutablePath -ProjectRoot $projectRoot -ConfiguredPath ([string]$modelConfig.python_executable)
$serviceDir = [System.IO.Path]::GetFullPath((Join-Path $projectRoot $modelConfig.service_dir))
$jobsRoot = Initialize-TestJobsRoot
$moduleName = [string]$modelConfig.module
$modelInputDir = Join-Path $jobsRoot (Join-Path "input" $ModelName)
$dataRoot = Join-Path $jobsRoot "data"
$outputDir = Join-Path $jobsRoot "output"
$pidPath = Join-Path $projectRoot (Join-Path "services" "$ModelName.pid")
$logsRoot = Join-Path (Get-TestLogsRoot) "sanity"

Write-TestStep "Model: $ModelName"
Write-TestStep "Audio files: $($audioFilePaths.Count)"
Write-TestStep "Python: $pythonExecutable"
Write-TestStep "Service dir: $serviceDir"
Write-TestStep "Jobs root: $jobsRoot"

Assert-GreaterThan "audio fixture count" $audioFilePaths.Count 0
Assert-True "python executable exists" (Test-Path $pythonExecutable)
Assert-True "service directory exists" (Test-Path $serviceDir)
Assert-NotNull "module name exists" $moduleName

if ($audioFilePaths.Count -eq 0 -or -not (Test-Path $pythonExecutable) -or -not (Test-Path $serviceDir) -or $moduleName.Length -eq 0) {
    Complete-TestRun
}

New-Item -ItemType Directory -Force -Path $modelInputDir | Out-Null
New-Item -ItemType Directory -Force -Path $dataRoot | Out-Null
New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
New-Item -ItemType Directory -Force -Path $logsRoot | Out-Null

foreach ($audioFilePath in $audioFilePaths) {
    $audioLabel = Get-TestAudioLabel -AudioPath $audioFilePath
    Write-TestHeader "Direct filesystem model job [$audioLabel]"
    Write-TestStep "Audio: $audioFilePath"

    Assert-True "audio file exists [$audioLabel]" (Test-Path $audioFilePath)
    if (-not (Test-Path $audioFilePath)) {
        continue
    }

    $jobId = New-TestJobId -ModelName $ModelName
    $dataDir = Join-Path $dataRoot $jobId
    $statusPath = Join-Path $dataDir "status.json"
    $inputPath = Join-Path $dataDir "input"
    $inputJsonPath = Join-Path $dataDir "input.json"
    $paramsPath = Join-Path $dataDir "params.json"
    $resultPath = Join-Path $dataDir "result.json"
    $outputMarkerPath = Join-Path $outputDir "$jobId.json"
    $queueMarkerPath = Join-Path $modelInputDir "$jobId.json"
    $stdoutLogPath = Join-Path $logsRoot "$jobId.stdout.log"
    $stderrLogPath = Join-Path $logsRoot "$jobId.stderr.log"

    $serviceProcess = $null
    $serviceStarted = $false
    $jobSucceeded = $false

    try {
        if (Test-Path $pidPath) {
            Remove-Item -Path $pidPath -Force -ErrorAction SilentlyContinue
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
                "250"
            )
            WorkingDirectory = $serviceDir
            RedirectStandardOutput = $stdoutLogPath
            RedirectStandardError = $stderrLogPath
            PassThru = $true
        }
        $serviceProcess = Start-Process @startProcessArgs

        Assert-NotNull "service process started [$audioLabel]" $serviceProcess

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

        Write-TestHeader "Create direct job files [$audioLabel]"
        New-Item -ItemType Directory -Path $dataDir | Out-Null
        Copy-Item -Path $audioFilePath -Destination $inputPath -Force
        Write-JsonFile -Path $inputJsonPath -Payload @{
            job_id = $jobId
            source = [System.IO.Path]::GetFileName($audioFilePath)
        }
        Write-JsonFile -Path $paramsPath -Payload @{
            language = "ru"
            timestamps = $true
            word_timestamps = $false
        }
        Write-JsonFile -Path $statusPath -Payload @(
            @{
                status = "dispatching"
                updated_at = [DateTime]::UtcNow.ToString("o")
            },
            @{
                status = "pending"
                updated_at = [DateTime]::UtcNow.ToString("o")
            }
        )
        Write-JsonFile -Path $queueMarkerPath -Payload @{
            created_at = [DateTime]::UtcNow.ToString("o")
        }

        Assert-True "job queue marker created [$audioLabel]" (Test-Path $queueMarkerPath)
        Assert-True "job status file created [$audioLabel]" (Test-Path $statusPath)

        Write-TestHeader "Wait for direct job completion [$audioLabel]"
        $processingStartedAt = Get-Date
        $finalStatuses = @()
        while (((Get-Date) - $processingStartedAt).TotalSeconds -lt $ProcessingTimeoutSeconds) {
            $serviceProcess.Refresh()
            if ($serviceProcess.HasExited) {
                break
            }

            if (Test-Path $statusPath) {
                $statusPayload = @(Read-JsonFile -Path $statusPath)
                if ($statusPayload.Count -gt 0) {
                    $finalStatuses = $statusPayload
                    $lastStatus = [string]$statusPayload[$statusPayload.Count - 1].status
                    Write-TestStep "Job $jobId [$audioLabel] status: $lastStatus"

                    if ($lastStatus -eq "ready" -and (Test-Path $resultPath) -and (Test-Path $outputMarkerPath)) {
                        $jobSucceeded = $true
                        break
                    }

                    if ($lastStatus -eq "failed") {
                        break
                    }
                }
            }

            Start-Sleep -Seconds 2
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

            Write-TestStep "stdout tail [$audioLabel]:"
            Write-Host (Get-LogTail -Path $stdoutLogPath)
            Write-TestStep "stderr tail [$audioLabel]:"
            Write-Host (Get-LogTail -Path $stderrLogPath)
            Complete-TestRun
        }

        $resultPayload = Read-JsonFile -Path $resultPath
        $statusNames = @($finalStatuses | ForEach-Object { $_.status })

        Assert-Contains "status progression includes processing [$audioLabel]" ($statusNames -join ",") "processing"
        Assert-Equal "final status is ready [$audioLabel]" "ready" $statusNames[$statusNames.Count - 1]
        Assert-True "output marker exists [$audioLabel]" (Test-Path $outputMarkerPath)
        Assert-NotNull "result normalized text exists [$audioLabel]" $resultPayload.normalized.text
        Assert-NotNull "result raw text exists [$audioLabel]" $resultPayload.raw.text
        Assert-IsArray "result normalized segments is array [$audioLabel]" $resultPayload.normalized.segments
        Assert-GreaterThan "result normalized segments count [$audioLabel]" (@($resultPayload.normalized.segments)).Count 0
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

        Write-TestStep "Artifacts preserved for inspection [$audioLabel]: $dataDir"
        Write-TestStep "stdout log [$audioLabel]: $stdoutLogPath"
        Write-TestStep "stderr log [$audioLabel]: $stderrLogPath"
    }
}

Complete-TestRun