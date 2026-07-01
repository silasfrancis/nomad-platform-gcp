"""
conftest.py
Sets DATABASE_URL before main is imported (Flask app construction doesn't
require it, but keeps tests deterministic), adds the service root to the
path, and provides a reusable Flask test client fixture.
"""

import os
import sys
from pathlib import Path

import pytest

SERVICE_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SERVICE_ROOT))

os.environ.setdefault(
    "DATABASE_URL", "postgresql://test_user:test_pass@localhost:5432/testdb"
)

import main  # noqa: E402


@pytest.fixture
def client():
    main.app.config["TESTING"] = True
    # Reset module-level counters between tests so they don't leak state
    main._request_count = 0
    main._db_query_durations = []
    with main.app.test_client() as c:
        yield c
