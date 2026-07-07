<#
.SYNOPSIS
  Launch a daemon either as a NEW TAB in the current Windows Terminal window (when the
  caller runs inside an interactive WT session), or — as before — as a minimized window
  with output redirected to log files.

.DESCRIPTION
  Mirrors the pattern in c:\projects\Games\AppCore (AppLaunch.pas): on Windows 11 with
  wt.exe present, open the process as a tab of the current/most-recent WT window
  (`wt -w 0 new-tab`, `-w 0` = current/most-recent window, created if none) — whether the
  .bat is run from a WT tab OR double-clicked — so daemons stack as tabs of one window
  instead of N separate console windows (WT_TABS=0 forces the fallback). The tab
  runs `cmd /k` and shows the daemon's live output (warmup included) — we do NOT block on
  warmup in tab mode; the caller returns after a short port probe. WT hosts the tab shell
  outside our process tree, so (like the echoctl launch) it does not inherit our handles.

  Env: for the tab we rely on the daemons' built-in defaults (WHISPER_MODELS_ROOT →
  services/whisperdaemon/models, VOSK_MODELS_ROOT → C:\var\vosk, ECHOSCRIPT_PORT → 3000),
  which match what the start scripts set. Pass -EnvNames to bake specific overrides into
  the tab.

.NOTES
  Start scripts keep building their own arg list and just call this for the final launch.
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

# True on Windows 11 (build >= 22000) with wt.exe present. We open tabs regardless of how
# the script was launched: `wt -w 0` adds the tab to the current/most-recent Windows
# Terminal window (creating one if none), so both "run from a WT tab" and "double-click the
# .bat" get a tab instead of a standalone console window. Set WT_TABS=0 to force the
# minimized-window fallback.
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

if (Test-TabsAvailable) {
  # Write a per-tab .cmd (title + cd + env + command) to sidestep quote-nesting through wt/cmd.
  $tabCmd = Join-Path $env:TEMP ("echoscript-tab-{0}.cmd" -f ([Guid]::NewGuid().ToString('N').Substring(0, 12)))
  $lines = @("@echo off", "title $Title")
  if ($WorkDir) { $lines += "cd /d `"$WorkDir`"" }
  foreach ($n in $EnvNames) {
    $v = [Environment]::GetEnvironmentVariable($n)
    if ($v) { $lines += "set `"$n=$v`"" }
  }
  $argStr = ($ArgList | ForEach-Object { '"' + $_ + '"' }) -join ' '
  $lines += "`"$Exe`" $argStr"
  Set-Content -LiteralPath $tabCmd -Value $lines -Encoding Ascii

  $wt = Get-WtPath
  if ($DryRun) {
    Write-Host "[dry-run] tab .cmd ($tabCmd):"
    $lines | ForEach-Object { Write-Host "    $_" }
    Write-Host "[dry-run] wt: `"$wt`" -w 0 new-tab --title `"$Title`" cmd /k `"$tabCmd`""
    exit 0
  }

  # -w 0 targets the current/most-recent window; new-tab adds a tab to it.
  & $wt -w 0 new-tab --title $Title cmd /k $tabCmd | Out-Null
  Write-Host "opened '$Title' in a new Windows Terminal tab (watch it for warmup)"
  Wait-PortOpen $WaitPort 20000
  exit 0
}

# Fallback: minimized window, output redirected to logs (previous behavior).
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
