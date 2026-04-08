# Deploy Knative — Serverless Audit Function

## Overview

`deploy-knative.sh` installs Knative Serving on an existing VKS cluster and deploys a serverless audit function with a Next.js dashboard — the VCF equivalent of deploying an AWS Lambda function with API Gateway. The audit function receives HTTP POST requests logging asset changes and demonstrates Knative's scale-to-zero behavior.

**Architecture:**
- **Knative Serving:** CRDs, core controllers, and net-contour networking plugin installed from upstream YAML manifests
- **Audit Function:** Knative Service `asset-audit` in `knative-demo` namespace — scales to zero when idle, cold-starts on request
- **Dashboard:** Next.js application with LoadBalancer Service showing audit log, pod count, and scale-to-zero status

The script is fully non-interactive. All configuration is driven by environment variables (loaded from `.env` via Docker Compose). No user input is required during execution.

---

## AWS to VCF Mapping

| AWS Component | VCF Equivalent | Notes |
|---|---|---|
| AWS Lambda | Knative Service (`asset-audit`) | Scale-to-zero, auto-scaling, revision management |
| API Gateway | Contour Ingress (net-contour) | HTTP routing via Envoy proxy |
| CloudWatch Logs | `kubectl logs` | Pod logs for audit function |
| DynamoDB Streams | HTTP webhook (POST) | Direct HTTP invocation from API server |
| Route 53 | sslip.io Magic DNS | Wildcard DNS via `<IP>.sslip.io` |
| Lambda Layers | Container image | Custom Node.js image with dependencies |

---

## Prerequisites

- **Deploy Cluster** completed successfully (VKS cluster running)
- **kubectl** installed with a valid admin kubeconfig for the target cluster
- **curl** installed for verification
- **Container images** pushed to the registry (`knative-audit`, `knative-dashboard`)

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

### Phase 7: Audit Function Deployment

Creates the `knative-demo` namespace (if not exists) and deploys the `asset-audit` Knative Service with scale-to-zero annotation. Waits for the service to reach `Ready` status and extracts the service URL.

### Phase 8: Dashboard Deployment

Deploys the Next.js dashboard as a standard Kubernetes Deployment with a LoadBalancer Service. Waits for the pod to reach `Running` state and the LoadBalancer to receive an external IP.

### Phase 9: Verification & Scale-to-Zero Demo

Sends a test HTTP POST to the audit function URL, verifies HTTP 200 response, logs the response body, waits for scale-to-zero, and verifies the pod count reaches zero.

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
| `CONTAINER_REGISTRY` | No | `scafeman` | Container registry prefix |
| `IMAGE_TAG` | No | `latest` | Container image tag |
| `AUDIT_IMAGE` | No | `${CONTAINER_REGISTRY}/knative-audit:${IMAGE_TAG}` | Audit function image |
| `SCALE_TO_ZERO_GRACE_PERIOD` | No | `30s` | Idle timeout before scale-to-zero |
| `KNATIVE_TIMEOUT` | No | `300` | Timeout for Knative component readiness (seconds) |
| `POD_TIMEOUT` | No | `300` | Timeout for pod readiness (seconds) |
| `LB_TIMEOUT` | No | `300` | Timeout for LoadBalancer IP assignment (seconds) |
| `POLL_INTERVAL` | No | `10` | Polling interval (seconds) |

---

## How to Trigger

### Docker exec (recommended)

```bash
docker exec vcf9-dev bash examples/deploy-knative/deploy-knative.sh
```

### GitHub Actions UI

Navigate to **Actions → Deploy Knative → Run workflow**, enter the `cluster_name`, and click **Run workflow**.

### curl (repository_dispatch)

```bash
curl -X POST \
  -H "Authorization: token ghp_xxxxxxxxxxxx" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/OWNER/REPO/dispatches" \
  -d '{
    "event_type": "deploy-knative",
    "client_payload": {
      "cluster_name": "my-dev-project-01-clus-01"
    }
  }'
```

---

## Expected Output

A successful run produces output like this:

```
[Step 1] Setting up kubeconfig and verifying connectivity...
✓ Kubeconfig set and cluster 'my-clus-01' is reachable
[Step 2] Installing Knative Serving CRDs (v1.21.2)...
✓ Knative Serving CRDs installed and Established
[Step 3] Installing Knative Serving Core (v1.21.2)...
✓ Knative Serving Core installed and Available
[Step 4] Installing net-contour networking plugin (v1.21.1)...
✓ net-contour networking plugin installed and Available
[Step 5] Configuring Knative ingress (Contour)...
✓ Knative ingress configured to use Contour (external-domain-tls: Disabled)
[Step 6] Configuring DNS with sslip.io...
✓ Envoy LoadBalancer IP: 10.96.0.50
✓ DNS configured: *.10.96.0.50.sslip.io
[Step 7] Deploying audit function as Knative Service...
✓ Namespace 'knative-demo' created
✓ Audit function deployed: http://asset-audit.knative-demo.10.96.0.50.sslip.io
[Step 8] Deploying Knative dashboard...
✓ Dashboard deployed: http://74.205.11.95
[Step 9] Verifying audit function and scale-to-zero behavior...
✓ Audit function responded with HTTP 200
✓ Scale-to-zero confirmed: 0 audit function pods running
✓ Verification complete

=============================================
  VCF 9 Deploy Knative — Deployment Complete
=============================================
  Cluster:              my-clus-01
  Knative Serving:      v1.21.2
  net-contour:          v1.21.1
  Ingress IP:           10.96.0.50
  Domain:               10.96.0.50.sslip.io
  Audit Function:       http://asset-audit.knative-demo.10.96.0.50.sslip.io
  Dashboard:            http://74.205.11.95
  Audit Image:          scafeman/knative-audit:latest
  Scale-to-Zero Grace:  30s
=============================================
```

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
| Phase 7 (Audit function deployment) | 30s–2 min |
| Phase 8 (Dashboard deployment) | 1–3 min |
| Phase 9 (Verification + scale-to-zero) | 1–2 min |
| **Total** | **~5–15 min** |

---

## Exit Codes

| Code | Failure Category |
|---|---|
| 0 | Success |
| 1 | Variable validation failure |
| 2 | CRD or core installation failure |
| 3 | Networking/ingress failure |
| 4 | DNS configuration failure |
| 5 | Audit function deployment failure |
| 6 | Dashboard deployment failure |
| 7 | Verification failure |

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

### Audit function deployment fails (exit 5)

- Check container image availability: `docker pull ${AUDIT_IMAGE}`
- Check Knative Service events: `kubectl describe ksvc asset-audit -n knative-demo`
- Check pod logs: `kubectl logs -n knative-demo -l serving.knative.dev/service=asset-audit`

### Dashboard deployment fails (exit 6)

- Check dashboard pod status: `kubectl get pods -n knative-demo -l app=knative-dashboard`
- Check container image availability
- Verify LoadBalancer IP assignment: `kubectl get svc knative-dashboard -n knative-demo`

### Verification fails (exit 7)

- Verify audit function URL is reachable: `curl -v ${AUDIT_FUNCTION_URL}`
- Check pod logs for errors: `kubectl logs -n knative-demo -l serving.knative.dev/service=asset-audit`
- Increase `KNATIVE_TIMEOUT` if the function takes longer to cold-start

### Monitor during deployment

```bash
# Watch Knative Serving namespace
docker exec vcf9-dev kubectl get pods -n knative-serving -w

# Watch demo namespace
docker exec vcf9-dev kubectl get pods -n knative-demo -w

# Check Knative Services
docker exec vcf9-dev kubectl get ksvc -n knative-demo
```
