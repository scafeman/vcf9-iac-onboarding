# Deploy GitOps: Self-Contained ArgoCD Consumption Model Teardown Script

## Overview

`teardown-gitops.sh` removes all ArgoCD Consumption Model components installed by `deploy-gitops.sh`, deleting resources in reverse dependency order. It removes application components (GitLab, ArgoCD Application) and application-level infrastructure services (ArgoCD, Harbor) that were installed via Helm. Shared VKS packages (cert-manager, Contour) are not removed — they are managed by Deploy Metrics's teardown script.

The script is fully non-interactive. All configuration is driven by environment variables defined in the variable block at the top of the script. No user input or confirmation prompts are required.

---

## What the Script Does

### Phase 1: Kubeconfig Setup

Sets the `KUBECONFIG` environment variable to the kubeconfig file path. If the file is missing or the cluster is unreachable, the script prints a warning but continues with cleanup anyway.

### Phase 1b: CI/CD Pipeline Cleanup

Cleans up CI/CD pipeline resources created by Phases 16–18 of the deploy script. This phase must run before Phase 2 (Delete ArgoCD Application) because ArgoCD must be running to restore the Application source and remove repository credentials.

- Restores the ArgoCD Application source to the original GitHub repository (`HELM_CHARTS_REPO_URL`) and path (`examples/deploy-gitops/microservices-overlay`) via `kubectl patch`.
- Removes ArgoCD repository credentials for the GitLab hostname via `argocd repo rm` (executed inside the ArgoCD server pod).
- Deletes the GitLab project via the GitLab REST API (`DELETE /api/v4/projects/:id`). Retrieves the root password from the `gitlab-gitlab-initial-root-password` K8s Secret and obtains an OAuth token for API access.
- Deletes the Harbor CI project via the Harbor REST API (`DELETE /api/v2.0/projects/HARBOR_CI_PROJECT`). Retrieves the Harbor admin password from the `harbor-core` K8s Secret.

All commands use `|| true` and `2>/dev/null` for idempotency. Missing resources produce warnings via `log_warn` but do not block the script.

### Phase 2: Delete ArgoCD Application

Deletes the ArgoCD Application custom resource (`microservices-demo`) from the ArgoCD namespace. Waits for Microservices Demo pods to terminate in the application namespace (up to 120 seconds). Deletes the application namespace. Uses `--ignore-not-found` and `|| true` for idempotency.

### Phase 3: Delete GitLab Runner

Uninstalls the GitLab Runner Helm release via `helm uninstall`. Strips finalizers from all resources in the GitLab Runner namespace to prevent stuck namespace deletion (lesson learned from Deploy Metrics). Deletes the GitLab Runner namespace.

### Phase 4: Delete GitLab

Uninstalls the GitLab Helm release via `helm uninstall`. Deletes GitLab custom resources created by the operator. Strips finalizers from all resources in the GitLab namespace to prevent stuck namespace deletion. Deletes the GitLab namespace.

### Phase 5: Delete ArgoCD

Uninstalls the ArgoCD Helm release via `helm uninstall`. Strips finalizers from all resources in the ArgoCD namespace. Deletes the ArgoCD namespace.

### Phase 6: Restore CoreDNS

When `USE_SSLIP_DNS=false` was used during deployment, reads the current CoreDNS ConfigMap and removes the custom `hosts { ... }` block that was added by the deploy script (containing Harbor, GitLab, and ArgoCD static entries). Restarts CoreDNS pods to pick up the restored configuration. Skips if the hosts block is not present or if sslip.io DNS was used (no CoreDNS patching to revert).

Also performs defensive cleanup of node-level DaemonSets:
- Deletes the `node-dns-patcher` DaemonSet from `kube-system` (deployed by `deploy-cluster.sh` Phase 5j — defensive cleanup in case `teardown-cluster.sh` was not run first).
- Deletes the `node-ca-installer` DaemonSet and `node-ca-bundle` ConfigMap from `kube-system` (deployed by Phase 8b). This removes the node-level CA trust store installation and stops containerd restarts on each node.

All deletes use `--ignore-not-found` and `|| true` for idempotency.

### Phase 7: Delete Harbor

Uninstalls the Harbor Helm release via `helm uninstall`. Strips finalizers from all resources in the Harbor namespace. Deletes the Harbor namespace.

### Phase 8: Delete Certificate Secrets

Deletes the Harbor CA certificate secret from the GitLab and GitLab Runner namespaces. Deletes the GitLab wildcard TLS secret from the GitLab namespace. Uses `--ignore-not-found` for idempotency.

### Phase 9: Clean Up Certificate Files

Removes the generated certificate files from `CERT_DIR`. Skips if the directory does not exist.

### Phase 10: Summary Banner

Prints a summary of all removed components. Note: Contour and cert-manager are shared VKS packages and are not removed by this script.

---

## Prerequisites

