# Централизованный UI настроек + управление демонами (control-panel)

Status: **active**
Created: 2026-07-05
Branch: `feature/control-panel` (от `feature/language-routing` — актуальный `config.json` + VAD-демон)
Authoritative progress ledger: [control-panel-progress.json](control-panel-progress.json)

## Goal
Отдельное **Bun-приложение (control plane)** на **:3001** с **Quasar-UI**, «подселённое» к оркестратору
(data plane :3000). Централизованно управляет **всеми** настройками (оркестратор + демоны), делает
**старт/стоп/рестарт демонов** (поглощает нативный Monitor), показывает статус, провижинит модели.
Пояснения к настройкам — **i18n ru/en**. `config.json` — единый источник истины; control-server —
**единственный писатель**; оркестратор — **hot-reload** (watch) + кнопка **restart** из UI.

## Конвенции (зеркалим `c:\projects\Games\SoundTrainer`)
- **Quasar 2 (Vite) + Vue 3 + vue-i18n 11 + Bun** (`@quasar/app-vite ~2.1`).
- `ui/` **собирается в `server/public/`** (`quasar.config.build.distDir`), роутинг **hash**.
- Один `Bun.serve` отдаёт `public/` (SPA-fallback на `index.html`) + `/api/*` + `/ws` (upgrade);
  path-traversal guard; 503 если бандл не собран.
- **dev:** `quasar dev` + `devServer.proxy` `/api`,`/ws` → сервер (порт из env).
- **i18n boot** (`boot:["i18n"]`): `createI18n({legacy:false})`, `ru` по умолчанию, `en` fallback,
  локаль в `localStorage`; `src/i18n/{index.ts, locales/{ru,en}.json}`.
- `src/services/api.ts` — относительный `fetch("/api/...")`; **tabbed `SettingsPage`** (q-tabs/q-tab-panels)
  как паттерн для секций настроек; `layouts/MainLayout.vue`, `router/`, `types/`.
- Скрипты: `quasar dev` / `quasar build` / `vue-tsc --noEmit` (typecheck) / `bun test`.

## Decisions (locked — владелец)
- **CP-D1 — Отдельное Bun-приложение :3001** (control plane), рядом с оркестратором (data plane :3000).
- **CP-D2 — `config.json` = единый источник истины;** control-server — **ЕДИНСТВЕННЫЙ писатель**
  (atomic temp+rename, валидация по схеме). Оркестратор и демоны — только читают.
- **CP-D3 — Оркестратор hot-reload:** `fs.watch(config.json)` перечитывает **безопасные** поля
  (интервалы, TTL, drop_stable, requeue-cap, ws_daemons-роутинг); что нельзя на лету — помечается
  «нужен рестарт», UI даёт кнопку **restart оркестратора** (он в инвентаре как демон).
- **CP-D4 — UI поглощает Monitor:** старт/стоп/рестарт демонов (портируем логику `monitor_control`:
  запуск по скриптам/инвентарю) + статус (`monitor_status`: реестр `jobs/registry/` + port/health-проба).
  Нативный `orchestrator/monitor` **ретайрится** после паритета.
- **CP-D5 — Выносим ВСЕ доступные настройки** (оркестратор + демоны, включая VAD-пороги/GPU/DLL/decode).
  Тонкие демон-настройки, что сейчас в хардкоде Pascal / .env.bat, — через **CLI-флаги демона**,
  генерируемые лаунчером из `config.json` (+ небольшие Pascal-правки на новые флаги).
- **CP-D6 — i18n ru/en:** у каждой настройки — `label` + `description` в **обоих** локалях.
- **CP-D7 — Стек Quasar по конвенциям SoundTrainer** (см. выше); `ui/`→`server/public/`; один порт в
  prod, proxy в dev.
- **CP-D8 — Провижининг моделей из UI:** запуск `download_whisper_models.bat <lang|vad>` + прогресс/лог.

## Настройки для выноса (инвентарь охвата CP-D5)
- **Оркестратор** (`config.json`): max_workers, poll_interval_ms, stream_window_ms, stream_chunk_ms,
  daemon_registry_ttl_ms, drop_stable_ms, max_requeue_attempts, default_model, ffmpeg_path, jobs_root.
- **ws_daemons[]**: host, port, engine, language, model_name (+ добавляемые ниже демон-настройки).
- **Демон (сейчас env/CLI):** GPU on/off, gpu_device, whisper_dll/release_tag, **WHISPER_VAD on/off**,
  registry_dir, host/port.
