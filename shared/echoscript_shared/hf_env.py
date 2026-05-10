import os
from pathlib import Path

HF_HOME_ENV = "HF_HOME"
HF_HUB_CACHE_ENV = "HF_HUB_CACHE"
HUGGINGFACE_HUB_CACHE_ENV = "HUGGINGFACE_HUB_CACHE"
HF_ASSETS_CACHE_ENV = "HF_ASSETS_CACHE"
HF_XET_CACHE_ENV = "HF_XET_CACHE"
_WINDOWS_DEFAULT_HF_HOME = Path("C:/var/huggingface")


def bootstrap_hf_cache_env() -> None:
    default_hf_home = _get_default_hf_home()
    if default_hf_home is None:
        return

    hf_home = Path(os.environ.get(HF_HOME_ENV) or default_hf_home)
    hub_cache = Path(
        os.environ.get(HF_HUB_CACHE_ENV)
        or os.environ.get(HUGGINGFACE_HUB_CACHE_ENV)
        or hf_home / "hub"
    )
    assets_cache = Path(os.environ.get(HF_ASSETS_CACHE_ENV) or hf_home / "assets")
    xet_cache = Path(os.environ.get(HF_XET_CACHE_ENV) or hf_home / "xet")

    os.environ.setdefault(HF_HOME_ENV, str(hf_home))
    os.environ.setdefault(HF_HUB_CACHE_ENV, str(hub_cache))
    os.environ.setdefault(HUGGINGFACE_HUB_CACHE_ENV, str(hub_cache))
    os.environ.setdefault(HF_ASSETS_CACHE_ENV, str(assets_cache))
    os.environ.setdefault(HF_XET_CACHE_ENV, str(xet_cache))

    for cache_path in (hf_home, hub_cache, assets_cache, xet_cache):
        cache_path.mkdir(parents=True, exist_ok=True)


def get_hf_hub_cache() -> str | None:
    bootstrap_hf_cache_env()
    cache_dir = os.environ.get(HF_HUB_CACHE_ENV) or os.environ.get(HUGGINGFACE_HUB_CACHE_ENV)
    return cache_dir if cache_dir else None


def _get_default_hf_home() -> str | None:
    if os.name != "nt":
        return None

    return str(_WINDOWS_DEFAULT_HF_HOME)