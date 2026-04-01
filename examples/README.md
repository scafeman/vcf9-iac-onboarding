# VCF 9 IaC Onboarding — Examples

This folder contains two types of resources:

1. **Sample Manifests** — standalone YAML files for creating individual VCF 9 resources. Start here if you are following the [VCF 9 IaC Onboarding Guide](../vcf9-iac-onboarding-guide.md) step by step.
2. **Automation Scripts** — end-to-end shell scripts that orchestrate full deployments. Use these once you are familiar with the individual resources.

---

## Sample Manifests

These files are working YAML manifests populated with real environment values. Each file includes inline comments explaining every field and `# CHANGE:` markers on values you need to update for your own deployment. Apply them in the order shown below — each resource depends on the ones before it.

### Deployment Order

The VPC must exist before creating the Project and Supervisor Namespace, because the namespace manifest references the VPC by name. If your environment already has a VPC you want to use (check with `kubectl get vpcs`), skip steps 1–3 and use that VPC name in the `vpcName` field of `sample-create-project-ns.yaml`.

```
1. sample-create-vpc.yaml          → NSX VPC                                 (Phase 3)
2. sample-vpc-connectivity-profile.yaml → VPC Connectivity Profile           (Phase 3, optional)
3. sample-vpc-attachment.yaml      → Associate VPC with Connectivity Profile  (Phase 3)
4. sample-create-project-ns.yaml   → Project + RBAC + Supervisor Namespace   (Phase 4)
5. sample-nat-rules.yaml           → SNAT / DNAT rules                       (Phase 3, optional — advanced)
6. sample-create-cluster.yaml      → VKS Cluster                             (Phase 6)
7. sample-create-vm.yaml           → VirtualMachine on private SubnetSet      (VM Service)
8. sample-create-postgres-cluster.yaml → DSM PostgresCluster                  (Database Service Manager)
9. sample-vks-functional-test.yaml → Functional validation workload           (Phase 7)
```

> **Already have a VPC?** If your tenant already has a VPC provisioned (e.g., a default VPC), you can skip steps 1–3 entirely. Just set the `vpcName` field in `sample-create-project-ns.yaml` to your existing VPC name (find it with `kubectl get vpcs`) and start at step 4.

---

### `sample-create-vpc.yaml`

Creates an **NSX VPC** that provides network isolation for your project workloads. Uses the corrected API structure with `spec.privateIPs` and `spec.regionName`.

| | |
|---|---|
| Guide reference | Phase 3 — Step 3: Create the VPC |
| API | `vpc.nsx.vmware.com/v1alpha1` |
| Kind | `VPC` |
| Apply command | `kubectl create -f sample-create-vpc.yaml --validate=false` |

> **Already have a VPC?** If your tenant already has a VPC you want to use, skip this file and the next two (connectivity profile + attachment). Use your existing VPC name in the `vpcName` field of `sample-create-project-ns.yaml`. Find it with `kubectl get vpcs`.

**Values to change for your environment:**

| Field | Sample value | Description |
|---|---|---|
| `name` | `region-us1-a-sample-vpc` | Your VPC name |
| `privateIPs[0]` | `10.10.0.0/16` | Your allocated CIDR range (from `kubectl get ipblocks`) |
| `regionName` | `region-us1-a` | From `kubectl get regions` |

---

### `sample-vpc-connectivity-profile.yaml`

Creates a **VPCConnectivityProfile** that associates a public IP block and a Private-Transit IP block with a Transit Gateway. Use this when you need a custom connectivity profile — if a suitable profile already exists in your environment, skip this step and reference it directly in `sample-vpc-attachment.yaml`.

| | |
|---|---|
| Guide reference | Phase 3 — Step 2: Inspect VPC Connectivity Profiles |
| API | `vpc.nsx.vmware.com/v1alpha1` |
| Kind | `VPCConnectivityProfile` |
| Apply command | `kubectl create -f sample-vpc-connectivity-profile.yaml --validate=false` |
| Optional | Yes — skip if an existing profile meets your needs |

**Values to change for your environment:**

| Field | Sample value | Description |
|---|---|---|
| `name` | `sample-connectivity-profile` | Your profile name |
| `transitGatewayName` | `default@region-us1-a` | From `kubectl get transitgateways` |
| `externalIPBlockNames[0]` | `:ips-02-public-8ga3w` | Provider-provisioned public IP block |
| `privateTGWIPBlockNames[0]` | `region-us1-a-default-tgw-ip-block` | Private-Transit Gateway IP block |

