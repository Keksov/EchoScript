from echoscript_shared import BaseASRAdapter, TranscriptionResult


class VibeVoiceAdapter(BaseASRAdapter):
    MODEL_ID = "microsoft/VibeVoice-ASR"

    def load_model(self) -> None:
        raise NotImplementedError

    def transcribe(self, audio_path: str, language: str | None = None) -> TranscriptionResult:
        raise NotImplementedError

    def is_loaded(self) -> bool:
        return False
