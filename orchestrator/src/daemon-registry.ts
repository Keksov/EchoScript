/**
 * Daemon registry (pure core) — see orchestrator/spec/jobs-drop-daemon-registry-plan.md.
 *
 * Recognition daemons self-register by writing jobs/registry/<name>.json with their
 * readiness, host/port and input format, refreshing `updated_at` as a heartbeat. This
 * module is the framework-free core: parse/validate a registration record, decide
 * readiness by state + TTL freshness (injectable clock), and hold the live map the
 * scheduler consults before dispatching a ws-daemon job. The fs watcher/scan that
 * feeds it lives in DR1.2; registration invalidation/backoff in DR1.4.
 */

export const DEFAULT_REGISTRY_TTL_MS = 15000;

export interface DaemonInputFormat {
  readonly codec: string;
  readonly sampleRateHz: number;
  readonly channels: number;
}

export interface DaemonRegistration {
  readonly name: string;
  readonly host: string;
  readonly port: number;
  readonly modelName: string;
  readonly state: string;
  readonly pid: number | null;
  readonly input: DaemonInputFormat | null;
  readonly updatedAt: string;
  /** `updated_at` parsed to epoch ms (derived at parse time). */
  readonly updatedAtMs: number;
}

export interface Clock {
  now(): number;
}

export const systemClock: Clock = { now: (): number => Date.now() };

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value);

const asString = (value: unknown): string | null =>
  typeof value === "string" && value.length > 0 ? value : null;

const asFiniteNumber = (value: unknown): number | null =>
  typeof value === "number" && Number.isFinite(value) ? value : null;

const parseTimestampMs = (value: unknown): number | null => {
  const text = asString(value);
  if (text === null) {
    return null;
  }
  const ms = Date.parse(text);
  return Number.isNaN(ms) ? null : ms;
};

const parseInput = (value: unknown): DaemonInputFormat | null => {
  if (!isRecord(value)) {
    return null;
  }
  const codec = asString(value.codec);
  const sampleRateHz = asFiniteNumber(value.sample_rate_hz);
  const channels = asFiniteNumber(value.channels);
  if (codec === null || sampleRateHz === null || channels === null) {
    return null;
  }
  return { codec, sampleRateHz, channels };
};

/**
 * Validate a raw registration payload. Returns null on anything malformed so the
 * watcher can simply ignore bad/half-written files. Required: name, host, numeric
 * port, model_name, state, parseable updated_at.
 */
export const parseRegistration = (raw: unknown): DaemonRegistration | null => {
  if (!isRecord(raw)) {
    return null;
  }
  const name = asString(raw.name);
  const host = asString(raw.host);
  const port = asFiniteNumber(raw.port);
  const modelName = asString(raw.model_name);
  const state = asString(raw.state);
  const updatedAtMs = parseTimestampMs(raw.updated_at);
  if (name === null || host === null || port === null || port <= 0 || modelName === null || state === null || updatedAtMs === null) {
    return null;
  }
  return {
    name,
    host,
    port: Math.trunc(port),
    modelName,
    state,
    pid: asFiniteNumber(raw.pid) !== null ? Math.trunc(raw.pid as number) : null,
    input: parseInput(raw.input),
    updatedAt: raw.updated_at as string,
    updatedAtMs,
  };
};

/** A registration is fresh if its heartbeat is within `ttlMs` of `nowMs`. */
export const isRegistrationFresh = (reg: DaemonRegistration, nowMs: number, ttlMs: number): boolean =>
  nowMs - reg.updatedAtMs <= ttlMs;

/** Ready = declares state "ready" AND its heartbeat is still fresh. */
export const isRegistrationReady = (reg: DaemonRegistration, nowMs: number, ttlMs: number): boolean =>
  reg.state === "ready" && isRegistrationFresh(reg, nowMs, ttlMs);

/**
 * Live map of daemon registrations. Readiness decisions use the injected clock and
 * the TTL so a stale heartbeat (crashed daemon that never removed its file) is not
 * treated as ready.
 */
export class DaemonRegistry {
  private readonly entries = new Map<string, DaemonRegistration>();

  public constructor(
    private readonly ttlMs: number = DEFAULT_REGISTRY_TTL_MS,
    private readonly clock: Clock = systemClock,
  ) {}

  public upsert(registration: DaemonRegistration): void {
    this.entries.set(registration.name, registration);
  }

  public remove(name: string): void {
    this.entries.delete(name);
  }

  public clear(): void {
    this.entries.clear();
  }

  /** Raw entry regardless of freshness (or null). */
  public get(name: string): DaemonRegistration | null {
    return this.entries.get(name) ?? null;
  }

  public isReady(name: string): boolean {
    const reg = this.entries.get(name);
    return reg !== undefined && isRegistrationReady(reg, this.clock.now(), this.ttlMs);
  }

  /** First ready registration serving `modelName`, else null. */
  public readyForModel(modelName: string): DaemonRegistration | null {
    const now = this.clock.now();
    for (const reg of this.entries.values()) {
      if (reg.modelName === modelName && isRegistrationReady(reg, now, this.ttlMs)) {
        return reg;
      }
    }
    return null;
  }

  /** Names of all currently ready daemons. */
  public readyNames(): string[] {
    const now = this.clock.now();
    const names: string[] = [];
    for (const reg of this.entries.values()) {
      if (isRegistrationReady(reg, now, this.ttlMs)) {
        names.push(reg.name);
      }
    }
    return names;
  }
}
