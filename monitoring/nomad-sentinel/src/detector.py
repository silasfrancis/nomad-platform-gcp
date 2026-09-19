"""
detector.py
Polls the Nomad API to identify anomalous allocations.

All API behaviour verified against real Nomad 1.11.0 wire responses
(collected June 2026 from a live local Nomad dev agent).

Polling strategy:
  GET /v1/allocations?namespace=*   — all allocs across all namespaces in
                                      one call. Has JobType + TaskStates
                                      inline. Does NOT have AllocatedResources
                                      or embedded Job spec.
  GET /v1/job/:id                   — full job spec for resource limits
                                      (CPU, MemoryMB). Fetched once per
                                      job_id per cycle, cached.
  GET /v1/client/fs/logs/:alloc_id  — task logs (plain=true, bounded response)

Confirmed TaskState.State wire values (from docs + real responses):
  "pending"  — waiting to run, or failed and waiting to restart
  "running"  — currently running
  "dead"     — finished, will not run again

There is NO "starting" value. A task downloading an image sits in "pending".

Confirmed event Type wire values (from real responses):
  "Received", "Task Setup", "Driver", "Driver Failure", "Started",
  "Terminated", "Restarting", "Not Restarting", "Killing", "Killed"

Image pull failure CONFIRMED:
  event.Type == "Driver Failure" (two words, space between)
  event.DriverError contains the pull error message
  event.DisplayMessage also contains it
  Task stays in State="pending" while retrying pulls
  Alloc ClientStatus stays "pending" during pull retries
  After exhausting restart policy: State="dead", ClientStatus="failed"
  A stuck image pull loop ALSO produces high Restarts count — so
  image_pull_failure must be detected BEFORE restart_loop to avoid
  misclassification.

OOM kill CONFIRMED:
  event.Type == "Terminated"
  event.Details["oom_killed"] == "true"  (STRING, not boolean)
  Exit code 137 alone is not sufficient (SIGKILL from any source = 137)
"""

import time
from typing import Optional

import requests
import structlog

from config import (
    NOMAD_ADDR,
    NOMAD_TOKEN,
    RESTART_THRESHOLD,
    PENDING_THRESHOLD_SECONDS,
    STARTING_THRESHOLD_SECONDS,
    LOG_TAIL_LINES,
    WATCH_NAMESPACES,
)
from nomad_client import session as _session

log = structlog.get_logger()

# Event Types that indicate a driver-level start attempt is in progress.
# Used for stuck_starting detection.
_DRIVER_EVENTS = {"Driver", "Task Setup"}

# Event Type that confirms an image pull (or other driver) failure.
# Presence of this type overrides stuck_starting classification.
_DRIVER_FAILURE_TYPE = "Driver Failure"


def _headers() -> dict:
    return {"X-Nomad-Token": NOMAD_TOKEN}


def _get(path: str, params: Optional[dict] = None) -> Optional[dict | list]:
    url = f"{NOMAD_ADDR}{path}"
    try:
        resp = _session.get(url, headers=_headers(), params=params, timeout=10)
        resp.raise_for_status()
        return resp.json()
    except requests.exceptions.Timeout:
        log.warning("nomad_request_timeout", url=url)
    except requests.exceptions.ConnectionError:
        log.warning("nomad_connection_error", url=url)
    except requests.exceptions.HTTPError as e:
        log.warning("nomad_http_error", url=url, status=e.response.status_code)
    except Exception as e:
        log.error("nomad_unexpected_error", url=url, error=str(e))
    return None


def _is_oom_killed(event: dict) -> bool:
    """
    OOM is confirmed by:
      event.Type == "Terminated"
      event.Details["oom_killed"] == "true"   ← STRING, not boolean

    Exit code 137 alone is not reliable — SIGKILL from any source gives 137.
    Verified against real API responses.
    """
    if event.get("Type") != "Terminated":
        return False
    return (event.get("Details") or {}).get("oom_killed") == "true"


