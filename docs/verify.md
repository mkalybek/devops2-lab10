# Verification flow

Proves each grade tier actually works. Run from the Mac with `KUBECONFIG=$HOME/.kube/lab10` exported.

## Edge — Longhorn + Postgres on a Longhorn PVC

```bash
kubectl get nodes                                 # 1 node, Ready
kubectl get storageclass                          # longhorn (default)
kubectl -n longhorn-system get pods               # all Running
kubectl -n app get statefulset,pvc,pod            # helm-app-postgres ready
kubectl -n app get pvc -o wide                    # RWO, Bound, StorageClass=longhorn
kubectl -n longhorn-system get volumes            # 1 volume matching the PVC
```

Seed data:
```bash
kubectl -n app exec -it helm-app-postgres-0 -- psql -U keycloak -c "
  CREATE TABLE test_data (id serial, name text, created_at timestamp default now());
  INSERT INTO test_data (name) VALUES ('before-snapshot-1'), ('before-snapshot-2');
  SELECT * FROM test_data;
"
```

## Target — 5-min snapshots, drop + restore, PVC clone

### Snapshots fire every 5 minutes

`longhorn/snapshot-recurring-job.yaml` attaches to PVCs labeled with
`recurring-job-group.longhorn.io/default: enabled`. The Postgres chart adds
that label to its `volumeClaimTemplates`, so snapshots flow automatically.

```bash
kubectl -n longhorn-system get recurringjob
# NAME            GROUPS      TASK       CRON            RETAIN   CONCURRENCY
# snapshot-5min   [default]   snapshot   */5 * * * *     5        1

# Longhorn UI → Volume → pvc-<uuid> → Snapshots (new one every ~5 min)
kubectl -n longhorn-system port-forward svc/longhorn-frontend 9000:80
```

### Drop data, restore from snapshot

Disable ArgoCD self-heal on the helm-app so it doesn't scale Postgres back up
while we're swapping the volume underneath it:

```bash
kubectl -n argocd patch application helm-app --type merge \
  -p '{"spec":{"syncPolicy":null}}'

# destroy table, confirm loss
kubectl -n app exec -it helm-app-postgres-0 -- psql -U keycloak -c "DROP TABLE test_data;"

# scale down the pod so the volume detaches
kubectl -n app scale statefulset helm-app-postgres --replicas=0
kubectl -n app wait --for=delete pod/helm-app-postgres-0 --timeout=2m

# In Longhorn UI: Volume → this volume → Snapshots → pick one before the drop
#                → Revert.  (Must be in "Detached" state to revert.)

# Scale back up
kubectl -n app scale statefulset helm-app-postgres --replicas=1
kubectl -n app wait --for=condition=Ready pod/helm-app-postgres-0 --timeout=3m

# Data is back
kubectl -n app exec -it helm-app-postgres-0 -- psql -U keycloak -c "SELECT * FROM test_data;"

# Re-enable GitOps
kubectl -n argocd patch application helm-app --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
```

### Clone PVC into a new PV

Longhorn supports volume cloning via the CSI `dataSource` field. This creates
a brand-new PV seeded from the current state of the source PVC — useful for
spinning up a throwaway copy without touching production.

```bash
SRC_PVC=$(kubectl -n app get pvc -o jsonpath='{.items[0].metadata.name}')
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-data-clone
  namespace: app
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: longhorn
  resources:
    requests:
      storage: 1Gi
  dataSource:
    kind: PersistentVolumeClaim
    name: $SRC_PVC
EOF

kubectl -n app get pvc postgres-data-clone -w   # wait for Bound
kubectl -n longhorn-system get volumes          # now 2 volumes
```

You now have a second PV on the same node with an independent copy of the
Postgres data — verifying the "make a new pv as copy of current" requirement.

## Perfection — off-cluster backup to MinIO (S3)

```bash
# Longhorn backup target points at MinIO
kubectl -n longhorn-system get setting backup-target backup-target-credential-secret
# backup-target                         s3://longhorn-backups@us-east-1/
# backup-target-credential-secret       minio-backup-secret

# Backup RecurringJob
kubectl -n longhorn-system get recurringjob backup-5min

# After 5 minutes, backups appear in MinIO
kubectl -n minio port-forward svc/minio-console 9090:9090
# http://localhost:9090 — browse bucket "longhorn-backups"

# In the Longhorn UI: Backup tab shows the volume's backups. Click one →
# "Restore Latest Backup" → creates a brand-new volume from the off-cluster
# backup, surviving even if the original PV is wiped.
```

## Useful one-liners

```bash
kubectl top nodes                                   # sanity on memory headroom
kubectl describe nodes | grep -A5 'Allocated resources'
kubectl -n argocd get applications                  # all Synced/Healthy
kubectl -n longhorn-system get backups              # backup history
```
