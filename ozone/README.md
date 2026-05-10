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
```

## S3 Access

The S3 Gateway runs on port 9878 (NodePort 30878 externally).

### Generate S3 credentials for a user
```bash
OM_POD=$(kubectl get pod -n dwh -l app.kubernetes.io/component=om -o jsonpath='{.items[0].metadata.name}')

# Generate credentials for user 'trino'
kubectl exec -n dwh "$OM_POD" -- ozone s3 getsecret -u trino

# Output:
# awsAccessKey=<access-key>
# awsSecret=<secret-key>
```

### Test S3 access
```bash
# Using AWS CLI (point to Ozone S3 gateway)
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

AWS_ACCESS_KEY_ID=<access-key> \
AWS_SECRET_ACCESS_KEY=<secret-key> \
aws s3 ls s3://lakehouse/ \
  --endpoint-url http://${NODE_IP}:30878 \
  --no-verify-ssl

# Upload a test file
echo "hello lakehouse" | \
AWS_ACCESS_KEY_ID=<access-key> \
AWS_SECRET_ACCESS_KEY=<secret-key> \
aws s3 cp - s3://lakehouse/test.txt \
  --endpoint-url http://${NODE_IP}:30878
```

## Ozone CLI

```bash
OM_POD=$(kubectl get pod -n dwh -l app.kubernetes.io/component=om -o jsonpath='{.items[0].metadata.name}')

# List volumes
kubectl exec -n dwh "$OM_POD" -- ozone sh volume list

# List buckets
kubectl exec -n dwh "$OM_POD" -- ozone sh bucket list /s3v

# List keys
kubectl exec -n dwh "$OM_POD" -- ozone sh key list /s3v/lakehouse

# Check cluster status
kubectl exec -n dwh "$OM_POD" -- ozone admin cluster status
```

## Troubleshooting

**DataNode not registering**: SCM must be healthy first. Check: `kubectl logs -n dwh -l app.kubernetes.io/component=scm -f`

**S3G returning 403**: Credentials are invalid or user doesn't exist. Re-run `ozone s3 getsecret`.

**Safe mode**: Ozone starts in safe mode until minimum datanodes register. With `min.datanode=1` in our config, it exits safe mode after 1 datanode connects.

**"Bucket not found" from Trino/Spark**: The `lakehouse` bucket must exist. Run the bootstrap step above.
