import { stat } from "node:fs/promises";

export const PCM_SAMPLE_RATE_HZ = 16000;
export const PCM_CHANNELS = 1;
export const PCM_BYTES_PER_SAMPLE = 2;

export interface PcmConversionResult {
  readonly outputPath: string;
  readonly byteLength: number;
  readonly sampleCount: number;
}

export class AudioConversionError extends Error {}

/**
 * Convert an arbitrary audio file to the format agreed with recognition daemons
 * (see services/<daemon>/daemon.json "input"): raw pcm_s16le, 16000 Hz, mono.
 * Uses the configured ffmpeg binary; ffmpeg handles decode + downmix + resample.
 */
export const convertToPcm16leMono16k = async (
  ffmpegPath: string,
  inputPath: string,
  outputPath: string,
): Promise<PcmConversionResult> => {
  const proc = Bun.spawn({
    cmd: [
      ffmpegPath,
      "-hide_banner",
      "-loglevel",
      "error",
      "-y",
      "-i",
      inputPath,
      "-ac",
      String(PCM_CHANNELS),
      "-ar",
      String(PCM_SAMPLE_RATE_HZ),
      "-f",
      "s16le",
      outputPath,
    ],
    stdin: "ignore",
    stdout: "ignore",
    stderr: "pipe",
  });

  const stderrText = await new Response(proc.stderr).text();
  const exitCode = await proc.exited;
  if (exitCode !== 0) {
    throw new AudioConversionError(
      `ffmpeg failed to convert ${inputPath} (exit ${exitCode}): ${stderrText.trim()}`,
    );
  }

  const info = await stat(outputPath);
  return {
    outputPath,
    byteLength: info.size,
    sampleCount: Math.floor(info.size / PCM_BYTES_PER_SAMPLE),
  };
};
