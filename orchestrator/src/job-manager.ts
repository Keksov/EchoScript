import { randomUUID } from "node:crypto";
import { mkdir, readFile, readdir, rename, rm, stat, unlink } from "node:fs/promises";
import path from "node:path";
import process from "node:process";

import type { AppConfig } from "./config";
import { getNodeErrorCode } from "./node-error";

export class InvalidJobError extends Error {}
export class UnknownModelError extends Error {}
export class JobNotFoundError extends Error {}
export class JobResultNotFoundError extends Error {}

export interface CreatedJob {
  readonly jobId: string;
  readonly model: string | null;
  readonly dataDir: string;
}

export interface QueuedJob {
  readonly jobId: string;
  readonly targetModel: string;
}

export interface ListedJob {
  readonly job_id: string;
  readonly model: string | null;
  readonly current_status: string | null;
  readonly created_at: string | null;
  readonly updated_at: string | null;
  readonly has_result: boolean;
  readonly source: string | null;
  readonly original_filename: string | null;
}

export type JobResultType = "raw" | "normalized" | "plain" | "timestamp";

const MAX_JOB_ID_LENGTH = 200;
const JOB_ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9_-]*$/;
const RESULT_JSON_FILE_NAME = "result.json";
const RESULT_TEXT_FILE_NAMES = {
  plain: "result_plain.txt",
  timestamp: "result_timestamp.txt",
} as const;

const isRecord = (value: unknown): value is Record<string, unknown> => {
  return typeof value === "object" && value !== null && !Array.isArray(value);
};

const nowIso = (): string => new Date().toISOString();

const normalizeForComparison = (value: string): string => {
  const resolved = path.resolve(value);
  return process.platform === "win32" ? resolved.toLowerCase() : resolved;
};

const getKnownModelsBySpecificity = (knownModels: readonly string[]): string[] => {
  return [...knownModels].sort((left, right) => {
    if (right.length !== left.length) {
      return right.length - left.length;
    }

    return left.localeCompare(right);
  });
};

const getJobSequence = (jobId: string): number => {
  const separatorIndex = jobId.indexOf("_");
  const rawSequence = separatorIndex === -1 ? jobId : jobId.slice(0, separatorIndex);
  const parsedSequence = Number.parseInt(rawSequence, 10);
  return Number.isFinite(parsedSequence) ? parsedSequence : 0;
};

const isWithinRoot = (targetPath: string, rootPath: string): boolean => {
  const normalizedTarget = normalizeForComparison(targetPath);
  const normalizedRoot = normalizeForComparison(rootPath);
  if (normalizedTarget === normalizedRoot) {
    return true;
  }

  return normalizedTarget.startsWith(`${normalizedRoot}${path.sep}`);
};

export const assertValidJobId = (jobId: string): void => {
  if (jobId.length === 0 || jobId.length > MAX_JOB_ID_LENGTH) {
    throw new InvalidJobError(`Invalid job_id format: ${jobId}`);
  }

  if (!JOB_ID_PATTERN.test(jobId) || jobId.includes("..")) {
    throw new InvalidJobError(`Invalid job_id format: ${jobId}`);
  }
};

export const assertValidJobResultType = (resultType: string): JobResultType => {
  if (resultType === "raw" || resultType === "normalized" || resultType === "plain" || resultType === "timestamp") {
    return resultType;
  }

  throw new InvalidJobError(`Invalid result type: ${resultType}`);
};

const writeJson = async (filePath: string, payload: unknown): Promise<void> => {
  const tempPath = `${filePath}.${process.pid}.${Date.now()}.tmp`;
  await Bun.write(tempPath, JSON.stringify(payload, null, 2));
  try {
    await rename(tempPath, filePath);
  } catch (error) {
    const code = getNodeErrorCode(error);
    if (code === "EEXIST" || code === "EPERM") {
      await removeIfExists(filePath);
      await rename(tempPath, filePath);
      return;
    }

    await removeIfExists(tempPath);
    throw error;
  }
};

const readJson = async (filePath: string): Promise<unknown> => {
  return JSON.parse(await readFile(filePath, "utf-8"));
};

