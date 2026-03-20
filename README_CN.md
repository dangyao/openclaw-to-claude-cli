# openclaw-to-claude-cli

将你的编码任务通过 OpenClaw 等 AGI 平台派发给 Claude Code 

任务派发与异步回调方案:CLI + Hook

[English](./README.md)

---

## 定位

面向**自带 Gateway/HTTP 端点的 AGI 平台**（如 OpenClaw）。采用 dispatch-and-callback 模式：派发任务后立即返回，Claude Code 完成时 Stop Hook 自动回调通知 AGI。零轮询、零 token 浪费。

---

## 架构

```
OpenClaw / AGI 平台
  │
  └─ dispatch-claude.sh -p "任务" -w /project --callback-url http://...
       │
       ├─ 1. 写入 task-meta.json（任务名、回调 URL、目标群组）
       ├─ 2. 启动 Claude Code（iTerm2 或 tmux headless）
       ├─ 3. 立即返回（不阻塞 AGI）
       │
       └─ [异步] Claude Code 完成 → Stop Hook 自动触发
             notify-hook.sh:
             ├─ 防重复锁（30s 窗口）
             ├─ 检查 task-meta.json status == "running"
             ├─ 读取输出 → 写入 latest.json
             ├─ HTTP 回调（自动适配 /hooks/wake 或 /hooks/agent 格式）
             ├─ OpenClaw Gateway 唤醒
             ├─ Telegram/Slack 群组通知
             ├─ macOS 原生通知
             ├─ 写入 pending-wake.json（备用）
             └─ 标记 task-meta.json status: "done"
```

---

## 前置要求

- macOS（iTerm2 模式）或 Linux（tmux 模式）
- Python >= 3.10
- `jq` 命令行工具
- Claude Code CLI 已安装

---

## 文件结构

```
openclaw-to-claude-cli/
  dispatch-claude.sh        # 任务派发入口
  claude_code_run.py        # PTY/tmux 运行器
  hooks/
    notify-hook.sh          # Stop/SessionEnd Hook 回调脚本
    claude-settings.json    # Hook 注册配置示例
  pyproject.toml
```

---

## 安装配置

### 1. OpenClaw Gateway 侧：启用 Webhook 端点

OpenClaw 有两套独立的 Hook 系统：

| 系统 | 配置位置 | 作用 |
|------|----------|------|
| **内部 Hooks** (`hooks.internal`) | `openclaw.json` → `hooks.internal` | Gateway 内部事件驱动（boot-md、session-memory 等） |
| **外部 Webhooks** (`hooks.enabled`) | `openclaw.json` → `hooks.enabled` + `hooks.token` | HTTP 端点，接收外部系统的请求（`/hooks/wake`、`/hooks/agent`） |

两者互相独立，需要分别配置。`notify-hook.sh` 回调给 Gateway 使用的是**外部 Webhooks**。

在 `~/.openclaw/openclaw.json` 的 `hooks` 节点中添加：

```json
"hooks": {
  "enabled": true,
  "token": "your-webhook-secret",
  "path": "/hooks",
  "allowedAgentIds": ["hooks", "main", "claude"],
  "internal": {
    "enabled": true,
    "entries": {
      "boot-md": { "enabled": true }
    }
  }
}
```

| 字段 | 必填 | 说明 |
|------|------|------|
| `enabled` | 是 | 启用外部 webhook HTTP 端点 |
| `token` | 是 | Webhook 认证 token，所有请求必须携带 |
| `path` | 否 | 端点前缀，默认 `/hooks` |
| `allowedAgentIds` | 否 | 允许被 webhook 触发的 agent ID 列表 |

