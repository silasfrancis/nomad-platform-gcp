#!/usr/bin/env bash
# scripts/restore-octopus.sh
#
# Restores Octopus Deploy's backing store — SQL Server Express, running as a
# Docker container on mgmt-vm (§6.3) — from a .bak file. Octopus itself
# holds no state outside this database (projects, releases, variables,
# environments, deployment targets all live in SQL Server), so this one
# restore covers all of Octopus.
#
# This is the only restore of the five that isn't a HashiCorp tool, hence
# the different shape: stop the Octopus service (it holds open connections
# that block a RESTORE DATABASE), run sqlcmd's T-SQL RESTORE DATABASE with
# WITH REPLACE inside the container, restart Octopus, then hit its own
# health/status API to confirm it can see its data again.
#
# Usage:
#   GCP_PROJECT=my-project scripts/restore-octopus.sh

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=lib/restore-common.sh
source lib/restore-common.sh

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes) ASSUME_YES=1; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done

# Octopus is single-instance on mgmt-vm, same as Vault — there's no
# dev/prod split to select, it's one Octopus serving both environments'
# deployment targets. require_env exists purely to reuse the confirmation
# gate's environment-name echo; pin it here since there's nothing to choose.
TARGET_ENV="mgmt"

MGMT_HOST="mgmt-vm"
CONTAINER_NAME="octopus-mssql"   # per ansible octopus_vars.yaml (mssql_container_name)
DB_NAME="OctopusDeploy"

confirm_destructive "About to STOP Octopus Deploy and REPLACE the entire SQL Server Express database backing it — all projects, releases, variables, environments, and deployment target registrations revert to the backup's point in time. Any release created after the backup was taken will be gone."

# octopus-mssql-admin-password comes from GCP Secret Manager, NOT Vault —
# deliberately. Octopus/SQL Server on mgmt-vm has to be restorable
# independently of Vault (mgmt-vm also hosts Vault itself, so a scenario
# where this restore is needed could easily be one where Vault is also
# down or mid-restore). Same secret the nightly mssql-backup.service
# systemd unit already reads for `BACKUP DATABASE`.
log "fetching SA password for SQL Server Express from GCP Secret Manager"
SA_PASSWORD=$(fetch_gcp_secret "octopus-mssql-admin-password")

backup_file=$(fetch_latest_from_gcs "sql-backups/" "$SCRATCH_DIR")
log "using backup: $backup_file"

log "stopping Octopus Deploy Server (holds connections that block RESTORE DATABASE)"
iap_ssh "$MGMT_HOST" "sudo systemctl stop octopus" \
  || die "could not stop the octopus systemd service on $MGMT_HOST"

log "copying backup file to $MGMT_HOST"
iap_scp_to "$backup_file" "$MGMT_HOST" "/tmp/octopus-restore.bak"

log "copying backup into the SQL Server Express container"
iap_ssh "$MGMT_HOST" "docker cp /tmp/octopus-restore.bak ${CONTAINER_NAME}:/var/opt/mssql/backup/octopus-restore.bak"

# WITH REPLACE is required because we're overwriting a database that
# already exists (as opposed to restoring onto a truly fresh instance).
# MOVE clauses aren't included here because the container's default data/log
# paths haven't changed since backup — if that ever changes, this will need
# explicit MOVE ... TO clauses derived from RESTORE FILELISTONLY first.
log "running RESTORE DATABASE via sqlcmd inside the container"
iap_ssh "$MGMT_HOST" "docker exec ${CONTAINER_NAME} /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P '${SA_PASSWORD}' -C -Q \"RESTORE DATABASE [${DB_NAME}] FROM DISK = N'/var/opt/mssql/backup/octopus-restore.bak' WITH REPLACE, STATS = 10;\"" \
  || die "RESTORE DATABASE failed — Octopus remains stopped intentionally, do not restart it against a half-restored database"

log "cleaning up backup file inside the container"
iap_ssh "$MGMT_HOST" "docker exec ${CONTAINER_NAME} rm -f /var/opt/mssql/backup/octopus-restore.bak && rm -f /tmp/octopus-restore.bak"

log "restarting Octopus Deploy Server"
iap_ssh "$MGMT_HOST" "sudo systemctl start octopus" \
  || die "database restore succeeded but Octopus failed to start — check 'journalctl -u octopus' on $MGMT_HOST before retrying"

log "waiting for Octopus API to come back (up to 60s)"
for i in $(seq 1 12); do
  if iap_ssh "$MGMT_HOST" "curl -sf http://localhost:8080/api/serverstatus -o /dev/null"; then
    log "Octopus API is responding"
    break
  fi
  [[ "$i" == 12 ]] && warn "Octopus API still not responding after 60s — check the service manually"
  sleep 5
done

log "manual verification:"
cat <<EOF
  # Via the IAP tunnel + octopus.platform.lefrancis.org:
  #   - Confirm all 13 projects are present (11 Online Boutique + metrics-api + ai-agent)
  #   - Confirm both deployment targets (dev-nomad, prod-nomad) show healthy
  #   - Spot-check one project's release history matches the backup's point in time
EOF
log "done."
