"""
config.py
All configuration is loaded from environment variables.
No defaults are hardcoded for secrets — the agent will refuse to start
if required variables are missing.
"""

import os
import sys


def _require(name: str) -> str:
    """Load a required environment variable or exit with a clear error."""
    value = os.environ.get(name)
    if not value:
        print(f"[FATAL] Required environment variable '{name}' is not set.", flush=True)
        sys.exit(1)
    return value


def _optional(name: str, default: str) -> str:
    return os.environ.get(name, default)


# ── Required ──────────────────────────────────────────────────────────────────

# Nomad API address — e.g. http://10.0.1.10:4646
NOMAD_ADDR: str = _require("NOMAD_ADDR")

# Nomad ACL token — scoped read/write token for the agent
NOMAD_TOKEN: str = _require("NOMAD_TOKEN")

# TLS trust/identity for the Nomad API connection.
# Unlike the Go-based Nomad/Consul/Vault CLIs, the `requests` library does
# NOT read these automatically — they must be wired in explicitly wherever
# the HTTP client is built (see detector.py's _build_session()).
#
# NOMAD_CACERT         — path to the CA bundle that signed the Nomad
#                         server's cert. Optional: if unset, falls back to
#                         the system/certifi trust store.
# NOMAD_CLIENT_CERT /
# NOMAD_CLIENT_KEY     — optional mTLS client identity, if the cluster
#                         requires verify_https_client.
# NOMAD_TLS_SERVER_NAME — hostname to verify the server cert against, used
#                         when NOMAD_ADDR is a bare IP (e.g. resolved via
#                         Consul) rather than the hostname the cert was
#                         actually issued for. Optional: if unset, the
#                         hostname in NOMAD_ADDR itself is used, which will
#                         fail verification when NOMAD_ADDR is an IP and
#                         the cert has no matching IP SAN.
NOMAD_CACERT: str = _optional("NOMAD_CACERT", "")
NOMAD_CLIENT_CERT: str = _optional("NOMAD_CLIENT_CERT", "")
NOMAD_CLIENT_KEY: str = _optional("NOMAD_CLIENT_KEY", "")
NOMAD_TLS_SERVER_NAME: str = _optional("NOMAD_TLS_SERVER_NAME", "")

# Gemini API key — injected by Vault at runtime via Nomad template stanza
GEMINI_API_KEY: str = _require("GEMINI_API_KEY")

# Slack incoming webhook URL
SLACK_WEBHOOK_URL: str = _require("SLACK_WEBHOOK_URL")

# ── Optional with sensible defaults ───────────────────────────────────────────

# How often the anomaly detection loop polls Nomad (seconds)
POLL_INTERVAL_SECONDS: int = int(_optional("POLL_INTERVAL_SECONDS", "30"))

# Number of restarts before an allocation is considered looping
RESTART_THRESHOLD: int = int(_optional("RESTART_THRESHOLD", "3"))

# Seconds an allocation can stay in 'pending' before flagged
PENDING_THRESHOLD_SECONDS: int = int(_optional("PENDING_THRESHOLD_SECONDS", "120"))

# Seconds an allocation can stay in 'starting' before flagged
STARTING_THRESHOLD_SECONDS: int = int(_optional("STARTING_THRESHOLD_SECONDS", "180"))

# Number of log lines to retrieve per anomalous task
LOG_TAIL_LINES: int = int(_optional("LOG_TAIL_LINES", "200"))

# Minimum Gemini confidence score to trigger auto-remediation (0.0 – 1.0)
REMEDIATION_CONFIDENCE_THRESHOLD: float = float(
    _optional("REMEDIATION_CONFIDENCE_THRESHOLD", "0.8")
)

# Maximum remediation attempts per job before escalating to human-only alert
MAX_REMEDIATION_ATTEMPTS: int = int(_optional("MAX_REMEDIATION_ATTEMPTS", "3"))

# Cooldown period after a remediation attempt (seconds)
COOLDOWN_SECONDS: int = int(_optional("COOLDOWN_SECONDS", "300"))

# Separate from COOLDOWN_SECONDS above (which only governs repeat
# *remediation* attempts). Without this, an anomaly that never clears the
# remediation confidence/severity bar takes the alert-only path every
# single poll cycle forever, with nothing to stop it — re-running the full
# Gemini analysis every POLL_INTERVAL_SECONDS (30s default) for as long as
# the underlying condition persists. This cooldown is keyed per
# (job_id, anomaly_type) so a genuinely new anomaly on the same job is
# never suppressed by an unrelated one still cooling down.
ANOMALY_ALERT_COOLDOWN_SECONDS: int = int(_optional("ANOMALY_ALERT_COOLDOWN_SECONDS", "300"))

# Gemini model to use
GEMINI_MODEL: str = _optional("GEMINI_MODEL", "gemini-3.5-flash-lite")

# Environment label for alerts and logs (e.g. dev, prod)
ENVIRONMENT: str = _optional("ENVIRONMENT", "unknown")

# Remediation mode — controls whether the agent is allowed to act on its own:
#   "execute" — agent calls the Nomad API and performs the remediation (autonomous)
#   "propose" — agent builds the same decision and Slack alert, but takes no
#               action against Nomad. The alert clearly states what the agent
#               WOULD have done, so a human can act on it manually.
#
# No default is assumed silently — this must be set explicitly per
# environment in the Nomad job spec (REMEDIATION_MODE=execute in dev,
# REMEDIATION_MODE=propose in prod). This is deliberate: the blast radius
# of autonomous remediation should never depend on an implicit default.
_RAW_REMEDIATION_MODE = _require("REMEDIATION_MODE").strip().lower()
if _RAW_REMEDIATION_MODE not in ("execute", "propose"):
    print(
        f"[FATAL] REMEDIATION_MODE must be 'execute' or 'propose', "
        f"got '{_RAW_REMEDIATION_MODE}'.",
        flush=True,
    )
    sys.exit(1)
REMEDIATION_MODE: str = _RAW_REMEDIATION_MODE

# Namespaces to watch — comma-separated, empty means all
WATCH_NAMESPACES: list[str] = [
    ns.strip()
    for ns in _optional("WATCH_NAMESPACES", "").split(",")
    if ns.strip()
]

# Optional: PostgreSQL connection string for persisting anomaly history.
# Same database instance metrics-api uses, different table
# (agent_anomalies) — see history.py. If unset, the agent runs exactly as
# before with no persistence; this was never a hard dependency of the
# monitoring loop and a DB outage must never block detection, analysis,
# alerting, or remediation.
HISTORY_DATABASE_URL: str = _optional("HISTORY_DATABASE_URL", "")

# ── HTTP server ───────────────────────────────────────────────────────────────

# Port for the built-in Flask HTTP server.
# GET /health — liveness probe (Consul health check, Nomad health gate).
# GET /summary — on-demand cluster health summary (calls Nomad + Gemini).
# Must match the port registered in the Nomad job spec service stanza
# and the Prometheus scrape config.
HTTP_PORT: int = int(_optional("HTTP_PORT", "8090"))

# ── Scheduled summary ─────────────────────────────────────────────────────────

# How often (in hours) to post a proactive cluster health summary to Slack.
# This is independent of the anomaly detection loop — it fires whether or
# not anything is wrong.
# Set to 0 to disable scheduled summaries entirely.
SUMMARY_INTERVAL_HOURS: float = float(_optional("SUMMARY_INTERVAL_HOURS", "6.0"))
