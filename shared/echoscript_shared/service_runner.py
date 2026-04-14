import argparse
import hashlib
import json
import logging
import os
import re
import signal
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any
from uuid import uuid4

try:
    from watchdog.events import FileSystemEventHandler
    from watchdog.observers import Observer
except ImportError:
    FileSystemEventHandler = object
    Observer = None

from echoscript_shared.base_adapter import BaseASRAdapter, TranscriptionResult

LOGGER = logging.getLogger(__name__)

MAX_JOB_ID_LENGTH = 200
JOB_ID_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]*$")
_INPUT_WAKE_IGNORED_SUFFIXES = (".json.lock", ".tmp", ".processing")
_MEDIA_CLAIM_IGNORED_SUFFIXES = (".json", ".json.lock", ".tmp", ".processing")
_CYRILLIC_TO_LATIN = str.maketrans(
    {
        "\u0430": "a",
        "\u0431": "b",
        "\u0432": "v",
        "\u0433": "g",
        "\u0434": "d",
        "\u0435": "e",
        "\u0451": "e",
        "\u0436": "zh",
        "\u0437": "z",
        "\u0438": "i",
        "\u0439": "y",
        "\u043a": "k",
        "\u043b": "l",
        "\u043c": "m",
        "\u043d": "n",
        "\u043e": "o",
        "\u043f": "p",
        "\u0440": "r",
        "\u0441": "s",
        "\u0442": "t",
        "\u0443": "u",
        "\u0444": "f",
        "\u0445": "h",
        "\u0446": "ts",
        "\u0447": "ch",
        "\u0448": "sh",
        "\u0449": "shch",
        "\u044a": "",
        "\u044b": "y",
        "\u044c": "",
        "\u044d": "e",
        "\u044e": "yu",
        "\u044f": "ya",
    }
)


def _is_queue_marker_path(path_value: object) -> bool:
    if not isinstance(path_value, str):
        return False

    return path_value.lower().endswith(".json")


def _is_processable_input_path(path_value: object) -> bool:
    if not isinstance(path_value, str):
        return False

    normalized_path = path_value.lower()
    return not normalized_path.endswith(_INPUT_WAKE_IGNORED_SUFFIXES)


class _InputWakeHandler(FileSystemEventHandler):
    def __init__(self, wake_event: threading.Event) -> None:
        self._wake_event = wake_event

    def on_created(self, event: Any) -> None:
        if getattr(event, "is_directory", False):
            return

        if _is_processable_input_path(getattr(event, "src_path", None)):
            self._wake_event.set()

    def on_moved(self, event: Any) -> None:
        if getattr(event, "is_directory", False):
            return

        if _is_processable_input_path(getattr(event, "dest_path", None)):
            self._wake_event.set()


@dataclass(frozen=True)
class ServicePaths:
    project_root: Path
    jobs_root: Path
    model_name: str

    @property
    def input_root(self) -> Path:
        return self.jobs_root / "input"

    @property
    def model_input_dir(self) -> Path:
        return self.input_root / self.model_name

    @property
    def data_root(self) -> Path:
        return self.jobs_root / "data"

    @property
    def output_dir(self) -> Path:
        return self.jobs_root / "output"

    @property
    def pid_path(self) -> Path:
        return self.project_root / "services" / f"{self.model_name}.pid"

    @property
    def stop_request_path(self) -> Path:
        return self.project_root / "services" / f"{self.model_name}.stop"

    def data_dir(self, job_id: str) -> Path:
        return self.data_root / job_id


def run_service_from_cli(adapter: BaseASRAdapter, default_model_name: str) -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--jobs-root", required=True)
    parser.add_argument("--project-root", required=True)
    parser.add_argument("--model-name", default=default_model_name)
    parser.add_argument("--poll-interval-ms", type=int, default=500)
    parser.add_argument("--load-only", action="store_true")
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )

    run_model_service(
        adapter=adapter,
        model_name=str(args.model_name),
        jobs_root=Path(str(args.jobs_root)).resolve(),
        project_root=Path(str(args.project_root)).resolve(),
        poll_interval_ms=int(args.poll_interval_ms),
        load_only=bool(args.load_only),
    )


