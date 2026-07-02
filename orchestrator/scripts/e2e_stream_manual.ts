/**
 * Manual E2E for the streaming file bridge (SB3.2) — NOT part of `bun test`.
 *
 * Requires a live whisperdaemon:
 *   WHISPER_MODELS_ROOT=services/whisperdaemon/models \
 *     services/whisperdaemon/build/x64/WhisperDaemon.exe \
 *     --model-name whisper_podlodka --host 127.0.0.1 --port 7801
 *
 * Run (from orchestrator/):
 *   NO_PROXY=127.0.0.1,localhost bun run scripts/e2e_stream_manual.ts [audio.wav] [port]
 *
 * A small 3s window is used so a short clip still exercises many windows and shows
 * progress climb 0 -> 100. Verifies: incremental segment_final, absolute timestamps
 * spanning the whole clip (daemon cumulative base, SB-D9), progress to 100, no timeout.
 */
import path from "node:path";
import { tmpdir } from "node:os";
import { stat, unlink } from "node:fs/promises";

import { convertToPcm16leMono16k } from "../src/audio-convert";
import { transcribeFileStreaming, bytesForMs, msForBytes } from "../src/daemon-stream-driver";

const wav = process.argv[2] ?? "C:/projects/EchoScript/EchoRecorder/tests/Два человека.wav";
const port = Number(process.argv[3] ?? 7801);
const ffmpeg = process.env.ECHOSCRIPT_FFMPEG_PATH ?? "C:/projects/EchoScript/tools/ffmpeg/ffmpeg.exe";
const pcm = path.join(tmpdir(), `e2e-stream-${crypto.randomUUID()}.pcm`);

const t0 = Date.now();
await convertToPcm16leMono16k(ffmpeg, wav, pcm);
const sz = (await stat(pcm)).size;
console.log("pcm bytes:", sz, "~", (msForBytes(sz) / 1000).toFixed(1), "s audio");

const ticks: number[] = [];
try {
  const result = await transcribeFileStreaming(
    { host: "127.0.0.1", port, modelName: "whisper_podlodka" },
    pcm,
    { windowBytes: bytesForMs(3000), language: "ru", wordTimestamps: true },
    (pr) => {
      if (ticks.length === 0) console.log("windows_total:", pr.windowsTotal);
      ticks.push(Math.round(pr.progressPct));
    },
  );

  console.log("progress ticks:", ticks.join(" "));
  console.log("segments:", result.segments.length, "words:", result.words.length, "durationMs:", result.durationMs);
  console.log("first segment:", JSON.stringify(result.segments[0] ?? null));
  console.log("last  segment:", JSON.stringify(result.segments[result.segments.length - 1] ?? null));
  console.log("text:", result.text.slice(0, 300));
  console.log("elapsed ms:", Date.now() - t0);
} finally {
  await unlink(pcm).catch(() => undefined);
}
