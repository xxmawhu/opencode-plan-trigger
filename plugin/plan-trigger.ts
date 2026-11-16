// OpenCode plugin entry, installed as ~/.config/opencode/plugin/plan-trigger.ts.
//
// Dual-generation export, one plain object literal:
//   - opencode 1.x reads the default object and calls `server(input)`.
//   - opencode 2.x validates `id` + `setup(ctx)` on the same object.
// The shared library lives outside both scan directories (plugin/, plugins/) at
// ~/.config/opencode/plan-trigger-lib/, so neither host can mistake it for a plugin.
import { join } from "node:path";
import { createLogger, createPlanTrigger } from "../plan-trigger-lib/index.mjs";

// One trigger per project directory. A newer v1 host may run both the v1 and v2
// passes in one process, so server() and setup() can both fire; the refcount
// keeps a single watcher/injector instead of injecting the same plan twice.
const hosts = new Map();

function acquireHost({ directory, logger, listSessions, sendPrompt }) {
  const existing = hosts.get(directory);
  if (existing) {
    existing.refs += 1;
    return { host: existing, created: false };
  }
  const trigger = createPlanTrigger({
    planDir: join(directory, "plan"),
    logger,
    listSessions,
    sendPrompt,
  });
  const host = { trigger, refs: 1 };
  hosts.set(directory, host);
  return { host, created: true };
}

function releaseHost(directory) {
  const host = hosts.get(directory);
  if (!host) return undefined;
  host.refs -= 1;
  if (host.refs > 0) return undefined;
  hosts.delete(directory);
  return host.trigger.stop();
}

// Generation is decided by the registration surface actually present, never by a
// version string. Missing surface means "not my generation": the adapter stays
// inert, which also makes the v1 config callback of a v2 host harmless.
function v1Surface(input) {
  const directory = input?.directory ?? input?.worktree;
  if (typeof directory !== "string" || directory.length === 0) return undefined;
  const session = input?.client?.session;
  if (typeof session?.list !== "function") return undefined;
  if (typeof session?.prompt !== "function" && typeof session?.promptAsync !== "function") return undefined;
  return directory;
}

function v2Surface(ctx) {
  if (typeof ctx?.location?.directory !== "string" || ctx.location.directory.length === 0) return undefined;
  if (typeof ctx?.session?.list !== "function") return undefined;
  if (typeof ctx?.session?.prompt !== "function") return undefined;
  return ctx.location.directory;
}

// V1 adapter: translate the core into the classic initialization flow and return
// the hook table the v1 host consumes.
async function server(input) {
  const directory = v1Surface(input);
  if (!directory) return {};
  const client = input.client;
  const logger = createLogger();

  const { host, created } = acquireHost({
    directory,
    logger,
    listSessions: async () => {
      const result = await client.session.list({ query: { directory } });
      if (Array.isArray(result)) return result;
      if (Array.isArray(result?.data)) return result.data;
      return [];
    },
    sendPrompt: async (sessionID, text) => {
      const payload = {
        path: { id: sessionID },
        body: { parts: [{ type: "text", text }] },
        query: { directory },
      };
      if (typeof client.session.promptAsync === "function") {
        await client.session.promptAsync(payload);
        return;
      }
      await client.session.prompt(payload);
    },
  });

  host.trigger.start().catch((error) => {
    logger.error("failed to start plan-trigger", { error: String(error) });
  });

  if (created) logger.info("plan-trigger loaded", { planDir: host.trigger.planDir });

  return {
    event: async ({ event }) => {
      host.trigger.noteEvent(event);
    },
    dispose: async () => {
      await releaseHost(directory);
    },
  };
}

// V2 adapter: translate the same core onto context methods and return the
// cleanup callback the v2 host expects.
async function setup(ctx) {
  // Some v1 hosts reach only setup(); hand the v1-shaped input to server() and
  // reuse its dispose so the refcount still balances.
  if (typeof ctx?.client?.session === "object") {
    const hooks = await server(ctx);
    return hooks?.dispose;
  }
  const directory = v2Surface(ctx);
  if (!directory) return undefined;
  const logger = createLogger();

  const { host, created } = acquireHost({
    directory,
    logger,
    listSessions: async () => {
      const page = await ctx.session.list({ directory, limit: 50 });
      if (Array.isArray(page)) return page;
      if (Array.isArray(page?.data)) return page.data;
      if (Array.isArray(page?.items)) return page.items;
      return [];
    },
    sendPrompt: async (sessionID, text) => {
      await ctx.session.prompt({ sessionID, text });
    },
  });

  await host.trigger.start();
  if (created) logger.info("plan-trigger loaded", { planDir: host.trigger.planDir });

  const controller = new AbortController();
  const events =
    typeof ctx?.event?.subscribe === "function" ? ctx.event.subscribe({ signal: controller.signal }) : undefined;
  if (events) {
    void (async () => {
      try {
        for await (const event of events) host.trigger.noteEvent(event);
      } catch (error) {
        // [log-review] 预期内：插件卸载或连接重建；降级原因：注入不依赖该事件流；影响范围：会话跟踪退化为最近会话
        if (!controller.signal.aborted) {
          logger.warn("event stream ended (plugin unload or reconnect); tracking falls back to latest session", {
            error: String(error),
          });
        }
      }
    })();
  }

  return async () => {
    controller.abort();
    await releaseHost(directory);
  };
}

// `server` for opencode 1.x, `id` + `setup` for opencode 2.x. Both generations
// read this exact literal; it is never rewritten, wrapped or spread.
export default { id: "plan-trigger", server, setup };