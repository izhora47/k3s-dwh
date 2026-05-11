# Data Lakehouse on k3s

Apache Iceberg lakehouse on a single-node k3s cluster. Apache Polaris manages the Iceberg REST catalog,
RustFS provides S3-compatible object storage (replaceable with Apache Ozone), Trino queries the lakehouse
via SQL, and ClickHouse handles OLAP analytics. All components deploy via a single `install.sh` script.

---

## Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│  k3s cluster (single node: aurora, 4 CPU / 24 GB RAM)               │
│                                                                      │
│  namespace: dwh                                                      │
│  ┌─────────────────┐   ┌──────────────────┐   ┌──────────────────┐  │
│  │ Apache Polaris  │   │ CloudNativePG    │   │  RustFS 1.0-beta │  │
│  │ Iceberg REST    │──▶│ PostgreSQL 16    │   │  S3 API  :9000   │  │
│  │ Catalog :8181   │   │ (polaris-pg)     │   │  Console :9001   │  │
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
  → s3://lakehouse/...                  → RustFS S3 API (data files, parquet)
```

**Active S3 backend: RustFS** (`rustfs-svc.dwh.svc.cluster.local:9000`)
Ingress: `https://s3.test.local` (S3 API) / `https://s3-console.test.local` (console UI)

---

## Services & NodePorts

| Service | NodePort | In-cluster DNS |
|---|---|---|
| Apache Polaris | `30181` | `polaris.dwh.svc.cluster.local:8181` |
| RustFS S3 API | — | `rustfs-svc.dwh.svc.cluster.local:9000` (HTTPS via Traefik `s3.test.local`) |
| RustFS Console | — | `rustfs-svc.dwh.svc.cluster.local:9001` (HTTPS via Traefik `s3-console.test.local`) |
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
| `rustfs/rustfs` | `https://charts.rustfs.com` | `0.2.0` (app 1.0.0-beta.2) |
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
├── backup/
│   ├── pg-backup.sh        ← PostgreSQL dump via kubectl exec → local file
│   ├── pg-restore.sh       ← PostgreSQL restore from dump file
│   ├── ch-backup.sh        ← ClickHouse BACKUP DATABASE → RustFS S3
│   └── ch-restore.sh       ← ClickHouse RESTORE DATABASE ← RustFS S3
├── cnpg/
│   ├── pg-cluster.yaml     ← CNPG PostgreSQL cluster (polaris-pg)
│   └── pooler.yaml         ← PgBouncer Pooler CR (rw + ro, transaction mode)
├── polaris/
│   ├── CLAUDE.md           ← Polaris gotchas + auth flow reference
│   ├── README.md           ← Polaris API command reference
│   └── values.yaml         ← Polaris Helm values (S3 endpoint via AWS_ENDPOINT_URL_S3)
├── rustfs/
│   ├── README.md           ← User management, TLS notes, known chart issues
│   └── values.yaml         ← RustFS Helm values (standalone, Traefik TLS ingress)
├── ozone/
│   ├── CLAUDE.md
│   ├── README.md
│   └── values.yaml
├── trino/
│   ├── CLAUDE.md           ← Trino 480 property renames + gotchas
│   ├── README.md           ← Queries reference
│   └── values.yaml         ← Trino catalog config (s3.endpoint for active backend)
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

#### Step 5 — RustFS S3 storage (active backend)

RustFS is the default S3 backend. It runs as a single-node standalone server behind Traefik TLS ingress.

```bash
# 1. Create TLS secret from wildcard cert (*.test.local, valid until May 2028)
kubectl -n dwh create secret tls rustfs-tls \
  --cert=/home/nik/projects/ssl-certs/test.local.crt \
  --key=/home/nik/projects/ssl-certs/test.local.key

# 2. Create S3 credentials secret (reused by Polaris + Trino)
kubectl -n dwh create secret generic ozone-s3-creds \
  --from-literal=access-key="lakehouseadmin" \
  --from-literal=secret-key="Lk@h0use-S3-2026!"

# 3. Deploy RustFS
helm repo add rustfs https://charts.rustfs.com
helm upgrade --install rustfs rustfs/rustfs \
  --version 0.2.0 --namespace dwh --values rustfs/values.yaml --wait --timeout 5m

# 4. Create lakehouse bucket
kubectl run rustfs-init --rm -i --restart=Never -n dwh \
  --image=amazon/aws-cli:latest \
  --env="AWS_ACCESS_KEY_ID=lakehouseadmin" \
  --env="AWS_SECRET_ACCESS_KEY=Lk@h0use-S3-2026!" \
  --env="AWS_DEFAULT_REGION=us-east-1" \
  -- s3 mb s3://lakehouse \
     --endpoint-url http://rustfs-svc.dwh.svc.cluster.local:9000
```

