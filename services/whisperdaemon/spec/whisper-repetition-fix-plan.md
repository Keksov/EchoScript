# Повторяющиеся фразы в тексте: петля декодера whisper на не-речи

Status: **active**
Created: 2026-07-05
Branch: `fix/whisper-repetition` (от `feature/language-routing` — нужен EN-конфиг из P3 для воспроизведения)
Authoritative progress ledger: [whisper-repetition-progress.json](whisper-repetition-progress.json)

## Goal
Убрать многократные повторы фраз в готовом тексте на аудио с музыкой/тишиной (медитация CD4):
напр. `You are the number one in your mind.` ×27, `Thank you.` ×54, `Move through now…` ×17.
Ответить владельцу: **это ошибка whisper или мы re-шлём один и тот же аудио-сегмент?**

## Предварительный ответ (из наблюдений на CD4 EN)
**Это whisper (петля декодера / галлюцинация на не-речи), НЕ повторная отправка аудио.** Доказательства:
- `result_timestamp.txt`: `You are the number one in your mind.` — **27 сегментов подряд** с **непрерывно
  нарастающими** таймингами `00:37:00 → 00:37:54` (каждый конец = начало следующего), всё в **одном**
  чанке (чанк 19, 36–38 мин).
- Буферизованный режим (`auto_flush=false`, LF4.1) = **один** `whisper_full` на чанк → 27 повторов
  сгенерированы **внутри одного инференса**, а не re-send. При re-send были бы **совпадающие/наложенные**
  тайминги или буфер длиннее чанка — таких признаков нет.
- `Thank you.` ×54 и `*Painful music*` — классические галлюцинации whisper на не-речевых участках.
- Демон **не задаёт явно** анти-галлюцинационные пороги whisper — берёт дефолты DLL
  ([WhisperDaemon.pas:1420-1454](../app/src/WhisperDaemon.pas#L1420-L1454)).

Фаза 1 подтверждает это **строго** (аудит пампа/оффсетов чанков + аудит параметров/версии DLL) и
выбирает митигацию на дизайн-гейте.

## Decisions
- **WR-D1 (по фактам) — Причина: петля декодера whisper на не-речи**, не re-send аудио. Признак:
  N подряд одинаковых сегментов с монотонно растущими таймингами внутри одного чанка (1 инференс/чанк).
- **WR-D2 (подтвердить в P1)** — аудит нарезки: `daemon-stream-driver` пампит без перекрытия/повтора
  (оффсеты чанков не пересекаются); аудит `WhisperDaemon.pas`: какие поля `TWhisperFullParams` доступны
  в текущей связке DLL (`no_speech_thold`, `entropy_thold`, `logprob_thold`, `temperature`/fallback,
  `suppress_nst`, поля VAD) и какая версия whisper.cpp.
- **WR-D3 (дизайн-гейт)** — выбор митигаций:
  - **A. whisper-параметры**: включить temperature-fallback + пороги `entropy_thold`/`logprob_thold`/
    `no_speech_thold` + `suppress_nst` — чтобы декодер срывал петли и пропускал не-речь.
  - **B. VAD**: убирать не-речь ДО инференса — встроенный VAD whisper.cpp (Silero ggml) либо префильтр
    через уже имеющиеся sherpa-onnx VAD/segmentation-ассеты.
  - **C. Post-dedup (оркестратор)**: схлопывать подряд идущие одинаковые сегменты — дешёвая страховка
    читабельности (не лечит причину, но чистит вывод).
  Предполагаемо **A + C**, **B** если A недостаточно. Точный набор фиксируется на гейте после аудита P1.
- **WR-D4 — Аддитивно, без регресса** на чистой речи (img8726 RU, чистый EN распознаются как сейчас);
  правки минимальны; агрессивные пороги/VAD — под проверкой на over-suppression.

## Acceptance / gates
- **CD4 EN**: повторы (`number one`, `Thank you.`, `Move through…`) устранены или схлопнуты; связная
  речь сохранена (напр. «In this exercise you may have the experience of graduating…» остаётся).
- **Регресс**: чистая речь (img8726 RU, чистый EN-сэмпл) распознаётся без деградации / потери речи.
- Демон пересобирается (`build_whisperdaemon.bat`) зелёно; если задействован оркестратор (C) — `bun test`
  зелёный.
- **Дизайн-гейт после P1**: причина подтверждена, набор митигаций (A/B/C) согласован до реализации.

## Risks
- **Версия whisper.cpp / DLL** может не иметь части параметров или VAD → аудит в P1; при отсутствии —
  VAD-префильтр через sherpa (ассеты есть) или ограничиться A+C.
- **Over-suppression**: агрессивный `no_speech_thold`/VAD может резать тихую настоящую речь (медитация —
  тихая) → обязательный регресс-гейт на чистой/тихой речи.
- **Пересборка Pascal-демона** (см. `EchoRecorder/PASCAL_RULES.md`) — риск сборки на Windows; менять
  минимально и точечно.
- Петля может быть чувствительна к beam vs greedy и `temperature_inc` — проверить оба пути (обычный и
  safeMode) в демоне.

## Steps (mirror the ledger)
- [ ] **WR0.1 — Plan & ledger.**
- [ ] **WR1.1 — Диагностика + дизайн-гейт.** Строго подтвердить причину: (1) timestamp/паттерн-анализ
  результата CD4 [сделано предварительно]; (2) аудит `daemon-stream-driver` пампа/оффсетов — исключить
  перекрытие/re-send; (3) аудит `WhisperDaemon.pas` + версии DLL — доступные анти-репетишн параметры и
  VAD. Выбрать набор митигаций (A/B/C). Согласовать с владельцем.
- [ ] **WR2.1 — Демон: анти-репетишн параметры (и/или VAD).** Задать в `WhisperDaemon.pas` пороги/
  fallback/`suppress_nst` (и VAD по гейту); пересборка; прогон CD4-чанка с повтором.
- [ ] **WR3.1 — Оркестратор: post-dedup (по гейту).** Схлопывать подряд идущие идентичные сегменты в
  сборке результата (`ws-daemon-runner`/нормализация) + тесты.
- [ ] **WR4.1 — Валидация + docs.** CD4 EN повторы ушли/резко меньше; регресс чистой/тихой речи; заметка
  в ARCHITECTURE.md/спеке.

## References
- Whisper single-pass/детект: [../../../orchestrator/spec/language-routing-spike.md](../../../orchestrator/spec/language-routing-spike.md)
- Буфер-режим/нарезка: [../../../orchestrator/spec/long-file-chunking-fix-plan.md](../../../orchestrator/spec/long-file-chunking-fix-plan.md)
- Демон: [../app/src/WhisperDaemon.pas](../app/src/WhisperDaemon.pas); правила Pascal: `EchoRecorder/PASCAL_RULES.md`
- VAD-ассеты (sherpa) уже в репо: `services/whisperdaemon/models/diarization/`
- Улика: `jobs/data/1783185014758_..._whisper_en_turbo_cd4-8-the-absolute/result_timestamp.txt`