const removeIfExists = async (filePath: string): Promise<void> => {
  try {
    await unlink(filePath);
  } catch (error) {
    if (getNodeErrorCode(error) !== "ENOENT") {
      throw error;
    }
  }
};

export const getModelFromJobId = (jobId: string, knownModels: readonly string[] = []): string | null => {
  assertValidJobId(jobId);
  const parts = jobId.split("_");
  if (parts.length < 3) {
    throw new InvalidJobError(`Invalid job_id format: ${jobId}`);
  }

  const jobSuffix = parts.slice(2).join("_");
  if (jobSuffix.length === 0) {
    throw new InvalidJobError(`Invalid job_id format: ${jobId}`);
  }

  if (jobSuffix === "common") {
    return null;
  }

  for (const modelName of getKnownModelsBySpecificity(knownModels)) {
    if (jobSuffix === modelName || jobSuffix.startsWith(`${modelName}_`)) {
      return modelName;
    }
  }

  if (knownModels.length === 0) {
    return jobSuffix;
  }

  throw new InvalidJobError(`Unable to resolve model from job_id: ${jobId}`);
};

interface JobInputMetadata {
  readonly source: string | null;
  readonly originalFilename: string | null;
}

interface JobStatusSummary {
  readonly currentStatus: string | null;
  readonly createdAt: string | null;
  readonly updatedAt: string | null;
}

export class JobManager {
  public constructor(private readonly config: AppConfig) {}

  public async initialize(): Promise<void> {
    await mkdir(this.getQueueDir(), { recursive: true });
    await mkdir(this.getDataRoot(), { recursive: true });
    await mkdir(this.getOutputDir(), { recursive: true });

    for (const modelName of Object.keys(this.config.models)) {
      await mkdir(this.getModelInputDir(modelName), { recursive: true });
    }
  }

  public normalizeRequestedModel(modelName: string | null | undefined): string | null {
    if (modelName === undefined || modelName === null || modelName.length === 0) {
      return null;
    }

    if (!(modelName in this.config.models)) {
      throw new UnknownModelError(`Unknown model: ${modelName}`);
    }

    return modelName;
  }

  public async addBodyJob(
    body: ArrayBuffer,
    modelName: string | null,
    source: string,
  ): Promise<CreatedJob> {
    if (body.byteLength === 0) {
      throw new InvalidJobError("Request body must contain audio bytes");
    }

    const jobId = this.buildJobId(modelName);
    const dataDir = this.getDataDir(jobId);
    await mkdir(dataDir, { recursive: false });
    await this.writeInitialStatus(dataDir);
    await Bun.write(path.join(dataDir, "input"), new Uint8Array(body));
    await writeJson(path.join(dataDir, "input.json"), {
      job_id: jobId,
      source: source.length > 0 ? source : "input",
    });

    return {
      jobId,
      model: modelName,
      dataDir,
    };
  }

  public async addFileJob(sourcePath: string, modelName: string | null): Promise<CreatedJob> {
    if (sourcePath.length === 0) {
      throw new InvalidJobError("Audio file path must be a non-empty string");
    }

    const resolvedPath = path.resolve(sourcePath);
    if (!this.isAllowedInputPath(resolvedPath)) {
      throw new InvalidJobError("Audio file path is outside allowed roots");
    }

    let fileStats;
    try {
      fileStats = await stat(resolvedPath);
    } catch (error) {
      if (getNodeErrorCode(error) === "ENOENT") {
        throw new InvalidJobError("Audio file does not exist or is not a regular file");
      }
      throw error;
    }

    if (!fileStats.isFile()) {
      throw new InvalidJobError("Audio file does not exist or is not a regular file");
    }

    const jobId = this.buildJobId(modelName);
    const dataDir = this.getDataDir(jobId);
    await mkdir(dataDir, { recursive: false });
    await this.writeInitialStatus(dataDir);
    await writeJson(path.join(dataDir, "input.json"), {
      job_id: jobId,
      source: resolvedPath,
    });

    return {
      jobId,
      model: modelName,
      dataDir,
    };
  }

