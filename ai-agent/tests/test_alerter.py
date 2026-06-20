"""
test_alerter.py
Tests Slack alert formatting and delivery against a mocked webhook.
"""

import json

import pytest
import responses
import requests

import alerter
from config import SLACK_WEBHOOK_URL


def _sample_anomaly():
    return {
        "job_id": "web-job",
        "task": "web",
        "namespace": "default",
        "anomaly_type": "oom_killed",
        "restarts": 4,
    }


def _sample_analysis(severity="high", confidence=0.9):
    return {
        "likely_cause": "Heap exhaustion",
        "severity": severity,
        "suggested_action": "increase_memory",
        "memory_increase_mb": 256,
        "confidence": confidence,
        "summary": "Service needs more memory",
    }


class TestSendAlert:
    @responses.activate
    def test_sends_alert_successfully(self):
        responses.add(responses.POST, SLACK_WEBHOOK_URL, json={"ok": True}, status=200)
        result = alerter.send_alert(_sample_anomaly(), _sample_analysis())
        assert result is True
        assert len(responses.calls) == 1

    @responses.activate
    def test_alert_payload_includes_job_and_severity(self):
        responses.add(responses.POST, SLACK_WEBHOOK_URL, json={"ok": True}, status=200)
        alerter.send_alert(_sample_anomaly(), _sample_analysis(severity="critical"))

        sent_body = json.loads(responses.calls[0].request.body)
        field_values = [f["value"] for f in sent_body["attachments"][0]["fields"]]
        assert "web-job" in field_values
        assert "critical" in field_values

    @responses.activate
    def test_alert_includes_remediation_result_when_provided(self):
        responses.add(responses.POST, SLACK_WEBHOOK_URL, json={"ok": True}, status=200)
        remediation_result = {
            "action_taken": "increase_memory",
            "old_memory_mb": 256,
            "new_memory_mb": 512,
        }
        alerter.send_alert(_sample_anomaly(), _sample_analysis(), remediation_result=remediation_result)

        sent_body = json.loads(responses.calls[0].request.body)
        field_titles = [f["title"] for f in sent_body["attachments"][0]["fields"]]
        assert "Remediation" in field_titles

    @responses.activate
    def test_escalation_alert_includes_escalation_reason(self):
        responses.add(responses.POST, SLACK_WEBHOOK_URL, json={"ok": True}, status=200)
        alerter.send_alert(_sample_anomaly(), _sample_analysis(), escalate=True)

        sent_body = json.loads(responses.calls[0].request.body)
        assert "ESCALATION" in sent_body["text"]
        field_titles = [f["title"] for f in sent_body["attachments"][0]["fields"]]
        assert "Escalation Reason" in field_titles

    @responses.activate
    def test_send_alert_returns_false_on_webhook_failure(self):
        responses.add(responses.POST, SLACK_WEBHOOK_URL, json={"error": "bad"}, status=500)
        result = alerter.send_alert(_sample_anomaly(), _sample_analysis())
        assert result is False

    @responses.activate
    def test_send_alert_never_raises_on_connection_error(self):
        responses.add(
            responses.POST,
            SLACK_WEBHOOK_URL,
            body=requests.exceptions.ConnectionError("connection refused"),
        )
        result = alerter.send_alert(_sample_anomaly(), _sample_analysis())
        assert result is False


class TestSendProposalAlert:
    @responses.activate
    def test_sends_proposal_alert_successfully(self):
        responses.add(responses.POST, SLACK_WEBHOOK_URL, json={"ok": True}, status=200)
        result = alerter.send_proposal_alert(_sample_anomaly(), _sample_analysis())
        assert result is True

    @responses.activate
    def test_proposal_alert_title_indicates_action_required(self):
        responses.add(responses.POST, SLACK_WEBHOOK_URL, json={"ok": True}, status=200)
        alerter.send_proposal_alert(_sample_anomaly(), _sample_analysis())

        sent_body = json.loads(responses.calls[0].request.body)
        assert "ACTION REQUIRED" in sent_body["text"]

    @responses.activate
    def test_proposal_alert_states_no_action_was_executed(self):
        responses.add(responses.POST, SLACK_WEBHOOK_URL, json={"ok": True}, status=200)
        alerter.send_proposal_alert(_sample_anomaly(), _sample_analysis())

        sent_body = json.loads(responses.calls[0].request.body)
        fields = sent_body["attachments"][0]["fields"]
        mode_field = next(f for f in fields if f["title"] == "Mode")
        assert "did not modify Nomad" in mode_field["value"]

        proposed_field = next(f for f in fields if "NOT executed" in f["title"])
        assert proposed_field is not None

    @responses.activate
    def test_proposal_alert_describes_memory_increase_action(self):
        responses.add(responses.POST, SLACK_WEBHOOK_URL, json={"ok": True}, status=200)
        analysis = _sample_analysis()
        analysis["suggested_action"] = "increase_memory"
        analysis["memory_increase_mb"] = 256
        alerter.send_proposal_alert(_sample_anomaly(), analysis)

        sent_body = json.loads(responses.calls[0].request.body)
        fields = sent_body["attachments"][0]["fields"]
        proposed_field = next(f for f in fields if "NOT executed" in f["title"])
        assert "256MB" in proposed_field["value"]

    @responses.activate
    def test_proposal_alert_never_raises_on_failure(self):
        responses.add(responses.POST, SLACK_WEBHOOK_URL, json={"error": "bad"}, status=500)
        result = alerter.send_proposal_alert(_sample_anomaly(), _sample_analysis())
        assert result is False


class TestFormatProposedAction:
    def test_formats_increase_memory(self):
        text = alerter._format_proposed_action("increase_memory", {"memory_increase_mb": 512})
        assert "512MB" in text

    def test_formats_restart(self):
        text = alerter._format_proposed_action("restart", {})
        assert "Restart" in text

    def test_formats_revert(self):
        text = alerter._format_proposed_action("revert", {})
        assert "Revert" in text

    def test_formats_unknown_action(self):
        text = alerter._format_proposed_action("something_else", {})
        assert "manual review" in text


class TestSendSimpleAlert:
    @responses.activate
    def test_sends_simple_text_alert(self):
        responses.add(responses.POST, SLACK_WEBHOOK_URL, json={"ok": True}, status=200)
        result = alerter.send_simple_alert("Agent started", severity="low")
        assert result is True

        sent_body = json.loads(responses.calls[0].request.body)
        assert "Agent started" in sent_body["text"]


class TestFormatRemediation:
    def test_formats_increase_memory(self):
        result = {"action_taken": "increase_memory", "old_memory_mb": 256, "new_memory_mb": 512}
        text = alerter._format_remediation(result)
        assert "256" in text and "512" in text

    def test_formats_restart(self):
        result = {"action_taken": "restart", "alloc_id": "alloc-99"}
        text = alerter._format_remediation(result)
        assert "alloc-99" in text

    def test_formats_revert(self):
        result = {"action_taken": "revert", "from_version": 5, "to_version": 4}
        text = alerter._format_remediation(result)
        assert "5" in text and "4" in text

    def test_formats_failed_action(self):
        result = {"action_taken": "failed", "reason": "connection timeout"}
        text = alerter._format_remediation(result)
        assert "FAILED" in text
        assert "connection timeout" in text

    def test_formats_none_action(self):
        result = {"action_taken": "none", "reason": "requires human review"}
        text = alerter._format_remediation(result)
        assert "requires human review" in text
