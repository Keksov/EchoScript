# Daemon Monitor & Control — план

Status: **active**
Created: 2026-07-01
Authoritative progress ledger: [daemon-monitor-progress.json](daemon-monitor-progress.json)

Goal: утилита управления и мониторинга всеми стриминговыми демонами распознавания.
CLI на FPC (`orchestrator/monitor/cli`) — запрос статуса/health и управление
(start/stop/restart). GUI на Lazarus + Pixie (`orchestrator/monitor/app`) — визуальная
оболочка того же ядра. Оба линкуют общее UI-независимое ядро (monitor-core). Для единого
протокола статуса демонам без health добавляется WS `describe`/`health`.

## Audit / Where things stand (проверено по коду)
- **4 демона:**
  - `voskdaemon` — FPC (`VoskDaemon.exe`), порты 7701/7702/7703 (ru / ru_cmd / en), WS.
    Health **нет** (только `session_ack`). Скрипты: `start_/stop_/run_voskdaemon_*.bat`, `wait_voskdaemon_ready.ps1`.
  - `whisperdaemon` — FPC (`WhisperDaemon.exe`), порт 7801, WS. **Уже есть** `describe`/`health`
    (`WhisperDaemon.pas:handleDescribe/handleHealth`, `daemon.json`). Скрипты: `start_/stop_whisperdaemon_podlodka.bat`.
  - `vibevoicedaemon` — **Python** (`app/main.py`), порт 7802, WS (`session_ack`). Health нет.
    Скрипты: `start_/stop_/run_vibevoicedaemon.bat`, `wait_vibevoicedaemon_ready.ps1`.
  - `diarizationdaemon` — порт 7900, на sherpa; структура нестандартная, обычных start/stop-скриптов нет.
    Протокол `diar_*` (см. `EchoRecorder/core/src/echo_recorder_core_voskdaemon.pas`).
- **Управление сейчас:** per-instance `.bat` (start/stop/run) + `wait_*_ready.ps1`; живость — по процессу
  (exe+commandline) и порту; единого health нет (только whisper).
- **Pixie:** `EchoRecorder/vendors/pixie/source/{common,htmlview}`, компонент `TPixieHtmlView` (HTML-рендер).
  EchoRecorder GUI — **Lazarus/LCL** (`app/EchoRecorder.lpi`, `OtherUnitFiles=…\pixie\source\common;…\htmlview`,
  сборка `lazbuild`, Lazarus 4.6). Значит monitor GUI = Lazarus+Pixie; CLI/core = чистый FPC.
- **FPC-тулчейн:** `EchoRecorder/VendorsCore/fpc/fpc-main` (как в `whisperdaemon/app/scripts/fpc-x64.cfg`).
- WS-клиент на Pascal: `fpwebsocketclient` (пример — `echo_recorder_core_voskdaemon.pas`).
- Папки `orchestrator/monitor/{cli,app}` уже существуют (пустые).

## Decisions (locked)
- **D1 — Общее UI-независимое ядро (monitor-core, Pascal).** И CLI (FPC), и GUI (Lazarus+Pixie) линкуют его;
  CLI умеет человекочитаемый и `--json` вывод. *(ответ владельца)*
- **D2 — Объём: мониторинг + управление** (status/health/list + start/stop/restart через существующие
  скрипты демонов; логику жизненного цикла не переписываем). *(ответ владельца)*
- **D3 — Инвентарь демонов — декларативный** `orchestrator/monitor/daemons.json`: список инстансов
  (name, kind [fpc|python|sherpa], host, port, ws-resource, start/stop/ready-скрипты, метод health).
- **D4 — Единый протокол статуса: добавить WS `describe`/`health`** в `voskdaemon` (FPC) и `vibevoicedaemon`
  (Python); для `diarizationdaemon` — добавить если транспорт позволяет, иначе fallback. Статус ВСЕГДА
  включает порт-открыт + процесс-жив; health/describe — где доступно. *(ответ владельца: «сразу добавить WS health»)*
- **D5 — GUI = Lazarus/LCL + `Pixie.HtmlView`** (как EchoRecorder app; интерфейс рендерится как HTML).
  CLI и core — чистый FPC, без LCL/Pixie.
- **D6 — Управление вызывает существующие per-instance скрипты** (`start_*`/`stop_*`), а не переписывает старт/стоп.
- **D7 — Тулчейн/зависимости:** FPC из `EchoRecorder/VendorsCore`; Pixie из `EchoRecorder/vendors/pixie`
  (пути в `.cfg`/`.lpi`, как у существующих проектов).
