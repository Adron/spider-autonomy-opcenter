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

    if db.session.get(Agent, data["id"]):
        abort(409, description=f"Agent '{data['id']}' already registered")

    agent = Agent(
        id=data["id"],
        system_user=data["system_user"],
        status=data.get("status", "stopped"),
        log_file=data.get("log_file"),
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
    """Send SIGSTOP to the agent's systemd service (pauses execution)."""
    agent = db.session.get(Agent, agent_id)
    if agent is None:
        abort(404)
    _systemctl("stop", agent_id)
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
    _systemctl("start", agent_id)
    agent.status = "running"
    _record_event(agent_id, "status_change", '{"new_status":"running"}')
    db.session.commit()
    return jsonify({"status": "running"})


@app.route("/agents/<agent_id>/logs", methods=["GET"])
def tail_logs(agent_id):
    """Stream the last N lines from the agent's log file."""
    agent = db.session.get(Agent, agent_id)
    if agent is None:
        abort(404)
    lines = request.args.get("lines", 100, type=int)
    log_path = agent.log_file or os.path.join(LOG_BASE_DIR, f"{agent_id}.log")

    if not os.path.isfile(log_path):
        abort(404, description=f"Log file not found: {log_path}")

    def _generate():
        with open(log_path, "r", encoding="utf-8", errors="replace") as fh:
            all_lines = fh.readlines()
        yield from all_lines[-lines:]

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
    _record_event(data["agent_id"], "prompt", f'{{"prompt_key":"{data["prompt_key"]}"}}')
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


def _systemctl(action: str, agent_id: str) -> None:
    """Run a systemctl --user command for the named agent service."""
    service = f"agent@{agent_id}"
    result = subprocess.run(
        ["systemctl", "--user", action, service],
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
