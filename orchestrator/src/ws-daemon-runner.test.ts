import { test, expect } from "bun:test";
import { tmpdir } from "node:os";
import path from "node:path";
import { mkdtemp, mkdir, rm, writeFile, readFile } from "node:fs/promises";

import { runWsDaemonJob } from "./ws-daemon-runner";
import type { DaemonTranscription } from "./daemon-driver";
import type { WsDaemonConfig } from "./config";

const endpoint: WsDaemonConfig = { host: "127.0.0.1", port: 9, modelName: "whisperdaemon" };

const cannedTranscription: DaemonTranscription = {
  text: "привет мир",
  language: "ru",
  detectedLanguage: null,
  durationMs: 1800,
  segmentCount: 2,
  segments: [
    { segmentId: 0, text: "привет", startMs: 0, endMs: 1000 },
    { segmentId: 1, text: "мир", startMs: 1000, endMs: 1800 },
  ],
  words: [{ text: "привет", segmentId: 0, indexInSegment: 0, startMs: 0, endMs: 1000, confidence: 0.9 }],
};

const fakeConvert = async (_ffmpeg: string, _input: string, output: string) => {
  await writeFile(output, Buffer.alloc(4));
  return { outputPath: output, byteLength: 4, sampleCount: 2 };
};

const setupJob = async (params: Record<string, unknown>) => {
  const base = await mkdtemp(path.join(tmpdir(), "wsjob-"));
  const jobId = "1_abc_whisperdaemon";
  const dataDir = path.join(base, "data", jobId);
  const outputDir = path.join(base, "output");
  await mkdir(dataDir, { recursive: true });
  await mkdir(outputDir, { recursive: true });
  await writeFile(path.join(dataDir, "input"), Buffer.alloc(8));
  await writeFile(path.join(dataDir, "params.json"), JSON.stringify(params));
  return { base, jobId, dataDir, outputDir };
};

test("runWsDaemonJob writes result artifacts, status transitions and ready marker", async () => {
  const { base, jobId, dataDir, outputDir } = await setupJob({ language: "ru", word_timestamps: true });
  try {
    const status = await runWsDaemonJob(jobId, dataDir, outputDir, {
      ffmpegPath: "unused",
      endpoint,
      convert: fakeConvert,
      transcribe: async () => cannedTranscription,
    });
    expect(status).toBe("ready");

    const result = JSON.parse(await readFile(path.join(dataDir, "result.json"), "utf-8"));
    expect(result.normalized.text).toBe("привет мир");
    expect(result.normalized.language).toBe("ru");
    expect(result.normalized.segments).toHaveLength(2);
    expect(result.normalized.segments[0].start).toBe(0);
    expect(result.normalized.segments[0].end).toBe(1);
    expect(result.normalized.segments[1].end).toBeCloseTo(1.8, 5);
    expect(result.normalized.segments[0].words).toHaveLength(1);
    expect(result.normalized.segments[1].words).toHaveLength(0);

    const plain = await readFile(path.join(dataDir, "result_plain.txt"), "utf-8");
    expect(plain).toBe("привет мир\n");

    const timestamp = await readFile(path.join(dataDir, "result_timestamp.txt"), "utf-8");
    expect(timestamp).toBe("[00:00:00.000 --> 00:00:01.000]  привет\n[00:00:01.000 --> 00:00:01.800]  мир\n");

    const statuses = JSON.parse(await readFile(path.join(dataDir, "status.json"), "utf-8"));
    expect(statuses.map((s: { status: string }) => s.status)).toEqual(["processing", "ready"]);

    const marker = JSON.parse(await readFile(path.join(outputDir, `${jobId}.json`), "utf-8"));
    expect(marker.status).toBe("ready");
  } finally {
    await rm(base, { recursive: true, force: true });
  }
});

test("runWsDaemonJob writes progress.json from streaming progress and finalizes at 100%", async () => {
  const { base, jobId, dataDir, outputDir } = await setupJob({ language: "ru" });
  try {
    const status = await runWsDaemonJob(jobId, dataDir, outputDir, {
      ffmpegPath: "unused",
      endpoint,
      convert: fakeConvert,
      transcribe: async (_ep, _pcm, _opts, onProgress) => {
        onProgress?.({ windowsSent: 1, windowsTotal: 4, bytesSent: 1000, bytesTotal: 4000, processedMs: 500, totalMs: 2000, progressPct: 25 });
        onProgress?.({ windowsSent: 4, windowsTotal: 4, bytesSent: 4000, bytesTotal: 4000, processedMs: 1500, totalMs: 2000, progressPct: 75 });
        return cannedTranscription;
      },
    });
    expect(status).toBe("ready");

    const progress = JSON.parse(await readFile(path.join(dataDir, "progress.json"), "utf-8"));
    expect(progress.progress_pct).toBe(100);
    expect(progress.windows_done).toBe(4);
    expect(progress.windows_total).toBe(4);
    expect(progress.total_ms).toBe(2000);
    expect(typeof progress.updated_at).toBe("string");
  } finally {
    await rm(base, { recursive: true, force: true });
  }
});

test("runWsDaemonJob records failure and failed marker when the daemon errors", async () => {
  const { base, jobId, dataDir, outputDir } = await setupJob({ language: "ru" });
  try {
    const status = await runWsDaemonJob(jobId, dataDir, outputDir, {
      ffmpegPath: "unused",
      endpoint,
      convert: fakeConvert,
      transcribe: async () => {
        throw new Error("daemon unreachable");
      },
    });
    expect(status).toBe("failed");

    const statuses = JSON.parse(await readFile(path.join(dataDir, "status.json"), "utf-8"));
    const last = statuses[statuses.length - 1];
    expect(last.status).toBe("failed");
    expect(last.error).toContain("daemon unreachable");

    const marker = JSON.parse(await readFile(path.join(outputDir, `${jobId}.json`), "utf-8"));
    expect(marker.status).toBe("failed");
  } finally {
    await rm(base, { recursive: true, force: true });
  }
});
