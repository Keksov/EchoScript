from abc import ABC, abstractmethod
from dataclasses import dataclass


@dataclass
class TranscriptionResult:
    text: str
    language: str | None = None
    segments: list[dict] | None = None


class BaseASRAdapter(ABC):
    @abstractmethod
    def load_model(self) -> None:
        ...

    @abstractmethod
    def transcribe(self, audio_path: str, language: str | None = None) -> TranscriptionResult:
        ...

    @abstractmethod
    def is_loaded(self) -> bool:
        ...
