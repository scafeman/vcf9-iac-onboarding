# Teardown VM App — Infrastructure Asset Tracker

## Overview

`teardown-vm-app.sh` reverses everything created by `deploy-vm-app.sh`, deleting all VM app resources in the correct dependency order. It is the "spin down" half of the VM app lifecycle.

The script is fully non-interactive. All configuration is driven by the same environment variables as the deploy script (loaded from `.env` via Docker Compose). No user input or confirmation prompts are required.

---

## What the Script Does

### Phase 1: Delete Application Namespace in Guest Cluster

Switches to the guest cluster kubeconfig and deletes the application namespace (default: `vm-app`). This cascading delete removes all resources within the namespace:

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

Optional: `VM_NAME` (default: `postgresql-vm`), `APP_NAMESPACE` (default: `vm-app`), `VM_TIMEOUT` (default: `600`), `POLL_INTERVAL` (default: `30`), `KUBECONFIG_FILE` (default: `./kubeconfig-<CLUSTER_NAME>.yaml`).

---

## How to Trigger

### Docker exec (recommended)

```bash
docker exec vcf9-dev bash examples/deploy-vm-app/teardown-vm-app.sh
```

### GitHub Actions

The teardown can be triggered by adding a teardown job to the workflow, or by running the script manually on the self-hosted runner.

### curl (repository_dispatch)

A dedicated teardown workflow can be created following the same pattern as the deploy workflow, using event type `teardown-vm-app`.

---

## Expected Output

A successful run produces output like this:

```
[Step 1] Deleting application namespace 'vm-app' in guest cluster...
✓ Namespace 'vm-app' deleted (includes Frontend + API Deployments and Services)
[Step 2] Deleting VirtualMachine 'postgresql-vm' in supervisor namespace 'my-project-ns'...
✓ VirtualMachine 'postgresql-vm' delete command issued
  Waiting for VirtualMachine 'postgresql-vm' to be deleted... (0s/600s elapsed)
  Waiting for VirtualMachine 'postgresql-vm' to be deleted... (30s/600s elapsed)
✓ VirtualMachine 'postgresql-vm' fully terminated

=============================================
  VCF 9 VM App — Teardown Complete
=============================================
  Cluster:        my-project-01-clus-01
  Namespace:      vm-app (deleted)
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
