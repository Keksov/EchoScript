from echoscript_shared import BaseASRAdapter, TranscriptionResult


class WhisperPodlodkaAdapter(BaseASRAdapter):
    MODEL_ID = "bond005/whisper-podlodka-turbo"

    def load_model(self) -> None:
        raise NotImplementedError

    def transcribe(self, audio_path: str, language: str | None = None) -> TranscriptionResult:
        raise NotImplementedError

    def is_loaded(self) -> bool:
        return False
