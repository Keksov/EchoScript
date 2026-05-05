import { stat } from "node:fs/promises"

import type { AppConfig } from "./config"
import { JobManager } from "./job-manager"
import { getNodeErrorCode } from "./node-error"

export type SpeechMode = "command" | "dictation"
export type SpeechLanguage = "ru"

export interface BufferedSpeechRequest {
  readonly mode: SpeechMode
  readonly language: SpeechLanguage
  readonly timeoutMs: number
  readonly speakerEmbeddings: boolean | null
}

export interface BufferedSpeechResultPayload {
  readonly normalized: Record<string, unknown>
  readonly raw: Record<string, unknown>
}

export type BufferedSpeechCommandStatus = "matched" | "not_command"

export interface BufferedSpeechResponse {
  readonly job_id: string
  readonly mode: SpeechMode
  readonly transport: "buffered_http"
  readonly target_model: string
  readonly command_status: BufferedSpeechCommandStatus | null
  readonly status: "ready"
  readonly is_final: true
  readonly speaker_aware: boolean
  readonly text: string
  readonly language: string
  readonly segments: readonly unknown[] | null
  readonly normalized: Record<string, unknown>
  readonly raw: Record<string, unknown>
}

export class InvalidSpeechRequestError extends Error {}
export class SpeechConfigurationError extends Error {}

export class SpeechProcessingTimeoutError extends Error {
  public constructor(
    public readonly jobId: string,
    message: string,
  ) {
    super(message)
  }
}

export class SpeechJobFailedError extends Error {
  public constructor(
    public readonly jobId: string,
    message: string,
  ) {
    super(message)
  }
}

const DEFAULT_BUFFERED_TIMEOUT_MS = 300_000
const MAX_BUFFERED_TIMEOUT_MS = 600_000
const STATUS_POLL_INTERVAL_MS = 200

interface StatusEntry {
  readonly status: string
  readonly error?: unknown
}

const isRecord = (value: unknown): value is Record<string, unknown> => {
  return typeof value === "object" && value !== null && !Array.isArray(value)
}

const asOptionalString = (value: unknown): string | null => {
  return typeof value === "string" && value.trim().length > 0 ? value : null
}

const asPositiveInteger = (value: string | undefined): number | null => {
  if (value === undefined || value.length === 0) {
    return null
  }

  const parsed = Number.parseInt(value, 10)
  if (!Number.isInteger(parsed) || parsed <= 0) {
    return null
  }

  return parsed
}

const asOptionalBoolean = (value: string | undefined): boolean | null => {
  if (value === undefined || value.length === 0) {
    return null
  }

  const normalized = value.trim().toLowerCase()
  if (normalized === "1" || normalized === "true" || normalized === "yes") {
    return true
  }

  if (normalized === "0" || normalized === "false" || normalized === "no") {
    return false
  }

  return null
}

const getLastStatusEntry = (payload: unknown): StatusEntry | null => {
  if (!Array.isArray(payload) || payload.length === 0) {
    return null
  }

  const lastEntry = payload[payload.length - 1]
  if (!isRecord(lastEntry) || typeof lastEntry.status !== "string") {
    return null
  }

  return {
    status: lastEntry.status,
    error: lastEntry.error,
  }
}

const getFailureMessage = (statusEntry: StatusEntry): string => {
  if (typeof statusEntry.error === "string" && statusEntry.error.length > 0) {
    return statusEntry.error
  }

  return "Speech job failed"
}

const assertSpeechMode = (value: string | undefined): SpeechMode => {
  if (value === "command" || value === "dictation") {
    return value
  }

  throw new InvalidSpeechRequestError("mode query parameter must be 'command' or 'dictation'")
}

const assertSpeechLanguage = (value: string | undefined): SpeechLanguage => {
  if (value === undefined || value.length === 0 || value === "ru") {
    return "ru"
  }

  throw new InvalidSpeechRequestError("language query parameter must be 'ru'")
}

const assertResultPayload = (payload: unknown): BufferedSpeechResultPayload => {
  if (!isRecord(payload) || !isRecord(payload.normalized) || !isRecord(payload.raw)) {
    throw new SpeechConfigurationError("Speech result payload is invalid")
  }

  return {
    normalized: payload.normalized,
    raw: payload.raw,
  }
}

export const parseBufferedSpeechRequest = (
  rawMode: string | undefined,
  rawLanguage: string | undefined,
  rawTimeoutMs: string | undefined,
  rawSpeakerEmbeddings: string | undefined,
): BufferedSpeechRequest => {
  const timeoutMs = asPositiveInteger(rawTimeoutMs) ?? DEFAULT_BUFFERED_TIMEOUT_MS
  if (timeoutMs > MAX_BUFFERED_TIMEOUT_MS) {
    throw new InvalidSpeechRequestError(`timeout_ms cannot exceed ${MAX_BUFFERED_TIMEOUT_MS}`)
  }

  const speakerEmbeddings = asOptionalBoolean(rawSpeakerEmbeddings)
  if (rawSpeakerEmbeddings !== undefined && speakerEmbeddings === null) {
    throw new InvalidSpeechRequestError("speaker_embeddings query parameter must be true/false/1/0")
  }

  return {
    mode: assertSpeechMode(rawMode),
    language: assertSpeechLanguage(rawLanguage),
    timeoutMs,
    speakerEmbeddings,
  }
}

