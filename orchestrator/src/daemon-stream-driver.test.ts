import { test, expect } from "bun:test";
import { writeFile, unlink } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";

import type { WsDaemonConfig } from "./config";
import { DaemonDriverError } from "./daemon-driver";
import {
  transcribeFileStreaming,
  bytesForMs,
  msForBytes,
  type PcmSource,
  type StreamProgress,
  type StreamSocket,
} from "./daemon-stream-driver";

const ENDPOINT: WsDaemonConfig = { host: "127.0.0.1", port: 9, modelName: "mock" };

const nextTick = (ms = 0): Promise<void> => new Promise((resolve) => setTimeout(resolve, ms));

/** In-memory pcm source of `totalBytes` filled with 0x01. */
const fakePcm = (totalBytes: number): PcmSource => {
  let pos = 0;
  return {
    byteLength: totalBytes,
    async read(windowBytes: number): Promise<Uint8Array | null> {
      if (pos >= totalBytes) return null;
      const n = Math.min(windowBytes, totalBytes - pos);
      const buf = new Uint8Array(n).fill(1);
      pos += n;
      return buf;
    },
    async close(): Promise<void> {},
  };
};

interface Frame {
  readonly kind: "text" | "binary";
  readonly text?: string;
  readonly bytes?: number;
}

/** Injectable fake socket driven manually by the test. */
class FakeSocket implements StreamSocket {
  bufferedAmount = 0;
  readonly frames: Frame[] = [];
  closed = false;
  private openCb: (() => void) | null = null;
  private msgCb: ((data: string) => void) | null = null;
  private errCb: ((error: Error) => void) | null = null;
  private closeCb: (() => void) | null = null;

  send(data: string | Uint8Array): void {
    if (typeof data === "string") this.frames.push({ kind: "text", text: data });
    else this.frames.push({ kind: "binary", bytes: data.length });
  }
  close(): void {
    this.closed = true;
  }
  onOpen(handler: () => void): void {
    this.openCb = handler;
  }
  onMessage(handler: (data: string) => void): void {
    this.msgCb = handler;
  }
  onError(handler: (error: Error) => void): void {
    this.errCb = handler;
  }
  onClose(handler: () => void): void {
    this.closeCb = handler;
  }

  fireOpen(): void {
    this.openCb?.();
  }
  emit(message: Record<string, unknown>): void {
    this.msgCb?.(JSON.stringify(message));
  }
  fireError(error: Error): void {
    this.errCb?.(error);
  }
  fireClose(): void {
    this.closeCb?.();
  }

  get textFrames(): string[] {
    return this.frames.filter((f) => f.kind === "text").map((f) => f.text ?? "");
  }
  get binarySizes(): number[] {
    return this.frames.filter((f) => f.kind === "binary").map((f) => f.bytes ?? 0);
  }
}

test("bytesForMs / msForBytes round-trip pcm16le mono 16k", () => {
  expect(bytesForMs(30000)).toBe(960000);
  expect(bytesForMs(1000)).toBe(32000);
  expect(msForBytes(960000)).toBe(30000);
  expect(msForBytes(64000)).toBe(2000);
});

test("windows the file, sends session_start + binary frames + flush in order", async () => {
  const socket = new FakeSocket();
  const p = transcribeFileStreaming(
    ENDPOINT,
    "x.pcm",
    { requestId: "req-1", language: "ru", mode: "dictation", windowBytes: 30000, createSocket: () => socket, openPcm: async () => fakePcm(100000) },
  );

  await nextTick();
  socket.fireOpen();
  await nextTick();

  // First frame is session_start with the agreed pcm contract.
  const start = JSON.parse(socket.textFrames[0] ?? "{}");
  expect(start.event).toBe("session_start");
  expect(start.sample_rate_hz).toBe(16000);
  expect(start.channels).toBe(1);
  expect(start.audio_format).toBe("pcm16le");
  expect(start.language).toBe("ru");
  expect(start.mode).toBe("dictation");
  expect(start.request_id).toBe("req-1");

  // 100000 / 30000 -> 30000,30000,30000,10000
  expect(socket.binarySizes).toEqual([30000, 30000, 30000, 10000]);
  // Last text frame is the finalizing flush.
  expect(JSON.parse(socket.textFrames[socket.textFrames.length - 1] ?? "{}").event).toBe("flush");

  socket.emit({ event: "session_final", text: "готово", language: "ru", duration_ms: 3125, segment_count: 0 });
  const result = await p;
  expect(result.text).toBe("готово");
});

