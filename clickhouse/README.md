# ClickHouse on k3s

Deploys ClickHouse using the **official ClickHouse Inc operator** (`ClickHouse/clickhouse-operator` v0.0.4), not the Altinity operator. Uses the newer `clickhouse.com/v1alpha1` API with `ClickHouseCluster` and `KeeperCluster` CRDs.

## Components

| Component | Description |
|---|---|
| `clickhouse-operator` | Operator managing ClickHouseCluster and KeeperCluster CRs |
| `clickhouse-keeper` | ClickHouse Keeper (ZooKeeper-compatible coordination, 1 replica on k3s) |
| `clickhouse` | ClickHouse server cluster (1 shard × 1 replica on k3s) |

## Quick Deploy

```bash
cd /home/nik/projects/k3s/dwh

# Install operator (from GitHub release — no Helm repo needed)
kubectl create namespace clickhouse --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install clickhouse-operator \
  https://github.com/ClickHouse/clickhouse-operator/releases/download/v0.0.4/clickhouse-operator-helm-0.0.4.tgz \
  --namespace clickhouse \
  --values clickhouse/values.yaml \
  --wait --timeout 3m

# Deploy KeeperCluster first (required before ClickHouseCluster)
kubectl apply -f clickhouse/keeper-cluster.yaml
kubectl wait keepercluster clickhouse-keeper -n clickhouse \
  --for=condition=Ready --timeout=5m

# Deploy ClickHouseCluster
kubectl apply -f clickhouse/clickhouse-cluster.yaml
kubectl wait clickhousecluster clickhouse -n clickhouse \
  --for=condition=Ready --timeout=5m
```

## Access

ClickHouse exposes two ports:
- **HTTP**: `9000` (native protocol)
- **HTTP interface**: `8123`

```bash
# Port-forward for local access
kubectl port-forward svc/clickhouse -n clickhouse 8123:8123 9000:9000 &

# Test connection (HTTP interface)
curl http://localhost:8123/ping

# Run a query
curl -s "http://localhost:8123/?query=SELECT+version()"

# Connect via clickhouse-client
kubectl exec -n clickhouse \
  $(kubectl get pod -n clickhouse -l clickhouse.com/cluster=clickhouse -o jsonpath='{.items[0].metadata.name}') \
  -- clickhouse-client --query "SELECT version()"
```

### NodePort Access (if configured)
If you expose via NodePort, connect from outside the cluster:
```bash
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
curl http://${NODE_IP}:30123/ping
```

## Lakehouse Integration

ClickHouse can query Iceberg tables directly via Polaris REST catalog:

```sql
-- Query an Iceberg table from Polaris catalog
SELECT * FROM icebergREST(
    catalog_uri = 'http://polaris.dwh.svc.cluster.local:8181/api/catalog',
    catalog = 'lakehouse',
    schema = 'bronze',
    table = 'test_table',
    auth_type = 'oauth2',
    token_endpoint = 'http://polaris.dwh.svc.cluster.local:8181/api/catalog/v1/oauth/tokens',
    client_id = 'root',
    client_secret = 's3cr3t'
);
```

## Production Scaling

To scale from single-node dev to production:

1. **Scale KeeperCluster to 3 replicas** (minimum for quorum):
   ```yaml
   spec:
     replicas: 3
   ```

2. **Scale ClickHouseCluster** (2 shards × 2 replicas = 4 pods + KeeperCluster 3 pods):
   ```yaml
   spec:
     shards: 2
     replicas: 2
   ```

3. **Enable cert-manager and webhooks** for validation:
   ```yaml
   certManager:
     enable: true
     install: true   # installs cert-manager subchart
   webhook:
     enable: true
   ```

4. **Increase storage** in both CRs (`dataVolumeClaimSpec.resources.requests.storage: 500Gi`).

## Monitoring

```bash
# Operator logs
kubectl logs -n clickhouse -l control-plane=controller-manager -f

# KeeperCluster status
kubectl get keepercluster clickhouse-keeper -n clickhouse -o yaml

# ClickHouseCluster status
kubectl get clickhousecluster clickhouse -n clickhouse -o yaml

# All ClickHouse pods
kubectl get pods -n clickhouse
```

## Troubleshooting

**Pods stuck in Pending**: Check storage class exists — `kubectl get sc local-path`

**Keeper not Ready**: Check logs with `kubectl logs -n clickhouse -l app=clickhouse-keeper -f`

**cert-manager errors**: The operator is deployed without webhooks (`webhook.enable: false`) because quay.io/jetstack is unreachable on this cluster. For production with cert-manager, set `certManager.enable: true` and `webhook.enable: true`.

**ClickHouseCluster not starting**: KeeperCluster must be Ready before ClickHouseCluster becomes healthy.
