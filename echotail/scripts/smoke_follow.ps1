# Follow smoke: start echotail on a throwaway log, append, and assert the initial tail,
# the appended line, and ANSI colouring (with --color) all showed up.
$ErrorActionPreference = "Stop"
$exe = Join-Path $PSScriptRoot "..\build\x64\echotail.exe"
$log = Join-Path $env:TEMP ("echotail-smoke-{0}.log" -f $PID)
$cap = Join-Path $env:TEMP ("echotail-smoke-{0}.cap" -f $PID)

Set-Content -Path $log -Value @("a", "b", "c", "d", "e") -Encoding utf8
$p = Start-Process $exe -ArgumentList "`"$log`"", "--tail", "2", "--color" `
  -RedirectStandardOutput $cap -WindowStyle Hidden -PassThru
Start-Sleep -Milliseconds 900
Add-Content -Path $log -Value "warmup ready model=x" -Encoding utf8
Start-Sleep -Milliseconds 500
Stop-Process -Id $p.Id -Force
Start-Sleep -Milliseconds 200

$bytes = [System.IO.File]::ReadAllBytes($cap)
$txt = [System.Text.Encoding]::UTF8.GetString($bytes)
$ok = $true
if ($txt -notmatch "d") { Write-Host "FAIL: initial tail line 'd' missing"; $ok = $false }
if ($txt -notmatch "warmup ready") { Write-Host "FAIL: appended line missing"; $ok = $false }
if (-not ($bytes -contains 27)) { Write-Host "FAIL: no ANSI (ESC) with --color"; $ok = $false }

Remove-Item -Path $log, $cap -ErrorAction SilentlyContinue
if ($ok) { Write-Host "FOLLOW SMOKE OK"; exit 0 } else { Write-Host "FOLLOW SMOKE FAILED"; exit 1 }