  public async enqueueJob(
    jobId: string,
    params: Record<string, unknown>,
  ): Promise<{ readonly jobId: string; readonly queue: string; readonly targetModel: string }> {
    assertValidJobId(jobId);
    await this.ensureJobDataDir(jobId);
    const modelName = this.resolveModelFromJobId(jobId);
    const targetModel = modelName ?? this.config.defaultModel;

    await writeJson(path.join(this.getDataDir(jobId), "params.json"), params);
    await this.appendStatus(this.getDataDir(jobId), "queued");
    await writeJson(path.join(this.getQueueDir(), `${jobId}.json`), {
      created_at: nowIso(),
      model: modelName,
    });

    return {
      jobId,
      queue: "queue",
      targetModel,
    };
  }

  public async peekQueue(): Promise<QueuedJob | null> {
    const markerNames = (await readdir(this.getQueueDir()))
      .filter((entry) => entry.endsWith(".json"))
      .sort((left, right) => left.localeCompare(right));

    if (markerNames.length === 0) {
      return null;
    }

    const jobId = markerNames[0].slice(0, -".json".length);
    const model = this.resolveModelFromJobId(jobId);
    return {
      jobId,
      targetModel: model ?? this.config.defaultModel,
    };
  }

  public async listJobs(): Promise<readonly ListedJob[]> {
    const entries = await readdir(this.getDataRoot(), { withFileTypes: true });
    const listedJobs = await Promise.all(
      entries
        .filter((entry) => entry.isDirectory())
        .map(async (entry) => this.buildListedJob(entry.name)),
    );

    return listedJobs
      .filter((job): job is ListedJob => job !== null)
      .sort((left, right) => {
        const sequenceDelta = getJobSequence(right.job_id) - getJobSequence(left.job_id);
        if (sequenceDelta !== 0) {
          return sequenceDelta;
        }

        return right.job_id.localeCompare(left.job_id);
      });
  }

  public async dispatchJob(
    jobId: string,
    modelName: string,
  ): Promise<{ readonly jobId: string; readonly model: string }> {
    if (!(modelName in this.config.models)) {
      throw new UnknownModelError(`Unknown model: ${modelName}`);
    }

    assertValidJobId(jobId);
    await this.ensureJobDataDir(jobId);
    await this.appendStatus(this.getDataDir(jobId), "pending");
    await rename(
      path.join(this.getQueueDir(), `${jobId}.json`),
      path.join(this.getModelInputDir(modelName), `${jobId}.json`),
    );

    return {
      jobId,
      model: modelName,
    };
  }

  public async getJobStatus(jobId: string): Promise<unknown> {
    assertValidJobId(jobId);
    await this.ensureJobDataDir(jobId);
    const statusPath = path.join(this.getDataDir(jobId), "status.json");
    return readJson(statusPath);
  }

  public async getJobResult(jobId: string, resultType?: JobResultType): Promise<unknown | string> {
    assertValidJobId(jobId);
    await this.ensureJobDataDir(jobId);

    if (resultType === undefined) {
      return this.readResultJson(jobId);
    }

    if (resultType === "raw" || resultType === "normalized") {
      const resultPayload = await this.readResultJson(jobId);
      if (!isRecord(resultPayload) || !(resultType in resultPayload)) {
        throw new JobResultNotFoundError(`Result type ${resultType} not found for ${jobId}`);
      }

      return resultPayload[resultType];
    }

    return this.readResultText(jobId, resultType);
  }

  private async readResultJson(jobId: string): Promise<unknown> {
    const resultPath = path.join(this.getDataDir(jobId), RESULT_JSON_FILE_NAME);
    try {
      return await readJson(resultPath);
    } catch (error) {
      if (getNodeErrorCode(error) === "ENOENT") {
        throw new JobResultNotFoundError(`Result file not found for ${jobId}`);
      }
      throw error;
    }
  }

