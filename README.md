# Data Lakehouse on k3s

Apache Iceberg lakehouse on a single-node k3s cluster. Apache Polaris manages the Iceberg REST catalog,
Apache Ozone provides S3-compatible storage, Trino queries the lakehouse via SQL, and ClickHouse handles
OLAP analytics. All components deploy via a single `install.sh` script.

---

## Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│  k3s cluster (single node: aurora, 4 CPU / 8 GB RAM)                │
│                                                                      │
│  namespace: dwh                                                      │
│  ┌─────────────────┐   ┌──────────────────┐   ┌──────────────────┐  │
│  │ Apache Polaris  │   │ CloudNativePG    │   │  Apache Ozone    │  │
│  │ Iceberg REST    │──▶│ PostgreSQL 16    │   │  S3 Gateway      │  │
│  │ Catalog :8181   │   │ (polaris-pg)     │   │  :9878           │  │
│  └────────┬────────┘   └──────────────────┘   └────────┬─────────┘  │
│           │  metadata + auth                  data files│            │
│           │  ◀────────────────────────────────────────  │            │
│  ┌────────▼───────────────────────────────────────────▼──────────┐  │
│  │  Trino 480  (coordinator + 1 worker)                          │  │
│  │  lakehouse catalog (Iceberg REST) + tpch/tpcds benchmarks     │  │
│  │  :8080  NodePort :30880                                        │  │
│  └────────────────────────────────────────────────────────────────┘  │
│                                                                      │
│  namespace: clickhouse                                               │
│  ┌──────────────────┐   ┌──────────────────────────────────────────┐ │
│  │ ClickHouse Keeper│   │  ClickHouse 25.8 (1 shard × 1 replica)  │ │
│  │ (ZK coordination)│──▶│  HTTP :8123  native :9000                │ │
│  └──────────────────┘   │  NodePorts :30123 / :30900               │ │
│                          └──────────────────────────────────────────┘ │
│                                                                      │
│  namespace: dwh                                                      │
│  ┌────────────────────┐                                              │
│  │  CloudBeaver       │  Web SQL IDE — connects to Trino/ClickHouse │
│  │  :8978  NP :30978  │                                              │
│  └────────────────────┘                                              │
│                                                                      │
│  namespace: cnpg-system                                              │
│  ┌────────────────────────────────────────────────────────────────┐  │
│  │  CloudNativePG operator                                        │  │
│  └────────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────┘
```

### Data flow

```
Client (PyIceberg / Trino / ClickHouse)
  → POST /api/catalog/v1/oauth/tokens   → Polaris (auth)
  → GET/POST /api/catalog/v1/...        → Polaris (table metadata)
  → s3://lakehouse/...                  → Ozone S3 Gateway (data files, parquet)
```

---

## Services & NodePorts

| Service | NodePort | In-cluster DNS |
|---|---|---|
| Apache Polaris | `30181` | `polaris.dwh.svc.cluster.local:8181` |
| Apache Ozone S3 Gateway | `30878` | `ozone-s3g-rest.dwh.svc.cluster.local:9878` |
| Trino | `30880` | `trino.dwh.svc.cluster.local:8080` |
| ClickHouse HTTP | `30123` | `clickhouse.clickhouse.svc.cluster.local:8123` |
| ClickHouse native | `30900` | `clickhouse.clickhouse.svc.cluster.local:9000` |
| CloudBeaver | `30978` | `cloudbeaver.dwh.svc.cluster.local:8978` |
| Airflow | `30080` | `airflow-webserver.airflow.svc.cluster.local:8080` |

---

## Helm Charts

| Chart | Repo | Version |
|---|---|---|
| `cnpg/cloudnative-pg` | `https://cloudnative-pg.github.io/charts` | ≥ 1.24 |
| `polaris/polaris` | `https://downloads.apache.org/polaris/helm-chart` | `1.3.0-incubating` |
| `ozone/ozone` | `https://apache.github.io/ozone-helm-charts/` | `0.2.0` |
| `trino/trino` | `https://trinodb.github.io/charts` | `1.42.2` (app 480) |
| `clickhouse-operator` | GitHub release (no repo) | `v0.0.4` |
| `spark/spark-kubernetes-operator` | `https://apache.github.io/spark-kubernetes-operator` | `1.5.0` |
| `apache-airflow/airflow` | `https://airflow.apache.org` | `1.19.0` |

