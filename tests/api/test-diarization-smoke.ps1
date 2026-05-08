# DiarizationDaemon smoke test with real audio.
# Sends PCM audio and verifies diar_final carries speaker assignments.
# Prerequisite: DiarizationDaemon running at ws://127.0.0.1:7900 with models loaded
# Run: pwsh tests/api/test-diarization-smoke.ps1 [-AudioPath <wav>] [-TimeoutSeconds 120]

param(
    [string]$AudioPath = "",
    [int]$TimeoutSeconds = 120
)

. "$PSScriptRoot\..\helpers\common.ps1"

# ---------------------------------------------------------------------------
# WebSocket helpers
# ---------------------------------------------------------------------------

function New-DiarWS {
    param([string]$Uri = "ws://127.0.0.1:7900")
    $ws = [System.Net.WebSockets.ClientWebSocket]::new()
    $cts = [System.Threading.CancellationTokenSource]::new(5000)
    try {
        $ws.ConnectAsync([Uri]$Uri, $cts.Token).Wait()
    } finally {
        $cts.Dispose()
    }
    if ($ws.State -ne [System.Net.WebSockets.WebSocketState]::Open) {
        throw "WebSocket connection failed to $Uri"
    }
    return $ws
}

function Send-DiarJson {
    param($ws, [hashtable]$Msg)
    $json = $Msg | ConvertTo-Json -Compress -Depth 5
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $ws.SendAsync(
        [System.ArraySegment[byte]]::new($bytes),
        [System.Net.WebSockets.WebSocketMessageType]::Text,
        $true,
        [System.Threading.CancellationToken]::None
    ).Wait()
}

function Send-DiarBinary {
    param($ws, [byte[]]$Data, [int]$ChunkSize = 32768)
    $offset = 0
    while ($offset -lt $Data.Length) {
        $end    = [Math]::Min($offset + $ChunkSize, $Data.Length)
        $chunk  = $Data[$offset..($end - 1)]
        $isLast = ($end -ge $Data.Length)
        $ws.SendAsync(
            [System.ArraySegment[byte]]::new($chunk),
            [System.Net.WebSockets.WebSocketMessageType]::Binary,
            $isLast,
            [System.Threading.CancellationToken]::None
        ).Wait()
        $offset = $end
    }
}

function Receive-DiarJson {
    param($ws, [int]$TimeoutMs = 60000)
    $cts = [System.Threading.CancellationTokenSource]::new($TimeoutMs)
    $ms  = [System.IO.MemoryStream]::new()
    try {
        $buf = [byte[]]::new(8192)
        do {
            $seg    = [System.ArraySegment[byte]]::new($buf)
            $result = $ws.ReceiveAsync($seg, $cts.Token).GetAwaiter().GetResult()
            if ($result.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
                throw "WebSocket closed while waiting for message"
            }
            $ms.Write($buf, 0, $result.Count)
        } while (-not $result.EndOfMessage)
        return [System.Text.Encoding]::UTF8.GetString($ms.ToArray()) | ConvertFrom-Json
    } finally {
        $cts.Dispose()
        $ms.Dispose()
    }
}

