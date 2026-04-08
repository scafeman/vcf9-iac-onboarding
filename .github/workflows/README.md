# VCF 9 IaC — GitHub Actions Workflows

## Overview

This repository contains eight GitHub Actions workflows that automate the end-to-end deployment and teardown of VCF 9 VKS infrastructure and application stacks. Each workflow runs on a self-hosted runner built from `Dockerfile.runner` with VCF CLI, kubectl, Helm, jq, and openssl baked in. There is no `container:` directive — all `run:` steps execute directly on the runner.

| Workflow | File | Description |
|---|---|---|
| Deploy Cluster — Deploy VKS Cluster | `deploy-vks.yml` | Provisions VCF 9 VKS infrastructure end-to-end: context creation, project/namespace, cluster deployment, kubeconfig retrieval, cluster autoscaler installation, and functional validation |
| Deploy Metrics — Deploy VKS Metrics Stack | `deploy-vks-metrics.yml` | Deploys the metrics/observability stack (Telegraf, Prometheus, Grafana) on an existing VKS cluster |
| Deploy GitOps — Deploy ArgoCD Stack | `deploy-argocd.yml` | Deploys the ArgoCD consumption model stack (Harbor, ArgoCD, GitLab, GitLab Runner, Microservices Demo) on an existing VKS cluster |
| Deploy Hybrid App — Infrastructure Asset Tracker | `deploy-hybrid-app.yml` | Provisions a PostgreSQL VM via VM Service, deploys a Node.js API and Next.js frontend to the VKS cluster, demonstrating VM-to-container connectivity |
| Deploy Secrets Demo — VCF Secret Store | `deploy-secrets-demo.yml` | Demonstrates VCF Secret Store integration with vault-injected secrets for Redis and PostgreSQL authentication via a Next.js dashboard |
| Deploy Bastion VM — SSH Jump Host | `deploy-bastion-vm.yml` | Deploys an Ubuntu 24.04 bastion VM as a secure SSH jump host with source-IP-restricted LoadBalancer access in a supervisor namespace |
| Deploy Managed DB App — DSM PostgresCluster Asset Tracker | `deploy-managed-db-app.yml` | Provisions a DSM-managed PostgresCluster (VCF equivalent of AWS RDS), deploys a Node.js API and Next.js frontend to the VKS cluster, and verifies end-to-end connectivity |
| Deploy HA VM App — HA Three-Tier Application on VMs | `deploy-ha-vm-app.yml` | Deploys a traditional HA three-tier application using VCF VM Service VMs: 2× web VMs (Next.js) + LoadBalancer, 2× API VMs (Express) + LoadBalancer, DSM PostgresCluster |
| Teardown — Teardown VCF Stacks | `teardown.yml` | Selectively tears down GitOps, Metrics, Hybrid App, and Cluster stacks in reverse dependency order |

## Execution Order

Deploy Cluster must complete successfully before Deploy Metrics or Deploy GitOps can run. Deploy Metrics and Deploy GitOps can run in any order after Deploy Cluster. The Teardown workflow reverses this order — it tears down GitOps first, then Metrics, then the Cluster.

```
Deploy Cluster (deploy-vks.yml)  ← must run first
    ├── Deploy Metrics (deploy-vks-metrics.yml)
    ├── Deploy GitOps (deploy-argocd.yml)
    ├── Deploy Hybrid App (deploy-hybrid-app.yml)
    ├── Deploy Managed DB App (deploy-managed-db-app.yml)
    ├── Deploy HA VM App (deploy-ha-vm-app.yml)
    ├── Deploy Secrets Demo (deploy-secrets-demo.yml)
    └── Deploy Bastion VM (deploy-bastion-vm.yml)  ← no VKS cluster required

Teardown (teardown.yml)  ← reverses the deploy order
    ├── Phase A: GitOps Stack Teardown
    ├── Phase B: Metrics Stack Teardown
    ├── Phase D: Hybrid App Stack Teardown
    ├── Phase E: Secrets Demo Stack Teardown
    ├── Phase F: Bastion VM Teardown
    ├── Phase G: Managed DB App Teardown
    ├── Phase H: HA VM App Teardown
    └── Phase C: Cluster Stack Teardown
```

Deploy Metrics, Deploy GitOps, Deploy Hybrid App, and Deploy Managed DB App share the same VKS cluster provisioned by Deploy Cluster. Deploy Metrics and Deploy GitOps share common infrastructure (cert-manager, Contour, package repository, Envoy LoadBalancer, certificates) that is handled idempotently — whichever runs first installs the shared components, and the second skips them.

## Shared Configuration

All three workflows follow the same patterns:

- **Parameter resolution:** `workflow_dispatch` input → `client_payload` → GitHub secret → built-in default
- **Runner:** `runs-on: [self-hosted, vcf]` — no `container:` directive
- **Environment:** `vcf-production` for approval gates
- **Trigger methods:** GitHub UI (`workflow_dispatch`), API (`repository_dispatch`), companion trigger scripts

### Secret-Only (shared across all workflows)

| Secret | Description |
|---|---|
| `VCF_API_TOKEN` | API token from the VCFA portal for CCI authentication |

### Overridable via `client_payload` (shared across all workflows)

| Parameter | `client_payload` key | Description |
|---|---|---|
| `VCFA_ENDPOINT` | `vcfa_endpoint` | VCFA hostname (without `https://` prefix) |
| `TENANT_NAME` | `tenant_name` | SSO tenant/organization name |

Configure secrets in your repository under **Settings → Secrets and variables → Actions → New repository secret**.

## Environment Protection

All three workflows use `environment: vcf-production`. To enable approval gates:

1. Go to **Settings → Environments** in your GitHub repository
2. Click **New environment** and name it `vcf-production`
3. Enable **Required reviewers** and add one or more approvers
4. Optionally configure a **Wait timer** or restrict to specific branches

## Credential Retrieval

After a successful deployment, credentials are not printed in the job summary. Use the following commands to retrieve them from the cluster.

### Kubeconfig

Before retrieving the kubeconfig, you must be in the correct CCI namespace context. If you're not sure which context to use, refresh your contexts and switch to the one containing your cluster's project:

```bash
# List available contexts
vcf context list

# If your cluster's project context isn't listed, refresh
vcf context refresh

# Switch to the namespace context for your cluster's project
# Format: <org-context>:<namespace-id>:<project-name>
vcf context use <ORG_CONTEXT>:<NAMESPACE_ID>:<PROJECT_NAME>
```

Then download the kubeconfig:

**Linux / macOS (Bash):**

```bash
vcf cluster kubeconfig get <CLUSTER_NAME> --admin --export-file kubeconfig-<CLUSTER_NAME>.yaml
export KUBECONFIG=./kubeconfig-<CLUSTER_NAME>.yaml
kubectl config use-context <CLUSTER_NAME>-admin@<CLUSTER_NAME>
kubectl get namespaces   # verify connectivity
```

**Windows (PowerShell):**

```powershell
vcf cluster kubeconfig get <CLUSTER_NAME> --admin --export-file kubeconfig-<CLUSTER_NAME>.yaml
$env:KUBECONFIG = ".\kubeconfig-<CLUSTER_NAME>.yaml"
kubectl config use-context <CLUSTER_NAME>-admin@<CLUSTER_NAME>
kubectl get namespaces   # verify connectivity
```

> **Note:** The `vcf cluster kubeconfig get` command must be run from a namespace-level context (not the org-level context). If you get a "client to provide credentials" error, switch to the correct namespace context first. The `--export-file` flag saves the kubeconfig as a standalone file that may contain multiple contexts — use `kubectl config use-context` to switch to the admin context before running kubectl commands.

### Service Credentials

Once connected to the cluster via the kubeconfig above, retrieve service passwords with:

**Linux / macOS (Bash):**

```bash
# ArgoCD admin password
kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d

# GitLab root password
kubectl get secret gitlab-gitlab-initial-root-password -n gitlab-system -o jsonpath='{.data.password}' | base64 -d

# Grafana admin password
kubectl get grafana grafana -n grafana -o jsonpath='{.spec.config.security.admin_password}'

# Harbor admin password
kubectl get secret harbor-core -n harbor -o jsonpath='{.data.HARBOR_ADMIN_PASSWORD}' | base64 -d
```

**Windows (PowerShell):**

```powershell
# ArgoCD admin password
[System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String((kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}')))

# GitLab root password
[System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String((kubectl get secret gitlab-gitlab-initial-root-password -n gitlab-system -o jsonpath='{.data.password}')))

# Grafana admin password (not base64 encoded)
kubectl get grafana grafana -n grafana -o jsonpath='{.spec.config.security.admin_password}'

# Harbor admin password
[System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String((kubectl get secret harbor-core -n harbor -o jsonpath='{.data.HARBOR_ADMIN_PASSWORD}')))
```

## Self-Hosted Runner Setup

The VCFA endpoint resides on a private network, so all workflows require a self-hosted runner. The runner is provided as a container service in `docker-compose.yml` (`gh-actions-runner` service).

### Prerequisites

- **Network access** to the VCFA endpoint on **port 443** from the machine running Docker
- **Docker** must be installed (Docker Desktop on Windows/macOS, or Docker Engine on Linux)

### Runner Architecture

The runner image is built from `Dockerfile.runner`, which extends `myoung34/github-runner:latest` and installs:

- **VCF CLI** v9.0.2 — context management, project/namespace provisioning, kubeconfig retrieval
- **kubectl** v1.33.0 — Kubernetes resource management
- **Helm** v4 — chart-based deployments
- **jq** — JSON processing
- **openssl** — certificate generation

### Setup Steps

1. **Generate a runner registration token** from **Settings → Actions → Runners → New self-hosted runner**
2. **Set environment variables** in `.env`:
   ```
   RUNNER_TOKEN=<your-runner-registration-token>
   REPO_URL=https://github.com/OWNER/REPO
   ```
3. **Start the runner:** `docker compose up -d`
4. **Verify** at **Settings → Actions → Runners** — the runner should appear as `vcf-local-runner` with labels `self-hosted` and `vcf`

---

# Deploy Cluster — Deploy VKS Cluster (`deploy-vks.yml`)

## Overview

Provisions VCF 9 VKS infrastructure end-to-end: context creation, project and namespace provisioning, context bridge, cluster deployment, kubeconfig retrieval, and functional validation. This workflow must complete successfully before Deploy Metrics or Deploy GitOps can run.

