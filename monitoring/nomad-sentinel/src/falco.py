"""
falco.py
Handles Falco security alerts pushed in from falco-webhook (see
monitoring/falco-webhook/main.go — it POSTs its native FalcoAlert JSON
shape to this agent's /anomaly endpoint for anything >= WARNING priority).

This is deliberately a separate, simpler path from the main Nomad polling
loop in detector.py/main.py, for one important reason:

  A Falco alert gives us no verified Nomad alloc_id/job_id — only
  best-effort container/process identifiers Falco happened to capture.
  Nomad's own detector.py anomalies are always tied to a real alloc
  fetched from the Nomad API, so remediator.py can safely act on them.
  A Falco-sourced anomaly has no such guarantee, and even if it did,
  "restart"/"revert" a workload is not a meaningful response to a
  security event (it doesn't address the underlying activity and may
  destroy evidence). So this path always alerts and records history,
  and NEVER calls remediator.py — regardless of what Gemini's
  suggested_action comes back as. That's enforced here, not just by
  prompt instructions to Gemini.

No StateTracker/cooldown here either: cooldown/max-attempts in state.py
exist to stop the agent from repeatedly *remediating* the same job — since
this path never remediates, that machinery doesn't apply. If Falco itself
fires the same rule repeatedly, that's a Falco-side rate-limiting concern
(Falco's outputs already have their own throttling), not this agent's.
"""

import time
from datetime import datetime, timezone

import structlog

import alerter
import gemini_client
import history

log = structlog.get_logger()

# Falco priority values below this are not escalated by falco-webhook
# itself (see severityAtLeastWarning in falco-webhook), but this module
# stays defensive in case that ever changes upstream.
_REQUIRED_FIELDS = ("output", "priority", "rule")


class FalcoPayloadError(ValueError):
    """Raised when an incoming payload doesn't look like a Falco alert."""


def _parse_time(raw: str) -> float:
    """
    Falco's native http_output "time" field is an RFC3339 timestamp.
    Falls back to now() if missing or unparseable — this is only used
    for display/history ordering, never for triage logic.
    """
    if not raw:
        return time.time()
    try:
        # Falco emits nanosecond precision ("...123456789Z"); Python's
        # fromisoformat only handles up to microseconds, so truncate.
        cleaned = raw.replace("Z", "+00:00")
        if "." in cleaned:
            head, _, tail = cleaned.partition(".")
            frac, _, tz = tail.partition("+")
            cleaned = f"{head}.{frac[:6]}+{tz}" if tz else f"{head}.{frac[:6]}"
        return datetime.fromisoformat(cleaned).timestamp()
    except (ValueError, IndexError):
        return time.time()


def build_anomaly_from_falco(payload: dict) -> dict:
    """
    Maps a Falco native http_output payload onto this agent's internal
    anomaly dict shape (the same shape detector.py produces), so it can
    flow through gemini_client.analyze()/alerter/history unchanged.

    Deliberately does NOT try to reverse-engineer a Nomad job_id/alloc_id
    out of Falco's container fields — Nomad's Docker-driver container
    naming isn't something this codebase has confirmed against a real
    response (unlike detector.py's API assumptions, which are), so
    guessing at it would produce a job_id that looks authoritative but
    might be wrong. Falco's own identifiers are surfaced as-is instead.
    """
    missing = [f for f in _REQUIRED_FIELDS if not payload.get(f)]
    if missing:
        raise FalcoPayloadError(f"missing required field(s): {', '.join(missing)}")

    output_fields = payload.get("output_fields") or {}
    rule = payload["rule"]
    hostname = payload.get("hostname", "unknown")

    container_name = output_fields.get("container.name")
    container_id = output_fields.get("container.id")
    proc_name = output_fields.get("proc.name")

    # Best-effort, honestly-labelled identifiers — never fabricated.
    job_id = str(container_name) if container_name else f"falco-host:{hostname}"
    task = str(proc_name) if proc_name else "unknown"
    alloc_id = str(container_id) if container_id else "unknown"

    anomaly_type = f"falco:{rule}"

    anomaly = {
        "source":            "falco",
        "job_id":            job_id,
        "alloc_id":          alloc_id,
        "task":              task,
        "namespace":         "unknown",  # Falco has no concept of Nomad namespace
        "anomaly_type":      anomaly_type,
        "restarts":          0,
        "client_status":     "",
        "task_state":        "",
        "events":            [],
        "logs":              "",
        "current_memory_mb": "unknown",
        "current_cpu_mhz":   "unknown",
        "job_spec":          None,
        "detected_at":       _parse_time(payload.get("time", "")),
        # Raw Falco fields, kept alongside for the Falco-specific Gemini
        # prompt and for anything else that wants the original payload.
        "falco": {
            "output":        payload.get("output", ""),
            "priority":      payload.get("priority", "unknown"),
            "rule":          rule,
            "hostname":      hostname,
            "tags":          payload.get("tags", []) or [],
            "output_fields": output_fields,
        },
    }
    return anomaly


def handle_falco_alert(payload: dict) -> dict:
    """
    Full handling of one incoming Falco alert: build the anomaly, triage
    it with Gemini, alert, and record history. Always alert-only — never
    calls remediator.py. Never raises; returns a small result dict for
    logging/debugging by the caller.
    """
    try:
        anomaly = build_anomaly_from_falco(payload)
    except FalcoPayloadError as e:
        log.warning("falco_payload_invalid", error=str(e), payload=payload)
        return {"status": "rejected", "reason": str(e)}

    log.info(
        "falco_alert_received",
        rule=anomaly["falco"]["rule"],
        priority=anomaly["falco"]["priority"],
        job=anomaly["job_id"],
        task=anomaly["task"],
    )

    analysis = gemini_client.analyze(anomaly)

    alerter.send_alert(anomaly, analysis)
    history.record(anomaly, analysis, outcome="alerted_only")

    log.info(
        "falco_alert_handled",
        job=anomaly["job_id"],
        severity=analysis.get("severity"),
        confidence=analysis.get("confidence"),
    )
    return {
        "status": "processed",
        "severity": analysis.get("severity"),
        "confidence": analysis.get("confidence"),
    }
