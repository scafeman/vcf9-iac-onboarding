# Deploy VKS Cluster — GitHub Actions Workflow

## Overview

The `deploy-vks.yml` workflow provisions VCF 9 VKS infrastructure end-to-end using native GitHub Actions steps. Each provisioning phase — context creation, project and namespace provisioning, context bridge, cluster deployment, kubeconfig retrieval, and functional validation — runs as an individual named step directly on the self-hosted runner.

The runner is built from `Dockerfile.runner`, which extends `myoung34/github-runner` with VCF CLI v9.0.2, kubectl v1.33.0, and Helm v3 baked in. There is no `container:` directive — all `run:` steps execute directly on the runner itself.

The workflow runs on a **self-hosted GitHub Actions runner** with network access to the VCFA endpoint on a private network. It supports manual trigger (`workflow_dispatch`), API trigger (`repository_dispatch`), and a companion trigger script for external automation.

---

## Secrets and Parameters

All parameters follow a unified resolution order:

> **workflow_dispatch input → client_payload → GitHub secret → built-in default**

This means most infrastructure parameters can be overridden per-deployment via `client_payload` in the trigger script, without touching repository secrets.

### Secret-Only (truly sensitive)

| Secret | Description |
|---|---|
| `VCF_API_TOKEN` | API token from the VCFA portal for CCI authentication |

### Overridable via `client_payload` (fall back to secrets)

These must be configured as secrets for the default case, but can be overridden per-run via `client_payload`:

| Parameter | `client_payload` key | Description |
|---|---|---|
| `VCFA_ENDPOINT` | `vcfa_endpoint` | VCFA hostname (without `https://` prefix), e.g. `vcfa.example.com` |
| `TENANT_NAME` | `tenant_name` | SSO tenant/organization name |
| `USER_IDENTITY` | `user_identity` | SSO user identity for RBAC (ProjectRoleBinding subject) |
| `CONTENT_LIBRARY_ID` | `content_library_id` | vSphere content library ID used for OS image resolution |
| `ZONE_NAME` | `zone_name` | Availability zone name for Supervisor Namespace placement |

### Overridable via `client_payload` (fall back to secrets, then defaults)

| Parameter | `client_payload` key | Default | Description |
|---|---|---|---|
| `REGION_NAME` | `region_name` | `region-us1-a` | Region for Supervisor Namespace |
| `VPC_NAME` | `vpc_name` | `region-us1-a-default-vpc` | VPC for Supervisor Namespace |
| `RESOURCE_CLASS` | `resource_class` | `xxlarge` | Resource class for Supervisor Namespace |
| `K8S_VERSION` | `k8s_version` | `v1.33.6+vmware.1-fips` | Kubernetes version for the VKS cluster |
| `VM_CLASS` | `vm_class` | `best-effort-large` | VM class for cluster worker nodes |
| `STORAGE_CLASS` | `storage_class` | `nfs` | Storage class for PVCs and containerd volumes |
| `MIN_NODES` | `min_nodes` | `2` | Minimum worker nodes (autoscaler min) |
| `MAX_NODES` | `max_nodes` | `10` | Maximum worker nodes (autoscaler max) |

Configure secrets in your repository under **Settings → Secrets and variables → Actions → New repository secret**.

---

## Environment Protection

The deploy job uses `environment: vcf-production`. To enable approval gates:

1. Go to **Settings → Environments** in your GitHub repository
2. Click **New environment** and name it `vcf-production`
3. Enable **Required reviewers** and add one or more approvers
4. Optionally configure a **Wait timer** or restrict to specific branches

When a workflow run reaches the `deploy` job, it will pause and wait for an approved reviewer to approve before proceeding.

---

## Self-Hosted Runner Setup

The VCFA endpoint resides on a private network, so the workflow requires a self-hosted runner. The runner is provided as a container service in `docker-compose.yml` (`gh-actions-runner` service).

### Prerequisites