## Triggering the Workflow

### GitHub UI (workflow_dispatch)

1. Go to **Actions** → **"Deploy VKS Cluster"** → **"Run workflow"**
2. Fill in: **project_name**, **cluster_name**, **namespace_prefix**, and optionally **environment**, **resource_class**, **vm_class**, **min_nodes**, **max_nodes**, **containerd_volume_size**, **os_name**, **os_version**, **control_plane_replicas**, **node_pool_name**, **vpc_name**

### Trigger Script (repository_dispatch)

```bash
./scripts/trigger-deploy.sh \
  --repo myorg/vcf9-iac \
  --token ghp_xxxxxxxxxxxx \
  --project-name my-project-01 \
  --cluster-name my-project-01-clus-01 \
  --namespace-prefix my-project-01-ns- \
  --vpc-name region-us1-a-sample-vpc \
  --region-name region-us1-a
```

**Required:** `--repo`, `--token`, `--project-name`, `--cluster-name`, `--namespace-prefix`

**Optional:** `--environment`, `--vpc-name`, `--region-name`, `--zone-name`, `--resource-class`, `--user-identity`, `--content-library-id`, `--k8s-version`, `--vm-class`, `--storage-class`, `--min-nodes`, `--max-nodes`, `--containerd-volume-size`, `--os-name`, `--os-version`, `--control-plane-replicas`, `--node-pool-name`, `--vcfa-endpoint`, `--tenant-name`

### Direct API Call (curl)

```bash
curl -X POST \
  -H "Authorization: token GITHUB_TOKEN" \
  -H "Accept: application/vnd.github+json" \
  -H "Content-Type: application/json" \
  "https://api.github.com/repos/OWNER/REPO/dispatches" \
  -d '{
    "event_type": "deploy-vks",
    "client_payload": {
      "project_name": "my-dev-project-01",
      "cluster_name": "my-dev-project-01-clus-01",
      "namespace_prefix": "my-dev-project-01-ns-",
      "environment": "demo"
    }
  }'
```

## Parameters

### Overridable via `client_payload` (fall back to secrets)

| Parameter | `client_payload` key | Description |
|---|---|---|
| `USER_IDENTITY` | `user_identity` | SSO user identity for RBAC (ProjectRoleBinding subject) |
| `CONTENT_LIBRARY_ID` | `content_library_id` | vSphere content library ID used for OS image resolution |
| `ZONE_NAME` | `zone_name` | Availability zone name for Supervisor Namespace placement |

### Overridable via `client_payload` (fall back to secrets, then defaults)

| Parameter | `client_payload` key | Default | Description |
|---|---|---|---|
| `PROJECT_NAME` | `project_name` | (required) | VCF Project name |
| `CLUSTER_NAME` | `cluster_name` | (required) | VKS cluster name |
| `NAMESPACE_PREFIX` | `namespace_prefix` | (required) | Supervisor Namespace prefix |
| `ENVIRONMENT` | `environment` | `demo` | Environment label |
| `REGION_NAME` | `region_name` | `region-us1-a` | Region for Supervisor Namespace |
| `VPC_NAME` | `vpc_name` | `region-us1-a-default-vpc` | VPC for Supervisor Namespace |
| `RESOURCE_CLASS` | `resource_class` | `xxlarge` | Resource class for Supervisor Namespace |
| `K8S_VERSION` | `k8s_version` | `v1.33.6+vmware.1-fips` | Kubernetes version for the VKS cluster |
| `VM_CLASS` | `vm_class` | `best-effort-large` | VM class for cluster worker nodes |
| `STORAGE_CLASS` | `storage_class` | `nfs` | Storage class for PVCs and containerd volumes |
| `MIN_NODES` | `min_nodes` | `2` | Minimum worker nodes (autoscaler min) |
| `MAX_NODES` | `max_nodes` | `10` | Maximum worker nodes (autoscaler max) |
| `CONTAINERD_VOLUME_SIZE` | `containerd_volume_size` | `50Gi` | Containerd data volume size per node |
| `OS_NAME` | `os_name` | `photon` | Node OS image name (`photon` or `ubuntu`) |
| `OS_VERSION` | `os_version` | (none) | Node OS version (required for ubuntu, e.g., `24.04`) |
| `CONTROL_PLANE_REPLICAS` | `control_plane_replicas` | `1` | Control plane node count: `1` (default) or `3` (HA) |
| `NODE_POOL_NAME` | `node_pool_name` | `node-pool-01` | Worker node pool name |
| `AUTOSCALER_SCALE_DOWN_UNNEEDED_TIME` | `autoscaler_scale_down_unneeded_time` | `5m` | Time a node must be underutilized before removal |
| `AUTOSCALER_SCALE_DOWN_DELAY_AFTER_ADD` | `autoscaler_scale_down_delay_after_add` | `5m` | Cooldown after scale-up before scale-down is considered |
| `AUTOSCALER_SCALE_DOWN_UTILIZATION_THRESHOLD` | `autoscaler_scale_down_utilization_threshold` | `0.5` | Node utilization threshold below which scale-down is considered (0.0–1.0) |
| `AUTOSCALER_SCALE_DOWN_DELAY_AFTER_DELETE` | `autoscaler_scale_down_delay_after_delete` | `10s` | Cooldown after node deletion before next scale-down scan |
| `PACKAGE_NAMESPACE` | `package_namespace` | `tkg-packages` | Namespace for VKS standard packages and Cluster Autoscaler |
| `PACKAGE_REPO_URL` | `package_repo_url` | VKS standard packages 3.6.0 | Package repository URL |
| `PACKAGE_TIMEOUT` | `package_timeout` | `600` | Timeout (seconds) for package reconciliation |

## Workflow Steps

| Phase | Step Name | Description |
|---|---|---|
| 1 | **Validate Inputs** | Checks all required environment variables are set; fails with a list of missing variables |
| 2 | **Create VCF CLI Context** | Deletes any existing context and creates a new one authenticated to the VCFA endpoint |
| 3 | **Create Project and Namespace** | Applies a multi-document manifest to create the VCF Project, RBAC binding, and Supervisor Namespace (skips if project already exists) |
| 3b | **Get Dynamic Namespace Name** | Retrieves the auto-generated namespace name and passes it to subsequent steps |
| 4 | **Execute Context Bridge** | Retries context recreation to discover the new namespace (120s timeout, 10s interval) |
| 5 | **Deploy VKS Cluster** | Applies the Cluster API manifest to create the VKS cluster (skips if cluster already exists) |
| 5b | **Wait for Cluster Provisioning** | Polls cluster status until `Provisioned` (1800s timeout, 15s interval) |
| 6 | **Retrieve Kubeconfig** | Exports the admin kubeconfig for the guest cluster |
| 6b | **Wait for Guest Cluster API** | Polls until the guest cluster API server is reachable (300s timeout) |
| 6c | **Wait for Worker Nodes Ready** | Waits for minimum worker nodes to reach Ready status (600s timeout) |
| 6d | **Create Package Namespace** | Creates the `tkg-packages` namespace with privileged PodSecurity standard |
| 6e | **Register Package Repository** | Registers the VKS standard packages repository and waits for reconciliation |
| 6f | **Install Cluster Autoscaler** | Installs the Cluster Autoscaler package to enable automatic node scaling |
| 6g | **Wait for Autoscaler Ready** | Confirms the autoscaler deployment in `kube-system` is ready |
| 7 | **Deploy Functional Test Workload** | Deploys a PVC, nginx Deployment, and LoadBalancer Service to validate the cluster |
| 7b | **Wait for PVC Bound** | Waits for the PersistentVolumeClaim to bind (300s timeout) |
| 7c | **Wait for LoadBalancer IP** | Waits for the Service to receive an external IP (300s timeout) |
| 7d | **HTTP Connectivity Test** | Curls the LoadBalancer IP and verifies HTTP 200 |
| — | **Write Job Summary** | Writes a Markdown summary with cluster details to the GitHub Actions job summary |
| — | **Write Failure Summary** | On failure, writes a failure summary with error context |

## Troubleshooting

### Runner not picking up jobs

- Verify the runner labels match `[self-hosted, vcf]` — go to **Settings → Actions → Runners** and check the runner's labels
- Confirm the runner status shows as **Idle** or **Active** (not **Offline**)
- Check that `RUNNER_TOKEN` in `.env` is a valid, non-expired registration token
- Restart the runner: `docker compose restart gh-actions-runner`

### Environment approval pending

- If the workflow is stuck at "Waiting for review", a required reviewer must approve the deployment
- Go to the workflow run page and click **Review deployments** to approve or reject

### Context creation fails

- Verify the VCFA endpoint is reachable from the runner host: `curl -k https://<VCFA_ENDPOINT>/health`
- Check that the `VCF_API_TOKEN` secret is valid and not expired
- Confirm `TENANT_NAME` matches the SSO tenant configured in VCFA

### Context bridge timeout

- The context bridge retries for 120 seconds to handle VCFA propagation delays after namespace creation
- If it consistently times out, the Supervisor Namespace may not have been created successfully
- As a workaround, re-run the workflow — the idempotency checks will skip already-created resources

### Cluster provisioning timeout

- The default timeout is 1800 seconds (30 minutes) — large clusters may need more time
- Check vSphere resource availability (CPU, memory, storage) on the target cluster
- Verify the content library (`CONTENT_LIBRARY_ID`) is synced and contains the required OS images

### Functional test fails

- **PVC not binding:** Verify the storage class exists in the guest cluster and the CSI driver is operational
- **No LoadBalancer IP:** Check NSX load balancer capacity and VPC connectivity
- **HTTP test returns non-200:** The nginx pod may not be ready yet; check pod status with `kubectl get pods`

### Cluster Autoscaler not scaling

- Verify the autoscaler package is installed: `kubectl get packageinstall -n tkg-packages | grep cluster-autoscaler`
- Check the autoscaler deployment is running: `kubectl get deployment -A | grep autoscaler`
- Verify the autoscaler annotations are set on the cluster manifest: `cluster.x-k8s.io/cluster-api-autoscaler-node-group-min-size` and `max-size`
- Check autoscaler logs: `kubectl logs -n kube-system -l app=cluster-autoscaler --tail=50`
- The autoscaler requires `clusterConfig.clusterName` and `clusterConfig.clusterNamespace` values — if the package shows `Reconcile failed`, the values file may not have been passed correctly

