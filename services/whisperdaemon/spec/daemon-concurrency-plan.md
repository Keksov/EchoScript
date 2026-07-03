# whisperdaemon: неблокирующий WS-сервер + отмена инференса при обрыве

Status: **active** (планируется; реализация не начата)
Created: 2026-07-03
Authoritative progress ledger: [daemon-concurrency-progress.json](daemon-concurrency-progress.json)

## Goal
Убрать корневую причину каскада из инцидента `stream-stall-requeue-fix`: WS-сервер демона
**однопоточный** — во время длинного инференса он держит `gInferenceLock` и **не отменяет** инференс
при обрыве клиента (нет abort-on-disconnect). Из-за этого брошенный/медленный стрим блокирует новые
подключения и жжёт CPU на никому не нужном инференсе. Нужно: (1) инференс не должен блокировать
приём/обслуживание других соединений; (2) при обрыве клиента текущий инференс отменяется.

Это **отдельная будущая работа** (вне scope фикса `stream-stall-requeue-fix`, там SR-D4). keepalive +
лимит повторов уже гасят пользовательский симптом (бесконечный requeue), эта инициатива устраняет
первопричину.

## Audit / Where things stand (проверено по коду)
- **Сервер.** `TWhisperDaemonHost.Fserver: TWebSocketServer` (`fpwebsocketserver`).
  `Fserver.OnMessageReceived := @handleMessage` — блокирующий инференс (`gWhisperFullWithState`)
  выполняется **внутри** обработчика сообщения.
- **fpwebsocketserver умеет.** Есть `ThreadedAccept: Boolean`, `TAcceptThread`, события
  `OnConnect`/`OnDisconnect`/`OnConnectionHandshake`. Нужно проверить: обслуживается ли **каждое
  соединение в своём потоке** (тогда блокирующий handler на A не мешает B), и **приходит ли
  `OnDisconnect` во время** блокирующего handler (для abort).
- **Whisper поддерживает abort.** `TWhisperFullParams` содержит `abortCallback`/`abortCallbackUserData`
  (как `progressCallback`, уже задействованный для keepalive). Отмена = abort-callback возвращает
  «прервать» по потокобезопасному флагу.
- **Инференс сериализован** `gInferenceLock` — намеренно (одна модель, один прогон за раз). Это
  сохраняем; проблема не в сериализации, а в блокировке IO/приёма и отсутствии отмены.

## Decisions (locked)
- **DC-D1 — Две цели:** (a) инференс не блокирует WS-сервер (приём/обслуживание др. соединений и
  детект обрыва); (b) обрыв клиента отменяет текущий инференс.
- **DC-D2 — Сначала spike (P1), потом дизайн-гейт.** FPC-threading в `fpwebsocketserver` неочевиден;
  P1 — аудит + минимальный прототип, затем согласовать подход с владельцем **до** рефактора.
- **DC-D3 — Abort-on-disconnect:** потокобезопасный per-session флаг (`InterlockedExchange`/крит.секция)
  → whisper `abortCallback`; `OnDisconnect`/close-хендлер ставит флаг. Требует, чтобы обрыв
  детектился во время инференса (зависит от threading — P1).
- **DC-D4 — Инференс off IO-thread** (если P1 покажет блокировку приёма): вынести
  `processBufferedAudio`/инференс в рабочий поток/очередь; `handleMessage` не блокирует; `gInferenceLock`
  по-прежнему сериализует единственный прогон.
- **DC-D5 — Потокобезопасность `sendEvent`.** Отправка WS-событий (segment_final/keepalive/…) из
  рабочего потока vs IO-потока — согласовать (очередь исходящих или лок на соединение).
- **DC-D6 — Аддитивно и обратимо.** Сохранить текущий протокол и поведение (streaming/one-shot);
  правки минимальны и покрыты spike-прототипом + E2E.

## Acceptance / gates
- whisperdaemon собирается.
- **E2E:** (a) обрыв клиента во время инференса → инференс **прекращается** в течение ~секунд, CPU
  освобождается (не досчитывает 38-мин дорожку впустую); (b) новое подключение **открывается** во
  время идущего инференса (не висит до его конца); (c) регресс: обычный streaming/one-shot по-прежнему
  даёт корректный результат.
- Дизайн-гейт после P1: подход согласован до рефактора (DC-D2).

## Risks
- **FPC-threading / fpwebsocketserver** — высокая неопределённость; возможно потребуется своя обвязка
  потоков. Митигация: spike сначала.
- **Гонки sendEvent / состояние сессии** между IO- и worker-потоком (DC-D5).
- **Отмена whisper** должна корректно освобождать state/лок и не оставлять сессию в полу-состоянии.
- **Разрастание** правки — держать аддитивной, не ломать streaming/one-shot/registry/keepalive.

## Steps (mirror the ledger)
- [x] **DC0.1 — Plan & ledger.**
- [ ] **DC1.1 — Spike: аудит threading `fpwebsocketserver`** (per-connection thread? `OnDisconnect`
  во время блокирующего handler?) + минимальный прототип; **дизайн-гейт** с владельцем.
- [ ] **DC2.1 — Abort-on-disconnect** (потокобезопасный флаг → whisper `abortCallback`; close-хендлер
  ставит флаг). Зависит от DC1.1.
- [ ] **DC3.1 — Инференс off IO-thread** (если по DC1.1 нужно): worker/очередь, неблокирующий
  `handleMessage`, `gInferenceLock` сериализует; потокобезопасный `sendEvent`.
- [ ] **DC4.1 — E2E + docs:** обрыв → отмена/освобождение CPU; параллельное подключение во время
  инференса; регресс streaming/one-shot; обновить ARCHITECTURE.md (снять known-limitation).

## References
- Инцидент/фикс: [../../../orchestrator/spec/stream-stall-requeue-fix-plan.md](../../../orchestrator/spec/stream-stall-requeue-fix-plan.md) (SR-D4 — вынесенное ограничение)
- Стрим-мост: [../../../orchestrator/spec/file-streaming-bridge-plan.md](../../../orchestrator/spec/file-streaming-bridge-plan.md)
- Демон: `services/whisperdaemon/app/src/WhisperDaemon.pas`; сервер: `fpwebsocketserver`
- Методология: `EchoRecorder/METHODOLOGY.md`; Правила Pascal: `EchoRecorder/PASCAL_RULES.md`
