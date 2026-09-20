#!/usr/bin/env bash
# scripts/restore-octopus.sh
#
# Restores Octopus Deploy's backing store — SQL Server Express, running as a
# Docker container on mgmt-vm — from a .bak file. Octopus itself holds no
# state outside this database (projects, releases, variables, environments,
# deployment targets all live in SQL Server), so this one restore covers
# all of Octopus.
#
# Octopus is single-instance on mgmt-vm, same as Vault — there's no
# dev/prod split, it's one Octopus serving both environments' deployment
# targets.
#
# Both containers (octopus-server, octopus-mssql) run via Docker Compose on
# mgmt-vm, NOT systemd — everything below talks to them with `sudo docker
# ...` directly. sudo is used rather than assuming the SSH user is in the
# docker group.
#
# Usage:
#   GCP_PROJECT=my-project scripts/restore-octopus.sh
#
#   GCP_ZONE defaults to europe-west1-b (where mgmt-vm actually lives) —
#   override it if that ever changes.

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

MGMT_HOST="mgmt-vm"
OCTOPUS_CONTAINER="octopus-server"   # per ansible octopus_vars.yaml (octopus_container_name) — holds the DB connections that block RESTORE DATABASE
MSSQL_CONTAINER="octopus-mssql"      # per ansible octopus_vars.yaml (mssql_container_name)
DB_NAME="OctopusDeploy"

confirm_yesno "About to STOP Octopus Deploy and REPLACE the entire SQL Server Express database backing it — all projects, releases, variables, environments, and deployment target registrations revert to the backup's point in time. Any release created after the backup was taken will be gone."

# octopus-mssql-admin-password comes from GCP Secret Manager, NOT Vault —
# deliberately. mgmt-vm also hosts Vault itself, so a scenario where this
# restore is needed could easily be one where Vault is also down or
# mid-restore. Same secret the nightly mssql-backup.service systemd unit
# already reads for `BACKUP DATABASE`.
log "fetching SA password for SQL Server Express from GCP Secret Manager"
SA_PASSWORD=$(fetch_gcp_secret "octopus-mssql-admin-password")

backup_file=$(fetch_latest_from_gcs "sql-backups/" "$SCRATCH_DIR")
log "using backup: $backup_file"

log "stopping Octopus Deploy Server container (holds connections that block RESTORE DATABASE)"
iap_ssh "$MGMT_HOST" "sudo docker stop ${OCTOPUS_CONTAINER}" \
  || die "could not stop the ${OCTOPUS_CONTAINER} container on $MGMT_HOST"

log "copying backup file to $MGMT_HOST"
iap_scp_to "$backup_file" "$MGMT_HOST" "/tmp/octopus-restore.bak.gz"

log "decompressing and moving backup into the SQL Server Express container"
iap_ssh "$MGMT_HOST" "gunzip -f /tmp/octopus-restore.bak.gz && sudo docker exec ${MSSQL_CONTAINER} mkdir -p /var/opt/mssql/backup && sudo docker cp /tmp/octopus-restore.bak ${MSSQL_CONTAINER}:/var/opt/mssql/backup/octopus-restore.bak"

# WITH REPLACE is required because we're overwriting a database that
# already exists (as opposed to restoring onto a truly fresh instance).
# MOVE clauses aren't included here because the container's default data/log
# paths haven't changed since backup — if that ever changes, this will need
# explicit MOVE ... TO clauses derived from RESTORE FILELISTONLY first.
log "running RESTORE DATABASE via sqlcmd inside the container"
iap_ssh "$MGMT_HOST" "sudo docker exec ${MSSQL_CONTAINER} /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P '${SA_PASSWORD}' -C -Q \"RESTORE DATABASE [${DB_NAME}] FROM DISK = N'/var/opt/mssql/backup/octopus-restore.bak' WITH REPLACE, STATS = 10;\"" \
  || die "RESTORE DATABASE failed — Octopus remains stopped intentionally, do not restart it against a half-restored database"

log "cleaning up backup file"
iap_ssh "$MGMT_HOST" "sudo docker exec ${MSSQL_CONTAINER} rm -f /var/opt/mssql/backup/octopus-restore.bak && rm -f /tmp/octopus-restore.bak"

log "restarting Octopus Deploy Server container and waiting for its API to respond (up to 60s)"
iap_ssh "$MGMT_HOST" "sudo docker start ${OCTOPUS_CONTAINER} && for i in \$(seq 1 12); do curl -sf http://localhost:8080/api/serverstatus -o /dev/null && echo '[remote] Octopus API is responding' && exit 0; sleep 5; done; echo '[remote] still not responding after 60s' >&2; exit 1" \
  || warn "Octopus API still not responding after 60s — check 'sudo docker logs ${OCTOPUS_CONTAINER}' manually (it may just need more time; SQL Server Express startup and the App Pool warmup after a large restore isn't always fast)"

log "manual verification:"
cat <<EOF
  # Via octopus.platform.lefrancis.org (mgmt tunnel, port 8443):
  #   - Confirm all projects are present
  #   - Confirm both deployment targets (dev-nomad, prod-nomad) show healthy
  #   - Spot-check one project's release history matches the backup's point in time
EOF
log "done."
