# VibevoiceDaemon protocol tests — JSON message contract, error handling, session lifecycle.
# Does NOT require VibeVoice model to be loaded: empty-audio paths skip transcription.
# Prerequisite: vibevoicedaemon running at ws://127.0.0.1:7802
# Run: pwsh tests/api/test-vibevoicedaemon-protocol.ps1

. "$PSScriptRoot\..\helpers\common.ps1"

# ---------------------------------------------------------------------------
# WebSocket helpers
# ---------------------------------------------------------------------------

function New-VvWS {
    param([string]$Uri = "ws://127.0.0.1:7802")
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

function Send-VvJson {
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

function Send-VvBinary {
    param($ws, [byte[]]$Data)
    $ws.SendAsync(
        [System.ArraySegment[byte]]::new($Data),
        [System.Net.WebSockets.WebSocketMessageType]::Binary,
        $true,
        [System.Threading.CancellationToken]::None
    ).Wait()
}

function Receive-VvJson {
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

function Close-VvWS {
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
        $connected = $tcp.ConnectAsync("127.0.0.1", 7802).Wait(2000)
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
    throw "vibevoicedaemon is not running at ws://127.0.0.1:7802"
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

Write-TestHeader "VibevoiceDaemon Protocol"

# --- Test: binary frame before session_start → error ---
$ws = $null
try {
    $ws = New-VvWS
    Send-VvBinary $ws ([byte[]]::new(64))
    $msg = Receive-VvJson $ws
    Assert-Equal "binary_before_start event"   "error" $msg.event
    Assert-True  "binary_before_start message" ($msg.message.Length -gt 0)
} finally {
    if ($ws) { Close-VvWS $ws }
}

# --- Test: unknown event → error ---
$ws = $null
try {
    $ws = New-VvWS
    Send-VvJson $ws @{ event = "bogus_event" }
    $msg = Receive-VvJson $ws
    Assert-Equal "unknown_event event"   "error" $msg.event
    Assert-True  "unknown_event message" ($msg.message.Length -gt 0)
} finally {
    if ($ws) { Close-VvWS $ws }
}

# --- Test: flush before session_start → error ---
$ws = $null
try {
    $ws = New-VvWS
    Send-VvJson $ws @{ event = "flush" }
    $msg = Receive-VvJson $ws
    Assert-Equal "flush_before_start event"   "error" $msg.event
    Assert-True  "flush_before_start message" ($msg.message.Length -gt 0)
} finally {
    if ($ws) { Close-VvWS $ws }
}

# --- Test: valid session_start → session_ack with model_name and connection_id ---
$ws = $null
try {
    $ws = New-VvWS
    Send-VvJson $ws @{
        event          = "session_start"
        audio_format   = "pcm16le"
        sample_rate_hz = 16000
        channels       = 1
        language       = "ru"
    }
    $ack = Receive-VvJson $ws
    Assert-Equal   "session_start_ack event"      "session_ack" $ack.event
    Assert-Equal   "session_start_ack model_name" "vibevoice"   $ack.model_name
    Assert-NotNull "session_start_ack connection_id"             $ack.connection_id
} finally {
    if ($ws) { Close-VvWS $ws }
}

# --- Test: session_start with request_id → ack echoes request_id ---
$ws = $null
try {
    $ws = New-VvWS
    Send-VvJson $ws @{
        event          = "session_start"
        audio_format   = "pcm16le"
        sample_rate_hz = 16000
        channels       = 1
        request_id     = "vv-proto-test-1"
    }
    $ack = Receive-VvJson $ws
    Assert-Equal "request_id_echo event"      "session_ack"     $ack.event
    Assert-Equal "request_id_echo request_id" "vv-proto-test-1" $ack.request_id
} finally {
    if ($ws) { Close-VvWS $ws }
}

# --- Test: session_start with context_info → session_ack ---
$ws = $null
try {
    $ws = New-VvWS
    Send-VvJson $ws @{
        event          = "session_start"
        audio_format   = "pcm16le"
        sample_rate_hz = 16000
        channels       = 1
        context_info   = "Transcribe spoken Russian accurately."
    }
    $ack = Receive-VvJson $ws
    Assert-Equal "context_info_ack event"      "session_ack" $ack.event
    Assert-Equal "context_info_ack model_name" "vibevoice"   $ack.model_name
} finally {
    if ($ws) { Close-VvWS $ws }
}

# --- Test: extra fields (speaker_embeddings, emit_words, sample_format) are silently ignored ---
$ws = $null
try {
    $ws = New-VvWS
    Send-VvJson $ws @{
        event              = "session_start"
        audio_format       = "pcm16le"
        sample_rate_hz     = 16000
        channels           = 1
        speaker_embeddings = @()
        emit_words         = $true
        sample_format      = "s16"
    }
    $ack = Receive-VvJson $ws
    Assert-Equal "extra_fields_ack event" "session_ack" $ack.event
} finally {
    if ($ws) { Close-VvWS $ws }
}

# --- Test: session_start then immediate flush (no audio) → session_final with empty segments ---
$ws = $null
try {
    $ws = New-VvWS
    Send-VvJson $ws @{
        event          = "session_start"
        audio_format   = "pcm16le"
        sample_rate_hz = 16000
        channels       = 1
        request_id     = "vv-proto-empty"
    }
    $ack = Receive-VvJson $ws
    Assert-Equal "empty_flush ack" "session_ack" $ack.event

    Send-VvJson $ws @{ event = "flush" }
    $final = Receive-VvJson $ws 30000

    Assert-Equal   "empty_flush final event"      "session_final"   $final.event
    Assert-Equal   "empty_flush final request_id" "vv-proto-empty"  $final.request_id
    Assert-Equal   "empty_flush speaker_count"    0                 $final.speaker_count
    Assert-IsArray "empty_flush speaker_segments"                    $final.speaker_segments
    Assert-Equal   "empty_flush speaker_segments empty" 0 ([int]$final.speaker_segments.Count)
} finally {
    if ($ws) { Close-VvWS $ws }
}

# --- Test: duplicate session_start on same connection → error ---
$ws = $null
try {
    $ws = New-VvWS
    Send-VvJson $ws @{
        event          = "session_start"
        audio_format   = "pcm16le"
        sample_rate_hz = 16000
        channels       = 1
    }
    $ack = Receive-VvJson $ws
    Assert-Equal "double_start first ack" "session_ack" $ack.event

    Send-VvJson $ws @{
        event          = "session_start"
        audio_format   = "pcm16le"
        sample_rate_hz = 16000
        channels       = 1
    }
    $err = Receive-VvJson $ws
    Assert-Equal "double_start error event"   "error" $err.event
    Assert-True  "double_start error message" ($err.message.Length -gt 0)
} finally {
    if ($ws) { Close-VvWS $ws }
}

Complete-TestRun