test("aggregates incremental segments/words and reports progress from committed audio", async () => {
  const socket = new FakeSocket();
  const progress: StreamProgress[] = [];
  const p = transcribeFileStreaming(
    ENDPOINT,
    "x.pcm",
    { windowBytes: 32000, createSocket: () => socket, openPcm: async () => fakePcm(64000) }, // 2000ms total, 2 windows
    (pr) => progress.push(pr),
  );

  await nextTick();
  socket.fireOpen();
  await nextTick();

  socket.emit({ event: "session_ack", model_name: "mock" });
  socket.emit({ event: "segment_final", segment_id: 0, text: "привет", start_ms: 0, end_ms: 1000 });
  socket.emit({ event: "word_committed", segment_id: 0, index_in_segment: 0, text: "привет", start_ms: 0, end_ms: 1000, confidence: 0.8 });
  socket.emit({ event: "segment_final", segment_id: 1, text: "мир", start_ms: 1000, end_ms: 2000 });
  socket.emit({ event: "session_final", text: "привет мир", language: "ru", duration_ms: 2000, segment_count: 2 });

  const result = await p;
  expect(result.segments.map((s) => s.text)).toEqual(["привет", "мир"]);
  expect(result.words.length).toBe(1);
  expect(result.words[0]?.confidence).toBeCloseTo(0.8, 5);
  expect(result.segmentCount).toBe(2);

  // windowsTotal computed from bytes; progress climbs to 50% then 100%.
  expect(progress[0]?.windowsTotal).toBe(2);
  const pcts = progress.map((pr) => Math.round(pr.progressPct));
  expect(pcts).toContain(50);
  expect(pcts[pcts.length - 1]).toBe(100);
});

test("rejects on daemon error event", async () => {
  const socket = new FakeSocket();
  const p = transcribeFileStreaming(ENDPOINT, "x.pcm", {
    windowBytes: 999999,
    createSocket: () => socket,
    openPcm: async () => fakePcm(10),
  });
  await nextTick();
  socket.fireOpen();
  await nextTick();
  socket.emit({ event: "error", message: "boom" });
  await expect(p).rejects.toMatchObject({ message: "boom" });
});

test("rejects when the connection closes before session_final", async () => {
  const socket = new FakeSocket();
  const p = transcribeFileStreaming(ENDPOINT, "x.pcm", {
    windowBytes: 999999,
    createSocket: () => socket,
    openPcm: async () => fakePcm(10),
  });
  await nextTick();
  socket.fireOpen();
  await nextTick();
  socket.fireClose();
  await expect(p).rejects.toBeInstanceOf(DaemonDriverError);
});

test("heartbeat fires when the daemon goes silent", async () => {
  const socket = new FakeSocket();
  const p = transcribeFileStreaming(ENDPOINT, "x.pcm", {
    windowBytes: 999999,
    heartbeatTimeoutMs: 30,
    createSocket: () => socket,
    openPcm: async () => fakePcm(10),
  });
  await nextTick();
  socket.fireOpen();
  // no emits -> heartbeat should reject
  await expect(p).rejects.toMatchObject({ message: expect.stringContaining("stalled") });
});

test("keepalive resets the heartbeat (no false stall during long silence)", async () => {
  const socket = new FakeSocket();
  const p = transcribeFileStreaming(ENDPOINT, "x.pcm", {
    windowBytes: 999999,
    heartbeatTimeoutMs: 60,
    createSocket: () => socket,
    openPcm: async () => fakePcm(10),
  });
  await nextTick();
  socket.fireOpen();

  // Silence longer than the 60ms heartbeat, but punctuated by keepalives every 30ms:
  // if keepalive resets the timer, the session must NOT be failed as a stall.
  for (let i = 0; i < 4; i += 1) {
    await nextTick(30);
    socket.emit({ event: "keepalive", progress: i * 25 });
  }
  socket.emit({ event: "session_final", text: "ok", language: "ru", duration_ms: 0, segment_count: 0 });

  await expect(p).resolves.toMatchObject({ text: "ok" });
});

test("backpressure gates sending until bufferedAmount drains", async () => {
  const socket = new FakeSocket();
  socket.bufferedAmount = 10_000_000; // above high-water -> pump must wait before first window
  const p = transcribeFileStreaming(ENDPOINT, "x.pcm", {
    windowBytes: 32000,
    highWaterBytes: 100000,
    createSocket: () => socket,
    openPcm: async () => fakePcm(96000),
  });

  await nextTick();
  socket.fireOpen();
  await nextTick(15);

  // session_start went out, but no binary yet — blocked on backpressure.
  expect(socket.binarySizes.length).toBe(0);
  expect(socket.textFrames[0] && JSON.parse(socket.textFrames[0]).event).toBe("session_start");

  socket.bufferedAmount = 0; // drain
  await nextTick(15);
  expect(socket.binarySizes.length).toBeGreaterThan(0);

  socket.emit({ event: "session_final", text: "", language: "ru", duration_ms: 3000, segment_count: 0 });
  await p;
});