  private async readResultText(jobId: string, resultType: "plain" | "timestamp"): Promise<string> {
    const resultPath = path.join(this.getDataDir(jobId), RESULT_TEXT_FILE_NAMES[resultType]);
    try {
      return await readFile(resultPath, "utf-8");
    } catch (error) {
      if (getNodeErrorCode(error) === "ENOENT") {
        throw new JobResultNotFoundError(`Result file not found for ${jobId} and type ${resultType}`);
      }

      throw error;
    }
  }

  public async deleteJob(jobId: string): Promise<boolean> {
    assertValidJobId(jobId);

    const queueMarkerPath = path.join(this.getQueueDir(), `${jobId}.json`);
    const outputMarkerPath = path.join(this.getOutputDir(), `${jobId}.json`);
    const dataDir = this.getDataDir(jobId);
    const inputMarkers = Object.keys(this.config.models).flatMap((modelName) => [
      path.join(this.getModelInputDir(modelName), `${jobId}.json`),
      path.join(this.getModelInputDir(modelName), `${jobId}.json.lock`),
    ]);

    let deleted = false;
    for (const markerPath of [queueMarkerPath, outputMarkerPath, ...inputMarkers]) {
      try {
        await unlink(markerPath);
        deleted = true;
      } catch (error) {
        if (getNodeErrorCode(error) !== "ENOENT") {
          throw error;
        }
      }
    }

    try {
      await rm(dataDir, { recursive: true, force: false });
      deleted = true;
    } catch (error) {
      if (getNodeErrorCode(error) !== "ENOENT") {
        throw error;
      }
    }

    return deleted;
  }

  public getDataDir(jobId: string): string {
    assertValidJobId(jobId);
    return path.join(this.getDataRoot(), jobId);
  }

  public getQueueDir(): string {
    return path.join(this.config.jobsRoot, "queue");
  }

  public getOutputDir(): string {
    return path.join(this.config.jobsRoot, "output");
  }

  public resolveModelFromJobId(jobId: string): string | null {
    return getModelFromJobId(jobId, Object.keys(this.config.models));
  }

  private buildJobId(modelName: string | null): string {
    const suffix = modelName ?? "common";
    if (!JOB_ID_PATTERN.test(suffix) || suffix.includes("..")) {
      throw new InvalidJobError(`Model name cannot be used in job_id: ${suffix}`);
    }

    const uniquePart = randomUUID().replaceAll("-", "");
    return `${Date.now()}_${uniquePart}_${suffix}`;
  }

  private async ensureJobDataDir(jobId: string): Promise<void> {
    assertValidJobId(jobId);
    try {
      const dirStats = await stat(this.getDataDir(jobId));
      if (!dirStats.isDirectory()) {
        throw new JobNotFoundError(`Job directory not found for ${jobId}`);
      }
    } catch (error) {
      if (error instanceof JobNotFoundError) {
        throw error;
      }

      if (getNodeErrorCode(error) === "ENOENT") {
        throw new JobNotFoundError(`Job directory not found for ${jobId}`);
      }

      throw error;
    }
  }

  private isAllowedInputPath(candidatePath: string): boolean {
    return this.config.allowedInputRoots.some((rootPath) => isWithinRoot(candidatePath, rootPath));
  }

  private async readStatuses(statusPath: string, jobId: string): Promise<unknown[]> {
    try {
      const payload = await readJson(statusPath);
      if (!Array.isArray(payload)) {
        throw new InvalidJobError(`status.json must contain an array for ${jobId}`);
      }

      return [...payload];
    } catch (error) {
      if (error instanceof InvalidJobError) {
        throw error;
      }

      const code = getNodeErrorCode(error);
      if (code === "ENOENT") {
        return [];
      }

      if (error instanceof SyntaxError) {
        throw new InvalidJobError(`status.json is invalid JSON for ${jobId}`);
      }

      throw error;
    }
  }

  private async writeInitialStatus(dataDir: string): Promise<void> {
    await writeJson(path.join(dataDir, "status.json"), [
      {
        status: "dispatching",
        updated_at: nowIso(),
      },
    ]);
  }

