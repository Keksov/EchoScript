# LG1.1 — Спайк: язык оригинала + маршрутизация по языку (дизайн-гейт)

Status: **signed off by owner 2026-07-04** (design gate passed)
Part of: [language-routing-plan.md](language-routing-plan.md) · Ledger: [language-routing-progress.json](language-routing-progress.json)

## Итог дизайн-гейта (решения владельца)
1. **Директория = `engine`:** `input/whisper/<lang>/`; `whisper_podlodka` — легаси-алиас на RU-даймон.
2. **Mixed — ОТКЛОНЯТЬ до P4:** файл прямо в `input/<engine>/` (без lang) НЕ берётся в работу (лог +
   не-роутится), пока P4 не сделает per-fragment. **Никакого `auto`-фолбэка** (не плодим битые
   результаты). Отменяет промежуточную рекомендацию Q1 ниже.
3. **turbo = f16 (~1.6 ГБ)** (не квант).

Спайк отвечает на три вопроса P1 и предлагает дизайн к реализации в P2/P3. Всё обосновано кодом и
семантикой whisper.cpp; живые прогоны (EN на turbo, смешанный сэмпл) вынесены в P3/P4/E2E, т.к.
turbo-модель ещё не скачана, а прогон EN на RU-подлодке дал бы мусор и не проверил бы тезис.

---

## Вопрос 1 — Умеет ли whisper сам мульти-язык в одном файле?

**Короткий ответ: нет, не в одном проходе.** Whisper (и whisper.cpp) детектит язык **один раз** —
по первому ~30-сек окну — и транскрибирует **весь файл** как этот язык. Мид-файл переключения языка
в одном `whisper_full` нет.

