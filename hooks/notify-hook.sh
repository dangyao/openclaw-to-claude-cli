#!/bin/bash
# Claude Code Stop/SessionEnd Hook: 任务完成后通知 AGI
# 适配 macOS, 支持 HTTP 回调 + OpenClaw Gateway + macOS 通知
#
# 触发时机: Stop (生成停止) + SessionEnd (会话结束)
# 支持 Agent Teams: lead 完成后自动触发

set -uo pipefail

RESULT_DIR="${HOME}/Library/Application Support/openclaw-claude/results"
META_FILE="${RESULT_DIR}/task-meta.json"
LOG="${RESULT_DIR}/hook.log"
OPENCLAW_BIN="${OPENCLAW_BIN:-openclaw}"

mkdir -p "$RESULT_DIR"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" >> "$LOG"; }

log "=== Hook fired ==="

# ---- 读 stdin ----
INPUT=""
if [ -t 0 ]; then
    log "stdin is tty, skip"
elif [ -e /dev/stdin ]; then
    INPUT=$(timeout 2 cat /dev/stdin 2>/dev/null || true)
fi

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null || echo "unknown")
CWD=$(echo "$INPUT" | jq -r '.cwd // ""' 2>/dev/null || echo "")
EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // "unknown"' 2>/dev/null || echo "unknown")

log "session=$SESSION_ID cwd=$CWD event=$EVENT"

# ---- 防重复：只处理第一个事件（Stop），跳过后续的 SessionEnd ----
LOCK_FILE="${RESULT_DIR}/.hook-lock"
LOCK_AGE_LIMIT=30

if [ -f "$LOCK_FILE" ]; then
    # macOS stat syntax
    LOCK_TIME=$(stat -f %m "$LOCK_FILE" 2>/dev/null || echo 0)
    NOW=$(date +%s)
    AGE=$(( NOW - LOCK_TIME ))
    if [ "$AGE" -lt "$LOCK_AGE_LIMIT" ]; then
        log "Duplicate hook within ${AGE}s, skipping"
        exit 0
    fi
fi
touch "$LOCK_FILE"

# ---- 读取 Claude Code 输出 ----
OUTPUT=""

# 等待 tee 管道 flush
sleep 1

# 来源1: task-output.txt (dispatch 脚本 tee 写入)
TASK_OUTPUT="${RESULT_DIR}/task-output.txt"
if [ -f "$TASK_OUTPUT" ] && [ -s "$TASK_OUTPUT" ]; then
    OUTPUT=$(tail -c 4000 "$TASK_OUTPUT")
    log "Output from task-output.txt (${#OUTPUT} chars)"
fi

# 来源2: /tmp fallback
if [ -z "$OUTPUT" ] && [ -f "/tmp/claude-code-output.txt" ] && [ -s "/tmp/claude-code-output.txt" ]; then
    OUTPUT=$(tail -c 4000 /tmp/claude-code-output.txt)
    log "Output from /tmp fallback (${#OUTPUT} chars)"
fi

# 来源3: 工作目录列表
if [ -z "$OUTPUT" ] && [ -n "$CWD" ] && [ -d "$CWD" ]; then
    FILES=$(ls -1t "$CWD" 2>/dev/null | head -20 | tr '\n' ', ')
    OUTPUT="Working dir: ${CWD}\nFiles: ${FILES}"
    log "Output from dir listing"
fi

# ---- 读取任务元数据 ----
TASK_NAME="unknown"
TELEGRAM_GROUP=""
CALLBACK_URL=""
CALLBACK_SESSION=""
HAS_ACTIVE_TASK=false

if [ -f "$META_FILE" ]; then
    META_STATUS=$(jq -r '.status // "unknown"' "$META_FILE" 2>/dev/null || echo "unknown")
    if [ "$META_STATUS" = "running" ]; then
        HAS_ACTIVE_TASK=true
        TASK_NAME=$(jq -r '.task_name // "unknown"' "$META_FILE" 2>/dev/null || echo "unknown")
        TELEGRAM_GROUP=$(jq -r '.telegram_group // ""' "$META_FILE" 2>/dev/null || echo "")
        CALLBACK_URL=$(jq -r '.callback_url // ""' "$META_FILE" 2>/dev/null || echo "")
        CALLBACK_SESSION=$(jq -r '.callback_session // ""' "$META_FILE" 2>/dev/null || echo "")
        log "Meta: task=$TASK_NAME group=$TELEGRAM_GROUP callback=$CALLBACK_URL"
    else
        log "No active task (status=$META_STATUS), skipping notifications"
    fi
else
    log "No task-meta.json found, skipping notifications"
fi

# ---- 如果没有活跃的 openclaw 任务，直接退出 ----
if [ "$HAS_ACTIVE_TASK" = false ]; then
    log "=== Hook completed (no active task, no notifications sent) ==="
    exit 0
fi

# ---- 写入结果 JSON ----
RESULT_JSON="${RESULT_DIR}/latest.json"
jq -n \
    --arg sid "$SESSION_ID" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg cwd "$CWD" \
    --arg event "$EVENT" \
    --arg output "$OUTPUT" \
    --arg task "$TASK_NAME" \
    --arg group "$TELEGRAM_GROUP" \
    --arg session "$CALLBACK_SESSION" \
    '{session_id: $sid, timestamp: $ts, cwd: $cwd, event: $event, output: $output, task_name: $task, telegram_group: $group, callback_session: $session, status: "done"}' \
    > "$RESULT_JSON" 2>/dev/null