- **Network access** to the VCFA endpoint on **port 443** from the machine running Docker
- **Docker** must be installed (Docker Desktop on Windows/macOS, or Docker Engine on Linux)

### Runner Architecture

The runner image is built from `Dockerfile.runner`, which extends `myoung34/github-runner:latest` and installs all required tooling directly into the image:

- **VCF CLI** v9.0.2 — for context management, project/namespace provisioning, and kubeconfig retrieval
- **kubectl** v1.33.0 — for Kubernetes resource management
- **Helm** v3 — for chart-based deployments
- **jq** — for JSON processing

Because the tooling is baked into the runner image, there is no `container:` directive in the workflow and no Docker-in-Docker. All `run:` steps execute directly on the runner.

### Setup Steps

1. **Generate a runner registration token** from your GitHub repository:
   - Go to **Settings → Actions → Runners → New self-hosted runner**
   - Copy the registration token displayed on the setup page

2. **Set environment variables** in your `.env` file at the repository root:
   ```
   RUNNER_TOKEN=<your-runner-registration-token>
   REPO_URL=https://github.com/OWNER/REPO
   ```

3. **Start the runner** (alongside the dev container) with:
   ```bash
   docker compose up -d
   ```
   This starts both the `vcf9-dev` interactive dev container and the `gh-actions-runner` agent.

4. **Verify the runner is registered** in your GitHub repository:
   - Go to **Settings → Actions → Runners**
   - The runner should appear as `vcf-local-runner` with labels `self-hosted` and `vcf`
   - Status should show as **Idle** (ready to accept jobs)

---

## Triggering the Workflow

### Method 1: GitHub UI (workflow_dispatch)

1. Go to the **Actions** tab in your GitHub repository
2. Select **"Deploy VKS Cluster"** from the workflow list on the left
3. Click **"Run workflow"**
4. Fill in the required inputs:
   - **project_name** — VCF Project name (e.g., `my-dev-project-01`)
   - **cluster_name** — VKS cluster name (e.g., `my-dev-project-01-clus-01`)
   - **namespace_prefix** — Supervisor Namespace prefix (e.g., `my-dev-project-01-ns-`)
   - **environment** — Environment label (optional, defaults to `demo`)
5. Click **"Run workflow"** to start the deployment

> **Note:** `workflow_dispatch` does not support the optional infrastructure overrides. Use the trigger script or curl for per-deployment parameter overrides.

### Method 2: Trigger Script (repository_dispatch)

Use the companion trigger script (`scripts/trigger-deploy.sh`) to dispatch the workflow from the command line or external automation. The script accepts 14 optional parameters and uses `jq` to build the `client_payload` JSON, including only the parameters you provide.

**Required arguments:**

```
--repo              GitHub repository (OWNER/REPO)
--token             GitHub PAT with repo scope
--project-name      VCF Project name
--cluster-name      VKS cluster name
--namespace-prefix  Supervisor Namespace prefix
```

**Optional arguments (override workflow defaults):**

```
--vpc-name          NSX VPC name
--region-name       Region name
--zone-name         Availability zone
--resource-class    Namespace resource class
--user-identity     SSO user identity for RBAC
--content-library-id  vSphere Content Library ID
--k8s-version       Kubernetes version
--vm-class          VM class for worker nodes
--storage-class     Storage class for PVCs
--min-nodes         Autoscaler minimum worker nodes
--max-nodes         Autoscaler maximum worker nodes
--vcfa-endpoint     VCFA hostname (no https://)
--tenant-name       SSO tenant/organization
--environment       Environment label (default: demo)
```

**Example with optional overrides:**

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

The script sends a `repository_dispatch` event with event type `deploy-vks`, prints the parameters sent as JSON, and provides a link to the Actions tab on success.

### Method 3: Direct API Call (curl)

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
      "environment": "demo",
      "vpc_name": "region-us1-a-sample-vpc",
      "region_name": "region-us1-a"
    }
  }'
