import { readFile, stat, unlink, writeFile } from "node:fs/promises";
import path from "node:path";
import process from "node:process";

import type { AppConfig } from "./config";
import { getModelFromJobId, UnknownModelError } from "./job-manager";
import { getNodeErrorCode } from "./node-error";

export class ProcessCapacityError extends Error {}

interface RuntimeHandle {
  readonly modelName: string;
  readonly process: Bun.Subprocess;
  readonly startedAt: number;
}

export class ProcessManager {
  private readonly runtimes = new Map<string, RuntimeHandle>();

  public constructor(private readonly config: AppConfig) {}

  public async ensureServiceForJob(
    jobId: string,
  ): Promise<{ readonly model: string; readonly started: boolean }> {
    const modelName = getModelFromJobId(jobId, Object.keys(this.config.models));
    if (modelName !== null) {
      const started = await this.ensureModelRunning(modelName);
      return { model: modelName, started };
    }

    const runningModels = await this.listRunningModels();
    if (runningModels.length > 0) {
      return { model: runningModels[0], started: false };
    }

    const started = await this.ensureModelRunning(this.config.defaultModel);
    return { model: this.config.defaultModel, started };
  }

  public async ensureModelRunning(modelName: string): Promise<boolean> {
    if (!(modelName in this.config.models)) {
      throw new UnknownModelError(`Unknown model: ${modelName}`);
    }

    await this.cleanupStaleProcesses();
    if (await this.isModelRunning(modelName)) {
      return false;
    }

    const runningModels = await this.listRunningModels();
    if (runningModels.length >= this.config.maxWorkers) {
      throw new ProcessCapacityError(
        `No free service slots for ${modelName}: max_workers=${this.config.maxWorkers}`,
      );
    }

    await this.spawnModel(modelName);
    return true;
  }

  public async stopModel(
    modelName: string,
    timeoutMs = this.config.modelStopTimeoutMs,
  ): Promise<boolean> {
    if (!(modelName in this.config.models)) {
      throw new UnknownModelError(`Unknown model: ${modelName}`);
    }

    await this.cleanupStaleProcesses();
    const pid = await this.readPid(modelName);
    if (pid === null) {
      await this.removeStopRequest(modelName);
      this.runtimes.delete(modelName);
      return false;
    }

    await this.writeStopRequest(modelName);
    try {
      const gracefulStopped = await this.waitForStop(modelName, timeoutMs);
      if (!gracefulStopped) {
        this.killPid(pid, modelName, process.platform === "win32" ? "SIGKILL" : "SIGTERM");
        const forcedStopped = await this.waitForStop(modelName, Math.min(timeoutMs, 30000));
        if (!forcedStopped) {
          throw new Error(`Timed out waiting for ${modelName} to stop`);
        }
      }
    } finally {
      await this.removeStopRequest(modelName);
    }

    return true;
  }

  public async stopAllModels(timeoutMs = this.config.modelStopTimeoutMs): Promise<void> {
    const runningModels = await this.listRunningModels();
    for (const modelName of runningModels) {
      await this.stopModel(modelName, timeoutMs);
    }
  }

  public async stopCurrentModel(timeoutMs = this.config.modelStopTimeoutMs): Promise<boolean> {
    const currentModel = await this.getCurrentModel();
    if (currentModel === null) {
      return false;
    }

    return this.stopModel(currentModel, timeoutMs);
  }

  public async getCurrentModel(): Promise<string | null> {
    const runningModels = await this.listRunningModels();
    return runningModels.length > 0 ? runningModels[0] : null;
  }

  public async listRunningModels(): Promise<string[]> {
    const runningModels: string[] = [];
    for (const modelName of Object.keys(this.config.models)) {
      if (await this.isModelRunning(modelName)) {
        runningModels.push(modelName);
      }
    }
    return runningModels;
  }

