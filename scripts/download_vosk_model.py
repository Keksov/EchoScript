from __future__ import annotations

import argparse
import http.client
import json
import shutil
import socket
import time
import urllib.error
import urllib.request
import zipfile
from collections.abc import Callable
from pathlib import Path
from typing import Any, TypeVar
from urllib.parse import quote

_MAX_DOWNLOAD_ATTEMPTS = 4
_RETRY_DELAY_SECONDS = 2
_REQUEST_TIMEOUT_SECONDS = 120

_ResultT = TypeVar("_ResultT")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--url")
    parser.add_argument("--hf-repo")
    parser.add_argument("--hf-path")
    parser.add_argument("--target-root", required=True)
    parser.add_argument("--expected-dir", required=True)
    args = parser.parse_args()

    archive_mode = isinstance(args.url, str) and len(args.url) > 0
    hf_mode = isinstance(args.hf_repo, str) and len(args.hf_repo) > 0 and isinstance(args.hf_path, str) and len(args.hf_path) > 0
    if archive_mode == hf_mode:
        parser.error("Specify either --url or --hf-repo together with --hf-path")

    return args


def with_retries(action: Callable[[], _ResultT], description: str) -> _ResultT:
    last_error: Exception | None = None
    for attempt in range(1, _MAX_DOWNLOAD_ATTEMPTS + 1):
        try:
            return action()
        except (http.client.RemoteDisconnected, urllib.error.URLError, ConnectionError, TimeoutError, socket.timeout) as error:
            last_error = error
            if attempt >= _MAX_DOWNLOAD_ATTEMPTS:
                raise

            print(
                f"[WARN] {description} failed on attempt {attempt}/{_MAX_DOWNLOAD_ATTEMPTS}: {error}. Retrying..."
            )
            time.sleep(_RETRY_DELAY_SECONDS * attempt)

    if last_error is not None:
        raise last_error

    raise RuntimeError(f"Retry loop exited unexpectedly for {description}")


def download_archive(url: str, archive_path: Path) -> None:
    def action() -> None:
        with urllib.request.urlopen(url, timeout=_REQUEST_TIMEOUT_SECONDS) as response, archive_path.open("wb") as output_file:
            shutil.copyfileobj(response, output_file)

    with_retries(action, f"archive download {url}")


def download_file(url: str, output_path: Path) -> None:
    output_path.parent.mkdir(parents=True, exist_ok=True)

    def action() -> None:
        with urllib.request.urlopen(url, timeout=_REQUEST_TIMEOUT_SECONDS) as response, output_path.open("wb") as output_file:
            shutil.copyfileobj(response, output_file)

    with_retries(action, f"file download {url}")


def load_json(url: str) -> Any:
    def action() -> Any:
        with urllib.request.urlopen(url, timeout=_REQUEST_TIMEOUT_SECONDS) as response:
            return json.load(response)

    return with_retries(action, f"JSON request {url}")


def extract_archive_safely(archive_path: Path, target_dir: Path) -> None:
    target_root = target_dir.resolve()
    with zipfile.ZipFile(archive_path) as archive:
        for member in archive.infolist():
            resolved_member_path = (target_root / member.filename).resolve()
            try:
                resolved_member_path.relative_to(target_root)
            except ValueError as error:
                raise RuntimeError(f"Archive contains unsafe path: {member.filename}") from error

        archive.extractall(target_dir)


def build_hf_tree_url(repo_id: str, repo_path: str) -> str:
    return f"https://huggingface.co/api/models/{repo_id}/tree/main/{quote(repo_path, safe='/')}?recursive=1"


def build_hf_resolve_url(repo_id: str, repo_path: str) -> str:
    return f"https://huggingface.co/{repo_id}/resolve/main/{quote(repo_path, safe='/')}?download=true"


def download_hf_directory(repo_id: str, repo_path: str, target_dir: Path) -> None:
    entries = load_json(build_hf_tree_url(repo_id, repo_path))
    if not isinstance(entries, list) or len(entries) == 0:
        raise RuntimeError(f"No files listed for Hugging Face path: {repo_id}/{repo_path}")

    repo_root_path = Path(repo_path)
    downloaded_files = 0
    for entry in entries:
        if not isinstance(entry, dict) or entry.get("type") != "file":
            continue

        raw_path = entry.get("path")
        if not isinstance(raw_path, str) or len(raw_path) == 0:
            continue

        relative_path = Path(raw_path).relative_to(repo_root_path)
        target_path = target_dir / relative_path
        print(f"[INFO] Downloading {raw_path}")
        download_file(build_hf_resolve_url(repo_id, raw_path), target_path)
        downloaded_files += 1

    if downloaded_files == 0:
        raise RuntimeError(f"No files downloaded for Hugging Face path: {repo_id}/{repo_path}")


def find_git_lfs_pointer_file(root_dir: Path) -> Path | None:
    if not root_dir.exists() or not root_dir.is_dir():
        return None

    for path in root_dir.rglob("*"):
        if not path.is_file():
            continue

        try:
            if path.stat().st_size > 1024:
                continue

            if path.read_bytes().startswith(b"version https://git-lfs.github.com/spec/v1"):
                return path
        except OSError:
            continue

    return None


def main() -> int:
    args = parse_args()
    target_root = Path(args.target_root)
    target_root.mkdir(parents=True, exist_ok=True)

    expected_dir = target_root / args.expected_dir
    if expected_dir.exists():
        pointer_file = find_git_lfs_pointer_file(expected_dir)
        if pointer_file is None:
            print(f"[INFO] Model already present: {expected_dir}")
            return 0

        print(f"[WARN] Existing model contains unresolved Git LFS pointer: {pointer_file}")
        shutil.rmtree(expected_dir)

    temp_extract_root = target_root / f"{args.expected_dir}.extracting"
    archive_path = (
        target_root / Path(args.url).name
        if isinstance(args.url, str) and len(args.url) > 0
        else target_root / f"{args.expected_dir}.download.tmp"
    )

    if temp_extract_root.exists():
        shutil.rmtree(temp_extract_root)

    if archive_path.exists():
        archive_path.unlink()

    print(f"[INFO] Target root: {target_root}")
    temp_extract_root.mkdir(parents=True, exist_ok=True)
    try:
        if isinstance(args.url, str) and len(args.url) > 0:
            print(f"[INFO] Downloading archive {args.url}")
            download_archive(args.url, archive_path)

            print(f"[INFO] Extracting {archive_path.name}")
            extract_archive_safely(archive_path, temp_extract_root)

            extracted_dir = temp_extract_root / args.expected_dir
        else:
            print(f"[INFO] Downloading Hugging Face directory {args.hf_repo}/{args.hf_path}")
            extracted_dir = temp_extract_root / args.expected_dir
            download_hf_directory(str(args.hf_repo), str(args.hf_path), extracted_dir)

        if not extracted_dir.exists():
            raise FileNotFoundError(f"Extracted model directory is missing: {extracted_dir}")

        pointer_file = find_git_lfs_pointer_file(extracted_dir)
        if pointer_file is not None:
            raise RuntimeError(f"Downloaded model contains unresolved Git LFS pointer: {pointer_file}")

        extracted_dir.replace(expected_dir)
    finally:
        shutil.rmtree(temp_extract_root, ignore_errors=True)
        archive_path.unlink(missing_ok=True)

    print(f"[OK] Model available at {expected_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
