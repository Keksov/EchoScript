# Stop the isolated test orchestrator.
# Run: pwsh tests/stop-test-orchestrator.ps1

. "$PSScriptRoot\helpers\common.ps1"

if (Stop-TestOrchestrator) {
    Write-Host "Test orchestrator stopped" -ForegroundColor Green
} else {
    Write-Host "No test orchestrator pid file found" -ForegroundColor Yellow
}