---

# Deploy Metrics — Deploy VKS Metrics Stack (`deploy-vks-metrics.yml`)

## Overview

Deploys the VKS Metrics Observability stack (Telegraf, Prometheus, Grafana) on an existing VKS cluster provisioned by Deploy Cluster. Requires a running VKS cluster with a valid admin kubeconfig file.

## Triggering the Workflow

### GitHub UI (workflow_dispatch)

1. Go to **Actions** → **"Deploy VKS Metrics Stack"** → **"Run workflow"**
2. Fill in: **cluster_name** (required), **telegraf_version** (optional, defaults to `1.37.1+vmware.1-vks.1`), **environment** (optional, defaults to `demo`)

### Trigger Script (repository_dispatch)

```bash
./scripts/trigger-deploy-metrics.sh \
  --repo myorg/vcf9-iac \
  --token ghp_xxxxxxxxxxxx \
  --cluster-name my-project-01-clus-01 \
  --telegraf-version 1.4.3 \
  --environment demo \
  --domain lab.local
```

**Required:** `--repo`, `--token`, `--cluster-name`

**Optional:** `--telegraf-version`, `--environment`, `--domain`, `--kubeconfig-path`, `--package-namespace`, `--package-repo-url`, `--telegraf-values-file`, `--prometheus-values-file`, `--storage-class`, `--grafana-admin-password`, `--package-timeout`

### Direct API Call (curl)

```bash
curl -X POST \
  -H "Authorization: token GITHUB_TOKEN" \
  -H "Accept: application/vnd.github+json" \
  -H "Content-Type: application/json" \
  "https://api.github.com/repos/OWNER/REPO/dispatches" \
  -d '{
    "event_type": "deploy-vks-metrics",
    "client_payload": {
      "cluster_name": "my-dev-project-01-clus-01",
      "telegraf_version": "1.4.3",
      "environment": "demo",
      "domain": "lab.local"
    }
  }'
```

## Parameters

| Parameter | `client_payload` key | Default | Description |
|---|---|---|---|
| `CLUSTER_NAME` | `cluster_name` | (required) | VKS cluster name |
| `TELEGRAF_VERSION` | `telegraf_version` | `1.37.1+vmware.1-vks.1` | Telegraf package version to install |
| `ENVIRONMENT` | `environment` | `demo` | Environment label for the deployment |
| `DOMAIN` | `domain` | `lab.local` | Domain suffix for service hostnames |
| `KUBECONFIG_PATH` | `kubeconfig_path` | `./kubeconfig-<CLUSTER_NAME>.yaml` | Path to the admin kubeconfig file |
| `PACKAGE_NAMESPACE` | `package_namespace` | `tkg-packages` | Namespace for VKS standard packages |
| `PACKAGE_REPO_URL` | `package_repo_url` | VKS standard packages OCI URL | VKS standard packages OCI repository URL |
| `TELEGRAF_VALUES_FILE` | `telegraf_values_file` | `examples/deploy-metrics/telegraf-values.yaml` | Telegraf Helm values file path |
| `PROMETHEUS_VALUES_FILE` | `prometheus_values_file` | `examples/deploy-metrics/prometheus-values.yaml` | Prometheus Helm values file path |
| `STORAGE_CLASS` | `storage_class` | `nfs` | Storage class for PVCs |
| `GRAFANA_ADMIN_PASSWORD` | `grafana_admin_password` | (auto-generated) | Grafana admin password |
| `PACKAGE_TIMEOUT` | `package_timeout` | `600` | Package reconciliation timeout in seconds |
| `NODE_CPU_THRESHOLD` | `node_cpu_threshold` | `4000` | Minimum allocatable CPU (millicores) for node sizing advisory |

## Workflow Steps

| # | Step Name | Description |
|---|---|---|
| 1 | **Checkout Repository** | Checks out the repository using `actions/checkout@v5` |
| 2 | **Setup Kubeconfig** | Sets `KUBECONFIG` env var to the provided path (default `./kubeconfig-<CLUSTER_NAME>.yaml`); fails if file not found |
| 3 | **Verify Cluster Connectivity** | Runs `kubectl get namespaces` to verify the cluster is reachable; fails if unreachable |
| 4 | **Node Sizing Advisory** | Queries total allocatable CPU across worker nodes; prints `::warning::` if below threshold but does not fail |
| 5 | **Create Package Namespace** | Creates the package namespace (default `tkg-packages`) with privileged PodSecurity label; skips if exists |
| 6 | **Register Package Repository** | Registers the VKS standard packages OCI repository; polls until reconciled; skips if already registered |
| 7 | **Install Telegraf** | Installs the Telegraf VKS package with specified version and values file; polls until reconciled |
| 8 | **Install cert-manager** | Installs the cert-manager VKS package; polls until reconciled; skips if already installed |
| 9 | **Install Contour** | Installs the Contour VKS package; polls until reconciled; skips if already installed |
| 10 | **Create Envoy LoadBalancer** | Creates `envoy-lb` LoadBalancer service in `tanzu-system-ingress`; waits for external IP; stores IP in `CONTOUR_LB_IP` |
| 11 | **Generate Self-Signed Certificates** | Generates CA cert, wildcard CSR, signed wildcard cert, and fullchain cert; skips if certs already exist |
| 12 | **Configure CoreDNS** | Patches CoreDNS ConfigMap with `grafana.<DOMAIN>` → Contour LB IP; restarts CoreDNS; waits for API server |
| 13 | **Install Prometheus** | Installs the Prometheus VKS package with specified values file; polls until reconciled |
| 14 | **Install Grafana Operator** | Creates Grafana namespace with baseline PodSecurity; installs Grafana Operator via Helm; waits for pod Running |
| 15 | **Configure Grafana Instance** | Creates TLS secret, applies Grafana instance/datasource/dashboard manifests, creates Contour Ingress; waits for pod Running |
| 16 | **Verify Installation** | Lists installed packages; checks Telegraf, Prometheus, Grafana pods; prints warnings for non-Running pods |
| 17 | **Write Job Summary** | Writes Markdown summary with cluster details, Grafana URL, credentials, and DNS instructions |
| 18 | **Write Failure Summary** | On failure (`if: failure()`), writes failure summary with cluster name, environment, and error context |

## Troubleshooting

### Kubeconfig not found

- Verify Deploy Cluster has completed and the kubeconfig file exists on the runner
- If stored at a non-default path, pass `--kubeconfig-path` via the trigger script or set the `KUBECONFIG_PATH` secret

### Package reconciliation timeout

- Default timeout is `600s` — increase via `PACKAGE_TIMEOUT` if packages take longer
- Check the package repository is registered: `vcf package repository list -n tkg-packages`
- Verify the package namespace has the `privileged` PodSecurity label

### CoreDNS restart issues

- If CoreDNS pods fail to restart, check the patched Corefile for syntax errors: `kubectl get configmap coredns -n kube-system -o yaml`
- If the API server becomes unreachable after the restart, wait 30–60 seconds and re-run

### Helm install failures (Grafana Operator)

- Check the Helm release status: `helm status grafana-operator -n grafana`
- Common causes: insufficient cluster resources, image pull errors
- Re-running the workflow will retry — `helm upgrade --install` is idempotent

---

# Deploy GitOps — Deploy ArgoCD Stack (`deploy-argocd.yml`)

## Overview

Deploys the ArgoCD Consumption Model stack (Harbor, ArgoCD, GitLab, GitLab Runner, and the Microservices Demo) on an existing VKS cluster provisioned by Deploy Cluster. Requires a running VKS cluster with a valid admin kubeconfig file.

## Triggering the Workflow

### GitHub UI (workflow_dispatch)

1. Go to **Actions** → **"Deploy ArgoCD Stack"** → **"Run workflow"**
2. Fill in: **cluster_name** (required), **environment** (optional, defaults to `demo`)

### Trigger Script (repository_dispatch)

```bash
./scripts/trigger-deploy-argocd.sh \
  --repo myorg/vcf9-iac \
  --token ghp_xxxxxxxxxxxx \
  --cluster-name my-project-01-clus-01 \
  --environment demo \
  --domain lab.local
```

**Required:** `--repo`, `--token`, `--cluster-name`

**Optional:** `--environment`, `--domain`, `--kubeconfig-path`, `--harbor-version`, `--argocd-version`, `--gitlab-operator-version`, `--gitlab-runner-version`, `--harbor-admin-password`, `--package-timeout`

### Direct API Call (curl)

```bash
curl -X POST \
  -H "Authorization: token GITHUB_TOKEN" \
  -H "Accept: application/vnd.github+json" \
  -H "Content-Type: application/json" \
  "https://api.github.com/repos/OWNER/REPO/dispatches" \
  -d '{
    "event_type": "deploy-argocd",
    "client_payload": {
      "cluster_name": "my-dev-project-01-clus-01",
      "environment": "demo",
      "domain": "lab.local"
    }
  }'
```

## Parameters

| Parameter | `client_payload` key | Default | Description |
|---|---|---|---|
| `CLUSTER_NAME` | `cluster_name` | (required) | VKS cluster name |
| `ENVIRONMENT` | `environment` | `demo` | Environment label for the deployment |
| `DOMAIN` | `domain` | `lab.local` | Domain suffix for service hostnames |
| `KUBECONFIG_PATH` | `kubeconfig_path` | `./kubeconfig-<CLUSTER_NAME>.yaml` | Path to the admin kubeconfig file |
| `HARBOR_VERSION` | `harbor_version` | `1.18.3` | Harbor Helm chart version |
| `ARGOCD_VERSION` | `argocd_version` | `9.4.17` | ArgoCD Helm chart version |
| `GITLAB_OPERATOR_VERSION` | `gitlab_operator_version` | `9.10.3` | GitLab Operator Helm chart version |
| `GITLAB_RUNNER_VERSION` | `gitlab_runner_version` | `0.87.1` | GitLab Runner Helm chart version |
| `HARBOR_ADMIN_PASSWORD` | `harbor_admin_password` | (auto-generated) | Harbor admin password |
| `PACKAGE_TIMEOUT` | `package_timeout` | `900` | Package reconciliation timeout in seconds |
| `PACKAGE_NAMESPACE` | `package_namespace` | `tkg-packages` | Namespace for VKS standard packages |
| `PACKAGE_REPO_URL` | `package_repo_url` | VKS standard packages OCI URL | VKS standard packages OCI repository URL |

