"""
test_detector.py
Tests anomaly detection logic against mocked Nomad API responses.
"""

import time
import pytest
import responses
import requests

import detector
from config import NOMAD_ADDR


def _alloc_summary(alloc_id="alloc-1", job_id="job-1", client_status="running", create_time_ns=None):
    return {
        "ID": alloc_id,
        "JobID": job_id,
        "Namespace": "default",
        "ClientStatus": client_status,
        "JobType": "service",
        "CreateTime": create_time_ns if create_time_ns is not None else int(time.time() * 1e9),
    }


def _task_state(state="running", restarts=0, events=None):
    return {
        "State": state,
        "Restarts": restarts,
        "Events": events or [],
    }


class TestDetectAnomalyType:
    def test_no_anomaly_for_healthy_task(self):
        alloc = _alloc_summary()
        task_state = _task_state(state="running", restarts=0)
        result = detector._detect_anomaly_type(alloc, "web", task_state)
        assert result is None

    def test_restart_loop_detected_at_threshold(self):
        alloc = _alloc_summary()
        task_state = _task_state(state="running", restarts=3)
        result = detector._detect_anomaly_type(alloc, "web", task_state)
        assert result == "restart_loop"

    def test_restart_loop_not_detected_below_threshold(self):
        alloc = _alloc_summary()
        task_state = _task_state(state="running", restarts=2)
        result = detector._detect_anomaly_type(alloc, "web", task_state)
        assert result is None

    def test_oom_detected_via_exit_code(self):
        alloc = _alloc_summary()
        events = [{"DisplayMessage": "Exited with code 137", "ExitCode": 137}]
        task_state = _task_state(state="dead", restarts=1, events=events)
        result = detector._detect_anomaly_type(alloc, "web", task_state)
        assert result == "oom_killed"

    def test_oom_detected_via_message(self):
        alloc = _alloc_summary()
        events = [{"DisplayMessage": "Task killed: OOM detected by kernel"}]
        task_state = _task_state(state="dead", restarts=1, events=events)
        result = detector._detect_anomaly_type(alloc, "web", task_state)
        assert result == "oom_killed"

    def test_oom_takes_priority_over_restart_loop(self):
        # Even with restarts below threshold, an OOM event should be caught
        alloc = _alloc_summary()
        events = [{"DisplayMessage": "OOM killed"}]
        task_state = _task_state(state="dead", restarts=1, events=events)
        result = detector._detect_anomaly_type(alloc, "web", task_state)
        assert result == "oom_killed"

    def test_image_pull_failure_detected(self):
        alloc = _alloc_summary()
        events = [{"DisplayMessage": "Failed to pull image 'myapp:latest': not found"}]
        task_state = _task_state(state="pending", restarts=0, events=events)
        result = detector._detect_anomaly_type(alloc, "web", task_state)
        assert result == "image_pull_failure"

    def test_stuck_pending_detected_past_threshold(self):
        old_create_time_ns = int((time.time() - 200) * 1e9)
        alloc = _alloc_summary(client_status="pending", create_time_ns=old_create_time_ns)
        task_state = _task_state(state="pending", restarts=0)
        result = detector._detect_anomaly_type(alloc, "web", task_state)
        assert result == "stuck_pending"

    def test_stuck_pending_not_detected_within_threshold(self):
        recent_create_time_ns = int((time.time() - 10) * 1e9)
        alloc = _alloc_summary(client_status="pending", create_time_ns=recent_create_time_ns)
        task_state = _task_state(state="pending", restarts=0)
        result = detector._detect_anomaly_type(alloc, "web", task_state)
        assert result is None

    def test_stuck_starting_detected_past_threshold(self):
        old_event_time_ns = int((time.time() - 300) * 1e9)
        alloc = _alloc_summary()
        events = [{"DisplayMessage": "Starting task", "Time": old_event_time_ns}]
        task_state = _task_state(state="starting", restarts=0, events=events)
        result = detector._detect_anomaly_type(alloc, "web", task_state)
        assert result == "stuck_starting"


