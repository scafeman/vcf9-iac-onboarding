# Deploy Secrets Demo — VCF Secret Store Integration

## Overview

`deploy-secrets-demo.sh` deploys a secrets management demo that demonstrates VCF Secret Store Service integration with a VKS guest cluster. It walks through the full secret lifecycle: secret creation in the supervisor namespace → vault-injector deployment → automatic secret injection into pods → application reads credentials from mounted files.

This is the VCF equivalent of AWS Secrets Manager. Instead of pulling secrets via SDK calls at runtime, VCF uses a vault-injector sidecar that automatically mounts secrets as files inside the pod at `/vault/secrets/`. The application simply reads files from disk — no SDK, no API calls, no secret-handling code.

The demo deploys:

- **Redis** — in-memory data store authenticated with a vault-injected password
- **PostgreSQL** — relational database authenticated with vault-injected username/password/database
- **Next.js Dashboard** — web UI that reads vault-injected secret files and verifies connectivity to both data stores

The script is fully non-interactive. All configuration is driven by environment variables (loaded from `.env` via Docker Compose). No user input is required during execution.

---

## AWS Secrets Manager vs VCF Secret Store — Comparison

| Feature | AWS Secrets Manager | VCF Secret Store Service |
|---|---|---|
| Secret creation | AWS CLI / SDK / Console | `vcf secret create -f` / VCFA UI |
| Secret format | JSON key-value | KeyValueSecret CRD (array of key/value) |
| API version | AWS SDK | `secretstore.vmware.com/v1alpha1` |
| Secret injection | AWS SDK in app code | Vault-injector sidecar (automatic file mount) |
| Injection method | App pulls secrets at runtime | Sidecar injects files at `/vault/secrets/` |
| Authentication | IAM Roles / IRSA | Supervisor namespace service account token |
| Namespace isolation | AWS account / region | Supervisor namespace (secrets tied to namespace) |
| Rotation | Built-in rotation with Lambda | Manual (delete + recreate) |
| Access from K8s pods | External Secrets Operator or SDK | vault-injector VKS standard package |
| Package management | N/A | `vcf package install vault-injector` |
| Secret retrieval | `aws secretsmanager get-secret-value` | Write-only (values masked on retrieval, consumed via sidecar) |
| Cost | Per-secret per-month pricing | Included with VCF license |

---

## Architecture

The secret injection flow spans two Kubernetes layers — the supervisor and the VKS guest cluster:

1. **Secrets created in supervisor namespace** — `vcf secret create -f <yaml>` registers `KeyValueSecret` CRDs with the Secret Store Service
2. **Service account token copied into guest cluster** — a long-lived `kubernetes.io/service-account-token` Secret is created in the supervisor namespace, then its base64-encoded token and CA cert are copied into the guest cluster namespace as an Opaque Secret
3. **vault-injector installed as a VKS standard package** — handles TLS certificates, RBAC (ClusterRole, ClusterRoleBinding), and a MutatingWebhookConfiguration automatically
4. **Pods with vault annotations get a sidecar** — the vault-injector webhook intercepts pod creation, injects a vault-agent init container and sidecar that authenticate with the Secret Store using the mounted service account token, then writes secrets as files to a shared emptyDir volume at `/vault/secrets/`
5. **Application reads files** — the dashboard container reads `/vault/secrets/redis-creds` and `/vault/secrets/postgres-creds` to extract credentials, then connects to Redis and PostgreSQL

---

## Prerequisites

- **Deploy Cluster completed** — a running VKS cluster provisioned by `deploy-cluster.sh`
- **VCF Secret Store Service enabled** on the supervisor
- **SECRET_STORE_IP** — the external IP address of the Secret Store service (visible in the supervisor services UI)
- **VCF CLI with `secret` plugin installed** — `vcf plugin install secret`
- **Package repository registered** in the VKS cluster (`tkg-packages` namespace)
- **kubectl** installed
- **Docker** installed (for building and pushing the dashboard container image)
- **openssl** installed (for generating random passwords if not provided)

---

## What the Script Does

### Phase 1: Create KeyValueSecrets in Supervisor Namespace

Creates two `KeyValueSecret` CRDs in the supervisor namespace via `vcf secret create -f`:

