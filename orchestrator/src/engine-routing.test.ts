import { test, expect } from "bun:test";

import { buildEngineRouting } from "./engine-routing";
import type { WsDaemonConfig } from "./config";

const daemon = (over: Partial<WsDaemonConfig>): WsDaemonConfig => ({
  host: "127.0.0.1",
  port: 7801,
  modelName: "whisper_podlodka",
  ...over,
});

test("buildEngineRouting maps (engine, language) -> model from ws_daemons", () => {
  const routing = buildEngineRouting({
    whisperdaemon: daemon({ engine: "whisper", language: "ru", modelName: "whisper_podlodka" }),
    whisperdaemon_en: daemon({ engine: "whisper", language: "en", modelName: "whisper_en_turbo", port: 7802 }),
  });

  expect(routing.get("whisper")?.get("ru")).toBe("whisper_podlodka");
  expect(routing.get("whisper")?.get("en")).toBe("whisper_en_turbo");
});

test("buildEngineRouting ignores daemons without both engine and language", () => {
  const routing = buildEngineRouting({
    legacy: daemon({ modelName: "whisper_podlodka" }), // no engine/language
    halfEngine: daemon({ engine: "whisper", modelName: "whisper_podlodka" }), // no language
    halfLang: daemon({ language: "ru", modelName: "whisper_podlodka" }), // no engine
  });

  expect(routing.size).toBe(0);
});

test("buildEngineRouting drops entries whose model is not among knownModels", () => {
  const routing = buildEngineRouting(
    {
      whisperdaemon: daemon({ engine: "whisper", language: "ru", modelName: "whisper_podlodka" }),
      whisperdaemon_en: daemon({ engine: "whisper", language: "en", modelName: "whisper_en_turbo" }),
    },
    ["whisper_podlodka"], // en model not staged yet (P3)
  );

  expect(routing.get("whisper")?.get("ru")).toBe("whisper_podlodka");
  expect(routing.get("whisper")?.has("en")).toBe(false);
});

test("buildEngineRouting lower-cases engine and language keys", () => {
  const routing = buildEngineRouting({
    d: daemon({ engine: "Whisper", language: "EN", modelName: "whisper_en_turbo" }),
  });

  expect(routing.get("whisper")?.get("en")).toBe("whisper_en_turbo");
});

test("buildEngineRouting keeps the first daemon on a duplicate (engine, language)", () => {
  const routing = buildEngineRouting({
    first: daemon({ engine: "whisper", language: "ru", modelName: "whisper_podlodka" }),
    second: daemon({ engine: "whisper", language: "ru", modelName: "whisper_other", port: 7999 }),
  });

  expect(routing.get("whisper")?.get("ru")).toBe("whisper_podlodka");
});
