# Environment Variables Reference

All deployment scripts and GitHub Actions workflows are configured through environment variables. Variables are defined in a `.env` file at the project root, which Docker Compose automatically loads and passes into the dev container.

**How it works:** Docker Compose reads the `.env` file and injects the variables into the container environment. Each deploy script reads its required variables from the environment at runtime — no hardcoded values in the scripts. Optional variables have sensible defaults baked into the scripts; you only need to set them if you want to override the default.

For setup instructions and the starter `.env` template, see the [Getting Started Guide](GETTING-STARTED.md).

---

## Deploy Cluster — VKS Cluster Deployment

| Variable | Required | Description |
|---|---|---|
| `VCF_API_TOKEN` | Yes | API token from the VCFA portal |
| `VCFA_ENDPOINT` | Yes | VCFA hostname (no `https://` prefix) |
| `TENANT_NAME` | Yes | SSO tenant/organization |
| `CONTEXT_NAME` | Yes | Local CLI context name |
| `PROJECT_NAME` | Yes | VCF Project name |
| `USER_IDENTITY` | Yes | SSO user identity for RBAC |
| `NAMESPACE_PREFIX` | Yes | Supervisor Namespace prefix (VCF appends a random suffix) |
| `ZONE_NAME` | Yes | Availability zone for namespace placement |
| `CLUSTER_NAME` | Yes | VKS cluster name |
| `CONTENT_LIBRARY_ID` | Yes | vSphere content library ID for OS images |
| `REGION_NAME` | No | Region name (default: `region-us1-a`) |
| `VPC_NAME` | No | VPC name (default: `region-us1-a-default-vpc`) |
| `RESOURCE_CLASS` | No | Namespace resource class (default: `xxlarge`) |
| `K8S_VERSION` | No | Kubernetes version (default: `v1.33.6+vmware.1-fips`) |
| `VM_CLASS` | No | VM class for worker nodes (default: `best-effort-large`) |
| `STORAGE_CLASS` | No | Storage class for PVCs (default: `nfs`) |
| `MIN_NODES` | No | Autoscaler minimum nodes (default: `2`) |
| `MAX_NODES` | No | Autoscaler maximum nodes (default: `10`) |
| `CONTAINERD_VOLUME_SIZE` | No | Containerd data volume per node (default: `50Gi`) |
| `OS_NAME` | No | Node OS image: `photon` or `ubuntu` (default: `photon`) |
| `OS_VERSION` | No | Node OS version, required for ubuntu (e.g., `24.04`) |
| `CONTROL_PLANE_REPLICAS` | No | Control plane node count: `1` (default) or `3` (HA) |
| `NODE_POOL_NAME` | No | Worker node pool name (default: `node-pool-01`) |
| `AUTOSCALER_SCALE_DOWN_UNNEEDED_TIME` | No | Time before underutilized node removal (default: `5m`) |
| `AUTOSCALER_SCALE_DOWN_DELAY_AFTER_ADD` | No | Cooldown after scale-up before scale-down (default: `5m`) |
| `AUTOSCALER_SCALE_DOWN_UTILIZATION_THRESHOLD` | No | Node utilization threshold for scale-down (default: `0.5`) |
| `AUTOSCALER_SCALE_DOWN_DELAY_AFTER_DELETE` | No | Cooldown after node deletion before next scale-down (default: `10s`) |
| `PACKAGE_NAMESPACE` | No | Namespace for VKS packages and Cluster Autoscaler (default: `tkg-packages`) |
| `PACKAGE_REPO_URL` | No | VKS standard packages OCI repository URL |
| `PACKAGE_TIMEOUT` | No | Timeout for package reconciliation in seconds (default: `600`) |

---

## Deploy Metrics — VKS Metrics Observability

| Variable | Required | Description |
|---|---|---|
| `PACKAGE_NAMESPACE` | No | Namespace for VKS packages (default: `tkg-packages`) |
| `PACKAGE_REPO_URL` | No | VKS standard packages OCI repository URL |
| `TELEGRAF_VERSION` | No | Telegraf package version (default: `1.37.1+vmware.1-vks.1`) |

---

## Deploy GitOps — ArgoCD Consumption Model

| Variable | Required | Description |
|---|---|---|
| `HARBOR_VERSION` | No | Harbor Helm chart version (default: `1.18.3`) |
| `ARGOCD_VERSION` | No | ArgoCD Helm chart version (default: `9.4.17`) |
| `GITLAB_OPERATOR_VERSION` | No | GitLab Operator Helm chart version (default: `9.10.1`) |
| `GITLAB_RUNNER_VERSION` | No | GitLab Runner Helm chart version (default: `0.75.0`) |

---

## Deploy Hybrid App — Infrastructure Asset Tracker

| Variable | Required | Description |
|---|---|---|
| `SUPERVISOR_NAMESPACE` | Yes | Supervisor namespace where the VKS cluster and VM are provisioned |
| `VM_CONTENT_LIBRARY_ID` | Yes | Content library ID for VM images (separate from VKS node `CONTENT_LIBRARY_ID`) |
| `VM_IMAGE` | No | VM image name (default: `ubuntu-24.04-server-cloudimg-amd64`) |
| `VM_CLASS` | No | VM Service compute class (default: `best-effort-medium`) |
| `VM_NAME` | No | VirtualMachine resource name (default: `postgresql-vm`) |
| `POSTGRES_USER` | No | PostgreSQL database user (default: `assetadmin`) |
| `POSTGRES_PASSWORD` | No | PostgreSQL database password (default: `assetpass`) |
| `POSTGRES_DB` | No | PostgreSQL database name (default: `assetdb`) |
| `APP_NAMESPACE` | No | Kubernetes namespace for API + Frontend (default: `hybrid-app`) |
| `STORAGE_CLASS` | No | Storage class for the VM disk (default: `nfs`) |

---

## Deploy Bastion VM — SSH Jump Host

| Variable | Required | Description |
|---|---|---|
| `SUPERVISOR_NAMESPACE` | Yes | Supervisor namespace where the bastion VM will be provisioned |
| `ALLOWED_SSH_SOURCES` | No | Comma-separated allowed SSH source IPs (default: `136.62.85.50`) |
| `VM_CLASS` | No | VM Service compute class (default: `best-effort-medium`) |
| `VM_IMAGE` | No | VM image name (default: `ubuntu-24.04-server-cloudimg-amd64`) |
| `VM_NAME` | No | VirtualMachine resource name (default: `bastion-vm`) |
| `STORAGE_CLASS` | No | Storage class for the VM disk (default: `nfs`) |
| `VM_TIMEOUT` | No | Seconds to wait for VM PoweredOn (default: `600`) |
| `LB_TIMEOUT` | No | Seconds to wait for LoadBalancer external IP (default: `300`) |
| `SSH_TIMEOUT` | No | Seconds to wait for SSH connectivity (default: `120`) |

---

## GitHub Actions Runner

| Variable | Required | Description |
|---|---|---|
| `RUNNER_TOKEN` | Yes | GitHub Actions runner registration token |
| `REPO_URL` | Yes | GitHub repository URL (e.g., `https://github.com/OWNER/REPO`) |
