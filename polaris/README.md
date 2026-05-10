# Apache Polaris — Deployment Commands

Polaris is deployed via the official Helm chart into the `dwh` namespace.
It uses CNPG PostgreSQL for persistence and Apache Ozone for S3 storage.

## Prerequisites

- CNPG PostgreSQL cluster `polaris-pg` running in `dwh` namespace
- Ozone deployed and S3 Gateway accessible

## 1. Create Secrets

### Persistence secret (from CNPG credentials)

```bash
JDBC_URL="jdbc:postgresql://polaris-pg-rw.dwh.svc.cluster.local:5432/polaris"

kubectl -n dwh create secret generic polaris-persistence \
  --from-literal=username="$(kubectl get secret polaris-pg-app -n dwh -o jsonpath='{.data.username}' | base64 -d)" \
  --from-literal=password="$(kubectl get secret polaris-pg-app -n dwh -o jsonpath='{.data.password}' | base64 -d)" \
  --from-literal=jdbcUrl="$JDBC_URL"
```

### RSA token broker secret

```bash
kubectl -n dwh delete secret polaris-token-broker --ignore-not-found

tmpdir="$(mktemp -d)"
openssl genrsa -out "${tmpdir}/private.pem" 2048
openssl rsa -in "${tmpdir}/private.pem" -pubout -out "${tmpdir}/public.pem"
printf "%s" "secret" > "${tmpdir}/symmetric.key"

kubectl -n dwh create secret generic polaris-token-broker \
  --from-file="${tmpdir}/private.pem" \
  --from-file="${tmpdir}/public.pem" \
  --from-file="${tmpdir}/symmetric.key"

rm -rf "${tmpdir}"
```

## 2. Install via Helm

```bash
helm upgrade --install polaris polaris/polaris \
  --namespace dwh \
  --values polaris/values.yaml \
  --wait --timeout 5m
```

## 3. Bootstrap Realm

```bash
REALM="POLARIS"
NS="dwh"

# Purge (only needed if re-bootstrapping)
kubectl -n $NS run polaris-purge --rm -it --restart=Never \
  --image=apache/polaris-admin-tool:latest \
  --env="QUARKUS_DATASOURCE_JDBC_URL=$(kubectl get secret polaris-persistence -n $NS -o jsonpath='{.data.jdbcUrl}' | base64 -d)" \
  --env="QUARKUS_DATASOURCE_USERNAME=$(kubectl get secret polaris-persistence -n $NS -o jsonpath='{.data.username}' | base64 -d)" \
  --env="QUARKUS_DATASOURCE_PASSWORD=$(kubectl get secret polaris-persistence -n $NS -o jsonpath='{.data.password}' | base64 -d)" \
  -- purge -r "$REALM"

# Bootstrap
kubectl -n $NS run polaris-bootstrap --rm -it --restart=Never \
  --image=apache/polaris-admin-tool:latest \
  --env="QUARKUS_DATASOURCE_JDBC_URL=$(kubectl get secret polaris-persistence -n $NS -o jsonpath='{.data.jdbcUrl}' | base64 -d)" \
  --env="QUARKUS_DATASOURCE_USERNAME=$(kubectl get secret polaris-persistence -n $NS -o jsonpath='{.data.username}' | base64 -d)" \
  --env="QUARKUS_DATASOURCE_PASSWORD=$(kubectl get secret polaris-persistence -n $NS -o jsonpath='{.data.password}' | base64 -d)" \
  -- bootstrap -r "$REALM" -c "$REALM,root,s3cr3t" -p
```

## 4. Create Catalog

```bash
REALM="POLARIS"

TOKEN=$(curl -sS -X POST "http://localhost:30181/api/catalog/v1/oauth/tokens" \
  -H "Polaris-Realm: $REALM" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=client_credentials&client_id=root&client_secret=s3cr3t&scope=PRINCIPAL_ROLE:ALL" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

curl -sS -X POST "http://localhost:30181/api/management/v1/catalogs" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Polaris-Realm: $REALM" \
  -H "Content-Type: application/json" \
  -d '{
    "catalog": {
      "name": "lakehouse",
      "type": "INTERNAL",
      "properties": {
        "default-base-location": "s3://lakehouse/"
      },
      "storageConfigInfo": {
        "storageType": "S3",
        "allowedLocations": ["s3://lakehouse/"],
        "s3.endpoint": "http://ozone-s3g-rest.dwh.svc.cluster.local:9878",
        "s3.path-style-access": "true",
        "s3.region": "us-east-1",
        "stsUnavailable": true,
        "pathStyleAccess": true
      }
    }
  }' | python3 -m json.tool
```

## 5. Verify

```bash
# List catalogs
curl -sS "http://localhost:30181/api/management/v1/catalogs" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Polaris-Realm: $REALM" | python3 -m json.tool
```

## Uninstall

```bash
helm uninstall polaris -n dwh
kubectl -n dwh delete secret polaris-persistence polaris-token-broker --ignore-not-found
```

## Key Configuration Notes

- **`stsUnavailable: true`** — Ozone doesn't support AWS STS credential vending
- **`pathStyleAccess: true`** — Required for Ozone S3 Gateway
- **`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`** — Set in `values.yaml` extraEnv for server-side Ozone access
- **Realm header** — All API calls require `Polaris-Realm: POLARIS` header
- **Root credentials** — `root` / `s3cr3t` (set during bootstrap)
