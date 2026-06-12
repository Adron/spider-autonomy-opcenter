"""
app.py — Spider Autonomy OpCenter Dashboard

A lightweight Flask REST API + minimal web UI that provides:
  - Agent status overview
  - Real-time log tailing
  - Pending prompt queue with operator-approval workflow
  - Heartbeat receiver
  - Agent pause / resume control

Usage:
  pip install -r requirements.txt
  # Initialise the database before first run:
  python app.py --init-db
  # Or start directly (also initialises the DB):
  python app.py
  # To use flask run, initialise the DB first then start the server:
  DATABASE_URL=sqlite:///opcenter.db python -c "from app import init_db; init_db()"
  DATABASE_URL=sqlite:///opcenter.db flask run --host 0.0.0.0 --port 8080

Environment variables:
  DATABASE_URL      SQLAlchemy database URL (default: sqlite:///opcenter.db)
  SECRET_KEY        Flask secret key — set to a random value in production
  LOG_BASE_DIR      Root directory where agent log files are written
                    (default: /var/log/spider-autonomy)
"""

import os
import subprocess
from datetime import datetime, timezone

from flask import Flask, Response, jsonify, render_template, request, abort
from flask_sqlalchemy import SQLAlchemy

# ── App setup ─────────────────────────────────────────────────────────────────

app = Flask(__name__)
app.config["SECRET_KEY"] = os.environ.get("SECRET_KEY", "change-me-in-production")
app.config["SQLALCHEMY_DATABASE_URI"] = os.environ.get(
    "DATABASE_URL", "sqlite:///opcenter.db"
)
app.config["SQLALCHEMY_TRACK_MODIFICATIONS"] = False

LOG_BASE_DIR = os.environ.get("LOG_BASE_DIR", "/var/log/spider-autonomy")

db = SQLAlchemy(app)


# ── Models ────────────────────────────────────────────────────────────────────


class Agent(db.Model):
    __tablename__ = "agents"

    id = db.Column(db.String, primary_key=True)
    system_user = db.Column(db.String, nullable=False)
    status = db.Column(
        db.String, nullable=False, default="stopped"
    )  # running|paused|failed|stopped
    last_checkpoint = db.Column(db.String)
    last_heartbeat = db.Column(db.DateTime)
    log_file = db.Column(db.String)
    workdir = db.Column(db.String)
    created_at = db.Column(db.DateTime, default=lambda: datetime.now(timezone.utc))
    updated_at = db.Column(
        db.DateTime,
        default=lambda: datetime.now(timezone.utc),
        onupdate=lambda: datetime.now(timezone.utc),
    )

    prompts = db.relationship("Prompt", backref="agent", lazy=True, cascade="all, delete-orphan")
    events = db.relationship("Event", backref="agent", lazy=True, cascade="all, delete-orphan")

    def to_dict(self):
        return {
            "id": self.id,
            "system_user": self.system_user,
            "status": self.status,
            "last_checkpoint": self.last_checkpoint,
            "last_heartbeat": self.last_heartbeat.isoformat() if self.last_heartbeat else None,
            "log_file": self.log_file,
            "workdir": self.workdir,
            "created_at": self.created_at.isoformat() if self.created_at else None,
            "updated_at": self.updated_at.isoformat() if self.updated_at else None,
        }


class Prompt(db.Model):
    __tablename__ = "prompts"

    id = db.Column(db.Integer, primary_key=True, autoincrement=True)
    agent_id = db.Column(db.String, db.ForeignKey("agents.id"), nullable=False)
    prompt_key = db.Column(db.String, nullable=False)
    prompt_text = db.Column(db.String, nullable=False)
    awaiting_input = db.Column(db.Boolean, nullable=False, default=True)
    answer = db.Column(db.String)
    created_at = db.Column(db.DateTime, default=lambda: datetime.now(timezone.utc))
    answered_at = db.Column(db.DateTime)

    def to_dict(self):
        return {
            "id": self.id,
            "agent_id": self.agent_id,
            "prompt_key": self.prompt_key,
            "prompt_text": self.prompt_text,
            "awaiting_input": self.awaiting_input,
            "answer": self.answer,
            "created_at": self.created_at.isoformat() if self.created_at else None,
            "answered_at": self.answered_at.isoformat() if self.answered_at else None,
        }


class Event(db.Model):
    __tablename__ = "events"

    id = db.Column(db.Integer, primary_key=True, autoincrement=True)
    agent_id = db.Column(db.String, db.ForeignKey("agents.id"), nullable=False)
    event_type = db.Column(db.String, nullable=False)
    payload = db.Column(db.String)
    created_at = db.Column(db.DateTime, default=lambda: datetime.now(timezone.utc))

    def to_dict(self):
        return {
            "id": self.id,
            "agent_id": self.agent_id,
            "event_type": self.event_type,
            "payload": self.payload,
            "created_at": self.created_at.isoformat() if self.created_at else None,
        }


