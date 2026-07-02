# Файловый ввод через стриминговый мост оркестратора + прогресс

Status: **complete**
Created: 2026-07-01
Authoritative progress ledger: [file-streaming-bridge-progress.json](file-streaming-bridge-progress.json)

## Goal
Многочасовые файлы через `jobs/` должны распознаваться так же надёжно, как **живая запись**:
оркестратор скармливает уже сконвертированный `audio.pcm` демону **через существующий стриминговый
протокол** (`session_start` → бинарные окна pcm16le → `flush` → `session_final`), а не одним
`transcribe_file`. Это убирает 10-минутный потолок таймаута, ограничивает память демона окном,
даёт инкрементальные `segment_final` и **процент выполнения** (`progress_pct`), как у EchoRecorder.
Модель очереди и ленты статусов из старого Python-watcher сохраняем.

## Audit / Where things stand (проверено по коду)
- **Проблема файлового пути.** `orchestrator/src/ws-daemon-runner.ts` → `transcribeFileViaDaemon`
  ([daemon-driver.ts:130](../src/daemon-driver.ts)) шлёт **один** `transcribe_file{path}` под
  дефолтным таймаутом `DEFAULT_TRANSCRIBE_TIMEOUT_MS = 600000` (10 мин,
  [daemon-driver.ts:40](../src/daemon-driver.ts)). Раннер вызывает `transcribe(...)` **без**
  `timeoutMs` ([ws-daemon-runner.ts:207](../src/ws-daemon-runner.ts)) → действует дефолт.
- **Демон грузит файл целиком.** `handleTranscribeFile` → `FaudioBytes := loadBinaryFile(path);
  processBufferedAudio(True)` ([WhisperDaemon.pas:1868](../../services/whisperdaemon/app/src/WhisperDaemon.pas)) —
  один `whisper_full` на всё аудио под `gInferenceLock`; клиент отвалился по таймауту — инференс НЕ
  отменяется. Лимит `MAX_SESSION_AUDIO_BYTES = 30 мин` ([:262](../../services/whisperdaemon/app/src/WhisperDaemon.pas))
  стоит только на **стриминговом** пути (`appendAudioBytes`), файловый его обходит.
- **Стриминговый путь УЖЕ обрабатывает длинное аудио окнами.** `processBufferedAudio(False)`
  ([:1457](../../services/whisperdaemon/app/src/WhisperDaemon.pas)): инференс окна → при границе
  предложения commit `segment_final` + **очистка буфера** (`clearSessionData`) → память ограничена,
  результаты инкрементальны. Auto-flush каждые ~3 c при мин. 8 c
  ([:1744](../../services/whisperdaemon/app/src/WhisperDaemon.pas)).
- **Транспорт согласован.** Демон принимает **бинарные** WS-кадры как pcm16le
  (`if not aMessage.IsText then handleBinary(Payload)`,
  [WhisperDaemon.pas:1935](../../services/whisperdaemon/app/src/WhisperDaemon.pas)), текстовые — как
  JSON-события (`session_start`/`flush`/`session_final`, [:1948](../../services/whisperdaemon/app/src/WhisperDaemon.pas)).
  Оркестратор уже пишет `data/<id>/audio.pcm` в pcm16le 16k mono — его и режем на окна.
- **Прогресс уже есть на стороне рекордера.** `writeBackendProgress`
  ([echo_recorder_core_protocol.pas:381](../../EchoRecorder/core/src/echo_recorder_core_protocol.pas))
  считает `progress_pct = completedFragments*100/fragmentCount` и эмитит `backend_progress`.
- **Старый Python-watcher = эталон очереди.** `shared/echoscript_shared/service_runner.py`:
  claim через atomic rename, одна задача за раз, `status.json` — **append-лента** событий
  (`dispatching→pending→processing→ready|failed`, [:647](../../shared/echoscript_shared/service_runner.py)),
  маркер `jobs/output/<id>.json`. Эту семантику сохраняем; прогресс кладём рядом, не засоряя ленту.
- **Статус-API оркестратора.** `job-manager.getJobStatus` читает `status.json`; `/get_job_status`
  и `/list_jobs` ([index.ts](../src/index.ts)) — точки, куда добавляем `progress_pct`.

## Decisions (locked)
- **SB-D1 — Стриминговый мост, не one-shot.** Большие файлы идут через существующий протокол демона
  (`session_start` → бинарные окна pcm16le → `flush` → `session_final`). Переиспользуем живой путь.
  *(Пересмотрено на SB3.2: минимальная правка демона всё же понадобилась — см. SB-D9.)*
- **SB-D2 — Мост = чистый TS-модуль оркестратора** `orchestrator/src/daemon-stream-driver.ts`;
  WS-фабрика и чтение файла **инъектируются** (DI) для детерминированных тестов без сети/ФС.
- **SB-D3 — Окно настраивается через `config.json`** — ключ `stream_window_ms`, **дефолт 30000**
  (30 c = 960000 байт pcm16le), клампится как прочие ms-поля. Один бинарный кадр на окно, `flush`
  после каждого окна. Дефолт совпадает с внутренним окном whisper; редундантная переинференция
  ограничена границами предложений. *(подтверждено владельцем: значение из конфига, дефолт — текущий)*
- **SB-D4 — Единый путь: ВСЕ файлы через мост.** `transcribeFileViaDaemon` (one-shot) остаётся только
  для юнит-тестов/обратной совместимости, из джоб-раннера убирается. *(подтверждено владельцем)*
- **SB-D8 — Rollover-порог тоже из конфига** — ключ `stream_rollover_ms`, дефолт 1200000 (20 мин);
  см. SB-D7.
