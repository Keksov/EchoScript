# Файловый интерфейс распознавания: file-daemon (оркестратор) + тонкий file-API демонов

Status: **active** (пересмотрен 2026-07-01; заменяет прежний подход «очередь внутри демона»)
Created: 2026-07-01
Authoritative progress ledger: [whisperdaemon-jobs-progress.json](whisperdaemon-jobs-progress.json)

## Goal
Дать распознаванию файловый вход через `jobs/`, **не** дублируя очередь в каждом демоне. Роль
«файлового демона» (watch + convert + lifecycle + status) берёт на себя существующий оркестратор
(TS/Bun). Демоны распознавания (FPC: whisperdaemon и далее) остаются тонкими и получают файловый API
поверх своего WebSocket: `describe` / `health` / `transcribe_file`. Формат аудио стороны согласуют
через settings-файл демона + запрос `describe`. Артефакты и жизненный цикл `jobs/` остаются
целиком за оркестратором.

## Audit / Where things stand (проверено по коду)
- **Оркестратор = уже почти file-daemon.** `orchestrator/src/index.ts` (Hono, :3000):
  `/add_file`, `/add_body`, `/run_job`, `/get_job_status`, `/get_job_result`, `/list_jobs`,
  `/delete_job`, `/api/v2/speech/recognize`.
  - `JobManager` (`job-manager.ts`) — владелец `jobs/`: `addFileJob`/`addBodyJob` (создаёт `data/<id>/`,
    `input.json`, `params.json`), `getJobStatus` (:358, читает `status.json`), `getJobResult` (:365,
    `result.json`/`result_plain.txt`/`result_timestamp.txt`).
  - `Scheduler` (`scheduler.ts`) — `watch(jobs/output)` + reconcile; диспетч маркерами.
  - `ProcessManager` (`process-manager.ts`) — спавнит python-воркеры (`python -m app.main --jobs-root …`),
    следит по `.pid`/`.stop`.
  - **Конвертации аудио НЕТ** (ffmpeg в оркестраторе отсутствует; сейчас декодят сами воркеры).
- **Артефакты результата сейчас пишет python-воркер** (`service_runner._write_job_result_artifacts`):
  `result.json` (`{raw, normalized:{text,language,segments[]}}`, тайминги в **секундах**),
  `result_plain.txt`, `result_timestamp.txt` (`[hh:mm:ss.mmm --> …]  text`), переходы `status.json`
  (`dispatching→pending→processing→ready|failed`), маркер `jobs/output/<id>.json`.
- **WhisperDaemon (FPC)** — WS-сервер + прогретый `gCachedContext`; ядро инференса —
  `TWhisperDaemonSession.inferBufferedAudio` (принимает pcm16le 16k mono); главный цикл
  `while True do Sleep(250)`. Декодера файлов нет (и не нужен по новой схеме).
- **ffmpeg** есть на машине (`c:\bin\ffmpeg-7.1…\bin\ffmpeg.exe`); в оркестраторе уже есть `scripts/ffmpeg.bat`.

## Decisions (locked)
- **D1 — File-daemon = расширенный оркестратор (TS).** Он остаётся единственным владельцем watch,
  конвертации, жизненного цикла, `status.json`, артефактов и HTTP-статусов. *(ответ владельца)*
- **D2 — Демоны распознавания — тонкие:** получают WS file-API (`describe`/`health`/`transcribe_file`),
  НЕ читают `jobs/`, НЕ пишут артефакты, НЕ декодируют аудио.
- **D3 — Согласованный формат: raw pcm16le 16kHz mono.** Конвертацию делает оркестратор через ffmpeg;
  демон только читает байты (`bytesToPcmFloat`) и распознаёт. *(ответ владельца)*
- **D4 — Транспорт: существующий WebSocket демона** (`fpwebsocketserver`) + новые события. *(ответ владельца)*
- **D5 — Согласование формата/возможностей:** settings-файл `services/<daemon>/daemon.json`
  (accepted input, transport, capabilities); демон отдаёт тот же дескриптор по `{event:'describe'}`.
- **D6 — Контракт `jobs/` — в одном месте (оркестратор).** Он пишет `result.json`/`result_plain.txt`/
  `result_timestamp.txt`/переходы `status.json`/output-маркер для ws-daemon пути.
- **D7 — Python-воркеры (service_runner) не трогаем.** Новый file-API — только для FPC-демонов; модель в
  `config.json` помечается как `python-worker` (как сейчас) либо `ws-daemon` (новый путь). *(ответ владельца)*
- **D8 — Конкурентность:** файловый и WS-инференс в демоне сериализуются существующим `gInferenceLock`.
- **D9 — Правила:** для FPC-частей — `EchoRecorder/PASCAL_RULES.md`; для TS-частей — стиль оркестратора
  (Hono, существующие паттерны `JobManager`/`Scheduler`, `writeJson`, атомарные ренеймы).
- **D10 — Паритет = схема/контракт артефактов, не текст** (whisper.cpp ≠ HF; текст не совпадёт байт-в-байт).

## Acceptance / gates
- **Блокирующий (FPC):** `services\whisperdaemon\app\scripts\build_x64.bat` → exit 0 после каждого FPC-шага;
  WS-смоук прежнего пути (session_start/flush) не сломан.
- **Блокирующий (TS):** typecheck/`bun test` оркестратора зелёный после каждого TS-шага.
- **Блокирующий (интеграция, с F4.1):** `POST /add_file` фикстуры для ws-daemon модели → `status=ready` +
  корректные `result.json`/`result_plain.txt`/`result_timestamp.txt` + output-маркер; `GET /get_job_status`
  и `GET /get_job_result?type=timestamp` возвращают ожидаемое.
