# CLAUDE.md — CloudNativePG Component

## Operator vs Cluster

There are two separate resources:
1. **Operator** — installed via Helm into `cnpg-system` namespace (`cnpg/cloudnative-pg` chart)
2. **Cluster CR** — `pg-cluster.yaml` applied to the `dwh` namespace (a `postgresql.cnpg.io/v1/Cluster`)

The `values.yaml` in this folder is for the operator Helm chart. The `pg-cluster.yaml` is the database CR.

## Secret Naming Convention

CNPG names secrets as `<cluster-name>-<role>`. For cluster named `polaris-pg`:
- `polaris-pg-app` — application user (`polaris` DB user)
- `polaris-pg-ca` / `polaris-pg-server` / `polaris-pg-replication` — TLS secrets
- `polaris-pg-superuser` — **does NOT exist** — `enableSuperuserAccess: false`

`enableSuperuserAccess: false` means CNPG does not generate or expose a superuser
secret. To run superuser operations, exec into the pod as the `postgres` container
(which runs as the OS user `postgres` — peer auth applies):
```bash
kubectl exec -n dwh polaris-pg-1 -c postgres -- psql -U postgres -c "\du"
```

The `polaris-persistence` secret in `install.sh` is a **separate** secret created manually by extracting credentials from `polaris-pg-app`. This intermediate secret is needed because Polaris helm chart expects specific key names (`username`, `password`, `jdbcUrl`).

## Service Names

CNPG creates these services automatically:
- `polaris-pg-rw` — always routes to primary (read-write)
- `polaris-pg-r` — routes to any instance (read-only replica safe)
- `polaris-pg-ro` — routes to replicas only

For Polaris, always use `polaris-pg-rw` in the JDBC URL since Polaris needs write access.

## Phase vs Condition

To wait for CNPG cluster readiness, use `jsonpath` on `.status.phase`:
```bash
kubectl wait cluster polaris-pg -n dwh \
  --for=jsonpath='{.status.phase}'='Cluster in healthy state' --timeout=3m
```

The exact phase string is `"Cluster in healthy state"` — this is CNPG-specific, not a standard Kubernetes condition.

## Storage

The cluster uses `local-path` storage class (k3s default). The PVC is named `<cluster>-<instance>` e.g. `polaris-pg-1`. On a single-instance cluster, there is only `polaris-pg-1`.

## Polaris Bootstrap User

The `initdb` config in `pg-cluster.yaml` creates:
- Database: `polaris`
- Owner: `polaris` (this becomes the app user)

Polaris's persistence layer connects as this user. All Iceberg catalog tables live in the `polaris` database under the `polaris` schema.

---

## PgBouncer (Connection Pooler)

PgBouncer is managed by the CNPG operator via the `Pooler` CR (`postgresql.cnpg.io/v1/Pooler`).
This is the correct approach — NOT a standalone PgBouncer Deployment.

**Why CNPG-managed vs standalone:**
- Operator automatically syncs auth (`pg_shadow` lookup) from cluster secrets
- Automatically follows primary on failover (no manual config update)
- Lifecycle is tied to the cluster — restart/reconfigure together
- Generates and rotates the `pooler-auth` secret automatically

**Files:** `cnpg/pooler.yaml` — defines two poolers:
- `polaris-pg-pooler-rw` — routes to primary, port 5432, transaction mode
- `polaris-pg-pooler-ro` — routes to replicas (falls back to primary if none), port 5432

**Deploy:**
```bash
kubectl apply -f cnpg/pooler.yaml
kubectl rollout status deployment/polaris-pg-pooler-rw -n dwh
```

**Connection string for external services (Superset, etc.):**
```
postgresql://<user>:<pass>@polaris-pg-pooler-rw.dwh.svc.cluster.local:5432/<database>
```

### Pool modes