## Workflow Steps

| # | Step Name | Description |
|---|---|---|
| 1 | **Checkout Repository** | Checks out the repository using `actions/checkout@v5` |
| 2 | **Setup Kubeconfig** | Sets `KUBECONFIG` env var to the provided path; fails if file not found |
| 3 | **Verify Cluster Connectivity** | Runs `kubectl get namespaces` to verify the cluster is reachable; fails if unreachable |
| 4 | **Generate Self-Signed Certificates** | Generates CA cert, wildcard CSR (using `examples/deploy-gitops/wildcard.cnf`), signed wildcard cert, and fullchain cert; skips if certs exist |
| 5 | **Create Package Namespace** | Creates the package namespace with privileged PodSecurity label; skips if exists |
| 6 | **Register Package Repository** | Registers the VKS standard packages OCI repository; polls until reconciled; skips if already registered |
| 7 | **Install cert-manager** | Installs the cert-manager VKS package; polls until reconciled; skips if already installed |
| 8 | **Install Contour** | Installs the Contour VKS package; polls until reconciled; skips if already installed |
| 9 | **Create Envoy LoadBalancer** | Creates `envoy-lb` LoadBalancer service; waits for external IP; stores IP in `CONTOUR_LB_IP` |
| 10 | **Install Harbor** | Creates Harbor namespace, TLS/CA secrets, installs Harbor via Helm; skips if release exists; waits for pods Running |
| 11 | **Configure CoreDNS** | Patches CoreDNS ConfigMap with `harbor/gitlab/argocd.<DOMAIN>` → Contour LB IP; restarts CoreDNS; waits for API server |
| 12 | **Install ArgoCD** | Installs ArgoCD via Helm with hostname substitution; retrieves admin password from `argocd-initial-admin-secret`; waits for pods Running |
| 13 | **Install ArgoCD CLI** | Downloads ArgoCD CLI from GitHub releases if not in PATH; adds to `$GITHUB_PATH` |
| 14 | **Distribute Certificates** | Creates TLS secrets in ArgoCD, GitLab, and Runner namespaces using `--dry-run=client -o yaml \| kubectl apply -f -` |
| 15 | **Install GitLab** | Installs GitLab via Helm with hostname substitution; waits for webservice pod Running |
| 16 | **Verify Harbor Proxy Configuration** | Checks GitLab values file for Harbor proxy cache config; prints `::warning::` if not found |
| 17 | **Install GitLab Runner** | Retrieves runner registration token; installs GitLab Runner via Helm; waits for pod Running |
| 18 | **Disable GitLab Public Sign-Up** | Calls GitLab API to disable public sign-up; prints `::warning::` on failure (non-fatal) |
| 19 | **Register Cluster with ArgoCD** | Authenticates to ArgoCD via `kubectl exec`; copies kubeconfig; registers cluster with `argocd cluster add` |
| 20 | **Bootstrap ArgoCD Application** | Applies ArgoCD Application manifest for Microservices Demo; waits for Synced and Healthy state |
| 21 | **Verify Microservices Demo** | Checks all 11 microservice pods are Running; waits for `frontend-external` LoadBalancer IP |
| 22 | **Write Job Summary** | Writes Markdown summary with all service URLs, credentials, versions, and DNS instructions |
| 23 | **Write Failure Summary** | On failure (`if: failure()`), writes failure summary with cluster name, environment, and error context |

## Shared Infrastructure Idempotency

Deploy Metrics and Deploy GitOps share these components, all handled idempotently:

| Shared Component | Idempotency Check | Behavior |
|---|---|---|
| Package namespace (`tkg-packages`) | `kubectl get ns` | Skips creation if namespace exists |
| Package repository (`tkg-packages`) | `vcf package repository list` | Skips registration if repository found |
| cert-manager | `vcf package installed list` | Skips installation if package found |
| Contour | `vcf package installed list` | Skips installation if package found |
| Envoy LoadBalancer (`envoy-lb`) | `kubectl get svc envoy-lb` | Skips creation if service exists; retrieves existing IP |
| Self-signed certificates (`certs/`) | File existence check (`ca.crt`) | Skips generation if certificates exist |
| CoreDNS host entries | `grep` on Corefile content | Skips patch if hostname already present |

## Troubleshooting

### Kubeconfig not found

- Verify Deploy Cluster has completed and the kubeconfig file exists on the runner
- If stored at a non-default path, pass `--kubeconfig-path` via the trigger script

### Cluster unreachable

- Verify the VKS cluster from Deploy Cluster is still running
- Check network connectivity from the runner host to the cluster API endpoint
- If the kubeconfig contains an expired token, re-run Deploy Cluster to regenerate it

### Package reconciliation timeout

- Default timeout is `900s` — increase via `PACKAGE_TIMEOUT` if packages take longer
- Check the package repository is registered: `vcf package repository list -n tkg-packages`
- If a package is stuck, delete it and re-run — the idempotency checks will re-install it

### Helm install failures

- Check the Helm release status: `helm status <release> -n <namespace>`
- Common causes: insufficient cluster resources (CPU/memory), PVC binding failures, image pull errors
- For Harbor: verify the TLS and CA secrets exist in the `harbor` namespace
- For ArgoCD: verify the values file hostname substitution produced valid YAML
- For GitLab: the install can take 10+ minutes — increase the Helm `--timeout` if needed
- To clean up a failed release: `helm uninstall <release> -n <namespace>` and re-run

### CoreDNS restart issues

- Check the patched Corefile for syntax errors: `kubectl get configmap coredns -n kube-system -o yaml`
- If the API server becomes unreachable after the restart, wait 30–60 seconds and re-run
- To manually fix a broken Corefile: `kubectl edit configmap coredns -n kube-system`

### GitLab pod startup delays

- GitLab webservice pod can take 5–10 minutes to reach Running state
- If the workflow times out, increase `PACKAGE_TIMEOUT` (default `900s`)
- Check pod events: `kubectl describe pod <pod-name> -n gitlab-system`
- Common causes: insufficient memory (GitLab requires ~8 GB RAM), PVC binding delays, image pull throttling

---

# Deploy Hybrid App — Infrastructure Asset Tracker (`deploy-hybrid-app.yml`)

## Overview

Deploys a full-stack Infrastructure Asset Tracker demo that demonstrates VM-to-container connectivity within a VCF 9 namespace. A PostgreSQL 16 database runs on a dedicated VM provisioned via the VCF VM Service, while a Node.js REST API and Next.js frontend run as containerized workloads in the VKS guest cluster. Both the VM and containers reside in the same VCF namespace and NSX VPC, communicating over Layer 3 networking.

## Triggering the Workflow

### GitHub UI (workflow_dispatch)

1. Go to **Actions** → **"Deploy Hybrid App"** → **"Run workflow"**
2. Fill in: **cluster_name** (required), **supervisor_namespace** (required), **project_name** (required), **vm_content_library_id** (required), and optionally **environment**, **vm_class**, **vm_image**

### Trigger Script (repository_dispatch)

```bash
./scripts/trigger-deploy-hybrid-app.sh \
  --repo myorg/vcf9-iac \
  --token ghp_xxxxxxxxxxxx \
  --cluster-name my-project-01-clus-01 \
  --supervisor-namespace my-project-ns-xxxxx \
  --project-name my-project-01 \
  --vm-content-library-id cl-97acf13b5e2909643
```

**Required:** `--repo`, `--token`, `--cluster-name`

**Optional:** `--environment`, `--supervisor-namespace`, `--project-name`, `--vm-class`, `--vm-image`, `--vm-content-library-id`, `--postgres-user`, `--postgres-password`, `--postgres-db`, `--vm-name`, `--app-namespace`, `--container-registry`, `--image-tag`, `--vcfa-endpoint`, `--tenant-name`

### Direct API Call (curl)

```bash
curl -X POST \
  -H "Authorization: token GITHUB_TOKEN" \
  -H "Accept: application/vnd.github+json" \
  -H "Content-Type: application/json" \
  "https://api.github.com/repos/OWNER/REPO/dispatches" \
  -d '{
    "event_type": "deploy-hybrid-app",
    "client_payload": {
      "cluster_name": "my-dev-project-01-clus-01",
      "supervisor_namespace": "my-project-ns-xxxxx",
      "project_name": "my-dev-project-01",
      "vm_content_library_id": "cl-97acf13b5e2909643"
    }
  }'
```

## Parameters

| Parameter | `client_payload` key | Default | Description |
|---|---|---|---|
| `CLUSTER_NAME` | `cluster_name` | (required) | VKS cluster name |
| `SUPERVISOR_NAMESPACE` | `supervisor_namespace` | (required) | Supervisor namespace where the VKS cluster and VM are provisioned |
| `PROJECT_NAME` | `project_name` | (required) | VCF project name |
| `VM_CONTENT_LIBRARY_ID` | `vm_content_library_id` | (required) | Content library ID for VM images (separate from VKS node images) |
| `ENVIRONMENT` | `environment` | `demo` | Environment label |
| `VM_CLASS` | `vm_class` | `best-effort-medium` | VM Service compute class for the PostgreSQL VM |
| `VM_IMAGE` | `vm_image` | `ubuntu-24.04-server-cloudimg-amd64` | Content library image name (must be a cloud image with cloud-init) |
| `POSTGRES_USER` | `postgres_user` | `assetadmin` | PostgreSQL database user |
| `POSTGRES_PASSWORD` | `postgres_password` | `assetpass` | PostgreSQL database password |
| `POSTGRES_DB` | `postgres_db` | `assetdb` | PostgreSQL database name |
| `VM_NAME` | `vm_name` | `postgresql-vm` | Name for the VirtualMachine resource |
| `APP_NAMESPACE` | `app_namespace` | `hybrid-app` | Kubernetes namespace for API + Frontend in guest cluster |
| `STORAGE_CLASS` | `storage_class` | `nfs` | Storage class for the VM disk |
| `CONTAINER_REGISTRY` | `container_registry` | `scafeman` | Docker registry prefix for container images |
| `IMAGE_TAG` | `image_tag` | `latest` | Container image tag |
| `API_PORT` | `api_port` | `3001` | API service port |
| `FRONTEND_PORT` | `frontend_port` | `3000` | Frontend container port |
| `VM_TIMEOUT` | `vm_timeout` | `600` | Seconds to wait for VM ready power state |
| `POD_TIMEOUT` | `pod_timeout` | `300` | Seconds to wait for pod Running state |
| `LB_TIMEOUT` | `lb_timeout` | `300` | Seconds to wait for LoadBalancer external IP |
| `POLL_INTERVAL` | `poll_interval` | `30` | Seconds between polling attempts |

