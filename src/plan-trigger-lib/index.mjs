// plan-trigger shared library (no runtime dependencies, Node/Bun built-ins only).
export { createPlanTrigger, buildPlanPrompt, PROMPT_TEMPLATE } from "./trigger.mjs";
export { createPlanWatcher } from "./watcher.mjs";
export { createInjector } from "./injector.mjs";
export { createSessionTracker } from "./session-tracker.mjs";
export { createStateStore } from "./state.mjs";
export { createLogger } from "./logger.mjs";