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
| `GITLAB_OPERATOR_VERSION` | No | GitLab Operator Helm chart version (default: `9.10.3`) |
| `GITLAB_RUNNER_VERSION` | No | GitLab Runner Helm chart version (default: `0.87.1`) |

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
| `SSH_USERNAME` | No | SSH username for the bastion VM (default: `rackadmin`) |
| `SSH_PUBLIC_KEY` | No | SSH public key for the bastion VM user (default: ed25519 key) |
| `BOOT_DISK_SIZE` | No | Boot disk size override, e.g. `50Gi` (default: image default) |
| `DATA_DISK_SIZE` | No | Additional data disk size, e.g. `100Gi` (default: none) |
| `VM_NETWORK` | No | NSX SubnetSet name, e.g. `inside-subnet` (default: VPC default network) |
| `VM_TIMEOUT` | No | Seconds to wait for VM PoweredOn (default: `600`) |
| `LB_TIMEOUT` | No | Seconds to wait for LoadBalancer external IP (default: `300`) |
| `SSH_TIMEOUT` | No | Seconds to wait for SSH connectivity (default: `120`) |

---

## Deploy Managed DB App — DSM PostgresCluster Infrastructure Asset Tracker

| Variable | Required | Description |
|---|---|---|
| `SUPERVISOR_NAMESPACE` | Yes | Supervisor namespace where the PostgresCluster will be provisioned |
| `DSM_INFRA_POLICY` | Yes | DSM infrastructure policy name |
| `DSM_STORAGE_POLICY` | Yes | vSphere storage policy name for DSM |
| `ADMIN_PASSWORD` | Yes | Admin password for the PostgresCluster |
| `SECRET_STORE_IP` | Yes | VCF Secret Store IP address for vault-injector configuration |
| `DSM_CLUSTER_NAME` | No | PostgresCluster resource name (default: `postgres-clus-01`) |
| `DSM_VM_CLASS` | No | VM class for DSM instances — Single Server requires 4 CPU minimum (default: `best-effort-large`) |
| `DSM_STORAGE_SPACE` | No | Storage allocation (default: `20Gi`) |
| `POSTGRES_VERSION` | No | PostgreSQL version (default: `17.7+vmware.v9.0.2.0`) |
| `POSTGRES_REPLICAS` | No | Topology: `0` = Single Server, `1` = Single-Zone HA (default: `0`) |
| `POSTGRES_DB` | No | Database name (default: `assetdb`) |
| `ADMIN_PASSWORD_SECRET_NAME` | No | Name of the admin password Secret (default: `postgres-admin-password`) |
| `DSM_MAINTENANCE_WINDOW_DAY` | No | Maintenance window day (default: `SATURDAY`) |
| `DSM_MAINTENANCE_WINDOW_TIME` | No | Maintenance window start time (default: `04:59`) |
| `DSM_MAINTENANCE_WINDOW_DURATION` | No | Maintenance window duration (default: `6h0m0s`) |
| `DSM_SHARED_MEMORY` | No | Requested shared memory size (default: `64Mi`) |
| `APP_NAMESPACE` | No | Kubernetes namespace for API + Frontend (default: `managed-db-app`) |
| `CONTAINER_REGISTRY` | No | Docker registry prefix (default: `scafeman`) |
| `IMAGE_TAG` | No | Container image tag (default: `latest`) |
| `API_PORT` | No | API service port (default: `3001`) |
| `FRONTEND_PORT` | No | Frontend container port (default: `3000`) |
| `DSM_TIMEOUT` | No | Seconds to wait for PostgresCluster Ready (default: `1800`) |
| `POD_TIMEOUT` | No | Seconds to wait for pod Running state (default: `300`) |
| `LB_TIMEOUT` | No | Seconds to wait for LoadBalancer external IP (default: `300`) |
| `POLL_INTERVAL` | No | Seconds between polling attempts (default: `30`) |
| `DOCKERHUB_USERNAME` | No | DockerHub username (for image push authentication) |
| `DOCKERHUB_TOKEN` | No | DockerHub access token (for image push authentication) |

---

## Deploy HA VM App — HA Three-Tier Application on VMs