- `redis-creds` — contains `password`
- `postgres-creds` — contains `username`, `password`, `database`

If a secret already exists, creation is skipped (idempotent). Passwords are auto-generated with `openssl rand -base64 18` if not provided.

### Phase 2: Create ServiceAccount + Long-Lived Token in Supervisor Namespace

Creates a `ServiceAccount` named `internal-app` and a `kubernetes.io/service-account-token` Secret named `internal-app-token` in the supervisor namespace. Waits for the token controller to populate the token data (timeout: 300s).

### Phase 3: Switch to Guest Cluster Kubeconfig

Validates the guest cluster kubeconfig file exists and the cluster is reachable via `kubectl get namespaces`.

### Phase 4: Create Namespace, Copy Token, Deploy Vault-Injector

1. Creates the `secrets-demo` namespace in the guest cluster with `pod-security.kubernetes.io/enforce=privileged` label
2. Copies the supervisor service account token (base64 `token` + `ca.crt`) into the guest cluster namespace as an Opaque Secret
3. Installs the `vault-injector` VKS standard package with values pointing to the Secret Store IP
4. Waits for the vault-injector pod to reach Running state (timeout: 300s)
5. Waits for the vault-injector mutating webhook (`vault-agent-injector-cfg`) to be registered (up to 120s with 10s polling), then sleeps 5s to allow the webhook to stabilize. This ensures the webhook is active before creating pods with vault annotations.

### Phase 5: Deploy Data Tier (Redis + PostgreSQL)

Deploys Redis 7 (Alpine) and PostgreSQL 16 (Alpine) as single-replica Deployments with ClusterIP Services. Redis is configured with `--requirepass` using the generated password. PostgreSQL is configured with the generated user/password/database via environment variables.

Waits for both pods to reach Running state (timeout: 300s each).

### Phase 6: Build + Push Next.js Container Image

Builds the dashboard Docker image from `examples/deploy-secrets-demo/dashboard/` and pushes it to the configured container registry.

### Phase 7: Deploy Dashboard with Vault Annotations

1. Creates a `test-service-account` ServiceAccount and token in the guest cluster namespace
2. Deploys the `secrets-dashboard` Deployment with vault annotations that trigger secret injection
3. The pod mounts the supervisor service account token at `/var/run/secrets/kubernetes.io/serviceaccount` (overriding the default)
4. Creates a Service — when `USE_SSLIP_DNS=true` (default), uses ClusterIP with traffic routed through the shared envoy-lb Ingress. When `USE_SSLIP_DNS=false`, uses LoadBalancer type on port 80 → 3000.

Waits for the dashboard pod to reach Running state (timeout: 300s).

### Phase 8: Verify Connectivity

When `USE_SSLIP_DNS=true` (default), verifies the sslip.io Ingress is serving traffic and performs an HTTP GET to verify the dashboard returns status 200. When `USE_SSLIP_DNS=false`, waits for the LoadBalancer to receive an external IP (timeout: 300s), then performs the HTTP check.

### sslip.io DNS & TLS

When `USE_SSLIP_DNS=true` (default), the script creates a Contour Ingress resource with an sslip.io hostname (e.g., `secrets-demo.<IP>.sslip.io`) pointing to the Envoy LoadBalancer IP. This provides a human-readable DNS name without requiring external DNS configuration. If a Let's Encrypt ClusterIssuer is available (installed by Deploy Cluster Phase 5i), the Ingress includes a `cert-manager.io/cluster-issuer` annotation to automatically provision a trusted TLS certificate.

| Variable | Default | Description |
|---|---|---|
| `USE_SSLIP_DNS` | `true` | Enable/disable sslip.io DNS integration |
| `SSLIP_HOSTNAME_PREFIX` | `secrets-demo` | Hostname prefix for sslip.io DNS name |
| `CLUSTER_ISSUER_NAME` | `letsencrypt-prod` | ClusterIssuer for TLS certificate requests |
| `CERT_WAIT_TIMEOUT` | `300` | Seconds to wait for TLS certificate Ready |

---

## Required Environment Variables

Set these in the `.env` file at the project root. Docker Compose loads them into the container automatically.

