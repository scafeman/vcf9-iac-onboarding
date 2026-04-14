# VCF 9 Architecture Diagrams

High-level design documents for each VCF 9 deployment pattern. Each document includes a Mermaid architecture diagram, component descriptions, networking details, and AWS equivalence mapping.

These documents are intended for DevOps engineers migrating from AWS EKS to VCF 9 VKS.

## Deployment Patterns

| Pattern | Document | AWS Equivalent |
|---|---|---|
| Deploy Cluster | [deploy-cluster.md](deploy-cluster.md) | EKS Cluster + Add-ons |
| Deploy Metrics | [deploy-metrics.md](deploy-metrics.md) | CloudWatch + Grafana |
| Deploy GitOps | [deploy-gitops.md](deploy-gitops.md) | ECR + CodePipeline + ArgoCD |
| Deploy Hybrid App | [deploy-hybrid-app.md](deploy-hybrid-app.md) | EC2 + EKS in same VPC |
| Deploy Managed DB App | [deploy-managed-db-app.md](deploy-managed-db-app.md) | EKS + RDS + Secrets Manager |
| Deploy Secrets Demo | [deploy-secrets-demo.md](deploy-secrets-demo.md) | Secrets Manager + EKS |
| Deploy HA VM App | [deploy-ha-vm-app.md](deploy-ha-vm-app.md) | 2× EC2 + 2× ALB + RDS |
| Deploy Knative | [deploy-knative.md](deploy-knative.md) | Lambda + API Gateway + RDS |
| Deploy Bastion VM | [deploy-bastion-vm.md](deploy-bastion-vm.md) | EC2 Bastion + Security Groups |
