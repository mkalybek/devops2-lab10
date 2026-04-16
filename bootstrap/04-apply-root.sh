#!/usr/bin/env bash
# Apply the root Application. Everything else is GitOps from this point.
set -euo pipefail

: "${KUBECONFIG:?export KUBECONFIG=\$HOME/.kube/lab10 first}"

HERE=$(cd "$(dirname "$0")/.." && pwd)
kubectl apply -f "$HERE/argocd/root-app.yaml"

echo
echo "Watch the apps fan out:"
echo "  kubectl -n argocd get applications -w"
