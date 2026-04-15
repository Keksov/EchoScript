from typing import Any

from echoscript_shared.base_adapter import BaseASRAdapter, TranscriptionResult
from echoscript_shared.vosk_runtime import VoskRuntime, VoskRuntimeConfig


class VoskEnAdapter(BaseASRAdapter):
    def __init__(self) -> None:
        self._runtime = VoskRuntime(
            VoskRuntimeConfig(
                model_dir_name="vosk-model-en-us-0.42-gigaspeech",
                language_code="en",
                punctuation_model_dir_name="vosk-recasepunc-en-0.22",
                speaker_model_dir_name="vosk-model-spk-0.4",
            )
        )

    def load_model(self) -> None:
        self._runtime.load_model()

    def transcribe(
        self,
        audio_path: str,
        language: str | None = None,
        params: dict[str, Any] | None = None,
    ) -> TranscriptionResult:
        return self._runtime.transcribe(audio_path=audio_path, language=language, params=params)

    def is_loaded(self) -> bool:
        return self._runtime.is_loaded()
