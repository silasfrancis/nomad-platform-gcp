# Nomad Sentinel (AI Monitoring & Remediation Agent)

A Python control-loop agent that polls a Nomad cluster for anomalous allocations,
sends context to Gemini 2.5 Flash for root-cause analysis, alerts via Slack, and
performs bounded automated remediation. It also accepts Falco runtime security
alerts over HTTP for triage and alerting alongside its own Nomad-native
detection.

This is a standalone platform tool, deployed independently of the application
services it monitors. It runs as a Nomad `service` job — one instance per
environment (dev / prod) — and only ever knows about its own cluster.

## What it detects

**From polling the Nomad API directly:**

| Condition | Nomad equivalent of... | How it's detected |
|---|---|---|
| `restart_loop` | CrashLoopBackOff | Task restart count exceeds `RESTART_THRESHOLD` |
| `oom_killed` | OOMKilled | Exit code 137 or "OOM" in task events |
| `stuck_pending` | Pod stuck Pending | Allocation in `pending` state past `PENDING_THRESHOLD_SECONDS` |
| `stuck_starting` | ContainerCreating stuck | Task in `starting` state past `STARTING_THRESHOLD_SECONDS` |
| `image_pull_failure` | ImagePullBackOff | Task events mention failed image pull |

**From Falco, pushed in over HTTP:** any runtime security alert Falco fires at
`warning` priority or above (shell spawned in a container, unexpected outbound
connection, sensitive file read, etc.) is forwarded here by a separate
`falco-webhook` service and triaged the same way — see
[Falco security alerts](#falco-security-alerts-posted-in) below.

## What it does

1. Polls the Nomad API every `POLL_INTERVAL_SECONDS` (default 30s)
2. For each anomalous allocation found, fetches recent logs and task events
3. Sends the full context to Gemini, which returns a structured analysis:
   `likely_cause`, `severity`, `suggested_action`, `confidence`, `summary`
4. Always logs the analysis (structured JSON to stdout — picked up by
   Grafana Alloy and shipped to Loki) and sends a Slack alert
5. If severity is `high`/`critical` **and** confidence meets
   `REMEDIATION_CONFIDENCE_THRESHOLD`, the agent's behaviour depends on
   `REMEDIATION_MODE`:
   - **`execute`** — attempts automated remediation against the live Nomad
     API: `increase_memory`, `restart`, or `revert`
   - **`propose`** — takes no action against Nomad. Instead sends a clearly
     labelled "ACTION REQUIRED" Slack alert stating exactly what the agent
     would have done, so a human can act on it manually
6. Tracks remediation attempts per job. After `MAX_REMEDIATION_ATTEMPTS`,
   stops attempting/proposing and sends an escalation alert instead
7. Applies a cooldown (`COOLDOWN_SECONDS`) after any remediation attempt
   (executed or proposed) to avoid rapid repeated action on the same job

This is the Nomad-native detection path (steps 1–7 above). Falco alerts
arrive separately over HTTP and are triaged with the same Gemini-analysis-
and-alert machinery, but with remediation deliberately excluded — see below.

## Remediation mode — autonomous vs human-in-the-loop

`REMEDIATION_MODE` is a required, explicit setting per environment — there
is no implicit default, because the blast radius of autonomous remediation
should never depend on something easy to overlook.

| Environment | `REMEDIATION_MODE` | Behaviour |
|---|---|---|
| dev | `execute` | Agent autonomously patches memory, restarts allocations, and reverts jobs. This is where the remediation logic is proven out and tuned. |
| prod | `propose` | Agent does all the same detection and Gemini analysis, but never calls the Nomad API. It sends a Slack alert describing the proposed action; a human reviews and acts manually. |

This is a deliberate staged-trust design: once the remediation logic has
proven reliable in dev (and ideally once a stronger Gemini model is
available), prod can be flipped to `execute` by changing one variable in
the Nomad job spec — no code change required.

In `propose` mode, the agent still goes through the same cooldown and
max-attempt bookkeeping as `execute` mode. This is intentional — without
it, the same proposal would be re-sent to Slack on every poll cycle
(every 30 seconds by default) until a human acted on it.

`REMEDIATION_MODE` only governs the Nomad-native detection path. Falco alerts
never trigger remediation in either mode — see below.

## HTTP endpoints

The agent runs a small Flask server (`HTTP_PORT`, default `8090`) alongside
the polling loop, in a daemon thread so a slow or failed request never blocks
detection:

| Endpoint | Purpose |
|---|---|
| `GET /health` | Liveness probe. Instant response, no Nomad or Gemini call. Used by the Consul health check and Nomad health gate in the job spec. |
| `GET /summary` | On-demand cluster health summary — calls Nomad + Gemini and returns JSON. Useful for demos and manual "what does the agent see right now?" checks. |
| `POST /anomaly` | Receives a Falco security alert for triage and alerting. See below. |

## Falco security alerts (posted in)

A separate `falco-webhook` service receives Falco's native HTTP output,
forwards everything to Loki, and — for anything `warning` priority or
above — POSTs the same alert here to `/anomaly`. The request body is
Falco's own native `http_output` JSON shape (`output`, `priority`, `rule`,
`time`, `source`, `hostname`, `tags`, `output_fields`); no translation is
needed on the sending side.

