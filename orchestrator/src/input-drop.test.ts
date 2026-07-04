import { test, expect } from "bun:test";
import { tmpdir } from "node:os";
import path from "node:path";
import { mkdtemp, rm, writeFile, readFile, stat, mkdir } from "node:fs/promises";

import { loadConfig } from "./config";
import { JobManager, getModelFromJobId } from "./job-manager";
import { scanInputDrops, type DropJobSink, type DropRouting } from "./input-drop";
import { buildEngineRouting, type EngineRouting } from "./engine-routing";

// Override jobsRoot on the loaded config object rather than mutating the shared
// ECHOSCRIPT_JOBS_ROOT env var — Bun runs test files concurrently, so a global env
// mutation races across files (whichever value is set during another file's `await
// loadConfig()` wins). Overriding the returned object is race-free.
const configWithJobsRoot = async (jobsRoot: string) => {
  const loaded = await loadConfig();
  return { ...loaded, jobsRoot };
};

const inputDir = (base: string, ...segments: string[]): string =>
  path.join(base, "input", ...segments);

/** Legacy flat routing (no engines) — the pre-language-routing behaviour. */
const flat = (models: readonly string[]): DropRouting => ({ legacyModels: models, engines: new Map() });

/** A DropJobSink that records routing decisions without touching the fs (fast unit tests). */
const recordingSink = () => {
  const calls: { jobId: string; model: string; filename: string; language: string | null; params: Record<string, unknown> }[] = [];
  let counter = 0;
  const sink: DropJobSink = {
    async createDroppedJob(_processingPath, originalFilename, modelName, meta) {
      const jobId = `job${counter++}_${modelName}`;
      calls.push({ jobId, model: modelName, filename: originalFilename, language: meta?.language ?? null, params: {} });
      return { jobId };
    },
    async enqueueJob(jobId, params) {
      const call = calls.find((c) => c.jobId === jobId);
      if (call !== undefined) call.params = params;
      return {};
    },
  };
  return { sink, calls };
};

const whisperEngines: EngineRouting = new Map([
  ["whisper", new Map([["ru", "whisper_podlodka"], ["en", "whisper_en_turbo"]])],
]);

test("scanInputDrops turns a dropped raw file into a queued job and consumes it", async () => {
  const base = await mkdtemp(path.join(tmpdir(), "drop-scan-"));
  try {
    const config = await configWithJobsRoot(base);
    const jm = new JobManager(config);
    await jm.initialize();

    const dropped = path.join(inputDir(base, "whisper_podlodka"), "Два человека.wav");
    await writeFile(dropped, Buffer.alloc(32, 5));

    const created = await scanInputDrops(base, flat(Object.keys(config.models)), 0, jm);
    expect(created.length).toBe(1);
    const jobId = created[0]!;
    expect(getModelFromJobId(jobId, Object.keys(config.models))).toBe("whisper_podlodka");

    // raw file consumed, job data + queue marker created
    await expect(stat(dropped)).rejects.toBeDefined();
    expect((await readFile(path.join(base, "data", jobId, "input"))).length).toBe(32);
    await stat(path.join(base, "queue", `${jobId}.json`)); // throws if missing
    const inputJson = JSON.parse(await readFile(path.join(base, "data", jobId, "input.json"), "utf-8"));
    expect(inputJson.created_from).toBe("file_drop");
  } finally {
    await rm(base, { recursive: true, force: true });
  }
});

test("scanInputDrops recovers an orphaned .processing claim", async () => {
  const base = await mkdtemp(path.join(tmpdir(), "drop-orphan-"));
  try {
    const config = await configWithJobsRoot(base);
    const jm = new JobManager(config);
    await jm.initialize();

    const orphan = path.join(inputDir(base, "whisper_podlodka"), "song.flac.processing");
    await writeFile(orphan, Buffer.alloc(8, 1));

    const created = await scanInputDrops(base, flat(Object.keys(config.models)), 0, jm);
    expect(created.length).toBe(1);
    await expect(stat(orphan)).rejects.toBeDefined(); // recovered/moved
    expect((await readFile(path.join(base, "data", created[0]!, "input"))).length).toBe(8);
  } finally {
    await rm(base, { recursive: true, force: true });
  }
});

test("scanInputDrops ignores dispatch markers and unstable files", async () => {
  const base = await mkdtemp(path.join(tmpdir(), "drop-skip-"));
  try {
    const config = await configWithJobsRoot(base);
    const jm = new JobManager(config);
    await jm.initialize();

    const dir = inputDir(base, "whisper_podlodka");
    await writeFile(path.join(dir, "1751_abc_whisper_podlodka.json"), "{}"); // dispatch marker
    await writeFile(path.join(dir, "fresh.flac"), Buffer.alloc(4)); // just written -> unstable

    // stableMs high so the fresh file is not yet claimable; marker never claimable
    const created = await scanInputDrops(base, flat(Object.keys(config.models)), 60000, jm);
    expect(created).toEqual([]);
    await stat(path.join(dir, "1751_abc_whisper_podlodka.json")); // marker untouched
    await stat(path.join(dir, "fresh.flac")); // still there (unstable)
  } finally {
    await rm(base, { recursive: true, force: true });
  }
});

