"""
gemini_client.py
Sends anomaly context to Gemini 1.5 Flash and parses the structured response.

The prompt is designed to:
  - Give Gemini enough context to distinguish crash types
  - Request a strictly structured JSON response
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
from typing import Optional

import google.generativeai as genai
import structlog

from config import GEMINI_API_KEY, GEMINI_MODEL, ENVIRONMENT

log = structlog.get_logger()

# Configure the SDK once at import time
genai.configure(api_key=GEMINI_API_KEY)
_model = genai.GenerativeModel(GEMINI_MODEL)

VALID_ACTIONS = {
    "increase_memory",
    "restart",
    "revert",
    "check_image",
    "manual_intervention",
    "none",
}

VALID_SEVERITIES = {"low", "medium", "high", "critical"}

_PROMPT_TEMPLATE = """\
You are a platform reliability engineer analysing a Nomad workload failure.
Respond with a single JSON object only. No markdown. No explanation outside the JSON.

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

Respond with this exact JSON structure:
{{
  "likely_cause": "<concise technical explanation>",
  "severity": "<low|medium|high|critical>",
  "suggested_action": "<increase_memory|restart|revert|check_image|manual_intervention|none>",
  "memory_increase_mb": <integer, 0 if not applicable>,
  "confidence": <float 0.0 to 1.0>,
  "summary": "<one sentence for Slack alert>"
}}

Rules:
- suggested_action must be one of: increase_memory, restart, revert, check_image, manual_intervention, none
- Use increase_memory only when logs clearly show OOM, heap exhaustion, or memory pressure
- Use restart for transient failures, dependency not ready, or connection refused at startup
- Use revert when a recent deployment is the likely cause of the regression
- Use check_image when the failure is clearly a missing or inaccessible Docker image
- Use manual_intervention when the cause is unclear or requires human judgement
- memory_increase_mb should be a reasonable increment: 128, 256, or 512 — not arbitrary large values
- confidence reflects how certain you are given the available evidence
"""


def _build_prompt(anomaly: dict) -> str:
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


def _validate_response(parsed: dict) -> dict:
    """
    Validate and sanitise the Gemini response.
    Returns a safe default if fields are missing or invalid.
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
        response = _model.generate_content(prompt)
        raw_text = response.text.strip()

        # Strip markdown code fences if Gemini wraps the JSON
        if raw_text.startswith("```"):
            lines = raw_text.splitlines()
            raw_text = "\n".join(
                line for line in lines
                if not line.strip().startswith("```")
            )

        parsed = json.loads(raw_text)
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
