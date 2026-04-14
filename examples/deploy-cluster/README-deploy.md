# Deploy Cluster: Full Stack Deploy Script

## Overview

`deploy-cluster.sh` automates the complete VCF 9 provisioning workflow from zero to a fully validated VKS cluster with running workloads. It is the "spin up" half of the dev environment lifecycle — pair it with `teardown-cluster.sh` to tear everything down.

> See the [Architecture Diagram](../../docs/architecture/deploy-cluster.md) for a visual overview of this deployment pattern.

The script is fully non-interactive. All configuration is driven by environment variables (loaded from `.env` via Docker Compose). No user input is required during execution.

---

## What the Script Does

### Phase 1: VCF CLI Context Creation

Authenticates to the VCFA endpoint using an API token and creates a named CLI context scoped to the target tenant. The `--set-current` flag activates the context immediately so all subsequent `kubectl` commands route through VCFA's CCI APIs.

```
vcf context create <CONTEXT_NAME> \
  --endpoint https://<VCFA_ENDPOINT> \
  --type cci \
  --tenant-name <TENANT_NAME> \
  --api-token <VCF_API_TOKEN> \
  --set-current
```

### Phase 2: Project + RBAC + Supervisor Namespace Provisioning

Applies a single multi-document YAML manifest that creates three resources in one shot:

1. **Project** (`project.cci.vmware.com/v1alpha2`) — the governance boundary for resource ownership and RBAC.
2. **ProjectRoleBinding** (`authorization.cci.vmware.com/v1alpha1`) — grants admin access to the specified user identity.
3. **SupervisorNamespace** (`infrastructure.cci.vmware.com/v1alpha2`) — provisions a vSphere Supervisor Namespace with compute, storage, and network resources. Uses `generateName` so VCF appends a random 5-character suffix to produce the final namespace name.

After creation, the script retrieves the dynamically generated namespace name via:

```
kubectl get supervisornamespaces -n <PROJECT_NAME> -o jsonpath='{.items[0].metadata.name}'
```

This phase includes an idempotency check — if the project already exists, creation is skipped.

### Phase 2b + 3: Context Refresh and Bridge (with retry)

This is the trickiest part of the VCF 9 workflow. The newly created namespace isn't immediately visible to the VCF CLI because the VCFA API needs time to propagate it. The script handles this with a retry loop:

1. Deletes the existing CLI context (`vcf context delete --yes`)
2. Re-creates it (`vcf context create`) — this triggers namespace discovery
3. Attempts to switch to the namespace-scoped context (`vcf context use <CONTEXT>:<NAMESPACE>:<PROJECT>`)
4. Verifies Cluster API access (`kubectl get clusters`)

If the namespace context isn't available yet, it retries every 10 seconds for up to 120 seconds. This is the "Context Bridge" — the critical step that makes `cluster.x-k8s.io` API resources visible.

### Phase 4: VKS Cluster Deployment

Applies a Cluster API manifest (`cluster.x-k8s.io/v1beta1`) that deploys a VKS cluster with:

- 1 control plane node by default (set `CONTROL_PLANE_REPLICAS=3` for HA)
- 1 worker node pool with autoscaling (min 2, max 10 nodes)
- Cluster class: `builtin-generic-v3.4.0`
- Kubernetes version: `v1.33.6+vmware.1-fips`

The script polls every 15 seconds until the cluster reaches `Provisioned` phase (timeout: 30 minutes). This phase includes an idempotency check — if the cluster already exists, creation is skipped.

### Phase 5: Kubeconfig Retrieval

Uses the VCF CLI to retrieve an admin kubeconfig with certificate-based authentication:

```
vcf cluster kubeconfig get <CLUSTER_NAME> --admin --export-file ./kubeconfig-<CLUSTER_NAME>.yaml
```

Then waits up to 300 seconds for the guest cluster API server to become reachable (the control plane VM needs time to boot and start the API server after the cluster reaches `Provisioned` state).

### Phase 5b: Worker Node Readiness Wait

