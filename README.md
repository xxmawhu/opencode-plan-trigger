# plan-trigger

面向 OpenCode 用户。

OpenCode 插件。监控项目根目录下的 `plan/`，新写入完成的 plan 文件会立即注入当前会话，提示词为：

> 请严格遵守{plan-path}的内容，完成所有的任务

其中 `{plan-path}` 为项目内相对路径，形如 `./plan/2026-11-02_refactor.md`。

## 环境要求

- OpenCode 1.x 或 2.x（同一份安装同时服务两代宿主）
- 无需安装任何 npm 依赖

## 安装

```bash
./install.sh
```

安装布局遵循 OpenCode 插件安装契约 v1：

- 入口（两代共用同一文件）：`~/.config/opencode/plugin/plan-trigger.ts`
- 共享库（在插件扫描目录之外）：`~/.config/opencode/plan-trigger-lib/`

安装同时满足三条约束：

- 库在扫描区外：宿主不会把 `plan-trigger-lib/` 当插件加载。
- 单次生效：一个入口文件，每进程只激活一次。
- 零告警验收：两个宿主启动日志均无 `failed to load plugin`。

重新执行 `./install.sh` 即可升级，重复安装结果一致。仓库已配置 `post-merge` hook，`git pull` 后会自动重新安装。

安装日志写入仓库 `log/install.<日期>.log`。若该目录不可写（只读副本、他人属主等），日志降级到 stderr，安装照常完成。

验证：重启 OpenCode，在任意项目写入一个非空 `plan/*.md`，随后查看运行日志出现 `injected plan prompt`。

## 使用

在项目根目录创建 `plan/` 目录，写入任意 `.md` 文件即可。文件保存后约 1 秒触发注入；同一路径的内容签名变化后会再次注入（60 秒防抖）。

```bash
your-project/
  plan/
    2026-11-02_refactor.md
```

说明：

- 空文件不触发，等待写入内容后再注入。
- 隐藏文件、`.gitkeep`、`.tmp` / `.part` / `.swp` 等临时文件忽略。
- 插件启动时，修改时间早于 10 分钟的 plan 文件记为基线不注入；10 分钟内新写入的文件仍会正常注入。
- 目录变化偶尔漏检时会在 30 秒内自动复查补上。
- 当前没有可用会话时，注入任务会排队等待，最长保留 30 分钟。
- 文件大小或 mtime 变化会触发重新注入；仅改写 front matter 元数据也属于签名变化。

## 日志

- 运行日志：`~/.local/state/opencode-plan-trigger/plan-trigger.log`
- 安装日志：`log/install.YYYYMMDD.log`

## 卸载

```bash
rm -rf ~/.config/opencode/plugin/plan-trigger.ts \
       ~/.config/opencode/plan-trigger-lib
```

旧版本遗留的 `~/.config/opencode/plugin/plan-trigger-lib` 与
`~/.config/opencode/plugins/plan-trigger` 会被 `install.sh` 自动删除。

## 常见问题

**没有触发注入**

确认 plan 文件非空、扩展名任意但文件名不以 `.` 开头，并查看运行日志是否有 `injected plan prompt`。

**注入了但会话没有开始执行**

注入会发送到最近活跃的会话；当前没有打开会话时，排队等待新会话出现后再注入。

**启动日志出现 `failed to load plugin`**

重新执行 `./install.sh`。若仍出现，检查 `~/.config/opencode/plugin/` 与
`~/.config/opencode/plugins/` 下是否残留旧版库目录。