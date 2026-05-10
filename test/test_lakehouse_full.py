"""
Full lakehouse integration test: Polaris + Ozone S3 + Trino

Tests:
  1. Polaris REST API: auth, catalog list, namespace list
  2. Ozone S3: bucket existence, put/get/delete object
  3. Trino: TPC-H query, Iceberg table create/insert/select/drop
  4. End-to-end: write Iceberg table via Trino, read metadata from Polaris API

Run inside the cluster:
  kubectl run lakehouse-test --rm -i --restart=Never \
    --image=trinodb/trino:480 \
    --env="POLARIS_URL=http://polaris.dwh.svc.cluster.local:8181" \
    --env="TRINO_URL=http://trino.dwh.svc.cluster.local:8080" \
    --env="OZONE_S3_URL=http://ozone-s3g-rest.dwh.svc.cluster.local:9878" \
    --env="AWS_ACCESS_KEY_ID=$(kubectl get secret ozone-s3-creds -n dwh -o jsonpath='{.data.access-key}' | base64 -d)" \
    --env="AWS_SECRET_ACCESS_KEY=$(kubectl get secret ozone-s3-creds -n dwh -o jsonpath='{.data.secret-key}' | base64 -d)" \
    -- python3 /test/test_lakehouse_full.py

Or as a ConfigMap Job (see test-job-full.yaml).
"""

import os
import sys
import json
import time
import urllib.request
import urllib.parse
import urllib.error
import hmac
import hashlib
import datetime
import traceback

# ── Config from environment ────────────────────────────────────────────────────
POLARIS_URL   = os.getenv("POLARIS_URL",   "http://polaris.dwh.svc.cluster.local:8181")
TRINO_URL     = os.getenv("TRINO_URL",     "http://trino.dwh.svc.cluster.local:8080")
OZONE_S3_URL  = os.getenv("OZONE_S3_URL",  "http://ozone-s3g-rest.dwh.svc.cluster.local:9878")
POLARIS_REALM = os.getenv("POLARIS_REALM", "POLARIS")
CLIENT_ID     = os.getenv("POLARIS_CLIENT_ID",     "root")
CLIENT_SECRET = os.getenv("POLARIS_CLIENT_SECRET",  "s3cr3t")
S3_ACCESS_KEY = os.getenv("AWS_ACCESS_KEY_ID",      "")
S3_SECRET_KEY = os.getenv("AWS_SECRET_ACCESS_KEY",  "")
CATALOG       = os.getenv("POLARIS_CATALOG",  "lakehouse")
SCHEMA        = os.getenv("POLARIS_SCHEMA",   "bronze")
TEST_TABLE    = "lakehouse_test_" + str(int(time.time()))[-6:]

PASS = "\033[32m[PASS]\033[0m"
FAIL = "\033[31m[FAIL]\033[0m"
SKIP = "\033[33m[SKIP]\033[0m"
INFO = "\033[36m[INFO]\033[0m"

results = []


def check(name, fn):
    try:
        fn()
        print(f"{PASS} {name}")
        results.append((name, True, None))
    except Exception as e:
        print(f"{FAIL} {name}: {e}")
        results.append((name, False, str(e)))


def http(method, url, headers=None, data=None, timeout=10):
    body = json.dumps(data).encode() if isinstance(data, dict) else \
           data.encode() if isinstance(data, str) else data
    req = urllib.request.Request(url, data=body, method=method, headers=headers or {})
    if body and "Content-Type" not in (headers or {}):
        req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, timeout=timeout) as r:
        raw = r.read()
        return json.loads(raw) if raw else {}


def get_polaris_token():
    payload = urllib.parse.urlencode({
        "grant_type":    "client_credentials",
        "client_id":     CLIENT_ID,
        "client_secret": CLIENT_SECRET,
        "scope":         "PRINCIPAL_ROLE:ALL",
    })
    resp = http("POST",
                f"{POLARIS_URL}/api/catalog/v1/oauth/tokens",
                headers={"Content-Type": "application/x-www-form-urlencoded",
                         "Polaris-Realm": POLARIS_REALM},
                data=payload)
    return resp["access_token"]


# ─── AWS Sig v4 for Ozone S3 (stdlib only) ────────────────────────────────────

def _sign(key, msg):
    return hmac.new(key, msg.encode("utf-8"), hashlib.sha256).digest()