After the API server is reachable, the script waits for at least `MIN_NODES` (default: 2) worker nodes to reach `Ready` status before proceeding. This prevents workload deployment failures caused by unschedulable pods. Timeout: 600 seconds.

```
kubectl get nodes --no-headers | grep -c ' Ready'
```

### Phase 5c–5f: Cluster Autoscaler Installation

After worker nodes are ready, the script installs the Cluster Autoscaler as a VKS standard package. This enables automatic node scaling when pods can't be scheduled due to insufficient resources.

1. **Create Package Namespace** (`tkg-packages`) — creates and labels the namespace with privileged PodSecurity standard.
2. **Register Package Repository** — registers the VKS standard packages repository and waits for reconciliation.
3. **Install Cluster Autoscaler** — installs the `cluster-autoscaler.kubernetes.vmware.com` package. The package version is automatically matched to the cluster's VKR version.
4. **Wait for Autoscaler Ready** — confirms the autoscaler deployment in `kube-system` has at least one ready replica.

The autoscaler uses the min/max annotations already set on the cluster manifest (`MIN_NODES` / `MAX_NODES`) to determine scaling bounds. When pods are Pending due to insufficient resources, the autoscaler adds worker nodes up to `MAX_NODES`. When nodes are underutilized, it scales back down to `MIN_NODES`.

The following tuning parameters control scale-down behavior:

| Variable | Default | Description |
|---|---|---|
| `AUTOSCALER_SCALE_DOWN_UNNEEDED_TIME` | `5m` | Time a node must be underutilized before removal |
| `AUTOSCALER_SCALE_DOWN_DELAY_AFTER_ADD` | `5m` | Cooldown after scale-up before scale-down resumes |
| `AUTOSCALER_SCALE_DOWN_DELAY_AFTER_DELETE` | `10s` | Cooldown after node deletion before next scale-down |
| `AUTOSCALER_SCALE_DOWN_UTILIZATION_THRESHOLD` | `0.5` | Node utilization threshold (0.0–1.0) below which scale-down is considered |

### Phase 5g: cert-manager VKS Package Installation

Installs the cert-manager VKS standard package (`cert-manager.kubernetes.vmware.com`) into the `tkg-packages` namespace. cert-manager provides automated TLS certificate lifecycle management and is a prerequisite for both Contour and Let's Encrypt ClusterIssuers. Polls until the package reaches a reconciled state.

### Phase 5h: Contour VKS Package + Envoy LoadBalancer + CoreDNS sslip.io Forwarding

Installs the Contour VKS standard package (`contour.kubernetes.vmware.com`) into the `tkg-packages` namespace. Contour provides an Envoy-based ingress controller for HTTP/HTTPS routing. After installation, creates an `envoy-lb` LoadBalancer service in the `tanzu-system-ingress` namespace (the VKS Contour package deploys Envoy as NodePort by default). Waits for the LoadBalancer to receive an external IP from NSX.

When `USE_SSLIP_DNS=true`, this phase also adds a CoreDNS forwarding rule for `sslip.io` queries to `8.8.8.8` and `1.1.1.1`. This is required for cert-manager HTTP-01 challenge self-checks — without it, cert-manager pods inside the cluster cannot resolve `*.sslip.io` hostnames to validate their own challenges.

### Phase 5i: Let's Encrypt ClusterIssuer Creation

Creates a `letsencrypt-prod` ClusterIssuer resource that configures cert-manager to request TLS certificates from Let's Encrypt via the ACME HTTP-01 challenge solver. If `LETSENCRYPT_EMAIL` is set, it is used as the ACME account registration email. The ClusterIssuer is referenced by Ingress annotations in subsequent deployment patterns to automatically provision trusted TLS certificates.

### Phase 6: Functional Validation Workload Deployment

Deploys three resources to the guest cluster to validate storage, compute, and networking:

