# Sync the shared package into all configured service virtual environments.
# Run: pwsh tests/sync-shared-package.ps1

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\helpers\common.ps1"

$projectRoot = Get-TestProjectRoot
$sharedPath = Join-Path $projectRoot "shared"
$config = Get-TestConfig
$updatedModels = @()
$skippedModels = @()

Write-Host "Syncing shared package into configured service virtual environments" -ForegroundColor Cyan
Write-Host "Shared path: $sharedPath" -ForegroundColor DarkGray

foreach ($modelProperty in $config.models.PSObject.Properties) {
    $modelName = [string]$modelProperty.Name
    $modelConfig = $modelProperty.Value
    $pythonExecutable = Resolve-TestPythonExecutablePath -ProjectRoot $projectRoot -ConfiguredPath ([string]$modelConfig.python_executable)

    if (-not (Test-Path $pythonExecutable)) {
        Write-Host "SKIP: $modelName - virtual environment not found at $pythonExecutable" -ForegroundColor Yellow
        $skippedModels += $modelName
        continue
    }

    Write-Host "UPDATE: $modelName" -ForegroundColor Green
    Write-Host "  Python: $pythonExecutable" -ForegroundColor DarkGray

    & $pythonExecutable -m pip install -e $sharedPath
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to install shared package for $modelName"
    }

    & $pythonExecutable -c "import echoscript_shared; import watchdog"
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to verify shared/watchdog imports for $modelName"
    }

    $updatedModels += $modelName
}

if ($updatedModels.Count -eq 0) {
    throw "No configured service virtual environments were found"
}

Write-Host "" 
Write-Host "Updated models: $($updatedModels -join ', ')" -ForegroundColor Green
if ($skippedModels.Count -gt 0) {
    Write-Host "Skipped models without local virtual environments: $($skippedModels -join ', ')" -ForegroundColor Yellow
}