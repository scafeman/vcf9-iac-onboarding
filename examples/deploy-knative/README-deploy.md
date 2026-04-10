# Deploy Knative — Serverless Asset Tracker with DSM PostgreSQL

## Overview

`deploy-knative.sh` installs Knative Serving on an existing VKS cluster and deploys a full Asset Tracker with DSM PostgreSQL persistence, an API server, a serverless audit function, and a Next.js dashboard — the VCF equivalent of deploying an AWS Lambda function with API Gateway backed by RDS PostgreSQL. The audit function receives HTTP POST requests logging asset changes and demonstrates Knative's scale-to-zero behavior, while the API server provides full CRUD operations on assets.

**Architecture:**
- **Knative Serving:** CRDs, core controllers, and net-contour networking plugin installed from upstream YAML manifests
- **DSM PostgresCluster:** Managed PostgreSQL instance provisioned via VCF Database Service Manager for persistent storage of assets and audit entries
- **API Server:** Express.js application with CRUD endpoints backed by DSM PostgreSQL, deployed as a standard Kubernetes Deployment with ClusterIP Service
- **Audit Function:** Knative Service `asset-audit` in `knative-demo` namespace — scales to zero when idle, cold-starts on request, writes audit entries to DSM PostgreSQL
- **Dashboard:** Next.js application with LoadBalancer Service showing Asset Tracker CRUD, audit trail, Knative pod count, and scale-to-zero status
- **RBAC:** ServiceAccount, Role, and RoleBinding for dashboard pod count access

The script is fully non-interactive. All configuration is driven by environment variables (loaded from `.env` via Docker Compose). No user input is required during execution.

---

## AWS to VCF Mapping

| AWS Component | VCF Equivalent | Notes |
|---|---|---|
| AWS Lambda | Knative Service (`asset-audit`) | Scale-to-zero, auto-scaling, revision management |
| API Gateway | Contour Ingress (net-contour) | HTTP routing via Envoy proxy |
| RDS PostgreSQL | DSM PostgresCluster | Managed PostgreSQL via VCF Database Service Manager |
| CloudWatch Logs | `kubectl logs` | Pod logs for audit function |
| DynamoDB Streams | HTTP webhook (POST) | Direct HTTP invocation from API server |
| Route 53 | sslip.io Magic DNS | Wildcard DNS via `<IP>.sslip.io` |
| Lambda Layers | Container image | Custom Node.js image with dependencies |
| IAM Roles | RBAC (ServiceAccount, Role, RoleBinding) | Pod-level permissions for Kubernetes API access |

---

## Prerequisites

- **Deploy Cluster** completed successfully (VKS cluster running)
- **kubectl** installed with a valid admin kubeconfig for the target cluster
- **VCF CLI** installed and configured with supervisor context
- **DSM infrastructure policy** configured in the supervisor namespace
- **curl** installed for verification
- **Container images** pushed to the registry (`knative-audit`, `knative-api`, `knative-dashboard`)

---

## What the Script Does

### Phase 1: Kubeconfig Setup & Connectivity Check

Sets `KUBECONFIG` to the specified file and verifies cluster connectivity with `kubectl get namespaces`.

### Phase 2: Knative Serving CRDs

Applies the Knative Serving CRDs manifest from the official GitHub release. Waits for all CRDs (services, routes, configurations, revisions) to reach the `Established` condition.

### Phase 3: Knative Serving Core

Applies the Knative Serving core manifest, installing controllers, webhooks, and the activator into the `knative-serving` namespace. Waits for all deployments to reach `Available`.

### Phase 4: net-contour Networking Plugin

Installs the net-contour plugin that bridges Knative Serving to Contour for HTTP routing. This creates separate Contour instances in `contour-external` and `contour-internal` namespaces.

### Phase 5: Ingress Configuration

Patches the `config-network` ConfigMap to set `ingress-class` to `contour.ingress.networking.knative.dev` and `external-domain-tls` to `Disabled`.

### Phase 6: DNS Configuration (sslip.io)

Retrieves the Envoy LoadBalancer external IP from the `contour-external` namespace and patches the `config-domain` ConfigMap with `<IP>.sslip.io` for wildcard DNS resolution.

### Phase 7: DSM PostgresCluster Provisioning

Creates a VCF CLI context for supervisor namespace access, provisions a DSM PostgresCluster by applying the `databases.dataservices.vmware.com/v1alpha1 PostgresCluster` CRD manifest, creates the admin password secret, and waits for the cluster to become ready with connection details. Extracts host, port, username, and password for use by the API server and audit function.

### Phase 8: API Server Deployment

Creates the `knative-demo` namespace (if not exists) and deploys the Express.js API server as a Kubernetes Deployment with a ClusterIP Service. The API server connects to DSM PostgreSQL with SSL and provides CRUD endpoints for assets. Waits for the pod to reach `Running` state.

### Phase 9: Audit Function Deployment (Knative Service with DSM)

Deploys the `asset-audit` Knative Service with DSM PostgreSQL connection environment variables (POSTGRES_HOST, POSTGRES_PORT, POSTGRES_USER, POSTGRES_DB, POSTGRES_PASSWORD, POSTGRES_SSL). Includes scale-to-zero annotation. Waits for the service to reach `Ready` status.

