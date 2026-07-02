import { test, expect } from "bun:test";

import {
  parseRegistration,
  isRegistrationFresh,
  isRegistrationReady,
  DaemonRegistry,
  type Clock,
} from "./daemon-registry";

const baseRaw = (overrides: Record<string, unknown> = {}): Record<string, unknown> => ({
  name: "whisperdaemon",
  host: "127.0.0.1",
  port: 7801,
  model_name: "whisper_podlodka",
  state: "ready",
  pid: 45728,
  input: { codec: "pcm16le", sample_rate_hz: 16000, channels: 1 },
  updated_at: "2026-07-02T12:00:00.000Z",
  ...overrides,
});

const mutableClock = (start: number): Clock & { set: (ms: number) => void } => {
  let now = start;
  return { now: () => now, set: (ms: number) => (now = ms) };
};

const AT = Date.parse("2026-07-02T12:00:00.000Z");

test("parseRegistration accepts a well-formed record and derives updatedAtMs", () => {
  const reg = parseRegistration(baseRaw());
  expect(reg).not.toBeNull();
  expect(reg?.name).toBe("whisperdaemon");
  expect(reg?.port).toBe(7801);
  expect(reg?.modelName).toBe("whisper_podlodka");
  expect(reg?.state).toBe("ready");
  expect(reg?.pid).toBe(45728);
  expect(reg?.input).toEqual({ codec: "pcm16le", sampleRateHz: 16000, channels: 1 });
  expect(reg?.updatedAtMs).toBe(AT);
});

test("parseRegistration rejects malformed / half-written records", () => {
  expect(parseRegistration(null)).toBeNull();
  expect(parseRegistration("not json")).toBeNull();
  expect(parseRegistration(baseRaw({ name: "" }))).toBeNull();
  expect(parseRegistration(baseRaw({ port: "7801" }))).toBeNull();
  expect(parseRegistration(baseRaw({ port: 0 }))).toBeNull();
  expect(parseRegistration(baseRaw({ model_name: undefined }))).toBeNull();
  expect(parseRegistration(baseRaw({ updated_at: "nonsense" }))).toBeNull();
  expect(parseRegistration(baseRaw({ updated_at: undefined }))).toBeNull();
});

test("parseRegistration tolerates optional pid/input", () => {
  const reg = parseRegistration(baseRaw({ pid: undefined, input: undefined }));
  expect(reg).not.toBeNull();
  expect(reg?.pid).toBeNull();
  expect(reg?.input).toBeNull();
});

test("freshness is bounded by TTL", () => {
  const reg = parseRegistration(baseRaw())!;
  const ttl = 15000;
  expect(isRegistrationFresh(reg, AT + 10000, ttl)).toBe(true);
  expect(isRegistrationFresh(reg, AT + 15000, ttl)).toBe(true);
  expect(isRegistrationFresh(reg, AT + 15001, ttl)).toBe(false);
  // Small clock skew (heartbeat slightly in the future) still counts as fresh.
  expect(isRegistrationFresh(reg, AT - 2000, ttl)).toBe(true);
});

test("readiness requires state=ready AND freshness", () => {
  const ttl = 15000;
  const ready = parseRegistration(baseRaw())!;
  const loading = parseRegistration(baseRaw({ state: "loading" }))!;
  expect(isRegistrationReady(ready, AT + 5000, ttl)).toBe(true);
  expect(isRegistrationReady(loading, AT + 5000, ttl)).toBe(false); // fresh but not ready
  expect(isRegistrationReady(ready, AT + 20000, ttl)).toBe(false); // ready but stale
});

test("DaemonRegistry.isReady honours state + TTL via the injected clock", () => {
  const clock = mutableClock(AT + 1000);
  const registry = new DaemonRegistry(15000, clock);
  registry.upsert(parseRegistration(baseRaw())!);

  expect(registry.isReady("whisperdaemon")).toBe(true);
  clock.set(AT + 20000); // heartbeat now stale
  expect(registry.isReady("whisperdaemon")).toBe(false);
  expect(registry.get("whisperdaemon")).not.toBeNull(); // raw entry still present
});

test("DaemonRegistry.readyForModel skips stale/non-ready and finds the ready one", () => {
  const clock = mutableClock(AT + 1000);
  const registry = new DaemonRegistry(15000, clock);
  // stale whisper, fresh-but-loading vibevoice, fresh-ready vosk
  registry.upsert(parseRegistration(baseRaw({ name: "whisperdaemon", model_name: "whisper_podlodka", updated_at: "2026-07-02T11:00:00.000Z" }))!);
  registry.upsert(parseRegistration(baseRaw({ name: "vibevoice", model_name: "vibevoice", state: "loading" }))!);
  registry.upsert(parseRegistration(baseRaw({ name: "voskru", model_name: "vosk_ru", port: 7701 }))!);

  expect(registry.readyForModel("whisper_podlodka")).toBeNull(); // stale
  expect(registry.readyForModel("vibevoice")).toBeNull(); // loading
  const vosk = registry.readyForModel("vosk_ru");
  expect(vosk?.name).toBe("voskru");
  expect(vosk?.port).toBe(7701);
  expect(registry.readyNames()).toEqual(["voskru"]);
});

test("DaemonRegistry.remove drops the entry", () => {
  const registry = new DaemonRegistry(15000, mutableClock(AT));
  registry.upsert(parseRegistration(baseRaw())!);
  expect(registry.isReady("whisperdaemon")).toBe(true);
  registry.remove("whisperdaemon");
  expect(registry.get("whisperdaemon")).toBeNull();
  expect(registry.isReady("whisperdaemon")).toBe(false);
});