  private async appendStatus(dataDir: string, status: string, error?: string): Promise<void> {
    const statusPath = path.join(dataDir, "status.json");
    const statuses = await this.readStatuses(statusPath, path.basename(dataDir));

    statuses.push({
      ...(error === undefined ? {} : { error }),
      status,
      updated_at: nowIso(),
    });
    await writeJson(statusPath, statuses);
  }

  private async buildListedJob(jobId: string): Promise<ListedJob | null> {
    try {
      assertValidJobId(jobId);
    } catch {
      return null;
    }

    const dataDir = this.getDataDir(jobId);
    const [inputMetadata, statusSummary, outputStatus, hasResult] = await Promise.all([
      this.readJobInputMetadata(dataDir),
      this.readJobStatusSummary(jobId, dataDir),
      this.readOutputStatus(jobId),
      this.hasResultArtifact(jobId),
    ]);

    let model: string | null = null;
    try {
      model = this.resolveModelFromJobId(jobId);
    } catch {
      model = null;
    }

    return {
      job_id: jobId,
      model,
      current_status: statusSummary.currentStatus ?? outputStatus,
      created_at: statusSummary.createdAt,
      updated_at: statusSummary.updatedAt,
      has_result: hasResult,
      source: inputMetadata.source,
      original_filename: inputMetadata.originalFilename,
    };
  }

  private async readJobInputMetadata(dataDir: string): Promise<JobInputMetadata> {
    try {
      const payload = await readJson(path.join(dataDir, "input.json"));
      if (!isRecord(payload)) {
        return {
          source: null,
          originalFilename: null,
        };
      }

      return {
        source: typeof payload.source === "string" ? payload.source : null,
        originalFilename: typeof payload.original_filename === "string" ? payload.original_filename : null,
      };
    } catch (error) {
      const code = getNodeErrorCode(error);
      if (code === "ENOENT" || error instanceof SyntaxError) {
        return {
          source: null,
          originalFilename: null,
        };
      }

      throw error;
    }
  }

  private async readJobStatusSummary(jobId: string, dataDir: string): Promise<JobStatusSummary> {
    try {
      const statuses = await this.readStatuses(path.join(dataDir, "status.json"), jobId);
      if (statuses.length === 0) {
        return {
          currentStatus: null,
          createdAt: null,
          updatedAt: null,
        };
      }

      const firstStatus = isRecord(statuses[0]) ? statuses[0] : null;
      const lastStatus = isRecord(statuses[statuses.length - 1]) ? statuses[statuses.length - 1] : null;
      return {
        currentStatus: typeof lastStatus?.status === "string" ? lastStatus.status : null,
        createdAt: typeof firstStatus?.updated_at === "string" ? firstStatus.updated_at : null,
        updatedAt: typeof lastStatus?.updated_at === "string" ? lastStatus.updated_at : null,
      };
    } catch (error) {
      if (error instanceof InvalidJobError) {
        return {
          currentStatus: null,
          createdAt: null,
          updatedAt: null,
        };
      }

      throw error;
    }
  }

  private async readOutputStatus(jobId: string): Promise<string | null> {
    try {
      const payload = await readJson(path.join(this.getOutputDir(), `${jobId}.json`));
      if (!isRecord(payload) || typeof payload.status !== "string") {
        return null;
      }

      return payload.status;
    } catch (error) {
      const code = getNodeErrorCode(error);
      if (code === "ENOENT" || error instanceof SyntaxError) {
        return null;
      }

      throw error;
    }
  }

  private async hasResultArtifact(jobId: string): Promise<boolean> {
    try {
      const resultStats = await stat(path.join(this.getDataDir(jobId), RESULT_JSON_FILE_NAME));
      return resultStats.isFile();
    } catch (error) {
      if (getNodeErrorCode(error) === "ENOENT") {
        return false;
      }

      throw error;
    }
  }

  private getModelInputDir(modelName: string): string {
    if (!(modelName in this.config.models)) {
      throw new UnknownModelError(`Unknown model: ${modelName}`);
    }

    return path.join(this.config.jobsRoot, "input", modelName);
  }

  private getDataRoot(): string {
    return path.join(this.config.jobsRoot, "data");
  }
}