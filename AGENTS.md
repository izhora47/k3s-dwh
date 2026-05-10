# AGENTS.md — DWH Data Lakehouse on k3s

This document describes the architecture, components, and lessons learned for the
data warehouse (DWH) stack running on a single-node k3s cluster.

## Stack Overview

```
┌─────────────────────────────────────────────────────────────┐
│  k3s cluster (single node: aurora)                          │
│                                                             │
│  namespace: dwh                                             │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐  │
│  │ Apache        │  │ CloudNative   │  │ Apache Spark     │  │
│  │ Polaris       │  │ PG (CNPG)    │  │ (jobs only)      │  │
│  │ 1.3.0-incub.  │  │ PostgreSQL   │  │                  │  │
│  └──────────────┘  └──────────────┘  └──────────────────┘  │
│                                                             │
│  namespace: spark-operator                                  │
│  ┌──────────────────────────────────────────────────────┐   │
│  │ Apache Spark Kubernetes Operator 0.7.0 (chart 1.5.0) │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                             │
│  namespace: airflow  (planned)                              │
│  ┌──────────────────────────────────────────────────────┐   │
│  │ Apache Airflow 3.1.7 — LocalExecutor                 │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

## Components

### Apache Polaris (Iceberg REST Catalog)
- **Version**: 1.3.0-incubating
- **Helm chart**: `polaris/polaris` from `https://downloads.apache.org/polaris/helm-chart`
- **Namespace**: `dwh`
- **Database**: CloudNativePG PostgreSQL (via CNPG operator)
- **Port**: 8181 (internal: `polaris.dwh.svc.cluster.local:8181`)
- **API base**: `/api/catalog` (Iceberg REST), `/api/management` (admin)
- **Auth**: OAuth2 client credentials (`root`/`s3cr3t`, realm `POLARIS`)
- **Key config**:
  - `stsUnavailable: true` — disables AWS STS credential vending
  - `pathStyleAccess: true` — forces S3 path-style URLs (required for Ozone)
  - `AWS_ENDPOINT_URL_S3` env var — redirects server-side S3 calls to Ozone

### CloudNativePG (CNPG) PostgreSQL
- Provides managed PostgreSQL for Polaris metadata
- Creates secret `polaris-pg-app` with keys: `username`, `password`, `jdbcUrl`
- **IMPORTANT**: Never use `USERNAME` as a shell variable name — it's a reserved
  bash variable (contains the Linux username). Use `DB_USER` instead.

### Apache Spark Kubernetes Operator
- **Version**: chart 1.5.0, operator 0.7.0 (app 0.7.0)
- **Helm chart**: `spark/spark-kubernetes-operator` from `https://apache.github.io/spark-kubernetes-operator`
- **Namespace**: `spark-operator` (watches `dwh` namespace)
- **CRD**: `SparkApplication`, `SparkCluster`
- **Service account**: `spark` in `dwh` namespace

#### SparkApplication CRD — NEW format (NOT google/spark-on-k8s-operator)

The Apache Spark Kubernetes Operator uses a **completely different CRD spec** than
the old google/spark-on-k8s-operator. Key differences:

| Old (google) | New (Apache) |
|---|---|
| `spec.mainApplicationFile` | `spec.pyFiles` (Python) |
| `spec.image` | `sparkConf["spark.kubernetes.container.image"]` |
| `spec.sparkVersion` | `spec.runtimeVersions.sparkVersion` |
| `spec.driver.serviceAccount` | `sparkConf["spark.kubernetes.authenticate.driver.serviceAccountName"]` |
| `spec.driver` / `spec.executor` | `spec.driverSpec.podTemplateSpec` |

#### pyFiles ConfigMap workaround

Spark copies `pyFiles` to the work-dir (`/opt/spark/work-dir`). If you mount a
ConfigMap at work-dir, Spark fails because:
1. First: "Failed to delete" (read-only ConfigMap)
2. Then: "NoSuchFileException" (src == dst copy path)

**Solution**: Use an initContainer to copy the ConfigMap file to an emptyDir:

```yaml
spec:
  pyFiles: "local:///app/polaris_catalog.py"   # NOT work-dir
  driverSpec:
    podTemplateSpec:
      spec:
        initContainers:
          - name: copy-script
            image: busybox:1.36
            command: [sh, -c, "cp /cm/polaris_catalog.py /app/polaris_catalog.py"]
            volumeMounts:
              - {name: script-cm, mountPath: /cm}
              - {name: appdir, mountPath: /app}
        volumes:
          - name: script-cm
            configMap: {name: spark-polaris-script}
          - name: appdir
            emptyDir: {}
        containers:
          - name: spark-kubernetes-driver
            volumeMounts:
              - {name: appdir, mountPath: /app}
```

