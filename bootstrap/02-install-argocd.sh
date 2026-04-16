#!/usr/bin/env bash
# Install ArgoCD in the `argocd` namespace. Uses the upstream install manifest.
set -euo pipefail

: "${KUBECONFIG:?export KUBECONFIG=\$HOME/.kube/lab10 first}"

ARGOCD_VERSION="${ARGOCD_VERSION:-v2.13.2}"

echo "==> install ArgoCD $ARGOCD_VERSION"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/$ARGOCD_VERSION/manifests/install.yaml"

echo "==> wait for argocd-server rollout"
kubectl -n argocd rollout status deploy/argocd-server --timeout=5m

echo
echo "Initial admin password:"
echo "  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo"
echo
echo "UI:"
echo "  kubectl -n argocd port-forward svc/argocd-server 8080:443"
echo "  https://localhost:8080   (user: admin)"
