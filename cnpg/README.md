# CloudNativePG (CNPG) on k3s

CloudNativePG provides the PostgreSQL cluster used by Apache Polaris as its metadata store. The operator manages the full lifecycle: provisioning, backups, failover, and connection secrets.

## Components

| Resource | Description |
|---|---|
| `cnpg-system` namespace | CloudNativePG operator |
| `polaris-pg` Cluster (in `dwh`) | 1-instance PostgreSQL cluster for Polaris metadata |

## Deploy

```bash
# Add repo (only once)
helm repo add cnpg https://cloudnative-pg.github.io/charts
helm repo update cnpg

# 1. Install the CNPG operator
helm upgrade --install cnpg cnpg/cloudnative-pg \
  --namespace cnpg-system \
  --create-namespace \
  --wait --timeout 5m

# 2. Deploy the PostgreSQL cluster
kubectl apply -f cnpg/pg-cluster.yaml

# 3. Wait for cluster to be healthy
kubectl wait cluster polaris-pg -n dwh \
  --for=jsonpath='{.status.phase}'='Cluster in healthy state' \
  --timeout=3m
```

## Secrets Created Automatically

CNPG creates these secrets in the `dwh` namespace:

| Secret | Keys | Used By |
|---|---|---|
| `polaris-pg-superuser` | username, password, uri | DBA access |
| `polaris-pg-app` | username, password, host, port, dbname, uri | Polaris |

```bash
# Get app user password
kubectl get secret polaris-pg-app -n dwh \
  -o jsonpath='{.data.password}' | base64 -d

# Get full connection URI
kubectl get secret polaris-pg-app -n dwh \
  -o jsonpath='{.data.uri}' | base64 -d
```

## Connection Details

| Parameter | Value |
|---|---|
| Host (read-write) | `polaris-pg-rw.dwh.svc.cluster.local` |
| Host (read-only) | `polaris-pg-r.dwh.svc.cluster.local` |
| Port | `5432` |
| Database | `polaris` |
| App user | `polaris` (from secret) |

## Status and Monitoring

```bash
# Cluster health
kubectl get cluster polaris-pg -n dwh

# Operator logs
kubectl logs -n cnpg-system -l app.kubernetes.io/name=cloudnative-pg -f

# PostgreSQL pod
kubectl get pod -n dwh -l cnpg.io/cluster=polaris-pg

# Connect via psql
kubectl exec -n dwh \
  $(kubectl get pod -n dwh -l cnpg.io/cluster=polaris-pg,role=primary -o jsonpath='{.items[0].metadata.name}') \
  -- psql -U polaris -d polaris -c "\dt"
```

## Troubleshooting

**Cluster stuck in "Setting up primary"**: Usually a storage issue. Check PVC: `kubectl get pvc -n dwh`

**Polaris can't connect**: Verify the `polaris-persistence` secret has the correct JDBC URL. Recreate it:
```bash
kubectl delete secret polaris-persistence -n dwh
# Then rerun the install.sh step that creates it
```

**"Role polaris does not exist"**: The bootstrap initdb creates the role on first start. If the PVC has old data without this role, delete the PVC and Pod to re-initialize.