def _aws_headers(method, bucket, key, body=b"", region="us-east-1"):
    endpoint_host = OZONE_S3_URL.split("//", 1)[1].rstrip("/")
    now = datetime.datetime.utcnow()
    amz_date = now.strftime("%Y%m%dT%H%M%SZ")
    date_stamp = now.strftime("%Y%m%d")
    path = f"/{bucket}/{key}" if key else f"/{bucket}/"
    payload_hash = hashlib.sha256(body).hexdigest()
    headers = {
        "host":                 endpoint_host,
        "x-amz-date":           amz_date,
        "x-amz-content-sha256": payload_hash,
    }
    canonical_headers = "".join(f"{k}:{v}\n" for k, v in sorted(headers.items()))
    signed_headers    = ";".join(sorted(headers.keys()))
    canonical_request = "\n".join([
        method, path, "",
        canonical_headers, signed_headers, payload_hash
    ])
    credential_scope = f"{date_stamp}/{region}/s3/aws4_request"
    string_to_sign = "\n".join([
        "AWS4-HMAC-SHA256", amz_date, credential_scope,
        hashlib.sha256(canonical_request.encode()).hexdigest()
    ])
    signing_key = _sign(
        _sign(_sign(_sign(f"AWS4{S3_SECRET_KEY}".encode(), date_stamp), region), "s3"),
        "aws4_request"
    )
    signature = hmac.new(signing_key, string_to_sign.encode(), hashlib.sha256).hexdigest()
    auth = (f"AWS4-HMAC-SHA256 Credential={S3_ACCESS_KEY}/{credential_scope}, "
            f"SignedHeaders={signed_headers}, Signature={signature}")
    result = {k: v for k, v in headers.items() if k != "host"}
    result["Authorization"] = auth
    return result, path, endpoint_host


# ── 1: Polaris REST API ────────────────────────────────────────────────────────

print(f"\n{INFO} ── Polaris REST API ──────────────────────────────────────")

def test_polaris_token():
    token = get_polaris_token()
    assert token, "Empty token"

def test_polaris_list_catalogs():
    token = get_polaris_token()
    resp = http("GET",
                f"{POLARIS_URL}/api/management/v1/catalogs",
                headers={"Authorization": f"Bearer {token}",
                         "Polaris-Realm": POLARIS_REALM})
    catalogs = [c["name"] for c in resp.get("catalogs", [])]
    assert CATALOG in catalogs, f"Catalog '{CATALOG}' not found. Got: {catalogs}"

def test_polaris_list_namespaces():
    token = get_polaris_token()
    resp = http("GET",
                f"{POLARIS_URL}/api/catalog/v1/{CATALOG}/namespaces",
                headers={"Authorization": f"Bearer {token}",
                         "Polaris-Realm": POLARIS_REALM})
    ns_list = [".".join(n) for n in resp.get("namespaces", [])]
    assert SCHEMA in ns_list, f"Namespace '{SCHEMA}' not found. Got: {ns_list}"

check("Polaris: obtain OAuth2 token",    test_polaris_token)
check("Polaris: list catalogs (lakehouse present)", test_polaris_list_catalogs)
check("Polaris: list namespaces (bronze present)",  test_polaris_list_namespaces)


# ── 2: Ozone S3 ───────────────────────────────────────────────────────────────

print(f"\n{INFO} ── Ozone S3 ──────────────────────────────────────────────")

def test_s3_bucket_exists():
    if not S3_ACCESS_KEY:
        raise RuntimeError("AWS_ACCESS_KEY_ID not set — skipping S3 tests")
    hdrs, path, host = _aws_headers("HEAD", "lakehouse", "")
    url = f"{OZONE_S3_URL}{path}"
    req = urllib.request.Request(url, method="HEAD", headers={**hdrs, "host": host})
    with urllib.request.urlopen(req, timeout=10) as r:
        assert r.status in (200, 301), f"Unexpected status: {r.status}"

