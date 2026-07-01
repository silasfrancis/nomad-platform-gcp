"""
conftest.py
Sets required environment variables before any src module is imported,
since config.py validates them at import time via _require().
Adds src/ to the path so tests can import modules directly.
"""

import os
import sys
from pathlib import Path

SRC_PATH = Path(__file__).resolve().parent.parent / "src"
sys.path.insert(0, str(SRC_PATH))

os.environ.setdefault("NOMAD_ADDR", "http://localhost:4646")
os.environ.setdefault("NOMAD_TOKEN", "test-nomad-token")
os.environ.setdefault("GEMINI_API_KEY", "test-gemini-key")
os.environ.setdefault("SLACK_WEBHOOK_URL", "https://hooks.slack.com/services/TEST/TEST/TEST")
os.environ.setdefault("ENVIRONMENT", "test")
os.environ.setdefault("REMEDIATION_MODE", "execute")
os.environ.setdefault("HTTP_PORT", "8090")
os.environ.setdefault("SUMMARY_INTERVAL_HOURS", "6.0")
