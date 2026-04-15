from abc import ABC, abstractmethod
from dataclasses import dataclass
from typing import Any


@dataclass(frozen=True)
class TranscriptionResult:
    text: str
    language: str | None = None
    segments: list[dict[str, Any]] | None = None
    raw: dict[str, Any] | None = None


class BaseASRAdapter(ABC):
    @abstractmethod
    def load_model(self) -> None:
        ...

    @abstractmethod
    def transcribe(
        self,
        audio_path: str,
        language: str | None = None,
        params: dict[str, Any] | None = None,
    ) -> TranscriptionResult:
        ...

    @abstractmethod
    def is_loaded(self) -> bool:
        ...