---

### `sample-vpc-attachment.yaml`

Creates a **VPCAttachment** that associates your VPC with a VPC Connectivity Profile, enabling external connectivity and Transit Gateway routing. This replaces the older approach of creating a Transit Gateway directly.

| | |
|---|---|
| Guide reference | Phase 3 — Step 4: Associate VPC with a VPC Connectivity Profile |
| API | `vpc.nsx.vmware.com/v1alpha1` |
| Kind | `VPCAttachment` |
| Apply command | `kubectl create -f sample-vpc-attachment.yaml --validate=false` |

**Values to change for your environment:**

| Field | Sample value | Description |
|---|---|---|
| `name` | `region-us1-a-sample-vpc:sample-attachment` | Must follow `<vpcName>:<attachmentName>` pattern |
| `regionName` | `region-us1-a` | Must match the VPC's region |
| `vpcConnectivityProfileName` | `default@region-us1-a` | From `kubectl get vpcconnectivityprofiles` |
| `vpcName` | `region-us1-a-sample-vpc` | The VPC created in the previous step |

---

### `sample-create-project-ns.yaml`

Creates the three foundational VCF 9 resources in a single apply: a **Project** (governance boundary), a **ProjectRoleBinding** (grants a user admin access), and a **SupervisorNamespace** (provisions the Kubernetes namespace with compute, storage, and network resources).

| | |
|---|---|
| Guide reference | Phase 4 — Project and Namespace Provisioning |
| APIs | `project.cci.vmware.com/v1alpha2`, `authorization.cci.vmware.com/v1alpha1`, `infrastructure.cci.vmware.com/v1alpha2` |
| Kinds | `Project`, `ProjectRoleBinding`, `SupervisorNamespace` |
| Apply command | `kubectl create -f sample-create-project-ns.yaml --validate=false` |

> **Note:** The `SupervisorNamespace` uses `generateName`, so the actual namespace name is only known after creation. Retrieve it with `kubectl get supervisornamespaces -n <PROJECT_NAME>` — you will need this generated name for the Context Bridge in Phase 5.

**Values to change for your environment:**

| Field | Sample value | Description |
|---|---|---|
| Project `name` | `sample-vcf-project-01` | Your project name |
| User identity | `rax-user-1` | Your SSO user identity |
| `generateName` prefix | `sample-vcf-project-01-ns-` | Your namespace prefix |
| `regionName` | `region-us1-a` | From `kubectl get regions` |
| `className` | `xxlarge` | From `kubectl get svnscls` |
| `vpcName` | `region-us1-a-sample-vpc` | Your VPC name — use an existing VPC or the one created in step 1 |
| Zone `name` | `zone-vmw-lab1-md-cl01` | From `kubectl get zones` |

---

### `sample-nat-rules.yaml`

Contains two **VPCNATRule** examples — one SNAT rule (outbound traffic translation) and one DNAT rule (inbound traffic translation). This file is **optional** for most deployments.

| | |
|---|---|
| Guide reference | Phase 3 — Step 5: Configure NAT Rules (Optional — Advanced) |
| API | `vpc.nsx.vmware.com/v1alpha1` |
| Kind | `VPCNATRule` (×2) |
| Apply command | `kubectl create -f sample-nat-rules.yaml --validate=false` |
| Optional | Yes — a default outbound NAT is auto-created with every VPC |

> **When you need this:** Only create custom NAT rules when your design requires mapping a specific internal subnet to a dedicated external IP (SNAT), or forwarding inbound traffic to a specific internal host (DNAT). Resources deployed with External IP blocks receive public IPs automatically and do not need DNAT rules.

**Values to change for your environment:**

| Field | Sample value | Description |
|---|---|---|
| SNAT `namespace` | `sample-vcf-project-01` | Your project name |
| SNAT `translatedNetwork` | *(your external IP)* | An IP from your External IP block |
| SNAT `sourceNetwork` | `10.10.0.0/16` | Internal CIDR to translate |
| DNAT `namespace` | `sample-vcf-project-01` | Your project name |
| DNAT `translatedNetwork` | *(your internal IP)* | Internal IP to forward traffic to |
| DNAT `sourceNetwork` | *(your external CIDR)* | External source CIDR |

