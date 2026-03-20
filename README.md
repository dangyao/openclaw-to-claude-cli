# openclaw-to-claude-cli

CLI + Hook: Dispatch Claude Code tasks from OpenClaw/AGI platforms with async callbacks.

[中文文档](./README_CN.md)

---

## Purpose

For **AGI platforms with their own Gateway/HTTP endpoints** (e.g., OpenClaw). Uses a dispatch-and-callback pattern: dispatch a task and return immediately; when Claude Code finishes, the Stop Hook automatically fires callbacks to notify the AGI. Zero polling, zero token waste.

---

## Architecture

```
OpenClaw / AGI Platform
  │
  └─ dispatch-claude.sh -p "task" -w /project --callback-url http://...
       │
       ├─ 1. Write task-meta.json (task name, callback URL, target group)
       ├─ 2. Launch Claude Code (iTerm2 or tmux headless)
       ├─ 3. Return immediately (non-blocking)
       │
       └─ [Async] Claude Code completes → Stop Hook fires
             notify-hook.sh:
             ├─ Deduplication lock (30s window)
             ├─ Check task-meta.json status == "running"
             ├─ Capture output → write latest.json
             ├─ HTTP callback (auto-adapts to /hooks/wake or /hooks/agent format)
             ├─ OpenClaw Gateway wake
             ├─ Telegram/Slack group notification
             ├─ macOS native notification
             ├─ Write pending-wake.json (fallback)
             └─ Mark task-meta.json status: "done"
```

---

## Prerequisites

- macOS (iTerm2 mode) or Linux (tmux mode)
- Python >= 3.10
- `jq` CLI tool
- Claude Code CLI installed

---

## File Structure

```
openclaw-to-claude-cli/
  dispatch-claude.sh        # Task dispatch entry point
  claude_code_run.py        # PTY/tmux runner
  hooks/
    notify-hook.sh          # Stop/SessionEnd callback hook
    claude-settings.json    # Hook registration example
  pyproject.toml
```

---

## Installation & Configuration

### 1. OpenClaw Gateway: Enable Webhook Endpoints

OpenClaw has two independent hook systems:

| System | Config Location | Purpose |
|--------|----------------|---------|
| **Internal Hooks** (`hooks.internal`) | `openclaw.json` → `hooks.internal` | Gateway internal events (boot-md, session-memory, etc.) |
| **External Webhooks** (`hooks.enabled`) | `openclaw.json` → `hooks.enabled` + `hooks.token` | HTTP endpoints for external systems (`/hooks/wake`, `/hooks/agent`) |

These are independent and must be configured separately. `notify-hook.sh` uses **external Webhooks** to call back to the Gateway.

Add to `~/.openclaw/openclaw.json` under the `hooks` node:

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

| Field | Required | Description |
|-------|----------|-------------|
| `enabled` | Yes | Enable external webhook HTTP endpoints |
| `token` | Yes | Webhook auth token, required on all requests |
| `path` | No | Endpoint prefix, defaults to `/hooks` |
| `allowedAgentIds` | No | Agent IDs allowed to be triggered by webhooks |

