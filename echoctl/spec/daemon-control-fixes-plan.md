# daemon-control-fixes — план

Две правки echoctl по итогам живого прогона панели в VS Code-окружении.

## #3 — stop без PowerShell (виснет)

`stopDaemonByPort` глушит демон через `powershell -Command "Get-NetTCPConnection -LocalPort N
-State Listen | Stop-Process"`. В текущей сессии `Get-NetTCPConnection` (CIM-backed) **зависает**
→ `stop`/`restart` висят (проверено: `restart` таймаут 2 мин; прямые PS-команды не отвечают;
`netstat`/сокеты работают). Правка: найти PID слушателя порта через Win-API
`GetExtendedTcpTable` (TCP_TABLE_OWNER_PID_LISTENER) и `TerminateProcess` — в процессе, без
внешних утилит и PowerShell. Пусто на порту = уже остановлен (True).

## #2 — dev-вкладка не открывается из панели

По Start из панели демон поднимается, но `echotail`-вкладки нет (проверено: после Start процесса
`echotail` в системе не было). При этом **прямой** вызов `wt -w 0 new-tab echotail <log>` из shell
поднимает и WindowsTerminal, и echotail. Разница — `openLogTab` запускает `wt` через
`CreateProcess(nil, "\"wt.exe\" …", CREATE_NO_WINDOW)`: прямой запуск app-execution-alias `wt.exe`
из оконно-безголового процесса окно не создаёт. Правка: запускать `wt` через `cmd.exe /c "…"`
(проверенный паттерн DT2.1 + spawnDaemon), без `CREATE_NO_WINDOW` на самом cmd/wt. Диагностику и
проверку делаем ПОСЛЕ #3 (тогда `restart diarization` заново дёрнет openLogTab с гарантированным
ECHOSCRIPT_DEV и можно наблюдать echotail).

Примечание: dev-вкладка — окно **Windows Terminal**, отдельное от терминала VS Code (это ожидаемо;
пользователю показать, что искать отдельное окно WT).

## Решения

- **DC-D1** #3 через Win-API GetExtendedTcpTable + TerminateProcess (без PowerShell/внешних утилит);
  функция в echoctl_launch (там уже Windows), stopDaemonByPort делегирует.
- **DC-D2** #2 — запуск wt через `cmd.exe /c` (как spawnDaemon), диагностика/фикс после #3.

## Фазы

- **P0** План + леджер.
- **P1** #3 stop без PowerShell — gate: stop реального демона закрывает порт без PowerShell; restart не виснет.
- **P2** #2 dev-вкладка из панели — gate: `ECHOSCRIPT_DEV=1 echoctl restart <d>` (и панель) открывает echotail-вкладку (WindowsTerminal + echotail следит за логом).

## Конвенции

FPC по лекалу echoctl. Один шаг → один коммит → один гейт. Ветка `feature/daemon-control-fixes` от master.
