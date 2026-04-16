#!/usr/bin/env bash
# End-to-end demo for Target + Perfection tiers:
#   1. seed test data in Postgres
#   2. take a named snapshot via Longhorn REST API
#   3. drop the data
#   4. scale Postgres to 0 so the volume detaches cleanly
#   5. attach the volume in maintenance mode, revert to the snapshot, detach
#   6. scale back to 1 and prove the data came back
#   7. create a PVC clone (new PV seeded from the live one)
#   8. trigger an off-cluster backup of the current volume to MinIO
#
# Requires: KUBECONFIG pointed at the cluster, ArgoCD + Longhorn + helm-app
# all Synced/Healthy, MinIO ready, Longhorn BackupTarget `default` available.
set -euo pipefail

: "${KUBECONFIG:?export KUBECONFIG=\$HOME/.kube/lab10 first}"

NS_APP="${NS_APP:-app}"
NS_LH="${NS_LH:-longhorn-system}"
STS="${STS:-helm-app-postgres}"
PG_USER="${PG_USER:-keycloak}"
SNAP_NAME="${SNAP_NAME:-demo-before-drop}"
NODE="${NODE:-$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')}"
PVC="postgres-data-${STS}-0"

hr() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

# Helper: POST to Longhorn REST API via an ephemeral curl pod in longhorn-system.
lh_api() {
  local path=$1 body=$2
  kubectl -n "$NS_LH" run lh-api-$RANDOM --rm -i --restart=Never --quiet \
    --image=curlimages/curl:8.9.1 --command -- \
    sh -c "curl -fsS -XPOST 'http://longhorn-backend:9500${path}' \
      -H 'content-type: application/json' -d '${body}'"
}

PV=$(kubectl -n "$NS_APP" get pvc "$PVC" -o jsonpath='{.spec.volumeName}')
hr "volume for ${PVC}: $PV"

hr "clean up artifacts from a previous run (idempotent)"
# Snapshot with the same name → Longhorn returns 500 on snapshotCreate.
# PVC clone with the same name → kubectl apply is fine, but delete for a
# clean re-run so the "new PV" step produces a fresh one.
if kubectl -n "$NS_LH" get snapshot.longhorn.io "$SNAP_NAME" >/dev/null 2>&1; then
  kubectl -n "$NS_LH" delete snapshot.longhorn.io "$SNAP_NAME" --wait=false || true
fi
if kubectl -n "$NS_LH" get backup.longhorn.io postgres-demo-backup >/dev/null 2>&1; then
  kubectl -n "$NS_LH" delete backup.longhorn.io postgres-demo-backup --wait=false || true
fi
if kubectl -n "$NS_APP" get pvc postgres-data-clone >/dev/null 2>&1; then
  kubectl -n "$NS_APP" delete pvc postgres-data-clone --wait=false || true
fi
# Give the finalizers a moment.
sleep 3

hr "seed test data"
kubectl -n "$NS_APP" exec "${STS}-0" -- psql -U "$PG_USER" <<'SQL'
CREATE TABLE IF NOT EXISTS test_data (id serial, name text, created_at timestamp default now());
TRUNCATE test_data;
INSERT INTO test_data (name) VALUES ('before-snapshot-1'), ('before-snapshot-2');
SELECT * FROM test_data;
SQL

hr "take snapshot $SNAP_NAME via Longhorn API"
lh_api "/v1/volumes/$PV?action=snapshotCreate" "{\"name\":\"$SNAP_NAME\"}" >/dev/null
echo "snapshot created"

hr "drop the table"
kubectl -n "$NS_APP" exec "${STS}-0" -- psql -U "$PG_USER" -c "DROP TABLE test_data;"

hr "pause ArgoCD auto-sync (both root-apps and helm-app)"
# root-apps reconciles helm-app back if we only patch helm-app, so disable both.
kubectl -n argocd patch application root-apps --type json \
  -p='[{"op":"remove","path":"/spec/syncPolicy/automated"}]' 2>/dev/null || true
