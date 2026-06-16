# Bastion Server Setup — Prereqs and Immediate Steps

The bastion is the long-running host that runs the dashboard, the SQLite
state DB, and the agent execution layer. Your laptop never runs agents —
it only SSH-tunnels in. This doc covers what to provision before running
`bastion/setup_bastion.sh` and the exact sequence to run it.

## Prerequisites

### 1. A VM or bare-metal host

| Resource | Minimum | Comfortable |
|---|---|---|
| OS | Ubuntu 22.04 LTS or Debian 12 (the setup script uses `apt-get`) | same |
| CPU | 1 vCPU | 2 vCPU |
| RAM | 1 GB | 2 GB |
| Disk | 20 GB | 40 GB+ (logs and `opcenter.db` grow) |
| Network | Public IPv4 or reachable on Tailscale/VPN | same |

Providers that work cleanly with this setup: Hetzner (CX22 is plenty),
DigitalOcean (basic droplet), Linode/Akamai, Vultr, Scaleway, or any
home server reachable over Tailscale.

### 2. DNS or stable address (optional but recommended)

- A hostname like `bastion.yourdomain.tld` pointing at the host, **or**
- A stable Tailscale machine name, **or**
- Just the raw IP — you'll set `BASTION_HOST` to whichever you choose.

### 3. SSH access from your laptop as a non-root user with sudo

Before `setup_bastion.sh` hardens SSH (disables password auth, no root
login), make sure you can already log in with a key:

```bash
# On the laptop
ssh-keygen -t ed25519 -C "you@laptop"          # if you don't have one
ssh-copy-id <youruser>@<bastion-ip>             # push the pubkey
ssh <youruser>@<bastion-ip> sudo -n true        # verify passwordless sudo
```

If `sudo -n true` fails, fix sudoers first — once SSH is locked down you
do not want to discover you can't `sudo`.

### 4. Inbound port 22 open

The setup script will configure `ufw` to allow OpenSSH and deny everything
else. If your provider has a separate cloud firewall (AWS Security Groups,
Hetzner firewall, etc.), allow inbound 22 there too. Do **not** open 80
or 8080 — the dashboard is intentionally tunnel-only.

### 5. This repo on the bastion

The setup script copies `dashboard/` from the repo on disk into
`/home/opcenter/dashboard/`, so the repo has to be present locally on the
bastion when you run it:

```bash
ssh <youruser>@<bastion-ip>
git clone https://github.com/Adron/spider-autonomy-opcenter
cd spider-autonomy-opcenter
```

### 6. (Optional) An off-host backup target

`opcenter.db` is the only piece of state that cannot be reconstructed.
Pick where nightly backups will land before you start producing real
state: an S3 bucket, a B2 bucket, a restic repo, anywhere off-host.

## Immediate Steps

Run these on the bastion, in order. The whole thing should take under
five minutes.

```bash
# 1. Run the setup script as root
sudo bash bastion/setup_bastion.sh
```

This installs `tmux`, `python3`, `python3-venv`, `sqlite3`, `nginx`,
`ufw`, and `openssh-server`; creates the `opcenter` user; deploys the
Flask app under gunicorn behind nginx; enables `spider-opcenter.service`;
hardens SSH; and turns on `ufw`.

```bash
# 2. Verify the dashboard is alive
sudo systemctl status spider-opcenter
curl -sf http://127.0.0.1:8080/agents && echo OK
```

```bash
# 3. From the laptop — open a tunnel and confirm the UI
export BASTION_HOST=<bastion-ip-or-hostname>
./scripts/bastion_connect.sh dashboard
# Browser should open http://localhost:8080
```

```bash
# 4. Smoke-test by provisioning a throwaway agent
sudo bash scripts/setup_agent.sh hello_world \
     you@example.com \
     http://localhost:8080

# Note the printed public key — add to GitHub only if this agent
# will actually touch a repo; for the smoke test you can skip that.
```

```bash
# 5. Drop in a trivial implementation and start it
sudo -u agent_hello_world bash -c 'cat > ~/workspace/agent_impl.sh <<"EOF"
#!/usr/bin/env bash
while true; do
  echo "[$(date -Iseconds)] hello from $AGENT_ID"
  sleep 30
done
EOF
chmod +x ~/workspace/agent_impl.sh'

sudo -u agent_hello_world \
  XDG_RUNTIME_DIR=/run/user/$(id -u agent_hello_world) \
  systemctl --user start agent@hello_world
```

```bash
# 6. From the laptop — confirm the agent shows up
./scripts/bastion_connect.sh dashboard
# In the UI: hello_world should appear with a recent heartbeat.
```

If step 6 shows a live heartbeat, the bastion is operational. From here,
follow [`next-steps.md`](./next-steps.md) for hardening (TLS, backups,
API auth) before you put any real agent on it.

## Post-Setup Checklist

- [ ] Dashboard reachable via `bastion_connect.sh dashboard`
- [ ] `sudo ufw status` shows only OpenSSH allowed inbound
- [ ] `sshd -T | grep -E '^(passwordauthentication|permitrootlogin)'`
      shows `no` for both
- [ ] `systemctl is-enabled spider-opcenter` returns `enabled`
- [ ] Backup job for `/home/opcenter/dashboard/opcenter.db` is scheduled
- [ ] Provider-level firewall (if any) matches `ufw` — only 22 inbound
- [ ] Removed the throwaway `hello_world` agent if you did the smoke test:
      `sudo userdel -r agent_hello_world && sudo rm -f /var/log/spider-autonomy/hello_world.log`
