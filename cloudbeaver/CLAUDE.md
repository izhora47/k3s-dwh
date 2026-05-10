# CLAUDE.md — CloudBeaver Component

## Deployment

CloudBeaver is deployed as a plain Kubernetes Deployment + NodePort Service (no Helm chart).
The official DBeaver Helm repo (`https://dbeaver.io/helm-chart/`) is not reachable from this cluster.
Use `kubectl apply -f cloudbeaver/manifest.yaml`.

## Workspace

The workspace (`/opt/cloudbeaver/workspace`) is persisted in a 2Gi PVC (`cloudbeaver-workspace`
in `dwh` namespace). Admin credentials and connections survive pod restarts.

## Connection endpoints (in-cluster DNS)

| Target | URL |
|---|---|
| ClickHouse HTTP | `http://clickhouse-clickhouse-headless.clickhouse.svc.cluster.local:8123` |
| Trino JDBC | `jdbc:trino://trino.dwh.svc.cluster.local:8080/lakehouse` |
| Polaris REST | `http://polaris.dwh.svc.cluster.local:8181` |
| PostgreSQL | `polaris-pg-rw.dwh.svc.cluster.local:5432` |

## Version

Pinned to `dbeaver/cloudbeaver:25.0.0`. Update the image tag in `manifest.yaml`
when upgrading — check for breaking changes to workspace format between major versions.

## Readiness

CloudBeaver takes ~30s to start (JVM warm-up). The readiness probe hits `/status`
on port 8978. If the pod shows `0/1 Running` for more than 60s, check logs:
```bash
kubectl logs -n dwh -l app=cloudbeaver -f
```
