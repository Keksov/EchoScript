import logging
from pathlib import Path
from typing import Any

import librosa
import torch
from huggingface_hub import snapshot_download
from safetensors import safe_open
from transformers import AutoConfig, AutoFeatureExtractor, AutoModelForSpeechSeq2Seq, AutoTokenizer, GenerationConfig, pipeline
from transformers.models.whisper.tokenization_whisper import TO_LANGUAGE_CODE

from echoscript_shared.base_adapter import BaseASRAdapter, TranscriptionResult
from echoscript_shared.hf_env import get_hf_hub_cache

LOGGER = logging.getLogger(__name__)

try:
    from whisper_lid.whisper_lid import detect_language_in_long_speech, detect_language_in_speech
except ImportError:
    detect_language_in_long_speech = None
    detect_language_in_speech = None


class WhisperPodlodkaAdapter(BaseASRAdapter):
    MODEL_ID = "bond005/whisper-podlodka-turbo"

    def __init__(self) -> None:
        self._pipeline: Any | None = None

    def load_model(self) -> None:
        if self._pipeline is not None:
            return

        cache_dir = get_hf_hub_cache()
        model_path = self._resolve_model_path(cache_dir)
        self._pipeline = self._load_pipeline_from_snapshot(Path(model_path))

    def _resolve_model_path(self, cache_dir: str | None) -> str:
        if cache_dir is None:
            return snapshot_download(self.MODEL_ID)

        return snapshot_download(self.MODEL_ID, cache_dir=cache_dir)

    def _load_pipeline_from_snapshot(self, snapshot_path: Path) -> Any:
        LOGGER.info("Loading whisper pipeline from local snapshot %s", snapshot_path)
        model = self._load_model_from_snapshot(snapshot_path)
        tokenizer = AutoTokenizer.from_pretrained(str(snapshot_path), local_files_only=True)
        feature_extractor = AutoFeatureExtractor.from_pretrained(str(snapshot_path), local_files_only=True)

        pipeline_device = -1
        if torch.cuda.is_available():
            model = model.to("cuda")
            pipeline_device = 0

        return pipeline(
            task="automatic-speech-recognition",
            model=model,
            tokenizer=tokenizer,
            feature_extractor=feature_extractor,
            device=pipeline_device,
        )

    def _load_model_from_snapshot(self, snapshot_path: Path) -> Any:
        config = AutoConfig.from_pretrained(str(snapshot_path), local_files_only=True)
        model = AutoModelForSpeechSeq2Seq.from_config(config)
        model_state = model.state_dict()
        weights_path = snapshot_path / "model.safetensors"
        if not weights_path.exists():
            raise FileNotFoundError(f"Model weights are missing: {weights_path}")

        loaded_keys: set[str] = set()
        unexpected_keys: list[str] = []
        with safe_open(str(weights_path), framework="np") as handle:
            with torch.no_grad():
                for key in handle.keys():
                    loaded_keys.add(key)
                    target_tensor = model_state.get(key)
                    if target_tensor is None:
                        unexpected_keys.append(key)
                        continue

                    source_tensor = torch.from_numpy(handle.get_tensor(key))
                    target_tensor.copy_(source_tensor)

        model.tie_weights()
        missing_keys = [
            key for key in model.state_dict().keys() if key not in loaded_keys and key != "proj_out.weight"
        ]
        if missing_keys or unexpected_keys:
            LOGGER.warning(
                "Whisper checkpoint restored with mismatched keys: missing=%s unexpected=%s",
                missing_keys,
                unexpected_keys,
            )

        try:
            model.generation_config = GenerationConfig.from_pretrained(str(snapshot_path), local_files_only=True)
        except OSError:
            LOGGER.warning("Generation config is missing for %s", snapshot_path)

        model.eval()
        return model

    def transcribe(self, audio_path: str, language: str | None = None) -> TranscriptionResult:
        audio_file = Path(audio_path)
        if not audio_file.exists() or not audio_file.is_file():
            raise FileNotFoundError(f"Audio file does not exist: {audio_file}")

        if self._pipeline is None:
            self.load_model()

        pipeline_instance = self._pipeline
        if pipeline_instance is None:
            raise RuntimeError("ASR pipeline is not loaded")

        target_language = self._resolve_language(audio_file, language)

        generate_kwargs: dict[str, Any] = {
            "task": "transcribe",
            "max_new_tokens": 410,
            "num_beams": 5,
            "condition_on_prev_tokens": False,
            "compression_ratio_threshold": 2.4,
            "temperature": (0.0, 0.2, 0.4, 0.6, 0.8, 1.0),
            "logprob_threshold": -1.0,
            "no_speech_threshold": 0.6,
        }
        if target_language is not None:
            generate_kwargs["language"] = target_language

        raw_output = pipeline_instance(
            str(audio_file),
            return_timestamps=True,
            generate_kwargs=generate_kwargs,
        )
        if not isinstance(raw_output, dict):
            raise RuntimeError("Unexpected output type from ASR pipeline")

        text = str(raw_output.get("text", "")).strip()
        segments = self._extract_segments(raw_output)
        return TranscriptionResult(
            text=text,
            language=target_language,
            segments=segments,
            raw=raw_output,
        )

    def is_loaded(self) -> bool:
        return self._pipeline is not None

    def _resolve_language(self, audio_file: Path, language: str | None) -> str | None:
        if language is not None and language.lower() != "auto":
            return language
        return self._detect_language(audio_file)

    def _detect_language(self, audio_file: Path) -> str | None:
        pipeline_instance = self._pipeline
        if pipeline_instance is None:
            return None

        feature_extractor = getattr(pipeline_instance, "feature_extractor", None)
        tokenizer = getattr(pipeline_instance, "tokenizer", None)
        model = getattr(pipeline_instance, "model", None)
        if feature_extractor is None or tokenizer is None or model is None:
            LOGGER.warning("ASR pipeline does not expose language detection components")
            return None

        try:
            audio, _ = librosa.load(str(audio_file), sr=16000, mono=True)
        except (RuntimeError, OSError, ValueError) as error:
            LOGGER.warning("Language detector audio load failed for %s: %s", audio_file, error)
            return None

        if detect_language_in_speech is not None:
            detected = self._call_detector(
                detect_language_in_speech,
                audio_file,
                audio,
                feature_extractor,
                tokenizer,
                model,
            )
            if detected is not None:
                return detected

        if detect_language_in_long_speech is not None:
            detected = self._call_detector(
                detect_language_in_long_speech,
                audio_file,
                audio,
                feature_extractor,
                tokenizer,
                model,
            )
            if detected is not None:
                return detected

        return None

    def _call_detector(
        self,
        detector: Any,
        audio_file: Path,
        audio: Any,
        feature_extractor: Any,
        tokenizer: Any,
        model: Any,
    ) -> str | None:
        try:
            return self._parse_detected_language(detector(audio, feature_extractor, tokenizer, model))
        except (RuntimeError, OSError, ValueError, TypeError) as error:
            LOGGER.warning("Language detector failed for %s: %s", audio_file, error)
            return None

    def _parse_detected_language(self, payload: Any) -> str | None:
        if isinstance(payload, str):
            return self._normalize_detected_language(payload)

        if isinstance(payload, dict):
            language = payload.get("language")
            return self._normalize_detected_language(language)

        if isinstance(payload, tuple) and payload:
            first = payload[0]
            if isinstance(first, list):
                return self._parse_detected_language(first)
            if isinstance(first, (tuple, list)) and first:
                return self._normalize_detected_language(first[0])
            if isinstance(first, str):
                return self._normalize_detected_language(first)

        if isinstance(payload, (list, tuple)) and payload:
            first = payload[0]
            if isinstance(first, str):
                return self._normalize_detected_language(first)
            if isinstance(first, dict):
                language = first.get("language")
                return self._normalize_detected_language(language)
            if isinstance(first, (list, tuple)) and first:
                return self._normalize_detected_language(first[0])

        return None

    def _normalize_detected_language(self, language: Any) -> str | None:
        if not isinstance(language, str):
            return None

        normalized = language.strip().lower()
        if normalized in {"", "no speech"}:
            return None

        return TO_LANGUAGE_CODE.get(normalized, normalized)

    def _extract_segments(self, raw_output: dict[str, Any]) -> list[dict] | None:
        chunks = raw_output.get("chunks")
        if not isinstance(chunks, list):
            return None

        segments: list[dict[str, Any]] = []
        for index, chunk in enumerate(chunks):
            if not isinstance(chunk, dict):
                continue

            start, end = self._extract_timestamps(chunk.get("timestamp"))
            segments.append(
                {
                    "id": index,
                    "start": start,
                    "end": end,
                    "text": str(chunk.get("text", "")).strip(),
                }
            )

        return segments or None

    def _extract_timestamps(self, timestamp: Any) -> tuple[float | None, float | None]:
        if isinstance(timestamp, (tuple, list)) and len(timestamp) == 2:
            return self._to_float(timestamp[0]), self._to_float(timestamp[1])
        return None, None

    def _to_float(self, value: Any) -> float | None:
        if isinstance(value, (int, float)):
            return float(value)
        return None
