# Teardown Knative — Serverless Audit Function

## Overview

`teardown-knative.sh` reverses everything created by `deploy-knative.sh`, deleting all Knative Serving resources and the sample serverless audit function in the correct reverse dependency order. It is the "spin down" half of the Knative deployment lifecycle.

The script is fully non-interactive. All configuration is driven by the same environment variables as the deploy script (loaded from `.env` via Docker Compose). No user input or confirmation prompts are required.

---

## What the Script Does

### Phase 1: Delete Audit Function, Dashboard, and knative-demo Namespace

Deletes the Knative Service `asset-audit`, the Dashboard Deployment and Service, and the `knative-demo` namespace.

```
kubectl delete ksvc asset-audit -n knative-demo --ignore-not-found
kubectl delete deployment knative-dashboard -n knative-demo --ignore-not-found
kubectl delete svc knative-dashboard -n knative-demo --ignore-not-found
kubectl delete ns knative-demo --ignore-not-found
```

If resources do not exist, this phase logs "already absent" and continues.

### Phase 2: Delete net-contour Resources and Contour Namespaces

Deletes the net-contour plugin resources using the upstream manifest, then removes the `contour-external` and `contour-internal` namespaces.

```
kubectl delete -f <net-contour-url> --ignore-not-found
kubectl delete ns contour-external --ignore-not-found
kubectl delete ns contour-internal --ignore-not-found
```

### Phase 3: Delete Knative Core Components and knative-serving Namespace

Deletes the Knative Serving core resources using the upstream manifest, then waits for the `knative-serving` namespace to be fully terminated. If the namespace gets stuck in `Terminating` state, the script removes finalizers to force deletion.

```
kubectl delete -f <serving-core-url> --ignore-not-found
kubectl delete ns knative-serving --ignore-not-found
```

### Phase 4: Delete Knative CRDs

Deletes the Knative Serving CRDs using the upstream manifest, then cleans up any remaining Knative CRDs, webhooks, ClusterRoles, and ClusterRoleBindings.

```
kubectl delete -f <serving-crds-url> --ignore-not-found
```

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
| `CLUSTER_NAME` | Yes | — | VKS cluster name |
| `KUBECONFIG_FILE` | No | `./kubeconfig-${CLUSTER_NAME}.yaml` | Path to admin kubeconfig |
| `KNATIVE_SERVING_VERSION` | No | `1.21.2` | Knative Serving version (for manifest URLs) |
| `NET_CONTOUR_VERSION` | No | `1.21.1` | net-contour version (for manifest URLs) |
| `KNATIVE_NAMESPACE` | No | `knative-serving` | Knative system namespace |
| `DEMO_NAMESPACE` | No | `knative-demo` | Demo application namespace |
| `KNATIVE_TIMEOUT` | No | `300` | Timeout for namespace termination (seconds) |
| `POLL_INTERVAL` | No | `10` | Polling interval (seconds) |

---

## How to Trigger

### Docker exec (recommended)

```bash
docker exec vcf9-dev bash examples/deploy-knative/teardown-knative.sh
```

### GitHub Actions (Teardown VCF Stacks workflow)

1. Go to **Actions** → **Teardown VCF Stacks** → **Run workflow**
2. Enter the **cluster_name**
3. Ensure the Knative teardown phase is enabled
4. Click **Run workflow**

---

## Expected Output

A successful run produces output like this:

```
[Step 0] Setting up kubeconfig...
✓ Kubeconfig set to './kubeconfig-my-clus-01.yaml'
[Step 1] Deleting audit function, dashboard, and 'knative-demo' namespace...
✓ Knative Service 'asset-audit' deleted
✓ Dashboard Deployment 'knative-dashboard' deleted
✓ Dashboard Service 'knative-dashboard' deleted
✓ Namespace 'knative-demo' deleted
[Step 2] Deleting net-contour resources and Contour namespaces...
✓ net-contour resources deleted
✓ Namespace 'contour-external' deleted
✓ Namespace 'contour-internal' deleted
[Step 3] Deleting Knative Core components and 'knative-serving' namespace...
✓ Knative Core resources deleted
✓ Namespace 'knative-serving' terminated
[Step 4] Deleting Knative CRDs...
✓ Knative Serving CRDs deleted
✓ Knative cluster-scoped resources cleaned up

=============================================
  VCF 9 Deploy Knative — Teardown Complete
=============================================
  Cluster:          my-clus-01
  Phase 1 (App):    deleted
  Phase 2 (Contour):deleted
  Phase 3 (Core):   deleted
  Phase 4 (CRDs):   deleted
=============================================
```

---

## Typical Timing

| Phase | Duration |
|---|---|
| Phase 1 (App + namespace deletion) | 10–30s |
| Phase 2 (net-contour + Contour namespaces) | 10–30s |
| Phase 3 (Knative Core + namespace termination) | 30s–3 min |
| Phase 4 (CRDs + cluster-scoped cleanup) | 10–30s |
| **Total** | **~1–5 min** |

---

## Idempotency

The teardown script is safe to run multiple times. If resources are already deleted, each phase skips gracefully:

- Missing Knative Service → logs "already absent", continues
- Missing Deployment/Service → logs "already absent", continues
- Missing namespace → logs "already absent", continues
- Missing CRDs → logs "already absent", continues
- Deletion failures → logs a warning and continues to the next resource (does not abort)
- `--ignore-not-found` flag on all `kubectl delete` commands prevents errors on re-runs

The teardown summary reports per-phase status: **deleted**, **already absent**, or **failed**.
