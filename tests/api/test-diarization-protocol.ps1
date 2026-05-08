# DiarizationDaemon protocol tests — JSON message contract, error handling, session lifecycle.
# Does NOT require sherpa models to be loaded: empty-audio paths never call runDiarization.
# Prerequisite: DiarizationDaemon running at ws://127.0.0.1:7900
# Run: pwsh tests/api/test-diarization-protocol.ps1

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

function Receive-DiarJson {
    param($ws, [int]$TimeoutMs = 10000)
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
# Guard
# ---------------------------------------------------------------------------

if (-not (Test-DaemonPort)) {
    throw "DiarizationDaemon is not running at ws://127.0.0.1:7900"
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

Write-TestHeader "DiarizationDaemon Protocol"

# --- Test: diar_set_segments before diar_session_start → diar_error ---
$ws = $null
try {
    $ws = New-DiarWS
    Send-DiarJson $ws @{ event = "diar_set_segments"; segments = @() }
    $msg = Receive-DiarJson $ws
    Assert-Equal "set_segments_before_start event"   "diar_error" $msg.event
    Assert-True  "set_segments_before_start message" ($msg.message.Length -gt 0)
} finally {
    if ($ws) { Close-DiarWS $ws }
}

# --- Test: diar_flush before diar_session_start → diar_error ---
$ws = $null
try {
    $ws = New-DiarWS
    Send-DiarJson $ws @{ event = "diar_flush" }
    $msg = Receive-DiarJson $ws
    Assert-Equal "flush_before_start event"   "diar_error" $msg.event
    Assert-True  "flush_before_start message" ($msg.message.Length -gt 0)
} finally {
    if ($ws) { Close-DiarWS $ws }
}

# --- Test: valid diar_session_start → diar_session_ack with engine field ---
$ws = $null
try {
    $ws = New-DiarWS
    Send-DiarJson $ws @{
        event          = "diar_session_start"
        sample_rate_hz = 16000
        channels       = 1
        audio_format   = "pcm16le"
    }
    $ack = Receive-DiarJson $ws
    Assert-Equal "session_start_ack event"         "diar_session_ack" $ack.event
    Assert-Equal "session_start_ack engine"        "sherpa-onnx"      $ack.engine
    Assert-NotNull "session_start_ack connection_id"                   $ack.connection_id
} finally {
    if ($ws) { Close-DiarWS $ws }
}

# --- Test: diar_session_start with request_id → ack echoes request_id ---
$ws = $null
try {
    $ws = New-DiarWS
    Send-DiarJson $ws @{
        event          = "diar_session_start"
        sample_rate_hz = 16000
        channels       = 1
        audio_format   = "pcm16le"
        request_id     = "proto-test-req-1"
    }
    $ack = Receive-DiarJson $ws
    Assert-Equal "request_id_echo event"      "diar_session_ack"  $ack.event
    Assert-Equal "request_id_echo request_id" "proto-test-req-1"  $ack.request_id
} finally {
    if ($ws) { Close-DiarWS $ws }
}

# --- Test: session_start then immediate flush (no audio) → diar_final with empty speaker_segments ---
$ws = $null
try {
    $ws = New-DiarWS
    Send-DiarJson $ws @{
        event          = "diar_session_start"
        sample_rate_hz = 16000
        channels       = 1
        audio_format   = "pcm16le"
        request_id     = "proto-test-empty"
    }
    $ack = Receive-DiarJson $ws
    Assert-Equal "empty_flush ack" "diar_session_ack" $ack.event

    Send-DiarJson $ws @{ event = "diar_flush" }
    $final = Receive-DiarJson $ws 30000

    Assert-Equal  "empty_flush final event"         "diar_final"        $final.event
    Assert-Equal  "empty_flush final engine"        "sherpa-onnx"       $final.engine
    Assert-Equal  "empty_flush final request_id"    "proto-test-empty"  $final.request_id
    Assert-Equal  "empty_flush speaker_count"       0                   $final.speaker_count
    Assert-IsArray "empty_flush speaker_segments"                        $final.speaker_segments
    Assert-Equal  "empty_flush speaker_segments empty" 0 ([int]$final.speaker_segments.Count)
} finally {
    if ($ws) { Close-DiarWS $ws }
}

# --- Test: duplicate diar_session_start on same connection → diar_error ---
$ws = $null
try {
    $ws = New-DiarWS
    Send-DiarJson $ws @{
        event          = "diar_session_start"
        sample_rate_hz = 16000
        channels       = 1
        audio_format   = "pcm16le"
    }
    $ack = Receive-DiarJson $ws
    Assert-Equal "double_start first ack" "diar_session_ack" $ack.event

    Send-DiarJson $ws @{
        event          = "diar_session_start"
        sample_rate_hz = 16000
        channels       = 1
        audio_format   = "pcm16le"
    }
    $err = Receive-DiarJson $ws
    Assert-Equal "double_start error event"   "diar_error" $err.event
    Assert-True  "double_start error message" ($err.message.Length -gt 0)
} finally {
    if ($ws) { Close-DiarWS $ws }
}

Complete-TestRun
