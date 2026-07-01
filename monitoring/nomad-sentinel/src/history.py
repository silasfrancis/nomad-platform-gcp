"""
history.py
Persists a record of every anomaly the agent detects, what Gemini decided,
and what happened as a result, to a PostgreSQL table (agent_anomalies).

This is intentionally a thin, isolated module: persistence is an
enhancement to the agent's existing detect/analyze/alert/remediate loop,
never a dependency of it. Every function here is built to fail safely —
a database outage logs a warning and the control loop continues exactly
as it did before this module existed. Nothing in main.py's decision logic
should ever be gated on a successful write here.

Uses the same PostgreSQL instance metrics-api connects to, in a separate
table, reached via HISTORY_DATABASE_URL. Locally that's a static
connection string from .env. This table is platform observability data,
not a workload requiring per-allocation dynamic credentials the way
metrics-api's own connection does — so it intentionally does not go
through Vault's database secrets engine the way metrics-api's connection
eventually will. A single longer-lived service account credential is the
right shape for a service like this.
"""

import json
from datetime import datetime, timezone
from typing import Optional

import psycopg2
import structlog

import config
from config import HISTORY_DATABASE_URL, ENVIRONMENT

log = structlog.get_logger()

_ENABLED = bool(HISTORY_DATABASE_URL)
_schema_ready = False

if not _ENABLED:
    log.warning(
        "history_disabled",
        reason="HISTORY_DATABASE_URL not set — anomaly history will not be persisted",
    )

_CREATE_TABLE_SQL = """
CREATE TABLE IF NOT EXISTS agent_anomalies (
    id                  SERIAL PRIMARY KEY,
    environment         TEXT NOT NULL,
    detected_at         TIMESTAMPTZ NOT NULL,
    job_id              TEXT NOT NULL,
    alloc_id            TEXT NOT NULL,
    task                TEXT NOT NULL,
    namespace           TEXT NOT NULL,
    anomaly_type        TEXT NOT NULL,
    restarts            INTEGER NOT NULL DEFAULT 0,
    likely_cause        TEXT,
    severity            TEXT,
    confidence          REAL,
    suggested_action    TEXT,
    remediation_mode    TEXT NOT NULL,
    outcome             TEXT NOT NULL,
    outcome_detail      JSONB
);
"""

_CREATE_INDEX_SQL = """
CREATE INDEX IF NOT EXISTS idx_agent_anomalies_job_detected
    ON agent_anomalies (job_id, detected_at DESC);
"""

_INSERT_SQL = """
INSERT INTO agent_anomalies (
    environment, detected_at, job_id, alloc_id, task, namespace,
    anomaly_type, restarts, likely_cause, severity, confidence,
    suggested_action, remediation_mode, outcome, outcome_detail
) VALUES (
    %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s
);
"""

# Valid outcome values — kept as a Python set rather than a DB CHECK
# constraint so adding a new outcome type later doesn't require a
# migration, just an updated set here.
VALID_OUTCOMES = {
    "alerted_only",
    "proposed",
    "remediated",
    "remediation_failed",
    "escalated",
    "skipped_cooldown",
}


def _get_connection():
    return psycopg2.connect(HISTORY_DATABASE_URL)


def ensure_schema() -> None:
    """
    Creates the agent_anomalies table and its index if they don't already
    exist. Called once at agent startup. Safe to call repeatedly — both
    statements use IF NOT EXISTS. Failure here disables history for the
    rest of the process lifetime rather than retrying on every cycle.
    """
    global _schema_ready

    if not _ENABLED:
        return

    try:
        conn = _get_connection()
        try:
            cur = conn.cursor()
            cur.execute(_CREATE_TABLE_SQL)
            cur.execute(_CREATE_INDEX_SQL)
            conn.commit()
            cur.close()
            _schema_ready = True
            log.info("history_schema_ready")
        finally:
            conn.close()
    except Exception as e:
        log.error("history_schema_setup_failed", error=str(e))
        _schema_ready = False


def record(
    anomaly: dict,
    analysis: Optional[dict],
    outcome: str,
    outcome_detail: Optional[dict] = None,
) -> None:
    """
    Persists one anomaly detection + outcome row. Never raises — any
    failure here is logged and swallowed so the control loop is never
    affected by a database problem.

    outcome must be one of VALID_OUTCOMES. analysis may be None only for
    the "skipped_cooldown" outcome, where Gemini was never called.
    """
    if not _ENABLED:
        return

    if not _schema_ready:
        log.debug("history_write_skipped_schema_not_ready", job=anomaly.get("job_id"))
        return

    if outcome not in VALID_OUTCOMES:
        log.warning("history_invalid_outcome", outcome=outcome, job=anomaly.get("job_id"))
        outcome = "alerted_only"

    analysis = analysis or {}

    try:
        conn = _get_connection()
        try:
            cur = conn.cursor()
            cur.execute(
                _INSERT_SQL,
                (
                    ENVIRONMENT,
                    datetime.fromtimestamp(
                        anomaly.get("detected_at", datetime.now(timezone.utc).timestamp()),
                        tz=timezone.utc,
                    ),
                    anomaly.get("job_id", "unknown"),
                    anomaly.get("alloc_id", "unknown"),
                    anomaly.get("task", "unknown"),
                    anomaly.get("namespace", "default"),
                    anomaly.get("anomaly_type", "unknown"),
                    anomaly.get("restarts", 0),
                    analysis.get("likely_cause"),
                    analysis.get("severity"),
                    analysis.get("confidence"),
                    analysis.get("suggested_action"),
                    _remediation_mode_for_row(),
                    outcome,
                    json.dumps(outcome_detail) if outcome_detail else None,
                ),
            )
            conn.commit()
            cur.close()
        finally:
            conn.close()

        log.debug("history_recorded", job=anomaly.get("job_id"), outcome=outcome)

    except Exception as e:
        log.error("history_write_failed", error=str(e), job=anomaly.get("job_id"))


def _remediation_mode_for_row() -> str:
    return config.REMEDIATION_MODE
