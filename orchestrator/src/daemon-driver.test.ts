import { test, expect } from "bun:test";

import type { WsDaemonConfig } from "./config";
import { describeDaemon, transcribeFileViaDaemon, DaemonDriverError } from "./daemon-driver";

const startMockDaemon = (handler: (event: string, msg: Record<string, unknown>, ws: any) => void) => {
  return Bun.serve({
    port: 0,
    fetch(req, server) {
      if (server.upgrade(req)) return undefined;
      return new Response("expected websocket", { status: 400 });
    },
    websocket: {
      message(ws, message) {
        const parsed = JSON.parse(typeof message === "string" ? message : message.toString());
        handler(String(parsed.event), parsed, ws);
      },
    },
  });
};

const endpointOf = (server: ReturnType<typeof startMockDaemon>): WsDaemonConfig => ({
  host: "127.0.0.1",
  port: server.port ?? 0,
  modelName: "mock",
});

test("describeDaemon resolves the describe_ack descriptor", async () => {
  const server = startMockDaemon((event, _msg, ws) => {
    if (event === "describe") {
      ws.send(JSON.stringify({ event: "describe_ack", daemon: { name: "mock" }, input: { codec: "pcm_s16le" } }));
    }
  });
  try {
    const descriptor = await describeDaemon(endpointOf(server), 3000);
    expect(descriptor.event).toBe("describe_ack");
    expect((descriptor.input as Record<string, unknown>).codec).toBe("pcm_s16le");
  } finally {
    server.stop(true);
  }
});

test("transcribeFileViaDaemon collects segments/words and resolves on session_final", async () => {
  const server = startMockDaemon((event, msg, ws) => {
    if (event !== "transcribe_file") return;
    ws.send(JSON.stringify({ event: "segment_final", segment_id: 0, text: "привет", start_ms: 0, end_ms: 1000 }));
    ws.send(JSON.stringify({ event: "word_committed", segment_id: 0, index_in_segment: 0, text: "привет", start_ms: 0, end_ms: 1000, confidence: 0.9 }));
    ws.send(JSON.stringify({ event: "segment_final", segment_id: 1, text: "мир", start_ms: 1000, end_ms: 1800 }));
    ws.send(JSON.stringify({ event: "session_final", text: "привет мир", language: "ru", duration_ms: 1800, segment_count: 2, request_id: msg.request_id }));
  });
  try {
    const result = await transcribeFileViaDaemon(endpointOf(server), "C:/fake/audio.pcm", {
      requestId: "req-1",
      language: "ru",
    });
    expect(result.text).toBe("привет мир");
    expect(result.language).toBe("ru");
    expect(result.durationMs).toBe(1800);
    expect(result.segmentCount).toBe(2);
    expect(result.segments.map((s) => s.text)).toEqual(["привет", "мир"]);
    expect(result.words.length).toBe(1);
    expect(result.words[0]?.confidence).toBeCloseTo(0.9, 5);
  } finally {
    server.stop(true);
  }
});

test("transcribeFileViaDaemon rejects on daemon error event", async () => {
  const server = startMockDaemon((event, _msg, ws) => {
    if (event === "transcribe_file") {
      ws.send(JSON.stringify({ event: "error", message: "file not found" }));
    }
  });
  try {
    await expect(
      transcribeFileViaDaemon(endpointOf(server), "C:/missing.pcm", { timeoutMs: 3000 }),
    ).rejects.toBeInstanceOf(DaemonDriverError);
  } finally {
    server.stop(true);
  }
});
