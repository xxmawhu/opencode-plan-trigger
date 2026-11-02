// Watches <project>/plan with fs.watch plus a periodic polling fallback.
// A file is ready when it is a regular non-empty file and its signature has not
// changed for the quiet window.
import { readdirSync, statSync, watch } from "node:fs";
import { join } from "node:path";

const IGNORED_NAMES = new Set([".gitkeep", ".DS_Store"]);
const IGNORED_SUFFIXES = [".tmp", ".temp", ".part", ".crdownload", ".swp", ".swo", "~"];

export function isPlanCandidate(name) {
  if (typeof name !== "string" || name.length === 0) return false;
  if (name.startsWith(".")) return false;
  if (IGNORED_NAMES.has(name)) return false;
  if (name.includes("/") || name.includes("\\")) return false;
  if (IGNORED_SUFFIXES.some((suffix) => name.endsWith(suffix))) return false;
  return true;
}

function signatureOf(file) {
  try {
    const stat = statSync(file);
    if (!stat.isFile()) return undefined;
    return {
      signature: `${stat.dev}:${stat.ino}:${stat.size}:${Math.trunc(stat.mtimeMs)}`,
      size: stat.size,
      mtimeMs: stat.mtimeMs,
    };
  } catch {
    return undefined;
  }
}

function unref(timer) {
  if (timer && typeof timer.unref === "function") timer.unref();
  return timer;
}

export function createPlanWatcher({
  planDir,
  state,
  logger,
  onReady,
  quietMs = 800,
  pollMs = 30_000,
  baselineGraceMs = 10 * 60_000,
  reInjectionCooldownMs = 60_000,
  setTimeoutFn = setTimeout,
  clearTimeoutFn = clearTimeout,
  setIntervalFn = setInterval,
  clearIntervalFn = clearInterval,
} = {}) {
  let watcher;
  let pollTimer;
  let missingLoggedAt = 0;
  const candidates = new Map();
  // Last accepted dispatch time per path; used only for the re-injection debounce window.
  const lastDispatched = new Map();

  function listFiles() {
    let entries;
    try {
      entries = readdirSync(planDir, { withFileTypes: true });
    } catch {
      return [];
    }
    const files = [];
    for (const entry of entries) {
      if (!isPlanCandidate(entry.name)) continue;
      const path = join(planDir, entry.name);
      const info = signatureOf(path);
      if (info) files.push({ path, ...info });
    }
    return files;
  }

  function cancel(path) {
    const candidate = candidates.get(path);
    if (!candidate) return;
    clearTimeoutFn(candidate.timer);
    candidates.delete(path);
  }

  function dispatch(path, info) {
    candidates.delete(path);
    if (state.has(path, info.signature)) return;
    const lastAt = lastDispatched.get(path);
    if (lastAt !== undefined && Date.now() - lastAt < reInjectionCooldownMs) return;
    try {
      const result = onReady(path, info.signature);
      if (result && typeof result.catch === "function") {
        result.catch((error) => logger?.error("plan ready handler failed", { path, error: String(error) }));
      }
      if (result !== false) lastDispatched.set(path, Date.now());
    } catch (error) {
      logger?.error("plan ready handler threw", { path, error: String(error) });
    }
  }

  function schedule(path, info) {
    if (state.has(path, info.signature)) return;
    // Drop a stale candidate before the cooldown check; otherwise a deferred
    // change can be blocked forever by an already-fired timer entry.
    cancel(path);
    const lastAt = lastDispatched.get(path);
    if (lastAt !== undefined && Date.now() - lastAt < reInjectionCooldownMs) return;
    const candidate = { signature: info.signature, size: info.size, timer: undefined };
    candidates.set(path, candidate);
    candidate.timer = unref(
      setTimeoutFn(() => {
        const current = candidates.get(path);
        if (current !== candidate) return;
        const latest = signatureOf(path);
        if (!latest) {
          cancel(path);
          state.forget(path);
          return;
        }
        if (latest.signature !== candidate.signature) {
          schedule(path, latest);
          return;
        }
        if (latest.size === 0) {
          // Empty files are ignored until a later write event or poll sees content.
          cancel(path);
          return;
        }
        dispatch(path, latest);
      }, quietMs),
    );
  }

  function consider(name) {
    if (!isPlanCandidate(name)) return;
    const path = join(planDir, name);
    const info = signatureOf(path);
    if (!info) {
      cancel(path);
      state.forget(path);
      return;
    }
    if (state.has(path, info.signature)) return;
    schedule(path, info);
  }

  function scanNow() {
    ensureWatch();
    const files = listFiles();
    const existing = new Set(files.map((file) => file.path));
    state.prune(existing);
    for (const path of [...lastDispatched.keys()]) {
      if (!existing.has(path)) lastDispatched.delete(path);
    }
    for (const file of files) {
      if (file.size === 0) continue;
      if (state.has(file.path, file.signature)) continue;
      if (candidates.has(file.path)) continue;
      schedule(file.path, file);
    }
  }

  function ensureWatch() {
    if (watcher) return;
    try {
      watcher = watch(planDir, { persistent: false }, (_eventType, filename) => {
        if (typeof filename === "string" && filename.length > 0) {
          consider(filename);
        } else {
          scanNow();
        }
      });
      watcher.on("error", (error) => {
        // [log-review] 预期内：目录被替换或句柄失效；降级原因：轮询兜底仍可发现文件；影响范围：最长延迟一个轮询周期
        logger?.warn("plan watcher stopped; polling fallback continues", { error: String(error) });
        try {
          watcher?.close();
        } catch {
          // Ignore close failures.
        }
        watcher = undefined;
      });
    } catch (error) {
      watcher = undefined;
      const now = Date.now();
      if (now - missingLoggedAt > 300_000) {
        missingLoggedAt = now;
        // [log-review] 预期内：plan 目录尚未创建；降级原因：每 5 分钟重试且轮询兜底；影响范围：创建后最长延迟一个轮询周期
        logger?.warn("plan directory is not watchable yet; polling fallback continues", {
          planDir,
          error: String(error),
        });
      }
    }
  }

  return {
    get planDir() {
      return planDir;
    },

    async start() {
      const loaded = state.load();
      if (!loaded || !state.initialized) {
        const cutoff = Date.now() - baselineGraceMs;
        const baselinePaths = [];
        for (const file of listFiles()) {
          if (file.mtimeMs > cutoff) continue;
          baselinePaths.push(file.path);
          logger?.info("baseline skip existing plan", {
            path: file.path,
            mtime: new Date(file.mtimeMs).toISOString(),
          });
        }
        state.baseline(baselinePaths);
      }
      scanNow();
      pollTimer = unref(setIntervalFn(scanNow, pollMs));
    },

    scanNow,
    consider,

    async stop() {
      if (pollTimer) {
        clearIntervalFn(pollTimer);
        pollTimer = undefined;
      }
      for (const path of [...candidates.keys()]) cancel(path);
      try {
        watcher?.close();
      } catch {
        // Ignore close failures.
      }
      watcher = undefined;
    },
  };
}