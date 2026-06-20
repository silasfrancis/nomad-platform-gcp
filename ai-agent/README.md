# Nomad AI Monitoring Agent

A Python control-loop agent that polls a Nomad cluster for anomalous allocations,
sends context to Gemini 1.5 Flash for root-cause analysis, alerts via Slack, and
performs bounded automated remediation.

This is a standalone platform tool, deployed independently of the application
services it monitors. It runs as a Nomad `service` job — one instance per
environment (dev / prod) — and only ever knows about its own cluster.

## What it detects

| Condition | Nomad equivalent of... | How it's detected |
|---|---|---|
| `restart_loop` | CrashLoopBackOff | Task restart count exceeds `RESTART_THRESHOLD` |
| `oom_killed` | OOMKilled | Exit code 137 or "OOM" in task events |
| `stuck_pending` | Pod stuck Pending | Allocation in `pending` state past `PENDING_THRESHOLD_SECONDS` |
| `stuck_starting` | ContainerCreating stuck | Task in `starting` state past `STARTING_THRESHOLD_SECONDS` |
| `image_pull_failure` | ImagePullBackOff | Task events mention failed image pull |

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

## Architecture

```
src/
├── main.py            # control loop, remediation decision logic, mode gate
├── detector.py         # polls Nomad API, identifies anomalies, fetches logs
├── gemini_client.py     # builds prompts, calls Gemini, validates responses
├── remediator.py        # executes remediation against the Nomad API (execute mode only)
├── alerter.py            # sends Slack webhook alerts (normal, proposal, escalation)
├── history.py             # persists anomaly + outcome history to PostgreSQL (optional)
├── state.py                # in-memory cooldown + attempt tracking
└── config.py                 # all configuration from environment variables
```

## Anomaly history (optional)

If `HISTORY_DATABASE_URL` is set, every anomaly the agent handles is
persisted to a PostgreSQL table (`agent_anomalies`) — what was detected,
what Gemini decided, and what actually happened. This reuses the same
PostgreSQL instance `metrics-api` connects to (a separate table, same
database), rather than introducing a second database to operate.

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
values) where applicable.

```sql
-- What got remediated most often this week?
SELECT job_id, anomaly_type, COUNT(*)
FROM agent_anomalies
WHERE outcome = 'remediated' AND detected_at > now() - interval '7 days'
GROUP BY job_id, anomaly_type
ORDER BY count DESC;
```

## Configuration

All configuration is via environment variables — nothing is hardcoded.
Secrets (`NOMAD_TOKEN`, `GEMINI_API_KEY`, `SLACK_WEBHOOK_URL`) are injected
at runtime via Vault using Nomad's Workload Identity template stanza; they
are never present in the Docker image or job spec.

| Variable | Required | Default | Purpose |
|---|---|---|---|
| `NOMAD_ADDR` | Yes | — | Nomad API address, e.g. `http://10.0.1.10:4646` |
| `NOMAD_TOKEN` | Yes | — | Nomad ACL token scoped for the agent |
| `GEMINI_API_KEY` | Yes | — | Gemini API key, injected from Vault |
| `SLACK_WEBHOOK_URL` | Yes | — | Slack incoming webhook URL, injected from Vault |
| `REMEDIATION_MODE` | Yes | — | `execute` (autonomous, dev) or `propose` (alert-only, prod) — see above |
| `ENVIRONMENT` | No | `unknown` | Label used in alerts/logs, e.g. `dev`, `prod` |
| `POLL_INTERVAL_SECONDS` | No | `30` | Control loop interval |
| `RESTART_THRESHOLD` | No | `3` | Restart count that triggers `restart_loop` |
| `PENDING_THRESHOLD_SECONDS` | No | `120` | Time before `pending` is flagged |
| `STARTING_THRESHOLD_SECONDS` | No | `180` | Time before `starting` is flagged |
| `LOG_TAIL_LINES` | No | `200` | Log lines fetched per anomaly |
| `REMEDIATION_CONFIDENCE_THRESHOLD` | No | `0.8` | Minimum Gemini confidence to remediate/propose |
| `MAX_REMEDIATION_ATTEMPTS` | No | `3` | Max attempts (executed or proposed) per job before escalating |
| `COOLDOWN_SECONDS` | No | `300` | Cooldown after a remediation attempt |
| `GEMINI_MODEL` | No | `gemini-1.5-flash` | Gemini model name |
| `WATCH_NAMESPACES` | No | (all) | Comma-separated Nomad namespaces to watch |
| `HISTORY_DATABASE_URL` | No | (disabled) | PostgreSQL connection string for anomaly history — see above. Unset disables persistence entirely. |

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

cd src
python main.py
```

Pair this with a local Nomad dev agent (`nomad agent -dev`) to exercise the
full loop without any cloud infrastructure.

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
  -e NOMAD_ADDR=http://nomad.service.consul:4646 \
  -e NOMAD_TOKEN=... \
  -e GEMINI_API_KEY=... \
  -e SLACK_WEBHOOK_URL=... \
  -e ENVIRONMENT=dev \
  -e REMEDIATION_MODE=execute \
  -e HISTORY_DATABASE_URL=postgresql://user:pass@metrics-postgres:5432/metricsdb \
  nomad-ai-agent

# Prod — alert-only, human acts manually
docker run --rm \
  -e NOMAD_ADDR=http://nomad.service.consul:4646 \
  -e NOMAD_TOKEN=... \
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
- Per-job attempt cap with escalation alert once exceeded — the agent will
  not loop indefinitely trying to fix something it can't fix
- Memory increases are capped at 1024MB per remediation to prevent runaway
  resource scaling from a bad Gemini suggestion
- All Gemini and Nomad API failures fall back safely — a Gemini outage
  results in an alert-only response, never a crash of the control loop
