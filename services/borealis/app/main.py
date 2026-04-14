import importlib
from typing import Any

from echoscript_shared.hf_env import bootstrap_hf_cache_env

bootstrap_hf_cache_env()

from .adapter import BorealisAdapter


def _resolve_cli_runner() -> Any:
    module = importlib.import_module("echoscript_shared.service_runner")
    runner = getattr(module, "run_service_from_cli", None)
    if runner is None:
        raise RuntimeError("run_service_from_cli is not available in echoscript_shared.service_runner")

    return runner


def _main() -> None:
    run_service_from_cli = _resolve_cli_runner()
    run_service_from_cli(BorealisAdapter(), default_model_name="borealis")


if __name__ == "__main__":
    _main()
