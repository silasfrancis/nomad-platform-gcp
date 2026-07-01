"""
test_scheduler.py
Tests scheduler job registration and the scheduled summary callback.
APScheduler itself is exercised directly (start/shutdown), but the job
function's dependencies (summarizer, alerter) are mocked.
"""

import pytest

import scheduler


class TestStartScheduler:
    def test_disabled_when_interval_zero(self, monkeypatch):
        monkeypatch.setattr(scheduler, "SUMMARY_INTERVAL_HOURS", 0)
        result = scheduler.start_scheduler()
        assert result is None

    def test_starts_and_registers_job_when_enabled(self, monkeypatch):
        monkeypatch.setattr(scheduler, "SUMMARY_INTERVAL_HOURS", 6.0)
        sched = scheduler.start_scheduler()
        try:
            assert sched is not None
            assert sched.get_job("cluster_health_summary") is not None
        finally:
            if sched:
                sched.shutdown(wait=False)

    def test_negative_interval_disables_scheduler(self, monkeypatch):
        monkeypatch.setattr(scheduler, "SUMMARY_INTERVAL_HOURS", -1)
        result = scheduler.start_scheduler()
        assert result is None


class TestRunScheduledSummary:
    def test_calls_summarizer_and_alerter(self, monkeypatch):
        calls = {"summary": False, "alert": False}

        def fake_get_summary():
            calls["summary"] = True
            return {"overall_status": "healthy", "healthy_count": 11, "unhealthy_count": 0}

        def fake_send_summary(result):
            calls["alert"] = True
            assert result["overall_status"] == "healthy"
            return True

        monkeypatch.setattr("summarizer.get_cluster_summary", fake_get_summary)
        monkeypatch.setattr("alerter.send_summary_alert", fake_send_summary)

        scheduler._run_scheduled_summary()

        assert calls["summary"] is True
        assert calls["alert"] is True

    def test_swallows_exceptions_without_raising(self, monkeypatch):
        def raise_error():
            raise RuntimeError("nomad down")

        monkeypatch.setattr("summarizer.get_cluster_summary", raise_error)

        # Should not raise - scheduler must keep firing on future intervals
        scheduler._run_scheduled_summary()

    def test_swallows_alerter_exceptions(self, monkeypatch):
        monkeypatch.setattr(
            "summarizer.get_cluster_summary",
            lambda: {"overall_status": "healthy"},
        )

        def raise_error(result):
            raise RuntimeError("slack down")

        monkeypatch.setattr("alerter.send_summary_alert", raise_error)

        # Should not raise
        scheduler._run_scheduled_summary()
