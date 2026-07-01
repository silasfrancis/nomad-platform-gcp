"""
scheduler.py
Runs a scheduled cluster health summary on a configurable interval.

Separate from the anomaly detection loop — this is a proactive
"all-clear" (or status) message, not a reaction to a detected failure.
It fires whether or not anything is wrong.

"All 11 services healthy, metrics-api DB connection stable,
0 anomalies in the last 6 hours" is a genuinely useful operational
message. It also proves the Gemini integration is doing real reasoning
continuously, not just reacting to failures.

Configuration:
  SUMMARY_INTERVAL_HOURS (float, default 6.0) — how often to post.
  Set to 0 to disable the scheduler entirely.

Uses APScheduler's BackgroundScheduler: runs in a daemon thread,
does not block the main anomaly loop, shuts down automatically when
the process exits.
"""

import structlog
from apscheduler.schedulers.background import BackgroundScheduler
from apscheduler.triggers.interval import IntervalTrigger

import alerter
import summarizer
from config import SUMMARY_INTERVAL_HOURS, ENVIRONMENT

log = structlog.get_logger()


def _run_scheduled_summary() -> None:
    """
    Fetch cluster state, call Gemini, post to Slack.
    Never raises — any failure is logged and swallowed so the scheduler
    keeps firing on future intervals regardless.
    """
    log.info("scheduled_summary_starting", environment=ENVIRONMENT)
    try:
        result = summarizer.get_cluster_summary()
        alerter.send_summary_alert(result)
        log.info(
            "scheduled_summary_complete",
            status=result.get("overall_status"),
            healthy=result.get("healthy_count"),
            unhealthy=result.get("unhealthy_count"),
        )
    except Exception as e:
        log.error("scheduled_summary_failed", error=str(e))


def start_scheduler() -> BackgroundScheduler | None:
    """
    Start the APScheduler background scheduler.

    Returns the scheduler instance so callers can shut it down cleanly
    on process exit if needed. Returns None if scheduling is disabled
    (SUMMARY_INTERVAL_HOURS == 0).
    """
    if SUMMARY_INTERVAL_HOURS <= 0:
        log.info("scheduled_summary_disabled", reason="SUMMARY_INTERVAL_HOURS=0")
        return None

    scheduler = BackgroundScheduler(
        job_defaults={"misfire_grace_time": 300},  # 5min grace if job fires late
        timezone="UTC",
    )

    scheduler.add_job(
        func=_run_scheduled_summary,
        trigger=IntervalTrigger(hours=SUMMARY_INTERVAL_HOURS),
        id="cluster_health_summary",
        name="Scheduled cluster health summary",
        replace_existing=True,
    )

    scheduler.start()

    log.info(
        "scheduled_summary_started",
        interval_hours=SUMMARY_INTERVAL_HOURS,
        environment=ENVIRONMENT,
    )

    return scheduler
