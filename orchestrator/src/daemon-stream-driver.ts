import { open } from "node:fs/promises";

import type { WsDaemonConfig } from "./config";
import {
  DaemonDriverError,
  type DaemonSegment,
  type DaemonTranscription,
  type DaemonWord,
} from "./daemon-driver";

/**
 * Streaming file bridge: instead of handing the daemon the whole pcm file in one
 * `transcribe_file`, drive the daemon's live-session protocol
 * (`session_start` -> binary pcm16le windows -> `flush` -> `session_final`), the
 * same path EchoRecorder uses for live capture. This bounds daemon memory to a
 * window, yields incremental `segment_final`, removes the 10-min one-shot wall
 * (per-event heartbeat instead), and lets us report real progress.
 *
 * The daemon is unchanged (see SB-D1). Rollover (SB-D7/SB-D8): if audio piles up
 * uncommitted toward the daemon's 30-min session cap, we finalize the current
 * session and continue on a *fresh WS connection* (the daemon does not reset a
 * session on `flush`), shifting timestamps by the audio already consumed. In
 * practice sentence-boundary auto-commits keep the buffer tiny, so rollover is a
 * safety net for pathological no-boundary audio.
 */

// PCM format agreed with the daemon (session_start guards these exact values).
const SAMPLE_RATE_HZ = 16000;
const CHANNELS = 1;
const BYTES_PER_SAMPLE = 2; // pcm16le mono
const AUDIO_FORMAT = "pcm16le";

export const DEFAULT_STREAM_WINDOW_MS = 30000;
export const DEFAULT_STREAM_ROLLOVER_MS = 1200000;
const DEFAULT_HEARTBEAT_TIMEOUT_MS = 120000;
const MIN_HIGH_WATER_BYTES = 4_000_000;

/** Bytes of pcm16le mono 16k that hold `ms` of audio (rounded to whole samples). */
export const bytesForMs = (ms: number): number =>
  Math.max(BYTES_PER_SAMPLE, Math.round((ms / 1000) * SAMPLE_RATE_HZ) * BYTES_PER_SAMPLE);

/** Milliseconds of audio represented by `bytes` of pcm16le mono 16k. */
export const msForBytes = (bytes: number): number =>
  Math.round((bytes / BYTES_PER_SAMPLE / SAMPLE_RATE_HZ) * 1000);

export interface StreamProgress {
  readonly windowsSent: number;
  readonly windowsTotal: number;
  readonly bytesSent: number;
  readonly bytesTotal: number;
  /** Audio position the daemon has committed (max segment end), in ms. */
  readonly processedMs: number;
  readonly totalMs: number;
  /** Headline percent: committed audio / total, clamped to 0..100. */
  readonly progressPct: number;
}

export type ProgressListener = (progress: StreamProgress) => void;

/** Minimal WS surface the driver needs; injectable so tests avoid real sockets. */
export interface StreamSocket {
  readonly bufferedAmount: number;
  send(data: string | Uint8Array): void;
  close(): void;
  onOpen(handler: () => void): void;
  onMessage(handler: (data: string) => void): void;
  onError(handler: (error: Error) => void): void;
  onClose(handler: () => void): void;
}

/** Sequential window reader over the pcm file; injectable for tests. */
export interface PcmSource {
  readonly byteLength: number;
  /** Next window of up to `windowBytes`; null at EOF. */
  read(windowBytes: number): Promise<Uint8Array | null>;
  close(): Promise<void>;
}

export interface TranscribeStreamOptions {
  readonly requestId?: string;
  readonly language?: string;
  readonly wordTimestamps?: boolean;
  readonly mode?: string;
  readonly windowBytes?: number;
  readonly rolloverBytes?: number;
  readonly heartbeatTimeoutMs?: number;
  readonly highWaterBytes?: number;
  readonly createSocket?: (url: string) => StreamSocket;
  readonly openPcm?: (path: string) => Promise<PcmSource>;
}

const daemonUrl = (endpoint: WsDaemonConfig): string => `ws://${endpoint.host}:${endpoint.port}/`;

