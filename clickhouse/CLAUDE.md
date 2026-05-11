# CLAUDE.md — ClickHouse Component

## Operator Choice

**Official ClickHouse Inc operator** from `github.com/ClickHouse/clickhouse-operator` v0.0.4.
NOT the Altinity operator (`Altinity/clickhouse-operator`).

| | ClickHouse Inc (this) | Altinity |
|---|---|---|
| API group | `clickhouse.com/v1alpha1` | `clickhouse.altinity.com/v1` |
| Server CR | `ClickHouseCluster` | `ClickHouseInstallation` |
| Keeper CR | `KeeperCluster` | `ClickHouseKeeperInstallation` |
| Helm chart | GitHub release tgz (no repo) | `altinity-operator` repo |

## Install Command

No `helm repo add` needed — install directly from release tgz:

```bash
helm upgrade --install clickhouse-operator \
  https://github.com/ClickHouse/clickhouse-operator/releases/download/v0.0.4/clickhouse-operator-helm-0.0.4.tgz \
  --namespace clickhouse --values clickhouse/values.yaml --wait --timeout 3m
```

## Webhooks Disabled

`webhook.enable: false` and `certManager.enable: false` because `quay.io` (jetstack cert-manager
source) is unreachable. Without webhooks, CRD spec errors surface at runtime (not at `kubectl apply`).

## CRD Field Gotchas (v0.0.4)

**ClickHouseCluster:**
- `spec.version` — does NOT exist. Use `spec.upgradeChannel: "25.8"` (or `"stable"`, `"lts"`)
- `spec.keeperClusterRef` — only `name` field; no `namespace` field. KeeperCluster must be in the same namespace
- `spec.settings.extraConfig` — server-level settings (go into `config.yaml`)
- `spec.settings.extraUsersConfig` — user-level settings (go into `users.yaml`)

User-level settings (`max_memory_usage`, `async_insert`, `async_insert_threads`,
`network_compression_method`) MUST go in `extraUsersConfig.profiles.default`, NOT in
`extraConfig`. Putting user-level settings in `extraConfig` causes ClickHouse to refuse to start.

**KeeperCluster:**
- `spec.version` — does NOT exist. Use `spec.upgradeChannel: "25.8"`
- `spec.settings.logger` — nested object (`level`, `size`, etc.), not flat key `logger_level`
- `spec.settings.max_snapshots` — does NOT exist in v0.0.4

## CR Ordering

**KeeperCluster MUST be Ready before applying ClickHouseCluster.**
ClickHouse pods crashloop without a working Keeper.

```bash
kubectl apply -f clickhouse/keeper-cluster.yaml
kubectl wait keepercluster clickhouse-keeper -n clickhouse --for=condition=Ready --timeout=5m
kubectl apply -f clickhouse/clickhouse-cluster.yaml
```

## NodePort Service

The operator creates a ClusterIP service named `clickhouse`. A separate NodePort manifest
`clickhouse-service.yaml` provides external access on ports 30123 (HTTP) and 30900 (native).

The NodePort selector uses `clickhouse.com/role: clickhouse-server` — this is the actual label
set by the operator on server pods. Do NOT use `app: clickhouse` or other guessed labels.

To find the correct labels: `kubectl get pod -n clickhouse --show-labels`

## Service Discovery

- In-cluster: `clickhouse.clickhouse.svc.cluster.local:8123` (HTTP), `:9000` (native)
- External: `<node-ip>:30123` (HTTP), `<node-ip>:30900` (native)
- No auth by default (development mode)

---

## Scaling and Enterprise Readiness

### Current configuration (dev/single-node)

```
shards: 1 × replicas: 1 = 1 server pod (no HA, no horizontal scale)
KeeperCluster: 1 replica (no quorum — single point of failure)
Storage: 20 Gi local-path PVC
```

### For 1 GB/day ingestion + 2 TB total store

**ClickHouse handles this easily on a single server:**
- 1 GB/day = ~730 GB/year raw; with LZ4 compression (5–10×) = **73–146 GB/year on disk**
- 2 TB raw ≈ 200–400 GB compressed; a single modern server with a 1 TB SSD is sufficient
- `async_insert` is already enabled — ideal for high-frequency small-batch ingestion
- No sharding needed at this data volume