`transaction` mode (configured here): server connection held only during a query.
Best for stateless apps. Limitations:
- No `SET` session variables persisting across queries
- No advisory locks (`pg_advisory_lock`)
- No `LISTEN`/`NOTIFY`
- No temporary tables that span multiple statements

Use `session` mode only if the app requires the above features (rare for analytics tools).

### Adding a database for a new service (e.g. Superset)

The pooler routes connections to any database; clients specify the database in the DSN.
To create a dedicated database for Superset:

```bash
PRIMARY=$(kubectl get cluster polaris-pg -n dwh -o jsonpath='{.status.currentPrimary}')
SUPERUSER=$(kubectl get secret polaris-pg-superuser -n dwh \
  -o jsonpath='{.data.username}' | base64 -d)

# Create database and user
kubectl exec -n dwh "$PRIMARY" -- \
  psql -U "$SUPERUSER" -c "
    CREATE USER superset WITH PASSWORD 'Sup3rset-2026!';
    CREATE DATABASE superset OWNER superset;
    GRANT ALL PRIVILEGES ON DATABASE superset TO superset;"
```

Superset DSN (via pooler):
```
postgresql://superset:Sup3rset-2026!@polaris-pg-pooler-rw.dwh.svc.cluster.local:5432/superset
```

### Pooler parameters

| Parameter | Value | Meaning |
|---|---|---|
| `max_client_conn` | 200 | max inbound client connections |
| `default_pool_size` | 25 | server connections per (db, user) pair |
| `reserve_pool_size` | 5 | extra burst connections |
| `max_db_connections` | 50 | total server connections per database |
| `server_idle_timeout` | 600 | close idle server connection after 10 min |

With `max_connections=100` in PostgreSQL and `default_pool_size=25`, the pooler
can serve up to `25 × (number of unique db+user combos)` server connections.
Keep the sum below `max_connections - 5` (reserve for superuser access).

---

## Backup and Restore

Scripts in `backup/`. Uses `pg_dump` streamed via `kubectl exec` — no extra tooling needed.

### Backup — implementation details

Scripts use `kubectl exec -c postgres` (peer auth as OS user `postgres`).
No superuser password needed. Works even with `enableSuperuserAccess: false`.

### Backup

```bash
# Backup 'polaris' database (default)
./backup/pg-backup.sh

# Backup specific database
./backup/pg-backup.sh superset

# Backup all user databases
./backup/pg-backup.sh all

# Backup to specific directory
./backup/pg-backup.sh polaris /mnt/backups/postgres
```

Output: `backup/dumps/pg-<db>-<YYYYMMDD-HHMMSS>.dump` (compressed custom format)

### Restore

```bash
# List dumps
ls backup/dumps/

# Restore to same database name (interactive confirmation)
./backup/pg-restore.sh backup/dumps/pg-polaris-20260511-120000.dump

# Restore to a different database (for testing without overwriting live)
./backup/pg-restore.sh backup/dumps/pg-polaris-20260511-120000.dump polaris_restored
```

### Scheduling backups (cron)

```bash
# Add to crontab: daily backup at 02:00
# crontab -e
0 2 * * * cd /home/nik/projects/k3s/dwh && ./backup/pg-backup.sh all >> /tmp/pg-backup.log 2>&1
```

### CNPG Continuous Archiving (WAL-G, enterprise approach)

For point-in-time recovery (PITR), enable WAL archiving in `pg-cluster.yaml`:
```yaml
spec:
  backup:
    barmanObjectStore:
      destinationPath: "s3://lakehouse/pg-wal-archive"
      endpointURL: "http://rustfs-svc.dwh.svc.cluster.local:9000"
      s3Credentials:
        accessKeyId:
          name: ozone-s3-creds
          key: access-key
        secretAccessKey:
          name: ozone-s3-creds
          key: secret-key
    retentionPolicy: "7d"
```
Then create on-demand backups with a `Backup` CR. WAL archiving enables restore to any
point in time, not just the last full dump.