## Workflow Steps

| # | Step Name | Description |
|---|---|---|
| 1 | **Checkout Repository** | Checks out the repository using `actions/checkout@v5` |
| 2 | **Validate Inputs** | Checks all required environment variables are set; fails with a list of missing variables |
| 3 | **Create VCF CLI Context** | Creates a VCF CLI context authenticated to the VCFA endpoint |
| 4 | **Setup Kubeconfig** | Retrieves the admin kubeconfig for the VKS guest cluster via VCF CLI |
| 5 | **Provision PostgreSQL VM** | Creates a cloud-init Secret and applies the VirtualMachine manifest (`vmoperator.vmware.com/v1alpha3`) to the supervisor namespace |
| 6 | **Wait for VM Ready** | Polls until the VM reaches PoweredOn state and an IP address is assigned |
| 7 | **Build and Push API Image** | Builds and pushes the Node.js API container image to DockerHub |
| 8 | **Build and Push Frontend Image** | Builds and pushes the Next.js dashboard container image to DockerHub |
| 9 | **Setup Guest Cluster Kubeconfig** | Switches to the guest cluster kubeconfig and verifies connectivity |
| 10 | **Create Application Namespace** | Creates the `hybrid-app` namespace with privileged PodSecurity label |
| 11 | **Deploy API Service** | Deploys the API Deployment (with readiness probe on `/healthz`) and ClusterIP Service |
| 12 | **Wait for API Pod Running** | Polls until the API pod reaches Running state |
| 13 | **Deploy Frontend Service** | Deploys the Frontend Deployment and LoadBalancer Service (port 80 → 3000) |
| 14 | **Wait for Frontend Pod Running** | Polls until the Frontend pod reaches Running state |
| 15 | **Wait for LoadBalancer IP** | Polls until the LoadBalancer receives an external IP |
| 16 | **HTTP Connectivity Test** | Curls the frontend IP for HTTP 200 and the `/api/healthz` endpoint for healthy database status |
| 17 | **Write Job Summary** | Writes a Markdown summary with cluster details, VM IP, frontend IP, and container images |
| 18 | **Write Failure Summary** | On failure, writes a failure summary with troubleshooting steps |

## Troubleshooting

### VM does not reach PoweredOn state

- Verify the `VM_IMAGE` exists in the content library and is a cloud image (Template type, not ISO)
- Verify the `VM_CLASS` is available in the namespace: `kubectl get virtualmachineclasses`
- Check VirtualMachine events: `kubectl describe virtualmachine postgresql-vm -n <SUPERVISOR_NAMESPACE>`
- Increase `VM_TIMEOUT` if the environment is slow to provision VMs

### VM IP not assigned

- The VM IP may take 30–60 seconds to appear after PoweredOn state
- The workflow polls for up to 120 seconds for the IP to be assigned
- Check VM network status: `kubectl get virtualmachine postgresql-vm -n <SUPERVISOR_NAMESPACE> -o jsonpath='{.status.network}'`

### API pod in CrashLoopBackOff

- Check pod logs: `kubectl logs -l app=hybrid-app-api -n hybrid-app`
- Common cause: PostgreSQL not reachable from the pod (cloud-init may not have completed)
- Verify PostgreSQL is listening: `kubectl exec -it deploy/hybrid-app-api -n hybrid-app -- nc -zv <VM_IP> 5432`
- Verify `pg_hba.conf` allows connections from the pod CIDR

### Frontend returns 502 on /api/healthz

- The API pod may still be starting or in CrashLoopBackOff
- Check API pod status: `kubectl get pods -l app=hybrid-app-api -n hybrid-app`
- Check API pod logs for database connection errors

### Container image build/push fails

- Verify Docker is running on the self-hosted runner
- Verify `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` secrets are set
- Check that the Dockerfiles at `examples/deploy-hybrid-app/api/Dockerfile` and `examples/deploy-hybrid-app/dashboard/Dockerfile` are valid

---

# Deploy Secrets Demo — VCF Secret Store (`deploy-secrets-demo.yml`)

## Overview

Demonstrates VCF Secret Store Service integration with a VKS guest cluster. Creates KeyValueSecrets in the supervisor namespace, installs the vault-injector VKS standard package, deploys Redis and PostgreSQL with vault-injected credentials, and runs a Next.js dashboard that verifies connectivity using secrets read from mounted files. This is the VCF equivalent of AWS Secrets Manager.

## Triggering the Workflow

### GitHub UI (workflow_dispatch)

1. Go to **Actions** → **"Deploy Secrets Demo"** → **"Run workflow"**
2. Fill in: **cluster_name** (required), optionally **environment**

### Trigger Script (repository_dispatch)

```bash
./scripts/trigger-deploy-secrets-demo.sh \
  --repo myorg/vcf9-iac \
  --token ghp_xxxxxxxxxxxx \
  --cluster-name my-project-01-clus-01
```

**Required:** `--repo`, `--token`, `--cluster-name`

**Optional:** `--environment`, `--secret-store-ip`, `--supervisor-namespace`, `--redis-password`, `--postgres-user`, `--postgres-password`, `--postgres-db`, `--namespace`, `--container-registry`, `--image-name`, `--image-tag`, `--vcfa-endpoint`, `--tenant-name`

## Parameters

| Parameter | `client_payload` key | Default | Description |
|---|---|---|---|
| `CLUSTER_NAME` | `cluster_name` | (required) | VKS cluster name |
| `ENVIRONMENT` | `environment` | `demo` | Environment label |
| `SECRET_STORE_IP` | `secret_store_ip` | (from secret) | External IP of the VCF Secret Store service |
| `REDIS_PASSWORD` | `redis_password` | (auto-generated) | Redis authentication password |
| `POSTGRES_USER` | `postgres_user` | `secretsadmin` | PostgreSQL username |
| `POSTGRES_PASSWORD` | `postgres_password` | (auto-generated) | PostgreSQL password |
| `POSTGRES_DB` | `postgres_db` | `secretsdb` | PostgreSQL database name |
| `NAMESPACE` | `namespace` | `secrets-demo` | Kubernetes namespace in the guest cluster |
| `CONTAINER_REGISTRY` | `container_registry` | `scafeman` | Docker registry prefix |
| `IMAGE_NAME` | `image_name` | `secrets-dashboard` | Dashboard container image name |
| `IMAGE_TAG` | `image_tag` | `latest` | Container image tag |

## Workflow Steps

| # | Step Name | Description |
|---|---|---|
| 1 | **Checkout Repository** | Checks out the repository using `actions/checkout@v5` |
| 2 | **Setup Kubeconfig** | Retrieves the admin kubeconfig via VCF CLI, discovers the supervisor namespace |
| 3 | **Install VCF Secret Plugin** | Installs the `vcf secret` CLI plugin if not present |
| 4 | **Create KeyValueSecrets** | Creates `redis-creds` and `postgres-creds` KeyValueSecrets in the supervisor namespace |
| 5 | **Create ServiceAccount and Token** | Creates `internal-app` ServiceAccount and long-lived token in the supervisor namespace |
| 6 | **Create Namespace, Copy Token, Install Vault-Injector** | Creates `secrets-demo` namespace, copies supervisor token, installs vault-injector VKS standard package |
| 7 | **Deploy Redis and PostgreSQL** | Deploys Redis 7 and PostgreSQL 16 with vault-injected credentials |
| 8 | **Build and Push Dashboard Image** | Builds and pushes the Next.js dashboard container image |
| 9 | **Deploy Dashboard with Vault Annotations** | Deploys the dashboard with vault annotations for secret injection, mounts supervisor token |
| 10 | **Wait for LoadBalancer and Verify HTTP** | Waits for external IP, verifies HTTP 200 |
| 11 | **Write Job Summary** | Writes deployment summary with service endpoints |

## Key Concepts

- **KeyValueSecret** — secrets are created via `vcf secret create -f` using `secretstore.vmware.com/v1alpha1` API with array-format `spec.data`
- **vault-injector package** — installed via `vcf package install vault-injector` (VKS standard package), handles all TLS, RBAC, and webhook configuration
- **Token volume mount** — pods must mount the supervisor `internal-app-token` at `/var/run/secrets/kubernetes.io/serviceaccount` to authenticate with the Secret Store
- **Secret file format** — vault-injector mounts secrets as files at `/vault/secrets/` in Go map format: `data: map[key1:value1 key2:value2]`

## Troubleshooting

### "namespace not authorized"

The pod is mounting the wrong service account token. Ensure the Deployment mounts `internal-app-token` (supervisor token), not `test-service-account-token` (guest cluster token).

### "http: server gave HTTP response to HTTPS client"

The vault-injector `agentInjectVaultAddr` must be `http://secret-store-service:8200` (not `https://`).

### Password mismatch (Redis/PostgreSQL auth fails)

The vault secrets contain passwords from a previous run. Delete and recreate the KeyValueSecrets to match the current deployment's passwords.

### vault-agent-init stuck in Init:0/1

Check vault-agent-init logs: `kubectl logs <pod> -c vault-agent-init -n secrets-demo`. Common causes: wrong token, unreachable Secret Store IP, TLS mismatch.

---

# Deploy Bastion VM — SSH Jump Host (`deploy-bastion-vm.yml`)

## Overview

Deploys a minimal Ubuntu 24.04 bastion VM as a secure SSH jump host in a VCF 9 supervisor namespace. The VM is exposed via a VirtualMachineService LoadBalancer with `loadBalancerSourceRanges` to restrict SSH access to specific source IPs. Does not require a VKS cluster — only a supervisor namespace with VPC networking.

## Triggering the Workflow

### GitHub UI (workflow_dispatch)

