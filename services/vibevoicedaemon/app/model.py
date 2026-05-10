import asyncio
import ctypes
import gc
import json
import logging
import os
import re
import tempfile
import wave
from collections import Counter
from pathlib import Path
from typing import Any

import torch
from accelerate import init_empty_weights
from accelerate.utils import set_module_tensor_to_device
from echoscript_shared.hf_env import bootstrap_hf_cache_env, get_hf_hub_cache
from huggingface_hub import snapshot_download
from safetensors import safe_open

# TRANSFORMERS_CACHE is deprecated and can emit warnings during transformers import.
os.environ.pop("TRANSFORMERS_CACHE", None)

from transformers import GenerationConfig
from vibevoice.modular.configuration_vibevoice import VibeVoiceASRConfig
from vibevoice.modular.modeling_vibevoice_asr import (
    VibeVoiceASRForConditionalGeneration,
)
from vibevoice.processor.vibevoice_asr_processor import VibeVoiceASRProcessor

LOGGER = logging.getLogger(__name__)

_MODEL_ID = "microsoft/VibeVoice-ASR"
_TOKENIZER_MODEL_ID = "Qwen/Qwen2.5-7B"
_SAMPLE_RATE = 16000
_MAX_NEW_TOKENS = 1024
_MAX_CHUNK_DURATION_MS = 15000
_CHUNK_OVERLAP_MS = 2000
_MIN_STITCH_SEGMENT_MS = 250
_NON_SPEECH_MARKERS = {"[noise]", "[silence]", "[music]", "[applause]"}
_RUSSIAN_CONTEXT_HINT = (
    "Transcribe spoken Russian verbatim. "
    "The audio may contain a casual dialogue between two speakers. "
    "Preserve colloquial wording, false starts, hesitations, short interjections, and proper names exactly as spoken. "
    "Do not translate, summarize, paraphrase, merge distant phrases, or omit short utterances."
)

_VIBEVOICE_SEGMENT_PATTERN = re.compile(
    r'\{\s*"?(?:Start(?: time)?)"?\s*:\s*(?P<start>-?\d+(?:\.\d+)?)'
    r'\s*,\s*"?(?:End(?: time)?)"?\s*:\s*(?P<end>-?\d+(?:\.\d+)?)'
    r'(?:\s*,\s*"?(?:Speaker(?: ID)?)"?\s*:\s*(?P<speaker>-?\d+))?'
    r'\s*,\s*"?Content"?\s*:\s*"(?P<text>(?:[^"\\]|\\.)*?)"\s*\}',
    re.DOTALL,
)


def _to_spk_id(value: Any) -> str | None:
    """Convert a VibeVoice speaker value (int or 'Speaker N' string) to 'spk_N' format."""
    if value is None:
        return None
    sv = str(value).strip()
    if not sv:
        return None
    m = re.match(r"^[Ss]peaker\s+(\d+)$", sv)
    if m:
        return f"spk_{m.group(1)}"
    try:
        return f"spk_{int(sv)}"
    except ValueError:
        return f"spk_{sv}"


def _write_wav(path: str, pcm_bytes: bytes, sample_rate: int) -> None:
    """Write raw PCM16LE bytes to a WAV file."""
    wf = wave.open(path, "wb")
    try:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(sample_rate)
        wf.writeframes(pcm_bytes)
    finally:
        wf.close()


def _estimate_model_bytes(snapshot_path: Path) -> int:
    total_bytes = 0
    for shard_path in snapshot_path.glob("model-*.safetensors"):
        total_bytes += shard_path.stat().st_size
    return total_bytes