| Variable | Required | Default | Description |
|---|---|---|---|
| `CLUSTER_NAME` | Yes | — | VKS guest cluster name |
| `KUBECONFIG_FILE` | No | `./kubeconfig-<CLUSTER_NAME>.yaml` | Path to guest cluster admin kubeconfig |
| `VCF_API_TOKEN` | Yes | — | API token from the VCFA portal |
| `VCFA_ENDPOINT` | Yes | — | VCFA hostname (no `https://` prefix) |
| `TENANT_NAME` | Yes | — | SSO tenant/organization |
| `CONTEXT_NAME` | Yes | — | Local VCF CLI context name |
| `SECRET_STORE_IP` | Yes | — | External IP of the Secret Store service |
| `SUPERVISOR_NAMESPACE` | Yes | — | Supervisor namespace name (used as vault role) |
| `REDIS_PASSWORD` | No | Random (openssl) | Redis authentication password |
| `POSTGRES_USER` | No | `secretsadmin` | PostgreSQL database user |
| `POSTGRES_PASSWORD` | No | Random (openssl) | PostgreSQL database password |
| `POSTGRES_DB` | No | `secretsdb` | PostgreSQL database name |
| `NAMESPACE` | No | `secrets-demo` | Kubernetes namespace in the guest cluster |
| `CONTAINER_REGISTRY` | No | `scafeman` | Docker registry prefix for container images |
| `IMAGE_NAME` | No | `secrets-dashboard` | Dashboard container image name |
| `IMAGE_TAG` | No | `latest` | Container image tag |
| `POD_TIMEOUT` | No | `300` | Seconds to wait for pod Running state |
| `POLL_INTERVAL` | No | `15` | Seconds between polling attempts |
| `LB_TIMEOUT` | No | `300` | Seconds to wait for LoadBalancer external IP |
| `DOCKERHUB_USERNAME` | No | — | DockerHub username (for image push authentication) |
| `DOCKERHUB_TOKEN` | No | — | DockerHub access token (for image push authentication) |

---

## Key Implementation Details

### KeyValueSecret YAML Format

Secrets are defined as `KeyValueSecret` CRDs in the supervisor namespace. The `spec.data` field is an array of key/value pairs (not a map):

```yaml
apiVersion: secretstore.vmware.com/v1alpha1
kind: KeyValueSecret
metadata:
  name: db-creds
spec:
  data:
  - key: username
    value: myuser
  - key: password
    value: mypassword
```

### Vault Annotations for Pod Injection

The vault-injector webhook watches for pods with these annotations and injects a vault-agent sidecar:

```yaml
annotations:
  vault.hashicorp.com/agent-inject: "true"
  vault.hashicorp.com/role: "<supervisor-namespace>"
  vault.hashicorp.com/agent-inject-secret-db-creds: "secret/data/<supervisor-namespace>/db-creds"
  vault.hashicorp.com/tls-skip-verify: "true"
```

- `agent-inject: "true"` — enables the webhook mutation
- `role` — must match the supervisor namespace name (this is the vault authentication role)
- `agent-inject-secret-<name>` — each annotation creates a file at `/vault/secrets/<name>` with the secret data
- `tls-skip-verify: "true"` — required because the Secret Store uses self-signed certificates

### Token Volume Mount (Critical)

VKS pods **must** mount the supervisor service account token to authenticate with the Secret Store. The default pod service account token will not work — it belongs to the guest cluster, not the supervisor. The deployment overrides the default service account mount:

```yaml
volumeMounts:
- mountPath: /var/run/secrets/kubernetes.io/serviceaccount
  name: vault-token
volumes:
- name: vault-token
  secret:
    secretName: internal-app-token
```

Without this override, the vault-agent sidecar will fail with "namespace not authorized" because it presents a guest cluster token instead of a supervisor namespace token.

### Vault-Injector Package Installation

The vault-injector is installed as a VKS standard package via the VCF CLI:

```bash
vcf package install vault-injector \
  -p vault-injector.kubernetes.vmware.com \
  --version 1.6.2+vmware.1-vks.1 \
  --values-file vault-injector-values.yaml \
  -n tkg-packages
```

