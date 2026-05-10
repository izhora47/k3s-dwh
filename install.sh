#!/usr/bin/env bash
# =============================================================================
# Data Lakehouse Install Script (Helm-based)
# Components:
#   Core:        CNPG (PostgreSQL) + Apache Polaris (Iceberg REST catalog)
#   Storage:     Apache Ozone (S3) — enabled with --with-ozone
#   Compute:     Apache Spark Operator + Apache Airflow
#   SQL:         Trino — enabled with --with-trino (requires Ozone)
#   OLAP:        ClickHouse — enabled with --with-clickhouse
#   UI:          CloudBeaver — enabled with --with-cloudbeaver
#   UI:          pgAdmin4 — enabled with --with-pgadmin
#   All-in:      --full (enables all optional components)
# Target: k3s single-node cluster
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="dwh"
REALM="POLARIS"
WITH_OZONE=false
WITH_TRINO=false
WITH_CLICKHOUSE=false
WITH_CLOUDBEAVER=false
WITH_PGADMIN=false
WITH_SPARK=true
WITH_AIRFLOW=true

for arg in "$@"; do
  case $arg in
    --with-ozone)        WITH_OZONE=true ;;
    --with-trino)        WITH_TRINO=true; WITH_OZONE=true ;;
    --with-clickhouse)   WITH_CLICKHOUSE=true ;;
    --with-cloudbeaver)  WITH_CLOUDBEAVER=true ;;
    --with-pgadmin)      WITH_PGADMIN=true ;;
    --no-spark)          WITH_SPARK=false ;;
    --no-airflow)        WITH_AIRFLOW=false ;;
    --full)              WITH_OZONE=true; WITH_TRINO=true; WITH_CLICKHOUSE=true; WITH_CLOUDBEAVER=true; WITH_PGADMIN=true ;;
  esac
done

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ── Prerequisites ─────────────────────────────────────────────────────────────
info "Checking prerequisites..."
command -v kubectl >/dev/null || error "kubectl not found"
command -v helm    >/dev/null || error "helm not found"
command -v openssl >/dev/null || error "openssl not found"
kubectl cluster-info &>/dev/null || error "Cannot reach Kubernetes cluster"
success "Prerequisites OK"

# ── Step 1: Namespace ─────────────────────────────────────────────────────────
info "Creating namespace '$NAMESPACE'..."
kubectl apply -f "$SCRIPT_DIR/namespace.yaml"
success "Namespace created."

# ── Step 2: CloudNativePG operator ────────────────────────────────────────────
info "Adding CloudNativePG Helm repo..."
helm repo add cnpg https://cloudnative-pg.github.io/charts --force-update
helm repo update cnpg

info "Installing CloudNativePG operator..."
helm upgrade --install cnpg cnpg/cloudnative-pg \
  --namespace cnpg-system \
  --create-namespace \
  --wait --timeout 5m
success "CloudNativePG operator installed."

# ── Step 3: PostgreSQL cluster for Polaris ────────────────────────────────────
info "Deploying PostgreSQL cluster (polaris-pg)..."
kubectl apply -f "$SCRIPT_DIR/cnpg/pg-cluster.yaml"