def _get_available_memory_bytes() -> int | None:
    if os.name == "nt":
        class MEMORYSTATUSEX(ctypes.Structure):
            _fields_ = [
                ("dwLength", ctypes.c_ulong),
                ("dwMemoryLoad", ctypes.c_ulong),
                ("ullTotalPhys", ctypes.c_ulonglong),
                ("ullAvailPhys", ctypes.c_ulonglong),
                ("ullTotalPageFile", ctypes.c_ulonglong),
                ("ullAvailPageFile", ctypes.c_ulonglong),
                ("ullTotalVirtual", ctypes.c_ulonglong),
                ("ullAvailVirtual", ctypes.c_ulonglong),
                ("ullAvailExtendedVirtual", ctypes.c_ulonglong),
            ]

        status = MEMORYSTATUSEX(ctypes.sizeof(MEMORYSTATUSEX))
        if ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(status)) == 0:
            return None
        return int(status.ullAvailPhys)

    try:
        page_size = os.sysconf("SC_PAGE_SIZE")
        available_pages = os.sysconf("SC_AVPHYS_PAGES")
        return int(page_size * available_pages)
    except (AttributeError, OSError, ValueError):
        return None


def _format_gb(value: int) -> str:
    return f"{value / (1024 ** 3):.2f} GB"


def _is_non_speech_text(text: str) -> bool:
    return text.strip().lower() in _NON_SPEECH_MARKERS


def _normalized_word_tokens(text: str) -> list[str]:
    return [token.lower() for token in re.findall(r"[0-9A-Za-zА-Яа-яЁё]+", text)]


def _normalized_text_key(text: str) -> str:
    tokens = _normalized_word_tokens(text)
    if len(tokens) > 0:
        return " ".join(tokens)
    return " ".join(text.lower().split())


def _is_repetitive_segment_text(text: str) -> bool:
    tokens = _normalized_word_tokens(text)
    if len(tokens) < 8:
        return False

    counts = Counter(tokens)
    dominant_token, dominant_count = counts.most_common(1)[0]
    if len(dominant_token) <= 3 and (dominant_count / len(tokens)) >= 0.65:
        return True
    if len(tokens) >= 16 and len(counts) <= 2:
        return True

    char_stream = "".join(tokens)
    if len(char_stream) >= 24 and len(set(char_stream)) <= 3:
        return True

    return False


def _should_drop_segment_text(text: str) -> bool:
    return _is_non_speech_text(text) or _is_repetitive_segment_text(text)


def _looks_structured_vibevoice_output(text: str) -> bool:
    stripped = text.strip()
    if not stripped:
        return False
    if stripped.startswith("assistant"):
        return True
    return ('"Start"' in stripped or '"End"' in stripped or '"Content"' in stripped) and '[' in stripped


def _normalize_context_info(value: str | None) -> str | None:
    if value is None:
        return None
    normalized = value.strip()
    if not normalized:
        return None
    return normalized


def _default_context_info(language: str) -> str | None:
    normalized_language = language.strip().lower()
    if normalized_language in {"ru", "rus", "russian"}:
        return _RUSSIAN_CONTEXT_HINT
    return None


def _compose_context_info(language: str, context_info: str | None) -> str | None:
    parts: list[str] = []
    default_context = _default_context_info(language)
    if default_context is not None:
        parts.append(default_context)

    normalized_context = _normalize_context_info(context_info)
    if normalized_context is not None and normalized_context not in parts:
        parts.append(normalized_context)

    if len(parts) == 0:
        return None

    return "\n".join(parts)


