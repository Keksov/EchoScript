# daemon-fleet — план

Динамический «флот» демонов: запускать разные скачанные модели на разных портах
с индивидуальными настройками, удалять модели и их конфиги. Движок управления —
FPC CLI `echoctl`; UI/Bun — тонкая обёртка над ним.

Методология: «План + Леджер» (`daemon-fleet-progress.json`). Один шаг → один коммит →
один гейт. Пауза на границах фаз. Первый шаг — DF0.1. DAG ацикличен.

## Что уже есть (фундамент)

- **Инстансы уже в config.json.** `ws_daemons` — объект, ключёванный именем; каждая
  запись несёт `host/port/engine/language/model_name`. «Разные модели на разных портах»
  структурно поддержано — не хватает динамического CRUD и per-instance настроек.
- **whisper-демон уже generic:** `resolveWhisperModelPath` берёт полный путь (если файл
  существует) или имя + `WHISPER_MODELS_ROOT`.
- **vosk-демон — хардкод** трёх имён (`resolveVoskModelName`) → нужен generic-резолвинг.
- **CLI-паттерн есть** (`EchoRecorder/cli/src/EchoRecorderCore.pas`, `orchestrator/monitor/cli`):
  один `program`, `{$mode objfpc}{$H+}`, ручной парсинг аргументов, `scripts/{build,run,smoke,clean}_x64.bat`.
- **Панель уже умеет:** start/stop/restart, download, схему настроек (hot/restart +
  `DAEMON_ENV_MAP`), атомарную запись config.json, hot-reload оркестратора. Эта логика
  (settings.ts / services-control.ts / models-provision.ts) при big-bang **переезжает в echoctl**.

## Решения (владелец, 2026-07-06)

- **DF-D1 (big-bang):** `echoctl` сразу — ЕДИНСТВЕННЫЙ движок управления и единственный
  писатель config.json (atomic temp+rename). Существующая TS-логика (save-настроек,
  start/stop/restart, download) переносится в CLI. Bun control-server → чистый прокси.
- **DF-D2 (JSON-контракт):** каждая команда поддерживает `--json` (машинный вывод) для
  UI/сервера; человекочитаемый вывод по умолчанию.
- **DF-D3 (охват v1):** whisper + vosk (ws-демоны). python-модели из `config.models`
  (gemma/vibevoice/borealis — воркеры оркестратора) вне v1.
- **DF-D4 (удаление):** по умолчанию ОТКАЗ, если на модель ссылается хоть один инстанс
  (показать кто). `--force` каскадно удаляет и эти инстансы. Всегда `--dry-run` preview
  (список файлов + конфиг-записей) → подтверждение в UI перед реальным удалением.
- **DF-D5 (per-instance настройки):** запись `ws_daemons` расширяется полем `settings{}`
  (движко-специфичные ключи, зеркало `DAEMON_ENV_MAP`); лаунчер генерит env/флаги из `settings`.
- **DF-D6 (порты):** авто-аллокация per-engine (whisper 78xx, vosk 77xx) + ручной override;
  валидация коллизий по всем инстансам.
- **DF-D7 (spawn + фикс утечки сокета):** демоны запускаются из echoctl через
  `CreateProcess(bInheritHandles=FALSE)` → детач + попутно чиним давнюю утечку :3001
  (демоны больше не наследуют слушающий сокет Bun).
- **DF-D8 (vosk generic):** vosk-демон — резолвинг «путь-или-имя + `VOSK_MODELS_ROOT`»,
  back-compat со старыми именами (`vosk_ru`/`vosk_ru_cmd`/`vosk_en`).
- **DF-D9:** config.json — единый источник истины (как CP-D2), но единственный писатель
  теперь echoctl. Оркестратор по-прежнему hot-reload'ит `ws_daemons` (add/remove инстансов).

## Архитектура

