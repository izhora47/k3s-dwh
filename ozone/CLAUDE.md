# CLAUDE.md — Apache Ozone Component

## Chart

`ozone/ozone` v0.2.0 (app version 2.0.0). Helm repo: `https://apache.github.io/ozone-helm-charts/`.

## Single-Node Configuration

All critical single-node settings are in `values.yaml` via `OZONE-SITE.XML_` env var prefix:
- `hdds.scm.safemode.min.datanode: "1"` — exits safe mode with just 1 datanode
- `ozone.replication: "1"` — no replication (single node)
- `ozone.scm.pipeline.creation.auto.factor.one: "true"` — allows pipelines with factor 1
- `ozone.datanode.pipeline.limit: "1"` — limits concurrent pipelines

## S3 Gateway

The S3 Gateway (`s3g`) component provides the S3-compatible REST API. It is exposed as:
- ClusterIP: `ozone-s3g-rest.dwh.svc.cluster.local:9878` (used by Trino and Spark)
- NodePort: `30878` (external access)

## S3 Credentials

Ozone uses its own credential system. Credentials are NOT static config — they are generated per user via `ozone s3 getsecret -u <username>`. The install script generates credentials for user `trino` and stores them in secret `ozone-s3-creds` in the `dwh` namespace.

**Critical**: Credentials are deterministic for a given user+cluster. If you regenerate, the old secret in Kubernetes must be updated.

## Volumes and Buckets

Ozone uses a hierarchy: Volume → Bucket → Key.

The S3 Gateway maps S3 buckets to Ozone buckets in the volume `/s3v` (the "S3 volume" created automatically by S3G). So S3 bucket `lakehouse` maps to Ozone path `/s3v/lakehouse`.

The `lakehouse` bucket must be created with `--layout OBJECT_STORE` (not `LEGACY`) for S3 compatibility.

## Service Names

After Helm install, Ozone services in the `dwh` namespace:
- OM: `ozone-om.dwh.svc.cluster.local:9862` (RPC) / `:9874` (HTTP UI)
- SCM: `ozone-scm.dwh.svc.cluster.local:9860`
- S3G: `ozone-s3g-rest.dwh.svc.cluster.local:9878`
- DataNode: headless service for pod-to-pod communication

The exact service names depend on the Helm release name (`ozone`). If the release is renamed, update all service references in `trino/values.yaml` and `polaris/values.yaml`.

## Storage

Each Ozone component (OM, SCM, DataNode) uses a separate PVC on `local-path`. DataNode gets 10Gi for actual data, OM and SCM get 5Gi for metadata.