```

A successful dispatch returns HTTP 204 with no response body. Only include the optional keys you want to override — omitted keys fall back to secrets or defaults.

---

## Workflow Steps

The workflow executes the following phases in order. Each phase is a separate named step visible in the GitHub Actions UI.

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
| — | **Upload Kubeconfig Artifact** | Uploads the kubeconfig file as a downloadable artifact (runs even on failure) |
| — | **Write Job Summary** | Writes a Markdown summary with cluster details to the GitHub Actions job summary |
| — | **Write Failure Summary** | On failure, writes a failure summary with error context |

---

## Artifacts

On completion (success or failure), the workflow uploads the kubeconfig file as a GitHub Actions artifact:

- **Artifact name:** `kubeconfig-<CLUSTER_NAME>`
- **File:** `kubeconfig-<CLUSTER_NAME>.yaml`
- **Retention:** 90 days

Download the artifact from the workflow run page in the GitHub Actions UI.

---

## Troubleshooting

### Runner not picking up jobs

- Verify the runner labels match `[self-hosted, vcf]` — go to **Settings → Actions → Runners** and check the runner's labels
- Confirm the runner status shows as **Idle** or **Active** (not **Offline**)
- Check that `RUNNER_TOKEN` in `.env` is a valid, non-expired registration token
- Restart the runner: `docker compose restart gh-actions-runner`
- If the token expired, generate a new one from **Settings → Actions → Runners** and update `.env`

### Environment approval pending

- If the workflow is stuck at "Waiting for review", a required reviewer must approve the deployment
- Go to the workflow run page and click **Review deployments** to approve or reject
- Check **Settings → Environments → vcf-production** to see who is configured as a reviewer

### Context creation fails

- Verify the VCFA endpoint is reachable from the runner host: `curl -k https://<VCFA_ENDPOINT>/health`
- Check that the `VCF_API_TOKEN` secret is valid and not expired
- Confirm `TENANT_NAME` matches the SSO tenant configured in VCFA
- The error message in the step output includes the endpoint and tenant name for debugging

### Context bridge timeout

- The context bridge retries for 120 seconds to handle VCFA propagation delays after namespace creation
- If it consistently times out, the Supervisor Namespace may not have been created successfully — check the "Create Project and Namespace" step output
- Verify the VCFA endpoint is responsive (propagation can be slow under load)
- As a workaround, re-run the workflow — the idempotency checks will skip already-created resources

### Cluster provisioning timeout

- The default timeout is 1800 seconds (30 minutes) — large clusters may need more time
- Check vSphere resource availability (CPU, memory, storage) on the target cluster
- Verify the content library (`CONTENT_LIBRARY_ID`) is synced and contains the required OS images
- Check that the VM class (`VM_CLASS`) and storage class (`STORAGE_CLASS`) are available in the target zone
- The step output includes the current cluster status YAML on timeout for debugging

### Functional test fails

- **PVC not binding:** Verify the storage class (`STORAGE_CLASS`) exists in the guest cluster and the CSI driver is operational
- **No LoadBalancer IP:** Check NSX load balancer capacity and VPC connectivity; the NSX-T load balancer pool may be exhausted
- **HTTP test returns non-200:** The nginx pod may not be ready yet; check pod status with `kubectl get pods` using the downloaded kubeconfig


---

# Deploy VKS Metrics Stack — GitHub Actions Workflow (Scenario 2)

## Overview

The `deploy-vks-metrics.yml` workflow deploys the VKS Metrics Observability stack (Telegraf, Prometheus, Grafana) on an existing VKS cluster provisioned by Scenario 1. Each provisioning phase — kubeconfig setup, node sizing advisory, package installation, certificate generation, CoreDNS configuration, and Grafana deployment — runs as an individual named step directly on the self-hosted runner.

This workflow requires a running VKS cluster from Scenario 1 with a valid admin kubeconfig file. The runner is built from `Dockerfile.runner` with VCF CLI, kubectl, Helm, jq, and openssl baked in. There is no `container:` directive — all `run:` steps execute directly on the runner itself.

