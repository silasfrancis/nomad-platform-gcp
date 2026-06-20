"""
test_history.py
Tests for history.py. Real PostgreSQL is never touched — psycopg2.connect
is mocked throughout. Tests cover: the disabled-by-default path (no
HISTORY_DATABASE_URL set), schema setup success/failure, write success
across all outcome types, and — most importantly — that every failure
mode degrades to "log and continue" rather than raising, since nothing
in the control loop should ever be affected by a database problem.
"""

import json
from unittest.mock import MagicMock, patch

import pytest

import history


def _sample_anomaly(**overrides):
    base = {
        "job_id": "web-job",
        "alloc_id": "alloc-1",
        "task": "web",
        "namespace": "default",
        "anomaly_type": "oom_killed",
        "restarts": 4,
        "detected_at": 1750000000.0,
    }
    base.update(overrides)
    return base


def _sample_analysis(**overrides):
    base = {
        "likely_cause": "Heap exhaustion",
        "severity": "high",
        "confidence": 0.91,
        "suggested_action": "increase_memory",
    }
    base.update(overrides)
    return base


class TestDisabledByDefault:
    def test_record_is_a_no_op_when_disabled(self):
        with patch.object(history, "_ENABLED", False):
            with patch.object(history, "_get_connection") as mock_conn:
                history.record(_sample_anomaly(), _sample_analysis(), outcome="alerted_only")
            mock_conn.assert_not_called()

    def test_ensure_schema_is_a_no_op_when_disabled(self):
        with patch.object(history, "_ENABLED", False):
            with patch.object(history, "_get_connection") as mock_conn:
                history.ensure_schema()
            mock_conn.assert_not_called()


class TestEnsureSchema:
    def test_creates_table_and_index_on_success(self):
        mock_cursor = MagicMock()
        mock_conn = MagicMock()
        mock_conn.cursor.return_value = mock_cursor

        with patch.object(history, "_ENABLED", True), \
             patch.object(history, "_get_connection", return_value=mock_conn):
            history.ensure_schema()

        executed_sql = [call.args[0] for call in mock_cursor.execute.call_args_list]
        assert any("CREATE TABLE" in sql for sql in executed_sql)
        assert any("CREATE INDEX" in sql for sql in executed_sql)
        mock_conn.commit.assert_called_once()
        mock_conn.close.assert_called_once()

    def test_sets_schema_ready_true_on_success(self):
        mock_conn = MagicMock()
        with patch.object(history, "_ENABLED", True), \
             patch.object(history, "_get_connection", return_value=mock_conn):
            history.ensure_schema()
        assert history._schema_ready is True

    def test_sets_schema_ready_false_and_does_not_raise_on_failure(self):
        with patch.object(history, "_ENABLED", True), \
             patch.object(history, "_get_connection", side_effect=Exception("connection refused")):
            history.ensure_schema()  # must not raise
        assert history._schema_ready is False

    def test_closes_connection_even_on_failure_after_connect(self):
        mock_conn = MagicMock()
        mock_conn.cursor.side_effect = Exception("boom")

        with patch.object(history, "_ENABLED", True), \
             patch.object(history, "_get_connection", return_value=mock_conn):
            history.ensure_schema()

        mock_conn.close.assert_called_once()


