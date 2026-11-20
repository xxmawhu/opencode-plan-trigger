// Regression test: a plan that never reached a session must stay queued.
// Uses a fake clock and a fake host so it runs without OpenCode.
// Exit code 0 = all cases pass; 1 = at least one case failed.
import { mkdirSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { createInjector } from "../plan-trigger-lib/injector.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const WORK = join(HERE, `.tmp-injector-expiry.${process.pid}`);
const PLAN = join(WORK, "example.md");
const MAX_AGE_MS = 30 * 60 * 1000;

let failed = 0;
function check(label, ok, detail) {
  if (ok) {
    console.log(`PASS: ${label}`);
    return;
  }
  failed += 1;
  console.log(`FAIL: ${label}${detail ? ` -> ${detail}` : ""}`);
}

const logs = [];
const logger = {
  info: (msg, data) => logs.push({ level: "info", msg, data }),
  warn: (msg, data) => logs.push({ level: "warn", msg, data }),
  error: (msg, data) => logs.push({ level: "error", msg, data }),
};
const drops = () => logs.filter((entry) => entry.msg === "dropping plan injection");
const keeps = () => logs.filter((entry) => entry.msg === "plan still waiting for an idle session");

const timers = [];
const setTimeoutFn = (fn, ms) => {
  const timer = { fn, ms, unref() {} };
  timers.push(timer);
  return timer;
};
const clearTimeoutFn = (timer) => {
  const index = timers.indexOf(timer);
  if (index >= 0) timers.splice(index, 1);
};

const settle = async () => {
  await new Promise((resolve) => setImmediate(resolve));
  await new Promise((resolve) => setImmediate(resolve));
};

let clock = 1_700_000_000_000;
const now = () => clock;

// Fire every pending timer after moving the fake clock forward.
async function advance(ms) {
  clock += ms;
  for (const timer of timers.splice(0)) timer.fn();
  await settle();
}

async function main() {
  mkdirSync(WORK, { recursive: true });
  writeFileSync(PLAN, "# plan\n");

  let session = null;
  const injected = [];
  const succeeded = [];
  const injector = createInjector({
    resolveSession: () => session,
    sendPrompt: async (sessionID, text) => {
      injected.push({ sessionID, text });
    },
    onSuccess: (item) => succeeded.push(item.path),
    logger,
    maxAgeMs: MAX_AGE_MS,
    now,
    setTimeoutFn,
    clearTimeoutFn,
  });

  // Case 1: no idle session, 31 minutes pass.
  const accepted = injector.enqueue(PLAN, "prompt", "sig-1");
  await settle();
  await injector.flush();
  await advance(MAX_AGE_MS + 60_000);
  await injector.flush();

  check("队列接受首个 plan", accepted === true);
  check("31 分钟后不丢弃未送达 plan", drops().length === 0, JSON.stringify(drops()));
  check("输出 keep-queued 告警", keeps().length >= 1);
  check("同一路径仍被去重（重新入队被拒）", injector.enqueue(PLAN, "prompt", "sig-1") === false);

  // Case 2: the plan file disappears -> only then drop.
  rmSync(PLAN, { force: true });
  await advance(MAX_AGE_MS + 60_000);
  await injector.flush();
  check("文件消失后丢弃一次", drops().length === 1 && drops()[0].data?.reason === "missing", JSON.stringify(drops()));

  // Case 3: a new plan is delivered once when a session becomes idle.
  writeFileSync(PLAN, "# plan 2\n");
  session = "ses-test";
  check("文件重建后重新入队", injector.enqueue(PLAN, "prompt", "sig-2") === true);
  await settle();
  check("空闲会话下注入一次", injected.length === 1 && injected[0].sessionID === "ses-test");
  check("注入成功后写 state 一次", succeeded.length === 1 && succeeded[0] === PLAN);
  await advance(MAX_AGE_MS + 60_000);
  await injector.flush();
  check("成功注入后不再重复注入", injected.length === 1);

  injector.stop();
  rmSync(WORK, { recursive: true, force: true });

  if (failed > 0) {
    console.log(`\n${failed} 项失败`);
    process.exit(1);
  }
  console.log("\n全部通过");
}

main().catch((error) => {
  console.error(error);
  rmSync(WORK, { recursive: true, force: true });
  process.exit(1);
});