const toInt = (value: unknown): number =>
  typeof value === "number" && Number.isFinite(value) ? Math.trunc(value) : 0;
const toFloat = (value: unknown): number =>
  typeof value === "number" && Number.isFinite(value) ? value : 0;
const toStr = (value: unknown): string => (typeof value === "string" ? value : "");
const clampPct = (value: number): number => Math.min(100, Math.max(0, value));

const sleep = (ms: number): Promise<void> => new Promise((resolve) => setTimeout(resolve, ms));

/** Wrap the global WebSocket into the injectable StreamSocket surface. */
const createDefaultSocket = (url: string): StreamSocket => {
  const ws = new WebSocket(url);
  ws.binaryType = "arraybuffer";
  return {
    get bufferedAmount(): number {
      return ws.bufferedAmount;
    },
    send(data: string | Uint8Array): void {
      ws.send(data);
    },
    close(): void {
      try {
        ws.close();
      } catch {
        // ignore close errors
      }
    },
    onOpen(handler: () => void): void {
      ws.addEventListener("open", () => handler());
    },
    onMessage(handler: (data: string) => void): void {
      ws.addEventListener("message", (event: MessageEvent) => {
        handler(typeof event.data === "string" ? event.data : "");
      });
    },
    onError(handler: (error: Error) => void): void {
      ws.addEventListener("error", () => handler(new DaemonDriverError(`websocket error connecting to ${url}`)));
    },
    onClose(handler: () => void): void {
      ws.addEventListener("close", () => handler());
    },
  };
};

/** Open a pcm file as a sequential window source backed by a file handle. */
const openPcmFile = async (filePath: string): Promise<PcmSource> => {
  const handle = await open(filePath, "r");
  const { size } = await handle.stat();
  let position = 0;
  return {
    byteLength: size,
    async read(windowBytes: number): Promise<Uint8Array | null> {
      if (position >= size) {
        return null;
      }
      const toRead = Math.min(windowBytes, size - position);
      const buffer = Buffer.allocUnsafe(toRead);
      const { bytesRead } = await handle.read(buffer, 0, toRead, position);
      if (bytesRead <= 0) {
        return null;
      }
      position += bytesRead;
      return bytesRead === buffer.length ? buffer : buffer.subarray(0, bytesRead);
    },
    async close(): Promise<void> {
      await handle.close();
    },
  };
};

/** Cumulative counters shared across the sessions of one file. */
interface StreamState {
  bytesSent: number;
  windowsSent: number;
  processedMs: number;
}

interface SessionResult {
  readonly endedByRollover: boolean;
  readonly text: string;
  readonly language: string;
  readonly detectedLanguage: string | null;
  readonly durationMs: number;
}

interface SessionContext {
  readonly url: string;
  readonly source: PcmSource;
  readonly windowBytes: number;
  readonly rolloverMs: number;
  readonly heartbeatTimeoutMs: number;
  readonly highWaterBytes: number;
  readonly createSocket: (url: string) => StreamSocket;
  readonly requestId: string;
  readonly language: string;
  readonly mode: string;
  readonly bytesTotal: number;
  readonly offsetMs: number;
  readonly segBase: number;
  readonly state: StreamState;
  readonly segments: DaemonSegment[];
  readonly words: DaemonWord[];
  readonly emitProgress: () => void;
}

/**
 * Run one WS session over a fresh connection, streaming windows from the shared
 * source until EOF or the rollover threshold. Pushes offset-adjusted segments/words
 * into the shared sink and resolves on the daemon's `session_final`.
 */
