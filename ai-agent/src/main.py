"""
main.py
Entry point for the Nomad AI Monitoring Agent.

Control loop:
  1. Poll Nomad for anomalous allocations
  2. For each anomaly not in cooldown:
       - Send context to Gemini for analysis
       - Always log the analysis and send a Slack alert
       - If severity is high/critical and confidence is high enough,
         attempt automated remediation (bounded by max attempts)
  3. Sleep and repeat
"""

import sys
import time

import structlog

import config
import detector
import gemini_client
import remediator
import alerter
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

    if tracker.is_cooling_down(job_id):
        log.info("skipping_anomaly_cooldown", job=job_id)
        return

    analysis = gemini_client.analyze(anomaly)
    tracker.record_anomaly_type(job_id, anomaly["anomaly_type"])

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
        log.warning("max_remediation_attempts_reached", job=job_id)
        return

    remediation_result = remediator.remediate(anomaly, analysis)
    tracker.record_remediation(job_id)
    alerter.send_alert(anomaly, analysis, remediation_result=remediation_result)


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
    )

    tracker = StateTracker(
        cooldown_seconds=config.COOLDOWN_SECONDS,
        max_attempts=config.MAX_REMEDIATION_ATTEMPTS,
    )

    alerter.send_simple_alert("AI monitoring agent started", severity="low")

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
