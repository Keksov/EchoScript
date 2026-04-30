# Benchmark Russian command-mode latency using prepared fixtures in tests/audio/commands/ru.
# Run: pwsh tests/bench/test-command-latency.ps1

param(
    [string]$CommandsRoot = "",
    [int]$WarmRunsPerCommand = 3,
    [int]$StartupTimeoutSeconds = 120,
    [int]$RequestTimeoutSeconds = 120,
    [switch]$KeepOrchestratorRunning
)

. "$PSScriptRoot\..\helpers\common.ps1"

function Resolve-CommandsRoot {
    param([string]$RequestedPath)

    if ($RequestedPath.Length -gt 0) {
        return [System.IO.Path]::GetFullPath($RequestedPath)
    }

    return [System.IO.Path]::GetFullPath((Join-Path (Join-Path (Join-Path (Get-TestProjectRoot) "tests") "audio") "commands\ru"))
}

function Get-CommandFixtures {
    param([string]$RootPath)

    if (-not (Test-Path $RootPath)) {
        return @()
    }

    return @(
        Get-ChildItem -Path $RootPath -File | Where-Object {
            $Script:SupportedAudioExtensions -contains $_.Extension.ToLowerInvariant()
        } | Sort-Object Name
    )
}

function Normalize-CommandText {
    param([string]$Text)

    $normalized = $Text.ToLowerInvariant().Replace("ё", "е")
    $normalized = [System.Text.RegularExpressions.Regex]::Replace($normalized, "[^\p{L}\p{Nd}\s-]", " ")
    $normalized = [System.Text.RegularExpressions.Regex]::Replace($normalized, "\s+", " ")
    return $normalized.Trim()
}

function Invoke-CommandRecognizeRequest {
    param(
        [string]$AudioPath,
        [int]$TimeoutSeconds
    )

    $audioBytes = [System.IO.File]::ReadAllBytes($AudioPath)
    $uriBuilder = [System.UriBuilder]::new([uri](Get-TestBaseUrl))
    $uriBuilder.Path = "/api/v2/speech/recognize"
    $uriBuilder.Query = "mode=command&language=ru"

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $response = Invoke-WebRequest -Uri $uriBuilder.Uri.AbsoluteUri -Method Post -Body $audioBytes -ContentType "application/octet-stream" -TimeoutSec $TimeoutSeconds -SkipHttpErrorCheck
    } catch {
        $stopwatch.Stop()
        return @{
            Ok = $false
            StatusCode = 0
            Error = $_.Exception.Message
            ElapsedMs = [int][Math]::Round($stopwatch.Elapsed.TotalMilliseconds)
        }
    }
    $stopwatch.Stop()

    $payload = $null
    if ($null -ne $response.Content -and $response.Content.Length -gt 0) {
        try {
            $payload = $response.Content | ConvertFrom-Json -NoEnumerate
        } catch {
            $payload = $response.Content
        }
    }

    return @{
        Ok = ($response.StatusCode -ge 200 -and $response.StatusCode -lt 300)
        StatusCode = [int]$response.StatusCode
        Data = $payload
        Error = if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 300) { $null } else { $payload }
        ElapsedMs = [int][Math]::Round($stopwatch.Elapsed.TotalMilliseconds)
    }
}

function New-BenchmarkRecord {
    param(
        [string]$Phase,
        [int]$Iteration,
        [System.IO.FileInfo]$AudioFile,
        [hashtable]$Response
    )

    $expectedText = Normalize-CommandText -Text $AudioFile.BaseName
    $actualText = if ($Response.Ok -and $null -ne $Response.Data) {
        Normalize-CommandText -Text ([string]$Response.Data.text)
    } else {
        ""
    }

    return [pscustomobject]@{
        phase = $Phase
        iteration = $Iteration
        file_name = $AudioFile.Name
        expected_text = $expectedText
        actual_text = $actualText
        matched = ($expectedText -eq $actualText)
        elapsed_ms = [int]$Response.ElapsedMs
        status_code = [int]$Response.StatusCode
        target_model = if ($Response.Ok -and $null -ne $Response.Data) { [string]$Response.Data.target_model } else { "" }
        ok = [bool]$Response.Ok
        error = if ($null -ne $Response.Error) { [string]($Response.Error | ConvertTo-Json -Compress) } else { "" }
    }
}

