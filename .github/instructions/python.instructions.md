---
applyTo: "**/*.py"
description: "Python best practices for EchoScript services, including FastAPI structure, adapters, async patterns, and dependency rules."
---

# Python Best Practices (EchoScript Services)

## General

- Target Python 3.11+
- Use type hints for all function signatures and class attributes
- Use `from __future__ import annotations` only if needed for forward refs
- Prefer `pathlib.Path` over `os.path` for file operations
- Use f-strings for string formatting

## Project Structure

- Each service is an independent FastAPI app in `services/<name>/app/`
- Shared code lives in `shared/echoscript_shared/` — installed via `pip install -e`
- Model adapters inherit from `BaseASRAdapter` in the shared package
- Do not import across services — they communicate only via HTTP

## Type Hints & Data

- Use `str | None` syntax, not `Optional[str]`
- Use `dataclasses.dataclass` for simple data containers
- Use Pydantic `BaseModel` for API request/response schemas
- Prefer `typing.TypeAlias` for complex type aliases

## FastAPI

- Use async endpoints (`async def`) for I/O-bound handlers
- Use synchronous functions for CPU-bound model inference (run in thread pool)
- Define request/response models as Pydantic classes, not inline dicts
- Raise `HTTPException` with appropriate status codes at handler level

## Error Handling

- Use try/except only at boundaries (endpoint handlers, model loading)
- Never catch bare `Exception` — catch specific exceptions
- Log errors with `logging` module, not `print()`
- Let unexpected exceptions propagate to FastAPI's default handler

## Async Patterns

- Use `async/await` for HTTP calls, file I/O
- Use `asyncio.to_thread()` to offload blocking model inference
- Never use `time.sleep()` in async context — use `asyncio.sleep()`

## Model Adapters

- Each adapter implements `BaseASRAdapter` (load_model, transcribe, is_loaded)
- Model loading is lazy — triggered on first request or explicit call
- Keep adapter stateless beyond the loaded model reference
- Use `HF_HOME` environment variable for model cache path

## Dependencies

- torch is NOT in requirements.txt — installed by setup scripts based on GPU detection
- Keep requirements.txt minimal — only direct dependencies
- Pin major versions only when breaking changes are known