The endpoint validates the payload, responds `202 Accepted` immediately, and
does the actual triage in a background thread — analysis can take longer
than falco-webhook's own request timeout, and there's no reason to hold that
connection open for it. `400` is returned only if the body isn't valid JSON
or is missing `output`/`priority`/`rule`.

Once accepted, a Falco alert goes through the same Gemini-analysis-and-Slack-
alert path as a Nomad-detected anomaly, with two differences:

- **A separate, security-oriented prompt.** The Nomad-detection prompt is
  built around workload crashes (restart counts, memory limits); a Falco
  alert gets its own prompt asking Gemini to triage actual security risk
  rather than just echoing Falco's own priority.
- **Remediation is never attempted, in either `REMEDIATION_MODE`.** A Falco
  alert carries no verified Nomad `alloc_id` — only best-effort container/
  process identifiers Falco happened to capture — and "restart" or "revert"
  isn't a meaningful response to a security event regardless (it doesn't
  address the underlying activity and may destroy evidence). This is
  enforced in code, not just by prompt instructions: the Falco path never
  calls `remediator.py`. Every Falco alert is recorded to history (when
  `HISTORY_DATABASE_URL` is set) with outcome `alerted_only`.

`job_id`/`task` shown in the resulting Slack alert and history row come
directly from Falco's `output_fields` (`container.name`, `proc.name`) when
present, falling back to `falco-host:<hostname>` — this is never guessed at
from Nomad's own container-naming convention, so it may be less specific
than a Nomad-native anomaly's `job_id`, but it won't be silently wrong.

## Architecture

```
src/
├── main.py            # control loop, remediation decision logic, mode gate
├── detector.py         # polls Nomad API, identifies anomalies, fetches logs
├── falco.py             # maps an incoming Falco alert to an anomaly and triages it (alert-only, no remediation)
├── gemini_client.py       # builds prompts (Nomad-crash and Falco-security), calls Gemini, validates responses
├── remediator.py            # executes remediation against the Nomad API (execute mode only)
├── nomad_client.py            # shared requests.Session for all Nomad API calls — CA trust, mTLS, TLS hostname override
├── alerter.py                    # sends Slack webhook alerts (normal, proposal, escalation)
├── history.py                      # persists anomaly + outcome history to PostgreSQL (optional)
├── state.py                          # in-memory cooldown + attempt tracking (Nomad-native detections only)
├── http_server.py                      # Flask server: /health, /summary, /anomaly
├── scheduler.py                          # posts a proactive cluster summary to Slack on an interval
└── config.py                                # all configuration from environment variables
```

## Anomaly history (optional)

If `HISTORY_DATABASE_URL` is set, every anomaly the agent handles — Nomad-
native or Falco-sourced — is persisted to a PostgreSQL table
(`agent_anomalies`): what was detected, what Gemini decided, and what
actually happened. This reuses the same PostgreSQL instance `metrics-api`
connects to (a separate table, same database), rather than introducing a
second database to operate.

This is purely additive. The table schema is created automatically on
startup if it doesn't exist (`history.ensure_schema()`). If
`HISTORY_DATABASE_URL` is unset, or the database is unreachable at any
point, the agent logs a warning and continues operating exactly as it
did before this feature existed — detection, Gemini analysis, Slack
alerting, and remediation are never gated on a successful database
write. This is deliberate: monitoring infrastructure should not be able
to take itself down by losing its own logging backend.

