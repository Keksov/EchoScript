import importlib.util
import json
import logging
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import librosa
import numpy as np
import soundfile as sf

from echoscript_shared.base_adapter import TranscriptionResult
from echoscript_shared.hf_env import bootstrap_hf_cache_env
from echoscript_shared.vosk_compat import (
    find_git_lfs_pointer_files,
    patch_main_module_pickle_compatibility,
    patch_module_hf_loading,
    patch_module_state_dict_compatibility,
    patch_module_torch_load,
    patch_transformers_pickle_compatibility,
)
from echoscript_shared.vosk_env import get_vosk_models_root

LOGGER = logging.getLogger(__name__)

_TARGET_SAMPLE_RATE = 16_000
_PCM_CHUNK_FRAMES = 4_000
_INT16_MAX = float(np.iinfo(np.int16).max)

try:
    from vosk import KaldiRecognizer, Model, SpkModel
except ImportError:
    KaldiRecognizer = None
    Model = None
    SpkModel = None


@dataclass(frozen=True)
class VoskRuntimeConfig:
    model_dir_name: str
    language_code: str
    punctuation_model_dir_name: str | None = None
    speaker_model_dir_name: str | None = None


class VoskRuntime:
    def __init__(self, config: VoskRuntimeConfig) -> None:
        self._config = config
        self._model: Any | None = None
        self._speaker_model: Any | None = None
        self._punctuation_predictor: Any | None = None

    def load_model(self) -> None:
        if self._model is not None:
            return

        if Model is None:
            raise RuntimeError("vosk is not installed. Run the corresponding setup script first.")

        model_path = self._resolve_model_path()
        if not model_path.exists():
            raise FileNotFoundError(
                f"Vosk model directory does not exist: {model_path}. Run the download script first."
            )

        LOGGER.info("Loading Vosk model from %s", model_path)
        self._model = Model(str(model_path))
        LOGGER.info("Loaded Vosk model %s", self._config.model_dir_name)

    def transcribe(
        self,
        audio_path: str,
        language: str | None = None,
        params: dict[str, Any] | None = None,
    ) -> TranscriptionResult:
        audio_file = Path(audio_path)
        if not audio_file.exists() or not audio_file.is_file():
            raise FileNotFoundError(f"Audio file does not exist: {audio_file}")

        if self._model is None:
            self.load_model()

        if self._model is None:
            raise RuntimeError("Vosk model is not loaded")

        normalized_params = params or {}
        punctuation_enabled = self._coerce_bool_param(normalized_params.get("punctuation"))
        speaker_embeddings_enabled = self._coerce_bool_param(normalized_params.get("speaker_embeddings"))
        self._log_ignored_runtime_params(language, normalized_params)

        if punctuation_enabled:
            self._get_punctuation_predictor()

        recognizer = self._create_recognizer(normalized_params, speaker_embeddings_enabled)
        pcm_bytes = self._convert_audio_to_pcm_bytes(audio_file)
        raw_payloads = self._decode_audio(recognizer, pcm_bytes)
        segments = self._normalize_segments(raw_payloads)
        transcript_text = self._build_transcript_text(segments, raw_payloads)
        normalized_segments = segments
        normalized_text = transcript_text

        if punctuation_enabled:
            normalized_text = self._apply_punctuation(transcript_text)
            normalized_segments = self._punctuate_segments(segments)

        raw_result: dict[str, Any] = {
            "text": transcript_text,
            "language": self._config.language_code,
            "model": self._config.model_dir_name,
            "segments": segments,
            "recognizer_results": raw_payloads,
        }

        return TranscriptionResult(
            text=normalized_text,
            language=self._config.language_code,
            segments=normalized_segments or None,
            raw=raw_result,
        )

    def is_loaded(self) -> bool:
        return self._model is not None

    def _resolve_model_path(self) -> Path:
        return get_vosk_models_root() / self._config.model_dir_name

    def _create_recognizer(self, params: dict[str, Any], speaker_embeddings_enabled: bool) -> Any:
        if KaldiRecognizer is None or self._model is None:
            raise RuntimeError("vosk is not available")

        grammar = self._coerce_grammar_param(params.get("grammar"))
        if grammar is None:
            recognizer = KaldiRecognizer(self._model, _TARGET_SAMPLE_RATE)
        else:
            recognizer = KaldiRecognizer(
                self._model,
                _TARGET_SAMPLE_RATE,
                json.dumps(grammar, ensure_ascii=False),
            )

        recognizer.SetWords(True)
        if bool(params.get("partial_words", False)) and hasattr(recognizer, "SetPartialWords"):
            recognizer.SetPartialWords(True)
        if speaker_embeddings_enabled:
            if not hasattr(recognizer, "SetSpkModel"):
                raise RuntimeError("Installed vosk package does not support speaker embeddings")

            recognizer.SetSpkModel(self._get_speaker_model())

        return recognizer

    def _get_speaker_model(self) -> Any:
        if self._speaker_model is not None:
            return self._speaker_model

        if SpkModel is None:
            raise RuntimeError("vosk speaker model support is unavailable. Run the corresponding setup script first.")

        if not self._config.speaker_model_dir_name:
            raise RuntimeError(f"Speaker embeddings are not configured for {self._config.model_dir_name}")

        speaker_model_path = get_vosk_models_root() / self._config.speaker_model_dir_name
        required_files = ("mfcc.conf", "final.ext.raw", "mean.vec", "transform.mat")
        missing_files = [file_name for file_name in required_files if not (speaker_model_path / file_name).exists()]
        if missing_files:
            missing_details = ", ".join(missing_files)
            raise FileNotFoundError(
                f"Speaker embedding model is incomplete at {speaker_model_path}. Missing: {missing_details}. "
                "Run the corresponding download script first."
            )

        unresolved_pointer_files = find_git_lfs_pointer_files(
            speaker_model_path / file_name for file_name in required_files
        )
        if len(unresolved_pointer_files) > 0:
            pointer_details = ", ".join(unresolved_pointer_files)
            raise RuntimeError(
                f"Speaker embedding model at {speaker_model_path} contains unresolved Git LFS pointer files: "
                f"{pointer_details}. Re-run the corresponding download script first."
            )

        LOGGER.info("Loading Vosk speaker model from %s", speaker_model_path)
        self._speaker_model = SpkModel(str(speaker_model_path))
        return self._speaker_model

    def _get_punctuation_predictor(self) -> Any:
        if self._punctuation_predictor is not None:
            return self._punctuation_predictor

        if not self._config.punctuation_model_dir_name:
            raise RuntimeError(f"Punctuation is not configured for {self._config.model_dir_name}")

        punctuation_model_path = get_vosk_models_root() / self._config.punctuation_model_dir_name
        checkpoint_path = punctuation_model_path / "checkpoint"
        runtime_path = punctuation_model_path / "recasepunc.py"
        missing_paths = [path.name for path in (checkpoint_path, runtime_path) if not path.exists()]
        if missing_paths:
            missing_details = ", ".join(missing_paths)
            raise FileNotFoundError(
                f"Punctuation model is incomplete at {punctuation_model_path}. Missing: {missing_details}. "
                "Run the corresponding download script first."
            )

        unresolved_pointer_files = find_git_lfs_pointer_files((checkpoint_path, runtime_path))
        if len(unresolved_pointer_files) > 0:
            pointer_details = ", ".join(unresolved_pointer_files)
            raise RuntimeError(
                f"Punctuation model at {punctuation_model_path} contains unresolved Git LFS pointer files: "
                f"{pointer_details}. Re-run the corresponding download script first."
            )

        bootstrap_hf_cache_env()
        patch_transformers_pickle_compatibility()
        module_name = f"echoscript_vosk_recasepunc_{self._config.language_code}_{self._config.model_dir_name}".replace(
            "-", "_"
        )

        try:
            module = self._load_module(module_name, runtime_path)
            patch_module_torch_load(module)
            patch_module_hf_loading(module)
            patch_module_state_dict_compatibility(module)
            patch_main_module_pickle_compatibility(module)
            predictor_class = getattr(module, "CasePuncPredictor", None)
            if not callable(predictor_class):
                raise RuntimeError(f"CasePuncPredictor is missing in {runtime_path}")
            predictor_factory: Callable[..., Any] = predictor_class

            LOGGER.info("Loading Vosk punctuation model from %s", checkpoint_path)
            self._punctuation_predictor = self._instantiate_punctuation_predictor(
                predictor_factory,
                checkpoint_path,
            )
        except ImportError as error:
            raise RuntimeError(
                "Punctuation dependencies are unavailable. Run the corresponding setup script first."
            ) from error

        return self._punctuation_predictor

    def _load_module(self, module_name: str, module_path: Path) -> Any:
        spec = importlib.util.spec_from_file_location(module_name, module_path)
        if spec is None or spec.loader is None:
            raise RuntimeError(f"Unable to load module from {module_path}")

        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def _instantiate_punctuation_predictor(
        self,
        predictor_class: Callable[..., Any],
        checkpoint_path: Path,
    ) -> Any:
        return predictor_class(
            str(checkpoint_path),
            lang=self._config.language_code,
        )

    def _apply_punctuation(self, text: str) -> str:
        normalized_text = text.strip()
        if len(normalized_text) == 0:
            return normalized_text

        predictor = self._get_punctuation_predictor()
        tokens = list(enumerate(predictor.tokenize(normalized_text)))
        punctuated = ""

        for token, case_label, punc_label in predictor.predict(tokens, lambda item: item[1]):
            token_text = str(token[1])
            prediction = predictor.map_punc_label(
                predictor.map_case_label(token_text, case_label),
                punc_label,
            )
            if token_text.startswith("'") or (len(punctuated) > 0 and punctuated.endswith("'")):
                punctuated = f"{punctuated}{prediction}"
            elif token_text.startswith("#"):
                punctuated = f"{punctuated}{prediction}"
            else:
                punctuated = f"{punctuated} {prediction}"

        return punctuated.strip()

    def _punctuate_segments(self, segments: list[dict[str, Any]]) -> list[dict[str, Any]]:
        punctuated_segments: list[dict[str, Any]] = []
        for segment in segments:
            punctuated_segment = dict(segment)
            segment_text = str(segment.get("text", "")).strip()
            if len(segment_text) > 0:
                punctuated_segment["text"] = self._apply_punctuation(segment_text)
            punctuated_segments.append(punctuated_segment)

        return punctuated_segments

    def _convert_audio_to_pcm_bytes(self, audio_file: Path) -> bytes:
        audio_data, sample_rate = self._load_audio(audio_file)
        if sample_rate != _TARGET_SAMPLE_RATE:
            audio_data = librosa.resample(audio_data, orig_sr=sample_rate, target_sr=_TARGET_SAMPLE_RATE)

        clipped_audio = np.clip(audio_data, -1.0, 1.0)
        pcm_audio = np.asarray(clipped_audio * _INT16_MAX, dtype=np.int16)
        return pcm_audio.tobytes()

    def _load_audio(self, audio_file: Path) -> tuple[np.ndarray[Any, Any], int]:
        try:
            audio_data, sample_rate = sf.read(str(audio_file), dtype="float32", always_2d=False)
            audio_array = np.asarray(audio_data, dtype=np.float32)
            if audio_array.ndim > 1:
                audio_array = np.mean(audio_array, axis=1, dtype=np.float32)
            return audio_array, int(sample_rate)
        except (OSError, RuntimeError, ValueError):
            LOGGER.debug("soundfile failed for %s, falling back to librosa", audio_file, exc_info=True)

        audio_data, sample_rate = librosa.load(str(audio_file), sr=None, mono=False)
        audio_array = np.asarray(audio_data, dtype=np.float32)
        if audio_array.ndim > 1:
            audio_array = librosa.to_mono(audio_array)
        return np.asarray(audio_array, dtype=np.float32), int(sample_rate)

    def _decode_audio(self, recognizer: Any, pcm_bytes: bytes) -> list[dict[str, Any]]:
        payloads: list[dict[str, Any]] = []
        chunk_size = _PCM_CHUNK_FRAMES * 2

        for offset in range(0, len(pcm_bytes), chunk_size):
            chunk = pcm_bytes[offset : offset + chunk_size]
            if len(chunk) == 0:
                continue

            if recognizer.AcceptWaveform(chunk):
                payload = self._parse_recognizer_payload(recognizer.Result())
                if payload is not None:
                    payloads.append(payload)

        final_payload = self._parse_recognizer_payload(recognizer.FinalResult())
        if final_payload is not None:
            payloads.append(final_payload)

        return payloads

    def _normalize_segments(self, payloads: list[dict[str, Any]]) -> list[dict[str, Any]]:
        segments: list[dict[str, Any]] = []
        for payload in payloads:
            segment = self._build_segment(payload)
            if segment is not None:
                segments.append(segment)
        return segments

    def _build_segment(self, payload: dict[str, Any]) -> dict[str, Any] | None:
        words = self._normalize_words(payload.get("result"))
        text = str(payload.get("text", "")).strip()
        if len(text) == 0 and len(words) > 0:
            text = " ".join(
                word["text"]
                for word in words
                if isinstance(word.get("text"), str) and len(str(word.get("text"))) > 0
            ).strip()

        if len(text) == 0:
            return None

        start = words[0].get("start") if len(words) > 0 else None
        end = words[-1].get("end") if len(words) > 0 else None
        confidence = self._average_confidence(words)

        return {
            "start": start,
            "end": end,
            "text": text,
            "confidence": confidence,
            "words": words,
        }

    def _normalize_words(self, raw_words: object) -> list[dict[str, Any]]:
        if not isinstance(raw_words, list):
            return []

        words: list[dict[str, Any]] = []
        for item in raw_words:
            if not isinstance(item, dict):
                continue

            text = str(item.get("word", "")).strip()
            if len(text) == 0:
                continue

            words.append(
                {
                    "start": self._coerce_float(item.get("start")),
                    "end": self._coerce_float(item.get("end")),
                    "text": text,
                    "confidence": self._coerce_float(item.get("conf")),
                }
            )

        return words

    def _build_transcript_text(
        self,
        segments: list[dict[str, Any]],
        raw_payloads: list[dict[str, Any]],
    ) -> str:
        segment_texts = [str(segment.get("text", "")).strip() for segment in segments]
        non_empty_segment_texts = [text for text in segment_texts if len(text) > 0]
        if len(non_empty_segment_texts) > 0:
            return " ".join(non_empty_segment_texts).strip()

        payload_texts = [str(payload.get("text", "")).strip() for payload in raw_payloads]
        non_empty_payload_texts = [text for text in payload_texts if len(text) > 0]
        return " ".join(non_empty_payload_texts).strip()

    def _parse_recognizer_payload(self, payload_text: str) -> dict[str, Any] | None:
        try:
            payload = json.loads(payload_text)
        except json.JSONDecodeError:
            LOGGER.warning("Failed to parse Vosk recognizer payload", exc_info=True)
            return None

        if not isinstance(payload, dict):
            return None

        return payload

    def _average_confidence(self, words: list[dict[str, Any]]) -> float | None:
        confidences = [
            confidence
            for confidence in (word.get("confidence") for word in words)
            if isinstance(confidence, float)
        ]
        if len(confidences) == 0:
            return None

        return float(sum(confidences) / len(confidences))

    def _log_ignored_runtime_params(self, language: str | None, params: dict[str, Any]) -> None:
        if isinstance(language, str) and len(language.strip()) > 0 and language.lower() not in {
            "auto",
            self._config.language_code.lower(),
        }:
            LOGGER.info(
                "Ignoring explicit language override for %s service: %s",
                self._config.model_dir_name,
                language,
            )

        unsupported_keys = [key for key in ("hotwords",) if key in params]
        if len(unsupported_keys) > 0:
            LOGGER.info(
                "Ignoring unsupported Vosk runtime params for %s: %s",
                self._config.model_dir_name,
                ", ".join(unsupported_keys),
            )

    def _coerce_float(self, value: object) -> float | None:
        if isinstance(value, (float, int)):
            return float(value)

        return None

    def _coerce_bool_param(self, value: object) -> bool:
        if isinstance(value, bool):
            return value

        if isinstance(value, (int, float)):
            return bool(value)

        if isinstance(value, str):
            normalized_value = value.strip().lower()
            if normalized_value in {"1", "true", "yes", "on"}:
                return True
            if normalized_value in {"0", "false", "no", "off", ""}:
                return False

        return False

    def _coerce_grammar_param(self, value: object) -> list[str] | None:
        if isinstance(value, str):
            normalized_value = value.strip()
            return [normalized_value] if len(normalized_value) > 0 else None

        if not isinstance(value, list):
            return None

        grammar: list[str] = []
        for item in value:
            if not isinstance(item, str):
                continue

            normalized_item = item.strip()
            if len(normalized_item) == 0:
                continue

            grammar.append(normalized_item)

        if len(grammar) == 0:
            return None

        return grammar
