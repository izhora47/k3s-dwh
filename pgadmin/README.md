# pgAdmin4 on k3s

pgAdmin4 provides a web UI for managing the PostgreSQL databases in the lakehouse stack. It comes pre-configured to connect to the Polaris CNPG cluster.

## Deploy

```bash
# Add repo (only once)
helm repo add runix https://helm.runix.net
helm repo update runix

# Install pgAdmin4
helm upgrade --install pgadmin runix/pgadmin4 \
  --version 1.62.0 \
  --namespace dwh \
  --values pgadmin/values.yaml \
  --wait --timeout 3m
```

## Access

```bash
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
echo "pgAdmin4: http://${NODE_IP}:30543"
```

Login:
- **Email**: `admin@lakehouse.local`
- **Password**: `admin123`

## Connecting to Polaris PostgreSQL

The `Polaris PostgreSQL (CNPG)` server is pre-registered in the **Lakehouse** group. To connect:

1. Open pgAdmin4 at the URL above
2. Log in with the credentials above
3. Expand **Lakehouse → Polaris PostgreSQL (CNPG)**
4. Enter the PostgreSQL password when prompted

Get the PostgreSQL password:
```bash
kubectl get secret polaris-pg-app -n dwh \
  -o jsonpath='{.data.password}' | base64 -d
```

## What to Explore

Once connected to `polaris-pg-rw.dwh.svc.cluster.local:5432/polaris`:

- **CATALOG_ENTITY_RECORD** — Polaris catalog/namespace/table registry
- **ENTITY_CHANGE_TRACKING** — audit log of all catalog mutations
- **PRINCIPAL** / **PRINCIPAL_ROLE** — Polaris access control
- **POLARIS_ENTITY_BASE** — base entity table

These tables reflect the current state of all Iceberg catalogs managed by Polaris.

## Troubleshooting

**Pod not starting**: Check PVC is provisioned — `kubectl get pvc -n dwh | grep pgadmin`

**Cannot connect to Polaris PG**: Verify the CNPG cluster is healthy:
```bash
kubectl get cluster polaris-pg -n dwh
```

**Password not accepted for PG**: Retrieve the current app secret:
```bash
kubectl get secret polaris-pg-app -n dwh -o jsonpath='{.data.password}' | base64 -d
```
