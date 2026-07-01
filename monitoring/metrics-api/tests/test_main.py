"""
test_main.py
Tests for metrics-api. The real PostgreSQL connection (psycopg2.connect)
is mocked throughout — these tests never require an actual database.
"""

import os
from datetime import datetime, timezone
from unittest.mock import MagicMock, patch

import pytest

import main


class TestHealth:
    def test_health_returns_200_ok(self, client):
        resp = client.get("/health")
        assert resp.status_code == 200
        assert resp.get_json() == {"status": "ok"}

    def test_health_does_not_touch_database(self, client):
        """A DB outage should never make /health fail — that's what
        /db-check exists to surface instead."""
        with patch.object(main, "get_connection") as mock_conn:
            resp = client.get("/health")
            assert resp.status_code == 200
            mock_conn.assert_not_called()


class TestGetDatabaseUrl:
    def test_returns_value_from_environment(self):
        with patch.dict(os.environ, {"DATABASE_URL": "postgresql://a:b@host/db"}):
            assert main.get_database_url() == "postgresql://a:b@host/db"

    def test_raises_when_unset(self):
        with patch.dict(os.environ, {}, clear=True):
            with pytest.raises(RuntimeError, match="DATABASE_URL is not set"):
                main.get_database_url()

    def test_reads_fresh_value_each_call_not_cached(self):
        """
        This is the behaviour that matters once Vault rotation is wired
        in: Nomad's template stanza rewrites DATABASE_URL in the env file
        when a credential rotates, and the app must pick up the new value
        on the next connection attempt rather than keep using a cached
        (and eventually revoked) one.
        """
        with patch.dict(os.environ, {"DATABASE_URL": "postgresql://first:pw@host/db"}):
            assert main.get_database_url() == "postgresql://first:pw@host/db"

        with patch.dict(os.environ, {"DATABASE_URL": "postgresql://rotated:pw2@host/db"}):
            assert main.get_database_url() == "postgresql://rotated:pw2@host/db"


class TestGetConnection:
    def test_calls_psycopg2_connect_with_current_database_url(self):
        with patch.object(main, "get_database_url", return_value="postgresql://x:y@h/d"):
            with patch("main.psycopg2.connect") as mock_connect:
                main.get_connection()
                mock_connect.assert_called_once_with("postgresql://x:y@h/d")


def _mock_db_cursor(current_user="app_user", version="PostgreSQL 16.1", valid_until=None):
    """
    Builds a mock cursor whose fetchone() returns appropriate results for
    the two queries db_check() runs in sequence: first the
    (current_user, version) query, then the rolvaliduntil lookup.
    """
    cursor = MagicMock()
    cursor.fetchone.side_effect = [
        (current_user, version),
        (valid_until,) if valid_until is not None else (None,),
    ]
    return cursor


