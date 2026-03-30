# VCF 9 IaC Onboarding Toolkit

Infrastructure-as-Code toolkit for provisioning and managing VMware Cloud Foundation (VCF) 9 environments with VMware Kubernetes Service (VKS). Built for DevOps engineers migrating container workloads from AWS EKS to on-premises VCF 9.

## What This Repo Provides

- A comprehensive [IaC Onboarding Guide](vcf9-iac-onboarding-guide.md) covering the full VCF 9 lifecycle from environment initialization through VKS cluster deployment and functional validation
- Fully automated deploy and teardown scripts for spinning VCF 9 dev environments up and down with zero user interaction
- A Dockerized development environment with VCF CLI, kubectl, and all tooling pre-installed
- Declarative YAML manifests for VCF 9 resources (Projects, Namespaces, VKS Clusters, functional test workloads)
- Property-based and content-presence test suites validating manifest correctness and guide accuracy
- GitHub Actions workflows for automated deployment of all four deployments via CI/CD
- A hybrid VM+container demo (Infrastructure Asset Tracker) showcasing VCF VM Service with PostgreSQL on a VM and a Next.js/Node.js app on VKS — proving VM-to-container connectivity over NSX VPC
- Companion trigger scripts for dispatching workflows from the command line
- A self-hosted runner configuration for executing workflows on private VCF infrastructure
- An EKS-to-VKS migration mapping for teams coming from AWS

## Architecture Overview

The toolkit automates the VCF 9 provisioning workflow across six phases:

1. **Environment Initialization** — VCF CLI context creation and VCFA authentication
2. **Project & Namespace Provisioning** — Project, RBAC, and Supervisor Namespace creation via CCI APIs
3. **Context Bridge** — Switching from global to namespace-scoped context to expose Cluster API resources
4. **VKS Cluster Deployment** — Cluster API manifest with autoscaling worker pools
5. **Kubeconfig Retrieval** — Admin kubeconfig via VCF CLI with guest cluster connectivity verification
6. **Cluster Autoscaler Installation** — VKS standard package for automatic node scaling based on pod resource demands
7. **Functional Validation** — PVC, Deployment, and LoadBalancer Service to validate storage, compute, and networking

## Quick Start

1. Clone the repo and create a `.env` file with your VCF 9 credentials
2. `docker compose up -d --build` — start the dev container
3. `docker exec vcf9-dev bash examples/deploy-cluster/deploy-cluster.sh` — deploy a VKS cluster

See the [Getting Started Guide](GETTING-STARTED.md) for full setup instructions, all deployment commands, and GitHub Actions configuration.

## GitHub Actions Workflows

All four deployments are also available as GitHub Actions workflows for automated CI/CD deployment. The workflows run on a self-hosted runner built from `Dockerfile.runner` with VCF CLI, kubectl, Helm, and openssl baked in.

| Workflow | File | Trigger |
|---|---|---|
| Deploy VKS Cluster | `deploy-vks.yml` | `workflow_dispatch` / `repository_dispatch` (event: `deploy-vks`) |
| Deploy VKS Metrics Stack | `deploy-vks-metrics.yml` | `workflow_dispatch` / `repository_dispatch` (event: `deploy-vks-metrics`) |
| Deploy ArgoCD Stack | `deploy-argocd.yml` | `workflow_dispatch` / `repository_dispatch` (event: `deploy-argocd`) |
| Deploy Hybrid App | `deploy-hybrid-app.yml` | `workflow_dispatch` / `repository_dispatch` (event: `deploy-hybrid-app`) |
| Teardown VCF Stacks | `teardown.yml` | `workflow_dispatch` / `repository_dispatch` (event: `teardown`) |

Deploy Cluster must complete before Deploy Metrics, Deploy GitOps, or Deploy Hybrid App can run. The Teardown workflow reverses the deploy order (GitOps → Metrics → Cluster) with selective boolean inputs. See the [Workflows README](.github/workflows/README.md) for full parameter documentation, credential retrieval instructions, and troubleshooting.