class TestRecord:
    def test_skips_write_when_schema_not_ready(self):
        with patch.object(history, "_ENABLED", True), \
             patch.object(history, "_schema_ready", False), \
             patch.object(history, "_get_connection") as mock_conn:
            history.record(_sample_anomaly(), _sample_analysis(), outcome="alerted_only")
        mock_conn.assert_not_called()

    def test_writes_row_with_expected_values(self):
        mock_cursor = MagicMock()
        mock_conn = MagicMock()
        mock_conn.cursor.return_value = mock_cursor

        with patch.object(history, "_ENABLED", True), \
             patch.object(history, "_schema_ready", True), \
             patch.object(history, "_get_connection", return_value=mock_conn), \
             patch.object(history.config, "REMEDIATION_MODE", "execute"):
            history.record(
                _sample_anomaly(),
                _sample_analysis(),
                outcome="remediated",
                outcome_detail={"action_taken": "increase_memory", "new_memory_mb": 512},
            )

        mock_conn.commit.assert_called_once()
        mock_conn.close.assert_called_once()

        insert_args = mock_cursor.execute.call_args.args[1]
        # Spot-check key positional values land where the SQL expects them
        assert insert_args[2] == "web-job"        # job_id
        assert insert_args[3] == "alloc-1"         # alloc_id
        assert insert_args[6] == "oom_killed"      # anomaly_type
        assert insert_args[8] == "Heap exhaustion" # likely_cause
        assert insert_args[9] == "high"            # severity
        assert insert_args[13] == "remediated"     # outcome
        assert json.loads(insert_args[14]) == {"action_taken": "increase_memory", "new_memory_mb": 512}

    def test_handles_none_analysis_for_skipped_cooldown(self):
        mock_cursor = MagicMock()
        mock_conn = MagicMock()
        mock_conn.cursor.return_value = mock_cursor

        with patch.object(history, "_ENABLED", True), \
             patch.object(history, "_schema_ready", True), \
             patch.object(history, "_get_connection", return_value=mock_conn):
            # Should not raise even though analysis is None
            history.record(_sample_anomaly(), analysis=None, outcome="skipped_cooldown")

        mock_conn.commit.assert_called_once()

    def test_invalid_outcome_falls_back_to_alerted_only(self):
        mock_cursor = MagicMock()
        mock_conn = MagicMock()
        mock_conn.cursor.return_value = mock_cursor

        with patch.object(history, "_ENABLED", True), \
             patch.object(history, "_schema_ready", True), \
             patch.object(history, "_get_connection", return_value=mock_conn):
            history.record(_sample_anomaly(), _sample_analysis(), outcome="not_a_real_outcome")

        insert_args = mock_cursor.execute.call_args.args[1]
        assert insert_args[13] == "alerted_only"

    def test_write_failure_does_not_raise(self):
        with patch.object(history, "_ENABLED", True), \
             patch.object(history, "_schema_ready", True), \
             patch.object(history, "_get_connection", side_effect=Exception("connection refused")):
            # This is the most important test in the file: a DB outage
            # during a write must never propagate up into the control loop
            history.record(_sample_anomaly(), _sample_analysis(), outcome="alerted_only")

    def test_write_failure_mid_transaction_does_not_raise(self):
        mock_cursor = MagicMock()
        mock_cursor.execute.side_effect = Exception("syntax error")
        mock_conn = MagicMock()
        mock_conn.cursor.return_value = mock_cursor

        with patch.object(history, "_ENABLED", True), \
             patch.object(history, "_schema_ready", True), \
             patch.object(history, "_get_connection", return_value=mock_conn):
            history.record(_sample_anomaly(), _sample_analysis(), outcome="alerted_only")
        # No exception propagated is the assertion

    def test_connection_closed_even_on_write_failure(self):
        mock_cursor = MagicMock()
        mock_cursor.execute.side_effect = Exception("boom")
        mock_conn = MagicMock()
        mock_conn.cursor.return_value = mock_cursor

        with patch.object(history, "_ENABLED", True), \
             patch.object(history, "_schema_ready", True), \
             patch.object(history, "_get_connection", return_value=mock_conn):
            history.record(_sample_anomaly(), _sample_analysis(), outcome="alerted_only")

        mock_conn.close.assert_called_once()

    def test_outcome_detail_none_serializes_as_null(self):
        mock_cursor = MagicMock()
        mock_conn = MagicMock()
        mock_conn.cursor.return_value = mock_cursor

        with patch.object(history, "_ENABLED", True), \
             patch.object(history, "_schema_ready", True), \
             patch.object(history, "_get_connection", return_value=mock_conn):
            history.record(_sample_anomaly(), _sample_analysis(), outcome="alerted_only")

        insert_args = mock_cursor.execute.call_args.args[1]
        assert insert_args[14] is None


class TestValidOutcomes:
    @pytest.mark.parametrize("outcome", sorted(history.VALID_OUTCOMES))
    def test_each_valid_outcome_is_accepted_without_fallback(self, outcome):
        mock_cursor = MagicMock()
        mock_conn = MagicMock()
        mock_conn.cursor.return_value = mock_cursor

        with patch.object(history, "_ENABLED", True), \
             patch.object(history, "_schema_ready", True), \
             patch.object(history, "_get_connection", return_value=mock_conn):
            history.record(_sample_anomaly(), _sample_analysis(), outcome=outcome)

        insert_args = mock_cursor.execute.call_args.args[1]
        assert insert_args[13] == outcome
