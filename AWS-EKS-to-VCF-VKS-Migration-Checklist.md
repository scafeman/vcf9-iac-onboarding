# AWS EKS to VCF VKS Migration — Success Criteria Checklist

## Overview

This document provides a pass/fail checklist for teams migrating workloads from AWS Elastic Kubernetes Service (EKS) to VMware Cloud Foundation (VCF) 9 VMware Kubernetes Service (VKS). Each item maps an AWS EKS concept to its VCF equivalent and includes a verification command to confirm the migration step succeeded.

Use this checklist sequentially. Each phase builds on the previous one — do not skip ahead.

### Prerequisites

- Docker and Docker Compose installed on your workstation
- The `vcf9-dev` container built and running (`docker compose up -d --build`)
- A populated `.env` file with all required VCF environment variables
- VCF CLI (`vcf`) installed in the container
- `kubectl` configured and available in the container
- Access credentials (API token) for the VCFA endpoint

---

## Phase 1: Environment Initialization

**EKS Equivalent:** `aws configure` + `aws eks update-kubeconfig`

In AWS, you configure the CLI with access keys and then pull the EKS kubeconfig. In VCF, you create a CLI context that authenticates to the VCFA endpoint and scopes all subsequent commands to your tenant. You must create the context first — no other `vcf` or `kubectl` commands will work until this step is complete.

### Step 1: Create the VCF CLI Context

This is the very first command you run. It authenticates to the VCFA endpoint, prompts for your API token, and discovers all available namespace contexts in one shot:

```bash
vcf context create <CONTEXT_NAME> \
  --endpoint <VCFA_ENDPOINT> \
  --type cci \
  --tenant-name <TENANT_NAME> \
  --insecure-skip-tls-verify
```

You will be prompted for your API token:

```
? Provide API Token: <paste your token here>
Successfully logged into <VCFA_ENDPOINT>
You have access to the following contexts:
  <CONTEXT_NAME>
  <CONTEXT_NAME>:<NAMESPACE_1>:<PROJECT_1>
  <CONTEXT_NAME>:<NAMESPACE_2>:<PROJECT_2>
  ...
```

Replace the placeholders with your environment-specific values:

| Placeholder | Description | Example |
|---|---|---|
| `<CONTEXT_NAME>` | A local name for this CLI context | `my-dev` |
| `<VCFA_ENDPOINT>` | VCFA hostname (no `https://` prefix) | `vcfa01.example.com` |
| `<TENANT_NAME>` | SSO tenant/organization name in VCFA | `org-mycompany-01` |

### Step 2: Verify

| # | Check | Command | Pass Criteria |
|---|---|---|---|
| 1.1 | Context created and authenticated | `vcf context list` | Context name appears in the list with correct endpoint and tenant |
| 1.2 | Context is active | `vcf context list --current` | Shows the expected context name with `CURRENT: true` |
| 1.3 | Context details correct | `vcf context get <CONTEXT_NAME>` | Shows correct endpoint, tenant, and auth type |

### Token Refresh

API tokens expire. If any subsequent `vcf` or `kubectl` command fails with a `401 Unauthorized` or token-related error, re-authenticate with:

```bash
vcf context refresh <CONTEXT_NAME>
```

This re-prompts for your API token and refreshes the credentials for the given context without recreating it. You can run this at any point during the checklist if you hit auth errors.


---

## Phase 2: Project and RBAC Provisioning

**EKS Equivalent:** AWS Account + IAM Roles/Policies + `aws-auth` ConfigMap

In AWS, resource isolation is handled by AWS accounts and IAM policies. In VCF, the **Project** is the governance boundary. A **ProjectRoleBinding** grants access to SSO users (replacing IAM role mappings), and a **SupervisorNamespace** provisions the compute, storage, and network resources (replacing the VPC + subnet setup that EKS relies on).

> **Note:** The SupervisorNamespace references a VPC by name. If you need to create a new VPC (rather than using an existing one), complete Phase 4 (VPC and Network Provisioning) before this phase. See the [VCF 9 IaC Onboarding Guide](../vcf9-iac-onboarding-guide.md) Phase 3 for VPC creation steps.

