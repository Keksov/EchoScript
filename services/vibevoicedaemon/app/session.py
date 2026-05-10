import json
import logging
import time
from dataclasses import dataclass
from typing import Any

from .model import VibevoiceModel

LOGGER = logging.getLogger(__name__)

_SAMPLE_RATE_HZ = 16000
_MAX_PCM_BYTES = _SAMPLE_RATE_HZ * 2 * 60 * 30  # 30 min of PCM16LE at 16 kHz mono


def _normalize_context_info(value: Any) -> str | None:
    if not isinstance(value, str):
        return None
    normalized = value.strip()
    if not normalized:
        return None
    return normalized


@dataclass
class _SessionSettings:
    language: str = "auto"
    request_id: str | None = None
    mode: str = "diarize"
    context_info: str | None = None


class Session:
    """Per-connection session: buffers PCM, manages state, sends protocol events."""

    def __init__(self, model: VibevoiceModel, connection_id: str) -> None:
        self._model = model
        self._connection_id = connection_id
        self._started = False
        self._done = False
        self._settings = _SessionSettings()
        self._pcm_chunks: list[bytes] = []
        self._pcm_size = 0

    async def handle_text(self, raw_message: str) -> dict[str, Any] | None:
        """Route a JSON text frame. Returns a reply dict or None."""
        try:
            msg = json.loads(raw_message)
        except json.JSONDecodeError:
            return self._error("bad_request", "Invalid JSON")

        event = msg.get("event")
        if not isinstance(event, str):
            return self._error("bad_request", "Missing or non-string 'event' field")

        if event == "session_start":
            return await self._handle_session_start(msg)
        if event == "flush":
            return await self._handle_flush()
        if event == "cancel":
            return self._handle_cancel()
        return self._error("bad_request", f"Unknown event: {event}")

    async def handle_binary(self, data: bytes) -> dict[str, Any] | None:
        """Buffer a binary PCM frame. Returns an error dict on protocol violation."""
        if not self._started:
            return self._error("bad_request", "Binary frame received before session_start")
        if self._done:
            return self._error("bad_request", "Binary frame received after session is complete")
        if self._pcm_size + len(data) > _MAX_PCM_BYTES:
            return self._error("audio_too_long", "PCM audio exceeds the 30-minute limit")
        self._pcm_chunks.append(data)
        self._pcm_size += len(data)
        return None

    # ---------- internal handlers ----------

    async def _handle_session_start(self, msg: dict[str, Any]) -> dict[str, Any]:
        if self._started:
            return self._error("protocol_error", "session_start already received on this connection")

        audio_format = msg.get("audio_format", "pcm16le")
        sample_rate = msg.get("sample_rate_hz", 16000)
        channels = msg.get("channels", 1)

        if audio_format != "pcm16le":
            return self._error("unsupported_format", f"audio_format must be pcm16le, got: {audio_format}")
        if sample_rate != 16000:
            return self._error("unsupported_format", f"sample_rate_hz must be 16000, got: {sample_rate}")
        if channels != 1:
            return self._error("unsupported_format", f"channels must be 1, got: {channels}")

        self._settings = _SessionSettings(
            language=str(msg.get("language") or "auto"),
            request_id=str(msg["request_id"]) if msg.get("request_id") is not None else None,
            mode=str(msg.get("mode") or "diarize"),
            context_info=_normalize_context_info(msg.get("context_info")),
        )
        self._started = True

        ack: dict[str, Any] = {
            "event": "session_ack",
            "model_name": "vibevoice",
            "connection_id": self._connection_id,
        }
        if self._settings.request_id is not None:
            ack["request_id"] = self._settings.request_id
        return ack

    async def _handle_flush(self) -> dict[str, Any]:
        if not self._started:
            return self._error("protocol_error", "flush received before session_start")
        if self._done:
            return self._error("protocol_error", "flush received after session is complete")

        self._done = True
        pcm_bytes = b"".join(self._pcm_chunks)
        self._pcm_chunks.clear()
        duration_ms = (len(pcm_bytes) // 2) * 1000 // _SAMPLE_RATE_HZ
        flush_start_ts = time.perf_counter()
        LOGGER.info(
            "Flush start connection_id=%s request_id=%s audio_bytes=%s duration_ms=%s",
            self._connection_id,
            self._settings.request_id,
            len(pcm_bytes),
            duration_ms,
        )

        if len(pcm_bytes) == 0:
            LOGGER.info(
                "Flush done (empty audio) connection_id=%s request_id=%s elapsed_s=%.3f",
                self._connection_id,
                self._settings.request_id,
                time.perf_counter() - flush_start_ts,
            )
            return self._build_session_final(
                text="",
                duration_ms=0,
                detected_language=None,
                speaker_count=0,
                speaker_segments=[],
            )

        try:
            result = await self._model.transcribe_pcm(
                pcm_bytes,
                self._settings.language,
                self._settings.context_info,
            )
        except (RuntimeError, ValueError, OSError) as exc:
            LOGGER.exception("Transcription failed: %s", exc)
            return self._error("internal_error", "Transcription failed")

        LOGGER.info(
            "Flush done connection_id=%s request_id=%s elapsed_s=%.3f output_segments=%s",
            self._connection_id,
            self._settings.request_id,
            time.perf_counter() - flush_start_ts,
            len(result.get("speaker_segments") or []),
        )

        return self._build_session_final(
            text=result["text"],
            duration_ms=result["duration_ms"],
            detected_language=result.get("detected_language"),
            speaker_count=result["speaker_count"],
            speaker_segments=result["speaker_segments"],
        )

    def _handle_cancel(self) -> dict[str, Any]:
        self._done = True
        self._pcm_chunks.clear()
        reply: dict[str, Any] = {"event": "session_cancelled"}
        if self._settings.request_id is not None:
            reply["request_id"] = self._settings.request_id
        return reply

    def _build_session_final(
        self,
        text: str,
        duration_ms: int,
        detected_language: str | None,
        speaker_count: int,
        speaker_segments: list[dict[str, Any]],
    ) -> dict[str, Any]:
        resp: dict[str, Any] = {
            "event": "session_final",
            "text": text,
            "duration_ms": duration_ms,
            "segment_count": len(speaker_segments),
            "language": self._settings.language,
            "detected_language": detected_language or self._settings.language,
            "speaker_count": speaker_count,
            "speaker_segments": speaker_segments,
        }
        if self._settings.request_id is not None:
            resp["request_id"] = self._settings.request_id
        return resp

    def _error(self, code: str, message: str) -> dict[str, Any]:
        err: dict[str, Any] = {
            "event": "error",
            "code": code,
            "message": message,
        }
        if self._settings.request_id is not None:
            err["request_id"] = self._settings.request_id
        return err
