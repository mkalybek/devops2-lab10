#!/usr/bin/env bash
# Provision the gainful-skater VM: install Longhorn host deps + k3s, copy
# kubeconfig to $HOME/.kube/lab10 on the Mac.
#
# Idempotent — safe to rerun.
set -euo pipefail

VM_NAME="${VM_NAME:-gainful-skater}"
MULTIPASS="${MULTIPASS:-/usr/local/bin/multipass}"
KUBECONFIG_OUT="${KUBECONFIG_OUT:-$HOME/.kube/lab10}"

echo "==> [1/4] apt deps on $VM_NAME (open-iscsi, nfs-common, cryptsetup)"
"$MULTIPASS" exec "$VM_NAME" -- sudo apt-get update -qq
"$MULTIPASS" exec "$VM_NAME" -- sudo apt-get install -y -qq \
  open-iscsi nfs-common cryptsetup dmsetup curl

echo "==> [2/4] enable iscsid and load kernel modules"
"$MULTIPASS" exec "$VM_NAME" -- sudo systemctl enable --now iscsid
"$MULTIPASS" exec "$VM_NAME" -- sudo modprobe iscsi_tcp
"$MULTIPASS" exec "$VM_NAME" -- sudo modprobe dm_crypt

echo "==> [3/4] install k3s (if missing)"
if ! "$MULTIPASS" exec "$VM_NAME" -- which k3s >/dev/null 2>&1; then
  "$MULTIPASS" exec "$VM_NAME" -- bash -c \
    'curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--write-kubeconfig-mode 644" sh -'
fi

echo "==> [4/4] fetch kubeconfig -> $KUBECONFIG_OUT"
mkdir -p "$(dirname "$KUBECONFIG_OUT")"
VM_IP=$("$MULTIPASS" info "$VM_NAME" | awk '/IPv4/ {print $2; exit}')
"$MULTIPASS" exec "$VM_NAME" -- sudo cat /etc/rancher/k3s/k3s.yaml \
  | sed "s|127.0.0.1|$VM_IP|" > "$KUBECONFIG_OUT"
chmod 600 "$KUBECONFIG_OUT"

echo
echo "Done. Point your shell at the cluster:"
echo "  export KUBECONFIG=$KUBECONFIG_OUT"
echo
echo "Then:"
echo "  kubectl get nodes"
