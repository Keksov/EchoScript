import { Hono } from "hono";
import process from "node:process";

import { loadConfig } from "./config";
import {
  assertValidJobResultType,
  assertValidJobId,
  InvalidJobError,
  JobManager,
  JobNotFoundError,
  JobResultNotFoundError,
  UnknownModelError,
} from "./job-manager";
import { ProcessManager } from "./process-manager";
import {
  assertSpeechTargetProvisioned,
  buildBufferedSpeechParams,
  buildBufferedSpeechResponse,
  hasBufferedSpeechText,
  InvalidSpeechRequestError,
  parseBufferedSpeechRequest,
  resolveSpeechTargetModel,
  SpeechConfigurationError,
  SpeechJobFailedError,
  SpeechProcessingTimeoutError,
  waitForBufferedSpeechResult,
} from "./speech-v2";
import { JobBusyError, Scheduler } from "./scheduler";

interface AddFileBody {
  readonly path: string;
  readonly model?: string;
}

interface RunJobBody {
  readonly job_id: string;
  readonly params?: Record<string, unknown>;
}

const DEFAULT_MAX_ADD_BODY_BYTES = 50 * 1024 * 1024;

const isRecord = (value: unknown): value is Record<string, unknown> => {
  return typeof value === "object" && value !== null && !Array.isArray(value);
};

const messageOf = (error: unknown): string => {
  return error instanceof Error ? error.message : "Unknown error";
};

const resolveAddBodyLimitBytes = (): number => {
  const rawLimit = process.env.ECHOSCRIPT_MAX_BODY_BYTES;
  if (rawLimit === undefined) {
    return DEFAULT_MAX_ADD_BODY_BYTES;
  }

  const parsedLimit = Number.parseInt(rawLimit, 10);
  if (!Number.isInteger(parsedLimit) || parsedLimit <= 0) {
    return DEFAULT_MAX_ADD_BODY_BYTES;
  }

  return parsedLimit;
};

const readBodyWithLimit = async (request: Request, maxBytes: number): Promise<ArrayBuffer> => {
  const contentLengthHeader = request.headers.get("content-length");
  if (contentLengthHeader !== null) {
    const contentLength = Number.parseInt(contentLengthHeader, 10);
    if (Number.isFinite(contentLength) && contentLength > maxBytes) {
      throw new InvalidJobError(`Request body exceeds ${maxBytes} bytes`);
    }
  }

  if (request.body === null) {
    return new ArrayBuffer(0);
  }

  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let totalSize = 0;

  while (true) {
    const chunk = await reader.read();
    if (chunk.done) {
      break;
    }

    totalSize += chunk.value.byteLength;
    if (totalSize > maxBytes) {
      throw new InvalidJobError(`Request body exceeds ${maxBytes} bytes`);
    }

    chunks.push(chunk.value);
  }

  const merged = new Uint8Array(totalSize);
  let offset = 0;
  for (const chunk of chunks) {
    merged.set(chunk, offset);
    offset += chunk.byteLength;
  }

  return merged.buffer;
};

const parseAddFileBody = (payload: unknown): AddFileBody => {
  if (!isRecord(payload) || typeof payload.path !== "string" || payload.path.length === 0) {
    throw new InvalidJobError("add_file body must contain a non-empty path field");
  }

  const model = typeof payload.model === "string" ? payload.model : undefined;
  return {
    path: payload.path,
    model,
  };
};

const parseRunJobBody = (payload: unknown): RunJobBody => {
  if (!isRecord(payload) || typeof payload.job_id !== "string" || payload.job_id.length === 0) {
    throw new InvalidJobError("run_job body must contain a non-empty job_id field");
  }

  const params = isRecord(payload.params) ? payload.params : {};
  return {
    job_id: payload.job_id,
    params,
  };
};

const resolvePort = (): number => {
  const rawPort = process.env.ECHOSCRIPT_PORT;
  if (rawPort === undefined) {
    return 3000;
  }

  const parsedPort = Number.parseInt(rawPort, 10);
  if (!Number.isInteger(parsedPort) || parsedPort <= 0) {
    return 3000;
  }

  return parsedPort;
};

const config = await loadConfig();
const jobManager = new JobManager(config);
await jobManager.initialize();
const processManager = new ProcessManager(config);
const scheduler = new Scheduler(config, jobManager, processManager);
await scheduler.start();
const maxAddBodyBytes = resolveAddBodyLimitBytes();

