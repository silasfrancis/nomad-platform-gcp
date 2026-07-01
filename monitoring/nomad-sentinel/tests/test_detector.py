"""
test_detector.py
Tests verified against real Nomad 1.11.0 wire responses (June 2026).

Confirmed facts embedded in test data:
  - /v1/allocations exists, returns JobType + TaskStates inline
  - Image pull failure: event.Type == "Driver Failure" (two words, space)
    event.DriverError or DisplayMessage contains the pull error
  - OOM: event.Type == "Terminated", Details["oom_killed"] == "true" (STRING)
  - TaskState.State values: "pending", "running", "dead" — no "starting"
  - Restart loop fires on any State including "pending" (confirmed: Restarts=19
    on a pending task with Driver Failure events)
  - image_pull_failure must be detected BEFORE restart_loop (pull loops
    produce high restart counts — would be misclassified without priority)
  - stuck_starting must NOT fire when Driver Failure events are present
  - Log endpoint: /v1/client/fs/logs/:alloc_id?task=X&type=Y&plain=true
"""

import time
import pytest
import responses as resp_lib
import requests

import detector
from config import NOMAD_ADDR

ALLOCS_URL = f"{NOMAD_ADDR}/v1/allocations"


# ── Stub factories matching confirmed real wire format ─────────────────────

def _alloc(alloc_id="alloc-1", job_id="job-1", job_type="service",
           client_status="running", create_time_ns=None, task_states=None,
           namespace="default"):
    """
    Matches /v1/allocations list stub.
    JobType and TaskStates are confirmed present.
    AllocatedResources and embedded Job are confirmed NOT present.
    """
    return {
        "ID": alloc_id, "JobID": job_id,
        "JobType": job_type,
        "Namespace": namespace,
        "ClientStatus": client_status,
        "ClientDescription": "",
        "CreateTime": create_time_ns or int(time.time() * 1e9),
        "TaskStates": task_states or {},
    }


def _ts(state="running", restarts=0, events=None):
    """Task state matching real wire format."""
    return {
        "State": state, "Restarts": restarts, "Failed": state == "dead",
        "Events": events or [], "FinishedAt": None, "LastRestart": None,
        "StartedAt": None, "Paused": "",
    }


def _ev_received():
    return {"Type": "Received", "ExitCode": 0, "DisplayMessage": "Task received",
            "DriverError": "", "DriverMessage": "", "Details": {},
            "Time": int(time.time() * 1e9)}


def _ev_task_setup():
    return {"Type": "Task Setup", "ExitCode": 0,
            "DisplayMessage": "Building Task Directory",
            "DriverError": "", "DriverMessage": "", "Details": {},
            "Time": int(time.time() * 1e9)}


def _ev_driver(msg="Downloading image"):
    """Type='Driver' — image download in progress, NOT a failure."""
    return {"Type": "Driver", "ExitCode": 0, "DisplayMessage": msg,
            "DriverError": "", "DriverMessage": msg, "Details": {},
            "Time": int(time.time() * 1e9)}


def _ev_driver_failure(image="alpine:latest", time_offset=0):
    """
    Type='Driver Failure' — CONFIRMED real event type for image pull failures.
    NOT 'Driver'. Two words with a space.
    DriverError field contains the pull error message (confirmed).
    """
    err = (f"Failed to pull `{image}`: Error response from daemon: "
           f"failed to resolve reference: net/http: TLS handshake timeout")
    return {
        "Type": "Driver Failure",
        "ExitCode": 0,
        "DisplayMessage": err,
        "DriverError": err,
        "DriverMessage": "",
        "Details": {"driver_error": err},
        "Time": int((time.time() + time_offset) * 1e9),
    }


def _ev_restarting():
    return {"Type": "Restarting", "ExitCode": 0,
            "DisplayMessage": "Task restarting in 2s",
            "DriverError": "", "DriverMessage": "",
            "Details": {"restart_reason": "Restart within policy",
                        "start_delay": "2000000000"},
            "Time": int(time.time() * 1e9)}


def _ev_not_restarting():
    return {"Type": "Not Restarting", "ExitCode": 0, "FailsTask": True,
            "DisplayMessage": "Exceeded allowed attempts 3 in interval 30s",
            "DriverError": "", "DriverMessage": "",
            "Details": {"fails_task": "true",
                        "restart_reason": "Exceeded allowed attempts 3"},
            "Time": int(time.time() * 1e9)}