function Get-LatencySummary {
    param(
        [string]$Label,
        [object[]]$Records
    )

    if ($Records.Count -eq 0) {
        return $null
    }

    $sortedValues = @($Records | ForEach-Object { [double]$_.elapsed_ms } | Sort-Object)
    $indexOf = {
        param([double]$Percentile)

        if ($sortedValues.Count -eq 1) {
            return 0
        }

        return [int][Math]::Ceiling(($sortedValues.Count - 1) * $Percentile)
    }

    return [pscustomobject]@{
        label = $Label
        count = $sortedValues.Count
        min_ms = [int]$sortedValues[0]
        p50_ms = [int]$sortedValues[(& $indexOf 0.50)]
        p95_ms = [int]$sortedValues[(& $indexOf 0.95)]
        max_ms = [int]$sortedValues[$sortedValues.Count - 1]
        avg_ms = [int][Math]::Round(($sortedValues | Measure-Object -Average).Average)
    }
}

function Write-LatencySummary {
    param([pscustomobject]$Summary)

    if ($null -eq $Summary) {
        return
    }

    Write-Host ("  count={0} min={1}ms p50={2}ms p95={3}ms avg={4}ms max={5}ms" -f $Summary.count, $Summary.min_ms, $Summary.p50_ms, $Summary.p95_ms, $Summary.avg_ms, $Summary.max_ms) -ForegroundColor DarkGray
}

$resolvedCommandsRoot = Resolve-CommandsRoot -RequestedPath $CommandsRoot
$commandFixtures = @(Get-CommandFixtures -RootPath $resolvedCommandsRoot)

Write-TestHeader "Command latency benchmark"
Write-TestStep "Commands root: $resolvedCommandsRoot"
Write-TestStep "Fixture count: $($commandFixtures.Count)"
Write-TestStep "Warm runs per command: $WarmRunsPerCommand"

Assert-True "commands fixture directory exists" (Test-Path $resolvedCommandsRoot)
Assert-GreaterThan "at least one command fixture is present" $commandFixtures.Count 0
if (-not (Test-Path $resolvedCommandsRoot) -or $commandFixtures.Count -eq 0) {
    Complete-TestRun
}

$records = New-Object System.Collections.Generic.List[object]

