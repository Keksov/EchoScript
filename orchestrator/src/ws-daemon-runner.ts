import { stat, readFile, writeFile, rename } from "node:fs/promises";
import path from "node:path";

import type { WsDaemonConfig } from "./config";
import { convertToPcm16leMono16k } from "./audio-convert";
import { transcribeFileViaDaemon, type DaemonTranscription } from "./daemon-driver";

const nowIso = (): string => new Date().toISOString();

type ConvertFn = typeof convertToPcm16leMono16k;
type TranscribeFn = typeof transcribeFileViaDaemon;

export interface WsDaemonJobDeps {
  readonly ffmpegPath: string;
  readonly endpoint: WsDaemonConfig;
  readonly convert?: ConvertFn;
  readonly transcribe?: TranscribeFn;
}

const isRecord = (value: unknown): value is Record<string, unknown> => {
  return typeof value === "object" && value !== null && !Array.isArray(value);
};

const writeJsonAtomic = async (filePath: string, payload: unknown): Promise<void> => {
  const tempPath = `${filePath}.${process.pid}.${crypto.randomUUID()}.tmp`;
  await writeFile(tempPath, `${JSON.stringify(payload, null, 2)}\n`, "utf-8");
  await rename(tempPath, filePath);
};

const writeTextAtomic = async (filePath: string, content: string): Promise<void> => {
  const tempPath = `${filePath}.${process.pid}.${crypto.randomUUID()}.tmp`;
  await writeFile(tempPath, content, "utf-8");
  await rename(tempPath, filePath);
};

const readJson = async (filePath: string): Promise<unknown> => {
  try {
    return JSON.parse(await readFile(filePath, "utf-8"));
  } catch {
    return null;
  }
};

const appendStatus = async (dataDir: string, status: string, error?: string): Promise<void> => {
  const statusPath = path.join(dataDir, "status.json");
  const existing = await readJson(statusPath);
  const statuses = Array.isArray(existing) ? existing : [];
  const event: Record<string, string> = { status, updated_at: nowIso() };
  if (error !== undefined) {
    event.error = error;
  }
  statuses.push(event);
  await writeJsonAtomic(statusPath, statuses);
};

const loadParams = async (dataDir: string): Promise<Record<string, unknown>> => {
  const payload = await readJson(path.join(dataDir, "params.json"));
  return isRecord(payload) ? payload : {};
};

const extractLanguage = (params: Record<string, unknown>): string | null => {
  const language = params.language;
  if (typeof language !== "string" || language.toLowerCase() === "auto") {
    return null;
  }
  return language;
};

const resolveAudioPath = async (dataDir: string): Promise<string> => {
  const inlinePath = path.join(dataDir, "input");
  try {
    if ((await stat(inlinePath)).isFile()) {
      return inlinePath;
    }
  } catch {
    // fall through to input.json
  }

  const payload = await readJson(path.join(dataDir, "input.json"));
  const source = isRecord(payload) && typeof payload.source === "string" ? payload.source : "";
  if (source.length === 0) {
    throw new Error(`Missing audio source in input.json for ${path.basename(dataDir)}`);
  }
  const sourcePath = path.isAbsolute(source) ? source : path.resolve(dataDir, source);
  if (!(await stat(sourcePath)).isFile()) {
    throw new Error(`Audio source is not a file: ${sourcePath}`);
  }
  return sourcePath;
};

const formatTimestampSeconds = (seconds: number): string => {
  const clamped = Math.max(seconds, 0);
  const totalMs = Math.round(clamped * 1000);
  const hours = Math.floor(totalMs / 3_600_000);
  const minutes = Math.floor((totalMs % 3_600_000) / 60_000);
  const wholeSeconds = Math.floor((totalMs % 60_000) / 1000);
  const millis = totalMs % 1000;
  const pad = (value: number, width: number): string => String(value).padStart(width, "0");
  return `${pad(hours, 2)}:${pad(minutes, 2)}:${pad(wholeSeconds, 2)}.${pad(millis, 3)}`;
};

