#!/usr/bin/env bash
# PostgreSQL backup via CNPG pg_dump (streams from the primary pod)
# Produces a compressed custom-format dump (.dump) restorable with pg_restore.
#
# Usage:
#   ./backup/pg-backup.sh                         # backup 'polaris' database
#   ./backup/pg-backup.sh superset ./my-dumps     # backup named DB to custom dir
#   ./backup/pg-backup.sh all                     # backup all user databases
#
# Output: backup/dumps/pg-<database>-<YYYYMMDD-HHMMSS>.dump
#
# Requirements: kubectl in PATH, kubeconfig pointing at the cluster.

set -euo pipefail

# Resolve kubectl: prefer ~/bin/kubectl (k3s wrapper), fall back to system kubectl
KUBECTL="$(command -v kubectl 2>/dev/null || echo "$HOME/bin/kubectl")"
if [[ ! -x "$KUBECTL" ]]; then KUBECTL="$HOME/bin/kubectl"; fi

NAMESPACE="dwh"
CLUSTER="polaris-pg"
DATABASE="${1:-polaris}"
OUTPUT_DIR="${2:-$(dirname "$0")/dumps}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

mkdir -p "$OUTPUT_DIR"

# Resolve primary pod name from cluster status
PRIMARY=$("$KUBECTL" get cluster "$CLUSTER" -n "$NAMESPACE" \
  -o jsonpath='{.status.currentPrimary}')

if [[ -z "$PRIMARY" ]]; then
  echo "ERROR: could not resolve primary pod for cluster $CLUSTER" >&2
  exit 1
fi

echo "Primary pod: $PRIMARY"

# CNPG has enableSuperuserAccess=false — no superuser secret is generated.
# Use peer authentication: exec into the 'postgres' container (runs as OS user postgres)
# and connect as the postgres superuser. No password needed.
PG_EXEC="$KUBECTL exec -n $NAMESPACE $PRIMARY -c postgres --"

dump_database() {
  local db="$1"
  local outfile="${OUTPUT_DIR}/pg-${db}-${TIMESTAMP}.dump"

  echo "  → pg_dump $db → $outfile"
  $PG_EXEC pg_dump -U postgres -d "$db" --format=custom --compress=6 \
    > "$outfile"

  local size
  size=$(du -sh "$outfile" | cut -f1)
  echo "    Done: $size"
}

if [[ "$DATABASE" == "all" ]]; then
  # List all user databases (exclude template and postgres system DBs)
  DATABASES=$($PG_EXEC \
    psql -U postgres -Atc \
    "SELECT datname FROM pg_database
     WHERE datistemplate = false AND datname NOT IN ('postgres')
     ORDER BY datname")

  echo "Backing up databases: $(echo $DATABASES | tr '\n' ' ')"
  for db in $DATABASES; do
    dump_database "$db"
  done
else
  dump_database "$DATABASE"
fi

echo ""
echo "Backup complete. Files in: $OUTPUT_DIR"
ls -lh "$OUTPUT_DIR"/pg-*-"${TIMESTAMP}".dump 2>/dev/null || true
