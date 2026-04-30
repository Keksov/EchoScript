# Compare Russian command recognition latency and accuracy across two models.
# Run: pwsh tests/bench/test-command-model-compare.ps1

param(
    [string]$CommandsRoot = "",
    [string]$PrimaryModel = "vosk_ru_cmd",
    [string]$CompareWithModel = "vosk_ru",
    [int]$WarmRunsPerCommand = 3,
    [int]$StartupTimeoutSeconds = 120,
    [int]$RequestTimeoutSeconds = 120,
    [int]$ComparisonRequestTimeoutSeconds = 300,
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

function Get-ConfiguredCommandGrammar {
    $config = Get-TestConfig
    if ($null -eq $config.speech -or $null -eq $config.speech.command_grammars -or $null -eq $config.speech.command_grammars.ru) {
        return @()
    }

    return @(
        $config.speech.command_grammars.ru | Where-Object {
            $_ -is [string] -and $_.Trim().Length -gt 0
        } | ForEach-Object {
            [string]$_.Trim()
        } | Select-Object -Unique
    )
}

function New-CommandParams {
    param([string[]]$Grammar)

    $params = @{
        language = "ru"
        punctuation = $false
        speaker_embeddings = $false
        timestamps = $false
        word_timestamps = $false
    }

    if ($Grammar.Count -gt 0) {
        $params["grammar"] = @($Grammar)
    }

    return $params
}

function Wait-ForJobReady {
    param(
        [string]$JobId,
        [int]$TimeoutSeconds,
        [int]$PollIntervalMilliseconds = 200
    )

    $deadline = [System.DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([System.DateTimeOffset]::UtcNow -lt $deadline) {
        $statusResult = Get-JobStatus -JobId $JobId
        if ($statusResult.Ok -and $statusResult.Data -is [System.Array] -and $statusResult.Data.Count -gt 0) {
            $lastEntry = $statusResult.Data[$statusResult.Data.Count - 1]
            $lastStatus = [string]$lastEntry.status
            if ($lastStatus -eq "ready") {
                return @{
                    Ok = $true
                    Statuses = $statusResult.Data
                }
            }

            if ($lastStatus -eq "failed") {
                return @{
                    Ok = $false
                    Error = [string]$lastEntry.error
                    Statuses = $statusResult.Data
                }
            }
        }

        Start-Sleep -Milliseconds $PollIntervalMilliseconds
    }

    return @{
        Ok = $false
        Error = "Timed out after $TimeoutSeconds seconds"
        Statuses = @()
    }
}

function Invoke-ModelRecognizeRequest {
    param(
        [string]$AudioPath,
        [string]$ModelName,
        [hashtable]$Params,
        [int]$TimeoutSeconds
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $jobId = ""

    try {
        $createdJob = Add-BodyJob -AudioPath $AudioPath -Model $ModelName -Source "command_model_compare"
        if (-not $createdJob.Ok) {
            $stopwatch.Stop()
            return @{
                Ok = $false
                StatusCode = [int]$createdJob.StatusCode
                Error = if ($null -ne $createdJob.Error) { $createdJob.Error } else { "add_body failed" }
                ElapsedMs = [int][Math]::Round($stopwatch.Elapsed.TotalMilliseconds)
            }
        }

        $jobId = [string]$createdJob.Data.job_id
        $runResult = Start-JobRun -JobId $jobId -Params $Params
        if (-not $runResult.Ok) {
            $stopwatch.Stop()
            return @{
                Ok = $false
                StatusCode = [int]$runResult.StatusCode
                Error = if ($null -ne $runResult.Error) { $runResult.Error } else { "run_job failed" }
                ElapsedMs = [int][Math]::Round($stopwatch.Elapsed.TotalMilliseconds)
            }
        }

        $waitResult = Wait-ForJobReady -JobId $jobId -TimeoutSeconds $TimeoutSeconds
        if (-not $waitResult.Ok) {
            $stopwatch.Stop()
            return @{
                Ok = $false
                StatusCode = 0
                Error = $waitResult.Error
                ElapsedMs = [int][Math]::Round($stopwatch.Elapsed.TotalMilliseconds)
            }
        }

        $result = Get-JobResult -JobId $jobId
        if (-not $result.Ok) {
            $stopwatch.Stop()
            return @{
                Ok = $false
                StatusCode = [int]$result.StatusCode
                Error = if ($null -ne $result.Error) { $result.Error } else { "get_job_result failed" }
                ElapsedMs = [int][Math]::Round($stopwatch.Elapsed.TotalMilliseconds)
            }
        }

        $stopwatch.Stop()

        $normalized = if ($null -ne $result.Data -and $null -ne $result.Data.normalized) {
            $result.Data.normalized
        } else {
            $null
        }
        $raw = if ($null -ne $result.Data -and $null -ne $result.Data.raw) {
            $result.Data.raw
        } else {
            $null
        }
        $recognizedText = if ($null -ne $normalized -and $null -ne $normalized.text) {
            [string]$normalized.text
        } elseif ($null -ne $result.Data -and $null -ne $result.Data.text) {
            [string]$result.Data.text
        } else {
            ""
        }

        return @{
            Ok = $true
            StatusCode = [int]$result.StatusCode
            Data = @{
                text = $recognizedText
                normalized = $normalized
                raw = $raw
                target_model = [string]$runResult.Data.target_model
            }
            ElapsedMs = [int][Math]::Round($stopwatch.Elapsed.TotalMilliseconds)
        }
    }
    catch {
        $stopwatch.Stop()
        return @{
            Ok = $false
            StatusCode = 0
            Error = $_.Exception.Message
            ElapsedMs = [int][Math]::Round($stopwatch.Elapsed.TotalMilliseconds)
        }
    }
    finally {
        if ($jobId.Length -gt 0) {
            try {
                Remove-Job -JobId $jobId | Out-Null
            }
            catch {
            }
        }
    }
}

function New-BenchmarkRecord {
    param(
        [string]$ProfileName,
        [string]$ModelName,
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
        profile_name = $ProfileName
        model_name = $ModelName
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
        [string]$ProfileName,
        [string]$ModelName,
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
        profile_name = $ProfileName
        model_name = $ModelName
        label = $Label
        count = $sortedValues.Count
        min_ms = [int]$sortedValues[0]
        p50_ms = [int]$sortedValues[(& $indexOf 0.50)]
        p95_ms = [int]$sortedValues[(& $indexOf 0.95)]
        max_ms = [int]$sortedValues[$sortedValues.Count - 1]
        avg_ms = [int][Math]::Round(($sortedValues | Measure-Object -Average).Average)
    }
}

function Get-AccuracySummary {
    param([object[]]$Records)

    if ($Records.Count -eq 0) {
        return $null
    }

    $matchedCount = @($Records | Where-Object { $_.matched }).Count
    $mismatchedCount = $Records.Count - $matchedCount

    return [pscustomobject]@{
        total = $Records.Count
        matched = $matchedCount
        mismatched = $mismatchedCount
        match_rate_pct = [Math]::Round((100.0 * $matchedCount) / $Records.Count, 1)
    }
}

function Get-AvailabilitySummary {
    param([object[]]$Records)

    if ($Records.Count -eq 0) {
        return $null
    }

    $successfulCount = @($Records | Where-Object { $_.ok }).Count
    $failedCount = $Records.Count - $successfulCount

    return [pscustomobject]@{
        total = $Records.Count
        successful = $successfulCount
        failed = $failedCount
        success_rate_pct = [Math]::Round((100.0 * $successfulCount) / $Records.Count, 1)
    }
}

function Write-LatencySummary {
    param([pscustomobject]$Summary)

    if ($null -eq $Summary) {
        return
    }

    Write-Host ("  count={0} min={1}ms p50={2}ms p95={3}ms avg={4}ms max={5}ms" -f $Summary.count, $Summary.min_ms, $Summary.p50_ms, $Summary.p95_ms, $Summary.avg_ms, $Summary.max_ms) -ForegroundColor DarkGray
}

function New-BenchmarkProfile {
    param(
        [string]$Name,
        [string]$ModelName,
        [hashtable]$Params,
        [string]$GrammarMode,
        [bool]$RequireTranscriptMatch,
        [bool]$RequireSuccessfulRuns,
        [int]$PerRequestTimeoutSeconds
    )

    return [pscustomobject]@{
        Name = $Name
        ModelName = $ModelName
        Params = $Params
        GrammarMode = $GrammarMode
        RequireTranscriptMatch = $RequireTranscriptMatch
        RequireSuccessfulRuns = $RequireSuccessfulRuns
        PerRequestTimeoutSeconds = $PerRequestTimeoutSeconds
    }
}

function Invoke-BenchmarkProfile {
    param(
        [pscustomobject]$Profile,
        [System.IO.FileInfo[]]$Fixtures,
        [int]$WarmRunsPerCommand,
        [int]$StartupTimeoutSeconds,
        [System.Collections.Generic.List[object]]$Records
    )

    foreach ($audioFile in $Fixtures) {
        Write-TestHeader ("{0} cold start: {1}" -f $Profile.Name, $audioFile.Name)
        Stop-TestOrchestrator | Out-Null
        Start-TestOrchestrator -StartupTimeoutSeconds $StartupTimeoutSeconds | Out-Null

        $coldResponse = Invoke-ModelRecognizeRequest -AudioPath $audioFile.FullName -ModelName $Profile.ModelName -Params $Profile.Params -TimeoutSeconds $Profile.PerRequestTimeoutSeconds
        $coldRecord = New-BenchmarkRecord -ProfileName $Profile.Name -ModelName $Profile.ModelName -Phase "cold" -Iteration 1 -AudioFile $audioFile -Response $coldResponse
        $Records.Add($coldRecord) | Out-Null

        if ($Profile.RequireSuccessfulRuns) {
            Assert-True ("{0} cold request succeeds for {1}" -f $Profile.Name, $audioFile.Name) $coldResponse.Ok
        }
        if (-not $coldResponse.Ok) {
            Write-TestStep ("cold failure: status={0} error={1}" -f $coldResponse.StatusCode, $coldRecord.error)
            continue
        }

        Assert-Equal ("{0} cold route stays on {1} for {2}" -f $Profile.Name, $Profile.ModelName, $audioFile.Name) $Profile.ModelName ([string]$coldResponse.Data.target_model)
        if ($Profile.RequireTranscriptMatch) {
            Assert-True ("{0} cold transcript matches fixture name for {1}" -f $Profile.Name, $audioFile.Name) $coldRecord.matched
        }
        Write-TestStep ("elapsed={0}ms expected='{1}' actual='{2}'" -f $coldRecord.elapsed_ms, $coldRecord.expected_text, $coldRecord.actual_text)
        if (-not $coldRecord.matched) {
            Write-TestStep ("transcript mismatch recorded for {0}: expected='{1}' actual='{2}'" -f $audioFile.Name, $coldRecord.expected_text, $coldRecord.actual_text)
        }
    }

    Write-TestHeader ("{0} warm phase" -f $Profile.Name)
    Stop-TestOrchestrator | Out-Null
    Start-TestOrchestrator -StartupTimeoutSeconds $StartupTimeoutSeconds | Out-Null

    $warmupFixture = $Fixtures[0]
    $warmupResponse = Invoke-ModelRecognizeRequest -AudioPath $warmupFixture.FullName -ModelName $Profile.ModelName -Params $Profile.Params -TimeoutSeconds $Profile.PerRequestTimeoutSeconds
    if ($Profile.RequireSuccessfulRuns) {
        Assert-True ("{0} warmup request succeeds" -f $Profile.Name) $warmupResponse.Ok
    }
    if ($warmupResponse.Ok) {
        Assert-Equal ("{0} warmup route stays on {1}" -f $Profile.Name, $Profile.ModelName) $Profile.ModelName ([string]$warmupResponse.Data.target_model)
    } else {
        Write-TestStep ("warmup failure recorded: status={0} error={1}" -f $warmupResponse.StatusCode, ($warmupResponse.Error | ConvertTo-Json -Compress))
    }

    foreach ($audioFile in $Fixtures) {
        for ($iteration = 1; $iteration -le $WarmRunsPerCommand; $iteration++) {
            $warmResponse = Invoke-ModelRecognizeRequest -AudioPath $audioFile.FullName -ModelName $Profile.ModelName -Params $Profile.Params -TimeoutSeconds $Profile.PerRequestTimeoutSeconds
            $warmRecord = New-BenchmarkRecord -ProfileName $Profile.Name -ModelName $Profile.ModelName -Phase "warm" -Iteration $iteration -AudioFile $audioFile -Response $warmResponse
            $Records.Add($warmRecord) | Out-Null

            if ($Profile.RequireSuccessfulRuns) {
                Assert-True ("{0} warm request succeeds for {1} run {2}" -f $Profile.Name, $audioFile.Name, $iteration) $warmResponse.Ok
            }
            if (-not $warmResponse.Ok) {
                Write-TestStep ("warm failure: status={0} error={1}" -f $warmResponse.StatusCode, $warmRecord.error)
                continue
            }

            Assert-Equal ("{0} warm route stays on {1} for {2} run {3}" -f $Profile.Name, $Profile.ModelName, $audioFile.Name, $iteration) $Profile.ModelName ([string]$warmResponse.Data.target_model)
            if ($Profile.RequireTranscriptMatch) {
                Assert-True ("{0} warm transcript matches fixture name for {1} run {2}" -f $Profile.Name, $audioFile.Name, $iteration) $warmRecord.matched
            }
            Write-TestStep ("{0} run {1}: elapsed={2}ms expected='{3}' actual='{4}'" -f $audioFile.Name, $iteration, $warmRecord.elapsed_ms, $warmRecord.expected_text, $warmRecord.actual_text)
            if (-not $warmRecord.matched) {
                Write-TestStep ("transcript mismatch recorded for {0} run {1}: expected='{2}' actual='{3}'" -f $audioFile.Name, $iteration, $warmRecord.expected_text, $warmRecord.actual_text)
            }
        }
    }

    $coldRecords = @($Records | Where-Object { $_.profile_name -eq $Profile.Name -and $_.phase -eq "cold" -and $_.ok })
    $warmRecords = @($Records | Where-Object { $_.profile_name -eq $Profile.Name -and $_.phase -eq "warm" -and $_.ok })
    $allRecords = @($Records | Where-Object { $_.profile_name -eq $Profile.Name })
    $allSuccessfulRecords = @($Records | Where-Object { $_.profile_name -eq $Profile.Name -and $_.ok })

    return [pscustomobject]@{
        name = $Profile.Name
        model_name = $Profile.ModelName
        grammar_mode = $Profile.GrammarMode
        cold = Get-LatencySummary -ProfileName $Profile.Name -ModelName $Profile.ModelName -Label "cold" -Records $coldRecords
        warm = Get-LatencySummary -ProfileName $Profile.Name -ModelName $Profile.ModelName -Label "warm" -Records $warmRecords
        availability = Get-AvailabilitySummary -Records $allRecords
        accuracy = Get-AccuracySummary -Records $allSuccessfulRecords
    }
}

function New-ComparisonSummary {
    param(
        [pscustomobject]$PrimarySummary,
        [pscustomobject]$ComparisonSummary
    )

    if ($null -eq $PrimarySummary -or $null -eq $ComparisonSummary -or $null -eq $PrimarySummary.warm -or $null -eq $ComparisonSummary.warm) {
        return $null
    }

    $warmImprovementMs = $ComparisonSummary.warm.avg_ms - $PrimarySummary.warm.avg_ms
    $coldImprovementMs = if ($null -ne $PrimarySummary.cold -and $null -ne $ComparisonSummary.cold) {
        $ComparisonSummary.cold.avg_ms - $PrimarySummary.cold.avg_ms
    } else {
        $null
    }

    return [pscustomobject]@{
        primary_profile = $PrimarySummary.name
        comparison_profile = $ComparisonSummary.name
        warm_avg_improvement_ms = [int]$warmImprovementMs
        warm_speedup_ratio = if ($PrimarySummary.warm.avg_ms -gt 0) { [Math]::Round(($ComparisonSummary.warm.avg_ms / [double]$PrimarySummary.warm.avg_ms), 2) } else { $null }
        cold_avg_improvement_ms = if ($null -ne $coldImprovementMs) { [int]$coldImprovementMs } else { $null }
        cold_speedup_ratio = if ($null -ne $PrimarySummary.cold -and $null -ne $ComparisonSummary.cold -and $PrimarySummary.cold.avg_ms -gt 0) { [Math]::Round(($ComparisonSummary.cold.avg_ms / [double]$PrimarySummary.cold.avg_ms), 2) } else { $null }
        primary_match_rate_pct = if ($null -ne $PrimarySummary.accuracy) { $PrimarySummary.accuracy.match_rate_pct } else { $null }
        comparison_match_rate_pct = if ($null -ne $ComparisonSummary.accuracy) { $ComparisonSummary.accuracy.match_rate_pct } else { $null }
        primary_success_rate_pct = if ($null -ne $PrimarySummary.availability) { $PrimarySummary.availability.success_rate_pct } else { $null }
        comparison_success_rate_pct = if ($null -ne $ComparisonSummary.availability) { $ComparisonSummary.availability.success_rate_pct } else { $null }
    }
}

$resolvedCommandsRoot = Resolve-CommandsRoot -RequestedPath $CommandsRoot
$commandFixtures = @(Get-CommandFixtures -RootPath $resolvedCommandsRoot)
$configuredGrammar = @(Get-ConfiguredCommandGrammar)
$configuredModels = @((Get-TestConfig).models.PSObject.Properties.Name)

Write-TestHeader "Command model comparison benchmark"
Write-TestStep "Commands root: $resolvedCommandsRoot"
Write-TestStep "Fixture count: $($commandFixtures.Count)"
Write-TestStep "Primary model: $PrimaryModel"
Write-TestStep "Comparison model: $CompareWithModel"
Write-TestStep "Warm runs per command: $WarmRunsPerCommand"

Assert-True "commands fixture directory exists" (Test-Path $resolvedCommandsRoot)
Assert-GreaterThan "at least one command fixture is present" $commandFixtures.Count 0
Assert-True "configured command grammar is present" ($configuredGrammar.Count -gt 0)
Assert-True "primary model is configured" ($configuredModels -contains $PrimaryModel)
Assert-True "comparison model is configured" ($configuredModels -contains $CompareWithModel)
if (-not (Test-Path $resolvedCommandsRoot) -or $commandFixtures.Count -eq 0 -or $configuredGrammar.Count -eq 0 -or -not ($configuredModels -contains $PrimaryModel) -or -not ($configuredModels -contains $CompareWithModel)) {
    Complete-TestRun
}

$profiles = @(
    (New-BenchmarkProfile -Name "primary" -ModelName $PrimaryModel -Params (New-CommandParams -Grammar $configuredGrammar) -GrammarMode "configured" -RequireTranscriptMatch $true -RequireSuccessfulRuns $true -PerRequestTimeoutSeconds $RequestTimeoutSeconds)
    (New-BenchmarkProfile -Name "comparison" -ModelName $CompareWithModel -Params (New-CommandParams -Grammar @()) -GrammarMode "open" -RequireTranscriptMatch $false -RequireSuccessfulRuns $false -PerRequestTimeoutSeconds $ComparisonRequestTimeoutSeconds)
)
$records = New-Object System.Collections.Generic.List[object]
$profileSummaries = New-Object System.Collections.Generic.List[object]

try {
    foreach ($profile in $profiles) {
        $profileSummary = Invoke-BenchmarkProfile -Profile $profile -Fixtures $commandFixtures -WarmRunsPerCommand $WarmRunsPerCommand -StartupTimeoutSeconds $StartupTimeoutSeconds -Records $records
        $profileSummaries.Add($profileSummary) | Out-Null

        Write-TestHeader ("{0} latency summary" -f $profile.Name)
        if ($null -ne $profileSummary.cold) {
            Write-Host "Cold:" -ForegroundColor Cyan
            Write-LatencySummary -Summary $profileSummary.cold
        }
        if ($null -ne $profileSummary.warm) {
            Write-Host "Warm:" -ForegroundColor Cyan
            Write-LatencySummary -Summary $profileSummary.warm
        }
        if ($null -ne $profileSummary.availability) {
            Write-TestStep ("availability: successful={0}/{1} ({2}%%)" -f $profileSummary.availability.successful, $profileSummary.availability.total, $profileSummary.availability.success_rate_pct)
        }
        if ($null -ne $profileSummary.accuracy) {
            Write-TestStep ("accuracy: matched={0}/{1} ({2}%%)" -f $profileSummary.accuracy.matched, $profileSummary.accuracy.total, $profileSummary.accuracy.match_rate_pct)
        }
    }

    $comparisonSummary = New-ComparisonSummary -PrimarySummary $profileSummaries[0] -ComparisonSummary $profileSummaries[1]
    if ($null -ne $comparisonSummary) {
        Write-TestHeader "Comparison summary"
        Write-TestStep ("warm avg improvement: {0}ms" -f $comparisonSummary.warm_avg_improvement_ms)
        Write-TestStep ("warm speedup ratio: {0}x" -f $comparisonSummary.warm_speedup_ratio)
        Write-TestStep ("primary success rate: {0}%%" -f $comparisonSummary.primary_success_rate_pct)
        Write-TestStep ("comparison success rate: {0}%%" -f $comparisonSummary.comparison_success_rate_pct)
        Write-TestStep ("primary match rate: {0}%%" -f $comparisonSummary.primary_match_rate_pct)
        Write-TestStep ("comparison match rate: {0}%%" -f $comparisonSummary.comparison_match_rate_pct)
        if ($null -ne $comparisonSummary.cold_avg_improvement_ms) {
            Write-TestStep ("cold avg improvement: {0}ms" -f $comparisonSummary.cold_avg_improvement_ms)
        }
        if ($null -ne $comparisonSummary.cold_speedup_ratio) {
            Write-TestStep ("cold speedup ratio: {0}x" -f $comparisonSummary.cold_speedup_ratio)
        }
    }

    $report = @{
        generated_at = (Get-Date).ToString("o")
        commands_root = $resolvedCommandsRoot
        warm_runs_per_command = $WarmRunsPerCommand
        configured_command_grammar = @($configuredGrammar)
        profiles = @($profileSummaries.ToArray())
        comparison = $comparisonSummary
        records = @($records.ToArray())
    }
    $reportPath = Join-Path (Get-TestLogsRoot) ("command-model-compare.{0}.json" -f (Get-TestRunId))
    $report | ConvertTo-Json -Depth 6 | Set-Content -Path $reportPath -Encoding UTF8
    Write-TestStep "Benchmark report written to $reportPath"
}
finally {
    if (-not $KeepOrchestratorRunning) {
        Stop-TestOrchestrator | Out-Null
    }
}

Complete-TestRun