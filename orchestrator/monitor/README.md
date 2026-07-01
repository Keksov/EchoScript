# Daemon Monitor & Control

Утилита мониторинга и управления стриминговыми демонами распознавания EchoScript.
Состоит из общего UI-независимого ядра на Free Pascal, **CLI** (чистый FPC) и **GUI**
(Lazarus + Pixie). Область: 4 демона — `vosk`, `whisper`, `vibevoice`, `diarization`.

```
orchestrator/monitor/
├── daemons.json        # инвентарь демонов (инстансы, порты, скрипты)
├── core/               # UI-независимое ядро (FPC)
│   ├── monitor_core.pas      # типы + загрузчик daemons.json
│   ├── monitor_status.pas    # статус: порт (ssockets) + WS health (fpwebsocketclient)
│   └── monitor_control.pas   # start/stop/restart через скрипты (TProcess)
├── cli/                # CLI-программа `monitor` (FPC)
├── app/                # GUI `MonitorApp` (Lazarus + Pixie.HtmlView)
├── tests/              # console unit-тесты ядра
└── scripts/            # общий fpc-x64.cfg + build_all.bat
```

## Единый протокол статуса (WS describe/health)

Все 4 демона отвечают на два WS-события (добавлены в этой инициативе; whisper имел изначально):

| Запрос | Ответ |
|--------|-------|
| `{event:describe}` | `describe_ack` — дескриптор `services/<daemon>/daemon.json` с фактическими `transport.host/port` |
| `{event:health}` | `health_ack {state: loading\|ready\|failed, model_name, error?}` |

Статус демона в мониторе = **порт открыт** (что-то слушает → процесс-сервер жив) + при
`health=ws` ещё и **WS health** (state/model). Закрытый порт → `down`.

## Инвентарь `daemons.json`

Массив `daemons`, каждый элемент — инстанс:

| Поле | Смысл |
|------|-------|
| `name` | уникальное имя инстанса (напр. `vosk_ru`) |
| `kind` | `fpc` \| `python` \| `sherpa` |
| `host`, `port` | WS-endpoint |
| `ws_resource` | ресурс (обычно `/`) |
| `model_name` | модель (информативно) |
| `health` | метод статуса (`ws`) |
| `start_script`, `stop_script` | пути (относительно корня проекта) для управления |

Текущие 5 инстансов: `vosk_ru` (7701), `vosk_ru_cmd` (7702), `whisper_podlodka` (7801),
`vibevoice` (7802), `diarization` (7900).

## CLI

```
monitor list                        список демонов из daemons.json
monitor status [<name>] [--json]    статус всех или одного демона
monitor start <name>                запустить (start-скрипт демона)
monitor stop <name>                 остановить (stop-скрипт)
monitor restart <name>              stop -> start
monitor -h | --help                 справка
```

Примеры:
```
monitor status
NAME               STATE     PORT       REACHABLE  MODEL
whisper_podlodka   ready     7801       yes        whisper_podlodka
vosk_ru            down      7701       no

monitor status diarization --json
[ { "name":"diarization","port":7900,"port_open":true,"reachable":true,"state":"ready", ... } ]
```

## Сборка

Требуется тулчейн FPC из `EchoRecorder/VendorsCore` (для CLI/ядра) и Lazarus 4.6 (для GUI).

```
# всё сразу (тесты + CLI + GUI)
pwsh -NoProfile -File orchestrator\monitor\scripts\build_all.bat   REM или cmd /c

# по отдельности
orchestrator\monitor\tests\build_x64.bat     # unit-тесты ядра (core 10/10, status 6/6, control 10/10)
orchestrator\monitor\cli\scripts\build_x64.bat   # -> build\x64\monitor.exe
orchestrator\monitor\app\scripts\build_x64.bat   # lazbuild -> app\build\x64\MonitorApp.exe
```

**Порядок важен: сначала CLI, потом GUI.** GUI — тонкий фронт над CLI (см. ниже).

## Архитектурная заметка (D5a)

`fpwebsocket` отсутствует в FPC, встроенном в Lazarus 4.6 (3.2.4), а `.ppu` тулчейна
VendorsCore (3.3.x) несовместимы по версии. Поэтому **GUI не линкует** `monitor_status`/
`monitor_control`, а вызывает уже собранный `monitor.exe` (`status --json`, `start/stop/
restart`) через `TProcess` и парсит JSON. Ядро `monitor_core` остаётся общим и собирается
обоими компиляторами; вся WS-логика живёт в CLI/ядре, собранных VendorsCore FPC.

## Тесты

`orchestrator\monitor\tests\build_x64.bat` собирает и прогоняет три консольных сьюта
(exit 1 при любом провале): `test_monitor_core`, `test_monitor_status`, `test_monitor_control`.
`test_monitor_status --live <host> <port>` — живой опрос одного endpoint.
