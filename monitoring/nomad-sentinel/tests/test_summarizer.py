"""
test_summarizer.py
Tests cluster snapshot construction and the Gemini summary call.
Nomad and Gemini are both mocked — no live network calls.
"""

import json

import pytest
import responses

import summarizer
from config import NOMAD_ADDR


def _alloc(job_id, client_status, task_state="running", events=None):
    return {
        "ID": f"{job_id}-alloc-id-00000000",
        "JobID": job_id,
        "ClientStatus": client_status,
        "TaskStates": {
            "main": {
                "State": task_state,
                "Restarts": 0,
                "Events": events or [],
            }
        },
    }


class TestBuildSnapshot:
    def test_counts_healthy_allocations(self):
        allocs = [
            _alloc("web", "running", "running"),
            _alloc("api", "running", "running"),
        ]
        snap = summarizer._build_snapshot(allocs)
        assert snap["healthy_count"] == 2
        assert snap["unhealthy_count"] == 0
        assert snap["pending_count"] == 0
        assert snap["total_allocs"] == 2

    def test_counts_pending_allocations(self):
        allocs = [_alloc("web", "pending", "pending")]
        snap = summarizer._build_snapshot(allocs)
        assert snap["pending_count"] == 1
        assert snap["healthy_count"] == 0

    def test_counts_unhealthy_allocations(self):
        allocs = [_alloc("web", "failed", "dead")]
        snap = summarizer._build_snapshot(allocs)
        assert snap["unhealthy_count"] == 1

    def test_empty_allocations_list(self):
        snap = summarizer._build_snapshot([])
        assert snap["total_allocs"] == 0
        assert snap["healthy_count"] == 0
        assert "no allocations" in snap["alloc_breakdown"]

    def test_flags_recent_anomalous_events(self):
        import time
        recent_event = {
            "Type": "Terminated",
            "DisplayMessage": "OOM killed",
            "Time": int(time.time() * 1e9),  # now, in nanoseconds
        }
        allocs = [_alloc("web", "failed", "dead", events=[recent_event])]
        snap = summarizer._build_snapshot(allocs)
        assert "Terminated" in snap["recent_events_str"]
        assert "web" in snap["recent_events_str"]

    def test_ignores_stale_events(self):
        import time
        stale_event = {
            "Type": "Terminated",
            "DisplayMessage": "OOM killed",
            "Time": int((time.time() - 3600) * 1e9),  # 1 hour ago
        }
        allocs = [_alloc("web", "failed", "dead", events=[stale_event])]
        snap = summarizer._build_snapshot(allocs)
        assert "none in the last 5 minutes" in snap["recent_events_str"]

    def test_job_summary_groups_by_job_id(self):
        allocs = [
            _alloc("web", "running", "running"),
            _alloc("web", "running", "running"),
            _alloc("api", "failed", "dead"),
        ]
        snap = summarizer._build_snapshot(allocs)
        assert "web:" in snap["job_summary_str"]
        assert "api:" in snap["job_summary_str"]


class TestFetchAllAllocations:
    @responses.activate
    def test_fetches_all_namespaces_when_unset(self, monkeypatch):
        monkeypatch.setattr(summarizer, "WATCH_NAMESPACES", [])
        responses.add(
            responses.GET,
            f"{NOMAD_ADDR}/v1/allocations",
            json=[{"ID": "a1", "JobID": "web", "ClientStatus": "running"}],
            status=200,
        )
        result = summarizer._fetch_all_allocations()
        assert len(result) == 1

    @responses.activate
    def test_returns_empty_list_on_connection_error(self, monkeypatch):
        monkeypatch.setattr(summarizer, "WATCH_NAMESPACES", [])
        # No responses registered -> ConnectionError raised by responses lib
        result = summarizer._fetch_all_allocations()
        assert result == []


