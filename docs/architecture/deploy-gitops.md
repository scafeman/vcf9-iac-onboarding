# Deploy GitOps — High-Level Design

## Overview

Deploy GitOps installs a self-contained CI/CD and GitOps stack on an existing VKS cluster: Harbor (container registry), GitLab (source control + CI), ArgoCD (GitOps continuous delivery), and a sample application (Google Microservices Demo / Online Boutique). This demonstrates that VCF can deliver the same developer experience as AWS ECR + CodePipeline + ArgoCD.

When sslip.io DNS is enabled, all services are accessible via `*.IP.sslip.io` hostnames with dynamic self-signed TLS certificates generated for the sslip.io domain.

## Architecture Diagram

```mermaid
graph TB
    subgraph "Internet"
        DEV[Developer<br/>Browser / git push]
        SSLIP[sslip.io DNS]
    end

    subgraph "VKS Guest Cluster"
        subgraph "tanzu-system-ingress"
            ENVOY[Envoy Proxy]
            ENVOYLB[envoy-lb<br/>LoadBalancer<br/>IP: 74.x.x.x]
        end

        subgraph "harbor Namespace"
            HARBOR_CORE[Harbor Core<br/>API + UI]
            HARBOR_REG[Harbor Registry<br/>Container Image Storage]
            HARBOR_DB[Harbor Database<br/>PostgreSQL]
            HARBOR_REDIS[Harbor Redis<br/>Cache + Job Queue]
            HARBOR_TRIVY[Trivy<br/>Vulnerability Scanner]
        end

        subgraph "gitlab-system Namespace"
            GITLAB_WS[GitLab Webservice<br/>Rails App]
            GITLAB_GIT[Gitaly<br/>Git Storage]
            GITLAB_PG[GitLab PostgreSQL<br/>Metadata DB]
            GITLAB_REDIS[GitLab Redis<br/>Cache + Sidekiq]
            GITLAB_REG[GitLab Registry<br/>Container Registry]
        end

        subgraph "gitlab-runners Namespace"
            RUNNER[GitLab Runner<br/>CI/CD Job Executor]
        end

        subgraph "argocd Namespace"
            ARGOCD_SRV[ArgoCD Server<br/>API + UI]
            ARGOCD_REPO[ArgoCD Repo Server<br/>Git Manifest Rendering]
            ARGOCD_APP[ArgoCD Application Controller<br/>Reconciliation Loop]
            APP_CR[Application CR<br/>microservices-demo]
        end

        subgraph "microservices-demo Namespace"
            FRONTEND[Frontend<br/>Online Boutique UI]
            CART[Cart Service]
            CHECKOUT[Checkout Service]
            CURRENCY[Currency Service]
            PAYMENT[Payment Service]
            SHIPPING[Shipping Service]
            PRODUCT[Product Catalog]
            RECOMMEND[Recommendation Service]
            AD[Ad Service]
            EMAIL[Email Service]
        end

        subgraph "kube-system"
            COREDNS[CoreDNS<br/>sslip.io forwarding]
        end
    end

    DEV -->|https://harbor.IP.sslip.io| ENVOYLB
    DEV -->|https://gitlab.IP.sslip.io| ENVOYLB
    DEV -->|https://argocd.IP.sslip.io| ENVOYLB
    DEV -->|http://FRONTEND_IP| FRONTEND

    ENVOYLB --> ENVOY
    ENVOY -->|host: harbor.*| HARBOR_CORE
    ENVOY -->|host: gitlab.*| GITLAB_WS
    ENVOY -->|host: argocd.*| ARGOCD_SRV

    GITLAB_WS --> GITLAB_GIT
    GITLAB_WS --> GITLAB_PG
    GITLAB_WS --> GITLAB_REDIS

    RUNNER -->|CI jobs| GITLAB_WS
    RUNNER -->|push images| HARBOR_REG

    ARGOCD_APP -->|watches git repo| GITLAB_WS
    ARGOCD_APP -->|deploys manifests| FRONTEND
    APP_CR -->|defines| ARGOCD_APP

    HARBOR_CORE --> HARBOR_REG
    HARBOR_CORE --> HARBOR_DB
    HARBOR_CORE --> HARBOR_REDIS

    style HARBOR_CORE fill:#60b932,color:#fff
    style GITLAB_WS fill:#fc6d26,color:#fff
    style ARGOCD_SRV fill:#ef7b4d,color:#fff
    style ENVOYLB fill:#d0021b,color:#fff
    style FRONTEND fill:#4a90d9,color:#fff
```