def _has_image_pull_failure(events: list[dict]) -> bool:
    """
    Image pull failure is signalled by event.Type == "Driver Failure"
    (two words, confirmed from real responses — not "Driver").

    Check both the Type and that DriverError or DisplayMessage contains
    pull-related keywords to avoid false positives from other driver errors.
    """
    for event in events:
        if event.get("Type") != _DRIVER_FAILURE_TYPE:
            continue
        driver_err = (event.get("DriverError") or "").lower()
        display_msg = (event.get("DisplayMessage") or "").lower()
        combined = driver_err + " " + display_msg
        if any(phrase in combined for phrase in (
            "failed to pull",
            "failed to resolve reference",
            "image not found",
            "no such image",
            "pull access denied",
            "manifest unknown",
            "tls handshake timeout",   # confirmed in real pull-failure events
            "name unknown",
        )):
            return True
    return False


def _detect_anomaly_type(
    alloc_stub: dict,
    task_name: str,
    task_state: dict,
) -> Optional[str]:
    """
    Inspect a single task state and return the anomaly type, or None.

    Priority order (most severe / most specific first):
      1. oom_killed
      2. image_pull_failure   ← must be before restart_loop because a pull
                                 loop also produces high restart counts
      3. restart_loop
      4. stuck_pending
      5. stuck_starting       ← only if no Driver Failure events present
    """
    events: list[dict] = task_state.get("Events") or []
    restarts: int = task_state.get("Restarts", 0)
    state: str = task_state.get("State", "")  # "pending", "running", "dead"

    # 1. OOM killed
    for event in events:
        if _is_oom_killed(event):
            return "oom_killed"

    # 2. Image pull failure — check BEFORE restart_loop because a pull
    #    failure loop also increments Restarts (confirmed: Restarts=19 in
    #    real response with only Driver Failure events, no Terminated events)
    if _has_image_pull_failure(events):
        return "image_pull_failure"

    # 3. Restart loop — fires on any State value (confirmed: a pending task
    #    with Restarts=19 is a real scenario from live API responses)
    if restarts >= RESTART_THRESHOLD:
        return "restart_loop"

    # 4. Stuck pending — allocation-level check.
    #    ClientStatus="pending" means Nomad hasn't placed or started the task.
    #    CreateTime is in nanoseconds (confirmed from real responses).
    client_status = alloc_stub.get("ClientStatus", "")
    if client_status == "pending":
        create_time_s = alloc_stub.get("CreateTime", 0) / 1e9
        if time.time() - create_time_s > PENDING_THRESHOLD_SECONDS:
            return "stuck_pending"

    # 5. Stuck starting — task State is "pending" WITH a driver-start event
    #    (meaning the container layer was reached) AND elapsed > threshold.
    #    Exclude this if Driver Failure events are present — that is
    #    image_pull_failure (already handled above), not stuck_starting.
    #    NOTE: "starting" is not a real Nomad TaskState.State value.
    if state == "pending" and not _has_image_pull_failure(events):
        driver_events = [
            ev for ev in events
            if ev.get("Type") in _DRIVER_EVENTS
        ]
        if driver_events:
            last_ns = driver_events[-1].get("Time", 0)
            elapsed = time.time() - (last_ns / 1e9)
            if elapsed > STARTING_THRESHOLD_SECONDS:
                return "stuck_starting"

    return None


def fetch_logs(alloc_id: str, task_name: str, log_type: str = "stderr") -> str:
    """
    Fetch task logs via the confirmed Nomad client filesystem endpoint.

    Confirmed working URL format (from real API responses):
      GET /v1/client/fs/logs/{alloc_id}?task={task}&type={type}&plain=true

    With plain=true the response is bounded plain text (not a streaming
    JSON frame sequence). No follow, offset, or origin parameters needed
    for the plain=true mode — confirmed from working real API calls.

    Falls back to stdout if stderr is empty or the request fails.
    Dead tasks (like the crasher) may return empty logs — handled gracefully.
    """
    for lt in (log_type, "stdout"):
        url = f"{NOMAD_ADDR}/v1/client/fs/logs/{alloc_id}"
        params = {"task": task_name, "type": lt, "plain": "true"}
        try:
            resp = _session.get(url, headers=_headers(), params=params, timeout=15)
            resp.raise_for_status()
            content = resp.text.strip()
            if content and content != "NO_LOG_OUTPUT":
                lines = content.splitlines()
                return "\n".join(lines[-LOG_TAIL_LINES:])
        except Exception as e:
            log.debug("log_fetch_failed", alloc_id=alloc_id,
                      task=task_name, type=lt, error=str(e))
    return ""