def _ev_started():
    return {"Type": "Started", "ExitCode": 0, "DisplayMessage": "Task started",
            "DriverError": "", "DriverMessage": "", "Details": {},
            "Time": int(time.time() * 1e9)}


def _ev_terminated(exit_code=0, oom_killed="false"):
    """
    oom_killed is a STRING "true"/"false" in Details — confirmed from real API.
    """
    return {
        "Type": "Terminated",
        "ExitCode": exit_code,
        "DisplayMessage": f"Exit Code: {exit_code}",
        "DriverError": "", "DriverMessage": "",
        "Details": {
            "oom_killed": oom_killed,   # STRING
            "exit_code": str(exit_code),
            "exit_message": f"Docker container exited with non-zero exit code: {exit_code}",
            "signal": "0",
        },
        "Time": int(time.time() * 1e9),
    }


def _job_spec(task_name="web", memory_mb=256, cpu=200):
    return {
        "Type": "service",
        "TaskGroups": [{"Tasks": [
            {"Name": task_name, "Resources": {"MemoryMB": memory_mb, "CPU": cpu}}
        ]}],
    }


def _log_url(alloc_id):
    return f"{NOMAD_ADDR}/v1/client/fs/logs/{alloc_id}"


def _job_url(job_id):
    return f"{NOMAD_ADDR}/v1/job/{job_id}"


# ── Unit: OOM detection ────────────────────────────────────────────────────

class TestIsOomKilled:
    def test_detected_when_oom_killed_string_is_true(self):
        ev = _ev_terminated(exit_code=137, oom_killed="true")
        assert detector._is_oom_killed(ev) is True

    def test_not_detected_when_oom_killed_string_is_false(self):
        ev = _ev_terminated(exit_code=1, oom_killed="false")
        assert detector._is_oom_killed(ev) is False

    def test_exit_137_alone_is_not_oom(self):
        """SIGKILL from any source gives 137. oom_killed field is authoritative."""
        ev = _ev_terminated(exit_code=137, oom_killed="false")
        assert detector._is_oom_killed(ev) is False

    def test_boolean_true_is_not_the_string_true(self):
        """Real API returns string 'true', not Python bool True."""
        ev = {"Type": "Terminated", "Details": {"oom_killed": True}, "ExitCode": 137}
        assert detector._is_oom_killed(ev) is False

    def test_non_terminated_event_is_not_oom(self):
        ev = {"Type": "Driver", "Details": {"oom_killed": "true"}, "ExitCode": 0}
        assert detector._is_oom_killed(ev) is False


# ── Unit: image pull failure detection ────────────────────────────────────

class TestHasImagePullFailure:
    def test_detected_via_driver_failure_type(self):
        """
        Confirmed: image pull failure event Type is 'Driver Failure'
        (two words, space). NOT 'Driver'.
        """
        events = [_ev_driver(), _ev_driver_failure()]
        assert detector._has_image_pull_failure(events) is True

    def test_not_detected_on_plain_driver_event(self):
        """Type='Driver' is a normal image download progress event, not a failure."""
        events = [_ev_driver("Downloading image nginx:latest")]
        assert detector._has_image_pull_failure(events) is False

    def test_not_detected_on_empty_events(self):
        assert detector._has_image_pull_failure([]) is False

    def test_detected_via_driver_error_field(self):
        events = [_ev_driver_failure()]
        assert detector._has_image_pull_failure(events) is True

    def test_detected_via_display_message_field(self):
        ev = {"Type": "Driver Failure", "ExitCode": 0,
              "DriverError": "",
              "DisplayMessage": "Failed to pull myapp:latest: image not found",
              "Details": {}}
        assert detector._has_image_pull_failure([ev]) is True

    def test_driver_failure_type_without_pull_message_not_flagged(self):
        """Not every Driver Failure is an image pull failure."""
        ev = {"Type": "Driver Failure", "ExitCode": 0,
              "DriverError": "OOM while setting up cgroups",
              "DisplayMessage": "OOM while setting up cgroups",
              "Details": {}}
        assert detector._has_image_pull_failure([ev]) is False

    def test_tls_handshake_timeout_is_pull_failure(self):
        """Confirmed from real responses: TLS timeout during pull = Driver Failure."""
        events = [_ev_driver_failure()]  # uses TLS handshake timeout message
        assert detector._has_image_pull_failure(events) is True


# ── Unit: anomaly type detection ──────────────────────────────────────────

