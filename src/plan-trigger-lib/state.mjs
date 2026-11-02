// Durable per-plan-directory state: which plan files already triggered an injection.
import { createHash } from "node:crypto";
import {
  existsSync,
  mkdirSync,
  readFileSync,
  renameSync,
  statSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const VERSION = 1;

export function fileSignature(file) {
  try {
    const stat = statSync(file);
    if (!stat.isFile()) return undefined;
    return `${stat.dev}:${stat.ino}:${stat.size}:${Math.trunc(stat.mtimeMs)}`;
  } catch {
    return undefined;
  }
}

export function createStateStore({ planDir, stateDir } = {}) {
  const root = stateDir || join(homedir(), ".local", "state", "opencode-plan-trigger");
  const digest = createHash("sha1").update(planDir).digest("hex").slice(0, 16);
  const file = join(root, `state-${digest}.json`);
  let initialized = false;
  let processed = new Map();

  function load() {
    try {
      if (!existsSync(file)) return false;
      const raw = JSON.parse(readFileSync(file, "utf8"));
      if (!raw || raw.version !== VERSION || raw.planDir !== planDir) return false;
      const entries = raw.processed && typeof raw.processed === "object" ? raw.processed : {};
      processed = new Map(Object.entries(entries).filter(([key, value]) => typeof key === "string" && typeof value === "string"));
      initialized = true;
      return true;
    } catch {
      processed = new Map();
      initialized = false;
      return false;
    }
  }

  function save() {
    const payload = {
      version: VERSION,
      planDir,
      initializedAt: new Date().toISOString(),
      processed: Object.fromEntries(processed),
    };
    try {
      if (!existsSync(root)) mkdirSync(root, { recursive: true });
      const tmp = `${file}.${process.pid}.${Date.now()}.tmp`;
      writeFileSync(tmp, JSON.stringify(payload, null, 2));
      renameSync(tmp, file);
      return true;
    } catch {
      try {
        if (existsSync(file)) unlinkSync(file);
      } catch {
        // Best effort only.
      }
      return false;
    }
  }

  function baseline(paths) {
    processed = new Map();
    for (const path of paths) {
      const signature = fileSignature(path);
      if (signature !== undefined) processed.set(path, signature);
    }
    initialized = true;
    save();
  }

  function has(path) {
    return processed.has(path);
  }

  function mark(path) {
    const signature = fileSignature(path);
    processed.set(path, signature === undefined ? "unknown" : signature);
    save();
  }

  function forget(path) {
    if (!processed.delete(path)) return false;
    save();
    return true;
  }

  function prune(existing) {
    let changed = false;
    for (const path of [...processed.keys()]) {
      if (!existing.has(path)) {
        processed.delete(path);
        changed = true;
      }
    }
    if (changed) save();
    return changed;
  }

  return {
    get initialized() {
      return initialized;
    },
    load,
    save,
    baseline,
    has,
    mark,
    forget,
    prune,
  };
}