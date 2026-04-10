# Deploy Cluster: Full Stack Teardown Script

## Overview

`teardown-cluster.sh` reverses everything created by `deploy-cluster.sh`, deleting all VCF 9 resources in the correct dependency order. It is the "spin down" half of the dev environment lifecycle.

The script is fully non-interactive. All configuration is driven by the same environment variables as the deploy script (loaded from `.env` via Docker Compose). No user input or confirmation prompts are required.

---

## What the Script Does

### Phase 0: Establish VCF CLI Context

Before deleting anything, the script needs a working CLI context to talk to VCFA. It tries to activate the existing context first (`vcf context use`). If that fails (e.g., the context doesn't exist, or the token is expired), it deletes any stale context and creates a fresh one. This matches the deploy script's pattern and prevents "context already exists" errors on re-runs.

Once the context is active, it discovers the dynamically named Supervisor Namespace by querying:

```
kubectl get supervisornamespaces -n <PROJECT_NAME> -o jsonpath='{.items[0].metadata.name}'
```

If no namespace is found (already deleted or never created), the script skips cluster and workload teardown and jumps straight to project deletion.

### Phase 1: Guest Cluster Workload Cleanup

Switches to the namespace-scoped context, retrieves the admin kubeconfig for the VKS guest cluster, and deletes the functional validation workloads deployed in Phase 6 of the deploy script:

1. **Ingress** `vks-test-sslip-ingress` — removes the sslip.io Ingress resource and associated TLS Certificate (if created)
2. **Service** `vks-test-lb` — releases the NSX LoadBalancer external IP
3. **Deployment** `vks-test-app` — terminates the test app pod
4. **PersistentVolumeClaim** `vks-test-pvc` — releases the NFS volume

If `USE_SSLIP_DNS` was enabled during deployment, the script also cleans up the ClusterIssuer, cert-manager, and Contour VKS packages installed in Phases 5g–5i:

5. **ClusterIssuer** `letsencrypt-prod` — removes the Let's Encrypt ACME issuer
6. **Contour VKS package** — uninstalls the Contour ingress controller and Envoy LoadBalancer
7. **cert-manager VKS package** — uninstalls the certificate lifecycle manager

All deletes use `--ignore-not-found` so the script doesn't fail if any resource was already deleted or never created.

If the kubeconfig can't be retrieved (e.g., the cluster is already gone), this phase is skipped gracefully.

### Phase 2: VKS Cluster Deletion

From the namespace-scoped context, deletes the VKS Cluster object:

```
kubectl delete cluster <CLUSTER_NAME> -n <DYNAMIC_NS_NAME>
```

Then waits for the cluster to be fully removed (timeout: 30 minutes, polling every 15 seconds). VCF deprovisions the control plane and worker VMs during this time.

If the cluster doesn't exist, this phase is skipped. If the namespace context can't be reached, this phase is also skipped gracefully.

### Phase 3: Supervisor Namespace + RBAC + Project Deletion

Switches back to the project-level context and deletes resources in dependency order:

1. **SupervisorNamespace** — deletes the Supervisor Namespace and waits for it to be fully removed (timeout: 600s). This releases the compute, storage, and network resources allocated to the namespace.
2. **ProjectRoleBinding** — removes the RBAC binding for the user identity.
3. **Project** — deletes the project governance boundary.

All deletes use `--ignore-not-found` to handle race conditions where child resources are automatically garbage-collected when the parent is deleted.

### Phase 4: VCF CLI Context and Local Artifact Cleanup

Removes the VCF CLI context from the local configuration:

```
vcf context delete <CONTEXT_NAME> --yes
```

The `--yes` flag bypasses the interactive confirmation prompt. Then removes the local kubeconfig file (`./kubeconfig-<CLUSTER_NAME>.yaml`) if it exists.

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
| `VCFA_ENDPOINT` | VCFA hostname (no `https://` prefix) | `vcfa01.vmw-lab1.rpcai.rackspace-cloud.com` |
| `TENANT_NAME` | SSO tenant/organization | `org-rax-01` |
| `CONTEXT_NAME` | Local CLI context name | `my-dev-automation` |
| `PROJECT_NAME` | VCF Project name | `my-dev-project-01` |
| `USER_IDENTITY` | SSO user identity for RBAC | `rax-user-1` |
| `CLUSTER_NAME` | VKS cluster name | `my-dev-project-01-clus-01` |

---

## How to Run

### Execute the teardown script

```bash
docker exec vcf9-dev bash examples/deploy-cluster/teardown-cluster.sh
```

### Monitor from a second terminal (optional)

While the script is running, you can monitor deletion progress:

```bash
# Watch cluster deletion
docker exec vcf9-dev kubectl get clusters -w

# Watch VM deprovisioning
docker exec vcf9-dev kubectl get virtualmachines -w

# Check namespace deletion status
docker exec vcf9-dev bash -c "vcf context use my-dev-automation 2>/dev/null && kubectl get supervisornamespaces -n my-dev-project-01"
```

---

## Expected Output

A successful run produces output like this:

```
[Step 0] Establishing VCF CLI context...
✓ VCF CLI context 'my-dev-automation' active
✓ Discovered namespace 'my-dev-project-01-ns-x3qk6' in project 'my-dev-project-01'
[Step 1] Deleting guest cluster workloads (Service, Deployment, PVC)...
service "vks-test-lb" deleted
deployment.apps "vks-test-app" deleted
persistentvolumeclaim "vks-test-pvc" deleted
✓ Guest cluster workloads deleted
[Step 2] Deleting VKS cluster 'my-dev-project-01-clus-01'...
cluster.cluster.x-k8s.io "my-dev-project-01-clus-01" deleted
✓ VKS cluster 'my-dev-project-01-clus-01' deleted
[Step 3] Deleting Supervisor Namespace, ProjectRoleBinding, and Project...
supervisornamespace.infrastructure.cci.vmware.com "my-dev-project-01-ns-x3qk6" deleted
  Waiting for SupervisorNamespace '...' to be deleted... (0s/600s elapsed)
  Waiting for SupervisorNamespace '...' to be deleted... (15s/600s elapsed)
✓ SupervisorNamespace 'my-dev-project-01-ns-x3qk6' deleted
✓ ProjectRoleBinding 'cci:user:rax-user-1' deleted
✓ Project 'my-dev-project-01' deleted
[Step 4] Cleaning up VCF CLI context and local artifacts...
✓ VCF CLI context 'my-dev-automation' deleted
✓ Local kubeconfig './kubeconfig-my-dev-project-01-clus-01.yaml' removed

=============================================
  VCF 9 Deploy Cluster — Teardown Complete
=============================================
  Cluster:    my-dev-project-01-clus-01 (deleted)
  Project:    my-dev-project-01 (deleted)
  Namespace:  my-dev-project-01-ns-x3qk6 (deleted)
  Context:    my-dev-automation (deleted)
=============================================
```

---

## Typical Timing

| Phase | Duration |
|---|---|
| Phase 0 (Context setup) | ~5s |
| Phase 1 (Workload cleanup) | ~10s |
| Phase 2 (Cluster deletion) | 0-5 min |
| Phase 3 (Namespace/Project deletion) | 30-60s |
| Phase 4 (Context cleanup) | ~5s |
| **Total** | **~1-6 min** |

---

## Idempotency

The teardown script is safe to run multiple times. If resources are already deleted, each phase skips gracefully:

- Missing kubeconfig → skips workload cleanup
- Missing cluster → skips cluster deletion
- Missing namespace → skips namespace deletion
- Missing RBAC/project → `--ignore-not-found` handles it
- Missing context → `--yes` flag prevents prompts

This makes it safe to re-run after a partial failure or manual cleanup.
