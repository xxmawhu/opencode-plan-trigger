// OpenCode v1 plugin entry. Installed as ~/.config/opencode/plugin/plan-trigger.ts
// Only the plugin function is exported on purpose: the v1 loader requires every
// export of a legacy plugin module to be a plugin function.
import { join } from "node:path";
import { createLogger, createPlanTrigger } from "./plan-trigger-lib/index.mjs";

function createPlugin(input) {
  const directory = input?.directory || input?.worktree || process.cwd();
  const client = input?.client;
  const logger = createLogger();

  if (!client?.session) {
    logger.error("opencode session client is unavailable; plan-trigger disabled");
    return {};
  }

  const trigger = createPlanTrigger({
    planDir: join(directory, "plan"),
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

  trigger.start().catch((error) => {
    logger.error("failed to start plan-trigger", { error: String(error) });
  });

  logger.info("plan-trigger loaded", { planDir: trigger.planDir });

  return {
    event: async ({ event }) => {
      trigger.noteEvent(event);
    },
    dispose: async () => {
      await trigger.stop();
    },
  };
}

export const Plugin = createPlugin;
export default createPlugin;