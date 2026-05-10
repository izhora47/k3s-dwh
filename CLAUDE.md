# CLAUDE.md — Instructions for AI Agents

This file provides context and instructions for AI agents working on this project.

## Project Purpose

This is a **data lakehouse** stack running on a single-node k3s Kubernetes cluster.
It demonstrates Apache Iceberg table format on top of Apache Ozone object storage,
managed by Apache Polaris as the Iceberg REST catalog, with Apache Spark for
compute, Apache Airflow for orchestration, Trino for SQL queries, ClickHouse for
OLAP analytics, and pgAdmin4 as the database UI.

## Full Stack

| Component | Namespace | Helm Chart | Purpose |
|---|---|---|---|
| CloudNativePG | `cnpg-system` | `cnpg/cloudnative-pg` | PostgreSQL operator |
| PostgreSQL (polaris-pg) | `dwh` | CNPG CR | Polaris metadata store |
| Apache Polaris | `dwh` | `polaris/polaris 1.3.0-incubating` | Iceberg REST catalog |
| Apache Ozone | `dwh` | `ozone/ozone 0.2.0` | S3-compatible object storage |
| Spark Operator | `spark-operator` | `spark/spark-kubernetes-operator 1.5.0` | Spark jobs |
| Apache Airflow | `airflow` | `apache-airflow/airflow 1.19.0` | DAG orchestration |
| Trino | `dwh` | `trino/trino 1.42.2` | Distributed SQL over Iceberg |
| ClickHouse Operator | `clickhouse` | GitHub release v0.0.4 | ClickHouse lifecycle mgmt |
| ClickHouse Keeper | `clickhouse` | CR: KeeperCluster | ZK-compatible coordination |
| ClickHouse | `clickhouse` | CR: ClickHouseCluster | Columnar OLAP engine |
| pgAdmin4 | `dwh` | `runix/pgadmin4 1.62.0` | PostgreSQL web UI |

## Install

```bash
# Core only (CNPG + Polaris + Spark + Airflow)
./install.sh

# Core + Ozone S3 storage
./install.sh --with-ozone

# Full stack (all components)
./install.sh --full

# Flags: --with-ozone --with-trino --with-clickhouse --with-pgadmin --no-spark --no-airflow
```

## Repository Layout

The k3s configuration lives at `/home/nik/projects/k3s/dwh/`. Read `AGENTS.md`
for the full architecture overview and lessons learned.

## Critical Rules

### 1. Shell variable naming
**NEVER use `USERNAME` as a variable name in shell scripts.** It is a reserved
bash variable that contains the current Linux username. Use `DB_USER` instead.

### 2. Spark Kubernetes Operator CRD format
This project uses the **Apache Spark Kubernetes Operator** (NOT google/spark-on-k8s-operator).
The CRD fields are different — see `AGENTS.md` for the mapping table.

Key: Python jobs use `spec.pyFiles`, not `spec.mainApplicationFile`.
Key: Image goes in `sparkConf["spark.kubernetes.container.image"]`, not `spec.image`.
Key: Driver customization is under `spec.driverSpec.podTemplateSpec`.

### 3. ConfigMap + pyFiles workaround
Never mount a ConfigMap at `/opt/spark/work-dir` for `pyFiles`. Use an
initContainer to copy the script to an emptyDir, then set `pyFiles` to
`local:///app/<script>.py` and mount the emptyDir at `/app`.

### 4. Resource constraints
This is a single-node cluster (4 CPUs, ~8GB RAM). Total requested CPU across all
pods is close to 4000m. Always set for Spark jobs:
```yaml
"spark.executor.instances": "1"
"spark.kubernetes.executor.request.cores": "500m"
"spark.kubernetes.driver.request.cores": "500m"
```

### 5. Polaris chart version
The Polaris Helm chart version has `-incubating` suffix. Always use:
```bash
helm upgrade --install polaris polaris/polaris --version 1.3.0-incubating ...
```

### 6. No pip in Spark driver
The `apache/spark:4.1.1-python3` image has only stdlib + pip (no packages).
pip installs time out in most environments. Write PySpark scripts using only
`urllib` (stdlib) for HTTP calls. PySpark itself is available at runtime.

## Cluster Access

```bash
# Check all dwh workloads
kubectl get all -n dwh

# Watch Spark jobs
kubectl get sparkapplication -n dwh -w

# Driver logs
kubectl logs -n dwh -l spark-role=driver -c spark-kubernetes-driver -f

# Polaris logs
kubectl logs -n dwh -l app.kubernetes.io/name=polaris -f
```

## Polaris API

Base URL (from within cluster): `http://polaris.dwh.svc.cluster.local:8181`

```bash
# Get auth token
TOKEN=$(curl -s -X POST \
  http://polaris.dwh.svc.cluster.local:8181/api/catalog/v1/oauth/tokens \
  -H "Polaris-Realm: POLARIS" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=client_credentials&client_id=root&client_secret=s3cr3t&scope=PRINCIPAL_ROLE:ALL" \
  | jq -r .access_token)

# List catalogs
curl -H "Authorization: Bearer $TOKEN" -H "Polaris-Realm: POLARIS" \
  http://polaris.dwh.svc.cluster.local:8181/api/management/v1/catalogs
```

## Running Tests

```bash
# Classic SparkApplication (one-shot job)
kubectl apply -f spark/polaris-catalog-job.yaml
kubectl wait sparkapplication polaris-catalog-job -n dwh \
  --for=jsonpath='{.status.currentState.currentStateSummary}'=Succeeded --timeout=5m
kubectl logs -n dwh -l spark-role=driver -c spark-kubernetes-driver

# Spark Connect server (long-running)
kubectl apply -f spark/polaris-connect-server.yaml
kubectl wait sparkapplication spark-connect-server -n dwh \
  --for=jsonpath='{.status.currentState.currentStateSummary}'=RunningHealthy --timeout=3m

# Spark Connect client
kubectl apply -f spark/polaris-connect-client.yaml
kubectl logs -n dwh job/polaris-connect-client -f

# Cleanup
kubectl delete sparkapplication polaris-catalog-job spark-connect-server -n dwh
kubectl delete job polaris-connect-client -n dwh
kubectl delete configmap spark-polaris-script spark-connect-client-script -n dwh
```

## Airflow DAGs

DAGs are stored in `airflow/dags/` and deployed via ConfigMap.
To update a DAG:
1. Edit the file in `airflow/dags/`
2. Recreate the ConfigMap:
   ```bash
   kubectl create configmap airflow-dags \
     --from-file=airflow/dags/ -n airflow \
     --dry-run=client -o yaml | kubectl apply -f -
   ```
3. Airflow will pick up changes automatically (DAG file scanning interval: 30s)

## Install / Uninstall

```bash
cd /home/nik/projects/k3s/dwh
./install.sh    # Deploy full stack
./uninstall.sh  # Tear down everything
```

## Important Credentials (local dev only)

| Service | Credential |
|---|---|
| Polaris OAuth | client_id=`root`, client_secret=`s3cr3t`, realm=`POLARIS` |
| Airflow UI | admin / admin |
| PostgreSQL | See secret `polaris-pg-app` in `dwh` namespace |