Обосновано кодом даймона:
- [WhisperDaemon.pas:1442-1449](../../services/whisperdaemon/app/src/WhisperDaemon.pas#L1442-L1449):
  `language='auto'` → `ctxParams.language := 'auto'`, `detectLanguage := False` (флаг «детект без
  транскрипции» намеренно не ставим), `translate := False` (транскрипция в исходном языке, не перевод).
- [WhisperDaemon.pas:1458-1463](../../services/whisperdaemon/app/src/WhisperDaemon.pas#L1458-L1463):
  при `auto` берётся **один** `resolveDetectedLanguageCode(state)` на всю сессию → `FresolvedLanguage`.
- Архитектурно `whisper_full` — единый greedy/beam проход с одним language-token в начале; сегментные
  языки он не выдаёт.

**Следствия для `input/<engine>/` без языкового подкаталога (mixed):**
- Дешёвый интер-фолбэк — `auto`: получится **доминирующий** язык на весь файл (для не-доминирующих
  кусков — брак). Годится как временное поведение.
- Настоящий mixed требует пайплайна **VAD → language-ID по фрагменту → роутинг фрагмента в нужный
  языковой даймон → сшивка**. Это отдельная работа (P4), дорогая; whisper.cpp «из коробки» её не даёт.
- Промежуточный компромисс (тоже P4): нарезать по нашему chunking-у (у нас уже есть посекундная
  нарезка на сессии-чанки, [long-file-chunking-fix-plan.md](long-file-chunking-fix-plan.md)) и на
  каждом чанке звать `auto` — язык детектится per-chunk (грубее VAD, но без новой инфраструктуры).

**Рекомендация по вопросу 1:** для P2 mixed-файл (`input/<engine>/` без lang) → `auto` (single-language
fallback, честно логируем `detected_language`). Полноценный per-fragment mixed — в P4, с выбором между
per-chunk `auto` и VAD+language-ID (замер качества на реальном mixed-сэмпле — там же).

---

## Вопрос 2 — EN на `large-v3-turbo`: артефакт, память, скачивание

**Модель:** `ggml-large-v3-turbo` (официальная whisper.cpp-сборка, multilingual, 809M параметров,
**4 слоя декодера** вместо 32 → сильно быстрее декодинг; оптимизирована под транскрипцию, EN — хорошо).

**Память/диск (ggml f16):**
| Модель | ggml f16 на диске | ~RAM в работе |
|---|---|---|
| `large-v3` (full) | ~3.1 ГБ | ~3.3+ ГБ |
| **`large-v3-turbo`** | **~1.6 ГБ** | **~1.5–1.7 ГБ** |
| `large-v3-turbo-q5_0` (квант) | ~0.57 ГБ | ~0.7 ГБ |
| `large-v3-turbo-q8_0` (квант) | ~0.87 ГБ | ~1.0 ГБ |

Т.е. turbo ≈ **вдвое** легче large-v3 (не «чуть», но в нужную сторону). Для сопоставимости с подлодкой
(RU ggml ~1.6 ГБ) берём **f16 turbo** (без кванта) — одинаковый порядок памяти, лучшее качество.
Кванты держим в запасе, если упрёмся в память при двух живых даймонах.

**Скачивание:** сейчас стейджинг подлодки — это **локальная копия** уже сконвертированного ggml
([stage_whisperdaemon_model.bat](../../services/whisperdaemon/scripts/stage_whisperdaemon_model.bat)),
сети нет. Для turbo нужен **download** официального артефакта из HuggingFace `ggerganov/whisper.cpp`
(`resolve/main/ggml-large-v3-turbo.bin`) → сохранить под именем, которого ждёт даймон.

**Имя файла модели.** Даймон резолвит `ggml-<model-name>.bin`
([WhisperDaemon.pas:564](../../services/whisperdaemon/app/src/WhisperDaemon.pas#L564)). Предлагаю
`model_name = whisper_en_turbo` → файл `services/whisperdaemon/models/ggml-whisper_en_turbo.bin`.

**Рекомендация по вопросу 2:** докачивать `ggml-large-v3-turbo` (f16) → `ggml-whisper_en_turbo.bin`;
качество EN и реальный расход памяти замерить в P3 при подъёме `whisperdaemon_en` (живой load-test).

---

## Вопрос 3 — Схема роутинга `(engine, language) → daemon` и кодирование job

### Как устроен пайплайн сейчас (всё крутится вокруг `model_name`)
`input/<model>/` → `createDroppedJob` → jobId `<ts>_<uuid>_<model>_<stem>` →
`getModelFromJobId` → `findWsDaemonForModel(model)` (по `ws_daemons[].model_name`) →
`daemonRegistry.readyForModel(model)` (readiness-gate). Язык — независимо, из `params.language`.

### Рекомендуемый дизайн (минимальное вмешательство): **резолвить язык в конкретную модель на интейке**

Ключевая идея: языковой подкаталог превращается в **конкретную модель уже при приёме файла**, поэтому
весь низлежащий пайплайн (jobId, `getModelFromJobId`, роутинг по `model_name`, реестр, readiness-gate)
**остаётся без изменений**. Новая логика — только в сканере интейка + одна таблица в конфиге.

- **Директория:** `input/<engine>/<lang>/` где `<engine>` = семейство распознавания (`whisper`),
  `<lang>` ∈ {`ru`, `en`, …}. Файл прямо в `input/<engine>/` (без lang) = mixed/`auto`.
- **Конфиг — единый источник истины.** Расширяем записи `ws_daemons` полями `engine` и `language`:
  ```json
  "ws_daemons": {
    "whisperdaemon":    { "host":"127.0.0.1","port":7801,"engine":"whisper","language":"ru","model_name":"whisper_podlodka" },
    "whisperdaemon_en": { "host":"127.0.0.1","port":7802,"engine":"whisper","language":"en","model_name":"whisper_en_turbo" }
  }
  ```
  Из них строится обратная карта `(engine, language) → model_name`.
- **Интейк** (`input-drop`): `input/whisper/en/foo.flac` → `(whisper, en)` → `model_name=whisper_en_turbo`
  → `createDroppedJob(model=whisper_en_turbo, params.language="en")`. Дальше — как обычно.
- **Роутинг/реестр/readiness — БЕЗ изменений:** job уже несёт конкретную модель, `findWsDaemonForModel`
  и `readyForModel` работают как есть; readiness-gate автоматически «на язык», т.к. модель язык-специфична.
- **Обратная совместимость (LG-D7):** если сегмент-1 совпадает с известным `model_name` (легаси
  `input/whisper_podlodka/…`, плоско) — берём модель как есть (язык по умолчанию `ru`). Различаем по
  тому, известен ли сегмент-1 как `engine` (тогда сегмент-2 = язык) или как `model_name` (тогда плоско).
- **Mixed (`input/whisper/` без lang):** резолвим в назначенную «mixed/auto» модель движка (в P2 —
  дефолтный языковой даймон движка с `params.language="auto"`; полноценный per-fragment — P4).

**Почему не «тащить (engine, language) через весь роутинг»:** это второй, тяжёлый вариант (менять jobId,
`getModelFromJobId`, `findWsDaemonForModel`, реестр — join по паре). Даёт то же самое, но большой blast
radius. Резолв-на-интейке достигает цели LG-D2 добавочно и локально — предпочтительно.

**Кодирование job:** jobId остаётся `<ts>_<uuid>_<model>_<stem>` (model = уже разрезолвленная
конкретная модель). Язык пишем в `params.json.language` (и дублируем в `input.json` как исходный
`requested_language`/`engine` для трассировки). `ws-daemon-runner.extractLanguage` уже прокидывает
`params.language` → `session_start.language` — без изменений.

**Рекомендация по вопросу 3:** дизайн «резолв (engine,lang)→model на интейке»; `ws_daemons` расширяем
`engine`+`language`; RU-легаси-путь сохраняем алиасом сегмента-1 = `model_name`.

---

## Открытые решения для владельца (дизайн-гейт)
1. **Имя сегмента-1 директории.** Рекомендую `engine` = `whisper` (папки `input/whisper/en|ru/`), а
   `whisper_podlodka` оставить как легаси-алиас на RU-даймон.
   *Альтернатива:* оставить `whisper_podlodka` первым сегментом и не вводить «engine» — тогда EN-файлы
   кладутся в отдельную верхнюю папку `input/whisper_en_turbo/…`, а `<lang>`-подкаталог избыточен.
   Рекомендация — `engine`, т.к. именно она реализует «выбираю язык подпапкой, система сама берёт модель».
2. **Mixed-поведение в P2 (временное).** `auto` = доминирующий язык на весь файл — ОК как заглушка до
   P4? (иначе — отвергать mixed до готовности P4).
3. **Turbo f16 vs квант.** Рекомендую f16 (память как у подлодки, лучшее качество); квант — если два
   живых даймона не влезут в память.

## Влияние на план
- P2 реализует резолв-на-интейке + расширение `ws_daemons` (`engine`,`language`) + тесты; роутинг/реестр
  не трогаем (подтверждено спайком).
- P3: download-манифест язык→модель + докачка `ggml-large-v3-turbo`→`ggml-whisper_en_turbo.bin` +
  `whisperdaemon_en` (порт 7802) + регистрация; там же живой замер EN/памяти.
- P4: mixed per-fragment (per-chunk `auto` vs VAD+language-ID) + замер на реальном mixed-сэмпле.
