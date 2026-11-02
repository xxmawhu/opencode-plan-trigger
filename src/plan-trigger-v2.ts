// OpenCode v2 plugin entry. Installed as ~/.config/opencode/plugins/plan-trigger/index.ts
// define() from @opencode/plugin is an identity function, so the plain object below
// avoids any runtime dependency on the host package.
import { join } from "node:path";
import { createLogger, createPlanTrigger } from "./plan-trigger-lib/index.mjs";

const planTriggerPlugin = {
  id: "plan-trigger",
  async setup(ctx) {
    const logger = createLogger();
    const directory = ctx?.location?.directory || process.cwd();
    const controller = new AbortController();

    const trigger = createPlanTrigger({
      planDir: join(directory, "plan"),
      logger,
      listSessions: async () => {
        if (typeof ctx?.session?.list !== "function") return [];
        const page = await ctx.session.list({ directory, limit: 50 });
        if (Array.isArray(page)) return page;
        if (Array.isArray(page?.data)) return page.data;
        if (Array.isArray(page?.items)) return page.items;
        return [];
      },
      sendPrompt: async (sessionID, text) => {
        if (typeof ctx?.session?.prompt !== "function") {
          throw new Error("session.prompt is unavailable");
        }
        await ctx.session.prompt({ sessionID, text });
      },
    });

    await trigger.start();
    logger.info("plan-trigger loaded", { planDir: trigger.planDir });

    const events = typeof ctx?.event?.subscribe === "function" ? ctx.event.subscribe({ signal: controller.signal }) : undefined;
    if (events) {
      void (async () => {
        try {
          for await (const event of events) trigger.noteEvent(event);
        } catch (error) {
          // [log-review] 预期内：插件卸载或连接重建；降级原因：注入不依赖该事件流；影响范围：会话跟踪退化为最近会话
          if (!controller.signal.aborted) logger.warn("event stream ended", { error: String(error) });
        }
      })();
    }

    return async () => {
      controller.abort();
      await trigger.stop();
    };
  },
};

export default planTriggerPlugin;