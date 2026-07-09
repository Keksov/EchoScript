<#
.SYNOPSIS
  Launch a daemon WINDOWLESS (output → a combined log) and, when Windows Terminal is
  available, open a lightweight echotail tab that follows that log live. Falls back to a
  minimized window with redirected output when wt.exe/echotail are absent.

.DESCRIPTION
  Unified dev launch (see echotail/spec/dev-tail-plan.md, DT-D3/D5). The daemon NEVER runs
  inside the tab: it starts windowless (a hidden `cmd /c "<exe> args > <log> 2>&1"`, so
  stdout+stderr land in one combined log), exactly like echoctl's launch. When wt.exe is
  present (Win11), we open `wt -w 0 new-tab` running echotail on that log — a ~6.5 MB tail-f
  viewer (vs ~78 MB for pwsh Get-Content -Wait). `-w 0` targets the current/most-recent WT
  window (created if none), so both "run from a WT tab" and "double-click the .bat" get a
  tab. WT hosts the tab outside our process tree; the echotail tab outlives the daemon
  (the user closes it). Set WT_TABS=0 to force the minimized-window fallback.

  Log: the daemon writes a single combined log at -StdoutLog (echotail follows it). -StderrLog
  is only used by the minimized fallback. Env: -EnvNames are baked into the windowless
  daemon's .cmd (so the daemon gets them even though it no longer runs in the tab).

.NOTES
  Start scripts keep building their own arg list and just call this for the final launch;
  they need no changes — their -StdoutLog simply becomes the combined log echotail follows.