| Variable | Required | Description |
|---|---|---|
| `SUPERVISOR_NAMESPACE` | Yes | Supervisor namespace where VMs and PostgresCluster will be provisioned |
| `PROJECT_NAME` | Yes | VCF Project name |
| `VCF_API_TOKEN` | Yes | API token from the VCFA portal |
| `VCFA_ENDPOINT` | Yes | VCFA hostname (no `https://` prefix) |
| `TENANT_NAME` | Yes | SSO tenant/organization |
| `CONTEXT_NAME` | Yes | Local CLI context name |
| `DSM_INFRA_POLICY` | Yes | DSM infrastructure policy name |
| `DSM_STORAGE_POLICY` | Yes | vSphere storage policy name for DSM |
| `ADMIN_PASSWORD` | Yes | Admin password for the PostgresCluster |
| `VM_CLASS` | No | VM class for application VMs (default: `best-effort-medium`) |
| `VM_IMAGE` | No | VM image name (default: `ubuntu-24.04-server-cloudimg-amd64`) |
| `STORAGE_CLASS` | No | Storage class for VM disks (default: `nfs`) |
| `DSM_CLUSTER_NAME` | No | PostgresCluster resource name (default: `pg-clus-01`) |
| `DSM_VM_CLASS` | No | VM class for DSM instances — Single Server requires 4 CPU minimum (default: `best-effort-large`) |
| `DSM_STORAGE_SPACE` | No | Storage allocation (default: `20Gi`) |
| `POSTGRES_VERSION` | No | PostgreSQL version (default: `17.7+vmware.v9.0.2.0`) |
| `POSTGRES_REPLICAS` | No | Topology: `0` = Single Server, `1` = Single-Zone HA (default: `0`) |
| `POSTGRES_DB` | No | Database name (default: `assetdb`) |
| `ADMIN_PASSWORD_SECRET_NAME` | No | Name of the admin password Secret (default: `admin-pw-pg-clus-01`) |
| `DSM_MAINTENANCE_WINDOW_DAY` | No | Maintenance window day (default: `SATURDAY`) |
| `DSM_MAINTENANCE_WINDOW_TIME` | No | Maintenance window start time (default: `04:59`) |
| `DSM_MAINTENANCE_WINDOW_DURATION` | No | Maintenance window duration (default: `6h0m0s`) |
| `DSM_SHARED_MEMORY` | No | Requested shared memory size (default: `64Mi`) |
| `API_PORT` | No | API service port (default: `3001`) |
| `FRONTEND_PORT` | No | Frontend port (default: `3000`) |
| `CONTAINER_REGISTRY` | No | Docker registry prefix (default: `scafeman`) |
| `IMAGE_TAG` | No | Container image tag (default: `latest`) |
| `VM_TIMEOUT` | No | Seconds to wait for VM PoweredOn (default: `600`) |
| `DSM_TIMEOUT` | No | Seconds to wait for PostgresCluster Ready (default: `1800`) |
| `LB_TIMEOUT` | No | Seconds to wait for LoadBalancer external IP (default: `300`) |
| `POLL_INTERVAL` | No | Seconds between polling attempts (default: `30`) |

---

## Deploy Knative — Serverless Asset Tracker with DSM PostgreSQL

| Variable | Required | Description |
|---|---|---|
| `CLUSTER_NAME` | Yes | VKS cluster name |
| `KUBECONFIG_FILE` | No | Path to admin kubeconfig file (default: `./kubeconfig-<CLUSTER_NAME>.yaml`) |
| `KNATIVE_SERVING_VERSION` | No | Knative Serving version (default: `1.21.2`) |
| `NET_CONTOUR_VERSION` | No | net-contour networking plugin version (default: `1.21.1`) |
| `VCF_API_TOKEN` | Yes | API token from the VCFA portal |
| `VCFA_ENDPOINT` | Yes | VCFA hostname (no `https://` prefix) |
| `TENANT_NAME` | Yes | SSO tenant/organization |
| `CONTEXT_NAME` | Yes | Local CLI context name |
| `SUPERVISOR_NAMESPACE` | Yes | Supervisor namespace where the PostgresCluster will be provisioned |
| `PROJECT_NAME` | Yes | VCF Project name |
| `DSM_CLUSTER_NAME` | No | PostgresCluster resource name (default: `pg-clus-01`) |
| `DSM_INFRA_POLICY` | Yes | DSM infrastructure policy name |
| `DSM_VM_CLASS` | No | VM class for DSM instances — Single Server requires 4 CPU minimum (default: `best-effort-large`) |
| `DSM_STORAGE_POLICY` | Yes | vSphere storage policy name for DSM |
| `DSM_STORAGE_SPACE` | No | Storage allocation (default: `20Gi`) |
| `POSTGRES_VERSION` | No | PostgreSQL version (default: `17.7+vmware.v9.0.2.0`) |
| `POSTGRES_REPLICAS` | No | Topology: `0` = Single Server, `1` = Single-Zone HA (default: `0`) |
| `POSTGRES_DB` | No | Database name (default: `assetdb`) |
| `ADMIN_PASSWORD_SECRET_NAME` | No | Name of the admin password Secret (default: `admin-pw-pg-clus-01`) |
| `ADMIN_PASSWORD` | Yes | Admin password for the PostgresCluster |
| `CONTAINER_REGISTRY` | No | Docker registry prefix (default: `scafeman`) |
| `IMAGE_TAG` | No | Container image tag (default: `latest`) |
| `AUDIT_IMAGE` | No | Audit function container image (default: `<CONTAINER_REGISTRY>/knative-audit:<IMAGE_TAG>`) |
| `API_IMAGE` | No | API server container image (default: `<CONTAINER_REGISTRY>/knative-api:<IMAGE_TAG>`) |
| `API_PORT` | No | API service port (default: `3001`) |
| `SCALE_TO_ZERO_GRACE_PERIOD` | No | Knative scale-to-zero grace period (default: `30s`) |
| `KNATIVE_TIMEOUT` | No | Seconds to wait for Knative components to be ready (default: `300`) |
| `POD_TIMEOUT` | No | Seconds to wait for pod Running state (default: `300`) |
| `LB_TIMEOUT` | No | Seconds to wait for LoadBalancer external IP (default: `300`) |
| `DSM_TIMEOUT` | No | Seconds to wait for PostgresCluster Ready (default: `1800`) |
| `POLL_INTERVAL` | No | Seconds between polling attempts (default: `10`) |

---

## GitHub Actions Runner

| Variable | Required | Description |
|---|---|---|
| `RUNNER_TOKEN` | Yes | GitHub Actions runner registration token |
| `REPO_URL` | Yes | GitHub repository URL (e.g., `https://github.com/OWNER/REPO`) |
