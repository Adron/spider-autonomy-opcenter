#!/usr/bin/env bash
# run_agent.sh — Generic agent entry point.
#
# This script is the ExecStart target for the systemd agent@ template unit.
# It sources the prompt handler, sets up logging, and delegates to the
# agent-specific implementation script found at:
#
#   ${AGENT_WORKDIR}/agent_impl.sh
#
# Environment (set by systemd unit or calling process):
#   AGENT_ID              Unique name for this agent instance (required)
#   AGENT_WORKDIR         Working directory (default: ~/workspace)
#   AGENT_DEFAULTS_FILE   Path to YAML defaults file
#   DASHBOARD_API_URL     Control-plane API base URL
#   LOG_DIR               Directory for log files (default: ~/logs)

set -euo pipefail

AGENT_ID="${AGENT_ID:?AGENT_ID must be set}"
AGENT_WORKDIR="${AGENT_WORKDIR:-${HOME}/workspace}"
LOG_DIR="${LOG_DIR:-${HOME}/logs}"
AGENT_DEFAULTS_FILE="${AGENT_DEFAULTS_FILE:-${HOME}/agent_defaults.yaml}"
DASHBOARD_API_URL="${DASHBOARD_API_URL:-}"

export AGENT_ID AGENT_DEFAULTS_FILE DASHBOARD_API_URL

# ── Logging setup ─────────────────────────────────────────────────────────────
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/${AGENT_ID}.log"
# Tee stdout+stderr to the log file while keeping them on the terminal too.
exec > >(tee -a "$LOG_FILE") 2>&1

log() { echo "[${AGENT_ID}] $(date -u +%Y-%m-%dT%H:%M:%SZ) $*"; }

log "Starting agent (workdir=${AGENT_WORKDIR})"

# ── Sanity checks ─────────────────────────────────────────────────────────────
if [[ ! -d "$AGENT_WORKDIR" ]]; then
    log "ERROR: workdir '${AGENT_WORKDIR}' does not exist"
    exit 1
fi

IMPL_SCRIPT="${AGENT_WORKDIR}/agent_impl.sh"
if [[ ! -f "$IMPL_SCRIPT" ]]; then
    log "ERROR: implementation script '${IMPL_SCRIPT}' not found"
    exit 1
fi

# ── Source prompt handler ─────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./prompt_handler.sh
source "${SCRIPT_DIR}/prompt_handler.sh"

# ── Heartbeat ─────────────────────────────────────────────────────────────────
# Periodically POST a heartbeat to the dashboard so it can detect stalled
# agents.  Run as a background process that dies when the main script exits.
_heartbeat() {
    while true; do
        sleep 30
        if [[ -n "$DASHBOARD_API_URL" ]]; then
            curl -s -X POST \
                -H "Content-Type: application/json" \
                -d "{\"agent_id\":\"${AGENT_ID}\",\"status\":\"running\"}" \
                "${DASHBOARD_API_URL}/agents/${AGENT_ID}/heartbeat" \
                >/dev/null 2>&1 || true
        fi
    done
}

_heartbeat &
HEARTBEAT_PID=$!
trap 'kill "$HEARTBEAT_PID" 2>/dev/null || true; log "Agent stopped."' EXIT

# ── Delegate ──────────────────────────────────────────────────────────────────
log "Delegating to ${IMPL_SCRIPT}"
# shellcheck disable=SC1090
source "$IMPL_SCRIPT"
