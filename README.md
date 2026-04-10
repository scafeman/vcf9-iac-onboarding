# VCF 9 IaC Onboarding Toolkit

Infrastructure-as-Code toolkit for migrating containerized workloads from AWS EKS to VMware Cloud Foundation (VCF) 9 with VMware Kubernetes Service (VKS). Automates the full lifecycle — from cluster provisioning to hybrid VM+container deployments — on Private Cloud infrastructure.

## What This Repo Provides

- A comprehensive [IaC Onboarding Guide](vcf9-iac-onboarding-guide.md) covering the full VCF 9 lifecycle from environment initialization through VKS cluster deployment and functional validation
- Fully automated deploy and teardown scripts for spinning VCF 9 dev environments up and down with zero user interaction
- A Dockerized development environment with VCF CLI, kubectl, and all tooling pre-installed
- Declarative YAML manifests for VCF 9 resources (Projects, Namespaces, VKS Clusters, functional test workloads)
- Property-based and content-presence test suites validating manifest correctness and guide accuracy
- GitHub Actions workflows for automated deployment of all deployments via CI/CD
- A managed database demo (Infrastructure Asset Tracker) showcasing VCF Data Services Manager (DSM) with a fully managed PostgresCluster and a Next.js/Node.js app on VKS — the VCF equivalent of AWS EKS + RDS, with vault-injected credentials via VCF Secret Store for zero-trust credential management
- Companion trigger scripts for dispatching workflows from the command line
- A self-hosted runner configuration for executing workflows on private VCF infrastructure
- An EKS-to-VKS migration mapping for teams coming from AWS

## EKS to VKS at a Glance

Coming from AWS EKS? Here's how the core concepts map to VCF 9 and where this toolkit handles them:

| AWS EKS Concept | VCF 9 / VKS Equivalent | Toolkit Implementation |
|---|---|---|
| EKS Add-ons | VKS Standard Packages | Automated via `vcf package install` in Deploy Cluster, Metrics, and GitOps |
| IAM Roles / IRSA | CCI Projects & RBAC | Handled in Phase 2 (Project & Namespace Provisioning) |
| Managed Node Groups | Worker Pools (Cluster API) | Declarative YAML with autoscaler annotations in `examples/deploy-cluster/` |
| EBS / EFS | Cloud Native Storage (CNS) | Validated in Phase 7 (Functional Validation) with PVC + `nfs` StorageClass |
| ALB / NLB | NSX Load Balancer | LoadBalancer Services provisioned automatically via NSX VPC |
| ECR | Harbor (self-hosted) | Deployed via `examples/deploy-gitops/` with Helm |
| CodePipeline / CodeBuild | GitLab CI + ArgoCD | Full GitOps stack in `examples/deploy-gitops/` |
| Secrets Manager | VCF Secret Store Service | Demonstrated in `examples/deploy-secrets-demo/` |
| RDS (PostgreSQL) | Data Services Manager (DSM) | Fully managed PostgresCluster via DSM CRD in `examples/deploy-managed-db-app/` |
| Lambda | Knative Service | Scale-to-zero serverless functions in `examples/deploy-knative/` |
| API Gateway | Contour (net-contour) | HTTP routing via Envoy proxy for Knative Services |
| Route 53 | sslip.io Magic DNS | Wildcard DNS via `<IP>.sslip.io` — no external DNS provider required |
| ACM (Certificate Manager) | Let's Encrypt + cert-manager | Automated trusted TLS certificates via ACME HTTP-01 challenge |
| DynamoDB Streams | HTTP Webhook | Direct HTTP invocation from API server to Knative audit function |
| EC2 (HA multi-tier) | VM Service VMs | 2× web + 2× API VMs with LoadBalancers in `examples/deploy-ha-vm-app/` |

See the [EKS to VKS Migration Checklist](AWS-EKS-to-VCF-VKS-Migration-Checklist.md) for a full pass/fail validation checklist.

## Architecture Overview

The toolkit provides nine deployment patterns that cover the full VCF 9 application lifecycle — from cluster provisioning to managed databases with vault-injected credentials.

### Foundation: VKS Cluster Deployment (7 phases)