| # | Check | Command | Pass Criteria |
|---|---|---|---|
| 2.1 | Project exists | `kubectl get projects` | Project name appears with `Ready` or `Active` status |
| 2.2 | RBAC binding applied | `kubectl get projectrolebindings -n <PROJECT_NAME>` | Binding exists for the expected user identity with `admin` role |
| 2.3 | Supervisor Namespace provisioned | `kubectl get supervisornamespaces -n <PROJECT_NAME>` | Namespace appears with a generated name (prefix + 5-char suffix) |
| 2.4 | Namespace is Ready | `kubectl get supervisornamespaces -n <PROJECT_NAME> -o jsonpath='{.items[0].status.phase}'` | Returns `Created`, `Configured`, or `Ready` |

### Key Difference from EKS

VCF uses `generateName` for Supervisor Namespaces, which appends a random 5-character suffix (e.g., `my-dev-project-01-ns-frywy`). You must capture this generated name for all subsequent phases. In EKS, namespace names are deterministic.

---

## Phase 3: Context Bridge (Namespace-Scoped Access)

**EKS Equivalent:** No direct equivalent

This is the most significant architectural difference from EKS. In AWS, once you have a kubeconfig, all Kubernetes APIs are immediately visible. In VCF, Cluster API resources (`cluster.x-k8s.io`) are only visible after you switch from the global context to a namespace-scoped context. This "Context Bridge" is a required step with no EKS parallel.

| # | Check | Command | Pass Criteria |
|---|---|---|---|
| 3.1 | Context re-registered | `vcf context delete <CONTEXT_NAME> --yes` then `vcf context create <CONTEXT_NAME> --endpoint ... --type cci --tenant-name ... --api-token ... --set-current` | Context recreated and new namespace appears in context list |
| 3.2 | Namespace context available | `vcf context list` | Namespace-scoped context appears (format: `<CONTEXT>:<NAMESPACE>:<PROJECT>`) |
| 3.3 | Switched to namespace context | `vcf context use <CONTEXT_NAME>:<NAMESPACE>:<PROJECT_NAME>` | Command succeeds |
| 3.4 | Cluster API visible | `kubectl get clusters` | Command returns successfully (even if no clusters exist yet) — no "resource not found" error |

### Why This Matters

If you skip the Context Bridge, `kubectl get clusters` will return an error because the Cluster API CRDs are not visible from the global context. This is the most common stumbling block for teams coming from EKS.

---

## Phase 4: VPC and Network Provisioning

**EKS Equivalent:** VPC + Subnets + Route Tables + NAT Gateway + Security Groups

In AWS, you create a VPC with subnets, route tables, internet/NAT gateways, and security groups before deploying an EKS cluster. In VCF, networking is handled by NSX and is largely provisioned automatically when you create the Supervisor Namespace. However, you should verify the networking primitives are in place.

> **Important:** VPC and network resources are only visible from the global context (`<CONTEXT_NAME>`), not from a namespace-scoped context. If you switched contexts in Phase 3, switch back first: `vcf context use <CONTEXT_NAME>`

| # | Check | Command | Pass Criteria |
|---|---|---|---|
| 4.1 | VPC exists | `kubectl get vpcs` | VPC resource appears with `loadBalancerVPCEndpoint.enabled: true` (required for LoadBalancer services) |
| 4.2 | NAT rules configured (optional) | `kubectl get vpcnatrules` | A default outbound SNAT is auto-created with the VPC. Custom rules are optional — only needed for advanced networking |
| 4.3 | Connectivity profile set | `kubectl get vpcconnectivityprofiles` | Profile exists with external access enabled |
| 4.4 | IP blocks allocated | `kubectl get ipblocks` | IP block resources show available CIDR ranges |

### Networking Concept Mapping

| AWS Construct | VCF Equivalent | Notes |
|---|---|---|
| VPC + CIDR | NSX VPC with `privateIPs` | NSX VPC is scoped to a Project, not a Region |
| Subnets in AZs | Zones (`topology.cci.vmware.com`) | Zones map to vSphere clusters, not network segments |
| NAT Gateway | VPCNATRule (SNAT/DNAT) | Explicit rules instead of a managed gateway |
| Security Groups | VPCConnectivityProfile + NSX DFW | Policy-based at VPC level, not per-ENI |
| ALB / NLB | NSX LoadBalancer | Auto-provisioned for `Service` type `LoadBalancer` |
| Transit Gateway | NSX TransitGateway + VPCAttachment | VPCAttachment associates VPC with a VPCConnectivityProfile. Name must follow `<vpcName>:<attachmentName>` format |


---

## Phase 5: VKS Cluster Deployment

**EKS Equivalent:** `eksctl create cluster` or `aws eks create-cluster`

