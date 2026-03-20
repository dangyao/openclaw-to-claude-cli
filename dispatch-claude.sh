#!/bin/bash
# dispatch-claude.sh — Dispatch a task to Claude Code with async callback
#
# Usage:
#   dispatch-claude.sh [OPTIONS] -p "your prompt here"
#
# Designed for OpenClaw / AGI platforms with dispatch-and-callback pattern.
# The script launches Claude Code and returns immediately.
# When Claude Code finishes, the Stop Hook fires and sends callbacks.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESULT_DIR="${HOME}/Library/Application Support/openclaw-claude/results"
META_FILE="${RESULT_DIR}/task-meta.json"
TASK_OUTPUT="${RESULT_DIR}/task-output.txt"
RUNNER="${SCRIPT_DIR}/claude_code_run.py"
CLAUDE_CODE_BIN="${CLAUDE_CODE_BIN:-/Users/dangyao/.nvm/versions/node/v22.22.0/bin/claude}"

# Defaults
PROMPT=""
TASK_NAME="adhoc-$(date +%s)"
TELEGRAM_GROUP=""
CALLBACK_SESSION=""
CALLBACK_URL=""
WORKDIR="$(pwd)"
AGENT_TEAMS=""
TEAMMATE_MODE=""
PERMISSION_MODE=""
ALLOWED_TOOLS=""
MODEL=""
MODE="headless"
USE_ITERM=""

# Parse args
while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--prompt) PROMPT="$2"; shift 2;;
        -n|--name) TASK_NAME="$2"; shift 2;;
        -g|--group) TELEGRAM_GROUP="$2"; shift 2;;
        -s|--session) CALLBACK_SESSION="$2"; shift 2;;
        -w|--workdir) WORKDIR="$2"; shift 2;;
        --callback-url) CALLBACK_URL="$2"; shift 2;;
        --agent-teams) AGENT_TEAMS="1"; shift;;
        --teammate-mode) TEAMMATE_MODE="$2"; shift 2;;
        --permission-mode) PERMISSION_MODE="$2"; shift 2;;
        --allowed-tools) ALLOWED_TOOLS="$2"; shift 2;;
        --model) MODEL="$2"; shift 2;;
        --mode) MODE="$2"; shift 2;;
        --use-iterm) USE_ITERM="1"; shift;;
        *) echo "Unknown option: $1" >&2; exit 1;;
    esac
done

if [ -z "$PROMPT" ]; then
    echo "Error: --prompt is required" >&2
    exit 1
fi

# ---- 1. Write task metadata ----
mkdir -p "$RESULT_DIR"

jq -n \
    --arg name "$TASK_NAME" \
    --arg group "$TELEGRAM_GROUP" \
    --arg session "$CALLBACK_SESSION" \
    --arg callback_url "$CALLBACK_URL" \
    --arg prompt "$PROMPT" \
    --arg workdir "$WORKDIR" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg agent_teams "${AGENT_TEAMS:-0}" \
    '{task_name: $name, telegram_group: $group, callback_session: $session, callback_url: $callback_url, prompt: $prompt, workdir: $workdir, started_at: $ts, agent_teams: ($agent_teams == "1"), status: "running"}' \
    > "$META_FILE"

echo "Task metadata written: $META_FILE"
echo "  Task: $TASK_NAME"
echo "  Callback URL: ${CALLBACK_URL:-none}"
echo "  Group: ${TELEGRAM_GROUP:-none}"
echo "  Agent Teams: ${AGENT_TEAMS:-no}"

# ---- 2. Clear previous output ----
> "$TASK_OUTPUT"

# ---- 3. Launch Claude Code ----
if [ -n "$USE_ITERM" ]; then
    # --- iTerm2 mode: AppleScript launch, returns immediately ---
    ENV_PREFIX=""
    if [ -n "$AGENT_TEAMS" ]; then
        ENV_PREFIX="export CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 && "
    fi

    MODEL_FLAG=""
    if [ -n "$MODEL" ]; then
        MODEL_FLAG=" --model $MODEL"
    fi

    PERM_FLAG=""
    if [ -n "$PERMISSION_MODE" ]; then
        PERM_FLAG=" --permission-mode $PERMISSION_MODE"
    fi

    # Escape single quotes in prompt
    ESCAPED_PROMPT="${PROMPT//\'/\'\\\'\'}"

    SHELL_CMD="${ENV_PREFIX}cd '${WORKDIR}' && ${CLAUDE_CODE_BIN} -p '${ESCAPED_PROMPT}'${MODEL_FLAG}${PERM_FLAG} 2>&1 | tee '${TASK_OUTPUT}'"

    osascript -e "
tell application \"iTerm2\"
    activate
    if (count of windows) = 0 then
        create window with default profile
    end if
    tell current window
        set newTab to (create tab with default profile)
        set name of newTab to \"${TASK_NAME}\"
        tell current session of newTab
            write text \"$(echo "$SHELL_CMD" | sed 's/\\/\\\\/g; s/"/\\"/g')\"
        end tell
    end tell
end tell"

    echo "Launched in iTerm2 (async). Hook will fire on completion."
else
    # --- Headless/tmux mode via claude_code_run.py ---
    CMD=(python3 "$RUNNER" -p "$PROMPT" --cwd "$WORKDIR" --claude-bin "$CLAUDE_CODE_BIN")

    if [ -n "$AGENT_TEAMS" ]; then
        CMD+=(--agent-teams)
    fi
    if [ -n "$TEAMMATE_MODE" ]; then
        CMD+=(--teammate-mode "$TEAMMATE_MODE")
    fi
    if [ -n "$PERMISSION_MODE" ]; then
        CMD+=(--permission-mode "$PERMISSION_MODE")
    fi
    if [ -n "$ALLOWED_TOOLS" ]; then
        CMD+=(--allowedTools "$ALLOWED_TOOLS")
    fi
    if [ "$MODE" = "interactive" ]; then
        CMD+=(--mode interactive)
    fi

    if [ -n "$MODEL" ]; then
        export ANTHROPIC_MODEL="$MODEL"
    fi

    echo "Launching Claude Code (headless)..."

    # Run in background, tee output, then update meta on completion
    (
        "${CMD[@]}" 2>&1 | tee "$TASK_OUTPUT"
        EXIT_CODE=${PIPESTATUS[0]}
        # Update meta with completion
        if [ -f "$META_FILE" ]; then
            jq --arg code "${EXIT_CODE:-0}" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                '. + {exit_code: ($code | tonumber), completed_at: $ts, status: "done"}' \
                "$META_FILE" > "${META_FILE}.tmp" && mv "${META_FILE}.tmp" "$META_FILE"
        fi
    ) &

    echo "Launched in background (PID: $!). Hook will fire on completion."
fi

echo "Results will be at: ${RESULT_DIR}/latest.json"
