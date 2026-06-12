#!/usr/bin/env bash
# bastion_connect.sh — Convenience wrapper for connecting to the bastion host
# and attaching to agent tmux sessions or the dashboard port-forward.
#
# Usage:
#   ./bastion_connect.sh attach  <agent_id>
#   ./bastion_connect.sh dashboard
#   ./bastion_connect.sh list
#   ./bastion_connect.sh tunnel  [local_port]
#
# Configuration via environment or ~/.config/spider-autonomy/bastion.env:
#   BASTION_HOST     Hostname or IP of the bastion server  (required)
#   BASTION_USER     SSH username on the bastion            (default: $(whoami))
#   BASTION_KEY      Path to SSH private key               (default: ~/.ssh/id_ed25519)
#   DASHBOARD_PORT   Remote dashboard port                 (default: 8080)
#   LOCAL_PORT       Local port for the SSH tunnel         (default: 8080)

set -euo pipefail

CONFIG_FILE="${HOME}/.config/spider-autonomy/bastion.env"
if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

BASTION_HOST="${BASTION_HOST:?'BASTION_HOST is not set. Export it or add it to ~/.config/spider-autonomy/bastion.env'}"
BASTION_USER="${BASTION_USER:-$(whoami)}"
BASTION_KEY="${BASTION_KEY:-${HOME}/.ssh/id_ed25519}"
DASHBOARD_PORT="${DASHBOARD_PORT:-8080}"
LOCAL_PORT="${LOCAL_PORT:-8080}"

SSH_OPTS=(
    -o StrictHostKeyChecking=accept-new
    -o ServerAliveInterval=30
    -o ServerAliveCountMax=3
    -i "$BASTION_KEY"
)

usage() {
    cat << EOF
Usage: $0 <command> [args]

Commands:
  attach  <agent_id>    Attach to a running agent's tmux session on the bastion
  dashboard             Open the OpCenter dashboard in your default browser
                        (starts an SSH tunnel if needed)
  list                  List active tmux sessions on the bastion
  tunnel  [local_port]  Start an SSH tunnel to the dashboard (stays in foreground)
  ssh                   Open an interactive SSH shell on the bastion

EOF
    exit 1
}

cmd="${1:-}"
[[ -z "$cmd" ]] && usage

case "$cmd" in

# ── attach ────────────────────────────────────────────────────────────────────
attach)
    agent_id="${2:?'agent_id required'}"
    echo "Attaching to agent '${agent_id}' on ${BASTION_HOST}…"
    ssh "${SSH_OPTS[@]}" \
        "${BASTION_USER}@${BASTION_HOST}" \
        -t "tmux attach -t '${agent_id}' || (echo 'Session not found.'; bash -l)"
    ;;

# ── dashboard ─────────────────────────────────────────────────────────────────
dashboard)
    echo "Forwarding localhost:${LOCAL_PORT} → ${BASTION_HOST}:${DASHBOARD_PORT}"
    # Start tunnel in background; open browser; wait for tunnel to die.
    ssh "${SSH_OPTS[@]}" \
        -L "${LOCAL_PORT}:localhost:${DASHBOARD_PORT}" \
        -N \
        "${BASTION_USER}@${BASTION_HOST}" &
    TUNNEL_PID=$!
    sleep 1  # give the tunnel a moment to establish

    URL="http://localhost:${LOCAL_PORT}"
    echo "Dashboard available at: ${URL}"
    # Try to open browser cross-platform.
    if command -v open &>/dev/null; then
        open "$URL"
    elif command -v xdg-open &>/dev/null; then
        xdg-open "$URL"
    fi

    trap 'kill "$TUNNEL_PID" 2>/dev/null || true' EXIT
    echo "Press Ctrl-C to close the tunnel."
    wait "$TUNNEL_PID"
    ;;

# ── list ──────────────────────────────────────────────────────────────────────
list)
    echo "Active sessions on ${BASTION_HOST}:"
    ssh "${SSH_OPTS[@]}" \
        "${BASTION_USER}@${BASTION_HOST}" \
        "tmux list-sessions 2>/dev/null || echo '(none)'"
    ;;

# ── tunnel ────────────────────────────────────────────────────────────────────
tunnel)
    local_port="${2:-$LOCAL_PORT}"
    echo "SSH tunnel: localhost:${local_port} → ${BASTION_HOST}:${DASHBOARD_PORT}"
    echo "Press Ctrl-C to disconnect."
    ssh "${SSH_OPTS[@]}" \
        -L "${local_port}:localhost:${DASHBOARD_PORT}" \
        -N \
        "${BASTION_USER}@${BASTION_HOST}"
    ;;

# ── ssh ───────────────────────────────────────────────────────────────────────
ssh)
    ssh "${SSH_OPTS[@]}" "${BASTION_USER}@${BASTION_HOST}"
    ;;

*)
    usage
    ;;
esac
