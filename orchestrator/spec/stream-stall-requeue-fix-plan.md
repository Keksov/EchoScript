# Фикс: бесконечный requeue при heartbeat-стойле (редкая речь / длинный инференс)

Status: **active**
Created: 2026-07-03
Authoritative progress ledger: [stream-stall-requeue-fix-progress.json](stream-stall-requeue-fix-progress.json)

## Goal
Длинный файл с **редкой речью** (`CD4 - 8 - The Absolute.flac`, ~38 мин, 73 МБ pcm) загнал
оркестратор в **бесконечный цикл** `processing→waiting→pending` (60 повторов, ~7.7 CPU-часов bun +
~9.6 CPU-часов демона, прогресс 0/0, финал — транзиентный `ffmpeg exit 66`). Причина: в стриминге
демон между границами предложений молчит дольше `heartbeat` (120 c), оркестратор считает это
транспортным сбоем (`DaemonUnreachableError` stall) и делает **requeue** — а демон жив, поэтому
цикл не заканчивается. Редкая речь — валидный вход; пайплайн не должен на нём разваливаться.

## Audit / Where things stand (проверено по коду и логам)
- **Стойл = requeue.** `daemon-stream-driver.ts`: heartbeat-таймаут → `DaemonUnreachableError`
  (наравне с connect/close). `ws-daemon-runner.ts` → `outcome "requeue"`.
  `scheduler.onWsDaemonJobOutcome` → `invalidateModel` + `requeueJob` **без лимита** → бесконечный
  цикл на живом-но-молчащем демоне.
- **Демон молчит во время инференса.** `segment_final` эмитится только на границе предложения; при
  редкой речи промежуток > 120 c. Демон при этом жив (registry-heartbeat свеж, порт слушает).
- **Демон биндит нужные колбэки.** `TWhisperFullParams` содержит `progressCallback`/`…UserData` и
  `abortCallback`/`…UserData` (whisper.cpp ABI) — есть чем слать keepalive и (в будущем) отменять.
- **Каскад.** Первый длинный стрим блокирует однопоточный демон (держит `gInferenceLock`, не отменяет
  инференс при обрыве), поэтому следующие подключения не открываются — усиливает цикл.
- **ffmpeg сам файл конвертит нормально** (проверено: exit 0, 73 МБ pcm). `exit 66` — транзиент от
  гонки перекрывающихся перезапусков за `audio.pcm`, следствие цикла, не корень.

## Decisions (locked)
- **SR-D1 — Лимит повторов на задание** (config `max_requeue_attempts`, дефолт 5). После порога —
  terminal `failed` + output-маркер. Счётчик **персистентный** (число `waiting` в `status.json`),
  чтобы переживать рестарты. Безусловно убирает бесконечный цикл.
- **SR-D2 — Демон шлёт keepalive во время инференса** через whisper `progressCallback` (событие
  `{event:keepalive, progress}`, троттлинг ~3 c). Оркестратор сбрасывает heartbeat на **любом**
  входящем событии (уже так) — добавить явный `case "keepalive"`. Редкая речь / долгий инференс
  больше не дают ложного стойла; heartbeat = реальная живость.
- **SR-D3 — Requeue остаётся только для транспортных сбоев** (connect/close/stall), но теперь
  ограничен (SR-D1) и почти не срабатывает ложно (SR-D2). Классы ошибок не усложняем.
- **SR-D4 — Abort-on-disconnect и не-блокирующий WS-сервер демона — ВНЕ scope** (нужен threading-
  рефактор `fpwebsocketserver`). Фиксируем как известное ограничение; каскад гасится P1+P2 (нет
  ложных стойлов → нет лавины брошенных стримов → демон не забивается).
- **SR-D5 — Чистое ядро + DI + тесты;** демон-правка минимальна (`progressCallback`), проверка
  пересборкой + E2E на реальном файле.

## Acceptance / gates
- `bun test` (orchestrator) зелёный: лимит повторов (после N → failed, не requeue), обработка
  `keepalive`.
- whisperdaemon собирается; во время инференса шлёт `keepalive`.
- **E2E** на `CD4 - 8 - The Absolute.flac` (изолированный jobs-root): **нет бесконечного цикла** —
  задание либо доходит до `ready`, либо честно `failed` после лимита; **без** 60 циклов и
  CPU-часов. Регресс: короткая речь по-прежнему `ready`.

## Risks
- **keepalive из progress-callback** шлётся в том же потоке, что инференс — убедиться, что send не
  ломает WS-состояние (демон уже шлёт `segment_final` по ходу). Троттлинг обязателен.
- **Персистентный счётчик** по `status.json` — не считать чужие `waiting`; считать только для этого
  задания (файл per-job).
- **Каскад при рестарте оркестратора** (брошенный стрим) — вне scope (SR-D4); частично гасится тем,
  что ложных стойлов больше нет.

## Steps (mirror the ledger)
- [x] **SR0.1 — Plan & ledger.**
- [x] **SR1.1 — Лимит повторов** (`max_requeue_attempts`): scheduler считает прошлые `waiting`,
  после порога `failed` + маркер вместо requeue; config + тесты.
- [ ] **SR2.1 — Keepalive демона** (`progressCallback` → `keepalive`) + оркестратор `case "keepalive"`;
  пересборка демона + тест.
- [ ] **SR3.1 — E2E** на реальном файле (изолированно): нет цикла (ready|failed-after-cap), регресс
  на короткой речи; + docs (ARCHITECTURE.md, known-limitation про блокирующий WS-сервер).

## References
- Инициатива стрим-моста: [file-streaming-bridge-plan.md](file-streaming-bridge-plan.md)
- Инициатива drop+registry: [jobs-drop-daemon-registry-plan.md](jobs-drop-daemon-registry-plan.md)
- Лог инцидента: `jobs/data/1783028491159_..._cd4-8-the-absolute/status.json`