**What you DO need to grow:**
1. Larger PVC (20 Gi → 500 Gi). Change `dataVolumeClaimSpec.resources.requests.storage` and resize the PVC
2. More RAM for larger mark caches and query memory (`limits.memory: 4Gi` → `16Gi+`)
3. More CPU for concurrent queries (`limits.cpu: "2"` → `"8"+`)

### Scaling to HA (production)

Change `clickhouse-cluster.yaml`:
```yaml
spec:
  shards: 1       # increase to 2+ for horizontal data partitioning
  replicas: 2     # 2 = HA; each replica holds a full copy of each shard
  keeperClusterRef:
    name: clickhouse-keeper  # must have 3 replicas for quorum
```

Change `keeper-cluster.yaml`:
```yaml
spec:
  replicas: 3     # always odd for quorum (1, 3, 5)
```

**Sharding vs replication:**
- `replicas: 2` — same data on both nodes, HA failover, reads can fan out
- `shards: 2` — data partitioned across nodes, 2× write throughput, needs `Distributed` table

For 2 TB / 1 GB day, `shards: 1, replicas: 2` (HA without sharding) is the right start.

### Is ClickHouse enterprise-ready for this use case?

**Yes**, with the following conditions:

| Requirement | Current state | Production fix |
|---|---|---|
| Data volume (2 TB) | ✓ Handles 10+ TB on single node | Expand PVC |
| Ingestion (1 GB/day) | ✓ async_insert configured | Keep; tune `async_insert_max_data_size` |
| HA / failover | ✗ Single replica | Set replicas: 2, Keeper: 3 |
| Authentication | ✗ No password (`default` user, open) | Add users + passwords |
| TLS | ✗ No TLS on ports 8123/9000 | Configure TLS in extraConfig |
| Backups | ✗ Not configured | See backup section below |
| Monitoring | ✗ ServiceMonitor disabled | Enable + configure Prometheus |

### Adding authentication (production must-have)

In `clickhouse-cluster.yaml`, add to `settings.extraUsersConfig`:
```yaml
users:
  default:
    password_sha256_hex: "<sha256 of password>"  # or remove default user
  admin:
    password_sha256_hex: "<sha256>"
    profile: default
    quota: default
    networks:
      ip: "::/0"
    databases: {}
```
Generate hash: `echo -n 'MyPassword' | sha256sum | awk '{print $1}'`

---

## Backup and Restore

ClickHouse 22.4+ supports native `BACKUP DATABASE ... TO S3(...)` SQL commands.
Scripts in `backup/` back up to RustFS (same S3 bucket used by the lakehouse).

### Backup

```bash
# Backup 'default' database to RustFS s3://lakehouse/ch-backups/
./backup/ch-backup.sh

# Backup specific database
./backup/ch-backup.sh mydb

# Backup all user databases
./backup/ch-backup.sh all
```

Destination: `s3://lakehouse/ch-backups/<database>/<YYYYMMDD-HHMMSS>/`

### Restore

```bash
# List available backups
./backup/ch-restore.sh

# Restore default database from a specific timestamp
./backup/ch-restore.sh default 20260511-120000

# Restore into a different database name (safe: keeps original intact)
./backup/ch-restore.sh default 20260511-120000 default_restored
```

### Manual backup commands (inside clickhouse-client)

```sql
-- Backup single table
BACKUP TABLE default.orders
TO S3('http://rustfs-svc.dwh.svc.cluster.local:9000/lakehouse/ch-backups/orders/20260511/',
      'lakehouseadmin', 'Lk@h0use-S3-2026!')

-- Backup full database
BACKUP DATABASE default
TO S3('http://rustfs-svc.dwh.svc.cluster.local:9000/lakehouse/ch-backups/default/20260511/',
      'lakehouseadmin', 'Lk@h0use-S3-2026!')

-- Restore (drops and recreates)
RESTORE DATABASE default AS default_restored
FROM S3('http://rustfs-svc.dwh.svc.cluster.local:9000/lakehouse/ch-backups/default/20260511/',
        'lakehouseadmin', 'Lk@h0use-S3-2026!')
```

### Scheduling backups

```bash
# Daily at 03:00
# crontab -e
0 3 * * * cd /home/nik/projects/k3s/dwh && ./backup/ch-backup.sh all >> /tmp/ch-backup.log 2>&1
```
