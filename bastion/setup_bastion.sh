#!/usr/bin/env bash
# setup_bastion.sh — Prepare a fresh Ubuntu/Debian server as the
# Spider Autonomy OpCenter bastion host.
#
# Run as root (or with sudo) on the bastion server:
#   curl -fsSL https://raw.github.com/…/setup_bastion.sh | sudo bash
#   — or —
#   sudo ./setup_bastion.sh [dashboard_port]
#
# What this script does:
#   1. Installs required packages (tmux, python3, pip, sqlite3, nginx)
#   2. Creates a dedicated opcenter system user for the dashboard
#   3. Deploys the Flask dashboard as a systemd service behind nginx
#   4. Configures SSH hardening (key-only auth, rate limiting)
#   5. Optionally sets up ufw firewall rules
#
# Environment variables:
#   DASHBOARD_PORT   Port the Flask app listens on (default: 8080)
#   OPCENTER_REPO    Git URL of this repo (default: current directory)

set -euo pipefail

DASHBOARD_PORT="${DASHBOARD_PORT:-8080}"
OPCENTER_USER="opcenter"
OPCENTER_HOME="/home/${OPCENTER_USER}"
DASHBOARD_DIR="${OPCENTER_HOME}/dashboard"

log()  { echo "==> $*"; }
warn() { echo "WARN: $*" >&2; }

# ── Privilege check ───────────────────────────────────────────────────────────
if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: Run as root."
    exit 1
fi

# ── 1. Package installation ───────────────────────────────────────────────────
log "Updating packages"
apt-get update -qq
apt-get install -y --no-install-recommends \
    tmux \
    python3 \
    python3-pip \
    python3-venv \
    sqlite3 \
    nginx \
    curl \
    git \
    ufw \
    openssh-server

# ── 2. Create opcenter user ───────────────────────────────────────────────────
if id "$OPCENTER_USER" &>/dev/null; then
    log "User '${OPCENTER_USER}' already exists"
else
    log "Creating user '${OPCENTER_USER}'"
    useradd -m -s /bin/bash "$OPCENTER_USER"
fi

# ── 3. Deploy dashboard ───────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

log "Copying dashboard files"
mkdir -p "$DASHBOARD_DIR"
cp -r "${REPO_ROOT}/dashboard/." "$DASHBOARD_DIR/"
chown -R "$OPCENTER_USER:$OPCENTER_USER" "$DASHBOARD_DIR"

log "Creating Python virtual environment"
sudo -u "$OPCENTER_USER" python3 -m venv "${OPCENTER_HOME}/venv"
sudo -u "$OPCENTER_USER" \
    "${OPCENTER_HOME}/venv/bin/pip" install -q \
    -r "${DASHBOARD_DIR}/requirements.txt" \
    gunicorn

# Initialise the database.
sudo -u "$OPCENTER_USER" bash -c "
    cd ${DASHBOARD_DIR}
    sqlite3 opcenter.db < db/schema.sql
"

# ── 4. systemd service for the dashboard ─────────────────────────────────────
log "Installing dashboard systemd service"
cat > /etc/systemd/system/spider-opcenter.service << EOF
[Unit]
Description=Spider Autonomy OpCenter Dashboard
After=network.target

[Service]
Type=simple
User=${OPCENTER_USER}
WorkingDirectory=${DASHBOARD_DIR}
Environment="SECRET_KEY=$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
Environment="DATABASE_URL=sqlite:///${DASHBOARD_DIR}/opcenter.db"
Environment="LOG_BASE_DIR=/var/log/spider-autonomy"
ExecStart=${OPCENTER_HOME}/venv/bin/gunicorn \
    --workers 2 \
    --bind 127.0.0.1:${DASHBOARD_PORT} \
    --access-logfile /var/log/spider-autonomy/dashboard-access.log \
    --error-logfile /var/log/spider-autonomy/dashboard-error.log \
    app:app
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

mkdir -p /var/log/spider-autonomy
chown -R "$OPCENTER_USER:$OPCENTER_USER" /var/log/spider-autonomy

systemctl daemon-reload
systemctl enable --now spider-opcenter

# ── 5. nginx reverse proxy ────────────────────────────────────────────────────
log "Configuring nginx"
cat > /etc/nginx/sites-available/spider-opcenter << EOF
server {
    listen 80;
    server_name _;

    # Only accessible via SSH tunnel from the operator's machine.
    # For public deployment add TLS here.
    location / {
        proxy_pass         http://127.0.0.1:${DASHBOARD_PORT};
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 300s;
        proxy_buffering    off;
    }
}
EOF

ln -sf /etc/nginx/sites-available/spider-opcenter \
       /etc/nginx/sites-enabled/spider-opcenter
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx

# ── 6. SSH hardening ──────────────────────────────────────────────────────────
log "Hardening SSH configuration"
SSHD_CONF="/etc/ssh/sshd_config.d/99-spider-autonomy.conf"
cat > "$SSHD_CONF" << 'EOF'
# Spider Autonomy bastion hardening
PasswordAuthentication no
ChallengeResponseAuthentication no
PermitRootLogin no
MaxAuthTries 3
ClientAliveInterval 120
ClientAliveCountMax 3
EOF
systemctl reload sshd || systemctl reload ssh

# ── 7. Firewall ───────────────────────────────────────────────────────────────
if command -v ufw &>/dev/null; then
    log "Configuring ufw firewall"
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow OpenSSH
    # Dashboard is only accessible via SSH tunnel — do NOT open 80/8080 publicly.
    ufw --force enable
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════"
echo "  Bastion setup complete"
echo "════════════════════════════════════════════════════════"
echo ""
echo "  Dashboard service : spider-opcenter"
echo "  Dashboard port    : ${DASHBOARD_PORT} (localhost only)"
echo ""
echo "  Access from your local machine:"
echo "    ssh -L 8080:localhost:${DASHBOARD_PORT} <user>@$(hostname -I | awk '{print $1}')"
echo "    Then open http://localhost:8080"
echo ""
echo "  Or use the helper:"
echo "    BASTION_HOST=$(hostname -I | awk '{print $1}') ./scripts/bastion_connect.sh dashboard"
echo "════════════════════════════════════════════════════════"
