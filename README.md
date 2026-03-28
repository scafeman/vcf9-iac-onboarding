# VCF 9 IaC Onboarding Toolkit

Infrastructure-as-Code toolkit for provisioning and managing VMware Cloud Foundation (VCF) 9 environments with VMware Kubernetes Service (VKS). Built for DevOps engineers migrating container workloads from AWS EKS to on-premises VCF 9.

## What This Repo Provides

- A comprehensive [IaC Onboarding Guide](vcf9-iac-onboarding-guide.md) covering the full VCF 9 lifecycle from environment initialization through VKS cluster deployment and functional validation
- Fully automated deploy and teardown scripts for spinning VCF 9 dev environments up and down with zero user interaction
- A Dockerized development environment with VCF CLI, kubectl, and all tooling pre-installed
- Declarative YAML manifests for VCF 9 resources (Projects, Namespaces, VKS Clusters, functional test workloads)
- Property-based and content-presence test suites validating manifest correctness and guide accuracy
- GitHub Actions workflows for automated deployment of all three scenarios via CI/CD
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
6. **Functional Validation** — PVC, Deployment, and LoadBalancer Service to validate storage, compute, and networking

## Quick Start

### Prerequisites

- Docker and Docker Compose
- A VCF 9 / VCFA environment with API access
- An API token from the VCFA portal

### 1. Clone and configure

```bash
git clone https://github.com/scafeman/vcf9-iac-onboarding.git
cd vcf9-iac-onboarding
```

Create a `.env` file at the project root with your environment-specific values:

```env
VCF_API_TOKEN=<your-api-token>
VCFA_ENDPOINT=<vcfa-hostname>
TENANT_NAME=<sso-tenant>
CONTEXT_NAME=<cli-context-name>
PROJECT_NAME=<project-name>
USER_IDENTITY=<sso-user>
NAMESPACE_PREFIX=<namespace-prefix->
ZONE_NAME=<availability-zone>
CLUSTER_NAME=<cluster-name>
CONTENT_LIBRARY_ID=<content-library-id>
```

See the [deploy script README](examples/scenario1/README-deploy.md) for the full variable reference including optional variables with defaults.

### 2. Build and start the dev container

```bash
docker compose up -d --build
```

This builds an Ubuntu 24.04 container with VCF CLI (v9.0.2) and kubectl (v1.33.0) pre-installed.

### 3. Deploy the full stack

```bash
docker exec vcf9-dev bash examples/scenario1/scenario1-full-stack-deploy.sh
```

Typical deployment time: 5–18 minutes. The script provisions a VCF project, supervisor namespace, VKS cluster with autoscaling workers, and validates the stack with a test workload.

### 4. Tear it all down

```bash
docker exec vcf9-dev bash examples/scenario1/scenario1-full-stack-teardown.sh
```

Typical teardown time: 1–6 minutes. Safe to run multiple times (fully idempotent).

## GitHub Actions Workflows

All three scenarios are also available as GitHub Actions workflows for automated CI/CD deployment. The workflows run on a self-hosted runner built from `Dockerfile.runner` with VCF CLI, kubectl, Helm, and openssl baked in.

| Workflow | File | Trigger |
|---|---|---|
| Deploy VKS Cluster | `deploy-vks.yml` | `workflow_dispatch` / `repository_dispatch` (event: `deploy-vks`) |
| Deploy VKS Metrics Stack | `deploy-vks-metrics.yml` | `workflow_dispatch` / `repository_dispatch` (event: `deploy-vks-metrics`) |
| Deploy ArgoCD Stack | `deploy-argocd.yml` | `workflow_dispatch` / `repository_dispatch` (event: `deploy-argocd`) |

Scenario 1 must complete before Scenarios 2 or 3 can run. See the [Workflows README](.github/workflows/README.md) for full parameter documentation, credential retrieval instructions, and troubleshooting.

## Repository Structure

