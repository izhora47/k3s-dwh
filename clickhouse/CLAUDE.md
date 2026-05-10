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
