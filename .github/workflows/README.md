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