test("integration: rollover spans multiple sessions and stitches timestamps", async () => {
  const total = 160000; // 5s -> 5 windows of 1s
  const tmpPath = path.join(tmpdir(), `stream-rollover-${crypto.randomUUID()}.pcm`);
  await writeFile(tmpPath, Buffer.alloc(total, 1));

  let connectionCount = 0;
  let totalReceived = 0;
  const perConn = new WeakMap<object, { bytes: number }>();
  const server = Bun.serve({
    port: 0,
    fetch(req, srv) {
      if (srv.upgrade(req)) return undefined;
      return new Response("expected websocket", { status: 400 });
    },
    websocket: {
      open(ws) {
        connectionCount += 1;
        perConn.set(ws, { bytes: 0 });
      },
      message(ws, message) {
        const conn = perConn.get(ws) ?? { bytes: 0 };
        if (typeof message === "string") {
          const parsed = JSON.parse(message);
          if (parsed.event === "session_start") {
            ws.send(JSON.stringify({ event: "session_ack" }));
          } else if (parsed.event === "flush") {
            const localMs = msForBytes(conn.bytes);
            ws.send(JSON.stringify({ event: "segment_final", segment_id: 0, text: "seg", start_ms: 0, end_ms: localMs }));
            ws.send(JSON.stringify({ event: "session_final", text: "seg", language: "ru", duration_ms: localMs, segment_count: 1 }));
          }
        } else {
          conn.bytes += message.length;
          totalReceived += message.length;
          perConn.set(ws, conn);
        }
      },
    },
  });

  try {
    const endpoint: WsDaemonConfig = { host: "127.0.0.1", port: server.port ?? 0, modelName: "mock" };
    let lastPct = 0;
    const result = await transcribeFileStreaming(
      endpoint,
      tmpPath,
      { windowBytes: 32000, rolloverBytes: 64000 }, // rollover every 2s of uncommitted audio
      (pr) => {
        lastPct = pr.progressPct;
      },
    );

    expect(connectionCount).toBe(3); // 2s + 2s + 1s
    expect(totalReceived).toBe(total);
    expect(result.segments.map((s) => [s.startMs, s.endMs])).toEqual([
      [0, 2000],
      [2000, 4000],
      [4000, 5000],
    ]);
    expect(result.segments.map((s) => s.segmentId)).toEqual([0, 1, 2]);
    expect(result.text).toBe("seg seg seg");
    expect(result.durationMs).toBe(5000);
    expect(Math.round(lastPct)).toBe(100);
  } finally {
    server.stop(true);
    await unlink(tmpPath).catch(() => undefined);
  }
});

test("integration: real socket delivers windows as binary frames end-to-end", async () => {
  const total = 100000;
  const tmpPath = path.join(tmpdir(), `stream-bridge-${crypto.randomUUID()}.pcm`);
  await writeFile(tmpPath, Buffer.alloc(total, 1));

  let receivedBinary = 0;
  let sawSessionStart = false;
  const server = Bun.serve({
    port: 0,
    fetch(req, srv) {
      if (srv.upgrade(req)) return undefined;
      return new Response("expected websocket", { status: 400 });
    },
    websocket: {
      message(ws, message) {
        if (typeof message === "string") {
          const parsed = JSON.parse(message);
          if (parsed.event === "session_start") {
            sawSessionStart = true;
            ws.send(JSON.stringify({ event: "session_ack" }));
          } else if (parsed.event === "flush") {
            ws.send(
              JSON.stringify({
                event: "session_final",
                text: "ok",
                language: "ru",
                duration_ms: msForBytes(receivedBinary),
                segment_count: 0,
              }),
            );
          }
        } else {
          receivedBinary += message.length;
        }
      },
    },
  });

  try {
    const endpoint: WsDaemonConfig = { host: "127.0.0.1", port: server.port ?? 0, modelName: "mock" };
    const result = await transcribeFileStreaming(endpoint, tmpPath, { windowBytes: 30000 });
    expect(sawSessionStart).toBe(true);
    expect(receivedBinary).toBe(total); // every byte arrived, as binary frames
    expect(result.text).toBe("ok");
    expect(result.durationMs).toBe(msForBytes(total));
  } finally {
    server.stop(true);
    await unlink(tmpPath).catch(() => undefined);
  }
});