### Phase 10: RBAC and Dashboard Deployment

Creates RBAC resources (ServiceAccount, Role, RoleBinding) for dashboard pod count access. Deploys the Next.js dashboard as a Deployment with a Service — when `USE_SSLIP_DNS=true` (default), uses ClusterIP with traffic routed through the shared envoy-lb Ingress. When `USE_SSLIP_DNS=false`, uses LoadBalancer type. Configured with the API server URL. Waits for the pod and LoadBalancer IP (or Ingress readiness).

### Phase 11: Verification & Scale-to-Zero Demo

Tests the API server healthz endpoint, sends a test audit event, verifies the audit trail via `/log`, waits for scale-to-zero, and verifies the pod count reaches zero.

### sslip.io DNS & TLS (Dashboard)

The Knative Service routing uses sslip.io for Knative domain resolution (Phase 6). Separately, when `USE_SSLIP_DNS=true` (default), the dashboard LoadBalancer Service also gets a Contour Ingress with an sslip.io hostname (e.g., `knative-dashboard.<IP>.sslip.io`). If a Let's Encrypt ClusterIssuer is available, the Ingress includes TLS annotations for automatic certificate provisioning.

| Variable | Default | Description |
|---|---|---|
| `USE_SSLIP_DNS` | `true` | Enable/disable sslip.io DNS for the dashboard |
| `SSLIP_HOSTNAME_PREFIX` | `knative-dashboard` | Hostname prefix for sslip.io DNS name |
| `CLUSTER_ISSUER_NAME` | `letsencrypt-prod` | ClusterIssuer for TLS certificate requests |
| `CERT_WAIT_TIMEOUT` | `300` | Seconds to wait for TLS certificate Ready |

---

## Required Environment Variables

Set these in the `.env` file at the project root. Docker Compose loads them into the container automatically.

| Variable | Required | Default | Description |
|---|---|---|---|
| `CLUSTER_NAME` | Yes | — | VKS cluster name |
| `KUBECONFIG_FILE` | No | `./kubeconfig-${CLUSTER_NAME}.yaml` | Path to admin kubeconfig |
| `KNATIVE_SERVING_VERSION` | No | `1.21.2` | Knative Serving version |
| `NET_CONTOUR_VERSION` | No | `1.21.1` | net-contour plugin version |
| `KNATIVE_NAMESPACE` | No | `knative-serving` | Knative system namespace |
| `DEMO_NAMESPACE` | No | `knative-demo` | Demo application namespace |
| `VCF_API_TOKEN` | Yes | — | VCF CLI API token |
| `VCFA_ENDPOINT` | Yes | — | VCF Automation endpoint |
| `TENANT_NAME` | Yes | — | VCF tenant name |
| `CONTEXT_NAME` | Yes | — | VCF CLI context name |
| `SUPERVISOR_NAMESPACE` | Yes | — | Supervisor namespace for DSM |
| `PROJECT_NAME` | Yes | — | VCF project name |
| `DSM_CLUSTER_NAME` | No | `pg-clus-01` | DSM PostgresCluster name |
| `DSM_INFRA_POLICY` | Yes | — | DSM infrastructure policy |
| `DSM_VM_CLASS` | No | `best-effort-large` | VM class for DSM |
| `DSM_STORAGE_POLICY` | Yes | — | Storage policy for DSM |
| `DSM_STORAGE_SPACE` | No | `20Gi` | Storage space for DSM |
| `POSTGRES_VERSION` | No | `17.7+vmware.v9.0.2.0` | PostgreSQL version |
| `POSTGRES_REPLICAS` | No | `0` | PostgreSQL replicas |
| `POSTGRES_DB` | No | `assetdb` | Database name |
| `ADMIN_PASSWORD_SECRET_NAME` | No | `admin-pw-pg-clus-01` | Secret name for admin password |
| `ADMIN_PASSWORD` | Yes | — | PostgreSQL admin password |
| `CONTAINER_REGISTRY` | No | `scafeman` | Container registry prefix |
| `IMAGE_TAG` | No | `latest` | Container image tag |
| `AUDIT_IMAGE` | No | `${CONTAINER_REGISTRY}/knative-audit:${IMAGE_TAG}` | Audit function image |
| `API_IMAGE` | No | `${CONTAINER_REGISTRY}/knative-api:${IMAGE_TAG}` | API server image |
| `API_PORT` | No | `3001` | API server port |
| `SCALE_TO_ZERO_GRACE_PERIOD` | No | `30s` | Idle timeout before scale-to-zero |
| `KNATIVE_TIMEOUT` | No | `300` | Timeout for Knative component readiness (seconds) |
| `POD_TIMEOUT` | No | `300` | Timeout for pod readiness (seconds) |
| `LB_TIMEOUT` | No | `300` | Timeout for LoadBalancer IP assignment (seconds) |
| `DSM_TIMEOUT` | No | `1800` | Timeout for DSM provisioning (seconds) |
| `POLL_INTERVAL` | No | `10` | Polling interval (seconds) |

