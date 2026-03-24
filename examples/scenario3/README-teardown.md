# Scenario 3: Self-Contained ArgoCD Consumption Model Teardown Script

## Overview

`scenario3-argocd-teardown.sh` removes all ArgoCD Consumption Model components installed by `scenario3-argocd-deploy.sh`, deleting resources in reverse dependency order. It removes both application components (GitLab, ArgoCD Application) and infrastructure services (ArgoCD, Harbor, Contour) that were installed by the self-contained deploy script.

The script is fully non-interactive. All configuration is driven by environment variables defined in the variable block at the top of the script. No user input or confirmation prompts are required.

---

## What the Script Does

### Phase 1: Kubeconfig Setup

Sets the `KUBECONFIG` environment variable to the kubeconfig file path. If the file is missing or the cluster is unreachable, the script prints a warning but continues with cleanup anyway.

### Phase 2: Delete ArgoCD Application

Deletes the ArgoCD Application custom resource (`microservices-demo`) from the ArgoCD namespace. Waits for Microservices Demo pods to terminate in the application namespace (up to 120 seconds). Deletes the application namespace. Uses `--ignore-not-found` and `|| true` for idempotency.

### Phase 3: Delete GitLab Runner

Uninstalls the GitLab Runner Helm release via `helm uninstall`. Strips finalizers from all resources in the GitLab Runner namespace to prevent stuck namespace deletion (lesson learned from Scenario 2). Deletes the GitLab Runner namespace.

### Phase 4: Delete GitLab Operator

Uninstalls the GitLab Operator Helm release via `helm uninstall`. Deletes GitLab custom resources created by the operator. Strips finalizers from all resources in the GitLab namespace to prevent stuck namespace deletion. Deletes the GitLab namespace.

### Phase 5: Delete ArgoCD

Uninstalls the ArgoCD Helm release via `helm uninstall`. Strips finalizers from all resources in the ArgoCD namespace. Deletes the ArgoCD namespace.

### Phase 6: Restore CoreDNS

Reads the current CoreDNS ConfigMap and removes the custom `hosts { ... }` block that was added by the deploy script (containing Harbor, GitLab, and ArgoCD static entries). Restarts CoreDNS pods to pick up the restored configuration. Skips if the hosts block is not present.

### Phase 7: Delete Harbor

Uninstalls the Harbor Helm release via `helm uninstall`. Strips finalizers from all resources in the Harbor namespace. Deletes the Harbor namespace.

### Phase 8: Delete Contour

Uninstalls the Contour Helm release via `helm uninstall`. Strips finalizers from all resources in the Contour namespace. Deletes the Contour namespace.

### Phase 9: Delete Certificate Secrets

Deletes the Harbor CA certificate secret from the GitLab and GitLab Runner namespaces. Deletes the GitLab wildcard TLS secret from the GitLab namespace. Uses `--ignore-not-found` for idempotency.

### Phase 10: Clean Up Certificate Files

Removes the generated certificate files from `CERT_DIR`. Skips if the directory does not exist.

### Phase 11: Summary Banner

Prints a summary of all removed components including infrastructure services (Contour, Harbor, ArgoCD) and application components.

---

## Prerequisites

- **Valid admin kubeconfig file** for the target VKS cluster. By default the script looks for `./kubeconfig-<CLUSTER_NAME>.yaml`.
- **Cluster reachable** — the script warns if the cluster is unreachable but attempts cleanup anyway.
- **Helm v3 installed** — required for uninstalling Helm releases.
- **kubectl installed** — required for all Kubernetes operations.

---

## Required Environment Variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `CLUSTER_NAME` | Yes | (none) | VKS cluster name |

### Optional Variables (with defaults)

| Variable | Default | Description |
|---|---|---|
| `KUBECONFIG_FILE` | `./kubeconfig-${CLUSTER_NAME}.yaml` | Path to admin kubeconfig |
| `DOMAIN` | `lab.local` | Base domain (used to derive hostnames for CoreDNS restore) |
| `CERT_DIR` | `./certs` | Directory containing generated certificate files |
| `CONTOUR_NAMESPACE` | `projectcontour` | Namespace for Contour |
| `HARBOR_NAMESPACE` | `harbor` | Namespace for Harbor |
| `GITLAB_NAMESPACE` | `gitlab-system` | Namespace for GitLab Operator |
| `GITLAB_RUNNER_NAMESPACE` | `gitlab-runners` | Namespace for GitLab Runner |
| `ARGOCD_NAMESPACE` | `argocd` | ArgoCD namespace |
| `APP_NAMESPACE` | `microservices-demo` | Namespace for the Microservices Demo |