interface NormalizedSegment {
  readonly start: number;
  readonly end: number;
  readonly text: string;
  readonly speaker: string | null;
  readonly words: readonly Record<string, unknown>[];
  readonly confidence: number | null;
}

interface JobResult {
  readonly raw: Record<string, unknown>;
  readonly normalized: {
    readonly text: string;
    readonly language: string;
    readonly segments: readonly NormalizedSegment[];
  };
}

const buildResult = (transcription: DaemonTranscription, includeWords: boolean): JobResult => {
  const normalizedSegments: NormalizedSegment[] = transcription.segments.map((segment) => ({
    start: segment.startMs / 1000,
    end: segment.endMs / 1000,
    text: segment.text.trim(),
    speaker: null,
    words: includeWords
      ? transcription.words
          .filter((word) => word.segmentId === segment.segmentId)
          .map((word) => ({
            start: word.startMs / 1000,
            end: word.endMs / 1000,
            word: word.text,
            confidence: word.confidence,
          }))
      : [],
    confidence: null,
  }));

  return {
    raw: {
      text: transcription.text,
      language: transcription.language,
      segments: transcription.segments.map((segment) => ({
        start: segment.startMs / 1000,
        end: segment.endMs / 1000,
        text: segment.text,
      })),
    },
    normalized: {
      text: transcription.text,
      language: transcription.language,
      segments: normalizedSegments,
    },
  };
};

const buildPlainText = (result: JobResult): string => {
  const text = result.normalized.text.trim();
  return text.length === 0 ? "" : `${text}\n`;
};

const buildTimestampText = (result: JobResult): string => {
  const lines: string[] = [];
  for (const segment of result.normalized.segments) {
    const text = segment.text.trim();
    if (text.length === 0) {
      continue;
    }
    const start = formatTimestampSeconds(segment.start);
    const end = formatTimestampSeconds(Math.max(segment.start, segment.end));
    lines.push(`[${start} --> ${end}]  ${text}`);
  }
  if (lines.length === 0) {
    return buildPlainText(result);
  }
  return `${lines.join("\n")}\n`;
};

const messageOf = (error: unknown): string => (error instanceof Error ? error.message : String(error));

/**
 * Run a ws-daemon job end to end (orchestrator owns the jobs/ lifecycle):
 * convert input -> pcm16le, transcribe via the daemon file-API, then write the
 * same artifacts a python worker would (result.json / result_plain.txt /
 * result_timestamp.txt), append status transitions, and drop the output marker.
 */
export const runWsDaemonJob = async (
  jobId: string,
  dataDir: string,
  outputDir: string,
  deps: WsDaemonJobDeps,
): Promise<"ready" | "failed"> => {
  const convert = deps.convert ?? convertToPcm16leMono16k;
  const transcribe = deps.transcribe ?? transcribeFileViaDaemon;
  let finalStatus: "ready" | "failed" = "ready";

  try {
    await appendStatus(dataDir, "processing");
    const params = await loadParams(dataDir);
    const language = extractLanguage(params);
    const includeWords = params.word_timestamps === true;

    const audioPath = await resolveAudioPath(dataDir);
    const pcmPath = path.join(dataDir, "audio.pcm");
    await convert(deps.ffmpegPath, audioPath, pcmPath);

    const transcription = await transcribe(deps.endpoint, pcmPath, {
      requestId: jobId,
      language: language ?? "auto",
      wordTimestamps: includeWords,
    });

    const result = buildResult(transcription, includeWords);
    await writeJsonAtomic(path.join(dataDir, "result.json"), result);
    await writeTextAtomic(path.join(dataDir, "result_plain.txt"), buildPlainText(result));
    await writeTextAtomic(path.join(dataDir, "result_timestamp.txt"), buildTimestampText(result));
    await appendStatus(dataDir, "ready");
  } catch (error) {
    finalStatus = "failed";
    await appendStatus(dataDir, "failed", messageOf(error)).catch(() => undefined);
  } finally {
    await writeJsonAtomic(path.join(outputDir, `${jobId}.json`), {
      created_at: nowIso(),
      status: finalStatus,
    }).catch(() => undefined);
  }

  return finalStatus;
};
