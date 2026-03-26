# Deploy VKS Cluster — GitHub Actions Workflow

## Overview

The `deploy-vks.yml` workflow provisions VCF 9 VKS infrastructure end-to-end using native GitHub Actions steps. Each provisioning phase — context creation, project and namespace provisioning, context bridge, cluster deployment, kubeconfig retrieval, and functional validation — runs as an individual named step inside a job-level container built from the repository Dockerfile (`vcf9-dev:latest`).

The workflow runs on a **self-hosted GitHub Actions runner** with network access to the VCFA endpoint on a private network. It supports manual trigger (`workflow_dispatch`), API trigger (`repository_dispatch`), and a companion trigger script for external automation.

---

## Required GitHub Actions Secrets

Configure these secrets in your repository under **Settings → Secrets and variables → Actions → New repository secret**.

### Required Secrets

| Secret | Description |
|---|---|
| `VCF_API_TOKEN` | API token from the VCFA portal for CCI authentication |
| `VCFA_ENDPOINT` | VCFA hostname (without `https://` prefix), e.g. `vcfa.example.com` |
| `TENANT_NAME` | SSO tenant/organization name |
| `USER_IDENTITY` | SSO user identity for RBAC (ProjectRoleBinding subject) |
| `CONTENT_LIBRARY_ID` | vSphere content library ID used for OS image resolution |
| `ZONE_NAME` | Availability zone name for Supervisor Namespace placement |

### Optional Secrets (with defaults)

These can be set as secrets to override the built-in defaults:

| Secret | Default | Description |
|---|---|---|
| `REGION_NAME` | `region-us1-a` | Region for Supervisor Namespace |
| `VPC_NAME` | `region-us1-a-default-vpc` | VPC for Supervisor Namespace |
| `RESOURCE_CLASS` | `xxlarge` | Resource class for Supervisor Namespace |
| `K8S_VERSION` | `v1.33.6+vmware.1-fips` | Kubernetes version for the VKS cluster |
| `VM_CLASS` | `best-effort-large` | VM class for cluster worker nodes |
| `STORAGE_CLASS` | `nfs` | Storage class for PVCs and containerd volumes |
| `MIN_NODES` | `2` | Minimum worker nodes (autoscaler min) |
| `MAX_NODES` | `10` | Maximum worker nodes (autoscaler max) |

---

## Self-Hosted Runner Setup

The VCFA endpoint resides on a private network, so the workflow requires a self-hosted runner. The runner is provided as a container service in `docker-compose.yml` (`gh-actions-runner` service).

### Prerequisites

- **Network access** to the VCFA endpoint on **port 443** from the machine running Docker
- **Docker** must be installed (Docker Desktop on Windows/macOS, or Docker Engine on Linux)
- The runner container mounts the Docker socket so it can launch the job-level container (`vcf9-dev:latest`) for workflow steps

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

### Runner Architecture

The runner container (`myoung34/github-runner`) is intentionally lightweight — it contains only the GitHub Actions runner agent. It does NOT contain VCF CLI, kubectl, or Helm. When a workflow job is dispatched, the runner launches the VCF tooling container (`vcf9-dev:latest`) via the Docker socket, and all workflow steps execute inside that container.

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

### Method 2: Trigger Script (repository_dispatch)

Use the companion trigger script to dispatch the workflow from the command line or external automation:

```bash
./scripts/trigger-deploy.sh \
  --repo OWNER/REPO \
  --token GITHUB_TOKEN \
  --project-name my-dev-project-01 \
  --cluster-name my-dev-project-01-clus-01 \
  --namespace-prefix my-dev-project-01-ns-
```

The script sends a `repository_dispatch` event with event type `deploy-vks` and prints a link to the Actions tab on success.

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
      "environment": "demo"
    }
  }'
```

A successful dispatch returns HTTP 204 with no response body.

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
