"""
detector.py
Polls the Nomad API to identify anomalous allocations.

Detects:
  - restart_loop     : task restarted more than RESTART_THRESHOLD times
  - oom_killed       : exit code 137 or OOM message in task events
  - stuck_pending    : allocation stuck in 'pending' beyond threshold
  - stuck_starting   : task stuck in 'starting' state beyond threshold
  - image_pull_failure: task events indicate Docker image pull failure
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

log = structlog.get_logger()

ANOMALY_TYPES = {
    "restart_loop",
    "oom_killed",
    "stuck_pending",
    "stuck_starting",
    "image_pull_failure",
}


def _headers() -> dict:
    return {"X-Nomad-Token": NOMAD_TOKEN}


def _get(path: str, params: Optional[dict] = None) -> Optional[dict | list]:
    url = f"{NOMAD_ADDR}{path}"
    try:
        resp = requests.get(url, headers=_headers(), params=params, timeout=10)
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


def _detect_anomaly_type(
    alloc: dict,
    task_name: str,
    task_state: dict,
) -> Optional[str]:
    """
    Inspect a single task state and return the anomaly type, or None.
    Checks are ordered by severity so the most critical is returned first.
    """
    events: list[dict] = task_state.get("Events") or []
    restarts: int = task_state.get("Restarts", 0)
    state: str = task_state.get("State", "")

    # OOM killed — exit code 137 or explicit OOM message in events
    for event in events:
        msg = (event.get("DisplayMessage") or "").lower()
        details = str(event.get("Details") or "").lower()
        if "oom" in msg or "oom" in details:
            return "oom_killed"
        exit_code = event.get("ExitCode")
        if exit_code == 137:
            return "oom_killed"

    # Restart loop
    if restarts >= RESTART_THRESHOLD:
        return "restart_loop"

    # Image pull failure
    for event in events:
        msg = (event.get("DisplayMessage") or "").lower()
        if any(phrase in msg for phrase in ("failed to pull", "image not found", "no such image")):
            return "image_pull_failure"

    # Stuck pending — check at allocation level, not task level
    client_status = alloc.get("ClientStatus", "")
    if client_status == "pending":
        create_time_ns = alloc.get("CreateTime", 0)
        create_time_s = create_time_ns / 1e9
        if time.time() - create_time_s > PENDING_THRESHOLD_SECONDS:
            return "stuck_pending"

    # Stuck starting
    if state == "starting":
        # Use the most recent event timestamp as a proxy for when starting began
        if events:
            last_event_time_ns = events[-1].get("Time", 0)
            last_event_time_s = last_event_time_ns / 1e9
            if time.time() - last_event_time_s > STARTING_THRESHOLD_SECONDS:
                return "stuck_starting"

    return None


def fetch_logs(alloc_id: str, task_name: str, log_type: str = "stderr") -> str:
    """
    Fetch the last LOG_TAIL_LINES lines of logs for a task allocation.
    Falls back to stdout if stderr is empty.
    """
    for lt in (log_type, "stdout"):
        path = f"/v1/client/allocation/{alloc_id}/logs"
        params = {"task": task_name, "type": lt, "plain": "true"}
        try:
            url = f"{NOMAD_ADDR}{path}"
            resp = requests.get(
                url, headers=_headers(), params=params, timeout=15, stream=True
            )
            resp.raise_for_status()
            content = resp.text.strip()
            if content:
                lines = content.splitlines()
                return "\n".join(lines[-LOG_TAIL_LINES:])
        except Exception as e:
            log.debug("log_fetch_failed", alloc_id=alloc_id, task=task_name, type=lt, error=str(e))
    return ""


def _list_allocations() -> list[dict]:
    """Return all allocations, optionally filtered by namespace."""
    if WATCH_NAMESPACES:
        allocs: list[dict] = []
        for ns in WATCH_NAMESPACES:
            result = _get("/v1/allocations", params={"namespace": ns})
            if result:
                allocs.extend(result)
        return allocs
    result = _get("/v1/allocations", params={"namespace": "*"})
    return result if result else []


def detect_anomalies() -> list[dict]:
    """
    Poll Nomad and return a list of anomaly descriptors.

    Each descriptor contains everything the agent needs to:
      - send an alert
      - call Gemini for analysis
      - attempt remediation
    """
    anomalies: list[dict] = []
    allocs = _list_allocations()

    if not allocs:
        log.debug("no_allocations_found")
        return anomalies

    for alloc_summary in allocs:
        alloc_id = alloc_summary.get("ID", "")
        job_id = alloc_summary.get("JobID", "")
        namespace = alloc_summary.get("Namespace", "default")

        # Skip system jobs (Nomad internals) unless explicitly watched
        job_type = alloc_summary.get("JobType", "")
        if job_type == "system" and not WATCH_NAMESPACES:
            continue

        # Fetch full allocation detail for task states
        detail = _get(f"/v1/allocation/{alloc_id}")
        if not detail:
            continue

        task_states: dict = detail.get("TaskStates") or {}
        resources: dict = detail.get("AllocatedResources") or {}

        for task_name, task_state in task_states.items():
            anomaly_type = _detect_anomaly_type(alloc_summary, task_name, task_state)
            if not anomaly_type:
                continue

            # Fetch the job spec to get current resource limits
            job_spec = _get(f"/v1/job/{job_id}", params={"namespace": namespace})
            current_memory_mb = _extract_memory_mb(job_spec, task_name)
            current_cpu_mhz = _extract_cpu_mhz(job_spec, task_name)

            logs = fetch_logs(alloc_id, task_name)

            anomaly = {
                "job_id": job_id,
                "alloc_id": alloc_id,
                "task": task_name,
                "namespace": namespace,
                "anomaly_type": anomaly_type,
                "restarts": task_state.get("Restarts", 0),
                "client_status": alloc_summary.get("ClientStatus", ""),
                "task_state": task_state.get("State", ""),
                "events": (task_state.get("Events") or [])[-10:],
                "logs": logs,
                "current_memory_mb": current_memory_mb,
                "current_cpu_mhz": current_cpu_mhz,
                "job_spec": job_spec,
                "detected_at": time.time(),
            }

            log.info(
                "anomaly_detected",
                job=job_id,
                task=task_name,
                type=anomaly_type,
                restarts=task_state.get("Restarts", 0),
                namespace=namespace,
            )
            anomalies.append(anomaly)

    return anomalies


def _extract_memory_mb(job_spec: Optional[dict], task_name: str) -> int:
    """Walk the job spec to find the memory limit for a named task."""
    if not job_spec:
        return 0
    for group in job_spec.get("TaskGroups") or []:
        for task in group.get("Tasks") or []:
            if task.get("Name") == task_name:
                resources = task.get("Resources") or {}
                return resources.get("MemoryMB", 0)
    return 0


def _extract_cpu_mhz(job_spec: Optional[dict], task_name: str) -> int:
    """Walk the job spec to find the CPU limit for a named task."""
    if not job_spec:
        return 0
    for group in job_spec.get("TaskGroups") or []:
        for task in group.get("Tasks") or []:
            if task.get("Name") == task_name:
                resources = task.get("Resources") or {}
                return resources.get("CPU", 0)
    return 0
