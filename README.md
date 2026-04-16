# Lab 10 — Longhorn on single-node k3s

Replicates [`reference/`](reference/) with two simplifications vs the original:

1. **Nginx** replaces Keycloak as the demo workload (Postgres stays — it's the thing with persistent storage).
2. **One** multipass node (`gainful-skater`) instead of three.

The stack is otherwise the same: k3s → ArgoCD → apps-of-apps → Longhorn + Postgres + Nginx + MinIO. Everything after ArgoCD is GitOps-driven from this repo.

## Grade tiers

| Tier | Requirement | Where it lives |
|------|-------------|----------------|
| Edge (1) | Longhorn installed, Postgres on a Longhorn PVC | [apps-of-apps/longhorn-app.yaml](apps-of-apps/longhorn-app.yaml), [helm-charts/my-chart/charts/postgres/templates/statefulset.yaml](helm-charts/my-chart/charts/postgres/templates/statefulset.yaml) |
| Target (2.5) | Snapshot every 5 min, drop + restore, clone PVC | [longhorn/snapshot-recurring-job.yaml](longhorn/snapshot-recurring-job.yaml), [docs/verify.md](docs/verify.md) |
| Perfection | Off-site backup target (MinIO S3) | [apps-of-apps/minio-app.yaml](apps-of-apps/minio-app.yaml), [longhorn/backup-target.yaml](longhorn/backup-target.yaml), [longhorn/backup-recurring-job.yaml](longhorn/backup-recurring-job.yaml) |

## Directory layout

```
lab10/
├── argocd/root-app.yaml            # bootstraps everything else
├── apps-of-apps/                   # one ArgoCD Application per component
├── helm-charts/my-chart/           # umbrella chart: postgres + nginx
├── longhorn/                       # RecurringJobs + backup target Setting
├── bootstrap/                      # one-shot scripts run on your Mac
└── reference/                      # original multi-node reference, untouched
```

## Bootstrap

Prerequisites on the Mac: `multipass`, `gh` (logged in as `mkalybek`), `git`.

```bash
# 1. Provision the VM (k3s + Longhorn host deps, grabs kubeconfig → ~/.kube/lab10)
./bootstrap/01-provision-vm.sh

# 2. Point kubectl at the cluster
export KUBECONFIG=$HOME/.kube/lab10

# 3. Install ArgoCD + create credential Secrets + apply root-app
./bootstrap/02-install-argocd.sh
./bootstrap/03-create-secrets.sh
./bootstrap/04-apply-root.sh
```

See [docs/verify.md](docs/verify.md) for the test flow (seed data → snapshot → drop → restore → clone → MinIO backup).

## UIs

```bash
kubectl port-forward -n argocd          svc/argocd-server      8080:443
kubectl port-forward -n longhorn-system svc/longhorn-frontend  9000:80
kubectl port-forward -n minio           svc/minio-console      9090:9090
```

| UI | URL | Credentials |
|----|-----|-------------|
| ArgoCD | https://localhost:8080 | `admin` / `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' \| base64 -d` |
| Longhorn | http://localhost:9000 | (no auth by default) |
| MinIO Console | http://localhost:9090 | values from `bootstrap/03-create-secrets.sh` (default `minio-admin` / `minio-change-me`) |