info "Waiting for PostgreSQL cluster to be ready (~2 min)..."
for i in $(seq 1 60); do
  PHASE=$(kubectl get cluster polaris-pg -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  if [ "$PHASE" = "Cluster in healthy state" ]; then
    success "PostgreSQL cluster is healthy."
    break
  fi
  if [ "$i" -eq 60 ]; then error "PostgreSQL cluster did not become healthy in time."; fi
  echo -n "."
  sleep 5
done

# ── Step 4: Polaris secrets ────────────────────────────────────────────────────
info "Creating Polaris persistence secret from CNPG credentials..."
JDBC_URL="jdbc:postgresql://polaris-pg-rw.${NAMESPACE}.svc.cluster.local:5432/polaris"

kubectl -n "$NAMESPACE" delete secret polaris-persistence --ignore-not-found
kubectl -n "$NAMESPACE" create secret generic polaris-persistence \
  --from-literal=username="$(kubectl get secret polaris-pg-app -n "$NAMESPACE" -o jsonpath='{.data.username}' | base64 -d)" \
  --from-literal=password="$(kubectl get secret polaris-pg-app -n "$NAMESPACE" -o jsonpath='{.data.password}' | base64 -d)" \
  --from-literal=jdbcUrl="$JDBC_URL"
success "Persistence secret created."

info "Creating RSA token broker secret..."
kubectl -n "$NAMESPACE" delete secret polaris-token-broker --ignore-not-found
tmpdir="$(mktemp -d)"
openssl genrsa -out "${tmpdir}/private.pem" 2048 2>/dev/null
openssl rsa -in "${tmpdir}/private.pem" -pubout -out "${tmpdir}/public.pem" 2>/dev/null
printf "%s" "secret" > "${tmpdir}/symmetric.key"
kubectl -n "$NAMESPACE" create secret generic polaris-token-broker \
  --from-file="${tmpdir}/private.pem" \
  --from-file="${tmpdir}/public.pem" \
  --from-file="${tmpdir}/symmetric.key"
rm -rf "${tmpdir}"
success "Token broker secret created."

# ── Step 5: Apache Ozone (optional) ───────────────────────────────────────────
if [ "$WITH_OZONE" = "true" ]; then
  info "Adding Apache Ozone Helm repo..."
  helm repo add ozone https://apache.github.io/ozone-helm-charts/ --force-update
  helm repo update ozone

  info "Installing Apache Ozone..."
  helm upgrade --install ozone ozone/ozone \
    --version 0.2.0 \
    --namespace "$NAMESPACE" \
    --values "$SCRIPT_DIR/ozone/values.yaml" \
    --wait --timeout 10m
  success "Apache Ozone deployed."

  info "Bootstrapping Ozone: creating S3 bucket 'lakehouse'..."
  OM_POD=$(kubectl get pod -n "$NAMESPACE" -l app.kubernetes.io/component=om -o jsonpath='{.items[0].metadata.name}')
  kubectl exec -n "$NAMESPACE" "$OM_POD" -- \
    ozone sh bucket create /s3v/lakehouse --layout OBJECT_STORE 2>/dev/null \
    || warn "Bucket 'lakehouse' may already exist."
  success "Ozone bootstrap complete."

  info "Creating Ozone S3 credentials secret..."
  # 'ozone s3 getsecret' requires Kerberos security (not enabled in dev mode).
  # In non-secure Ozone, S3G accepts any credentials — use static dev values.
  # For production with Kerberos, replace with: ozone s3 getsecret -u trino
  kubectl -n "$NAMESPACE" delete secret ozone-s3-creds --ignore-not-found
  kubectl -n "$NAMESPACE" create secret generic ozone-s3-creds \
    --from-literal=access-key="ozone" \
    --from-literal=secret-key="ozone-secret123"
  success "Ozone S3 credentials secret created (static dev credentials)."
else
  info "Skipping Ozone (use --with-ozone or --full to include it)."
fi

# ── Step 6: Apache Polaris ─────────────────────────────────────────────────────
info "Adding Apache Polaris Helm repo..."
helm repo add polaris https://downloads.apache.org/polaris/helm-chart --force-update
helm repo update polaris

info "Installing Apache Polaris..."
helm upgrade --install polaris polaris/polaris \
  --namespace "$NAMESPACE" \
  --values "$SCRIPT_DIR/polaris/values.yaml" \
  --version 1.3.0-incubating \
  --wait --timeout 5m
success "Apache Polaris deployed."

# ── Step 7: Bootstrap Polaris realm ───────────────────────────────────────────
info "Bootstrapping Polaris realm '$REALM'..."

DB_JDBC=$(kubectl get secret polaris-persistence -n "$NAMESPACE" -o json | python3 -c "import sys,json,base64; s=json.load(sys.stdin); print(base64.b64decode(s['data']['jdbcUrl']).decode())")
DB_USER=$(kubectl get secret polaris-persistence -n "$NAMESPACE" -o json | python3 -c "import sys,json,base64; s=json.load(sys.stdin); print(base64.b64decode(s['data']['username']).decode())")
DB_PASS=$(kubectl get secret polaris-persistence -n "$NAMESPACE" -o json | python3 -c "import sys,json,base64; s=json.load(sys.stdin); print(base64.b64decode(s['data']['password']).decode())")

kubectl -n "$NAMESPACE" run polaris-bootstrap --rm -i --restart=Never \
  --image=apache/polaris-admin-tool:1.3.0-incubating \
  --env="QUARKUS_DATASOURCE_JDBC_URL=$DB_JDBC" \
  --env="QUARKUS_DATASOURCE_USERNAME=$DB_USER" \
  --env="QUARKUS_DATASOURCE_PASSWORD=$DB_PASS" \
  -- bootstrap -r "$REALM" -c "$REALM,root,s3cr3t" -p \
  2>/dev/null || warn "Bootstrap may have already been done."
success "Polaris realm bootstrapped."

# ── Step 8: Create catalog, namespace ─────────────────────────────────────────
info "Creating Polaris catalog 'lakehouse'..."
sleep 5

POLARIS_POD=$(kubectl get pod -n "$NAMESPACE" -l app.kubernetes.io/name=polaris -o jsonpath='{.items[0].metadata.name}')

TOKEN=$(kubectl exec -n "$NAMESPACE" "$POLARIS_POD" -- \
  curl -sS -X POST "http://localhost:8181/api/catalog/v1/oauth/tokens" \
    -H "Polaris-Realm: $REALM" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=client_credentials&client_id=root&client_secret=s3cr3t&scope=PRINCIPAL_ROLE:ALL" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])" 2>/dev/null || echo "")

if [ -z "$TOKEN" ]; then
  warn "Could not obtain Polaris OAuth token. Manual bootstrap required."
else
  if [ "$WITH_OZONE" = "true" ]; then
    CATALOG_PAYLOAD='{
      "catalog": {
        "name": "lakehouse",
        "type": "INTERNAL",
        "properties": {"default-base-location": "s3://lakehouse/"},
        "storageConfigInfo": {
          "storageType": "S3",
          "allowedLocations": ["s3://lakehouse/"],
          "s3.endpoint": "http://ozone-s3g-rest.dwh.svc.cluster.local:9878",
          "s3.path-style-access": "true",
          "stsUnavailable": true,
          "pathStyleAccess": true
        }
      }
    }'
    NS_PAYLOAD='{"namespace":["bronze"],"properties":{"location":"s3://lakehouse/bronze"}}'
  else
    CATALOG_PAYLOAD='{
      "catalog": {
        "name": "lakehouse",
        "type": "INTERNAL",
        "properties": {"default-base-location": "file:///tmp/lakehouse-data"},
        "storageConfigInfo": {
          "storageType": "FILE",
          "allowedLocations": ["file:///"]
        }
      }
    }'
    NS_PAYLOAD='{"namespace":["bronze"],"properties":{"location":"file:///tmp/lakehouse-data/bronze"}}'
  fi

  kubectl exec -n "$NAMESPACE" "$POLARIS_POD" -- \
    curl -sS -X POST "http://localhost:8181/api/management/v1/catalogs" \
      -H "Authorization: Bearer $TOKEN" -H "Polaris-Realm: $REALM" \
      -H "Content-Type: application/json" \
      -d "$CATALOG_PAYLOAD" 2>/dev/null | grep -q '"name"' \
    && success "Catalog 'lakehouse' created." \
    || warn "Catalog creation may have failed or already exists."

  kubectl exec -n "$NAMESPACE" "$POLARIS_POD" -- \
    curl -sS -X POST "http://localhost:8181/api/catalog/v1/lakehouse/namespaces" \
      -H "Authorization: Bearer $TOKEN" -H "Polaris-Realm: $REALM" \
      -H "Content-Type: application/json" \
      -d "$NS_PAYLOAD" 2>/dev/null | grep -q '"namespace"' \
    && success "Namespace 'bronze' created." \
    || warn "Namespace creation may have failed or already exists."
