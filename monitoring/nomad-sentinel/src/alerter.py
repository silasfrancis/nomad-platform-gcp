"""
alerter.py
Sends alerts to Slack via incoming webhook.

Alert severity maps to Slack message colour/emoji.
All alerts include: environment, job, task, anomaly type, Gemini analysis,
and remediation outcome (if any action was taken).
"""

from typing import Optional

import requests
import structlog

from config import SLACK_WEBHOOK_URL, ENVIRONMENT

log = structlog.get_logger()

_SEVERITY_EMOJI = {
    "low": ":large_blue_circle:",
    "medium": ":large_yellow_circle:",
    "high": ":red_circle:",
    "critical": ":rotating_light:",
}

_SEVERITY_COLOR = {
    "low": "#2E75B6",
    "medium": "#E8A33D",
    "high": "#D9534F",
    "critical": "#8B0000",
}

_STATUS_EMOJI = {
    "healthy":  ":large_green_circle:",
    "degraded": ":large_yellow_circle:",
    "critical": ":rotating_light:",
    "unknown":  ":white_circle:",
}

_STATUS_COLOR = {
    "healthy":  "#2ECC71",
    "degraded": "#E8A33D",
    "critical": "#8B0000",
    "unknown":  "#888888",
}


def send_alert(
    anomaly: dict,
    analysis: dict,
    remediation_result: Optional[dict] = None,
    escalate: bool = False,
) -> bool:
    """
    Send a formatted alert to Slack.
    Returns True on success, False on failure (never raises).
    """
    severity = analysis.get("severity", "medium")
    emoji = _SEVERITY_EMOJI.get(severity, ":warning:")
    color = _SEVERITY_COLOR.get(severity, "#888888")

    title = f"{emoji} Nomad Anomaly — {anomaly.get('job_id', 'unknown')}"
    if escalate:
        title = f":rotating_light: ESCALATION — {anomaly.get('job_id', 'unknown')}"

    fields = [
        {"title": "Environment", "value": ENVIRONMENT, "short": True},
        {"title": "Severity", "value": severity, "short": True},
        {"title": "Job", "value": anomaly.get("job_id", "unknown"), "short": True},
        {"title": "Task", "value": anomaly.get("task", "unknown"), "short": True},
        {"title": "Namespace", "value": anomaly.get("namespace", "default"), "short": True},
        {"title": "Anomaly Type", "value": anomaly.get("anomaly_type", "unknown"), "short": True},
        {"title": "Restarts", "value": str(anomaly.get("restarts", 0)), "short": True},
        {"title": "Confidence", "value": f"{analysis.get('confidence', 0.0):.2f}", "short": True},
        {"title": "Likely Cause", "value": analysis.get("likely_cause", "Unknown"), "short": False},
    ]

    if remediation_result:
        fields.append({
            "title": "Remediation",
            "value": _format_remediation(remediation_result),
            "short": False,
        })

    if escalate:
        fields.append({
            "title": "Escalation Reason",
            "value": "Maximum remediation attempts reached — human intervention required",
            "short": False,
        })

    payload = {
        "text": title,
        "attachments": [
            {
                "color": color,
                "text": analysis.get("summary", ""),
                "fields": fields,
                "footer": "Nomad AI Monitoring Agent",
            }
        ],
    }

    return _post_to_slack(payload)


def send_simple_alert(message: str, severity: str = "medium") -> bool:
    """Send a plain text alert without full anomaly context — used for agent-level issues."""
    emoji = _SEVERITY_EMOJI.get(severity, ":warning:")
    payload = {
        "text": f"{emoji} [{ENVIRONMENT}] {message}",
    }
    return _post_to_slack(payload)