---

## Secrets and Parameters

All parameters follow the same unified resolution order as Scenario 1:

> **workflow_dispatch input → client_payload → GitHub secret → built-in default**

### Secret-Only (truly sensitive)

| Secret | Description |
|---|---|
| `VCF_API_TOKEN` | API token from the VCFA portal for CCI authentication |

### Overridable via `client_payload` (fall back to secrets)

| Parameter | `client_payload` key | Description |
|---|---|---|
| `VCFA_ENDPOINT` | `vcfa_endpoint` | VCFA hostname (without `https://` prefix) |
| `TENANT_NAME` | `tenant_name` | SSO tenant/organization name |

### Overridable via `client_payload` (fall back to secrets, then defaults)

| Parameter | `client_payload` key | Default | Description |
|---|---|---|---|
| `CLUSTER_NAME` | `cluster_name` | (required) | VKS cluster name |
| `TELEGRAF_VERSION` | `telegraf_version` | (required) | Telegraf package version to install |
| `ENVIRONMENT` | `environment` | `demo` | Environment label for the deployment |
| `DOMAIN` | `domain` | `lab.local` | Domain suffix for service hostnames |
| `KUBECONFIG_PATH` | `kubeconfig_path` | `./kubeconfig-<CLUSTER_NAME>.yaml` | Path to the admin kubeconfig file |
| `PACKAGE_NAMESPACE` | `package_namespace` | `tkg-packages` | Namespace for VKS standard packages |
| `PACKAGE_REPO_URL` | `package_repo_url` | VKS standard packages OCI URL | VKS standard packages OCI repository URL |
| `TELEGRAF_VALUES_FILE` | `telegraf_values_file` | `examples/scenario2/telegraf-values.yaml` | Telegraf Helm values file path |
| `PROMETHEUS_VALUES_FILE` | `prometheus_values_file` | `examples/scenario2/prometheus-values.yaml` | Prometheus Helm values file path |
| `STORAGE_CLASS` | `storage_class` | `nfs` | Storage class for PVCs |
| `GRAFANA_ADMIN_PASSWORD` | `grafana_admin_password` | (auto-generated) | Grafana admin password |
| `PACKAGE_TIMEOUT` | `package_timeout` | `600` | Package reconciliation timeout in seconds |
| `NODE_CPU_THRESHOLD` | `node_cpu_threshold` | `4000` | Minimum allocatable CPU (millicores) for node sizing advisory |

---

## Triggering the Workflow

### Method 1: GitHub UI (workflow_dispatch)

1. Go to the **Actions** tab in your GitHub repository
2. Select **"Deploy VKS Metrics Stack"** from the workflow list on the left
3. Click **"Run workflow"**
4. Fill in the required inputs:
   - **cluster_name** — VKS cluster name (e.g., `my-dev-project-01-clus-01`)
   - **telegraf_version** — Telegraf package version to install (e.g., `1.4.3`)
   - **environment** — Environment label (optional, defaults to `demo`)
5. Click **"Run workflow"** to start the deployment

> **Note:** `workflow_dispatch` does not support the optional infrastructure overrides. Use the trigger script or curl for per-deployment parameter overrides.

### Method 2: Trigger Script (repository_dispatch)

Use the companion trigger script (`scripts/trigger-deploy-metrics.sh`) to dispatch the workflow from the command line or external automation.

**Required arguments:**

```
--repo              GitHub repository (OWNER/REPO)
--token             GitHub PAT with repo scope
--cluster-name      VKS cluster name
--telegraf-version  Telegraf package version
```

**Optional arguments (override workflow defaults):**

```
--environment             Environment label (default: demo)
--domain                  Domain suffix (default: lab.local)
--kubeconfig-path         Path to kubeconfig file
--package-namespace       Package namespace (default: tkg-packages)
--package-repo-url        VKS standard packages OCI repository URL
--telegraf-values-file    Telegraf Helm values file path
--prometheus-values-file  Prometheus Helm values file path
--storage-class           Storage class for PVCs
--grafana-admin-password  Grafana admin password
--package-timeout         Package reconciliation timeout in seconds
```

