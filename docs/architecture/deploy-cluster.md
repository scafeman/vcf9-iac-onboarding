# Deploy Cluster — High-Level Design

## Overview

Deploy Cluster provisions a production-ready VKS (VMware Kubernetes Service) cluster from scratch on VCF 9 private cloud infrastructure. It is the foundation for all other deployment patterns — every container-based pattern depends on a running VKS cluster created by this workflow.

This is the VCF equivalent of creating an AWS EKS cluster with managed node groups, EBS CSI driver, ALB controller, and cluster autoscaler.

## Architecture Diagram

```mermaid
graph TB
    subgraph "Internet"
        USER[DevOps Engineer<br/>Browser / kubectl]
        SSLIP[sslip.io DNS<br/>Magic DNS Service]
        LE[Let's Encrypt<br/>ACME CA]
    end

    subgraph "VCF 9 Platform"
        subgraph "VCFA Control Plane"
            VCFA[VCFA Endpoint<br/>CCI API Server]
            CCI[Cloud Consumption Interface<br/>Projects, Namespaces, RBAC]
        end

        subgraph "Supervisor Cluster"
            subgraph "Project: my-project-01"
                NS[SupervisorNamespace<br/>my-project-01-ns-xxxxx]
                PRB[ProjectRoleBinding<br/>admin → user-identity]
            end
        end

        subgraph "NSX Networking"
            VPC[NSX VPC<br/>10.10.0.0/16]
            TGW[Transit Gateway<br/>North-South routing]
            EXTIP[External IP Pool<br/>Public IPs for LoadBalancers]
        end

        subgraph "VKS Guest Cluster"
            subgraph "Control Plane"
                CP[Control Plane Node<br/>1 or 3 replicas]
            end

            subgraph "Worker Pool: node-pool-01"
                W1[Worker Node 1<br/>best-effort-large]
                W2[Worker Node 2<br/>best-effort-large]
                WN[Worker Node N<br/>autoscaler: 2–10]
            end

            subgraph "System Namespaces"
                KUBE[kube-system<br/>CoreDNS, kube-proxy]
                COREDNS[CoreDNS<br/>+ sslip.io forwarding rule]
            end

            subgraph "tkg-packages Namespace"
                AUTOSCALER[Cluster Autoscaler<br/>VKS Standard Package]
                CERTMGR[cert-manager<br/>VKS Standard Package]
                CONTOUR[Contour<br/>VKS Standard Package]
            end

            subgraph "tanzu-system-ingress Namespace"
                ENVOY[Envoy Proxy<br/>Contour data plane]
                ENVOYLB[envoy-lb Service<br/>type: LoadBalancer]
            end

            subgraph "ClusterIssuers"
                LEPROD[letsencrypt-prod<br/>ACME Production]
                LESTAG[letsencrypt-staging<br/>ACME Staging]
            end

            subgraph "default Namespace — Functional Test"
                PVC[PersistentVolumeClaim<br/>vks-test-pvc / 1Gi / nfs]
                DEPLOY[Deployment: vks-test-app<br/>scafeman/vks-test-app:latest]
                LBSVC[Service: vks-test-lb<br/>type: LoadBalancer]
                INGRESS[Ingress: vks-test-sslip-ingress<br/>test.IP.sslip.io]
            end
        end
    end

    USER -->|HTTPS| VCFA
    VCFA --> CCI
    CCI --> NS
    CCI --> PRB

    NS --> CP
    CP --> W1
    CP --> W2
    CP --> WN

    AUTOSCALER -->|scales| W1
    AUTOSCALER -->|scales| WN

    CERTMGR -->|issues certs via| LE
    COREDNS -->|forwards sslip.io → 8.8.8.8| SSLIP

    ENVOYLB -->|External IP from| EXTIP
    LBSVC -->|External IP from| EXTIP

    USER -->|http://test.IP.sslip.io| ENVOYLB
    ENVOYLB --> ENVOY
    ENVOY --> INGRESS
    INGRESS --> DEPLOY

    USER -->|http://EXTERNAL_IP| LBSVC
    LBSVC --> DEPLOY
    DEPLOY --> PVC

    VPC --> TGW

    style VCFA fill:#4a90d9,color:#fff
    style NS fill:#f5a623,color:#fff
    style CP fill:#7ed321,color:#fff
    style CERTMGR fill:#9013fe,color:#fff
    style CONTOUR fill:#9013fe,color:#fff
    style ENVOYLB fill:#d0021b,color:#fff
    style LBSVC fill:#d0021b,color:#fff
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
| 6. Functional Test | Deploys test app, verifies PVC + LB + HTTP + sslip.io | ~60s |

**Total: ~12–18 minutes** from zero to a fully validated VKS cluster.

## Key Design Decisions

1. **Single envoy-lb for all patterns** — All deployment patterns share one Contour envoy-lb LoadBalancer IP. Each pattern creates its own Ingress with a unique sslip.io hostname. This avoids wasting public IPs.

2. **CoreDNS sslip.io forwarding** — cert-manager's HTTP-01 solver needs to resolve sslip.io hostnames from inside the cluster. The CoreDNS forwarding rule sends `sslip.io` queries to 8.8.8.8 and 1.1.1.1 instead of the cluster's internal DNS.

3. **Dual access for functional test** — deploy-cluster keeps both the raw LoadBalancer IP (for NSX validation) and the envoy-lb Ingress (for sslip.io). Other patterns use only the envoy-lb Ingress.

4. **Idempotent provisioning** — Every phase checks if resources already exist before creating them. The script can be re-run safely after partial failures.