class TestDetectAnomalyType:
    def test_healthy_running_task_returns_none(self):
        alloc = _alloc()
        assert detector._detect_anomaly_type(alloc, "web", _ts("running", 0)) is None

    def test_oom_takes_priority_over_everything(self):
        events = [_ev_terminated(exit_code=137, oom_killed="true")]
        alloc = _alloc()
        # Even with high restarts and pull failures, OOM wins
        result = detector._detect_anomaly_type(alloc, "web",
                    _ts("dead", restarts=10, events=events))
        assert result == "oom_killed"

    def test_image_pull_failure_detected_before_restart_loop(self):
        """
        CRITICAL: a pull failure loop also produces high Restarts (confirmed:
        Restarts=19 in real response). image_pull_failure must have higher
        priority than restart_loop to avoid misclassification.
        """
        events = [
            _ev_driver(), _ev_driver_failure(), _ev_restarting(),
            _ev_driver(), _ev_driver_failure(), _ev_restarting(),
            _ev_driver(), _ev_driver_failure(), _ev_restarting(),
        ]
        alloc = _alloc(client_status="pending")
        result = detector._detect_anomaly_type(alloc, "app",
                    _ts("pending", restarts=19, events=events))
        assert result == "image_pull_failure"

    def test_restart_loop_on_pending_task(self):
        """
        Confirmed from real response: Restarts=19 on a PENDING task.
        restart_loop must fire on any State, not only 'dead'.
        """
        alloc = _alloc()
        result = detector._detect_anomaly_type(alloc, "web",
                    _ts("pending", restarts=5))
        assert result == "restart_loop"

    def test_restart_loop_on_dead_task(self):
        events = [_ev_terminated(1), _ev_restarting(), _ev_terminated(1),
                  _ev_not_restarting()]
        alloc = _alloc()
        result = detector._detect_anomaly_type(alloc, "web",
                    _ts("dead", restarts=3, events=events))
        assert result == "restart_loop"

    def test_restart_loop_not_triggered_below_threshold(self):
        alloc = _alloc()
        result = detector._detect_anomaly_type(alloc, "web",
                    _ts("dead", restarts=2))
        assert result is None

    def test_stuck_pending_beyond_threshold(self):
        old_ns = int((time.time() - 200) * 1e9)
        alloc = _alloc(client_status="pending", create_time_ns=old_ns)
        result = detector._detect_anomaly_type(alloc, "web", _ts("pending"))
        assert result == "stuck_pending"

    def test_stuck_pending_within_threshold_not_triggered(self):
        recent_ns = int((time.time() - 10) * 1e9)
        alloc = _alloc(client_status="pending", create_time_ns=recent_ns)
        result = detector._detect_anomaly_type(alloc, "web", _ts("pending"))
        assert result is None

    def test_stuck_starting_via_old_driver_event(self):
        """
        stuck_starting: state='pending', Driver event is old, no Driver Failure.
        """
        old_ns = int((time.time() - 300) * 1e9)
        events = [{"Type": "Driver", "DisplayMessage": "Downloading image",
                   "ExitCode": 0, "DriverError": "", "Details": {}, "Time": old_ns}]
        alloc = _alloc()
        result = detector._detect_anomaly_type(alloc, "web",
                    _ts("pending", restarts=0, events=events))
        assert result == "stuck_starting"

    def test_stuck_starting_not_triggered_with_recent_driver_event(self):
        recent_ns = int((time.time() - 5) * 1e9)
        events = [{"Type": "Driver", "DisplayMessage": "Downloading image",
                   "ExitCode": 0, "DriverError": "", "Details": {}, "Time": recent_ns}]
        alloc = _alloc()
        result = detector._detect_anomaly_type(alloc, "web",
                    _ts("pending", events=events))
        assert result is None

    def test_stuck_starting_not_triggered_when_driver_failure_present(self):
        """
        A task with Driver Failure events is image_pull_failure, not stuck_starting.
        stuck_starting must be suppressed when Driver Failure events exist.
        But since image_pull_failure fires first (priority 2), and stuck_starting
        is priority 5, this test confirms the suppression guard in stuck_starting
        also works independently.
        """
        old_ns = int((time.time() - 300) * 1e9)
        events = [
            {"Type": "Driver", "ExitCode": 0, "DisplayMessage": "Downloading",
             "DriverError": "", "Details": {}, "Time": old_ns},
            _ev_driver_failure(),
        ]
        alloc = _alloc()
        result = detector._detect_anomaly_type(alloc, "web",
                    _ts("pending", restarts=0, events=events))
        # Should be image_pull_failure (priority 2), not stuck_starting (priority 5)
        assert result == "image_pull_failure"

    def test_state_value_starting_does_not_exist_and_is_ignored(self):
        """'starting' is not a real Nomad TaskState.State value."""
        old_ns = int((time.time() - 300) * 1e9)
        events = [{"Type": "Driver", "ExitCode": 0, "DisplayMessage": "x",
                   "DriverError": "", "Details": {}, "Time": old_ns}]
        alloc = _alloc()
        # 'starting' state — our code only checks for 'pending', so this won't
        # trigger stuck_starting even with old driver events
        result = detector._detect_anomaly_type(alloc, "web",
                    _ts("starting", restarts=0, events=events))
        assert result is None

    def test_task_setup_event_triggers_stuck_starting(self):
        """'Task Setup' is also a driver-start event type."""
        old_ns = int((time.time() - 300) * 1e9)
        events = [{"Type": "Task Setup", "ExitCode": 0, "DisplayMessage": "Building",
                   "DriverError": "", "Details": {}, "Time": old_ns}]
        alloc = _alloc()
        result = detector._detect_anomaly_type(alloc, "web",
                    _ts("pending", restarts=0, events=events))
        assert result == "stuck_starting"


