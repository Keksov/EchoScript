import { test, expect } from "bun:test";
import { tmpdir } from "node:os";
import path from "node:path";
import { mkdtemp, rm } from "node:fs/promises";

import { loadConfig } from "./config";
import { convertToPcm16leMono16k, PCM_SAMPLE_RATE_HZ } from "./audio-convert";

test("convertToPcm16leMono16k downmixes and resamples to pcm16le 16k mono", async () => {
  const config = await loadConfig();
  const dir = await mkdtemp(path.join(tmpdir(), "ffconv-"));
  const srcPath = path.join(dir, "src.wav");
  const outPath = path.join(dir, "out.pcm");

  try {
    // Deterministic fixture: 2s 440Hz sine, stereo, 44100 Hz -> exercises downmix + resample.
    const gen = Bun.spawn({
      cmd: [
        config.ffmpegPath,
        "-hide_banner", "-loglevel", "error", "-y",
        "-f", "lavfi", "-i", "sine=frequency=440:duration=2",
        "-ac", "2", "-ar", "44100",
        srcPath,
      ],
      stdin: "ignore", stdout: "ignore", stderr: "pipe",
    });
    const genErr = await new Response(gen.stderr).text();
    expect(await gen.exited).toBe(0);
    if (genErr.trim().length > 0) console.warn("ffmpeg gen stderr:", genErr.trim());

    const result = await convertToPcm16leMono16k(config.ffmpegPath, srcPath, outPath);

    const expectedSamples = 2 * PCM_SAMPLE_RATE_HZ; // 32000
    expect(result.sampleCount).toBeGreaterThan(expectedSamples * 0.99);
    expect(result.sampleCount).toBeLessThan(expectedSamples * 1.01);
    expect(result.byteLength).toBe(result.sampleCount * 2);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