const runStreamSession = (ctx: SessionContext): Promise<SessionResult> => {
  return new Promise<SessionResult>((resolve, reject) => {
    const socket = ctx.createSocket(ctx.url);
    let settled = false;
    let heartbeat: ReturnType<typeof setTimeout> | null = null;
    let rolloverRequested = false;
    let sessionMaxEndMs = 0;

    const cleanup = (): void => {
      if (heartbeat !== null) {
        clearTimeout(heartbeat);
        heartbeat = null;
      }
      socket.close();
    };
    const done = (value: SessionResult): void => {
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
    const touchHeartbeat = (): void => {
      if (heartbeat !== null) {
        clearTimeout(heartbeat);
      }
      heartbeat = setTimeout(
        () => fail(new DaemonDriverError(`daemon ${ctx.url} stalled: no event for ${ctx.heartbeatTimeoutMs}ms`)),
        ctx.heartbeatTimeoutMs,
      );
    };

    const maybeRollover = (): void => {
      if (rolloverRequested) {
        return;
      }
      const uncommittedMs = msForBytes(ctx.state.bytesSent) - ctx.state.processedMs;
      if (uncommittedMs >= ctx.rolloverMs) {
        rolloverRequested = true;
        socket.send(JSON.stringify({ event: "flush" }));
      }
    };

    const pump = async (): Promise<void> => {
      socket.send(
        JSON.stringify({
          event: "session_start",
          request_id: ctx.requestId,
          sample_rate_hz: SAMPLE_RATE_HZ,
          channels: CHANNELS,
          audio_format: AUDIO_FORMAT,
          language: ctx.language,
          mode: ctx.mode,
        }),
      );

      while (!settled && !rolloverRequested) {
        const window = await ctx.source.read(ctx.windowBytes);
        if (window === null) {
          if (!settled) {
            socket.send(JSON.stringify({ event: "flush" }));
          }
          return;
        }

        // Backpressure: don't buffer the whole file on our side; let the daemon
        // (which reads frames sequentially) set the pace.
        while (!settled && socket.bufferedAmount > ctx.highWaterBytes) {
          await sleep(5);
        }
        if (settled) {
          return;
        }

        socket.send(window);
        ctx.state.bytesSent += window.length;
        ctx.state.windowsSent += 1;
        ctx.emitProgress();
        maybeRollover();
      }
    };

    socket.onError((error) => fail(error));
    socket.onClose(() => fail(new DaemonDriverError(`connection to ${ctx.url} closed before completion`)));

    socket.onMessage((data) => {
      if (data.length === 0) {
        return;
      }
      let parsed: unknown;
      try {
        parsed = JSON.parse(data);
      } catch {
        return;
      }
      if (typeof parsed !== "object" || parsed === null) {
        return;
      }
      const message = parsed as Record<string, unknown>;
      touchHeartbeat();

      switch (message.event) {
        case "session_ack":
          break;
        case "segment_final": {
          const startMs = toInt(message.start_ms) + ctx.offsetMs;
          const endMs = toInt(message.end_ms) + ctx.offsetMs;
          ctx.segments.push({
            segmentId: ctx.segBase + toInt(message.segment_id),
            text: toStr(message.text),
            startMs,
            endMs,
          });
          const localEnd = toInt(message.end_ms);
          if (localEnd > sessionMaxEndMs) {
            sessionMaxEndMs = localEnd;
          }
          const absoluteProcessed = ctx.offsetMs + sessionMaxEndMs;
          if (absoluteProcessed > ctx.state.processedMs) {
            ctx.state.processedMs = absoluteProcessed;
          }
          ctx.emitProgress();
          break;
        }
        case "word_committed":
          ctx.words.push({
            text: toStr(message.text),
            segmentId: ctx.segBase + toInt(message.segment_id),
            indexInSegment: toInt(message.index_in_segment),
            startMs: toInt(message.start_ms) + ctx.offsetMs,
            endMs: toInt(message.end_ms) + ctx.offsetMs,
            confidence: toFloat(message.confidence),
          });
          break;
        case "session_final": {
          const sessionDurationMs = toInt(message.duration_ms);
          const absoluteProcessed = ctx.offsetMs + Math.max(sessionDurationMs, sessionMaxEndMs);
          if (absoluteProcessed > ctx.state.processedMs) {
            ctx.state.processedMs = absoluteProcessed;
          }
          ctx.emitProgress();
          done({
            endedByRollover: rolloverRequested,
            text: toStr(message.text),
            language: toStr(message.language),
            detectedLanguage:
              typeof message.detected_language === "string" ? message.detected_language : null,
            durationMs: sessionDurationMs,
          });
          break;
        }
        case "error":
          fail(new DaemonDriverError(toStr(message.message) || "daemon stream error"));
          break;
        default:
          break;
      }
    });

    socket.onOpen(() => {
      touchHeartbeat();
      void pump().catch((error) => fail(error instanceof Error ? error : new DaemonDriverError(String(error))));
    });
  });
};

/**
 * Stream a pre-converted pcm16le file to the daemon over its live-session
 * protocol and collect the transcription. Emits incremental progress; spans
 * multiple sessions if rollover triggers, stitching timestamps and segment ids.
 */
export const transcribeFileStreaming = async (
  endpoint: WsDaemonConfig,
  pcmPath: string,
  options: TranscribeStreamOptions = {},
  onProgress?: ProgressListener,
): Promise<DaemonTranscription> => {
  const requestId = options.requestId ?? crypto.randomUUID();
  const language = options.language ?? "auto";
  const mode = options.mode ?? "dictation";
  const windowBytes = Math.max(BYTES_PER_SAMPLE, options.windowBytes ?? bytesForMs(DEFAULT_STREAM_WINDOW_MS));
  const rolloverBytes = Math.max(windowBytes, options.rolloverBytes ?? bytesForMs(DEFAULT_STREAM_ROLLOVER_MS));
  const rolloverMs = msForBytes(rolloverBytes);
  const heartbeatTimeoutMs = options.heartbeatTimeoutMs ?? DEFAULT_HEARTBEAT_TIMEOUT_MS;
  const highWaterBytes = Math.max(windowBytes * 2, options.highWaterBytes ?? MIN_HIGH_WATER_BYTES);
  const createSocket = options.createSocket ?? createDefaultSocket;
  const openPcm = options.openPcm ?? openPcmFile;
  const url = daemonUrl(endpoint);

  const source = await openPcm(pcmPath);
  const bytesTotal = source.byteLength;
  const windowsTotal = Math.max(1, Math.ceil(bytesTotal / windowBytes));
  const totalMs = msForBytes(bytesTotal);

  const segments: DaemonSegment[] = [];
  const words: DaemonWord[] = [];
  const state: StreamState = { bytesSent: 0, windowsSent: 0, processedMs: 0 };

  const emitProgress = (): void => {
    onProgress?.({
      windowsSent: state.windowsSent,
      windowsTotal,
      bytesSent: state.bytesSent,
      bytesTotal,
      processedMs: state.processedMs,
      totalMs,
      progressPct: totalMs > 0 ? clampPct((state.processedMs / totalMs) * 100) : 0,
    });
  };

  let fullText = "";
  let resolvedLanguage = language;
  let detectedLanguage: string | null = null;
  let durationMs = 0;

  try {
    let more = true;
    while (more) {
      const offsetMs = msForBytes(state.bytesSent);
      const session = await runStreamSession({
        url,
        source,
        windowBytes,
        rolloverMs,
        heartbeatTimeoutMs,
        highWaterBytes,
        createSocket,
        requestId,
        language: resolvedLanguage,
        mode,
        bytesTotal,
        offsetMs,
        segBase: segments.length,
        state,
        segments,
        words,
        emitProgress,
      });

      if (session.text.trim().length > 0) {
        fullText = fullText.length === 0 ? session.text.trim() : `${fullText} ${session.text.trim()}`;
      }
      if (session.language.length > 0) {
        resolvedLanguage = session.language;
      }
      if (detectedLanguage === null) {
        detectedLanguage = session.detectedLanguage;
      }
      durationMs = offsetMs + session.durationMs;

      // Continue only if the session cut off for rollover and there is more audio.
      more = session.endedByRollover && state.bytesSent < bytesTotal;
    }
  } finally {
    await source.close().catch(() => undefined);
  }

  return {
    text: fullText,
    language: resolvedLanguage.length > 0 ? resolvedLanguage : language,
    detectedLanguage,
    durationMs: durationMs > 0 ? durationMs : totalMs,
    segmentCount: segments.length,
    segments,
    words,
  };
};
