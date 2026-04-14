# Deploy Secrets Demo — High-Level Design

## Overview

Deploy Secrets Demo demonstrates VCF Secret Store integration with vault-injected secrets for Redis and PostgreSQL. A Next.js dashboard reads vault-injected credentials at runtime to verify connectivity to both data stores. This proves that VCF can deliver the same zero-trust credential management as AWS Secrets Manager + EKS.

Unlike Deploy Managed DB App (which uses DSM-managed PostgreSQL), this pattern deploys Redis and PostgreSQL as simple in-cluster containers to focus on the secret injection workflow.

## Architecture Diagram

```mermaid
graph TB
    subgraph "Internet"
        USER[DevOps Engineer<br/>Browser]
    end

    subgraph "VCF 9 Supervisor Namespace"
        subgraph "VCF Secret Store"
            REDIS_KVS[KeyValueSecret: redis-creds<br/>password]
            PG_KVS[KeyValueSecret: postgres-creds<br/>username, password, database]
            SA[ServiceAccount: internal-app<br/>+ long-lived token]
        end
    end

    subgraph "VKS Guest Cluster"
        subgraph "tanzu-system-ingress"
            ENVOY[Envoy Proxy]
            ENVOYLB[envoy-lb<br/>LoadBalancer]
        end

        subgraph "tkg-packages"
            VAULT[vault-injector<br/>Mutating Webhook]
        end

        subgraph "secrets-demo Namespace"
            TOKEN[Secret: internal-app-token<br/>Copied from supervisor]

            REDIS[Deployment: redis<br/>redis:7-alpine<br/>requirepass]
            REDIS_SVC[Service: redis<br/>ClusterIP:6379]

            PG[Deployment: postgres<br/>postgres:16-alpine]
            PG_SVC[Service: postgres<br/>ClusterIP:5432]

            DASH["Deployment: secrets-dashboard<br/>Next.js + vault-agent sidecar<br/>Reads /vault/secrets/redis-creds<br/>Reads /vault/secrets/postgres-creds"]
            DASH_SVC[Service: secrets-dashboard-lb<br/>ClusterIP:80 → 3000]

            INGRESS[Ingress: secrets-dashboard-sslip-ingress<br/>secrets-dashboard.IP.sslip.io]
        end
    end

    USER -->|http://secrets-dashboard.IP.sslip.io| ENVOYLB
    ENVOYLB --> ENVOY --> INGRESS --> DASH_SVC --> DASH

    DASH -->|Redis:6379| REDIS_SVC --> REDIS
    DASH -->|PostgreSQL:5432| PG_SVC --> PG

    VAULT -->|injects vault-agent sidecar| DASH
    DASH -->|authenticates via| TOKEN
    TOKEN -.->|copied from| SA
    SA -.->|reads| REDIS_KVS
    SA -.->|reads| PG_KVS

    style REDIS fill:#d82c20,color:#fff
    style PG fill:#336791,color:#fff
    style VAULT fill:#ffd814,color:#000
    style DASH fill:#000,color:#fff
    style ENVOYLB fill:#d0021b,color:#fff
    style REDIS_KVS fill:#9013fe,color:#fff
    style PG_KVS fill:#9013fe,color:#fff
```

## Component Details

### Secret Store Integration

| Resource | Type | Contents | Stored In |
|---|---|---|---|
| redis-creds | KeyValueSecret | `password` | VCF Secret Store (supervisor) |
| postgres-creds | KeyValueSecret | `username`, `password`, `database` | VCF Secret Store (supervisor) |
| internal-app | ServiceAccount | Long-lived token for vault authentication | Supervisor namespace |
| internal-app-token | Secret | Token + CA cert copied to guest cluster | secrets-demo namespace |

### Credential Injection Flow

```
VCF Secret Store (supervisor)
    ├── redis-creds (KeyValueSecret)
    └── postgres-creds (KeyValueSecret)
            ↓
    ServiceAccount: internal-app (authenticates)
            ↓
    Token copied to guest cluster → internal-app-token
            ↓
    vault-injector webhook intercepts pod creation
            ↓
    vault-agent sidecar injected into dashboard pod
            ↓
    /vault/secrets/redis-creds    → dashboard reads Redis password
    /vault/secrets/postgres-creds → dashboard reads PG credentials
            ↓
    Dashboard connects to Redis:6379 and PostgreSQL:5432
    Dashboard UI shows green checkmarks for each verified connection
```

### Data Stores (In-Cluster)

| Component | Image | Port | Purpose |
|---|---|---|---|
| Redis | redis:7-alpine | 6379 | Key-value cache (password-protected) |
| PostgreSQL | postgres:16-alpine | 5432 | Relational database |

### Dashboard Verification

The Next.js dashboard displays a status page with green checkmarks for each successfully verified connection:

- ✅ Redis connection (authenticated with vault-injected password)
- ✅ PostgreSQL connection (authenticated with vault-injected credentials)
- ✅ Vault agent sidecar running (secrets files present)

## Key Design Decisions

1. **Focus on secret injection** — This pattern uses simple in-cluster Redis and PostgreSQL containers (not DSM-managed) to keep the focus on the VCF Secret Store and vault-injector workflow.

2. **Two separate KeyValueSecrets** — Redis and PostgreSQL credentials are stored as separate KeyValueSecrets in the VCF Secret Store, demonstrating that a single pod can consume multiple vault-injected secrets.

3. **CrashLoopBackOff auto-restart** — If the vault-agent sidecar isn't injected on first pod creation (webhook timing), the script automatically restarts the deployment and waits again.

4. **Shared vault-injector** — The vault-injector package is shared with Deploy Managed DB App. The secrets-demo teardown deletes the package; the managed-db-app teardown does not.
