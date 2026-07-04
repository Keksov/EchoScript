# Фикс длинных файлов: нарезка на chunk'и + keepalive-safety

Status: **complete**
Created: 2026-07-04
Authoritative progress ledger: [long-file-chunking-fix-progress.json](long-file-chunking-fix-progress.json)

## Goal
Длинный файл с редкой речью (`CD4 - 8 - The Absolute.flac`, ~38 мин) не досчитывается: копится
огромный необработанный буфер → срабатывает rollover (переоткрытие сессии), но демон однопоточный и
блокирующий — новое соединение rollover'а не обслуживается во время идущего инференса → стойл →
requeue → рестарт с нуля (в логе `10054` + «inference failed after retry», `session_final: 0`).
Чиним две ошибки:
- **A (демон):** keepalive-`Send` не защищён от разорванного соединения → обрыв рушит инференс через
  ложный OOM-retry. Регрессия из SR2.1.
- **B (оркестратор):** заменить rollover-по-порогу на **проактивную нарезку** — каждая сессия
  обрабатывает фикс. chunk аудио и завершается штатно (flush→session_final→close) **до** того как
  буфер вырастет; сессии строго последовательны (одно соединение за раз) → нет reconnect-во-время-
  инференса и 30-мин cap не достигается.

## Audit / Where things stand (проверено по коду и логам)
- **Rollover сейчас** (`daemon-stream-driver.ts`): сессия завершается, когда
  `uncommittedMs = msForBytes(bytesSent) - processedMs >= rolloverMs` (20 мин). При редкой речи
  `processedMs` почти не растёт → буфер копится → огромные медленные инференсы; rollover рвётся о
  блокирующий демон. Внешний цикл уже переоткрывает соединение и сшивает таймстампы сдвигом `offsetMs`.
- **Демон, keepalive (SR2.1):** `onInferenceProgress` шлёт `sendEvent(keepalive)` из whisper
  `progressCallback` **без** try/except. При обрыве `Fconnection.Send` кидает `(10054)`; исключение
  ловится общим OOM-обработчиком инференса → «retrying with low-memory» → повторный крах →
  `error: inference failed after retry`. Лог `bmzor7dud`: строки 429–435, 550–563.
- **Демон однопоточный** (известное ограничение, план `daemon-concurrency`): блокирующий инференс не
  даёт обслужить параллельное соединение. Нарезка (B) обходит это, делая сессии последовательными и
  короткими; полноценное решение — `daemon-concurrency` (отдельно).

## Decisions (locked)
- **LF-D1 — Проактивная нарезка вместо rollover.** Каждая сессия шлёт фикс. объём аудио
  (`stream_chunk_ms`, дефолт 300000 = 5 мин), затем `flush`→`session_final`→close; следующая сессия —
  со сдвигом. Буфер демона ≤ chunk (нет 30-мин cap), инференс каждого chunk быстрый и завершается,
  сессии **строго последовательны** (нет reconnect во время инференса). Заменяет rollover (SB-D7/D8).
- **LF-D2 — keepalive best-effort.** `sendEvent` в `onInferenceProgress` обёрнут в try/except — обрыв
  соединения не бросает в инференс, ложного OOM-retry больше нет.
- **LF-D3 — Сшивка сохраняется:** `offsetMs` и сквозная нумерация сегментов как в текущем внешнем
  цикле; результат склеивается из chunk'ов.
- **LF-D4 — Компромисс границ:** chunk может резать предложение на стыке (демон коммитит хвост на
  flush) — приемлемо для корректности; overlap/выравнивание по тишине — не в этой итерации.
- **LF-D5 — Чистое ядро + DI + тесты;** демон-правка минимальна; E2E на реальном срезе CD4 (несколько
  chunk'ов, сшитые таймстампы, доходит до `ready`).

## Acceptance / gates
- `bun test` (orchestrator) зелёный: нарезка (несколько сессий по фикс. объёму, сшивка), обратная
  совместимость коротких файлов (одна сессия).
- whisperdaemon собирается; keepalive-`Send` не рушит инференс при обрыве.
- **E2E** на срезе `CD4 - 8 - The Absolute.flac` (напр. 12–15 мин → 3 chunk'а): проходит до
  `session_final`/`ready` **без** стойла/requeue; таймстампы растянуты по всей длине. Регресс короткой
  речи → `ready`.

## Risks
- **Границы chunk'ов** режут слова/предложения → небольшая потеря на стыках (LF-D4). Митигация:
  разумный chunk (5 мин) → мало стыков; overlap — будущее.
- **Скорость:** длинный файл всё равно считается ~реальное-время×N на CPU; цель — **корректность и
  завершаемость**, не скорость.
- **Регресс rollover-тестов:** заменяем механизм — обновить/переписать интеграционный тест rollover на
  тест нарезки.

## Steps (mirror the ledger)
- [x] **LF0.1 — Plan & ledger.**
- [x] **LF1.1 — A: keepalive-safety в демоне** (try/except вокруг `sendEvent`) + пересборка.
- [x] **LF2.1 — B: нарезка в драйвере** — сессия завершается по `stream_chunk_ms` (не по uncommitted);
  config-ключ; обновить/переписать тесты (в т.ч. rollover→chunking).
- [x] **LF3.1 — E2E** на срезе реального файла (несколько chunk'ов до `ready`, сшивка) + регресс
  короткой речи; docs (ARCHITECTURE.md: rollover→нарезка).

## References
- Инцидент/фикс стойла: [stream-stall-requeue-fix-plan.md](stream-stall-requeue-fix-plan.md)
- Стрим-мост (rollover SB-D7/D8): [file-streaming-bridge-plan.md](file-streaming-bridge-plan.md)
- Глубокое решение: [../../services/whisperdaemon/spec/daemon-concurrency-plan.md](../../services/whisperdaemon/spec/daemon-concurrency-plan.md)
- Лог инцидента: task `bmzor7dud` (10054 / inference failed after retry)
