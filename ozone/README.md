# Apache Ozone on k3s

Apache Ozone is the S3-compatible object storage backend for the lakehouse. It stores all Iceberg data files (Parquet, Avro, ORC) written by Trino and Spark.

## Architecture

```
Ozone Manager (OM)      — metadata: namespace, volume, bucket, key management
Storage Container Mgr   — SCM: block management, pipeline coordination
DataNode(s)             — actual data storage
S3 Gateway (S3G)        — S3-compatible REST API on port 9878
```

Single-node k3s deployment: 1 replica of each component, replication factor 1.

## Deploy

```bash
# Add repo (only once)
helm repo add ozone https://apache.github.io/ozone-helm-charts/
helm repo update ozone

# Install Ozone
helm upgrade --install ozone ozone/ozone \
  --version 0.2.0 \
  --namespace dwh \
  --values ozone/values.yaml \
  --wait --timeout 10m

# Bootstrap: create the lakehouse bucket
OM_POD=$(kubectl get pod -n dwh -l app.kubernetes.io/component=om -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n dwh "$OM_POD" -- \
  ozone sh bucket create /s3v/lakehouse --layout OBJECT_STORE

# Create S3 credentials secret (static — S3G accepts any key/secret in non-secure mode)
kubectl -n dwh delete secret ozone-s3-creds --ignore-not-found
kubectl -n dwh create secret generic ozone-s3-creds \
  --from-literal=access-key="ozone" \
  --from-literal=secret-key="ozone-secret123"
```

## Reinstall (full wipe and redeploy)

```bash
helm uninstall ozone -n dwh
kubectl -n dwh delete secret ozone-s3-creds --ignore-not-found
kubectl -n dwh delete pvc \
  ozone-datanode-ozone-datanode-0 \
  ozone-om-ozone-om-0 \
  ozone-scm-ozone-scm-0
# Wait for pods to terminate, then re-run Deploy steps above
kubectl -n dwh wait --for=delete pod -l app.kubernetes.io/instance=ozone --timeout=120s
```

---

## AWS CLI Setup

The Ozone S3 Gateway speaks standard S3 API. In non-secure mode (this cluster) any
access key / secret key pair is accepted — use the static dev credentials.

### Configure profile

```bash
mkdir -p ~/.aws

cat >> ~/.aws/credentials << 'EOF'
[ozone]
aws_access_key_id = ozone
aws_secret_access_key = ozone-secret123
EOF

cat >> ~/.aws/config << 'EOF'
[profile ozone]
region = us-east-1
output = json
EOF
```

### Endpoint

```bash
# From WSL (all commands below use this)
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
S3_EP="http://${NODE_IP}:30878"

# Shorthand alias (add to ~/.zshrc or ~/.bashrc for persistence)
alias s3ozone="aws --profile ozone --endpoint-url $S3_EP s3"
```

---

## AWS CLI Tests

All commands use:
```bash
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
EP="http://${NODE_IP}:30878"
AWS="aws --profile ozone --endpoint-url $EP"
```

### List buckets

```bash
$AWS s3 ls
# 2026-05-10 18:45:06 lakehouse
```

### Create a bucket

```bash
$AWS s3 mb s3://my-new-bucket
# make_bucket: my-new-bucket

$AWS s3 ls
# 2026-05-10 ... lakehouse
# 2026-05-10 ... my-new-bucket
```

### Upload files

```bash
# Upload a single file
echo "hello ozone" > /tmp/test.txt
$AWS s3 cp /tmp/test.txt s3://my-new-bucket/data/test.txt

# Upload a directory recursively
$AWS s3 cp /tmp/mydir/ s3://my-new-bucket/mydir/ --recursive

# List contents
$AWS s3 ls s3://my-new-bucket/ --recursive
# 2026-05-10 ...         11 data/test.txt
```

### Download files

```bash
$AWS s3 cp s3://my-new-bucket/data/test.txt /tmp/downloaded.txt
cat /tmp/downloaded.txt
# hello ozone
```

### Delete a single object

```bash
$AWS s3 rm s3://my-new-bucket/data/test.txt
$AWS s3 ls s3://my-new-bucket/ --recursive
# (empty)
```

### Delete all objects in a bucket (recursive)

```bash
$AWS s3 rm s3://my-new-bucket/ --recursive
```

### Delete a bucket

```bash
# Bucket must be empty first
$AWS s3 rb s3://my-new-bucket

# Or force-remove with all contents
$AWS s3 rb s3://my-new-bucket --force
```