function Close-DiarWS {
    param($ws)
    try {
        if ($ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
            $ws.CloseAsync(
                [System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure,
                "done",
                [System.Threading.CancellationToken]::None
            ).Wait(3000) | Out-Null
        }
    } catch { }
    $ws.Dispose()
}

function Read-WavPcmData {
    param([string]$FilePath)
    $bytes = [System.IO.File]::ReadAllBytes($FilePath)
    # Scan for the "data" sub-chunk (bytes: 0x64 0x61 0x74 0x61)
    $dataOffset = 0
    for ($i = 12; $i -lt $bytes.Length - 8; $i++) {
        if ($bytes[$i]   -eq 0x64 -and $bytes[$i+1] -eq 0x61 -and
            $bytes[$i+2] -eq 0x74 -and $bytes[$i+3] -eq 0x61) {
            $dataOffset = $i + 8   # skip "data" marker + 4-byte chunk size
            break
        }
    }
    if ($dataOffset -eq 0) {
        throw "No 'data' chunk found in WAV file: $FilePath"
    }
    return $bytes[$dataOffset..($bytes.Length - 1)]
}

function Test-DaemonPort {
    try {
        $tcp = [System.Net.Sockets.TcpClient]::new()
        $connected = $tcp.ConnectAsync("127.0.0.1", 7900).Wait(2000)
        $tcp.Close()
        return $connected
    } catch {
        return $false
    }
}

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

$resolvedAudio = if ($AudioPath.Length -gt 0) {
    [System.IO.Path]::GetFullPath($AudioPath)
} else {
    [System.IO.Path]::GetFullPath((Get-PrimaryTestAudioFile))
}

if (-not (Test-Path $resolvedAudio)) {
    throw "Audio file not found: $resolvedAudio"
}

if (-not (Test-DaemonPort)) {
    throw "DiarizationDaemon is not running at ws://127.0.0.1:7900"
}

$timeoutMs = $TimeoutSeconds * 1000
$pcmData   = Read-WavPcmData $resolvedAudio

Write-TestHeader "DiarizationDaemon Smoke"
Write-TestStep "Audio:    $resolvedAudio"
Write-TestStep "PCM data: $($pcmData.Length) bytes ($([Math]::Round($pcmData.Length / 32000.0, 1)) s at 16 kHz mono)"

# ---------------------------------------------------------------------------
# Test 1: session with num_speakers=2, real audio → diar_final with segments
# ---------------------------------------------------------------------------

$ws = $null
try {
    $ws = New-DiarWS
    Send-DiarJson $ws @{
        event          = "diar_session_start"
        sample_rate_hz = 16000
        channels       = 1
        audio_format   = "pcm16le"
        num_speakers   = 2
        request_id     = "smoke-1"
    }
    $ack = Receive-DiarJson $ws
    Assert-Equal "smoke1 ack event"  "diar_session_ack" $ack.event
    Assert-Equal "smoke1 ack engine" "sherpa-onnx"      $ack.engine

    Send-DiarBinary $ws $pcmData
    Send-DiarJson   $ws @{ event = "diar_flush" }
    $final = Receive-DiarJson $ws $timeoutMs

    Assert-Equal  "smoke1 final event"      "diar_final" $final.event
    Assert-Equal  "smoke1 final engine"     "sherpa-onnx" $final.engine
    Assert-Equal  "smoke1 final request_id" "smoke-1"     $final.request_id
    Assert-True   "smoke1 speaker_count > 0"  ([int]$final.speaker_count -gt 0)
    Assert-True   "smoke1 duration_ms > 0"    ([long]$final.duration_ms -gt 0)
    Assert-IsArray "smoke1 speaker_segments"               $final.speaker_segments
    Assert-True   "smoke1 has segments"       ($final.speaker_segments.Count -gt 0)

    if ($final.speaker_segments.Count -gt 0) {
        $seg0 = $final.speaker_segments[0]
        Assert-NotNull "smoke1 seg0 speaker_id"             $seg0.speaker_id
        Assert-True    "smoke1 seg0 start_ms >= 0"          ([long]$seg0.start_ms -ge 0)
        Assert-True    "smoke1 seg0 end_ms > start_ms"      ([long]$seg0.end_ms -gt [long]$seg0.start_ms)
    }
} finally {
    if ($ws) { Close-DiarWS $ws }
}

# ---------------------------------------------------------------------------
# Test 2: session with automatic speaker detection (no num_speakers)
# ---------------------------------------------------------------------------

$ws = $null
try {
    $ws = New-DiarWS
    Send-DiarJson $ws @{
        event          = "diar_session_start"
        sample_rate_hz = 16000
        channels       = 1
        audio_format   = "pcm16le"
        request_id     = "smoke-2"
    }
    $ack = Receive-DiarJson $ws
    Assert-Equal "smoke2 ack event" "diar_session_ack" $ack.event

    Send-DiarBinary $ws $pcmData
    Send-DiarJson   $ws @{ event = "diar_flush" }
    $final = Receive-DiarJson $ws $timeoutMs

    Assert-Equal  "smoke2 final event"      "diar_final" $final.event
    Assert-Equal  "smoke2 final request_id" "smoke-2"    $final.request_id
    Assert-True   "smoke2 speaker_count >= 0" ([int]$final.speaker_count -ge 0)
    Assert-IsArray "smoke2 speaker_segments"              $final.speaker_segments
} finally {
    if ($ws) { Close-DiarWS $ws }
}

Complete-TestRun
