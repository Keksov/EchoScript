# WR1.1 — Диагностика: причина повторов + выбор митигации (дизайн-гейт)

Status: **awaiting owner sign-off** (design gate)
Part of: [whisper-repetition-fix-plan.md](whisper-repetition-fix-plan.md) · Ledger: [whisper-repetition-progress.json](whisper-repetition-progress.json)

## Вывод: это whisper, НЕ re-send (доказано)

### 1. Re-send аудио — ИСКЛЮЧЁН (по коду)
[daemon-stream-driver.ts](../../../orchestrator/src/daemon-stream-driver.ts): `openPcmFile` — один
forward-курсор (`position += bytesRead`, никогда не перечитывает). Общий `source` передаётся во все
чанк-сессии, `state.bytesSent` монотонно растёт, `offsetMs = msForBytes(bytesSent)`, цикл
`more = bytesSent < bytesTotal && bytesSent > bytesBefore`. Каждый байт уходит **ровно один раз**, чанк N+1
стартует ровно там, где кончился чанк N — **без перекрытия**. Плюс буфер-режим (`auto_flush=false`) =
**один `whisper_full` на чанк**. → повтор физически не может быть re-send.

### 2. Причина — авторегрессионная петля декодера whisper на не-речи
`result_timestamp.txt` CD4: `You are the number one in your mind.` ×27 подряд, тайминги
`00:37:00 → 00:37:54` непрерывно, всё внутри одного чанка (1 инференс). `Thank you.` ×54,
`*Painful music*` — галлюцинации на музыке/тишине. Классическая seq2seq repetition loop.