---

### `sample-create-vm.yaml`

Creates a **VirtualMachine** on a private NSX SubnetSet with no public IP — suitable for internal workloads (app servers, databases, web servers) that only need outbound internet access via the VPC's default SNAT rule. Demonstrates boot disk resize, data disk attachment via PVC, cloud-init bootstrap, and SubnetSet network selection.

| | |
|---|---|
| API | `vmoperator.vmware.com/v1alpha3` |
| Kinds | `PersistentVolumeClaim`, `VirtualMachine` |
| Apply command | `kubectl apply -f sample-create-vm.yaml` |
| Prerequisite | Cloud-init Secret created, SubnetSet exists in namespace |

> **Three-step process:** (1) Create the cloud-init Secret via `kubectl create secret generic`, (2) apply the manifest which creates the data disk PVC and VirtualMachine together. The cloud-init Secret must exist before the VM is created.

**Values to change for your environment:**

| Field | Sample value | Description |
|---|---|---|
| `namespace` | `sample-vcf-project-01-ns-xxxxx` | Your supervisor namespace |
| VM `name` | `sample-vm` | Your VM name |
| `className` | `best-effort-medium` | From `kubectl get virtualmachineclasses` |
| `imageName` | `ubuntu-24.04-server-cloudimg-amd64` | From `kubectl get virtualmachineimages` |
| `storageClass` | `nfs` | From `kubectl get storageclasses` |
| `bootDiskCapacity` | `50Gi` | Boot disk size (must include unit: Mi, Gi, Ti) |
| `network.name` | `inside-subnet` | From `kubectl get subnetsets` |
| PVC `storage` | `50Gi` | Data disk size |
| `rawCloudConfig.name` | `sample-vm-cloud-init` | Your cloud-init Secret name |

---

### `sample-create-cluster.yaml`

Creates a **VKS cluster** via the Cluster API. Defines the cluster network CIDRs, Kubernetes version, control plane replica count, worker node pool with autoscaler bounds, VM class, and storage class.

> **Note:** The autoscaler annotations (`cluster.x-k8s.io/cluster-api-autoscaler-node-group-min-size` and `max-size`) define the scaling bounds but do not enable autoscaling by themselves. You must also install the Cluster Autoscaler VKS standard package on the guest cluster after provisioning. The `deploy-cluster.sh` script and `deploy-vks.yml` workflow handle this automatically.

| | |
|---|---|
| Guide reference | Phase 6 — VKS Cluster Deployment |
| API | `cluster.x-k8s.io/v1beta1` |
| Kind | `Cluster` |
| Apply command | `kubectl apply -f sample-create-cluster.yaml --validate=false --insecure-skip-tls-verify` |
| Prerequisite | Complete Phase 5 (Context Bridge) — `kubectl get clusters` must not return an error |

> **Important:** The `metadata.namespace` must be the **generated namespace name** from Phase 5 (e.g., `sample-vcf-project-01-ns-a1b2c`). Replace `sample-vcf-project-01-ns-xxxxx` with the actual suffix after running `kubectl get supervisornamespaces -n sample-vcf-project-01`.

**Values to change for your environment:**

| Field | Sample value | Description |
|---|---|---|
| `name` | `sample-vcf-project-clus-01` | Your cluster name |
| `namespace` | `sample-vcf-project-01-ns-xxxxx` | Replace `xxxxx` with actual generated suffix |
| `version` | `v1.33.6+vmware.1-fips` | From `kubectl get tkr` |
| `content-library` | `cl-32ee3681364c701d0` | From `kubectl get clustercontentlibraries` or VCFA Portal (Build & Deploy → Services → Virtual Machine Image → Content Libraries tab) |
| `max-size` | `10` | Autoscaler maximum worker nodes |
| `min-size` | `2` | Autoscaler minimum worker nodes |
| `vmClass` | `best-effort-large` | Worker node VM size |
| `storageClass` | `nfs` | From `kubectl get sc` on the VKS cluster |

---

### `sample-create-postgres-cluster.yaml`

Creates a **DSM PostgresCluster** — a fully managed PostgreSQL instance provisioned via the VCF Database Service Manager. This is the VCF equivalent of AWS RDS. DSM handles VM provisioning, PostgreSQL installation, patching, maintenance windows, and connection endpoint management.