The values file configures the injector to connect to the Secret Store:

```yaml
externalIP: "<SECRET_STORE_IP>"
namespace: "secrets-demo"
agentInjectVaultAddr: "http://secret-store-service:8200"
agentInjectVaultImage: "projects.packages.broadcom.com/vsphere/iaas/secret-store-service/9.0.0/openbao_ssl:0.0.15"
```

- `externalIP` — the Secret Store service external IP (creates a Kubernetes Service + Endpoints pointing to it)
- `namespace` — the namespace where the vault-injector pod and webhook run
- `agentInjectVaultAddr` — must be `http://` (not `https://`), the vault-agent connects to the Secret Store via the in-cluster Service
- `agentInjectVaultImage` — the Broadcom-published vault-agent sidecar image

### Secret File Format

The vault-injector mounts secrets as files at `/vault/secrets/`. The default template outputs Go map format:

```
data: map[password:mypassword username:myuser]
```

### Reading Secrets in Application Code

The dashboard uses a `parseVaultFile` function that handles both the default Go map format and a `key=value` per-line format:

```typescript
export function parseVaultFile(path: string): Record<string, string> {
  const content = fs.readFileSync(path, 'utf-8');
  const result: Record<string, string> = {};

  // Try default vault "map" template: data: map[key1:value1 key2:value2]
  const mapMatch = content.match(/data:\s*map\[([^\]]+)\]/);
  if (mapMatch) {
    const pairs = mapMatch[1].split(/\s+/);
    for (const pair of pairs) {
      const colonIdx = pair.indexOf(':');
      if (colonIdx > 0) {
        result[pair.substring(0, colonIdx)] = pair.substring(colonIdx + 1);
      }
    }
    return result;
  }

  // Fall back to key=value per line
  for (const line of content.split('\n')) {
    const [key, ...rest] = line.split('=');
    if (key && rest.length > 0) {
      result[key.trim()] = rest.join('=').trim();
    }
  }
  return result;
}
```

---

## How to Trigger

### Docker exec (recommended)

```bash
docker exec vcf9-dev bash examples/deploy-secrets-demo/deploy-secrets-demo.sh
```

### GitHub Actions UI

Navigate to **Actions → Deploy Secrets Demo → Run workflow**, enter the VKS cluster name, and click **Run workflow**.

### Trigger script (repository_dispatch)

```bash
bash scripts/trigger-deploy-secrets-demo.sh \
  --repo myorg/vcf9-iac \
  --token ghp_xxxxxxxxxxxx \
  --cluster-name my-project-01-clus-01
```

### curl (repository_dispatch)

```bash
curl -X POST \
  -H "Authorization: token ghp_xxxxxxxxxxxx" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/OWNER/REPO/dispatches" \
  -d '{
    "event_type": "deploy-secrets-demo",
    "client_payload": {
      "cluster_name": "my-project-01-clus-01",
      "secret_store_ip": "10.0.1.50",
      "supervisor_namespace": "my-project-ns"
    }
  }'
```

### PowerShell (Windows 11 workstation)

```powershell
docker exec vcf9-dev bash examples/deploy-secrets-demo/deploy-secrets-demo.sh
```

Or trigger via the GitHub API from PowerShell:

```powershell
$headers = @{
    "Authorization" = "token ghp_xxxxxxxxxxxx"
    "Accept"        = "application/vnd.github+json"
}
$body = @{
    event_type     = "deploy-secrets-demo"
    client_payload = @{
        cluster_name         = "my-project-01-clus-01"
        secret_store_ip      = "10.0.1.50"
        supervisor_namespace = "my-project-ns"
    }
} | ConvertTo-Json -Depth 3

Invoke-RestMethod `
    -Uri "https://api.github.com/repos/OWNER/REPO/dispatches" `
    -Method Post `
    -Headers $headers `
    -Body $body `
    -ContentType "application/json"
