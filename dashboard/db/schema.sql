-- schema.sql — State database for the Spider Autonomy OpCenter dashboard.
--
-- Apply with:
--   sqlite3 opcenter.db < schema.sql
-- or against PostgreSQL:
--   psql -d opcenter -f schema.sql
--
-- The dashboard application uses this schema to track agent lifecycle,
-- pending prompts, and operational events.

-- ── Agents ────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS agents (
    id              TEXT        PRIMARY KEY,
    system_user     TEXT        NOT NULL,
    status          TEXT        NOT NULL DEFAULT 'stopped'
                                CHECK (status IN ('running','paused','failed','stopped')),
    last_checkpoint TEXT,
    last_heartbeat  TIMESTAMP,
    log_file        TEXT,
    workdir         TEXT,
    created_at      TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at      TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- ── Prompts ───────────────────────────────────────────────────────────────────
-- Pending prompts that require operator input before the agent can continue.

CREATE TABLE IF NOT EXISTS prompts (
    id              INTEGER     PRIMARY KEY AUTOINCREMENT,
    agent_id        TEXT        NOT NULL REFERENCES agents(id) ON DELETE CASCADE,
    prompt_key      TEXT        NOT NULL,
    prompt_text     TEXT        NOT NULL,
    awaiting_input  BOOLEAN     NOT NULL DEFAULT 1,
    answer          TEXT,
    created_at      TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    answered_at     TIMESTAMP
);

-- ── Events ────────────────────────────────────────────────────────────────────
-- Operational audit log: status transitions, errors, restarts, etc.

CREATE TABLE IF NOT EXISTS events (
    id          INTEGER     PRIMARY KEY AUTOINCREMENT,
    agent_id    TEXT        NOT NULL REFERENCES agents(id) ON DELETE CASCADE,
    event_type  TEXT        NOT NULL,   -- heartbeat | status_change | error | prompt
    payload     TEXT,                   -- JSON blob
    created_at  TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- ── Defaults ──────────────────────────────────────────────────────────────────
-- Operator-supplied default answers, mirrored from YAML into the DB for the
-- dashboard UI to manage without touching files directly.

CREATE TABLE IF NOT EXISTS defaults (
    agent_id    TEXT        NOT NULL REFERENCES agents(id) ON DELETE CASCADE,
    prompt_key  TEXT        NOT NULL,
    answer      TEXT        NOT NULL,
    updated_at  TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (agent_id, prompt_key)
);

-- ── Indexes ───────────────────────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_prompts_agent_awaiting
    ON prompts (agent_id, awaiting_input);

CREATE INDEX IF NOT EXISTS idx_events_agent_created
    ON events (agent_id, created_at);

-- ── Trigger: keep agents.updated_at current ───────────────────────────────────
CREATE TRIGGER IF NOT EXISTS agents_updated_at
AFTER UPDATE ON agents
FOR EACH ROW
BEGIN
    UPDATE agents SET updated_at = CURRENT_TIMESTAMP WHERE id = NEW.id;
END;