test("scanInputDrops routes input/<engine>/<language>/ to the resolved model and tags the language", async () => {
  const base = await mkdtemp(path.join(tmpdir(), "drop-lang-"));
  try {
    await mkdir(inputDir(base, "whisper", "en"), { recursive: true });
    await mkdir(inputDir(base, "whisper", "ru"), { recursive: true });
    await writeFile(path.join(inputDir(base, "whisper", "en"), "talk.flac"), Buffer.alloc(16, 7));
    await writeFile(path.join(inputDir(base, "whisper", "ru"), "Речь.wav"), Buffer.alloc(16, 8));

    const { sink, calls } = recordingSink();
    const routing: DropRouting = { legacyModels: [], engines: whisperEngines };
    const created = await scanInputDrops(base, routing, 0, sink);

    expect(created.length).toBe(2);
    const en = calls.find((c) => c.filename === "talk.flac")!;
    const ru = calls.find((c) => c.filename === "Речь.wav")!;
    expect(en.model).toBe("whisper_en_turbo");
    expect(en.language).toBe("en");
    expect(en.params).toEqual({ language: "en" });
    expect(ru.model).toBe("whisper_podlodka");
    expect(ru.language).toBe("ru");
    expect(ru.params).toEqual({ language: "ru" });
  } finally {
    await rm(base, { recursive: true, force: true });
  }
});

test("scanInputDrops rejects a mixed drop (engine root, no language) into _unrouted/", async () => {
  const base = await mkdtemp(path.join(tmpdir(), "drop-mixed-"));
  try {
    await mkdir(inputDir(base, "whisper"), { recursive: true });
    const mixed = path.join(inputDir(base, "whisper"), "mixed.flac");
    await writeFile(mixed, Buffer.alloc(16, 9));

    const { sink, calls } = recordingSink();
    const routing: DropRouting = { legacyModels: [], engines: whisperEngines };
    const created = await scanInputDrops(base, routing, 0, sink);

    expect(created).toEqual([]);
    expect(calls).toEqual([]);
    await expect(stat(mixed)).rejects.toBeDefined(); // moved out of the engine root
    await stat(path.join(inputDir(base, "whisper"), "_unrouted", "mixed.flac")); // parked here

    // A second sweep must not re-process the parked file.
    const again = await scanInputDrops(base, routing, 0, sink);
    expect(again).toEqual([]);
    expect(calls).toEqual([]);
  } finally {
    await rm(base, { recursive: true, force: true });
  }
});

test("scanInputDrops skips an unconfigured language subfolder", async () => {
  const base = await mkdtemp(path.join(tmpdir(), "drop-unklang-"));
  try {
    await mkdir(inputDir(base, "whisper", "de"), { recursive: true });
    const file = path.join(inputDir(base, "whisper", "de"), "sprache.flac");
    await writeFile(file, Buffer.alloc(16, 3));

    const { sink, calls } = recordingSink();
    const routing: DropRouting = { legacyModels: [], engines: whisperEngines };
    const created = await scanInputDrops(base, routing, 0, sink);

    expect(created).toEqual([]);
    expect(calls).toEqual([]);
    await stat(file); // left untouched
  } finally {
    await rm(base, { recursive: true, force: true });
  }
});

test("scanInputDrops (integration) routes input/whisper/ru/ to whisper_podlodka via real config", async () => {
  const base = await mkdtemp(path.join(tmpdir(), "drop-ru-int-"));
  try {
    const config = await configWithJobsRoot(base);
    const jm = new JobManager(config);
    await jm.initialize(); // creates input/whisper/ru/ from ws_daemons

    const dropped = path.join(inputDir(base, "whisper", "ru"), "Запись.wav");
    await writeFile(dropped, Buffer.alloc(24, 4));

    const models = Object.keys(config.models);
    const routing: DropRouting = { legacyModels: models, engines: buildEngineRouting(config.wsDaemons, models) };
    const created = await scanInputDrops(base, routing, 0, jm);

    expect(created.length).toBe(1);
    const jobId = created[0]!;
    expect(getModelFromJobId(jobId, models)).toBe("whisper_podlodka");
    const params = JSON.parse(await readFile(path.join(base, "data", jobId, "params.json"), "utf-8"));
    expect(params.language).toBe("ru");
    const inputJson = JSON.parse(await readFile(path.join(base, "data", jobId, "input.json"), "utf-8"));
    expect(inputJson.requested_language).toBe("ru");
  } finally {
    await rm(base, { recursive: true, force: true });
  }
});
