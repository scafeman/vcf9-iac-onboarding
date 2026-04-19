# Deploy Cluster — High-Level Design

## Overview

Deploy Cluster provisions a production-ready VKS (vSphere Kubernetes Service) cluster from scratch on VCF 9 private cloud infrastructure. It is the foundation for all other deployment patterns — every container-based pattern depends on a running VKS cluster created by this workflow.

This is the VCF equivalent of creating an AWS EKS cluster with managed node groups, EBS CSI driver, ALB controller, and cluster autoscaler.

## Architecture Diagram

```mermaid
graph TB
    subgraph "Internet"
        USER[DevOps Engineer<br/>Browser / kubectl]
    end

    subgraph "VCF 9 Control Plane"
        VCFA[VCFA Endpoint<br/>CCI API Server]
        NS[SupervisorNamespace<br/>my-project-01-ns-xxxxx]
    end

    subgraph "VKS Guest Cluster"
        subgraph "Control Plane + Workers"
            CP[Control Plane<br/>1 or 3 nodes]
            W1[Worker 1<br/>best-effort-large]
            W2[Worker 2<br/>best-effort-large]
            WN[Worker N<br/>autoscaler: 2–10]
        end

        subgraph "Infrastructure Packages — tkg-packages"
            AUTOSCALER[Cluster Autoscaler<br/>VKS Standard Package]
            CERTMGR[cert-manager<br/>VKS Standard Package]
            CONTOUR[Contour + Envoy<br/>VKS Standard Package]
        end

        subgraph "Ingress — tanzu-system-ingress"
            ENVOYLB[envoy-lb Service<br/>type: LoadBalancer<br/>External IP: 74.x.x.x]
        end

        subgraph "TLS — ClusterIssuers"
            LEPROD[letsencrypt-prod<br/>ACME Production]
            LESTAG[letsencrypt-staging<br/>ACME Staging]
        end

        subgraph "Node DaemonSets — kube-system"
            DNSPATCH[node-dns-patcher<br/>resolvectl: 8.8.8.8, 1.1.1.1]
            COREDNS[CoreDNS<br/>+ sslip.io forwarding]
        end

        subgraph "Functional Test — default namespace"
            PVC[PVC: vks-test-pvc<br/>1Gi / nfs]
            DEPLOY[Deployment: vks-test-app<br/>scafeman/vks-test-app:latest]
            LBSVC[Service: vks-test-lb<br/>type: LoadBalancer]
            INGRESS[Ingress: vks-test-sslip-ingress<br/>test.IP.sslip.io]
        end
    end

    USER -->|HTTPS / API Token| VCFA
    VCFA -->|provisions| NS
    NS -->|creates| CP

    CP --> W1
    CP --> W2
    CP --> WN
    AUTOSCALER -->|scales 2–10| WN

    CERTMGR -->|issues certs via| LEPROD
    CONTOUR --> ENVOYLB

    USER -->|http://test.IP.sslip.io| ENVOYLB
    ENVOYLB --> INGRESS
    INGRESS --> DEPLOY

    USER -->|http://EXTERNAL_IP| LBSVC
    LBSVC --> DEPLOY
    DEPLOY --> PVC

    style VCFA fill:#4a90d9,color:#fff
    style NS fill:#f5a623,color:#fff
    style CP fill:#7ed321,color:#fff
    style CERTMGR fill:#9013fe,color:#fff
    style CONTOUR fill:#9013fe,color:#fff
    style AUTOSCALER fill:#9013fe,color:#fff
    style ENVOYLB fill:#d0021b,color:#fff
    style LBSVC fill:#d0021b,color:#fff
    style DNSPATCH fill:#336791,color:#fff
    style COREDNS fill:#336791,color:#fff
```

## Component Details

### VCF Control Plane

| Component | Purpose | AWS Equivalent |
|---|---|---|
| VCFA Endpoint | API gateway for all VCF operations | AWS API Gateway / EKS API |
| CCI (Cloud Consumption Interface) | Project, Namespace, and RBAC management | IAM + Organizations |
| Project | Governance boundary for resources | AWS Account / OU |
| SupervisorNamespace | Resource-scoped Kubernetes namespace with compute/storage/network quotas | EKS Namespace + Resource Quotas |
| ProjectRoleBinding | RBAC grant (admin, edit, view) | IAM Role Binding |

### VKS Cluster

