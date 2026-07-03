import { watch, type FSWatcher } from "node:fs";
import { readdir, rename, stat, unlink } from "node:fs/promises";
import path from "node:path";

import type { AppConfig, WsDaemonConfig } from "./config";
import { JobManager, type QueuedJob } from "./job-manager";
import { getNodeErrorCode } from "./node-error";
import { ProcessManager } from "./process-manager";
import { runWsDaemonJob } from "./ws-daemon-runner";
import { bytesForMs } from "./daemon-stream-driver";
import { DaemonRegistry } from "./daemon-registry";
import { scanInputDrops } from "./input-drop";

interface SchedulerState {
  readonly activeJobId: string | null;
  readonly activeModel: string | null;
}

interface DispatchedJob {
  readonly jobId: string;
  readonly modelName: string;
  readonly markerPath: string;
  readonly locked: boolean;
}

export class JobBusyError extends Error {}

const MIN_RECONCILE_INTERVAL_MS = 250;

const normalizeFilename = (filename: string | Buffer | null): string | null => {
  if (filename === null) {
    return null;
  }

  return typeof filename === "string" ? filename : filename.toString("utf-8");
};

const stripMarkerSuffix = (fileName: string): string | null => {
  if (fileName.endsWith(".json.lock")) {
    return fileName.slice(0, -".json.lock".length);
  }

  if (fileName.endsWith(".json")) {
    return fileName.slice(0, -".json".length);
  }

  return null;
};

export interface DispatchChoice {
  readonly job: QueuedJob;
  /** ws-daemon endpoint (announced host/port) to dispatch to, or null for the python path. */
  readonly wsEndpoint: WsDaemonConfig | null;
}

/**
 * Peek-dispatchable (DR-D10): walk the queue in order and pick the first job we can run
 * now — python-model jobs always (the orchestrator starts the worker), ws-daemon jobs
 * only when the registry reports a fresh ready daemon. Not-ready ws-daemon jobs are
 * skipped (no head-of-line blocking); null means nothing is dispatchable right now and
 * the reconcile tick will retry when a daemon registers.
 */
export const selectDispatchable = (
  queued: readonly QueuedJob[],
  findWsDaemon: (model: string) => WsDaemonConfig | null,
  readyEndpoint: (model: string) => WsDaemonConfig | null,
): DispatchChoice | null => {
  for (const job of queued) {
    const wsDaemon = findWsDaemon(job.targetModel);
    if (wsDaemon === null) {
      return { job, wsEndpoint: null }; // python path — always dispatchable
    }
    const endpoint = readyEndpoint(job.targetModel);
    if (endpoint !== null) {
      return { job, wsEndpoint: endpoint };
    }
    // ws-daemon not ready — skip this job, try the next one
  }
  return null;
};

/** Whether a job that already requeued `priorRequeues` times has hit the cap (SR-D1). */
export const exceededRequeueCap = (priorRequeues: number, maxRequeueAttempts: number): boolean =>
  priorRequeues >= maxRequeueAttempts;

export class Scheduler {
  private outputWatcher: FSWatcher | null = null;
  private inputWatchers: FSWatcher[] = [];
  private reconcileTimer: ReturnType<typeof setInterval> | null = null;
  private activeJobId: string | null = null;
  private activeModel: string | null = null;
  private isDispatching = false;
  private dispatchRequested = false;
  private isSweeping = false;
  private sweepRequested = false;

  public constructor(
    private readonly config: AppConfig,
    private readonly jobManager: JobManager,
    private readonly processManager: ProcessManager,
    private readonly daemonRegistry: DaemonRegistry,
  ) {}

  public async start(): Promise<void> {
    if (this.outputWatcher !== null) {
      return;
    }

    await this.restoreDispatchedJob();
    if (this.activeModel === null) {
      this.activeModel = await this.processManager.getCurrentModel();
    }

    // Pick up files dropped into jobs/input/<model>/ before startup (and recover any
    // orphaned .processing claims) before we start watching.
    await this.sweepInputDrops();

    this.outputWatcher = watch(this.outputDir(), (_eventType, filename) => {
      const resolvedName = normalizeFilename(filename);
      if (resolvedName === null || !resolvedName.endsWith(".json")) {
        return;
      }

      void this.onOutputMarkerDetected(resolvedName);
    });

    this.startInputWatchers();

    this.reconcileTimer = setInterval(() => {
      void this.triggerSweep();
      this.triggerDispatch();
    }, Math.max(this.config.pollIntervalMs, MIN_RECONCILE_INTERVAL_MS));

    this.triggerDispatch();
  }

  public stop(): void {
    this.outputWatcher?.close();
    this.outputWatcher = null;

    for (const watcher of this.inputWatchers) {
      watcher.close();
    }
    this.inputWatchers = [];

    if (this.reconcileTimer !== null) {
      clearInterval(this.reconcileTimer);
      this.reconcileTimer = null;
    }
  }