In AWS, EKS cluster creation is a single API call that provisions a fully managed control plane — you never see or manage control plane nodes. In VCF, VKS deploys clusters via Cluster API on a vSphere Supervisor. The Supervisor provisions actual VirtualMachine resources for both control plane and worker nodes, which you can observe in real time.

> **Important:** Cluster API resources are only visible from the namespace-scoped context. You must complete the Context Bridge (Phase 3) before running these commands. Switch to the namespace context: `vcf context use <CONTEXT_NAME>:<NAMESPACE>:<PROJECT_NAME>`. The first time you switch, the VCF CLI will auto-install required plugins (cluster, kubernetes-release, etc.).

| # | Check | Command | Pass Criteria |
|---|---|---|---|
| 5.1 | Cluster manifest applied | `kubectl get clusters` | Cluster name appears in the list |
| 5.2 | Cluster provisioning | `kubectl get clusters -o jsonpath='{.items[0].status.phase}'` | Returns `Provisioning` (in progress) or `Provisioned` (complete) |
| 5.3 | Control plane VM running | `kubectl get virtualmachines` | Control plane VM shows `PoweredOn` power state |
| 5.4 | Worker VMs running | `kubectl get virtualmachines` | Worker node VMs show `PoweredOn` power state (count matches `MIN_NODES`) |
| 5.5 | Cluster fully provisioned | `kubectl get clusters` | `PHASE` column shows `Provisioned` |

### Key Differences from EKS

| Aspect | AWS EKS | VCF VKS |
|---|---|---|
| Control plane visibility | Hidden (managed service) | Visible as VirtualMachine resources |
| Provisioning time | 10-15 minutes | 5-20 minutes (depends on VM cloning speed) |
| Node scaling | Managed Node Groups (EC2 Auto Scaling) | Cluster API MachineDeployments with autoscaler annotations |
| Kubernetes version | EKS-managed versions | Tanzu Kubernetes Releases (`kubectl get tkr`) |
| Cluster configuration | `eksctl` config or AWS API | Cluster API manifest (`cluster.x-k8s.io/v1beta1`) with topology class |

---

## Phase 6: Kubeconfig Retrieval and API Server Access

**EKS Equivalent:** `aws eks update-kubeconfig --name <cluster>`

In AWS, the kubeconfig is generated via the AWS CLI and uses IAM-based authentication (STS tokens). In VCF, the kubeconfig uses certificate-based authentication and can be retrieved either from the VCFA portal UI or programmatically via a `VksCredentialRequest` resource.

> **Important:** The `vcf cluster kubeconfig get` command requires the `cluster` plugin, which is auto-installed when you first switch to a namespace-scoped context (Phase 3). You must be in the namespace context to run this command. After retrieving the kubeconfig, set `KUBECONFIG` to point to the downloaded file — all remaining checks (Phases 7–9) run against the guest cluster.

| # | Check | Command | Pass Criteria |
|---|---|---|---|
| 6.1 | Kubeconfig retrieved | `ls ./kubeconfig-<CLUSTER_NAME>.yaml` | File exists |
| 6.2 | KUBECONFIG exported | `echo $KUBECONFIG` (Bash) or `echo $env:KUBECONFIG` (PowerShell) | Points to the correct kubeconfig file path |
| 6.3 | API server reachable | `kubectl get namespaces` | Returns system namespaces (`kube-system`, `default`, etc.) without errors |
| 6.4 | Worker nodes Ready | `kubectl get nodes` | All nodes show `Ready` status in the `STATUS` column |
| 6.5 | Node count matches spec | `kubectl get nodes --no-headers \| wc -l` | Count equals or exceeds `MIN_NODES` from cluster manifest |

### Kubeconfig Retrieval Methods

**Method A — VCF CLI (Simplest):**

```powershell
# Windows (PowerShell)
vcf cluster kubeconfig get <CLUSTER_NAME> --admin --export-file "$env:USERPROFILE\kubeconfig-<CLUSTER_NAME>.yaml"
$env:KUBECONFIG = "$env:USERPROFILE\kubeconfig-<CLUSTER_NAME>.yaml"
```

```bash
# Linux / macOS (Bash)
vcf cluster kubeconfig get <CLUSTER_NAME> --admin --export-file ~/kubeconfig-<CLUSTER_NAME>.yaml
export KUBECONFIG=~/kubeconfig-<CLUSTER_NAME>.yaml
```

