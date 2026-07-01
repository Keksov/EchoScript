# E2E: ws-daemon file interface (orchestrator file-daemon + whisperdaemon transcribe_file)
#
# Poднимает whisperdaemon (если не запущен) и оркестратор в изолированном jobs-root,
# кладёт задание через POST /add_file + /run_job, ждёт ready и проверяет артефакты
# и /get_job_result. Exit 0 = pass, 1 = fail.
#
# Run: pwsh -NoProfile -File tests\whisperdaemon-file-api.ps1
param(
    [string]$AudioPath = "",
    [int]$Port = 3099,
    [int]$DaemonPort = 7801,
    [int]$TimeoutSec = 240
)

$ErrorActionPreference = "Stop"
# Local services must not go through the system HTTP proxy.
$PSDefaultParameterValues['Invoke-RestMethod:NoProxy'] = $true
$repoRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($AudioPath)) {
    $AudioPath = Join-Path $repoRoot "EchoRecorder\tests\Два человека.wav"
}

$daemonExe = Join-Path $repoRoot "services\whisperdaemon\build\x64\WhisperDaemon.exe"
$orchestratorDir = Join-Path $repoRoot "orchestrator"
$jobsRoot = Join-Path $env:TEMP ("echo_e2e_" + [guid]::NewGuid().ToString("N"))
$base = "http://127.0.0.1:$Port"

$daemonProc = $null
$orchProc = $null
$startedDaemon = $false
$failed = $false

function Test-PortOpen([int]$p) {
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $c.Connect("127.0.0.1", $p); $c.Close(); return $true
    } catch { return $false }
}

function Wait-Until([scriptblock]$cond, [int]$sec, [string]$what) {
    $deadline = (Get-Date).AddSeconds($sec)
    while ((Get-Date) -lt $deadline) {
        try { if (& $cond) { return $true } } catch {}
        Start-Sleep -Milliseconds 500
    }
    throw "Timed out waiting for $what"
}

try {
    if (-not (Test-Path $daemonExe)) { throw "WhisperDaemon.exe not found: $daemonExe (build it first)" }
    if (-not (Test-Path $AudioPath)) { throw "Audio file not found: $AudioPath" }
    New-Item -ItemType Directory -Force -Path $jobsRoot | Out-Null

    # --- whisperdaemon ---
    if (Test-PortOpen $DaemonPort) {
        Write-Host "[e2e] whisperdaemon already listening on $DaemonPort (reusing)"
    } else {
        Write-Host "[e2e] starting whisperdaemon on $DaemonPort ..."
        $dOut = Join-Path $jobsRoot "daemon.out.log"; $dErr = Join-Path $jobsRoot "daemon.err.log"
        $daemonProc = Start-Process -FilePath $daemonExe -ArgumentList '--host','127.0.0.1','--port',"$DaemonPort" `
            -WorkingDirectory $repoRoot -PassThru -WindowStyle Hidden -RedirectStandardOutput $dOut -RedirectStandardError $dErr
        $startedDaemon = $true
        Wait-Until { Test-PortOpen $DaemonPort } 30 "whisperdaemon port"
    }

    # --- orchestrator (isolated jobs root) ---
    Write-Host "[e2e] starting orchestrator on $Port (jobs=$jobsRoot) ..."
    $oOut = Join-Path $jobsRoot "orch.out.log"; $oErr = Join-Path $jobsRoot "orch.err.log"
    $env:ECHOSCRIPT_JOBS_ROOT = $jobsRoot
    $env:ECHOSCRIPT_PORT = "$Port"
    $orchProc = Start-Process -FilePath "bun" -ArgumentList 'run','src/index.ts' `
        -WorkingDirectory $orchestratorDir -PassThru -WindowStyle Hidden -RedirectStandardOutput $oOut -RedirectStandardError $oErr
    Wait-Until { (Invoke-RestMethod -Uri "$base/" -TimeoutSec 3).status -eq "ok" } 30 "orchestrator health"

    # --- submit job ---
    Write-Host "[e2e] POST /add_file ..."
    $addBody = @{ path = $AudioPath; model = "whisper_podlodka" } | ConvertTo-Json
    $add = Invoke-RestMethod -Uri "$base/add_file" -Method Post -Body $addBody -ContentType "application/json; charset=utf-8"
    $jobId = $add.job_id
    if ([string]::IsNullOrWhiteSpace($jobId)) { throw "add_file returned no job_id" }
    Write-Host "[e2e] job_id=$jobId"

    $runBody = @{ job_id = $jobId; params = @{ language = "ru" } } | ConvertTo-Json
    Invoke-RestMethod -Uri "$base/run_job" -Method Post -Body $runBody -ContentType "application/json; charset=utf-8" | Out-Null

    # --- poll status ---
    Write-Host "[e2e] waiting for ready (up to ${TimeoutSec}s) ..."
    $final = $null
    Wait-Until {
        $st = Invoke-RestMethod -Uri "$base/get_job_status?job_id=$jobId" -TimeoutSec 5
        $script:final = @($st)[-1].status
        $script:final -eq "ready" -or $script:final -eq "failed"
    } $TimeoutSec "job completion"
    if ($final -ne "ready") { throw "job finished with status '$final' (expected ready)" }

    # --- verify artifacts ---
    $dataDir = Join-Path $jobsRoot "data\$jobId"
    foreach ($f in @("result.json","result_plain.txt","result_timestamp.txt")) {
        if (-not (Test-Path (Join-Path $dataDir $f))) { throw "missing artifact: $f" }
    }
    if (-not (Test-Path (Join-Path $jobsRoot "output\$jobId.json"))) { throw "missing output marker" }

    $plain = Invoke-RestMethod -Uri "$base/get_job_result?job_id=$jobId&type=plain" -TimeoutSec 10
    $timestamp = Invoke-RestMethod -Uri "$base/get_job_result?job_id=$jobId&type=timestamp" -TimeoutSec 10
    $json = Invoke-RestMethod -Uri "$base/get_job_result?job_id=$jobId" -TimeoutSec 10

    if ([string]::IsNullOrWhiteSpace([string]$plain)) { throw "result_plain is empty" }
    if (([string]$timestamp) -notmatch "-->") { throw "result_timestamp missing timecodes" }
    if ($json.normalized.segments.Count -lt 1) { throw "normalized has no segments" }

    Write-Host ""
    Write-Host "[e2e] PASS"
    Write-Host ("  status={0} segments={1} lang={2}" -f $final, $json.normalized.segments.Count, $json.normalized.language)
    Write-Host ("  plain[0..80]={0}" -f ([string]$plain).Substring(0, [Math]::Min(80, ([string]$plain).Length)))
    Write-Host ("  timestamp[0..80]={0}" -f ([string]$timestamp).Substring(0, [Math]::Min(80, ([string]$timestamp).Length)))
}
catch {
    $failed = $true
    Write-Host "[e2e] FAIL: $($_.Exception.Message)"
    $oe = Join-Path $jobsRoot "orch.err.log"
    if (Test-Path $oe) { Write-Host "--- orchestrator stderr (tail) ---"; Get-Content $oe -Tail 15 }
}
finally {
    if ($orchProc -and -not $orchProc.HasExited) { Stop-Process -Id $orchProc.Id -Force -ErrorAction SilentlyContinue }
    if ($startedDaemon -and $daemonProc -and -not $daemonProc.HasExited) { Stop-Process -Id $daemonProc.Id -Force -ErrorAction SilentlyContinue }
    Remove-Item -Recurse -Force $jobsRoot -ErrorAction SilentlyContinue
}

if ($failed) { exit 1 } else { exit 0 }
