from typing import Any

from echoscript_shared import BaseASRAdapter, TranscriptionResult


class BorealisAdapter(BaseASRAdapter):
    MODEL_ID = "Vikhrmodels/Borealis-5b-it"

    def load_model(self) -> None:
        raise NotImplementedError

    def transcribe(
        self,
        audio_path: str,
        language: str | None = None,
        params: dict[str, Any] | None = None,
    ) -> TranscriptionResult:
        raise NotImplementedError

    def is_loaded(self) -> bool:
        return False