class VibevoiceModel:
    """Thread-safe VibeVoice ASR model singleton with queue-based concurrency."""

    def __init__(self) -> None:
        self._model: VibeVoiceASRForConditionalGeneration | None = None
        self._processor: VibeVoiceASRProcessor | None = None
        self._device = "cpu"
        self._dtype: torch.dtype = torch.float32
        self._lock = asyncio.Lock()

    def is_loaded(self) -> bool:
        return self._model is not None

    async def load(self) -> None:
        """Pre-load the model (idempotent). Called during warmup."""
        async with self._lock:
            if self._model is not None:
                return
            await asyncio.to_thread(self._load_sync)

    async def transcribe_pcm(
        self,
        pcm_bytes: bytes,
        language: str,
        context_info: str | None = None,
    ) -> dict[str, Any]:
        """Transcribe raw PCM16LE bytes. Queues if another transcription is in progress."""
        async with self._lock:
            if self._model is None:
                await asyncio.to_thread(self._load_sync)
            return await asyncio.to_thread(self._transcribe_sync, pcm_bytes, language, context_info)

    # ---------- synchronous helpers (run in thread pool) ----------

    def _load_sync(self) -> None:
        bootstrap_hf_cache_env()
        cache_dir = get_hf_hub_cache()
        model_path = self._resolve_snapshot(_MODEL_ID, cache_dir)
        tokenizer_path = self._resolve_snapshot(_TOKENIZER_MODEL_ID, cache_dir)
        self._device = self._resolve_device()
        self._dtype = self._resolve_dtype(self._device)
        attn_impl = "sdpa" if self._device == "cuda" else "eager"

        if self._device == "cpu" and os.environ.get("ECHOSCRIPT_SKIP_MEMORY_PREFLIGHT") != "1":
            model_bytes = _estimate_model_bytes(model_path)
            available_bytes = _get_available_memory_bytes()
            required_bytes = int(model_bytes * 1.25)
            if model_bytes > 0 and available_bytes is not None and available_bytes < required_bytes:
                raise RuntimeError(
                    "VibeVoice-ASR cannot be loaded on CPU with the current free RAM: "
                    f"available={_format_gb(available_bytes)}, required~={_format_gb(required_bytes)}. "
                    "Use a CUDA-enabled environment or free more memory. "
                    "Set ECHOSCRIPT_SKIP_MEMORY_PREFLIGHT=1 to bypass this check."
                )

        LOGGER.info("Loading VibeVoice processor from %s", model_path)
        self._processor = VibeVoiceASRProcessor.from_pretrained(
            str(model_path),
            language_model_pretrained_name=str(tokenizer_path),
            local_files_only=True,
        )

        LOGGER.info("Loading VibeVoice model on %s (%s, %s)", self._device, self._dtype, attn_impl)
        self._model = self._load_model_from_snapshot(model_path, attn_impl)
        if self._device == "cuda":
            self._model = self._model.to(device=self._device, dtype=self._dtype)
        else:
            self._model = self._model.to(self._device)
        self._model.eval()
        LOGGER.info("VibeVoice model loaded on %s", self._device)

    def _transcribe_sync(
        self,
        pcm_bytes: bytes,
        language: str,
        context_info: str | None,
    ) -> dict[str, Any]:
        model = self._model
        processor = self._processor
        assert model is not None and processor is not None

        resolved_context_info = _compose_context_info(language, context_info)

        if language and language.lower() != "auto":
            LOGGER.info(
                "Language hint '%s' passed; applying context bias=%s",
                language,
                resolved_context_info is not None,
            )

        duration_ms = (len(pcm_bytes) // 2) * 1000 // _SAMPLE_RATE

        if duration_ms > _MAX_CHUNK_DURATION_MS:
            return self._transcribe_chunked_sync(pcm_bytes, duration_ms, resolved_context_info)

        return self._transcribe_single_chunk_sync(pcm_bytes, duration_ms, 0, resolved_context_info)

    def _transcribe_chunked_sync(
        self,
        pcm_bytes: bytes,
        duration_ms: int,
        context_info: str | None,
    ) -> dict[str, Any]:
        chunk_bytes = (_MAX_CHUNK_DURATION_MS * _SAMPLE_RATE * 2) // 1000
        if (chunk_bytes % 2) != 0:
            chunk_bytes -= 1
        overlap_bytes = (_CHUNK_OVERLAP_MS * _SAMPLE_RATE * 2) // 1000
        if (overlap_bytes % 2) != 0:
            overlap_bytes -= 1
        if overlap_bytes >= chunk_bytes:
            overlap_bytes = 0
        stride_bytes = chunk_bytes - overlap_bytes

        LOGGER.info(
            "Chunking VibeVoice request duration_ms=%s chunk_ms=%s overlap_ms=%s",
            duration_ms,
            _MAX_CHUNK_DURATION_MS,
            _CHUNK_OVERLAP_MS,
        )

        chunk_ranges: list[tuple[int, int]] = []
        offset_bytes = 0
        while offset_bytes < len(pcm_bytes):
            end_bytes = min(offset_bytes + chunk_bytes, len(pcm_bytes))
            chunk_ranges.append((offset_bytes, end_bytes))
            if end_bytes >= len(pcm_bytes):
                break
            offset_bytes += stride_bytes

        combined_segments: list[dict[str, Any]] = []
        detected_language: str | None = None

        for chunk_index, (offset_bytes, end_bytes) in enumerate(chunk_ranges):
            chunk_pcm = pcm_bytes[offset_bytes:end_bytes]
            chunk_offset_ms = ((offset_bytes // 2) * 1000) // _SAMPLE_RATE
            chunk_duration_ms = (len(chunk_pcm) // 2) * 1000 // _SAMPLE_RATE
            keep_start_ms = chunk_offset_ms
            keep_end_ms = chunk_offset_ms + chunk_duration_ms
            if chunk_index < len(chunk_ranges) - 1:
                keep_end_ms = min(keep_end_ms, chunk_offset_ms + _MAX_CHUNK_DURATION_MS - _CHUNK_OVERLAP_MS)

            chunk_result = self._transcribe_single_chunk_sync(
                chunk_pcm,
                chunk_duration_ms,
                chunk_offset_ms,
                context_info,
            )

            stitched_chunk_segments = self._clip_segments_to_window(
                chunk_result["speaker_segments"],
                keep_start_ms,
                keep_end_ms,
            )
            if detected_language is None and chunk_result.get("detected_language"):
                detected_language = str(chunk_result["detected_language"])

            combined_segments.extend(stitched_chunk_segments)

        combined_segments = self._stitch_chunk_boundaries(combined_segments)
        for idx, segment in enumerate(combined_segments):
            segment["segment_id"] = idx

        text = " ".join(
            segment["text"]
            for segment in combined_segments
            if segment.get("text") and not _should_drop_segment_text(str(segment["text"]))
        ).strip()

        return {
            "text": text,
            "detected_language": detected_language,
            "duration_ms": duration_ms,
            "speaker_segments": combined_segments,
            "speaker_count": len({seg["speaker_id"] for seg in combined_segments if seg.get("speaker_id")}),
        }

    def _transcribe_single_chunk_sync(
        self,
        pcm_bytes: bytes,
        duration_ms: int,
        offset_ms: int,
        context_info: str | None,
    ) -> dict[str, Any]:
        model = self._model
        processor = self._processor
        assert model is not None and processor is not None

        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
            wav_path = tmp.name

        try:
            _write_wav(wav_path, pcm_bytes, _SAMPLE_RATE)
            input_device = self._get_input_device(model)
            inputs = processor(
                audio=wav_path,
                sampling_rate=None,
                return_tensors="pt",
                padding=True,
                add_generation_prompt=True,
                context_info=context_info,
            )
            inputs = {
                k: v.to(input_device) if isinstance(v, torch.Tensor) else v
                for k, v in inputs.items()
            }
            with torch.no_grad():
                output_ids = model.generate(**inputs, **self._gen_config(processor))
        finally:
            try:
                Path(wav_path).unlink(missing_ok=True)
            except OSError:
                pass

        generated_ids = self._extract_generated_ids(
            output_ids, inputs["input_ids"].shape[1], processor.tokenizer.eos_token_id
        )
        generated_text = processor.decode(generated_ids, skip_special_tokens=True).strip()
        vendor_segments = self._parse_vendor_segments(processor, generated_text)
        speaker_segments = self._normalize_to_daemon_segments(vendor_segments)
        structured_output = len(vendor_segments) > 0 or _looks_structured_vibevoice_output(generated_text)

        for segment in speaker_segments:
            segment["start_ms"] += offset_ms
            segment["end_ms"] += offset_ms

        if (
            len(speaker_segments) == 0
            and generated_text
            and not structured_output
            and not _should_drop_segment_text(generated_text)
        ):
            speaker_segments = [
                {
                    "segment_id": 0,
                    "start_ms": offset_ms,
                    "end_ms": offset_ms + duration_ms,
                    "speaker_id": "",
                    "text": generated_text,
                }
            ]

        plain_text = " ".join(
            s["text"]
            for s in speaker_segments
            if s.get("text") and not _should_drop_segment_text(str(s["text"]))
        ).strip()
        if (
            not plain_text
            and generated_text
            and not structured_output
            and not _should_drop_segment_text(generated_text)
        ):
            plain_text = generated_text

        return {
            "text": plain_text,
            "detected_language": None,
            "duration_ms": duration_ms,
            "speaker_segments": speaker_segments,
            "speaker_count": len({s["speaker_id"] for s in speaker_segments if s.get("speaker_id")}),
        }

    def _parse_vendor_segments(
        self, processor: VibeVoiceASRProcessor, generated_text: str
    ) -> list[dict[str, Any]]:
        try:
            parsed = processor.post_process_transcription(generated_text)
        except (RuntimeError, ValueError, TypeError) as exc:
            LOGGER.warning("post_process_transcription failed: %s", exc)
            parsed = []

        parsed = [s for s in parsed if isinstance(s, dict)]
        salvaged = self._salvage_segments(generated_text)
        return self._merge_segments(parsed, salvaged)

    def _salvage_segments(self, generated_text: str) -> list[dict[str, Any]]:
        text = generated_text.strip()
        if text.startswith("assistant"):
            text = text.removeprefix("assistant").strip()

        idx = text.find("[")
        if idx == -1:
            return []

        candidate = text[idx:]
        segments: list[dict[str, Any]] = []
        for m in _VIBEVOICE_SEGMENT_PATTERN.finditer(candidate):
            decoded_text = self._decode_json_string_fragment(m.group("text"))
            segments.append({
                "start_time": m.group("start"),
                "end_time": m.group("end"),
                "speaker_id": m.group("speaker"),
                "text": decoded_text,
            })
        if len(segments) > 0:
            return segments

        object_texts = self._extract_json_object_chunks(candidate)
        for object_text in object_texts:
            repaired_text = self._repair_json_object_text(object_text)
            try:
                payload = json.loads(repaired_text)
            except json.JSONDecodeError:
                continue

            if not isinstance(payload, dict):
                continue

            normalized_segment = self._normalize_vendor_segment_object(payload)
            if normalized_segment is not None:
                segments.append(normalized_segment)

        return segments

    def _decode_json_string_fragment(self, value: str) -> str:
        try:
            return json.loads(f'"{value}"')
        except json.JSONDecodeError:
            return value

    def _extract_json_object_chunks(self, text: str) -> list[str]:
        objects: list[str] = []
        depth = 0
        start_index: int | None = None
        in_string = False
        is_escaped = False

        for index, character in enumerate(text):
            if in_string:
                if is_escaped:
                    is_escaped = False
                    continue
                if character == "\\":
                    is_escaped = True
                    continue
                if character == '"':
                    in_string = False
                continue

            if character == '"':
                in_string = True
                continue

            if character == "{":
                if depth == 0:
                    start_index = index
                depth += 1
                continue

            if character == "}":
                if depth == 0:
                    continue
                depth -= 1
                if depth == 0 and start_index is not None:
                    objects.append(text[start_index : index + 1])
                    start_index = None

        return objects

    def _repair_json_object_text(self, text: str) -> str:
        repaired_text = text
        repaired_text = re.sub(
            r'(\"End(?: time)?\"\s*:\s*-?\d+(?:\.\d+)?)(\s*\"(?:Speaker(?: ID)?|Speaker|Content|Start(?: time)?|End(?: time)?)\")',
            r'\1,\2',
            repaired_text,
        )
        repaired_text = re.sub(
            r'(\"Speaker(?: ID)?\"\s*:\s*-?\d+)(\s*\"(?:Content|Start(?: time)?|End(?: time)?)\")',
            r'\1,\2',
            repaired_text,
        )
        repaired_text = re.sub(
            r'(\"Content\"\s*:\s*\"(?:[^\"\\]|\\.)*\")(\s*\"(?:Start(?: time)?|End(?: time)?|Speaker(?: ID)?|Speaker)\")',
            r'\1,\2',
            repaired_text,
        )
        return repaired_text

    def _normalize_vendor_segment_object(self, payload: dict[str, Any]) -> dict[str, Any] | None:
        normalized_payload: dict[str, Any] = {}
        key_mapping = {
            "Start time": "start_time",
            "Start": "start_time",
            "End time": "end_time",
            "End": "end_time",
            "Speaker ID": "speaker_id",
            "Speaker": "speaker_id",
            "Content": "text",
        }
        for source_key, target_key in key_mapping.items():
            if source_key in payload:
                normalized_payload[target_key] = payload[source_key]

        return normalized_payload if len(normalized_payload) > 0 else None

    def _merge_segments(
        self, parsed: list[dict[str, Any]], salvaged: list[dict[str, Any]]
    ) -> list[dict[str, Any]]:
        merged_by_key: dict[tuple[str, str, str], dict[str, Any]] = {}
        order: list[tuple[str, str, str]] = []
        for seg in [*parsed, *salvaged]:
            start = str(
                seg.get("start_time") or seg.get("Start time") or seg.get("Start") or ""
            )
            end = str(
                seg.get("end_time") or seg.get("End time") or seg.get("End") or ""
            )
            text = str(seg.get("text") or seg.get("Content") or "")
            speaker = str(
                seg.get("speaker_id") or seg.get("Speaker ID") or seg.get("Speaker") or ""
            ).strip()
            key = (start, end, text)
            if key not in merged_by_key:
                merged_by_key[key] = seg
                order.append(key)
                continue
            existing = merged_by_key[key]
            existing_speaker = str(
                existing.get("speaker_id") or existing.get("Speaker ID") or existing.get("Speaker") or ""
            ).strip()
            if speaker and not existing_speaker:
                merged_by_key[key] = seg
        return [merged_by_key[key] for key in order]

    def _normalize_to_daemon_segments(
        self, vendor_segments: list[dict[str, Any]]
    ) -> list[dict[str, Any]]:
        """Convert raw vendor segments to the daemon wire format."""
        merged_by_key: dict[tuple[int, int, str], dict[str, Any]] = {}
        order: list[tuple[int, int, str]] = []
        for seg in vendor_segments:
            text = str(seg.get("text") or seg.get("Content") or "").strip()
            if not text or _should_drop_segment_text(text):
                continue
            start = self._to_float(
                seg.get("start_time") or seg.get("Start time") or seg.get("Start")
            )
            end = self._to_float(
                seg.get("end_time") or seg.get("End time") or seg.get("End")
            )
            speaker = _to_spk_id(
                seg.get("speaker_id") or seg.get("Speaker ID") or seg.get("Speaker")
            )
            start_ms = int(start * 1000) if start is not None else 0
            end_ms = int(end * 1000) if end is not None else 0
            normalized_segment = {
                "segment_id": 0,
                "start_ms": start_ms,
                "end_ms": end_ms,
                "speaker_id": speaker or "",
                "text": text,
            }
            key = (start_ms, end_ms, text)
            if key not in merged_by_key:
                merged_by_key[key] = normalized_segment
                order.append(key)
                continue
            existing_segment = merged_by_key[key]
            if normalized_segment["speaker_id"] and not existing_segment["speaker_id"]:
                merged_by_key[key] = normalized_segment

        result: list[dict[str, Any]] = []
        for idx, key in enumerate(order):
            segment = dict(merged_by_key[key])
            segment["segment_id"] = idx
            result.append(segment)
        return result

    def _clip_segments_to_window(
        self,
        segments: list[dict[str, Any]],
        keep_start_ms: int,
        keep_end_ms: int,
    ) -> list[dict[str, Any]]:
        clipped_segments: list[dict[str, Any]] = []
        for segment in segments:
            start_ms = int(segment["start_ms"])
            end_ms = int(segment["end_ms"])
            if end_ms <= keep_start_ms or start_ms >= keep_end_ms:
                continue

            clipped_start_ms = max(start_ms, keep_start_ms)
            clipped_end_ms = min(end_ms, keep_end_ms)
            if clipped_end_ms - clipped_start_ms < _MIN_STITCH_SEGMENT_MS:
                continue

            clipped_segment = dict(segment)
            clipped_segment["start_ms"] = clipped_start_ms
            clipped_segment["end_ms"] = clipped_end_ms
            clipped_segments.append(clipped_segment)

        return clipped_segments

    def _stitch_chunk_boundaries(
        self,
        segments: list[dict[str, Any]],
    ) -> list[dict[str, Any]]:
        if len(segments) == 0:
            return []

        sorted_segments = sorted(
            segments,
            key=lambda item: (item["start_ms"], item["end_ms"], item["text"]),
        )
        stitched: list[dict[str, Any]] = []
        for segment in sorted_segments:
            if _should_drop_segment_text(str(segment.get("text") or "")):
                continue

            current = dict(segment)
            if len(stitched) == 0:
                stitched.append(current)
                continue

            previous = stitched[-1]
            compatible_speaker = (
                previous["speaker_id"] == current["speaker_id"]
                or previous["speaker_id"] == ""
                or current["speaker_id"] == ""
            )
            same_text = _normalized_text_key(previous["text"]) == _normalized_text_key(current["text"])
            touching = current["start_ms"] <= previous["end_ms"] + _MIN_STITCH_SEGMENT_MS

            if same_text and compatible_speaker and touching:
                previous["end_ms"] = max(previous["end_ms"], current["end_ms"])
                if previous["speaker_id"] == "" and current["speaker_id"] != "":
                    previous["speaker_id"] = current["speaker_id"]
                continue

            previous_repetitive = _is_repetitive_segment_text(previous["text"])
            current_repetitive = _is_repetitive_segment_text(current["text"])
            if current["start_ms"] < previous["end_ms"] and compatible_speaker:
                if previous_repetitive and not current_repetitive:
                    stitched[-1] = current
                    continue
                if current_repetitive and not previous_repetitive:
                    continue

            stitched.append(current)

        return stitched

    def _to_float(self, value: Any) -> float | None:
        if value is None:
            return None
        try:
            return float(value)
        except (TypeError, ValueError):
            return None

    def _get_input_device(self, model: VibeVoiceASRForConditionalGeneration) -> torch.device:
        try:
            return next(model.parameters()).device
        except StopIteration:
            return torch.device(self._device)

    def _gen_config(self, processor: VibeVoiceASRProcessor) -> dict[str, Any]:
        return {
            "max_new_tokens": _MAX_NEW_TOKENS,
            "do_sample": False,
            "num_beams": 1,
            "pad_token_id": processor.pad_id,
            "eos_token_id": processor.tokenizer.eos_token_id,
        }

    def _extract_generated_ids(
        self,
        output_ids: torch.Tensor,
        input_length: int,
        eos_token_id: int | None,
    ) -> torch.Tensor:
        if output_ids.ndim != 2 or output_ids.shape[0] == 0:
            raise RuntimeError("Unexpected output shape from VibeVoice generation")
        generated = output_ids[0, input_length:].detach().cpu()
        if eos_token_id is None:
            return generated
        eos_positions = (generated == eos_token_id).nonzero(as_tuple=True)[0]
        if len(eos_positions) == 0:
            return generated
        return generated[: eos_positions[0]]

    def _resolve_snapshot(self, repo_id: str, cache_dir: str | None) -> Path:
        kwargs: dict[str, Any] = {"local_files_only": True}
        if cache_dir is not None:
            kwargs["cache_dir"] = cache_dir
        return Path(snapshot_download(repo_id, **kwargs))

    def _resolve_device(self) -> str:
        forced = os.environ.get("ECHOSCRIPT_FORCE_DEVICE", "").strip().lower()
        if forced == "cuda":
            return "cuda" if torch.cuda.is_available() else "cpu"
        if forced == "cpu":
            return "cpu"
        return "cuda" if torch.cuda.is_available() else "cpu"

    def _resolve_dtype(self, device: str) -> torch.dtype:
        if device == "cuda":
            return torch.bfloat16 if torch.cuda.is_bf16_supported() else torch.float16
        forced = os.environ.get("ECHOSCRIPT_FORCE_CPU_DTYPE", "").strip().lower()
        if forced == "float32":
            return torch.float32
        if forced == "bfloat16":
            return torch.bfloat16
        return torch.bfloat16

    def _load_model_from_snapshot(
        self, snapshot_path: Path, attn_impl: str
    ) -> VibeVoiceASRForConditionalGeneration:
        config = VibeVoiceASRConfig.from_pretrained(str(snapshot_path), local_files_only=True)
        if hasattr(config, "dtype"):
            config.dtype = self._dtype
        else:
            config.torch_dtype = self._dtype
        setattr(config, "_attn_implementation", attn_impl)

        with init_empty_weights():
            model = VibeVoiceASRForConditionalGeneration(config)

        expected_keys = set(model.state_dict().keys())
        index_path = snapshot_path / "model.safetensors.index.json"
        if not index_path.exists():
            raise FileNotFoundError(f"Model shard index missing: {index_path}")

        shard_index = json.loads(index_path.read_text(encoding="utf-8"))
        weight_map = shard_index.get("weight_map")
        if not isinstance(weight_map, dict):
            raise ValueError(f"Invalid shard index: {index_path}")

        loaded_keys: set[str] = set()
        unexpected_keys: list[str] = []
        with torch.no_grad():
            for shard_name in sorted({str(v) for v in weight_map.values()}):
                shard_path = snapshot_path / shard_name
                if not shard_path.exists():
                    raise FileNotFoundError(f"Shard missing: {shard_path}")
                LOGGER.info("Loading shard %s", shard_path.name)
                with safe_open(str(shard_path), framework="pt") as handle:
                    for key in handle.keys():
                        loaded_keys.add(key)
                        if key not in expected_keys:
                            unexpected_keys.append(key)
                            continue
                        t = handle.get_tensor(key)
                        if t.is_floating_point():
                            t = t.to(self._dtype)
                        set_module_tensor_to_device(model, key, device="cpu", value=t)
                        del t
                gc.collect()

        model.tie_weights()
        missing_keys = [k for k in expected_keys if k not in loaded_keys and k != "lm_head.weight"]
        if missing_keys or unexpected_keys:
            LOGGER.warning(
                "Key mismatch: missing=%s unexpected=%s", missing_keys, unexpected_keys
            )

        try:
            model.generation_config = GenerationConfig.from_pretrained(
                str(snapshot_path), local_files_only=True
            )
        except OSError:
            LOGGER.info("Generation config missing for %s, using defaults", snapshot_path)

        model.eval()
        return model