认证方式（根据[官方文档](https://docs.openclaw.ai/automation/webhook)）：
- `Authorization: Bearer <token>` （推荐）
- `x-openclaw-token: <token>` （备选）
- **不支持** query string `?token=...`（返回 HTTP 400）

### 2. Claude Code 侧：注册 Hook

在 `~/.claude/settings.json` 中添加：

```json
{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "~/WorkSpace/openclaw-to-claude-cli/hooks/notify-hook.sh",
            "timeout": 10
          }
        ]
      }
    ],
    "SessionEnd": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "~/WorkSpace/openclaw-to-claude-cli/hooks/notify-hook.sh",
            "timeout": 10
          }
        ]
      }
    ]
  }
}
```

### 3. 环境变量

```bash
# OpenClaw Gateway 地址
export OPENCLAW_GATEWAY="http://127.0.0.1:18789"

# Webhook 认证 token（对应 openclaw.json 中的 hooks.token）
export OPENCLAW_GATEWAY_TOKEN="your-webhook-secret"

# Claude Code 二进制路径
export CLAUDE_CODE_BIN="/Users/xxxx/.nvm/versions/node/v22.22.0/bin/claude"

# openclaw CLI 路径（如果不在 PATH 中）
export OPENCLAW_BIN="openclaw"
```

**注意**：`OPENCLAW_GATEWAY_TOKEN` 对应的是 `hooks.token`，不是 `gateway.auth.token`。如果两者设为相同值则无需区分。

---

## 使用方法

### dispatch-claude.sh

任务派发脚本，启动 Claude Code 后立即返回。

```bash
./dispatch-claude.sh [OPTIONS] -p "你的任务提示"
```

**参数：**

| 参数 | 说明 |
|---|---|
| `-p, --prompt` | **必填** 任务提示 |
| `-n, --name` | 任务名称（用于跟踪） |
| `-w, --workdir` | 工作目录 |
| `-g, --group` | Telegram/Slack 群组 ID |
| `-s, --session` | AGI 回调 session key |
| `--callback-url` | 完成后回调的 HTTP URL |
| `--mode` | `headless`（默认）或 `interactive` |
| `--use-iterm` | 使用 iTerm2（macOS 专属） |
| `--model` | 模型覆盖 |
| `--permission-mode` | Claude Code 权限模式 |
| `--allowed-tools` | 允许的工具列表 |
| `--agent-teams` | 启用 Agent Teams |
| `--teammate-mode` | Agent Teams 模式 (auto/in-process/tmux) |

---

## 使用示例

### 回调 /hooks/wake（简单唤醒）

```bash
./dispatch-claude.sh \
  -p "分析代码结构" \
  -w /Users/me/my-project \
  --callback-url "http://127.0.0.1:18789/hooks/wake"
```

Gateway 收到 `{"text": "Task adhoc-xxx completed: ...", "mode": "now"}`，唤醒主会话。

### 回调 /hooks/agent（触发 Agent 处理）

```bash
./dispatch-claude.sh \
  -p "执行代码审查并生成报告" \
  -n "code-review" \
  -w /Users/me/my-project \
  --callback-url "http://127.0.0.1:18789/hooks/agent"
```

Gateway 启动独立 agent 处理 Claude Code 的输出，并通过消息频道推送结果。

### iTerm2 模式

```bash
./dispatch-claude.sh \
  -p "修复所有 lint 错误" \
  -w /Users/me/my-project \
  --use-iterm \
  --callback-url http://127.0.0.1:18789/hooks/wake
```

在 iTerm2 中打开新 tab 运行，可以实时观察 Claude Code 的输出。

### 仅通过环境变量（无需 callback-url）

```bash
export OPENCLAW_GATEWAY="http://127.0.0.1:18789"
export OPENCLAW_GATEWAY_TOKEN="your-webhook-secret"

./dispatch-claude.sh \
  -p "修复 lint 错误" \
  -w /Users/me/my-project
```

不指定 `--callback-url`，Hook 仍会通过环境变量自动调用 `/hooks/wake`。

### Agent Teams 模式

```bash
./dispatch-claude.sh \
  -p "并行完成：1) 写单元测试 2) 更新文档 3) 修复 lint" \
  -w /Users/me/my-project \
  --agent-teams \
  --teammate-mode tmux \
  --callback-url http://127.0.0.1:18789/hooks/agent
```

启用 Agent Teams，Claude Code 会自动拆分为多个子 Agent 并行工作。

### 回调外部系统 + 同时唤醒 Gateway

```bash
export OPENCLAW_GATEWAY="http://127.0.0.1:18789"
export OPENCLAW_GATEWAY_TOKEN="your-webhook-secret"

./dispatch-claude.sh \
  -p "重构 API" \
  -w /Users/me/my-project \
  --callback-url "http://my-ci-server.com/api/task-done" \
  -g "-1001812192154"
```

任务完成后同时：
1. POST 到 CI 服务器（发送完整 latest.json）
2. 唤醒 OpenClaw Gateway（通过环境变量）
3. 发送 Telegram 群组消息
4. 弹出 macOS 通知

---

## OpenClaw Webhook 端点详解

启用外部 webhook 后，Gateway 提供以下端点：

### `POST /hooks/wake` — 唤醒主会话

```json
{ "text": "事件描述", "mode": "now" }
```

- `text`（必填）：事件描述文本
- `mode`（可选）：`now`（立即唤醒）或 `next-heartbeat`（下次心跳时处理），默认 `now`

### `POST /hooks/agent` — 触发独立 Agent 处理

```json
{
  "message": "处理 Claude Code 的输出结果",
  "name": "claude-task-complete",
  "agentId": "claude",
  "sessionKey": "hook:claude:task-name",
  "wakeMode": "now",
  "deliver": true,
  "channel": "last"
}
```

| 字段 | 必填 | 说明 |
|------|------|------|
| `message` | 是 | Agent 要处理的 prompt |
| `name` | 否 | Hook 标识名（用于 session 摘要） |
| `agentId` | 否 | 路由到指定 agent；未知 ID 回退到默认 |
| `sessionKey` | 否 | Session 标识（默认禁用，需配置 `allowRequestSessionKey`） |
| `wakeMode` | 否 | `now` 或 `next-heartbeat` |
| `deliver` | 否 | 是否通过消息频道推送结果（默认 `true`） |
| `channel` | 否 | 推送目标：`last`/`telegram`/`slack`/`discord` 等 |
| `model` | 否 | 模型覆盖（需在允许列表中） |
| `thinking` | 否 | 思考级别：`low`/`medium`/`high` |
| `timeoutSeconds` | 否 | 最大执行时间 |

### Session Key 安全策略

`sessionKey` 由请求方指定时**默认禁用**。如需启用：

```json
"hooks": {
  "allowRequestSessionKey": true,
  "allowedSessionKeyPrefixes": ["hook:"]
}
```

---

## notify-hook.sh 回调机制

### HTTP 回调的自动格式适配

`notify-hook.sh` 根据 `--callback-url` 的路径自动选择 payload 格式：

| URL 路径 | Payload 格式 | 用途 |
|----------|-------------|------|
| `*/hooks/wake` | `{"text": "Task X completed: ...", "mode": "now"}` | 唤醒 AGI 主会话 |
| `*/hooks/agent` | `{"message": "...", "name": "...", "agentId": "claude", ...}` | 触发独立 agent 处理 |
| 其他 URL | 完整 `latest.json` 内容 | 通用 HTTP 回调 |

所有请求自动携带 `Authorization: Bearer` header（如果 `OPENCLAW_GATEWAY_TOKEN` 已设置）。

### 两条独立的 Gateway 通知路径

| 路径 | 触发方式 | 说明 |
|------|----------|------|
| `--callback-url` | 显式指定 | 灵活，可指向任意端点 |
| `OPENCLAW_GATEWAY` 环境变量 | 自动触发 | 始终调用 `/hooks/wake` |

两者可以同时使用。如果 `callback-url` 已经指向同一个 Gateway 的 `/hooks/wake`，脚本会自动跳过方式 2 避免重复。

### 任务状态守卫

`notify-hook.sh` 注册为全局 Hook，所有 Claude Code 会话都会触发。通过以下机制避免误触发：

1. 检查 `task-meta.json` 的 `status` 字段，只有 `"running"` 才执行通知链
2. 通知完成后将 status 标记为 `"done"`
3. 没有 `task-meta.json` 或 status 不是 `"running"` 时直接退出

### latest.json 格式

```json
{
  "session_id": "abc-123",
  "timestamp": "2026-03-18T10:30:00Z",
  "cwd": "/Users/me/my-project",
  "event": "Stop",
  "output": "Claude Code 的输出内容...",
  "task_name": "api-refactor",
  "telegram_group": "-1001234567890",
  "callback_session": "session-key",
  "status": "done"
}
```

---

## OpenClaw 内部 Hooks（boot-md 等）

`hooks.internal` 用于 Gateway 内部事件，与外部 webhook 无关，但可以配合使用。

**boot-md** 在 Gateway 启动时自动执行 workspace 中的 `BOOT.md` 指令：

```bash
openclaw hooks enable boot-md
echo "检查是否有待处理的 Claude Code 任务" > ~/.openclaw/workspace/BOOT.md
```

| Hook | 作用 |
|------|------|
| `boot-md` | Gateway 启动时执行 `BOOT.md` 指令 |
| `session-memory` | `/new` 时保存会话上下文到 `~/.openclaw/workspace/memory/` |
| `bootstrap-extra-files` | Agent 启动时注入额外文件 |
| `command-logger` | 记录所有命令到 `~/.openclaw/logs/commands.log` |

管理命令：

```bash
openclaw hooks list       # 列出所有 hooks
openclaw hooks enable X   # 启用
openclaw hooks disable X  # 禁用
openclaw hooks info X     # 查看详情
openclaw hooks check      # 检查状态
```

---

## claude_code_run.py

PTY/tmux 运行器，改编自 [claude-code-hooks-main](https://github.com/anthropics/claude-code-hooks)，适配 macOS。

通常由 `dispatch-claude.sh` 自动调用，也可以独立使用：

```bash
python3 claude_code_run.py -p "你的任务" --cwd /project

# 交互模式
python3 claude_code_run.py -p "/review" --mode interactive

# Agent Teams
python3 claude_code_run.py -p "并行重构" --agent-teams --teammate-mode tmux
```

**macOS 适配：**
- `script(1)` 使用 macOS 语法（无 `-c` 参数）
- 默认 claude 路径指向 nvm 安装
- tmux socket 目录使用 `$TMPDIR`

---

## 数据目录

所有运行时数据存储在：

```
~/Library/Application Support/openclaw-claude/results/
  task-meta.json      # 当前任务元数据
  task-output.txt     # Claude Code 输出
  latest.json         # 最近一次完成的结果
  pending-wake.json   # AGI 唤醒标记
  .hook-lock          # 防重复锁文件
  hook.log            # Hook 执行日志
```

---

## 配置检查清单

- [ ] `~/.openclaw/openclaw.json` 中 `hooks.enabled: true` + `hooks.token` 已设置
- [ ] Gateway 已重启使 webhook 配置生效
- [ ] `~/.claude/settings.json` 中 Stop/SessionEnd Hook 已注册
- [ ] 环境变量 `OPENCLAW_GATEWAY` + `OPENCLAW_GATEWAY_TOKEN` 已设置
- [ ] 验证 webhook 可达：`curl -X POST http://127.0.0.1:18789/hooks/wake -H "Authorization: Bearer <token>" -H "Content-Type: application/json" -d '{"text":"test","mode":"now"}'`

---

## 故障排查

**Gateway 返回 401：**
- 检查 `OPENCLAW_GATEWAY_TOKEN` 是否与 `openclaw.json` 中 `hooks.token` 一致
- 确认使用的是 `Authorization: Bearer` header，不是 query string

**Gateway 返回 404：**
- 确认 `hooks.enabled: true` 已设置并重启了 Gateway
- 检查 `hooks.path` 配置（默认 `/hooks`）

**Hook 没有触发：**
- 检查 `~/.claude/settings.json` 中 Hook 是否注册
- 查看日志：`cat ~/Library/Application\ Support/openclaw-claude/results/hook.log`

**普通 Claude Code 会话也弹通知：**
- 确认 `task-meta.json` 的 status 不是 `"running"`（旧任务未正常标记完成）
- 手动清理：`rm ~/Library/Application\ Support/openclaw-claude/results/task-meta.json`

**iTerm2 模式不工作：**
- 确认 iTerm2 已安装
- 在系统设置中授予 Accessibility 权限

**HTTP 回调状态码 429：**
- Gateway 限流，检查 `Retry-After` header
- 可能是认证多次失败触发了速率限制

---

## 与 iterm-claude-mcp 的区别

| | iterm-claude-mcp | openclaw-to-claude-cli |
|---|---|---|
| **协议** | MCP (stdio) | CLI + HTTP callback |
| **调用方** | 通用 MCP 客户端 | OpenClaw / AGI 平台 |
| **模式** | 同步（阻塞等待） | 异步（dispatch-and-callback） |
| **结果通知** | Server 内部 poll → 直接返回 | Hook → HTTP POST / Gateway / Telegram |
| **Hook 依赖** | 否 | 是 |
| **适用场景** | 从 Agent 发起子任务 | AGI 批量派发、团队协作 |

---

## 参考文档

- [OpenClaw Hooks 文档](https://docs.openclaw.ai/automation/hooks)
- [OpenClaw Webhook 文档](https://docs.openclaw.ai/automation/webhook)
