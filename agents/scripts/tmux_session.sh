#!/usr/bin/env bash
# tmux_session.sh — Helper for managing persistent agent tmux sessions.
#
# Usage:
#   ./tmux_session.sh start  <agent_id> [command]
#   ./tmux_session.sh stop   <agent_id>
#   ./tmux_session.sh attach <agent_id>
#   ./tmux_session.sh list
#   ./tmux_session.sh status <agent_id>
#
# Each agent runs in its own tmux session named after its AGENT_ID.
# Sessions survive SSH disconnects.  Re-attach from anywhere with
# `tmux attach -t <agent_id>` or via this script.

set -euo pipefail

SESSION_WIDTH="${SESSION_WIDTH:-250}"
SESSION_HEIGHT="${SESSION_HEIGHT:-50}"
AGENTS_BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    echo "Usage: $0 <start|stop|attach|list|status> [agent_id] [command]"
    exit 1
}

cmd="${1:-}"
[[ -z "$cmd" ]] && usage

case "$cmd" in
# ── start ─────────────────────────────────────────────────────────────────────
start)
    agent_id="${2:?'agent_id required for start'}"
    shift 2
    run_command="${*:-${AGENTS_BIN}/run_agent.sh}"

    if tmux has-session -t "$agent_id" 2>/dev/null; then
        echo "Session '${agent_id}' already exists.  Use 'attach' to connect."
        exit 0
    fi

    echo "Starting tmux session '${agent_id}'..."
    tmux new-session -d -s "$agent_id" \
        -x "$SESSION_WIDTH" -y "$SESSION_HEIGHT"

    # Export AGENT_ID into the session environment.
    tmux setenv -t "$agent_id" AGENT_ID "$agent_id"

    # Send the command.
    tmux send-keys -t "$agent_id" \
        "export AGENT_ID='${agent_id}'; ${run_command}" Enter

    echo "Session '${agent_id}' started.  Attach with: tmux attach -t ${agent_id}"
    ;;

# ── stop ──────────────────────────────────────────────────────────────────────
stop)
    agent_id="${2:?'agent_id required for stop'}"
    if tmux has-session -t "$agent_id" 2>/dev/null; then
        tmux kill-session -t "$agent_id"
        echo "Session '${agent_id}' stopped."
    else
        echo "No session named '${agent_id}'."
    fi
    ;;

# ── attach ────────────────────────────────────────────────────────────────────
attach)
    agent_id="${2:?'agent_id required for attach'}"
    if ! tmux has-session -t "$agent_id" 2>/dev/null; then
        echo "No session named '${agent_id}'.  Start it first with: $0 start ${agent_id}"
        exit 1
    fi
    tmux attach -t "$agent_id"
    ;;

# ── list ──────────────────────────────────────────────────────────────────────
list)
    echo "Active agent tmux sessions:"
    tmux list-sessions 2>/dev/null || echo "(none)"
    ;;

# ── status ────────────────────────────────────────────────────────────────────
status)
    agent_id="${2:?'agent_id required for status'}"
    if tmux has-session -t "$agent_id" 2>/dev/null; then
        echo "Session '${agent_id}': RUNNING"
        tmux list-panes -t "$agent_id" -F \
            "  pane #{pane_index}: #{pane_current_command} (#{pane_width}x#{pane_height})"
    else
        echo "Session '${agent_id}': NOT RUNNING"
    fi
    ;;

*)
    usage
    ;;
esac