```
UI (Quasar)  ──HTTP──▶  Bun control-server :3001  ──exec echoctl <cmd> --json──▶  echoctl (FPC)
                              (тонкий прокси)                                          │
                                                                                      ├─ config.json  (atomic R/W, единственный писатель)
                                                                                      ├─ models-manifest.json (каталог скачиваемых моделей)
                                                                                      ├─ модели на диске (whisper models root, C:\var\vosk)
                                                                                      └─ CreateProcess(bInheritHandles=FALSE) ▶ whisper/vosk демоны
Оркестратор :3000 ──fs.watch config.json──▶ hot-reload ws_daemons → routing
```

### Командный интерфейс echoctl (v1)

- `daemons list [--json]` — инстансы + live-статус (port-probe / реестр).
- `daemons add --engine <e> --model <m> [--port N] [--host H] [--lang L] [--name NM] [--set k=v ...] [--json]`
- `daemons remove <name> [--json]`
- `daemons edit <name> [--port N] [--model M] [--set k=v ...] [--json]`
- `daemons start|stop|restart <name> [--json]`
- `config get [--json]` · `config set <key> <val>` · `config schema [--json]` — настройки оркестратора.
- `models list [--json]` — манифест + downloaded-state + пути + размеры.
- `models download <id> [--json]`
- `models delete <id> [--dry-run] [--force] [--json]`

### Модель данных (расширение записи ws_daemons)

```json
"whisperdaemon_en": {
  "host": "127.0.0.1", "port": 7802, "engine": "whisper",
  "language": "en", "model_name": "whisper_en_turbo",
  "settings": { "vad": true, "vad_threshold": 0.5, "gpu": false, "no_speech_thold": 0.6 }
}
```

## Фазы

| Фаза | Содержание | Гейт (пауза) |
|---|---|---|
| **P0** | План + скелет echoctl + config I/O | обзор плана владельцем; build зелёный; `daemons list --json` читает ws_daemons |
| **P1** | CRUD инстансов (config-сторона) + per-instance settings + аллокация портов | add/remove/edit пишут config атомарно; валидация; unit-смоки |
| **P2** | Жизненный цикл моделей: manifest, list, download, delete (refuse/force/dry-run) | список/скачивание/удаление моделей из CLI; safety подтверждён |
| **P3** | Обобщение демонов: vosk generic-резолвинг; whisper — подтвердить + settings pass-through | 2-я модель движка на 2-м порту стартует из echoctl |
| **P4** | spawn/stop в echoctl (CreateProcess no-inherit) + config settings get/set/schema | start/stop/restart из CLI с port-verify; утечка :3001 устранена |
| **P5** | Bun → прокси (перенос мутаций из TS) + UI (create/delete/settings/model-delete) + i18n | UI = обёртка; правки идут через echoctl; ru/en полны; тесты зелёные |
| **P6** | Оркестратор: динамический pickup add/remove + E2E | job на новой модели/порту проходит; удаление модели (refuse→force); docs |

## Риски / заметки

- **Два писателя во время миграции.** Big-bang минимизирует окно, но пока P5 не закрыт,
  часть TS-мутаций может сосуществовать с echoctl. Смягчение: echoctl атомарен;
  Bun-мутации отключаем в P5.1 одним коммитом.
- **Утечка сокета :3001** — исторически демоны, запущенные из Bun, наследовали слушающий
  сокет. DF-D7 (CreateProcess bInheritHandles=FALSE) — целевой фикс; проверяем в P4.
- **Прогрев/память больших моделей** — vosk ru-0.42 грузится ~2 мин и падает под нехваткой
  RAM (см. заметку памяти vosk-model-load-cost). echoctl `daemons start` должен не врать о
  готовности: ждать реального warmup-ready, а не только открытия порта.
- **vosk-модели вне download-манифеста** (внешний `C:\var\vosk`) — `models list` показывает
  их read-only (без download), delete — с явным предупреждением о внешнем каталоге.
- **FPC JSON round-trip** должен сохранять неизвестные ключи config.json (speech, models,
  и пр.) — read-modify-write, а не пересборка.