| Component | Purpose | Configuration |
|---|---|---|
| Control Plane | Kubernetes API server, etcd, scheduler, controller-manager | 1 node (dev) or 3 nodes (HA) |
| Worker Pool | Application workload nodes | best-effort-large VMs, autoscaler 2–10 |
| Cluster Autoscaler | Automatic node scaling based on pod resource demands | VKS Standard Package |
| CoreDNS | Cluster DNS with sslip.io forwarding rule | Forwards `sslip.io` queries to 8.8.8.8, 1.1.1.1 |

### Infrastructure Packages (tkg-packages)

| Package | Purpose | AWS Equivalent |
|---|---|---|
| cert-manager | X.509 certificate lifecycle management | ACM (AWS Certificate Manager) |
| Contour | Envoy-based ingress controller | ALB Ingress Controller |
| Cluster Autoscaler | Node pool auto-scaling | EKS Managed Node Group autoscaling |

### Networking

| Component | Purpose | Details |
|---|---|---|
| NSX VPC | Network isolation boundary | Private CIDR 10.10.0.0/16 |
| Transit Gateway | North-South routing between VPC and external networks | Connects VPC to physical network |
| External IP Pool | Public IPs for LoadBalancer services | Auto-allocated by NSX |
| envoy-lb | Shared Contour ingress LoadBalancer | Single public IP for all Ingress routes |
| sslip.io | Magic DNS — resolves `*.IP.sslip.io` to IP | No DNS provider needed |

### TLS / Certificate Management

| Component | Purpose | Details |
|---|---|---|
| cert-manager | Watches Ingress annotations, requests certificates from ACME | VKS Standard Package |
| ClusterIssuer (prod) | Let's Encrypt production endpoint | Trusted certificates, rate-limited |
| ClusterIssuer (staging) | Let's Encrypt staging endpoint | Untrusted certificates, no rate limit |
| HTTP-01 Challenge | Domain validation via HTTP | Requires port 80 accessible from internet |
| CoreDNS sslip.io rule | Forwards sslip.io queries to public DNS | Required for cert-manager self-checks |

## Provisioning Phases

| Phase | What Happens | Duration |
|---|---|---|
| 1. Context Creation | VCF CLI authenticates to VCFA | ~5s |
| 2. Project & Namespace | Creates Project, RBAC, SupervisorNamespace | ~10s |
| 3. Context Bridge | Switches to namespace-scoped context | ~30s |
| 4. VKS Cluster | Applies Cluster API manifest, waits for Provisioned | ~8–12 min |
| 5. Kubeconfig | Retrieves admin kubeconfig, verifies API access | ~30s |
| 5a. Package Repo | Registers VKS standard package repository | ~30s |
| 5b. Cluster Autoscaler | Installs and configures autoscaler package | ~60s |
| 5g. cert-manager | Installs cert-manager VKS package | ~60s |
| 5h. Contour + envoy-lb | Installs Contour, creates envoy-lb LoadBalancer, patches CoreDNS | ~90s |
| 5i. ClusterIssuers | Creates Let's Encrypt prod + staging ClusterIssuers | ~30s |
| 5j. Node DNS Patcher | Deploys DaemonSet to configure systemd-resolved with public DNS on each node | ~15s |
| 6. Functional Test | Deploys test app, verifies PVC + LB + HTTP + sslip.io | ~60s |

**Total: ~12–18 minutes** from zero to a fully validated VKS cluster.

## Key Design Decisions

1. **Single envoy-lb for all patterns** — All deployment patterns share one Contour envoy-lb LoadBalancer IP. Each pattern creates its own Ingress with a unique sslip.io hostname. This avoids wasting public IPs.

2. **CoreDNS sslip.io forwarding** — cert-manager's HTTP-01 solver needs to resolve sslip.io hostnames from inside the cluster. The CoreDNS forwarding rule sends `sslip.io` queries to 8.8.8.8 and 1.1.1.1 instead of the cluster's internal DNS.

3. **Dual access for functional test** — deploy-cluster keeps both the raw LoadBalancer IP (for NSX validation) and the envoy-lb Ingress (for sslip.io). Other patterns use only the envoy-lb Ingress.

4. **Idempotent provisioning** — Every phase checks if resources already exist before creating them. The script can be re-run safely after partial failures.

5. **Node DNS Patcher DaemonSet** — VKS nodes inherit corporate DNS from the Supervisor Cluster, which can't resolve sslip.io. The `node-dns-patcher` DaemonSet uses `nsenter` + `resolvectl` to add public DNS servers (8.8.8.8, 1.1.1.1) to `systemd-resolved` on each node, enabling kubelet/containerd to resolve sslip.io hostnames for container image pulls.
