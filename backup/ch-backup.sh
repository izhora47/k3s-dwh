#!/usr/bin/env bash
# ClickHouse backup using native SQL BACKUP DATABASE ... TO S3
# Backs up to RustFS (S3-compatible) at s3://lakehouse/ch-backups/<db>/<timestamp>/
#
# Usage:
#   ./backup/ch-backup.sh                  # backup 'default' database
#   ./backup/ch-backup.sh mydb             # backup named database
#   ./backup/ch-backup.sh all              # backup all user databases
#
# Requirements: kubectl in PATH, ClickHouse >= 22.4 (we run 26.4).
# Backup destination: RustFS bucket 'lakehouse', prefix 'ch-backups/'.
# Credentials are read from the ozone-s3-creds secret (same secret Trino/Polaris use).

set -euo pipefail

KUBECTL="$(command -v kubectl 2>/dev/null || echo "$HOME/bin/kubectl")"
if [[ ! -x "$KUBECTL" ]]; then KUBECTL="$HOME/bin/kubectl"; fi

NAMESPACE="clickhouse"
CH_POD="clickhouse-clickhouse-0-0-0"
CH_NS="dwh"                          # the ozone-s3-creds secret is in dwh namespace
DATABASE="${1:-default}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

S3_ENDPOINT="http://rustfs-svc.dwh.svc.cluster.local:9000"
S3_BUCKET="lakehouse"
S3_PREFIX="ch-backups"

# Read S3 credentials from the ozone-s3-creds secret
ACCESS_KEY=$("$KUBECTL" get secret ozone-s3-creds -n "$CH_NS" \
  -o jsonpath='{.data.access-key}' | base64 -d)
SECRET_KEY=$("$KUBECTL" get secret ozone-s3-creds -n "$CH_NS" \
  -o jsonpath='{.data.secret-key}' | base64 -d)

ch_query() {
  "$KUBECTL" exec -n "$NAMESPACE" "$CH_POD" -- \
    clickhouse-client --multiquery --query "$1"
}

backup_database() {
  local db="$1"
  local s3_path="s3://${S3_BUCKET}/${S3_PREFIX}/${db}/${TIMESTAMP}/"

  # ClickHouse BACKUP TO S3 syntax:
  # BACKUP DATABASE <db> TO S3('<endpoint>/<path>', '<access>', '<secret>')
  local s3_url="${S3_ENDPOINT}/${S3_BUCKET}/${S3_PREFIX}/${db}/${TIMESTAMP}/"

  echo "  → BACKUP DATABASE $db"
  echo "    destination: $s3_url"

  ch_query "
    BACKUP DATABASE \`${db}\`
    TO S3('${s3_url}', '${ACCESS_KEY}', '${SECRET_KEY}')
    SETTINGS allow_s3_native_copy = 0"

  echo "    Done."
}

if [[ "$DATABASE" == "all" ]]; then
  # List user databases (exclude system ones)
  DATABASES=$(ch_query \
    "SELECT name FROM system.databases
     WHERE name NOT IN ('system','information_schema','INFORMATION_SCHEMA')
     FORMAT TabSeparated")

  if [[ -z "$DATABASES" ]]; then
    echo "No user databases found."
    exit 0
  fi

  echo "Backing up databases: $(echo $DATABASES | tr '\n' ' ')"
  for db in $DATABASES; do
    backup_database "$db"
  done
else
  backup_database "$DATABASE"
fi

echo ""
echo "Backup complete. Listing backups in RustFS:"
"$KUBECTL" run ch-backup-ls --rm -i --restart=Never -n dwh \
  --image=amazon/aws-cli:latest \
  --env="AWS_ACCESS_KEY_ID=${ACCESS_KEY}" \
  --env="AWS_SECRET_ACCESS_KEY=${SECRET_KEY}" \
  --env="AWS_DEFAULT_REGION=us-east-1" \
  -- s3 ls "s3://${S3_BUCKET}/${S3_PREFIX}/" --endpoint-url "${S3_ENDPOINT}" 2>/dev/null || true
