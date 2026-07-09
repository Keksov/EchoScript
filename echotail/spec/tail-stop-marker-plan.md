# tail-stop-marker — план

## Проблема

Stop демона (UI/echoctl) = жёсткий `TerminateProcess`: демон умирает молча, лог перестаёт
расти. echotail-вкладка остаётся открытой (так решено, DT-D6), но в ней **нет никакой
информации, что демон завершился** — выглядит как живой демон, который просто молчит.

## Решение

echotail получает `--watch-port N` и следит за состоянием порта демона:

- проверка «кто-то слушает порт N» — через **GetExtendedTcpTable** (как DC1.1), БЕЗ
  подключений к порту: connect-проба заставляла бы демона логировать connected/disconnected
  каждые ~2с — мусор в том самом логе, который вкладка показывает;
- переходы состояния печатаются в вкладку (в stdout, НЕ в лог демона):
  - open → closed: 🔴 `[echotail] daemon stopped (port N no longer listening)`
  - unknown/closed → open: 🟢 `[echotail] daemon listening on port N` (бонус: виден момент
    готовности при прогреве и рестарте демона при живой вкладке);
- начальное состояние unknown → маркер «stopped» только после реально виденного open
  (вкладка, открытая до прогрева, не врёт «stopped»);
- период проверки ~2с (poll-цикл echotail 250мс, проверка по GetTickCount64).

Порт передают все, кто открывает вкладку:
- echoctl `openLogTab(..., aPort)` — start (woReady), already-running, `daemons tabs`;
- `scripts/launch_tab.ps1` — у него уже есть `-WaitPort`.

## Решения

- **TS-D1** слежение за портом внутри echotail (`--watch-port`), listen-состояние через
  GetExtendedTcpTable без connect-проб; маркеры в stdout вкладки, лог демона не трогаем.
- **TS-D2** вкладка по-прежнему НЕ закрывается (DT-D6); маркер — информация, не действие.
- **TS-D3** маркеры: stopped → красный, listening → зелёный; уважают --no-color/redirect.

## Фазы

- **P0** План + леджер.
- **P1** echotail `--watch-port` + маркеры — gate: stop демона → красный маркер в выводе;
  старт демона при живом echotail → зелёный маркер; без --watch-port поведение прежнее.
- **P2** Прокидка порта (echoctl openLogTab ×3 + launch_tab.ps1) — gate: стоп через
  echoctl/UI при вкладке из start/tabs/панели → маркер виден; смоуки echotail зелёные.

## Конвенции

FPC по лекалу echotail/echoctl. Один шаг → один коммит → один гейт. Ветка
`feature/tail-stop-marker` от master (daemon-control-fixes влит).