- **D8 — Правила:** `EchoRecorder/METHODOLOGY.md` + `EchoRecorder/PASCAL_RULES.md`
  (`fcl-process`/`fpwebsocketclient` в `-Fu`; CRLF-safe правки; `SetExceptionMask` при C-вызовах;
  разделитель `.` в JSON; DLL рядом с exe при необходимости).

## Acceptance / gates
- **Блокирующий (FPC):** сборка monitor-core + CLI (`fpc … monitor.pas`) → exit 0; консольные unit-тесты
  ядра (`Ok(name,cond)`, exit 1 при провале) — парсинг inventory, формирование статуса на mock-WS.
- **Блокирующий (health-правки):** `voskdaemon` собирается (`build_voskdaemon.bat` exit 0) и живьём отвечает
  на WS `describe`/`health`; `vibevoicedaemon` живьём отвечает на `describe`/`health`.
- **Блокирующий (CLI E2E):** `monitor status --json` против поднятого(ых) демона(ов) даёт корректный статус
  (up/down, порт, health); `monitor start/stop <name>` меняет состояние (проверка порт-открыт/закрыт).
- **Non-blocking/manual:** GUI — `lazbuild` зелёный + скриншот таблицы статусов; действия start/stop из GUI.

## Risks
- **R1 — diarizationdaemon нестандартный** (sherpa, 7900, без обычных скриптов). Митиг.: config-driven,
  health опционально, fallback порт/процесс; шаг M1.3 сначала выясняет транспорт.
- **R2 — GUI требует Lazarus 4.6** (не везде установлен). Митиг.: сборка GUI — manual/non-blocking гейт;
  core/CLI собираются чистым FPC без Lazarus.
- **R3 — voskdaemon имеет 3 инстанса** (7701/7702/7703). Митиг.: инвентарь моделирует инстансы отдельно.
- **R4 — health-события должны быть аддитивны** (не ломать существующих стриминговых клиентов). Митиг.:
  новые ветки в dispatch, как в whisperdaemon.
- **R5 — Детекция процесса на Windows** (по exe+commandline). Митиг.: переиспользовать подход существующих
  start/stop-скриптов (Get-CimInstance) либо порт как основной сигнал.
- **R6 — Управление зависит от рабочего каталога скриптов** (относительные пути). Митиг.: запускать скрипты
  с корректным cwd (project root), как делают сами `.bat`.

## Steps (mirror the ledger)
- [x] **M0.1 — Plan & ledger.** JSON валиден, DAG ацикличен.
- [x] **M1.1 — voskdaemon: WS `describe`/`health`** (FPC, по образцу whisperdaemon) + `daemon.json`. Сборка + живой WS-опрос.
- [ ] **M1.2 — vibevoicedaemon: WS `describe`/`health`** (Python) + дескриптор. Живой WS-опрос.
- [ ] **M1.3 — diarizationdaemon: health/транспорт** — выяснить, добавить health или задокументировать fallback.
- [ ] **M2.1 — monitor-core: инвентарь** `daemons.json` + загрузчик/типы (Pascal). Парсинг + unit-тест.
- [ ] **M2.2 — monitor-core: статус** (порт-открыт + процесс-жив + WS `describe`/`health`-клиент). Unit (mock) + живой.
- [ ] **M2.3 — monitor-core: управление** (start/stop/restart через скрипты; спавн инъектируется для тестов).
- [ ] **M3.1 — CLI** (`orchestrator/monitor/cli`): `list`, `status [--json]`, `start/stop/restart <name>`. Сборка + E2E.
- [ ] **M4.1 — GUI** (`orchestrator/monitor/app`, Lazarus+Pixie): таблица статусов с опросом ядра. `lazbuild` + скриншот.
- [ ] **M4.2 — GUI: действия** start/stop/restart (кнопки → ядро). `lazbuild` + ручная проверка.
- [ ] **M5.1 — Документация и ops** (README, build/run-скрипты, описание `daemons.json`).

## References
- Демоны: `services/{voskdaemon,whisperdaemon,vibevoicedaemon,diarizationdaemon}`
- Образец WS health/describe: `services/whisperdaemon/app/src/WhisperDaemon.pas`, `services/whisperdaemon/daemon.json`
- WS-клиент на Pascal: `EchoRecorder/core/src/echo_recorder_core_voskdaemon.pas`
- Pixie GUI: `EchoRecorder/app` (`.lpi`, `main_form.pas`), `EchoRecorder/vendors/pixie/source/htmlview`
- Методология: `EchoRecorder/METHODOLOGY.md`; Правила Pascal: `EchoRecorder/PASCAL_RULES.md`
