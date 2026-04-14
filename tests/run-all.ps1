# Run all EchoScript tests manually
# Run: pwsh tests/run-all.ps1

$ErrorActionPreference = "Continue"
$testsRoot = $PSScriptRoot

. "$PSScriptRoot\helpers\common.ps1"

Write-Host "" 
Write-Host "========================================" -ForegroundColor Magenta
Write-Host "  EchoScript Manual Test Suite" -ForegroundColor Magenta
Write-Host "========================================" -ForegroundColor Magenta
Write-Host ""

$jobsRoot = Initialize-TestJobsRoot
Write-Host "Preserving artifacts under: $jobsRoot" -ForegroundColor Cyan

$standaloneSuites = @(
    @{ Label = "Sanity Model Load"; Path = "sanity\test-model-load.ps1" },
    @{ Label = "Sanity Watcher Wake-up"; Path = "sanity\test-watcher-wakeup.ps1" },
    @{ Label = "Sanity Media File Drop"; Path = "sanity\test-media-file-drop.ps1" },
    @{ Label = "Sanity Direct Job"; Path = "sanity\test-direct-model-job.ps1" }
)

$bunSuites = @(
    @{ Label = "API Full Cycle"; Path = "api\test-full-cycle.ps1" },
    @{ Label = "API Contract"; Path = "api\test-endpoints.ps1" },
    @{ Label = "API Job Discovery"; Path = "api\test-job-discovery.ps1" },
    @{ Label = "API Errors"; Path = "api\test-errors.ps1" },
    @{ Label = "E2E Params"; Path = "e2e\test-param-matrix.ps1" },
    @{ Label = "E2E Formats"; Path = "e2e\test-input-formats.ps1" },
    @{ Label = "E2E FIFO"; Path = "e2e\test-queue-fifo.ps1" }
)

$totalFailedSuites = 0

function Invoke-TestSuite {
    param([hashtable]$Suite)

    $fullPath = Join-Path $testsRoot $Suite.Path
    Write-Host "----------------------------------------" -ForegroundColor Yellow
    Write-Host "  $($Suite.Label)" -ForegroundColor Yellow
    Write-Host "  $($Suite.Path)" -ForegroundColor DarkGray
    Write-Host "----------------------------------------" -ForegroundColor Yellow

    if (-not (Test-Path $fullPath)) {
        Write-Host "MISSING: $($Suite.Path)" -ForegroundColor Red
        $script:totalFailedSuites++
        return
    }

    try {
        & $fullPath
    } catch {
        Write-Host "Suite failed: $($_.Exception.Message)" -ForegroundColor Red
        $script:totalFailedSuites++
    }

    Write-Host ""
}

foreach ($suite in $standaloneSuites) {
    Invoke-TestSuite -Suite $suite
}

$orchestratorStarted = $false
try {
    Write-Host "Starting isolated test orchestrator at $(Get-TestBaseUrl)" -ForegroundColor Cyan
    $state = Start-TestOrchestrator
    $orchestratorStarted = $true
    Write-Host "Using test jobs root: $($state.JobsRoot)" -ForegroundColor DarkGray

    foreach ($suite in $bunSuites) {
        Invoke-TestSuite -Suite $suite
    }
} catch {
    Write-Host "Failed to start or run Bun-backed suites: $($_.Exception.Message)" -ForegroundColor Red
    $totalFailedSuites++
} finally {
    if ($orchestratorStarted) {
        Stop-TestOrchestrator | Out-Null
    }
}

Write-Host "========================================" -ForegroundColor Magenta
if ($totalFailedSuites -eq 0) {
    Write-Host "  All test suites passed" -ForegroundColor Green
} else {
    Write-Host "  Failed suites: $totalFailedSuites" -ForegroundColor Red
    throw "One or more test suites failed"
}
Write-Host "========================================" -ForegroundColor Magenta
