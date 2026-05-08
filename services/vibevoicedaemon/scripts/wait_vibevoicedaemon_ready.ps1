param(
    [int]$TimeoutSeconds = 900
)

$ErrorActionPreference = "Stop"

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\..\.."))
$logDir = Join-Path $repoRoot "services\vibevoicedaemon\logs"
$stdoutLog = Join-Path $logDir "vibevoicedaemon.stdout.log"
$stderrLog = Join-Path $logDir "vibevoicedaemon.stderr.log"
$readyMarker = "[vibevoicedaemon] fully loaded and ready for requests"
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$lastPrinted = ""
$lastStderrLine = 0

if (-not (Test-Path $stdoutLog)) {
    throw "stdout log not found: $stdoutLog"
}

while ((Get-Date) -lt $deadline) {
    $processes = Get-CimInstance Win32_Process | Where-Object {
        $_.Name -ieq "python.exe" -and $_.CommandLine -match "app\.main.*--port\s+7802"
    }

    if (@($processes).Count -eq 0) {
        throw "vibevoicedaemon process is not running"
    }

    if (Test-Path $stdoutLog) {
        $content = Get-Content -Path $stdoutLog -Raw -ErrorAction SilentlyContinue
        if ($content -and $content.Contains($readyMarker)) {
            Write-Host $readyMarker
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
    }

    Start-Sleep -Seconds 2
}

throw "Timed out waiting for vibevoicedaemon ready"