**Method B — VCFA Portal (UI):**
1. Log in to `https://<VCFA_ENDPOINT>`
2. Navigate to your Project → Kubernetes Clusters
3. Click the cluster → Download Kubeconfig

**Method C — Programmatic (VksCredentialRequest):**
```bash
# From the Supervisor namespace-scoped context (not the guest cluster)
kubectl create -f vks-cred-request.yaml --validate=false
kubectl get vkscredentialrequest <CLUSTER_NAME>-creds \
  -n <GENERATED_NS_NAME> -o jsonpath='{.status.kubeconfig}' > ./kubeconfig-<CLUSTER_NAME>.yaml
```

### Option: Run Phases 7–9 from Your Workstation

Once you have the kubeconfig, you can copy it out of the container and run all remaining `kubectl` commands directly from your workstation. This avoids the long `docker exec vcf9-dev sh -c 'export KUBECONFIG=... && kubectl ...'` syntax.

**Copy the kubeconfig to your workstation:**

```bash
docker cp vcf9-dev:/workspace/kubeconfig-<CLUSTER_NAME>.yaml ./kubeconfig-<CLUSTER_NAME>.yaml
```

**Set KUBECONFIG locally:**

```powershell
# PowerShell
$env:KUBECONFIG=".\kubeconfig-<CLUSTER_NAME>.yaml"

# Bash / Linux / macOS
export KUBECONFIG=./kubeconfig-<CLUSTER_NAME>.yaml
```

**Verify connectivity:**

```bash
kubectl get nodes
```

If this works, you can run all Phase 7–9 commands directly (no `docker exec` wrapper needed). This requires `kubectl` installed on your workstation.


---

## Phase 7: Storage Validation

**EKS Equivalent:** EBS CSI Driver + `gp3` StorageClass + PVC binding

In AWS, EKS uses the EBS CSI driver for block storage (gp2/gp3 volumes) and optionally EFS for shared file storage. In VCF, VKS uses the vSphere CSI driver for vSAN/VMFS and NFS provisioners for file storage. The validation approach is the same — create a PVC and confirm it binds.

> **Critical — Switch to Guest Cluster:** Phases 7–9 run against the VKS guest cluster, not the Supervisor context. You must set `KUBECONFIG` to the guest cluster kubeconfig retrieved in Phase 6 before running any commands below. If you skip this, `kubectl` will target the Supervisor and commands will fail with permission errors.
>
> All `kubectl` commands in Phases 7–9 must be prefixed with the kubeconfig export. When running via `docker exec`, use:
>
> ```bash
> docker exec vcf9-dev sh -c 'export KUBECONFIG=./kubeconfig-<CLUSTER_NAME>.yaml && kubectl <command>'
> ```
>
> `export` is a shell built-in and cannot be called directly with `docker exec` — you must wrap it in `sh -c '...'`.

| # | Check | Command | Pass Criteria |
|---|---|---|---|
| 7.1 | Storage classes available | `kubectl get storageclasses` | At least one storage class exists (e.g., `nfs`) |
| 7.2 | PVC created | `kubectl apply -f sample-vks-functional-test.yaml` | PVC resource created without errors |
| 7.3 | PVC bound | `kubectl get pvc vks-test-pvc` | `STATUS` column shows `Bound` |
| 7.4 | PV dynamically provisioned | `kubectl get pv` | A PersistentVolume exists and is bound to the test PVC |

### Storage Mapping

| AWS Storage | VCF Equivalent | Notes |
|---|---|---|
| EBS (gp2/gp3) | vSphere CSI (vSAN/VMFS) | Block storage for single-node attach (RWO) |
| EFS | NFS StorageClass | Shared file storage for multi-node attach (RWX) |
| EBS CSI Driver | vSphere CSI Driver (`vmware-system-csi`) | Pre-installed on VKS clusters |

### Troubleshooting: PVC Stuck in Pending

```bash
# Check if the storage class exists
kubectl get sc

# Check CSI driver pods
kubectl get pods -n vmware-system-csi

# Get detailed PVC events
kubectl describe pvc vks-test-pvc
```

Common causes: storage class name mismatch, CSI driver not running, NFS backend unreachable.

---

## Phase 8: Compute Validation

**EKS Equivalent:** Pod scheduling on managed node groups with Pod Security Standards

