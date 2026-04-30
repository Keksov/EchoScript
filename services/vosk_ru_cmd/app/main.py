from echoscript_shared.service_runner import run_service_from_cli
from echoscript_shared.vosk_env import bootstrap_vosk_models_root

from app.adapter import VoskRuCmdAdapter

bootstrap_vosk_models_root()


def _main() -> None:
    run_service_from_cli(VoskRuCmdAdapter(), default_model_name="vosk_ru_cmd")


if __name__ == "__main__":
    _main()