log "Wrote latest.json"

# ---- 方式1: HTTP 回调（自动适配 OpenClaw webhook 端点格式）----
if [ -n "$CALLBACK_URL" ]; then
    # 构建认证 header（如果有 token）
    AUTH_HEADER=""
    if [ -n "${OPENCLAW_GATEWAY_TOKEN:-}" ]; then
        AUTH_HEADER="-H \"Authorization: Bearer ${OPENCLAW_GATEWAY_TOKEN}\""
    fi

    # 根据 URL 路径自动选择 payload 格式
    SUMMARY=$(echo "$OUTPUT" | tail -c 2000 | tr '\n' ' ')
    case "$CALLBACK_URL" in
        */hooks/wake)
            # OpenClaw /hooks/wake 端点：{text, mode}
            PAYLOAD=$(jq -n \
                --arg text "Task ${TASK_NAME} completed: ${SUMMARY:0:500}" \
                --arg mode "now" \
                '{text: $text, mode: $mode}')
            log "Using /hooks/wake payload format"
            ;;
        */hooks/agent)
            # OpenClaw /hooks/agent 端点：{message, name, wakeMode, deliver, channel}
            PAYLOAD=$(jq -n \
                --arg message "Claude Code 任务 ${TASK_NAME} 已完成。\n结果摘要:\n${SUMMARY:0:1500}" \
                --arg name "claude-task-${TASK_NAME}" \
                --arg agentId "claude" \
                --arg sessionKey "hook:claude:${TASK_NAME}" \
                '{message: $message, name: $name, agentId: $agentId, sessionKey: $sessionKey, wakeMode: "now", deliver: true, channel: "last"}')
            log "Using /hooks/agent payload format"
            ;;
        *)
            # 其他 URL：发送完整 latest.json
            PAYLOAD=$(cat "$RESULT_JSON")
            log "Using raw latest.json payload format"
            ;;
    esac

    HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST "$CALLBACK_URL" \
        -H "Content-Type: application/json" \
        ${AUTH_HEADER:+-H "Authorization: Bearer ${OPENCLAW_GATEWAY_TOKEN}"} \
        -d "$PAYLOAD" \
        --connect-timeout 5 --max-time 10 2>/dev/null || echo "000")
    log "HTTP callback to $CALLBACK_URL => status $HTTP_STATUS"
fi

# ---- 方式2: OpenClaw Gateway 唤醒（通过环境变量自动触发，独立于 callback-url）----
OPENCLAW_GATEWAY="${OPENCLAW_GATEWAY:-}"
OPENCLAW_GATEWAY_TOKEN="${OPENCLAW_GATEWAY_TOKEN:-}"

if [ -n "$OPENCLAW_GATEWAY" ] && [ -n "$OPENCLAW_GATEWAY_TOKEN" ]; then
    # 如果 callback-url 已经指向了同一个 gateway 的 /hooks/wake，跳过避免重复
    if [[ "$CALLBACK_URL" == "${OPENCLAW_GATEWAY}/hooks/wake" ]]; then
        log "Skipping gateway wake (already handled by callback-url)"
    else
        curl -s -X POST "${OPENCLAW_GATEWAY}/hooks/wake" \
            -H "Authorization: Bearer ${OPENCLAW_GATEWAY_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "{\"text\": \"Task ${TASK_NAME} completed\", \"mode\": \"now\"}" \
            --connect-timeout 5 --max-time 10 >/dev/null 2>&1 \
            && log "Woke AGI gateway via /hooks/wake" || log "Gateway wake failed"
    fi
fi

# ---- 方式3: Telegram 消息 ----
if [ -n "$TELEGRAM_GROUP" ] && command -v "$OPENCLAW_BIN" &>/dev/null; then
    SUMMARY=$(echo "$OUTPUT" | tail -c 1000 | tr '\n' ' ')
    MSG="Claude Code 任务完成
任务: ${TASK_NAME}
结果摘要:
${SUMMARY:0:800}"

    "$OPENCLAW_BIN" message send \
        --channel telegram \
        --target "$TELEGRAM_GROUP" \
        --message "$MSG" 2>/dev/null \
        && log "Sent Telegram message to $TELEGRAM_GROUP" \
        || log "Telegram send failed"
fi

# ---- 方式4: macOS 原生通知 ----
osascript -e "display notification \"任务 ${TASK_NAME} 已完成\" with title \"Claude Code\" sound name \"Glass\"" 2>/dev/null || true
log "macOS notification sent"

# ---- 写入 pending-wake.json（备用）----
WAKE_FILE="${RESULT_DIR}/pending-wake.json"
jq -n \
    --arg task "$TASK_NAME" \
    --arg group "$TELEGRAM_GROUP" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg summary "$(echo "$OUTPUT" | head -c 500 | tr '\n' ' ')" \
    '{task_name: $task, telegram_group: $group, timestamp: $ts, summary: $summary, processed: false}' \
    > "$WAKE_FILE" 2>/dev/null

log "Wrote pending-wake.json"

# ---- 标记任务为已完成，防止后续会话重复触发通知 ----
if [ -f "$META_FILE" ]; then
    jq --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '. + {status: "done", completed_at: $ts}' \
        "$META_FILE" > "${META_FILE}.tmp" && mv "${META_FILE}.tmp" "$META_FILE"
    log "Marked task-meta.json as done"
fi

log "=== Hook completed ==="
exit 0