fi

# ── Step 9: Spark Kubernetes Operator ─────────────────────────────────────────
if [ "$WITH_SPARK" = "true" ]; then
  info "Adding Apache Spark Kubernetes Operator Helm repo..."
  helm repo add spark https://apache.github.io/spark-kubernetes-operator --force-update
  helm repo update spark

  info "Installing Spark Kubernetes Operator..."
  helm upgrade --install spark-kubernetes-operator spark/spark-kubernetes-operator \
    --version 1.5.0 \
    --namespace spark-operator \
    --create-namespace \
    --values "$SCRIPT_DIR/spark/values.yaml" \
    --wait --timeout 5m
  success "Spark Kubernetes Operator deployed."
else
  info "Skipping Spark Operator (--no-spark passed)."
fi

# ── Step 10: Apache Airflow ────────────────────────────────────────────────────
if [ "$WITH_AIRFLOW" = "true" ]; then
  info "Adding Apache Airflow Helm repo..."
  helm repo add apache-airflow https://airflow.apache.org --force-update
  helm repo update apache-airflow

  info "Creating Airflow namespace and DAGs ConfigMap..."
  kubectl create namespace airflow --dry-run=client -o yaml | kubectl apply -f -
  kubectl create configmap airflow-dags \
    --from-file="$SCRIPT_DIR/airflow/dags/" \
    -n airflow \
    --dry-run=client -o yaml | kubectl apply -f -

  info "Installing Apache Airflow..."
  helm upgrade --install airflow apache-airflow/airflow \
    --version 1.19.0 \
    --namespace airflow \
    --values "$SCRIPT_DIR/airflow/values.yaml" \
    --wait --timeout 10m
  success "Apache Airflow deployed."