class TestDbCheck:
    def test_returns_200_with_expected_fields_on_success(self, client):
        mock_cursor = _mock_db_cursor(current_user="app_user", version="PostgreSQL 16.1")
        mock_conn = MagicMock()
        mock_conn.cursor.return_value = mock_cursor

        with patch.object(main, "get_connection", return_value=mock_conn):
            resp = client.get("/db-check")

        assert resp.status_code == 200
        body = resp.get_json()
        assert body["status"] == "ok"
        assert body["connected_as"] == "app_user"
        assert body["postgres_version"] == "PostgreSQL 16.1"
        assert "query_duration_seconds" in body
        assert "checked_at" in body

    def test_credential_valid_until_null_for_static_creds(self, client):
        """With a static (non-Vault) local user, rolvaliduntil is NULL —
        the response should reflect that honestly rather than fabricate
        a value."""
        mock_cursor = _mock_db_cursor(valid_until=None)
        mock_conn = MagicMock()
        mock_conn.cursor.return_value = mock_cursor

        with patch.object(main, "get_connection", return_value=mock_conn):
            resp = client.get("/db-check")

        assert resp.get_json()["credential_valid_until"] is None

    def test_credential_valid_until_populated_for_dynamic_vault_role(self, client):
        """Once Vault issues a dynamic role with a TTL, rolvaliduntil is
        set — this is the actual proof-of-rotation the endpoint exists
        to provide."""
        expiry = datetime(2026, 6, 21, 12, 0, 0, tzinfo=timezone.utc)
        mock_cursor = _mock_db_cursor(current_user="v-token-abc123", valid_until=expiry)
        mock_conn = MagicMock()
        mock_conn.cursor.return_value = mock_cursor

        with patch.object(main, "get_connection", return_value=mock_conn):
            resp = client.get("/db-check")

        body = resp.get_json()
        assert body["connected_as"] == "v-token-abc123"
        assert body["credential_valid_until"] == expiry.isoformat()

    def test_returns_503_on_connection_failure(self, client):
        with patch.object(main, "get_connection", side_effect=Exception("connection refused")):
            resp = client.get("/db-check")

        assert resp.status_code == 503
        body = resp.get_json()
        assert body["status"] == "error"
        assert "connection refused" in body["error"]

    def test_returns_503_on_query_failure(self, client):
        mock_cursor = MagicMock()
        mock_cursor.execute.side_effect = Exception("relation does not exist")
        mock_conn = MagicMock()
        mock_conn.cursor.return_value = mock_cursor

        with patch.object(main, "get_connection", return_value=mock_conn):
            resp = client.get("/db-check")

        assert resp.status_code == 503

    def test_connection_closed_on_success(self, client):
        mock_cursor = _mock_db_cursor()
        mock_conn = MagicMock()
        mock_conn.cursor.return_value = mock_cursor

        with patch.object(main, "get_connection", return_value=mock_conn):
            client.get("/db-check")

        mock_conn.close.assert_called_once()

    def test_connection_closed_even_on_query_failure(self, client):
        """A short-TTL Vault role has a connection limit — leaking
        connections on failure would exhaust it quickly during rotation
        testing, so the close must happen in a finally block."""
        mock_cursor = MagicMock()
        mock_cursor.execute.side_effect = Exception("boom")
        mock_conn = MagicMock()
        mock_conn.cursor.return_value = mock_cursor

        with patch.object(main, "get_connection", return_value=mock_conn):
            client.get("/db-check")

        mock_conn.close.assert_called_once()

    def test_does_not_close_connection_that_was_never_opened(self, client):
        """If get_connection() itself raises, there is no conn object to
        close — this must not raise an AttributeError in the finally
        block."""
        with patch.object(main, "get_connection", side_effect=Exception("refused")):
            resp = client.get("/db-check")
        # No exception propagating out is the assertion here
        assert resp.status_code == 503


class TestMetrics:
    def test_metrics_returns_prometheus_format(self, client):
        resp = client.get("/metrics")
        assert resp.status_code == 200
        assert resp.mimetype == "text/plain"
        assert "metrics_api_requests_total" in resp.get_data(as_text=True)
        assert "metrics_api_db_query_duration_seconds" in resp.get_data(as_text=True)

    def test_request_count_increments_across_requests(self, client):
        client.get("/health")
        client.get("/health")
        resp = client.get("/metrics")
        body = resp.get_data(as_text=True)
        # 2 prior /health calls + this /metrics call itself = 3
        assert "metrics_api_requests_total 3" in body

    def test_avg_query_duration_zero_when_no_queries_yet(self, client):
        resp = client.get("/metrics")
        body = resp.get_data(as_text=True)
        assert "metrics_api_db_query_duration_seconds 0.0000" in body

    def test_avg_query_duration_reflects_successful_db_checks(self, client):
        mock_cursor = _mock_db_cursor()
        mock_conn = MagicMock()
        mock_conn.cursor.return_value = mock_cursor

        with patch.object(main, "get_connection", return_value=mock_conn):
            client.get("/db-check")

        resp = client.get("/metrics")
        body = resp.get_data(as_text=True)
        # Duration was recorded — just confirm it's no longer the zero default
        assert "metrics_api_db_query_duration_seconds 0.0000" not in body
