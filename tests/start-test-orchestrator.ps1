# Start the isolated test orchestrator.
# Run: pwsh tests/start-test-orchestrator.ps1

. "$PSScriptRoot\helpers\common.ps1"

Write-Host "Preparing isolated test jobs root: $(Get-TestJobsRoot)" -ForegroundColor Cyan
$state = Start-TestOrchestrator
Write-Host "Test orchestrator started at $($state.BaseUrl)" -ForegroundColor Green
Write-Host "Jobs root: $($state.JobsRoot)" -ForegroundColor DarkGray
Write-Host "Stdout log: $($state.StdoutPath)" -ForegroundColor DarkGray
Write-Host "Stderr log: $($state.StderrPath)" -ForegroundColor DarkGray