---

## Directory Structure

```
dwh/
├── README.md               ← This file
├── AGENTS.md               ← Architecture notes and lessons learned
├── CLAUDE.md               ← Instructions for AI agents
├── install.sh              ← One-shot install script
├── uninstall.sh            ← Teardown script
├── namespace.yaml          ← dwh namespace
├── cnpg/
│   └── pg-cluster.yaml     ← CNPG PostgreSQL cluster (polaris-pg)
├── polaris/
│   ├── CLAUDE.md           ← Polaris gotchas + auth flow reference
│   ├── README.md           ← Polaris API command reference
│   └── values.yaml         ← Polaris Helm values
├── ozone/
│   ├── CLAUDE.md
│   ├── README.md
│   └── values.yaml
├── trino/
│   ├── CLAUDE.md           ← Trino 480 property renames + gotchas
│   ├── README.md           ← Queries reference
│   └── values.yaml
├── clickhouse/
│   ├── CLAUDE.md           ← Official operator CRD schema + gotchas
│   ├── README.md
│   ├── values.yaml         ← Operator Helm values (webhooks disabled)
│   ├── keeper-cluster.yaml ← KeeperCluster CR
│   ├── clickhouse-cluster.yaml  ← ClickHouseCluster CR
│   └── clickhouse-service.yaml  ← NodePort service (external access)
├── cloudbeaver/
│   └── manifest.yaml       ← CloudBeaver Deployment + PVC + Service
├── spark/
│   ├── README.md
│   └── values.yaml
├── airflow/
│   ├── values.yaml
│   └── dags/
└── test/
    └── test-job.yaml       ← PyIceberg integration test (CREATE + INSERT + SELECT)
```

---

## Installation

### Prerequisites

```bash
kubectl get nodes              # k3s running, node status Ready
helm version                   # Helm ≥ 3.12
kubectl get sc local-path      # k3s default storage class present
```

### One-shot install

```bash
cd /home/nik/projects/k3s/dwh

# Core + Ozone + Trino + ClickHouse + CloudBeaver (no Spark/Airflow)
./install.sh --with-ozone --with-trino --with-clickhouse --with-cloudbeaver --no-spark --no-airflow

# Everything
./install.sh --full

# Core only (Polaris + PostgreSQL)
./install.sh --no-spark --no-airflow
```

**Flags:**

| Flag | Effect |
|---|---|
| `--with-ozone` | Apache Ozone S3 storage |
| `--with-trino` | Trino SQL engine (implies `--with-ozone`) |
| `--with-clickhouse` | ClickHouse OLAP engine |
| `--with-cloudbeaver` | CloudBeaver web SQL IDE |
| `--with-pgadmin` | pgAdmin4 PostgreSQL UI |
| `--no-spark` | Skip Spark Operator |
| `--no-airflow` | Skip Airflow |
| `--full` | Enable all optional components |

### Manual step-by-step

#### Step 1 — Namespace

```bash
kubectl apply -f namespace.yaml
```

#### Step 2 — CloudNativePG operator

```bash
helm repo add cnpg https://cloudnative-pg.github.io/charts
helm upgrade --install cnpg cnpg/cloudnative-pg \
  --namespace cnpg-system --create-namespace --wait
```

#### Step 3 — PostgreSQL cluster

```bash
kubectl apply -f cnpg/pg-cluster.yaml
# Wait for "Cluster in healthy state"
kubectl get cluster polaris-pg -n dwh -w
```

#### Step 4 — Polaris secrets

