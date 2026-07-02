# Восстановление file-drop + файловая саморегистрация демонов

Status: **complete**
Created: 2026-07-02
Authoritative progress ledger: [jobs-drop-daemon-registry-progress.json](jobs-drop-daemon-registry-progress.json)

## Goal
Вернуть поведение «бросил медиафайл в `jobs/input/<model>/` — он распознался» (было в старом
Python-watcher, не портировано в оркестратор). И закрыть timing-проблему: если файл появился, а
нужный ws-daemon ещё не запущен, задание должно **ждать**, а не падать в `failed`. Механизм
готовности — **файловая саморегистрация**: демон кладёт в `jobs/registry/<name>.json` дескриптор
(готовность + host/port + форматы) и обновляет heartbeat; оркестратор watch'ит папку и диспетчит
ws-daemon-задания только на свежезарегистрированные готовые демоны.

## Audit / Where things stand (проверено по коду)
- **Drop не работает.** `Scheduler.restoreDispatchedJob` сканирует `input/<model>/`, но
  `stripMarkerSuffix` берёт только `*.json`/`*.json.lock` ([scheduler.ts:255-262](../src/scheduler.ts),
  [:37-44](../src/scheduler.ts)) → сырой `.flac` игнорируется. Наблюдателя на `input/` нет (только
  `outputWatcher` на `jobs/output/`, [:72](../src/scheduler.ts)). Задание создаётся лишь через HTTP
  API (`/add_file` → `data/<id>/` + `queue/<id>.json`).
- **Эталон drop — старый Python.** `shared/echoscript_shared/service_runner.py`:
  `_claim_media_file` (claim non-json через rename → `.processing`), `_build_media_job_id`
  (транслит кириллицы, `ts_uuid_model_stem`), `_bootstrap_media_job` (`data/<id>/input`,
  `input.json{created_from:file_drop}`, `params.json`, `status.json`).
- **Timing-провал.** `dispatchNext` ([:160](../src/scheduler.ts)) для ws-daemon-модели зовёт
  `dispatchWsDaemonJob` **без проверки готовности**. Демон down → `transcribeFileStreaming` ловит
  WS connection refused → `runWsDaemonJob` пишет `failed` + output-маркер (терминально). reconcile
  ([:81](../src/scheduler.ts), каждые ~500 мс) не перезапускает — маркер уже есть.
- **Асимметрия python vs ws-daemon.** python-воркеры оркестратор стартует сам
  (`switchToModel → ensureModelRunning`, [:180](../src/scheduler.ts)); ws-daemon'ы — внешние
  always-on, оркестратор их не запускает → «демона нет» бывает только у них.
- **Есть чем валидировать готовность.** У демона уже есть `describe`/`health` и `daemon.json`;
  регистрационный файл — их file-based push-версия.

## Decisions (locked)
- **DR-D1 — Оркестратор снова подбирает сырые файлы** из `input/<model>/` (порт `_claim_media_file`):
  `fs.watch` + startup-scan + reconcile-sweep (watch ненадёжен → скан/свип страхуют). Startup-scan
  также **восстанавливает осиротевшие `.processing`** (краш между claim и созданием задания).
- **DR-D2 — Claim атомарным rename → `.processing`, затем файл ПЕРЕМЕЩАЕТСЯ в `data/<id>/input`**
  (не reference: иначе watcher повторно подхватит файл в `input/`). Задание создаётся через
  **существующий `JobManager` + `enqueueJob`** (единый контракт статусов/маркера), с
  `input.json{source:"input", original_filename, created_from:file_drop}`; дальше обычный `Scheduler`.
  См. DR-D13.
- **DR-D3 — Debounce незавершённой записи:** файл берём, только когда его размер стабилен ≥
  `drop_stable_ms` (config.json), иначе большой файл (напр. 118 МБ) можно схватить недокопированным.
  Стабильность проверяется **до** claim.
- **DR-D4 — job_id из имени файла** (транслит кириллицы, `ts_uuid_model_stem`), как
  `_build_media_job_id`.
- **DR-D5 — Файловая саморегистрация демонов в `jobs/registry/<name>.json`.** Демон на `ready`
  **атомарно** (temp+rename) пишет `{name, host, port, model_name, state, pid,
  input:{codec,sample_rate_hz,channels}, updated_at}`, периодически обновляет `updated_at`
  (heartbeat — настройка демона), удаляет на остановке. `jobs/registry/` **создаёт оркестратор** на
  старте.
- **DR-D6 — Liveness через свежесть (TTL) + readiness-gate + requeue.** Запись валидна, если
  `updated_at` не старше `daemon_registry_ttl_ms` (config.json); инвариант **TTL ≥ ~3× heartbeat**.
  `dispatchNext` диспетчит ws-daemon-задание **только** при свежей `ready`-записи, используя её
  host/port (см. DR-D10 — без HOL-блокировки). Транспортный сбой → requeue, не terminal `failed`
  (см. DR-D11/DR-D12). *(ответ на timing-вопрос владельца)*
- **DR-D7 — Реестр дополняет config, не заменяет:** config = маршрутизация (model→daemon по
  `model_name`), реестр = живые host/port/готовность/форматы (announced port — авторитетный). Join:
  `targetModel` → config ws_daemon (по `model_name`) → registry (по `name`) → свежесть/порт.
