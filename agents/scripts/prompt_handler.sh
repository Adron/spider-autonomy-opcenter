#!/usr/bin/env bash
# prompt_handler.sh — Wrapper for interactive prompts in unattended agents.
#
# Usage:
#   source prompt_handler.sh
#   answer=$(prompt_with_default "confirm_push" "yes" "Push changes to remote?")
#
# Environment:
#   AGENT_DEFAULTS_FILE  Path to the YAML defaults file.
#                        Defaults to ~/agent_defaults.yaml
#   DASHBOARD_API_URL    Base URL for the dashboard REST API.
#                        Set to enable remote prompt notifications.
#   AGENT_ID             Identifier used when notifying the dashboard.

set -euo pipefail

AGENT_DEFAULTS_FILE="${AGENT_DEFAULTS_FILE:-${HOME}/agent_defaults.yaml}"
DASHBOARD_API_URL="${DASHBOARD_API_URL:-}"
AGENT_ID="${AGENT_ID:-unknown}"

# ── Helpers ─────────────────────────────────────────────────────────────────

_log() { echo "[prompt_handler] $(date -u +%Y-%m-%dT%H:%M:%SZ) $*" >&2; }

# Read a value from the YAML defaults file for a given key.
# YAML parsing is intentionally kept simple: lines of the form "key: value".
_lookup_default() {
    local key="$1"
    if [[ -f "$AGENT_DEFAULTS_FILE" ]]; then
        grep -E "^${key}:[[:space:]]" "$AGENT_DEFAULTS_FILE" \
            | head -1 \
            | sed 's/^[^:]*:[[:space:]]*//' \
            | tr -d '"' \
            | tr -d "'"
    fi
}

# Write a new key/value pair to the defaults file so it is remembered for next
# time. If the key already exists the existing line is replaced.
_save_default() {
    local key="$1" value="$2"
    if [[ -f "$AGENT_DEFAULTS_FILE" ]] && grep -qE "^${key}:" "$AGENT_DEFAULTS_FILE"; then
        sed -i "s|^${key}:.*|${key}: ${value}|" "$AGENT_DEFAULTS_FILE"
    else
        echo "${key}: ${value}" >> "$AGENT_DEFAULTS_FILE"
    fi
}

# Notify the dashboard that an agent is waiting for a prompt answer.
# Returns the answer provided via the API, or an empty string on failure.
_notify_dashboard() {
    local agent_id="$1" prompt_key="$2" prompt_text="$3"

    if [[ -z "$DASHBOARD_API_URL" ]]; then
        return 0
    fi

    local payload
    payload=$(printf '{"agent_id":"%s","prompt_key":"%s","prompt_text":"%s"}' \
        "$agent_id" "$prompt_key" "$prompt_text")

    local response
    response=$(curl -s -X POST \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "${DASHBOARD_API_URL}/prompts" 2>/dev/null) || true

    echo "$response" | grep -oP '"answer"\s*:\s*"\K[^"]+' || true
}

# ── Public API ───────────────────────────────────────────────────────────────

# prompt_with_default KEY DEFAULT PROMPT_TEXT
#
# 1. Look up KEY in the defaults file.  If found, echo the stored value and
#    return immediately (fully unattended).
# 2. If not found and a dashboard URL is configured, POST a pending prompt and
#    poll for an operator-supplied answer.
# 3. If still no answer (interactive terminal present) fall back to read(1).
# 4. Save the answer to the defaults file for future runs.
prompt_with_default() {
    local key="${1:?prompt_with_default requires a key}"
    local default="${2:-}"
    local prompt_text="${3:-${key}}"

    # 1. Check stored defaults.
    local stored
    stored=$(_lookup_default "$key")
    if [[ -n "$stored" ]]; then
        _log "Using stored default for '${key}': ${stored}"
        echo "$stored"
        return 0
    fi

    # 2. Notify dashboard and wait for remote answer (non-interactive path).
    if [[ -n "$DASHBOARD_API_URL" ]]; then
        _log "No default for '${key}'; notifying dashboard (agent=${AGENT_ID})"
        local remote_answer
        remote_answer=$(_notify_dashboard "$AGENT_ID" "$key" "$prompt_text")
        if [[ -n "$remote_answer" ]]; then
            _log "Received remote answer for '${key}': ${remote_answer}"
            _save_default "$key" "$remote_answer"
            echo "$remote_answer"
            return 0
        fi
    fi

    # 3. Interactive fallback.
    local response=""
    if [[ -t 0 ]]; then
        read -r -p "${prompt_text} [default: ${default}] " response
    fi
    response="${response:-$default}"

    # 4. Persist for next time.
    _save_default "$key" "$response"
    _log "Saved new default for '${key}': ${response}"
    echo "$response"
}

# Convenience: ask a yes/no question.  Returns 0 (true) for yes, 1 for no.
confirm() {
    local key="${1:?confirm requires a key}"
    local prompt_text="${2:-${key}}"
    local answer
    answer=$(prompt_with_default "$key" "no" "$prompt_text [yes/no]")
    [[ "$answer" =~ ^[Yy](es)?$ ]]
}
