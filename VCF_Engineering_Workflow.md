# VCF 9 Engineering Workflow: Infrastructure & Application Deployment

This guide provides the standardized steps to initialize the VCF context, provision infrastructure, deploy VMware Kubernetes Service (VKS) clusters, and run application workloads on VCF 9.

---

## Phase 1: Environment Initialization
Before any resources can be created, you must establish a local context that points to the VCF Automation endpoint and identifies your tenant.

### Step 1: Create the Primary Environment Context
Run this command to map your local CLI to the VCF 9 environment.

```powershell
# PowerShell
vcf context create my-dev `
  --endpoint https://vcfa01.vmw-lab1.rpcai.rackspace-cloud.com `
  --type cci `
  --tenant-name org-rax-01 `
  --api-token <API_TOKEN> `
  --set-current
```

```bash
# Bash (Linux / macOS / dev container)
vcf context create my-dev \
  --endpoint https://vcfa01.vmw-lab1.rpcai.rackspace-cloud.com \
  --type cci \
  --tenant-name org-rax-01 \
  --api-token <API_TOKEN> \
  --set-current
```

> **Note:** Replace `<API_TOKEN>` with your API token from the VCFA portal (Build & Deploy → Identity and Access Management → API Tokens). The endpoint and tenant values above are environment-specific — update them for your VCFA deployment.

### Step 2: Authenticate and Set Active Context
Once the context is created, you must set it as "active" to update your local `kubectl` configuration.

```powershell
# Set the environment as the active target
vcf context use my-dev
```

---

## Phase 2: Infrastructure Provisioning
With the global context active, you can now build the logical boundaries for the project.

### Step 3: Create the Project and Namespace
Use the `sample-create-project-ns.yaml` file. This manifest handles the VCF 9 placement logic for the **xxlarge** resource class.

```powershell
# You MUST use --validate=false to bypass local schema checks 
# and allow the VCF Supervisor to process custom CCI fields.
kubectl create -f sample-create-project-ns.yaml --validate=false
```
*This command creates the **Project** (`my-dev-project-01`), assigns **RBAC** for `rax-user-1`, and provisions the **Supervisor Namespace**.*

---

## Phase 3: The "Context Bridge" (CRITICAL)
VCF 9 scopes Kubernetes Cluster APIs (VKS) strictly to the namespace level. You cannot see the `Cluster` kind from the global `my-dev` context. You must "pivot" into the new namespace to enable these APIs.

### Step 4: Re-register and Identify the Dynamic Context
The VCF CLI must discover the newly created infrastructure. **Pay close attention to the name, as VCF appends a unique 5-character suffix to your namespace prefix (e.g., `-frywy`).**

> **Note:** `vcf context refresh` does NOT re-enumerate namespaces when the token is still valid. You must delete and recreate the context to pick up newly created namespaces.

```powershell
# Delete the existing context
vcf context delete my-dev --yes

# Recreate the context — this performs a full login and discovers all namespaces
vcf context create my-dev --endpoint https://<VCFA_ENDPOINT> --type cci --tenant-name <TENANT_NAME> --api-token <API_TOKEN> --set-current

# Find the full context string in the list
vcf context list
```

### Step 5: Switch to the Namespace Context
Identify the namespace name provided by VCF (e.g., `my-dev-project-01-ns-frywy`). **You must update the command below with this specific generated name.**

```powershell
# Update <GENERATED_NAMESPACE_NAME> with the value from Step 4
vcf context use my-dev:<GENERATED_NAMESPACE_NAME>:my-dev-project-01
```

---

## Phase 4: VKS Cluster Deployment
Now that you are "inside" the namespace context, the `Cluster` API is visible.

### Step 6: Update and Deploy the VKS Cluster
Before running the deployment, open **`sample-create-cluster.yaml`** and update the `metadata.namespace` field to match the **exact generated name** from Phase 3.

```powershell
# Deploy the cluster using the updated YAML
kubectl apply -f sample-create-cluster.yaml --insecure-skip-tls-verify --validate=false
```

### Step 7: Monitor the Infrastructure Build
Because VKS nodes are virtual machines managed by the Supervisor, you can watch the hardware allocation in real-time:

```powershell
# Watch the worker nodes being cloned and powered on
kubectl get virtualmachines -w

# Check the overall cluster status
kubectl get clusters
```

---

## Phase 5: VKS Functional Testing (Storage & Ingress)
To validate that the Tanzu cluster is properly integrated with the underlying vSphere CSI and NSX Load Balancer, we deploy a sample web application.

### Step 8: Connect to the Guest Cluster Context
Retrieve the kubeconfig for the VKS guest cluster and set it as the active context.

**Option A: VCF CLI (recommended)**

```bash
# From the namespace context (Phase 3)
vcf cluster kubeconfig get <CLUSTER_NAME> --admin --export-file ./kubeconfig-<CLUSTER_NAME>.yaml

# Set the KUBECONFIG environment variable
export KUBECONFIG=./kubeconfig-<CLUSTER_NAME>.yaml    # Bash
# $env:KUBECONFIG=".\kubeconfig-<CLUSTER_NAME>.yaml"  # PowerShell

# Verify connectivity to the workload cluster
kubectl get nodes
```

**Option B: VCFA Portal (UI)**

1. Navigate to Build & Deploy → Kubernetes → `<CLUSTER_NAME>` and click **Download Kubeconfig**
2. Set the `KUBECONFIG` environment variable to point to the downloaded file

```powershell
# PowerShell
$env:KUBECONFIG="C:\path\to\downloaded\kubeconfig.yaml"
kubectl get nodes
```

### Step 9: Deploy the Functional Test Workload
Apply the `sample-vks-functional-test.yaml` manifest. This creates a 1Gi Persistent Volume, an Nginx deployment serving data from that volume, and an NSX LoadBalancer service exposing it to the network.

