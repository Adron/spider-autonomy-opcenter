"""
test_app.py — Pytest tests for the Spider Autonomy OpCenter dashboard.

Run from the dashboard/ directory:
    pip install -r requirements.txt pytest
    pytest tests/ -v
"""

import json
import pytest

import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from app import app as flask_app, db, init_db


# ── Fixtures ─────────────────────────────────────────────────────────────────


@pytest.fixture()
def app():
    flask_app.config.update(
        {
            "TESTING": True,
            "SQLALCHEMY_DATABASE_URI": "sqlite:///:memory:",
        }
    )
    with flask_app.app_context():
        db.create_all()
        yield flask_app
        db.session.remove()
        db.drop_all()


@pytest.fixture()
def client(app):
    return app.test_client()


# ── Helper ────────────────────────────────────────────────────────────────────


def _register_agent(client, agent_id="test_agent", system_user="agent_test"):
    return client.post(
        "/agents",
        data=json.dumps({"id": agent_id, "system_user": system_user}),
        content_type="application/json",
    )


# ── Agent registration ────────────────────────────────────────────────────────


def test_register_agent(client):
    res = _register_agent(client)
    assert res.status_code == 201
    data = res.get_json()
    assert data["id"] == "test_agent"
    assert data["system_user"] == "agent_test"
    assert data["status"] == "stopped"


def test_register_agent_duplicate(client):
    _register_agent(client)
    res = _register_agent(client)
    assert res.status_code == 409


def test_register_agent_missing_fields(client):
    res = client.post(
        "/agents",
        data=json.dumps({"id": "x"}),
        content_type="application/json",
    )
    assert res.status_code == 400


def test_list_agents_empty(client):
    res = client.get("/agents")
    assert res.status_code == 200
    assert res.get_json() == []


def test_list_agents(client):
    _register_agent(client, "a1", "user_a1")
    _register_agent(client, "a2", "user_a2")
    res = client.get("/agents")
    assert res.status_code == 200
    ids = {a["id"] for a in res.get_json()}
    assert ids == {"a1", "a2"}


def test_get_agent(client):
    _register_agent(client)
    res = client.get("/agents/test_agent")
    assert res.status_code == 200
    assert res.get_json()["id"] == "test_agent"


def test_get_agent_not_found(client):
    res = client.get("/agents/nonexistent")
    assert res.status_code == 404


# ── Heartbeat ─────────────────────────────────────────────────────────────────


def test_heartbeat(client):
    _register_agent(client)
    res = client.post("/agents/test_agent/heartbeat")
    assert res.status_code == 200
    assert res.get_json()["status"] == "ok"

    # Agent status should flip to 'running'
    agent = client.get("/agents/test_agent").get_json()
    assert agent["status"] == "running"
    assert agent["last_heartbeat"] is not None


def test_heartbeat_unknown_agent(client):
    res = client.post("/agents/ghost/heartbeat")
    assert res.status_code == 404


# ── Prompts ───────────────────────────────────────────────────────────────────


def _create_prompt(client, agent_id="test_agent", key="confirm_push", text="Push?"):
    return client.post(
        "/prompts",
        data=json.dumps(
            {"agent_id": agent_id, "prompt_key": key, "prompt_text": text}
        ),
        content_type="application/json",
    )


def test_create_prompt(client):
    _register_agent(client)
    res = _create_prompt(client)
    assert res.status_code == 201
    data = res.get_json()
    assert data["awaiting_input"] is True
    assert data["answer"] is None


def test_create_prompt_missing_fields(client):
    _register_agent(client)
    res = client.post(
        "/prompts",
        data=json.dumps({"agent_id": "test_agent"}),
        content_type="application/json",
    )
    assert res.status_code == 400


def test_create_prompt_unknown_agent(client):
    res = _create_prompt(client, agent_id="ghost")
    assert res.status_code == 404


def test_list_prompts_pending_only(client):
    _register_agent(client)
    r1 = _create_prompt(client, key="key1")
    r2 = _create_prompt(client, key="key2")
    pid1 = r1.get_json()["id"]
    pid2 = r2.get_json()["id"]

    # Answer one prompt.
    client.post(
        f"/prompts/{pid1}/answer",
        data=json.dumps({"answer": "yes"}),
        content_type="application/json",
    )

    res = client.get("/prompts?pending=true")
    ids = [p["id"] for p in res.get_json()]
    assert pid2 in ids
    assert pid1 not in ids


def test_answer_prompt(client):
    _register_agent(client)
    prompt_id = _create_prompt(client).get_json()["id"]

    res = client.post(
        f"/prompts/{prompt_id}/answer",
        data=json.dumps({"answer": "yes"}),
        content_type="application/json",
    )
    assert res.status_code == 200
    data = res.get_json()
    assert data["answer"] == "yes"
    assert data["awaiting_input"] is False
    assert data["answered_at"] is not None


def test_answer_prompt_missing_field(client):
    _register_agent(client)
    prompt_id = _create_prompt(client).get_json()["id"]
    res = client.post(
        f"/prompts/{prompt_id}/answer",
        data=json.dumps({}),
        content_type="application/json",
    )
    assert res.status_code == 400


# ── Events ────────────────────────────────────────────────────────────────────


def test_events_created_on_heartbeat(client):
    _register_agent(client)
    client.post("/agents/test_agent/heartbeat")
    res = client.get("/agents/test_agent/events")
    assert res.status_code == 200
    events = res.get_json()
    assert any(e["event_type"] == "heartbeat" for e in events)


def test_events_created_on_prompt(client):
    _register_agent(client)
    _create_prompt(client)
    res = client.get("/agents/test_agent/events")
    events = res.get_json()
    assert any(e["event_type"] == "prompt" for e in events)


# ── Index page ────────────────────────────────────────────────────────────────


def test_index_returns_html(client):
    res = client.get("/")
    assert res.status_code == 200
    assert b"Spider Autonomy" in res.data
