"""
main.py
Entry point for the Nomad AI Monitoring Agent.

Three concurrent loops, all running in the same process:

  1. Anomaly detection loop (main thread)
     Polls Nomad every POLL_INTERVAL_SECONDS, detects workload anomalies,
     calls Gemini for root-cause analysis, alerts and optionally remediates.
     Unchanged from the original implementation.

  2. HTTP server (daemon thread — http_server.py)
     Flask server on HTTP_PORT (default 8090).
       GET /health  — liveness probe, instant response, no Nomad call.
       GET /summary — on-demand cluster health summary: calls Nomad +
                      Gemini and returns JSON. Hit this endpoint during a
                      demo to show what the agent sees right now.

  3. Scheduled summary (APScheduler background thread — scheduler.py)
     Every SUMMARY_INTERVAL_HOURS (default 6h), posts a proactive cluster
     health summary to Slack whether or not anything is wrong.
     "All 11 services healthy, 0 anomalies in the last 6 hours" is a
     genuinely useful operational message — it also proves continuous
     Gemini integration, not just reactive alerting.
     Set SUMMARY_INTERVAL_HOURS=0 to disable.

REMEDIATION_MODE is set per environment in the Nomad job spec — typically
"execute" in dev and "propose" in prod. This lets autonomous remediation
be proven out safely in dev before being trusted with live prod mutations.
"""

import sys
import time

import structlog

import config
import detector
import gemini_client
import remediator
import alerter
import history
import http_server
import scheduler
from state import StateTracker

structlog.configure(
    processors=[
        structlog.processors.TimeStamper(fmt="iso"),
        structlog.processors.add_log_level,
        structlog.processors.JSONRenderer(),
    ]
)
log = structlog.get_logger()


def handle_anomaly(anomaly: dict, tracker: StateTracker) -> None:
    job_id = anomaly["job_id"]
    anomaly_type = anomaly["anomaly_type"]

    if tracker.is_cooling_down(job_id):
        log.info("skipping_anomaly_cooldown", job=job_id)
        history.record(anomaly, analysis=None, outcome="skipped_cooldown")
        return

    if tracker.is_alert_cooling_down(job_id, anomaly_type):
        # Already analyzed and alerted on this exact (job, anomaly_type)
        # recently, and it didn't clear the remediation bar last time
        # either — skip the Gemini call entirely rather than re-running
        # analysis on an unchanged condition every poll cycle. This is
        # what actually bounds Gemini call volume for a persistently
        # broken, non-remediable job; is_cooling_down above only bounds
        # repeat *remediation* attempts, not repeat analysis.
        log.debug("skipping_anomaly_alert_cooldown", job=job_id, anomaly_type=anomaly_type)
        return

    analysis = gemini_client.analyze(anomaly)
    tracker.record_anomaly_type(job_id, anomaly_type)

    severity = analysis.get("severity", "medium")
    confidence = analysis.get("confidence", 0.0)
    suggested_action = analysis.get("suggested_action", "manual_intervention")

    should_remediate = (
        severity in ("high", "critical")
        and confidence >= config.REMEDIATION_CONFIDENCE_THRESHOLD
        and suggested_action not in ("check_image", "manual_intervention", "none")
    )

    if not should_remediate:
        alerter.send_alert(anomaly, analysis)
        history.record(anomaly, analysis, outcome="alerted_only")
        tracker.record_alert(job_id, anomaly_type)
        log.info(
            "anomaly_logged_no_remediation",
            job=job_id,
            severity=severity,
            confidence=confidence,
            action=suggested_action,
        )
        return

    if tracker.has_reached_max_attempts(job_id):
        alerter.send_alert(anomaly, analysis, escalate=True)
        history.record(anomaly, analysis, outcome="escalated")
        log.warning("max_remediation_attempts_reached", job=job_id)
        return

    if config.REMEDIATION_MODE == "propose":
        # Do not touch Nomad. Record the "attempt" so cooldown/max-attempts
        # bookkeeping still applies — otherwise the same proposal would be
        # re-sent to Slack every poll interval until a human acts.
        tracker.record_remediation(job_id)
        alerter.send_proposal_alert(anomaly, analysis)
        history.record(anomaly, analysis, outcome="proposed")
        log.info(
            "remediation_proposed_not_executed",
            job=job_id,
            action=suggested_action,
            mode=config.REMEDIATION_MODE,
        )
        return

    # REMEDIATION_MODE == "execute" — this is a live mutation against Nomad
    remediation_result = remediator.remediate(anomaly, analysis)
    tracker.record_remediation(job_id)
    alerter.send_alert(anomaly, analysis, remediation_result=remediation_result)

    outcome = (
        "remediation_failed"
        if remediation_result.get("action_taken") == "failed"
        else "remediated"
    )
    history.record(anomaly, analysis, outcome=outcome, outcome_detail=remediation_result)


def run_once(tracker: StateTracker) -> int:
    """Run a single detection + handling cycle. Returns number of anomalies processed."""
    anomalies = detector.detect_anomalies()

    for anomaly in anomalies:
        try:
            handle_anomaly(anomaly, tracker)
        except Exception as e:
            log.error(
                "anomaly_handling_failed",
                job=anomaly.get("job_id", "unknown"),
                error=str(e),
            )

    return len(anomalies)


def run() -> None:
    log.info(
        "agent_starting",
        environment=config.ENVIRONMENT,
        nomad_addr=config.NOMAD_ADDR,
        poll_interval=config.POLL_INTERVAL_SECONDS,
        remediation_mode=config.REMEDIATION_MODE,
        http_port=config.HTTP_PORT,
        summary_interval_hours=config.SUMMARY_INTERVAL_HOURS,
    )

    history.ensure_schema()

    tracker = StateTracker(
        cooldown_seconds=config.COOLDOWN_SECONDS,
        max_attempts=config.MAX_REMEDIATION_ATTEMPTS,
        alert_cooldown_seconds=config.ANOMALY_ALERT_COOLDOWN_SECONDS,
    )

    # Start HTTP server in a daemon thread.
    # /health is used by Consul + Nomad health gates.
    # /summary is the on-demand demo endpoint.
    http_server.start_http_server()

    # Start the scheduled summary (posts to Slack every SUMMARY_INTERVAL_HOURS).
    # Returns None if disabled (SUMMARY_INTERVAL_HOURS=0).
    sched = scheduler.start_scheduler()

    alerter.send_simple_alert(
        f"AI monitoring agent started "
        f"(remediation_mode={config.REMEDIATION_MODE}, "
        f"http_port={config.HTTP_PORT}, "
        f"summary_interval={config.SUMMARY_INTERVAL_HOURS}h)",
        severity="low",
    )

    while True:
        try:
            count = run_once(tracker)
            if count:
                log.info("cycle_complete", anomalies_processed=count)
        except Exception as e:
            log.error("control_loop_error", error=str(e))

        time.sleep(config.POLL_INTERVAL_SECONDS)


if __name__ == "__main__":
    try:
        run()
    except KeyboardInterrupt:
        log.info("agent_shutdown_requested")
        sys.exit(0)
