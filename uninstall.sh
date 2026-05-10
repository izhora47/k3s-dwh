#!/usr/bin/env bash
# =============================================================================
# Data Lakehouse Uninstall Script (Helm-based)
# Removes all DWH, Spark, and Airflow components from the cluster.
# =============================================================================
set -euo pipefail

NAMESPACE="dwh"

echo "WARNING: This will delete ALL resources in namespaces:"
echo "  - $NAMESPACE (Polaris, Spark jobs)"
echo "  - spark-operator"
echo "  - airflow"
echo "  - cnpg-system (CloudNativePG operator)"
echo "Data will be LOST."
read -r -p "Are you sure? [y/N] " confirm
[[ "${confirm,,}" == "y" ]] || { echo "Aborted."; exit 0; }

echo "Removing Spark jobs and ConfigMaps..."
kubectl delete sparkapplication --all -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true
kubectl delete job --all -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true
kubectl delete configmap spark-polaris-script spark-connect-client-script -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true

echo "Removing Apache Airflow (Helm)..."
helm uninstall airflow -n airflow 2>/dev/null || true
kubectl delete namespace airflow --ignore-not-found 2>/dev/null || true

echo "Removing Spark Kubernetes Operator (Helm)..."
helm uninstall spark-kubernetes-operator -n spark-operator 2>/dev/null || true
kubectl delete namespace spark-operator --ignore-not-found 2>/dev/null || true

echo "Removing Apache Polaris (Helm)..."
helm uninstall polaris -n "$NAMESPACE" 2>/dev/null || true

echo "Removing Apache Ozone (Helm, if installed)..."
helm uninstall ozone -n "$NAMESPACE" 2>/dev/null || true

echo "Removing Polaris secrets..."
kubectl -n "$NAMESPACE" delete secret polaris-persistence polaris-token-broker --ignore-not-found

echo "Removing PostgreSQL cluster..."
kubectl delete -f cnpg/polaris-pg.yaml --ignore-not-found 2>/dev/null || true

echo "Removing CloudNativePG operator (Helm)..."
helm uninstall cnpg -n cnpg-system 2>/dev/null || true

echo "Removing namespace (and remaining PVCs)..."
kubectl delete namespace "$NAMESPACE" --ignore-not-found

echo ""
echo "Uninstall complete."
echo "Note: PersistentVolumes may remain. Check: kubectl get pv"