else
  info "Skipping Airflow (--no-airflow passed)."
fi

# ── Step 11: ClickHouse (optional) ────────────────────────────────────────────
if [ "$WITH_CLICKHOUSE" = "true" ]; then
  info "Creating ClickHouse namespace..."
  kubectl create namespace clickhouse --dry-run=client -o yaml | kubectl apply -f -

  info "Installing ClickHouse Operator (official ClickHouse Inc, v0.0.4)..."
  helm upgrade --install clickhouse-operator \
    "https://github.com/ClickHouse/clickhouse-operator/releases/download/v0.0.4/clickhouse-operator-helm-0.0.4.tgz" \
    --namespace clickhouse \
    --values "$SCRIPT_DIR/clickhouse/values.yaml" \
    --wait --timeout 5m
  success "ClickHouse Operator installed."

  info "Deploying KeeperCluster (ClickHouse Keeper)..."
  kubectl apply -f "$SCRIPT_DIR/clickhouse/keeper-cluster.yaml"

  info "Waiting for KeeperCluster to be ready..."
  for i in $(seq 1 60); do
    READY=$(kubectl get keepercluster clickhouse-keeper -n clickhouse \
      -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    if [ "$READY" = "1" ]; then
      success "KeeperCluster is ready."
      break
    fi
    if [ "$i" -eq 60 ]; then
      warn "KeeperCluster did not become ready in time. Deploying ClickHouseCluster anyway."
    fi
    echo -n "."
    sleep 5
  done

  info "Deploying ClickHouseCluster..."
  kubectl apply -f "$SCRIPT_DIR/clickhouse/clickhouse-cluster.yaml"

  info "Waiting for ClickHouseCluster to be ready (~3 min)..."
  for i in $(seq 1 60); do
    READY=$(kubectl get clickhousecluster clickhouse -n clickhouse \
      -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    if [ "$READY" = "1" ]; then
      success "ClickHouseCluster is ready."
      break
    fi
    if [ "$i" -eq 60 ]; then
      warn "ClickHouseCluster did not become ready in time. Check 'kubectl get pods -n clickhouse'."
    fi
    echo -n "."
    sleep 5
  done

  info "Applying ClickHouse NodePort service..."
  kubectl apply -f "$SCRIPT_DIR/clickhouse/clickhouse-service.yaml"
  success "ClickHouse NodePort service applied."
else
  info "Skipping ClickHouse (use --with-clickhouse or --full to include it)."
fi

# ── Step 12: Trino (optional, requires Ozone) ─────────────────────────────────
if [ "$WITH_TRINO" = "true" ]; then
  info "Adding Trino Helm repo..."
  helm repo add trino https://trinodb.github.io/charts --force-update
  helm repo update trino

  info "Installing Trino..."
  helm upgrade --install trino trino/trino \
    --version 1.42.2 \
    --namespace "$NAMESPACE" \
    --values "$SCRIPT_DIR/trino/values.yaml" \
    --wait --timeout 5m
  success "Trino deployed."
else
  info "Skipping Trino (use --with-trino or --full to include it)."
fi

# ── Step 13: CloudBeaver (optional) ───────────────────────────────────────────
if [ "$WITH_CLOUDBEAVER" = "true" ]; then
  info "Deploying CloudBeaver..."
  kubectl apply -f "$SCRIPT_DIR/cloudbeaver/manifest.yaml"
  success "CloudBeaver deployed."

  info "Waiting for CloudBeaver to be ready..."
  kubectl rollout status deployment/cloudbeaver -n "$NAMESPACE" --timeout=3m \
    && success "CloudBeaver is ready." \
    || warn "CloudBeaver rollout timed out. Check 'kubectl get pods -n $NAMESPACE'."
else
  info "Skipping CloudBeaver (use --with-cloudbeaver or --full to include it)."
fi

# ── Step 14: pgAdmin4 (optional) ──────────────────────────────────────────────
if [ "$WITH_PGADMIN" = "true" ]; then
  info "Adding runix (pgAdmin4) Helm repo..."
  helm repo add runix https://helm.runix.net --force-update
  helm repo update runix

  info "Installing pgAdmin4..."
  helm upgrade --install pgadmin runix/pgadmin4 \
    --version 1.62.0 \
    --namespace "$NAMESPACE" \
    --values "$SCRIPT_DIR/pgadmin/values.yaml" \
    --wait --timeout 3m
  success "pgAdmin4 deployed."
else
  info "Skipping pgAdmin4 (use --with-pgadmin or --full to include it)."
fi

# ── Done ──────────────────────────────────────────────────────────────────────
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "<node-ip>")

echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Data Lakehouse installed successfully!${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
echo ""
echo "  Polaris REST API  : http://${NODE_IP}:30181"
if [ "$WITH_AIRFLOW" = "true" ]; then
  echo "  Airflow UI        : http://${NODE_IP}:30080  (admin/admin)"
fi
if [ "$WITH_OZONE" = "true" ]; then
  echo "  Ozone S3 Gateway  : http://${NODE_IP}:30878"
fi
if [ "$WITH_TRINO" = "true" ]; then
  echo "  Trino UI          : http://${NODE_IP}:30880"
  echo "  Trino JDBC        : jdbc:trino://${NODE_IP}:30880/lakehouse"
fi
if [ "$WITH_CLICKHOUSE" = "true" ]; then
  echo "  ClickHouse HTTP   : http://${NODE_IP}:30123  (NodePort)"
  echo "  ClickHouse native : ${NODE_IP}:30900"
fi
if [ "$WITH_CLOUDBEAVER" = "true" ]; then
  echo "  CloudBeaver UI    : http://${NODE_IP}:30978  (complete setup wizard on first visit)"
fi
if [ "$WITH_PGADMIN" = "true" ]; then
  echo "  pgAdmin4 UI       : http://${NODE_IP}:30543  (admin@lakehouse.local / admin123)"
fi
echo ""
echo "  Lakehouse test (create table + INSERT + SELECT):"
echo "    kubectl apply -f test/test-job.yaml"
echo ""
echo "  Trino lakehouse test (requires --with-trino):"
echo "    kubectl run trino-test --rm -i --restart=Never --image=trinodb/trino:480 \\"
echo "      --command -- trino --server http://trino.dwh.svc.cluster.local:8080 \\"
echo "      --catalog lakehouse --schema bronze \\"
echo "      --execute \"SHOW TABLES\""
echo ""
echo "  See README.md for full usage."
