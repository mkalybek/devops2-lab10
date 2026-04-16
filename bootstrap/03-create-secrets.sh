#!/usr/bin/env bash
# Create the three credential Secrets that ArgoCD intentionally does NOT manage:
#   - app/helm-app-postgres          — Postgres superuser creds
#   - minio/minio-creds              — MinIO root user/pass
#   - longhorn-system/minio-backup-secret — S3 creds Longhorn uses to reach MinIO
#
# Lab-only credentials. In production, use sealed-secrets or external-secrets.
set -euo pipefail

: "${KUBECONFIG:?export KUBECONFIG=\$HOME/.kube/lab10 first}"

POSTGRES_USER="${POSTGRES_USER:-keycloak}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-keycloak-change-me}"
POSTGRES_DB="${POSTGRES_DB:-keycloak}"

MINIO_ROOT_USER="${MINIO_ROOT_USER:-minio-admin}"
MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-minio-change-me}"

for ns in app minio longhorn-system; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
done

echo "==> helm-app-postgres (namespace: app)"
kubectl -n app create secret generic helm-app-postgres \
  --from-literal=POSTGRES_USER="$POSTGRES_USER" \
  --from-literal=POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
  --from-literal=POSTGRES_DB="$POSTGRES_DB" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> minio-creds (namespace: minio)"
kubectl -n minio create secret generic minio-creds \
  --from-literal=rootUser="$MINIO_ROOT_USER" \
  --from-literal=rootPassword="$MINIO_ROOT_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

# Longhorn reads AWS_ENDPOINTS (+ access key/secret) from this secret.
# http://minio.minio.svc.cluster.local:9000 — in-cluster endpoint.
echo "==> minio-backup-secret (namespace: longhorn-system)"
kubectl -n longhorn-system create secret generic minio-backup-secret \
  --from-literal=AWS_ACCESS_KEY_ID="$MINIO_ROOT_USER" \
  --from-literal=AWS_SECRET_ACCESS_KEY="$MINIO_ROOT_PASSWORD" \
  --from-literal=AWS_ENDPOINTS="http://minio.minio.svc.cluster.local:9000" \
  --dry-run=client -o yaml | kubectl apply -f -

echo
echo "Secrets applied. ArgoCD will not prune them (not in git)."
