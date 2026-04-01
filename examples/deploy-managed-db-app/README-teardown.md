# Teardown Managed DB App — Infrastructure Asset Tracker

## Overview

`teardown-managed-db-app.sh` reverses everything created by `deploy-managed-db-app.sh`, deleting all Managed DB App resources in the correct dependency order. It is the "spin down" half of the Managed DB App lifecycle.

The script is fully non-interactive. All configuration is driven by the same environment variables as the deploy script (loaded from `.env` via Docker Compose). No user input or confirmation prompts are required.

---

## What the Script Does

### Phase 1: Delete Application Namespace in Guest Cluster

Switches to the guest cluster kubeconfig and deletes the application namespace (default: `managed-db-app`). This cascading delete removes all resources within the namespace:

- Frontend LoadBalancer Service (releases the NSX external IP)
- Frontend Deployment (terminates the dashboard pod)
- API ClusterIP Service
- API Deployment (terminates the API pod)

If the kubeconfig file is not found (e.g., the cluster was already torn down), the script attempts to retrieve it via VCF CLI. If that also fails, this phase is skipped gracefully.

### Phase 2: Delete PostgresCluster in Supervisor Namespace

Ensures the VCF CLI context is active, then deletes the PostgresCluster resource from the supervisor namespace:

```
kubectl delete postgrescluster postgres-01 -n <SUPERVISOR_NAMESPACE> --ignore-not-found
```

Waits for the PostgresCluster to be fully terminated within the configured timeout (default: 900s, polling every 30s). DSM deprovisions the managed PostgreSQL instance and releases compute resources during this time.

If the PostgresCluster does not exist, this phase is skipped.

### Phase 3: Delete Admin Password Secret in Supervisor Namespace

Deletes the admin password Secret and the DSM-created password secret (`pg-<cluster-name>`):

```
kubectl delete secret postgres-admin-password -n <SUPERVISOR_NAMESPACE> --ignore-not-found
kubectl delete secret pg-postgres-01 -n <SUPERVISOR_NAMESPACE> --ignore-not-found
```

If the secrets do not exist, this phase is skipped.

---

## Prerequisites

- Docker and Docker Compose installed
- The `vcf9-dev` container running (`docker compose up -d`)
- A populated `.env` file with the same variables used by the deploy script

---

## Required Environment Variables

The teardown script uses a subset of the deploy script's variables:

| Variable | Description | Example |
|---|---|---|
| `CLUSTER_NAME` | VKS guest cluster name | `my-project-01-clus-01` |
| `SUPERVISOR_NAMESPACE` | Supervisor namespace where the PostgresCluster was provisioned | `my-project-ns` |
| `VCF_API_TOKEN` | API token from the VCFA portal | `uT3s3jCY8GIPzK...` |
| `VCFA_ENDPOINT` | VCFA hostname (no `https://` prefix) | `vcfa01.vmw-lab1.example.com` |
| `TENANT_NAME` | SSO tenant/organization | `org-rax-01` |
| `CONTEXT_NAME` | Local VCF CLI context name | `my-dev-automation` |

Optional: `DSM_CLUSTER_NAME` (default: `postgres-01`), `ADMIN_PASSWORD_SECRET_NAME` (default: `postgres-admin-password`), `APP_NAMESPACE` (default: `managed-db-app`), `DSM_TIMEOUT` (default: `900`), `POLL_INTERVAL` (default: `30`), `KUBECONFIG_FILE` (default: `./kubeconfig-<CLUSTER_NAME>.yaml`).

---

## How to Trigger

### GitHub Actions (recommended)

The Managed DB App teardown is integrated into the **Teardown VCF Stacks** workflow:

1. Go to **Actions** → **"Teardown VCF Stacks"** → **"Run workflow"**
2. Enter the **cluster_name**
3. Ensure **"Tear down the Managed DB App stack"** is checked
4. Optionally uncheck other stacks if you only want to tear down the Managed DB App

The workflow automatically discovers the supervisor namespace from the cluster name and handles kubeconfig retrieval — no additional inputs needed.

### Docker exec (local)

When running locally, you must pass `CLUSTER_NAME` and `SUPERVISOR_NAMESPACE` explicitly:

```bash
docker exec \
  -e CLUSTER_NAME=gh-actions-demo-01-clus-01 \
  -e SUPERVISOR_NAMESPACE=gh-actions-demo-01-ns-6dxm9 \
  vcf9-dev bash examples/deploy-managed-db-app/teardown-managed-db-app.sh
```

### Trigger script (repository_dispatch)

```bash
./scripts/trigger-teardown.sh \
  --repo myorg/vcf9-iac \
  --token ghp_xxxxxxxxxxxx \
  --cluster-name gh-actions-demo-01-clus-01 \
  --teardown-gitops false \
  --teardown-metrics false \
  --teardown-cluster false
```

This tears down only the Managed DB App stack while leaving everything else intact.

---

## Expected Output

A successful run produces output like this:

```
[Step 1] Deleting application namespace 'managed-db-app' in guest cluster...
✓ Namespace 'managed-db-app' deleted (includes Frontend + API Deployments and Services)
[Step 2] Deleting PostgresCluster 'postgres-01' in supervisor namespace 'my-project-ns'...
✓ PostgresCluster 'postgres-01' delete command issued
  Waiting for PostgresCluster 'postgres-01' to be deleted... (0s/900s elapsed)
  Waiting for PostgresCluster 'postgres-01' to be deleted... (30s/900s elapsed)
✓ PostgresCluster 'postgres-01' fully deleted
[Step 3] Deleting admin password Secret 'postgres-admin-password' in supervisor namespace 'my-project-ns'...
✓ Admin password Secret 'postgres-admin-password' deleted
✓ DSM-created Secret 'pg-postgres-01' cleaned up

=============================================
  VCF 9 Managed DB App — Teardown Complete
=============================================
  Cluster:          my-project-01-clus-01
  Namespace:        managed-db-app (deleted)
  PostgresCluster:  postgres-01 (deleted)
  Admin Secret:     postgres-admin-password (deleted)
=============================================
```

---

## Typical Timing

| Phase | Duration |
|---|---|
| Phase 1 (Namespace deletion) | 10–30s |
| Phase 2 (PostgresCluster termination) | 2–10 min |
| Phase 3 (Secret deletion) | ~5s |
| **Total** | **~2–11 min** |

---

## Idempotency

The teardown script is safe to run multiple times. If resources are already deleted, each phase skips gracefully:

- Missing kubeconfig → attempts retrieval via VCF CLI, skips guest cluster cleanup if unavailable
- Missing namespace → logs "already absent", continues
- Missing PostgresCluster → logs "already absent", continues
- Missing admin password Secret → logs "already absent", continues
- Deletion failures → logs a warning and continues to the next resource (does not abort)
- `--ignore-not-found` flag on all `kubectl delete` commands prevents errors on re-runs

The teardown summary reports per-resource status: **deleted**, **already absent**, or **failed**.