1. Go to **Actions** → **"Deploy Bastion VM"** → **"Run workflow"**
2. Fill in: **supervisor_namespace** (required), and optionally **allowed_ssh_sources**, **vm_class**, **vm_image**, **vm_name**, **storage_class**, **ssh_username**, **ssh_public_key**, **boot_disk_size**, **data_disk_size**, **vm_network**

### Trigger Script (repository_dispatch)

```bash
./scripts/trigger-deploy-bastion-vm.sh \
  --repo myorg/vcf9-iac \
  --token ghp_xxxxxxxxxxxx \
  --supervisor-namespace my-project-ns-xxxxx
```

**Required:** `--repo`, `--token`, `--supervisor-namespace`

**Optional:** `--allowed-ssh-sources`, `--vm-class`, `--vm-image`, `--vm-name`, `--storage-class`, `--ssh-username`, `--ssh-public-key`, `--boot-disk-size`, `--data-disk-size`, `--vm-network`, `--vcfa-endpoint`, `--tenant-name`

### Direct API Call (curl)

```bash
curl -X POST \
  -H "Authorization: token GITHUB_TOKEN" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/OWNER/REPO/dispatches" \
  -d '{
    "event_type": "deploy-bastion-vm",
    "client_payload": {
      "supervisor_namespace": "my-project-ns-xxxxx",
      "allowed_ssh_sources": "136.62.85.50"
    }
  }'
```

## Parameters

| Parameter | `client_payload` key | Default | Description |
|---|---|---|---|
| `SUPERVISOR_NAMESPACE` | `supervisor_namespace` | (required) | Supervisor namespace where the bastion VM will be provisioned |
| `ALLOWED_SSH_SOURCES` | `allowed_ssh_sources` | `136.62.85.50` | Comma-separated list of allowed SSH source IPs |
| `VM_CLASS` | `vm_class` | `best-effort-medium` | VM Service compute class |
| `VM_IMAGE` | `vm_image` | `ubuntu-24.04-server-cloudimg-amd64` | Content library image name |
| `VM_NAME` | `vm_name` | `bastion-vm` | Name for the VirtualMachine resource |
| `STORAGE_CLASS` | `storage_class` | `nfs` | Storage class for VM disk |
| `SSH_USERNAME` | `ssh_username` | `rackadmin` | SSH username for the bastion VM |
| `SSH_PUBLIC_KEY` | `ssh_public_key` | ed25519 key | SSH public key for the bastion VM user |
| `BOOT_DISK_SIZE` | `boot_disk_size` | (image default) | Boot disk size override (e.g., `30Gi`) |
| `DATA_DISK_SIZE` | `data_disk_size` | (none) | Additional data disk size (e.g., `10Gi`) |
| `VM_NETWORK` | `vm_network` | (VPC default) | NSX SubnetSet name (e.g., `inside-subnet`) |
| `VM_TIMEOUT` | `vm_timeout` | `600` | Seconds to wait for VM PoweredOn |
| `LB_TIMEOUT` | `lb_timeout` | `300` | Seconds to wait for LoadBalancer external IP |
| `SSH_TIMEOUT` | `ssh_timeout` | `120` | Seconds to wait for SSH connectivity |
| `POLL_INTERVAL` | `poll_interval` | `30` | Seconds between polling attempts |

## Workflow Steps

| # | Step Name | Description |
|---|---|---|
| 1 | **Checkout Repository** | Checks out the repository using `actions/checkout@v5` |
| 2 | **Validate Inputs** | Checks all required environment variables are set |
| 3 | **Create VCF CLI Context** | Creates a VCF CLI context and switches to the supervisor namespace |
| 4 | **Provision Bastion VM** | Creates cloud-init Secret and applies VirtualMachine manifest with optional boot disk resize, data disk PVC, and SubnetSet network selection |
| 5 | **Wait for VM Ready** | Polls until the VM reaches PoweredOn state and an internal IP is assigned |
| 6 | **Create VirtualMachineService** | Creates a LoadBalancer VirtualMachineService with `loadBalancerSourceRanges` restricting SSH to allowed IPs |
| 7 | **Wait for LoadBalancer IP** | Polls until the VirtualMachineService receives an external IP |
| 8 | **Verify SSH Connectivity** | Tests SSH connectivity via `nc` to the LoadBalancer IP on port 22 |
| 9 | **Write Job Summary** | Writes deployment summary with VM name, internal IP, external IP, and SSH command |
| 10 | **Write Failure Summary** | On failure, writes failure summary with troubleshooting steps |

## Troubleshooting

### VM does not reach PoweredOn state

- Verify the `VM_IMAGE` exists in the content library
- Verify the `VM_CLASS` is available: `kubectl get virtualmachineclasses`
- Check VirtualMachine events: `kubectl describe virtualmachine bastion-vm -n <SUPERVISOR_NAMESPACE>`

### No LoadBalancer IP assigned

- Check NSX load balancer capacity and VPC configuration
- Verify the VirtualMachineService exists: `kubectl get virtualmachineservice -n <SUPERVISOR_NAMESPACE>`

### SSH connectivity test fails

- Verify the source IP is in the `ALLOWED_SSH_SOURCES` list
- Check that the VM's cloud-init completed (SSH key injection)
- Try connecting manually: `ssh <SSH_USERNAME>@<EXTERNAL_IP>`

---

# Deploy Managed DB App — DSM PostgresCluster Asset Tracker (`deploy-managed-db-app.yml`)

## Overview

Deploys a full-stack Infrastructure Asset Tracker demo backed by a VCF Database Service Manager (DSM) managed PostgresCluster — the VCF equivalent of AWS EKS + RDS. Provisions a fully managed PostgreSQL instance via the PostgresCluster CRD, builds and pushes API and Frontend container images, deploys them to the VKS guest cluster, and verifies end-to-end connectivity. Supports both Single Server (replicas=0) and Single-Zone HA (replicas=1) topologies.

## Triggering the Workflow

### GitHub UI (workflow_dispatch)

1. Go to **Actions** → **"Deploy Managed DB App"** → **"Run workflow"**
2. Fill in: **cluster_name** (required), **supervisor_namespace** (required), **project_name** (required), and optionally **dsm_infra_policy**, **dsm_storage_policy**, **dsm_vm_class**, **dsm_storage_space**, **postgres_version**, **dsm_cluster_name**, **postgres_replicas**, **postgres_db**

### Trigger Script (repository_dispatch)

```bash
./scripts/trigger-deploy-managed-db-app.sh \
  --repo myorg/vcf9-iac \
  --token ghp_xxxxxxxxxxxx \
  --cluster-name my-project-01-clus-01 \
  --supervisor-namespace my-project-ns-xxxxx \
  --dsm-infra-policy shared-dsm-01 \
  --dsm-storage-policy nfs
```

**Required:** `--repo`, `--token`, `--cluster-name`

**Optional:** `--supervisor-namespace`, `--project-name`, `--dsm-infra-policy`, `--dsm-storage-policy`, `--dsm-vm-class`, `--dsm-storage-space`, `--postgres-version`, `--dsm-cluster-name`, `--postgres-replicas`, `--postgres-db`, `--vcfa-endpoint`, `--tenant-name`

### Direct API Call (curl)

```bash
curl -X POST \
  -H "Authorization: token GITHUB_TOKEN" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/OWNER/REPO/dispatches" \
  -d '{
    "event_type": "deploy-managed-db-app",
    "client_payload": {
      "cluster_name": "my-dev-project-01-clus-01",
      "supervisor_namespace": "my-project-ns-xxxxx",
      "dsm_infra_policy": "shared-dsm-01",
      "dsm_storage_policy": "nfs"
    }
  }'
```

## Parameters

| Parameter | `client_payload` key | Default | Description |
|---|---|---|---|
| `CLUSTER_NAME` | `cluster_name` | (required) | VKS cluster name |
| `SUPERVISOR_NAMESPACE` | `supervisor_namespace` | (required) | Supervisor namespace for DSM provisioning |
| `PROJECT_NAME` | `project_name` | (required) | VCF project name |
| `DSM_INFRA_POLICY` | `dsm_infra_policy` | `shared-dsm-01` | DSM infrastructure policy name |
| `DSM_STORAGE_POLICY` | `dsm_storage_policy` | `NFS` | vSphere storage policy name for DSM |
| `DSM_VM_CLASS` | `dsm_vm_class` | `best-effort-large` | VM class for DSM instances (Single Server requires 4 CPU minimum) |
| `DSM_STORAGE_SPACE` | `dsm_storage_space` | `20Gi` | Storage allocation |
| `POSTGRES_VERSION` | `postgres_version` | `17.7+vmware.v9.0.2.0` | PostgreSQL version |
| `DSM_CLUSTER_NAME` | `dsm_cluster_name` | `pg-clus-01` | PostgresCluster resource name |
| `POSTGRES_REPLICAS` | `postgres_replicas` | `0` | Topology: `0` = Single Server, `1` = Single-Zone HA |
| `POSTGRES_DB` | `postgres_db` | `assetdb` | Database name |
| `ADMIN_PASSWORD_SECRET_NAME` | `admin_password_secret_name` | `postgres-admin-password` | Name of the admin password Secret |
| `ADMIN_PASSWORD` | — | (secret only) | Admin password for the PostgresCluster |
| `APP_NAMESPACE` | `app_namespace` | `managed-db-app` | Kubernetes namespace for API + Frontend |
| `CONTAINER_REGISTRY` | `container_registry` | `scafeman` | Docker registry prefix |
| `IMAGE_TAG` | `image_tag` | `latest` | Container image tag |
| `API_PORT` | `api_port` | `3001` | API service port |
| `FRONTEND_PORT` | `frontend_port` | `3000` | Frontend container port |
| `DSM_TIMEOUT` | `dsm_timeout` | `1800` | Seconds to wait for PostgresCluster Ready |
| `POD_TIMEOUT` | `pod_timeout` | `300` | Seconds to wait for pod Running state |
| `LB_TIMEOUT` | `lb_timeout` | `300` | Seconds to wait for LoadBalancer external IP |
| `POLL_INTERVAL` | `poll_interval` | `30` | Seconds between polling attempts |

## Workflow Steps

