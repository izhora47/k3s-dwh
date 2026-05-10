# Trino on k3s

Trino (formerly PrestoSQL) is the SQL query engine for the lakehouse. It connects to the Apache Polaris REST catalog (Iceberg metadata) and reads/writes data from Apache Ozone (S3-compatible object storage).

## Architecture

```
Trino Coordinator + Worker(s)
  └─ lakehouse catalog ──► Polaris REST API (Iceberg metadata)
  └─ S3 reads/writes ────► Ozone S3 Gateway (data files)
  └─ tpch/tpcds ─────────► Built-in benchmark data
```

## Prerequisites

1. Polaris deployed in `dwh` namespace (`kubectl get pod -n dwh -l app.kubernetes.io/name=polaris`)
2. Ozone deployed with S3 gateway (`kubectl get pod -n dwh -l app.kubernetes.io/component=s3g`)
3. Secret `ozone-s3-creds` in `dwh` namespace (created by `install.sh`)

## Deploy

```bash
# 1. Add repo (only once)
helm repo add trino https://trinodb.github.io/charts
helm repo update trino

# 2. Create ozone-s3-creds secret (if not done by install.sh)
# Note: 'ozone s3 getsecret' requires Kerberos (not enabled in dev mode).
# Ozone non-secure S3G accepts any credentials — use static values:
kubectl create secret generic ozone-s3-creds -n dwh \
  --from-literal=access-key="ozone" \
  --from-literal=secret-key="ozone-secret123" \
  --dry-run=client -o yaml | kubectl apply -f -

# 3. Install Trino
helm upgrade --install trino trino/trino \
  --version 1.42.2 \
  --namespace dwh \
  --values trino/values.yaml \
  --wait --timeout 5m
```

## Access

### Web UI
```bash
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
# Open http://${NODE_IP}:30880 in browser
```

### JDBC / SQL clients
- JDBC URL: `jdbc:trino://<node-ip>:30880/lakehouse`
- User: any string (no auth in this setup)
- Password: empty

### Port-forward for local tools
```bash
kubectl port-forward svc/trino -n dwh 8080:8080 &
# Then connect to jdbc:trino://localhost:8080
```

### CLI
```bash
kubectl exec -n dwh -it \
  $(kubectl get pod -n dwh -l app=trino,component=coordinator -o jsonpath='{.items[0].metadata.name}') \
  -- trino --catalog lakehouse --schema bronze
```

## Queries

### Test Iceberg catalog via Polaris
```sql
-- List namespaces in the lakehouse catalog
SHOW SCHEMAS IN lakehouse;

-- List tables
SHOW TABLES IN lakehouse.bronze;

-- Create an Iceberg table
CREATE TABLE lakehouse.bronze.events (
    event_id   BIGINT,
    event_type VARCHAR,
    ts         TIMESTAMP(6) WITH TIME ZONE,
    payload    VARCHAR
)
WITH (
    format = 'PARQUET',
    partitioning = ARRAY['day(ts)']
);

-- Insert data
INSERT INTO lakehouse.bronze.events VALUES
    (1, 'click', TIMESTAMP '2024-01-15 10:00:00 UTC', '{"page": "/home"}'),
    (2, 'view',  TIMESTAMP '2024-01-15 10:01:00 UTC', '{"page": "/products"}'),
    (3, 'click', TIMESTAMP '2024-01-16 09:00:00 UTC', '{"page": "/cart"}');

-- Query
SELECT event_type, COUNT(*) AS cnt
FROM lakehouse.bronze.events
GROUP BY event_type;

-- Time travel (Iceberg snapshot)
SELECT * FROM lakehouse.bronze.events
FOR VERSION AS OF <snapshot_id>;
```

### Test TPC-H (no S3 needed)
```sql
SELECT l_returnflag, SUM(l_extendedprice) AS revenue
FROM tpch.sf1.lineitem
GROUP BY l_returnflag;
```


## Troubleshooting

**S3 errors (NoSuchKey / Access Denied)**: Verify `ozone-s3-creds` secret exists and has the correct keys:
```bash
kubectl get secret ozone-s3-creds -n dwh -o jsonpath='{.data.access-key}' | base64 -d
```

**Polaris catalog not connecting**: Check Polaris is running and the realm header is correct:
```bash
kubectl logs -n dwh -l app.kubernetes.io/name=polaris --tail=20
```

**Worker OOMKilled**: Increase `worker.jvm.maxHeapSize` and `limits.memory` in `values.yaml`.

**Slow queries on k3s**: With 1 worker, queries are serial. Increase `server.workers` when more CPU/RAM is available.
