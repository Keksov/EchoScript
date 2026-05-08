# DiarizationDaemon multi-client num_speakers isolation test.
# Opens two sequential sessions with different num_speakers values and verifies
# each receives an independent diar_final with the correct request_id.
# This exercises the gDiarizerCache keyed by num_speakers.
# Prerequisite: DiarizationDaemon running at ws://127.0.0.1:7900 with models loaded
# Run: pwsh tests/api/test-diarization-multiclient.ps1 [-AudioPath <wav>] [-TimeoutSeconds 120]

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
    $dataOffset = 0
    for ($i = 12; $i -lt $bytes.Length - 8; $i++) {
        if ($bytes[$i]   -eq 0x64 -and $bytes[$i+1] -eq 0x61 -and
            $bytes[$i+2] -eq 0x74 -and $bytes[$i+3] -eq 0x61) {
            $dataOffset = $i + 8
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

Write-TestHeader "DiarizationDaemon Multi-Client num_speakers Isolation"
Write-TestStep "Audio:    $resolvedAudio"
Write-TestStep "PCM data: $($pcmData.Length) bytes ($([Math]::Round($pcmData.Length / 32000.0, 1)) s at 16 kHz mono)"

# ---------------------------------------------------------------------------
# Run sessions with num_speakers = 2 then 3 (exercises gDiarizerCache)
# ---------------------------------------------------------------------------

$results = [System.Collections.Generic.List[hashtable]]::new()

foreach ($numSpeakers in @(2, 3)) {
    $reqId = "multiclient-spk$numSpeakers"
    Write-TestStep "Session num_speakers=$numSpeakers request_id=$reqId"

    $ws = $null
    try {
        $ws = New-DiarWS
        Send-DiarJson $ws @{
            event          = "diar_session_start"
            sample_rate_hz = 16000
            channels       = 1
            audio_format   = "pcm16le"
            num_speakers   = $numSpeakers
            request_id     = $reqId
        }
        $ack = Receive-DiarJson $ws
        if ($ack.event -ne "diar_session_ack") {
            throw "Expected diar_session_ack for num_speakers=$numSpeakers, got: $($ack.event)"
        }

        Send-DiarBinary $ws $pcmData
        Send-DiarJson   $ws @{ event = "diar_flush" }
        $final = Receive-DiarJson $ws $timeoutMs

        $results.Add(@{
            NumSpeakers = $numSpeakers
            RequestId   = $reqId
            Final       = $final
        })
    } finally {
        if ($ws) { Close-DiarWS $ws }
    }
}

# ---------------------------------------------------------------------------
# Assertions
# ---------------------------------------------------------------------------

foreach ($r in $results) {
    $ns  = $r.NumSpeakers
    $fin = $r.Final

    Assert-Equal  "spk$ns final event"      "diar_final"        $fin.event
    Assert-Equal  "spk$ns final engine"     "sherpa-onnx"       $fin.engine
    Assert-Equal  "spk$ns final request_id" $r.RequestId        $fin.request_id
    Assert-True   "spk$ns speaker_count >= 0" ([int]$fin.speaker_count -ge 0)
    Assert-IsArray "spk$ns speaker_segments"                     $fin.speaker_segments
    Assert-True   "spk$ns has segments"       ($fin.speaker_segments.Count -gt 0)
}

# Verify the two sessions produced distinct, non-interfering results
Assert-Equal "distinct request_ids returned" 2 (
    $results | ForEach-Object { $_.Final.request_id } | Sort-Object -Unique | Measure-Object | Select-Object -ExpandProperty Count
)

# Verify the two diar_finals are keyed to the correct sessions (no cross-contamination)
$spk2Final = ($results | Where-Object { $_.NumSpeakers -eq 2 }).Final
$spk3Final = ($results | Where-Object { $_.NumSpeakers -eq 3 }).Final
Assert-Equal "spk2 session isolation" "multiclient-spk2" $spk2Final.request_id
Assert-Equal "spk3 session isolation" "multiclient-spk3" $spk3Final.request_id

Complete-TestRun
