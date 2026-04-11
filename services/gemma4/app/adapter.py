from echoscript_shared import BaseASRAdapter, TranscriptionResult


class Gemma4Adapter(BaseASRAdapter):
    MODEL_ID = "google/gemma-4-E4B"

    def load_model(self) -> None:
        raise NotImplementedError

    def transcribe(self, audio_path: str, language: str | None = None) -> TranscriptionResult:
        raise NotImplementedError

    def is_loaded(self) -> bool:
        return False