Every deployment pattern starts with a running VKS cluster. The Deploy Cluster workflow automates the full provisioning lifecycle:

1. **Environment Initialization** — VCF CLI context creation and VCFA authentication
2. **Project & Namespace Provisioning** — Project, RBAC, and Supervisor Namespace creation via CCI APIs
3. **Context Bridge** — Switching from global to namespace-scoped context to expose Cluster API resources
4. **VKS Cluster Deployment** — Cluster API manifest with autoscaling worker pools
5. **Kubeconfig Retrieval** — Admin kubeconfig via VCF CLI with guest cluster connectivity verification
6. **Cluster Autoscaler Installation** — VKS standard package for automatic node scaling based on pod resource demands
7. **cert-manager, Contour & Let's Encrypt** — TLS certificate lifecycle management, Envoy-based ingress controller, and Let's Encrypt ClusterIssuer for automated trusted certificates via sslip.io DNS
8. **Functional Validation** — PVC, Deployment, and LoadBalancer Service to validate storage, compute, and networking

> [!TIP]
> **The Context Bridge** is the critical step that most engineers miss. In VCF 9, Cluster API resources are hidden from the global context. This toolkit automates the switch to the namespace-scoped context, effectively "unlocking" `kubectl get clusters`. Without it, the command returns nothing — even though the cluster exists.

### Deployment Patterns

Once the VKS cluster is running, the toolkit offers eight additional deployment patterns:

| Pattern | What It Proves | AWS Equivalent |
|---|---|---|
| **Deploy Metrics** | VKS standard packages (Telegraf, Prometheus, Grafana) | EKS Add-ons + CloudWatch |
| **Deploy GitOps** | Full CI/CD stack (Harbor, ArgoCD, GitLab) on VKS | ECR + CodePipeline + ArgoCD |
| **Deploy Hybrid App** | VM-to-container connectivity over NSX VPC | EC2 + EKS in same VPC |
| **Deploy Managed DB App** | DSM-managed PostgreSQL with vault-injected credentials | EKS + RDS + Secrets Manager |
| **Deploy Secrets Demo** | VCF Secret Store with vault-injected Redis + PostgreSQL | Secrets Manager + EKS |
| **Deploy HA VM App** | Traditional HA three-tier app on VMs (web, API, managed DB) | 2× EC2 + 2× ALB + RDS PostgreSQL Multi-AZ |
| **Deploy Knative** | Knative Serving FaaS with DSM-backed serverless audit function | Lambda + API Gateway + RDS |
| **Deploy Bastion VM** | SSH jump host with source-IP-restricted LoadBalancer | EC2 bastion + Security Groups |

```
Deploy Cluster (foundation)
    ├── Deploy Metrics         — observability stack
    ├── Deploy GitOps          — CI/CD + GitOps stack
    ├── Deploy Hybrid App      — VM + container connectivity
    ├── Deploy Managed DB App  — managed database + vault credentials
    ├── Deploy HA VM App       — HA three-tier app on VMs
    ├── Deploy Knative         — serverless FaaS + DBaaS
    ├── Deploy Secrets Demo    — secret store integration
    └── Deploy Bastion VM      — SSH jump host (no VKS cluster required)
```

Each pattern has a deploy script, teardown script, GitHub Actions workflow, and README documentation. All scripts and workflows follow the same structure — making it easy to understand one and apply the pattern to the others.

## How to Use This Toolkit

| Path | Best For | What You Need |
|---|---|---|
| **Run locally** | Fastest way to deploy — no GitHub setup needed | Clone the repo, configure `.env`, run scripts via `docker exec` |
| **Fork to your GitHub org** | CI/CD automation with GitHub Actions workflows | Fork the repo, add your secrets, register a self-hosted runner |
| **Watch the demo** | See the workflows in action before committing | The source repo has approval-gated workflows for live demos |

> [!NOTE]
> The GitHub Actions workflows in this repository are locked down with environment protection rules and require reviewer approval. To run the workflows yourself, **fork the repo** to your own GitHub organization, configure your secrets, and register your own self-hosted runner. See the [Getting Started Guide](GETTING-STARTED.md) for detailed fork and runner setup instructions.

## Quick Start