**Hosts entries required** (add to `/etc/hosts` in WSL and Windows `C:\Windows\System32\drivers\etc\hosts`):
```
100.64.193.139  s3.test.local  s3-console.test.local
```

> The chart has a known bug: the default ingress points to the console port (9001) instead of the S3
> API port (9000). After install, patch it:
> ```bash
> kubectl -n dwh patch ingress rustfs --type=json \
>   -p='[{"op":"replace","path":"/spec/rules/0/http/paths/0/backend/service/port/name","value":"endpoint"}]'
> ```

#### Step 5b — Apache Ozone (alternative backend)

Ozone is an S3-compatible + HDFS-compatible object store. Use it instead of RustFS for Hadoop ecosystem integration (ofs:// URIs, Spark with OzoneFileSystem, etc.). For a pure S3 use case, RustFS is simpler.

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

Requires an S3 backend deployed (Step 5 or 5b).

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
**lakehouse → silver**.

**Test queries:**

```sql
-- Built-in TPC-H benchmark data (no S3 needed)
SELECT COUNT(*) FROM tpch.sf1.orders;

SELECT l_returnflag, SUM(l_extendedprice) AS revenue
FROM tpch.sf1.lineitem
GROUP BY l_returnflag
ORDER BY l_returnflag;

-- Iceberg lakehouse (RustFS-backed)
SHOW SCHEMAS IN lakehouse;
SHOW TABLES IN lakehouse.silver;
SELECT * FROM lakehouse.silver.test_orders LIMIT 10;

-- Iceberg time travel
SELECT * FROM lakehouse.silver.test_orders
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

## PostgreSQL Connection Pooling (PgBouncer)

PgBouncer is deployed as a CNPG `Pooler` CR — managed by the CloudNativePG operator, not
as a standalone deployment. This is the correct approach: the operator handles auth sync,
automatic failover tracking, and lifecycle management.

### Why PgBouncer should be part of CNPG (not standalone)

| Concern | CNPG Pooler CR | Standalone PgBouncer |
|---|---|---|
| Auth sync | Automatic — operator reads `pg_shadow` | Manual — update config on password rotation |
| Failover | Operator rewires to new primary automatically | Manual config update required |
| Lifecycle | Managed alongside cluster | Separate deployment to maintain |
| TLS | Operator-managed certificates | Manual certificate wiring |

### Poolers deployed

| Service | Type | Port | Use for |
|---|---|---|---|
| `polaris-pg-pooler-rw.dwh.svc.cluster.local` | rw → primary | 5432 | writes + reads (Superset, services) |
| `polaris-pg-pooler-ro.dwh.svc.cluster.local` | ro → replicas | 5432 | read-only analytics (falls back to primary when single instance) |

Both run in **transaction pool mode** — optimal for stateless apps that open many short-lived
connections. Not suitable for: advisory locks, `LISTEN`/`NOTIFY`, temp tables spanning statements.

### Deploy

```bash
kubectl apply -f cnpg/pooler.yaml
kubectl rollout status deployment/polaris-pg-pooler-rw -n dwh
kubectl rollout status deployment/polaris-pg-pooler-ro -n dwh
```

### Connect via pooler (CNPG TLS required)

The CNPG pooler requires `sslmode=require`. Direct test:

```bash
PGPASSWORD=$(kubectl get secret polaris-pg-app -n dwh \
  -o jsonpath='{.data.password}' | base64 -d)

kubectl exec -n dwh polaris-pg-1 -c postgres -- \
  env PGPASSWORD="$PGPASSWORD" \
  psql "host=polaris-pg-pooler-rw.dwh.svc.cluster.local sslmode=require user=polaris dbname=polaris" \
  -c "SELECT current_database(), now();"
```

### Add a new database for an external service (e.g. Superset)

```bash
# Create on the primary using peer auth (no password needed for superuser)
kubectl exec -n dwh polaris-pg-1 -c postgres -- psql -U postgres -c "
  CREATE USER superset WITH PASSWORD 'Sup3rset-2026!';
  CREATE DATABASE superset OWNER superset;"

# Superset connection string (via pooler):
# postgresql://superset:Sup3rset-2026!@polaris-pg-pooler-rw.dwh.svc.cluster.local:5432/superset?sslmode=require
```

---

## ClickHouse — Scaling and Enterprise Readiness

### Current configuration

Single server: `shards: 1 × replicas: 1` + `KeeperCluster replicas: 1`.
No HA, no failover, no horizontal scale.

### For 1 GB/day ingestion + 2 TB total

**ClickHouse handles this comfortably on a single server:**
- 1 GB/day raw ≈ 73–146 GB/year on disk after LZ4 compression (5–10× typical for events/logs)
- 2 TB raw ≈ 200–400 GB compressed — fits on a single 1 TB SSD
- `async_insert` is already enabled — built for high-frequency small-batch ingestion
- No sharding needed at this scale

**What to grow first:**
1. **PVC size** — current 20 Gi is a dev limit. For 2 TB: `storage: 1Ti`
2. **RAM** — bump `limits.memory` from 4Gi to 16–32Gi (mark cache + query memory)
3. **CPU** — bump `limits.cpu` from 2 to 8+ for concurrent analytics queries

### Path to HA (production)

Change `clickhouse/clickhouse-cluster.yaml`:
```yaml
shards: 1       # 2+ for data partitioning; 1 is fine for 2 TB
replicas: 2     # 2 = HA — full data copy on each replica
```

Change `clickhouse/keeper-cluster.yaml`:
```yaml
replicas: 3     # always odd for quorum
```

**Shards vs replicas:** at 2 TB, `replicas: 2` (HA without data partitioning) is right.
Add shards only when a single node's disk or write throughput becomes the bottleneck.

### Enterprise readiness at 1 GB/day / 2 TB

| Requirement | Current state | Production fix |
|---|---|---|
| Data volume (2 TB) | ✓ Single node handles 10+ TB | Expand PVC to 1Ti+ |
| Ingestion (1 GB/day) | ✓ async_insert configured | Tune `async_insert_max_data_size` |
| HA / failover | ✗ Single replica | replicas: 2, Keeper: 3 |
| Authentication | ✗ No password | Add users with `password_sha256_hex` |
| TLS | ✗ Ports 8123/9000 unencrypted | Configure TLS in `extraConfig` |
| Backups | ✓ Scripts in `backup/` (→ RustFS) | Add cron schedule |
| Monitoring | ✗ No metrics | Enable `metrics.enable: true` |

**Verdict:** ClickHouse itself is enterprise-grade software. At 1 GB/day + 2 TB it's well within
its comfort zone. The current k3s deployment needs HA replicas, auth, and TLS before
it's production-ready, but none of these require changing the data model or storage engine.

---

## RustFS User Management

RustFS uses the MinIO-compatible Admin API. The `mc` (MinIO client) image is the easiest way to manage users from within the cluster.

### Create a user and assign access

```bash
kubectl run mc-tmp --rm -i --restart=Never -n dwh \
  --image=minio/mc:latest \
  --command -- /bin/sh -c "
    mc alias set rustfs http://rustfs-svc.dwh.svc.cluster.local:9000 \
      lakehouseadmin 'Lk@h0use-S3-2026!' >/dev/null

    mc admin user add rustfs alice 'Al!ce-S3-2026!'
    mc admin policy attach rustfs readwrite --user alice
    mc admin user info rustfs alice"
```

Built-in policies: `readonly`, `readwrite`, `writeonly`, `consoleAdmin`, `diagnostics`.

### Create a service account (separate access key for an app)

```bash
kubectl run mc-tmp --rm -i --restart=Never -n dwh \
  --image=minio/mc:latest \
  --command -- /bin/sh -c "
    mc alias set rustfs http://rustfs-svc.dwh.svc.cluster.local:9000 \
      lakehouseadmin 'Lk@h0use-S3-2026!' >/dev/null
    mc admin accesskey create rustfs alice"
```

Output: a new `Access Key` + `Secret Key` pair scoped to `alice`'s policies.

### Bucket-scoped policy (least privilege)

```bash
kubectl run mc-tmp --rm -i --restart=Never -n dwh \
  --image=minio/mc:latest \
  --command -- /bin/sh -c "
    mc alias set rustfs http://rustfs-svc.dwh.svc.cluster.local:9000 \
      lakehouseadmin 'Lk@h0use-S3-2026!' >/dev/null

    cat > /tmp/lakehouse-rw.json << 'EOF'
{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",
\"Action\":[\"s3:GetObject\",\"s3:PutObject\",\"s3:DeleteObject\",\"s3:ListBucket\"],
\"Resource\":[\"arn:aws:s3:::lakehouse\",\"arn:aws:s3:::lakehouse/*\"]}]}
EOF
    mc admin policy create rustfs lakehouse-rw /tmp/lakehouse-rw.json
    mc admin policy attach rustfs lakehouse-rw --user alice
    mc admin user info rustfs alice"
```

### List / remove users

```bash
kubectl run mc-tmp --rm -i --restart=Never -n dwh \
  --image=minio/mc:latest \
  --command -- /bin/sh -c "
    mc alias set rustfs http://rustfs-svc.dwh.svc.cluster.local:9000 \
      lakehouseadmin 'Lk@h0use-S3-2026!' >/dev/null
    mc admin user list rustfs
    mc admin user remove rustfs alice"
```

> For full reference (service accounts, custom policies, AWS CLI alternative) see `rustfs/README.md`.

---

## Switching S3 Backend (RustFS ↔ Ozone)

Three files control which S3 backend is active. Change all three together when switching.

### RustFS → Ozone

**1. Polaris** (`polaris/values.yaml` → `extraEnv`):
```yaml
- name: AWS_ENDPOINT_URL_S3
  value: "http://ozone-s3g-rest.dwh.svc.cluster.local:9878"   # ← Ozone
# value: "http://rustfs-svc.dwh.svc.cluster.local:9000"       # RustFS
```

**2. Trino** (`trino/values.yaml` → `catalogs.lakehouse`):
```
s3.endpoint=http://ozone-s3g-rest.dwh.svc.cluster.local:9878   # ← Ozone
# s3.endpoint=http://rustfs-svc.dwh.svc.cluster.local:9000     # RustFS
```

**3. S3 credentials secret** (`ozone-s3-creds`):
```bash
# Ozone credentials (non-secure mode — any value works)
kubectl -n dwh create secret generic ozone-s3-creds \
  --from-literal=access-key="ozone" \
  --from-literal=secret-key="ozone-secret123" \
  --dry-run=client -o yaml | kubectl apply -f -
```

**4. Apply:**
```bash
helm upgrade polaris polaris/polaris --version 1.3.0-incubating \
  -n dwh --values polaris/values.yaml
helm upgrade trino trino/trino --version 1.42.2 \
  -n dwh --values trino/values.yaml
```

### Ozone → RustFS

**1. Polaris** (`polaris/values.yaml` → `extraEnv`):
```yaml
- name: AWS_ENDPOINT_URL_S3
  value: "http://rustfs-svc.dwh.svc.cluster.local:9000"        # ← RustFS
```

**2. Trino** (`trino/values.yaml` → `catalogs.lakehouse`):
```
s3.endpoint=http://rustfs-svc.dwh.svc.cluster.local:9000       # ← RustFS
```

**3. S3 credentials secret:**
```bash
kubectl -n dwh create secret generic ozone-s3-creds \
  --from-literal=access-key="lakehouseadmin" \
  --from-literal=secret-key="Lk@h0use-S3-2026!" \
  --dry-run=client -o yaml | kubectl apply -f -
```

**4. Apply** (same helm upgrade commands as above).

> **Why one secret name for both?** Polaris and Trino reference `ozone-s3-creds` by name.
> Keeping the name constant means only the secret's content changes when switching backends —
> no Helm value edits for the secret reference itself.

### Test after switching

```bash
# Trino quick smoke test
kubectl run trino-test --rm -i --restart=Never -n dwh --image=trinodb/trino:480 -- \
  trino --server http://trino.dwh.svc.cluster.local:8080 \
        --execute "SHOW SCHEMAS IN lakehouse; SELECT COUNT(*) FROM tpch.sf1.orders"
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
# Via CLI from a temp pod — TPC-H (no S3 needed)
kubectl run trino-test --rm -i --restart=Never -n dwh --image=trinodb/trino:480 -- \
  trino --server http://trino.dwh.svc.cluster.local:8080 \
        --execute "SELECT COUNT(*) AS orders FROM tpch.sf1.orders"
# Expected: 1500000

# List lakehouse schemas and tables
kubectl run trino-test --rm -i --restart=Never -n dwh --image=trinodb/trino:480 -- \
  trino --server http://trino.dwh.svc.cluster.local:8080 \
        --execute "SHOW SCHEMAS IN lakehouse; SHOW TABLES IN lakehouse.silver"

# Full Iceberg write + read test (creates silver.trino_test table in RustFS)
kubectl run trino-test --rm -i --restart=Never -n dwh --image=trinodb/trino:480 -- \
  trino --server http://trino.dwh.svc.cluster.local:8080 \
        --execute "
          CREATE TABLE IF NOT EXISTS lakehouse.silver.trino_test
            (id INTEGER, name VARCHAR, amount DOUBLE)
          WITH (format='PARQUET');
          INSERT INTO lakehouse.silver.trino_test VALUES (1,'Alice',99.99),(2,'Bob',149.50);
          SELECT * FROM lakehouse.silver.trino_test ORDER BY id"
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

## Backup and Restore

Scripts in `backup/`. No extra tools required — uses `kubectl exec` and ClickHouse native SQL.

### Directory layout

```
backup/
├── pg-backup.sh    ← PostgreSQL: pg_dump via kubectl exec → local .dump file
├── pg-restore.sh   ← PostgreSQL: pg_restore streamed into primary pod
├── ch-backup.sh    ← ClickHouse: BACKUP DATABASE ... TO S3 (RustFS)
├── ch-restore.sh   ← ClickHouse: RESTORE DATABASE ... FROM S3 (RustFS) + list
└── dumps/          ← PostgreSQL dump files (created on first backup)
```

### PostgreSQL backup

```bash
# Backup 'polaris' database (default)
./backup/pg-backup.sh

# Backup a specific database
./backup/pg-backup.sh superset

# Backup all user databases
./backup/pg-backup.sh all

# Backup to a custom directory
./backup/pg-backup.sh polaris /mnt/nfs/pg-backups
```

Output: `backup/dumps/pg-<database>-<YYYYMMDD-HHMMSS>.dump` (compressed custom format, ~20 KB for Polaris metadata)

### PostgreSQL restore

```bash
# List available dumps
ls backup/dumps/

# Restore to the same database name (asks for confirmation — drops existing data)
./backup/pg-restore.sh backup/dumps/pg-polaris-20260511-110320.dump

# Restore to a different database (safe — original stays intact)
./backup/pg-restore.sh backup/dumps/pg-polaris-20260511-110320.dump polaris_test
```

> Uses `kubectl exec -c postgres` peer auth (postgres OS user → postgres superuser).
> No password needed, works even with `enableSuperuserAccess: false`.

### ClickHouse backup

Backs up directly to RustFS S3 at `s3://lakehouse/ch-backups/<database>/<timestamp>/`.

```bash
# Backup 'default' database
./backup/ch-backup.sh

# Backup specific database
./backup/ch-backup.sh mydb

# Backup all user databases
./backup/ch-backup.sh all
```

### ClickHouse restore

```bash
# List available backups (reads from system.backups)
./backup/ch-restore.sh

# Restore 'default' from a specific timestamp (drops and recreates the database)
./backup/ch-restore.sh default 20260511-110326

# Restore into a different name (keeps original intact)
./backup/ch-restore.sh default 20260511-110326 default_restored
```

### Schedule daily backups (cron)

```bash
# Edit crontab
crontab -e

# Add these lines:
# PostgreSQL — daily at 02:00
0 2 * * * cd /home/nik/projects/k3s/dwh && ./backup/pg-backup.sh all >> /tmp/pg-backup.log 2>&1

# ClickHouse — daily at 03:00
0 3 * * * cd /home/nik/projects/k3s/dwh && ./backup/ch-backup.sh all >> /tmp/ch-backup.log 2>&1
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
| RustFS S3 (active) | `access-key=lakehouseadmin`, `secret-key=Lk@h0use-S3-2026!` |
| Ozone S3 (alternate) | `access-key=ozone`, `secret-key=ozone-secret123` |
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
| Polaris S3 writes going to real AWS (301 redirect) | Set `AWS_ENDPOINT_URL_S3` env var on Polaris pod — `s3.endpoint` in storageConfigInfo is silently ignored |
| RustFS `access_key` validation failure during helm install | Chart rejects default `rustfsadmin` and empty keys — use a custom key (e.g. `lakehouseadmin`) |
| RustFS S3 ingress routes to console (9001) instead of S3 API (9000) | Chart bug: patch after install — `kubectl -n dwh patch ingress rustfs --type=json -p='[{"op":"replace","path":"/spec/rules/0/http/paths/0/backend/service/port/name","value":"endpoint"}]'` |
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
./uninstall.sh && ./install.sh --with-trino --with-clickhouse --with-cloudbeaver --no-spark --no-airflow
```

> `--with-ozone` is not needed when using RustFS. RustFS is deployed manually via Helm
> (see Step 5) because it needs the TLS secret and credentials secret created first.