Each row records: environment, detection timestamp, job/alloc/task/
namespace, anomaly type, restart count, Gemini's likely cause/severity/
confidence/suggested action, the remediation mode in effect at the time,
and an `outcome` — one of `alerted_only`, `proposed`, `remediated`,
`remediation_failed`, `escalated`, or `skipped_cooldown` — plus a JSONB
`outcome_detail` column for remediation specifics (e.g. old/new memory
values) where applicable. Falco-sourced rows always have `outcome =
'alerted_only'`, since that path never remediates.

```sql
-- What got remediated most often this week?
SELECT job_id, anomaly_type, COUNT(*)
FROM agent_anomalies
WHERE outcome = 'remediated' AND detected_at > now() - interval '7 days'
GROUP BY job_id, anomaly_type
ORDER BY count DESC;

-- Falco alerts by rule this week
SELECT anomaly_type, severity, COUNT(*)
FROM agent_anomalies
WHERE anomaly_type LIKE 'falco:%' AND detected_at > now() - interval '7 days'
GROUP BY anomaly_type, severity
ORDER BY count DESC;
```

## Configuration

All configuration is via environment variables — nothing is hardcoded.
Secrets (`NOMAD_TOKEN`, `GEMINI_API_KEY`, `SLACK_WEBHOOK_URL`) are injected
at runtime via Vault using Nomad's Workload Identity template stanza; they
are never present in the Docker image or job spec.

| Variable | Required | Default | Purpose |
|---|---|---|---|
| `NOMAD_ADDR` | Yes | — | Nomad API address, e.g. `https://10.0.1.10:4646` |
| `NOMAD_TOKEN` | Yes | — | Nomad ACL token scoped for the agent |
| `NOMAD_CACERT` | No | (system/certifi trust store) | Path to the CA bundle that signed the Nomad server's cert |
| `NOMAD_CLIENT_CERT` / `NOMAD_CLIENT_KEY` | No | — | Optional mTLS client identity, if the cluster requires `verify_https_client` |
| `NOMAD_TLS_SERVER_NAME` | No | (hostname in `NOMAD_ADDR`) | Hostname to verify the Nomad server cert against — needed when `NOMAD_ADDR` is a bare IP (e.g. resolved via Consul) rather than the hostname the cert was actually issued for |
| `GEMINI_API_KEY` | Yes | — | Gemini API key, injected from Vault |
| `SLACK_WEBHOOK_URL` | Yes | — | Slack incoming webhook URL, injected from Vault |
| `REMEDIATION_MODE` | Yes | — | `execute` (autonomous, dev) or `propose` (alert-only, prod) — see above. Governs the Nomad-native path only; Falco alerts never remediate either way. |
| `ENVIRONMENT` | No | `unknown` | Label used in alerts/logs, e.g. `dev`, `prod` |
| `POLL_INTERVAL_SECONDS` | No | `30` | Control loop interval |
| `RESTART_THRESHOLD` | No | `3` | Restart count that triggers `restart_loop` |
| `PENDING_THRESHOLD_SECONDS` | No | `120` | Time before `pending` is flagged |
| `STARTING_THRESHOLD_SECONDS` | No | `180` | Time before `starting` is flagged |
| `LOG_TAIL_LINES` | No | `200` | Log lines fetched per anomaly |
| `REMEDIATION_CONFIDENCE_THRESHOLD` | No | `0.8` | Minimum Gemini confidence to remediate/propose |
| `MAX_REMEDIATION_ATTEMPTS` | No | `3` | Max attempts (executed or proposed) per job before escalating |
| `COOLDOWN_SECONDS` | No | `300` | Cooldown after a remediation attempt |
| `GEMINI_MODEL` | No | `gemini-2.5-flash` | Gemini model name |
| `WATCH_NAMESPACES` | No | (all) | Comma-separated Nomad namespaces to watch |
| `HISTORY_DATABASE_URL` | No | (disabled) | PostgreSQL connection string for anomaly history — see above. Unset disables persistence entirely. |
| `HTTP_PORT` | No | `8090` | Port for the built-in Flask server (`/health`, `/summary`, `/anomaly`) |
| `SUMMARY_INTERVAL_HOURS` | No | `6.0` | How often to post a proactive cluster health summary to Slack. `0` disables it. |

