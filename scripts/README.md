# VCF 9 IaC — Trigger Scripts

## Overview

This folder contains companion trigger scripts that dispatch GitHub Actions workflows via the `repository_dispatch` API. Each script maps to a deploy or teardown workflow and sends a `client_payload` with the specified parameters.

These scripts are an alternative to triggering workflows from the GitHub Actions UI (`workflow_dispatch`). They are useful for:

- Automating deployments from the command line or CI/CD pipelines
- Passing parameters programmatically without navigating the GitHub UI
- Integrating VCF deployments into existing automation toolchains

All scripts require a GitHub Personal Access Token (PAT) with `repo` scope and the repository name in `OWNER/REPO` format.

| Script | Workflow | Event Type | Description |
|---|---|---|---|
| `trigger-deploy.sh` | `deploy-vks.yml` | `deploy-vks` | Provisions VKS cluster with autoscaling, packages, and functional validation |
| `trigger-deploy-metrics.sh` | `deploy-vks-metrics.yml` | `deploy-vks-metrics` | Deploys Telegraf, Prometheus, and Grafana on the VKS cluster |
| `trigger-deploy-argocd.sh` | `deploy-argocd.yml` | `deploy-argocd` | Deploys Harbor, ArgoCD, GitLab, and Microservices Demo |
| `trigger-deploy-hybrid-app.sh` | `deploy-hybrid-app.yml` | `deploy-hybrid-app` | Provisions PostgreSQL VM and deploys Next.js/Node.js app on VKS |
| `trigger-deploy-bastion-vm.sh` | `deploy-bastion-vm.yml` | `deploy-bastion-vm` | Deploys SSH jump host VM with source-IP-restricted LoadBalancer |
| `trigger-deploy-managed-db-app.sh` | `deploy-managed-db-app.yml` | `deploy-managed-db-app` | Provisions DSM PostgresCluster and deploys Next.js/Node.js app with vault-injected credentials |
| `trigger-deploy-secrets-demo.sh` | `deploy-secrets-demo.yml` | `deploy-secrets-demo` | Deploys VCF Secret Store demo with vault-injected Redis and PostgreSQL |
| `trigger-teardown.sh` | `teardown.yml` | `teardown` | Selectively tears down deployment stacks in reverse dependency order |

## Prerequisites

- **GitHub PAT** with `repo` scope — generate at **Settings → Developer settings → Personal access tokens**
- **bash** shell (Linux, macOS, or Windows with Git Bash / WSL)
- **curl** and **jq** installed
- The target repository must have the corresponding workflow file and a registered self-hosted runner

## Usage Pattern

All scripts follow the same pattern:

```bash
./scripts/trigger-<workflow>.sh \
  --repo OWNER/REPO \
  --token ghp_xxxxxxxxxxxx \
  --<required-param> value \
  --<optional-param> value
```

Each script prints the `curl` command it sends and the GitHub API response. A successful dispatch returns HTTP 204.

Make scripts executable before first use:

```bash
chmod +x scripts/*.sh
```

---

## Deploy VKS Cluster (`trigger-deploy.sh`)

Triggers the full VKS cluster provisioning workflow.

```bash
./scripts/trigger-deploy.sh \
  --repo myorg/vcf9-iac \
  --token ghp_xxxxxxxxxxxx \
  --project-name my-project-01 \
  --cluster-name my-project-01-clus-01 \
  --namespace-prefix my-project-01-ns-
```

**Required:** `--repo`, `--token`, `--project-name`, `--cluster-name`, `--namespace-prefix`

**Optional:** `--environment`, `--vpc-name`, `--region-name`, `--zone-name`, `--resource-class`, `--user-identity`, `--content-library-id`, `--k8s-version`, `--vm-class`, `--storage-class`, `--min-nodes`, `--max-nodes`, `--containerd-volume-size`, `--os-name`, `--os-version`, `--control-plane-replicas`, `--node-pool-name`, `--vcfa-endpoint`, `--tenant-name`

---

## Deploy Metrics (`trigger-deploy-metrics.sh`)

Triggers the VKS Metrics Observability stack deployment.

```bash
./scripts/trigger-deploy-metrics.sh \
  --repo myorg/vcf9-iac \
  --token ghp_xxxxxxxxxxxx \
  --cluster-name my-project-01-clus-01
```

**Required:** `--repo`, `--token`, `--cluster-name`

**Optional:** `--telegraf-version`, `--environment`, `--domain`, `--kubeconfig-path`, `--package-namespace`, `--package-repo-url`

---

## Deploy ArgoCD (`trigger-deploy-argocd.sh`)

Triggers the ArgoCD Consumption Model stack deployment.

```bash
./scripts/trigger-deploy-argocd.sh \
  --repo myorg/vcf9-iac \
  --token ghp_xxxxxxxxxxxx \
  --cluster-name my-project-01-clus-01
```

**Required:** `--repo`, `--token`, `--cluster-name`

**Optional:** `--environment`, `--domain`, `--kubeconfig-path`, `--harbor-version`, `--argocd-version`, `--gitlab-operator-version`, `--gitlab-runner-version`

---

## Deploy Hybrid App (`trigger-deploy-hybrid-app.sh`)