def send_summary_alert(summary_result: dict) -> bool:
    """
    Post a scheduled cluster health summary to Slack.

    Called by scheduler.py on a configurable interval (default: every 6h).
    This is a proactive status message — not triggered by an anomaly.
    Visually distinct from anomaly alerts so it is easy to tell apart
    in the Slack channel.

    summary_result is the dict returned by summarizer.get_cluster_summary().
    """
    overall_status = summary_result.get("overall_status", "unknown")
    emoji  = _STATUS_EMOJI.get(overall_status, ":white_circle:")
    color  = _STATUS_COLOR.get(overall_status, "#888888")
    generated_at = summary_result.get("generated_at", "unknown")

    title = f"{emoji} Cluster Health Summary — {ENVIRONMENT}"

    fields = [
        {
            "title": "Overall Status",
            "value": overall_status.upper(),
            "short": True,
        },
        {
            "title": "Generated At",
            "value": generated_at,
            "short": True,
        },
        {
            "title": "Healthy Allocations",
            "value": str(summary_result.get("healthy_count", 0)),
            "short": True,
        },
        {
            "title": "Unhealthy Allocations",
            "value": str(summary_result.get("unhealthy_count", 0)),
            "short": True,
        },
        {
            "title": "Pending Allocations",
            "value": str(summary_result.get("pending_count", 0)),
            "short": True,
        },
        {
            "title": "Total Allocations",
            "value": str(summary_result.get("total_allocs", 0)),
            "short": True,
        },
        {
            "title": "Confidence",
            "value": f"{summary_result.get('confidence', 0.0):.2f}",
            "short": True,
        },
    ]

    notable_issues = summary_result.get("notable_issues") or []
    if notable_issues:
        fields.append({
            "title": "Notable Issues",
            "value": "\n".join(f"• {issue}" for issue in notable_issues),
            "short": False,
        })

    # Include the error field if Nomad/Gemini failed, so Slack makes
    # it obvious the summary is incomplete rather than silently misleading.
    if "error" in summary_result:
        fields.append({
            "title": "Error",
            "value": summary_result["error"],
            "short": False,
        })

    payload = {
        "text": title,
        "attachments": [
            {
                "color": color,
                "text": summary_result.get("summary", ""),
                "fields": fields,
                "footer": "Nomad AI Monitoring Agent — scheduled summary",
            }
        ],
    }

    return _post_to_slack(payload)


def _format_remediation(result: dict) -> str:
    action = result.get("action_taken", "none")
    if action == "increase_memory":
        return (
            f"Increased memory from {result.get('old_memory_mb')}MB "
            f"to {result.get('new_memory_mb')}MB"
        )
    elif action == "restart":
        return f"Restarted allocation {result.get('alloc_id', '')}"
    elif action == "revert":
        return (
            f"Reverted job from version {result.get('from_version')} "
            f"to {result.get('to_version')}"
        )
    elif action == "failed":
        return f"Remediation attempt FAILED: {result.get('reason', 'unknown error')}"
    else:
        return f"No automated action taken — {result.get('reason', 'requires manual review')}"


def send_proposal_alert(anomaly: dict, analysis: dict) -> bool:
    """
    Send an alert describing the remediation the agent WOULD have taken,
    without taking it. Used when REMEDIATION_MODE=propose (typically prod).
    Visually distinct from a normal alert so it is unmistakable that no
    action was executed against Nomad.
    """
    severity = analysis.get("severity", "medium")
    color = _SEVERITY_COLOR.get(severity, "#888888")
    suggested_action = analysis.get("suggested_action", "manual_intervention")

    title = f":large_orange_diamond: ACTION REQUIRED — {anomaly.get('job_id', 'unknown')}"

    fields = [
        {"title": "Environment", "value": ENVIRONMENT, "short": True},
        {"title": "Severity", "value": severity, "short": True},
        {"title": "Job", "value": anomaly.get("job_id", "unknown"), "short": True},
        {"title": "Task", "value": anomaly.get("task", "unknown"), "short": True},
        {"title": "Namespace", "value": anomaly.get("namespace", "default"), "short": True},
        {"title": "Anomaly Type", "value": anomaly.get("anomaly_type", "unknown"), "short": True},
        {"title": "Confidence", "value": f"{analysis.get('confidence', 0.0):.2f}", "short": True},
        {"title": "Likely Cause", "value": analysis.get("likely_cause", "Unknown"), "short": False},
        {
            "title": "Proposed Action (NOT executed)",
            "value": _format_proposed_action(suggested_action, analysis),
            "short": False,
        },
        {
            "title": "Mode",
            "value": "propose — agent did not modify Nomad. Manual action required.",
            "short": False,
        },
    ]

    payload = {
        "text": title,
        "attachments": [
            {
                "color": color,
                "text": analysis.get("summary", ""),
                "fields": fields,
                "footer": "Nomad AI Monitoring Agent — propose mode",
            }
        ],
    }

    return _post_to_slack(payload)


def _format_proposed_action(action: str, analysis: dict) -> str:
    if action == "increase_memory":
        mb = analysis.get("memory_increase_mb", 0)
        return f"Increase task memory by {mb}MB"
    elif action == "restart":
        return "Restart the affected allocation"
    elif action == "revert":
        return "Revert the job to its previous version"
    else:
        return f"'{action}' — requires manual review"


def _post_to_slack(payload: dict) -> bool:
    try:
        resp = requests.post(SLACK_WEBHOOK_URL, json=payload, timeout=10)
        resp.raise_for_status()
        log.info("slack_alert_sent")
        return True
    except requests.exceptions.RequestException as e:
        log.error("slack_alert_failed", error=str(e))
        return False