| | |
|---|---|
| API | `databases.dataservices.vmware.com/v1alpha1` |
| Kind | `PostgresCluster` |
| Apply command | `kubectl apply -f sample-create-postgres-cluster.yaml --validate=false` |
| Prerequisite | Admin password Secret created, DSM infrastructure policy configured in supervisor namespace |

> **Two-step process:** (1) Create the admin password Secret via `kubectl create secret generic`, (2) apply the manifest which creates the PostgresCluster. DSM automatically creates a `pg-<cluster-name>` secret with the admin password after provisioning.

**Values to change for your environment:**

| Field | Sample value | Description |
|---|---|---|
| `namespace` | `sample-vcf-project-01-ns-xxxxx` | Your supervisor namespace |
| `name` | `sample-postgres-cluster` | Your PostgresCluster name |
| `dsm.vmware.com/infra-policy` | `sample-infra-policy` | DSM infrastructure policy name |
| `dsm.vmware.com/vm-class` | `best-effort-large` | VM class (Single Server requires 4 CPU min) |
| `dsm.vmware.com/consumption-namespace` | `sample-vcf-project-01-ns-xxxxx` | Must be the supervisor namespace |
| `replicas` | `0` | `0` = Single Server, `1` = Single-Zone HA |
| `storagePolicyName` | `nfs` | From `kubectl get storagepolicies` |
| `version` | `16` | PostgreSQL version |

---

### `sample-vks-functional-test.yaml`

Deploys a lightweight test workload to validate that storage, compute, and networking are all operational on a VKS cluster. Creates a **PersistentVolumeClaim** (validates CSI/storage), a **Deployment** (validates pod scheduling with a hardened security context), and a **LoadBalancer Service** (validates NSX load balancer ingress and external IP assignment).

| | |
|---|---|
| Guide reference | Phase 7 — Functional Validation |
| APIs | `v1`, `apps/v1` |
| Kinds | `PersistentVolumeClaim`, `Deployment`, `Service` |
| Apply command | `kubectl apply -f sample-vks-functional-test.yaml` |
| Prerequisite | VKS cluster provisioned and kubeconfig set (`vcf cluster kubeconfig get <CLUSTER_NAME>`) |

**Verification steps:**

```bash
kubectl get pvc vks-test-pvc       # STATUS should be Bound
kubectl get deploy vks-test-app    # READY should be 1/1
kubectl get svc vks-test-lb        # EXTERNAL-IP should be assigned
curl http://<EXTERNAL_IP>          # Should return nginx page
```

**Cleanup:**

```bash
kubectl delete -f sample-vks-functional-test.yaml
```

**Values to change for your environment:**

| Field | Sample value | Description |
|---|---|---|
| `storageClassName` | `nfs` | From `kubectl get storageclasses` on the VKS cluster |

---

## Automation Scripts

These end-to-end scripts orchestrate full deployments across multiple VCF resources. Each deployment builds on the previous one.

## Dependency Chain

```
Deploy Cluster: Full Stack Deploy (VKS cluster provisioning)
  ├─► Deploy Metrics: VKS Metrics Observability (monitoring stack)
  ├─► Deploy GitOps: Self-Contained ArgoCD Consumption Model (GitOps + CI/CD)
  ├─► Deploy Hybrid App: Infrastructure Asset Tracker (VM-to-container connectivity)
  ├─► Deploy Managed DB App: DSM PostgresCluster Asset Tracker (managed database)
  └─► Deploy Bastion VM: SSH Jump Host (standalone VM — no VKS cluster required)
```

Deploy Metrics, Deploy GitOps, Deploy Hybrid App, and Deploy Managed DB App all require a running VKS cluster provisioned by Deploy Cluster. They are independent of each other and can be deployed in any order.

---

## Deploy Cluster: Full Stack Deploy

Provisions a complete VKS cluster from scratch using the VCF CLI. Handles project creation, RBAC, Supervisor Namespace, VPC networking, cluster lifecycle, and Cluster Autoscaler installation — from zero to a running Kubernetes cluster with LoadBalancer support, `nfs` storageClass, and automatic node scaling.

| | |
|---|---|
| Folder | [`deploy-cluster/`](deploy-cluster/) |
| Deploy | `bash examples/deploy-cluster/deploy-cluster.sh` |
| Teardown | `bash examples/deploy-cluster/teardown-cluster.sh` |
| Output | Running VKS cluster + admin kubeconfig file |

