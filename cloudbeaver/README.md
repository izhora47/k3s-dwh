# CloudBeaver

Web-based SQL IDE that provides browser access to ClickHouse, Trino (lakehouse), and PostgreSQL.

## Access

```
http://<node-ip>:30978
```

On first launch, complete the setup wizard:
1. Set admin credentials (save them — they persist in the PVC workspace)
2. Skip the sample connections

## Adding Connections

### ClickHouse (OLAP)

Driver: **ClickHouse** — use **URL** mode with explicit `http://` to avoid protocol auto-detect issues:

| Field | Value |
|---|---|
| URL | `jdbc:clickhouse:http://clickhouse-clickhouse-headless.clickhouse.svc.cluster.local:8123/default` |
| Username | `default` |
| Password | *(empty)* |

If URL mode isn't available, use Host/Port with port **9000** (native TCP):

| Field | Value |
|---|---|
| Host | `clickhouse-clickhouse-headless.clickhouse.svc.cluster.local` |
| Port | `9000` |
| Database | `default` |
| Username | `default` |
| Password | *(empty)* |

**Test queries:**

```sql
SELECT version();
SHOW DATABASES;
CREATE TABLE IF NOT EXISTS default.test (id UInt32, val String) ENGINE = MergeTree ORDER BY id;
INSERT INTO default.test VALUES (1, 'hello'), (2, 'world');
SELECT * FROM default.test;
DROP TABLE default.test;
```

### Trino — Lakehouse (Iceberg via Polaris)

Driver: **Trino** (or Presto — use JDBC URL manually)

| Field | Value |
|---|---|
| JDBC URL | `jdbc:trino://trino.dwh.svc.cluster.local:8080/lakehouse` |
| Username | `trino` |
| Password | *(empty)* |

To browse Iceberg tables: navigate to `lakehouse` catalog → `bronze` schema.

**Test queries:**

```sql
-- TPC-H (built-in, no S3 needed)
SELECT COUNT(*) FROM tpch.sf1.orders;

-- Iceberg lakehouse
SHOW SCHEMAS IN lakehouse;
SHOW TABLES IN lakehouse.bronze;
SELECT * FROM lakehouse.bronze.orders LIMIT 10;
```

### PostgreSQL (Polaris metadata)

Driver: **PostgreSQL**

| Field | Value |
|---|---|
| Host | `polaris-pg-rw.dwh.svc.cluster.local` |
| Port | `5432` |
| Database | `polaris` |
| Username | From secret `polaris-pg-app` in `dwh` |

## Install

```bash
kubectl apply -f cloudbeaver/manifest.yaml
kubectl rollout status deployment/cloudbeaver -n dwh
```

## Uninstall

```bash
kubectl delete -f cloudbeaver/manifest.yaml
# PVC is not deleted automatically — remove it if needed:
kubectl delete pvc cloudbeaver-workspace -n dwh
```
