"""
test_gemini_client.py
Tests prompt building, response validation, and error fallback behaviour.
The Gemini SDK call itself is mocked — these tests never hit the real API.

Mocks target gemini_client._client.models.generate_content, matching the
google-genai SDK's client-based call shape (not the legacy
google.generativeai module-level GenerativeModel pattern).
"""

import json
from unittest.mock import MagicMock, patch

import pytest

import gemini_client


def _sample_anomaly():
    return {
        "job_id": "web-job",
        "task": "web",
        "namespace": "default",
        "anomaly_type": "oom_killed",
        "restarts": 4,
        "current_memory_mb": 256,
        "current_cpu_mhz": 200,
        "events": [{"DisplayMessage": "OOM killed", "ExitCode": 137}],
        "logs": "java.lang.OutOfMemoryError: Java heap space",
    }


def _valid_gemini_payload(**overrides):
    payload = {
        "likely_cause": "Heap exhaustion",
        "severity": "high",
        "suggested_action": "increase_memory",
        "memory_increase_mb": 256,
        "confidence": 0.92,
        "summary": "Service needs more memory",
    }
    payload.update(overrides)
    return payload


class TestBuildPrompt:
    def test_prompt_includes_key_fields(self):
        anomaly = _sample_anomaly()
        prompt = gemini_client._build_prompt(anomaly)
        assert "web-job" in prompt
        assert "oom_killed" in prompt
        assert "256" in prompt
        assert "OutOfMemoryError" in prompt

    def test_prompt_handles_missing_logs(self):
        anomaly = _sample_anomaly()
        anomaly["logs"] = ""
        prompt = gemini_client._build_prompt(anomaly)
        assert "no logs available" in prompt


class TestValidateResponse:
    def test_valid_response_passes_through(self):
        result = gemini_client._validate_response(_valid_gemini_payload())
        assert result["severity"] == "high"
        assert result["suggested_action"] == "increase_memory"
        assert result["confidence"] == 0.92
        assert result["memory_increase_mb"] == 256

    def test_invalid_action_falls_back_to_manual_intervention(self):
        parsed = {"suggested_action": "delete_everything", "severity": "high", "confidence": 0.9}
        result = gemini_client._validate_response(parsed)
        assert result["suggested_action"] == "manual_intervention"

    def test_invalid_severity_falls_back_to_medium(self):
        parsed = {"suggested_action": "restart", "severity": "catastrophic", "confidence": 0.5}
        result = gemini_client._validate_response(parsed)
        assert result["severity"] == "medium"

    def test_confidence_clamped_to_valid_range(self):
        parsed = {"suggested_action": "restart", "severity": "low", "confidence": 1.5}
        result = gemini_client._validate_response(parsed)
        assert result["confidence"] == 1.0

        parsed["confidence"] = -0.3
        result = gemini_client._validate_response(parsed)
        assert result["confidence"] == 0.0

    def test_memory_increase_capped_at_maximum(self):
        parsed = {
            "suggested_action": "increase_memory",
            "severity": "high",
            "confidence": 0.9,
            "memory_increase_mb": 99999,
        }
        result = gemini_client._validate_response(parsed)
        assert result["memory_increase_mb"] == 1024

    def test_missing_fields_use_safe_defaults(self):
        result = gemini_client._validate_response({})
        assert result["suggested_action"] == "manual_intervention"
        assert result["severity"] == "medium"
        assert result["confidence"] == 0.0
        assert result["memory_increase_mb"] == 0


class TestAnalyze:
    def test_analyze_returns_parsed_response_on_success(self):
        mock_response = MagicMock()
        mock_response.text = json.dumps(_valid_gemini_payload())

        with patch.object(gemini_client, "_client") as mock_client:
            mock_client.models.generate_content.return_value = mock_response
            result = gemini_client.analyze(_sample_anomaly())

        assert result["severity"] == "high"
        assert result["suggested_action"] == "increase_memory"
        assert result["confidence"] == 0.92

    def test_analyze_calls_generate_content_with_model_and_json_config(self):
        """
        Confirms the call uses the google-genai client shape:
        client.models.generate_content(model=..., contents=..., config=...)
        with response_mime_type='application/json' enforced server-side —
        not the legacy module-level genai.GenerativeModel().generate_content().
        """
        mock_response = MagicMock()
        mock_response.text = json.dumps(_valid_gemini_payload())

        with patch.object(gemini_client, "_client") as mock_client:
            mock_client.models.generate_content.return_value = mock_response
            gemini_client.analyze(_sample_anomaly())

            call_kwargs = mock_client.models.generate_content.call_args.kwargs
            assert call_kwargs["model"] == gemini_client.GEMINI_MODEL
            assert "contents" in call_kwargs
            assert call_kwargs["config"].response_mime_type == "application/json"

    def test_analyze_returns_safe_fallback_on_json_error(self):
        mock_response = MagicMock()
        mock_response.text = "this is not json at all"

        with patch.object(gemini_client, "_client") as mock_client:
            mock_client.models.generate_content.return_value = mock_response
            result = gemini_client.analyze(_sample_anomaly())

        assert result["suggested_action"] == "manual_intervention"
        assert result["confidence"] == 0.0
        assert "Gemini analysis unavailable" in result["likely_cause"]

    def test_analyze_returns_safe_fallback_on_api_exception(self):
        with patch.object(gemini_client, "_client") as mock_client:
            mock_client.models.generate_content.side_effect = Exception("API timeout")
            result = gemini_client.analyze(_sample_anomaly())

        assert result["suggested_action"] == "manual_intervention"
        assert result["confidence"] == 0.0

    def test_analyze_never_raises(self):
        with patch.object(gemini_client, "_client") as mock_client:
            mock_client.models.generate_content.side_effect = RuntimeError("boom")
            # Should not raise
            result = gemini_client.analyze(_sample_anomaly())
            assert isinstance(result, dict)
