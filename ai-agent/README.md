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
   `REMEDIATION_CONFIDENCE_THRESHOLD`, attempts automated remediation:
   - `increase_memory` — patches the task's memory limit and resubmits the job
   - `restart` — stops the allocation, Nomad reschedules it
   - `revert` — reverts the job to its previous version
6. Tracks remediation attempts per job. After `MAX_REMEDIATION_ATTEMPTS`,
   stops attempting and sends an escalation alert instead
7. Applies a cooldown (`COOLDOWN_SECONDS`) after any remediation attempt to
   avoid rapid repeated action on the same job

## Architecture

```
src/
├── main.py            # control loop, remediation decision logic
├── detector.py         # polls Nomad API, identifies anomalies, fetches logs
├── gemini_client.py     # builds prompts, calls Gemini, validates responses
├── remediator.py        # executes remediation against the Nomad API
├── alerter.py            # sends Slack webhook alerts
├── state.py               # in-memory cooldown + attempt tracking
└── config.py                # all configuration from environment variables
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
| `ENVIRONMENT` | No | `unknown` | Label used in alerts/logs, e.g. `dev`, `prod` |
| `POLL_INTERVAL_SECONDS` | No | `30` | Control loop interval |
| `RESTART_THRESHOLD` | No | `3` | Restart count that triggers `restart_loop` |
| `PENDING_THRESHOLD_SECONDS` | No | `120` | Time before `pending` is flagged |
| `STARTING_THRESHOLD_SECONDS` | No | `180` | Time before `starting` is flagged |
| `LOG_TAIL_LINES` | No | `200` | Log lines fetched per anomaly |
| `REMEDIATION_CONFIDENCE_THRESHOLD` | No | `0.8` | Minimum Gemini confidence to remediate |
| `MAX_REMEDIATION_ATTEMPTS` | No | `3` | Max auto-remediation attempts per job |
| `COOLDOWN_SECONDS` | No | `300` | Cooldown after a remediation attempt |
| `GEMINI_MODEL` | No | `gemini-1.5-flash` | Gemini model name |
| `WATCH_NAMESPACES` | No | (all) | Comma-separated Nomad namespaces to watch |

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

All Nomad, Gemini, and Slack calls are mocked in tests (`responses` for
HTTP, `unittest.mock` for the Gemini SDK) — the test suite never makes a
real network call.

## Docker

```bash
docker build -t nomad-ai-agent .
docker run --rm \
  -e NOMAD_ADDR=http://nomad.service.consul:4646 \
  -e NOMAD_TOKEN=... \
  -e GEMINI_API_KEY=... \
  -e SLACK_WEBHOOK_URL=... \
  -e ENVIRONMENT=dev \
  nomad-ai-agent
```

## Safety guardrails

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
