import { test, expect } from "bun:test"

import { computeDaemonStatuses, type RegistryEntry, type WsDaemonConfig } from "./status"

const NOW = 1_000_000
const TTL = 15_000

const wsDaemons: Record<string, WsDaemonConfig> = {
  whisperdaemon: { host: "127.0.0.1", port: 7801, engine: "whisper", language: "ru", model_name: "whisper_podlodka" },
  whisperdaemon_en: { host: "127.0.0.1", port: 7802, engine: "whisper", language: "en", model_name: "whisper_en_turbo" },
}

const reg = (over: Partial<RegistryEntry>): RegistryEntry => ({
  host: "127.0.0.1",
  port: 7801,
  state: "ready",
  pid: 100,
  updated_at: new Date(NOW).toISOString(),
  ...over,
})

test("fresh registry entry within TTL is ready", () => {
  const [ru] = computeDaemonStatuses(
    { whisperdaemon: wsDaemons.whisperdaemon! },
    [reg({ model_name: "whisper_podlodka", updated_at: new Date(NOW - 5_000).toISOString() })],
    TTL,
    NOW,
  )
  expect(ru!.configured).toBe(true)
  expect(ru!.registered).toBe(true)
  expect(ru!.fresh).toBe(true)
  expect(ru!.state).toBe("ready")
  expect(ru!.pid).toBe(100)
})

test("registry entry older than TTL is stale (registered but not fresh)", () => {
  const [ru] = computeDaemonStatuses(
    { whisperdaemon: wsDaemons.whisperdaemon! },
    [reg({ model_name: "whisper_podlodka", updated_at: new Date(NOW - 20_000).toISOString() })],
    TTL,
    NOW,
  )
  expect(ru!.registered).toBe(true)
  expect(ru!.fresh).toBe(false)
})

test("configured daemon with no registry entry is down", () => {
  const [en] = computeDaemonStatuses({ whisperdaemon_en: wsDaemons.whisperdaemon_en! }, [], TTL, NOW)
  expect(en!.configured).toBe(true)
  expect(en!.registered).toBe(false)
  expect(en!.fresh).toBe(false)
  expect(en!.pid).toBeNull()
})

test("registry entry with no matching config is surfaced as an orphan", () => {
  const statuses = computeDaemonStatuses(
    {},
    [reg({ model_name: "whisper_ghost", name: "ghostdaemon" })],
    TTL,
    NOW,
  )
  expect(statuses).toHaveLength(1)
  expect(statuses[0]!.configured).toBe(false)
  expect(statuses[0]!.registered).toBe(true)
  expect(statuses[0]!.name).toBe("ghostdaemon")
})

test("merges config endpoint when registry lacks it, prefers registry when present", () => {
  const [ru] = computeDaemonStatuses(
    { whisperdaemon: wsDaemons.whisperdaemon! },
    [reg({ model_name: "whisper_podlodka", host: "10.0.0.5", port: 9999 })],
    TTL,
    NOW,
  )
  expect(ru!.host).toBe("10.0.0.5") // registry wins (announced endpoint)
  expect(ru!.port).toBe(9999)
})