1. **PersistentVolumeClaim** (`vks-test-pvc`) — 1Gi NFS volume. Validates CSI driver and storage backend.
2. **Deployment** (`vks-test-app`) — custom test app (`scafeman/vks-test-app:latest`) with hardened security context (non-root, seccomp, capabilities dropped). Validates pod scheduling and security enforcement. The `CONTAINER_REGISTRY` and `IMAGE_TAG` variables control the image used.
3. **LoadBalancer Service** (`vks-test-lb`) — NSX-provisioned external IP on port 80. Validates network ingress. When `USE_SSLIP_DNS=true`, the test app also keeps its raw LoadBalancer IP for direct NSX validation alongside the Ingress route through envoy-lb.

When `USE_SSLIP_DNS=true` (default), the script also creates a Contour Ingress resource with an sslip.io hostname (e.g., `vks-test.<IP>.sslip.io`) pointing to the Envoy LoadBalancer IP. If a ClusterIssuer is configured, the Ingress includes a `cert-manager.io/cluster-issuer` annotation to automatically provision a Let's Encrypt TLS certificate, enabling HTTPS access.

The script waits for:
- PVC to reach `Bound` status (timeout: 300s)
- LoadBalancer to receive an external IP (timeout: 300s)
- HTTP 200 response from the external IP
- (If TLS enabled) Certificate to reach Ready status (timeout: `CERT_WAIT_TIMEOUT`)

---

## Prerequisites

- Docker and Docker Compose installed
- The `vcf9-dev` container built and running (`docker compose up -d --build`)
- A populated `.env` file with all required variables (see below)

---

## Required Environment Variables

Set these in the `.env` file at the project root. Docker Compose loads them into the container automatically.

| Variable | Description | Example |
|---|---|---|
| `VCF_API_TOKEN` | API token from the VCFA portal | `uT3s3jCY8GIPzK...` |
| `VCFA_ENDPOINT` | VCFA hostname (no `https://` prefix) | `vcfa01.vmw-lab1.rpcai.rackspace-cloud.com` |
| `TENANT_NAME` | SSO tenant/organization | `org-rax-01` |
| `CONTEXT_NAME` | Local CLI context name | `my-dev-automation` |
| `PROJECT_NAME` | VCF Project name | `my-dev-project-01` |
| `USER_IDENTITY` | SSO user identity for RBAC | `rax-user-1` |
| `NAMESPACE_PREFIX` | Supervisor Namespace prefix (VCF appends a random suffix) | `my-dev-project-01-ns-` |
| `ZONE_NAME` | Availability zone for namespace placement | `zone-vmw-lab1-md-cl01` |
| `CLUSTER_NAME` | VKS cluster name | `my-dev-project-01-clus-01` |
| `CONTENT_LIBRARY_ID` | vSphere content library ID for OS images | `cl-32ee3681364c701d0` |

Optional variables with defaults: `REGION_NAME` (`region-us1-a`), `VPC_NAME` (`region-us1-a-default-vpc`), `RESOURCE_CLASS` (`xxlarge`), `K8S_VERSION` (`v1.33.6+vmware.1-fips`), `VM_CLASS` (`best-effort-large`), `STORAGE_CLASS` (`nfs`), `MIN_NODES` (`2`), `MAX_NODES` (`10`), `NODE_DISK_SIZE` (`50Gi`), `OS_NAME` (`photon`), `OS_VERSION` (empty — set to `24.04` for Ubuntu), `CONTROL_PLANE_REPLICAS` (`1` — set to `3` for HA), `NODE_POOL_NAME` (`node-pool-01`), `AUTOSCALER_SCALE_DOWN_UNNEEDED_TIME` (`5m`), `AUTOSCALER_SCALE_DOWN_DELAY_AFTER_ADD` (`5m`), `AUTOSCALER_SCALE_DOWN_UTILIZATION_THRESHOLD` (`0.5`), `AUTOSCALER_SCALE_DOWN_DELAY_AFTER_DELETE` (`10s`), `PACKAGE_NAMESPACE` (`tkg-packages`), `PACKAGE_REPO_URL` (VKS standard packages 3.6.0), `PACKAGE_TIMEOUT` (`600`), `USE_SSLIP_DNS` (`true`), `LETSENCRYPT_EMAIL` (empty), `CLUSTER_ISSUER_NAME` (`letsencrypt-prod`), `CERT_WAIT_TIMEOUT` (`300`), `CONTOUR_INGRESS_NAMESPACE` (`tanzu-system-ingress`), `CONTAINER_REGISTRY` (`scafeman`), `IMAGE_TAG` (`latest`), and all timeout values.

