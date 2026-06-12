#!/usr/bin/env bash
# setup_agent.sh — Provision a new agent with its own system user, SSH key,
# git config, working directory, and systemd service.
#
# Usage (must be run as root or with sudo):
#   sudo ./setup_agent.sh <agent_id> [github_email] [dashboard_api_url]
#
# Examples:
#   sudo ./setup_agent.sh agent_github_sync ci@example.com http://localhost:8080
#   sudo ./setup_agent.sh agent_deploy
#
# What this script does:
#   1. Creates a dedicated Linux system user  (agent_<id>)
#   2. Generates an ed25519 SSH key for GitHub authentication
#   3. Configures git for the agent user
#   4. Installs the run_agent.sh and prompt_handler.sh scripts
#   5. Creates a systemd user service (via agent@.service template)
#   6. Optionally registers the agent with the dashboard API
#
# After running, add the public key printed at the end to the agent's GitHub
# account or the target organisation's deploy keys.

set -euo pipefail

# ── Args ──────────────────────────────────────────────────────────────────────
AGENT_ID="${1:?Usage: $0 <agent_id> [github_email] [dashboard_api_url]}"
GITHUB_EMAIL="${2:-${AGENT_ID}@agents.local}"
DASHBOARD_API_URL="${3:-}"

SYSTEM_USER="agent_${AGENT_ID}"
AGENT_HOME="/home/${SYSTEM_USER}"
WORKSPACE="${AGENT_HOME}/workspace"
BIN_DIR="${AGENT_HOME}/.local/bin"
CONFIG_DIR="${AGENT_HOME}/.config/spider-autonomy/${AGENT_ID}"
LOG_DIR="${AGENT_HOME}/logs"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

log() { echo "==> $*"; }
warn() { echo "WARN: $*" >&2; }

# ── Privilege check ───────────────────────────────────────────────────────────
if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: This script must be run as root."
    exit 1
fi

# ── 1. Create system user ─────────────────────────────────────────────────────
if id "$SYSTEM_USER" &>/dev/null; then
    log "User '${SYSTEM_USER}' already exists — skipping creation"
else
    log "Creating system user: ${SYSTEM_USER}"
    useradd -m -s /bin/bash "$SYSTEM_USER"
fi

# ── 2. Directory structure ────────────────────────────────────────────────────
log "Creating directories"
for dir in "$WORKSPACE" "$BIN_DIR" "$CONFIG_DIR" "$LOG_DIR" \
           "${AGENT_HOME}/.config/systemd/user"; do
    mkdir -p "$dir"
    chown "$SYSTEM_USER:$SYSTEM_USER" "$dir"
done

# ── 3. Generate SSH key ───────────────────────────────────────────────────────
SSH_DIR="${AGENT_HOME}/.ssh"
SSH_KEY="${SSH_DIR}/github_key"

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
chown "$SYSTEM_USER:$SYSTEM_USER" "$SSH_DIR"

if [[ -f "$SSH_KEY" ]]; then
    log "SSH key already exists — skipping generation"
else
    log "Generating ed25519 SSH key"
    sudo -u "$SYSTEM_USER" ssh-keygen -t ed25519 \
        -f "$SSH_KEY" \
        -C "${SYSTEM_USER}@$(hostname)" \
        -N ""
fi

# SSH config so git uses the agent-specific key.
SSH_CONFIG="${SSH_DIR}/config"
cat > "$SSH_CONFIG" << EOF
Host github.com
    HostName github.com
    User git
    IdentityFile ${SSH_KEY}
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
EOF
chown "$SYSTEM_USER:$SYSTEM_USER" "$SSH_CONFIG"
chmod 600 "$SSH_CONFIG"

# ── 4. Git config ─────────────────────────────────────────────────────────────
log "Configuring git for ${SYSTEM_USER}"
sudo -u "$SYSTEM_USER" git config --global user.name  "$SYSTEM_USER"
sudo -u "$SYSTEM_USER" git config --global user.email "$GITHUB_EMAIL"
sudo -u "$SYSTEM_USER" git config --global \
    core.sshCommand "ssh -i ${SSH_KEY} -o IdentitiesOnly=yes"
sudo -u "$SYSTEM_USER" git config --global init.defaultBranch main