**Note on `requests` and TLS:** unlike the Go-based Nomad/Consul/Vault CLIs
and SDKs, Python's `requests` library does not read `NOMAD_CACERT`,
`NOMAD_CLIENT_CERT`, `NOMAD_CLIENT_KEY`, or `NOMAD_TLS_SERVER_NAME`
automatically — they're wired in explicitly via a shared session in
`nomad_client.py`, which every module that calls the Nomad API uses.

## Running locally

```bash
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt

export NOMAD_ADDR=http://localhost:4646
export NOMAD_TOKEN=dev-token
export GEMINI_API_KEY=your-key
export SLACK_WEBHOOK_URL=https://hooks.slack.com/services/...
export ENVIRONMENT=dev
export REMEDIATION_MODE=execute   # use 'propose' to test alert-only behaviour
export HISTORY_DATABASE_URL=postgresql://user:pass@localhost:5432/metricsdb  # optional
# TLS is only needed against a real TLS-enabled Nomad cluster — a local
# `nomad agent -dev` is plaintext HTTP, so these can stay unset:
# export NOMAD_CACERT=/path/to/ca.pem
# export NOMAD_CLIENT_CERT=/path/to/cert.pem
# export NOMAD_CLIENT_KEY=/path/to/key.pem
# export NOMAD_TLS_SERVER_NAME=server.dev.nomad

cd src
python main.py
```

Pair this with a local Nomad dev agent (`nomad agent -dev`) to exercise the
full loop without any cloud infrastructure. To exercise the Falco path
locally, POST a sample Falco `http_output` payload to `/anomaly` yourself:

```bash
curl -X POST http://localhost:8090/anomaly \
  -H 'Content-Type: application/json' \
  -d '{
    "output": "Shell spawned in container",
    "priority": "Warning",
    "rule": "Terminal shell in container",
    "time": "2026-09-19T18:00:00.000000000Z",
    "hostname": "nomad-client-01",
    "tags": ["container", "shell"],
    "output_fields": {"container.name": "web-abc123", "proc.name": "bash"}
  }'
```

## Running tests

```bash
pip install -r requirements.txt
pytest
```

All Nomad, Gemini, Slack, and PostgreSQL calls are mocked in tests
(`responses` for HTTP, `unittest.mock` for the Gemini SDK and
`psycopg2.connect`) — the test suite never makes a real network or
database call.

## Docker

```bash
docker build -t nomad-ai-agent .

# Dev — autonomous remediation, with history persistence
docker run --rm \
  -e NOMAD_ADDR=https://nomad.service.consul:4646 \
  -e NOMAD_TOKEN=... \
  -e NOMAD_CACERT=/secrets/nomad-ca.pem \
  -e NOMAD_TLS_SERVER_NAME=server.dev.nomad \
  -e GEMINI_API_KEY=... \
  -e SLACK_WEBHOOK_URL=... \
  -e ENVIRONMENT=dev \
  -e REMEDIATION_MODE=execute \
  -e HISTORY_DATABASE_URL=postgresql://user:pass@metrics-postgres:5432/metricsdb \
  nomad-ai-agent

# Prod — alert-only, human acts manually
docker run --rm \
  -e NOMAD_ADDR=https://nomad.service.consul:4646 \
  -e NOMAD_TOKEN=... \
  -e NOMAD_CACERT=/secrets/nomad-ca.pem \
  -e NOMAD_TLS_SERVER_NAME=server.prod.nomad \
  -e GEMINI_API_KEY=... \
  -e SLACK_WEBHOOK_URL=... \
  -e ENVIRONMENT=prod \
  -e REMEDIATION_MODE=propose \
  nomad-ai-agent
```

## Safety guardrails

- `REMEDIATION_MODE` defaults to nothing — it must be set explicitly per
  environment. Prod runs `propose` until the team is confident enough in
  the model and logic to trust `execute` in production
- Remediation only triggers above a confidence threshold — low-confidence
  Gemini responses always fall back to alert-only
- `check_image` and `manual_intervention` never trigger automated action,
  regardless of severity or confidence
- Falco-sourced anomalies never trigger automated action, in either
  `REMEDIATION_MODE` — enforced in code (the Falco path never calls
  `remediator.py`), not just by prompt instructions to Gemini
- Per-job attempt cap with escalation alert once exceeded — the agent will
  not loop indefinitely trying to fix something it can't fix
- Memory increases are capped at 1024MB per remediation to prevent runaway
  resource scaling from a bad Gemini suggestion
- All Gemini and Nomad API failures fall back safely — a Gemini outage
  results in an alert-only response, never a crash of the control loop