# ── Initialise DB ─────────────────────────────────────────────────────────────


def init_db():
    """Create tables if they do not exist yet."""
    with app.app_context():
        db.create_all()


# ── UI ────────────────────────────────────────────────────────────────────────


@app.route("/", methods=["GET"])
def index():
    """Serve the dashboard HTML page."""
    return render_template("index.html")


# ── Agent API ─────────────────────────────────────────────────────────────────


@app.route("/agents", methods=["GET"])
def list_agents():
    """Return all registered agents and their current status."""
    agents = Agent.query.all()
    return jsonify([a.to_dict() for a in agents])


@app.route("/agents/<agent_id>", methods=["GET"])
def get_agent(agent_id):
    agent = db.session.get(Agent, agent_id)
    if agent is None:
        abort(404)
    return jsonify(agent.to_dict())


@app.route("/agents", methods=["POST"])
def register_agent():
    """Register a new agent. Called by setup_agent.sh during provisioning."""
    data = request.get_json(force=True)
    required = {"id", "system_user"}
    if not required.issubset(data.keys()):
        abort(400, description=f"Missing required fields: {required - data.keys()}")

    agent_id = data["id"]

    # Validate the agent_id so it is safe as a filename component.
    if not _SAFE_ID_PATTERN.match(agent_id):
        abort(400, description="agent id contains invalid characters (use [A-Za-z0-9_-] only)")

    if db.session.get(Agent, agent_id):
        abort(409, description=f"Agent '{agent_id}' already registered")

    # Compute the log file path server-side so that no user-supplied path value
    # ever reaches filesystem operations in tail_logs.
    log_file = os.path.join(os.path.realpath(LOG_BASE_DIR), f"{agent_id}.log")

    agent = Agent(
        id=agent_id,
        system_user=data["system_user"],
        status=data.get("status", "stopped"),
        log_file=log_file,
        workdir=data.get("workdir"),
    )
    db.session.add(agent)
    db.session.commit()
    return jsonify(agent.to_dict()), 201


@app.route("/agents/<agent_id>/heartbeat", methods=["POST"])
def heartbeat(agent_id):
    """Receive a heartbeat from a running agent."""
    agent = db.session.get(Agent, agent_id)
    if agent is None:
        abort(404)
    agent.last_heartbeat = datetime.now(timezone.utc)
    agent.status = "running"
    _record_event(agent_id, "heartbeat")
    db.session.commit()
    return jsonify({"status": "ok"})


@app.route("/agents/<agent_id>/pause", methods=["POST"])
def pause_agent(agent_id):
    """Stop the agent's systemd service (halts execution until resumed)."""
    agent = db.session.get(Agent, agent_id)
    if agent is None:
        abort(404)
    _systemctl("stop", agent_id, agent.system_user)
    agent.status = "paused"
    _record_event(agent_id, "status_change", '{"new_status":"paused"}')
    db.session.commit()
    return jsonify({"status": "paused"})


@app.route("/agents/<agent_id>/resume", methods=["POST"])
def resume_agent(agent_id):
    """Restart the agent's systemd service."""
    agent = db.session.get(Agent, agent_id)
    if agent is None:
        abort(404)
    _systemctl("start", agent_id, agent.system_user)
    agent.status = "running"
    _record_event(agent_id, "status_change", '{"new_status":"running"}')
    db.session.commit()
    return jsonify({"status": "running"})


@app.route("/agents/<agent_id>/logs", methods=["GET"])
def tail_logs(agent_id):
    """Stream the last N lines from the agent's log file.

    The log file path is read from the database record (set server-side at
    registration time) rather than being derived from the URL parameter.
    This ensures no user-controlled data flows to filesystem operations.
    """
    agent = db.session.get(Agent, agent_id)
    if agent is None:
        abort(404)

    # Use the pre-stored log_file path (set server-side in register_agent).
    # Apply realpath + prefix check as a defence-in-depth measure.
    stored_path = agent.log_file
    if not stored_path:
        abort(404, description="No log file registered for this agent")

    log_base = os.path.realpath(LOG_BASE_DIR)
    resolved = os.path.realpath(stored_path)
    if not (resolved.startswith(log_base + os.sep) or resolved == log_base):
        abort(403, description="Log path is outside the permitted directory")

    lines = request.args.get("lines", 100, type=int)
    # Clamp to a sane range so callers cannot request negative or huge reads.
    lines = max(1, min(lines, 10_000))

    if not os.path.isfile(resolved):
        abort(404, description="Log file not found")

    def _generate():
        result = subprocess.run(
            ["tail", "-n", str(lines), resolved],
            capture_output=True,
            text=True,
            errors="replace",
        )
        yield result.stdout

    return Response(_generate(), mimetype="text/plain")