# ── 5. Install scripts ────────────────────────────────────────────────────────
log "Installing agent scripts"
cp "${REPO_ROOT}/agents/scripts/run_agent.sh"      "${BIN_DIR}/run_agent.sh"
cp "${REPO_ROOT}/agents/scripts/prompt_handler.sh" "${BIN_DIR}/prompt_handler.sh"
chmod +x "${BIN_DIR}/run_agent.sh" "${BIN_DIR}/prompt_handler.sh"
chown "$SYSTEM_USER:$SYSTEM_USER" "${BIN_DIR}/run_agent.sh" "${BIN_DIR}/prompt_handler.sh"

# ── 6. Default YAML ───────────────────────────────────────────────────────────
DEFAULTS_SRC="${REPO_ROOT}/agents/defaults/agent_defaults.yaml"
DEFAULTS_DST="${AGENT_HOME}/agent_defaults.yaml"
if [[ ! -f "$DEFAULTS_DST" ]]; then
    log "Installing default prompts config"
    cp "$DEFAULTS_SRC" "$DEFAULTS_DST"
    chown "$SYSTEM_USER:$SYSTEM_USER" "$DEFAULTS_DST"
fi

# ── 7. Per-agent environment file ─────────────────────────────────────────────
log "Writing environment file"
cat > "${CONFIG_DIR}/env" << EOF
AGENT_ID=${AGENT_ID}
AGENT_WORKDIR=${WORKSPACE}
AGENT_DEFAULTS_FILE=${DEFAULTS_DST}
DASHBOARD_API_URL=${DASHBOARD_API_URL}
LOG_DIR=${LOG_DIR}
EOF
chown "$SYSTEM_USER:$SYSTEM_USER" "${CONFIG_DIR}/env"
chmod 600 "${CONFIG_DIR}/env"

# ── 8. Systemd user service ───────────────────────────────────────────────────
log "Installing systemd service"
SYSTEMD_USER_DIR="${AGENT_HOME}/.config/systemd/user"
cp "${REPO_ROOT}/agents/systemd/agent@.service" \
   "${SYSTEMD_USER_DIR}/agent@.service"
chown -R "$SYSTEM_USER:$SYSTEM_USER" "${SYSTEMD_USER_DIR}"

# Enable linger so the service can start without an interactive login session.
loginctl enable-linger "$SYSTEM_USER" 2>/dev/null || \
    warn "loginctl enable-linger failed — service may not auto-start after reboot"

sudo -u "$SYSTEM_USER" \
    XDG_RUNTIME_DIR="/run/user/$(id -u "$SYSTEM_USER")" \
    systemctl --user daemon-reload 2>/dev/null || true

# ── 9. Register with dashboard ────────────────────────────────────────────────
if [[ -n "$DASHBOARD_API_URL" ]]; then
    log "Registering agent with dashboard at ${DASHBOARD_API_URL}"
    curl -s -X POST \
        -H "Content-Type: application/json" \
        -d "{
              \"id\": \"${AGENT_ID}\",
              \"system_user\": \"${SYSTEM_USER}\",
              \"log_file\": \"${LOG_DIR}/${AGENT_ID}.log\",
              \"workdir\": \"${WORKSPACE}\"
            }" \
        "${DASHBOARD_API_URL}/agents" | python3 -m json.tool || true
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════"
echo "  Agent '${AGENT_ID}' provisioned successfully"
echo "════════════════════════════════════════════════════════"
echo "  System user : ${SYSTEM_USER}"
echo "  Home        : ${AGENT_HOME}"
echo "  Workspace   : ${WORKSPACE}"
echo "  Logs        : ${LOG_DIR}"
echo "  Defaults    : ${DEFAULTS_DST}"
echo ""
echo "  GitHub public key (add to GitHub account / deploy keys):"
cat "${SSH_KEY}.pub"
echo ""
echo "  To start the agent:"
echo "    sudo -u ${SYSTEM_USER} XDG_RUNTIME_DIR=/run/user/\$(id -u ${SYSTEM_USER})"
echo "    systemctl --user start agent@${AGENT_ID}"
echo ""
echo "  To place your agent implementation script:"
echo "    ${WORKSPACE}/agent_impl.sh"
echo "════════════════════════════════════════════════════════"