**Example:**

```bash
./scripts/trigger-deploy-metrics.sh \
  --repo myorg/vcf9-iac \
  --token ghp_xxxxxxxxxxxx \
  --cluster-name my-project-01-clus-01 \
  --telegraf-version 1.4.3 \
  --environment demo \
  --domain lab.local
```

The script sends a `repository_dispatch` event with event type `deploy-vks-metrics`, prints the parameters sent as JSON, and provides a link to the Actions tab on success.

### Method 3: Direct API Call (curl)

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

A successful dispatch returns HTTP 204 with no response body. Only include the optional keys you want to override — omitted keys fall back to secrets or defaults.

---

## Workflow Steps

The workflow executes the following phases in order. Each phase is a separate named step visible in the GitHub Actions UI.

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

---

# Deploy ArgoCD Stack — GitHub Actions Workflow (Scenario 3)

## Overview

The `deploy-argocd.yml` workflow deploys the ArgoCD Consumption Model stack (Harbor, ArgoCD, GitLab, GitLab Runner, and the Microservices Demo) on an existing VKS cluster provisioned by Scenario 1. Each provisioning phase — certificate generation, package prerequisites, Harbor, CoreDNS, ArgoCD, GitLab, runner setup, cluster registration, and application bootstrap — runs as an individual named step directly on the self-hosted runner.

This workflow requires a running VKS cluster from Scenario 1 with a valid admin kubeconfig file. The runner is built from `Dockerfile.runner` with VCF CLI, kubectl, Helm, jq, and openssl baked in. There is no `container:` directive — all `run:` steps execute directly on the runner itself.

---

## Secrets and Parameters

All parameters follow the same unified resolution order as Scenario 1:

> **workflow_dispatch input → client_payload → GitHub secret → built-in default**

### Secret-Only (truly sensitive)

| Secret | Description |
|---|---|
| `VCF_API_TOKEN` | API token from the VCFA portal for CCI authentication |

### Overridable via `client_payload` (fall back to secrets)

| Parameter | `client_payload` key | Description |
|---|---|---|
| `VCFA_ENDPOINT` | `vcfa_endpoint` | VCFA hostname (without `https://` prefix) |
| `TENANT_NAME` | `tenant_name` | SSO tenant/organization name |

### Overridable via `client_payload` (fall back to secrets, then defaults)

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

---

## Triggering the Workflow

### Method 1: GitHub UI (workflow_dispatch)

1. Go to the **Actions** tab in your GitHub repository
2. Select **"Deploy ArgoCD Stack"** from the workflow list on the left
3. Click **"Run workflow"**
4. Fill in the required inputs:
   - **cluster_name** — VKS cluster name (e.g., `my-dev-project-01-clus-01`)
   - **environment** — Environment label (optional, defaults to `demo`)
5. Click **"Run workflow"** to start the deployment

> **Note:** `workflow_dispatch` does not support the optional infrastructure overrides. Use the trigger script or curl for per-deployment parameter overrides.

### Method 2: Trigger Script (repository_dispatch)

Use the companion trigger script (`scripts/trigger-deploy-argocd.sh`) to dispatch the workflow from the command line or external automation.

**Required arguments:**

```
--repo              GitHub repository (OWNER/REPO)
--token             GitHub PAT with repo scope
--cluster-name      VKS cluster name
```

**Optional arguments (override workflow defaults):**

```
--environment                Environment label (default: demo)
--domain                     Domain suffix (default: lab.local)
--kubeconfig-path            Path to kubeconfig file
--harbor-version             Harbor Helm chart version
--argocd-version             ArgoCD Helm chart version
--gitlab-operator-version    GitLab Operator Helm chart version
--gitlab-runner-version      GitLab Runner Helm chart version
--harbor-admin-password      Harbor admin password
--package-timeout            Package reconciliation timeout in seconds
```

