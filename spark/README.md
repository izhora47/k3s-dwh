# Apache Spark on k3s

Spark jobs running via the **Apache Spark Kubernetes Operator** (v0.7.0, chart 1.5.0).

## Setup

```bash
helm repo add spark https://apache.github.io/spark-kubernetes-operator
helm upgrade --install spark-kubernetes-operator spark/spark-kubernetes-operator \
  --version 1.5.0 \
  -n spark-operator \
  --create-namespace \
  --values spark/values.yaml
```

Verify:
```bash
kubectl get pods -n spark-operator
kubectl get crd | grep spark
```

## Job Types

### 1. Classic SparkApplication

A standard batch job — driver + executors, runs to completion.

```bash
# Submit
kubectl apply -f spark/polaris-catalog-job.yaml

# Watch
kubectl get sparkapplication polaris-catalog-job -n dwh -w

# Logs
kubectl logs -n dwh polaris-catalog-job-0-driver -c spark-kubernetes-driver -f

# Delete
kubectl delete sparkapplication polaris-catalog-job -n dwh
kubectl delete configmap spark-polaris-script -n dwh
```

What it does:
1. Authenticates to Polaris REST API (via urllib stdlib — no pip install)
2. Lists all catalogs, namespaces, and tables
3. Creates Spark DataFrames from the catalog metadata
4. Prints formatted table output via `df.show()`

Expected output (last lines):
```
Catalog inventory:
+--------+--------+-------+----------------------------+
|catalog |type    |storage|location                    |
+--------+--------+-------+----------------------------+
|lakehouse|INTERNAL|FILE   |file:///tmp/lakehouse-data  |
+--------+--------+-------+----------------------------+

Total catalogs: 1
Total tables  : 2
Job COMPLETED successfully.
```

### 2. Spark Connect

A long-running gRPC server with a separate client job. Demonstrates the
Spark Connect protocol where Python code executes on a remote Spark cluster.

#### Step 1 — Start the server

```bash
kubectl apply -f spark/polaris-connect-server.yaml

# Wait for server to be ready
kubectl wait sparkapplication spark-connect-server -n dwh \
  --for=jsonpath='{.status.currentState.currentStateSummary}'=RunningHealthy \
  --timeout=3m
```

The server exposes gRPC on `spark-connect-server-svc.dwh.svc.cluster.local:15002`.

#### Step 2 — Run the client

```bash
kubectl apply -f spark/polaris-connect-client.yaml
kubectl logs -n dwh job/polaris-connect-client -f
```

The client:
1. Waits for Connect server (via initContainer nc probe)
2. Installs `pyspark[connect]==4.1.1` + `pandas` + `pyarrow`
3. Connects via `SparkSession.builder.remote("sc://...")`
4. Calls Polaris REST API to discover catalogs
5. Creates and shows DataFrames — executed **remotely** on the cluster

#### Cleanup

```bash
kubectl delete sparkapplication spark-connect-server -n dwh
kubectl delete svc spark-connect-server-svc -n dwh
kubectl delete job polaris-connect-client -n dwh
kubectl delete configmap spark-connect-client-script -n dwh
```

## CRD Reference (Apache Spark Kubernetes Operator)

> ⚠️ This operator uses a **different CRD format** than the old google/spark-on-k8s-operator.

```yaml
apiVersion: spark.apache.org/v1
kind: SparkApplication
metadata:
  name: my-job
  namespace: dwh
spec:
  # Python entry point (use pyFiles, NOT mainApplicationFile)
  pyFiles: "local:///app/my_script.py"

  runtimeVersions:
    sparkVersion: "4.1.1"

  sparkConf:
    # Image goes here (NOT spec.image)
    "spark.kubernetes.container.image": "apache/spark:4.1.1-python3"
    "spark.kubernetes.authenticate.driver.serviceAccountName": "spark"
    "spark.kubernetes.namespace": "dwh"
    "spark.pyspark.python": "python3"
    # Resource tuning for single-node k3s
    "spark.executor.instances": "1"
    "spark.kubernetes.executor.request.cores": "500m"
    "spark.kubernetes.driver.request.cores": "500m"

  applicationTolerations:
    resourceRetainPolicy: OnFailure   # keep pods if job fails
    ttlAfterStopMillis: 60000         # delete pods 60s after completion

  driverSpec:
    podTemplateSpec:          # Standard Kubernetes PodSpec
      spec:
        # ... volumes, initContainers, env, etc.
```

### ConfigMap + pyFiles pattern

Spark copies `pyFiles` into its work-dir. If you mount a ConfigMap there, it fails.
**Solution**: Use an initContainer to copy to an emptyDir:

```yaml
spec:
  pyFiles: "local:///app/script.py"
  driverSpec:
    podTemplateSpec:
      spec:
        initContainers:
          - name: copy-script
            image: busybox:1.36
            command: [sh, -c, "cp /cm/script.py /app/script.py"]
            volumeMounts:
              - {name: script-cm, mountPath: /cm}
              - {name: appdir,    mountPath: /app}
        volumes:
          - name: script-cm
            configMap: {name: my-configmap}
          - name: appdir
            emptyDir: {}
        containers:
          - name: spark-kubernetes-driver
            volumeMounts:
              - {name: appdir, mountPath: /app}
```

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Executor pods stuck `Pending` | Insufficient CPU | Add `spark.kubernetes.executor.request.cores: 500m` |
| `NoSuchFileException` on pyFiles | src==dst copy (ConfigMap at work-dir) | Use initContainer + emptyDir pattern |
| `Failed to delete` | Read-only ConfigMap at work-dir | Same fix as above |
| pip install times out | Network / timeout | Use stdlib only (urllib) for HTTP calls |
| `HTTP 500` from Polaris on load_table | Ozone offline | Use try/except around table metadata calls |