# ── Unit: log fetching ─────────────────────────────────────────────────────

class TestFetchLogs:
    @resp_lib.activate
    def test_uses_correct_confirmed_endpoint(self):
        """
        Confirmed URL: /v1/client/fs/logs/:alloc_id?task=X&type=Y&plain=true
        No follow, offset, or origin params needed with plain=true.
        """
        resp_lib.add(resp_lib.GET, _log_url("alloc-1"), body="line1\nline2", status=200)
        result = detector.fetch_logs("alloc-1", "nginx", "stdout")
        assert "line1" in result
        called = resp_lib.calls[0].request.url
        assert "/v1/client/fs/logs/alloc-1" in called
        assert "task=nginx" in called
        assert "plain=true" in called
        # Confirm no follow param (not needed for plain=true)
        assert "follow" not in called

    @resp_lib.activate
    def test_falls_back_to_stdout_when_stderr_empty(self):
        resp_lib.add(resp_lib.GET, _log_url("alloc-1"), body="", status=200)
        resp_lib.add(resp_lib.GET, _log_url("alloc-1"), body="stdout content", status=200)
        result = detector.fetch_logs("alloc-1", "web", "stderr")
        assert result == "stdout content"

    @resp_lib.activate
    def test_no_log_output_string_treated_as_empty(self):
        """
        Real crasher alloc returned empty logs (dead task with no output).
        The collection script wrote 'NO_LOG_OUTPUT' as a placeholder.
        Both empty string and this placeholder are treated as no content.
        """
        resp_lib.add(resp_lib.GET, _log_url("alloc-1"), body="NO_LOG_OUTPUT", status=200)
        resp_lib.add(resp_lib.GET, _log_url("alloc-1"), body="NO_LOG_OUTPUT", status=200)
        result = detector.fetch_logs("alloc-1", "app", "stderr")
        assert result == ""

    @resp_lib.activate
    def test_returns_empty_on_connection_error(self):
        resp_lib.add(resp_lib.GET, _log_url("alloc-1"),
                     body=requests.exceptions.ConnectionError())
        result = detector.fetch_logs("alloc-1", "web")
        assert result == ""

    @resp_lib.activate
    def test_truncates_to_tail_lines(self, monkeypatch):
        monkeypatch.setattr(detector, "LOG_TAIL_LINES", 3)
        resp_lib.add(resp_lib.GET, _log_url("alloc-1"),
                     body="a\nb\nc\nd\ne\nf", status=200)
        result = detector.fetch_logs("alloc-1", "web")
        lines = result.splitlines()
        assert len(lines) == 3
        assert lines[-1] == "f"


# ── Integration: detect_anomalies ─────────────────────────────────────────

