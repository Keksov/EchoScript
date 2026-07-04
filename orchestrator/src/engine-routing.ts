import type { WsDaemonConfig } from "./config";

/**
 * Language routing (LG-D4, resolved at the design gate): a file dropped in
 * jobs/input/<engine>/<language>/ is resolved to a concrete model *at intake*, so the
 * rest of the pipeline (jobId, model routing, registry, readiness-gate) is untouched.
 *
 * The routing table is derived from ws_daemons — the single source of truth. Each daemon
 * that declares an `engine` family and a `language` contributes one (engine, language) ->
 * modelName entry. Daemons without both fields are legacy model-only daemons and are
 * ignored here (their input/<model>/ dirs are scanned flat).
 */
export type EngineRouting = ReadonlyMap<string, ReadonlyMap<string, string>>;

/**
 * Build `engine -> (language -> modelName)` from ws_daemons.
 *
 * `knownModels`, when non-empty, filters out entries whose model is not (yet) registered
 * — so a daemon can be declared before its model is staged without the scanner claiming
 * files it cannot turn into jobs (guards the P2/P3 ordering: EN daemon may appear before
 * its model). On a duplicate (engine, language) the first daemon wins.
 */
export const buildEngineRouting = (
  wsDaemons: Readonly<Record<string, WsDaemonConfig>>,
  knownModels: readonly string[] = [],
): EngineRouting => {
  const known = knownModels.length > 0 ? new Set(knownModels) : null;
  const engines = new Map<string, Map<string, string>>();

  for (const daemon of Object.values(wsDaemons)) {
    if (daemon.engine === undefined || daemon.language === undefined) {
      continue;
    }
    if (known !== null && !known.has(daemon.modelName)) {
      continue;
    }

    const engine = daemon.engine.toLowerCase();
    const language = daemon.language.toLowerCase();
    let langMap = engines.get(engine);
    if (langMap === undefined) {
      langMap = new Map<string, string>();
      engines.set(engine, langMap);
    }
    if (!langMap.has(language)) {
      langMap.set(language, daemon.modelName);
    }
  }

  return engines;
};