In AWS, pods are scheduled on EC2 instances in managed node groups. Security is enforced via Pod Security Standards (PSS) or third-party admission controllers. VKS enforces the same Kubernetes Pod Security Standards. The validation deploys a hardened test app container (`scafeman/vks-test-app:latest`) to confirm scheduling and security enforcement work correctly.

| # | Check | Command | Pass Criteria |
|---|---|---|---|
| 8.1 | Deployment created | `kubectl get deployment vks-test-app` | Deployment exists with desired replica count |
| 8.2 | Pod running | `kubectl get pods -l app=vks-test-app` | Pod shows `Running` status with `1/1` containers ready |
| 8.3 | Security context enforced | `kubectl get pod -l app=vks-test-app -o jsonpath='{.items[0].spec.securityContext.runAsNonRoot}'` | Returns `true` |
| 8.4 | Pod not running as root | `kubectl exec deploy/vks-test-app -- id` | UID is non-zero (e.g., `uid=101(nginx)`) |

### Compute Mapping

| AWS Compute | VCF Equivalent | Notes |
|---|---|---|
| EC2 instances (node groups) | VirtualMachines (MachineDeployments) | VMs are visible via `kubectl get virtualmachines` |
| Instance types (m5.large, etc.) | VM Classes (best-effort-large, etc.) | Set via `vmClass` variable in cluster topology |
| Cluster Autoscaler | Cluster API Autoscaler annotations | `cluster.x-k8s.io/cluster-api-autoscaler-node-group-min-size` / `max-size` |
| Fargate (serverless pods) | Knative Serving | Scale-to-zero serverless workloads via `examples/deploy-knative/` |

---

## Phase 9: Network / LoadBalancer Validation

**EKS Equivalent:** AWS ALB/NLB + Target Groups + Security Group ingress rules

In AWS, LoadBalancer services provision an NLB or ALB via the AWS Load Balancer Controller. In VCF, LoadBalancer services are backed by NSX, which automatically provisions a load balancer and assigns an external IP from the VPC's IP pool. The validation creates a LoadBalancer service and confirms external connectivity.

| # | Check | Command | Pass Criteria |
|---|---|---|---|
| 9.1 | LoadBalancer service created | `kubectl get svc vks-test-lb` | Service exists with type `LoadBalancer` |
| 9.2 | External IP assigned | `kubectl get svc vks-test-lb -o jsonpath='{.status.loadBalancer.ingress[0].ip}'` | Returns a valid IP address (not empty or `<pending>`) |
| 9.3 | HTTP connectivity | `curl -s -o /dev/null -w '%{http_code}' http://<EXTERNAL_IP>` | Returns `200` |
| 9.4 | Response content valid | `curl -s http://<EXTERNAL_IP>` | Returns HTML content from the test app |

### LoadBalancer Mapping

| AWS LB Concept | VCF Equivalent | Notes |
|---|---|---|
| NLB (Network Load Balancer) | NSX LoadBalancer | Auto-provisioned for `Service` type `LoadBalancer` |
| ALB (Application Load Balancer) | Contour / Envoy HTTPProxy | Requires an ingress controller (e.g., Contour) |
| Target Groups | NSX backend pools | Managed automatically by NSX |
| Elastic IP | NSX external IP allocation | Assigned from VPC IP pool |

### Troubleshooting: No External IP

```bash
# Check service details and events for error messages
kubectl describe svc vks-test-lb

# Check events related to the service
kubectl get events --field-selector involvedObject.name=vks-test-lb

# Verify the service endpoints are populated (pods are matched)
kubectl get endpoints vks-test-lb
```

Common causes: NSX Edge cluster at capacity, VPC connectivity profile blocks external access, firewall rules blocking traffic, no pods matching the service selector.


---

## Phase 10: Application Deployment Patterns

Once the VKS cluster passes Phases 1–9, you can deploy application workloads using the toolkit's deployment patterns. Each pattern validates a different VCF capability.

### Deploy Hybrid App — Container-to-VM Connectivity

**EKS Equivalent:** EC2 instance + EKS pods in the same VPC

| # | Check | Command | Pass Criteria |
|---|---|---|---|
| 10.1 | PostgreSQL VM provisioned | `kubectl get virtualmachines -n <SUPERVISOR_NS>` | VM shows `PoweredOn` with an assigned IP |
| 10.2 | API pod running | `kubectl get pods -n hybrid-app -l app=hybrid-app-api` | Pod shows `Running` with `1/1` ready |
| 10.3 | Frontend LoadBalancer IP | `kubectl get svc hybrid-app-dashboard-lb -n hybrid-app` | `EXTERNAL-IP` assigned |
| 10.4 | HTTP connectivity | `curl http://<FRONTEND_IP>` | Returns HTTP 200 |
| 10.5 | API health check | `curl http://<FRONTEND_IP>/api/healthz` | Returns `{"status":"ok","database":"connected"}` |