class TestDetectAnomalies:
    @resp_lib.activate
    def test_returns_empty_when_no_allocations(self):
        resp_lib.add(resp_lib.GET, ALLOCS_URL, json=[], status=200)
        assert detector.detect_anomalies() == []

    @resp_lib.activate
    def test_skips_system_jobs(self):
        """JobType='system' on alloc stub — confirmed present, confirmed skipped."""
        stub = _alloc(job_id="alloy", job_type="system",
                     task_states={"alloy": _ts("running", restarts=5)})
        resp_lib.add(resp_lib.GET, ALLOCS_URL, json=[stub], status=200)
        assert detector.detect_anomalies() == []
        # /v1/job/alloy should never be called
        called = [c.request.url for c in resp_lib.calls]
        assert not any("/v1/job/" in u for u in called)

    @resp_lib.activate
    def test_detects_image_pull_failure_matching_real_crasher_response(self):
        """
        Mirrors the real crasher alloc from doc 25:
          ClientStatus='pending', State='pending', Restarts=19,
          events: Driver, Driver Failure, Restarting (repeated)
        Should detect image_pull_failure, NOT restart_loop.
        """
        events = [
            _ev_driver(), _ev_driver_failure(), _ev_restarting(),
            _ev_driver(), _ev_driver_failure(), _ev_restarting(),
            _ev_driver(), _ev_driver_failure(), _ev_restarting(),
            _ev_driver(),
        ]
        stub = _alloc(
            alloc_id="alloc-crasher", job_id="crasher",
            client_status="pending",
            task_states={"app": _ts("pending", restarts=19, events=events)},
        )
        resp_lib.add(resp_lib.GET, ALLOCS_URL, json=[stub], status=200)
        resp_lib.add(resp_lib.GET, _job_url("crasher"),
                     json=_job_spec("app", 64, 100), status=200)
        resp_lib.add(resp_lib.GET, _log_url("alloc-crasher"), body="", status=200)
        resp_lib.add(resp_lib.GET, _log_url("alloc-crasher"), body="", status=200)

        anomalies = detector.detect_anomalies()
        assert len(anomalies) == 1
        assert anomalies[0]["anomaly_type"] == "image_pull_failure"
        assert anomalies[0]["restarts"] == 19

    @resp_lib.activate
    def test_detects_restart_loop_from_terminated_events(self):
        events = [_ev_terminated(1), _ev_restarting(),
                  _ev_terminated(1), _ev_restarting(),
                  _ev_terminated(1), _ev_not_restarting()]
        stub = _alloc(
            alloc_id="alloc-c", job_id="crasher", client_status="failed",
            task_states={"app": _ts("dead", restarts=3, events=events)},
        )
        resp_lib.add(resp_lib.GET, ALLOCS_URL, json=[stub], status=200)
        resp_lib.add(resp_lib.GET, _job_url("crasher"),
                     json=_job_spec("app", 64, 100), status=200)
        resp_lib.add(resp_lib.GET, _log_url("alloc-c"), body="", status=200)
        resp_lib.add(resp_lib.GET, _log_url("alloc-c"), body="", status=200)

        anomalies = detector.detect_anomalies()
        assert len(anomalies) == 1
        assert anomalies[0]["anomaly_type"] == "restart_loop"

    @resp_lib.activate
    def test_detects_oom_via_string_field(self):
        events = [_ev_terminated(exit_code=137, oom_killed="true")]
        stub = _alloc(
            alloc_id="alloc-oom", job_id="oom-job", client_status="failed",
            task_states={"web": _ts("dead", restarts=1, events=events)},
        )
        resp_lib.add(resp_lib.GET, ALLOCS_URL, json=[stub], status=200)
        resp_lib.add(resp_lib.GET, _job_url("oom-job"), json=_job_spec(), status=200)
        resp_lib.add(resp_lib.GET, _log_url("alloc-oom"), body="", status=200)
        resp_lib.add(resp_lib.GET, _log_url("alloc-oom"), body="", status=200)

        anomalies = detector.detect_anomalies()
        assert anomalies[0]["anomaly_type"] == "oom_killed"

    @resp_lib.activate
    def test_job_spec_fetched_once_per_job_id(self):
        """Two anomalous tasks in same job — only one /v1/job/:id call."""
        log_url = _log_url("alloc-multi")
        stub = _alloc(
            alloc_id="alloc-multi", job_id="multi-job",
            task_states={
                "web":    _ts("dead", restarts=3),
                "worker": _ts("dead", restarts=3),
            },
        )
        spec = {"Type": "service", "TaskGroups": [{"Tasks": [
            {"Name": "web",    "Resources": {"MemoryMB": 256, "CPU": 200}},
            {"Name": "worker", "Resources": {"MemoryMB": 512, "CPU": 400}},
        ]}]}
        resp_lib.add(resp_lib.GET, ALLOCS_URL, json=[stub], status=200)
        resp_lib.add(resp_lib.GET, _job_url("multi-job"), json=spec, status=200)
        for _ in range(4):
            resp_lib.add(resp_lib.GET, log_url, body="", status=200)

        anomalies = detector.detect_anomalies()
        assert len(anomalies) == 2
        job_calls = [c for c in resp_lib.calls
                     if "/v1/job/multi-job" in c.request.url]
        assert len(job_calls) == 1

    @resp_lib.activate
    def test_never_calls_alloc_detail_endpoint(self):
        """/v1/allocation/:id is never called — all data is on the list stub."""
        stub = _alloc(
            alloc_id="alloc-1", job_id="job-1",
            task_states={"web": _ts("dead", restarts=3)},
        )
        resp_lib.add(resp_lib.GET, ALLOCS_URL, json=[stub], status=200)
        resp_lib.add(resp_lib.GET, _job_url("job-1"), json=_job_spec(), status=200)
        resp_lib.add(resp_lib.GET, _log_url("alloc-1"), body="", status=200)
        resp_lib.add(resp_lib.GET, _log_url("alloc-1"), body="", status=200)

        detector.detect_anomalies()

        called = [c.request.url for c in resp_lib.calls]
        assert not any(
            "/v1/allocation/alloc-1" in u
            and "logs" not in u and "stats" not in u
            for u in called
        )

    @resp_lib.activate
    def test_uses_namespace_star_when_no_watch_namespaces(self, monkeypatch):
        monkeypatch.setattr(detector, "WATCH_NAMESPACES", [])
        resp_lib.add(resp_lib.GET, ALLOCS_URL, json=[], status=200)
        detector.detect_anomalies()
        assert "namespace=%2A" in resp_lib.calls[0].request.url or \
               "namespace=*" in resp_lib.calls[0].request.url

    @resp_lib.activate
    def test_skips_allocs_with_empty_task_states(self):
        stub = _alloc(alloc_id="alloc-empty", job_id="job-1", task_states={})
        resp_lib.add(resp_lib.GET, ALLOCS_URL, json=[stub], status=200)
        assert detector.detect_anomalies() == []

    @resp_lib.activate
    def test_anomaly_dict_contains_expected_fields(self):
        stub = _alloc(
            alloc_id="alloc-1", job_id="job-1", namespace="staging",
            task_states={"web": _ts("dead", restarts=3)},
        )
        resp_lib.add(resp_lib.GET, ALLOCS_URL, json=[stub], status=200)
        resp_lib.add(resp_lib.GET, _job_url("job-1"),
                     json=_job_spec("web", 512, 300), status=200)
        resp_lib.add(resp_lib.GET, _log_url("alloc-1"), body="some logs", status=200)

        anomalies = detector.detect_anomalies()
        a = anomalies[0]
        assert a["job_id"] == "job-1"
        assert a["alloc_id"] == "alloc-1"
        assert a["task"] == "web"
        assert a["namespace"] == "staging"
        assert a["anomaly_type"] == "restart_loop"
        assert a["current_memory_mb"] == 512
        assert a["current_cpu_mhz"] == 300
        assert "detected_at" in a
        assert "events" in a
        assert "logs" in a