def test_s3_put_get_delete():
    if not S3_ACCESS_KEY:
        raise RuntimeError("AWS_ACCESS_KEY_ID not set — skipping S3 tests")
    test_key  = f"_test/{TEST_TABLE}.txt"
    test_body = b"lakehouse-test-object"

    # PUT
    hdrs, path, host = _aws_headers("PUT", "lakehouse", test_key, body=test_body)
    hdrs["Content-Type"] = "text/plain"
    url = f"{OZONE_S3_URL}/lakehouse/{test_key}"
    req = urllib.request.Request(url, data=test_body, method="PUT",
                                  headers={**hdrs, "host": host})
    with urllib.request.urlopen(req, timeout=10) as r:
        assert r.status == 200, f"PUT failed: {r.status}"

    # GET
    hdrs2, _, _ = _aws_headers("GET", "lakehouse", test_key)
    req2 = urllib.request.Request(f"{OZONE_S3_URL}/lakehouse/{test_key}",
                                   method="GET", headers={**hdrs2, "host": host})
    with urllib.request.urlopen(req2, timeout=10) as r:
        data = r.read()
        assert data == test_body, f"GET body mismatch: {data!r}"

    # DELETE
    hdrs3, _, _ = _aws_headers("DELETE", "lakehouse", test_key)
    req3 = urllib.request.Request(f"{OZONE_S3_URL}/lakehouse/{test_key}",
                                   method="DELETE", headers={**hdrs3, "host": host})
    with urllib.request.urlopen(req3, timeout=10) as r:
        assert r.status in (200, 204), f"DELETE failed: {r.status}"

check("Ozone S3: bucket 'lakehouse' exists",   test_s3_bucket_exists)
check("Ozone S3: PUT / GET / DELETE object",   test_s3_put_get_delete)


# ── 3: Trino ──────────────────────────────────────────────────────────────────

print(f"\n{INFO} ── Trino SQL Engine ─────────────────────────────────────")

def trino_query(sql, catalog="tpch", schema="sf1", timeout=60):
    """Execute a Trino query and return rows."""
    headers = {
        "X-Trino-User":    "test",
        "X-Trino-Catalog": catalog,
        "X-Trino-Schema":  schema,
        "Content-Type":    "text/plain; charset=utf-8",
    }
    resp = http("POST", f"{TRINO_URL}/v1/statement",
                headers=headers, data=sql.encode())
    next_uri = resp.get("nextUri")
    rows = []
    deadline = time.time() + timeout
    while next_uri:
        if time.time() > deadline:
            raise TimeoutError(f"Trino query timed out after {timeout}s")
        time.sleep(0.5)
        req = urllib.request.Request(next_uri, headers={"X-Trino-User": "test"})
        with urllib.request.urlopen(req, timeout=30) as r:
            resp = json.loads(r.read())
        if "error" in resp:
            raise RuntimeError(resp["error"].get("message", str(resp["error"])))
        rows.extend(resp.get("data", []))
        next_uri = resp.get("nextUri")
    return rows

def test_trino_health():
    req = urllib.request.Request(f"{TRINO_URL}/v1/info")
    with urllib.request.urlopen(req, timeout=10) as r:
        info = json.loads(r.read())
    assert info.get("starting") is False, "Trino is still starting"

def test_trino_tpch():
    rows = trino_query(
        "SELECT l_returnflag, COUNT(*) as cnt FROM lineitem GROUP BY l_returnflag ORDER BY 1",
        catalog="tpch", schema="sf1"
    )
    assert len(rows) >= 2, f"Expected TPC-H rows, got: {rows}"

def test_trino_show_catalogs():
    rows = trino_query("SHOW CATALOGS", catalog="tpch", schema="sf1")
    catalogs = [r[0] for r in rows]
    assert "lakehouse" in catalogs, f"'lakehouse' catalog missing. Got: {catalogs}"

def test_trino_iceberg_create_table():
    trino_query(f"DROP TABLE IF EXISTS lakehouse.{SCHEMA}.{TEST_TABLE}",
                catalog="lakehouse", schema=SCHEMA)
    trino_query(f"""
        CREATE TABLE lakehouse.{SCHEMA}.{TEST_TABLE} (
            id      BIGINT,
            name    VARCHAR,
            value   DOUBLE,
            created TIMESTAMP(6) WITH TIME ZONE
        )
        WITH (format = 'PARQUET')
    """, catalog="lakehouse", schema=SCHEMA)