## Deploy Metrics: VKS Metrics Observability

Installs a monitoring stack on an existing VKS cluster: Telegraf (metrics collection), Prometheus (metrics storage), and Grafana (dashboards). Uses VCF Supervisor packages for Telegraf and Prometheus, and Helm for the Grafana Operator.

| | |
|---|---|
| Folder | [`deploy-metrics/`](deploy-metrics/) |
| Depends on | Deploy Cluster (running VKS cluster) |
| Deploy | `bash examples/deploy-metrics/deploy-metrics.sh` |
| Teardown | `bash examples/deploy-metrics/teardown-metrics.sh` |
| Output | Grafana dashboards with Kubernetes cluster metrics |

## Deploy GitOps: Self-Contained ArgoCD Consumption Model

Installs a full GitOps and CI/CD stack on an existing VKS cluster. Infrastructure services (cert-manager, Contour) are installed as shared VKS standard packages. Application services (Harbor, ArgoCD, GitLab) are installed via Helm. Deploys the Google Microservices Demo (Online Boutique) as a sample ArgoCD-managed application.

| | |
|---|---|
| Folder | [`deploy-gitops/`](deploy-gitops/) |
| Depends on | Deploy Cluster (running VKS cluster with LoadBalancer + nfs storageClass) |
| Deploy | `bash examples/deploy-gitops/deploy-gitops.sh` |
| Teardown | `bash examples/deploy-gitops/teardown-gitops.sh` |
| Output | Harbor, GitLab, ArgoCD, and Online Boutique accessible via Contour ingress (shared VKS package) |

## Deploy Bastion VM: SSH Jump Host

Deploys a minimal Ubuntu 24.04 bastion VM as a secure SSH jump host in a VCF 9 supervisor namespace. The VM is exposed via a `VirtualMachineService` LoadBalancer with `loadBalancerSourceRanges` to restrict SSH access to specific source IPs. The public IP is automatically allocated from the NSX VPC external IP pool.

| | |
|---|---|
| Folder | [`deploy-bastion-vm/`](deploy-bastion-vm/) |
| Depends on | Supervisor Namespace with VPC networking (no VKS cluster required) |
| Deploy | `bash examples/deploy-bastion-vm/deploy-bastion-vm.sh` |
| Teardown | `bash examples/deploy-bastion-vm/teardown-bastion-vm.sh` |
| Output | SSH-accessible bastion VM at auto-assigned LoadBalancer IP, restricted to allowed source IPs |

## Deploy Hybrid App: Infrastructure Asset Tracker

Deploys a full-stack demo application demonstrating VM-to-container connectivity within a VCF 9 namespace. A PostgreSQL 16 database runs on a dedicated VM provisioned via the VCF VM Service, while a Node.js REST API and Next.js frontend run as containerized workloads in the VKS guest cluster.

| | |
|---|---|
| Folder | [`deploy-hybrid-app/`](deploy-hybrid-app/) |
| Depends on | Deploy Cluster (running VKS cluster) |
| Deploy | `bash examples/deploy-hybrid-app/deploy-hybrid-app.sh` |
| Teardown | `bash examples/deploy-hybrid-app/teardown-hybrid-app.sh` |
| Output | Next.js dashboard at LoadBalancer IP, PostgreSQL VM, Node.js API — all communicating over NSX VPC |

## Deploy Managed DB App: DSM PostgresCluster Infrastructure Asset Tracker

Deploys the same Infrastructure Asset Tracker application but backed by a VCF Database Service Manager (DSM) managed PostgresCluster instead of a manually provisioned VM. This is the VCF equivalent of AWS EKS + RDS — a fully managed PostgreSQL instance with automated maintenance, patching, and connection management.

| | |
|---|---|
| Folder | [`deploy-managed-db-app/`](deploy-managed-db-app/) |
| Depends on | Deploy Cluster (running VKS cluster) + DSM infrastructure policy configured in supervisor namespace |
| Deploy | `bash examples/deploy-managed-db-app/deploy-managed-db-app.sh` |
| Teardown | `bash examples/deploy-managed-db-app/teardown-managed-db-app.sh` |
| Output | Next.js dashboard at LoadBalancer IP, DSM-managed PostgreSQL, Node.js API — all communicating over NSX VPC |

---
