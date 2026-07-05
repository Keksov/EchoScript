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
- **Service lifecycle.** Start/stop/restart the orchestrator and each ws-daemon from the Services
  tab (inventory `services.json` → start/stop scripts), verified by a TCP port probe. The native
  `orchestrator/monitor` is left untouched and runs in parallel.
- **Daemon tuning.** Per-daemon VAD (on/off, threshold, speech-pad), decode thresholds
  (no_speech/entropy) and GPU are edited in the UI and applied to the daemon **at (re)start** —
  the launcher sets them as env from config (`DAEMON_ENV_MAP`), which the daemon reads.
- **Model provisioning.** The Models tab lists the downloadable ggml assets and their status and
  triggers `download_whisper_models.bat <lang|vad>` (idempotent).

## API (localhost)
`GET /api/health` · `GET|PUT /api/config` · `GET /api/schema` · `GET /api/daemons` ·
`POST /api/orchestrator/restart` · `POST /api/services/<name>/<start|stop|restart>` ·
`GET /api/models` · `POST /api/models/<id>/download`

## Known limitation (Windows socket inheritance)
`Bun.serve`'s listening socket is inheritable, and a daemon launched by the control-server (via the
start script's `Start-Process -RedirectStandardOutput`) inherits it — so it keeps :3001 bound after
the control-server exits. This only bites if you **restart the control-server while daemons it
launched are still running**: free :3001 first (stop those daemons, or start the control-server
before the daemons). Normal operation is unaffected.