#### Resource constraints (single-node k3s)

Default executor requests 1 CPU. On a constrained cluster, always set:
```yaml
sparkConf:
  "spark.executor.instances": "1"
  "spark.kubernetes.executor.request.cores": "500m"
  "spark.kubernetes.driver.request.cores": "500m"
```

### Spark Job Types

#### 1. Classic SparkApplication (`spark/polaris-catalog-job.yaml`)
- Runs as a `SparkApplication` CR
- Driver + executor pods managed by operator
- Python script uses only urllib stdlib (no pip install)
- Connects to Polaris REST API, lists catalogs/namespaces/tables
- Creates in-memory Spark DataFrames from catalog metadata
- TTL: 60s after completion

#### 2. Spark Connect (`spark/polaris-connect-server.yaml` + `spark/polaris-connect-client.yaml`)
- **Server**: Long-running SparkApplication, exposes gRPC on port 15002
  - `mainClass: org.apache.spark.sql.connect.service.SparkConnectServer`
  - Dynamic allocation: 1-2 executors
  - Service: `spark-connect-server-svc.dwh.svc.cluster.local:15002`
- **Client**: Kubernetes Job using `python:3.12-slim`
  - Installs `pyspark[connect]==4.1.1`, `pandas`, `pyarrow` at runtime
  - Connects via `SparkSession.builder.remote("sc://host:15002")`
  - Executes DataFrames remotely on the cluster
  - initContainer waits for Connect server to be ready

### Apache Airflow (planned — `airflow/values.yaml`)
- **Version**: 3.1.7 (chart 1.19.0)
- **Helm repo**: `https://airflow.apache.org` (chart: `apache-airflow/airflow`)
- **Executor**: LocalExecutor (single-node, no Redis/Celery)
- **Namespace**: `airflow`
- **UI**: NodePort 30080
- **DAGs**: Loaded from ConfigMap via extraVolumes → `/opt/airflow/dags/dwh`
- **Auth**: admin/admin (local dev)

## Directory Structure

```
k3s/dwh/
├── README.md              # Main setup guide
├── AGENTS.md              # This file
├── CLAUDE.md              # Instructions for AI agents
├── install.sh             # One-shot install script
├── uninstall.sh           # One-shot uninstall script
├── namespace.yaml         # Kubernetes namespace definition
├── cnpg/                  # CloudNativePG PostgreSQL cluster
│   └── polaris-pg.yaml
├── polaris/               # Apache Polaris Iceberg catalog
│   ├── README.md
│   └── values.yaml
├── spark/                 # Spark operator + jobs
│   ├── README.md
│   ├── values.yaml        # Operator Helm values
│   ├── polaris-catalog-job.yaml    # Classic SparkApplication
│   ├── polaris-connect-server.yaml # Spark Connect gRPC server
│   └── polaris-connect-client.yaml # Spark Connect client job
├── airflow/               # Apache Airflow
│   ├── values.yaml
│   └── dags/
│       ├── polaris_catalog_dag.py   # Classic Spark DAG
│       └── polaris_connect_dag.py   # Spark Connect DAG
└── test/                  # Manual test scripts
    └── test_polaris.py
```

## Airflow 3.x Specifics

### Component renames
- **Webserver → API Server**: In Airflow 3, the UI is served by `apiServer`, not `webserver`.
  Use `apiServer.service.type: NodePort` in values.yaml.
- **Health endpoint**: `/health` redirects; use `/api/v2/monitor/health` instead.

### DAG loading from ConfigMap
ConfigMap volumes in Kubernetes use symlinks (`..data/` → timestamped directory).
Airflow 3's dag-processor crashes with:
```
RuntimeError: Detected recursive loop when walking DAG directory
```

**Fix**: Use an `extraInitContainers` that copies ConfigMap files to an emptyDir:
```yaml
dagProcessor:
  extraInitContainers:
    - name: copy-dags
      image: busybox:1.36
      command: [sh, -c, "cp /cm/*.py /dags/"]
      volumeMounts:
        - {name: dags-cm, mountPath: /cm}
        - {name: dags-copy, mountPath: /dags}
  extraVolumes:
    - name: dags-cm
      configMap: {name: airflow-dags}
    - name: dags-copy
      emptyDir: {}
  extraVolumeMounts:
    - name: dags-copy
      mountPath: /opt/airflow/dags/dwh
```

**Note**: After updating the ConfigMap, restart dag-processor to re-run the init container:
```bash
kubectl rollout restart deployment airflow-dag-processor -n airflow
```