---

## How to Trigger

### Docker exec (recommended)

```bash
docker exec vcf9-dev bash examples/deploy-knative/deploy-knative.sh
```

### GitHub Actions UI

Navigate to **Actions → Deploy Knative → Run workflow**, enter the required parameters (cluster_name, DSM infra policy, storage policy, supervisor namespace, etc.), and click **Run workflow**.

### curl (repository_dispatch)

```bash
curl -X POST \
  -H "Authorization: token ghp_xxxxxxxxxxxx" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/OWNER/REPO/dispatches" \
  -d '{
    "event_type": "deploy-knative",
    "client_payload": {
      "cluster_name": "my-dev-project-01-clus-01",
      "vcfa_endpoint": "vcfa.example.com",
      "tenant_name": "my-tenant",
      "supervisor_namespace": "my-sv-ns",
      "project_name": "my-project",
      "dsm_infra_policy": "my-infra-policy",
      "dsm_storage_policy": "my-storage-policy"
    }
  }'
```

---

## Exit Codes

| Code | Failure Category |
|---|---|
| 0 | Success |
| 1 | Variable validation failure |
| 2 | CRD or core installation failure |
| 3 | Networking/ingress failure |
| 4 | DNS configuration failure |
| 5 | DSM provisioning failure |
| 6 | API server deployment failure |
| 7 | Audit function deployment failure |
| 8 | Dashboard deployment failure |
| 9 | Verification failure |

---

## Typical Timing

| Phase | Duration |
|---|---|
| Phase 1 (Kubeconfig setup) | ~5s |
| Phase 2 (Knative CRDs) | 10–30s |
| Phase 3 (Knative Core) | 1–3 min |
| Phase 4 (net-contour plugin) | 1–3 min |
| Phase 5 (Ingress configuration) | ~5s |
| Phase 6 (DNS configuration) | 30s–2 min |
| Phase 7 (DSM PostgresCluster) | 5–30 min |
| Phase 8 (API server deployment) | 30s–2 min |
| Phase 9 (Audit function deployment) | 30s–2 min |
| Phase 10 (RBAC + Dashboard) | 1–3 min |
| Phase 11 (Verification + scale-to-zero) | 1–2 min |
| **Total** | **~10–45 min** |

---

## Troubleshooting

### Knative CRDs or Core fail to install (exit 2)

- Verify cluster connectivity: `kubectl get namespaces`
- Check RBAC permissions — the kubeconfig must have cluster-admin access
- Verify the Knative version URL is reachable from the runner
- Check events: `kubectl get events -n knative-serving --sort-by=.lastTimestamp`

### net-contour or ingress configuration fails (exit 3)

- Check net-contour controller logs: `kubectl logs -n knative-serving -l app=net-contour-controller`
- Verify Contour namespaces were created: `kubectl get ns contour-external contour-internal`
- Check for conflicting ingress classes

### DNS configuration fails (exit 4)

- Verify Envoy LoadBalancer has an external IP: `kubectl get svc -n contour-external envoy`
- Check that the NSX load balancer has capacity for a new IP
- Increase `LB_TIMEOUT` if the environment is slow to assign IPs

### DSM provisioning fails (exit 5)

- Verify VCF CLI context: `vcf context list`
- Check DSM infrastructure policy exists in the supervisor namespace
- Check PostgresCluster status: `kubectl get postgrescluster -n ${SUPERVISOR_NAMESPACE}`
- Increase `DSM_TIMEOUT` for slow environments (default 1800s)

### API server deployment fails (exit 6)

- Check container image availability: `docker pull ${API_IMAGE}`
- Check pod status: `kubectl get pods -n knative-demo -l app=knative-api-server`
- Check pod logs: `kubectl logs -n knative-demo -l app=knative-api-server`

### Audit function deployment fails (exit 7)

- Check container image availability: `docker pull ${AUDIT_IMAGE}`
- Check Knative Service events: `kubectl describe ksvc asset-audit -n knative-demo`
- Check pod logs: `kubectl logs -n knative-demo -l serving.knative.dev/service=asset-audit`

### Dashboard deployment fails (exit 8)

- Check dashboard pod status: `kubectl get pods -n knative-demo -l app=knative-dashboard`
- Check container image availability
- Verify LoadBalancer IP assignment: `kubectl get svc knative-dashboard -n knative-demo`

### Verification fails (exit 9)

- Verify API server healthz: `kubectl run test --rm -i --restart=Never --image=curlimages/curl:latest -n knative-demo -- curl -s http://knative-api-server:3001/healthz`
- Check audit function URL is reachable
- Increase `KNATIVE_TIMEOUT` if the function takes longer to cold-start

### Monitor during deployment

```bash
# Watch Knative Serving namespace
docker exec vcf9-dev kubectl get pods -n knative-serving -w

# Watch demo namespace
docker exec vcf9-dev kubectl get pods -n knative-demo -w

# Check Knative Services
docker exec vcf9-dev kubectl get ksvc -n knative-demo

# Check DSM PostgresCluster status
docker exec vcf9-dev kubectl get postgrescluster -n ${SUPERVISOR_NAMESPACE}
```
