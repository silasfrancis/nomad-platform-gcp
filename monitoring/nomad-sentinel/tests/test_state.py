"""
test_state.py
Tests the in-memory cooldown and remediation attempt tracker.
"""

import time

from state import StateTracker


class TestStateTracker:
    def test_new_job_is_not_cooling_down(self):
        tracker = StateTracker(cooldown_seconds=60, max_attempts=3)
        assert tracker.is_cooling_down("job-1") is False

    def test_record_remediation_starts_cooldown(self):
        tracker = StateTracker(cooldown_seconds=60, max_attempts=3)
        tracker.record_remediation("job-1")
        assert tracker.is_cooling_down("job-1") is True

    def test_cooldown_expires_after_duration(self):
        tracker = StateTracker(cooldown_seconds=0, max_attempts=3)
        tracker.record_remediation("job-1")
        time.sleep(0.01)
        assert tracker.is_cooling_down("job-1") is False

    def test_attempts_increment_correctly(self):
        tracker = StateTracker(cooldown_seconds=0, max_attempts=3)
        assert tracker.attempts("job-1") == 0
        tracker.record_remediation("job-1")
        assert tracker.attempts("job-1") == 1
        tracker.record_remediation("job-1")
        assert tracker.attempts("job-1") == 2

    def test_has_reached_max_attempts(self):
        tracker = StateTracker(cooldown_seconds=0, max_attempts=2)
        assert tracker.has_reached_max_attempts("job-1") is False
        tracker.record_remediation("job-1")
        assert tracker.has_reached_max_attempts("job-1") is False
        tracker.record_remediation("job-1")
        assert tracker.has_reached_max_attempts("job-1") is True

    def test_jobs_are_tracked_independently(self):
        tracker = StateTracker(cooldown_seconds=60, max_attempts=3)
        tracker.record_remediation("job-1")
        assert tracker.is_cooling_down("job-1") is True
        assert tracker.is_cooling_down("job-2") is False
        assert tracker.attempts("job-2") == 0

    def test_record_and_retrieve_anomaly_type(self):
        tracker = StateTracker(cooldown_seconds=60, max_attempts=3)
        tracker.record_anomaly_type("job-1", "oom_killed")
        assert tracker.last_anomaly_type("job-1") == "oom_killed"

    def test_last_anomaly_type_none_for_unseen_job(self):
        tracker = StateTracker(cooldown_seconds=60, max_attempts=3)
        assert tracker.last_anomaly_type("never-seen") is None

    def test_clear_resets_job_state(self):
        tracker = StateTracker(cooldown_seconds=60, max_attempts=3)
        tracker.record_remediation("job-1")
        tracker.record_anomaly_type("job-1", "restart_loop")
        tracker.clear("job-1")
        assert tracker.attempts("job-1") == 0
        assert tracker.is_cooling_down("job-1") is False
        assert tracker.last_anomaly_type("job-1") is None

    def test_clear_on_unseen_job_does_not_raise(self):
        tracker = StateTracker(cooldown_seconds=60, max_attempts=3)
        tracker.clear("never-seen")  # should not raise

    def test_summary_reflects_all_tracked_jobs(self):
        tracker = StateTracker(cooldown_seconds=60, max_attempts=3)
        tracker.record_remediation("job-1")
        tracker.record_anomaly_type("job-2", "stuck_pending")

        summary = tracker.summary()
        assert "job-1" in summary
        assert summary["job-1"]["attempts"] == 1
        assert summary["job-1"]["cooling_down"] is True
        assert "job-2" in summary
        assert summary["job-2"]["last_anomaly"] == "stuck_pending"
