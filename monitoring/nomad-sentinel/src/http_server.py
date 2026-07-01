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
from flask import Flask, jsonify

import summarizer
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
            "GET /health":  "liveness probe with instant response and no Nomad call",
            "GET /summary": "on-demand cluster health summary which calls Nomad + Gemini and returns JSON",
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
