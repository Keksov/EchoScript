import gc
import json
import logging
import os
import re
from pathlib import Path
from typing import Any

import torch
from accelerate import init_empty_weights
from accelerate.utils import set_module_tensor_to_device
from echoscript_shared.base_adapter import BaseASRAdapter, TranscriptionResult
from echoscript_shared.hf_env import get_hf_hub_cache
from huggingface_hub import snapshot_download
from safetensors import safe_open
from transformers import GenerationConfig
from vibevoice.modular.configuration_vibevoice import VibeVoiceASRConfig
from vibevoice.modular.modeling_vibevoice_asr import (
    VibeVoiceASRForConditionalGeneration,
)
from vibevoice.processor.vibevoice_asr_processor import VibeVoiceASRProcessor

LOGGER = logging.getLogger(__name__)

_VIBEVOICE_SEGMENT_PATTERN = re.compile(
    r'\{\s*"?(?:Start(?: time)?)"?\s*:\s*(?P<start>-?\d+(?:\.\d+)?)'
    r'\s*,\s*"?(?:End(?: time)?)"?\s*:\s*(?P<end>-?\d+(?:\.\d+)?)'
    r'\s*,?\s*"?(?:Speaker(?: ID)?)"?\s*:\s*(?P<speaker>-?\d+)'
    r'\s*,\s*"?Content"?\s*:\s*"(?P<text>(?:[^"\\]|\\.)*?)"\s*\}',
    re.DOTALL,
)


