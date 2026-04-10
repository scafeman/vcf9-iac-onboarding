# Teardown Knative — Serverless Asset Tracker with DSM PostgreSQL

## Overview

`teardown-knative.sh` reverses everything created by `deploy-knative.sh`, deleting all Knative Serving resources, the DSM PostgresCluster, API server, RBAC resources, audit function, and dashboard in the correct reverse dependency order. It is the "spin down" half of the Knative deployment lifecycle.

The script is fully non-interactive. All configuration is driven by the same environment variables as the deploy script (loaded from `.env` via Docker Compose). No user input or confirmation prompts are required.

---

## What the Script Does

### Phase 1: Delete Dashboard, RBAC, API Server, Audit Function, and knative-demo Namespace

Deletes resources in order: sslip.io Ingress and TLS Certificate (if `USE_SSLIP_DNS` was enabled), Dashboard Deployment/Service, RBAC resources (RoleBinding, Role, ServiceAccount), API Server Deployment/Service, Knative Service `asset-audit`, and the `knative-demo` namespace.

```
kubectl delete deployment knative-dashboard -n knative-demo --ignore-not-found
kubectl delete svc knative-dashboard -n knative-demo --ignore-not-found
kubectl delete rolebinding knative-dashboard-pod-reader-binding -n knative-demo --ignore-not-found
kubectl delete role knative-dashboard-pod-reader -n knative-demo --ignore-not-found
kubectl delete serviceaccount knative-dashboard-sa -n knative-demo --ignore-not-found
kubectl delete deployment knative-api-server -n knative-demo --ignore-not-found
kubectl delete svc knative-api-server -n knative-demo --ignore-not-found
kubectl delete ksvc asset-audit -n knative-demo --ignore-not-found
kubectl delete ns knative-demo --ignore-not-found
```

If resources do not exist, this phase logs "already absent" and continues.

### Phase 2: Delete DSM PostgresCluster and Secrets

Creates a VCF CLI context for supervisor namespace access, then deletes the DSM PostgresCluster CRD, the admin password secret, and the DSM-created password secret `pg-<cluster-name>`.

```
kubectl delete postgrescluster <cluster-name> -n <supervisor-namespace> --ignore-not-found
kubectl delete secret <admin-password-secret> -n <supervisor-namespace> --ignore-not-found
kubectl delete secret pg-<cluster-name> -n <supervisor-namespace> --ignore-not-found
```

If VCF CLI credentials are not set, this phase is skipped with a warning.

### Phase 3: Delete net-contour Resources and Contour Namespaces

Deletes the net-contour plugin resources using the upstream manifest, then removes the `contour-external` and `contour-internal` namespaces.

```
kubectl delete -f <net-contour-url> --ignore-not-found
kubectl delete ns contour-external --ignore-not-found
kubectl delete ns contour-internal --ignore-not-found
```

### Phase 4: Delete Knative Core Components and knative-serving Namespace

Deletes the Knative Serving core resources using the upstream manifest, then waits for the `knative-serving` namespace to be fully terminated. If the namespace gets stuck in `Terminating` state, the script removes finalizers to force deletion.

```
kubectl delete -f <serving-core-url> --ignore-not-found
kubectl delete ns knative-serving --ignore-not-found
```

### Phase 5: Delete Knative CRDs

Deletes the Knative Serving CRDs using the upstream manifest, then cleans up any remaining Knative CRDs, webhooks, ClusterRoles, and ClusterRoleBindings.

```
kubectl delete -f <serving-crds-url> --ignore-not-found
```

---

## Prerequisites

- Docker and Docker Compose installed
- The `vcf9-dev` container running (`docker compose up -d`)
- A populated `.env` file with the same variables used by the deploy script
- VCF CLI credentials for DSM PostgresCluster deletion (Phase 2)

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
| `VCF_API_TOKEN` | No | — | VCF CLI API token (for DSM deletion) |
| `VCFA_ENDPOINT` | No | — | VCF Automation endpoint (for DSM deletion) |
| `TENANT_NAME` | No | — | VCF tenant name (for DSM deletion) |
| `CONTEXT_NAME` | No | — | VCF CLI context name (for DSM deletion) |
| `SUPERVISOR_NAMESPACE` | No | — | Supervisor namespace (for DSM deletion) |
| `PROJECT_NAME` | No | — | VCF project name (for DSM deletion) |
| `DSM_CLUSTER_NAME` | No | `pg-clus-01` | DSM PostgresCluster name |
| `ADMIN_PASSWORD_SECRET_NAME` | No | `admin-pw-pg-clus-01` | Secret name for admin password |
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

## Typical Timing

| Phase | Duration |
|---|---|
| Phase 1 (App + RBAC + API + namespace deletion) | 10–30s |
| Phase 2 (DSM PostgresCluster + secrets) | 30s–5 min |
| Phase 3 (net-contour + Contour namespaces) | 10–30s |
| Phase 4 (Knative Core + namespace termination) | 30s–3 min |
| Phase 5 (CRDs + cluster-scoped cleanup) | 10–30s |
| **Total** | **~2–10 min** |

---

## Idempotency

The teardown script is safe to run multiple times. If resources are already deleted, each phase skips gracefully:

- Missing Knative Service → logs "already absent", continues
- Missing Deployment/Service → logs "already absent", continues
- Missing RBAC resources → logs "already absent", continues
- Missing DSM PostgresCluster → logs "already absent", continues
- Missing namespace → logs "already absent", continues
- Missing CRDs → logs "already absent", continues
- Deletion failures → logs a warning and continues to the next resource (does not abort)
- `--ignore-not-found` flag on all `kubectl delete` commands prevents errors on re-runs

The teardown summary reports per-phase status: **deleted**, **already absent**, **skipped**, or **failed**.
