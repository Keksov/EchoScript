import os
from pathlib import Path

VOSK_MODELS_ROOT_ENV = "VOSK_MODELS_ROOT"
_WINDOWS_DEFAULT_VOSK_ROOT = Path("C:/var/vosk")


def bootstrap_vosk_models_root() -> Path | None:
    default_root = _get_default_vosk_models_root()
    configured_root = os.environ.get(VOSK_MODELS_ROOT_ENV)
    if configured_root is None and default_root is None:
        return None

    models_root = Path(configured_root or default_root)
    os.environ.setdefault(VOSK_MODELS_ROOT_ENV, str(models_root))
    models_root.mkdir(parents=True, exist_ok=True)
    return models_root


def get_vosk_models_root() -> Path:
    models_root = bootstrap_vosk_models_root()
    if models_root is None:
        raise RuntimeError(
            "VOSK_MODELS_ROOT is not configured. Set the environment variable or run scripts/env.bat."
        )

    return models_root


def is_vosk_model_name(model_name: str) -> bool:
    return model_name.startswith("vosk_")


def _get_default_vosk_models_root() -> Path | None:
    if os.name != "nt":
        return None

    return _WINDOWS_DEFAULT_VOSK_ROOT
