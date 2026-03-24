# Scenario 2: VKS Metrics Observability Teardown Script

## Overview

`scenario2-vks-metrics-teardown.sh` removes all observability components installed by `scenario2-vks-metrics-deploy.sh`, deleting resources in reverse dependency order. It is the "spin down" half of the metrics observability lifecycle.

The script is fully non-interactive. All configuration is driven by environment variables (loaded from `.env` via Docker Compose). No user input or confirmation prompts are required.

---

## What the Script Does

### Phase 1: Kubeconfig Setup & Connectivity Check

Sets the `KUBECONFIG` environment variable to the kubeconfig file path. If the file is missing or the cluster is unreachable, the script prints a warning but continues with cleanup anyway.

### Phase 2: Delete Grafana

Removes all Grafana custom resources (dashboards, datasources, instances), uninstalls the Grafana Operator Helm release, deletes Grafana CRDs (Helm does not remove CRDs on uninstall), and deletes the `grafana` namespace. Each step uses error suppression so the script continues even if resources are already gone.

### Phase 3: Delete Packages (Prometheus, Contour, cert-manager, Telegraf)

All four VKS standard packages are deleted in reverse dependency order using a shared `delete_package` helper that:

1. Lists all PackageInstall resources in the namespace and greps for the package name (more reliable than exact-name lookup)
2. If found, strips finalizers from the PackageInstall and its companion App resource first — this prevents kapp-controller from triggering a reconcile-delete that would cascade into deleting the shared namespace and its service accounts
3. Deletes the PackageInstall and App resources via `kubectl delete` with `--ignore-not-found`
4. If not found, skips gracefully

This approach avoids the critical issue where `vcf package installed delete` triggers kapp-controller's cascading delete, which destroys the `tkg-packages` namespace and all service accounts — breaking deletion of subsequent packages.

### Phase 4: Delete Package Repository

Lists all PackageRepository resources in the namespace and greps for the repository name. If found, strips finalizers and deletes it via `kubectl delete`. If not found, skips gracefully.

### Phase 5: Delete Package Namespace

Strips finalizers from any remaining PackageInstall, App, and PackageRepository resources in the namespace, then deletes the namespace with a 60-second timeout. If the namespace deletion times out (e.g., due to a stuck namespace finalizer), force-removes the namespace finalizer via the Kubernetes finalize API so the namespace can terminate.

### Phase 6: Clean Up Cluster-Scoped Resources

Removes all orphaned cluster-scoped resources left behind by the packages. Since we bypassed kapp's reconcile-delete (by stripping finalizers), these resources are still present and must be removed manually so a subsequent deploy starts clean.

Resources cleaned up include:
- Telegraf, cert-manager, Contour, and Prometheus ClusterRoles and ClusterRoleBindings
- cert-manager CRDs, webhooks, and leader election Roles in `kube-system`
- Contour CRDs and the `tanzu-system-ingress` namespace
- The `cert-manager` namespace (created by the cert-manager package, separate from `tkg-packages`)

---

## Prerequisites

- Docker and Docker Compose installed
- The `vcf9-dev` container running (`docker compose up -d`)
- A populated `.env` file with the same variables used by the deploy script
- Helm v3 installed (for Grafana Operator uninstall)

---

## Required Environment Variables

The teardown script uses a subset of the deploy script's variables:

| Variable | Required | Default | Description |
|---|---|---|---|
| `CLUSTER_NAME` | Yes | (none) | VKS cluster name |
| `KUBECONFIG_FILE` | No | `./kubeconfig-${CLUSTER_NAME}.yaml` | Path to admin kubeconfig |
| `PACKAGE_NAMESPACE` | No | `tkg-packages` | Namespace for VKS standard packages |
| `PACKAGE_REPO_NAME` | No | `tkg-packages` | Package repository name |
| `GRAFANA_NAMESPACE` | No | `grafana` | Namespace for Grafana |

---

## How to Run

### Execute the teardown script

```bash
docker exec vcf9-dev bash examples/scenario2/scenario2-vks-metrics-teardown.sh
```

---

## Idempotency

The teardown script is safe to run multiple times. If resources are already deleted, each phase skips gracefully:

- Missing kubeconfig → prints warning, continues cleanup
- Missing Grafana resources → `|| true` and `--ignore-not-found` handle it
- Missing Helm release → `helm uninstall` with `|| true` handles it
- Missing package → broad grep detection finds absence, skips deletion
- Stuck PackageInstall/App → finalizers stripped before deletion so they can't block
- Missing repository → broad grep detection finds absence, skips deletion
- Missing namespace → `--ignore-not-found` handles it
- Stuck namespace → force-removes namespace finalizer via Kubernetes finalize API
- Failed delete commands → `|| true` prevents script from exiting

This makes it safe to re-run after a partial failure or manual cleanup.