def run_model_service(
    adapter: BaseASRAdapter,
    model_name: str,
    jobs_root: Path,
    project_root: Path,
    poll_interval_ms: int = 500,
    load_only: bool = False,
) -> None:
    paths = ServicePaths(
        project_root=project_root,
        jobs_root=jobs_root,
        model_name=model_name,
    )
    _ensure_service_directories(paths)

    LOGGER.info("Starting service %s", model_name)
    LOGGER.info("Loading model %s", model_name)

    if load_only:
        adapter.load_model()
        LOGGER.info("Loaded model %s successfully", model_name)
        return

    stop_event = threading.Event()
    wake_event = threading.Event()
    _install_signal_handlers(stop_event)
    _remove_stop_request(paths.stop_request_path)
    _write_pid_file(paths.pid_path)

    model_thread: threading.Thread | None = None
    input_watcher: Any | None = None
    executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix=f"{model_name}-job")
    poll_interval_seconds = max(poll_interval_ms, 100) / 1000.0

    try:
        adapter.load_model()
        input_watcher = _start_input_watcher(paths.model_input_dir, wake_event)

        model_thread = threading.Thread(
            target=_model_input_loop,
            args=(paths, adapter, executor, stop_event, wake_event, poll_interval_seconds),
            name=f"{model_name}-model",
            daemon=False,
        )

        model_thread.start()

        while not stop_event.is_set():
            if not model_thread.is_alive():
                LOGGER.warning("The service loop stopped unexpectedly for %s", model_name)
                stop_event.set()
                break

            if paths.stop_request_path.exists():
                LOGGER.info("Stop request file detected for %s", model_name)
                stop_event.set()
                break

            model_thread.join(timeout=0.5)
    finally:
        stop_event.set()
        wake_event.set()
        _stop_input_watcher(input_watcher)
        if model_thread is not None:
            model_thread.join(timeout=5.0)
        executor.shutdown(wait=True)
        _remove_pid_file(paths.pid_path)
        _remove_stop_request(paths.stop_request_path)
        LOGGER.info("Stopped service %s", model_name)


def _start_input_watcher(watch_dir: Path, wake_event: threading.Event) -> Any | None:
    if Observer is None:
        LOGGER.info("watchdog is not installed; using polling-only queue wake-up for %s", watch_dir)
        return None

    observer = Observer()
    try:
        observer.schedule(_InputWakeHandler(wake_event), str(watch_dir), recursive=False)
        observer.start()
    except (OSError, RuntimeError):
        LOGGER.warning(
            "Failed to start input watcher for %s; using polling-only queue wake-up",
            watch_dir,
            exc_info=True,
        )
        try:
            observer.stop()
            observer.join(timeout=1.0)
        except RuntimeError:
            pass
        return None

    LOGGER.info("Watching model queue for wake-up hints: %s", watch_dir)
    return observer


def _stop_input_watcher(observer: Any | None) -> None:
    if observer is None:
        return

    observer.stop()
    observer.join(timeout=3.0)


def _model_input_loop(
    paths: ServicePaths,
    adapter: BaseASRAdapter,
    executor: ThreadPoolExecutor,
    stop_event: threading.Event,
    wake_event: threading.Event,
    poll_interval: float,
) -> None:
    LOGGER.info("Polling model queue: %s", paths.model_input_dir)
    while not stop_event.is_set():
        lock_path: Path | None = None
        claimed = _claim_queue_file(paths.model_input_dir)
        if claimed is not None:
            job_id, lock_path = claimed
            data_dir = paths.data_dir(job_id)
        else:
            media_claim = _claim_media_file(paths.model_input_dir)
            if media_claim is None:
                if wake_event.wait(poll_interval):
                    wake_event.clear()
                continue

            processing_path, original_filename = media_claim
            job_id = _build_media_job_id(paths.model_name, original_filename)
            data_dir = paths.data_dir(job_id)
            try:
                _bootstrap_media_job(paths, job_id, processing_path, original_filename)
            except (OSError, RuntimeError, ValueError, TypeError) as error:
                LOGGER.exception("Failed to bootstrap media job %s from %s", job_id, original_filename)
                try:
                    _record_bootstrap_failure(data_dir, error)
                except (OSError, RuntimeError, ValueError, TypeError):
                    LOGGER.exception("Failed to persist bootstrap failure for job %s", job_id)

                try:
                    _write_output_marker(paths.output_dir / f"{job_id}.json", "failed")
                except OSError:
                    LOGGER.exception("Failed to write bootstrap failure marker for job %s", job_id)

                continue

        final_status = "ready"
        try:
            _append_status(data_dir, "processing")
            result = executor.submit(_process_job, adapter, data_dir).result()
            _write_job_result_artifacts(data_dir, result)
            _append_status(data_dir, "ready")
        except (OSError, RuntimeError, ValueError, TypeError) as error:
            LOGGER.exception("Failed to process job %s", job_id)
            _append_status(data_dir, "failed", str(error))
            final_status = "failed"
        finally:
            try:
                _write_output_marker(paths.output_dir / f"{job_id}.json", final_status)
            except OSError as marker_error:
                LOGGER.exception("Failed to write output marker for job %s", job_id)
                try:
                    _append_status(data_dir, "failed", f"Failed to write output marker: {marker_error}")
                except (OSError, RuntimeError, ValueError, TypeError):
                    LOGGER.exception("Failed to append marker-write failure status for job %s", job_id)

            if lock_path is not None:
                _safe_unlink(lock_path)


