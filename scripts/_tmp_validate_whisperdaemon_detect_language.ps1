$ErrorActionPreference = "Stop"

$repoRoot = "c:\projects\EchoScript"
$cliPath = "c:\projects\EchoScript\EchoRecorder\cli\build\x64\EchoRecorderCore.exe"
$logPath = "c:\projects\EchoScript\services\whisperdaemon\logs\whisperdaemon_detected_language_cli.jsonl"
$testsDir = Join-Path $repoRoot "EchoRecorder\tests"

$audioItem = Get-ChildItem -Path $testsDir -Filter "*_ogg.ogg" | Select-Object -First 1
if ($null -eq $audioItem) {
    throw "Audio fixture not found under $testsDir"
}

$audioPath = $audioItem.FullName

Set-Location $repoRoot

if (Test-Path $logPath) {
    Remove-Item $logPath -Force
}

$output = & ffmpeg -re -hide_banner -loglevel error -i $audioPath -f s16le -ar 16000 -ac 1 - |
    & $cliPath --backend daemon --mode dictation --language auto --daemon-host 127.0.0.1 --daemon whisper:7801 -f pcm16le -i - --log=jsonl:stdout

$output | Set-Content -Path $logPath -Encoding utf8
$output | Where-Object { $_ -match '"event":"(server_final|final)"' }