# VibeVoice API smoke with longer timeout for CPU inference
# Run: pwsh tests/api/test-vibevoice-smoke.ps1

param(
    [string]$AudioPath = "",
    [int]$TimeoutSeconds = 900,
    [int]$IntervalSeconds = 5
)

. "$PSScriptRoot\..\helpers\common.ps1"

if (-not (Test-OrchestratorRunning)) {
    throw "Test orchestrator is not running"
}

if ($AudioPath.Length -eq 0) {
    $AudioPath = Get-PrimaryTestAudioFile
}

$audioPath = [System.IO.Path]::GetFullPath($AudioPath)
$audioLabel = Get-TestAudioLabel -AudioPath $audioPath

Write-TestHeader "VibeVoice API smoke [$audioLabel]"

$run = Invoke-TestTranscriptionFlow `
    -Label "vibevoice smoke [$audioLabel]" `
    -InputMethod body `
    -AudioPath $audioPath `
    -Model "vibevoice" `
    -Params @{ timestamps = $true; hotwords = @("EchoScript", "VibeVoice"); context_info = "Smoke test for VibeVoice ASR output" } `
    -TimeoutSeconds $TimeoutSeconds `
    -IntervalSeconds $IntervalSeconds

Assert-NotNull "vibevoice smoke run payload exists [$audioLabel]" $run
if ($null -eq $run -or $null -eq $run.Result) {
    Complete-TestRun
}

$segments = @($run.Result.normalized.segments)
Assert-GreaterThan "vibevoice segment count [$audioLabel]" $segments.Count 0
Assert-NotNull "vibevoice normalized text [$audioLabel]" $run.Result.normalized.text

if ($segments.Count -gt 0) {
    $firstSegment = $segments[0]
    Assert-NotNull "vibevoice first segment start [$audioLabel]" $firstSegment.start
    Assert-NotNull "vibevoice first segment end [$audioLabel]" $firstSegment.end
    Assert-NotNull "vibevoice first segment speaker [$audioLabel]" $firstSegment.speaker
    Assert-NotNull "vibevoice first segment text [$audioLabel]" $firstSegment.text
}

$rawKeys = @($run.Result.raw.PSObject.Properties.Name)
Assert-Contains "vibevoice raw contains vendor_segments [$audioLabel]" ($rawKeys -join ",") "vendor_segments"
Assert-Contains "vibevoice raw contains context_info [$audioLabel]" ($rawKeys -join ",") "context_info"

$plainResult = Get-JobResult -JobId $run.JobId -Type "plain"
Assert-True "vibevoice plain result fetch succeeds [$audioLabel]" $plainResult.Ok
if ($plainResult.Ok) {
    Assert-True "vibevoice plain result is string [$audioLabel]" ($plainResult.Data -is [string])
    Assert-Contains "vibevoice plain result contains transcript [$audioLabel]" ([string]$plainResult.Data) ([string]$segments[0].text).Substring(0, [Math]::Min(24, ([string]$segments[0].text).Length))
}

$timestampResult = Get-JobResult -JobId $run.JobId -Type "timestamp"
Assert-True "vibevoice timestamp result fetch succeeds [$audioLabel]" $timestampResult.Ok
if ($timestampResult.Ok) {
    Assert-True "vibevoice timestamp result is string [$audioLabel]" ($timestampResult.Data -is [string])
    Assert-Contains "vibevoice timestamp result contains range marker [$audioLabel]" ([string]$timestampResult.Data) "-->"
    Assert-Contains "vibevoice timestamp result contains speaker [$audioLabel]" ([string]$timestampResult.Data) "[Speaker 0]"
}

$normalizedOnly = Get-JobResult -JobId $run.JobId -Type "normalized"
Assert-True "vibevoice normalized-only fetch succeeds [$audioLabel]" $normalizedOnly.Ok
if ($normalizedOnly.Ok) {
    Assert-NotNull "vibevoice normalized-only text exists [$audioLabel]" $normalizedOnly.Data.text
    Assert-IsArray "vibevoice normalized-only segments array [$audioLabel]" $normalizedOnly.Data.segments
}

$rawOnly = Get-JobResult -JobId $run.JobId -Type "raw"
Assert-True "vibevoice raw-only fetch succeeds [$audioLabel]" $rawOnly.Ok
if ($rawOnly.Ok) {
    Assert-IsArray "vibevoice raw-only vendor segments array [$audioLabel]" $rawOnly.Data.vendor_segments
    Assert-Contains "vibevoice raw-only context_info contains hotwords [$audioLabel]" ([string]$rawOnly.Data.context_info) "EchoScript"
}

Write-TestStep "Artifacts preserved for vibevoice job [$audioLabel]: $($run.JobId)"

Complete-TestRun