"""
main.py
metrics-api — a small custom platform-engineering demo service.

Purpose: Online Boutique has no real database dependency, so it can't
demonstrate Vault's dynamic database secrets engine. This service exists
purely to prove that lifecycle end-to-end: it connects to PostgreSQL using
credentials supplied via DATABASE_URL, exposes Prometheus-format metrics,
and provides a /db-check endpoint that proves the connection is alive.

Locally (this Docker Compose), DATABASE_URL is built from static env vars
in .env — there is no Vault yet. Once this moves to Nomad, DATABASE_URL's
components will instead be templated in by Vault's database secrets
engine with a short TTL, auto-rotated. The application code does not
change between these two states — it always just reads DATABASE_URL.

Important: DATABASE_URL is read fresh from the environment on every
connection attempt, not cached at import time. This matters once Vault
is wired in — Nomad's template stanza rewrites the env file in place when
a credential rotates, and a stale cached value would silently keep using
an expired (and eventually revoked) database role.
"""

import os
import time
from datetime import datetime, timezone

import psycopg2
from flask import Flask, jsonify, Response

app = Flask(__name__)

# Simple in-process counters for the /metrics endpoint. A real deployment
# would use prometheus_client, but the dependency is intentionally kept
# minimal here since this service only needs to prove the concept.
_request_count = 0
_db_query_durations: list[float] = []


def get_database_url() -> str:
    """
    Reads DATABASE_URL fresh from the environment on every call rather
    than caching it at import time. See module docstring for why this
    matters once Vault rotation is wired in.
    """
    url = os.environ.get("DATABASE_URL")
    if not url:
        raise RuntimeError("DATABASE_URL is not set")
    return url


def get_connection():
    """Thin wrapper around psycopg2.connect so tests can mock a single
    well-defined seam instead of patching the psycopg2 module directly."""
    return psycopg2.connect(get_database_url())


@app.before_request
def _count_request():
    global _request_count
    _request_count += 1


@app.route("/health")
def health():
    """Used by Compose/Nomad health checks. Does not touch the database —
    a DB outage should not make this service look unhealthy to the
    orchestrator, since /db-check exists specifically to surface that."""
    return jsonify(status="ok"), 200


@app.route("/db-check")
def db_check():
    """
    Connects to PostgreSQL using whatever credentials DATABASE_URL
    currently holds, runs a trivial query, and reports back the
    connected username and (if available) the role's password
    expiry — proving the credentials in use are live and, once Vault
    is wired in, rotating.
    """
    start = time.monotonic()
    conn = None
    try:
        conn = get_connection()
        cur = conn.cursor()
        cur.execute("SELECT current_user, version();")
        current_user, version = cur.fetchone()

        # VALID UNTIL is only meaningful for Vault-issued dynamic roles.
        # With static local creds this will simply return NULL.
        cur.execute(
            "SELECT rolvaliduntil FROM pg_roles WHERE rolname = %s;",
            (current_user,),
        )
        row = cur.fetchone()
        valid_until = row[0].isoformat() if row and row[0] else None

        cur.close()

        duration = time.monotonic() - start
        _db_query_durations.append(duration)

        return jsonify(
            status="ok",
            connected_as=current_user,
            credential_valid_until=valid_until,
            postgres_version=version,
            query_duration_seconds=round(duration, 4),
            checked_at=datetime.now(timezone.utc).isoformat(),
        ), 200

    except Exception as e:
        return jsonify(status="error", error=str(e)), 503

    finally:
        # Always release the connection, even on failure — left-open
        # connections on a short-TTL Vault-issued role exhaust the
        # role's connection limit quickly during rotation testing.
        if conn is not None:
            conn.close()


@app.route("/metrics")
def metrics():
    """Minimal Prometheus-format exposition — enough for local testing
    and for Prometheus to scrape once this moves to Nomad."""
    avg_duration = (
        sum(_db_query_durations) / len(_db_query_durations)
        if _db_query_durations
        else 0.0
    )
    body = (
        "# HELP metrics_api_requests_total Total HTTP requests received\n"
        "# TYPE metrics_api_requests_total counter\n"
        f"metrics_api_requests_total {_request_count}\n"
        "# HELP metrics_api_db_query_duration_seconds Average DB query duration\n"
        "# TYPE metrics_api_db_query_duration_seconds gauge\n"
        f"metrics_api_db_query_duration_seconds {avg_duration:.4f}\n"
    )
    return Response(body, mimetype="text/plain")


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "8080"))
    app.run(host="0.0.0.0", port=port)
