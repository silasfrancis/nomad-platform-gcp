#!/bin/bash
# GCE Shutdown Script — On-Demand Instance Templates Only.
#
# On-demand instances aren't preemptible, so this doesn't guard against GCP
# reclaiming capacity the way the spot version does. It exists purely as a
# safety net for out-of-band termination Nomad's own scale-in drain never
# sees: a manual `gcloud compute instances delete`, host maintenance forcing
# a stop/restart, or an operator error — none of which go through the
# autoscaler's node_drain_deadline first.

set -euo pipefail

echo "[nomad-client-ondemand-shutdown] Shutdown signal received, draining node..."

nomad node drain -self -enable -deadline 60s -yes || \
  echo "[nomad-client-ondemand-shutdown] Drain command failed or timed out — instance is terminating regardless."

echo "[nomad-client-ondemand-shutdown] Drain attempt complete."