from __future__ import annotations

import argparse
import logging

from echoscript_shared.hf_env import bootstrap_hf_cache_env
from transformers import AutoModel, AutoTokenizer

LOGGER = logging.getLogger(__name__)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model-id", required=True)
    return parser.parse_args()


def main() -> int:
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    args = parse_args()

    bootstrap_hf_cache_env()
    LOGGER.info("[INFO] Prefetching Hugging Face tokenizer for %s", args.model_id)
    AutoTokenizer.from_pretrained(args.model_id)
    LOGGER.info("[INFO] Prefetching Hugging Face model for %s", args.model_id)
    AutoModel.from_pretrained(args.model_id)
    LOGGER.info("[OK] Hugging Face backbone cached for %s", args.model_id)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