def _list_allocations() -> list[dict]:
    """
    GET /v1/allocations — confirmed to exist and return the same fields
    as /v1/job/:id/allocations, including JobType and TaskStates.

    Using namespace=* fetches all namespaces in one call, which is more
    efficient than GET /v1/jobs + per-job GET /v1/job/:id/allocations.

    When WATCH_NAMESPACES is set, filter to those namespaces instead.
    """
    if WATCH_NAMESPACES:
        allocs: list[dict] = []
        for ns in WATCH_NAMESPACES:
            result = _get("/v1/allocations", params={"namespace": ns})
            if result:
                allocs.extend(result)
        return allocs
    return _get("/v1/allocations", params={"namespace": "*"}) or []


def detect_anomalies() -> list[dict]:
    """
    Poll all Nomad allocations and return anomaly descriptors.

    Strategy (using confirmed, tested endpoints only):
    1. GET /v1/allocations?namespace=*  — all alloc stubs with TaskStates
       and JobType inline. Single call covers all namespaces.
    2. GET /v1/job/:id  — full job spec for CPU/MemoryMB resource limits.
       Fetched once per job_id per cycle (cached). The embedded Job on
       /v1/allocation/:id is stale per the API docs — use /v1/job/:id.
    3. GET /v1/client/fs/logs/:alloc_id  — logs for anomalous tasks only.

    /v1/allocation/:id detail is NOT called. All detection data is on
    the list stub. The detail endpoint adds AllocatedResources, Metrics,
    and an embedded (potentially stale) Job copy — none needed here.
    """
    anomalies: list[dict] = []
    alloc_stubs = _list_allocations()

    if not alloc_stubs:
        log.debug("no_allocations_found")
        return anomalies

    # Cache job specs within one polling cycle
    job_spec_cache: dict[str, Optional[dict]] = {}

    for alloc_stub in alloc_stubs:
        alloc_id   = alloc_stub.get("ID", "")
        job_id     = alloc_stub.get("JobID", "")
        namespace  = alloc_stub.get("Namespace", "default")

        # JobType IS present on /v1/allocations stubs (confirmed)
        job_type = alloc_stub.get("JobType", "")
        if job_type == "system":
            continue

        task_states: dict = alloc_stub.get("TaskStates") or {}
        if not task_states:
            continue

        for task_name, task_state in task_states.items():
            anomaly_type = _detect_anomaly_type(alloc_stub, task_name, task_state)
            if not anomaly_type:
                continue

            # Fetch job spec for resource limits (cached per job_id).
            # The API docs explicitly note the embedded Job on the alloc
            # detail may be stale — always use /v1/job/:id for current spec.
            if job_id not in job_spec_cache:
                job_spec_cache[job_id] = _get(
                    f"/v1/job/{job_id}", params={"namespace": namespace}
                )
            job_spec = job_spec_cache[job_id]

            logs = fetch_logs(alloc_id, task_name)

            anomaly = {
                "job_id":            job_id,
                "alloc_id":          alloc_id,
                "task":              task_name,
                "namespace":         namespace,
                "anomaly_type":      anomaly_type,
                "restarts":          task_state.get("Restarts", 0),
                "client_status":     alloc_stub.get("ClientStatus", ""),
                "task_state":        task_state.get("State", ""),
                "events":            (task_state.get("Events") or [])[-10:],
                "logs":              logs,
                "current_memory_mb": _extract_memory_mb(job_spec, task_name),
                "current_cpu_mhz":   _extract_cpu_mhz(job_spec, task_name),
                "job_spec":          job_spec,
                "detected_at":       time.time(),
            }

            log.info("anomaly_detected", job=job_id, task=task_name,
                     type=anomaly_type, restarts=task_state.get("Restarts", 0),
                     namespace=namespace)
            anomalies.append(anomaly)

    return anomalies


def _extract_memory_mb(job_spec: Optional[dict], task_name: str) -> int:
    if not job_spec:
        return 0
    for group in job_spec.get("TaskGroups") or []:
        for task in group.get("Tasks") or []:
            if task.get("Name") == task_name:
                return (task.get("Resources") or {}).get("MemoryMB", 0)
    return 0


def _extract_cpu_mhz(job_spec: Optional[dict], task_name: str) -> int:
    if not job_spec:
        return 0
    for group in job_spec.get("TaskGroups") or []:
        for task in group.get("Tasks") or []:
            if task.get("Name") == task_name:
                return (task.get("Resources") or {}).get("CPU", 0)
    return 0
