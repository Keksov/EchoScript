from echoscript_shared.hf_env import bootstrap_hf_cache_env
from echoscript_shared.service_runner import run_service_from_cli
from echoscript_shared.vosk_env import bootstrap_vosk_models_root

from app.adapter import VoskRuAdapter

bootstrap_vosk_models_root()
bootstrap_hf_cache_env()


def _main() -> None:
    run_service_from_cli(VoskRuAdapter(), default_model_name="vosk_ru")


if __name__ == "__main__":
    _main()