```bash
NS=dwh

# Persistence secret (JDBC credentials for Polaris → PostgreSQL)
kubectl -n $NS create secret generic polaris-persistence \
  --from-literal=username="$(kubectl get secret polaris-pg-app -n $NS -o jsonpath='{.data.username}' | base64 -d)" \
  --from-literal=password="$(kubectl get secret polaris-pg-app -n $NS -o jsonpath='{.data.password}' | base64 -d)" \
  --from-literal=jdbcUrl="jdbc:postgresql://polaris-pg-rw.${NS}.svc.cluster.local:5432/polaris"

# RSA token broker secret (JWT signing keys)
openssl genrsa -out /tmp/private.pem 2048
openssl rsa -in /tmp/private.pem -pubout -out /tmp/public.pem
printf "secret" > /tmp/symmetric.key
kubectl -n $NS create secret generic polaris-token-broker \
  --from-file=/tmp/private.pem \
  --from-file=/tmp/public.pem \
  --from-file=/tmp/symmetric.key
```

#### Step 5 — Apache Ozone (optional)

```bash
helm repo add ozone https://apache.github.io/ozone-helm-charts/
helm upgrade --install ozone ozone/ozone \
  --version 0.2.0 --namespace dwh --values ozone/values.yaml --wait --timeout 10m

# Create S3 bucket
OM_POD=$(kubectl get pod -n dwh -l app.kubernetes.io/component=om -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n dwh "$OM_POD" -- ozone sh bucket create /s3v/lakehouse --layout OBJECT_STORE

# Create S3 credentials secret (static — Ozone non-secure mode accepts any credentials)
kubectl -n dwh create secret generic ozone-s3-creds \
  --from-literal=access-key="ozone" \
  --from-literal=secret-key="ozone-secret123"
```

> **Note:** `ozone s3 getsecret` requires Kerberos (not enabled in dev mode). Use static
> credentials — Ozone S3G in non-secure mode accepts any credential values.

#### Step 6 — Apache Polaris

```bash
helm repo add polaris https://downloads.apache.org/polaris/helm-chart
helm upgrade --install polaris polaris/polaris \
  --version 1.3.0-incubating \        # -incubating suffix required — Helm treats it as pre-release
  --namespace dwh \
  --values polaris/values.yaml \
  --wait --timeout 5m
```

#### Step 7 — Bootstrap Polaris realm

```bash
NS=dwh; REALM=POLARIS
DB_JDBC=$(kubectl get secret polaris-persistence -n $NS -o json \
  | python3 -c "import sys,json,base64; s=json.load(sys.stdin); print(base64.b64decode(s['data']['jdbcUrl']).decode())")
DB_USER=$(kubectl get secret polaris-persistence -n $NS -o json \
  | python3 -c "import sys,json,base64; s=json.load(sys.stdin); print(base64.b64decode(s['data']['username']).decode())")
DB_PASS=$(kubectl get secret polaris-persistence -n $NS -o json \
  | python3 -c "import sys,json,base64; s=json.load(sys.stdin); print(base64.b64decode(s['data']['password']).decode())")

kubectl -n $NS run polaris-bootstrap --rm -i --restart=Never \
  --image=apache/polaris-admin-tool:1.3.0-incubating \
  --env="QUARKUS_DATASOURCE_JDBC_URL=$DB_JDBC" \
  --env="QUARKUS_DATASOURCE_USERNAME=$DB_USER" \
  --env="QUARKUS_DATASOURCE_PASSWORD=$DB_PASS" \
  -- bootstrap -r "$REALM" -c "$REALM,root,s3cr3t" -p
```

This creates realm `POLARIS` with principal `root` / secret `s3cr3t`.

> **Never use `USERNAME` as a shell variable** — it is a reserved bash variable containing
> the current Linux user. Use `DB_USER` or similar names.

#### Step 8 — Create catalog + namespace

