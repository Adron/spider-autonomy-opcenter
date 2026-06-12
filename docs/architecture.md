# Agent Orchestration System — Architecture

## Overview

The Spider Autonomy OpCenter is a multi-agent orchestration platform that allows agents to run persistently and autonomously on a remote Bastion/Jump server. Operators can disconnect their local machine, travel, and reconnect later to inspect, resume, or redirect agents.

---

## System Architecture

```
┌─ Your Laptop (MBP / any machine) ─────────────────┐
│  SSH client                                        │
│  Web browser (dashboard via tunnel)                │
│  scripts/bastion_connect.sh                        │
└──────────────────────┬─────────────────────────────┘
                       │ SSH tunnel
                       ▼
┌─ Bastion / Jump Server ────────────────────────────────────────────────────┐
│  OpenSSH (hardened, key-only auth)                                         │
│  nginx  → Flask dashboard (localhost:8080)                                 │
│  SQLite state database  (opcenter.db)                                      │
│  Session recorder (optional)                                               │
│                                                                            │
│  ┌─ spider-opcenter.service (systemd) ──────────────────────────────────┐  │
│  │  gunicorn → dashboard/app.py                                         │  │
│  │  REST API: /agents  /prompts  /agents/<id>/logs  /agents/<id>/events │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
└───────────────────────────────────────┬────────────────────────────────────┘
                                        │ (same host or local network)
                                        ▼
┌─ Agent Execution Layer ──────────────────────────────────────────────────────┐
│                                                                              │
│  Agent 1 (systemd user service)                                              │
│    ├─ System user:  agent_github_sync                                        │
│    ├─ tmux session: github_sync                                              │
│    ├─ ExecStart:    ~/.local/bin/run_agent.sh                                │
│    ├─ Prompt defaults: ~/agent_defaults.yaml                                 │
│    └─ Logs:        ~/logs/github_sync.log  +  journalctl                    │
│                                                                              │
│  Agent 2 (systemd user service)                                              │
│    ├─ System user:  agent_deploy                                             │
│    ├─ Credentials: ~/.ssh/github_key  ~/.aws/credentials                    │
│    └─ ...                                                                    │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘
```

---

## Component Reference

### agents/scripts/prompt_handler.sh

Shell library sourced by agent scripts. Provides `prompt_with_default` and `confirm` functions that:

1. Look up the prompt key in `~/agent_defaults.yaml`
2. If not found, POST to the dashboard and return the operator-supplied answer
3. Fall back to interactive `read` when a TTY is present
4. Persist new answers back to the defaults file

### agents/scripts/run_agent.sh

Generic entry point installed as `~/.local/bin/run_agent.sh` for each agent system user. It:

- Sets up log tee to `~/logs/<AGENT_ID>.log`
- Spawns a background heartbeat loop (POST to dashboard every 30 s)
- Sources `prompt_handler.sh`
- Delegates to `~/workspace/agent_impl.sh`

### agents/systemd/agent@.service

Systemd template unit. One instance per agent (`agent@<id>.service`). Reads its environment from `~/.config/spider-autonomy/<id>/env`.

### dashboard/app.py

Flask REST API with the following endpoints:

| Method | Path | Description |
|--------|------|-------------|
| GET | `/` | Dashboard web UI |
| GET | `/agents` | List all agents |
| POST | `/agents` | Register a new agent |
| GET | `/agents/<id>` | Get agent details |
| POST | `/agents/<id>/heartbeat` | Agent heartbeat receiver |
| POST | `/agents/<id>/pause` | Stop agent service |
| POST | `/agents/<id>/resume` | Start agent service |
| GET | `/agents/<id>/logs?lines=N` | Tail agent log file |
| GET | `/agents/<id>/events` | List audit events |
| GET | `/prompts?pending=true` | List pending prompts |
| POST | `/prompts` | Agent submits a new prompt |
| GET | `/prompts/<id>` | Get prompt detail |
| POST | `/prompts/<id>/answer` | Operator submits answer |

### scripts/setup_agent.sh

Provisions a new agent:
- Creates Linux system user (`agent_<id>`)
- Generates ed25519 SSH key
- Configures git
- Installs scripts
- Writes systemd service + environment file
- Optionally registers with the dashboard

### bastion/setup_bastion.sh

One-shot bastion server setup:
- Installs packages (tmux, python3, nginx)
- Deploys dashboard as a systemd service
- Configures nginx reverse proxy
- Hardens SSH (key-only, no root login)
- Configures ufw firewall

### scripts/bastion_connect.sh

Local helper for operators:
- `attach <agent>` — tmux attach to agent session
- `dashboard` — SSH tunnel + browser open
- `list` — list remote tmux sessions
- `tunnel` — foreground SSH tunnel
- `ssh` — plain SSH to bastion

---

## Data Model

```
agents         prompts          events          defaults
─────────      ────────         ───────         ────────
id (PK)        id (PK)          id (PK)         agent_id (PK,FK)
system_user    agent_id (FK)    agent_id (FK)   prompt_key (PK)
status         prompt_key       event_type      answer
last_heartbeat prompt_text      payload         updated_at
last_checkpoint awaiting_input  created_at
log_file       answer
workdir        created_at
created_at     answered_at
updated_at
```

---

## Deployment Guide

### 1. Set up the bastion server

```bash
git clone https://github.com/Adron/spider-autonomy-opcenter
cd spider-autonomy-opcenter
sudo bash bastion/setup_bastion.sh
```

### 2. Provision an agent

```bash
# On the bastion (or agent execution server)
sudo bash scripts/setup_agent.sh github_sync ci@example.com http://localhost:8080
```

Add the printed SSH public key to the GitHub account or deploy keys for the repos the agent needs to access.

### 3. Write your agent implementation

```bash
sudo -u agent_github_sync bash
cat > ~/workspace/agent_impl.sh << 'EOF'
#!/usr/bin/env bash
# Your agent logic here.
# prompt_with_default and confirm are already available.

if confirm "confirm_push" "Push latest changes to remote?"; then
    git push origin main
fi
EOF
chmod +x ~/workspace/agent_impl.sh
```

### 4. Start the agent

```bash
sudo -u agent_github_sync \
  XDG_RUNTIME_DIR=/run/user/$(id -u agent_github_sync) \
  systemctl --user start agent@github_sync
```

### 5. Connect from your laptop

```bash
export BASTION_HOST=<your-bastion-ip>
./scripts/bastion_connect.sh dashboard    # opens browser at http://localhost:8080
./scripts/bastion_connect.sh attach github_sync
```

---

## Security Notes

- The dashboard is **not** exposed publicly — access is only via SSH tunnel
- Each agent runs as a dedicated unprivileged system user
- SSH keys are per-agent and stored in the agent user's `~/.ssh/`
- Secrets (AWS credentials etc.) belong in `~/.aws/` or HashiCorp Vault; never in environment files committed to git
- The bastion SSH config disables password auth and root login
- ufw restricts inbound traffic to SSH only

---

## Phased Roadmap

| Phase | Status | Description |
|-------|--------|-------------|
| 1 | ✅ | tmux sessions, YAML defaults, prompt handler |
| 2 | ✅ | systemd services, SQLite state DB, heartbeats |
| 3 | ✅ | Per-agent system users, SSH keys, git config |
| 4 | ✅ | Flask dashboard, REST API, web UI |
| 5 | 🔲 | NATS/RabbitMQ for agent-to-agent messaging |
| 6 | 🔲 | HashiCorp Vault integration for secrets |
| 7 | 🔲 | Prometheus metrics + Grafana dashboard |
| 8 | 🔲 | Multi-server agent fleet (agent exec servers) |
