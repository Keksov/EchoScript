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
 * The daemon is unchanged (see SB-D1): it already appends + auto-commits on
 * binary frames and finalizes on `flush`. Rollover across the 30-min buffer cap
 * (SB-D7/SB-D8) is a follow-up (SB3.1); this module streams one session.
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

/**
 * Stream a pre-converted pcm16le file to the daemon over its live-session
 * protocol and collect the transcription. Emits incremental progress; resolves
 * on the daemon's terminal `session_final`.
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
  const heartbeatTimeoutMs = options.heartbeatTimeoutMs ?? DEFAULT_HEARTBEAT_TIMEOUT_MS;
  const highWaterBytes = Math.max(windowBytes * 2, options.highWaterBytes ?? MIN_HIGH_WATER_BYTES);
  const createSocket = options.createSocket ?? createDefaultSocket;
  const openPcm = options.openPcm ?? openPcmFile;

  const source = await openPcm(pcmPath);
  const bytesTotal = source.byteLength;
  const windowsTotal = Math.max(1, Math.ceil(bytesTotal / windowBytes));
  const totalMs = msForBytes(bytesTotal);

  const segments: DaemonSegment[] = [];
  const words: DaemonWord[] = [];

  let windowsSent = 0;
  let bytesSent = 0;
  let processedMs = 0;

  return new Promise<DaemonTranscription>((resolve, reject) => {
    const url = daemonUrl(endpoint);
    const socket = createSocket(url);
    let settled = false;
    let heartbeat: ReturnType<typeof setTimeout> | null = null;

    const emitProgress = (): void => {
      if (onProgress === undefined) {
        return;
      }
      onProgress({
        windowsSent,
        windowsTotal,
        bytesSent,
        bytesTotal,
        processedMs,
        totalMs,
        progressPct: totalMs > 0 ? clampPct((processedMs / totalMs) * 100) : 0,
      });
    };

    const cleanup = (): void => {
      if (heartbeat !== null) {
        clearTimeout(heartbeat);
        heartbeat = null;
      }
      socket.close();
      void source.close().catch(() => undefined);
    };

    const done = (value: DaemonTranscription): void => {
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
        () => fail(new DaemonDriverError(`daemon ${url} stalled: no event for ${heartbeatTimeoutMs}ms`)),
        heartbeatTimeoutMs,
      );
    };

    const pump = async (): Promise<void> => {
      socket.send(
        JSON.stringify({
          event: "session_start",
          request_id: requestId,
          sample_rate_hz: SAMPLE_RATE_HZ,
          channels: CHANNELS,
          audio_format: AUDIO_FORMAT,
          language,
          mode,
        }),
      );

      while (!settled) {
        const window = await source.read(windowBytes);
        if (window === null) {
          break;
        }

        // Backpressure: don't buffer the whole file on our side; let the daemon
        // (which reads frames sequentially) set the pace.
        while (!settled && socket.bufferedAmount > highWaterBytes) {
          await sleep(5);
        }
        if (settled) {
          return;
        }

        socket.send(window);
        bytesSent += window.length;
        windowsSent += 1;
        emitProgress();
      }

      if (!settled) {
        socket.send(JSON.stringify({ event: "flush" }));
      }
    };

    socket.onError((error) => fail(error));
    socket.onClose(() => fail(new DaemonDriverError(`connection to ${url} closed before completion`)));

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
          const endMs = toInt(message.end_ms);
          segments.push({
            segmentId: toInt(message.segment_id),
            text: toStr(message.text),
            startMs: toInt(message.start_ms),
            endMs,
          });
          if (endMs > processedMs) {
            processedMs = endMs;
          }
          emitProgress();
          break;
        }
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
        case "session_final": {
          const durationMs = toInt(message.duration_ms) || totalMs;
          if (durationMs > processedMs) {
            processedMs = durationMs;
          }
          emitProgress();
          done({
            text: toStr(message.text),
            language: toStr(message.language) || language,
            detectedLanguage:
              typeof message.detected_language === "string" ? message.detected_language : null,
            durationMs,
            segmentCount:
              typeof message.segment_count === "number" ? toInt(message.segment_count) : segments.length,
            segments,
            words,
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
