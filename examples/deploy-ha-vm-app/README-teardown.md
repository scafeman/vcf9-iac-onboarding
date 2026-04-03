# Teardown HA VM App — High-Availability Three-Tier Application

## Overview

`teardown-ha-vm-app.sh` reverses everything created by `deploy-ha-vm-app.sh`, deleting all HA VM app resources in the correct reverse dependency order. It is the "spin down" half of the HA VM app lifecycle.

The script is fully non-interactive. All configuration is driven by the same environment variables as the deploy script (loaded from `.env` via Docker Compose). No user input or confirmation prompts are required.

---

## What the Script Does

### Phase 1: Delete Web Tier VirtualMachineService LoadBalancer

Deletes the `ha-web-lb` VirtualMachineService from the supervisor namespace. This releases the NSX LoadBalancer external IP and removes the port 80 mapping.

```
kubectl delete virtualmachineservice ha-web-lb -n <SUPERVISOR_NAMESPACE> --ignore-not-found
```

If the VirtualMachineService does not exist, this phase logs "already absent" and continues.

### Phase 2: Delete Web Tier VMs + Cloud-Init Secrets

Deletes `web-vm-01` and `web-vm-02` VirtualMachine resources and their corresponding `*-cloud-init` Secrets from the supervisor namespace. Waits for each VM to be fully terminated within the configured timeout (default: 600s, polling every 30s).

```
kubectl delete virtualmachine web-vm-01 -n <SUPERVISOR_NAMESPACE> --ignore-not-found
kubectl delete secret web-vm-01-cloud-init -n <SUPERVISOR_NAMESPACE> --ignore-not-found
kubectl delete virtualmachine web-vm-02 -n <SUPERVISOR_NAMESPACE> --ignore-not-found
kubectl delete secret web-vm-02-cloud-init -n <SUPERVISOR_NAMESPACE> --ignore-not-found
```

If a VM or Secret does not exist, the phase logs "already absent" and continues.

### Phase 3: Delete API Tier VirtualMachineService

Deletes the `ha-api-internal` VirtualMachineService from the supervisor namespace. This removes the internal API VIP.

```
kubectl delete virtualmachineservice ha-api-internal -n <SUPERVISOR_NAMESPACE> --ignore-not-found
```

### Phase 4: Delete API Tier VMs + Cloud-Init Secrets

Deletes `api-vm-01` and `api-vm-02` VirtualMachine resources and their corresponding `*-cloud-init` Secrets. Waits for each VM to be fully terminated within the configured timeout.

```
kubectl delete virtualmachine api-vm-01 -n <SUPERVISOR_NAMESPACE> --ignore-not-found
kubectl delete secret api-vm-01-cloud-init -n <SUPERVISOR_NAMESPACE> --ignore-not-found
kubectl delete virtualmachine api-vm-02 -n <SUPERVISOR_NAMESPACE> --ignore-not-found
kubectl delete secret api-vm-02-cloud-init -n <SUPERVISOR_NAMESPACE> --ignore-not-found
```

### Phase 5: Delete DSM PostgresCluster + Admin Password Secret

Deletes the PostgresCluster resource, the DSM-created password secret (`pg-<cluster-name>`), and the admin password Secret.

```
kubectl delete postgrescluster <DSM_CLUSTER_NAME> -n <SUPERVISOR_NAMESPACE> --ignore-not-found --wait=false
kubectl delete secret pg-<DSM_CLUSTER_NAME> -n <SUPERVISOR_NAMESPACE> --ignore-not-found
kubectl delete secret <ADMIN_PASSWORD_SECRET_NAME> -n <SUPERVISOR_NAMESPACE> --ignore-not-found
```

Waits for the PostgresCluster to be fully deleted within the configured timeout.

---

## Prerequisites

- Docker and Docker Compose installed
- The `vcf9-dev` container running (`docker compose up -d`)
- A populated `.env` file with the same variables used by the deploy script

---

## Required Environment Variables

The teardown script uses a subset of the deploy script's variables:

