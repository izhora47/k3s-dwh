#!/usr/bin/env bash
# ClickHouse restore using native SQL RESTORE DATABASE ... FROM S3
# Restores from a backup created by ch-backup.sh in RustFS.
#
# Usage:
#   ./backup/ch-restore.sh                          # list available backups
#   ./backup/ch-restore.sh default 20260511-120000  # restore default DB from timestamp
#   ./backup/ch-restore.sh default 20260511-120000 default_restored  # restore into new name
#
# Arguments:
#   $1  — source database name (as it was backed up)
#   $2  — timestamp (YYYYMMDD-HHMMSS) from the backup directory listing
#   $3  — target database name (optional; defaults to $1, DROPS and recreates it)

set -euo pipefail

KUBECTL="$(command -v kubectl 2>/dev/null || echo "$HOME/bin/kubectl")"
if [[ ! -x "$KUBECTL" ]]; then KUBECTL="$HOME/bin/kubectl"; fi

NAMESPACE="clickhouse"
CH_POD="clickhouse-clickhouse-0-0-0"
CH_NS="dwh"

S3_ENDPOINT="http://rustfs-svc.dwh.svc.cluster.local:9000"
S3_BUCKET="lakehouse"
S3_PREFIX="ch-backups"

ACCESS_KEY=$("$KUBECTL" get secret ozone-s3-creds -n "$CH_NS" \
  -o jsonpath='{.data.access-key}' | base64 -d)
SECRET_KEY=$("$KUBECTL" get secret ozone-s3-creds -n "$CH_NS" \
  -o jsonpath='{.data.secret-key}' | base64 -d)

ch_query() {
  "$KUBECTL" exec -n "$NAMESPACE" "$CH_POD" -- \
    clickhouse-client --multiquery --query "$1"
}

# No args = list available backups
if [[ $# -eq 0 ]]; then
  echo "Available backups in s3://${S3_BUCKET}/${S3_PREFIX}/:"
  # Query ClickHouse's system.backups table — name field contains the S3 URL
  # Parse: S3('...ch-backups/<database>/<timestamp>/', ...)
  "$KUBECTL" exec -n "$NAMESPACE" "$CH_POD" -- \
    clickhouse-client --query "
      SELECT
        extract(name, 'ch-backups/([^/]+)/') AS database,
        extract(name, 'ch-backups/[^/]+/([0-9]{8}-[0-9]{6})') AS timestamp,
        status,
        formatReadableSize(total_size) AS size,
        formatDateTime(start_time, '%Y-%m-%d %H:%M:%S') AS started
      FROM system.backups
      WHERE status = 'BACKUP_CREATED'
      ORDER BY start_time DESC
      FORMAT PrettyCompact"
  echo ""
  echo "Usage: $0 <database> <timestamp> [target-database]"
  exit 0
fi

SOURCE_DB="${1:?Missing source database name}"
TIMESTAMP="${2:?Missing timestamp (run $0 with no args to list)}"
TARGET_DB="${3:-$SOURCE_DB}"

S3_URL="${S3_ENDPOINT}/${S3_BUCKET}/${S3_PREFIX}/${SOURCE_DB}/${TIMESTAMP}/"

echo "Source backup : s3://${S3_BUCKET}/${S3_PREFIX}/${SOURCE_DB}/${TIMESTAMP}/"
echo "Target DB     : $TARGET_DB"
echo ""

read -r -p "Restore '$SOURCE_DB' from $TIMESTAMP into '$TARGET_DB'? (will DROP if exists) [y/N] " confirm
[[ "${confirm,,}" == "y" ]] || { echo "Aborted."; exit 0; }

# Drop target database if it exists, to allow clean restore
echo "Dropping existing '$TARGET_DB' (if any)..."
ch_query "DROP DATABASE IF EXISTS \`${TARGET_DB}\`" 2>/dev/null || true

echo "Restoring..."
ch_query "
  RESTORE DATABASE \`${SOURCE_DB}\`
  AS \`${TARGET_DB}\`
  FROM S3('${S3_URL}', '${ACCESS_KEY}', '${SECRET_KEY}')
  SETTINGS allow_s3_native_copy = 0"

echo ""
echo "Restore complete. Tables in '$TARGET_DB':"
ch_query "
  SELECT table, engine, formatReadableSize(total_bytes) AS size, total_rows AS rows
  FROM system.tables
  WHERE database = '${TARGET_DB}'
  FORMAT PrettyCompact"