let isShuttingDown = false;
const shutdown = async (signal: string): Promise<void> => {
  if (isShuttingDown) {
    return;
  }

  isShuttingDown = true;
  console.info(`Received ${signal}, stopping scheduler and model services`);
  scheduler.stop();

  try {
    await processManager.stopAllModels();
  } catch (error) {
    console.error("Failed to stop model services during shutdown", error);
  }

  process.exit(0);
};

process.once("SIGINT", () => {
  void shutdown("SIGINT");
});

process.once("SIGTERM", () => {
  void shutdown("SIGTERM");
});

const app = new Hono();

app.get("/", async (c) => {
  const runningModels = await processManager.listRunningModels();
  const schedulerState = scheduler.getState();
  return c.json({
    service: "echoscript-orchestrator",
    status: "ok",
    active_job_id: schedulerState.activeJobId,
    active_model: schedulerState.activeModel,
    running_models: runningModels,
  });
});

app.get("/list_jobs", async (c) => {
  try {
    const jobs = await jobManager.listJobs();
    return c.json({ jobs });
  } catch (error) {
    return c.json({ error: messageOf(error) }, 500);
  }
});

app.post("/api/v2/speech/recognize", async (c) => {
  try {
    const requestStartedAt = Date.now();
    const request = parseBufferedSpeechRequest(
      c.req.query("mode"),
      c.req.query("language"),
      c.req.query("timeout_ms"),
    );
    const targetModel = resolveSpeechTargetModel(config, request);
    await assertSpeechTargetProvisioned(config, targetModel);
    const body = await readBodyWithLimit(c.req.raw, maxAddBodyBytes);
    const createdJob = await jobManager.addBodyJob(body, targetModel, `speech_v2_${request.mode}`);
    const queuedJob = await scheduler.enqueue(createdJob.jobId, buildBufferedSpeechParams(config, request));
    let responseJobId = createdJob.jobId;
    let responseTargetModel = queuedJob.targetModel;
    let responsePayload = await waitForBufferedSpeechResult(jobManager, createdJob.jobId, request.timeoutMs);
    let commandStatus = request.mode === "command" ? "matched" : null;

    if (request.mode === "command" && !hasBufferedSpeechText(responsePayload)) {
      const fallbackRequest = { ...request, mode: "dictation" as const };
      const fallbackTargetModel = resolveSpeechTargetModel(config, fallbackRequest);
      await assertSpeechTargetProvisioned(config, fallbackTargetModel);

      const remainingTimeoutMs = request.timeoutMs - (Date.now() - requestStartedAt);
      if (remainingTimeoutMs <= 0) {
        throw new SpeechProcessingTimeoutError(
          createdJob.jobId,
          `Timed out waiting for speech fallback result for ${createdJob.jobId}`,
        );
      }

      const fallbackCreatedJob = await jobManager.addBodyJob(
        body,
        fallbackTargetModel,
        "speech_v2_command_fallback",
      );
      const fallbackQueuedJob = await scheduler.enqueue(
        fallbackCreatedJob.jobId,
        buildBufferedSpeechParams(config, fallbackRequest),
      );

      responseJobId = fallbackCreatedJob.jobId;
      responseTargetModel = fallbackQueuedJob.targetModel;
      responsePayload = await waitForBufferedSpeechResult(
        jobManager,
        fallbackCreatedJob.jobId,
        remainingTimeoutMs,
      );
      commandStatus = "not_command";
    }

    return c.json(
      buildBufferedSpeechResponse(
        responseJobId,
        request,
        responseTargetModel,
        responsePayload,
        commandStatus,
      ),
    );
  } catch (error) {
    if (error instanceof InvalidSpeechRequestError || error instanceof InvalidJobError) {
      return c.json({ error: messageOf(error) }, 400);
    }

    if (error instanceof SpeechProcessingTimeoutError) {
      return c.json({ error: messageOf(error), job_id: error.jobId }, 504);
    }

    if (error instanceof SpeechJobFailedError) {
      return c.json({ error: messageOf(error), job_id: error.jobId }, 422);
    }

    if (error instanceof SpeechConfigurationError || error instanceof UnknownModelError) {
      return c.json({ error: messageOf(error) }, 503);
    }

    return c.json({ error: messageOf(error) }, 500);
  }
});