| Variable | Required | Default | Description |
|---|---|---|---|
| `VCF_API_TOKEN` | Yes | — | API token from the VCFA portal |
| `VCFA_ENDPOINT` | Yes | — | VCFA hostname (no `https://` prefix) |
| `TENANT_NAME` | Yes | — | SSO tenant/organization |
| `CONTEXT_NAME` | Yes | — | Local VCF CLI context name |
| `SUPERVISOR_NAMESPACE` | Yes | — | Supervisor namespace where resources were provisioned |
| `CLUSTER_NAME` | No | — | Cluster name (used for namespace context fallback) |
| `DSM_CLUSTER_NAME` | No | `postgres-clus-01` | PostgresCluster resource name |
| `ADMIN_PASSWORD_SECRET_NAME` | No | `admin-pw-pg-clus-01` | Name of the admin password Secret |
| `VM_TIMEOUT` | No | `600` | Seconds to wait for VM deletion |
| `POLL_INTERVAL` | No | `30` | Seconds between polling attempts |

---

## How to Trigger

### Docker exec (recommended)

```bash
docker exec vcf9-dev bash examples/deploy-ha-vm-app/teardown-ha-vm-app.sh
```

### GitHub Actions (Teardown VCF Stacks workflow)

1. Go to **Actions** → **Teardown VCF Stacks** → **Run workflow**
2. Enter the **cluster_name**
3. Ensure the HA VM App teardown phase is enabled
4. Click **Run workflow**

---

## Expected Output

A successful run produces output like this:

```
[Step 0] Creating VCF CLI context and switching to supervisor namespace...
✓ VCF CLI context 'my-context' created, switched to namespace context 'my-context:my-project-ns'
[Step 1] Deleting VirtualMachineService 'ha-web-lb' in namespace 'my-project-ns'...
✓ VirtualMachineService 'ha-web-lb' deleted
[Step 2] Deleting VirtualMachine 'web-vm-01' in namespace 'my-project-ns'...
✓ VirtualMachine 'web-vm-01' delete command issued
  Waiting for VirtualMachine 'web-vm-01' to be deleted... (0s/600s elapsed)
✓ VirtualMachine 'web-vm-01' fully terminated
[Step 2] Deleting cloud-init Secret 'web-vm-01-cloud-init' in namespace 'my-project-ns'...
✓ Secret 'web-vm-01-cloud-init' deleted
[Step 2] Deleting VirtualMachine 'web-vm-02' in namespace 'my-project-ns'...
✓ VirtualMachine 'web-vm-02' delete command issued
  Waiting for VirtualMachine 'web-vm-02' to be deleted... (0s/600s elapsed)
✓ VirtualMachine 'web-vm-02' fully terminated
[Step 2] Deleting cloud-init Secret 'web-vm-02-cloud-init' in namespace 'my-project-ns'...
✓ Secret 'web-vm-02-cloud-init' deleted
[Step 3] Deleting VirtualMachineService 'ha-api-internal' in namespace 'my-project-ns'...
✓ VirtualMachineService 'ha-api-internal' deleted
[Step 4] Deleting VirtualMachine 'api-vm-01' in namespace 'my-project-ns'...
✓ VirtualMachine 'api-vm-01' delete command issued
  Waiting for VirtualMachine 'api-vm-01' to be deleted... (0s/600s elapsed)
✓ VirtualMachine 'api-vm-01' fully terminated
[Step 4] Deleting cloud-init Secret 'api-vm-01-cloud-init' in namespace 'my-project-ns'...
✓ Secret 'api-vm-01-cloud-init' deleted
[Step 4] Deleting VirtualMachine 'api-vm-02' in namespace 'my-project-ns'...
✓ VirtualMachine 'api-vm-02' delete command issued
  Waiting for VirtualMachine 'api-vm-02' to be deleted... (0s/600s elapsed)
✓ VirtualMachine 'api-vm-02' fully terminated
[Step 4] Deleting cloud-init Secret 'api-vm-02-cloud-init' in namespace 'my-project-ns'...
✓ Secret 'api-vm-02-cloud-init' deleted
[Step 5] Deleting PostgresCluster 'postgres-clus-01' in supervisor namespace 'my-project-ns'...
✓ PostgresCluster 'postgres-clus-01' delete command issued
✓ PostgresCluster 'postgres-clus-01' fully deleted
✓ DSM-created Secret 'pg-postgres-clus-01' cleaned up
[Step 5] Deleting admin password Secret 'admin-pw-pg-clus-01' in supervisor namespace 'my-project-ns'...
✓ Admin password Secret 'admin-pw-pg-clus-01' deleted

=============================================
  VCF 9 HA VM App — Teardown Complete
=============================================
  Namespace:          my-project-ns
  ha-web-lb:          (deleted)
  web-vm-01:          (deleted)
  web-vm-01-cloud-init: (deleted)
  web-vm-02:          (deleted)
  web-vm-02-cloud-init: (deleted)
  ha-api-internal:    (deleted)
  api-vm-01:          (deleted)
  api-vm-01-cloud-init: (deleted)
  api-vm-02:          (deleted)
  api-vm-02-cloud-init: (deleted)
  PostgresCluster:    postgres-clus-01 (deleted)
  Admin Secret:       admin-pw-pg-clus-01 (deleted)
=============================================
```

