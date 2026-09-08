"""
summarizer.py
Produces an on-demand cluster health summary by fetching current Nomad
allocation state and asking Gemini to summarise it.

Called from two places:
  - http_server.py  (GET /summary — synchronous, returns JSON)
  - scheduler.py    (scheduled interval — posts result to Slack)

This module is deliberately stateless: every call fetches fresh data from
Nomad and makes a fresh Gemini request. There is no caching — the whole
point is an accurate picture of the cluster at the moment of the call.

Gemini response shape (enforced server-side via response_schema):
{
  "overall_status":   "healthy" | "degraded" | "critical",
  "healthy_count":    int,
  "unhealthy_count":  int,
  "pending_count":    int,
  "summary":          str,   # one paragraph, human-readable
  "notable_issues":   [str], # empty list when everything is healthy
  "confidence":       float
}
"""

import json
import time
from typing import Optional

import requests
import structlog
from google import genai
from google.genai import types

from config import (
    NOMAD_ADDR,
    NOMAD_TOKEN,
    GEMINI_API_KEY,
    GEMINI_MODEL,
    ENVIRONMENT,
    WATCH_NAMESPACES,
)

log = structlog.get_logger()

_client = genai.Client(api_key=GEMINI_API_KEY)

# ── Gemini schema for cluster health summary ──────────────────────────────────

_SUMMARY_RESPONSE_SCHEMA = {
    "type": "object",
    "properties": {
        "overall_status": {
            "type": "string",
            "enum": ["healthy", "degraded", "critical"],
        },
        "healthy_count":   {"type": "integer"},
        "unhealthy_count": {"type": "integer"},
        "pending_count":   {"type": "integer"},
        "summary":         {"type": "string"},
        "notable_issues":  {
            "type": "array",
            "items": {"type": "string"},
        },
        "confidence": {"type": "number"},
    },
    "required": [
        "overall_status",
        "healthy_count",
        "unhealthy_count",
        "pending_count",
        "summary",
        "notable_issues",
        "confidence",
    ],
}

_SUMMARY_PROMPT_TEMPLATE = """\
You are a platform reliability engineer reviewing a Nomad cluster health snapshot.

Environment: {environment}
Snapshot taken at: {timestamp}
Total allocations visible: {total_allocs}

Allocation status breakdown:
{alloc_breakdown}

Job-level summary (job_id → status → allocation count):
{job_summary}

Recent events across all allocations (last 5 minutes, anomalous only):
{recent_events}

Summarise the cluster health. Be concise and factual.

Rules:
- overall_status must be one of: healthy, degraded, critical
  - healthy: all services running, no anomalies in this snapshot
  - degraded: some services have issues but the cluster is mostly functional
  - critical: multiple critical services are failing or the majority of \
allocations are unhealthy
- healthy_count: number of running allocations with all tasks in \"running\" state
- unhealthy_count: number of allocations with tasks in \"dead\" or restarting state
- pending_count: number of allocations in \"pending\" client status
- summary: one paragraph (3-5 sentences) describing cluster state — suitable \
for a Slack message. State what is healthy, what is not, and any obvious \
patterns.
- notable_issues: list of specific issues worth calling out (empty list if all \
healthy). Each item is one sentence max.
- confidence: how confident you are in this assessment given the snapshot data \
(0.0 to 1.0)
"""


# ── Nomad data fetching ───────────────────────────────────────────────────────

def _headers() -> dict:
    return {"X-Nomad-Token": NOMAD_TOKEN}


def _get(path: str, params: Optional[dict] = None) -> Optional[dict | list]:
    url = f"{NOMAD_ADDR}{path}"
    try:
        resp = requests.get(url, headers=_headers(), params=params, timeout=10)
        resp.raise_for_status()
        return resp.json()
    except requests.exceptions.Timeout:
        log.warning("summarizer_nomad_timeout", url=url)
    except requests.exceptions.ConnectionError:
        log.warning("summarizer_nomad_connection_error", url=url)
    except requests.exceptions.HTTPError as e:
        log.warning("summarizer_nomad_http_error", url=url,
                    status=e.response.status_code)
    except Exception as e:
        log.error("summarizer_nomad_error", url=url, error=str(e))
    return None


