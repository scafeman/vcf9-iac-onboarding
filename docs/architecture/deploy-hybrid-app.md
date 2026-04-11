# Deploy Hybrid App — High-Level Design

## Overview

Deploy Hybrid App demonstrates VM-to-container connectivity within a VCF 9 namespace. A PostgreSQL 16 database runs on a dedicated VM provisioned via VCF VM Service, while a Node.js REST API and Next.js frontend run as containerized workloads in the VKS guest cluster. Both tiers communicate over the NSX VPC private network.

This is the VCF equivalent of running an EC2 database instance alongside EKS containers in the same AWS VPC.

## Architecture Diagram

```mermaid
graph TB
    subgraph "Internet"
        USER[DevOps Engineer<br/>Browser]
    end

    subgraph "VCF 9 Supervisor Namespace"
        subgraph "VM Service"
            PGVM[VirtualMachine: postgresql-vm<br/>Ubuntu 24.04<br/>PostgreSQL 16<br/>Private IP: 10.x.x.x]
            CLOUDINIT[cloud-init Secret<br/>DB user + password + schema]
        end
    end

    subgraph "VKS Guest Cluster"
        subgraph "tanzu-system-ingress"
            ENVOY[Envoy Proxy]
            ENVOYLB[envoy-lb<br/>LoadBalancer<br/>IP: 74.x.x.x]
        end

        subgraph "hybrid-app Namespace"
            API_DEP[Deployment: hybrid-app-api<br/>Node.js Express<br/>scafeman/hybrid-app-api:latest]
            API_SVC[Service: hybrid-app-api<br/>ClusterIP:3001]

            DASH_DEP[Deployment: hybrid-app-dashboard<br/>Next.js Frontend<br/>scafeman/hybrid-app-dashboard:latest]
            DASH_SVC[Service: hybrid-app-dashboard-lb<br/>ClusterIP:80 → 3000]

            INGRESS[Ingress: hybrid-dashboard-sslip-ingress<br/>hybrid-dashboard.IP.sslip.io]
        end
    end

    subgraph "NSX VPC Network"
        VPCNET[Private Network<br/>10.10.0.0/16<br/>VM ↔ Container connectivity]
    end

    USER -->|http://hybrid-dashboard.IP.sslip.io| ENVOYLB
    ENVOYLB --> ENVOY
    ENVOY --> INGRESS
    INGRESS --> DASH_SVC
    DASH_SVC --> DASH_DEP

    DASH_DEP -->|/api/* proxy| API_SVC
    API_SVC --> API_DEP
    API_DEP -->|PostgreSQL:5432<br/>over NSX VPC| PGVM

    CLOUDINIT -.->|bootstrap| PGVM
    PGVM --- VPCNET
    API_DEP --- VPCNET

    style PGVM fill:#336791,color:#fff
    style API_DEP fill:#68a063,color:#fff
    style DASH_DEP fill:#000,color:#fff
    style ENVOYLB fill:#d0021b,color:#fff
    style INGRESS fill:#4a90d9,color:#fff
```

## Component Details

### Data Tier — PostgreSQL VM

| Attribute | Value |
|---|---|
| Resource Type | VirtualMachine (VM Service) |
| OS | Ubuntu 24.04 Server |
| Database | PostgreSQL 16 |
| VM Class | best-effort-medium |
| Network | Private NSX SubnetSet (no public IP) |
| Bootstrap | cloud-init Secret with DB user/password/schema creation |
| Storage | Boot disk (default) |

### Application Tier — Node.js API

| Attribute | Value |
|---|---|
| Resource Type | Kubernetes Deployment |
| Image | `scafeman/hybrid-app-api:latest` |
| Port | 3001 |
| Service Type | ClusterIP |
| DB Connection | Direct TCP to VM private IP:5432 over NSX VPC |
| Health Check | `GET /healthz` |

### Presentation Tier — Next.js Dashboard

| Attribute | Value |
|---|---|
| Resource Type | Kubernetes Deployment |
| Image | `scafeman/hybrid-app-dashboard:latest` |
| Port | 3000 |
| Service Type | ClusterIP (sslip.io mode) / LoadBalancer (legacy) |
| Ingress | `hybrid-dashboard.IP.sslip.io` via shared envoy-lb |
| API Proxy | Next.js rewrites `/api/*` to `hybrid-app-api:3001` |

### Networking

| Path | Protocol | Details |
|---|---|---|
| User → Dashboard | HTTP/HTTPS | Via sslip.io Ingress on envoy-lb |
| Dashboard → API | HTTP | ClusterIP service within cluster |
| API → PostgreSQL VM | TCP:5432 | Over NSX VPC private network (cross-tier) |

## Key Design Decisions

1. **VM-to-container connectivity** — The PostgreSQL VM and VKS worker nodes share the same NSX VPC, enabling direct TCP communication without NAT or VPN. This is the same pattern as EC2 + EKS in the same AWS VPC.

2. **cloud-init bootstrap** — The VM is fully configured at boot time via cloud-init: PostgreSQL installation, `pg_hba.conf` configuration for remote access, user/database creation. No SSH required after provisioning.

3. **ClusterIP + sslip.io Ingress** — When `USE_SSLIP_DNS=true`, the dashboard uses ClusterIP and routes through the shared envoy-lb Ingress. No additional public IP is consumed.

4. **Separate VM lifecycle** — The PostgreSQL VM is provisioned in the supervisor namespace (not the guest cluster). It persists independently of the VKS cluster and can be managed via `kubectl get virtualmachine`.
