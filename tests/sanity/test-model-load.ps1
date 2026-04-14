# Sanity check: start service, load model, exit successfully
# Run: pwsh tests/sanity/test-model-load.ps1
# Optional: pwsh tests/sanity/test-model-load.ps1 -ModelName whisper_podlodka

param(
    [string]$ModelName = "whisper_podlodka"
)

. "$PSScriptRoot\..\helpers\common.ps1"

Write-TestHeader "Sanity model load"

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

$modelConfig = $modelProperty.Value
$pythonExecutable = Resolve-TestPythonExecutablePath -ProjectRoot $projectRoot -ConfiguredPath ([string]$modelConfig.python_executable)
$serviceDir = [System.IO.Path]::GetFullPath((Join-Path $projectRoot $modelConfig.service_dir))
$jobsRoot = Initialize-TestJobsRoot
$moduleName = [string]$modelConfig.module

Write-TestStep "Model: $ModelName"
Write-TestStep "Python: $pythonExecutable"
Write-TestStep "Service dir: $serviceDir"
Write-TestStep "Jobs root: $jobsRoot"
Write-TestStep "Module: $moduleName"

Assert-True "python executable exists" (Test-Path $pythonExecutable)
Assert-True "service directory exists" (Test-Path $serviceDir)
Assert-NotNull "module name exists" $moduleName

if (-not (Test-Path $pythonExecutable) -or -not (Test-Path $serviceDir) -or $moduleName.Length -eq 0) {
    Complete-TestRun
}

$exitCode = -1
Push-Location $serviceDir
try {
    & $pythonExecutable -m $moduleName --jobs-root $jobsRoot --project-root $projectRoot --model-name $ModelName --load-only
    $exitCode = $LASTEXITCODE
} finally {
    Pop-Location
}

Assert-Equal "service exits successfully after model load" 0 $exitCode

Complete-TestRun
