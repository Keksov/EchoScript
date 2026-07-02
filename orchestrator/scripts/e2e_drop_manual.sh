#!/usr/bin/env bash
# Manual E2E for jobs-drop + daemon-registry (DR5.1). NOT part of `bun test`.
#
# Owner scenario: a file is dropped while the recognition daemon is OFF. The job must
# WAIT (not fail); once the daemon starts and self-registers as ready, it is recognized.
#
# Runs against an ISOLATED jobs root and a short clip, so it never touches the real
# jobs/ or large files. Usage:  bash scripts/e2e_drop_manual.sh [audio] [port]
set -u

ROOT="c:/projects/EchoScript"
ORCH="$ROOT/orchestrator"
FFMPEG="${ECHOSCRIPT_FFMPEG_PATH:-$ROOT/tools/ffmpeg/ffmpeg.exe}"
SRC="${1:-$ROOT/EchoRecorder/tests/Два человека.wav}"
PORT="${2:-3100}"
DPORT=7801
E2E="${E2E_JOBS:-$(mktemp -d)/e2e-jobs}"
IN="$E2E/input/whisper_podlodka"

api() { curl -s --noproxy '*' "http://127.0.0.1:$PORT$1"; }
cleanup() {
  kill "${DAEMON_PID:-0}" "${ORCH_PID:-0}" 2>/dev/null
  sleep 1; rm -rf "$E2E" 2>/dev/null
}
trap cleanup EXIT

rm -rf "$E2E"; mkdir -p "$IN"
echo "[e2e] isolated jobs root: $E2E"

# short clip so CPU inference is quick
"$FFMPEG" -y -v error -i "$SRC" -t 10 "$IN/clip.wav"
echo "[e2e] dropped: $(ls -la "$IN" | tail -1)"
sleep 3   # let mtime settle past drop_stable_ms

echo "[e2e] --- starting orchestrator on :$PORT (daemon OFF) ---"
cd "$ORCH"
ECHOSCRIPT_JOBS_ROOT="$E2E" ECHOSCRIPT_PORT="$PORT" NO_PROXY="127.0.0.1,localhost" \
  bun run src/index.ts >"$E2E/orch.log" 2>&1 &
ORCH_PID=$!
for i in $(seq 1 60); do api /list_jobs >/dev/null 2>&1 && break; sleep 0.5; done

JOB=""
for i in $(seq 1 40); do
  JOB=$(api /list_jobs | grep -oE '"job_id":"[^"]*"' | head -1 | cut -d'"' -f4)
  [ -n "$JOB" ] && break; sleep 0.5
done
echo "[e2e] job id: ${JOB:-<none>}"
[ -z "$JOB" ] && { echo "[e2e] FAIL: drop was not picked up"; exit 1; }

sleep 3
ST1=$(api "/get_job_status?job_id=$JOB")
echo "[e2e] status (daemon OFF): $ST1"
# Held-in-queue by the readiness gate: must be neither failed nor already ready.
if echo "$ST1" | grep -qE '"failed"|"ready"'; then
  echo "[e2e] FAIL: job should be held (queued/waiting) while the daemon is off"; exit 1
fi
echo "[e2e] OK: job held in queue while daemon OFF (not failed)"

echo "[e2e] --- starting whisperdaemon (self-registers ready) ---"
WHISPER_MODELS_ROOT="$ROOT/services/whisperdaemon/models" \
  "$ROOT/services/whisperdaemon/build/x64/WhisperDaemon.exe" \
  --model-name whisper_podlodka --host 127.0.0.1 --port $DPORT --registry-dir "$E2E/registry" \
  >"$E2E/daemon.log" 2>&1 &
DAEMON_PID=$!

FINAL=""
for i in $(seq 1 150); do
  ST=$(api "/get_job_status?job_id=$JOB")
  echo "$ST" | grep -q '"ready"'  && { FINAL="ready";  break; }
  echo "$ST" | grep -q '"failed"' && { FINAL="failed"; break; }
  sleep 2
done
echo "[e2e] final status: $(api "/get_job_status?job_id=$JOB")"
echo "[e2e] result_plain.txt:"; head -c 300 "$E2E/data/$JOB/result_plain.txt" 2>/dev/null; echo
echo "[e2e] RESULT: ${FINAL:-timeout}"
[ "$FINAL" = "ready" ] || exit 1