def test_trino_iceberg_insert():
    trino_query(f"""
        INSERT INTO lakehouse.{SCHEMA}.{TEST_TABLE} VALUES
            (1, 'alpha',  1.1, TIMESTAMP '2024-01-01 00:00:00 UTC'),
            (2, 'beta',   2.2, TIMESTAMP '2024-01-02 00:00:00 UTC'),
            (3, 'gamma',  3.3, TIMESTAMP '2024-01-03 00:00:00 UTC')
    """, catalog="lakehouse", schema=SCHEMA)

def test_trino_iceberg_select():
    rows = trino_query(
        f"SELECT id, name, value FROM lakehouse.{SCHEMA}.{TEST_TABLE} ORDER BY id",
        catalog="lakehouse", schema=SCHEMA
    )
    assert len(rows) == 3, f"Expected 3 rows, got {len(rows)}: {rows}"
    assert rows[0][1] == "alpha", f"Expected 'alpha', got: {rows[0]}"
    assert rows[2][0] == 3, f"Expected id=3, got: {rows[2]}"

def test_trino_iceberg_update():
    trino_query(
        f"UPDATE lakehouse.{SCHEMA}.{TEST_TABLE} SET value = 99.9 WHERE id = 2",
        catalog="lakehouse", schema=SCHEMA
    )
    rows = trino_query(
        f"SELECT value FROM lakehouse.{SCHEMA}.{TEST_TABLE} WHERE id = 2",
        catalog="lakehouse", schema=SCHEMA
    )
    assert rows[0][0] == 99.9, f"Expected 99.9 after UPDATE, got: {rows}"

def test_trino_iceberg_snapshots():
    rows = trino_query(
        f'SELECT snapshot_id FROM lakehouse.{SCHEMA}."${TEST_TABLE}$snapshots"',
        catalog="lakehouse", schema=SCHEMA
    )
    assert len(rows) >= 2, f"Expected at least 2 snapshots (insert+update), got {len(rows)}"

def test_trino_iceberg_table_in_polaris():
    token = get_polaris_token()
    resp = http("GET",
                f"{POLARIS_URL}/api/catalog/v1/{CATALOG}/{SCHEMA}/tables",
                headers={"Authorization": f"Bearer {token}",
                         "Polaris-Realm": POLARIS_REALM})
    identifiers = [t.get("name") for t in resp.get("identifiers", [])]
    assert TEST_TABLE in identifiers, \
        f"Table '{TEST_TABLE}' not in Polaris. Got: {identifiers}"

def test_trino_iceberg_drop_table():
    trino_query(f"DROP TABLE IF EXISTS lakehouse.{SCHEMA}.{TEST_TABLE}",
                catalog="lakehouse", schema=SCHEMA)
    rows = trino_query("SHOW TABLES IN lakehouse.bronze",
                       catalog="lakehouse", schema=SCHEMA)
    table_names = [r[0] for r in rows]
    assert TEST_TABLE not in table_names, \
        f"Table '{TEST_TABLE}' still exists after DROP"

check("Trino: health check (not starting)",     test_trino_health)
check("Trino: TPC-H query (lineitem groupby)",  test_trino_tpch)
check("Trino: SHOW CATALOGS includes lakehouse", test_trino_show_catalogs)
check("Trino+Polaris: CREATE TABLE (Iceberg)",  test_trino_iceberg_create_table)
check("Trino+Polaris+S3: INSERT rows",          test_trino_iceberg_insert)
check("Trino+Polaris+S3: SELECT rows",          test_trino_iceberg_select)
check("Trino+Polaris+S3: UPDATE rows",          test_trino_iceberg_update)
check("Trino+Polaris: Iceberg snapshots exist", test_trino_iceberg_snapshots)
check("Polaris API: table visible in catalog",  test_trino_iceberg_table_in_polaris)
check("Trino+Polaris+S3: DROP TABLE",           test_trino_iceberg_drop_table)


# ── Summary ───────────────────────────────────────────────────────────────────

print()
passed = sum(1 for _, ok, _ in results if ok)
failed = sum(1 for _, ok, _ in results if not ok)
total  = len(results)

print("═" * 60)
print(f"  Results: {passed}/{total} passed  |  {failed} failed")
print("═" * 60)

if failed:
    print("\nFailed tests:")
    for name, ok, err in results:
        if not ok:
            print(f"  ✗ {name}")
            print(f"    {err}")
    print()
    sys.exit(1)
else:
    print("\n  All tests passed! Lakehouse stack is fully operational.")
    sys.exit(0)