1. Clone the repo and create a `.env` file with your VCF 9 credentials
2. `docker compose up -d --build` — start the dev container
3. `docker exec vcf9-dev bash examples/deploy-cluster/deploy-cluster.sh` — deploy a VKS cluster
4. Estimated time: **12–18 minutes** for a fully validated VKS cluster with autoscaling

See the [Getting Started Guide](GETTING-STARTED.md) for full setup instructions, all deployment commands, and GitHub Actions configuration.

## GitHub Actions Workflows

All deployments are available as GitHub Actions workflows for automated CI/CD deployment. The workflows run on a self-hosted runner built from `Dockerfile.runner` with VCF CLI, kubectl, Helm, and openssl baked in.

| Workflow | File | Trigger |
|---|---|---|
| Deploy VKS Cluster | `deploy-vks.yml` | `workflow_dispatch` / `repository_dispatch` (event: `deploy-vks`) |
| Deploy VKS Metrics Stack | `deploy-vks-metrics.yml` | `workflow_dispatch` / `repository_dispatch` (event: `deploy-vks-metrics`) |
| Deploy ArgoCD Stack | `deploy-argocd.yml` | `workflow_dispatch` / `repository_dispatch` (event: `deploy-argocd`) |
| Deploy Hybrid App | `deploy-hybrid-app.yml` | `workflow_dispatch` / `repository_dispatch` (event: `deploy-hybrid-app`) |
| Deploy Secrets Demo | `deploy-secrets-demo.yml` | `workflow_dispatch` / `repository_dispatch` (event: `deploy-secrets-demo`) |
| Deploy Bastion VM | `deploy-bastion-vm.yml` | `workflow_dispatch` / `repository_dispatch` (event: `deploy-bastion-vm`) |
| Deploy Managed DB App | `deploy-managed-db-app.yml` | `workflow_dispatch` / `repository_dispatch` (event: `deploy-managed-db-app`) |
| Deploy HA VM App | `deploy-ha-vm-app.yml` | `workflow_dispatch` / `repository_dispatch` (event: `deploy-ha-vm-app`) |
| Deploy Knative | `deploy-knative.yml` | `workflow_dispatch` / `repository_dispatch` (event: `deploy-knative`) |
| Teardown VCF Stacks | `teardown.yml` | `workflow_dispatch` / `repository_dispatch` (event: `teardown`) |

Deploy Cluster must complete before Deploy Metrics, Deploy GitOps, or Deploy Hybrid App can run. The Teardown workflow reverses the deploy order with selective boolean inputs. See the [Workflows README](.github/workflows/README.md) for full parameter documentation, credential retrieval instructions, and troubleshooting.

## Deployments

| Deployment | What It Does | Folder |
|---|---|---|
| Deploy Cluster | Provisions VKS cluster with autoscaling, packages, and functional validation | [`examples/deploy-cluster/`](examples/deploy-cluster/) |
| Deploy Metrics | Installs Telegraf, Prometheus, and Grafana on the VKS cluster | [`examples/deploy-metrics/`](examples/deploy-metrics/) |
| Deploy GitOps | Installs Harbor, ArgoCD, GitLab, and deploys Microservices Demo | [`examples/deploy-gitops/`](examples/deploy-gitops/) |
| Deploy Hybrid App | Provisions a PostgreSQL VM + deploys a Next.js/Node.js app on VKS | [`examples/deploy-hybrid-app/`](examples/deploy-hybrid-app/) |
| Deploy Managed DB App | Provisions a DSM-managed PostgresCluster + deploys a Next.js/Node.js app on VKS | [`examples/deploy-managed-db-app/`](examples/deploy-managed-db-app/) |
| Deploy HA VM App | Deploys a traditional HA three-tier app on VMs: 2× web VMs + LB, 2× API VMs + LB, DSM PostgresCluster | [`examples/deploy-ha-vm-app/`](examples/deploy-ha-vm-app/) |
| Deploy Knative | Deploys Knative Serving with serverless audit function, API server, and DSM PostgresCluster | [`examples/deploy-knative/`](examples/deploy-knative/) |
| Deploy Bastion VM | Deploys a secure SSH jump host VM with source-IP-restricted LoadBalancer | [`examples/deploy-bastion-vm/`](examples/deploy-bastion-vm/) |
| Deploy Secrets Demo | Demonstrates VCF Secret Store with vault-injected secrets for Redis + PostgreSQL | [`examples/deploy-secrets-demo/`](examples/deploy-secrets-demo/) |

