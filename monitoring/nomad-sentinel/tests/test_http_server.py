"""
test_http_server.py
Tests the Flask /health and /summary endpoints using Flask's test client
(no real HTTP server bound, no real Nomad/Gemini calls).
"""

import json

import pytest

import http_server


@pytest.fixture
def client():
    http_server.app.config["TESTING"] = True
    with http_server.app.test_client() as c:
        yield c


class TestHealthEndpoint:
    def test_health_returns_200(self, client):
        resp = client.get("/health")
        assert resp.status_code == 200

    def test_health_returns_ok_status(self, client):
        resp = client.get("/health")
        data = json.loads(resp.data)
        assert data["status"] == "ok"

    def test_health_does_not_call_summarizer(self, client, monkeypatch):
        called = {"value": False}

        def fake_summary():
            called["value"] = True
            return {}

        monkeypatch.setattr("summarizer.get_cluster_summary", fake_summary)
        client.get("/health")
        assert called["value"] is False


class TestSummaryEndpoint:
    def test_summary_returns_200_on_success(self, client, monkeypatch):
        monkeypatch.setattr(
            "summarizer.get_cluster_summary",
            lambda: {
                "overall_status": "healthy",
                "healthy_count": 11,
                "unhealthy_count": 0,
                "pending_count": 0,
                "summary": "All services healthy",
                "notable_issues": [],
                "confidence": 0.95,
                "generated_at": "2026-06-30T00:00:00Z",
                "environment": "test",
                "total_allocs": 11,
            },
        )
        resp = client.get("/summary")
        assert resp.status_code == 200
        data = json.loads(resp.data)
        assert data["overall_status"] == "healthy"
        assert data["healthy_count"] == 11

    def test_summary_returns_500_when_result_has_error(self, client, monkeypatch):
        monkeypatch.setattr(
            "summarizer.get_cluster_summary",
            lambda: {
                "overall_status": "unknown",
                "error": "nomad unreachable",
            },
        )
        resp = client.get("/summary")
        assert resp.status_code == 500

    def test_summary_returns_500_on_unexpected_exception(self, client, monkeypatch):
        def raise_error():
            raise RuntimeError("boom")

        monkeypatch.setattr("summarizer.get_cluster_summary", raise_error)
        resp = client.get("/summary")
        assert resp.status_code == 500
        data = json.loads(resp.data)
        assert "error" in data
