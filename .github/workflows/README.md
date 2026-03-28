# VCF 9 IaC — GitHub Actions Workflows

## Overview

This repository contains three GitHub Actions workflows that automate the end-to-end deployment of VCF 9 VKS infrastructure and application stacks. Each workflow runs on a self-hosted runner built from `Dockerfile.runner` with VCF CLI, kubectl, Helm, jq, and openssl baked in. There is no `container:` directive — all `run:` steps execute directly on the runner.

| Workflow | File | Description |
|---|---|---|
| Scenario 1 — Deploy VKS Cluster | `deploy-vks.yml` | Provisions VCF 9 VKS infrastructure end-to-end: context creation, project/namespace, cluster deployment, kubeconfig retrieval, and functional validation |
| Scenario 2 — Deploy VKS Metrics Stack | `deploy-vks-metrics.yml` | Deploys the metrics/observability stack (Telegraf, Prometheus, Grafana) on an existing VKS cluster |
| Scenario 3 — Deploy ArgoCD Stack | `deploy-argocd.yml` | Deploys the ArgoCD consumption model stack (Harbor, ArgoCD, GitLab, GitLab Runner, Microservices Demo) on an existing VKS cluster |

## Execution Order

Scenario 1 must complete successfully before Scenarios 2 or 3 can run. Scenarios 2 and 3 can run in any order after Scenario 1.

```
Scenario 1 (deploy-vks.yml)  ← must run first
    ├── Scenario 2 (deploy-vks-metrics.yml)
    └── Scenario 3 (deploy-argocd.yml)
```

Scenarios 2 and 3 share common infrastructure (cert-manager, Contour, package repository, Envoy LoadBalancer, certificates) that is handled idempotently — whichever runs first installs the shared components, and the second skips them.

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
- **Helm** v3 — chart-based deployments
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

# Scenario 1 — Deploy VKS Cluster (`deploy-vks.yml`)

## Overview

Provisions VCF 9 VKS infrastructure end-to-end: context creation, project and namespace provisioning, context bridge, cluster deployment, kubeconfig retrieval, and functional validation. This workflow must complete successfully before Scenarios 2 or 3 can run.

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

## Triggering the Workflow

### GitHub UI (workflow_dispatch)

1. Go to **Actions** → **"Deploy VKS Cluster"** → **"Run workflow"**
2. Fill in: **project_name**, **cluster_name**, **namespace_prefix**, and optionally **environment**, **resource_class**, **vm_class**, **min_nodes**, **max_nodes**, **containerd_volume_size**, **os_name**, **os_version**

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

**Optional:** `--environment`, `--vpc-name`, `--region-name`, `--zone-name`, `--resource-class`, `--user-identity`, `--content-library-id`, `--k8s-version`, `--vm-class`, `--storage-class`, `--min-nodes`, `--max-nodes`, `--containerd-volume-size`, `--os-name`, `--os-version`, `--vcfa-endpoint`, `--tenant-name`

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

---

# Scenario 2 — Deploy VKS Metrics Stack (`deploy-vks-metrics.yml`)

## Overview

Deploys the VKS Metrics Observability stack (Telegraf, Prometheus, Grafana) on an existing VKS cluster provisioned by Scenario 1. Requires a running VKS cluster with a valid admin kubeconfig file.

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

## Workflow Steps

| # | Step Name | Description |
|---|---|---|
| 1 | **Checkout Repository** | Checks out the repository using `actions/checkout@v4` |
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

- Verify Scenario 1 has completed and the kubeconfig file exists on the runner
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

# Scenario 3 — Deploy ArgoCD Stack (`deploy-argocd.yml`)

## Overview

Deploys the ArgoCD Consumption Model stack (Harbor, ArgoCD, GitLab, GitLab Runner, and the Microservices Demo) on an existing VKS cluster provisioned by Scenario 1. Requires a running VKS cluster with a valid admin kubeconfig file.

## Parameters

| Parameter | `client_payload` key | Default | Description |
|---|---|---|---|
| `CLUSTER_NAME` | `cluster_name` | (required) | VKS cluster name |
| `ENVIRONMENT` | `environment` | `demo` | Environment label for the deployment |
| `DOMAIN` | `domain` | `lab.local` | Domain suffix for service hostnames |
| `KUBECONFIG_PATH` | `kubeconfig_path` | `./kubeconfig-<CLUSTER_NAME>.yaml` | Path to the admin kubeconfig file |
| `HARBOR_VERSION` | `harbor_version` | `1.16.2` | Harbor Helm chart version |
| `ARGOCD_VERSION` | `argocd_version` | `7.8.13` | ArgoCD Helm chart version |
| `GITLAB_OPERATOR_VERSION` | `gitlab_operator_version` | `9.10.0` | GitLab Operator Helm chart version |
| `GITLAB_RUNNER_VERSION` | `gitlab_runner_version` | `0.75.0` | GitLab Runner Helm chart version |
| `HARBOR_ADMIN_PASSWORD` | `harbor_admin_password` | (auto-generated) | Harbor admin password |
| `PACKAGE_TIMEOUT` | `package_timeout` | `900` | Package reconciliation timeout in seconds |
| `PACKAGE_NAMESPACE` | `package_namespace` | `tkg-packages` | Namespace for VKS standard packages |
| `PACKAGE_REPO_URL` | `package_repo_url` | VKS standard packages OCI URL | VKS standard packages OCI repository URL |

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

## Workflow Steps

| # | Step Name | Description |
|---|---|---|
| 1 | **Checkout Repository** | Checks out the repository using `actions/checkout@v4` |
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

Scenarios 2 and 3 share these components, all handled idempotently:

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

- Verify Scenario 1 has completed and the kubeconfig file exists on the runner
- If stored at a non-default path, pass `--kubeconfig-path` via the trigger script

### Cluster unreachable

- Verify the VKS cluster from Scenario 1 is still running
- Check network connectivity from the runner host to the cluster API endpoint
- If the kubeconfig contains an expired token, re-run Scenario 1 to regenerate it

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