#>
param(
  [Parameter(Mandatory)][string]$Title,
  [Parameter(Mandatory)][string]$Exe,
  [string[]]$ArgList = @(),
  [string]$WorkDir = "",
  [string]$StdoutLog = "",
  [string]$StderrLog = "",
  [string[]]$EnvNames = @(),
  [int]$WaitPort = 0,
  [switch]$ForceTab,
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"

function Get-WtPath {
  if ([string]::IsNullOrEmpty($env:LOCALAPPDATA)) { return "" }
  $p = Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps\wt.exe"
  if (Test-Path -LiteralPath $p) { return $p }
  return ""
}

# True on Windows 11 (build >= 22000) with wt.exe present. `wt -w 0` adds the tab to the
# current/most-recent Windows Terminal window (creating one if none), so both "run from a WT
# tab" and "double-click the .bat" get a tab. Set WT_TABS=0 to force the minimized fallback.
function Test-TabsAvailable {
  if ($ForceTab) { return $true }
  if ($env:WT_TABS -eq "0") { return $false }
  if ((Get-WtPath) -eq "") { return $false }
  return [Environment]::OSVersion.Version.Build -ge 22000
}

function Wait-PortOpen([int]$port, [int]$timeoutMs) {
  if ($port -le 0) { return }
  $deadline = (Get-Date).AddMilliseconds($timeoutMs)
  while ((Get-Date) -lt $deadline) {
    try {
      $c = New-Object System.Net.Sockets.TcpClient
      $c.Connect("127.0.0.1", $port); $c.Close(); return
    } catch { Start-Sleep -Milliseconds 300 }
  }
}

# repo\scripts\launch_tab.ps1 → repo root is the parent of this script's dir.
$repoRoot = Split-Path -Parent $PSScriptRoot
$echotail = Join-Path $repoRoot "echotail\build\x64\echotail.exe"

# Preferred path: WT present AND echotail built → daemon windowless + echotail tab.
if ((Test-TabsAvailable) -and (Test-Path -LiteralPath $echotail)) {
  # Combined log the daemon writes and echotail follows.
  $log = if ($StdoutLog) { $StdoutLog } else { Join-Path $env:TEMP ("echoscript-{0}.log" -f $Title) }
  $logDir = Split-Path -Parent $log
  if ($logDir -and -not (Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
  }

  # Windowless daemon: a .cmd (cd + env + "exe" args > log 2>&1) run via hidden cmd, so
  # stdout+stderr combine into one log (Start-Process can't redirect both to the same file).
  $argStr = ($ArgList | ForEach-Object { '"' + $_ + '"' }) -join ' '
  $dlines = @("@echo off")
  if ($WorkDir) { $dlines += "cd /d `"$WorkDir`"" }
  foreach ($n in $EnvNames) {
    $v = [Environment]::GetEnvironmentVariable($n)
    if ($v) { $dlines += "set `"$n=$v`"" }
  }
  $dlines += "`"$Exe`" $argStr > `"$log`" 2>&1"
  $daemonCmd = Join-Path $env:TEMP ("echoscript-daemon-{0}.cmd" -f ([Guid]::NewGuid().ToString('N').Substring(0, 12)))

  # Tab-reuse: a live echotail on this log publishes a named mutex (algorithm mirrored in
  # echotail.pas / echoctl_launch.pas — change in sync). If it exists, skip the duplicate tab.
  $mutexName = 'echotail-tab-' + ($log.ToLowerInvariant() -replace '[^a-z0-9]', '-')
  $tabExists = $false
  try { $m = [System.Threading.Mutex]::OpenExisting($mutexName); $m.Dispose(); $tabExists = $true } catch {}

  # echotail tab: a .cmd (title + echotail on the log); cmd /k keeps the tab open even if
  # echotail ever exits (the tab outlives the daemon — user closes it). -WaitPort also feeds
  # echotail's --watch-port so the tab reports when the daemon stops/starts listening.
  $watch = if ($WaitPort -gt 0) { " --watch-port $WaitPort" } else { "" }
  $tlines = @("@echo off", "title $Title log", "`"$echotail`" `"$log`" --tail 200 --title `"$Title log`"$watch")
  $tabCmd = Join-Path $env:TEMP ("echoscript-tab-{0}.cmd" -f ([Guid]::NewGuid().ToString('N').Substring(0, 12)))

  $wt = Get-WtPath
  if ($DryRun) {
    Write-Host "[dry-run] daemon .cmd ($daemonCmd):"
    $dlines | ForEach-Object { Write-Host "    $_" }
    Write-Host "[dry-run] windowless: cmd /c `"$daemonCmd`" (hidden)"
    Write-Host "[dry-run] tab exists (mutex $mutexName): $tabExists"
    Write-Host "[dry-run] tab .cmd ($tabCmd):"
    $tlines | ForEach-Object { Write-Host "    $_" }
    Write-Host "[dry-run] wt: `"$wt`" -w 0 new-tab --title `"$Title log`" cmd /k `"$tabCmd`""
    exit 0
  }

  Set-Content -LiteralPath $daemonCmd -Value $dlines -Encoding Ascii

  # Start the daemon windowless, then open the echotail tab following its log
  # (unless a live echotail already follows it — reuse that tab).
  Start-Process -FilePath "cmd.exe" -ArgumentList '/c', $daemonCmd -WindowStyle Hidden | Out-Null
  if ($tabExists) {
    Write-Host "started '$Title' windowless; log tab already open (reused)"
  } else {
    Set-Content -LiteralPath $tabCmd -Value $tlines -Encoding Ascii
    & $wt -w 0 new-tab --title "$Title log" cmd /k $tabCmd | Out-Null
    Write-Host "started '$Title' windowless; live log in a new Windows Terminal tab (echotail)"
  }
  Wait-PortOpen $WaitPort 20000
  exit 0
}

# Fallback (no wt, or echotail not built): minimized window, output redirected to logs.
if ($DryRun) {
  Write-Host "[dry-run] fallback: Start-Process -WindowStyle Minimized `"$Exe`" $($ArgList -join ' ')"
  exit 0
}
$sp = @{ FilePath = $Exe; WindowStyle = "Minimized"; PassThru = $true }
if ($ArgList.Count -gt 0) { $sp.ArgumentList = $ArgList }
if ($WorkDir)   { $sp.WorkingDirectory = $WorkDir }
if ($StdoutLog) { $sp.RedirectStandardOutput = $StdoutLog }
if ($StderrLog) { $sp.RedirectStandardError = $StderrLog }
$proc = Start-Process @sp
if ($proc.WaitForExit(1500)) {
  Write-Host ("$Title exited with code " + $proc.ExitCode)
  if ($StderrLog -and (Test-Path -LiteralPath $StderrLog)) {
    Get-Content -LiteralPath $StderrLog | ForEach-Object { Write-Host $_ }
  }
  exit $proc.ExitCode
}
Write-Host ("Started $Title PID " + $proc.Id)
exit 0