---

## Creating a New S3 User (Ozone Volume)

In non-secure Ozone (no Kerberos), S3 "users" are modelled as **Ozone volumes**.
The S3 Gateway serves all buckets under the built-in `/s3v` volume, but you can
create additional volumes to namespace your data.

> **Note:** The multi-tenancy feature (`ozone tenant`) and `ozone s3 getsecret`
> require Kerberos security to be enabled. In this dev cluster they are disabled.
> Any access-key / secret-key pair is accepted by the S3 Gateway.

```bash
OM_POD=$(kubectl get pod -n dwh -l app.kubernetes.io/component=om \
  -o jsonpath='{.items[0].metadata.name}')

# Create a new volume (user namespace)
kubectl exec -n dwh "$OM_POD" -- ozone sh volume create /alice
kubectl exec -n dwh "$OM_POD" -- ozone sh volume info /alice

# Create a bucket in that volume
kubectl exec -n dwh "$OM_POD" -- \
  ozone sh bucket create /alice/mybucket --layout OBJECT_STORE

# List buckets in the volume
kubectl exec -n dwh "$OM_POD" -- ozone sh bucket list /alice

# List all volumes
kubectl exec -n dwh "$OM_POD" -- ozone sh volume list
```

To access alice's bucket via S3 API, reference it like any other S3 bucket —
Ozone S3G routes bucket names through the `/s3v` volume (the standard S3 mapping):

```bash
# Put a file into alice's bucket (it must first be linked or created via S3G)
$AWS s3 mb s3://alice-bucket
$AWS s3 cp /tmp/test.txt s3://alice-bucket/test.txt
$AWS s3 ls s3://alice-bucket/
```

---

## Ozone CLI Reference

```bash
OM_POD=$(kubectl get pod -n dwh -l app.kubernetes.io/component=om \
  -o jsonpath='{.items[0].metadata.name}')

# Cluster health
kubectl exec -n dwh "$OM_POD" -- ozone admin cluster status

# Volumes
kubectl exec -n dwh "$OM_POD" -- ozone sh volume list
kubectl exec -n dwh "$OM_POD" -- ozone sh volume info /s3v
kubectl exec -n dwh "$OM_POD" -- ozone sh volume create /myvolume

# Buckets
kubectl exec -n dwh "$OM_POD" -- ozone sh bucket list /s3v
kubectl exec -n dwh "$OM_POD" -- ozone sh bucket info /s3v/lakehouse

# Keys (objects)
kubectl exec -n dwh "$OM_POD" -- ozone sh key list /s3v/lakehouse
kubectl exec -n dwh "$OM_POD" -- ozone sh key info /s3v/lakehouse/path/to/key

# DataNode / pipeline status
kubectl exec -n dwh "$OM_POD" -- ozone admin datanode list
kubectl exec -n dwh "$OM_POD" -- ozone admin pipeline list
```

---

## S3 Access (in-cluster, no AWS CLI)

```bash
# From any pod in dwh namespace
curl -s "http://ozone-s3g-rest.dwh.svc.cluster.local:9878/" \
  --aws-sigv4 "aws:amz:us-east-1:s3" \
  --user "ozone:ozone-secret123"

# Or use the NodePort from WSL
curl "http://${NODE_IP}:30878/" \
  --aws-sigv4 "aws:amz:us-east-1:s3" \
  --user "ozone:ozone-secret123"
```

---

## Troubleshooting

| Problem | Fix |
|---|---|
| `403 Forbidden` from S3G | S3G accepts any credentials in non-secure mode — check the bucket name exists (`ozone sh bucket list /s3v`) |
| `Bucket not found` from Trino/Spark | Run the bootstrap step: `ozone sh bucket create /s3v/lakehouse --layout OBJECT_STORE` |
| Safe mode stuck | Ozone waits for min datanodes. With `min.datanode=1` it exits after 1 datanode connects. Check: `ozone admin cluster status` |
| DataNode not registering | SCM must be healthy first. Check: `kubectl logs -n dwh -l app.kubernetes.io/component=scm` |
| `ozone s3 getsecret` fails | Requires Kerberos (not enabled in dev mode). Use static credentials: `access-key=ozone`, `secret-key=ozone-secret123` |
| `ozone tenant` commands fail | Multi-tenancy requires `ozone.om.multitenancy.enabled=true` in Ozone config (not set in this cluster) |