---

## How to Run

### Execute the teardown script

```bash
bash examples/scenario3/scenario3-argocd-teardown.sh
```

Or override variables inline:

```bash
CLUSTER_NAME=my-cluster bash examples/scenario3/scenario3-argocd-teardown.sh
```

---

## Expected Output

A successful run produces output similar to:

```
[Step 1] Setting up kubeconfig...
✓ Kubeconfig set to './kubeconfig-my-cluster.yaml'
[Step 2] Deleting ArgoCD Application...
  Waiting for pods in 'microservices-demo' to terminate...
  11 pod(s) still terminating... (0s/120s elapsed)
  ...
✓ ArgoCD Application 'microservices-demo' deleted (namespace 'microservices-demo' removed)
[Step 3] Deleting GitLab Runner...
✓ GitLab Runner removed (namespace 'gitlab-runners' deleted)
[Step 4] Deleting GitLab Operator...
✓ GitLab Operator removed (namespace 'gitlab-system' deleted)
[Step 5] Deleting ArgoCD...
✓ ArgoCD removed (namespace 'argocd' deleted)
[Step 6] Restoring CoreDNS configuration...
✓ CoreDNS configuration restored (hosts block removed)
✓ CoreDNS restore complete
[Step 7] Deleting Harbor...
✓ Harbor removed (namespace 'harbor' deleted)
[Step 8] Deleting Contour...
✓ Contour removed (namespace 'projectcontour' deleted)
[Step 9] Deleting certificate secrets...
✓ Certificate secrets deleted from all namespaces
[Step 10] Cleaning up certificate files...
✓ Certificate directory './certs' removed
✓ Certificate file cleanup complete
[Step 11] Teardown summary...
=============================================
  VCF 9 Scenario 3 — Teardown Complete
=============================================
  Cluster:              my-cluster
  Domain:               lab.local
  Removed components:
    - ArgoCD Application (microservices-demo)
    - Microservices Demo namespace (microservices-demo)
    - GitLab Runner (ns: gitlab-runners)
    - GitLab Operator (ns: gitlab-system)
    - ArgoCD (ns: argocd)
    - CoreDNS custom host entries
    - Harbor (ns: harbor)
    - Contour (ns: projectcontour)
    - Certificate secrets (harbor-ca-cert, gitlab-wildcard-tls)
    - Certificate files (./certs)
=============================================
✓ Scenario 3 teardown complete
```

---

## Idempotency

The teardown script is safe to run multiple times. If resources are already deleted, each phase skips gracefully:

- Missing kubeconfig → prints warning, continues cleanup
- Missing ArgoCD Application → `--ignore-not-found` and `|| true` handle it
- Missing Helm release → `helm uninstall` with `|| true` handles it
- Stuck resources with finalizers → finalizers stripped before namespace deletion so they cannot block (lesson learned from Scenario 2)
- Missing namespace → `--ignore-not-found` handles it
- Missing certificate Secrets → `--ignore-not-found` handles it
- CoreDNS without custom hosts block → detects no changes needed, skips patch
- Missing certificate directory → skips cleanup
- Failed delete commands → `|| true` prevents script from exiting

This makes it safe to re-run after a partial failure or manual cleanup.

---

## Finalizer Stripping

The teardown script strips finalizers from common resource types in each namespace before deleting that namespace. This is a pattern learned from Scenario 2, where stuck finalizers on resources can prevent namespace deletion from completing, leaving the namespace in a `Terminating` state indefinitely.

The script uses a `strip_finalizers_in_namespace` helper that targets ~11 common resource types (pods, services, deployments, statefulsets, replicasets, jobs, configmaps, secrets, pvc, serviceaccounts, roles, rolebindings) rather than enumerating all 100+ API types:

```bash
strip_finalizers_in_namespace() {
  local ns="$1"
  local resource_types=(
    pods services deployments statefulsets replicasets
    jobs configmaps secrets pvc serviceaccounts
    roles rolebindings
  )
  for rt in "${resource_types[@]}"; do
    for item in $(kubectl get "${rt}" -n "${ns}" -o name 2>/dev/null); do
      kubectl patch "${item}" -n "${ns}" \
        --type merge -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
    done
  done
}
```

This is applied to all namespaces being deleted: GitLab Runner, GitLab Operator, ArgoCD, Harbor, and Contour.