  private async spawnModel(modelName: string): Promise<void> {
    const modelConfig = this.config.models[modelName];
    await stat(modelConfig.pythonExecutable);
    await this.removeStopRequest(modelName);

    const subprocess = Bun.spawn({
      cmd: [
        modelConfig.pythonExecutable,
        "-m",
        modelConfig.module,
        "--jobs-root",
        this.config.jobsRoot,
        "--project-root",
        this.config.projectRoot,
        "--model-name",
        modelName,
        "--poll-interval-ms",
        `${this.config.pollIntervalMs}`,
      ],
      cwd: modelConfig.serviceDir,
      stdin: "ignore",
      stdout: "inherit",
      stderr: "inherit",
    });

    this.runtimes.set(modelName, {
      modelName,
      process: subprocess,
      startedAt: Date.now(),
    });
    void subprocess.exited.finally(() => {
      this.runtimes.delete(modelName);
    });

    await this.waitForPidFile(modelName, 15000);
  }

  private async isModelRunning(modelName: string): Promise<boolean> {
    const pid = await this.readPid(modelName);
    if (pid === null) {
      this.runtimes.delete(modelName);
      return false;
    }

    if (!this.isPidAlive(pid)) {
      await this.removePidFile(modelName);
      this.runtimes.delete(modelName);
      return false;
    }

    return true;
  }

  private async cleanupStaleProcesses(): Promise<void> {
    for (const modelName of Object.keys(this.config.models)) {
      await this.isModelRunning(modelName);
    }
  }

  private async waitForPidFile(modelName: string, timeoutMs: number): Promise<void> {
    const startedAt = Date.now();
    while (Date.now() - startedAt < timeoutMs) {
      if (await this.isModelRunning(modelName)) {
        return;
      }
      await Bun.sleep(250);
    }

    throw new Error(`Timed out waiting for PID file for ${modelName}`);
  }

  private async waitForStop(modelName: string, timeoutMs: number): Promise<boolean> {
    const startedAt = Date.now();
    while (Date.now() - startedAt < timeoutMs) {
      if (!(await this.isModelRunning(modelName))) {
        return true;
      }

      await Bun.sleep(250);
    }

    return false;
  }

  private async readPid(modelName: string): Promise<number | null> {
    try {
      const raw = await readFile(this.pidPath(modelName), "utf-8");
      const pid = Number.parseInt(raw.trim(), 10);
      return Number.isFinite(pid) ? pid : null;
    } catch (error) {
      if (getNodeErrorCode(error) === "ENOENT") {
        return null;
      }

      throw error;
    }
  }

  private killPid(pid: number, modelName: string, signal: NodeJS.Signals): void {
    try {
      process.kill(pid, signal);
    } catch (error) {
      if (!this.isPidAlive(pid)) {
        return;
      }

      throw new Error(`Failed to stop ${modelName} (pid ${pid})`);
    }
  }

  private async writeStopRequest(modelName: string): Promise<void> {
    await writeFile(this.stopRequestPath(modelName), nowIso(), "utf-8");
  }

  private async removeStopRequest(modelName: string): Promise<void> {
    try {
      await unlink(this.stopRequestPath(modelName));
    } catch (error) {
      if (getNodeErrorCode(error) !== "ENOENT") {
        throw error;
      }
    }
  }

  private stopRequestPath(modelName: string): string {
    return path.join(this.config.projectRoot, "services", `${modelName}.stop`);
  }

  private async removePidFile(modelName: string): Promise<void> {
    try {
      await unlink(this.pidPath(modelName));
    } catch (error) {
      if (getNodeErrorCode(error) !== "ENOENT") {
        throw error;
      }
    }
  }

  private isPidAlive(pid: number): boolean {
    try {
      process.kill(pid, 0);
      return true;
    } catch {
      return false;
    }
  }

  private pidPath(modelName: string): string {
    return path.join(this.config.projectRoot, "services", `${modelName}.pid`);
  }
}

const nowIso = (): string => new Date().toISOString();