### KubernetesPodOperator volume_mounts format
In the new CNCF k8s provider, `volume_mounts` and `volumes` must use proper k8s model objects,
not plain dicts:
```python
from kubernetes.client import models as k8s

volumes=[k8s.V1Volume(name="scripts",
    config_map=k8s.V1ConfigMapVolumeSource(name="my-cm"))],
volume_mounts=[k8s.V1VolumeMount(name="scripts", mount_path="/scripts")],
```

### Triggerer
Airflow 3 includes a triggerer for deferred tasks. On a constrained cluster, it crashes
due to logs directory issues (`/opt/airflow/logs: Device or resource busy`). Since our
DAGs use polling sensors (not deferred), disable it: `triggerer.enabled: false`.

### extraVolumes placement
In Airflow 3.x chart, `extraVolumes` and `extraVolumeMounts` are per-component,
NOT top-level. They must be under `scheduler.extraVolumes`, `dagProcessor.extraVolumes`, etc.

### logs.persistence
No `accessMode` field for logs persistence in the chart. With `local-path` storageClass,
use `logs.persistence.enabled: false` (emptyDir) instead.

## Known Issues and Fixes

| Issue | Cause | Fix |
|---|---|---|
| Ozone Helm repo 404 | Wrong URL | Use `https://apache.github.io/ozone-helm-charts/` |
| Polaris OCI 403 | ghcr.io registry denied | Use `https://downloads.apache.org/polaris/helm-chart` |
| Polaris chart version error | `-incubating` suffix = pre-release | Add `--version 1.3.0-incubating` |
| Polaris bootstrap uses wrong DB user | `USERNAME` is a reserved bash var | Use `DB_USER` variable name |
| Polaris table creation HTTP 500 | Server-side S3 calls go to AWS | Set `AWS_ENDPOINT_URL_S3` in Polaris extraEnv |
| SparkApplication wrong fields | Using old google operator fields | See CRD field mapping table above |
| pip install timeout in Spark | Network too slow / timeout | Use only stdlib (urllib) — no pip needed |
| ConfigMap mount at work-dir fails | src==dst copy or read-only delete | Use initContainer + emptyDir (see pattern above) |
| Executor pods Pending (Insufficient CPU) | Default 1 CPU request | Set `spark.kubernetes.executor.request.cores: 500m` |
| Polaris HTTP 500 on load_table | Ozone offline → S3 error | Use `http_get_safe()` with try/except |
| Airflow `webserver` NodePort not working | Airflow 3 uses `apiServer`, not `webserver` | Use `apiServer.service.type: NodePort` |
| Airflow dag-processor CrashLoop (recursive loop) | ConfigMap symlinks in dags dir | Use initContainer + emptyDir to copy DAGs |
| KubernetesPodOperator dict volume_mounts | New CNCF k8s provider requires k8s objects | Use `k8s.V1VolumeMount` instead of dict |
| Airflow triggerer CrashLoop | Logs dir busy + not needed for polling | Set `triggerer.enabled: false` |
| Airflow `extraVolumes` not applied | They're per-component in Airflow 3.x chart | Put under `scheduler.extraVolumes`, etc. |
| Spark Connect client pip install very slow | pyarrow ~70MB download on slow cluster | Expected 30-60min; use pre-built image for prod |

## Bootstrap Flow

1. Create `dwh` namespace
2. Install CNPG operator (if not present)
3. Create CNPG PostgreSQL cluster (`polaris-pg`)
4. Install Polaris via Helm (reads DB creds from `polaris-pg-app` secret)
5. Bootstrap Polaris: create principal role, catalog principal, assign roles
6. Create `lakehouse` catalog (type=INTERNAL, storage=FILE)
7. Create `bronze` namespace + `orders` table
8. Run test insert/select queries

## Helm Commands Reference

```bash
# Polaris
helm repo add polaris https://downloads.apache.org/polaris/helm-chart
helm upgrade --install polaris polaris/polaris \
  --version 1.3.0-incubating -n dwh --values polaris/values.yaml

# Spark Operator
helm repo add spark https://apache.github.io/spark-kubernetes-operator
helm upgrade --install spark-kubernetes-operator spark/spark-kubernetes-operator \
  --version 1.5.0 -n spark-operator --create-namespace \
  --values spark/values.yaml

# Airflow
helm repo add apache-airflow https://airflow.apache.org
helm upgrade --install airflow apache-airflow/airflow \
  --version 1.19.0 -n airflow --create-namespace \
  --values airflow/values.yaml
```