- **Демон (сейчас хардкод Pascal → в CLI/config):** VAD `threshold/min_speech_ms/min_silence_ms/
  max_speech_s/speech_pad_ms/samples_overlap`; sampling `beam|greedy` (+ beam_size/best_of);
  decode-пороги `entropy_thold/logprob_thold/no_speech_thold/temperature(+inc)`, `suppress_nst`.
- **Per-job дефолты** (опц.): language, word_timestamps, punctuation, speaker_embeddings.
- **Модели/провижининг**: список языков→моделей (манифест), какие скачаны.

## Acceptance / gates
- **P1:** `control-panel` поднимается (`quasar dev` proxy + `quasar build`→`server/public`, Bun :3001
  отдаёт UI), показывает read-only обзор `config.json` и статус демонов.
- **P2:** правка настроек оркестратора/ws_daemons в UI → atomic-запись `config.json` (single writer) →
  оркестратор hot-reload безопасных полей; для restart-required — кнопка restart работает.
- **P3:** старт/стоп/рестарт любого демона из UI + live-статус (реестр+порт) — паритет с Monitor.
- **P4:** VAD-пороги/decode/GPU правятся из UI → доезжают до демона (CLI-флаги из config) → эффект
  подтверждён (напр. VAD threshold меняет % reduction).
- **P5:** модель качается из UI; каждая настройка двуязычна (ru/en label+описание); `bun test`
  (control-server) + `vue-tsc` зелёные; docs.

## Risks
- **Hot-reload безопасность:** не все поля оркестратора применимы на лету (напр. смена jobs_root/порта) →
  явный список hot vs restart-required; неоднозначное — только через restart.
- **Демон-настройки в хардкоде:** VAD/decode-пороги требуют новых CLI-флагов + пересборка демона (P4).
- **Паритет с Monitor:** не потерять функциональность старта/статуса при портировании (port-probe,
  ws-health, listeningPidOnPort, инвентарь `daemons.json`).
- **Безопасность control-plane:** правит конфиг и рулит процессами → **bind localhost-only** по умолчанию;
  вопрос авторизации — решить на гейте (v1 возможно без auth, localhost).
- **Кроссплатформенность:** запуск демонов — `.bat` (Windows); control-server шелл-аут (как Monitor);
  POSIX — вне scope v1.
- **Два источника роутинга:** ws_daemons ↔ inventory `daemons.json` — свести к одному (ws_daemons в
  config как основной; инвентарь non-ws демонов отдельно).

## Steps (mirror the ledger)
- [ ] **CP0.1 — Plan & ledger.**
- [ ] **CP1.1 — Скелет control-panel.** `control-panel/ui` (Quasar по конвенциям SoundTrainer) +
  `control-panel/server` (Bun :3001, отдаёт `public/` + `/api/health`,`/api/config`(GET) +
  `/api/daemons`(GET статус)); read-only обзор config + статус демонов; i18n-каркас (ru/en). Gate.
- [ ] **CP2.1 — Настройки + hot-reload.** Схема config + `GET/PUT /api/config` (single writer, atomic,
  валидация) + оркестратор `fs.watch(config.json)` (hot безопасные поля, флаг restart-required) +
  restart-кнопка; формы оркестратор/ws_daemons + i18n. Gate.
- [ ] **CP3.1 — Управление демонами (поглощение Monitor).** start/stop/restart (портируем
  `monitor_control`) + live-статус (`monitor_status`: реестр+port/ws-health) в UI; инвентарь. Gate.
- [ ] **CP4.1 — Демон-настройки.** CLI-флаги в `WhisperDaemon.pas` (VAD-пороги/decode/GPU) + лаунчер
  генерит args из config + формы UI (+ i18n) + пересборка. Gate.
- [ ] **CP5.1 — Провижининг + i18n + docs.** Скачивание моделей из UI (прогресс); полнота ru/en;
  `bun test`+`vue-tsc` зелёные; ARCHITECTURE.md.

## References
- Конвенции Quasar/Bun: `c:\projects\Games\SoundTrainer\{ui,server}`.
- Существующий Monitor (портируем): `orchestrator/monitor/core/{monitor_control,monitor_status}.pas`,
  `orchestrator/monitor/daemons.json`.
- Конфиг/демоны: `config.json`, `orchestrator/src/config.ts`, `services/whisperdaemon/app/src/WhisperDaemon.pas`,
  start/stop-скрипты `services/whisperdaemon/scripts/`, `orchestrator/scripts/`.
- Языковой роутинг/VAD (то, чем будем рулить): [../../services/whisperdaemon/spec/whisper-repetition-diagnosis.md](../../services/whisperdaemon/spec/whisper-repetition-diagnosis.md),
  [../../orchestrator/spec/language-routing-plan.md](../../orchestrator/spec/language-routing-plan.md).
