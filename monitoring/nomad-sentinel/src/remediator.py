"""
remediator.py
Executes remediation actions against the Nomad API based on Gemini's
suggested_action. Every action is logged before and after execution.

Supported actions:
  - increase_memory : patch the task's MemoryMB and resubmit the job
  - restart         : stop the specific allocation via /v1/allocation/:id/stop
                      (no_shutdown_delay is a query parameter, not JSON body)
  - revert          : revert the job to its previous version, with
                      EnforceVersion as an optimistic concurrency lock
  - check_image     : no-op, alert only
  - manual_intervention : no-op, alert only
  - none            : no-op

API notes (verified against live Nomad API responses):
  - POST /v1/allocation/:id/stop  — no_shutdown_delay is a QUERY PARAMETER,
    not a JSON body field. Body is ignored by this endpoint.
  - POST /v1/job/:id              — Namespace must be in the Job object in
    the JSON body (already present when we deep-copy the fetched spec).
    The params={"namespace": ...} query arg on POST is redundant and removed.
  - POST /v1/job/:id/revert       — EnforceVersion should be set to the
    current version as an optimistic lock to prevent reverting to the wrong
    version if a concurrent change incremented it between our fetch and revert.
"""

import copy
from typing import Optional

import requests
import structlog

from config import NOMAD_ADDR, NOMAD_TOKEN
from nomad_client import session as _session

log = structlog.get_logger()


class RemediationError(Exception):
    """Raised when a remediation action fails to execute against Nomad."""


def _headers() -> dict:
    return {"X-Nomad-Token": NOMAD_TOKEN, "Content-Type": "application/json"}


def remediate(anomaly: dict, analysis: dict) -> dict:
    """
    Dispatch to the correct remediation function based on suggested_action.
    Returns a result dict describing what was done (or not done).
    Never raises — all errors are caught and returned in the result.
    """
    action = analysis.get("suggested_action", "manual_intervention")
    job_id = anomaly.get("job_id", "unknown")

    log.info("remediation_starting", job=job_id, action=action)

    try:
        if action == "increase_memory":
            return _increase_memory(anomaly, analysis)
        elif action == "restart":
            return _restart_allocation(anomaly)
        elif action == "revert":
            return _revert_job(anomaly)
        elif action in ("check_image", "manual_intervention", "none"):
            log.info("remediation_skipped_no_action", job=job_id, action=action)
            return {"action_taken": "none", "reason": f"action '{action}' requires human review"}
        else:
            log.warning("remediation_unknown_action", job=job_id, action=action)
            return {"action_taken": "none", "reason": f"unrecognised action '{action}'"}
    except RemediationError as e:
        log.error("remediation_failed", job=job_id, action=action, error=str(e))
        return {"action_taken": "failed", "reason": str(e)}
    except Exception as e:
        log.error("remediation_unexpected_error", job=job_id, action=action, error=str(e))
        return {"action_taken": "failed", "reason": f"unexpected error: {e}"}


def _fetch_job(job_id: str, namespace: str) -> dict:
    url = f"{NOMAD_ADDR}/v1/job/{job_id}"
    try:
        resp = _session.get(
            url, headers=_headers(), params={"namespace": namespace}, timeout=10
        )
        resp.raise_for_status()
        return resp.json()
    except requests.exceptions.RequestException as e:
        raise RemediationError(f"failed to fetch job spec for {job_id}: {e}")


def _submit_job(job_id: str, job_spec: dict) -> None:
    """
    Submit an updated job spec to Nomad.
    Namespace is already present in the job_spec dict (copied from the
    fetched spec) — no need for a namespace query param on POST.
    """
    url = f"{NOMAD_ADDR}/v1/job/{job_id}"
    payload = {"Job": job_spec}
    try:
        resp = _session.post(
            url,
            headers=_headers(),
            json=payload,
            timeout=15,
        )
        resp.raise_for_status()
    except requests.exceptions.RequestException as e:
        raise RemediationError(f"failed to submit updated job spec for {job_id}: {e}")


