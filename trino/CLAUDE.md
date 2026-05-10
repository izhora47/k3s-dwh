# CLAUDE.md — Trino Component

## Chart

`trino/trino` version `1.42.2` = app version `480`. Always pin `image.tag: "480"`.

## Trino 480 Breaking Changes (property renames)

Many catalog properties were renamed in Trino 480. This breaks configs from older docs.

| Old (< 480) | New (480+) |
|---|---|
| `iceberg.rest-catalog.oauth2.client-id` + `oauth2.client-secret` | `iceberg.rest-catalog.oauth2.credential=<id>:<secret>` (combined) |
| `iceberg.rest-catalog.oauth2.token-endpoint` | `iceberg.rest-catalog.oauth2.server-uri` |
| `s3.access-key` | `s3.aws-access-key` |
| `s3.secret-key` | `s3.aws-secret-key` |
| `iceberg.rest-catalog.additional-header.*` | **Removed entirely** |

Since `additional-header.*` is gone, the `Polaris-Realm` header can no longer be sent from Trino.
Workaround: set `polaris.realm-context.require-header: "false"` in Polaris `advancedConfig`. This
makes Polaris default to the first configured realm (safe when there is only one realm).

## Values.yaml Structure Gotchas

These chart-level placement issues cause silent failures (settings applied to wrong scope):

- **S3/env credentials**: Use top-level `env:` — NOT `coordinator.extraEnv` / `worker.extraEnv`.
  The chart only distributes top-level `env` to all pods (coordinator + workers).
- **NodePort service**: Use top-level `service:` — NOT `coordinator.service:`.
- **Memory config**: `coordinator.config.query.maxMemoryPerNode` / `worker.config.query.maxMemoryPerNode`
  — NOT `server.config.query.maxMemoryPerNode` (that key is ignored at the node level).
- **JVM heap vs memory**: `maxMemoryPerNode` must be < 70% of `jvm.maxHeapSize` (1 GB × 0.7 = 700 MB).

## Polaris REST Catalog URI

Full `/api/catalog` suffix is required:
```
iceberg.rest-catalog.uri=http://polaris.dwh.svc.cluster.local:8181/api/catalog
```

## OAuth2 Credential

Trino 480 uses `credential` (combined format):
```
iceberg.rest-catalog.oauth2.credential=root:s3cr3t
iceberg.rest-catalog.oauth2.server-uri=http://polaris.dwh.svc.cluster.local:8181/api/catalog/v1/oauth/tokens
iceberg.rest-catalog.oauth2.scope=PRINCIPAL_ROLE:ALL
```

## S3 (Ozone) Settings

```
fs.native-s3.enabled=true
s3.endpoint=http://ozone-s3g-rest.dwh.svc.cluster.local:9878
s3.path-style-access=true
s3.region=us-east-1
s3.aws-access-key=${ENV:AWS_ACCESS_KEY_ID}
s3.aws-secret-key=${ENV:AWS_SECRET_ACCESS_KEY}
```

The `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` env vars come from the `ozone-s3-creds` secret,
which must exist in the `dwh` namespace before Trino starts.

## Ozone S3 Credentials

**Do not** use `ozone s3 getsecret` — it requires Kerberos (not enabled in dev mode).
Use static credentials (`access-key=ozone`, `secret-key=ozone-secret123`).
Ozone S3G in non-secure mode accepts any credential values.

## Pending-Install Stuck State

If `helm upgrade --install` fails partway through, Helm may leave the release in
`pending-install` state. Subsequent runs refuse to proceed. Fix:

```bash
kubectl delete secret -n dwh -l owner=helm,name=trino
kubectl delete deploy,svc -n dwh -l app.kubernetes.io/name=trino
helm upgrade --install trino trino/trino ...
```

## Namespace

Trino is in the `dwh` namespace (same as Polaris and Ozone) for internal DNS access.
NodePort `30880`. JDBC: `jdbc:trino://<node-ip>:30880`.