```
.
├── README.md                          # This file
├── vcf9-iac-onboarding-guide.md       # Comprehensive IaC onboarding guide (8 phases + appendices)
├── VCF_Engineering_Workflow.md         # Quick-reference engineering workflow
├── AWS-EKS-to-VCF-VKS-Migration-Checklist.md  # Migration success criteria checklist
├── Dockerfile                         # Dev container with VCF CLI + kubectl
├── docker-compose.yml                 # Container orchestration config
├── .env                               # Environment variables (not committed)
├── .gitignore                         # Git ignore rules
├── .github/
│   └── workflows/
│       ├── deploy-vks.yml             # Scenario 1: Deploy VKS Cluster workflow
│       ├── deploy-vks-metrics.yml     # Scenario 2: Deploy VKS Metrics Stack workflow
│       ├── deploy-argocd.yml          # Scenario 3: Deploy ArgoCD Stack workflow
│       └── README.md                  # Workflow documentation (parameters, triggers, credentials)
├── scripts/
│   ├── trigger-deploy.sh             # Companion trigger script for Scenario 1
│   ├── trigger-deploy-metrics.sh     # Companion trigger script for Scenario 2
│   └── trigger-deploy-argocd.sh      # Companion trigger script for Scenario 3
├── Dockerfile.runner                  # Self-hosted GitHub Actions runner image
├── examples/
│   ├── scenario1/                               # Scenario 1: Full Stack Deploy
│   │   ├── scenario1-full-stack-deploy.sh       #   Deploy script
│   │   ├── scenario1-full-stack-teardown.sh     #   Teardown script
│   │   ├── README-deploy.md                     #   Deploy documentation
│   │   └── README-teardown.md                   #   Teardown documentation
│   ├── scenario2/                               # Scenario 2: VKS Metrics Observability
│   │   ├── scenario2-vks-metrics-deploy.sh      #   Deploy script
│   │   ├── scenario2-vks-metrics-teardown.sh    #   Teardown script
│   │   ├── README-deploy.md                     #   Deploy documentation
│   │   ├── README-teardown.md                   #   Teardown documentation
│   │   ├── telegraf-values.yaml                 #   Telegraf Helm values
│   │   ├── prometheus-values.yaml               #   Prometheus Helm values
│   │   ├── grafana-instance.yaml                #   Grafana instance manifest
│   │   ├── grafana-datasource-prometheus.yaml   #   Grafana datasource manifest
│   │   └── grafana-dashboards-k8s.yaml          #   Grafana dashboards manifest
│   ├── scenario3/                               # Scenario 3: ArgoCD Consumption Model
│   │   ├── scenario3-argocd-deploy.sh           #   Deploy script
│   │   ├── scenario3-argocd-teardown.sh         #   Teardown script
│   │   ├── README-deploy.md                     #   Deploy documentation
│   │   ├── README-teardown.md                   #   Teardown documentation
│   │   ├── contour-values.yaml                  #   Contour Helm values
│   │   ├── harbor-values.yaml                   #   Harbor Helm values
│   │   ├── argocd-values.yaml                   #   ArgoCD Helm values
│   │   ├── gitlab-operator-values.yaml          #   GitLab Operator Helm values
│   │   ├── gitlab-runner-values.yaml            #   GitLab Runner Helm values
│   │   ├── argocd-microservices-demo.yaml       #   ArgoCD Application manifest
│   │   └── wildcard.cnf                         #   OpenSSL wildcard cert config
│   ├── sample-create-vpc.yaml                   # Sample VPC manifest
│   ├── sample-vpc-connectivity-profile.yaml     # Sample VPC Connectivity Profile manifest
│   ├── sample-vpc-attachment.yaml               # Sample VPCAttachment manifest
│   ├── sample-create-project-ns.yaml            # Sample Project + RBAC + Namespace manifest
│   ├── sample-nat-rules.yaml                    # Sample NAT rules manifest (optional)
│   ├── sample-create-cluster.yaml               # Sample VKS Cluster manifest
│   ├── sample-vks-functional-test.yaml          # Sample functional test workload manifest
│   └── README.md                                # Examples overview and sample manifest guide
└── tests/
    ├── conftest.py                    # Shared pytest fixtures
    ├── requirements.txt               # Python test dependencies
    ├── test_content.py                # Content-presence tests for the onboarding guide
    ├── test_properties.py             # Property-based tests for guide YAML manifests
    ├── test_scenario1_content.py      # Content-presence tests for Scenario 1 scripts
    ├── test_scenario1_properties.py   # Property-based tests for Scenario 1 scripts
    ├── test_scenario2_content.py      # Content-presence tests for Scenario 2 scripts
    ├── test_scenario2_properties.py   # Property-based tests for Scenario 2 scripts
    ├── test_scenario3_content.py      # Content-presence tests for Scenario 3 scripts
    ├── test_scenario3_properties.py   # Property-based tests for Scenario 3 scripts
    ├── test_gh_actions_deploy_content.py       # Content tests for Scenario 1 workflow
    ├── test_gh_actions_deploy_properties.py    # Property tests for Scenario 1 workflow
    ├── test_gh_actions_scenarios_2_3_content.py    # Content tests for Scenarios 2 & 3 workflows
    ├── test_gh_actions_scenarios_2_3_properties.py # Property tests for Scenarios 2 & 3 workflows
    └── test_workflow_secrets_hardening.py      # Security hardening tests for all workflows
```