# ── Prompt API ────────────────────────────────────────────────────────────────


@app.route("/prompts", methods=["GET"])
def list_prompts():
    """Return all pending prompts across all agents."""
    pending_only = request.args.get("pending", "true").lower() == "true"
    query = Prompt.query
    if pending_only:
        query = query.filter_by(awaiting_input=True)
    prompts = query.order_by(Prompt.created_at.desc()).all()
    return jsonify([p.to_dict() for p in prompts])


@app.route("/prompts", methods=["POST"])
def create_prompt():
    """
    Called by agents when they encounter an unrecognised interactive prompt.
    The agent polls GET /prompts/<id> until awaiting_input becomes false.
    """
    data = request.get_json(force=True)
    required = {"agent_id", "prompt_key", "prompt_text"}
    if not required.issubset(data.keys()):
        abort(400, description=f"Missing required fields: {required - data.keys()}")

    if db.session.get(Agent, data["agent_id"]) is None:
        abort(404)

    prompt = Prompt(
        agent_id=data["agent_id"],
        prompt_key=data["prompt_key"],
        prompt_text=data["prompt_text"],
    )
    db.session.add(prompt)
    import json as _json
    _record_event(data["agent_id"], "prompt",
                  _json.dumps({"prompt_key": data["prompt_key"]}))
    db.session.commit()
    return jsonify(prompt.to_dict()), 201


@app.route("/prompts/<int:prompt_id>", methods=["GET"])
def get_prompt(prompt_id):
    prompt = db.session.get(Prompt, prompt_id)
    if prompt is None:
        abort(404)
    return jsonify(prompt.to_dict())


@app.route("/prompts/<int:prompt_id>/answer", methods=["POST"])
def answer_prompt(prompt_id):
    """
    Operator submits an answer for a pending prompt.
    The agent's prompt_handler.sh will pick this up on its next poll.
    """
    prompt = db.session.get(Prompt, prompt_id)
    if prompt is None:
        abort(404)
    data = request.get_json(force=True)

    if "answer" not in data:
        abort(400, description="'answer' field is required")

    prompt.answer = data["answer"]
    prompt.awaiting_input = False
    prompt.answered_at = datetime.now(timezone.utc)
    db.session.commit()
    return jsonify(prompt.to_dict())


# ── Events API ────────────────────────────────────────────────────────────────


@app.route("/agents/<agent_id>/events", methods=["GET"])
def list_events(agent_id):
    if db.session.get(Agent, agent_id) is None:
        abort(404)
    limit = request.args.get("limit", 50, type=int)
    events = (
        Event.query.filter_by(agent_id=agent_id)
        .order_by(Event.created_at.desc())
        .limit(limit)
        .all()
    )
    return jsonify([e.to_dict() for e in events])


# ── Helpers ───────────────────────────────────────────────────────────────────

import re as _re

_SAFE_ID_PATTERN = _re.compile(r"^[A-Za-z0-9_-]+$")


def _safe_agent_id(agent_id: str) -> str:
    """Return agent_id if it contains only safe characters, else abort(400).

    Ensures the value can be used as a filename component without risk of
    path traversal (e.g. ``../etc/passwd``).
    """
    if not _SAFE_ID_PATTERN.match(agent_id):
        abort(400, description="agent_id contains invalid characters")
    return agent_id


def _systemctl(action: str, agent_id: str, system_user: str) -> None:
    """Run a systemctl --user command for the named agent service.

    Each agent runs as its own Linux user, so the command is executed via
    ``sudo -u <system_user>`` with the correct XDG_RUNTIME_DIR so that
    systemd's user instance for that account is targeted.
    """
    import pwd as _pwd
    service = f"agent@{agent_id}"
    try:
        uid = _pwd.getpwnam(system_user).pw_uid
    except KeyError:
        app.logger.warning("System user %s not found; cannot run systemctl", system_user)
        return
    xdg_runtime_dir = f"/run/user/{uid}"
    result = subprocess.run(
        [
            "sudo", "-u", system_user,
            "env", f"XDG_RUNTIME_DIR={xdg_runtime_dir}",
            "systemctl", "--user", action, service,
        ],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        app.logger.warning(
            "systemctl %s %s failed: %s", action, service, result.stderr.strip()
        )


def _record_event(agent_id: str, event_type: str, payload: str = None) -> None:
    event = Event(agent_id=agent_id, event_type=event_type, payload=payload)
    db.session.add(event)


# ── Entry point ───────────────────────────────────────────────────────────────

if __name__ == "__main__":
    init_db()
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", 8080)), debug=False)