## Component Details

### CI/CD Stack

| Component | Role | AWS Equivalent | Namespace |
|---|---|---|---|
| Harbor | Container registry + vulnerability scanning | ECR + Inspector | harbor |
| GitLab | Source control + CI pipelines | CodeCommit + CodeBuild | gitlab-system |
| GitLab Runner | CI/CD job executor | CodeBuild compute | gitlab-runners |
| ArgoCD | GitOps continuous delivery | CodePipeline + Flux | argocd |
| Online Boutique | Sample microservices application | Demo workload | microservices-demo |

### Networking

| Service | Hostname (sslip.io mode) | Access Method |
|---|---|---|
| Harbor | `harbor.IP.sslip.io` | Contour Ingress via envoy-lb |
| GitLab | `gitlab.IP.sslip.io` | Contour Ingress via envoy-lb |
| ArgoCD | `argocd.IP.sslip.io` | Contour Ingress via envoy-lb |
| Online Boutique | Direct LoadBalancer IP | frontend-external Service |

### TLS Strategy (sslip.io Mode)

| Aspect | Details |
|---|---|
| DOMAIN override | `DOMAIN` is set to `IP.sslip.io` after envoy-lb IP is known |
| Wildcard cert | Dynamic self-signed cert generated for `*.IP.sslip.io` |
| Why self-signed? | Helm charts (Harbor, GitLab) require TLS secrets for internal communication |
| CoreDNS | Skipped — sslip.io resolves externally |
| Let's Encrypt | Not used for GitOps (Helm charts manage their own TLS) |

## GitOps Workflow

```
Developer → git push → GitLab → GitLab Runner (CI) → Harbor (image push)
                                                           ↓
                        ArgoCD ← watches git repo ← GitLab (manifests)
                           ↓
                    Deploys to microservices-demo namespace
```

## Installation Order

| Phase | Component | Method | Duration |
|---|---|---|---|
| 1 | Kubeconfig setup | VCF CLI | ~10s |
| 2 | Self-signed certs | openssl (dynamic `*.IP.sslip.io`) | ~5s |
| 3 | Package namespace + repo | VKS CLI | ~30s |
| 3c | cert-manager | VKS Standard Package | ~60s |
| 3d | Contour + envoy-lb | VKS Standard Package | ~90s |
| 4 | Harbor | Helm chart | ~3 min |
| 5 | CoreDNS | Skipped (sslip.io mode) | 0s |
| 6 | ArgoCD | Helm chart | ~2 min |
| 7 | GitLab | Helm chart (operator) | ~5 min |
| 8 | GitLab Runner | Helm chart | ~1 min |
| 9 | ArgoCD Application | kubectl apply | ~3 min |

**Total: ~15–20 minutes**

## Key Design Decisions

1. **Self-contained stack** — Harbor, GitLab, and ArgoCD all run inside the VKS cluster. No external dependencies on SaaS services. This proves VCF can deliver a complete developer platform on private infrastructure.

2. **Dynamic sslip.io certs** — When `USE_SSLIP_DNS=true`, the DOMAIN is overridden to `IP.sslip.io` and a new wildcard cert is generated for `*.IP.sslip.io`. This is needed because Helm charts (Harbor, GitLab) require TLS secrets for internal pod-to-pod communication.

3. **Shared infrastructure packages** — cert-manager and Contour are installed as VKS Standard Packages shared with other deployment patterns. The GitOps stack reuses the same envoy-lb LoadBalancer.

4. **ArgoCD Application CR** — The Online Boutique is deployed declaratively via an ArgoCD Application custom resource that watches a Git repository. This demonstrates the GitOps reconciliation loop.