```

---

## Expected Output

A successful run produces output like this:

```
[Step 1] Creating KeyValueSecrets (redis-creds, postgres-creds) in supervisor namespace...
✓ KeyValueSecret 'redis-creds' created
✓ KeyValueSecret 'postgres-creds' created
✓ Phase 1 complete — KeyValueSecrets created
[Step 2] Creating ServiceAccount and long-lived token in supervisor namespace...
✓ ServiceAccount 'internal-app' created
✓ Secret 'internal-app-token' created
✓ Phase 2 complete — ServiceAccount 'internal-app' with long-lived token ready
[Step 3] Switching to guest cluster kubeconfig...
✓ Phase 3 complete — switched to guest cluster 'my-clus-01' via './kubeconfig-my-clus-01.yaml'
[Step 4] Setting up namespace, token, and vault-injector in guest cluster...
✓ Namespace 'secrets-demo' created
✓ Service account token copied into namespace 'secrets-demo'
[Step 4b] Installing vault-injector package...
✓ vault-injector package installed
  Waiting for vault-injector pod to be ready... (0s/300s elapsed)
✓ Phase 4 complete — vault-injector deployed and running in namespace 'secrets-demo'
[Step 5] Deploying Redis and PostgreSQL data tier...
✓ Redis Deployment and ClusterIP Service applied
✓ PostgreSQL Deployment and ClusterIP Service applied
✓ Redis pod is running
✓ PostgreSQL pod is running
✓ Phase 5 complete — Redis and PostgreSQL deployed and running
[Step 6] Building and pushing Next.js container image...
✓ Container image 'scafeman/secrets-dashboard:latest' built successfully
✓ Phase 6 complete — container image 'scafeman/secrets-dashboard:latest' pushed
[Step 7] Deploying web dashboard with vault-injected secrets...
✓ ServiceAccount 'test-service-account' and token created
✓ Dashboard Deployment and LoadBalancer Service applied
✓ Phase 7 complete — web dashboard deployed with vault annotations
[Step 8] Waiting for LoadBalancer IP and verifying HTTP connectivity...
✓ LoadBalancer 'secrets-dashboard-lb' assigned external IP: 74.205.11.92
✓ HTTP connectivity test passed — received status 200 from http://74.205.11.92
✓ Phase 8 complete — dashboard is accessible

=============================================
  VCF 9 Secrets Demo — Deployment Complete
=============================================
  Cluster:    my-clus-01
  Namespace:  secrets-demo
  Kubeconfig: ./kubeconfig-my-clus-01.yaml

  Deployed Services:
    - Redis:      redis.secrets-demo.svc.cluster.local:6379
    - PostgreSQL: postgres.secrets-demo.svc.cluster.local:5432
    - Vault Injector: vault-agent-injector-svc.secrets-demo.svc.cluster.local:443
    - Dashboard:  http://74.205.11.92
=============================================
```

---

## Typical Timing

| Phase | Duration |
|---|---|
| Phase 1 (KeyValueSecrets creation) | ~10s |
| Phase 2 (ServiceAccount + token) | ~15s |
| Phase 3 (Kubeconfig switch) | ~5s |
| Phase 4 (Namespace + vault-injector) | 1–3 min |
| Phase 5 (Redis + PostgreSQL) | 1–2 min |
| Phase 6 (Image build + push) | 2–5 min |
| Phase 7 (Dashboard deployment) | 1–2 min |
| Phase 8 (LoadBalancer + HTTP test) | 1–3 min |
| **Total** | **~6–15 min** |

---

## Exit Codes

| Code | Failure Category |
|---|---|
| 0 | Success |
| 1 | Variable validation failure |
| 2 | KeyValueSecret creation failure |
| 3 | ServiceAccount / token creation failure |
| 4 | Guest cluster kubeconfig not found or unreachable |
| 5 | Namespace / token copy / vault-injector failure |
| 6 | Redis or PostgreSQL deployment failure |
| 7 | Container image build or push failure |
| 8 | Dashboard deployment failure |
| 9 | LoadBalancer IP timeout or HTTP connectivity failure |

---

## Troubleshooting

### "namespace not authorized" — vault-agent authentication failure

The vault-agent sidecar is presenting the wrong service account token. The pod **must** mount the `internal-app-token` Secret (copied from the supervisor) at `/var/run/secrets/kubernetes.io/serviceaccount`. If the default guest cluster service account token is mounted instead, the Secret Store rejects the request because the token belongs to the guest cluster, not the supervisor namespace.

**Fix:** Verify the Deployment spec includes the `vault-token` volume mount overriding the default service account path. Check that the `internal-app-token` Secret exists in the namespace: `kubectl get secret internal-app-token -n secrets-demo`.

### "http: server gave HTTP response to HTTPS client"

The vault-agent is trying to connect to the Secret Store over HTTPS, but the in-cluster Service forwards to HTTP.

**Fix:** Ensure `agentInjectVaultAddr` in the vault-injector values is set to `http://secret-store-service:8200` (not `https://`). If the package is already installed with the wrong value, delete and reinstall it.

