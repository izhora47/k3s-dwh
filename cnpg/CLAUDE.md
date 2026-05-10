# CLAUDE.md — CloudNativePG Component

## Operator vs Cluster

There are two separate resources:
1. **Operator** — installed via Helm into `cnpg-system` namespace (`cnpg/cloudnative-pg` chart)
2. **Cluster CR** — `pg-cluster.yaml` applied to the `dwh` namespace (a `postgresql.cnpg.io/v1/Cluster`)

The `values.yaml` in this folder is for the operator Helm chart. The `pg-cluster.yaml` is the database CR.

## Secret Naming Convention

CNPG names secrets as `<cluster-name>-<role>`. For cluster named `polaris-pg`:
- `polaris-pg-superuser` — postgres superuser
- `polaris-pg-app` — application user (`polaris` DB user)

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