---

## How to Run

### Start the dev container (if not already running)

```bash
docker compose up -d --build
```

### Execute the deploy script

```bash
docker exec vcf9-dev bash examples/deploy-cluster/deploy-cluster.sh
```

### Monitor from a second terminal (optional)

While the script is running, you can monitor progress in a separate terminal:

```bash
# Watch cluster provisioning status
docker exec vcf9-dev kubectl get clusters -w

# Watch VM creation in real time
docker exec vcf9-dev kubectl get virtualmachines -w

# Check node readiness on the guest cluster
docker exec vcf9-dev bash -c "export KUBECONFIG=./kubeconfig-my-dev-project-01-clus-01.yaml && kubectl get nodes -w"

# Check workload status on the guest cluster
docker exec vcf9-dev bash -c "export KUBECONFIG=./kubeconfig-my-dev-project-01-clus-01.yaml && kubectl get pvc,deploy,svc"
```

---

## Expected Output

A successful run produces output like this:

```
[Step 1] Creating VCF CLI context and activating it...
✓ VCF CLI context 'my-dev-automation' created and activated
[Step 2] Creating Project, ProjectRoleBinding, and Supervisor Namespace...
✓ Project 'my-dev-project-01' provisioned with namespace 'my-dev-project-01-ns-x3qk6'
[Step 2b] Refreshing VCF CLI context and bridging to namespace '...'...
✓ Context bridge complete — now targeting namespace '...' in project 'my-dev-project-01'
[Step 4] Deploying VKS cluster 'my-dev-project-01-clus-01'...
  Waiting for cluster '...' to reach Provisioned state... (0s/1800s elapsed)
  ...
✓ VKS cluster 'my-dev-project-01-clus-01' is Provisioned and ready
[Step 5] Retrieving admin kubeconfig for VKS cluster '...'...
✓ Kubeconfig retrieved and saved to './kubeconfig-...' — connected to VKS guest cluster '...'
[Step 5b] Waiting for worker nodes to become Ready...
✓ All worker nodes are Ready
[Step 5c] Creating package namespace 'tkg-packages'...
✓ Namespace 'tkg-packages' created
[Step 5d] Registering package repository 'tkg-packages'...
✓ Package repository setup complete
[Step 5e] Installing Cluster Autoscaler package...
✓ Cluster Autoscaler installed and reconciled
[Step 5f] Waiting for Cluster Autoscaler deployment to be ready...
✓ Cluster Autoscaler is ready (min=2, max=10 worker nodes)
[Step 6] Deploying functional validation workload (PVC, Deployment, LoadBalancer Service)...
✓ PVC 'vks-test-pvc' is Bound
✓ LoadBalancer 'vks-test-lb' assigned external IP: 74.205.11.86
✓ HTTP connectivity test passed — received status 200 from http://74.205.11.86

=============================================
  VCF 9 Deploy Cluster — Deployment Complete
=============================================
  Cluster:    my-dev-project-01-clus-01
  Namespace:  my-dev-project-01-ns-x3qk6
  Kubeconfig: ./kubeconfig-my-dev-project-01-clus-01.yaml
  External IP: 74.205.11.86
=============================================
```

---

## Typical Timing

| Phase | Duration |
|---|---|
| Phase 1 (Context creation) | ~10s |
| Phase 2 (Project/Namespace) | ~5s |
| Phase 2b+3 (Context bridge) | ~20-30s |
| Phase 4 (Cluster provisioning) | 1-10 min |
| Phase 5 (API server reachable) | 1-2 min |
| Phase 5b (Worker nodes ready) | 2-3 min |
| Phase 5c-5f (Cluster Autoscaler) | 1-3 min |
| Phase 5g-5i (cert-manager, Contour, CoreDNS sslip.io forwarding, ClusterIssuer) | 2-5 min |
| Phase 6 (Workload validation) | 1-2 min |
| **Total** | **~6-21 min** |
