# RustFS — S3-compatible object storage

RustFS 1.0.0-beta.2 deployed in standalone single-node mode.
Helm chart: `rustfs/rustfs` v0.2.0 from `https://charts.rustfs.com`.

Admin credentials: `lakehouseadmin` / `Lk@h0use-S3-2026!`  
Kubernetes secret: `ozone-s3-creds` (key: `access-key`, `secret-key`) — shared with Trino and Polaris.

## Endpoints

| Access | URL | Notes |
|---|---|---|
| S3 API (internal) | `http://rustfs-svc.dwh.svc.cluster.local:9000` | used by Polaris, Trino, AWS CLI |
| S3 API (external) | `https://s3.test.local` | Traefik TLS ingress, HTTPS port 443/31378 |
| Console (external) | `https://s3-console.test.local` | Web UI for bucket and user management |

## User Management

RustFS uses the MinIO-compatible Admin API. Use `mc` (MinIO client) via `kubectl run`:

```bash
# Helper alias — run from your WSL shell
mc_rustfs() {
  kubectl run mc-tmp --rm -i --restart=Never -n dwh \
    --image=minio/mc:latest \
    --command -- /bin/sh -c "
      mc alias set rustfs http://rustfs-svc.dwh.svc.cluster.local:9000 \
        lakehouseadmin 'Lk@h0use-S3-2026!' >/dev/null
      $*"
}
```

### Create a user

```bash
kubectl run mc-tmp --rm -i --restart=Never -n dwh \
  --image=minio/mc:latest \
  --command -- /bin/sh -c "
    mc alias set rustfs http://rustfs-svc.dwh.svc.cluster.local:9000 \
      lakehouseadmin 'Lk@h0use-S3-2026!' >/dev/null

    # Create user with username = access key, password = secret key
    mc admin user add rustfs <username> '<strong-password>'

    # Attach a built-in policy (readonly / readwrite / writeonly / consoleAdmin)
    mc admin policy attach rustfs readwrite --user <username>

    # Verify
    mc admin user info rustfs <username>"
```

**Built-in policies:**

| Policy | Access |
|---|---|
| `readonly` | GET/LIST on all buckets |
| `writeonly` | PUT/DELETE on all buckets |
| `readwrite` | Full S3 read+write on all buckets |
| `consoleAdmin` | Full admin including user management |
| `diagnostics` | Read-only diagnostics |

### Create a bucket-scoped policy

For least-privilege access to a single bucket (`mybucket`):

```bash
kubectl run mc-tmp --rm -i --restart=Never -n dwh \
  --image=minio/mc:latest \
  --command -- /bin/sh -c "
    mc alias set rustfs http://rustfs-svc.dwh.svc.cluster.local:9000 \
      lakehouseadmin 'Lk@h0use-S3-2026!' >/dev/null

    # Write policy JSON
    cat > /tmp/mybucket-rw.json << 'EOF'
{
  \"Version\": \"2012-10-17\",
  \"Statement\": [{
    \"Effect\": \"Allow\",
    \"Action\": [\"s3:GetObject\",\"s3:PutObject\",\"s3:DeleteObject\",\"s3:ListBucket\"],
    \"Resource\": [\"arn:aws:s3:::mybucket\",\"arn:aws:s3:::mybucket/*\"]
  }]
}
EOF

    mc admin policy create rustfs mybucket-rw /tmp/mybucket-rw.json
    mc admin user add rustfs myuser 'My-S3cret-2026!'
    mc admin policy attach rustfs mybucket-rw --user myuser
    mc admin user info rustfs myuser"
```

### Create a service account (scoped access key)

A service account is a short-lived or named access key tied to an existing user, optionally with a subset of that user's permissions. Useful for applications — rotate without changing the user's main password.

```bash
kubectl run mc-tmp --rm -i --restart=Never -n dwh \
  --image=minio/mc:latest \
  --command -- /bin/sh -c "
    mc alias set rustfs http://rustfs-svc.dwh.svc.cluster.local:9000 \
      lakehouseadmin 'Lk@h0use-S3-2026!' >/dev/null

    # Creates a new access-key/secret-key pair under the given user
    mc admin accesskey create rustfs <username>"
```