## Documentation

| Document | Description |
|---|---|
| [VCF 9 IaC Onboarding Guide](vcf9-iac-onboarding-guide.md) | Full walkthrough of the VCF 9 IaC workflow with annotated manifests, CLI commands, troubleshooting, and an EKS-to-VKS migration mapping |
| [Engineering Workflow](VCF_Engineering_Workflow.md) | Condensed step-by-step engineering workflow |
| [Examples Overview](examples/README.md) | Summary of all scenarios, dependency chain, and deploy/teardown commands |
| [Scenario 1 Deploy README](examples/scenario1/README-deploy.md) | Detailed breakdown of each Scenario 1 deploy phase, expected output, and timing |
| [Scenario 1 Teardown README](examples/scenario1/README-teardown.md) | Detailed breakdown of each Scenario 1 teardown phase with idempotency notes |
| [Scenario 2 Deploy README](examples/scenario2/README-deploy.md) | VKS Metrics Observability deploy documentation |
| [Scenario 2 Teardown README](examples/scenario2/README-teardown.md) | VKS Metrics Observability teardown documentation |
| [Scenario 3 Deploy README](examples/scenario3/README-deploy.md) | ArgoCD Consumption Model deploy documentation (15 phases) |
| [Scenario 3 Teardown README](examples/scenario3/README-teardown.md) | ArgoCD Consumption Model teardown documentation |
| [EKS to VKS Migration Checklist](AWS-EKS-to-VCF-VKS-Migration-Checklist.md) | Pass/fail checklist for validating a migration from AWS EKS to VCF VKS |
| [GitHub Actions Workflows README](.github/workflows/README.md) | Workflow documentation: parameters, triggers, credential retrieval, and troubleshooting for all three scenarios |

## Testing

The test suite validates both the onboarding guide and the automation scripts using pytest and Hypothesis (property-based testing).

### Run tests inside the dev container

```bash
docker exec vcf9-dev pytest tests/ -v
```

### Run tests locally (requires Python 3.10+)

```bash
python -m venv .venv
source .venv/bin/activate  # or .venv\Scripts\activate on Windows
pip install -r tests/requirements.txt
pytest tests/ -v
```

### What the tests cover

- **Content-presence tests** — Verify all required phases, CLI commands, manifest kinds, and reference sections exist in the guide and scripts
- **Property-based tests** — Use Hypothesis to generate random inputs and verify YAML round-trip integrity, placeholder parameterization, API version consistency, heredoc validity, and more

## Key VCF 9 Concepts

| Concept | Description |
|---|---|
| **Context Bridge** | The critical step that switches from global (org-level) to namespace-scoped context, making Cluster API resources visible. Without it, `kubectl get clusters` returns nothing. |
| **generateName** | Supervisor Namespaces use `generateName` instead of `name`, so VCF appends a random 5-character suffix. Scripts must discover the dynamic name after creation. |
| **CCI APIs** | Cloud Consumption Interface — the VCF 9 API layer for Projects, Namespaces, RBAC, and infrastructure resources. |
| **VKS** | VMware Kubernetes Service — managed Kubernetes clusters deployed via Cluster API on a vSphere Supervisor. |

## Environment Variables Reference

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

Optional variables with sensible defaults: `REGION_NAME`, `VPC_NAME`, `RESOURCE_CLASS`, `CPU_LIMIT`, `MEMORY_LIMIT`, `K8S_VERSION`, `SERVICES_CIDR`, `PODS_CIDR`, `VM_CLASS`, `STORAGE_CLASS`, `MIN_NODES`, `MAX_NODES`, and all timeout values.

## License

This project is provided as-is for internal use. See your organization's licensing policies for distribution terms.
