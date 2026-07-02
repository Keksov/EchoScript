import type { WsDaemonConfig } from "./config";

export interface DaemonSegment {
  readonly segmentId: number;
  readonly text: string;
  readonly startMs: number;
  readonly endMs: number;
}

export interface DaemonWord {
  readonly text: string;
  readonly segmentId: number;
  readonly indexInSegment: number;
  readonly startMs: number;
  readonly endMs: number;
  readonly confidence: number;
}

export interface DaemonTranscription {
  readonly text: string;
  readonly language: string;
  readonly detectedLanguage: string | null;
  readonly durationMs: number;
  readonly segmentCount: number;
  readonly segments: readonly DaemonSegment[];
  readonly words: readonly DaemonWord[];
}

export interface TranscribeFileOptions {
  readonly requestId?: string;
  readonly language?: string;
  readonly wordTimestamps?: boolean;
  readonly mode?: string;
  readonly timeoutMs?: number;
}

export class DaemonDriverError extends Error {}

/**
 * Transport-level failure: the daemon could not be reached / dropped the connection /
 * went silent (connect refused, close-before-completion, heartbeat stall). Retryable —
 * the job should be requeued rather than failed terminally (DR-D11).
 */
export class DaemonUnreachableError extends DaemonDriverError {}

const DEFAULT_DESCRIBE_TIMEOUT_MS = 5000;
const DEFAULT_TRANSCRIBE_TIMEOUT_MS = 600000;

const daemonUrl = (endpoint: WsDaemonConfig): string => `ws://${endpoint.host}:${endpoint.port}/`;

const toInt = (value: unknown): number => (typeof value === "number" && Number.isFinite(value) ? Math.trunc(value) : 0);
const toFloat = (value: unknown): number => (typeof value === "number" && Number.isFinite(value) ? value : 0);
const toStr = (value: unknown): string => (typeof value === "string" ? value : "");

/**
 * Open a short-lived WS connection to a recognition daemon, send one request,
 * and drive incoming events through `onMessage` until it resolves/rejects.
 */
const runDaemonExchange = <T>(
  endpoint: WsDaemonConfig,
  request: Record<string, unknown>,
  timeoutMs: number,
  onMessage: (message: Record<string, unknown>, done: (value: T) => void, fail: (error: Error) => void) => void,
): Promise<T> => {
  const url = daemonUrl(endpoint);
  return new Promise<T>((resolve, reject) => {
    const ws = new WebSocket(url);
    let settled = false;
    let timer: ReturnType<typeof setTimeout> | null = null;

    const cleanup = (): void => {
      if (timer !== null) {
        clearTimeout(timer);
      }
      try {
        ws.close();
      } catch {
        // ignore close errors
      }
    };
    const done = (value: T): void => {
      if (settled) return;
      settled = true;
      cleanup();
      resolve(value);
    };
    const fail = (error: Error): void => {
      if (settled) return;
      settled = true;
      cleanup();
      reject(error);
    };

    timer = setTimeout(() => fail(new DaemonDriverError(`daemon ${url} timed out after ${timeoutMs}ms`)), timeoutMs);

    ws.addEventListener("open", () => ws.send(JSON.stringify(request)));
    ws.addEventListener("message", (event: MessageEvent) => {
      let parsed: unknown;
      try {
        parsed = JSON.parse(typeof event.data === "string" ? event.data : String(event.data));
      } catch {
        return;
      }
      if (typeof parsed !== "object" || parsed === null) {
        return;
      }
      onMessage(parsed as Record<string, unknown>, done, fail);
    });
    ws.addEventListener("error", () => fail(new DaemonDriverError(`websocket error connecting to ${url}`)));
    ws.addEventListener("close", () => fail(new DaemonDriverError(`connection to ${url} closed before completion`)));
  });
};

/** Ask the daemon for its descriptor (services/<daemon>/daemon.json via `describe`). */
export const describeDaemon = async (
  endpoint: WsDaemonConfig,
  timeoutMs: number = DEFAULT_DESCRIBE_TIMEOUT_MS,
): Promise<Record<string, unknown>> => {
  return runDaemonExchange<Record<string, unknown>>(
    endpoint,
    { event: "describe" },
    timeoutMs,
    (message, done, fail) => {
      if (message.event === "describe_ack") {
        done(message);
      } else if (message.event === "error") {
        fail(new DaemonDriverError(toStr(message.message) || "daemon describe error"));
      }
    },
  );
};

/**
 * Hand a pre-converted pcm16le file to the daemon and collect the transcription.
 * The file must already be in the daemon's agreed input format (see describe/daemon.json).
 */
export const transcribeFileViaDaemon = async (
  endpoint: WsDaemonConfig,
  pcmPath: string,
  options: TranscribeFileOptions = {},
): Promise<DaemonTranscription> => {
  const requestId = options.requestId ?? crypto.randomUUID();
  const timeoutMs = options.timeoutMs ?? DEFAULT_TRANSCRIBE_TIMEOUT_MS;
  const segments: DaemonSegment[] = [];
  const words: DaemonWord[] = [];

  const request = {
    event: "transcribe_file",
    request_id: requestId,
    path: pcmPath,
    language: options.language ?? "auto",
    params: {
      word_timestamps: options.wordTimestamps ?? true,
      mode: options.mode ?? "dictation",
    },
  };

  return runDaemonExchange<DaemonTranscription>(endpoint, request, timeoutMs, (message, done, fail) => {
    switch (message.event) {
      case "segment_final":
        segments.push({
          segmentId: toInt(message.segment_id),
          text: toStr(message.text),
          startMs: toInt(message.start_ms),
          endMs: toInt(message.end_ms),
        });
        break;
      case "word_committed":
        words.push({
          text: toStr(message.text),
          segmentId: toInt(message.segment_id),
          indexInSegment: toInt(message.index_in_segment),
          startMs: toInt(message.start_ms),
          endMs: toInt(message.end_ms),
          confidence: toFloat(message.confidence),
        });
        break;
      case "session_final":
        done({
          text: toStr(message.text),
          language: toStr(message.language) || (options.language ?? ""),
          detectedLanguage: typeof message.detected_language === "string" ? message.detected_language : null,
          durationMs: toInt(message.duration_ms),
          segmentCount: typeof message.segment_count === "number" ? toInt(message.segment_count) : segments.length,
          segments,
          words,
        });
        break;
      case "error":
        fail(new DaemonDriverError(toStr(message.message) || "daemon transcribe error"));
        break;
      default:
        break;
    }
  });
};
