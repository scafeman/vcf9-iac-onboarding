# Getting Started

This guide walks you through setting up the VCF 9 IaC Onboarding Toolkit — from prerequisites to deploying your first VKS cluster and tearing it down.

For a high-level overview of the project, see the [main README](README.md).

## Prerequisites

- **Docker and Docker Compose** — the dev container runs all tooling so you don't need to install VCF CLI or kubectl locally
- **A VCF 9 / VCFA environment** with API access (Supervisor enabled, at least one availability zone configured)
- **An API token** from the VCFA portal (Build & Deploy → Identity and Access Management → API Tokens)

## Clone and Configure

```bash
git clone https://github.com/scafeman/vcf9-iac-onboarding.git
cd vcf9-iac-onboarding
```

Create a `.env` file at the project root with your environment-specific values:

```env
# --- API Token (from VCF Automation portal) ---
VCF_API_TOKEN=<your-api-token>

# --- VCFA Connection ---
VCFA_ENDPOINT=<vcfa-hostname>
TENANT_NAME=<sso-tenant>
CONTEXT_NAME=<cli-context-name>

# --- Project & Namespace ---
PROJECT_NAME=<project-name>
USER_IDENTITY=<sso-user>
NAMESPACE_PREFIX=<namespace-prefix->

# --- Infrastructure (Zone) ---
ZONE_NAME=<availability-zone>

# --- VKS Cluster ---
CLUSTER_NAME=<cluster-name>
CONTENT_LIBRARY_ID=<content-library-id>

# --- VKS Standard Packages (similar to EKS Add-ons — curated Kubernetes extensions) ---
# These are used by Deploy Cluster (autoscaler), Deploy Metrics, and Deploy GitOps
PACKAGE_NAMESPACE=tkg-packages
PACKAGE_REPO_NAME=tkg-packages
PACKAGE_REPO_URL=projects.packages.broadcom.com/vsphere/supervisor/vks-standard-packages/3.6.0-20260211/vks-standard-packages:3.6.0-20260211

# --- GitHub Actions Runner ---
RUNNER_TOKEN=<your-runner-registration-token>
REPO_URL=https://github.com/<OWNER>/<REPO>
GITHUB_PAT=<your-github-personal-access-token>
```

Replace all `<placeholder>` values with your environment-specific settings. See the [Environment Variables Reference](ENVIRONMENT-VARIABLES.md) for the full variable reference including optional variables with defaults.

## Build and Start the Dev Container

```bash
docker compose up -d --build
```

This builds an Ubuntu 24.04 container with VCF CLI (v9.0.2) and kubectl (v1.33.0) pre-installed. The `.env` file is automatically loaded by Docker Compose and passed into the container.

## Deploy Each Stack

### Deploy Cluster

Provisions a VCF project, supervisor namespace, VKS cluster with autoscaling workers, and validates the stack with a test workload.

```bash
docker exec vcf9-dev bash examples/deploy-cluster/deploy-cluster.sh
```

Typical deployment time: **5–18 minutes**.

See the [Deploy Cluster README](examples/deploy-cluster/README-deploy.md) for a detailed breakdown of each phase.

### Deploy Metrics

Installs Telegraf, Prometheus, and Grafana on the VKS cluster for metrics collection and dashboards.

```bash
docker exec vcf9-dev bash examples/deploy-metrics/deploy-metrics.sh
```

Typical deployment time: **3–5 minutes**. Requires a running VKS cluster from Deploy Cluster.

See the [Deploy Metrics README](examples/deploy-metrics/README-deploy.md) for details.

### Deploy GitOps

Installs Harbor, ArgoCD, GitLab, and deploys the Google Microservices Demo (Online Boutique) as a sample ArgoCD-managed application.

```bash
docker exec vcf9-dev bash examples/deploy-gitops/deploy-gitops.sh
```

Typical deployment time: **15–25 minutes**. Requires a running VKS cluster from Deploy Cluster.

See the [Deploy GitOps README](examples/deploy-gitops/README-deploy.md) for details.

### Deploy Hybrid App

Provisions a PostgreSQL VM via VCF VM Service and deploys a Next.js/Node.js application on VKS, demonstrating VM-to-container connectivity over NSX VPC.

```bash
docker exec vcf9-dev bash examples/deploy-hybrid-app/deploy-hybrid-app.sh
```

Typical deployment time: **8–12 minutes**. Requires a running VKS cluster from Deploy Cluster.

See the [Deploy Hybrid App README](examples/deploy-hybrid-app/README-deploy.md) for details.

## Teardown

Each deployment has a corresponding teardown script. Teardown scripts are fully idempotent — safe to run multiple times.

### Teardown Hybrid App

```bash
docker exec vcf9-dev bash examples/deploy-hybrid-app/teardown-hybrid-app.sh
```

Typical teardown time: **2–4 minutes**.

### Teardown GitOps

```bash
docker exec vcf9-dev bash examples/deploy-gitops/teardown-gitops.sh
```

Typical teardown time: **3–5 minutes**.

### Teardown Metrics

```bash
docker exec vcf9-dev bash examples/deploy-metrics/teardown-metrics.sh
```

Typical teardown time: **1–3 minutes**.

### Teardown Cluster

```bash
docker exec vcf9-dev bash examples/deploy-cluster/teardown-cluster.sh
```

Typical teardown time: **1–6 minutes**. This removes the VKS cluster, supervisor namespace, and project.

> **Teardown order matters.** If you deployed multiple stacks, tear them down in reverse order: Hybrid App / GitOps / Metrics → Cluster. The [Teardown workflow](.github/workflows/README.md) handles this automatically with selective boolean inputs.

## GitHub Actions Setup

The toolkit includes GitHub Actions workflows for automated CI/CD deployment. Workflows run on a self-hosted runner built from `Dockerfile.runner`.

### 1. Build the runner image

```bash
docker build -f Dockerfile.runner -t vcf9-runner .
```

### 2. Register the runner

Add your runner registration token and repo URL to `.env`:

```env
RUNNER_TOKEN=<your-runner-registration-token>
REPO_URL=https://github.com/<OWNER>/<REPO>
GITHUB_PAT=<your-github-personal-access-token>
```

### 3. Start the runner with Docker Compose

```bash
docker compose --profile runner up -d
```

The runner registers itself with GitHub and begins polling for workflow jobs. See the [Workflows README](.github/workflows/README.md) for full parameter documentation, credential retrieval instructions, and troubleshooting.
