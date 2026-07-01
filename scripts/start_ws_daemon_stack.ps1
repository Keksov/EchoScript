# Start the ws-daemon transcription stack:
#   - whisperdaemon (FPC WS server, file-API: describe/health/transcribe_file)
#   - orchestrator (file-daemon: watches jobs/, converts audio, drives the daemon)
#
# The orchestrator routes models listed in config.json "ws_daemons" to the daemon
# (transcribe_file) instead of spawning a python worker. Leaves both running.
#
# Run:  pwsh -NoProfile -File scripts\start_ws_daemon_stack.ps1
param(
    [int]$Port = 3000,
    [int]$DaemonPort = 7801
)

$ErrorActionPreference = "Stop"
# Local services must bypass any system HTTP proxy.
$PSDefaultParameterValues['Invoke-RestMethod:NoProxy'] = $true

$repoRoot = Split-Path -Parent $PSScriptRoot
$daemonExe = Join-Path $repoRoot "services\whisperdaemon\build\x64\WhisperDaemon.exe"
$orchestratorDir = Join-Path $repoRoot "orchestrator"
$logDir = Join-Path $repoRoot "services\whisperdaemon\logs"
$base = "http://127.0.0.1:$Port"

function Test-PortOpen([int]$p) {
    try { $c = New-Object System.Net.Sockets.TcpClient; $c.Connect("127.0.0.1", $p); $c.Close(); return $true }
    catch { return $false }
}

function Wait-Until([scriptblock]$cond, [int]$sec, [string]$what) {
    $deadline = (Get-Date).AddSeconds($sec)
    while ((Get-Date) -lt $deadline) {
        try { if (& $cond) { return $true } } catch {}
        Start-Sleep -Milliseconds 500
    }
    throw "Timed out waiting for $what"
}

if (-not (Test-Path $daemonExe)) {
    throw "WhisperDaemon.exe not found: $daemonExe`nBuild it: services\whisperdaemon\app\scripts\build_x64.bat"
}
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

# --- whisperdaemon ---
if (Test-PortOpen $DaemonPort) {
    Write-Host "[stack] whisperdaemon already listening on $DaemonPort (reusing)"
    $daemonPid = $null
} else {
    Write-Host "[stack] starting whisperdaemon on $DaemonPort ..."
    $dOut = Join-Path $logDir "whisperdaemon.stdout.log"
    $dErr = Join-Path $logDir "whisperdaemon.stderr.log"
    $dp = Start-Process -FilePath $daemonExe -ArgumentList '--host','127.0.0.1','--port',"$DaemonPort" `
        -WorkingDirectory $repoRoot -PassThru -WindowStyle Minimized -RedirectStandardOutput $dOut -RedirectStandardError $dErr
    $daemonPid = $dp.Id
    Wait-Until { Test-PortOpen $DaemonPort } 30 "whisperdaemon port"
}

# --- orchestrator ---
Write-Host "[stack] starting orchestrator on $Port ..."
$env:ECHOSCRIPT_PORT = "$Port"
$oOut = Join-Path $logDir "orchestrator.stdout.log"
$oErr = Join-Path $logDir "orchestrator.stderr.log"
$op = Start-Process -FilePath "bun" -ArgumentList 'run','src/index.ts' `
    -WorkingDirectory $orchestratorDir -PassThru -WindowStyle Minimized `
    -RedirectStandardOutput $oOut -RedirectStandardError $oErr
$orchPid = $op.Id
Wait-Until { (Invoke-RestMethod -Uri "$base/" -TimeoutSec 3).status -eq "ok" } 30 "orchestrator health"

Write-Host ""
Write-Host "[stack] READY"
Write-Host "  whisperdaemon: ws://127.0.0.1:$DaemonPort/   (PID $daemonPid)"
Write-Host "  orchestrator:  $base   (PID $orchPid)"
Write-Host ""
Write-Host "  Submit a file:"
Write-Host "    curl -x '' -s -XPOST $base/add_file -H 'content-type: application/json' -d '{\""path\"":\""<abs audio path>\"",\""model\"":\""whisper_podlodka\""}'"
Write-Host "    curl -x '' -s -XPOST $base/run_job  -H 'content-type: application/json' -d '{\""job_id\"":\""<id>\"",\""params\"":{\""language\"":\""ru\""}}'"
Write-Host "    curl -x '' -s   '$base/get_job_status?job_id=<id>'"
Write-Host ""
Write-Host "  Stop:  Stop-Process -Id $orchPid$(if ($daemonPid) { \", $daemonPid\" })"