- **SB-D9 — Накопительная база времени в демоне (стриминг).** E2E вскрыл: в живом пути демон эмитит
  `segment_final`/`word_committed` со временем **относительно каждого коммита** (буфер чистится),
  из-за чего абсолютные таймстампы файла ломались, а `progress_pct` упирался в ~18%. Мини-правка
  (`FcommittedMs`): эмитить со сдвигом + инкремент на длительность коммита, сброс на `session_start`.
  Точные времена, коммиты по границам предложений (без разрезов слов), заодно чинит живой стриминг;
  one-shot `transcribe_file` не затронут. *(выбор владельца)*
- **SB-D5 — Таймаут per-окно/heartbeat**, без глобального 10-мин потолка: ждём завершения каждого
  окна коротким таймаутом, который **сбрасывается** на каждом входящем событии демона.
- **SB-D6 — Прогресс — отдельный overwrite-файл** `data/<id>/progress.json`
  `{progress_pct, windows_done, windows_total, processed_ms, total_ms, updated_at}`. `status.json`
  остаётся append-лентой lifecycle как в старом Python. Прогресс отдаётся **аддитивно**, не ломая
  массив `status.json`: поле `progress` в каждом элементе `/list_jobs`, новый роут
  `/get_job_progress`, и `active_progress` в `GET /`. *(уточнено на SB2.2: `/get_job_status`
  сохраняет прежний контракт-массив.)*
- **SB-D7 — Rollover против 30-мин лимита демона.** Если без коммита накопилось ~20 мин аудио,
  оркестратор делает `session_final`→новый `session_start` со сдвигом таймстампов. На практике
  границы предложений коммитят раньше; это страховка.

## Acceptance / gates
- `bun test` (orchestrator) зелёный: юниты стрим-драйвера, записи `progress.json`, статус-API.
- **E2E**: длинный pcm через реальный whisperdaemon → наблюдаются инкрементальные `segment_final`,
  `progress.json` растёт 0→100, артефакты `result.json`/`result_plain.txt`/`result_timestamp.txt`
  записаны, `status.json` заканчивается `ready`, **без** ошибки таймаута.
- **Регресс**: короткий файл (`EchoRecorder/tests/Два человека.wav`) даёт прежний результат.

## Risks
- **Переинференция на каждый flush** — лишний компьютер. Митигация: flush раз в окно (не чаще),
  окно настраиваемое через `config.json` (SB-D3).
- **Качество на стыках окон** vs one-shot. Митигация: commit по границе предложения (демон уже так
  делает) + окно 30 c с контекстом.
- **30-мин cap демона.** Митигация: rollover SB-D7.
- **Бинарный фрейминг Bun WebSocket.** Убедиться, что `ws.send(Uint8Array/Buffer)` уходит бинарным
  кадром (демон различает `IsText`); закрыть тестом в SB1.2 и проверкой в E2E.

## Steps (mirror the ledger)
- [x] **SB0.1 — Plan & ledger.** Создать оба файла, DAG ацикличен, атомарный коммит.
- [x] **SB1.1 — Стрим-драйвер (чистый модуль, DI).** `daemon-stream-driver.ts`:
  `transcribeFileStreaming(endpoint, pcmPath, options, onProgress)`.
- [x] **SB1.2 — Юнит-тесты драйвера.** Оконная математика, порядок кадров, инкрементальная агрегация,
  прогресс-колбэк, сброс таймаута, ошибки, бинарность кадров.
- [x] **SB2.1 — Конфиг + progress.json в раннере + переключение на мост.** `config.ts` читает
  `stream_window_ms`/`stream_rollover_ms`; раннер пишет `progress.json` через `onProgress`,
  `runWsDaemonJob` вызывает `transcribeFileStreaming` с параметрами из конфига.
- [x] **SB2.2 — Статус-API отдаёт прогресс.** `getJobProgress` читает `progress.json`; `/list_jobs`
  (поле `progress`), новый `/get_job_progress`, `active_progress` в `GET /`. `/get_job_status` без
  изменений (контракт-массив).
- [x] **SB3.1 — Cutover + rollover-гвард (SB-D7).** Cutover сделан в SB2.1; rollover через новое
  WS-соединение со сдвигом таймстампов + интеграционный тест.
- [x] **SB3.2 — E2E против реального whisperdaemon** (`scripts/e2e_stream_manual.ts`). Вскрыл дефект
  таймстампов → правка демона SB-D9 → повторный прогон зелёный (сегменты на всю длину, progress→100).
- [x] **SB3.3 — Docs.** Обновить `docs/ARCHITECTURE.md` и кросс-ссылку из whisperdaemon-jobs-plan.
- [x] **SB4.1 — (non-blocking) Прогресс в мониторе.** Карточка оркестратора показывает активную
  задачу + полосу `progress_pct` (из `active_progress`). Попутно починена сборка GUI под новую
  сигнатуру Pixie `OnAnchorClick`.

## References
- Предыдущая инициатива (завершена): [../../services/whisperdaemon/spec/whisperdaemon-jobs-plan.md](../../services/whisperdaemon/spec/whisperdaemon-jobs-plan.md)
- Методология: [../../EchoRecorder/METHODOLOGY.md](../../EchoRecorder/METHODOLOGY.md)
- Правила Pascal: [../../EchoRecorder/PASCAL_RULES.md](../../EchoRecorder/PASCAL_RULES.md)
- Архитектура: [../../EchoRecorder/docs/ARCHITECTURE.md](../../EchoRecorder/docs/ARCHITECTURE.md)
