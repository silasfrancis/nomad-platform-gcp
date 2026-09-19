"""
gemini_client.py
Sends anomaly context to Gemini and parses the structured response.

Uses the google-genai SDK (the current, actively maintained Google GenAI
SDK), NOT the legacy google-generativeai package, which was deprecated
and reached end-of-life on November 30, 2025.

The prompt is designed to:
  - Give Gemini enough context to distinguish crash types
  - Request a strictly structured JSON response (enforced via
    response_mime_type="application/json", not just prompt instructions)
  - Avoid ambiguous remediation suggestions

Expected Gemini response shape:
{
  "likely_cause": "Java heap space exhaustion — service needs more memory",
  "severity": "high",
  "suggested_action": "increase_memory",
  "memory_increase_mb": 256,
  "confidence": 0.91,
  "summary": "One-line human-readable summary for Slack alert"
}
"""

import json

from google import genai
from google.genai import types
import structlog

from config import GEMINI_API_KEY, GEMINI_MODEL, ENVIRONMENT

log = structlog.get_logger()

# google-genai uses a client object rather than module-level configure().
# Created once at import time and reused across calls.
_client = genai.Client(api_key=GEMINI_API_KEY)

VALID_ACTIONS = {
    "increase_memory",
    "restart",
    "revert",
    "check_image",
    "manual_intervention",
    "none",
}

VALID_SEVERITIES = {"low", "medium", "high", "critical"}

# Enforced server-side via response_mime_type/response_schema below, so
# the model cannot return prose, markdown fences, or malformed JSON shape.
_RESPONSE_SCHEMA = {
    "type": "object",
    "properties": {
        "likely_cause": {"type": "string"},
        "severity": {"type": "string", "enum": sorted(VALID_SEVERITIES)},
        "suggested_action": {"type": "string", "enum": sorted(VALID_ACTIONS)},
        "memory_increase_mb": {"type": "integer"},
        "confidence": {"type": "number"},
        "summary": {"type": "string"},
    },
    "required": [
        "likely_cause",
        "severity",
        "suggested_action",
        "memory_increase_mb",
        "confidence",
        "summary",
    ],
}

_PROMPT_TEMPLATE = """\
You are a platform reliability engineer analysing a Nomad workload failure.

Environment: {environment}
Anomaly type: {anomaly_type}
Job: {job_id}
Task: {task}
Namespace: {namespace}
Restart count: {restarts}
Current memory limit: {memory_mb}MB
Current CPU limit: {cpu_mhz}MHz

Recent task events (last 10):
{events}

Recent logs ({log_type}, last {log_lines} lines):
{logs}

Determine the likely cause, severity, and suggested action.

Rules:
- suggested_action must be one of: increase_memory, restart, revert, check_image, manual_intervention, none
- Use increase_memory only when logs clearly show OOM, heap exhaustion, or memory pressure
- Use restart for transient failures, dependency not ready, or connection refused at startup
- Use revert when a recent deployment is the likely cause of the regression
- Use check_image when the failure is clearly a missing or inaccessible Docker image
- Use manual_intervention when the cause is unclear or requires human judgement
- memory_increase_mb should be a reasonable increment: 128, 256, or 512 — not arbitrary large values, and 0 if increase_memory is not the suggested action
- confidence reflects how certain you are given the available evidence, from 0.0 to 1.0
- summary should be one sentence suitable for a Slack alert
"""

# Falco security alerts are a fundamentally different kind of anomaly from a
# Nomad workload crash, and none of the workload-remediation actions apply
# to them — restarting or reverting a job does not address "a shell was
# spawned in a container" and may destroy evidence. This agent never takes
# automated action on a Falco-sourced anomaly regardless of what is
# returned here (enforced in falco.py, not just by this prompt) — this
# analysis exists purely to triage severity and surface a clear summary
# for a human, same as a low-confidence Nomad anomaly would be.
_FALCO_PROMPT_TEMPLATE = """\
You are a platform security engineer triaging a Falco runtime security alert
from a workload running on a Nomad cluster.

Environment: {environment}
Falco rule: {rule}
Falco priority: {priority}
Falco output: {output}
Host: {hostname}
Container/task (best-effort, may be "unknown"): {job_id}
Process (best-effort, may be "unknown"): {task}
Tags: {tags}
Other output fields:
{events}

Determine the likely cause, severity, and suggested action.

Rules:
- suggested_action must be one of: increase_memory, restart, revert, check_image, manual_intervention, none
- None of increase_memory, restart, revert, or check_image are ever appropriate here — they are Nomad workload-crash remediations, not security responses, and this agent will not execute them regardless of your answer. Use manual_intervention for anything a human should review, or none only if this is clearly benign/informational and needs no follow-up.
- severity should reflect actual security risk, not Falco's own priority field verbatim — a "warning"-priority rule that fired on expected, benign behaviour is not automatically "medium" severity
- likely_cause should explain what the underlying activity was and why Falco flagged it, in plain language for someone who may not know this rule
- confidence reflects how certain you are that this is a genuine security concern (not a false positive) given the available evidence, from 0.0 to 1.0
- summary should be one sentence suitable for a Slack alert
- memory_increase_mb must be 0
"""