  private startInputWatchers(): void {
    for (const modelName of Object.keys(this.config.models)) {
      const dir = path.join(this.config.jobsRoot, "input", modelName);
      try {
        this.inputWatchers.push(watch(dir, () => void this.triggerSweep()));
      } catch {
        // dir may not exist yet; JobManager.initialize creates model input dirs
      }
    }
  }

  /** Serialized input sweep (mirrors the dispatch loop): coalesces concurrent triggers. */
  private async triggerSweep(): Promise<void> {
    if (this.isSweeping) {
      this.sweepRequested = true;
      return;
    }
    this.isSweeping = true;
    try {
      do {
        this.sweepRequested = false;
        await this.sweepInputDrops();
      } while (this.sweepRequested);
    } finally {
      this.isSweeping = false;
    }
    this.triggerDispatch();
  }

  private async sweepInputDrops(): Promise<void> {
    await scanInputDrops(
      this.config.jobsRoot,
      Object.keys(this.config.models),
      this.config.dropStableMs,
      this.jobManager,
    );
  }

  public getState(): SchedulerState {
    return {
      activeJobId: this.activeJobId,
      activeModel: this.activeModel,
    };
  }

  public async enqueue(
    jobId: string,
    params: Record<string, unknown>,
  ): Promise<{ readonly jobId: string; readonly queue: string; readonly targetModel: string }> {
    const queuedJob = await this.jobManager.enqueueJob(jobId, params);
    this.triggerDispatch();
    return queuedJob;
  }

  public async deleteJob(jobId: string): Promise<boolean> {
    if (this.activeJobId === jobId && !(await this.hasOutputMarker(jobId))) {
      throw new JobBusyError(`Job ${jobId} is currently active and cannot be deleted`);
    }

    const deleted = await this.jobManager.deleteJob(jobId);
    if (this.activeJobId === jobId) {
      this.activeJobId = null;
    }

    this.triggerDispatch();
    return deleted;
  }

  private triggerDispatch(): void {
    this.dispatchRequested = true;
    if (this.isDispatching) {
      return;
    }

    void this.runDispatchLoop();
  }

  private async runDispatchLoop(): Promise<void> {
    if (this.isDispatching) {
      return;
    }

    this.isDispatching = true;
    try {
      while (this.dispatchRequested) {
        this.dispatchRequested = false;
        try {
          await this.dispatchNext();
        } catch (error) {
          console.error("Scheduler dispatch failed", error);
        }
      }
    } finally {
      this.isDispatching = false;
      if (this.dispatchRequested) {
        void this.runDispatchLoop();
      }
    }
  }

  private async dispatchNext(): Promise<void> {
    if (this.activeJobId !== null) {
      if (await this.hasOutputMarker(this.activeJobId)) {
        this.activeJobId = null;
      } else {
        return;
      }
    }

    const queued = await this.jobManager.listQueuedJobs();
    if (queued.length === 0) {
      return;
    }

    const choice = selectDispatchable(
      queued,
      (model) => this.findWsDaemonForModel(model),
      (model) => this.readyEndpointForModel(model),
    );
    if (choice === null) {
      // Nothing dispatchable now (ws-daemon(s) not ready) — leave jobs queued; the
      // reconcile tick retries once a daemon registers as ready (DR-D6/DR-D10).
      return;
    }

    if (choice.wsEndpoint !== null) {
      await this.dispatchWsDaemonJob(choice.job.jobId, choice.job.targetModel, choice.wsEndpoint);
      return;
    }

    await this.switchToModel(choice.job.targetModel);
    await this.jobManager.dispatchJob(choice.job.jobId, choice.job.targetModel);
    this.activeJobId = choice.job.jobId;
    this.activeModel = choice.job.targetModel;
  }

  private findWsDaemonForModel(modelName: string): WsDaemonConfig | null {
    for (const daemon of Object.values(this.config.wsDaemons)) {
      if (daemon.modelName === modelName) {
        return daemon;
      }
    }
    return null;
  }

  /** Fresh ready daemon for a model, as an endpoint using its announced host/port (DR-D7). */
  private readyEndpointForModel(modelName: string): WsDaemonConfig | null {
    const registration = this.daemonRegistry.readyForModel(modelName);
    if (registration === null) {
      return null;
    }
    return { host: registration.host, port: registration.port, modelName };
  }

  private async dispatchWsDaemonJob(
    jobId: string,
    targetModel: string,
    endpoint: WsDaemonConfig,
  ): Promise<void> {
    // The ws-daemon is an external always-on process; free any python worker slots first.
    const runningModels = await this.processManager.listRunningModels();
    for (const runningModel of runningModels) {
      await this.processManager.stopModel(runningModel);
    }

    await this.jobManager.claimExternalJob(jobId);
    this.activeJobId = jobId;
    this.activeModel = targetModel;

    // Fire-and-forget: the runner writes result artifacts + output marker (even on
    // failure), which the scheduler detects to clear the active job.
    void runWsDaemonJob(jobId, this.jobManager.getDataDir(jobId), this.jobManager.getOutputDir(), {
      ffmpegPath: this.config.ffmpegPath,
      endpoint,
      windowBytes: bytesForMs(this.config.streamWindowMs),
      rolloverBytes: bytesForMs(this.config.streamRolloverMs),
    })
      .then((outcome) => this.onWsDaemonJobOutcome(jobId, targetModel, outcome))
      .catch((error) => {
        console.error(`ws-daemon job ${jobId} failed unexpectedly`, error);
      })
      .finally(() => {
        this.triggerDispatch();
      });
  }