### "no Vault role found"

The `vault.hashicorp.com/role` annotation value does not match any known role in the Secret Store. The role name must be the supervisor namespace name.

**Fix:** Verify the `SUPERVISOR_NAMESPACE` variable matches the actual supervisor namespace name. In the GitHub Actions workflow, this is dynamically resolved from the VCF CLI context (`DYNAMIC_NS_NAME`).

### "ENOENT: no such file or directory, open '/vault/secrets/redis-creds'"

The vault-agent sidecar was not injected into the pod. The secret files do not exist because no sidecar wrote them.

**Fix:** Check that the vault-injector webhook is running: `kubectl get pods -n secrets-demo -l app.kubernetes.io/name=vault-injector`. Verify the MutatingWebhookConfiguration exists: `kubectl get mutatingwebhookconfiguration vault-injector-cfg`. Check pod events for webhook errors: `kubectl describe pod -l app=secrets-dashboard -n secrets-demo`.

### Password mismatch — Redis or PostgreSQL authentication fails

The secrets in the Secret Store contain passwords from a previous deployment run, but Redis/PostgreSQL were redeployed with new passwords.

**Fix:** Delete and recreate the KeyValueSecrets to ensure passwords match: `vcf secret delete redis-creds && vcf secret create -f redis-creds.yaml`. Then restart the dashboard pod to pick up the new secret values: `kubectl rollout restart deployment/secrets-dashboard -n secrets-demo`.

### vault-injector pod CrashLoopBackOff

The vault-injector container is failing to start, usually due to image pull issues or incorrect container arguments.

**Fix:** Check pod logs: `kubectl logs -l app.kubernetes.io/name=vault-injector -n secrets-demo`. Verify the `agentInjectVaultImage` is accessible from the cluster. Ensure the vault-injector container args include `agent-inject` (this is handled automatically by the package, but custom overrides may break it).

### Dashboard pod CrashLoopBackOff (vault-agent not injected)

If the dashboard pod goes into CrashLoopBackOff because the vault-injector webhook wasn't registered when the pod was first created, the script automatically restarts the deployment to trigger re-injection. If this still fails, manually restart: `kubectl rollout restart deployment/secrets-dashboard -n secrets-demo`.

### Monitor during deployment

```bash
# Watch vault-injector pod
docker exec vcf9-dev bash -c "export KUBECONFIG=./kubeconfig-<CLUSTER_NAME>.yaml && kubectl get pods -n secrets-demo -l app.kubernetes.io/name=vault-injector -w"

# Watch all pods in secrets-demo namespace
docker exec vcf9-dev bash -c "export KUBECONFIG=./kubeconfig-<CLUSTER_NAME>.yaml && kubectl get pods -n secrets-demo -w"

# Watch LoadBalancer IP assignment
docker exec vcf9-dev bash -c "export KUBECONFIG=./kubeconfig-<CLUSTER_NAME>.yaml && kubectl get svc -n secrets-demo -w"

# Check vault-agent sidecar logs in dashboard pod
docker exec vcf9-dev bash -c "export KUBECONFIG=./kubeconfig-<CLUSTER_NAME>.yaml && kubectl logs deploy/secrets-dashboard -c vault-agent -n secrets-demo"
```

---

## Broadcom Documentation References

- [Inject Secrets into Pods on VKS Clusters](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vsphere-supervisor-services-and-standalone-components/latest/using-supervisor-services/using-secret-store-service-with-vsphere-supervisor/managing-secrets-in-vsphere-supervisor-workloads-with-secret-store-service/inject-secrets-into-pods-on-vks-clusters.html)
