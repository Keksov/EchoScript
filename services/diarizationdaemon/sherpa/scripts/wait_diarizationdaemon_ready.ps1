param(
    [int]$TimeoutSeconds = 900
)

$ErrorActionPreference = "Stop"

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\..\..\.."))
$logDir = Join-Path $repoRoot "services\diarizationdaemon\sherpa\logs"
$stdoutLog = Join-Path $logDir "diarizationdaemon.stdout.log"
$stderrLog = Join-Path $logDir "diarizationdaemon.stderr.log"
$readyMarker = "[diarizationdaemon] warmup ready"
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$lastPrinted = ""
$lastStderrLine = 0

if (-not (Test-Path $stdoutLog)) {
    throw "stdout log not found: $stdoutLog"
}

while ((Get-Date) -lt $deadline) {
    $processes = Get-CimInstance Win32_Process -Filter "Name = 'DiarizationDaemon.exe'"

    if (@($processes).Count -eq 0) {
        throw "DiarizationDaemon process is not running"
    }

    if (Test-Path $stdoutLog) {
        $content = Get-Content -Path $stdoutLog -Raw -ErrorAction SilentlyContinue
        if ($content -and $content.Contains($readyMarker)) {
            Write-Host $readyMarker
            Write-Host "[diarizationdaemon] fully loaded and ready for requests"
            exit 0
        }

        $lastLine = Get-Content -Path $stdoutLog -Tail 1 -ErrorAction SilentlyContinue
        if ($lastLine -and $lastLine -ne $lastPrinted) {
            Write-Host "waiting: $lastLine"
            $lastPrinted = $lastLine
        }
    }

    if (Test-Path $stderrLog) {
        $stderrLines = @(Get-Content -Path $stderrLog -ErrorAction SilentlyContinue)
        if ($stderrLines.Count -gt $lastStderrLine) {
            $newLines = $stderrLines[$lastStderrLine..($stderrLines.Count - 1)]
            foreach ($line in $newLines) {
                if ($line) {
                    Write-Host $line
                }
            }
            $lastStderrLine = $stderrLines.Count
        }

        $stderrContent = $stderrLines -join [Environment]::NewLine
        if ($stderrContent -and $stderrContent.Contains('[diarizationdaemon] warmup failed:')) {
            throw $stderrContent.Trim()
        }
    }

    Start-Sleep -Seconds 2
}

throw "Timed out waiting for DiarizationDaemon warmup ready"