class VibeVoiceAdapter(BaseASRAdapter):
    MODEL_ID = "microsoft/VibeVoice-ASR"
    TOKENIZER_MODEL_ID = "Qwen/Qwen2.5-7B"

    def __init__(self) -> None:
        self._model: VibeVoiceASRForConditionalGeneration | None = None
        self._processor: VibeVoiceASRProcessor | None = None
        self._device = "cpu"
        self._dtype: torch.dtype = torch.float32

    def load_model(self) -> None:
        if self._model is not None and self._processor is not None:
            return

        cache_dir = get_hf_hub_cache()
        model_path = self._resolve_snapshot_path(self.MODEL_ID, cache_dir)
        tokenizer_path = self._resolve_snapshot_path(self.TOKENIZER_MODEL_ID, cache_dir)
        self._device = self._resolve_device()
        self._dtype = self._resolve_dtype(self._device)
        attn_implementation = self._resolve_attention_implementation(self._device)

        LOGGER.info(
            "Loading VibeVoice processor from local snapshot %s with tokenizer %s",
            model_path,
            tokenizer_path,
        )
        self._processor = VibeVoiceASRProcessor.from_pretrained(
            str(model_path),
            language_model_pretrained_name=str(tokenizer_path),
            local_files_only=True,
        )

        LOGGER.info(
            "Loading VibeVoice model from local snapshot %s on %s with %s attention and %s dtype",
            model_path,
            self._device,
            attn_implementation,
            self._dtype,
        )
        self._model = self._load_model_from_snapshot(model_path, attn_implementation)
        if self._device == "cuda":
            self._model = self._model.to(device=self._device, dtype=self._dtype)
        else:
            self._model = self._model.to(self._device)

        self._model.eval()
        LOGGER.info(
            "Loaded VibeVoice model on %s",
            self._resolve_input_device(self._model),
        )

    def transcribe(
        self,
        audio_path: str,
        language: str | None = None,
        params: dict[str, Any] | None = None,
    ) -> TranscriptionResult:
        audio_file = Path(audio_path)
        if not audio_file.exists() or not audio_file.is_file():
            raise FileNotFoundError(f"Audio file does not exist: {audio_file}")

        if self._model is None or self._processor is None:
            self.load_model()

        model = self._model
        processor = self._processor
        if model is None or processor is None:
            raise RuntimeError("VibeVoice model is not loaded")

        if language is not None and language.lower() != "auto":
            LOGGER.info("Ignoring explicit language override for VibeVoice: %s", language)

        context_info = self._build_context_info(params)
        input_device = self._resolve_input_device(model)
        inputs = processor(
            audio=str(audio_file),
            sampling_rate=None,
            return_tensors="pt",
            padding=True,
            add_generation_prompt=True,
            context_info=context_info,
        )
        inputs = {
            key: value.to(input_device) if isinstance(value, torch.Tensor) else value
            for key, value in inputs.items()
        }

        with torch.no_grad():
            output_ids = model.generate(**inputs, **self._prepare_generation_config(processor))

        generated_ids = self._extract_generated_ids(
            output_ids,
            inputs["input_ids"].shape[1],
            processor.tokenizer.eos_token_id,
        )
        generated_text = processor.decode(generated_ids, skip_special_tokens=True).strip()
        vendor_segments = self._parse_vendor_segments(processor, generated_text)
        normalized_segments = self._normalize_segments(vendor_segments)
        text = self._build_text(normalized_segments, generated_text)

        raw_result: dict[str, Any] = {
            "text": generated_text,
            "plain_text": text,
            "segments": normalized_segments,
            "vendor_segments": vendor_segments,
            "model": self.MODEL_ID,
        }
        if context_info is not None:
            raw_result["context_info"] = context_info

        return TranscriptionResult(
            text=text,
            language=None,
            segments=normalized_segments or None,
            raw=raw_result,
        )

    def is_loaded(self) -> bool:
        return self._model is not None and self._processor is not None

    def _resolve_snapshot_path(self, repo_id: str, cache_dir: str | None) -> Path:
        snapshot_kwargs: dict[str, Any] = {"local_files_only": True}
        if cache_dir is not None:
            snapshot_kwargs["cache_dir"] = cache_dir

        return Path(snapshot_download(repo_id, **snapshot_kwargs))

    def _load_model_from_snapshot(
        self,
        snapshot_path: Path,
        attn_implementation: str,
    ) -> VibeVoiceASRForConditionalGeneration:
        config = VibeVoiceASRConfig.from_pretrained(str(snapshot_path), local_files_only=True)
        config.dtype = self._dtype
        setattr(config, "_attn_implementation", attn_implementation)

        with init_empty_weights():
            model = VibeVoiceASRForConditionalGeneration(config)

        expected_keys = set(model.state_dict().keys())
        index_path = snapshot_path / "model.safetensors.index.json"
        if not index_path.exists():
            raise FileNotFoundError(f"Model shard index is missing: {index_path}")

        shard_index = json.loads(index_path.read_text(encoding="utf-8"))
        weight_map = shard_index.get("weight_map")
        if not isinstance(weight_map, dict):
            raise ValueError(f"Invalid model shard index: {index_path}")

        loaded_keys: set[str] = set()
        unexpected_keys: list[str] = []
        shard_names = sorted({str(value) for value in weight_map.values()})
        with torch.no_grad():
            for shard_name in shard_names:
                shard_path = snapshot_path / shard_name
                if not shard_path.exists():
                    raise FileNotFoundError(f"Model shard is missing: {shard_path}")

                LOGGER.info("Restoring VibeVoice weights from shard %s", shard_path.name)
                with safe_open(str(shard_path), framework="pt") as handle:
                    for key in handle.keys():
                        loaded_keys.add(key)
                        if key not in expected_keys:
                            unexpected_keys.append(key)
                            continue

                        source_tensor = handle.get_tensor(key)
                        if source_tensor.is_floating_point():
                            source_tensor = source_tensor.to(self._dtype)

                        set_module_tensor_to_device(model, key, device="cpu", value=source_tensor)
                        del source_tensor

                gc.collect()

        model.tie_weights()
        missing_keys = [
            key
            for key in expected_keys
            if key not in loaded_keys and key != "lm_head.weight"
        ]
        if missing_keys or unexpected_keys:
            LOGGER.warning(
                "VibeVoice checkpoint restored with mismatched keys: missing=%s unexpected=%s",
                missing_keys,
                unexpected_keys,
            )

        try:
            model.generation_config = GenerationConfig.from_pretrained(str(snapshot_path), local_files_only=True)
        except OSError:
            LOGGER.warning("Generation config is missing for %s", snapshot_path)

        model.eval()
        return model

    def _resolve_device(self) -> str:
        forced_device = os.environ.get("ECHOSCRIPT_FORCE_DEVICE", "").strip().lower()
        if forced_device in {"cpu", "cuda"}:
            if forced_device == "cuda" and not torch.cuda.is_available():
                LOGGER.warning("ECHOSCRIPT_FORCE_DEVICE=cuda was requested, but CUDA is unavailable; falling back to cpu")
                return "cpu"
            return forced_device

        if len(forced_device) > 0:
            LOGGER.warning("Ignoring unsupported ECHOSCRIPT_FORCE_DEVICE=%s", forced_device)

        return "cuda" if torch.cuda.is_available() else "cpu"

    def _resolve_dtype(self, device: str) -> torch.dtype:
        if device == "cuda":
            return torch.bfloat16 if torch.cuda.is_bf16_supported() else torch.float16

        forced_cpu_dtype = os.environ.get("ECHOSCRIPT_FORCE_CPU_DTYPE", "").strip().lower()
        if forced_cpu_dtype == "float32":
            return torch.float32
        if forced_cpu_dtype == "bfloat16":
            return torch.bfloat16
        if len(forced_cpu_dtype) > 0:
            LOGGER.warning("Ignoring unsupported ECHOSCRIPT_FORCE_CPU_DTYPE=%s", forced_cpu_dtype)

        return torch.bfloat16

    def _resolve_attention_implementation(self, device: str) -> str:
        return "sdpa" if device == "cuda" else "eager"

    def _resolve_input_device(self, model: VibeVoiceASRForConditionalGeneration) -> torch.device:
        try:
            return next(model.parameters()).device
        except StopIteration:
            return torch.device(self._device)

    def _prepare_generation_config(self, processor: VibeVoiceASRProcessor) -> dict[str, Any]:
        return {
            "max_new_tokens": 1024,
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

        generated_ids = output_ids[0, input_length:].detach().cpu()
        if eos_token_id is None:
            return generated_ids

        eos_positions = (generated_ids == eos_token_id).nonzero(as_tuple=True)[0]
        if len(eos_positions) == 0:
            return generated_ids

        return generated_ids[: eos_positions[0]]

    def _parse_vendor_segments(
        self,
        processor: VibeVoiceASRProcessor,
        generated_text: str,
    ) -> list[dict[str, Any]]:
        try:
            parsed = processor.post_process_transcription(generated_text)
        except (RuntimeError, ValueError, TypeError) as error:
            LOGGER.warning("Failed to parse VibeVoice structured output: %s", error)
            parsed = []

        normalized_parsed = [segment for segment in parsed if isinstance(segment, dict)]

        salvaged_segments = self._salvage_vendor_segments(generated_text)
        merged_segments = self._merge_vendor_segments(normalized_parsed, salvaged_segments)
        if len(salvaged_segments) > 0 and len(merged_segments) > len(normalized_parsed):
            LOGGER.info("Recovered %s VibeVoice segments from partial structured output", len(salvaged_segments))

        return merged_segments

    def _salvage_vendor_segments(self, generated_text: str) -> list[dict[str, Any]]:
        cleaned_text = generated_text.strip()
        if cleaned_text.startswith("assistant"):
            cleaned_text = cleaned_text.removeprefix("assistant").strip()

        array_start = cleaned_text.find("[")
        if array_start == -1:
            return []

        candidate_text = cleaned_text[array_start:]
        regex_segments = self._extract_segment_pattern_segments(candidate_text)
        if len(regex_segments) > 0:
            return regex_segments

        object_texts = self._extract_json_object_chunks(candidate_text)
        salvaged_segments: list[dict[str, Any]] = []
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
                salvaged_segments.append(normalized_segment)

        return salvaged_segments

    def _extract_segment_pattern_segments(self, text: str) -> list[dict[str, Any]]:
        salvaged_segments: list[dict[str, Any]] = []
        for match in _VIBEVOICE_SEGMENT_PATTERN.finditer(text):
            decoded_text = self._decode_json_string_fragment(match.group("text"))
            normalized_segment = self._normalize_vendor_segment_object(
                {
                    "Start": match.group("start"),
                    "End": match.group("end"),
                    "Speaker": match.group("speaker"),
                    "Content": decoded_text,
                }
            )
            if normalized_segment is not None:
                salvaged_segments.append(normalized_segment)

        return salvaged_segments

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
        repaired_text = re.sub(r"(\"End(?: time)?\"\s*:\s*-?\d+(?:\.\d+)?)(\s*\"(?:Speaker(?: ID)?|Speaker|Content|Start(?: time)?|End(?: time)?)\")", r"\1,\2", repaired_text)
        repaired_text = re.sub(r"(\"Speaker(?: ID)?\"\s*:\s*-?\d+)(\s*\"(?:Content|Start(?: time)?|End(?: time)?)\")", r"\1,\2", repaired_text)
        repaired_text = re.sub(r"(\"Content\"\s*:\s*\"(?:[^\"\\]|\\.)*\")(\s*\"(?:Start(?: time)?|End(?: time)?|Speaker(?: ID)?|Speaker)\")", r"\1,\2", repaired_text)
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

    def _merge_vendor_segments(
        self,
        parsed_segments: list[dict[str, Any]],
        salvaged_segments: list[dict[str, Any]],
    ) -> list[dict[str, Any]]:
        merged_segments: list[dict[str, Any]] = []
        seen_segments: set[tuple[Any, Any, Any, Any]] = set()

        for segment in [*parsed_segments, *salvaged_segments]:
            dedupe_key = (
                segment.get("start_time"),
                segment.get("end_time"),
                segment.get("speaker_id"),
                segment.get("text"),
            )
            if dedupe_key in seen_segments:
                continue

            seen_segments.add(dedupe_key)
            merged_segments.append(segment)

        return merged_segments

    def _normalize_segments(self, vendor_segments: list[dict[str, Any]]) -> list[dict[str, Any]]:
        normalized_segments: list[dict[str, Any]] = []
        for index, segment in enumerate(vendor_segments):
            text = str(segment.get("text", "")).strip()
            if len(text) == 0:
                continue

            start_value = self._first_present(segment, "start_time", "start")
            end_value = self._first_present(segment, "end_time", "end")
            speaker_value = self._first_present(segment, "speaker_id", "speaker")

            normalized_segments.append(
                {
                    "id": index,
                    "start": self._to_float(start_value),
                    "end": self._to_float(end_value),
                    "speaker": self._normalize_speaker(speaker_value),
                    "text": text,
                }
            )

        return normalized_segments

    def _first_present(self, payload: dict[str, Any], *keys: str) -> Any:
        for key in keys:
            if key in payload and payload[key] is not None:
                return payload[key]

        return None

    def _normalize_speaker(self, value: Any) -> str | None:
        if value is None:
            return None

        normalized_value = str(value).strip()
        if len(normalized_value) == 0:
            return None
        if normalized_value.lower().startswith("speaker"):
            return normalized_value

        return f"Speaker {normalized_value}"

    def _build_text(self, segments: list[dict[str, Any]], generated_text: str) -> str:
        if len(segments) == 0:
            return generated_text

        return "\n".join(str(segment.get("text", "")).strip() for segment in segments if segment.get("text"))

    def _build_context_info(self, params: dict[str, Any] | None) -> str | None:
        if not isinstance(params, dict):
            return None

        context_parts: list[str] = []
        context_info = params.get("context_info")
        if isinstance(context_info, str) and len(context_info.strip()) > 0:
            context_parts.append(context_info.strip())

        hotwords = params.get("hotwords")
        normalized_hotwords: list[str] = []
        if isinstance(hotwords, list):
            normalized_hotwords = [
                str(item).strip()
                for item in hotwords
                if isinstance(item, str) and len(item.strip()) > 0
            ]
        elif isinstance(hotwords, str) and len(hotwords.strip()) > 0:
            normalized_hotwords = [item.strip() for item in hotwords.split(",") if len(item.strip()) > 0]

        if len(normalized_hotwords) > 0:
            context_parts.append(f"Hotwords: {', '.join(normalized_hotwords)}")

        if len(context_parts) == 0:
            return None

        return "\n".join(context_parts)

    def _to_float(self, value: Any) -> float | None:
        if isinstance(value, (int, float)):
            return float(value)

        if isinstance(value, str):
            normalized_value = value.strip()
            if len(normalized_value) == 0:
                return None
            try:
                return float(normalized_value)
            except ValueError:
                return None

        return None
