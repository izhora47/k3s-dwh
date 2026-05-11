#!/usr/bin/env bash
# PostgreSQL restore via CNPG pg_restore (streams into the primary pod)
# Restores a custom-format dump created by pg-backup.sh.
#
# Usage:
#   ./backup/pg-restore.sh backup/dumps/pg-polaris-20260511-120000.dump
#   ./backup/pg-restore.sh backup/dumps/pg-polaris-20260511-120000.dump superset
#
# Arguments:
#   $1  — path to .dump file (required)
#   $2  — target database name (optional; defaults to the name embedded in the dump)
#
# WARNING: this drops and recreates the target database if it already exists.
# Do NOT restore over a live production database without stopping writers first.

set -euo pipefail

KUBECTL="$(command -v kubectl 2>/dev/null || echo "$HOME/bin/kubectl")"
if [[ ! -x "$KUBECTL" ]]; then KUBECTL="$HOME/bin/kubectl"; fi

NAMESPACE="dwh"
CLUSTER="polaris-pg"
DUMP_FILE="${1:?Usage: $0 <dump-file> [target-database]}"

if [[ ! -f "$DUMP_FILE" ]]; then
  echo "ERROR: dump file not found: $DUMP_FILE" >&2
  exit 1
fi

# Derive target DB from filename if not given: pg-<db>-YYYYMMDD-HHMMSS.dump
BASENAME=$(basename "$DUMP_FILE" .dump)
DEFAULT_DB=$(echo "$BASENAME" | sed 's/^pg-//' | sed 's/-[0-9]\{8\}-[0-9]\{6\}$//')
TARGET_DB="${2:-$DEFAULT_DB}"

PRIMARY=$("$KUBECTL" get cluster "$CLUSTER" -n "$NAMESPACE" \
  -o jsonpath='{.status.currentPrimary}')

# Use peer auth via the 'postgres' container (no superuser secret needed)
PG_EXEC="$KUBECTL exec -n $NAMESPACE $PRIMARY -c postgres --"
PG_EXEC_I="$KUBECTL exec -i -n $NAMESPACE $PRIMARY -c postgres --"

echo "Dump file   : $DUMP_FILE ($(du -sh "$DUMP_FILE" | cut -f1))"
echo "Target DB   : $TARGET_DB"
echo "Primary pod : $PRIMARY"
echo ""

# Confirm before overwriting
read -r -p "This will DROP and recreate '$TARGET_DB'. Continue? [y/N] " confirm
[[ "${confirm,,}" == "y" ]] || { echo "Aborted."; exit 0; }

# Drop existing connections and recreate the database
$PG_EXEC psql -U postgres -d postgres -c \
  "SELECT pg_terminate_backend(pid)
   FROM pg_stat_activity
   WHERE datname = '${TARGET_DB}' AND pid <> pg_backend_pid();" \
  >/dev/null 2>&1 || true

$PG_EXEC psql -U postgres -d postgres -c \
  "DROP DATABASE IF EXISTS \"${TARGET_DB}\";" 2>&1

$PG_EXEC psql -U postgres -d postgres -c \
  "CREATE DATABASE \"${TARGET_DB}\";" 2>&1

echo "Restoring..."
# Stream dump into pod, pg_restore reads from stdin
$PG_EXEC_I pg_restore -U postgres -d "$TARGET_DB" \
  --no-owner --no-acl --exit-on-error \
  < "$DUMP_FILE"

echo ""
echo "Restore complete: $DUMP_FILE → database '$TARGET_DB'"

# Quick row count sanity check
echo "Table row counts:"
$PG_EXEC psql -U postgres -d "$TARGET_DB" -c \
  "SELECT schemaname, relname, n_live_tup AS rows
   FROM pg_stat_user_tables
   ORDER BY schemaname, relname;" 2>/dev/null || true