try {
    foreach ($audioFile in $commandFixtures) {
        Write-TestHeader ("Cold start: {0}" -f $audioFile.Name)
        Stop-TestOrchestrator | Out-Null
        Start-TestOrchestrator -StartupTimeoutSeconds $StartupTimeoutSeconds | Out-Null

        $coldResponse = Invoke-CommandRecognizeRequest -AudioPath $audioFile.FullName -TimeoutSeconds $RequestTimeoutSeconds
        $coldRecord = New-BenchmarkRecord -Phase "cold" -Iteration 1 -AudioFile $audioFile -Response $coldResponse
        $records.Add($coldRecord) | Out-Null

        Assert-True ("cold request succeeds for {0}" -f $audioFile.Name) $coldResponse.Ok
        if (-not $coldResponse.Ok) {
            Write-TestStep ("cold failure: status={0} error={1}" -f $coldResponse.StatusCode, $coldRecord.error)
            continue
        }

        Assert-Equal ("cold route stays on vosk_ru_cmd for {0}" -f $audioFile.Name) "vosk_ru_cmd" ([string]$coldResponse.Data.target_model)
        Assert-True ("cold transcript matches fixture name for {0}" -f $audioFile.Name) $coldRecord.matched
        Write-TestStep ("elapsed={0}ms expected='{1}' actual='{2}'" -f $coldRecord.elapsed_ms, $coldRecord.expected_text, $coldRecord.actual_text)
    }

    Write-TestHeader "Warm phase"
    Stop-TestOrchestrator | Out-Null
    Start-TestOrchestrator -StartupTimeoutSeconds $StartupTimeoutSeconds | Out-Null

    $warmupFixture = $commandFixtures[0]
    $warmupResponse = Invoke-CommandRecognizeRequest -AudioPath $warmupFixture.FullName -TimeoutSeconds $RequestTimeoutSeconds
    Assert-True "warmup request succeeds" $warmupResponse.Ok
    if ($warmupResponse.Ok) {
        Assert-Equal "warmup route stays on vosk_ru_cmd" "vosk_ru_cmd" ([string]$warmupResponse.Data.target_model)
    }

    foreach ($audioFile in $commandFixtures) {
        for ($iteration = 1; $iteration -le $WarmRunsPerCommand; $iteration++) {
            $warmResponse = Invoke-CommandRecognizeRequest -AudioPath $audioFile.FullName -TimeoutSeconds $RequestTimeoutSeconds
            $warmRecord = New-BenchmarkRecord -Phase "warm" -Iteration $iteration -AudioFile $audioFile -Response $warmResponse
            $records.Add($warmRecord) | Out-Null

            Assert-True ("warm request succeeds for {0} run {1}" -f $audioFile.Name, $iteration) $warmResponse.Ok
            if (-not $warmResponse.Ok) {
                Write-TestStep ("warm failure: status={0} error={1}" -f $warmResponse.StatusCode, $warmRecord.error)
                continue
            }

            Assert-Equal ("warm route stays on vosk_ru_cmd for {0} run {1}" -f $audioFile.Name, $iteration) "vosk_ru_cmd" ([string]$warmResponse.Data.target_model)
            Assert-True ("warm transcript matches fixture name for {0} run {1}" -f $audioFile.Name, $iteration) $warmRecord.matched
            Write-TestStep ("{0} run {1}: elapsed={2}ms expected='{3}' actual='{4}'" -f $audioFile.Name, $iteration, $warmRecord.elapsed_ms, $warmRecord.expected_text, $warmRecord.actual_text)
        }
    }

    $coldRecords = @($records | Where-Object { $_.phase -eq "cold" -and $_.ok })
    $warmRecords = @($records | Where-Object { $_.phase -eq "warm" -and $_.ok })
    $coldSummary = Get-LatencySummary -Label "cold" -Records $coldRecords
    $warmSummary = Get-LatencySummary -Label "warm" -Records $warmRecords

    Write-TestHeader "Latency summary"
    if ($null -ne $coldSummary) {
        Write-Host "Cold:" -ForegroundColor Cyan
        Write-LatencySummary -Summary $coldSummary
    }
    if ($null -ne $warmSummary) {
        Write-Host "Warm:" -ForegroundColor Cyan
        Write-LatencySummary -Summary $warmSummary
    }

    $report = @{
        generated_at = (Get-Date).ToString("o")
        commands_root = $resolvedCommandsRoot
        target_model = "vosk_ru_cmd"
        warm_runs_per_command = $WarmRunsPerCommand
        cold = $coldSummary
        warm = $warmSummary
        records = @($records.ToArray())
    }
    $reportPath = Join-Path (Get-TestLogsRoot) ("command-latency.{0}.json" -f (Get-TestRunId))
    $report | ConvertTo-Json -Depth 6 | Set-Content -Path $reportPath -Encoding UTF8
    Write-TestStep "Benchmark report written to $reportPath"
}
finally {
    if (-not $KeepOrchestratorRunning) {
        Stop-TestOrchestrator | Out-Null
    }
}

Complete-TestRun