def _fetch_all_allocations() -> list[dict]:
    """
    Fetch all allocations across namespaces. Mirrors detector._list_allocations()
    but is kept separate so summarizer has no import dependency on detector.
    """
    if WATCH_NAMESPACES:
        allocs: list[dict] = []
        for ns in WATCH_NAMESPACES:
            result = _get("/v1/allocations", params={"namespace": ns})
            if result:
                allocs.extend(result)
        return allocs
    return _get("/v1/allocations", params={"namespace": "*"}) or []


def _fetch_nodes() -> list[dict]:
    """Fetch node (client) list for node-level health context."""
    return _get("/v1/nodes") or []


# ── Snapshot building ─────────────────────────────────────────────────────────

def _build_snapshot(allocs: list[dict]) -> dict:
    """
    Reduce raw allocation list into structured counts and summaries
    suitable for the Gemini prompt.
    """
    healthy = 0
    unhealthy = 0
    pending = 0
    active_count = 0

    # client_status → count
    status_counts: dict[str, int] = {}

    # job_id → {status → count}
    job_summary: dict[str, dict[str, int]] = {}

    # allocations with non-running tasks (for notable events)
    flagged: list[dict] = []

    now = time.time()

    for alloc in allocs:
        # Skip superseded allocations — they have a successor and are no
        # longer the active allocation for this job. Counting them inflates
        # unhealthy_count with historical failures that have already been
        # resolved by Nomad's rescheduler.
        if alloc.get("NextAllocation"):
            continue

        # Skip allocations that were intentionally stopped
        if alloc.get("DesiredStatus") == "stop" and alloc.get("ClientStatus") == "failed":
            continue

        cs = alloc.get("ClientStatus", "unknown")
        active_count += 1
        status_counts[cs] = status_counts.get(cs, 0) + 1

        job_id = alloc.get("JobID", "unknown")
        if job_id not in job_summary:
            job_summary[job_id] = {}
        job_summary[job_id][cs] = job_summary[job_id].get(cs, 0) + 1

        task_states = alloc.get("TaskStates") or {}
        all_running = all(
            ts.get("State") == "running"
            for ts in task_states.values()
        ) if task_states else False

        if cs == "running" and all_running:
            healthy += 1
        elif cs == "pending":
            pending += 1
        else:
            unhealthy += 1

        # Collect recent anomalous events (last 5 minutes)
        for task_name, ts in task_states.items():
            for event in (ts.get("Events") or []):
                event_time_s = (event.get("Time") or 0) / 1e9
                if (now - event_time_s) <= 300:  # 5 minutes
                    event_type = event.get("Type", "")
                    if event_type in (
                        "Driver Failure", "Terminated", "Restarting",
                        "Not Restarting", "Killing", "Killed"
                    ):
                        flagged.append({
                            "job_id":    job_id,
                            "alloc_id":  alloc.get("ID", "")[:8],
                            "task":      task_name,
                            "event":     event_type,
                            "message":   event.get("DisplayMessage", ""),
                            "restarts":  ts.get("Restarts", 0),
                        })

    # Format breakdown string for prompt
    breakdown_lines = [
        f"  {status}: {count}" for status, count in sorted(status_counts.items())
    ]
    alloc_breakdown = "\n".join(breakdown_lines) or "  (no allocations)"

    # Format job summary (cap at 30 jobs to keep prompt bounded)
    job_lines = []
    for job_id, statuses in sorted(job_summary.items())[:30]:
        parts = ", ".join(f"{s}={c}" for s, c in sorted(statuses.items()))
        job_lines.append(f"  {job_id}: {parts}")
    job_summary_str = "\n".join(job_lines) or "  (none)"

    # Format recent flagged events (cap at 20)
    if flagged:
        event_lines = [
            f"  [{f['job_id']}/{f['task']}] {f['event']}: {f['message']} "
            f"(restarts={f['restarts']})"
            for f in flagged[:20]
        ]
        recent_events_str = "\n".join(event_lines)
    else:
        recent_events_str = "  (none in the last 5 minutes)"

    return {
        "total_allocs":      active_count,
        "healthy_count":     healthy,
        "unhealthy_count":   unhealthy,
        "pending_count":     pending,
        "alloc_breakdown":   alloc_breakdown,
        "job_summary_str":   job_summary_str,
        "recent_events_str": recent_events_str,
    }


