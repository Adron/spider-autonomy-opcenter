# Spider Autonomy OpCenter

An agent orchestration system that keeps AI/automation agents running persistently on a remote Bastion server so you can disconnect your local machine, travel, and reconnect later — the "loop" concept.

## Quick Start

```bash
# 1. Set up bastion server (run as root on the server)
sudo bash bastion/setup_bastion.sh

# 2. Provision an agent
sudo bash scripts/setup_agent.sh my_agent me@example.com http://localhost:8080

# 3. Write your agent logic
sudo -u agent_my_agent bash -c 'cat > ~/workspace/agent_impl.sh << "EOF"
#!/usr/bin/env bash
# Your automation here — prompt_with_default is available
answer=$(prompt_with_default "confirm_push" "yes" "Push to remote?")
echo "Answer: $answer"
EOF
chmod +x ~/workspace/agent_impl.sh'

# 4. Start the agent
sudo -u agent_my_agent \
  XDG_RUNTIME_DIR=/run/user/$(id -u agent_my_agent) \
  systemctl --user start agent@my_agent

# 5. Connect from your laptop
export BASTION_HOST=<your-bastion-ip>
./scripts/bastion_connect.sh dashboard    # SSH tunnel + browser
./scripts/bastion_connect.sh attach my_agent
```

## Architecture

```
Your Laptop → SSH tunnel → Bastion Server → Agent Execution Layer
                           (Flask dashboard)  (systemd services,
                           (SQLite state DB)   tmux sessions,
                                               per-agent system users)
```

See [docs/architecture.md](docs/architecture.md) for the full design.

## Repository Layout

```
├── agents/
│   ├── defaults/agent_defaults.yaml   # Unattended prompt defaults
│   ├── scripts/
│   │   ├── prompt_handler.sh          # Auto-answer / notify-and-wait library
│   │   ├── run_agent.sh               # Generic agent entry point
│   │   └── tmux_session.sh            # tmux session management helper
│   └── systemd/agent@.service         # Systemd template unit
├── bastion/
│   └── setup_bastion.sh               # One-shot bastion server setup
├── dashboard/
│   ├── app.py                         # Flask REST API + web UI
│   ├── requirements.txt
│   ├── db/schema.sql                  # State database schema
│   ├── templates/index.html           # Operator dashboard UI
│   └── tests/test_app.py              # Pytest test suite (18 tests)
├── scripts/
│   ├── setup_agent.sh                 # Agent provisioning
│   └── bastion_connect.sh             # Local connection helper
└── docs/
    └── architecture.md                # Full architecture documentation
```

## Running the Dashboard Locally

```bash
cd dashboard
pip install -r requirements.txt
flask run --host 0.0.0.0 --port 8080
```

## Running Tests

```bash
cd dashboard
pip install -r requirements.txt pytest
pytest tests/ -v
```