Authentication methods (per [official docs](https://docs.openclaw.ai/automation/webhook)):
- `Authorization: Bearer <token>` (recommended)
- `x-openclaw-token: <token>` (alternative)
- Query string `?token=...` is **not supported** (returns HTTP 400)

### 2. Claude Code: Register Hooks

Add to `~/.claude/settings.json`:

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

### 3. Environment Variables

```bash
# OpenClaw Gateway address
export OPENCLAW_GATEWAY="http://127.0.0.1:18789"

# Webhook auth token (matches hooks.token in openclaw.json)
export OPENCLAW_GATEWAY_TOKEN="your-webhook-secret"

# Claude Code binary path
export CLAUDE_CODE_BIN="/Users/xxxx/.nvm/versions/node/v22.22.0/bin/claude"

# openclaw CLI path (if not in PATH)
export OPENCLAW_BIN="openclaw"
```

**Note**: `OPENCLAW_GATEWAY_TOKEN` corresponds to `hooks.token`, not `gateway.auth.token`. If both are set to the same value, no distinction is needed.

---

## Usage

### dispatch-claude.sh

Task dispatch script. Launches Claude Code and returns immediately.

```bash
./dispatch-claude.sh [OPTIONS] -p "your prompt here"
```

**Parameters:**

| Parameter | Description |
|---|---|
| `-p, --prompt` | **Required** Task prompt |
| `-n, --name` | Task name (for tracking) |
| `-w, --workdir` | Working directory |
| `-g, --group` | Telegram/Slack group ID |
| `-s, --session` | AGI callback session key |
| `--callback-url` | HTTP callback URL on completion |
| `--mode` | `headless` (default) or `interactive` |
| `--use-iterm` | Use iTerm2 (macOS only) |
| `--model` | Model override |
| `--permission-mode` | Claude Code permission mode |
| `--allowed-tools` | Allowed tools list |
| `--agent-teams` | Enable Agent Teams |
| `--teammate-mode` | Agent Teams mode (auto/in-process/tmux) |

---

## Examples

### Callback to /hooks/wake (simple wake)

```bash
./dispatch-claude.sh \
  -p "Analyze code structure" \
  -w /Users/me/my-project \
  --callback-url "http://127.0.0.1:18789/hooks/wake"
```

Gateway receives `{"text": "Task adhoc-xxx completed: ...", "mode": "now"}` and wakes the main session.

### Callback to /hooks/agent (trigger Agent processing)

```bash
./dispatch-claude.sh \
  -p "Run code review and generate report" \
  -n "code-review" \
  -w /Users/me/my-project \
  --callback-url "http://127.0.0.1:18789/hooks/agent"
```

Gateway launches an independent agent to process Claude Code's output and pushes results to messaging channels.

### iTerm2 mode

```bash
./dispatch-claude.sh \
  -p "Fix all lint errors" \
  -w /Users/me/my-project \
  --use-iterm \
  --callback-url http://127.0.0.1:18789/hooks/wake
```

Opens a new iTerm2 tab so you can watch Claude Code's output in real time.

### Environment variables only (no callback-url)

```bash
export OPENCLAW_GATEWAY="http://127.0.0.1:18789"
export OPENCLAW_GATEWAY_TOKEN="your-webhook-secret"

./dispatch-claude.sh \
  -p "Fix lint errors" \
  -w /Users/me/my-project
```

Without `--callback-url`, the hook still calls `/hooks/wake` automatically via environment variables.

### Agent Teams mode

```bash
./dispatch-claude.sh \
  -p "In parallel: 1) Write unit tests 2) Update docs 3) Fix lint" \
  -w /Users/me/my-project \
  --agent-teams \
  --teammate-mode tmux \
  --callback-url http://127.0.0.1:18789/hooks/agent
```

Enables Agent Teams; Claude Code automatically splits into multiple sub-agents working in parallel.

### External system callback + Gateway wake

```bash
export OPENCLAW_GATEWAY="http://127.0.0.1:18789"
export OPENCLAW_GATEWAY_TOKEN="your-webhook-secret"

./dispatch-claude.sh \
  -p "Refactor API" \
  -w /Users/me/my-project \
  --callback-url "http://my-ci-server.com/api/task-done" \
  -g "-1001812192154"
```

On completion, simultaneously:
1. POST to CI server (sends full latest.json)
2. Wake OpenClaw Gateway (via environment variables)
3. Send Telegram group message
4. Show macOS notification

---

## OpenClaw Webhook Endpoint Details

After enabling external webhooks, the Gateway provides:

### `POST /hooks/wake` — Wake main session

```json
{ "text": "Event description", "mode": "now" }
```

- `text` (required): Event description text
- `mode` (optional): `now` (immediate) or `next-heartbeat` (deferred), defaults to `now`

### `POST /hooks/agent` — Trigger independent Agent

```json
{
  "message": "Process Claude Code output",
  "name": "claude-task-complete",
  "agentId": "claude",
  "sessionKey": "hook:claude:task-name",
  "wakeMode": "now",
  "deliver": true,
  "channel": "last"
}
```

| Field | Required | Description |
|-------|----------|-------------|
| `message` | Yes | Prompt for the agent |
| `name` | No | Hook identifier for session summaries |
| `agentId` | No | Route to specific agent; unknown IDs fall back to default |
| `sessionKey` | No | Session identifier (disabled by default, requires `allowRequestSessionKey`) |
| `wakeMode` | No | `now` or `next-heartbeat` |
| `deliver` | No | Push results via messaging channel (default: `true`) |
| `channel` | No | Target: `last`/`telegram`/`slack`/`discord`, etc. |
| `model` | No | Model override (must be in allowed list) |
| `thinking` | No | Thinking level: `low`/`medium`/`high` |
| `timeoutSeconds` | No | Maximum execution time |

### Session Key Security

Request-specified `sessionKey` is **disabled by default**. To enable:

```json
"hooks": {
  "allowRequestSessionKey": true,
  "allowedSessionKeyPrefixes": ["hook:"]
}
```

---

## notify-hook.sh Callback Mechanism

### Auto-format adaptation for HTTP callbacks

`notify-hook.sh` automatically selects the payload format based on the `--callback-url` path:

| URL Path | Payload Format | Purpose |
|----------|---------------|---------|
| `*/hooks/wake` | `{"text": "Task X completed: ...", "mode": "now"}` | Wake AGI main session |
| `*/hooks/agent` | `{"message": "...", "name": "...", "agentId": "claude", ...}` | Trigger independent agent |
| Other URLs | Full `latest.json` content | Generic HTTP callback |

All requests automatically include `Authorization: Bearer` header (if `OPENCLAW_GATEWAY_TOKEN` is set).

### Two independent Gateway notification paths

| Path | Trigger | Description |
|------|---------|-------------|
| `--callback-url` | Explicit | Flexible, can point to any endpoint |
| `OPENCLAW_GATEWAY` env var | Automatic | Always calls `/hooks/wake` |

Both can be used simultaneously. If `callback-url` already points to the same Gateway's `/hooks/wake`, the script automatically skips path 2 to avoid duplicates.

### Task status guard

`notify-hook.sh` is registered as a global hook, triggered by all Claude Code sessions. Accidental triggers are prevented by:

1. Checking `task-meta.json` `status` field — only `"running"` triggers the notification chain
2. Marking status as `"done"` after notifications complete
3. Exiting immediately if no `task-meta.json` or status is not `"running"`

### latest.json format

```json
{
  "session_id": "abc-123",
  "timestamp": "2026-03-18T10:30:00Z",
  "cwd": "/Users/me/my-project",
  "event": "Stop",
  "output": "Claude Code output content...",
  "task_name": "api-refactor",
  "telegram_group": "-1001234567890",
  "callback_session": "session-key",
  "status": "done"
}
```

---

## OpenClaw Internal Hooks (boot-md, etc.)

`hooks.internal` handles Gateway internal events, independent of external webhooks but can be used in combination.

**boot-md** executes `BOOT.md` instructions from the workspace on Gateway startup:

```bash
openclaw hooks enable boot-md
echo "Check for pending Claude Code tasks" > ~/.openclaw/workspace/BOOT.md
```

| Hook | Purpose |
|------|---------|
| `boot-md` | Execute `BOOT.md` on Gateway startup |
| `session-memory` | Save session context on `/new` to `~/.openclaw/workspace/memory/` |
| `bootstrap-extra-files` | Inject additional files during agent bootstrap |
| `command-logger` | Log all commands to `~/.openclaw/logs/commands.log` |

Management commands:

```bash
openclaw hooks list       # List all hooks
openclaw hooks enable X   # Enable
openclaw hooks disable X  # Disable
openclaw hooks info X     # Show details
openclaw hooks check      # Check status
```

---

## claude_code_run.py

PTY/tmux runner adapted from [claude-code-hooks-main](https://github.com/anthropics/claude-code-hooks) for macOS.

Usually called by `dispatch-claude.sh` automatically. Can also be used standalone:

```bash
python3 claude_code_run.py -p "your prompt" --cwd /project

# Interactive mode
python3 claude_code_run.py -p "/review" --mode interactive

# Agent Teams
python3 claude_code_run.py -p "parallel refactor" --agent-teams --teammate-mode tmux
```

**macOS adaptations:**
- `script(1)` uses macOS syntax (no `-c` flag)
- Default claude path points to nvm installation
- tmux socket directory uses `$TMPDIR`

---

## Data Directory

All runtime data is stored in:

```
~/Library/Application Support/openclaw-claude/results/
  task-meta.json      # Current task metadata
  task-output.txt     # Claude Code output
  latest.json         # Latest completed result
  pending-wake.json   # AGI wake marker
  .hook-lock          # Deduplication lock file
  hook.log            # Hook execution log
```

---

## Configuration Checklist

- [ ] `~/.openclaw/openclaw.json`: `hooks.enabled: true` + `hooks.token` set
- [ ] Gateway restarted for webhook config to take effect
- [ ] `~/.claude/settings.json`: Stop/SessionEnd hooks registered
- [ ] Environment variables `OPENCLAW_GATEWAY` + `OPENCLAW_GATEWAY_TOKEN` set
- [ ] Verify webhook reachable: `curl -X POST http://127.0.0.1:18789/hooks/wake -H "Authorization: Bearer <token>" -H "Content-Type: application/json" -d '{"text":"test","mode":"now"}'`

---

## Troubleshooting

**Gateway returns 401:**
- Check `OPENCLAW_GATEWAY_TOKEN` matches `hooks.token` in `openclaw.json`
- Confirm using `Authorization: Bearer` header, not query string

**Gateway returns 404:**
- Confirm `hooks.enabled: true` is set and Gateway was restarted
- Check `hooks.path` config (defaults to `/hooks`)

**Hook not firing:**
- Verify hook registration in `~/.claude/settings.json`
- Check log: `cat ~/Library/Application\ Support/openclaw-claude/results/hook.log`

**Normal Claude Code sessions trigger notifications:**
- Ensure `task-meta.json` status is not stuck at `"running"` (incomplete old task)
- Manual cleanup: `rm ~/Library/Application\ Support/openclaw-claude/results/task-meta.json`

**iTerm2 mode not working:**
- Ensure iTerm2 is installed
- Grant Accessibility permissions in System Settings

**HTTP callback returns 429:**
- Gateway rate limiting; check `Retry-After` header
- Possibly triggered by repeated auth failures

---

## Comparison with iterm-claude-mcp

| | iterm-claude-mcp | openclaw-to-claude-cli |
|---|---|---|
| **Protocol** | MCP (stdio) | CLI + HTTP callback |
| **Caller** | Generic MCP clients | OpenClaw / AGI platforms |
| **Mode** | Sync (blocking) | Async (dispatch-and-callback) |
| **Notification** | Internal poll → direct return | Hook → HTTP POST / Gateway / Telegram |
| **Hook required** | No | Yes |
| **Use case** | Sub-tasks from agents | Batch dispatch, team collaboration |

---

## References

- [OpenClaw Hooks Documentation](https://docs.openclaw.ai/automation/hooks)
- [OpenClaw Webhook Documentation](https://docs.openclaw.ai/automation/webhook)
