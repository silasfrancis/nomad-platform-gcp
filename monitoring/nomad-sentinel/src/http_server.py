"""
http_server.py
Lightweight Flask HTTP server exposing two endpoints:

  GET /health   — liveness probe. Returns 200 immediately, no Nomad call.
                  Used by Consul health checks and Nomad service health gates.

  GET /summary  — on-demand cluster health summary. Calls Nomad + Gemini,
                  returns JSON. Designed for demos and manual inspection:
                  "what does the agent see right now?"

The server runs in a daemon thread so it does not block the main anomaly
detection loop. If Flask fails to bind, the agent logs the error and
continues — the HTTP endpoint is an addition, not a dependency of the
monitoring loop.

Port is configurable via HTTP_PORT (default 8090, matching the Nomad job
spec and Prometheus scrape config).
"""

import threading

import structlog
from flask import Flask, jsonify, request

import summarizer
import falco
from config import HTTP_PORT, ENVIRONMENT

log = structlog.get_logger()

app = Flask(__name__)


# ── Endpoints ─────────────────────────────────────────────────────────────────

@app.get("/")
def index():
    return jsonify(
        service="nomad-sentinel",
        status="ok",
        environment=ENVIRONMENT,
        endpoints={
            "GET /health":   "liveness probe with instant response and no Nomad call",
            "GET /summary":  "on-demand cluster health summary which calls Nomad + Gemini and returns JSON",
            "POST /anomaly": "receives a Falco security alert for triage and alerting (see falco-webhook)",
        },
    ), 200


@app.get("/health")
def health():
    """
    Liveness probe. No Nomad call, no Gemini call.
    Returns 200 immediately — a slow Nomad API must not make this fail.
    Consul health checks and Nomad task health gates call this endpoint.
    """
    return jsonify({"status": "ok", "environment": ENVIRONMENT}), 200


@app.get("/summary")
def summary():
    """
    On-demand cluster health summary.

    Calls Nomad to fetch current allocation state, passes it to Gemini
    for analysis, and returns the structured result as JSON.

    Response shape:
    {
      "overall_status":   "healthy" | "degraded" | "critical",
      "healthy_count":    int,
      "unhealthy_count":  int,
      "pending_count":    int,
      "total_allocs":     int,
      "summary":          str,
      "notable_issues":   [str],
      "confidence":       float,
      "generated_at":     "2026-06-29T12:00:00Z",
      "environment":      str
    }

    On error, returns HTTP 500 with an error field in the body.
    """
    log.info("summary_endpoint_called")
    try:
        result = summarizer.get_cluster_summary()
        status_code = 200 if "error" not in result else 500
        return jsonify(result), status_code
    except Exception as e:
        log.error("summary_endpoint_error", error=str(e))
        return jsonify({"error": str(e), "environment": ENVIRONMENT}), 500


@app.post("/anomaly")
def anomaly():
    """
    Receives a Falco security alert (falco-webhook's native http_output
    JSON shape — see monitoring/falco-webhook/main.go's FalcoAlert struct)
    and queues it for triage.

    Responds 202 immediately and processes in a background thread rather
    than inline: analysis calls Gemini, which can take longer than
    falco-webhook's own 5s HTTP client timeout, and there's no reason for
    Falco's own request/response cycle to wait on Slack-alert latency.
    falco-webhook already treats a failed/slow call here as non-fatal
    (logs a WARN and moves on), so this endpoint doesn't need to guarantee
    synchronous completion to be a reliable integration.

    Expected request body (Falco's native http_output shape):
    {
      "output": str, "priority": str, "rule": str, "time": str (RFC3339),
      "source": str, "hostname": str, "tags": [str],
      "output_fields": {str: any}
    }

    Returns 202 on a structurally valid payload (processing continues in
    the background), 400 if required fields (output/priority/rule) are
    missing or the body isn't valid JSON.
    """
    payload = request.get_json(silent=True)
    if not isinstance(payload, dict):
        return jsonify({"error": "request body must be a JSON object"}), 400

    missing = [f for f in ("output", "priority", "rule") if not payload.get(f)]
    if missing:
        return jsonify({"error": f"missing required field(s): {', '.join(missing)}"}), 400

    def _process():
        try:
            falco.handle_falco_alert(payload)
        except Exception as e:
            log.error("falco_alert_processing_failed", error=str(e))

    threading.Thread(target=_process, name="falco-alert", daemon=True).start()

    log.info("anomaly_endpoint_accepted", rule=payload.get("rule"), priority=payload.get("priority"))
    return jsonify({"status": "accepted"}), 202


# ── Thread startup ────────────────────────────────────────────────────────────

def start_http_server() -> threading.Thread:
    """
    Start the Flask server in a daemon thread.

    Daemon thread: if the main process exits (intentionally or via
    exception), this thread is cleaned up automatically — no hanging
    process left behind.

    Returns the thread so callers can log its start but should not
    join it (it runs for the lifetime of the process).
    """
    def _run():
        try:
            log.info("http_server_starting", port=HTTP_PORT)
            # use_reloader=False: reloader spawns a child process and
            # conflicts with the daemon thread model.
            # threaded=True: allow concurrent requests (e.g. Prometheus
            # scrape + /summary call at the same time).
            app.run(
                host="0.0.0.0",
                port=HTTP_PORT,
                use_reloader=False,
                threaded=True,
            )
        except Exception as e:
            log.error("http_server_failed", error=str(e))

    thread = threading.Thread(target=_run, name="http-server", daemon=True)
    thread.start()
    log.info("http_server_thread_started", port=HTTP_PORT)
    return thread