kubectl -n argocd patch application helm-app --type json \
  -p='[{"op":"remove","path":"/spec/syncPolicy/automated"}]' 2>/dev/null || true

hr "scale Postgres to 0 and wait for volume to fully detach"
kubectl -n "$NS_APP" scale statefulset "$STS" --replicas=0
for _ in $(seq 1 40); do
  STATE=$(kubectl -n "$NS_LH" get volume "$PV" -o jsonpath='{.status.state}' 2>/dev/null || echo "")
  [[ "$STATE" == "detached" ]] && break
  sleep 3
done
echo "state: $(kubectl -n "$NS_LH" get volume "$PV" -o jsonpath='{.status.state}')"

hr "attach in maintenance mode (disableFrontend=true)"
lh_api "/v1/volumes/$PV?action=attach" "{\"hostId\":\"$NODE\",\"disableFrontend\":true}" >/dev/null
for _ in $(seq 1 20); do
  STATE=$(kubectl -n "$NS_LH" get volume "$PV" -o jsonpath='{.status.state}')
  [[ "$STATE" == "attached" ]] && break
  sleep 2
done

hr "revert to snapshot $SNAP_NAME"
lh_api "/v1/volumes/$PV?action=snapshotRevert" "{\"name\":\"$SNAP_NAME\"}" >/dev/null

hr "detach and bring Postgres back"
lh_api "/v1/volumes/$PV?action=detach" '{}' >/dev/null
for _ in $(seq 1 20); do
  STATE=$(kubectl -n "$NS_LH" get volume "$PV" -o jsonpath='{.status.state}')
  [[ "$STATE" == "detached" ]] && break
  sleep 2
done
kubectl -n "$NS_APP" scale statefulset "$STS" --replicas=1
# rollout status waits for the pod to both exist AND become Ready — unlike
# `kubectl wait pod/...` which errors immediately if the pod doesn't exist yet.
kubectl -n "$NS_APP" rollout status statefulset/"$STS" --timeout=3m

hr "verify test_data is back"
kubectl -n "$NS_APP" exec "${STS}-0" -- psql -U "$PG_USER" -c "SELECT * FROM test_data;"

hr "re-enable ArgoCD auto-sync"
kubectl -n argocd patch application root-apps --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true},"syncOptions":["CreateNamespace=true"]}}}'
kubectl -n argocd patch application helm-app --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true},"syncOptions":["CreateNamespace=true"]}}}'

hr "create PVC clone (new PV seeded from current)"
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-data-clone
  namespace: $NS_APP
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: longhorn
  resources:
    requests:
      storage: 1Gi
  dataSource:
    kind: PersistentVolumeClaim
    name: $PVC
EOF
kubectl -n "$NS_APP" wait pvc/postgres-data-clone \
  --for=jsonpath='{.status.phase}'=Bound --timeout=3m

hr "trigger an off-cluster backup of the current volume"
# Needs a fresh snapshot to back up from — use the one we just reverted to if
# it's still the latest, otherwise make a new one first.
SNAP_ID=$(kubectl -n "$NS_LH" get snapshot.longhorn.io \
  --no-headers -o custom-columns=n:.metadata.name,v:.spec.volume 2>/dev/null \
  | awk -v vol="$PV" '$2 == vol {print $1; exit}')
: "${SNAP_ID:?no snapshot found for $PV}"
kubectl apply -f - <<EOF
apiVersion: longhorn.io/v1beta2
kind: Backup
metadata:
  name: postgres-demo-backup
  namespace: $NS_LH
  labels:
    backup-volume: $PV
spec:
  snapshotName: $SNAP_ID
EOF

# wait for the backup to land
for _ in $(seq 1 60); do
  STATE=$(kubectl -n "$NS_LH" get backup postgres-demo-backup -o jsonpath='{.status.state}' 2>/dev/null || echo "")
  [[ "$STATE" == "Completed" ]] && break
  sleep 3
done

hr "final state"
kubectl -n "$NS_APP" get pvc
kubectl -n "$NS_LH" get volumes
kubectl -n "$NS_LH" get backup
kubectl -n "$NS_LH" get backupvolume