- **Non-blocking/manual:** прогон на реальном `.flac` из истории очереди; визуальная сверка текста.

## Risks
- **R1 — Нет паритета текста** (whisper.cpp vs HF). Митиг. D10: гейты проверяют схему/формат, не текст.
- **R2 — Порядок старта:** ws-daemon должен быть поднят до диспетча. Митиг.: driver делает `health`/reconnect,
  внятная ошибка + `status=failed` при недоступности демона.
- **R3 — Разрешение пути ffmpeg** в оркестраторе. Митиг.: конфиг/env, явная ошибка.
- **R4 — Тайминги ms↔секунды:** WS-события демона в ms; оркестратор конвертирует в секунды при записи
  `result.json`. Покрыто гейтом F3.3.
- **R5 — Гонка файлового и WS инференса** за один контекст. Митиг. D8 (`gInferenceLock`).
- **R6 — Прогрев модели** к моменту первого `transcribe_file`. Митиг.: `health`/`ensureWarmupReady`.
- **R7 — Совместимость со Scheduler:** сейчас завершение ловится по output-маркеру, который писал воркер;
  на ws-daemon пути маркер пишет оркестратор сам. Покрыто F3.3.

## Steps (mirror the ledger)
- [x] **F0.1 — Пересмотр плана + леджера.** JSON валиден, DAG ацикличен.
- [x] **F1.1 — Контракт дескриптора + `services/whisperdaemon/daemon.json`** (accepted input pcm16le/16k/mono, transport ws host/port, capabilities). Документируем схему.
- [x] **F2.1 — FPC: вынести ядро инференса** в переиспользуемую функцию (pcm16le+lang → segments/words/text/lang); WS-путь делегирует. Поведение WS без изменений. *(in-file: `inferBufferedAudio`→`inferPcm16le(aAudioBytes)`; отдельный юнит не понадобился)*
- [x] **F2.2 — FPC: события `describe` + `health`** (отдают дескриптор из `daemon.json` / состояние прогрева).
- [x] **F2.3 — FPC: событие `transcribe_file`** (читает pcm16le-файл по пути, инференс под `gInferenceLock`, отдаёт segment_final/word_committed/session_final).
- [x] **F3.1 — TS: ffmpeg-конвертация** input → `data/<id>/audio.pcm` (pcm16le 16k mono) в конвейере диспетча; путь ffmpeg из конфига/env. *(модуль `audio-convert.ts` + `config.ffmpegPath`; ffmpeg скопирован в `tools/ffmpeg/` (gitignored))*
- [x] **F3.2 — TS: daemon-driver (WS-клиент) + конфиг** ws-daemon моделей (host/port); `describe` → `transcribe_file` → сбор сегментов в normalized-результат. *(config.wsDaemons; проверено mock-юнитами + живьём против whisperdaemon)*
- [x] **F3.3 — TS: интеграция driver в Scheduler** для моделей `ws-daemon`: вместо python-воркера — конвертация+driver, запись `result.json`/`result_plain.txt`/`result_timestamp.txt` (секунды)/переходов `status.json`/output-маркера. *(ws-daemon-runner.ts + JobManager.claimExternalJob + Scheduler.dispatchWsDaemonJob; unit-тесты контракта артефактов)*
- [x] **F4.1 — Интеграционный E2E-тест** (`/add_file` → convert → daemon → артефакты + `/get_job_status`). *(tests/whisperdaemon-file-api.ps1; PASS на реальном файле)*
- [x] **F4.2 — Ops: конфиг/скрипты** запуска оркестратора с whisperdaemon как `ws-daemon` (порядок старта) *(manual/non-blocking)*. *(scripts/start_ws_daemon_stack.ps1)*
- [ ] **F4.3 — Документация** (file-API демона, дескриптор, отличие ws-daemon от python-worker; обновить обзор).

## Contract (F1.1): дескриптор демона + протокол file-API
Источник истины — `services/whisperdaemon/daemon.json` (демон отдаёт его же по `describe`).

- **`transport`** — `ws://host:port/`; в файле дефолт (127.0.0.1:7801), фактические host/port возвращает
  `describe` (задаются `--host/--port`). Оркестратор берёт endpoint из своего `config.json` (F3.2).
- **`input`** — согласованный формат, который file-daemon обязан подготовить ffmpeg перед заданием:
  `raw` / `pcm_s16le` / `16000 Hz` / `mono` / little-endian.
- **События (client → daemon → client):**
  - `{event:describe}` → `describe_ack` (этот дескриптор с фактическим transport).
  - `{event:health}` → `health_ack {state: loading|ready|failed, model_name, error?}`.
  - `{event:transcribe_file, request_id, path, language, params:{word_timestamps?, mode?}}` →
    поток `word_committed`* / `segment_final` → терминальный `session_final {text, duration_ms,
    segment_count, language, detected_language?, request_id}`; при ошибке — `error {message, request_id?}`.
- **Тайминги**: все `*_ms` — миллисекунды; в секунды переводит оркестратор при записи `result.json` (R4).
- **Разделение**: демон только распознаёт присланный файл; очередь/артефакты/статусы — оркестратор (D6).

## References
- File-daemon: `orchestrator/src/{index,job-manager,scheduler,process-manager}.ts`, `config.json`
- Контракт артефактов: `shared/echoscript_shared/service_runner.py`, `jobs/data/*_whisper_podlodka_*/`
- Ядро демона: `services/whisperdaemon/app/src/WhisperDaemon.pas`
- Методология: `EchoRecorder/METHODOLOGY.md`; Правила Pascal: `EchoRecorder/PASCAL_RULES.md`
- Обзор системы: `EchoRecorder/docs/ARCHITECTURE.md`