def _process_job(adapter: BaseASRAdapter, data_dir: Path) -> dict[str, Any]:
    params = _load_params(data_dir)
    audio_path = _resolve_audio_path(data_dir)
    language = _extract_language(params)
    result = adapter.transcribe(str(audio_path), language)
    return {
        "raw": _build_raw_result(result),
        "normalized": _build_normalized_result(result, params),
    }


def _write_job_result_artifacts(data_dir: Path, result: dict[str, Any]) -> None:
    _write_json(data_dir / "result.json", result)
    _write_text(data_dir / "result_plain.txt", _build_plain_result_text(result))
    _write_text(data_dir / "result_timestamp.txt", _build_timestamp_result_text(result))


def _build_plain_result_text(result: dict[str, Any]) -> str:
    normalized_result = result.get("normalized")
    if not isinstance(normalized_result, dict):
        return ""

    return _normalize_text_artifact(str(normalized_result.get("text", "")))


def _build_timestamp_result_text(result: dict[str, Any]) -> str:
    normalized_result = result.get("normalized")
    if not isinstance(normalized_result, dict):
        return ""

    lines: list[str] = []
    raw_segments = normalized_result.get("segments")
    if isinstance(raw_segments, list):
        for segment in raw_segments:
            if not isinstance(segment, dict):
                continue

            text = str(segment.get("text", "")).strip()
            if len(text) == 0:
                continue

            start = _to_float(segment.get("start"))
            end = _to_float(segment.get("end"))
            if start is None or end is None:
                lines.append(text)
                continue

            lines.append(
                f"[{_format_timestamp_seconds(start)} --> {_format_timestamp_seconds(max(start, end))}]  {text}"
            )

    if len(lines) == 0:
        return _normalize_text_artifact(str(normalized_result.get("text", "")))

    return "\n".join(lines) + "\n"


def _normalize_text_artifact(text: str) -> str:
    stripped_text = text.strip()
    if len(stripped_text) == 0:
        return ""

    return f"{stripped_text}\n"


def _format_timestamp_seconds(seconds: float) -> str:
    clamped_seconds = max(seconds, 0.0)
    total_milliseconds = int(round(clamped_seconds * 1000))
    hours, remainder = divmod(total_milliseconds, 3_600_000)
    minutes, remainder = divmod(remainder, 60_000)
    whole_seconds, milliseconds = divmod(remainder, 1000)
    return f"{hours:02d}:{minutes:02d}:{whole_seconds:02d}.{milliseconds:03d}"


def _resolve_audio_path(data_dir: Path) -> Path:
    inline_path = data_dir / "input"
    if inline_path.exists() and inline_path.is_file():
        return inline_path

    input_payload = _read_json(data_dir / "input.json")
    source = input_payload.get("source")
    if not isinstance(source, str) or len(source) == 0:
        raise ValueError(f"Missing source in input.json for {data_dir.name}")

    source_path = Path(source)
    if not source_path.is_absolute():
        source_path = (data_dir / source_path).resolve()

    if not source_path.exists() or not source_path.is_file():
        raise FileNotFoundError(f"Audio source does not exist: {source_path}")

    return source_path


