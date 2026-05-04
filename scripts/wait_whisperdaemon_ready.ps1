param(
    [Parameter(Mandatory = $true)]
    [string]$ModelName,

    [int]$TimeoutSeconds = 900
)

$ErrorActionPreference = "Stop"

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$logDir = Join-Path $repoRoot "services\whisperdaemon\logs"
$stdoutLog = Join-Path $logDir ("{0}.stdout.log" -f $ModelName)
$stderrLog = Join-Path $logDir ("{0}.stderr.log" -f $ModelName)
$readyMarker = "[whisperdaemon] warmup ready model=$ModelName"
$processPattern = "--model-name {0}(\s|$)" -f [Regex]::Escape($ModelName)
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$lastPrinted = ""
$lastStderrLine = 0

if (-not (Test-Path $stdoutLog)) {
    throw "stdout log not found: $stdoutLog"
}

while ((Get-Date) -lt $deadline) {
    $processes = Get-CimInstance Win32_Process -Filter "Name = 'WhisperDaemon.exe'" | Where-Object {
        $_.CommandLine -match $processPattern
    }

    if (@($processes).Count -eq 0) {
        throw "WhisperDaemon process for $ModelName is not running"
    }

    if (Test-Path $stdoutLog) {
        $content = Get-Content -Path $stdoutLog -Raw -ErrorAction SilentlyContinue
        if ($content -and $content.Contains($readyMarker)) {
            Write-Host $readyMarker
            Write-Host ("[whisperdaemon] fully loaded and ready for requests model={0}" -f $ModelName)
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
        if ($stderrContent -and $stderrContent.Contains('[whisperdaemon] warmup failed:')) {
            throw $stderrContent.Trim()
        }
    }

    Start-Sleep -Seconds 2
}

throw "Timed out waiting for $ModelName warmup ready"