### Deploy Managed DB App — DSM Managed Database + Vault Credentials

**EKS Equivalent:** EKS + RDS + Secrets Manager

| # | Check | Command | Pass Criteria |
|---|---|---|---|
| 10.6 | DSM PostgresCluster provisioned | `kubectl get postgrescluster -n <SUPERVISOR_NS>` | Status shows `Ready` with connection details |
| 10.7 | Connection details available | `kubectl get postgrescluster <NAME> -n <NS> -o jsonpath='{.status.connection}'` | Returns host, port, dbname, username |
| 10.8 | KeyValueSecret created | `vcf secret list` | `dsm-pg-creds` appears in the list |
| 10.9 | Vault-injector running | `kubectl get pods -n tkg-packages -l app.kubernetes.io/name=vault-injector` | Pod shows `Running` |
| 10.10 | API pod with vault sidecar | `kubectl get pods -n managed-db-app -l app=managed-db-api` | Shows `2/2` ready (api + vault-agent) |
| 10.11 | Frontend LoadBalancer IP | `kubectl get svc managed-db-dashboard-lb -n managed-db-app` | `EXTERNAL-IP` assigned |
| 10.12 | HTTP connectivity | `curl http://<FRONTEND_IP>` | Returns HTTP 200 |
| 10.13 | API health check | `curl http://<FRONTEND_IP>/api/healthz` | Returns `{"status":"ok","database":"connected"}` |

### Deploy Bastion VM — SSH Jump Host

**EKS Equivalent:** EC2 bastion host + Security Groups

| # | Check | Command | Pass Criteria |
|---|---|---|---|
| 10.14 | Bastion VM provisioned | `kubectl get virtualmachines -n <SUPERVISOR_NS>` | VM shows `PoweredOn` with internal IP |
| 10.15 | VirtualMachineService created | `kubectl get virtualmachineservice -n <SUPERVISOR_NS>` | Service shows external IP assigned |
| 10.16 | SSH connectivity | `nc -zv <EXTERNAL_IP> 22` | Connection succeeded on port 22 |

### Deploy Secrets Demo — VCF Secret Store Integration

**EKS Equivalent:** Secrets Manager + EKS pod injection

| # | Check | Command | Pass Criteria |
|---|---|---|---|
| 10.17 | KeyValueSecrets created | `vcf secret list` | `redis-creds` and `postgres-creds` appear |
| 10.18 | Vault-injector running | `kubectl get pods -n tkg-packages -l app.kubernetes.io/name=vault-injector` | Pod shows `Running` |
| 10.19 | Dashboard pod with vault sidecar | `kubectl get pods -n secrets-demo -l app=secrets-dashboard` | Shows `2/2` ready |
| 10.20 | Dashboard LoadBalancer IP | `kubectl get svc secrets-dashboard-lb -n secrets-demo` | `EXTERNAL-IP` assigned |
| 10.21 | HTTP connectivity | `curl http://<DASHBOARD_IP>` | Returns HTTP 200 |

### Deploy Metrics — Observability Stack

**EKS Equivalent:** CloudWatch + Prometheus + Grafana

| # | Check | Command | Pass Criteria |
|---|---|---|---|
| 10.22 | Telegraf package installed | `vcf package installed list -n tkg-packages \| grep telegraf` | Shows `Reconcile succeeded` |
| 10.23 | Prometheus package installed | `vcf package installed list -n tkg-packages \| grep prometheus` | Shows `Reconcile succeeded` |
| 10.24 | Grafana pod running | `kubectl get pods -n grafana -l app.kubernetes.io/name=grafana` | Pod shows `Running` |

### Deploy GitOps — CI/CD Stack

**EKS Equivalent:** ECR + CodePipeline + ArgoCD