### 3. `noContext=True` — ДЕЙСТВУЕТ (ABI выровнен), но не лечит
[WhisperDaemon.pas:1433](../app/src/WhisperDaemon.pas#L1433) ставит `noContext:=True`
(=`condition_on_previous_text=False`, экспертный фикс №1). Record `TWhisperFullParams`
([WhisperDaemon.pas:96-154](../app/src/WhisperDaemon.pas#L96-L154)) — полный современный layout. **ABI
подтверждён косвенно, но надёжно:** поля `language` (стр.124) и колбэки (стр.139), стоящие *после*
`noContext` (стр.103), работают корректно (img8726 → идеальный русский, прогресс/keepalive идут) — при
рассинхроне они были бы сдвинуты и сломаны. → `noContext` доезжает. Но он отключает перенос текста
**между** окнами, а петля возникает **внутри** окна на не-речи (и повторяется в следующем окне
независимо, т.к. аудио там такое же музыкальное). Межоконный off-context тут бессилен.

### 4. Среда: whisper.cpp v1.8.4, VAD доступен, но ВЫКЛючен
DLL по умолчанию — `services/whisperdaemon/releases/1.8.4/whisper.dll`
([WhisperDaemon.pas:432-543](../app/src/WhisperDaemon.pas#L432-L543)). v1.8.4 поддерживает VAD; в
структуре есть `vad`/`vadModelPath`/`vadParams` (стр.151-153) и `TWhisperVadParams` (стр.78-85).
Демон задаёт лишь подмножество полей, остальное — из `gWhisperFullDefaultParams`, где по умолчанию:
`vad=false` (**не-речь скармливается whisper** — вот триггер), `temperature_inc=0.2` (fallback вкл),
`entropy_thold=2.4`, `no_speech_thold=0.6`, `suppress_nst=false`. Дефолтные пороги активны, но на
музыке-героине их **недостаточно** (повторы налицо).

## Итог для гейта
- **Причина:** whisper зацикливается на не-речевых участках; наш пайплайн НЕ виноват (re-send исключён,
  noContext уже включён и работает).
- **Главный рычаг:** **VAD** (вырезать не-речь до инференса) — доступен в v1.8.4, нужен лишь Silero
  ggml-модель + включение `vad:=True; vadModelPath`. Ровно то, что советует эксперт.

## Митигации (рекомендация)
- **B. VAD (whisper.cpp встроенный) — ПРИОРИТЕТ.** Скачать `ggml-silero-v5.1.2.bin` (~1.5 МБ, HF
  ggerganov/whisper.cpp) в манифест; в демоне `vad:=True; vadModelPath:=<silero>`; консервативная
  настройка (`threshold`, `speechPadMs`) против over-suppression тихой речи. Применить к обоим путям
  (beam и safeMode greedy). Пересборка демона.
- **C. Оркестраторный post-dedup — дешёвая страховка.** Схлопывать подряд идущие идентичные сегменты в
  сборке результата (`ws-daemon-runner`) + тесты. Ловит остаточные повторы, улучшает читабельность даже
  если VAD что-то пропустит. Не трогает демон.
- **A. Тюнинг параметров — в резерве.** Явно выставить `noSpeechThold`/`entropyThold`, гарантировать
  `temperatureInc>0`. Дёшево, но вторично (дефолты уже активны и не спасли). Включим при необходимости.

**Рекомендую B + C** (VAD как лечение причины + dedup как страховка); A держим в резерве.

## Риски
- **Over-suppression:** медитация тихая — VAD может срезать настоящую тихую речь. Настраивать
  консервативно (ниже `threshold`, щедрый `speechPadMs`), обязательный регресс на чистой/тихой речи (P4).
- **VAD × нарезка:** VAD применяется на каждый чанк-`whisper_full`; тайминги whisper ремапит к позиции в
  чанке, наш offset-ститчинг должен сохраниться — проверить в P2/P4.
- Пересборка Pascal-демона (PASCAL_RULES.md) — менять точечно.

## P2-находка (2026-07-05): VAD-флаг инертен — нужен рефактор даймона
Поставил `ctxParams.vad:=True; vadModelPath:=<silero>` + консервативные `vadParams`, пересобрал,
прогнал проблемный участок CD4 36:00–38:00 → **петля осталась**, инференс те же 117с (не ускорился),
в stderr **ноль** VAD-строк. Причина (по исходнику whisper.cpp):
- `whisper_full_with_state` (наш вызов, [WhisperDaemon.pas:1454](../app/src/WhisperDaemon.pas#L1454))
  **VAD НЕ делает**. VAD живёт в `whisper_full` (src/whisper.cpp:7749-7763): `if (params.vad) {
  whisper_vad(...); samples = vad_samples; } return whisper_full_with_state(...)`.
- Даймон создаёт контекст `whisper_init_from_file_with_params_no_state`
  ([:908](../app/src/WhisperDaemon.pas#L908)) → `ctx->state == nil`, поэтому используется явный
  `whisper_init_state` + всё `*_from_state`-семейство. `whisper_full` (использует `ctx->state`) в такой
  схеме упадёт.
- Структура `TWhisperFullParams` **совпадает** с whisper.h v1.8.4 поле-в-поле (сверено) — ABI не при чём,
  просто мы не на том пути вызова.

**Следствие:** включить VAD = не флаг, а рефактор:
- **Путь A:** контекст `whisper_init_from_file_with_params` (со state) + вызов `whisper_full` + перейти на
  ctx-аксессоры (`whisper_full_n_segments(ctx)`/`..._get_segment_*`/токены). VAD и ремап таймингов —
  автоматом. Меняет lifecycle контекста + извлечение результата (~import 8 функций + правки).
- **Путь B:** вручную: `whisper_vad_init_from_file_with_params` + `whisper_vad_segments_from_samples`,
  сплайсить речевые сэмплы, **самим ремапить тайминги** обратно на ось чанка, затем существующий
  `whisper_full_with_state`. Извлечение не трогаем, но remap-логика на нас (сложно/хрупко).

**Пороги (A из меню) РАБОТАЮТ** через `with_state` (это decoding-параметры, не gated на `whisper_full`):
`no_speech_thold`/`entropy_thold`/`temperature_inc` доходят до декодера. Дефолты активны, но петлю не
сняли; тюнинг может уменьшить, но не гарантирует.

**Дешёвая и надёжная для видимой проблемы — C (оркестраторный dedup)**: схлопывает 27 повторов в 1 в
готовом тексте, TypeScript+тесты, без пересборки/риска даймона. Не лечит компьют/причину, но снимает
жалобу пользователя.

## Резолюция (WR-D6 → P2/P4): VAD-рефактор (Путь A) — сделано и подтверждено
Владелец выбрал VAD-рефактор. Реализовано (WR2.1): переход с `whisper_full_with_state` на `whisper_full`
+ контекст `whisper_init_from_file_with_params` (со state) + ctx-аксессоры; `vad:=True`, Silero-модель
`ggml-silero-v5.1.2.bin` (в манифесте `download_whisper_models.bat vad`), консервативные `vadParams`
(threshold 0.4, speechPad 200мс). Whisper.cpp сам применяет VAD и ремапит тайминги.

**P4-валидация:**
- **Проблемный участок CD4 36:00–38:00:** `number one` ×27 → **×1**, инференс 117с → **19с**, stderr:
  `Reduced audio … 83.0% reduction`, `time mapping 23 points`.
- **Весь CD4 (E2E через `input/whisper/en/`):** 169 → **39 сегментов, все уникальны (×1)**, `Thank you.`
  ×54 → **0**, `number one` ×27 → **0**; время ~27 мин → **~4 мин** (VAD режет ~81% аудио); текст связный
  («In this exercise you may have the experience of graduating from the earth life…»).
- **Регресс RU (подлодка :7801 на чистой речи img8726):** распознано полностью и связно — рефактор
  with-state не сломал RU, VAD не над-подавляет нормальную/тихую речь.

**Операционно:** демон теперь требует Silero VAD-модель в `services/whisperdaemon/models/` —
`download_whisper_models.bat vad`. Если модели нет или `WHISPER_VAD=0` — VAD выключается gracefully
(демон работает как раньше). VAD активен и для EN, и для RU (общий бинарь).

**C (оркестраторный dedup) — отложен** (WR3.1 deferred): VAD снял причину, дедуп остаётся опциональной
страховкой на будущее.
