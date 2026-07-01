"""
test_remediator.py
Tests remediation dispatch and execution against a mocked Nomad API.
"""

import pytest
import responses
import requests

import remediator
from config import NOMAD_ADDR


def _sample_job_spec(memory_mb=256, version=3):
    return {
        "Version": version,
        "TaskGroups": [
            {"Tasks": [{"Name": "web", "Resources": {"MemoryMB": memory_mb, "CPU": 200}}]}
        ],
    }


def _sample_anomaly(job_spec=None):
    return {
        "job_id": "web-job",
        "alloc_id": "alloc-99",
        "task": "web",
        "namespace": "default",
        "anomaly_type": "oom_killed",
        "job_spec": job_spec or _sample_job_spec(),
    }


class TestRemediateDispatch:
    def test_dispatches_to_increase_memory(self):
        anomaly = _sample_anomaly()
        analysis = {"suggested_action": "increase_memory", "memory_increase_mb": 256}

        with responses.RequestsMock() as rsps:
            rsps.add(responses.POST, f"{NOMAD_ADDR}/v1/job/web-job", json={}, status=200)
            result = remediator.remediate(anomaly, analysis)

        assert result["action_taken"] == "increase_memory"

    def test_dispatches_to_restart(self):
        anomaly = _sample_anomaly()
        analysis = {"suggested_action": "restart"}

        with responses.RequestsMock() as rsps:
            rsps.add(
                responses.POST,
                f"{NOMAD_ADDR}/v1/allocation/alloc-99/stop",
                json={},
                status=200,
            )
            result = remediator.remediate(anomaly, analysis)

        assert result["action_taken"] == "restart"

    def test_dispatches_to_revert(self):
        anomaly = _sample_anomaly(job_spec=_sample_job_spec(version=5))
        analysis = {"suggested_action": "revert"}

        with responses.RequestsMock() as rsps:
            rsps.add(
                responses.POST,
                f"{NOMAD_ADDR}/v1/job/web-job/revert",
                json={},
                status=200,
            )
            result = remediator.remediate(anomaly, analysis)

        assert result["action_taken"] == "revert"
        assert result["from_version"] == 5
        assert result["to_version"] == 4

    def test_check_image_takes_no_action(self):
        anomaly = _sample_anomaly()
        analysis = {"suggested_action": "check_image"}
        result = remediator.remediate(anomaly, analysis)
        assert result["action_taken"] == "none"

    def test_manual_intervention_takes_no_action(self):
        anomaly = _sample_anomaly()
        analysis = {"suggested_action": "manual_intervention"}
        result = remediator.remediate(anomaly, analysis)
        assert result["action_taken"] == "none"

    def test_unknown_action_takes_no_action(self):
        anomaly = _sample_anomaly()
        analysis = {"suggested_action": "do_something_weird"}
        result = remediator.remediate(anomaly, analysis)
        assert result["action_taken"] == "none"

    def test_remediate_never_raises_on_network_failure(self):
        anomaly = _sample_anomaly()
        analysis = {"suggested_action": "increase_memory", "memory_increase_mb": 128}

        with responses.RequestsMock() as rsps:
            rsps.add(
                responses.POST,
                f"{NOMAD_ADDR}/v1/job/web-job",
                body=requests.exceptions.ConnectionError("connection refused"),
            )
            result = remediator.remediate(anomaly, analysis)

        assert result["action_taken"] == "failed"


class TestIncreaseMemory:
    def test_increases_memory_by_suggested_amount(self):
        anomaly = _sample_anomaly(job_spec=_sample_job_spec(memory_mb=256))
        analysis = {"memory_increase_mb": 256}

        captured_payload = {}

        def request_callback(request):
            import json as json_lib
            captured_payload.update(json_lib.loads(request.body))
            return (200, {}, "{}")

        with responses.RequestsMock() as rsps:
            rsps.add_callback(
                responses.POST,
                f"{NOMAD_ADDR}/v1/job/web-job",
                callback=request_callback,
                content_type="application/json",
            )
            result = remediator._increase_memory(anomaly, analysis)

        assert result["old_memory_mb"] == 256
        assert result["new_memory_mb"] == 512
        new_resources = captured_payload["Job"]["TaskGroups"][0]["Tasks"][0]["Resources"]
        assert new_resources["MemoryMB"] == 512

    def test_skips_when_increase_is_zero(self):
        anomaly = _sample_anomaly()
        analysis = {"memory_increase_mb": 0}
        result = remediator._increase_memory(anomaly, analysis)
        assert result["action_taken"] == "none"

    def test_raises_when_task_not_found(self):
        anomaly = _sample_anomaly(job_spec=_sample_job_spec())
        anomaly["task"] = "nonexistent-task"
        analysis = {"memory_increase_mb": 128}

        with pytest.raises(remediator.RemediationError):
            remediator._increase_memory(anomaly, analysis)

    def test_does_not_mutate_original_anomaly_job_spec(self):
        original_spec = _sample_job_spec(memory_mb=256)
        anomaly = _sample_anomaly(job_spec=original_spec)
        analysis = {"memory_increase_mb": 256}

        with responses.RequestsMock() as rsps:
            rsps.add(responses.POST, f"{NOMAD_ADDR}/v1/job/web-job", json={}, status=200)
            remediator._increase_memory(anomaly, analysis)

        # Original dict passed in should be untouched (deep copy was used)
        assert original_spec["TaskGroups"][0]["Tasks"][0]["Resources"]["MemoryMB"] == 256


class TestRestartAllocation:
    def test_restart_calls_stop_endpoint(self):
        anomaly = _sample_anomaly()

        with responses.RequestsMock() as rsps:
            rsps.add(
                responses.POST,
                f"{NOMAD_ADDR}/v1/allocation/alloc-99/stop",
                json={},
                status=200,
            )
            result = remediator._restart_allocation(anomaly)

        assert result["action_taken"] == "restart"
        assert result["alloc_id"] == "alloc-99"

    def test_restart_raises_remediation_error_on_failure(self):
        anomaly = _sample_anomaly()

        with responses.RequestsMock() as rsps:
            rsps.add(
                responses.POST,
                f"{NOMAD_ADDR}/v1/allocation/alloc-99/stop",
                json={"errors": "not found"},
                status=404,
            )
            with pytest.raises(remediator.RemediationError):
                remediator._restart_allocation(anomaly)


class TestRevertJob:
    def test_revert_raises_when_at_version_zero(self):
        anomaly = _sample_anomaly(job_spec=_sample_job_spec(version=0))
        with pytest.raises(remediator.RemediationError):
            remediator._revert_job(anomaly)