| # | Check | Command | Pass Criteria |
|---|---|---|---|
| 10.25 | Harbor pods running | `kubectl get pods -n harbor` | All pods show `Running` |
| 10.26 | ArgoCD pods running | `kubectl get pods -n argocd` | All pods show `Running` |
| 10.27 | GitLab webservice running | `kubectl get pods -n gitlab-system -l app=webservice` | Pod shows `Running` |
| 10.28 | Microservices Demo deployed | `kubectl get pods -n microservices-demo` | All 11 pods show `Running` |
| 10.29 | Harbor CI project exists | `curl -sSk -u "admin:<HARBOR_PASSWORD>" https://<HARBOR_HOST>/api/v2.0/projects?name=microservices-ci` | Returns project with `name: microservices-ci` |
| 10.30 | GitLab CI/CD project exists | Navigate to `https://<GITLAB_HOST>/root/microservices-demo` | Project page loads with `.gitlab-ci.yml`, `demo-config.yaml`, `kustomization.yaml` |
| 10.31 | GitLab Runner registered | `kubectl get pods -n gitlab-runners` | Runner pod shows `Running` |
| 10.32 | ArgoCD sources from GitLab | `kubectl get application microservices-demo -n argocd -o jsonpath='{.spec.source.repoURL}'` | Returns GitLab URL (e.g., `https://gitlab.IP.sslip.io/root/microservices-demo.git`) |
| 10.33 | CI/CD pipeline triggers on edit | Edit `demo-config.yaml` in GitLab web UI, commit change | Pipeline runs at `https://<GITLAB_HOST>/root/microservices-demo/-/pipelines` |
| 10.34 | Node DNS patcher running | `kubectl get daemonset node-dns-patcher -n kube-system` | DaemonSet shows desired/ready counts matching |
| 10.35 | Node CA installer running | `kubectl get daemonset node-ca-installer -n kube-system` | DaemonSet shows desired/ready counts matching |

### Deploy HA VM App — HA Three-Tier Application on VMs

**EKS Equivalent:** 2× EC2 + 2× ALB + RDS PostgreSQL Multi-AZ

| # | Check | Command | Pass Criteria |
|---|---|---|---|
| 10.29 | Web VMs provisioned | `kubectl get virtualmachines -n <SUPERVISOR_NS>` | 2× web VMs show `PoweredOn` |
| 10.30 | API VMs provisioned | `kubectl get virtualmachines -n <SUPERVISOR_NS>` | 2× API VMs show `PoweredOn` |
| 10.31 | Web LoadBalancer IP | `kubectl get virtualmachineservice -n <SUPERVISOR_NS>` | Web LB shows external IP |
| 10.32 | API LoadBalancer IP | `kubectl get virtualmachineservice -n <SUPERVISOR_NS>` | API LB shows external IP |
| 10.33 | DSM PostgresCluster ready | `kubectl get postgrescluster -n <SUPERVISOR_NS>` | Status shows `Ready` |
| 10.34 | Dashboard HTTP connectivity | `curl http://<WEB_LB_IP>` | Returns HTTP 200 |

### Deploy Knative — Serverless FaaS with DSM PostgreSQL

**EKS Equivalent:** Lambda + API Gateway + RDS PostgreSQL

| # | Check | Command | Pass Criteria |
|---|---|---|---|
| 10.35 | Knative Serving installed | `kubectl get pods -n knative-serving` | All pods show `Running` |
| 10.36 | Contour networking installed | `kubectl get pods -n contour-external` | Contour + Envoy pods `Running` |
| 10.37 | DSM PostgresCluster ready | `kubectl get postgrescluster -n <SUPERVISOR_NS>` | Status shows `Ready` with connection details |
| 10.38 | API server running | `kubectl get pods -n knative-demo -l app=knative-api-server` | Pod shows `Running` |
| 10.39 | Audit function ready | `kubectl get ksvc asset-audit -n knative-demo` | Shows `Ready: True` with URL |
| 10.40 | Dashboard LoadBalancer IP | `kubectl get svc knative-dashboard -n knative-demo` | `EXTERNAL-IP` assigned |
| 10.41 | Dashboard HTTP connectivity | `curl http://<DASHBOARD_IP>` | Returns HTTP 200 |
| 10.42 | Scale-to-zero verified | `kubectl get pods -n knative-demo -l serving.knative.dev/service=asset-audit` | 0 pods after idle timeout |

---

## Phase 11: End-to-End Summary

Once all phases pass, the VKS cluster is validated and ready for workload migration. Use this summary table to record your results.

### Checklist Summary

