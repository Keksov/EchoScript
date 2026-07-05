import { test, expect } from "bun:test"

import { validateConfig, mergeConfig, changedReloadClasses, type ConfigObject } from "./settings"

const base: ConfigObject = {
  max_workers: 1,
  poll_interval_ms: 500,
  stream_window_ms: 30000,
  stream_chunk_ms: 120000,
  daemon_registry_ttl_ms: 15000,
  drop_stable_ms: 2000,
  max_requeue_attempts: 5,
  default_model: "whisper_podlodka",
  ffmpeg_path: "./tools/ffmpeg/ffmpeg.exe",
  jobs_root: "./jobs",
  ws_daemons: {
    whisperdaemon: { host: "127.0.0.1", port: 7801, engine: "whisper", language: "ru", model_name: "whisper_podlodka" },
  },
  models: { whisper_podlodka: {}, whisper_en_turbo: {} },
}

test("valid config passes", () => {
  expect(validateConfig(base)).toEqual({ ok: true })
})

test("non-integer / out-of-range scalars are rejected", () => {
  const r = validateConfig({ ...base, max_workers: 0, poll_interval_ms: 10 })
  expect(r.ok).toBe(false)
  if (!r.ok) {
    expect(r.errors.some((e) => e.includes("max_workers"))).toBe(true)
    expect(r.errors.some((e) => e.includes("poll_interval_ms"))).toBe(true)
  }
})

test("stream_chunk_ms must be >= stream_window_ms", () => {
  const r = validateConfig({ ...base, stream_window_ms: 30000, stream_chunk_ms: 10000 })
  expect(r.ok).toBe(false)
})

test("default_model must be a known model", () => {
  expect(validateConfig({ ...base, default_model: "nope" }).ok).toBe(false)
  expect(validateConfig({ ...base, default_model: "whisper_en_turbo" }).ok).toBe(true)
})

test("ws_daemon port out of range is rejected", () => {
  const bad = { ...base, ws_daemons: { d: { host: "127.0.0.1", port: 70000, model_name: "m" } } }
  expect(validateConfig(bad).ok).toBe(false)
})

test("mergeConfig keeps untouched sections and merges ws_daemons per-daemon", () => {
  const merged = mergeConfig(base, {
    max_workers: 2,
    ws_daemons: { whisperdaemon: { port: 7999 } },
  })
  expect(merged.max_workers).toBe(2)
  expect(merged.models).toEqual(base.models) // untouched
  const wd = (merged.ws_daemons as ConfigObject).whisperdaemon as ConfigObject
  expect(wd.port).toBe(7999) // overridden
  expect(wd.language).toBe("ru") // preserved from current
})

test("changedReloadClasses flags restart for jobs_root and hot for intervals", () => {
  expect(changedReloadClasses(base, { ...base, jobs_root: "./other" }).has("restart")).toBe(true)
  expect(changedReloadClasses(base, { ...base, poll_interval_ms: 750 }).has("hot")).toBe(true)
  expect([...changedReloadClasses(base, base)]).toEqual([])
})

test("daemon launch fields validate as float/bool and don't affect orchestrator reload", () => {
  const withVad = mergeConfig(base, { ws_daemons: { whisperdaemon: { vad: true, vad_threshold: 0.4, no_speech_thold: 0.6 } } })
  expect(validateConfig(withVad)).toEqual({ ok: true })
  expect(validateConfig(mergeConfig(base, { ws_daemons: { whisperdaemon: { vad_threshold: 1.5 } } })).ok).toBe(false)
  expect(validateConfig(mergeConfig(base, { ws_daemons: { whisperdaemon: { vad: "yes" } } })).ok).toBe(false)

  // changing a daemon launch field is a daemon-restart concern, not an orchestrator one
  const changed = mergeConfig(base, { ws_daemons: { whisperdaemon: { vad_threshold: 0.7 } } })
  expect([...changedReloadClasses(base, changed)]).toEqual([])
  // but a routing field (port) still flags hot for the orchestrator
  const routed = mergeConfig(base, { ws_daemons: { whisperdaemon: { port: 7999 } } })
  expect(changedReloadClasses(base, routed).has("hot")).toBe(true)
})