def _build_prompt(anomaly: dict) -> str:
    if anomaly.get("source") == "falco":
        return _build_falco_prompt(anomaly)

    events_str = json.dumps(anomaly.get("events", []), indent=2)
    logs = anomaly.get("logs", "")
    log_lines = len(logs.splitlines()) if logs else 0

    return _PROMPT_TEMPLATE.format(
        environment=ENVIRONMENT,
        anomaly_type=anomaly.get("anomaly_type", "unknown"),
        job_id=anomaly.get("job_id", "unknown"),
        task=anomaly.get("task", "unknown"),
        namespace=anomaly.get("namespace", "default"),
        restarts=anomaly.get("restarts", 0),
        memory_mb=anomaly.get("current_memory_mb", "unknown"),
        cpu_mhz=anomaly.get("current_cpu_mhz", "unknown"),
        events=events_str,
        log_type="stderr",
        log_lines=log_lines,
        logs=logs or "(no logs available)",
    )


def _build_falco_prompt(anomaly: dict) -> str:
    falco = anomaly.get("falco", {})
    output_fields = falco.get("output_fields", {})

    return _FALCO_PROMPT_TEMPLATE.format(
        environment=ENVIRONMENT,
        rule=falco.get("rule", "unknown"),
        priority=falco.get("priority", "unknown"),
        output=falco.get("output", "(no output text)"),
        hostname=falco.get("hostname", "unknown"),
        job_id=anomaly.get("job_id", "unknown"),
        task=anomaly.get("task", "unknown"),
        tags=", ".join(falco.get("tags", []) or []) or "(none)",
        events=json.dumps(output_fields, indent=2, default=str) or "(none)",
    )


def _validate_response(parsed: dict) -> dict:
    """
    Validate and sanitise the Gemini response.
    The response schema constrains the shape server-side, but we still
    re-validate defensively here in case of partial/empty fields.
    """
    suggested_action = parsed.get("suggested_action", "manual_intervention")
    if suggested_action not in VALID_ACTIONS:
        log.warning("invalid_suggested_action", action=suggested_action)
        suggested_action = "manual_intervention"

    severity = parsed.get("severity", "medium")
    if severity not in VALID_SEVERITIES:
        log.warning("invalid_severity", severity=severity)
        severity = "medium"

    confidence = float(parsed.get("confidence", 0.0))
    confidence = max(0.0, min(1.0, confidence))

    memory_increase_mb = int(parsed.get("memory_increase_mb", 0))
    # Cap at a sane maximum to prevent runaway memory scaling
    memory_increase_mb = min(memory_increase_mb, 1024)

    return {
        "likely_cause": str(parsed.get("likely_cause", "Unknown")),
        "severity": severity,
        "suggested_action": suggested_action,
        "memory_increase_mb": memory_increase_mb,
        "confidence": confidence,
        "summary": str(parsed.get("summary", "Nomad workload anomaly detected")),
    }


def analyze(anomaly: dict) -> dict:
    """
    Send anomaly context to Gemini and return a validated analysis dict.
    Returns a safe fallback on any error so the agent loop never crashes
    due to a Gemini API failure.
    """
    prompt = _build_prompt(anomaly)

    try:
        response = _client.models.generate_content(
            model=GEMINI_MODEL,
            contents=prompt,
            config=types.GenerateContentConfig(
                response_mime_type="application/json",
                response_schema=_RESPONSE_SCHEMA,
                thinking_config=types.ThinkingConfig(thinking_budget=0),
            ),
        )

        parsed = json.loads(response.text)
        result = _validate_response(parsed)

        log.info(
            "gemini_analysis_complete",
            job=anomaly.get("job_id"),
            task=anomaly.get("task"),
            severity=result["severity"],
            suggested_action=result["suggested_action"],
            confidence=result["confidence"],
        )
        return result

    except json.JSONDecodeError as e:
        log.error("gemini_json_parse_error", error=str(e), job=anomaly.get("job_id"))
    except Exception as e:
        log.error("gemini_api_error", error=str(e), job=anomaly.get("job_id"))

    # Safe fallback — alert but do not attempt remediation
    return {
        "likely_cause": "Gemini analysis unavailable",
        "severity": "medium",
        "suggested_action": "manual_intervention",
        "memory_increase_mb": 0,
        "confidence": 0.0,
        "summary": f"Anomaly detected on {anomaly.get('job_id')} — Gemini analysis failed, manual review required",
    }