Each deployment has its own deploy script, teardown script, and README documentation. See the [Examples Overview](examples/README.md) for details.

### Showcase: Managed Database App (EKS + RDS → VKS + DSM)

The Deploy Managed DB App deployment demonstrates that VCF can deliver the same managed database experience as AWS RDS — fully automated, no DBA required:

- **Data Tier** — PostgreSQL 17 provisioned as a fully managed DSM PostgresCluster. DSM handles VM provisioning, PostgreSQL installation, patching, maintenance windows, and connection endpoint management. You define the topology (Single Server or HA), VM class, and storage — DSM does the rest.
- **App Tier** — Next.js frontend and Node.js API running as containerized workloads on VKS, connecting to the DSM-managed PostgreSQL endpoint over SSL
- **Zero Admin** — No SSH, no `apt install`, no `pg_hba.conf` editing. The PostgresCluster CRD is the single interface — same declarative model as every other Kubernetes resource

This is the deployment that resonates most with teams migrating from AWS. If you're running EKS + RDS today, this proves VCF can deliver the same pattern on private cloud infrastructure.

## Key VCF 9 Concepts

| Concept | Description |
|---|---|
| **Context Bridge** | The critical step that switches from global (org-level) to namespace-scoped context, making Cluster API resources visible. Without it, `kubectl get clusters` returns nothing. |
| **generateName** | Supervisor Namespaces use `generateName` instead of `name`, so VCF appends a random 5-character suffix. Scripts must discover the dynamic name after creation. |
| **CCI APIs** | Cloud Consumption Interface — the VCF 9 API layer for Projects, Namespaces, RBAC, and infrastructure resources. |
| **VKS** | VMware Kubernetes Service — managed Kubernetes clusters deployed via Cluster API on a vSphere Supervisor. |
| **VKS Standard Packages** | Pre-built, versioned Kubernetes add-ons distributed as OCI images and managed by kapp-controller. Installed via `vcf package install` into a dedicated namespace (default: `tkg-packages`). The AWS equivalent is EKS Add-ons — both provide curated, lifecycle-managed cluster extensions. |
| **Package Repository** | An OCI registry containing the VKS standard packages catalog. Registered via `vcf package repository add` before any packages can be installed. Similar to adding a Helm repo, but uses the Carvel packaging APIs. |
| **kapp-controller** | The Carvel package manager that runs on every VKS cluster. It watches PackageInstall resources and reconciles them. During teardown, finalizers must be stripped before deletion to prevent cascading namespace destruction. |

## Documentation

- [Getting Started Guide](GETTING-STARTED.md) — Setup, configuration, and deployment commands
- [Environment Variables Reference](ENVIRONMENT-VARIABLES.md) — All configurable variables for every deployment
- [GitHub Actions Workflows](.github/workflows/README.md) — Workflow parameters, triggers, credential retrieval, and troubleshooting
- [IaC Onboarding Guide](vcf9-iac-onboarding-guide.md) — Full VCF 9 walkthrough with annotated manifests and CLI commands
- [Engineering Workflow](VCF_Engineering_Workflow.md) — Condensed step-by-step engineering workflow
- [EKS to VKS Migration Checklist](AWS-EKS-to-VCF-VKS-Migration-Checklist.md) — Pass/fail migration validation checklist
- [Examples Overview](examples/README.md) — Sample manifests and automation script documentation
- [Command Reference](docs/COMMAND-REFERENCE.md) — VCF CLI, kubectl, and Docker command cheatsheet organized by context level

## Testing

```bash
docker exec vcf9-dev pytest tests/ -v    # inside dev container
pytest tests/ -v                          # locally (requires Python 3.10+)
```

The test suite uses pytest and Hypothesis for content-presence and property-based testing across all scripts, manifests, and workflows.

## License

This project is provided as-is for internal use. See your organization's licensing policies for distribution terms.