```powershell
kubectl apply -f sample-vks-functional-test.yaml
```

### Step 10: Verify the Deployments
Verify that the dynamic volume provisioning and ingress load balancing was successful.

```powershell
# 1. Check if the PVC successfully grabbed 1Gi of NFS storage (Status should be Bound)
kubectl get pvc vks-test-pvc

# 2. Check the LoadBalancer service provisioning. Note the EXTERNAL-IP assigned by NSX.
# This may take a minute to transition from <pending> to an IP address.
kubectl get svc vks-test-lb -w

# 3. Test the connectivity using the EXTERNAL-IP (replace <EXTERNAL-IP> with the IP from the previous step)
curl http://<EXTERNAL-IP>
```
You should receive the HTML response proving the pod is running, the storage is mounted, and the load balancer is routing external traffic.

---

## Summary of Manual Update Requirements

| Location | Action Required |
| :--- | :--- |
| **Step 5 (`vcf context use`)** | **Update** the namespace segment with the unique name provided by VCF. |
| **`sample-create-cluster.yaml`** | **Update** the `metadata.namespace` field to match the VCF-generated name. |
| **General Logic** | Always assume the namespace name will include a random 5-character suffix. |

---

## Automated Scripts (Recommended)

The manual workflow above has been fully automated into scripts that handle the entire lifecycle without any user interaction. These are the recommended way to spin the dev environment up and down.

### Build the Dev Container

```bash
docker compose up -d --build
```

### Deploy VKS Cluster (Foundation)

Every deployment pattern requires a running VKS cluster. Deploy it first:

```bash
docker exec vcf9-dev bash examples/deploy-cluster/deploy-cluster.sh
```

See [examples/deploy-cluster/README-deploy.md](examples/deploy-cluster/README-deploy.md) for details.

---

## Phase 6: Application Deployment Patterns

Once the VKS cluster is running, deploy any combination of the following patterns. Each is independent and can be deployed in any order.

### Deploy Metrics — Observability Stack

Installs Telegraf, Prometheus, and Grafana on the VKS cluster.

```bash
docker exec vcf9-dev bash examples/deploy-metrics/deploy-metrics.sh
```

**AWS Equivalent:** CloudWatch + Prometheus + Grafana

### Deploy GitOps — CI/CD Stack

Installs Harbor, ArgoCD, GitLab, and deploys the Google Microservices Demo.

```bash
docker exec vcf9-dev bash examples/deploy-gitops/deploy-gitops.sh
```

**AWS Equivalent:** ECR + CodePipeline + ArgoCD

### Deploy Hybrid App — VM-to-Container Connectivity

Provisions a PostgreSQL VM via VM Service and deploys a Next.js/Node.js app on VKS, proving VM-to-container connectivity over NSX VPC.

```bash
docker exec vcf9-dev bash examples/deploy-hybrid-app/deploy-hybrid-app.sh
```

**AWS Equivalent:** EC2 + EKS in the same VPC

### Deploy Managed DB App — DSM Managed Database + Vault Credentials

Provisions a fully managed PostgresCluster via DSM, stores credentials in the VCF Secret Store, and injects them into the API pod via vault-agent sidecar. The VCF equivalent of AWS EKS + RDS + Secrets Manager.

```bash
docker exec vcf9-dev bash examples/deploy-managed-db-app/deploy-managed-db-app.sh
```

**AWS Equivalent:** EKS + RDS + Secrets Manager

### Deploy Secrets Demo — VCF Secret Store Integration

Demonstrates VCF Secret Store with vault-injected secrets for Redis and PostgreSQL authentication via a Next.js dashboard.

```bash
docker exec vcf9-dev bash examples/deploy-secrets-demo/deploy-secrets-demo.sh
```

**AWS Equivalent:** Secrets Manager + EKS pod injection

### Deploy Bastion VM — SSH Jump Host

Deploys a minimal Ubuntu 24.04 bastion VM with source-IP-restricted SSH access via a VirtualMachineService LoadBalancer. Does not require a VKS cluster.

```bash
docker exec vcf9-dev bash examples/deploy-bastion-vm/deploy-bastion-vm.sh
```

**AWS Equivalent:** EC2 bastion + Security Groups

---

## Teardown

Each deployment has a corresponding teardown script. Tear down in reverse order.

```bash
# Application stacks (any order)
docker exec vcf9-dev bash examples/deploy-managed-db-app/teardown-managed-db-app.sh
docker exec vcf9-dev bash examples/deploy-hybrid-app/teardown-hybrid-app.sh
docker exec vcf9-dev bash examples/deploy-secrets-demo/teardown-secrets-demo.sh
docker exec vcf9-dev bash examples/deploy-bastion-vm/teardown-bastion-vm.sh
docker exec vcf9-dev bash examples/deploy-gitops/teardown-gitops.sh
docker exec vcf9-dev bash examples/deploy-metrics/teardown-metrics.sh

# Foundation (last)
docker exec vcf9-dev bash examples/deploy-cluster/teardown-cluster.sh
```

### Configuration

All scripts read configuration from environment variables loaded via the `.env` file. See the [Environment Variables Reference](ENVIRONMENT-VARIABLES.md) for the full variable reference and the [Getting Started Guide](GETTING-STARTED.md) for setup instructions.

### GitHub Actions Workflows

All deployment patterns are also available as GitHub Actions workflows for CI/CD automation. See the [Workflows README](.github/workflows/README.md) for parameters, triggers, and troubleshooting.

### Trigger Scripts

Companion scripts for dispatching workflows via the GitHub API are available in the [`scripts/`](scripts/) folder. See the [Scripts README](scripts/README.md) for usage.
