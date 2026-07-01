"""
state.py
In-memory state for the agent control loop.

Tracks:
  - Per-job remediation attempt counts
  - Per-job cooldown expiry timestamps
  - Seen anomaly deduplication (avoids re-alerting the same condition)

All state is in-memory. If the agent restarts, counters reset.
This is intentional — a restarted agent should be willing to try again.
"""

import time
from dataclasses import dataclass, field
from typing import Optional

import structlog

log = structlog.get_logger()


@dataclass
class JobState:
    attempts: int = 0
    cooldown_until: float = 0.0
    last_anomaly_type: Optional[str] = None


class StateTracker:
    def __init__(self, cooldown_seconds: int, max_attempts: int):
        self._cooldown_seconds = cooldown_seconds
        self._max_attempts = max_attempts
        self._jobs: dict[str, JobState] = {}

    def _get(self, job_id: str) -> JobState:
        if job_id not in self._jobs:
            self._jobs[job_id] = JobState()
        return self._jobs[job_id]

    def is_cooling_down(self, job_id: str) -> bool:
        state = self._get(job_id)
        if time.time() < state.cooldown_until:
            remaining = int(state.cooldown_until - time.time())
            log.debug("job_in_cooldown", job=job_id, remaining_seconds=remaining)
            return True
        return False

    def attempts(self, job_id: str) -> int:
        return self._get(job_id).attempts

    def has_reached_max_attempts(self, job_id: str) -> bool:
        return self._get(job_id).attempts >= self._max_attempts

    def record_remediation(self, job_id: str) -> None:
        state = self._get(job_id)
        state.attempts += 1
        state.cooldown_until = time.time() + self._cooldown_seconds
        log.info(
            "remediation_recorded",
            job=job_id,
            total_attempts=state.attempts,
            cooldown_until=state.cooldown_until,
        )

    def record_anomaly_type(self, job_id: str, anomaly_type: str) -> None:
        self._get(job_id).last_anomaly_type = anomaly_type

    def last_anomaly_type(self, job_id: str) -> Optional[str]:
        return self._get(job_id).last_anomaly_type

    def clear(self, job_id: str) -> None:
        """Reset state for a job — called when job recovers."""
        if job_id in self._jobs:
            del self._jobs[job_id]
            log.info("job_state_cleared", job=job_id)

    def summary(self) -> dict:
        return {
            job_id: {
                "attempts": s.attempts,
                "cooling_down": time.time() < s.cooldown_until,
                "last_anomaly": s.last_anomaly_type,
            }
            for job_id, s in self._jobs.items()
        }