class TestCallGemini:
    def test_clamps_confidence_to_valid_range(self, monkeypatch):
        class FakeResponse:
            text = json.dumps({
                "overall_status": "healthy",
                "healthy_count": 5,
                "unhealthy_count": 0,
                "pending_count": 0,
                "summary": "All good",
                "notable_issues": [],
                "confidence": 1.5,  # invalid - should clamp to 1.0
            })

        class FakeModels:
            def generate_content(self, **kwargs):
                return FakeResponse()

        monkeypatch.setattr(summarizer._client.models, "generate_content", FakeModels().generate_content)

        snapshot = {
            "total_allocs": 5, "healthy_count": 5, "unhealthy_count": 0,
            "pending_count": 0, "alloc_breakdown": "", "job_summary_str": "",
            "recent_events_str": "",
        }
        result = summarizer._call_gemini(snapshot, "2026-06-30T00:00:00Z")
        assert result["confidence"] == 1.0

    def test_falls_back_on_invalid_json(self, monkeypatch):
        class FakeResponse:
            text = "not json"

        class FakeModels:
            def generate_content(self, **kwargs):
                return FakeResponse()

        monkeypatch.setattr(summarizer._client.models, "generate_content", FakeModels().generate_content)

        snapshot = {
            "total_allocs": 3, "healthy_count": 2, "unhealthy_count": 1,
            "pending_count": 0, "alloc_breakdown": "", "job_summary_str": "",
            "recent_events_str": "",
        }
        result = summarizer._call_gemini(snapshot, "2026-06-30T00:00:00Z")
        assert result["overall_status"] == "degraded"
        assert result["confidence"] == 0.0

    def test_invalid_status_defaults_to_degraded(self, monkeypatch):
        class FakeResponse:
            text = json.dumps({
                "overall_status": "not-a-real-status",
                "healthy_count": 1,
                "unhealthy_count": 0,
                "pending_count": 0,
                "summary": "x",
                "notable_issues": [],
                "confidence": 0.5,
            })

        class FakeModels:
            def generate_content(self, **kwargs):
                return FakeResponse()

        monkeypatch.setattr(summarizer._client.models, "generate_content", FakeModels().generate_content)

        snapshot = {
            "total_allocs": 1, "healthy_count": 1, "unhealthy_count": 0,
            "pending_count": 0, "alloc_breakdown": "", "job_summary_str": "",
            "recent_events_str": "",
        }
        result = summarizer._call_gemini(snapshot, "2026-06-30T00:00:00Z")
        assert result["overall_status"] == "degraded"


class TestGetClusterSummary:
    @responses.activate
    def test_returns_error_dict_on_nomad_failure(self, monkeypatch):
        monkeypatch.setattr(summarizer, "WATCH_NAMESPACES", [])

        def raise_error(*args, **kwargs):
            raise ConnectionError("nomad unreachable")

        monkeypatch.setattr(summarizer, "_fetch_all_allocations", raise_error)

        result = summarizer.get_cluster_summary()
        assert result["overall_status"] == "unknown"
        assert "error" in result

    @responses.activate
    def test_happy_path_returns_summary(self, monkeypatch):
        monkeypatch.setattr(
            summarizer, "_fetch_all_allocations",
            lambda: [_alloc("web", "running", "running")]
        )

        class FakeResponse:
            text = json.dumps({
                "overall_status": "healthy",
                "healthy_count": 1,
                "unhealthy_count": 0,
                "pending_count": 0,
                "summary": "Cluster is healthy",
                "notable_issues": [],
                "confidence": 0.95,
            })

        class FakeModels:
            def generate_content(self, **kwargs):
                return FakeResponse()

        monkeypatch.setattr(summarizer._client.models, "generate_content", FakeModels().generate_content)

        result = summarizer.get_cluster_summary()
        assert result["overall_status"] == "healthy"
        assert result["total_allocs"] == 1
        assert "generated_at" in result
        assert "environment" in result