def _load_params(data_dir: Path) -> dict[str, Any]:
    params_path = data_dir / "params.json"
    if not params_path.exists():
        return {}
    payload = _read_json(params_path)
    return payload if isinstance(payload, dict) else {}


def _extract_language(params: dict[str, Any]) -> str | None:
    language = params.get("language")
    if not isinstance(language, str):
        return None
    if language.lower() == "auto":
        return None
    return language


def _build_raw_result(result: TranscriptionResult) -> dict[str, Any]:
    if isinstance(result.raw, dict):
        return result.raw

    payload: dict[str, Any] = {"text": result.text}
    if result.language is not None:
        payload["language"] = result.language
    if result.segments is not None:
        payload["segments"] = result.segments
    return payload


def _build_normalized_result(
    result: TranscriptionResult,
    params: dict[str, Any],
) -> dict[str, Any]:
    timestamps = bool(params.get("timestamps", True))
    include_words = bool(params.get("word_timestamps", False))

    segments: list[dict[str, Any]] = []
    if result.segments is not None and timestamps:
        for segment in result.segments:
            if not isinstance(segment, dict):
                continue

            words: list[dict[str, Any]] = []
            raw_words = segment.get("words")
            if include_words and isinstance(raw_words, list):
                words = [item for item in raw_words if isinstance(item, dict)]

            segments.append(
                {
                    "start": _to_float(segment.get("start")),
                    "end": _to_float(segment.get("end")),
                    "text": str(segment.get("text", "")).strip(),
                    "speaker": segment.get("speaker") if isinstance(segment.get("speaker"), str) else None,
                    "words": words,
                    "confidence": _to_float(segment.get("confidence")),
                }
            )

    return {
        "text": result.text,
        "language": result.language,
        "segments": segments,
    }


def _sanitize_filename_for_job_id(filename_stem: str, max_length: int) -> str:
    normalized_stem = filename_stem.strip().lower().translate(_CYRILLIC_TO_LATIN)
    sanitized_stem = re.sub(r"[^a-z0-9_-]+", "-", normalized_stem).strip("-_")
    if len(sanitized_stem) == 0:
        digest = hashlib.sha1(filename_stem.encode("utf-8")).hexdigest()[:12]
        sanitized_stem = f"file-{digest}"

    if len(sanitized_stem) > max_length:
        sanitized_stem = sanitized_stem[:max_length].strip("-_")

    if len(sanitized_stem) == 0:
        return "f"

    return sanitized_stem


def _validate_job_id(job_id: str) -> None:
    if len(job_id) == 0 or len(job_id) > MAX_JOB_ID_LENGTH:
        raise ValueError(f"Invalid job_id format: {job_id}")

    if ".." in job_id or JOB_ID_PATTERN.fullmatch(job_id) is None:
        raise ValueError(f"Invalid job_id format: {job_id}")


def _build_media_job_id(model_name: str, original_filename: str) -> str:
    unique_part = uuid4().hex
    prefix = f"{int(time.time() * 1000)}_{unique_part}_{model_name}"
    max_filename_length = MAX_JOB_ID_LENGTH - len(prefix) - 1
    if max_filename_length <= 0:
        raise ValueError(f"Model name cannot be used in job_id: {model_name}")

    filename_stem = Path(original_filename).stem
    sanitized_stem = _sanitize_filename_for_job_id(filename_stem, max_filename_length)
    job_id = f"{prefix}_{sanitized_stem}"
    _validate_job_id(job_id)
    return job_id


def _bootstrap_media_job(
    paths: ServicePaths,
    job_id: str,
    processing_path: Path,
    original_filename: str,
) -> Path:
    data_dir = paths.data_dir(job_id)
    data_dir.mkdir(parents=False, exist_ok=False)
    processing_path.replace(data_dir / "input")
    _write_json(
        data_dir / "input.json",
        {
            "job_id": job_id,
            "source": "input",
            "original_filename": original_filename,
        },
    )
    _write_json(data_dir / "params.json", {})
    _write_json(
        data_dir / "status.json",
        [
            {"status": "dispatching", "updated_at": _timestamp()},
            {"status": "pending", "updated_at": _timestamp()},
        ],
    )
    return data_dir


def _record_bootstrap_failure(data_dir: Path, error: Exception) -> None:
    if not data_dir.exists():
        return

    status_path = data_dir / "status.json"
    if status_path.exists():
        _append_status(data_dir, "failed", str(error))
        return

    _write_json(
        status_path,
        [
            {"status": "dispatching", "updated_at": _timestamp()},
            {"status": "failed", "updated_at": _timestamp(), "error": str(error)},
        ],
    )


