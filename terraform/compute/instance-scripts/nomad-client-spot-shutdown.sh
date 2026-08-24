#!/bin/bash
# GCE Shutdown Script — Wired Into nomad-dev-spot / nomad-prod-spot Instance
# Templates Only (NOT *-ondemand — Those Pools Aren't Preemptible, So There's
# Nothing To Drain For). Runs During GCP's ~30s ACPI G2 Soft-Off Warning
# Window Before A Spot Instance Is Actually Reclaimed.
#
# -deadline 25s Deliberately Leaves A Buffer Below GCP's Warning
# Window (30s) So The Drain Command Itself Has Time To Return Before Termination.

set -euo pipefail

echo "[nomad-client-spot-shutdown] Preemption signal received, draining node..."

nomad node drain -self -enable -deadline 25s -yes || \
  echo "[nomad-client-spot-shutdown] Drain command failed or timed out — instance is terminating regardless."

echo "[nomad-client-spot-shutdown] Drain attempt complete."
