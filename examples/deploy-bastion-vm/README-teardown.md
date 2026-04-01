# Teardown Bastion VM — SSH Jump Host

## Overview

`teardown-bastion-vm.sh` reverses everything created by `deploy-bastion-vm.sh`, deleting all bastion VM resources in the correct reverse dependency order. It is the "spin down" half of the bastion VM lifecycle.

The script is fully non-interactive. All configuration is driven by the same environment variables as the deploy script (loaded from `.env` via Docker Compose). No user input or confirmation prompts are required.

---

## What the Script Does

### Phase 1: Delete VirtualMachineService

Deletes the `<VM_NAME>-ssh` VirtualMachineService from the supervisor namespace. This releases the NSX LoadBalancer external IP and removes the SSH port mapping.

```
kubectl delete virtualmachineservice <VM_NAME>-ssh -n <SUPERVISOR_NAMESPACE> --ignore-not-found
```

If the VirtualMachineService does not exist, this phase logs "already absent" and continues.

### Phase 2: Delete VirtualMachine

Deletes the VirtualMachine resource from the supervisor namespace:

```
kubectl delete virtualmachine <VM_NAME> -n <SUPERVISOR_NAMESPACE> --ignore-not-found
```

Waits for the VM to be fully terminated within the configured timeout (default: 600s, polling every 30s). VCF deprovisions the VM and releases compute resources during this time.

If the VirtualMachine does not exist, this phase is skipped.

### Phase 3: Delete Data Disk PVC

Deletes the `<VM_NAME>-data` PersistentVolumeClaim from the supervisor namespace (if it exists). Strips the `kubernetes.io/pvc-protection` finalizer first to prevent stuck deletions when the PVC was still mounted.

```
kubectl patch pvc <VM_NAME>-data -n <SUPERVISOR_NAMESPACE> --type merge -p '{"metadata":{"finalizers":null}}'
kubectl delete pvc <VM_NAME>-data -n <SUPERVISOR_NAMESPACE> --ignore-not-found
```

If the PVC does not exist (no data disk was provisioned), this phase logs "already absent" and continues.

### Phase 4: Delete Cloud-Init Secret

Deletes the `<VM_NAME>-cloud-init` Secret from the supervisor namespace:

```
kubectl delete secret <VM_NAME>-cloud-init -n <SUPERVISOR_NAMESPACE> --ignore-not-found
```

If the Secret does not exist, this phase is skipped.

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
| `VCF_API_TOKEN` | API token from the VCFA portal | `uT3s3jCY8GIPzK...` |
| `VCFA_ENDPOINT` | VCFA hostname (no `https://` prefix) | `vcfa01.vmw-lab1.example.com` |
| `TENANT_NAME` | SSO tenant/organization | `org-rax-01` |
| `CONTEXT_NAME` | Local VCF CLI context name | `my-dev-automation` |
| `SUPERVISOR_NAMESPACE` | Supervisor namespace where the bastion VM was provisioned | `my-project-ns` |

Optional: `VM_NAME` (default: `bastion-vm`), `VM_TIMEOUT` (default: `600`), `POLL_INTERVAL` (default: `30`).

---

## How to Trigger

### Docker exec (recommended)

```bash
docker exec vcf9-dev bash examples/deploy-bastion-vm/teardown-bastion-vm.sh
```

### Docker exec with explicit namespace and VM name

```bash
docker exec \
  -e SUPERVISOR_NAMESPACE=my-project-ns \
  -e VM_NAME=bastion-vm-01 \
  vcf9-dev bash examples/deploy-bastion-vm/teardown-bastion-vm.sh
```

### GitHub Actions (Teardown VCF Stacks workflow)

1. Go to **Actions** → **Teardown VCF Stacks** → **Run workflow**
2. Enter the **cluster_name**
3. Enter the **bastion_vm_name** (must match the name used during deploy)
4. Ensure **"Tear down the Bastion VM"** is checked
5. Optionally uncheck other stacks if you only want to tear down the bastion

---

## Expected Output

A successful run produces output like this:

```
[Step 1] Deleting VirtualMachineService 'bastion-vm-ssh' in namespace 'my-project-ns'...
✓ VirtualMachineService 'bastion-vm-ssh' deleted
[Step 2] Deleting VirtualMachine 'bastion-vm' in namespace 'my-project-ns'...
✓ VirtualMachine 'bastion-vm' delete command issued
  Waiting for VirtualMachine 'bastion-vm' to be deleted... (0s/600s elapsed)
  Waiting for VirtualMachine 'bastion-vm' to be deleted... (30s/600s elapsed)
✓ VirtualMachine 'bastion-vm' fully terminated
[Step 3] Deleting data disk PVC 'bastion-vm-data' in namespace 'my-project-ns'...
✓ PVC 'bastion-vm-data' deleted
[Step 4] Deleting cloud-init Secret 'bastion-vm-cloud-init' in namespace 'my-project-ns'...
✓ Secret 'bastion-vm-cloud-init' deleted

=============================================
  VCF 9 Bastion VM — Teardown Complete
=============================================
  VM Name:            bastion-vm
  Namespace:          my-project-ns
  VMService:          bastion-vm-ssh (deleted)
  VirtualMachine:     bastion-vm (deleted)
  Data Disk PVC:      bastion-vm-data (deleted)
  Cloud-Init Secret:  bastion-vm-cloud-init (deleted)
=============================================
```

---

## Typical Timing

| Phase | Duration |
|---|---|
| Phase 1 (VirtualMachineService deletion) | ~5s |
| Phase 2 (VM termination) | 1–5 min |
| Phase 3 (Data disk PVC deletion) | ~5s |
| Phase 4 (Secret deletion) | ~5s |
| **Total** | **~1–6 min** |

---

## Idempotency

The teardown script is safe to run multiple times. If resources are already deleted, each phase skips gracefully:

- Missing VirtualMachineService → logs "already absent", continues
- Missing VirtualMachine → logs "already absent", continues
- Missing Data Disk PVC → logs "already absent", continues
- Missing Secret → logs "already absent", continues
- Deletion failures → logs a warning and continues to the next resource (does not abort)
- `--ignore-not-found` flag on all `kubectl delete` commands prevents errors on re-runs

The teardown summary reports per-resource status: **deleted**, **already absent**, or **failed**.
