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