```bash
POLARIS_POD=$(kubectl get pod -n dwh -l app.kubernetes.io/name=polaris -o jsonpath='{.items[0].metadata.name}')

# Get OAuth token
TOKEN=$(kubectl exec -n dwh "$POLARIS_POD" -- curl -sS -X POST \
  "http://localhost:8181/api/catalog/v1/oauth/tokens" \
  -H "Polaris-Realm: POLARIS" -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=client_credentials&client_id=root&client_secret=s3cr3t&scope=PRINCIPAL_ROLE:ALL" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

AUTH="-H 'Authorization: Bearer $TOKEN' -H 'Polaris-Realm: POLARIS'"

# Create S3 catalog (when Ozone is available)
kubectl exec -n dwh "$POLARIS_POD" -- curl -sS -X POST \
  "http://localhost:8181/api/management/v1/catalogs" \
  -H "Authorization: Bearer $TOKEN" -H "Polaris-Realm: POLARIS" \
  -H "Content-Type: application/json" \
  -d '{
    "catalog": {
      "name": "lakehouse",
      "type": "INTERNAL",
      "properties": {"default-base-location": "s3://lakehouse/"},
      "storageConfigInfo": {
        "storageType": "S3",
        "allowedLocations": ["s3://lakehouse/"],
        "s3.path-style-access": "true",
        "stsUnavailable": true
      }
    }
  }'

# Create namespace
kubectl exec -n dwh "$POLARIS_POD" -- curl -sS -X POST \
  "http://localhost:8181/api/catalog/v1/lakehouse/namespaces" \
  -H "Authorization: Bearer $TOKEN" -H "Polaris-Realm: POLARIS" \
  -H "Content-Type: application/json" \
  -d '{"namespace":["bronze"],"properties":{"location":"s3://lakehouse/bronze"}}'
```

> **Note:** The `s3.endpoint` field in `storageConfigInfo` is silently ignored by Polaris for
> actual data I/O. The endpoint must come from `AWS_ENDPOINT_URL_S3` env var set on the Polaris
> pod (see `polaris/values.yaml` → `extraEnv`).

#### Step 9 — Trino (optional)

Requires Ozone deployed (Step 5).

```bash
helm repo add trino https://trinodb.github.io/charts
helm upgrade --install trino trino/trino \
  --version 1.42.2 \
  --namespace dwh \
  --values trino/values.yaml \
  --wait --timeout 5m
```

#### Step 10 — ClickHouse (optional)

```bash
# Create namespace + install operator (direct GitHub release URL — no repo needed)
kubectl create namespace clickhouse --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install clickhouse-operator \
  https://github.com/ClickHouse/clickhouse-operator/releases/download/v0.0.4/clickhouse-operator-helm-0.0.4.tgz \
  --namespace clickhouse --values clickhouse/values.yaml --wait --timeout 3m

# Deploy KeeperCluster FIRST — ClickHouseCluster will crashloop without it
kubectl apply -f clickhouse/keeper-cluster.yaml
kubectl wait keepercluster clickhouse-keeper -n clickhouse \
  --for=condition=Ready --timeout=5m

# Deploy ClickHouseCluster
kubectl apply -f clickhouse/clickhouse-cluster.yaml

# NodePort service for external access (HTTP :30123, native :30900)
kubectl apply -f clickhouse/clickhouse-service.yaml
```

#### Step 11 — CloudBeaver (optional)

```bash
kubectl apply -f cloudbeaver/manifest.yaml
kubectl -n dwh rollout status deployment/cloudbeaver
```

