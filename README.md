# plan-trigger

面向 OpenCode 用户。

OpenCode 插件。监控项目根目录下的 `plan/`，新写入完成的 plan 文件会立即注入当前会话，提示词为：

> 请严格遵守{plan-path}的内容，完成所有的任务

## 环境要求

- OpenCode v1 或 v2
- 无需安装任何 npm 依赖

## 安装

```bash
./install.sh
```

安装会把插件写入 `~/.config/opencode/`：

- v1：`~/.config/opencode/plugin/plan-trigger.ts`
- v2：`~/.config/opencode/plugins/plan-trigger/index.ts`

重新执行 `./install.sh` 即可升级。仓库已配置 `post-merge` hook，`git pull` 后会自动重新安装。

验证：重启 OpenCode，在任意项目写入一个非空 `plan/*.md`，随后查看运行日志出现 `injected plan prompt`。

## 使用

在项目根目录创建 `plan/` 目录，写入任意 `.md` 文件即可。文件保存后约 1 秒触发注入，每个文件只注入一次。

```bash
your-project/
  plan/
    2026-11-02_refactor.md
```

说明：

- 空文件不触发，等待写入内容后再注入。
- 隐藏文件、`.gitkeep`、`.tmp` / `.part` / `.swp` 等临时文件忽略。
- 插件启动时已存在的 plan 文件只记为基线，不会重复注入。
- 目录变化偶尔漏检时会在 30 秒内自动复查补上。
- 当前没有可用会话时，注入任务会排队等待，最长保留 30 分钟。

## 日志

- 运行日志：`~/.local/state/opencode-plan-trigger/plan-trigger.log`
- 安装日志：`log/install.YYYYMMDD.log`

## 卸载

```bash
rm -rf ~/.config/opencode/plugin/plan-trigger.ts \
       ~/.config/opencode/plugin/plan-trigger-lib \
       ~/.config/opencode/plugins/plan-trigger
```

## 常见问题

**没有触发注入**

确认 plan 文件非空、扩展名任意但文件名不以 `.` 开头，并查看运行日志是否有 `injected plan prompt`。

**注入了但会话没有开始执行**

注入会发送到最近活跃的会话；当前没有打开会话时，排队等待新会话出现后再注入。