def _claim_media_file(queue_dir: Path) -> tuple[Path, str] | None:
    try:
        candidates = sorted(queue_dir.iterdir(), key=lambda candidate: candidate.name)
    except FileNotFoundError:
        return None

    for candidate in candidates:
        try:
            if not candidate.is_file():
                continue
        except OSError:
            continue

        if candidate.name.lower().endswith(_MEDIA_CLAIM_IGNORED_SUFFIXES):
            continue

        processing_path = candidate.with_name(f"{candidate.name}.processing")
        try:
            candidate.rename(processing_path)
            return processing_path, candidate.name
        except FileNotFoundError:
            continue
        except PermissionError:
            continue
        except OSError:
            continue

    return None


def _claim_queue_file(queue_dir: Path) -> tuple[str, Path] | None:
    for marker in sorted(queue_dir.glob("*.json")):
        job_id = marker.stem
        lock_path = marker.with_name(f"{marker.name}.lock")
        try:
            marker.rename(lock_path)
            return job_id, lock_path
        except FileNotFoundError:
            continue
        except PermissionError:
            continue
        except OSError:
            continue
    return None


def _append_status(data_dir: Path, status: str, error: str | None = None) -> None:
    status_path = data_dir / "status.json"
    if status_path.exists():
        payload = _read_json(status_path)
        if not isinstance(payload, list):
            raise ValueError(f"status.json must be a list for {data_dir.name}")
        statuses = payload
    else:
        statuses = []

    event: dict[str, str] = {
        "status": status,
        "updated_at": _timestamp(),
    }
    if error is not None:
        event["error"] = error

    statuses.append(event)
    _write_json(status_path, statuses)


def _ensure_service_directories(paths: ServicePaths) -> None:
    paths.model_input_dir.mkdir(parents=True, exist_ok=True)
    paths.data_root.mkdir(parents=True, exist_ok=True)
    paths.output_dir.mkdir(parents=True, exist_ok=True)
    paths.pid_path.parent.mkdir(parents=True, exist_ok=True)


def _install_signal_handlers(stop_event: threading.Event) -> None:
    def _handle_signal(_signum: int, _frame: Any) -> None:
        stop_event.set()

    signal.signal(signal.SIGINT, _handle_signal)
    if hasattr(signal, "SIGTERM"):
        signal.signal(signal.SIGTERM, _handle_signal)


def _write_pid_file(pid_path: Path) -> None:
    pid_path.write_text(str(os.getpid()), encoding="utf-8")


def _remove_pid_file(pid_path: Path) -> None:
    try:
        pid_path.unlink()
    except FileNotFoundError:
        pass


def _remove_stop_request(stop_request_path: Path) -> None:
    try:
        stop_request_path.unlink()
    except FileNotFoundError:
        pass


def _safe_unlink(path: Path) -> None:
    try:
        path.unlink()
    except FileNotFoundError:
        pass


def _read_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def _write_json(path: Path, payload: Any) -> None:
    serialized = json.dumps(payload, ensure_ascii=False, indent=2)
    _write_text(path, serialized)


def _write_text(path: Path, content: str) -> None:
    temp_path = path.with_name(f"{path.name}.{os.getpid()}.{uuid4().hex}.tmp")
    last_error: OSError | None = None
    try:
        temp_path.write_text(content, encoding="utf-8")

        for _attempt in range(5):
            try:
                os.replace(temp_path, path)
                return
            except OSError as error:
                last_error = error
                time.sleep(0.2)

        if last_error is not None:
            raise last_error
    finally:
        if temp_path.exists():
            _safe_unlink(temp_path)


def _write_output_marker(path: Path, status: str) -> None:
    last_error: OSError | None = None
    for _attempt in range(3):
        try:
            _write_json(path, {"created_at": _timestamp(), "status": status})
            return
        except OSError as error:
            last_error = error
            time.sleep(0.2)

    if last_error is not None:
        raise last_error


def _to_float(value: Any) -> float | None:
    if isinstance(value, (int, float)):
        return float(value)
    return None


def _timestamp() -> str:
    return datetime.now(UTC).isoformat()