The output gives you a new `Access Key` + `Secret Key`. The access key inherits the user's policies.

### List and remove users

```bash
kubectl run mc-tmp --rm -i --restart=Never -n dwh \
  --image=minio/mc:latest \
  --command -- /bin/sh -c "
    mc alias set rustfs http://rustfs-svc.dwh.svc.cluster.local:9000 \
      lakehouseadmin 'Lk@h0use-S3-2026!' >/dev/null
    mc admin user list rustfs
    mc admin user remove rustfs <username>"
```

## Bucket Operations

```bash
kubectl run mc-tmp --rm -i --restart=Never -n dwh \
  --image=minio/mc:latest \
  --command -- /bin/sh -c "
    mc alias set rustfs http://rustfs-svc.dwh.svc.cluster.local:9000 \
      lakehouseadmin 'Lk@h0use-S3-2026!' >/dev/null

    mc mb rustfs/newbucket          # create bucket
    mc ls rustfs                    # list buckets
    mc ls rustfs/lakehouse          # list contents
    mc rb rustfs/newbucket          # remove empty bucket
    mc rb --force rustfs/newbucket  # remove with all objects"
```

## AWS CLI (alternative)

```bash
export AWS_ACCESS_KEY_ID=lakehouseadmin
export AWS_SECRET_ACCESS_KEY='Lk@h0use-S3-2026!'
export AWS_DEFAULT_REGION=us-east-1
EP=http://rustfs-svc.dwh.svc.cluster.local:9000   # use from within cluster via kubectl exec

aws --endpoint-url "$EP" s3 ls
aws --endpoint-url "$EP" s3 mb s3://newbucket
aws --endpoint-url "$EP" s3 cp myfile.txt s3://newbucket/
aws --endpoint-url "$EP" s3 rm s3://newbucket/myfile.txt
```

## Known Chart Issues (v0.2.0)

| Issue | Fix |
|---|---|
| Main ingress routes to console port (9001) instead of S3 port (9000) | `kubectl -n dwh patch ingress rustfs --type=json -p='[{"op":"replace","path":"/spec/rules/0/http/paths/0/backend/service/port/name","value":"endpoint"}]'` |
| `access_key` validation rejects `rustfsadmin` and empty string | Use a custom key — chart enforces non-default credentials |

## TLS — Current Setup and Enterprise Gap

### What is configured

| Layer | Status |
|---|---|
| External access (`https://s3.test.local`) | **TLS** — Traefik terminates, wildcard cert `*.test.local` |
| Internal cluster traffic (`rustfs-svc:9000`) | **Plain HTTP** — no encryption pod-to-pod |
| Certificate authority | **Self-signed dev CA** — not trusted by browsers or clients by default |

### Enterprise best practices

For production, the gaps to close are:

1. **Certificate from a trusted CA** — use Let's Encrypt (cert-manager), a corporate internal CA, or a commercial CA. The `*.test.local` cert is dev-only.

2. **End-to-end TLS (not just ingress termination)** — in the current setup, traffic from Traefik to the RustFS pod is plain HTTP. To close this:
   - Configure RustFS with TLS certs via volume mount (`rustfs.tls.cert` / `rustfs.tls.key`)
   - Or use a service mesh (Istio mTLS) for automatic in-cluster encryption

3. **Audit logging** — enable access logs; ship to a SIEM (Loki, Splunk, Elastic). Every `GetObject` / `PutObject` / `DeleteObject` should be recorded.

4. **Short-lived credentials / key rotation** — do not use a single long-lived admin key for all clients. Create per-service users with scoped policies and rotate secrets on a schedule (90 days or less).

5. **Network policies** — add Kubernetes `NetworkPolicy` to restrict which pods can reach port 9000 on `rustfs-svc`. Only Polaris and Trino should need it.

6. **Read-only root filesystem** — set `securityContext.readOnlyRootFilesystem: true` on the RustFS container.

### Summary

The current setup (Traefik TLS + wildcard cert) is appropriate for a **dev / internal lab** environment. For a company-facing deployment:
- Replace the self-signed cert with one from a trusted CA
- Add end-to-end TLS or a service mesh
- Add per-user credentials and audit logs
