# echoctl

`echoctl` is the FPC CLI that owns EchoScript's **daemon fleet** and **model** management.
It is the single writer of `config.json` (atomic temp + `MoveFileEx` replace) and the single
engine behind the control panel: the Bun control-server shells out to it (`echoctl … --json`)
and forwards the result, so the UI is a wrapper, not a second writer.

## Build

```bat
echoctl\scripts\build_x64.bat      REM → echoctl\build\x64\echoctl.exe
echoctl\scripts\smoke_x64.bat      REM dispatcher + daemons list
echoctl\scripts\smoke_crud_x64.bat REM daemons add/edit/remove + port alloc (throwaway config)
echoctl\scripts\smoke_models_x64.bat
echoctl\scripts\smoke_delete_x64.bat     REM model delete on a fake model (safe)
echoctl\scripts\smoke_lifecycle_x64.bat  REM real start/stop (guarded by vosk prereqs)
echoctl\scripts\test_x64.bat       REM config round-trip
```

Built with the vendored FPC in `EchoRecorder/VendorsCore` (same toolchain as the daemons).

## Commands

```
daemons  list | add | remove | edit | start | stop | restart
models   list | download | delete
config   get | set | schema
```

```
daemons add --engine <whisper|vosk> --model <model> [--port N] [--host H] [--lang L] [--name NM] [--set k=v ...]
daemons edit <name> [--model M] [--port N] [--set k=v ...]
daemons start|stop|restart <name> [--timeout <sec>]
models delete <id> [--dry-run] [--force]
config set <key> <value>
```

- **`--json`** — machine-readable output (what the control-server consumes).
- **`--config <path>`** / **`--manifest <path>`** — override the config.json / models-manifest.json
  (default: found next to the exe). Used by the smokes to work on throwaway copies.

### Exit codes
`0` ok · `1` runtime error · `2` usage/validation · `3` not-implemented.

## What it manages

- **Instances** live in `config.json` `ws_daemons` (name → host/port/engine/language/model_name +
  optional `settings`). `add`/`remove`/`edit` mutate this atomically; ports auto-allocate per engine
  (whisper 78xx, vosk 77xx) when `--port` is omitted; per-instance `settings` are validated against a
  per-engine schema (whisper VAD/decode/GPU; vosk none in v1).
- **Lifecycle** — `start` spawns the daemon detached via `cmd /c ""exe" args > log 2>&1"` with
  `CreateProcess(bInheritHandles=FALSE)` (the daemon inherits none of echoctl's handles, so the
  control-panel's `:3001` socket no longer leaks into daemons), waits for a real `warmup ready` in the
  log, and verifies the port. `stop` kills the listener by port.
- **Models** — `models-manifest.json` is the catalog (whisper podlodka/en/vad/diarization downloadable;
  vosk external `C:\var\vosk` read-only). `delete` refuses when an instance references the model and
  cascades only with `--force`, always previewable with `--dry-run`.
- **Orchestrator settings** — `config get/set/schema` over the top-level scalars, each reporting a
  `hot` or `restart` reload class.

## Scope boundary

echoctl manages ws-daemon instances (whisper), the model catalog, and orchestrator settings.
The orchestrator process itself and the streaming vosk daemons in the control-panel's
`services.json` inventory (which serve EchoRecorder directly and are not `ws_daemons`) keep their
script-based lifecycle in the control-panel.
