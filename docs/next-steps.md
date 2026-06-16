# Next Steps — Spider Autonomy OpCenter

A short, actionable review of where the project stands today and what to do next.

## Where Things Stand

Phases 1–4 of the roadmap are implemented and merged to `main`:

- **Phase 1** — tmux session management, YAML prompt defaults, prompt handler library
- **Phase 2** — systemd template unit, SQLite state DB, heartbeat ingestion
- **Phase 3** — Per-agent system users, ed25519 SSH keys, git config
- **Phase 4** — Flask dashboard + REST API + web UI (18 passing tests)

The codebase is small and coherent: `bastion/setup_bastion.sh` provisions the
control plane; `scripts/setup_agent.sh` provisions individual agents; the
dashboard exposes both an HTTP API and a browser UI; `scripts/bastion_connect.sh`
is the operator's local entry point.

What is **not** yet done: nothing has been deployed to a real server. Every
piece has been written and unit-tested locally, but the bastion has never had
`setup_bastion.sh` executed against it end-to-end.

## Immediate Next Step

**Stand up the bastion server.** Until that happens, the rest of the roadmap
is theoretical. See [`bastion-server-setup.md`](./bastion-server-setup.md) for
prereqs and the step-by-step.

## After the Bastion Is Up

Ordered by what unlocks the most value soonest:

1. **End-to-end smoke test of a real agent.** Provision one trivial agent
   (e.g. `hello_world` that loops `date >> ~/logs/hello.log`) on the bastion,
   confirm heartbeats reach the dashboard, confirm `bastion_connect.sh attach`
   works from a laptop, confirm a pending prompt round-trips through the UI.
   This validates Phases 1–4 against real systemd / real SSH, not localhost.

2. **TLS in front of the dashboard.** Today nginx serves plain HTTP and relies
   on the SSH tunnel for confidentiality. That is fine for solo use, but the
   moment a second operator joins, or you want to access from a phone, you
   need TLS. Easiest path: Caddy in front of `127.0.0.1:8080` with an
   automatic Let's Encrypt cert, gated behind Tailscale or a Cloudflare
   Tunnel so the listener isn't publicly reachable.

3. **Backups for `opcenter.db`.** It is the only piece of state that cannot
   be reconstructed from code. A nightly `sqlite3 opcenter.db ".backup"` to
   an off-host location (S3, Backblaze B2, restic to a remote) is enough.

4. **Authentication on the dashboard API.** Right now any process on the
   bastion that can reach `127.0.0.1:8080` can register agents, answer
   prompts, and pause services. Add a shared-secret header check
   (`X-OpCenter-Token`) read from an env var, and have agents and the UI
   send it. Cheap, sufficient for the threat model.

5. **Phase 5 — agent-to-agent messaging.** NATS is the lower-friction choice
   over RabbitMQ for this footprint: single binary, runs as a systemd
   service, no broker config. Wire it once you have more than one agent that
   needs to coordinate.

6. **Phase 6 — Vault for secrets.** Worth doing once you have an agent that
   needs cloud credentials (AWS, GCP). Until then, per-agent `~/.ssh/` and
   `~/.aws/` are fine and avoid the operational overhead of running Vault.

7. **Phase 7 — Prometheus + Grafana.** Defer until you actually have a
   question that the dashboard cannot answer. The dashboard already shows
   heartbeats, status, and recent events; metrics are valuable when you
   want to look at trends over weeks.

8. **Phase 8 — multi-server fleet.** Defer until a single bastion is
   saturated or you have a regulatory reason to split execution from the
   control plane.

## Gaps Worth Closing Before They Bite

- **No log rotation.** `/var/log/spider-autonomy/<agent>.log` grows
  unbounded. Add a `logrotate` drop-in as part of `setup_bastion.sh`.
- **No `setup_bastion.sh` re-run safety check.** It re-deploys the
  dashboard on every run; verify that does not blow away `opcenter.db`
  before running it a second time on a host with real state.
- **No documented disaster-recovery path.** Write down (even in five
  lines) how to rebuild the bastion from a fresh VM + a DB backup.
- **Dashboard has no audit of who answered a prompt.** Multi-operator use
  will want this. Schema change is small (`events.actor`).