**Example:**

```bash
./scripts/trigger-deploy-argocd.sh \
  --repo myorg/vcf9-iac \
  --token ghp_xxxxxxxxxxxx \
  --cluster-name my-project-01-clus-01 \
  --environment demo \
  --domain lab.local
```

The script sends a `repository_dispatch` event with event type `deploy-argocd`, prints the parameters sent as JSON, and provides a link to the Actions tab on success.

### Method 3: Direct API Call (curl)

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

A successful dispatch returns HTTP 204 with no response body. Only include the optional keys you want to override — omitted keys fall back to secrets or defaults.

---

## Workflow Steps

The workflow executes the following phases in order. Each phase is a separate named step visible in the GitHub Actions UI.

| # | Step Name | Description |
|---|---|---|
| 1 | **Checkout Repository** | Checks out the repository using `actions/checkout@v4` |
| 2 | **Setup Kubeconfig** | Sets `KUBECONFIG` env var to the provided path (default `./kubeconfig-<CLUSTER_NAME>.yaml`); fails if file not found |
| 3 | **Verify Cluster Connectivity** | Runs `kubectl get namespaces` to verify the cluster is reachable; fails if unreachable |
| 4 | **Generate Self-Signed Certificates** | Generates CA cert, wildcard CSR (using `examples/scenario3/wildcard.cnf`), signed wildcard cert, and fullchain cert; skips if certs exist |
| 5 | **Create Package Namespace** | Creates the package namespace (default `tkg-packages`) with privileged PodSecurity label; skips if exists |
| 6 | **Register Package Repository** | Registers the VKS standard packages OCI repository; polls until reconciled; skips if already registered |
| 7 | **Install cert-manager** | Installs the cert-manager VKS package; polls until reconciled; skips if already installed |
| 8 | **Install Contour** | Installs the Contour VKS package; polls until reconciled; skips if already installed |
| 9 | **Create Envoy LoadBalancer** | Creates `envoy-lb` LoadBalancer service in `tanzu-system-ingress`; waits for external IP; stores IP in `CONTOUR_LB_IP` |
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

---

# Workflow Dependencies

## Scenario Execution Order

Both Scenario 2 and Scenario 3 depend on Scenario 1 having completed successfully. A running VKS cluster with a valid admin kubeconfig file is required before either workflow can run.

```
Scenario 1 (deploy-vks.yml)
    ├── Scenario 2 (deploy-vks-metrics.yml)
    └── Scenario 3 (deploy-argocd.yml)
```

- **Scenario 1** provisions the VKS cluster and produces the kubeconfig file
- **Scenario 2** deploys the metrics/observability stack (Telegraf, Prometheus, Grafana) on the cluster
- **Scenario 3** deploys the ArgoCD consumption model stack (Harbor, ArgoCD, GitLab, Microservices Demo) on the cluster

## Running Order Between Scenarios 2 and 3

Scenarios 2 and 3 can run in **any order** after Scenario 1. They share common infrastructure components (cert-manager, Contour, package repository, Envoy LoadBalancer, certificates) that are handled **idempotently**:

| Shared Component | Idempotency Check | Behavior |
|---|---|---|
| Package namespace (`tkg-packages`) | `kubectl get ns` | Skips creation if namespace exists |
| Package repository (`tkg-packages`) | `vcf package repository list` | Skips registration if repository found |
| cert-manager | `vcf package installed list` | Skips installation if package found |
| Contour | `vcf package installed list` | Skips installation if package found |
| Envoy LoadBalancer (`envoy-lb`) | `kubectl get svc envoy-lb` | Skips creation if service exists; retrieves existing IP |
| Self-signed certificates (`certs/`) | File existence check (`ca.crt`) | Skips generation if certificates exist |
| CoreDNS host entries | `grep` on Corefile content | Skips patch if hostname already present |