| # | Step Name | Description |
|---|---|---|
| 1 | **Checkout Repository** | Checks out the repository using `actions/checkout@v5` |
| 2 | **Validate Inputs** | Checks all required environment variables are set |
| 3 | **Create VCF CLI Context** | Creates a VCF CLI context authenticated to the VCFA endpoint |
| 4 | **Setup Kubeconfig** | Retrieves the admin kubeconfig for the VKS guest cluster via VCF CLI |
| 5 | **Provision PostgresCluster** | Creates admin password Secret, applies PostgresCluster manifest with DSM labels, waits for connection details (host + port), extracts DSM password from `pg-<cluster-name>` secret |
| 6 | **Build and Push API Image** | Builds and pushes the Node.js API container image to DockerHub |
| 7 | **Build and Push Frontend Image** | Builds and pushes the Next.js dashboard container image to DockerHub |
| 8 | **Setup Guest Cluster Kubeconfig** | Switches to the guest cluster kubeconfig and verifies connectivity |
| 9 | **Deploy API Service** | Deploys the API Deployment (with `POSTGRES_SSL=true` and readiness probe on `/healthz`) and ClusterIP Service |
| 10 | **Wait for API Pod Running** | Polls until the API pod reaches Running state |
| 11 | **Deploy Frontend Service** | Deploys the Frontend Deployment and LoadBalancer Service (port 80 → 3000) |
| 12 | **Wait for Frontend Pod Running** | Polls until the Frontend pod reaches Running state |
| 13 | **Wait for LoadBalancer IP** | Polls until the LoadBalancer receives an external IP |
| 14 | **HTTP Connectivity Test** | Curls the frontend IP for HTTP 200 and the `/api/healthz` endpoint for healthy database status |
| 15 | **Write Job Summary** | Writes a Markdown summary with cluster details, DSM host, frontend IP, and container images |
| 16 | **Write Failure Summary** | On failure, writes a failure summary with troubleshooting steps |

## Key DSM Concepts

| Concept | Description |
|---|---|
| `consumption-namespace` label | Must be the supervisor namespace (not the app namespace) |
| `infra-policy-type` label | Must be `supervisor-managed` for shared DSM policies |
| Secret naming | Secret names cannot start with `pg-` (reserved by DSM) |
| Connection readiness | Wait for `status.connection.host` to be populated — more reliable than the Ready condition |
| SSL requirement | DSM requires SSL for all connections — API deployment includes `POSTGRES_SSL=true` |
| Single Server minimum | `replicas: 0` requires minimum `best-effort-large` VM class (4 CPU) |

## Troubleshooting

### PostgresCluster does not reach Ready status

- Verify the DSM infrastructure policy exists in the supervisor namespace
- Verify the `DSM_STORAGE_POLICY` is available: `kubectl get storagepolicies`
- Verify the `DSM_VM_CLASS` is available: `kubectl get virtualmachineclasses`
- Check PostgresCluster status: `kubectl get postgrescluster <name> -n <SUPERVISOR_NAMESPACE> -o yaml`
- Increase `DSM_TIMEOUT` if the environment is slow (default: 1800s)

### Admission webhook denies PostgresCluster creation

- "already exists" — DSM has a stale record from a previous deployment. Use a different `DSM_CLUSTER_NAME`
- "secret name cannot be 'pg-...'" — secret names starting with `pg-` are reserved by DSM. Change `ADMIN_PASSWORD_SECRET_NAME`

### API pod in CrashLoopBackOff

- Check pod logs: `kubectl logs -l app=managed-db-api -n managed-db-app`
- Verify the DSM PostgreSQL endpoint is reachable from the guest cluster
- Verify `POSTGRES_SSL=true` is set (DSM requires SSL)

### Container image build/push fails

- Verify Docker is running on the self-hosted runner
- Verify `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` secrets are set

---

# Deploy HA VM App — HA Three-Tier Application on VMs (`deploy-ha-vm-app.yml`)

## Overview

Deploys a traditional HA three-tier application using VCF VM Service VMs — the VCF equivalent of deploying a classic HA application on AWS EC2 instances with 2× ALB and RDS. Provisions 2× web VMs (Next.js) fronted by a VirtualMachineService LoadBalancer, 2× API VMs (Express) fronted by a VirtualMachineService LoadBalancer, and a DSM-managed PostgresCluster. All resources are provisioned in a supervisor namespace — no VKS guest cluster required.

## Triggering the Workflow

### GitHub UI (workflow_dispatch)

1. Go to **Actions** → **"Deploy HA VM App"** → **"Run workflow"**
2. Fill in: **supervisor_namespace** (required), **project_name** (required), and optionally **vm_class**, **vm_image**, **storage_class**, **dsm_infra_policy**, **dsm_storage_policy**, **dsm_vm_class**, **dsm_storage_space**, **postgres_version**, **dsm_cluster_name**, **postgres_replicas**, **postgres_db**

### Direct API Call (curl)

```bash
curl -X POST \
  -H "Authorization: token GITHUB_TOKEN" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/OWNER/REPO/dispatches" \
  -d '{
    "event_type": "deploy-ha-vm-app",
    "client_payload": {
      "supervisor_namespace": "my-project-ns-xxxxx",
      "project_name": "my-dev-project-01",
      "dsm_infra_policy": "shared-dsm-01",
      "dsm_storage_policy": "NFS"
    }
  }'
```

## Parameters

| Parameter | `client_payload` key | Default | Description |
|---|---|---|---|
| `SUPERVISOR_NAMESPACE` | `supervisor_namespace` | (required) | Supervisor namespace where VMs and PostgresCluster will be provisioned |
| `PROJECT_NAME` | `project_name` | (required) | VCF Project name |
| `VM_CLASS` | `vm_class` | `best-effort-medium` | VM class for application VMs |
| `VM_IMAGE` | `vm_image` | `ubuntu-24.04-server-cloudimg-amd64` | Content library image name |
| `STORAGE_CLASS` | `storage_class` | `nfs` | Storage class for VM disks |
| `DSM_INFRA_POLICY` | `dsm_infra_policy` | `shared-dsm-01` | DSM infrastructure policy name |
| `DSM_STORAGE_POLICY` | `dsm_storage_policy` | `NFS` | vSphere storage policy name for DSM |
| `DSM_VM_CLASS` | `dsm_vm_class` | `best-effort-large` | VM class for DSM instances (Single Server requires 4 CPU minimum) |
| `DSM_STORAGE_SPACE` | `dsm_storage_space` | `20Gi` | Storage allocation |
| `POSTGRES_VERSION` | `postgres_version` | `17.7+vmware.v9.0.2.0` | PostgreSQL version |
| `DSM_CLUSTER_NAME` | `dsm_cluster_name` | `pg-clus-01` | PostgresCluster resource name |
| `POSTGRES_REPLICAS` | `postgres_replicas` | `0` | Topology: `0` = Single Server, `1` = Single-Zone HA |
| `POSTGRES_DB` | `postgres_db` | `assetdb` | Database name |
| `ADMIN_PASSWORD` | — | (secret only) | Admin password for the PostgresCluster |
| `API_PORT` | `api_port` | `3001` | API service port |
| `FRONTEND_PORT` | `frontend_port` | `3000` | Frontend port |
| `VM_TIMEOUT` | `vm_timeout` | `600` | Seconds to wait for VM PoweredOn |
| `DSM_TIMEOUT` | `dsm_timeout` | `1800` | Seconds to wait for PostgresCluster Ready |
| `LB_TIMEOUT` | `lb_timeout` | `300` | Seconds to wait for LoadBalancer external IP |
| `POLL_INTERVAL` | `poll_interval` | `30` | Seconds between polling attempts |

## Workflow Steps

| # | Step Name | Description |
|---|---|---|
| 1 | **Checkout Repository** | Checks out the repository using `actions/checkout@v5` |
| 2 | **Validate Inputs** | Checks all required environment variables are set |
| 3 | **Create VCF CLI Context** | Creates a VCF CLI context and switches to the supervisor namespace |
| 4 | **Provision DSM PostgresCluster** | Creates admin password Secret, applies PostgresCluster manifest, waits for Ready status, extracts connection details |
| 5 | **Provision API VMs** | Creates cloud-init Secrets and VirtualMachine manifests for `api-vm-01` and `api-vm-02` with DSM connection details |
| 6 | **Wait for API VMs Ready** | Polls until both API VMs reach PoweredOn state and obtain IP addresses |
| 7 | **Create API LoadBalancer** | Applies `ha-api-lb` VirtualMachineService LoadBalancer (selector `app: ha-api`, port `API_PORT`) |
| 8 | **Provision Web VMs** | Creates cloud-init Secrets and VirtualMachine manifests for `web-vm-01` and `web-vm-02` with API VIP address |
| 9 | **Wait for Web VMs Ready** | Polls until both web VMs reach PoweredOn state and obtain IP addresses |
| 10 | **Create Web LoadBalancer** | Applies `ha-web-lb` VirtualMachineService LoadBalancer (selector `app: ha-web`, port 80 → `FRONTEND_PORT`) |
| 11 | **Wait for LoadBalancer IP** | Polls until the web LoadBalancer receives an external IP |
| 12 | **HTTP Connectivity Test** | Curls the frontend IP for HTTP 200 and the API healthz endpoint for 200 |
| 13 | **Write Job Summary** | Writes deployment summary with Web LB IP, VM details, and DSM endpoint |
| 14 | **Write Failure Summary** | On failure, writes failure summary with troubleshooting steps |

## Troubleshooting

### VM does not reach PoweredOn state

- Verify the `VM_IMAGE` exists in the content library and is a cloud image
- Verify the `VM_CLASS` is available: `kubectl get virtualmachineclasses`
- Check VirtualMachine events: `kubectl describe virtualmachine <vm-name> -n <SUPERVISOR_NAMESPACE>`
- Increase `VM_TIMEOUT` if the environment is slow to provision VMs

### DSM PostgresCluster does not reach Ready status

- Verify the DSM infrastructure policy exists in the supervisor namespace
- Verify the `DSM_STORAGE_POLICY` is available: `kubectl get storagepolicies`
- Check PostgresCluster conditions: `kubectl get postgrescluster <name> -n <SUPERVISOR_NAMESPACE> -o yaml`
- DSM provisioning can take 10–25 minutes — increase `DSM_TIMEOUT` if needed

### No LoadBalancer IP assigned

- Check NSX load balancer capacity and VPC configuration
- Verify the VirtualMachineService exists: `kubectl get virtualmachineservice -n <SUPERVISOR_NAMESPACE>`

