import { readFile, rename, writeFile } from "node:fs/promises"

import { configJsonPath } from "./config"
import {
  ORCHESTRATOR_FIELDS,
  WS_DAEMON_FIELDS,
  resolveSelectOptions,
  type FieldSpec,
  type ReloadClass,
} from "./settings-schema"

export type ConfigObject = Record<string, unknown>

const isRecord = (value: unknown): value is ConfigObject =>
  typeof value === "object" && value !== null && !Array.isArray(value)

const validateField = (spec: FieldSpec, value: unknown, config: ConfigObject, path: string): string[] => {
  const errors: string[] = []
  if (spec.type === "int") {
    if (typeof value !== "number" || !Number.isInteger(value)) {
      errors.push(`${path}: expected an integer`)
      return errors
    }
    if (spec.min !== undefined && value < spec.min) errors.push(`${path}: must be >= ${spec.min}`)
    if (spec.max !== undefined && value > spec.max) errors.push(`${path}: must be <= ${spec.max}`)
  } else if (spec.type === "string") {
    if (typeof value !== "string" || value.trim().length === 0) {
      errors.push(`${path}: expected a non-empty string`)
    }
  } else if (spec.type === "select") {
    const options = resolveSelectOptions(spec, config)
    if (typeof value !== "string" || (options.length > 0 && !options.includes(value))) {
      errors.push(`${path}: must be one of [${options.join(", ")}]`)
    }
  }
  return errors
}

/**
 * Validate the known fields of a full config object against the schema (pure). Unknown
 * sections (speech, models) are left untouched and not validated here. Cross-field:
 * stream_chunk_ms must be >= stream_window_ms.
 */
export const validateConfig = (config: unknown): { ok: true } | { ok: false; errors: string[] } => {
  if (!isRecord(config)) {
    return { ok: false, errors: ["config must be an object"] }
  }
  const errors: string[] = []

  for (const spec of ORCHESTRATOR_FIELDS) {
    if (spec.key in config) {
      errors.push(...validateField(spec, config[spec.key], config, spec.key))
    }
  }

  if ("ws_daemons" in config) {
    if (!isRecord(config.ws_daemons)) {
      errors.push("ws_daemons: expected an object")
    } else {
      for (const [name, daemon] of Object.entries(config.ws_daemons)) {
        if (!isRecord(daemon)) {
          errors.push(`ws_daemons.${name}: expected an object`)
          continue
        }
        for (const spec of WS_DAEMON_FIELDS) {
          if (spec.key in daemon) {
            errors.push(...validateField(spec, daemon[spec.key], config, `ws_daemons.${name}.${spec.key}`))
          }
        }
      }
    }
  }

  const window = config.stream_window_ms
  const chunk = config.stream_chunk_ms
  if (typeof window === "number" && typeof chunk === "number" && chunk < window) {
    errors.push("stream_chunk_ms: must be >= stream_window_ms")
  }

  return errors.length === 0 ? { ok: true } : { ok: false, errors }
}

/** Shallow-merge incoming over current at the top level; ws_daemons merged per-daemon. */
export const mergeConfig = (current: ConfigObject, incoming: ConfigObject): ConfigObject => {
  const merged: ConfigObject = { ...current, ...incoming }
  if (isRecord(current.ws_daemons) && isRecord(incoming.ws_daemons)) {
    const wsMerged: ConfigObject = { ...current.ws_daemons }
    for (const [name, daemon] of Object.entries(incoming.ws_daemons)) {
      wsMerged[name] = isRecord(daemon) && isRecord(current.ws_daemons[name])
        ? { ...(current.ws_daemons[name] as ConfigObject), ...daemon }
        : daemon
    }
    merged.ws_daemons = wsMerged
  }
  return merged
}

/** Which reload classes are affected by fields that differ between two configs. */
export const changedReloadClasses = (current: ConfigObject, next: ConfigObject): Set<ReloadClass> => {
  const classes = new Set<ReloadClass>()
  for (const spec of ORCHESTRATOR_FIELDS) {
    if (JSON.stringify(current[spec.key]) !== JSON.stringify(next[spec.key])) {
      classes.add(spec.reload)
    }
  }
  if (JSON.stringify(current.ws_daemons) !== JSON.stringify(next.ws_daemons)) {
    classes.add("hot") // ws_daemons routing is read per-dispatch
  }
  return classes
}

export const readConfig = async (): Promise<ConfigObject> => {
  const parsed: unknown = JSON.parse(await readFile(configJsonPath, "utf-8"))
  if (!isRecord(parsed)) {
    throw new Error("config.json is not an object")
  }
  return parsed
}

const writeConfigAtomic = async (config: ConfigObject): Promise<void> => {
  const tempPath = `${configJsonPath}.${process.pid}.${crypto.randomUUID()}.tmp`
  await writeFile(tempPath, `${JSON.stringify(config, null, 2)}\n`, "utf-8")
  await rename(tempPath, configJsonPath)
}

export interface ApplyResult {
  readonly config: ConfigObject
  readonly restartRequired: boolean
}

/**
 * Merge an incoming (full or partial) config over the current one, validate, and write it
 * atomically (temp + rename — the control-server is the single writer, CP-D2). Returns the
 * new config and whether any restart-required field changed.
 */
export const applyConfig = async (incoming: unknown): Promise<ApplyResult> => {
  if (!isRecord(incoming)) {
    throw new Error("request body must be a config object")
  }
  const current = await readConfig()
  const merged = mergeConfig(current, incoming)
  const validation = validateConfig(merged)
  if (!validation.ok) {
    const error = new Error(validation.errors.join("; "))
    ;(error as Error & { code?: string }).code = "VALIDATION"
    throw error
  }
  await writeConfigAtomic(merged)
  return { config: merged, restartRequired: changedReloadClasses(current, merged).has("restart") }
}
