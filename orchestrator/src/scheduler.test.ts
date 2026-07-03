import { test, expect } from "bun:test";

import { selectDispatchable, exceededRequeueCap } from "./scheduler";
import type { WsDaemonConfig } from "./config";
import type { QueuedJob } from "./job-manager";

const job = (jobId: string, targetModel: string): QueuedJob => ({ jobId, targetModel });

// ws-daemon models and which of them are currently ready (fresh registration)
const makeDeps = (wsModels: Record<string, WsDaemonConfig>, readyModels: Set<string>) => ({
  findWsDaemon: (model: string): WsDaemonConfig | null => wsModels[model] ?? null,
  readyEndpoint: (model: string): WsDaemonConfig | null =>
    readyModels.has(model) ? { host: "10.0.0.1", port: 9999, modelName: model } : null,
});

const WS: Record<string, WsDaemonConfig> = {
  whisper_podlodka: { host: "127.0.0.1", port: 7801, modelName: "whisper_podlodka" },
};

test("python-model job is always dispatchable (null wsEndpoint)", () => {
  const deps = makeDeps(WS, new Set());
  const choice = selectDispatchable([job("j1", "vosk_ru")], deps.findWsDaemon, deps.readyEndpoint);
  expect(choice?.job.jobId).toBe("j1");
  expect(choice?.wsEndpoint).toBeNull();
});

test("ready ws-daemon job dispatches to the announced endpoint", () => {
  const deps = makeDeps(WS, new Set(["whisper_podlodka"]));
  const choice = selectDispatchable([job("j1", "whisper_podlodka")], deps.findWsDaemon, deps.readyEndpoint);
  expect(choice?.job.jobId).toBe("j1");
  expect(choice?.wsEndpoint).toEqual({ host: "10.0.0.1", port: 9999, modelName: "whisper_podlodka" });
});

test("not-ready ws-daemon job at the head does NOT block a later dispatchable job", () => {
  const deps = makeDeps(WS, new Set()); // whisper not ready
  const choice = selectDispatchable(
    [job("head", "whisper_podlodka"), job("tail", "vosk_ru")],
    deps.findWsDaemon,
    deps.readyEndpoint,
  );
  expect(choice?.job.jobId).toBe("tail"); // skipped the not-ready head (no HOL blocking)
});

test("head not-ready ws, second ready ws -> picks the ready one", () => {
  const ws = {
    ...WS,
    vibevoice: { host: "127.0.0.1", port: 7802, modelName: "vibevoice" } as WsDaemonConfig,
  };
  const deps = makeDeps(ws, new Set(["vibevoice"]));
  const choice = selectDispatchable(
    [job("a", "whisper_podlodka"), job("b", "vibevoice")],
    deps.findWsDaemon,
    deps.readyEndpoint,
  );
  expect(choice?.job.jobId).toBe("b");
  expect(choice?.wsEndpoint?.modelName).toBe("vibevoice");
});

test("nothing dispatchable when all ws-daemons are not ready -> null", () => {
  const deps = makeDeps(WS, new Set());
  const choice = selectDispatchable([job("j1", "whisper_podlodka")], deps.findWsDaemon, deps.readyEndpoint);
  expect(choice).toBeNull();
});

test("empty queue -> null", () => {
  const deps = makeDeps(WS, new Set());
  expect(selectDispatchable([], deps.findWsDaemon, deps.readyEndpoint)).toBeNull();
});

test("exceededRequeueCap fires at/after the cap (0 = never requeue)", () => {
  expect(exceededRequeueCap(0, 5)).toBe(false);
  expect(exceededRequeueCap(4, 5)).toBe(false);
  expect(exceededRequeueCap(5, 5)).toBe(true);
  expect(exceededRequeueCap(6, 5)).toBe(true);
  expect(exceededRequeueCap(0, 0)).toBe(true);
});
