# Deploy HA VM App — High-Level Design

## Overview

Deploy HA VM App provisions a traditional high-availability three-tier application entirely on VCF VM Service VMs — no containers involved. Two web-tier VMs run Next.js behind a VirtualMachineService LoadBalancer, two API-tier VMs run Express behind another LoadBalancer, and a DSM-managed PostgresCluster provides the database tier.

This is the VCF equivalent of deploying a classic HA application on AWS with 2× EC2 (web) + ALB + 2× EC2 (API) + ALB + RDS PostgreSQL Multi-AZ.

## Architecture Diagram

```mermaid
graph TB
    subgraph "Internet"
        USER[DevOps Engineer<br/>Browser]
    end

    subgraph "VCF 9 Supervisor Namespace"
        subgraph "Web Tier"
            WEBLB[VirtualMachineService: ha-web-lb<br/>type: LoadBalancer<br/>External IP: 74.x.x.x<br/>Port 80 → 3000]
            WEB1[VirtualMachine: web-vm-01<br/>Ubuntu 24.04<br/>Next.js Frontend<br/>Port 3000]
            WEB2[VirtualMachine: web-vm-02<br/>Ubuntu 24.04<br/>Next.js Frontend<br/>Port 3000]
        end

        subgraph "API Tier"
            APILB[VirtualMachineService: ha-api-lb<br/>type: LoadBalancer<br/>Internal LB<br/>Port 3001]
            API1[VirtualMachine: api-vm-01<br/>Ubuntu 24.04<br/>Express API Server<br/>Port 3001]
            API2[VirtualMachine: api-vm-02<br/>Ubuntu 24.04<br/>Express API Server<br/>Port 3001]
        end

        subgraph "Database Tier"
            DSM[PostgresCluster: pg-clus-01<br/>PostgreSQL 17<br/>DSM Fully Managed<br/>Host: 10.x.x.x:5432]
            ADMINPW[Secret: admin-pw-pg-clus-01]
        end
    end

    USER -->|http://74.x.x.x<br/>or http://ha-web.IP.sslip.io| WEBLB
    WEBLB -->|round-robin| WEB1
    WEBLB -->|round-robin| WEB2

    WEB1 -->|API calls<br/>ha-api-lb:3001| APILB
    WEB2 -->|API calls<br/>ha-api-lb:3001| APILB

    APILB -->|round-robin| API1
    APILB -->|round-robin| API2

    API1 -->|PostgreSQL:5432| DSM
    API2 -->|PostgreSQL:5432| DSM

    ADMINPW -.->|used by| DSM

    style WEBLB fill:#d0021b,color:#fff
    style APILB fill:#d0021b,color:#fff
    style WEB1 fill:#000,color:#fff
    style WEB2 fill:#000,color:#fff
    style API1 fill:#68a063,color:#fff
    style API2 fill:#68a063,color:#fff
    style DSM fill:#336791,color:#fff
```

## Component Details

### Web Tier (2× VMs + LoadBalancer)

| Attribute | Value | AWS Equivalent |
|---|---|---|
| VMs | web-vm-01, web-vm-02 | 2× EC2 instances |
| OS | Ubuntu 24.04 Server | Amazon Linux 2023 |
| Application | Next.js Frontend (port 3000) | Node.js on EC2 |
| LoadBalancer | VirtualMachineService (ha-web-lb) | Application Load Balancer |
| External IP | Auto-allocated from NSX External IP Pool | Elastic IP / ALB DNS |
| Bootstrap | cloud-init: apt install, npm install, pm2 start | EC2 User Data |
| sslip.io | DNS alias only (`ha-web.IP.sslip.io`) | Route 53 alias |

### API Tier (2× VMs + LoadBalancer)

| Attribute | Value | AWS Equivalent |
|---|---|---|
| VMs | api-vm-01, api-vm-02 | 2× EC2 instances |
| OS | Ubuntu 24.04 Server | Amazon Linux 2023 |
| Application | Express API Server (port 3001) | Node.js on EC2 |
| LoadBalancer | VirtualMachineService (ha-api-lb) | Internal ALB |
| Network | Internal only (no external IP) | Private subnet ALB |
| Bootstrap | cloud-init: apt install, npm install, pm2 start | EC2 User Data |

### Database Tier (DSM Managed)

| Attribute | Value | AWS Equivalent |
|---|---|---|
| Resource | PostgresCluster (DSM CRD) | RDS PostgreSQL |
| Version | PostgreSQL 17 | RDS engine version |
| Management | Fully managed by DSM | Fully managed by RDS |
| Connection | Internal IP:5432 | RDS endpoint |

### Networking

| Path | Protocol | Details |
|---|---|---|
| User → Web LB | HTTP:80 | External LoadBalancer (public IP) |
| Web VMs → API LB | HTTP:3001 | Internal LoadBalancer (private IP) |
| API VMs → PostgreSQL | TCP:5432 | Direct connection over NSX VPC |
| sslip.io | DNS alias | `ha-web.IP.sslip.io` → Web LB IP (no Ingress/TLS) |

## Key Design Decisions

1. **No Kubernetes Ingress** — VM-based LoadBalancers (VirtualMachineService) operate at the supervisor level, not inside a VKS cluster. They don't support Kubernetes Ingress resources. sslip.io provides a DNS alias only.

2. **cloud-init for everything** — All 4 VMs are fully configured at boot time via cloud-init secrets. No SSH required after provisioning. The cloud-init scripts install Node.js, clone the application code, install dependencies, and start the application via pm2.

3. **DSM for database** — The database tier uses DSM-managed PostgreSQL (same as Deploy Managed DB App) rather than a manually provisioned PostgreSQL VM. This demonstrates that VM-based applications can also benefit from managed database services.

4. **Internal API LoadBalancer** — The API tier LoadBalancer has no external IP. Web VMs connect to it via the internal service name (`ha-api-lb`), keeping the API tier private.

5. **No VKS cluster required** — This pattern runs entirely in the supervisor namespace. It demonstrates that VCF can host traditional VM-based applications alongside containerized workloads.
