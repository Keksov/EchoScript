# diarization-engine — план

## Цель

Сделать диаризационный **sherpa**-демон управляемым из echoctl и панели — как полноценный
третий движок (`diarization`) рядом с whisper/vosk: `daemons add/list/start/stop/edit`,
настройки, появление в UI. Движок — **зонтик**: сейчас единственная модель `diarization_sherpa`
(бэкенд sherpa-onnx), в дальнейшем под тем же движком могут появиться другие бэкенды
(конвенция имён `diarization_*`, по образцу `whisper_*`/`vosk_*`).

## Почему сейчас не видно

Панель — тонкая обёртка над echoctl, а echoctl знает только whisper/vosk. У diarization нет
веток в `isKnownEngine`, `enginePortRange`, `daemonExePath`, `daemonLogDir`, `buildDaemonArgs`,
`buildDaemonEnv`, `echoctl_schema`. В `config.json` нет инстанса. В `DaemonForm.vue`
`engineOptions` жёстко `[whisper, vosk]`. В `models-manifest.json` запись diarization есть
(`kind:diarization`), но **без `model_name`** → её нет в дропдауне моделей UI и не с чем связать инстанс.

## Форма демона (факт из скриптов + argparse DiarizationDaemon.pas)

- Аргументы: `--host --port --sherpa-dll` (+ опц. `--seg-model --emb-model --num-speakers
  --cluster-threshold --min-duration-on --min-duration-off`); всё дублируется env
  `SHERPA_DLL_PATH`, `DIARIZE_SEG_MODEL/EMB_MODEL`, `DIARIZE_NUM_SPEAKERS/CLUSTER_THRESHOLD/
  MIN_DURATION_ON/MIN_DURATION_OFF`.
- Порт по умолчанию **7900**; **нет `--model-name`** (модели — две ONNX, из дефолтов/путей).
- Готовность — тот же маркер `warmup ready` ⇒ `waitWarmup` без изменений.
- Перед стартом run-скрипт **стейджит ORT DLL** (`onnxruntime.dll` + `onnxruntime_providers_shared.dll`
  → `build/x64`) — обязательно, иначе демон не грузится.
- Реальные пути демона: `services/diarizationdaemon/sherpa/{build/x64,vendors/sherpa-onnx,models,logs}`
  (манифест сейчас ссылается на устаревшие `services/whisperdaemon/...` — почистить в DZ1.3).

## Решения

- **DZ-D1** diarization — движок-зонтик; модель `diarization_sherpa`; конвенция `diarization_*`;
  расширяемо под будущие бэкенды. (владелец)
- **DZ-D2** модель — через `models-manifest.json` (добавить `model_name: "diarization_sherpa"`
  в существующую запись `kind:diarization`); `modelKnown` расширить на манифест (в русле пометки
  DF2.1 «расширит проверку манифестом») — детали в DZ1.3.
- **DZ-D3** порт-диапазон diarization **7900–7999**.
- **DZ-D4** launch: `--host --port --sherpa-dll <diarizationdaemon/sherpa/vendors/sherpa-onnx/sherpa-onnx.dll>`;
  seg/emb через env `DIARIZE_SEG_MODEL/EMB_MODEL` → `services/diarizationdaemon/sherpa/models/*.onnx`.
- **DZ-D5** перед spawn стейджить ORT DLL (как run-скрипт) — иначе не грузится.
- **DZ-D6** маркер `warmup ready` без изменений; dev-tail (уже на master) даёт echotail-вкладку
  автоматически (generic путь `runDaemonsStart`).
- **DZ-D7** настройки diarization (num_speakers, cluster_threshold, min_duration_on/off) в схеме
  **и форме сразу** (паритет с vad-настройками whisper). (владелец)
- **DZ-D8** diarization language-agnostic — `language` необязателен (пустой) в инстансе/форме.

## Фазы (пауза на границах)

- **P0** План + леджер — gate: план/решения, DAG ацикличен.
- **P1** echoctl-движок diarization — gate: `daemons add --engine diarization` не отклоняется;
  сборка зелёная; args/env/ORT-стейджинг/схема готовы.
- **P2** echoctl E2E — gate: add → start (warmup ready, без окна) → stop; `config set` round-trip.
- **P3** UI — gate: diarization в форме, модель `diarization_sherpa` выбирается, поля настроек, i18n en/ru.
- **P4** E2E полный + docs — gate: панель(dev) → add+start diarization → появляется + warmup +
  echotail-вкладка; стоп; docs.

## Конвенции

FPC по лекалу echoctl (движковые ветки в тех же функциях, что whisper/vosk). Демон везде без окна.
echoctl — единственный писатель config.json. PASCAL_RULES соблюдаем. Ветка `feature/diarization-engine`
от master (dev-tail уже влит). Один шаг → один коммит → один гейт.
