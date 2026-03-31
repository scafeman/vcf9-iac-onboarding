# Teardown Secrets Demo — VCF Secret Store Integration

## Overview

`teardown-secrets-demo.sh` reverses everything created by `deploy-secrets-demo.sh`, deleting all secrets demo resources in the correct dependency order. It is the "spin down" half of the secrets demo lifecycle.

The script is fully non-interactive. All configuration is driven by the same environment variables as the deploy script (loaded from `.env` via Docker Compose). No user input or confirmation prompts are required.

---

## What Gets Deleted

### Phase 1: Guest Cluster Namespace Cleanup

Switches to the guest cluster kubeconfig and deletes the `secrets-demo` namespace. This cascading delete removes all namespaced resources:

- `secrets-dashboard` Deployment + LoadBalancer Service (releases the NSX external IP)
- Redis Deployment + ClusterIP Service
- PostgreSQL Deployment + ClusterIP Service
- `internal-app-token` Opaque Secret (copied supervisor token)
- `test-service-account` ServiceAccount + token Secret
- vault-injector pod, Service, and all namespaced RBAC resources

If the kubeconfig file is not found (e.g., the cluster was already torn down), this phase is skipped gracefully.

### Phase 2: Guest Cluster Cluster-Scoped Resource Cleanup

Deletes cluster-scoped resources created by the vault-injector package that are not removed by namespace deletion:

- `vault-injector-clusterrole` ClusterRole
- `vault-injector-clusterrolebinding` ClusterRoleBinding
- `vault-injector-cfg` MutatingWebhookConfiguration

### Phase 3: Supervisor Namespace Resource Cleanup

Switches back to the supervisor context (via VCF CLI) and deletes:

- `redis-creds` KeyValueSecret (via `vcf secret delete`)
- `postgres-creds` KeyValueSecret (via `vcf secret delete`)
- `internal-app` ServiceAccount
- `internal-app-token` Secret (the long-lived token in the supervisor)

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
| `VCF_API_TOKEN` | API token from the VCFA portal | `uT3s3jCY8GIPzK...` |
| `VCFA_ENDPOINT` | VCFA hostname (no `https://` prefix) | `vcfa01.vmw-lab1.example.com` |
| `TENANT_NAME` | SSO tenant/organization | `org-rax-01` |
| `CONTEXT_NAME` | Local VCF CLI context name | `my-dev-automation` |

Optional: `NAMESPACE` (default: `secrets-demo`), `KUBECONFIG_FILE` (default: `./kubeconfig-<CLUSTER_NAME>.yaml`).

---

## How to Trigger

### GitHub Actions (recommended)

The Secrets Demo teardown is integrated into the **Teardown VCF Stacks** workflow:

1. Go to **Actions** → **"Teardown VCF Stacks"** → **"Run workflow"**
2. Enter the **cluster_name**
3. Ensure the appropriate teardown checkboxes are selected
4. The workflow handles kubeconfig retrieval and supervisor context switching automatically

### Docker exec (local)

```bash
docker exec \
  -e CLUSTER_NAME=my-project-01-clus-01 \
  vcf9-dev bash examples/deploy-secrets-demo/teardown-secrets-demo.sh
```

### Manual teardown (step-by-step)

If you need to tear down resources manually:

```bash
# 1. Delete guest cluster namespace
export KUBECONFIG=./kubeconfig-<CLUSTER_NAME>.yaml
kubectl delete ns secrets-demo --ignore-not-found

# 2. Delete cluster-scoped vault-injector resources
kubectl delete clusterrole vault-injector-clusterrole --ignore-not-found
kubectl delete clusterrolebinding vault-injector-clusterrolebinding --ignore-not-found
kubectl delete mutatingwebhookconfiguration vault-injector-cfg --ignore-not-found

# 3. Switch to supervisor context and delete secrets + service account
unset KUBECONFIG
vcf context use <CONTEXT_NAME>
vcf secret delete redis-creds
vcf secret delete postgres-creds
kubectl delete sa internal-app --ignore-not-found
kubectl delete secret internal-app-token --ignore-not-found
```

---

## Expected Output

A successful run produces output like this:

```
[Step 1] Deleting secrets-demo namespace in guest cluster...
✓ Namespace 'secrets-demo' deleted (or did not exist)
[Step 2] Deleting cluster-scoped resources from guest cluster...
✓ ClusterRole 'vault-injector-clusterrole' deleted
✓ ClusterRoleBinding 'vault-injector-clusterrolebinding' deleted
✓ MutatingWebhookConfiguration 'vault-injector-cfg' deleted
[Step 3] Switching to supervisor context and cleaning up supervisor resources...
✓ KeyValueSecret 'redis-creds' deleted
✓ KeyValueSecret 'postgres-creds' deleted
✓ ServiceAccount 'internal-app' deleted
✓ Secret 'internal-app-token' deleted

=============================================
  VCF 9 Secrets Demo — Teardown Complete
=============================================
  Namespace:  secrets-demo (deleted)
  Secrets:    redis-creds, postgres-creds (deleted)
  ServiceAccount: internal-app (deleted)
=============================================
```

---

## Typical Timing

| Phase | Duration |
|---|---|
| Phase 1 (Namespace deletion) | 10–30s |
| Phase 2 (Cluster-scoped cleanup) | ~5s |
| Phase 3 (Supervisor cleanup) | ~10s |
| **Total** | **~25s–1 min** |

---

## Idempotency

The teardown script is safe to run multiple times. If resources are already deleted, each phase skips gracefully:

- Missing kubeconfig → skips guest cluster cleanup (Phases 1 and 2)
- Missing namespace → `--ignore-not-found` prevents errors
- Missing ClusterRole / ClusterRoleBinding / MutatingWebhookConfiguration → `--ignore-not-found` on all deletes
- Missing KeyValueSecrets → `vcf secret delete` exits cleanly
- Missing ServiceAccount / Secret → `--ignore-not-found` on all deletes
- VCF CLI context issues → attempts to recreate the context before proceeding

No phase aborts on failure — the script continues to the next resource and reports status in the teardown summary.
