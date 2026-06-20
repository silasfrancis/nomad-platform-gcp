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

# Gemini API key — injected by Vault at runtime via Nomad template stanza
GEMINI_API_KEY: str = _require("GEMINI_API_KEY")

# Slack incoming webhook URL
SLACK_WEBHOOK_URL: str = _require("SLACK_WEBHOOK_URL")

# ── Optional with sensible defaults ───────────────────────────────────────────

# How often the control loop polls Nomad (seconds)
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

# Gemini model to use
GEMINI_MODEL: str = _optional("GEMINI_MODEL", "gemini-1.5-flash")

# Environment label for alerts and logs (e.g. dev, prod)
ENVIRONMENT: str = _optional("ENVIRONMENT", "unknown")

# Namespaces to watch — comma-separated, empty means all
WATCH_NAMESPACES: list[str] = [
    ns.strip()
    for ns in _optional("WATCH_NAMESPACES", "").split(",")
    if ns.strip()
]