  /**
   * On a transport failure the runner returns "requeue" (no output marker written):
   * mark the daemon not-ready (DR-D12) so we don't immediately retry, clear the active
   * slot, and put the job back on the queue for when a ready daemon appears (DR-D11).
   * ready/failed already dropped an output marker; onOutputMarkerDetected clears active.
   */
  private async onWsDaemonJobOutcome(
    jobId: string,
    modelName: string,
    outcome: "ready" | "failed" | "requeue",
  ): Promise<void> {
    if (outcome !== "requeue") {
      return;
    }
    this.daemonRegistry.invalidateModel(modelName);
    if (this.activeJobId === jobId) {
      this.activeJobId = null;
    }
    // Cap requeues so a live-but-silent/stalled daemon can't loop forever (SR-D1).
    const priorRequeues = await this.jobManager.countJobStatus(jobId, "waiting");
    if (exceededRequeueCap(priorRequeues, this.config.maxRequeueAttempts)) {
      await this.jobManager.markFailed(
        jobId,
        `daemon ${modelName} unreachable/stalled after ${priorRequeues} requeue attempt(s)`,
      );
      return;
    }
    await this.jobManager.requeueJob(jobId);
  }

  private async switchToModel(modelName: string): Promise<void> {
    const runningModels = await this.processManager.listRunningModels();
    for (const runningModel of runningModels) {
      if (runningModel !== modelName) {
        await this.processManager.stopModel(runningModel);
      }
    }

    if (!runningModels.includes(modelName)) {
      await this.processManager.ensureModelRunning(modelName);
    }
  }

  private async onOutputMarkerDetected(fileName: string): Promise<void> {
    const jobId = stripMarkerSuffix(fileName);
    if (jobId === null) {
      return;
    }

    if (this.activeJobId === jobId && (await this.hasOutputMarker(jobId))) {
      this.activeJobId = null;
    }

    this.triggerDispatch();
  }

  private async restoreDispatchedJob(): Promise<void> {
    const candidates: DispatchedJob[] = [];

    for (const modelName of Object.keys(this.config.models)) {
      const inputDir = path.join(this.config.jobsRoot, "input", modelName);
      const entries = await readdir(inputDir).catch((): string[] => []);
      for (const entry of entries) {
        const jobId = stripMarkerSuffix(entry);
        if (jobId === null) {
          continue;
        }

        candidates.push({
          jobId,
          modelName,
          markerPath: path.join(inputDir, entry),
          locked: entry.endsWith(".json.lock"),
        });
      }
    }

    if (candidates.length === 0) {
      return;
    }

    candidates.sort((left, right) => left.jobId.localeCompare(right.jobId));

    const unlockedCandidates = candidates.filter((candidate) => !candidate.locked);
    const resumedCandidate = unlockedCandidates.length > 0 ? unlockedCandidates[0] : null;
    const queuedCandidates = candidates.filter((candidate) => candidate !== resumedCandidate);

    for (const candidate of queuedCandidates) {
      await this.requeueDispatchedCandidate(candidate);
    }

    if (queuedCandidates.length > 0) {
      console.warn("Recovered dispatched jobs into queue on startup", {
        resumed_job_id: resumedCandidate?.jobId ?? null,
        requeued_job_ids: queuedCandidates.map((candidate) => candidate.jobId),
      });
    }

    if (resumedCandidate !== null) {
      this.activeJobId = resumedCandidate.jobId;
      this.activeModel = resumedCandidate.modelName;
    }
  }

  private async hasOutputMarker(jobId: string): Promise<boolean> {
    try {
      const markerStats = await stat(path.join(this.outputDir(), `${jobId}.json`));
      return markerStats.isFile();
    } catch (error) {
      if (getNodeErrorCode(error) === "ENOENT") {
        return false;
      }

      throw error;
    }
  }

  private async requeueDispatchedCandidate(candidate: DispatchedJob): Promise<void> {
    const targetQueueMarker = path.join(this.config.jobsRoot, "queue", `${candidate.jobId}.json`);

    try {
      await rename(candidate.markerPath, targetQueueMarker);
      return;
    } catch (error) {
      const code = getNodeErrorCode(error);
      if (code === "ENOENT") {
        return;
      }

      if (code === "EEXIST") {
        try {
          await unlink(candidate.markerPath);
        } catch (unlinkError) {
          if (getNodeErrorCode(unlinkError) !== "ENOENT") {
            throw unlinkError;
          }
        }
        return;
      }

      throw error;
    }
  }

  private outputDir(): string {
    return this.jobManager.getOutputDir();
  }
}