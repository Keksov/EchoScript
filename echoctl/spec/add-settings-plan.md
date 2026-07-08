# add-settings — план

## Цель

`echoctl daemons add` должен принимать `--set ключ=значение` и применять настройки **при
создании** инстанса (с той же валидацией, что `edit`). Тогда форма панели, которая шлёт
settings при добавлении, перестаёт их терять.

## Проблема (подтверждено)

`doDaemonsAdd` (echoctl.pas) не читает `--set` — собирает только engine/model/host/lang/name/port;
`runDaemonsAdd` строит инстанс без `settings`. Проверено на throwaway-конфиге:

```
add  --set vad=false  ->  settings = None       (флаг проглочен)
edit --set vad=false  ->  settings = {vad:false} (применяется)
```

Касается ВСЕХ движков (whisper/vosk/diarization), предсуществующее.

## Подход

Переиспользовать существующий `applySet(inst, engine, "k=v", err)` (валидирует ключ по
`findSettingSpec`, парсит значение, пишет в `settings`) — он уже используется в `runDaemonsEdit`.

- `applySet` определён (стр. 367) ПОСЛЕ `runDaemonsAdd` (стр. 244) → **forward-декларация** перед
  runDaemonsAdd (минимальный диф, без перемещения кода).
- `runDaemonsAdd` получает параметр `const aSets: array of string`; цикл `applySet` — **после**
  `ws.Add(name, inst)` (тогда config владеет inst → нет утечки при `Exit(fail)` на плохом --set).
- `doDaemonsAdd` (echoctl.pas) прокидывает уже существующий `collectSets` (как doDaemonsEdit).

## Решения

- **AS-D1** переиспользовать `applySet` (единая валидация add/edit); forward-декларация;
  применять после `ws.Add` (без утечки inst на ошибке).
- **AS-D2** фикс для всех движков (не только diarization); поведение `edit` не трогаем.

## Фазы

- **P0** План + леджер — gate: DAG ацикличен.
- **P1** Фикс + тесты — gate: `add --set k=v` пишет валидированные settings; плохой `--set` →
  ошибка + инстанс не создан; регрессия — `add` без `--set` как прежде; UI-путь (панель add с
  настройками) сохраняет их.

## Конвенции

FPC по лекалу echoctl. Один шаг → один коммит → один гейт. Ветка `feature/add-settings` от master.