## Deployments

| Deployment | What It Does | Folder |
|---|---|---|
| Deploy Cluster | Provisions VKS cluster with autoscaling, packages, and functional validation | [`examples/deploy-cluster/`](examples/deploy-cluster/) |
| Deploy Metrics | Installs Telegraf, Prometheus, and Grafana on the VKS cluster | [`examples/deploy-metrics/`](examples/deploy-metrics/) |
| Deploy GitOps | Installs Harbor, ArgoCD, GitLab, and deploys Microservices Demo | [`examples/deploy-gitops/`](examples/deploy-gitops/) |
| Deploy Hybrid App | Provisions a PostgreSQL VM + deploys a Next.js/Node.js app on VKS | [`examples/deploy-hybrid-app/`](examples/deploy-hybrid-app/) |

Each deployment has its own deploy script, teardown script, and README documentation. See the [Examples Overview](examples/README.md) for details.

## Key VCF 9 Concepts

| Concept | Description |
|---|---|
| **Context Bridge** | The critical step that switches from global (org-level) to namespace-scoped context, making Cluster API resources visible. Without it, `kubectl get clusters` returns nothing. |
| **generateName** | Supervisor Namespaces use `generateName` instead of `name`, so VCF appends a random 5-character suffix. Scripts must discover the dynamic name after creation. |
| **CCI APIs** | Cloud Consumption Interface — the VCF 9 API layer for Projects, Namespaces, RBAC, and infrastructure resources. |
| **VKS** | VMware Kubernetes Service — managed Kubernetes clusters deployed via Cluster API on a vSphere Supervisor. |
| **VKS Standard Packages** | Pre-built, versioned Kubernetes add-ons distributed as OCI images and managed by kapp-controller. Installed via `vcf package install` into a dedicated namespace (default: `tkg-packages`). The AWS equivalent is EKS Add-ons — both provide curated, lifecycle-managed cluster extensions. Available packages include Telegraf, Prometheus, cert-manager, Contour, and Cluster Autoscaler. |
| **Package Repository** | An OCI registry containing the VKS standard packages catalog. Registered via `vcf package repository add` before any packages can be installed. Similar to adding a Helm repo, but uses the Carvel packaging APIs (PackageRepository, PackageInstall, App) instead of Helm charts. |
| **kapp-controller** | The Carvel package manager that runs on every VKS cluster. It watches PackageInstall resources and reconciles them — fetching the OCI bundle, templating with ytt, and deploying with kapp. When you `vcf package install`, it creates a PackageInstall CR that kapp-controller picks up. During teardown, finalizers must be stripped before deletion to prevent kapp-controller's reconcile-delete from cascading into namespace destruction. |

## Documentation

- [Getting Started Guide](GETTING-STARTED.md) — Setup, configuration, and deployment commands
- [Environment Variables Reference](ENVIRONMENT-VARIABLES.md) — All configurable variables for every deployment
- [GitHub Actions Workflows](.github/workflows/README.md) — Workflow parameters, triggers, credential retrieval, and troubleshooting
- [IaC Onboarding Guide](vcf9-iac-onboarding-guide.md) — Full VCF 9 walkthrough with annotated manifests and CLI commands
- [Engineering Workflow](VCF_Engineering_Workflow.md) — Condensed step-by-step engineering workflow
- [EKS to VKS Migration Checklist](AWS-EKS-to-VCF-VKS-Migration-Checklist.md) — Pass/fail migration validation checklist
- [Examples Overview](examples/README.md) — Sample manifests and automation script documentation

## Testing

```bash
docker exec vcf9-dev pytest tests/ -v    # inside dev container
pytest tests/ -v                          # locally (requires Python 3.10+)
```

The test suite uses pytest and Hypothesis for content-presence and property-based testing across all scripts, manifests, and workflows.

## License

This project is provided as-is for internal use. See your organization's licensing policies for distribution terms.