### Connectivity test fails

- Cloud-init bootstrap may still be running — the script retries with configurable interval
- Check VM cloud-init logs via serial console or SSH
- Verify the API VMs can reach the DSM PostgresCluster endpoint

---

# Teardown — Teardown VCF Stacks (`teardown.yml`)

## Overview

Selectively tears down the VCF 9 deployment stacks (GitOps, Metrics, Hybrid App, Secrets Demo, Bastion VM, Managed DB App, and Cluster) in reverse dependency order. The workflow consolidates the logic from the three existing teardown shell scripts into inline workflow steps, following the same patterns as the deploy workflows. Boolean inputs control which stacks are torn down, enabling selective teardown (e.g., tear down only GitOps while keeping Metrics and the Cluster).

## Triggering the Workflow

### GitHub UI (workflow_dispatch)

1. Go to **Actions** → **"Teardown VCF Stacks"** → **"Run workflow"**
2. Fill in: **cluster_name** (required), optionally uncheck **teardown_gitops**, **teardown_metrics**, **teardown_hybrid_app**, or **teardown_cluster** to skip specific stacks

### Trigger Script (repository_dispatch)

```bash
./scripts/trigger-teardown.sh \
  --repo myorg/vcf9-iac \
  --token ghp_xxxxxxxxxxxx \
  --cluster-name my-project-01-clus-01
```

**Required:** `--repo`, `--token`, `--cluster-name`

**Optional:** `--teardown-gitops`, `--teardown-metrics`, `--teardown-cluster`, `--teardown-hybrid-app` (default `true`), `--domain`, `--kubeconfig-path`, `--vcfa-endpoint`, `--tenant-name`

Selective teardown example (skip GitOps and Cluster, tear down only Metrics):

```bash
./scripts/trigger-teardown.sh \
  --repo myorg/vcf9-iac \
  --token ghp_xxxxxxxxxxxx \
  --cluster-name my-project-01-clus-01 \
  --teardown-gitops false \
  --teardown-cluster false
```

### Direct API Call (curl)

```bash
curl -X POST \
  -H "Authorization: token GITHUB_TOKEN" \
  -H "Accept: application/vnd.github+json" \
  -H "Content-Type: application/json" \
  "https://api.github.com/repos/OWNER/REPO/dispatches" \
  -d '{
    "event_type": "teardown",
    "client_payload": {
      "cluster_name": "my-dev-project-01-clus-01",
      "teardown_gitops": "true",
      "teardown_metrics": "true",
      "teardown_cluster": "true",
      "teardown_hybrid_app": "true"
    }
  }'
```

## Parameters

| Parameter | `client_payload` key | Type | Default | Description |
|---|---|---|---|---|
| `CLUSTER_NAME` | `cluster_name` | string | (required) | VKS cluster name to tear down |
| `TEARDOWN_GITOPS` | `teardown_gitops` | boolean | `true` | Tear down the GitOps stack (ArgoCD, GitLab, Harbor) |
| `TEARDOWN_METRICS` | `teardown_metrics` | boolean | `true` | Tear down the Metrics stack (Grafana, packages) |
| `TEARDOWN_CLUSTER` | `teardown_cluster` | boolean | `true` | Tear down the VKS cluster and project |
| `TEARDOWN_HYBRID_APP` | `teardown_hybrid_app` | boolean | `true` | Tear down the Hybrid App stack (PostgreSQL VM, API, Frontend) |
| `TEARDOWN_SECRETS_DEMO` | `teardown_secrets_demo` | boolean | `true` | Tear down the Secrets Demo stack |
| `TEARDOWN_BASTION_VM` | `teardown_bastion_vm` | boolean | `true` | Tear down the Bastion VM |
| `TEARDOWN_MANAGED_DB_APP` | `teardown_managed_db_app` | boolean | `true` | Tear down the Managed DB App stack (DSM PostgresCluster, API, Frontend) |
| `BASTION_VM_NAME` | `bastion_vm_name` | string | `bastion-vm` | Bastion VM name (must match the name used during deploy) |
| `DSM_CLUSTER_NAME` | `dsm_cluster_name` | string | `pg-clus-01` | DSM PostgresCluster name |
| `ADMIN_PASSWORD_SECRET_NAME` | `admin_password_secret_name` | string | `postgres-admin-password` | Admin password secret name |
| `MANAGED_DB_APP_NAMESPACE` | `managed_db_app_namespace` | string | `managed-db-app` | Managed DB App namespace |
| `DSM_TIMEOUT` | `dsm_timeout` | string | `1800` | Seconds to wait for PostgresCluster deletion |
| `DOMAIN` | `domain` | string | `lab.local` | Domain suffix for service hostnames |
| `KUBECONFIG_PATH` | `kubeconfig_path` | string | `./kubeconfig-<CLUSTER_NAME>.yaml` | Path to the admin kubeconfig file |
| `PACKAGE_NAMESPACE` | `package_namespace` | string | `tkg-packages` | Namespace for VKS standard packages |

## Workflow Steps

| Phase | Step Name | Description |
|---|---|---|
| Setup | **Checkout Repository** | Checks out the repository using `actions/checkout@v5` |
| Setup | **Setup Kubeconfig** | Retrieves or locates the admin kubeconfig; creates VCF CLI context if needed |
| — | **Warn Orphaned Stacks** | Emits `::warning::` when cluster teardown is enabled but application stacks are skipped |
| A | **Delete ArgoCD Application** | Deletes the ArgoCD Application CR, waits for Microservices Demo pods to terminate, deletes application namespace |
| A | **Delete GitLab Runner** | Uninstalls GitLab Runner Helm release, strips finalizers, deletes namespace |
| A | **Delete GitLab** | Uninstalls GitLab Helm release, deletes GitLab CRs, strips finalizers, deletes namespace |
| A | **Delete ArgoCD** | Uninstalls ArgoCD Helm release, strips finalizers from ArgoCD CRs, deletes namespace |
| A | **Restore CoreDNS (GitOps)** | Removes custom hosts block from CoreDNS ConfigMap, restarts CoreDNS |
| A | **Delete Harbor** | Uninstalls Harbor Helm release, strips finalizers, deletes namespace |
| A | **Delete Certificate Secrets and Files** | Deletes certificate secrets from namespaces, removes certificate directory |
| B | **Delete Grafana** | Deletes Grafana resources (Ingress, TLS, CRs, Operator, CRDs) and namespace |
| B | **Remove Metrics CoreDNS Entry** | Strips hosts block from CoreDNS, removes Envoy LB service |
| B | **Delete VKS Packages** | Deletes packages in reverse order (Prometheus, Contour, cert-manager, Telegraf) |
| B | **Delete Package Repository** | Strips finalizers and deletes the package repository |
| B | **Delete Package Namespace** | Strips finalizers, deletes namespace with timeout, force-removes finalizer as fallback |
| B | **Clean Up Cluster-Scoped Resources** | Deletes ClusterRoles, ClusterRoleBindings, CRDs, webhooks left by packages |
| D | **Delete Hybrid App Namespace** | Deletes the `hybrid-app` namespace in the guest cluster (removes API + Frontend Deployments and Services) |
| D | **Delete PostgreSQL VM** | Switches to supervisor context, deletes the VirtualMachine resource, waits for termination, cleans up cloud-init Secret |
| E | **Delete Secrets Demo Vault-Injector Package** | Deletes the vault-injector VKS standard package |
| E | **Delete Secrets Demo Namespace** | Deletes the `secrets-demo` namespace and cluster-scoped resources |
| E | **Delete Secrets Demo Supervisor Resources** | Deletes KeyValueSecrets, ServiceAccount, and token in supervisor namespace |
| F | **Delete Bastion VM Resources** | Deletes VirtualMachineService, VirtualMachine, data disk PVC, and cloud-init Secret in supervisor namespace |
| G | **Delete Managed DB App Namespace** | Deletes the `managed-db-app` namespace in the guest cluster (removes API + Frontend) |
| G | **Delete DSM PostgresCluster** | Switches to supervisor context, deletes the PostgresCluster resource, waits for deletion, cleans up admin password and DSM-created secrets |
| C | **Delete Guest Cluster Workloads** | Deletes vks-test-lb Service, vks-test-app Deployment, vks-test-pvc PVC |
| C | **Delete VKS Cluster** | Deletes the VKS cluster resource and waits for deletion |
| C | **Delete Supervisor Namespace and Project** | Deletes SupervisorNamespace, ProjectRoleBinding, and Project |
| C | **Context and Kubeconfig Cleanup** | Deletes VCF CLI context, removes local kubeconfig file |
| — | **Write Job Summary** | Writes Markdown summary listing which stacks were torn down or skipped |
| — | **Write Failure Summary** | On failure, writes failure summary with cluster name and error context |

## Troubleshooting

### Kubeconfig not found

- Verify Deploy Cluster has completed and the kubeconfig file exists on the runner
- If stored at a non-default path, pass `--kubeconfig-path` via the trigger script or set the `KUBECONFIG_PATH` secret

### Cluster unreachable during teardown

- Verify the VKS cluster is still running — if it was already deleted, skip to Cluster Stack teardown
- Check network connectivity from the runner host to the cluster API endpoint
- If the kubeconfig contains an expired token, re-run Deploy Cluster to regenerate it

### Namespace stuck in Terminating state

- The workflow strips finalizers before deletion to prevent this, but if it still occurs:
  - Check for remaining resources: `kubectl get all -n <namespace>`
  - Force-remove the namespace finalizer: `kubectl get ns <namespace> -o json | jq '.spec.finalizers = []' | kubectl replace --raw "/api/v1/namespaces/<namespace>/finalize" -f -`

### Helm uninstall failures

- All `helm uninstall` commands are guarded with `|| true` — failures on already-deleted releases are expected and non-fatal
- If a release is stuck, manually delete it: `helm uninstall <release> -n <namespace> --no-hooks`

### Orphaned resources after selective teardown

- If you tear down the cluster without tearing down GitOps or Metrics first, application-level resources are orphaned
- The workflow emits a `::warning::` annotation in this case
- To clean up, re-deploy the cluster and run a full teardown

### VKS cluster deletion timeout

- Default timeout is 1800 seconds (30 minutes) — large clusters may need more time
- Check vSphere for the cluster deletion status
- If the cluster is stuck, contact your vSphere administrator