app.post("/add_body", async (c) => {
  try {
    const model = jobManager.normalizeRequestedModel(c.req.query("model"));
    const source = c.req.query("source") ?? "input";
    const body = await readBodyWithLimit(c.req.raw, maxAddBodyBytes);
    const createdJob = await jobManager.addBodyJob(body, model, source);
    return c.json({ job_id: createdJob.jobId }, 201);
  } catch (error) {
    if (error instanceof InvalidJobError || error instanceof UnknownModelError) {
      return c.json({ error: messageOf(error) }, 400);
    }
    return c.json({ error: messageOf(error) }, 500);
  }
});

app.post("/add_file", async (c) => {
  try {
    const payload = parseAddFileBody(await c.req.json());
    const model = jobManager.normalizeRequestedModel(payload.model);
    const createdJob = await jobManager.addFileJob(payload.path, model);
    return c.json({ job_id: createdJob.jobId }, 201);
  } catch (error) {
    if (error instanceof InvalidJobError || error instanceof UnknownModelError) {
      return c.json({ error: messageOf(error) }, 400);
    }
    return c.json({ error: messageOf(error) }, 500);
  }
});

app.post("/run_job", async (c) => {
  try {
    const payload = parseRunJobBody(await c.req.json());
    assertValidJobId(payload.job_id);
    const queuedJob = await scheduler.enqueue(payload.job_id, payload.params ?? {});

    return c.json(
      {
        job_id: payload.job_id,
        status: "queued",
        queue: queuedJob.queue,
        target_model: queuedJob.targetModel,
      },
      202,
    );
  } catch (error) {
    if (
      error instanceof InvalidJobError ||
      error instanceof JobNotFoundError ||
      error instanceof UnknownModelError
    ) {
      const status = error instanceof JobNotFoundError ? 404 : 400;
      return c.json({ error: messageOf(error) }, status);
    }
    return c.json({ error: messageOf(error) }, 500);
  }
});

app.get("/get_job_status", async (c) => {
  const jobId = c.req.query("job_id");
  if (jobId === undefined || jobId.length === 0) {
    return c.json({ error: "job_id query parameter is required" }, 400);
  }

  try {
    assertValidJobId(jobId);
    const statusPayload = await jobManager.getJobStatus(jobId);
    return c.json(statusPayload);
  } catch (error) {
    if (error instanceof JobNotFoundError || error instanceof InvalidJobError) {
      const status = error instanceof JobNotFoundError ? 404 : 400;
      return c.json({ error: messageOf(error) }, status);
    }
    return c.json({ error: messageOf(error) }, 500);
  }
});

app.get("/get_job_result", async (c) => {
  const jobId = c.req.query("job_id");
  if (jobId === undefined || jobId.length === 0) {
    return c.json({ error: "job_id query parameter is required" }, 400);
  }

  try {
    assertValidJobId(jobId);
    const rawResultType = c.req.query("type");
    const resultType = rawResultType === undefined || rawResultType.length === 0 ? undefined : assertValidJobResultType(rawResultType);
    const resultPayload = await jobManager.getJobResult(jobId, resultType);

    if (resultType === "plain" || resultType === "timestamp") {
      return c.text(resultPayload as string);
    }

    return c.json(resultPayload);
  } catch (error) {
    if (
      error instanceof JobNotFoundError ||
      error instanceof JobResultNotFoundError ||
      error instanceof InvalidJobError
    ) {
      const status = error instanceof JobNotFoundError ? 404 : error instanceof InvalidJobError ? 400 : 404;
      return c.json({ error: messageOf(error) }, status);
    }
    return c.json({ error: messageOf(error) }, 500);
  }
});

app.delete("/delete_job", async (c) => {
  const jobId = c.req.query("job_id");
  if (jobId === undefined || jobId.length === 0) {
    return c.json({ error: "job_id query parameter is required" }, 400);
  }

  try {
    assertValidJobId(jobId);
    const deleted = await scheduler.deleteJob(jobId);
    if (!deleted) {
      return c.json({ error: `Job artifacts not found for ${jobId}` }, 404);
    }

    return c.json({ job_id: jobId, deleted: true });
  } catch (error) {
    if (error instanceof InvalidJobError || error instanceof JobBusyError) {
      const status = error instanceof JobBusyError ? 409 : 400;
      return c.json({ error: messageOf(error) }, status);
    }

    return c.json({ error: messageOf(error) }, 500);
  }
});

export const server = {
  port: resolvePort(),
  fetch: app.fetch,
};

export default server;