def _increase_memory(anomaly: dict, analysis: dict) -> dict:
    job_id = anomaly["job_id"]
    task_name = anomaly["task"]
    namespace = anomaly.get("namespace", "default")
    extra_mb = analysis.get("memory_increase_mb", 0)

    if extra_mb <= 0:
        log.warning("increase_memory_skipped_zero_amount", job=job_id)
        return {"action_taken": "none", "reason": "memory_increase_mb was 0 or invalid"}

    job_spec = anomaly.get("job_spec") or _fetch_job(job_id, namespace)
    job_spec = copy.deepcopy(job_spec)

    task_found = False
    old_memory = 0
    new_memory = 0

    for group in job_spec.get("TaskGroups") or []:
        for task in group.get("Tasks") or []:
            if task.get("Name") == task_name:
                resources = task.setdefault("Resources", {})
                old_memory = resources.get("MemoryMB", 0)
                new_memory = old_memory + extra_mb
                resources["MemoryMB"] = new_memory
                task_found = True

    if not task_found:
        raise RemediationError(f"task '{task_name}' not found in job spec for {job_id}")

    _submit_job(job_id, job_spec)

    log.info(
        "memory_increased",
        job=job_id,
        task=task_name,
        old_memory_mb=old_memory,
        new_memory_mb=new_memory,
    )

    return {
        "action_taken": "increase_memory",
        "old_memory_mb": old_memory,
        "new_memory_mb": new_memory,
    }


def _restart_allocation(anomaly: dict) -> dict:
    """
    Stop a specific allocation, causing Nomad to reschedule it.

    Endpoint: POST /v1/allocation/:id/stop
    no_shutdown_delay is a QUERY PARAMETER — the JSON body is ignored
    by this endpoint. Passing it as a JSON body (the prior bug) had no
    effect since the endpoint doesn't read the body at all.
    """
    alloc_id = anomaly["alloc_id"]
    url = f"{NOMAD_ADDR}/v1/allocation/{alloc_id}/stop"

    try:
        resp = _session.post(
            url,
            headers=_headers(),
            params={"no_shutdown_delay": "false"},
            timeout=10,
        )
        resp.raise_for_status()
    except requests.exceptions.RequestException as e:
        raise RemediationError(f"failed to stop allocation {alloc_id}: {e}")

    log.info("allocation_restarted", alloc_id=alloc_id, job=anomaly.get("job_id"))
    return {"action_taken": "restart", "alloc_id": alloc_id}


def _revert_job(anomaly: dict) -> dict:
    """
    Revert a job to its previous version.

    EnforceVersion is set to the current version as an optimistic
    concurrency lock: if another process incremented the version between
    our fetch and this revert call, the API rejects the request rather
    than silently reverting to the wrong version.
    """
    job_id = anomaly["job_id"]
    namespace = anomaly.get("namespace", "default")

    job_spec = anomaly.get("job_spec") or _fetch_job(job_id, namespace)
    current_version = job_spec.get("Version", 0)

    if current_version <= 0:
        raise RemediationError(f"job {job_id} has no previous version to revert to")

    target_version = current_version - 1
    url = f"{NOMAD_ADDR}/v1/job/{job_id}/revert"
    payload = {
        "JobID":          job_id,
        "JobVersion":     target_version,
        "EnforceVersion": current_version,
    }

    try:
        resp = _session.post(
            url,
            headers=_headers(),
            json=payload,
            timeout=15,
        )
        resp.raise_for_status()
    except requests.exceptions.RequestException as e:
        raise RemediationError(
            f"failed to revert job {job_id} to version {target_version}: {e}"
        )

    log.info(
        "job_reverted",
        job=job_id,
        from_version=current_version,
        to_version=target_version,
    )
    return {
        "action_taken":   "revert",
        "from_version":   current_version,
        "to_version":     target_version,
    }
