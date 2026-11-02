// Composes the watcher, session tracker and injector into a single lifecycle object.
// Host plugins only provide listSessions() and sendPrompt(); everything else is local.
import { basename } from "node:path";
import { createInjector } from "./injector.mjs";
import { createLogger } from "./logger.mjs";
import { createSessionTracker } from "./session-tracker.mjs";
import { createStateStore } from "./state.mjs";
import { createPlanWatcher } from "./watcher.mjs";

export const PROMPT_TEMPLATE = "请严格遵守{plan-path}的内容，完成所有的任务";

// 注入词只携带项目内相对路径（./plan/<file>），不暴露部署机的绝对目录。
export function toDisplayPlanPath(planPath, planDir = "plan") {
  return `./${basename(planDir)}/${basename(planPath)}`;
}

export function buildPlanPrompt(planPath, planDir = "plan") {
  return PROMPT_TEMPLATE.replace("{plan-path}", toDisplayPlanPath(planPath, planDir));
}

export function createPlanTrigger({
  planDir,
  stateDir,
  logger,
  listSessions,
  sendPrompt,
  quietMs,
  pollMs,
  baselineGraceMs,
  reInjectionCooldownMs,
  maxAgeMs,
  now,
  setTimeoutFn,
  clearTimeoutFn,
  setIntervalFn,
  clearIntervalFn,
} = {}) {
  if (typeof planDir !== "string" || planDir.length === 0) {
    throw new TypeError("createPlanTrigger requires planDir");
  }
  if (typeof listSessions !== "function") {
    throw new TypeError("createPlanTrigger requires listSessions()");
  }
  if (typeof sendPrompt !== "function") {
    throw new TypeError("createPlanTrigger requires sendPrompt()");
  }

  const log = logger || createLogger({ stateDir });
  const state = createStateStore({ planDir, stateDir });
  const sessions = createSessionTracker({ listSessions, logger: log });

  const injector = createInjector({
    resolveSession: () => sessions.resolve(),
    sendPrompt,
    onSuccess: (item) => state.mark(item.path, item.signature),
    logger: log,
    maxAgeMs,
    now,
    setTimeoutFn,
    clearTimeoutFn,
  });

  const watcher = createPlanWatcher({
    planDir,
    state,
    logger: log,
    quietMs,
    pollMs,
    baselineGraceMs,
    reInjectionCooldownMs,
    setTimeoutFn,
    clearTimeoutFn,
    setIntervalFn,
    clearIntervalFn,
    onReady: (path, signature) => {
      return injector.enqueue(path, buildPlanPrompt(path, planDir), signature);
    },
  });

  let started = false;

  return {
    planDir,
    noteEvent: (event) => sessions.noteEvent(event),
    async start() {
      if (started) return;
      started = true;
      await watcher.start();
    },
    async stop() {
      if (!started) return;
      started = false;
      injector.stop();
      await watcher.stop();
    },
    get started() {
      return started;
    },
  };
}