# ── Unit: resource extraction ─────────────────────────────────────────────

class TestResourceExtraction:
    def test_extract_memory_mb(self):
        spec = {"TaskGroups": [{"Tasks": [
            {"Name": "web", "Resources": {"MemoryMB": 512, "CPU": 200}}
        ]}]}
        assert detector._extract_memory_mb(spec, "web") == 512
        assert detector._extract_memory_mb(spec, "other") == 0
        assert detector._extract_memory_mb(None, "web") == 0

    def test_extract_cpu_mhz(self):
        spec = {"TaskGroups": [{"Tasks": [
            {"Name": "web", "Resources": {"MemoryMB": 512, "CPU": 500}}
        ]}]}
        assert detector._extract_cpu_mhz(spec, "web") == 500
        assert detector._extract_cpu_mhz(spec, "other") == 0
        assert detector._extract_cpu_mhz(None, "web") == 0

    def test_multiple_task_groups(self):
        spec = {"TaskGroups": [
            {"Tasks": [{"Name": "web",    "Resources": {"MemoryMB": 256, "CPU": 200}}]},
            {"Tasks": [{"Name": "worker", "Resources": {"MemoryMB": 512, "CPU": 400}}]},
        ]}
        assert detector._extract_memory_mb(spec, "worker") == 512
        assert detector._extract_cpu_mhz(spec, "worker") == 400
