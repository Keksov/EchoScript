# EchoScript Control Panel (:3001)

A second Bun app — the **control plane** — that sits next to the orchestrator (data plane,
:3000) and centralizes settings + service lifecycle behind a Quasar web UI. It coordinates
with everything else through the same file-based bus the system already uses (`config.json`,
`jobs/registry/`). Mirrors the SoundTrainer `ui/`+`server/` conventions.

```
control-panel/
  ui/       Quasar 2 (Vite) + Vue 3 + vue-i18n — builds into ../server/public (hash routing)
  server/   Bun server on :3001 (localhost-only): serves the UI + /api, no auth (v1)
  spec/     plan + ledger
```

The panel is a **thin wrapper over the [`echoctl`](../echoctl/README.md) FPC CLI**, which is the
single engine for `config.json` mutations, the model lifecycle, and ws-daemon instance
CRUD/lifecycle. The server shells out to it (`echoctl … --json`, `server/echoctl.ts`) and forwards
the result.

## Run
- **Dev:** `cd control-panel/server && bun run dev` (server on :3001) and, in another shell,
  `cd control-panel/ui && bun run dev` (Quasar dev server; proxies `/api`,`/ws` → :3001).
- **Prod:** `cd control-panel/ui && bun run build` (outputs to `server/public/`), then
  `cd control-panel/server && bun run start`. Open **http://127.0.0.1:3001**.
- Tests/typecheck: `bun test` + `bun x tsc --noEmit` (server), `bun run typecheck` (ui).

## What it does
- **Settings (single writer).** `config.json` is the source of truth; the control-server is the
  only writer (atomic temp+rename, schema-validated). A schema (`settings-schema.ts`) drives the
  UI forms; every field has a bilingual (ru/en) label + description and a `hot` / `restart` badge.
- **Orchestrator hot-reload.** The orchestrator watches `config.json` (`watchConfigForReload`) and
  re-applies safe fields live (intervals, registry TTL, drop-stable, requeue cap, ws_daemons
  routing); restart-class fields (`jobs_root`, `max_workers`) show a **Restart orchestrator** button.
- **Instance CRUD.** The Services tab can **add / edit / remove** ws-daemon instances (engine, model,
  port with per-engine auto-allocation, name, per-instance settings) via `echoctl daemons …`.
- **Service lifecycle.** Start/stop/restart from the Services tab: ws-daemons go through
  `echoctl daemons <action>` (detached, warmup-aware, socket-safe launch); the orchestrator and the
  streaming vosk daemons (inventory `services.json`, not `ws_daemons`) keep their start/stop scripts.
  The native `orchestrator/monitor` is left untouched and runs in parallel.
- **Daemon tuning.** Per-daemon VAD (on/off, threshold, speech-pad), decode thresholds
  (no_speech/entropy) and GPU are edited in the UI and applied to the daemon **at (re)start** — the
  launcher passes them as env, which the daemon reads (and echoes at warmup).
- **Model lifecycle.** The Models tab lists assets + status, downloads (`echoctl models download`,
  idempotent), and **deletes** (`echoctl models delete` — a `--dry-run` preview shows the files and
  any referencing instances, then `--force` cascades).

## API (localhost)
`GET /api/health` · `GET|PUT /api/config` · `GET /api/schema` · `GET /api/daemons` ·
`POST /api/daemons` (add) · `PATCH|DELETE /api/daemons/<name>` (edit/remove) ·
`POST /api/orchestrator/restart` · `POST /api/services/<name>/<start|stop|restart>` ·
`GET /api/models` · `POST /api/models/<id>/download` · `DELETE /api/models/<id>?force&dryRun` ·
`POST /api/pick-path`

## Known limitation (Windows socket inheritance)
ws-daemons launched via `echoctl` no longer inherit the control-server's `:3001` socket — echoctl
spawns them with `CreateProcess(bInheritHandles=FALSE)`. The **script-launched** services
(orchestrator, streaming vosk daemons) still inherit it, so restarting the control-server while
those are running requires freeing :3001 first (stop them, or start the control-server before them).
Normal operation is unaffected.