class TestFetchLogs:
    @responses.activate
    def test_fetch_logs_returns_stderr_content(self):
        responses.add(
            responses.GET,
            f"{NOMAD_ADDR}/v1/client/allocation/alloc-1/logs",
            body="line1\nline2\nline3",
            status=200,
        )
        result = detector.fetch_logs("alloc-1", "web", "stderr")
        assert "line1" in result
        assert "line3" in result

    @responses.activate
    def test_fetch_logs_falls_back_to_stdout_when_stderr_empty(self):
        responses.add(
            responses.GET,
            f"{NOMAD_ADDR}/v1/client/allocation/alloc-1/logs",
            body="",
            status=200,
        )
        responses.add(
            responses.GET,
            f"{NOMAD_ADDR}/v1/client/allocation/alloc-1/logs",
            body="stdout content here",
            status=200,
        )
        result = detector.fetch_logs("alloc-1", "web", "stderr")
        assert result == "stdout content here"

    @responses.activate
    def test_fetch_logs_truncates_to_tail_lines(self, monkeypatch):
        monkeypatch.setattr(detector, "LOG_TAIL_LINES", 2)
        responses.add(
            responses.GET,
            f"{NOMAD_ADDR}/v1/client/allocation/alloc-1/logs",
            body="a\nb\nc\nd\ne",
            status=200,
        )
        result = detector.fetch_logs("alloc-1", "web", "stderr")
        # Should not error and should return some subset of lines
        assert "e" in result

    @responses.activate
    def test_fetch_logs_handles_request_failure_gracefully(self):
        responses.add(
            responses.GET,
            f"{NOMAD_ADDR}/v1/client/allocation/alloc-1/logs",
            body=requests.exceptions.ConnectionError("connection refused"),
        )
        result = detector.fetch_logs("alloc-1", "web", "stderr")
        assert result == ""


class TestDetectAnomalies:
    @responses.activate
    def test_detect_anomalies_returns_empty_when_no_allocations(self):
        responses.add(
            responses.GET,
            f"{NOMAD_ADDR}/v1/allocations",
            json=[],
            status=200,
        )
        result = detector.detect_anomalies()
        assert result == []

    @responses.activate
    def test_detect_anomalies_finds_restart_loop(self):
        alloc_summary = _alloc_summary(alloc_id="alloc-99", job_id="web-job")
        responses.add(
            responses.GET,
            f"{NOMAD_ADDR}/v1/allocations",
            json=[alloc_summary],
            status=200,
        )
        responses.add(
            responses.GET,
            f"{NOMAD_ADDR}/v1/allocation/alloc-99",
            json={
                "TaskStates": {
                    "web": _task_state(state="running", restarts=5),
                },
                "AllocatedResources": {},
            },
            status=200,
        )
        responses.add(
            responses.GET,
            f"{NOMAD_ADDR}/v1/job/web-job",
            json={
                "TaskGroups": [
                    {"Tasks": [{"Name": "web", "Resources": {"MemoryMB": 256, "CPU": 200}}]}
                ]
            },
            status=200,
        )
        responses.add(
            responses.GET,
            f"{NOMAD_ADDR}/v1/client/allocation/alloc-99/logs",
            body="error error error",
            status=200,
        )

        anomalies = detector.detect_anomalies()
        assert len(anomalies) == 1
        assert anomalies[0]["anomaly_type"] == "restart_loop"
        assert anomalies[0]["job_id"] == "web-job"
        assert anomalies[0]["current_memory_mb"] == 256

    @responses.activate
    def test_detect_anomalies_skips_healthy_allocations(self):
        alloc_summary = _alloc_summary(alloc_id="alloc-healthy", job_id="healthy-job")
        responses.add(
            responses.GET,
            f"{NOMAD_ADDR}/v1/allocations",
            json=[alloc_summary],
            status=200,
        )
        responses.add(
            responses.GET,
            f"{NOMAD_ADDR}/v1/allocation/alloc-healthy",
            json={
                "TaskStates": {"web": _task_state(state="running", restarts=0)},
                "AllocatedResources": {},
            },
            status=200,
        )

        anomalies = detector.detect_anomalies()
        assert anomalies == []


class TestExtractResourceHelpers:
    def test_extract_memory_mb_finds_matching_task(self):
        job_spec = {
            "TaskGroups": [
                {"Tasks": [{"Name": "web", "Resources": {"MemoryMB": 512}}]},
                {"Tasks": [{"Name": "sidecar", "Resources": {"MemoryMB": 128}}]},
            ]
        }
        assert detector._extract_memory_mb(job_spec, "web") == 512
        assert detector._extract_memory_mb(job_spec, "sidecar") == 128

    def test_extract_memory_mb_returns_zero_when_not_found(self):
        job_spec = {"TaskGroups": [{"Tasks": [{"Name": "web", "Resources": {"MemoryMB": 512}}]}]}
        assert detector._extract_memory_mb(job_spec, "nonexistent") == 0

    def test_extract_memory_mb_handles_none_job_spec(self):
        assert detector._extract_memory_mb(None, "web") == 0

    def test_extract_cpu_mhz_finds_matching_task(self):
        job_spec = {
            "TaskGroups": [{"Tasks": [{"Name": "web", "Resources": {"CPU": 500}}]}]
        }
        assert detector._extract_cpu_mhz(job_spec, "web") == 500