Triggers the Infrastructure Asset Tracker deployment with a PostgreSQL VM.

```bash
./scripts/trigger-deploy-hybrid-app.sh \
  --repo myorg/vcf9-iac \
  --token ghp_xxxxxxxxxxxx \
  --cluster-name my-project-01-clus-01 \
  --supervisor-namespace my-project-ns-xxxxx \
  --project-name my-project-01 \
  --vm-content-library-id cl-97acf13b5e2909643
```

**Required:** `--repo`, `--token`, `--cluster-name`

**Optional:** `--environment`, `--supervisor-namespace`, `--project-name`, `--vm-class`, `--vm-image`, `--vm-content-library-id`, `--postgres-user`, `--postgres-password`, `--postgres-db`, `--vm-name`, `--app-namespace`, `--container-registry`, `--image-tag`, `--vcfa-endpoint`, `--tenant-name`

---

## Deploy Bastion VM (`trigger-deploy-bastion-vm.sh`)

Triggers the SSH jump host VM deployment.

```bash
./scripts/trigger-deploy-bastion-vm.sh \
  --repo myorg/vcf9-iac \
  --token ghp_xxxxxxxxxxxx \
  --supervisor-namespace my-project-ns-xxxxx
```

**Required:** `--repo`, `--token`, `--supervisor-namespace`

**Optional:** `--allowed-ssh-sources`, `--vm-class`, `--vm-image`, `--vm-name`, `--storage-class`, `--ssh-username`, `--ssh-public-key`, `--boot-disk-size`, `--data-disk-size`, `--vm-network`, `--vcfa-endpoint`, `--tenant-name`

---

## Deploy Managed DB App (`trigger-deploy-managed-db-app.sh`)

Triggers the DSM PostgresCluster Infrastructure Asset Tracker deployment with vault-injected credentials.

```bash
./scripts/trigger-deploy-managed-db-app.sh \
  --repo myorg/vcf9-iac \
  --token ghp_xxxxxxxxxxxx \
  --cluster-name my-project-01-clus-01 \
  --supervisor-namespace my-project-ns-xxxxx \
  --dsm-infra-policy shared-dsm-01 \
  --dsm-storage-policy NFS
```

**Required:** `--repo`, `--token`, `--cluster-name`

**Optional:** `--supervisor-namespace`, `--project-name`, `--dsm-infra-policy`, `--dsm-vm-class`, `--dsm-storage-policy`, `--dsm-storage-space`, `--postgres-version`, `--postgres-db`, `--admin-password`, `--app-namespace`, `--container-registry`, `--image-tag`, `--vcfa-endpoint`, `--tenant-name`

---

## Deploy Secrets Demo (`trigger-deploy-secrets-demo.sh`)

Triggers the VCF Secret Store integration demo deployment.

```bash
./scripts/trigger-deploy-secrets-demo.sh \
  --repo myorg/vcf9-iac \
  --token ghp_xxxxxxxxxxxx \
  --cluster-name my-project-01-clus-01
```

**Required:** `--repo`, `--token`, `--cluster-name`

**Optional:** `--environment`, `--secret-store-ip`, `--supervisor-namespace`, `--redis-password`, `--postgres-user`, `--postgres-password`, `--postgres-db`, `--namespace`, `--container-registry`, `--image-name`, `--image-tag`, `--vcfa-endpoint`, `--tenant-name`

---

## Teardown (`trigger-teardown.sh`)

Triggers selective teardown of deployment stacks in reverse dependency order.

```bash
# Tear down everything
./scripts/trigger-teardown.sh \
  --repo myorg/vcf9-iac \
  --token ghp_xxxxxxxxxxxx \
  --cluster-name my-project-01-clus-01

# Tear down only Managed DB App (skip everything else)
./scripts/trigger-teardown.sh \
  --repo myorg/vcf9-iac \
  --token ghp_xxxxxxxxxxxx \
  --cluster-name my-project-01-clus-01 \
  --teardown-gitops false \
  --teardown-metrics false \
  --teardown-hybrid-app false \
  --teardown-secrets-demo false \
  --teardown-bastion-vm false \
  --teardown-cluster false
```

**Required:** `--repo`, `--token`, `--cluster-name`

**Optional:** `--teardown-gitops` (default: true), `--teardown-metrics` (default: true), `--teardown-cluster` (default: true), `--teardown-hybrid-app` (default: true), `--teardown-secrets-demo` (default: true), `--teardown-bastion-vm` (default: true), `--teardown-managed-db-app` (default: true), `--domain`, `--kubeconfig-path`, `--vcfa-endpoint`, `--tenant-name`

---

## Troubleshooting

### HTTP 404 — Not Found

- Verify the `--repo` value is correct (`OWNER/REPO` format)
- Verify the PAT has `repo` scope
- Verify the workflow file exists on the default branch

### HTTP 422 — Unprocessable Entity

- The `event_type` in the script doesn't match the `repository_dispatch` types in the workflow file
- Check for typos in the event type string

### Workflow not triggered

- Verify the self-hosted runner is online: **Settings → Actions → Runners**
- Check that the workflow file has `repository_dispatch` as a trigger
- If the workflow requires environment approval, check **Actions → workflow run → Review deployments**