- **DR-D8 — В демоны инкрементально:** сперва whisperdaemon (FPC); vibevoice/diarization — позже.
  Ядро реестра на оркестраторе тестируется независимо (синтетические registration-файлы, DI).
- **DR-D9 — Чистое ядро + тонкая обёртка + DI (fs/clock)** для детерминированных тестов.
- **DR-D10 — Peek-dispatchable (без head-of-line блокировки).** `peekQueue` берёт только голову;
  readiness-gate должен **пропускать** ws-daemon-задания без свежей `ready`-записи и брать следующее
  выполнимое (python-задания не гейтятся — оркестратор их стартует сам).
- **DR-D11 — Классы ошибок transport vs terminal.** Драйвер различает недоступность демона
  (connect/close/stall → `DaemonUnreachableError`) и реальную ошибку (daemon `error` / сбой
  ffmpeg → терминально). `runWsDaemonJob` делает **requeue только для transport**, остальное → `failed`.
- **DR-D12 — Инвалидация регистрации на транспортном сбое + backoff.** При недоступности демон
  считается не-готовым (его registry-запись «подозрительна» до следующего свежего heartbeat) +
  короткий per-job backoff, чтобы не устроить шторм повторов внутри TTL-окна.
- **DR-D13 — Drop переиспользует `JobManager`/`enqueue`, а не дублирует bootstrap.** Файл
  перемещается в `data/<id>/input`, задание создаётся и ставится в очередь существующими методами —
  один источник правды для контракта `jobs/`.

## Acceptance / gates
- `bun test` (orchestrator) зелёный: реестр (свежесть/TTL/валидация), readiness-gate/requeue,
  drop-ядро (claim/job_id/bootstrap).
- whisperdaemon собирается; пишет/обновляет/удаляет `jobs/registry/whisperdaemon.json`.
- **E2E (сценарий владельца):** бросить файл в `input/whisper_podlodka/` при **выключенном**
  whisperdaemon → задание `waiting` (не `failed`); затем старт демона (пишет `ready`) → оркестратор
  видит регистрацию → файл распознаётся. Плюс бросок при живом демоне.

## Risks
- **Stale-регистрация** (демон упал, файл остался) → TTL + heartbeat (DR-D6); инвалидация записи на
  транспортном сбое (DR-D12).
- **HOL-блокировка очереди** (голова ждёт неготовый демон) → peek-dispatchable (DR-D10).
- **Шторм повторов внутри TTL-окна** → инвалидация registry-записи + per-job backoff (DR-D12).
- **Дубли/зацикливание drop** (файл остался в `input/`) → move в `data/` (DR-D2/DR-D13).
- **Ненадёжный `fs.watch`** → startup-scan + периодический reconcile-sweep (DR-D1).
- **Частичная запись файла** (копирование большого файла) → stability-debounce (DR-D3).
- **Гонки claim** (двойной подбор) → атомарный rename (DR-D2).
- **Демон пишет в `jobs/`** (реестр) — узкое исключение из «демон не трогает jobs/» (только
  регистрация, не артефакты заданий).
- **Гетерогенные демоны** (FPC/python/sherpa) → инкрементальный роллаут (DR-D8).

## Steps (mirror the ledger)
- [x] **DR0.1 — Plan & ledger.**
- [x] **DR1.1 — Реестр (чистое ядро) + юниты.** Парсер/валидатор `registry/<name>.json`, TTL-свежесть,
  live-map; DI clock.
- [x] **DR1.2 — Watcher реестра + startup-scan, подключить к старту оркестратора.** Оркестратор
  создаёт `jobs/registry/` на старте.
- [x] **DR1.3 — Readiness-gate (peek-dispatchable) в `dispatchNext`.** Пропуск ws-daemon-заданий без
  свежей `ready`-записи (DR-D10), диспетч на announced host/port; тесты.
- [x] **DR1.4 — Requeue-on-transport + классы ошибок + инвалидация/backoff.** Драйвер: класс
  `DaemonUnreachableError` (DR-D11); раннер: requeue только transport; инвалидация registry-записи и
  backoff (DR-D12); тесты.
- [x] **DR2.1 — whisperdaemon пишет регистрацию** (атомарно, на ready + heartbeat + remove на shutdown).
- [x] **DR3.1 — Drop-ядро + юниты.** `claimMediaFile` (stability → atomic rename `.processing`),
  `buildMediaJobId` (транслит), **move в `data/<id>/input` + переиспользование `JobManager`/`enqueue`**
  (DR-D13).
- [x] **DR4.1 — Интеграция drop:** watcher `input/<model>/` + startup-scan (+ recovery `.processing`)
  + reconcile-sweep → Scheduler.
- [x] **DR5.1 — E2E** (сценарий владельца: drop-до-демона → waiting → старт → распознано; + live).
- [x] **DR5.2 — Docs** (ARCHITECTURE.md: drop + реестр/registration-контракт).

## References
- Стрим-мост (завершён): [file-streaming-bridge-plan.md](file-streaming-bridge-plan.md)
- Эталон drop: `shared/echoscript_shared/service_runner.py`
- Методология: [../../EchoRecorder/METHODOLOGY.md](../../EchoRecorder/METHODOLOGY.md);
  Правила Pascal: [../../EchoRecorder/PASCAL_RULES.md](../../EchoRecorder/PASCAL_RULES.md)