Access from a Windows-host browser and full connection setup is in the
[CloudBeaver — Web SQL Client](#cloudbeaver--web-sql-client) section below.

---

## CloudBeaver — Web SQL Client

CloudBeaver runs inside the cluster and connects to ClickHouse, Trino, and the
CNPG PostgreSQL using in-cluster DNS. The deployment uses a `Recreate` strategy
because the H2 workspace DB on the ReadWriteOnce PVC cannot be opened by two
pods at once (rolling updates would deadlock the new pod).

### Step-by-step: open CloudBeaver from a Windows browser (k3s-in-WSL)

The k3s NodePort (`30978`) binds inside the WSL VM. Reaching it from the Windows
host depends on WSL's networking mode:

- **WSL mirrored mode + Windows Firewall on (this setup)** — Windows cannot
  reach `<wsl-ip>:30978` directly; the firewall blocks inbound NodePort traffic
  to the WSL VM. The reliable workaround is `kubectl port-forward` (binds in WSL,
  reachable from Windows via mirrored localhost loopback).
- **WSL NAT mode** — `localhost:30978` works directly from Windows via the
  built-in WSL port-forwarder; skip step 2.

#### 1. Make sure CloudBeaver is running (in WSL)

```bash
kubectl -n dwh rollout status deployment/cloudbeaver
kubectl -n dwh get pods -l app=cloudbeaver   # expect a single 1/1 Running pod
```

#### 2. Start a port-forward in WSL

```bash
# Bind on 0.0.0.0 so Windows mirrored localhost can reach it
kubectl -n dwh port-forward --address 0.0.0.0 svc/cloudbeaver 8978:8978
```

Leave this terminal open. To run it in the background:

```bash
nohup kubectl -n dwh port-forward --address 0.0.0.0 svc/cloudbeaver 8978:8978 \
  >/tmp/cb-pf.log 2>&1 &
```

#### 3. Open the URL in your Windows browser

```
http://localhost:8978
```

#### 4. Complete the first-launch wizard

1. Create an admin account (any username/password — persisted in the PVC).
2. Skip the sample connections wizard.
3. Click **☰ → Administration → Connection Management → New Connection** to add
   the connections below.

> **Tip:** if you want CloudBeaver always reachable on `http://localhost:8978`
> without manually starting a port-forward, run the command from step 2 as a
> systemd service, or add a Hyper-V firewall rule for the NodePort range:
> ```powershell
> # PowerShell, as Administrator
> New-NetFirewallHyperVRule -Name "WSL k3s NodePorts" `
>   -DisplayName "WSL k3s NodePorts" -Direction Inbound `
>   -VMCreatorId "{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}" `
>   -LocalPorts 30000-32767 -Protocol TCP
> ```
> Then `http://<wsl-eth0-ip>:30978` works from Windows. Get the WSL IP via
> `wsl hostname -I` from a Windows terminal.

### Connect to ClickHouse

| Field | Value |
|---|---|
| Driver | ClickHouse |
| URL | `jdbc:clickhouse:http://clickhouse-clickhouse-headless.clickhouse.svc.cluster.local:8123/default` |
| Username | `default` |
| Password | *(empty)* |

If URL mode isn't available, use Host/Port with the native TCP port:

| Field | Value |
|---|---|
| Driver | ClickHouse |
| Host | `clickhouse-clickhouse-headless.clickhouse.svc.cluster.local` |
| Port | `9000` |
| Database | `default` |
| Username | `default` |
| Password | *(empty)* |

Click **Test Connection** → **Create**.

**Test queries:**

```sql
SELECT version();                  -- expect 26.x
SHOW DATABASES;
SHOW USERS;                        -- expect: default, operator

CREATE TABLE IF NOT EXISTS default.test (
    id   UInt32,
    val  String
) ENGINE = MergeTree ORDER BY id;

INSERT INTO default.test VALUES (1, 'hello'), (2, 'world');
SELECT * FROM default.test;
DROP TABLE default.test;
```

### Connect to Trino (Iceberg lakehouse)

| Field | Value |
|---|---|
| Driver | Trino |
| JDBC URL | `jdbc:trino://trino.dwh.svc.cluster.local:8080/lakehouse` |
| Username | `trino` |
| Password | *(empty)* |

Click **Test Connection** → **Create**. To browse Iceberg tables, navigate to
**lakehouse → bronze**.

**Test queries:**

```sql
-- Built-in TPC-H benchmark data (no S3 needed)
SELECT COUNT(*) FROM tpch.sf1.orders;

SELECT l_returnflag, SUM(l_extendedprice) AS revenue
FROM tpch.sf1.lineitem
GROUP BY l_returnflag
ORDER BY l_returnflag;

-- Iceberg lakehouse
SHOW SCHEMAS IN lakehouse;
SHOW TABLES IN lakehouse.bronze;
SELECT * FROM lakehouse.bronze.orders LIMIT 10;          -- if lakehouse-test ran

-- Iceberg time travel
SELECT * FROM lakehouse.bronze.orders
FOR VERSION AS OF <snapshot_id>;
```

### Connect to PostgreSQL (CNPG — `polaris-pg`)

This is the metadata store backing Apache Polaris. The `polaris` database is
where Polaris persists realms, catalogs, namespaces, and table metadata.

| Field | Value |
|---|---|
| Driver | PostgreSQL |
| Host | `polaris-pg-rw.dwh.svc.cluster.local` |
| Port | `5432` |
| Database | `polaris` |
| Username | `polaris` |
| Password | *fetch from secret — see below* |

Read-only mirror (use for reporting): host `polaris-pg-ro.dwh.svc.cluster.local`,
same port/credentials.

```bash
# Get the password (paste into CloudBeaver)
kubectl -n dwh get secret polaris-pg-app \
  -o jsonpath='{.data.password}' | base64 -d ; echo
```

Click **Test Connection** → **Create**.

**Test queries:**

```sql
-- Polaris-managed schemas/tables
\dn                              -- or: SELECT schema_name FROM information_schema.schemata;
SELECT table_schema, COUNT(*)
FROM information_schema.tables
WHERE table_schema NOT IN ('pg_catalog','information_schema')
GROUP BY table_schema;

-- Sanity check
SELECT version(), current_database(), current_user;
```

---

## Testing the Lakehouse

### PyIceberg integration test (via Kubernetes Job)

```bash
# Run test
kubectl apply -f test/test-job.yaml

# Watch logs
kubectl logs -n dwh job/lakehouse-test -f

# Cleanup
kubectl delete job lakehouse-test -n dwh
kubectl delete configmap lakehouse-test-script -n dwh
```

Expected output:
```
Connected to Polaris catalog.
Namespace 'bronze' already exists.
Table 'bronze.orders' created.
INSERTing 5 rows into 'bronze.orders'...
INSERT complete.
SELECT * FROM bronze.orders:
------------------------------------------------------------------------------------------
  order_id= 1  customer=Alice    ...  status=shipped  region=EU
  ...
Shipped orders: 3
Table location : s3://lakehouse/bronze/orders
Test PASSED!
```

### Trino SQL

```bash
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

# Via CLI from a temp pod
kubectl run trino-cli --rm -i --restart=Never --image=trinodb/trino:480 \
  -- trino --server "http://trino.dwh.svc.cluster.local:8080" \
     --catalog lakehouse --schema bronze \
     --execute "SHOW TABLES"

# TPC-H test (no S3 needed)
kubectl run trino-cli --rm -i --restart=Never --image=trinodb/trino:480 \
  -- trino --server "http://trino.dwh.svc.cluster.local:8080" \
     --catalog tpch --schema sf1 \
     --execute "SELECT COUNT(*) FROM orders"
```

UI: `http://<node-ip>:30880`

### ClickHouse SQL

```bash
NODE_IP=...

# Via HTTP interface
curl "http://${NODE_IP}:30123/" --data "SELECT version()"

# CREATE + INSERT + SELECT
curl "http://${NODE_IP}:30123/" --data \
  "CREATE TABLE IF NOT EXISTS default.test (id UInt32, val String) ENGINE=MergeTree ORDER BY id"
curl "http://${NODE_IP}:30123/" --data \
  "INSERT INTO default.test VALUES (1,'hello'),(2,'world')"
curl "http://${NODE_IP}:30123/" --data \
  "SELECT * FROM default.test"
```

---

## Polaris REST API Reference

Base URL: `http://<node-ip>:30181` (external) or `http://polaris.dwh.svc.cluster.local:8181` (in-cluster)

```bash
REALM=POLARIS

# Get token
TOKEN=$(curl -sS -X POST "http://localhost:30181/api/catalog/v1/oauth/tokens" \
  -H "Polaris-Realm: $REALM" -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=client_credentials&client_id=root&client_secret=s3cr3t&scope=PRINCIPAL_ROLE:ALL" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

H="-H 'Authorization: Bearer $TOKEN' -H 'Polaris-Realm: $REALM'"

# Management API — catalogs, principals, roles
curl $H http://localhost:30181/api/management/v1/catalogs

# Catalog (Iceberg REST spec) — namespaces, tables
curl $H http://localhost:30181/api/catalog/v1/lakehouse/namespaces
curl $H http://localhost:30181/api/catalog/v1/lakehouse/namespaces/bronze/tables
```

**Two API paths — never mix them:**
- `/api/catalog/v1/` — Iceberg REST spec (used by Spark, Trino, PyIceberg)
- `/api/management/v1/` — Polaris admin API (catalogs, principals, roles)

---

## Credentials (dev only)

| Service | Credential |
|---|---|
| Polaris | `client_id=root`, `client_secret=s3cr3t`, `realm=POLARIS` |
| Ozone S3 | `access-key=ozone`, `secret-key=ozone-secret123` |
| Airflow UI | `admin` / `admin` |
| ClickHouse | user `default`, no password (also `operator` user, see secret `clickhouse-clickhouse`) |
| Trino | user `trino`, no password |
| PostgreSQL (CNPG) | user `polaris`, db `polaris`, password in secret `polaris-pg-app` (`kubectl -n dwh get secret polaris-pg-app -o jsonpath='{.data.password}' \| base64 -d`) |
| CloudBeaver | set on first-launch wizard |

---

## Monitoring

```bash
# All DWH pods
kubectl get pods -n dwh -o wide
kubectl get pods -n clickhouse -o wide

# Polaris logs
kubectl logs -n dwh -l app.kubernetes.io/name=polaris -f

# Trino coordinator logs
kubectl logs -n dwh -l app=trino,component=coordinator -f

# ClickHouse logs
kubectl logs -n clickhouse -l clickhouse.com/role=clickhouse-server -f

# Ozone Manager logs
kubectl logs -n dwh -l app.kubernetes.io/component=om -f
```

---

## Troubleshooting

| Problem | Fix |
|---|---|
| `helm install` fails with "chart not found" on Polaris | Add `--version 1.3.0-incubating` — Helm won't auto-resolve pre-release versions |
| Polaris bootstrap fails with wrong user | Never use `USERNAME` bash var — use `DB_USER` instead |
| PyIceberg `Credential vending was requested but no credentials are available` | Add `"header.X-Iceberg-Access-Delegation": ""` to catalog config (suppresses delegation) |
| Polaris S3 writes going to real AWS (301 redirect) | Set `AWS_ENDPOINT_URL_S3` env var on Polaris pod — `s3.endpoint` in storageConfigInfo is ignored |
| Ozone `getsecret` fails (Kerberos error) | Use static credentials — Ozone S3G in non-secure mode accepts any key/secret |
| Trino property errors on version 480 | See [Trino 480 Property Renames](#trino-480-property-renames) below |
| ClickHouseCluster `unknown field keeperClusterRef.namespace` | Remove `namespace` from `keeperClusterRef` — same-namespace only |
| ClickHouseCluster `unknown field spec.version` | Use `spec.upgradeChannel: "25.8"` instead |
| ClickHouse settings error on user-level settings | Move `max_memory_usage`, `async_insert`, `network_compression_method` to `settings.extraUsersConfig.profiles.default` |
| KeeperCluster `spec.settings.logger_level unknown field` | Use `settings.logger.level` (nested) not `logger_level` (flat) |
| Trino `pending-install` stuck | `kubectl delete secret -n dwh -l owner=helm,name=trino && kubectl delete deploy,svc -n dwh -l app.kubernetes.io/name=trino` |
| ClickHouse NodePort selector wrong | Use label `clickhouse.com/role: clickhouse-server` (found via `kubectl get pod --show-labels`) |
| Trino `AWS_SECRET_ACCESS_KEY` not available in workers | Use top-level `env:` in values.yaml, not `coordinator.extraEnv` / `worker.extraEnv` |
| Trino NodePort not applied | Use top-level `service:` in values.yaml, not `coordinator.service:` |

### Trino 480 Property Renames

Trino 480 renamed several catalog properties. Old → New:

| Old (< 480) | New (480+) |
|---|---|
| `iceberg.rest-catalog.oauth2.client-id` + `oauth2.client-secret` | `iceberg.rest-catalog.oauth2.credential=id:secret` |
| `iceberg.rest-catalog.oauth2.token-endpoint` | `iceberg.rest-catalog.oauth2.server-uri` |
| `s3.access-key` | `s3.aws-access-key` |
| `s3.secret-key` | `s3.aws-secret-key` |
| `iceberg.rest-catalog.additional-header.*` | Removed — set `polaris.realm-context.require-header: "false"` in Polaris |

---

## Reset

```bash
./uninstall.sh && ./install.sh --with-ozone --with-trino --with-clickhouse --with-cloudbeaver --no-spark --no-airflow
```
