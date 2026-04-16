# Verification flow

Proves each grade tier works. Run from the Mac with `KUBECONFIG=$HOME/.kube/lab10` exported.

## Edge — Longhorn installed + Postgres on a Longhorn PVC

```bash
kubectl get nodes                                   # 1 node Ready
kubectl get storageclass                            # longhorn (default)
kubectl -n longhorn-system get pods                 # csi-*, instance-manager, etc. Running
kubectl -n app get statefulset,pvc,pod              # helm-app-postgres-0 Ready
kubectl -n app get pvc -o wide                      # RWO, Bound, StorageClass=longhorn
kubectl -n longhorn-system get volumes              # attached, healthy
```

Seed some test data:
```bash
kubectl -n app exec -it helm-app-postgres-0 -- psql -U keycloak -c "
  CREATE TABLE test_data (id serial, name text, created_at timestamp default now());
  INSERT INTO test_data (name) VALUES ('before-snapshot-1'), ('before-snapshot-2');
  SELECT * FROM test_data;
"
```

## Target — 5-min snapshots, drop + restore, PVC clone

### Automated end-to-end demo

[`bootstrap/demo-restore.sh`](../bootstrap/demo-restore.sh) runs everything
below non-interactively:

```bash
./bootstrap/demo-restore.sh
```

### Snapshots fire every 5 minutes

`longhorn/snapshot-recurring-job.yaml` is a `RecurringJob` attached to the
`default` group; every Longhorn volume is in that group by default, so the
Postgres PV gets picked up automatically.

```bash
kubectl -n longhorn-system get recurringjob
# NAME            GROUPS      TASK       CRON            RETAIN   CONCURRENCY
# snapshot-5min   [default]   snapshot   */5 * * * *     5        1
# backup-5min     [default]   backup     */5 * * * *     3        1

kubectl -n longhorn-system get snapshot.longhorn.io
```

### Drop + restore (what `demo-restore.sh` does)

The StatefulSet must be scaled to 0 so the volume detaches before Longhorn
will let you revert. `root-apps` also reconciles `helm-app` back to its
declared state, so **both** Applications must have their `syncPolicy.automated`
removed before we scale, otherwise ArgoCD scales Postgres back up mid-revert.

The revert itself uses Longhorn's REST API (hit from an ephemeral curl pod
inside `longhorn-system`):

1. `scale sts/helm-app-postgres --replicas=0` and wait for volume to
   become `detached`
2. `POST /v1/volumes/$PV?action=attach {"hostId": NODE, "disableFrontend": true}`
   — attaches in **maintenance mode** (no frontend = no filesystem mount,
   safe to revert)
3. `POST /v1/volumes/$PV?action=snapshotRevert {"name": SNAPSHOT}`
4. `POST /v1/volumes/$PV?action=detach {}`
5. `scale sts/helm-app-postgres --replicas=1`

Verify the `test_data` rows are back:
```bash
kubectl -n app exec -it helm-app-postgres-0 -- psql -U keycloak -c "SELECT * FROM test_data;"
```

### Manual revert via the Longhorn UI (alternative)

```bash
kubectl -n longhorn-system port-forward svc/longhorn-frontend 9000:80
# http://localhost:9000 → Volume → pvc-<uuid> → Snapshots → Revert
```

The UI handles the maintenance-mode attach automatically. Still requires the
StatefulSet to be scaled to 0 first.

### Clone PVC into a new PV

Longhorn supports CSI volume cloning via the PVC `dataSource` field —
satisfies the "make a new pv as copy of current" requirement:

```yaml
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
    name: postgres-data-helm-app-postgres-0
```

```bash
kubectl -n app get pvc                  # postgres-data-clone Bound to a new PV
kubectl -n longhorn-system get volumes  # 2 postgres-sized volumes
```

## Perfection — off-cluster backup to MinIO (S3)

The Longhorn chart configures the backup target via
`defaultSettings.backupTarget` in [apps-of-apps/longhorn-app.yaml](../apps-of-apps/longhorn-app.yaml).
The credential secret (`minio-backup-secret` in `longhorn-system`) is
created by [bootstrap/03-create-secrets.sh](../bootstrap/03-create-secrets.sh).

```bash
kubectl -n longhorn-system get backuptarget default -o yaml | grep -E "backupTargetURL|credentialSecret|available"
# backupTargetURL: s3://longhorn-backups@us-east-1/
# credentialSecret: minio-backup-secret
# available: true
```

### Recurring backups fire every 5 minutes

```bash
kubectl -n longhorn-system get backup.longhorn.io
kubectl -n longhorn-system get backupvolume.longhorn.io
```

### Browse the MinIO bucket

```bash
kubectl -n minio port-forward svc/minio-console 9090:9090
# http://localhost:9090
# user/pass from minio-creds (default minio-admin / minio-change-me)
# bucket "longhorn-backups" → backupstore/volumes/<hash>/<pvc>/ contains the
# chunked .blk block files + backup_*.cfg metadata.
```

Or list via the `mc` CLI:
```bash
MINIO_USER=$(kubectl -n minio get secret minio-creds -o jsonpath='{.data.rootUser}' | base64 -d)
MINIO_PASS=$(kubectl -n minio get secret minio-creds -o jsonpath='{.data.rootPassword}' | base64 -d)
kubectl -n minio run mc --rm -it --restart=Never --image=minio/mc:latest \
  --env="MC_HOST_minio=http://${MINIO_USER}:${MINIO_PASS}@minio:9000" \
  --command -- sh -c 'mc ls --recursive minio/longhorn-backups | head -30'
```

### Restore from an off-cluster backup

In the Longhorn UI: `Backup` tab → select the volume → `Restore Latest Backup`.
This creates a brand-new volume seeded from the S3 backup — survives even if
the original PV and its snapshots are wiped from the cluster.
