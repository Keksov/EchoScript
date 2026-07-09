# echotail

`echotail` is a tiny FPC console utility that follows a daemon's log file live (`tail -f`),
used in **dev** to show an EchoScript daemon's output in a Windows Terminal tab while the
daemon itself runs **windowless**. It exists so the tail tab is cheap: ~6.5 MB working set
vs ~77.7 MB for `pwsh Get-Content -Wait` (~12× lighter), measured on this repo.

## Why a separate exe

Daemons (whisper/vosk) are launched windowless — by `echoctl` (from the control panel) or by
`launch_tab.ps1` (from the `start_*.bat` scripts) — with stdout+stderr redirected to one
combined log. In dev we open a WT tab that just *watches* that log. Running a full PowerShell
per tab to do so is wasteful; `echotail` is a single small binary that does exactly one thing.

## Usage

```
echotail <logpath> [--tail N] [--title T] [--watch-port N] [--color | --no-color]
```

- `<logpath>` — log file to follow; **waits** for it to appear (poll), so it can be opened
  before the daemon writes its first line.
- `--tail N` — show the last N lines first (default 50).
- `--title T` — set the console/tab title.
- `--watch-port N` — watch the daemon's TCP port (listen-state via `GetExtendedTcpTable`,
  no connect probes) and print markers on transitions: red `daemon stopped (port N no
  longer listening)`, green `daemon listening on port N`.
- `--color` / `--no-color` — force/disable ANSI colouring. Default: **on** for a console,
  **off** when redirected to a file/pipe.
- `--help` | `--version`.

## Behaviour

- **Follow**: prints the last N lines, then appended lines as the file grows (poll 250 ms,
  shared read so it never blocks the daemon writing).
- **Rotation**: if the file shrinks (truncated/rotated) it re-reads from the start.
- **UTF-8**: raw bytes are written straight through with `SetConsoleOutputCP(65001)`, so
  Cyrillic in logs stays intact (no FPC re-encoding).
- **Colour**: lines matching `error`/`fail`/`exception`/`fatal` → red;
  `warmup ready`/`listening`/`ready`/`started` → green; everything else plain. Partial
  (unterminated) lines are buffered until their newline arrives.
- The process just follows a file — it **outlives the daemon**: when the daemon stops, the
  log stops growing and the tab stays open until you close it (with `--watch-port` it also
  says so).
- **Tab reuse**: echotail publishes a named mutex derived from the log path
  (`echotail-tab-<normalized path>`); `echoctl`/`launch_tab.ps1` check it and skip opening a
  duplicate tab while one is already following the log (one tab per daemon; the algorithm is
  mirrored in `echoctl_launch.pas` and `launch_tab.ps1`).

## Where it's used (dev-tail)

The daemon always runs windowless; `echotail` is the live-log viewer in a WT tab.

- **From the control panel / `echoctl`**: when `ECHOSCRIPT_DEV=1` (the panel/orchestrator
  `dev` scripts set it; `Bun.spawn` passes it through to `echoctl`) and `wt.exe` is present,
  `echoctl daemons start` opens `wt -w 0 new-tab echotail <log>` once the daemon reaches
  `warmup ready`. `start` (prod) opens no tab. See `echoctl/src/echoctl_launch.pas`
  (`devTailEnabled` / `openLogTab`).
- **From the `start_*.bat` scripts**: `scripts/launch_tab.ps1` starts the daemon windowless
  (combined log) and, when `wt.exe` + `echotail.exe` are present, opens the echotail tab on
  that log. `WT_TABS=0`, no `wt.exe`, or an unbuilt `echotail` falls back to a minimized
  daemon window.

## Build

```bat
echotail\scripts\build_x64.bat          REM -> echotail\build\x64\echotail.exe
echotail\scripts\smoke_x64.bat          REM version/help/usage exit codes
echotail\scripts\smoke_follow_x64.bat   REM live follow + colour on a growing file
```

Built with the vendored FPC in `EchoRecorder/VendorsCore` (same toolchain as the daemons and
`echoctl`). `build/` is git-ignored.
