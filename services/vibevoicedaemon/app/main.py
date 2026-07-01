import argparse
import asyncio
import logging
import sys

from echoscript_shared.hf_env import bootstrap_hf_cache_env

bootstrap_hf_cache_env()

from .daemon import run_daemon
from .model import VibevoiceModel


def _build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="VibevoiceDaemon — WebSocket ASR+diarization daemon"
    )
    parser.add_argument("--host", default="127.0.0.1", help="Bind host (default: 127.0.0.1)")
    parser.add_argument("--port", type=int, default=7802, help="Bind port (default: 7802)")
    parser.add_argument("--model-name", default="vibevoice", help="Model name reported in session_ack")
    parser.add_argument(
        "--warmup",
        action="store_true",
        help="Load the model before accepting connections and print ready marker",
    )
    return parser


async def _main_async(args: argparse.Namespace) -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
        stream=sys.stdout,
        force=True,
    )
    logger = logging.getLogger(__name__)
    model = VibevoiceModel()

    if args.warmup:
        logger.info("Warming up VibeVoice model ...")
        try:
            await model.load()
        except (RuntimeError, OSError, ValueError) as exc:
            logger.error("[vibevoicedaemon] warmup failed: %s", exc)
            raise SystemExit(1) from exc
        print("[vibevoicedaemon] warmup ready", flush=True)
        print("[vibevoicedaemon] fully loaded and ready for requests", flush=True)

    await run_daemon(args.host, args.port, model, args.model_name)


def main() -> None:
    parser = _build_arg_parser()
    args = parser.parse_args()
    asyncio.run(_main_async(args))


if __name__ == "__main__":
    main()