---

## Typical Timing

| Phase | Duration |
|---|---|
| Phase 1 (Web LB deletion) | ~5s |
| Phase 2 (Web VM termination × 2) | 2–10 min |
| Phase 3 (API service deletion) | ~5s |
| Phase 4 (API VM termination × 2) | 2–10 min |
| Phase 5 (PostgresCluster + Secrets deletion) | 1–5 min |
| **Total** | **~5–25 min** |

---

## Idempotency

The teardown script is safe to run multiple times. If resources are already deleted, each phase skips gracefully:

- Missing VirtualMachineService → logs "already absent", continues
- Missing VirtualMachine → logs "already absent", continues
- Missing Secret → logs "already absent", continues
- Missing PostgresCluster → logs "already absent", continues
- Deletion failures → logs a warning and continues to the next resource (does not abort)
- `--ignore-not-found` flag on all `kubectl delete` commands prevents errors on re-runs

The teardown summary reports per-resource status: **deleted**, **already absent**, or **failed**.

---

## Exit Codes

| Code | Failure Category |
|---|---|
| 0 | Success (all resources deleted or already absent) |
| 1 | Variable validation failure |

---

## Troubleshooting

### VM deletion times out

- Check VirtualMachine status: `kubectl get virtualmachine <VM_NAME> -n <SUPERVISOR_NAMESPACE> -o yaml`
- The VM may still be in a terminating state — VCF deprovisions the VM and releases compute resources
- Increase `VM_TIMEOUT` if the environment is slow to terminate VMs
- Check for finalizers that may be blocking deletion: `kubectl get virtualmachine <VM_NAME> -n <SUPERVISOR_NAMESPACE> -o jsonpath='{.metadata.finalizers}'`

### PostgresCluster deletion times out

- Check PostgresCluster status: `kubectl get postgrescluster <DSM_CLUSTER_NAME> -n <SUPERVISOR_NAMESPACE> -o yaml`
- DSM may take several minutes to fully deprovision the managed database
- The script uses `--wait=false` to issue the delete and then polls for completion

### Variable validation failure (exit 1)

- Ensure `VCF_API_TOKEN`, `VCFA_ENDPOINT`, `TENANT_NAME`, `CONTEXT_NAME`, and `SUPERVISOR_NAMESPACE` are set
- These can be set in the `.env` file or passed as environment variables to `docker exec`

### Monitor during teardown

```bash
# Watch VM deletion
docker exec vcf9-dev kubectl get virtualmachines -n <SUPERVISOR_NAMESPACE> -w

# Watch PostgresCluster deletion
docker exec vcf9-dev kubectl get postgrescluster -n <SUPERVISOR_NAMESPACE> -w

# Check remaining resources
docker exec vcf9-dev kubectl get virtualmachine,virtualmachineservice,postgrescluster,secret -n <SUPERVISOR_NAMESPACE>
```