- **Valid admin kubeconfig file** for the target VKS cluster. By default the script looks for `./kubeconfig-<CLUSTER_NAME>.yaml`.
- **Cluster reachable** — the script warns if the cluster is unreachable but attempts cleanup anyway.
- **Helm v4 installed** — required for uninstalling Helm releases.
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
| `CONTOUR_INGRESS_NAMESPACE` | `tanzu-system-ingress` | Namespace for Contour Envoy (VKS package default) |
| `HARBOR_NAMESPACE` | `harbor` | Namespace for Harbor |
| `GITLAB_NAMESPACE` | `gitlab-system` | Namespace for GitLab |
| `GITLAB_RUNNER_NAMESPACE` | `gitlab-runners` | Namespace for GitLab Runner |
| `ARGOCD_NAMESPACE` | `argocd` | ArgoCD namespace |
| `APP_NAMESPACE` | `microservices-demo` | Namespace for the Microservices Demo |
| `GITLAB_PROJECT_NAME` | `microservices-demo` | GitLab project name for CI/CD pipeline cleanup |
| `HARBOR_CI_PROJECT` | `microservices-ci` | Harbor CI project name for cleanup |
| `HELM_CHARTS_REPO_URL` | `https://github.com/scafeman/vcf9-iac-onboarding.git` | Original GitHub repo URL (used to restore ArgoCD Application source) |

---

## How to Run

### Execute the teardown script

```bash
bash examples/deploy-gitops/teardown-gitops.sh
```

Or override variables inline:

```bash
CLUSTER_NAME=my-cluster bash examples/deploy-gitops/teardown-gitops.sh
```

---

## Expected Output

A successful run produces output similar to:

```
[Step 1] Setting up kubeconfig...
✓ Kubeconfig set to './kubeconfig-my-cluster.yaml'
[Step 1b] Cleaning up CI/CD pipeline resources...
✓ ArgoCD Application source restored to 'https://github.com/scafeman/vcf9-iac-onboarding.git'
✓ ArgoCD repo credentials for GitLab removed
✓ GitLab project 'microservices-demo' (ID: 1) deleted
✓ Harbor CI project 'microservices-ci' deleted
✓ CI/CD pipeline cleanup complete
[Step 2] Deleting ArgoCD Application...
  Waiting for pods in 'microservices-demo' to terminate...
  11 pod(s) still terminating... (0s/120s elapsed)
  ...
✓ ArgoCD Application 'microservices-demo' deleted (namespace 'microservices-demo' removed)
[Step 3] Deleting GitLab Runner...
✓ GitLab Runner removed (namespace 'gitlab-runners' deleted)
[Step 4] Deleting GitLab...
✓ GitLab removed (namespace 'gitlab-system' deleted)
[Step 5] Deleting ArgoCD...
✓ ArgoCD removed (namespace 'argocd' deleted)
[Step 6] Restoring CoreDNS configuration...
✓ CoreDNS configuration restored (hosts block removed)
✓ CoreDNS restore complete
[Step 7] Deleting Harbor...
✓ Harbor removed (namespace 'harbor' deleted)
[Step 8] Deleting certificate secrets...
✓ Certificate secrets deleted from all namespaces
[Step 9] Cleaning up certificate files...
✓ Certificate directory './certs' removed
✓ Certificate file cleanup complete
[Step 10] Teardown summary...
=============================================
  VCF 9 Deploy GitOps — Teardown Complete
=============================================
  Cluster:              my-cluster
  Domain:               lab.local
  Removed components:
    - CI/CD pipeline (GitLab project, Harbor CI project, ArgoCD repo credentials)
    - ArgoCD Application (microservices-demo)
    - Microservices Demo namespace (microservices-demo)
    - GitLab Runner (ns: gitlab-runners)
    - GitLab (ns: gitlab-system)
    - ArgoCD (ns: argocd)
    - CoreDNS custom host entries
    - Harbor (ns: harbor)
    - Certificate secrets (harbor-ca-cert, gitlab-wildcard-tls)
    - Certificate files (./certs)
=============================================
✓ Deploy GitOps teardown complete
```

---

## Idempotency

The teardown script is safe to run multiple times. If resources are already deleted, each phase skips gracefully:

- Missing kubeconfig → prints warning, continues cleanup
- Missing ArgoCD Application → `--ignore-not-found` and `|| true` handle it
- Missing Helm release → `helm uninstall` with `|| true` handles it
- Stuck resources with finalizers → finalizers stripped before namespace deletion so they cannot block (lesson learned from Deploy Metrics)
- Missing namespace → `--ignore-not-found` handles it
- Missing certificate Secrets → `--ignore-not-found` handles it
- CoreDNS without custom hosts block → detects no changes needed, skips patch
- Missing certificate directory → skips cleanup
- Failed delete commands → `|| true` prevents script from exiting

This makes it safe to re-run after a partial failure or manual cleanup.

---

## Finalizer Stripping

The teardown script strips finalizers from common resource types in each namespace before deleting that namespace. This is a pattern learned from Deploy Metrics, where stuck finalizers on resources can prevent namespace deletion from completing, leaving the namespace in a `Terminating` state indefinitely.

The script uses a `strip_finalizers_in_namespace` helper that targets ~11 common resource types (pods, services, deployments, statefulsets, replicasets, jobs, persistentvolumeclaims, secrets, configmaps, serviceaccounts, ingresses) rather than enumerating all 100+ API types. Additional component-specific resource types can be passed as extra arguments (e.g., `gitlabs runners` for GitLab, `applications applicationsets appprojects` for ArgoCD):

```bash
strip_finalizers_in_namespace() {
  local ns="$1"
  shift
  local resource_types=(
    pods services deployments statefulsets replicasets
    jobs persistentvolumeclaims secrets configmaps
    serviceaccounts ingresses "$@"
  )
  for resource in "${resource_types[@]}"; do
    for item in $(kubectl get "${resource}" -n "${ns}" -o name 2>/dev/null); do
      kubectl patch "${item}" -n "${ns}" \
        --type merge -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
    done
  done
}
```

This is applied to all namespaces being deleted: GitLab Runner, GitLab, ArgoCD, and Harbor.
