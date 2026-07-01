# WhisperDaemon

FPC (Free Pascal) WebSocket-сервер поверх **whisper.cpp** (`whisper.dll` + модель
`models/ggml-<model>.bin`). Держит модель прогретой в памяти и обслуживает **два интерфейса**:

1. **Стриминговый WS** (`session_start` → аудио-кадры → `flush` → `session_final`) —
   реальное время; используется клиентом EchoRecorder.
2. **Файловый API** (`describe` / `health` / `transcribe_file`) — распознавание готового
   файла; используется оркестратором как «ws-daemon» бэкенд для очереди `jobs/`.

Демон **тонкий**: он только распознаёт присланное аудио. Очередь `jobs/`, конвертацию
формата и запись артефактов (`result.json` и т.д.) полностью ведёт оркестратор.

## Запуск

```
# сборка
services\whisperdaemon\app\scripts\build_x64.bat

# одиночный демон (WS на 7801)
services\whisperdaemon\scripts\start_whisperdaemon_podlodka.bat

# весь ws-daemon стек (демон + оркестратор)
pwsh -NoProfile -File scripts\start_ws_daemon_stack.ps1
```

Флаги: `--host` (127.0.0.1), `--port` (7801), `--model-name` (whisper_podlodka),
`--gpu`/`--no-gpu`, `--gpu-device`, `--whisper-dll`, `--release-tag`.

## Дескриптор: `daemon.json`

Источник истины о согласованном формате входа и возможностях. Демон отдаёт его же
в ответ на `describe` (с фактическими `transport.host/port`):

- `input` — формат, который file-daemon обязан подготовить перед `transcribe_file`:
  `container: raw`, `codec: pcm_s16le`, `sample_rate_hz: 16000`, `channels: 1` (little-endian).
- `transport` — `ws://host:port/`.
- `capabilities` — languages, modes, word_timestamps, diarization, streaming_ws, file_api.

## Файловый API (WS control-channel)

Все сообщения — JSON поверх WebSocket. `*_ms` — миллисекунды (оркестратор переводит в
секунды при записи `result.json`).

| Запрос → | Ответ |
|---|---|
| `{event: describe}` | `{event: describe_ack, ...дескриптор с фактическим transport}` |
| `{event: health}` | `{event: health_ack, state: loading\|ready\|failed, model_name, error?}` |
| `{event: transcribe_file, request_id, path, language, params:{word_timestamps?, mode?}}` | поток `word_committed`* / `segment_final` → терминальный `session_final {text, duration_ms, segment_count, language, detected_language?, request_id}`; при ошибке `error {message, request_id?}` |

- `path` — абсолютный путь к **уже подготовленному** raw pcm16le-файлу (см. `input`).
- `word_committed` шлётся при `word_timestamps=true`; `partial_update` — только на стриминговом пути (vosk-подобные), не в файловом.

Пример (Bun):
```ts
import { transcribeFileViaDaemon } from "orchestrator/src/daemon-driver";
const r = await transcribeFileViaDaemon(
  { host: "127.0.0.1", port: 7801, modelName: "whisper_podlodka" },
  "C:/abs/audio.pcm",
  { language: "ru", wordTimestamps: true },
);
// r.text, r.language, r.segments[{startMs,endMs,text}], r.words[...]
```

## ws-daemon vs python-worker

Оба обслуживают **один и тот же контракт** `jobs/` (`jobs/data/<id>/{input,params,status,result*}`,
`jobs/output/<id>.json`), различие — только в рантайме и транспорте:

| | python-worker (`service_runner`) | ws-daemon (этот демон) |
|---|---|---|
| процесс | оркестратор спавнит `python -m app.main` | внешний, всегда поднятый `WhisperDaemon.exe` |
| очередь | воркер сам читает `jobs/input/<model>/` | оркестратор конвертит и зовёт `transcribe_file` |
| декод аудио | внутри воркера (librosa/HF) | оркестратор через **ffmpeg** → pcm16le 16k mono |
| артефакты | пишет воркер | пишет **оркестратор** (`ws-daemon-runner`) |
| модель | грузится в процессе воркера | прогрета в демоне, переиспользуется |

**Маршрутизация:** модель считается ws-daemon, если присутствует в `config.json` →
`ws_daemons` (сопоставление по `model_name`). Тогда `Scheduler` направляет её в
`dispatchWsDaemonJob` вместо python-воркера. Иначе — обычный python-путь. Так на файловый
API можно постепенно переводить отдельные модели, не трогая остальные.

Конфиг:
```json
"ws_daemons": {
  "whisperdaemon": { "host": "127.0.0.1", "port": 7801, "model_name": "whisper_podlodka" }
}
```

Путь к ffmpeg: `config.json` → `ffmpeg_path` или env `ECHOSCRIPT_FFMPEG_PATH`
(дефолт `./tools/ffmpeg/ffmpeg.exe`).

## Использование через HTTP (оркестратор)

```
POST /add_file   {"path":"<abs audio>","model":"whisper_podlodka"}   -> {job_id}
POST /run_job    {"job_id":"<id>","params":{"language":"ru"}}         -> 202
GET  /get_job_status?job_id=<id>                                      -> [...,{status:"ready"}]
GET  /get_job_result?job_id=<id>&type=timestamp                       -> текст с таймкодами
```

## Тесты

- Юнит (оркестратор): `cd orchestrator && bun test` (audio-convert, daemon-driver, ws-daemon-runner).
- E2E: `pwsh -NoProfile -File tests\whisperdaemon-file-api.ps1` — поднимает стек, гоняет
  реальный файл через HTTP API, проверяет `ready` + артефакты.

> Примечание: whisper.cpp (ggml) и python-путь (HF transformers) — разные рантаймы; тексты
> не совпадают байт-в-байт. Совпадает **контракт/схема** артефактов, не дословный результат.
