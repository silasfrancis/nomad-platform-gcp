# metrics-api

A small custom platform-engineering demo service. Not part of Online
Boutique's business logic — built specifically to demonstrate Vault's
**dynamic** database secrets engine, which Online Boutique's own services
have no real opportunity to exercise (their only genuine secret dependency
is cartservice's static Redis password).

## Why this exists

Static secret injection (read a password once at startup) is a thin
demonstration of Vault. Dynamic credential issuance — a unique,
short-lived database role minted per workload, auto-rotated, auto-revoked
on shutdown — is the more valuable and more commonly needed pattern in
real platform engineering. This service exists to prove that lifecycle
end-to-end, with nothing else competing for attention in the code.

## Endpoints

| Endpoint | Behaviour |
|---|---|
| `GET /health` | Returns `200 OK` without touching the database. A DB outage should never make this fail — that's what `/db-check` is for. Used by Compose/Nomad health checks. |
| `GET /db-check` | Connects to PostgreSQL using whatever credentials `DATABASE_URL` currently holds, runs a trivial query, and reports the connected username, that role's password expiry (`rolvaliduntil`), and query duration. |
| `GET /metrics` | Minimal Prometheus-format exposition: request count, average DB query duration. |

## The one behaviour that matters most

`DATABASE_URL` is read fresh from the environment on every connection
attempt (`get_database_url()`), never cached at import time. This is
deliberate: once Vault is wired in via Nomad's Workload Identity template
stanza, a credential rotation rewrites the environment in place. A cached
value would silently keep using a credential that's about to be revoked.

Locally (Docker Compose, no Vault yet), `DATABASE_URL` is built from
static values in `.env` — `rolvaliduntil` will come back `null` in
`/db-check`'s response, which is correct and expected for a static user.
Once this moves to Nomad and Vault issues a dynamic role, that same field
will be populated with a real expiry timestamp, and you'll be able to
watch the `connected_as` username and `credential_valid_until` change on
each rotation by hitting `/db-check` repeatedly.

## Running locally

```bash
pip install -r requirements.txt
export DATABASE_URL=postgresql://user:pass@localhost:5432/metricsdb
export PORT=8080
python main.py
```

Or via the project's `docker-compose.yml` — see the top-level README.

## Running tests

```bash
pip install -r requirements.txt
pytest
```

The real PostgreSQL connection is mocked throughout (`psycopg2.connect` is
patched via the `get_connection()` seam) — the test suite never requires
an actual database. 18 tests cover: health check isolation from DB state,
fresh-read behaviour of `DATABASE_URL` (not cached), successful and
failed `/db-check` responses, the static-vs-dynamic-credential
`rolvaliduntil` distinction, connection cleanup on both success and
failure paths (important once a short-TTL Vault role's connection limit
is in play), and metrics counter accuracy.
