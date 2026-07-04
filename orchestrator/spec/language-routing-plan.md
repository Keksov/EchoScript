# Язык оригинала при отправке файлов: подкаталоги input/<model>/<lang>/ + демон на язык

Status: **active**
Created: 2026-07-04
Authoritative progress ledger: [language-routing-progress.json](language-routing-progress.json)

## Goal
Дать задавать язык оригинала файла через **подкаталог** `jobs/input/<model>/<lang>/` (`en`, `ru`, …).
Файл, брошенный прямо в `jobs/input/<model>/` (без языкового подкаталога), считается **мульти-язычным**
(несколько языков), и с этим надо научиться работать. Разные языки обслуживаются **отдельными
демонами** (`whisperdaemon_<lang>` со своей моделью), оркестратор роутит задание по языку. Пока —
только whisperdaemon; механизм расширяемый (добавил язык = ещё модель + демон).

## Audit / Where things stand (проверено по коду)
- **Язык уже течёт** через `params.json.language` → `ws-daemon-runner.extractLanguage` → `session_start.language`
  → демон `Flanguage` → whisper `ctxParams.language` (`auto` = whisper сам детектит **один** язык на файл;
  per-window переключения нет). `detectLanguage` НЕ ставится (это «только детект, без транскрипции»).
- **Демон = одна модель**, грузится по `--model-name` (`whisper_podlodka`, RU fine-tuned, 1.6 ГБ ggml);
  прогретый `gCachedContext`. Для качественного EN нужна другая модель.
- **Сканер drop плоский:** `input-drop.scanInputDrops` ходит по `jobs/input/<model>/` (имя модели = имя
  папки), клеймит файлы, `createDroppedJob` → `enqueue`. Языковых подкаталогов пока нет.
- **Роутинг по модели:** `getModelFromJobId` → `<model>`; `scheduler.findWsDaemonForModel` →
  `config.ws_daemons` (по `model_name`). Реестр/readiness-gate — по имени/модели демона.
- **Скрипты моделей:** `stage_whisperdaemon_model.bat` тянет одну модель. Нужно расширить под несколько
  языков (манифест язык→модель).

## Decisions (locked)
- **LG-D1 — Язык из подкаталога** `input/<model>/<lang>/` (`en`, `ru`, …). Файл прямо в `input/<model>/`
  (без lang-подкаталога) = мульти-язык/`auto`. *(подтверждено владельцем)*
- **LG-D2 — Отдельный демон на язык:** `whisperdaemon_<lang>` со своей моделью/портом; оркестратор
  роутит задание по языку. Переиспользует однодельный демон + реестр + readiness-gate; расширяемо
  (добавил язык = ещё демон + модель). Память — только по запущенным языкам. *(владелец)*
- **LG-D3 — Мульти-язык — сначала SPIKE** по whisper (auto на весь файл / per-window detect /
  VAD+detect+routing), затем дизайн-гейт; временный fallback до решения — whisper `auto`
  (single-language). *(владелец)*
- **LG-D4 — Роутинг:** `lang` из подкаталога → `params.language`; scheduler выбирает ws_daemon по
  **(engine, language)** из конфига; readiness-gate применяется к языковому демону; реестр даёт его
  готовность. Точная схема конфига (`language_daemons`/`(engine,lang)→daemon`) и кодирование job —
  фиксируется в P1 (дизайн) и реализуется в P2.
- **LG-D5 — Скрипт моделей расширяется:** обобщённый манифест «язык→модель» + докачка английской
  модели. EN-модель = **`ggml-large-v3-turbo`** (меньше RAM/VRAM и быстрее `large-v3`, качество EN
  сопоставимо); инкрементально `ru`+`en`, дальше расширяемо. *(владелец)*
- **LG-D6 — Только whisperdaemon** (vosk/vibevoice/diarization — вне scope этой инициативы).
- **LG-D7 — Чистое ядро + DI + тесты;** демон-правки минимальны; аддитивно — текущий RU-путь
  (`input/whisper_podlodka/…`, `auto`) не ломаем.

## Acceptance / gates
- `bun test` (orchestrator) зелёный: сканер языковых подкаталогов, роутинг по (model, lang),
  обратная совместимость (файл без lang → auto/мульти).
- Скрипт моделей умеет докачать EN-модель; поднимается `whisperdaemon_en`, регистрируется в реестре.
- **E2E:** файл в `input/whisper_podlodka/en/` → распознан EN-демоном (английский текст); файл в
  `.../ru/` → RU-демоном; файл без lang → по итогам спайка (fallback whisper auto). Регресс RU-пути.
- Дизайн-гейт после P1: подход к мульти-языку и EN-модели согласован до реализации.

## Risks
- **whisper_podlodka заточен под RU** — EN на нём плохой; нужна отдельная EN-модель. Выбрана
  **`large-v3-turbo`** (меньше RAM/VRAM, быстрее `large-v3`); спайк подтверждает качество EN и замеряет
  память/скорость.
- **Мульти-язык** — whisper мид-файл язык не переключает; настоящий mixed требует VAD+language-ID+
  роутинг по фрагментам (дорого). Спайк определит реальную границу возможностей.
- **Память/порты:** каждый языковой демон — своя модель (~1.6 ГБ) и порт; поднимать по мере надобности.
- **Совместимость:** не сломать существующий плоский `input/<model>/` и RU-поток; языковой уровень —
  аддитивный.
- **Реестр/readiness по языку:** join (model, lang)→daemon + свежесть записи именно языкового демона.

## Steps (mirror the ledger)
- [ ] **LG0.1 — Plan & ledger.**
- [ ] **LG1.1 — Spike + дизайн-гейт.** whisper мульти-язык (auto/per-window/VAD) на смешанном сэмпле;
  проверка EN на **`large-v3-turbo`** (качество + память/скорость) и способа докачки; схема роутинга
  (engine,lang)→daemon и кодирование job. Согласовать с владельцем.
- [ ] **LG2.1 — Директория + роутинг (оркестратор).** Сканер `input/<model>/<lang>/` (+ файл в
  `input/<model>/` = мульти/auto); `lang`→`params.language`; scheduler роутит по (model, lang);
  readiness-gate по языковому демону; тесты + регресс RU.
- [ ] **LG3.1 — Модели + EN-демон.** Расширить скрипт скачивания (манифест язык→модель) + докачать
  EN-модель (`ggml-large-v3-turbo`); config/start-скрипты `whisperdaemon_en`; регистрация в реестре.
- [ ] **LG4.1 — Мульти-язык** по итогам спайка (fallback whisper `auto` или per-fragment routing).
- [ ] **LG5.1 — E2E + docs.** en→EN-демон, ru→RU-демон, multi→по спайку; регресс; ARCHITECTURE.md.

## References
- Drop/registry/readiness: [jobs-drop-daemon-registry-plan.md](jobs-drop-daemon-registry-plan.md)
- Стрим/нарезка: [file-streaming-bridge-plan.md](file-streaming-bridge-plan.md),
  [long-file-chunking-fix-plan.md](long-file-chunking-fix-plan.md)
- Демон: `services/whisperdaemon/app/src/WhisperDaemon.pas`; модели: `services/whisperdaemon/scripts/`
- Методология: `EchoRecorder/METHODOLOGY.md`; Правила Pascal: `EchoRecorder/PASCAL_RULES.md`