| Phase | Description | Status |
|---|---|---|
| 1 | Environment Initialization (CLI context) | ☐ Pass / ☐ Fail |
| 2 | Project + RBAC + Supervisor Namespace | ☐ Pass / ☐ Fail |
| 3 | Context Bridge (namespace-scoped access) | ☐ Pass / ☐ Fail |
| 4 | VPC and Network Provisioning | ☐ Pass / ☐ Fail |
| 5 | VKS Cluster Deployment | ☐ Pass / ☐ Fail |
| 6 | Kubeconfig Retrieval + API Server Access | ☐ Pass / ☐ Fail |
| 7 | Storage Validation (PVC binding) | ☐ Pass / ☐ Fail |
| 8 | Compute Validation (Pod scheduling + security) | ☐ Pass / ☐ Fail |
| 9 | Network Validation (LoadBalancer + HTTP) | ☐ Pass / ☐ Fail |
| 10a | Deploy Hybrid App (VM + container connectivity) | ☐ Pass / ☐ Fail / ☐ Skipped |
| 10b | Deploy Managed DB App (DSM + vault credentials) | ☐ Pass / ☐ Fail / ☐ Skipped |
| 10c | Deploy Bastion VM (SSH jump host) | ☐ Pass / ☐ Fail / ☐ Skipped |
| 10d | Deploy Secrets Demo (Secret Store integration) | ☐ Pass / ☐ Fail / ☐ Skipped |
| 10e | Deploy Metrics (observability stack) | ☐ Pass / ☐ Fail / ☐ Skipped |
| 10f | Deploy GitOps (CI/CD stack + self-contained pipeline) | ☐ Pass / ☐ Fail / ☐ Skipped |

### Migration Readiness Criteria

Phases 1–9 must all pass for the VKS cluster to be considered migration-ready. Phase 10 sub-checks (10a–10f) are optional — deploy only the patterns that match your workload requirements. If any required phase fails:

1. Review the troubleshooting section for that phase
2. Fix the root cause and re-run the verification commands
3. Do not proceed to workload migration until all required phases pass

### Automated Validation

The full provisioning and validation workflow (Phases 1–9) is automated in the Deploy Cluster deploy script:

```bash
docker exec vcf9-dev bash examples/deploy-cluster/deploy-cluster.sh
```

This script executes all phases non-interactively and reports pass/fail status for each step. See [Deploy Cluster Deploy README](examples/deploy-cluster/README-deploy.md) for details.

---

## Appendix: Quick Reference — EKS to VKS Concept Map

| Category | AWS EKS | VCF VKS |
|---|---|---|
| **Identity** | IAM Roles + Policies | SSO + ProjectRoleBinding |
| **Cluster** | EKS (managed control plane) | VKS via Cluster API (Supervisor-managed VMs) |
| **Networking** | VPC + Subnets + SGs | NSX VPC + Zones + VPCConnectivityProfile |
| **Load Balancing** | ALB / NLB | NSX LoadBalancer (auto-provisioned) |
| **Ingress Controller** | AWS ALB Ingress Controller | Contour / Envoy (Helm-deployed) |
| **Storage** | EBS CSI (gp3) / EFS | vSphere CSI / NFS |
| **Node Scaling** | Managed Node Groups + Cluster Autoscaler | MachineDeployments + Cluster API Autoscaler |
| **Container Registry** | ECR | Harbor (self-hosted) |
| **GitOps** | Flux / ArgoCD on EKS | ArgoCD on VKS (Helm-deployed) |
| **CI/CD** | CodePipeline / CodeBuild | GitLab + GitLab Runner (Helm-deployed) |
| **Monitoring** | CloudWatch + Prometheus | Prometheus + Telegraf + Grafana (Helm-deployed) |
| **Managed Database** | RDS (PostgreSQL) | Data Services Manager (DSM) PostgresCluster CRD |
| **Secrets Management** | Secrets Manager | VCF Secret Store + vault-injector |
| **VM Workloads** | EC2 instances | VM Service (VirtualMachine CRD) |
| **Bastion / Jump Host** | EC2 + Security Groups | VM Service + VirtualMachineService LoadBalancer |
| **DNS** | Route 53 | sslip.io magic DNS (`<IP>.sslip.io`) — ideal for lab/demo/PoC (use enterprise DNS for production) |
| **Certificates** | ACM (AWS Certificate Manager) | Let's Encrypt + cert-manager — ideal for lab/demo/PoC (use enterprise CA for production) |
| **CLI** | `aws` + `eksctl` + `kubectl` | `vcf` + `kubectl` |
| **IaC** | CloudFormation / Terraform | YAML manifests via `kubectl apply` (CCI APIs) |