This means you can safely run:
- Scenario 2 first, then Scenario 3
- Scenario 3 first, then Scenario 2
- Both concurrently (though sequential execution is recommended to avoid race conditions)

---

# Troubleshooting (Scenarios 2 & 3)

### Kubeconfig not found

- The workflow expects the kubeconfig file at the path specified by `KUBECONFIG_PATH` (default: `./kubeconfig-<CLUSTER_NAME>.yaml`)
- Verify that Scenario 1 has completed successfully and the kubeconfig file exists on the runner
- If the kubeconfig is stored at a non-default path, pass `--kubeconfig-path` via the trigger script or set the `KUBECONFIG_PATH` secret
- Check that the file was not cleaned up by a previous workflow run or runner restart

### Cluster unreachable

- The "Verify Cluster Connectivity" step runs `kubectl get namespaces` to confirm the cluster API server is reachable
- Verify the VKS cluster from Scenario 1 is still running — clusters may be scaled down or deleted
- Check network connectivity from the runner host to the cluster API endpoint
- If the kubeconfig contains an expired token, re-run Scenario 1 to regenerate it
- Confirm the runner has DNS resolution to the cluster API hostname

### Package reconciliation timeout

- VKS packages (Telegraf, cert-manager, Contour, Prometheus) are installed via `vcf package install` and polled until reconciled
- The default timeout is `600s` for Scenario 2 and `900s` for Scenario 3 — increase via `PACKAGE_TIMEOUT` if packages take longer
- Check the package repository is registered and reconciled: `vcf package repository list -n tkg-packages`
- Verify the package namespace has the `privileged` PodSecurity label: `kubectl get ns tkg-packages --show-labels`
- Inspect package status: `vcf package installed list -n tkg-packages`
- If a package is stuck, delete it and re-run the workflow — the idempotency checks will re-install it

### Helm install failures

- Harbor, ArgoCD, GitLab, GitLab Runner, and Grafana Operator are installed via `helm upgrade --install`
- If a Helm install fails, check the Helm release status: `helm status <release> -n <namespace>`
- Common causes: insufficient cluster resources (CPU/memory), PVC binding failures, image pull errors
- For Harbor: verify the TLS and CA secrets exist in the `harbor` namespace
- For ArgoCD: verify the values file hostname substitution produced valid YAML
- For GitLab: the install can take 10+ minutes — increase the Helm `--timeout` if needed
- To retry: the workflow uses `helm upgrade --install`, which is idempotent — re-running the workflow will attempt the install again
- To clean up a failed release: `helm uninstall <release> -n <namespace>` and re-run

### CoreDNS restart issues

- The "Configure CoreDNS" step patches the CoreDNS ConfigMap and restarts the CoreDNS deployment
- After the restart, the workflow waits for CoreDNS pods to reach Running state and for the API server to become reachable
- If CoreDNS pods fail to restart, check the patched Corefile for syntax errors: `kubectl get configmap coredns -n kube-system -o yaml`
- If the API server becomes unreachable after the restart, wait 30–60 seconds and re-run — this is a transient condition caused by DNS resolution delays
- To manually fix a broken Corefile: `kubectl edit configmap coredns -n kube-system` and remove any malformed hosts blocks

### GitLab pod startup delays

- GitLab is a large application with multiple components (webservice, sidekiq, gitaly, redis, postgresql, etc.)
- The webservice pod can take 5–10 minutes to reach Running state after the Helm install completes
- If the workflow times out waiting for the webservice pod, increase `PACKAGE_TIMEOUT` (default `900s` for Scenario 3)
- Check pod status: `kubectl get pods -n gitlab-system`
- Check pod events for scheduling or resource issues: `kubectl describe pod <pod-name> -n gitlab-system`
- Common causes: insufficient memory (GitLab requires ~8 GB RAM), PVC binding delays, image pull throttling
- If using Harbor as a proxy cache, verify Harbor is running and the proxy configuration is correct