export const resolveSpeechTargetModel = (
  config: AppConfig,
  request: BufferedSpeechRequest,
): string => {
  let targetModel: string | null = null

  if (request.language === "ru") {
    targetModel = request.mode === "command" ? "vosk_ru_cmd" : "vosk_ru"
  }

  if (targetModel === null || !(targetModel in config.models)) {
    throw new SpeechConfigurationError(
      `No speech model is configured for language '${request.language}' and mode '${request.mode}'`,
    )
  }

  return targetModel
}

const getProvisioningScripts = (targetModel: string): readonly string[] => {
  if (targetModel === "vosk_ru_cmd") {
    return ["services\\vosk_ru_cmd\\scripts\\setup_vosk_ru_cmd.bat", "services\\vosk_ru_cmd\\scripts\\download_vosk_ru_cmd.bat"]
  }

  if (targetModel === "vosk_ru") {
    return ["services\\vosk_ru\\scripts\\setup_vosk_ru.bat", "services\\vosk_ru\\scripts\\download_vosk_ru.bat"]
  }

  return []
}

const buildProvisioningMessage = (targetModel: string, details: string): string => {
  const scripts = getProvisioningScripts(targetModel)
  if (scripts.length === 0) {
    return `Speech model '${targetModel}' is not provisioned: ${details}`
  }

  return `Speech model '${targetModel}' is not provisioned: ${details}. Run ${scripts.join(" and ")} on this machine first.`
}

export const assertSpeechTargetProvisioned = async (
  config: AppConfig,
  targetModel: string,
): Promise<void> => {
  const modelConfig = config.models[targetModel]

  try {
    await stat(modelConfig.serviceDir)
  } catch (error) {
    if (getNodeErrorCode(error) === "ENOENT") {
      throw new SpeechConfigurationError(
        buildProvisioningMessage(targetModel, `missing service directory at ${modelConfig.serviceDir}`),
      )
    }

    throw error
  }

  try {
    await stat(modelConfig.pythonExecutable)
  } catch (error) {
    if (getNodeErrorCode(error) === "ENOENT") {
      throw new SpeechConfigurationError(
        buildProvisioningMessage(targetModel, `missing Python runtime at ${modelConfig.pythonExecutable}`),
      )
    }

    throw error
  }
}

const getCommandGrammar = (
  config: AppConfig,
  language: SpeechLanguage,
): readonly string[] => {
  const grammar = config.speech.commandGrammars[language]
  if (grammar === undefined || grammar.length === 0) {
    throw new SpeechConfigurationError(`No command grammar is configured for language '${language}'`)
  }

  return grammar
}

export const buildBufferedSpeechParams = (
  config: AppConfig,
  request: BufferedSpeechRequest,
): Record<string, unknown> => {
  const speakerEmbeddings = request.speakerEmbeddings ?? false

  if (request.mode === "command") {
    return {
      language: request.language,
      grammar: [...getCommandGrammar(config, request.language)],
      punctuation: false,
      speaker_embeddings: speakerEmbeddings,
      timestamps: false,
      word_timestamps: false,
    }
  }

  return {
    language: request.language,
    punctuation: true,
    speaker_embeddings: speakerEmbeddings,
    timestamps: true,
    word_timestamps: true,
  }
}

export const getBufferedSpeechText = (
  resultPayload: BufferedSpeechResultPayload,
): string | null => {
  return asOptionalString(resultPayload.normalized.text)
}

export const hasBufferedSpeechText = (
  resultPayload: BufferedSpeechResultPayload,
): boolean => {
  return getBufferedSpeechText(resultPayload) !== null
}

export const waitForBufferedSpeechResult = async (
  jobManager: JobManager,
  jobId: string,
  timeoutMs: number,
): Promise<BufferedSpeechResultPayload> => {
  const startedAt = Date.now()

  while (Date.now() - startedAt < timeoutMs) {
    const statusPayload = await jobManager.getJobStatus(jobId)
    const lastStatusEntry = getLastStatusEntry(statusPayload)
    if (lastStatusEntry !== null) {
      if (lastStatusEntry.status === "ready") {
        return assertResultPayload(await jobManager.getJobResult(jobId))
      }

      if (lastStatusEntry.status === "failed") {
        throw new SpeechJobFailedError(jobId, getFailureMessage(lastStatusEntry))
      }
    }

    await Bun.sleep(STATUS_POLL_INTERVAL_MS)
  }

  throw new SpeechProcessingTimeoutError(jobId, `Timed out waiting for speech result for ${jobId}`)
}

export const buildBufferedSpeechResponse = (
  jobId: string,
  request: BufferedSpeechRequest,
  targetModel: string,
  resultPayload: BufferedSpeechResultPayload,
  commandStatus: BufferedSpeechCommandStatus | null = request.mode === "command" ? "matched" : null,
): BufferedSpeechResponse => {
  const text = getBufferedSpeechText(resultPayload)
  if (text === null) {
    throw new SpeechConfigurationError("Speech response is missing normalized.text")
  }

  const language = asOptionalString(resultPayload.normalized.language) ?? request.language
  const segments = Array.isArray(resultPayload.normalized.segments) ? resultPayload.normalized.segments : null

  return {
    job_id: jobId,
    mode: request.mode,
    transport: "buffered_http",
    target_model: targetModel,
    command_status: commandStatus,
    status: "ready",
    is_final: true,
    speaker_aware: request.speakerEmbeddings === true,
    text,
    language,
    segments,
    normalized: resultPayload.normalized,
    raw: resultPayload.raw,
  }
}