# ── Gemini call ───────────────────────────────────────────────────────────────

def _call_gemini(snapshot: dict, timestamp: str) -> dict:
    prompt = _SUMMARY_PROMPT_TEMPLATE.format(
        environment=ENVIRONMENT,
        timestamp=timestamp,
        total_allocs=snapshot["total_allocs"],
        alloc_breakdown=snapshot["alloc_breakdown"],
        job_summary=snapshot["job_summary_str"],
        recent_events=snapshot["recent_events_str"],
    )

    try:
        response = _client.models.generate_content(
            model=GEMINI_MODEL,
            contents=prompt,
            config=types.GenerateContentConfig(
                response_mime_type="application/json",
                response_schema=_SUMMARY_RESPONSE_SCHEMA,
                thinking_config=types.ThinkingConfig(thinking_budget=0),
            ),
        )
        parsed = json.loads(response.text)

        # Defensive clamping
        parsed["confidence"] = max(0.0, min(1.0, float(parsed.get("confidence", 0.0))))
        parsed["healthy_count"]   = int(parsed.get("healthy_count", snapshot["healthy_count"]))
        parsed["unhealthy_count"] = int(parsed.get("unhealthy_count", snapshot["unhealthy_count"]))
        parsed["pending_count"]   = int(parsed.get("pending_count", snapshot["pending_count"]))
        if parsed.get("overall_status") not in ("healthy", "degraded", "critical"):
            parsed["overall_status"] = "degraded"

        log.info(
            "cluster_summary_generated",
            status=parsed["overall_status"],
            healthy=parsed["healthy_count"],
            unhealthy=parsed["unhealthy_count"],
            confidence=parsed["confidence"],
        )
        return parsed

    except json.JSONDecodeError as e:
        log.error("summarizer_gemini_json_error", error=str(e))
    except Exception as e:
        log.error("summarizer_gemini_error", error=str(e))

    # Fallback — use raw counts, skip Gemini narrative
    return {
        "overall_status":   "degraded" if snapshot["unhealthy_count"] > 0 else "healthy",
        "healthy_count":    snapshot["healthy_count"],
        "unhealthy_count":  snapshot["unhealthy_count"],
        "pending_count":    snapshot["pending_count"],
        "summary":          "Gemini analysis unavailable — raw allocation counts shown.",
        "notable_issues":   [],
        "confidence":       0.0,
    }


# ── Public API ────────────────────────────────────────────────────────────────

def get_cluster_summary() -> dict:
    """
    Fetch current Nomad allocation state, pass to Gemini, return a
    structured cluster health summary.

    Returns a dict suitable for:
      - JSON response from the /summary HTTP endpoint
      - Slack message construction in alerter.send_summary_alert()

    Never raises — returns an error dict on any failure.
    """
    timestamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

    try:
        allocs = _fetch_all_allocations()
    except Exception as e:
        log.error("summarizer_fetch_error", error=str(e))
        return {
            "overall_status":   "unknown",
            "healthy_count":    0,
            "unhealthy_count":  0,
            "pending_count":    0,
            "summary":          f"Failed to fetch Nomad allocations: {e}",
            "notable_issues":   [],
            "confidence":       0.0,
            "generated_at":     timestamp,
            "environment":      ENVIRONMENT,
            "error":            str(e),
        }

    snapshot = _build_snapshot(allocs)
    result   = _call_gemini(snapshot, timestamp)

    result["generated_at"] = timestamp
    result["environment"]  = ENVIRONMENT
    result["total_allocs"] = snapshot["total_allocs"]

    return result
