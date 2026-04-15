import importlib
import logging
import sys
from collections.abc import Iterable
from pathlib import Path
from typing import Any, TypeVar

LOGGER = logging.getLogger(__name__)

_StateDict = TypeVar("_StateDict")


def find_git_lfs_pointer_files(paths: Iterable[Path]) -> list[str]:
    pointer_files: list[str] = []
    for path in paths:
        if is_git_lfs_pointer_file(path):
            pointer_files.append(path.name)

    return pointer_files


def is_git_lfs_pointer_file(path: Path) -> bool:
    try:
        if not path.exists() or not path.is_file() or path.stat().st_size > 1024:
            return False

        return path.read_bytes().startswith(b"version https://git-lfs.github.com/spec/v1")
    except OSError:
        return False


def patch_transformers_pickle_compatibility() -> None:
    try:
        tokenization_utils = importlib.import_module("transformers.tokenization_utils")
        tokenization_python = importlib.import_module("transformers.tokenization_python")
        if not hasattr(tokenization_utils, "Trie") and hasattr(tokenization_python, "Trie"):
            tokenization_utils.Trie = tokenization_python.Trie
    except ImportError:
        LOGGER.debug("Unable to patch Trie compatibility for recasepunc", exc_info=True)

    try:
        bert_tokenization = importlib.import_module("transformers.models.bert.tokenization_bert")
        bert_legacy = importlib.import_module("transformers.models.bert.tokenization_bert_legacy")
        if not hasattr(bert_tokenization, "BasicTokenizer") and hasattr(bert_legacy, "BasicTokenizer"):
            bert_tokenization.BasicTokenizer = bert_legacy.BasicTokenizer
    except ImportError:
        LOGGER.debug("Unable to patch BasicTokenizer compatibility for recasepunc", exc_info=True)


def patch_main_module_pickle_compatibility(module: Any) -> None:
    main_modules = [
        main_module
        for main_module in (sys.modules.get("__main__"), sys.modules.get("app.main"))
        if main_module is not None
    ]
    exported_names = ("Config", "WordpieceTokenizer", "bpe")

    for main_module in main_modules:
        for exported_name in exported_names:
            if hasattr(module, exported_name) and not hasattr(main_module, exported_name):
                setattr(main_module, exported_name, getattr(module, exported_name))


def patch_module_torch_load(module: Any) -> None:
    torch_module = getattr(module, "torch", None)
    original_load = getattr(torch_module, "load", None)
    if not callable(original_load):
        return

    if getattr(original_load, "_echoscript_weights_only_patched", False):
        return

    def patched_load(*args: Any, **kwargs: Any) -> Any:
        kwargs.setdefault("weights_only", False)
        return original_load(*args, **kwargs)

    setattr(patched_load, "_echoscript_weights_only_patched", True)
    torch_module.load = patched_load


def patch_module_hf_loading(module: Any) -> None:
    for symbol_name in ("AutoModel", "AutoTokenizer", "BertTokenizer"):
        _patch_module_from_pretrained(module, symbol_name)


def _patch_module_from_pretrained(module: Any, symbol_name: str) -> None:
    loader_class = getattr(module, symbol_name, None)
    original_from_pretrained = getattr(loader_class, "from_pretrained", None)
    if not callable(original_from_pretrained):
        return

    class LocalFilesOnlyProxy:
        @staticmethod
        def from_pretrained(*args: Any, **kwargs: Any) -> Any:
            kwargs.setdefault("local_files_only", True)
            try:
                return original_from_pretrained(*args, **kwargs)
            except (OSError, ValueError) as error:
                model_id = str(args[0]) if len(args) > 0 else "<unknown>"
                raise RuntimeError(
                    f"Hugging Face backbone {model_id} is not cached for Vosk punctuation. "
                    "Run the corresponding download script first."
                ) from error

    setattr(module, symbol_name, LocalFilesOnlyProxy)


def patch_module_state_dict_compatibility(module: Any) -> None:
    model_class = getattr(module, "Model", None)
    original_load_state_dict = getattr(model_class, "load_state_dict", None)
    if not callable(original_load_state_dict):
        return

    if getattr(original_load_state_dict, "_echoscript_state_dict_compatibility_patched", False):
        return

    def patched_load_state_dict(
        model_instance: Any,
        state_dict: Any,
        strict: bool = True,
    ) -> Any:
        cleaned_state_dict = remove_legacy_state_dict_keys(state_dict)
        try:
            return original_load_state_dict(model_instance, cleaned_state_dict, strict=strict)
        except RuntimeError as error:
            if strict and should_retry_state_dict_load(error):
                LOGGER.warning(
                    "Retrying Vosk punctuation state_dict load with strict=False for compatibility: %s",
                    error,
                )
                return original_load_state_dict(model_instance, cleaned_state_dict, strict=False)

            raise

    setattr(patched_load_state_dict, "_echoscript_state_dict_compatibility_patched", True)
    model_class.load_state_dict = patched_load_state_dict


def remove_legacy_state_dict_keys(state_dict: _StateDict) -> _StateDict:
    if not isinstance(state_dict, dict):
        return state_dict

    ignored_suffixes = (".position_ids", ".token_type_ids")
    removed_keys = [
        key for key in state_dict.keys() if isinstance(key, str) and key.endswith(ignored_suffixes)
    ]
    if len(removed_keys) == 0:
        return state_dict

    LOGGER.info("Ignoring legacy punctuation checkpoint keys: %s", ", ".join(removed_keys))
    return state_dict.__class__((key, value) for key, value in state_dict.items() if key not in removed_keys)


def should_retry_state_dict_load(error: RuntimeError) -> bool:
    message = str(error)
    if "size mismatch" in message:
        return False

    return "Unexpected key(s) in state_dict" in message or "Missing key(s) in state_dict" in message
