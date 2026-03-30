# Teardown Hybrid App — Infrastructure Asset Tracker

## Overview

`teardown-hybrid-app.sh` reverses everything created by `deploy-hybrid-app.sh`, deleting all Hybrid App resources in the correct dependency order. It is the "spin down" half of the Hybrid App lifecycle.

The script is fully non-interactive. All configuration is driven by the same environment variables as the deploy script (loaded from `.env` via Docker Compose). No user input or confirmation prompts are required.

---

## What the Script Does

### Phase 1: Delete Application Namespace in Guest Cluster

Switches to the guest cluster kubeconfig and deletes the application namespace (default: `hybrid-app`). This cascading delete removes all resources within the namespace:

- Frontend LoadBalancer Service (releases the NSX external IP)
- Frontend Deployment (terminates the dashboard pod)
- API ClusterIP Service
- API Deployment (terminates the API pod)

If the kubeconfig file is not found (e.g., the cluster was already torn down), this phase is skipped gracefully.

### Phase 2: Delete VirtualMachine in Supervisor Namespace

Ensures the VCF CLI context is active, then deletes the VirtualMachine resource from the supervisor namespace:

```
kubectl delete virtualmachine postgresql-vm -n <SUPERVISOR_NAMESPACE> --ignore-not-found
```

Waits for the VM to be fully terminated within the configured timeout (default: 600s, polling every 30s). VCF deprovisions the VM and releases compute resources during this time.

If the VirtualMachine does not exist, this phase is skipped.

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
| `SUPERVISOR_NAMESPACE` | Supervisor namespace where the VM was provisioned | `my-project-ns` |
| `VCF_API_TOKEN` | API token from the VCFA portal | `uT3s3jCY8GIPzK...` |
| `VCFA_ENDPOINT` | VCFA hostname (no `https://` prefix) | `vcfa01.vmw-lab1.example.com` |
| `TENANT_NAME` | SSO tenant/organization | `org-rax-01` |
| `CONTEXT_NAME` | Local VCF CLI context name | `my-dev-automation` |

Optional: `VM_NAME` (default: `postgresql-vm`), `APP_NAMESPACE` (default: `hybrid-app`), `VM_TIMEOUT` (default: `600`), `POLL_INTERVAL` (default: `30`), `KUBECONFIG_FILE` (default: `./kubeconfig-<CLUSTER_NAME>.yaml`).

---

## How to Trigger

### GitHub Actions (recommended)

The Hybrid App teardown is integrated into the **Teardown VCF Stacks** workflow:

1. Go to **Actions** → **"Teardown VCF Stacks"** → **"Run workflow"**
2. Enter the **cluster_name**
3. Ensure **"Tear down the Hybrid App stack"** is checked
4. Optionally uncheck other stacks (GitOps, Metrics, Cluster) if you only want to tear down the Hybrid App

The workflow automatically discovers the supervisor namespace from the cluster name and handles kubeconfig retrieval — no additional inputs needed.

### Docker exec (local)

When running locally, you must pass `CLUSTER_NAME` and `SUPERVISOR_NAMESPACE` explicitly:

```bash
docker exec \
  -e CLUSTER_NAME=gh-actions-demo-01-clus-01 \
  -e SUPERVISOR_NAMESPACE=gh-actions-demo-01-ns-6dxm9 \
  vcf9-dev bash examples/deploy-hybrid-app/teardown-hybrid-app.sh
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

This tears down only the Hybrid App stack while leaving everything else intact.

---

## Expected Output

A successful run produces output like this:

```
[Step 1] Deleting application namespace 'hybrid-app' in guest cluster...
✓ Namespace 'hybrid-app' deleted (includes Frontend + API Deployments and Services)
[Step 2] Deleting VirtualMachine 'postgresql-vm' in supervisor namespace 'my-project-ns'...
✓ VirtualMachine 'postgresql-vm' delete command issued
  Waiting for VirtualMachine 'postgresql-vm' to be deleted... (0s/600s elapsed)
  Waiting for VirtualMachine 'postgresql-vm' to be deleted... (30s/600s elapsed)
✓ VirtualMachine 'postgresql-vm' fully terminated

=============================================
  VCF 9 Hybrid App — Teardown Complete
=============================================
  Cluster:        my-project-01-clus-01
  Namespace:      hybrid-app (deleted)
  VirtualMachine: postgresql-vm (deleted)
=============================================
```

---

## Typical Timing

| Phase | Duration |
|---|---|
| Phase 1 (Namespace deletion) | 10–30s |
| Phase 2 (VM termination) | 1–5 min |
| **Total** | **~1–6 min** |

---

## Idempotency

The teardown script is safe to run multiple times. If resources are already deleted, each phase skips gracefully:

- Missing kubeconfig → skips guest cluster namespace cleanup
- Missing namespace → logs "already absent", continues
- Missing VirtualMachine → logs "already absent", continues
- Deletion failures → logs a warning and continues to the next resource (does not abort)
- `--ignore-not-found` flag on all `kubectl delete` commands prevents errors on re-runs

The teardown summary reports per-resource status: **deleted**, **already absent**, or **failed**.
