# VCF 9 IaC Onboarding — Example Scenarios

This folder contains three automation scenarios for deploying workloads on VCF 9 VKS clusters. Each scenario builds on the previous one.

## Dependency Chain

```
Scenario 1: Full Stack Deploy (VKS cluster provisioning)
  ├─► Scenario 2: VKS Metrics Observability (monitoring stack)
  └─► Scenario 3: Self-Contained ArgoCD Consumption Model (GitOps + CI/CD)
```

Scenarios 2 and 3 both require a running VKS cluster provisioned by Scenario 1. They are independent of each other and can be deployed in any order (or only one of them).

---

## Scenario 1: Full Stack Deploy

Provisions a complete VKS cluster from scratch using the VCF CLI. Handles project creation, RBAC, Supervisor Namespace, VPC networking, and cluster lifecycle — from zero to a running Kubernetes cluster with LoadBalancer support and `nfs` storageClass.

| | |
|---|---|
| Folder | [`scenario1/`](scenario1/) |
| Deploy | `bash examples/scenario1/scenario1-full-stack-deploy.sh` |
| Teardown | `bash examples/scenario1/scenario1-full-stack-teardown.sh` |
| Output | Running VKS cluster + admin kubeconfig file |

## Scenario 2: VKS Metrics Observability

Installs a monitoring stack on an existing VKS cluster: Telegraf (metrics collection), Prometheus (metrics storage), and Grafana (dashboards). Uses VCF Supervisor packages for Telegraf and Prometheus, and Helm for the Grafana Operator.

| | |
|---|---|
| Folder | [`scenario2/`](scenario2/) |
| Depends on | Scenario 1 (running VKS cluster) |
| Deploy | `bash examples/scenario2/scenario2-vks-metrics-deploy.sh` |
| Teardown | `bash examples/scenario2/scenario2-vks-metrics-teardown.sh` |
| Output | Grafana dashboards with Kubernetes cluster metrics |

## Scenario 3: Self-Contained ArgoCD Consumption Model

Installs a full GitOps and CI/CD stack entirely from Helm charts — no Supervisor platform services required. Deploys Contour (ingress), Harbor (container registry), ArgoCD (GitOps), GitLab (CI/CD), and the Google Microservices Demo (Online Boutique) as a sample ArgoCD-managed application.

| | |
|---|---|
| Folder | [`scenario3/`](scenario3/) |
| Depends on | Scenario 1 (running VKS cluster with LoadBalancer + nfs storageClass) |
| Deploy | `bash examples/scenario3/scenario3-argocd-deploy.sh` |
| Teardown | `bash examples/scenario3/scenario3-argocd-teardown.sh` |
| Output | Harbor, GitLab, ArgoCD, and Online Boutique accessible via Contour ingress |

---

## Additional Resources

| Document | Description |
|---|---|
| [AWS EKS to VCF VKS Migration Checklist](AWS-EKS-to-VCF-VKS-Migration-Checklist.md) | Pass/fail checklist for validating a migration from AWS EKS to VCF VKS |
