#!/bin/bash
# scripts/close-tunnels.sh
# Kills any gcloud IAP tunnel processes started by open-tunnels.sh.
pkill -f "start-iap-tunnel" && echo "Tunnels closed." || echo "No matching tunnel processes found."
