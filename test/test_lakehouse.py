#!/usr/bin/env python3
"""
Apache Polaris + Apache Ozone Lakehouse Integration Test
=========================================================
Uses PyIceberg to:
  1. Connect to Polaris REST catalog
  2. Create a namespace (bronze layer)
  3. Create an Iceberg table (orders)
  4. INSERT test data (via PyArrow)
  5. SELECT and print all records

Requirements (auto-installed in the Kubernetes Job):
  pip install pyiceberg[s3fs] pyarrow boto3
"""

import os
import time
import pyarrow as pa
from pyiceberg.catalog import load_catalog
from pyiceberg.schema import Schema
from pyiceberg.types import (
    NestedField, IntegerType, StringType, FloatType, TimestampType
)
from pyiceberg.partitioning import PartitionSpec, PartitionField
from pyiceberg.transforms import DayTransform

# ── Configuration from environment variables (set in Kubernetes Job) ──────────
POLARIS_URI    = os.getenv("POLARIS_URI",    "http://polaris.dwh.svc.cluster.local:8181/api/catalog")
POLARIS_CLIENT_ID     = os.getenv("POLARIS_CLIENT_ID",     "polaris-root")
POLARIS_CLIENT_SECRET = os.getenv("POLARIS_CLIENT_SECRET", "polaris-secret-change-me")
POLARIS_WAREHOUSE     = os.getenv("POLARIS_WAREHOUSE",     "lakehouse")

OZONE_ENDPOINT   = os.getenv("OZONE_ENDPOINT",   "http://ozone-s3gateway.dwh.svc.cluster.local:9878")
OZONE_ACCESS_KEY = os.getenv("OZONE_ACCESS_KEY", "testuser")
OZONE_SECRET_KEY = os.getenv("OZONE_SECRET_KEY", "testuser-secret")
OZONE_BUCKET     = os.getenv("OZONE_BUCKET",     "lakehouse")

# ── Catalog setup ─────────────────────────────────────────────────────────────
def get_catalog():
    print(f"Connecting to Polaris catalog at {POLARIS_URI}...")
    catalog = load_catalog(
        POLARIS_WAREHOUSE,
        **{
            "type": "rest",
            "uri": POLARIS_URI,
            "credential": f"{POLARIS_CLIENT_ID}:{POLARIS_CLIENT_SECRET}",
            "warehouse": POLARIS_WAREHOUSE,
            # S3-compatible settings for Ozone storage
            "s3.endpoint": OZONE_ENDPOINT,
            "s3.access-key-id": OZONE_ACCESS_KEY,
            "s3.secret-access-key": OZONE_SECRET_KEY,
            "s3.path-style-access": "true",
        },
    )
    print("Connected to Polaris catalog.")
    return catalog


# ── Schema definition ─────────────────────────────────────────────────────────
ORDERS_SCHEMA = Schema(
    NestedField(1,  "order_id",    IntegerType(),   required=True),
    NestedField(2,  "customer",    StringType(),    required=True),
    NestedField(3,  "product",     StringType(),    required=True),
    NestedField(4,  "quantity",    IntegerType(),   required=True),
    NestedField(5,  "unit_price",  FloatType(),     required=True),
    NestedField(6,  "total",       FloatType(),     required=True),
    NestedField(7,  "status",      StringType(),    required=False),
    NestedField(8,  "region",      StringType(),    required=False),
)

# ── Test data ─────────────────────────────────────────────────────────────────
TEST_DATA = pa.table({
    "order_id":   [1,        2,         3,         4,         5],
    "customer":   ["Alice",  "Bob",     "Charlie", "Diana",   "Eve"],
    "product":    ["Widget", "Gadget",  "Widget",  "Doohickey","Gadget"],
    "quantity":   [10,       5,         20,        1,         8],
    "unit_price": [9.99,     24.99,     9.99,      99.99,     24.99],
    "total":      [99.90,    124.95,    199.80,    99.99,     199.92],
    "status":     ["shipped","pending", "shipped", "shipped", "pending"],
    "region":     ["EU",     "US",      "EU",      "APAC",    "US"],
})


def main():
    catalog = get_catalog()

    # ── 1. Create namespace ───────────────────────────────────────────────────
    namespace = "bronze"
    existing = [ns[0] for ns in catalog.list_namespaces()]
    if namespace not in existing:
        print(f"\nCreating namespace '{namespace}'...")
        catalog.create_namespace(namespace, properties={
            "location": f"s3a://{OZONE_BUCKET}/warehouse/{namespace}",
            "description": "Bronze (raw) data layer",
        })
        print(f"Namespace '{namespace}' created.")
    else:
        print(f"Namespace '{namespace}' already exists.")

    # ── 2. Create table ───────────────────────────────────────────────────────
    table_id = f"{namespace}.orders"
    if not catalog.table_exists(table_id):
        print(f"\nCreating table '{table_id}'...")
        table = catalog.create_table(
            table_id,
            schema=ORDERS_SCHEMA,
            location=f"s3a://{OZONE_BUCKET}/warehouse/{namespace}/orders",
            properties={
                "write.format.default": "parquet",
                "write.parquet.compression-codec": "snappy",
            },
        )
        print(f"Table '{table_id}' created.")
    else:
        print(f"Table '{table_id}' already exists, loading...")
        table = catalog.load_table(table_id)

    # ── 3. INSERT test data ───────────────────────────────────────────────────
    print(f"\nINSERTing {len(TEST_DATA)} rows into '{table_id}'...")
    table.append(TEST_DATA)
    print("INSERT complete.")

    # ── 4. SELECT all rows ────────────────────────────────────────────────────
    print(f"\nSELECT * FROM {table_id}:")
    print("-" * 80)
    scan = table.scan()
    result = scan.to_arrow()
    for row in result.to_pylist():
        print(f"  order_id={row['order_id']:2d}  customer={row['customer']:<10s}"
              f"  product={row['product']:<12s}  qty={row['quantity']:2d}"
              f"  total=${row['total']:7.2f}  status={row['status']:<8s}"
              f"  region={row['region']}")
    print("-" * 80)
    print(f"Total rows: {result.num_rows}")

    # ── 5. Filter query (SELECT with WHERE) ───────────────────────────────────
    print(f"\nSELECT * FROM {table_id} WHERE status = 'shipped':")
    print("-" * 80)
    from pyiceberg.expressions import EqualTo
    shipped = table.scan(row_filter=EqualTo("status", "shipped")).to_arrow()
    for row in shipped.to_pylist():
        print(f"  order_id={row['order_id']}  customer={row['customer']:<10s}  total=${row['total']:.2f}")
    print(f"Shipped orders: {shipped.num_rows}")

    # ── 6. Show table metadata ────────────────────────────────────────────────
    print(f"\nTable metadata:")
    print(f"  Location : {table.location()}")
    print(f"  Snapshots: {len(table.metadata.snapshots)}")
    print(f"  Schema   : {table.schema()}")

    print("\nTest completed successfully!")


if __name__ == "__main__":
    main()
