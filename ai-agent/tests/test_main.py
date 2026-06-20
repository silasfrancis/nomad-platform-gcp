"""
test_main.py
Tests the control loop's decision logic: when to remediate vs alert-only,
cooldown respect, and max-attempt escalation. Gemini, Nomad, and Slack
calls are all mocked — these tests never touch real network resources.
"""

from unittest.mock import patch, MagicMock

import pytest

import main
from state import StateTracker


def _sample_anomaly():
    return {
        "job_id": "web-job",
        "alloc_id": "alloc-1",
        "task": "web",
        "namespace": "default",
        "anomaly_type": "oom_killed",
        "restarts": 4,
        "events": [],
        "logs": "OOM",
        "current_memory_mb": 256,
        "current_cpu_mhz": 200,
        "job_spec": {"Version": 1, "TaskGroups": []},
    }


class TestHandleAnomaly:
    def test_low_confidence_does_not_remediate(self):
        tracker = StateTracker(cooldown_seconds=60, max_attempts=3)
        analysis = {
            "severity": "high",
            "confidence": 0.3,  # below threshold
            "suggested_action": "increase_memory",
            "likely_cause": "x",
            "summary": "x",
            "memory_increase_mb": 256,
        }

        with patch.object(main.gemini_client, "analyze", return_value=analysis), \
             patch.object(main.alerter, "send_alert") as mock_alert, \
             patch.object(main.remediator, "remediate") as mock_remediate:

            main.handle_anomaly(_sample_anomaly(), tracker)

        mock_alert.assert_called_once()
        mock_remediate.assert_not_called()

    def test_low_severity_does_not_remediate(self):
        tracker = StateTracker(cooldown_seconds=60, max_attempts=3)
        analysis = {
            "severity": "low",
            "confidence": 0.95,
            "suggested_action": "increase_memory",
            "likely_cause": "x",
            "summary": "x",
            "memory_increase_mb": 256,
        }

        with patch.object(main.gemini_client, "analyze", return_value=analysis), \
             patch.object(main.alerter, "send_alert") as mock_alert, \
             patch.object(main.remediator, "remediate") as mock_remediate:

            main.handle_anomaly(_sample_anomaly(), tracker)

        mock_alert.assert_called_once()
        mock_remediate.assert_not_called()

    def test_high_severity_high_confidence_triggers_remediation(self):
        tracker = StateTracker(cooldown_seconds=60, max_attempts=3)
        analysis = {
            "severity": "high",
            "confidence": 0.95,
            "suggested_action": "increase_memory",
            "likely_cause": "x",
            "summary": "x",
            "memory_increase_mb": 256,
        }

        with patch.object(main.gemini_client, "analyze", return_value=analysis), \
             patch.object(main.alerter, "send_alert") as mock_alert, \
             patch.object(main.remediator, "remediate", return_value={"action_taken": "increase_memory"}) as mock_remediate:

            main.handle_anomaly(_sample_anomaly(), tracker)

        mock_remediate.assert_called_once()
        mock_alert.assert_called_once()
        assert tracker.attempts("web-job") == 1

    def test_manual_intervention_action_does_not_remediate_even_if_critical(self):
        tracker = StateTracker(cooldown_seconds=60, max_attempts=3)
        analysis = {
            "severity": "critical",
            "confidence": 0.99,
            "suggested_action": "manual_intervention",
            "likely_cause": "x",
            "summary": "x",
            "memory_increase_mb": 0,
        }

        with patch.object(main.gemini_client, "analyze", return_value=analysis), \
             patch.object(main.alerter, "send_alert") as mock_alert, \
             patch.object(main.remediator, "remediate") as mock_remediate:

            main.handle_anomaly(_sample_anomaly(), tracker)

        mock_remediate.assert_not_called()
        mock_alert.assert_called_once()

    def test_job_in_cooldown_is_skipped_entirely(self):
        tracker = StateTracker(cooldown_seconds=300, max_attempts=3)
        tracker.record_remediation("web-job")  # puts it in cooldown

        with patch.object(main.gemini_client, "analyze") as mock_analyze, \
             patch.object(main.alerter, "send_alert") as mock_alert:

            main.handle_anomaly(_sample_anomaly(), tracker)

        mock_analyze.assert_not_called()
        mock_alert.assert_not_called()

    def test_max_attempts_reached_sends_escalation_instead_of_remediating(self):
        tracker = StateTracker(cooldown_seconds=0, max_attempts=1)
        tracker.record_remediation("web-job")  # 1 attempt already, cooldown is 0 so it expires immediately

        analysis = {
            "severity": "critical",
            "confidence": 0.95,
            "suggested_action": "restart",
            "likely_cause": "x",
            "summary": "x",
            "memory_increase_mb": 0,
        }

        with patch.object(main.gemini_client, "analyze", return_value=analysis), \
             patch.object(main.alerter, "send_alert") as mock_alert, \
             patch.object(main.remediator, "remediate") as mock_remediate:

            main.handle_anomaly(_sample_anomaly(), tracker)

        mock_remediate.assert_not_called()
        mock_alert.assert_called_once()
        _, kwargs = mock_alert.call_args
        assert kwargs.get("escalate") is True


class TestRunOnce:
    def test_run_once_processes_all_detected_anomalies(self):
        tracker = StateTracker(cooldown_seconds=60, max_attempts=3)
        anomalies = [_sample_anomaly(), {**_sample_anomaly(), "job_id": "job-2"}]

        with patch.object(main.detector, "detect_anomalies", return_value=anomalies), \
             patch.object(main, "handle_anomaly") as mock_handle:

            count = main.run_once(tracker)

        assert count == 2
        assert mock_handle.call_count == 2

    def test_run_once_continues_after_individual_anomaly_failure(self):
        tracker = StateTracker(cooldown_seconds=60, max_attempts=3)
        anomalies = [_sample_anomaly(), {**_sample_anomaly(), "job_id": "job-2"}]

        def side_effect(anomaly, tracker):
            if anomaly["job_id"] == "web-job":
                raise RuntimeError("boom")

        with patch.object(main.detector, "detect_anomalies", return_value=anomalies), \
             patch.object(main, "handle_anomaly", side_effect=side_effect) as mock_handle:

            # Should not raise even though the first anomaly's handler raises
            count = main.run_once(tracker)

        assert count == 2
        assert mock_handle.call_count == 2

    def test_run_once_returns_zero_when_no_anomalies(self):
        tracker = StateTracker(cooldown_seconds=60, max_attempts=3)
        with patch.object(main.detector, "detect_anomalies", return_value=[]):
            count = main.run_once(tracker)
        assert count == 0
