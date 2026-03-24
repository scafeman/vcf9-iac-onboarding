# Scenario 3: Self-Contained ArgoCD Consumption Model Deploy Script

## Overview

`scenario3-argocd-deploy.sh` installs the full self-contained ArgoCD Consumption Model stack on an existing VKS cluster provisioned by Scenario 1. All infrastructure services (Contour, Harbor, ArgoCD) are installed from scratch via Helm — no Supervisor platform services are required.

The script orchestrates: self-signed certificate generation, Contour ingress controller installation, Harbor container registry installation, ArgoCD GitOps controller installation, ArgoCD CLI auto-download, CoreDNS configuration for internal DNS resolution, GitLab (Operator + Runner) deployment for CI/CD, ArgoCD application synchronization, and Google Microservices Demo (Online Boutique) deployment via GitOps.

The script is fully non-interactive. All configuration is driven by environment variables defined in the variable block at the top of the script. No user input or confirmation prompts are required during execution.

---

## Architecture Overview

The self-contained ArgoCD Consumption Model has a strict dependency chain. Each component depends on the one before it:

```
Kubeconfig Setup
  └─► Self-Signed Certificate Generation (CA + wildcard cert via openssl)
        └─► Contour Installation (Helm, Envoy LoadBalancer)
              └─► Harbor Installation (Helm, TLS via Contour Ingress)
                    └─► CoreDNS Configuration (static DNS using Contour LB IP)
                          └─► ArgoCD Installation (Helm, ingress via Contour)
                                └─► ArgoCD CLI Installation (auto-download)
                                      └─► Certificate Distribution (Harbor CA, GitLab TLS)
                                            └─► GitLab Operator (Helm)
                                                  └─► Harbor Proxy Patching (image registry)
                                                        └─► GitLab Runner (Helm)
                                                              └─► ArgoCD Cluster Registration
                                                                    └─► ArgoCD Application Bootstrap
                                                                          └─► Microservices Demo Verification
```

- **Certificates** are generated first so all subsequent Helm installs can use TLS from the start.
- **Contour** provides the ingress controller and LoadBalancer IP used by all services.
- **Harbor** is installed with TLS via Contour Ingress and serves as the container registry.
- **CoreDNS** is patched with static entries using the auto-detected Contour LB IP for all service hostnames.
- **ArgoCD** is installed with ingress via Contour and its admin password is auto-retrieved from the K8s Secret.
- **ArgoCD CLI** is auto-downloaded if not already in PATH.
- **Certificate Distribution** creates Harbor CA and GitLab wildcard TLS secrets in application namespaces.
- **GitLab Operator** must be running before the Runner can register with it.
- **Harbor Proxy** configuration ensures GitLab images pull from Harbor instead of DockerHub.
- **GitLab Runner** must be running before CI pipelines can execute.
- **ArgoCD Cluster Registration** must complete before ArgoCD can deploy applications to the VKS cluster.
- **ArgoCD Application Bootstrap** triggers the GitOps sync that deploys the Microservices Demo.

The teardown script (`scenario3-argocd-teardown.sh`) reverses this order and also removes Contour, Harbor, and ArgoCD.

---

## What the Script Does

### Phase 1: Kubeconfig Setup & Connectivity Check

Sets the `KUBECONFIG` environment variable to the admin kubeconfig file produced by Scenario 1. Verifies the file exists and that the VKS cluster is reachable by running `kubectl get namespaces`. Exits with code 2 if the kubeconfig is missing or the cluster is unreachable.

### Phase 2: Self-Signed Certificate Generation

Generates a self-signed CA certificate and a wildcard TLS certificate for `*.${DOMAIN}` using openssl. If the CA certificate already exists in `CERT_DIR`, the entire phase is skipped (idempotent). Creates: CA key+cert, wildcard CSR (using `examples/scenario3/wildcard.cnf`), signed wildcard cert, and fullchain cert. Exits with code 3 on failure.

### Phase 3: Contour Installation

Adds the Project Contour Helm repository and installs Contour via `helm upgrade --install` with the configured version and values file. Waits for the Contour Envoy LoadBalancer service to receive an external IP address. Stores the IP in `CONTOUR_LB_IP` for use in CoreDNS configuration. Exits with code 4 if installation fails or the LB IP is not assigned within the timeout.

### Phase 4: Harbor Installation

Creates Harbor TLS and CA secrets in the Harbor namespace from the generated certificates. Adds the Harbor Helm repository and installs Harbor via `helm upgrade --install`. Waits for Harbor pods to reach Running state. Exits with code 5 on failure.

### Phase 5: CoreDNS Configuration

Patches the CoreDNS ConfigMap in `kube-system` to add static host entries for Harbor, GitLab, and ArgoCD hostnames, all pointing to the auto-detected Contour LB IP. Restarts CoreDNS pods and waits for them to reach Running state. Exits with code 6 if the patch fails or CoreDNS pods do not restart.

### Phase 6: ArgoCD Installation

Adds the Argo Helm repository and installs ArgoCD via `helm upgrade --install` with the configured version and values file. Waits for ArgoCD server pods to reach Running state. Retrieves the ArgoCD initial admin password from the `argocd-initial-admin-secret` K8s Secret. Exits with code 7 on failure.

### Phase 7: ArgoCD CLI Installation

Checks if the `argocd` CLI is already in PATH. If not, downloads it from GitHub releases and adds it to PATH. Verifies the binary is executable. Exits with code 8 on failure.

### Phase 8: Certificate Distribution

Creates Harbor CA certificate secrets in the GitLab and GitLab Runner namespaces. Creates the GitLab wildcard TLS secret in the GitLab namespace. Creates namespaces with PodSecurity labels if they do not already exist. Uses `--dry-run=client -o yaml | kubectl apply -f -` for idempotent Secret creation. Exits with code 9 on failure.

### Phase 9: GitLab Operator Installation

Adds the GitLab Helm repository, then installs the GitLab Operator via `helm upgrade --install` with the configured version and values file. Waits for the Operator pod to reach Running state, then waits for the GitLab webservice pod to reach Ready state. Exits with code 10 if installation fails or pods do not start.

### Phase 10: GitLab Image Patching / Harbor Proxy Configuration

Verifies that the GitLab Operator values file contains Harbor proxy cache configuration for DockerHub images. This avoids DockerHub rate limits by routing image pulls through Harbor. Prints a warning if proxy configuration is not detected. Exits with code 11 if Harbor hostname is not referenced in the values file.

### Phase 11: GitLab Runner Installation

Installs the GitLab Runner via `helm upgrade --install` with the configured version and values file. The Runner is configured with the Kubernetes executor, privileged mode, and CA certificate trust for both GitLab and Harbor. Waits for the Runner pod to reach Running state. Exits with code 12 if installation fails or the pod does not start.

### Phase 12: ArgoCD Cluster Registration

Runs all ArgoCD CLI commands inside the ArgoCD server pod via `kubectl exec` (the pod already contains the `argocd` binary). This avoids `kubectl port-forward`, which can suffer from persistent "connection reset by peer" errors on some VKS clusters due to stale CNI network namespace references in the kubelet. Authenticates using the auto-retrieved admin password via `argocd login localhost:8080 --plaintext`. Copies the kubeconfig into the pod so `argocd cluster add` can read it. Registers the VKS cluster with ArgoCD using `argocd cluster add`. Waits for the cluster to report a healthy status. Skips registration if the cluster is already registered. Exits with code 13 if authentication or registration fails.

### Phase 13: ArgoCD Application Bootstrap

Applies the ArgoCD Application manifest that defines the Helm charts repository as the source and the VKS cluster as the destination. Waits for the application to reach Synced and Healthy state. Skips creation if the application already exists. Exits with code 14 if the manifest apply fails or the application does not sync.

### Phase 14: Microservices Demo Verification

Checks that pods for all 11 microservices are in a Running state: adservice, cartservice, checkoutservice, currencyservice, emailservice, frontend, loadgenerator, paymentservice, productcatalogservice, recommendationservice, and shippingservice. Prints warnings for any non-running pods. Waits up to 5 minutes for the `frontend-external` LoadBalancer service to receive an external IP from NSX (the service is created by ArgoCD sync moments before this phase runs). Displays the frontend LB IP or falls back to ClusterIP with port-forward instructions. This phase is non-fatal — the script warns but does not block.

### Phase 15: Summary Banner

Prints a summary of all deployed components, their namespaces, versions, and access instructions for GitLab, Harbor, ArgoCD, and the Online Boutique frontend. Displays the Contour LoadBalancer IP and the frontend-external LoadBalancer IP (if different). Lists login credentials for Harbor, ArgoCD, and GitLab (retrieved from K8s Secrets). Lists DNS/hosts file entries to add to your local machine.

---

## Prerequisites

- **Scenario 1 completed successfully** — a VKS cluster must be running and accessible with LoadBalancer support and `nfs` storageClass. The deploy script does not create a cluster; it installs the ArgoCD Consumption Model stack on an existing one.
- **Valid admin kubeconfig file** for the target VKS cluster (produced by Scenario 1). By default the script looks for `./kubeconfig-<CLUSTER_NAME>.yaml`.
- **Helm v3 installed** — required for Contour, Harbor, ArgoCD, GitLab Operator, and GitLab Runner installation.
- **kubectl installed** — required for all Kubernetes operations.
- **openssl installed** — required for self-signed certificate generation.

No Supervisor services are required. The script installs Contour, Harbor, and ArgoCD from scratch. The ArgoCD CLI is auto-downloaded if not already in PATH.

---

## Required Environment Variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `CLUSTER_NAME` | Yes | (none) | VKS cluster name (from Scenario 1) |

### Optional Variables (with defaults)

| Variable | Default | Description |
|---|---|---|
| `KUBECONFIG_FILE` | `./kubeconfig-${CLUSTER_NAME}.yaml` | Path to admin kubeconfig |
| `DOMAIN` | `lab.local` | Base domain for all service hostnames |
| `CONTOUR_VERSION` | `0.3.0` | Contour Helm chart version |
| `HARBOR_VERSION` | `1.16.2` | Harbor Helm chart version |
| `ARGOCD_VERSION` | `7.8.13` | ArgoCD Helm chart version |
| `HARBOR_ADMIN_PASSWORD` | (auto-generated) | Harbor admin password (random 24-char if not set) |
| `HARBOR_SECRET_KEY` | (auto-generated) | Harbor secret key for encryption (random 32-char hex if not set) |
| `HARBOR_DB_PASSWORD` | `changeit` | Harbor database password |
| `CERT_DIR` | `./certs` | Directory for generated certificate files |
| `CONTOUR_NAMESPACE` | `projectcontour` | Namespace for Contour |
| `HARBOR_NAMESPACE` | `harbor` | Namespace for Harbor |
| `GITLAB_OPERATOR_VERSION` | `9.10.0` | GitLab Operator Helm chart version |
| `GITLAB_RUNNER_VERSION` | `0.75.0` | GitLab Runner Helm chart version |
| `GITLAB_RUNNER_TOKEN` | (auto-retrieved) | GitLab Runner registration token (auto-retrieved from GitLab instance if not set) |
| `GITLAB_NAMESPACE` | `gitlab-system` | Namespace for GitLab Operator |
| `GITLAB_RUNNER_NAMESPACE` | `gitlab-runners` | Namespace for GitLab Runner |
| `ARGOCD_NAMESPACE` | `argocd` | ArgoCD namespace |
| `APP_NAMESPACE` | `microservices-demo` | Namespace for the Microservices Demo |
| `HELM_CHARTS_REPO_URL` | `https://github.com/GoogleCloudPlatform/microservices-demo.git` | URL of the Helm charts Git repository |
| `CONTOUR_VALUES_FILE` | `examples/scenario3/contour-values.yaml` | Path to Contour Helm values |
| `HARBOR_VALUES_FILE` | `examples/scenario3/harbor-values.yaml` | Path to Harbor Helm values |
| `ARGOCD_VALUES_FILE` | `examples/scenario3/argocd-values.yaml` | Path to ArgoCD Helm values |
| `GITLAB_OPERATOR_VALUES_FILE` | `examples/scenario3/gitlab-operator-values.yaml` | Path to GitLab Operator Helm values |
| `GITLAB_RUNNER_VALUES_FILE` | `examples/scenario3/gitlab-runner-values.yaml` | Path to GitLab Runner Helm values |
| `ARGOCD_APP_MANIFEST` | `examples/scenario3/argocd-microservices-demo.yaml` | Path to ArgoCD Application manifest |
| `PACKAGE_TIMEOUT` | `900` | Wait loop timeout (seconds) |
| `POLL_INTERVAL` | `15` | Wait loop polling interval (seconds) |

### Derived Variables (computed automatically)

| Variable | Derivation | Description |
|---|---|---|
| `HARBOR_HOSTNAME` | `harbor.${DOMAIN}` | Harbor registry hostname |
| `GITLAB_HOSTNAME` | `gitlab.${DOMAIN}` | GitLab hostname |
| `ARGOCD_HOSTNAME` | `argocd.${DOMAIN}` | ArgoCD server hostname |
| `CONTOUR_LB_IP` | Auto-detected from Contour Envoy LB service | Used for CoreDNS static entries |
| `ARGOCD_PASSWORD` | Auto-retrieved from `argocd-initial-admin-secret` K8s Secret | ArgoCD admin password |

---

## How to Run

### Execute the deploy script

```bash
bash examples/scenario3/scenario3-argocd-deploy.sh
```

Or override variables inline:

```bash
CLUSTER_NAME=my-cluster \
  bash examples/scenario3/scenario3-argocd-deploy.sh
```

Override the domain and versions:

```bash
CLUSTER_NAME=my-cluster \
DOMAIN=mylab.example.com \
CONTOUR_VERSION=0.3.0 \
HARBOR_VERSION=1.16.2 \
ARGOCD_VERSION=7.8.13 \
  bash examples/scenario3/scenario3-argocd-deploy.sh
```

---

## Expected Output

A successful run produces output similar to:

```
[Step 1] Setting up kubeconfig...
✓ Kubeconfig set and cluster 'my-cluster' is reachable
[Step 2] Generating self-signed certificates...
✓ Self-signed CA certificate generated
✓ Wildcard certificate CSR generated
✓ Wildcard certificate signed by CA
✓ Fullchain certificate created
✓ Certificates ready in './certs'
[Step 3] Installing Contour ingress controller...
✓ Contour Helm release installed
  Waiting for Contour Envoy LoadBalancer to get external IP... (0s/900s elapsed)
✓ Contour installed and Envoy LoadBalancer IP: 10.0.0.50
[Step 4] Installing Harbor container registry...
✓ Harbor Helm release installed
  Waiting for Harbor pods to be running... (0s/900s elapsed)
✓ Harbor installed and running in namespace 'harbor'
[Step 5] Configuring CoreDNS with static host entries...
✓ CoreDNS ConfigMap patched with static entries for 'harbor.lab.local', 'gitlab.lab.local', and 'argocd.lab.local'
✓ CoreDNS configured and running with static host entries
[Step 6] Installing ArgoCD...
✓ ArgoCD Helm release installed
  Waiting for ArgoCD server pods to be running... (0s/900s elapsed)
✓ ArgoCD installed and running in namespace 'argocd'
[Step 7] Installing ArgoCD CLI...
✓ ArgoCD CLI downloaded and installed to /tmp/argocd
✓ ArgoCD CLI is available
[Step 8] Distributing certificates to application namespaces...
✓ Certificates distributed: Harbor CA in 'gitlab-system' and 'gitlab-runners', GitLab wildcard TLS in 'gitlab-system'
[Step 9] Installing GitLab Operator...
  Waiting for GitLab Operator pod to be running... (0s/900s elapsed)
✓ GitLab Operator installed and running
  Waiting for GitLab webservice pod to be ready... (0s/900s elapsed)
✓ GitLab Operator and webservice are running in namespace 'gitlab-system'
[Step 10] Configuring Harbor proxy for GitLab images...
✓ Harbor proxy configuration verified for GitLab images
[Step 11] Installing GitLab Runner...
  Waiting for GitLab Runner pod to be running... (0s/900s elapsed)
✓ GitLab Runner installed and running in namespace 'gitlab-runners'
[Step 12] Registering cluster with ArgoCD...
✓ Cluster 'my-cluster' registered and healthy in ArgoCD
[Step 13] Bootstrapping ArgoCD application for Microservices Demo...
  Waiting for ArgoCD application 'microservices-demo' to be Synced and Healthy... (0s/900s elapsed)
✓ ArgoCD application 'microservices-demo' is Synced and Healthy
[Step 14] Verifying Microservices Demo deployment...
✓ Service 'adservice' is running
✓ Service 'cartservice' is running
  ... (all 11 services)
✓ Microservices Demo verification complete
[Step 15] Deployment summary...
=============================================
  VCF 9 Scenario 3 — Deployment Complete
=============================================
  ...
✓ Scenario 3 deployment complete
```

---

## Typical Timing

| Phase | Typical Duration | Notes |
|---|---|---|
| Phase 1: Kubeconfig Setup | < 5 seconds | |
| Phase 2: Certificate Generation | < 5 seconds | Skipped if certs already exist |
| Phase 3: Contour Installation | 1–3 minutes | Includes LB IP assignment wait |
| Phase 4: Harbor Installation | 3–5 minutes | Includes pod startup wait |
| Phase 5: CoreDNS Configuration | 15–30 seconds | Includes pod restart wait |
| Phase 6: ArgoCD Installation | 1–3 minutes | Includes pod startup wait |
| Phase 7: ArgoCD CLI Installation | < 15 seconds | Skipped if already in PATH |
| Phase 8: Certificate Distribution | < 15 seconds | Includes namespace creation |
| Phase 9: GitLab Operator | 5–10 minutes | Webservice pod takes 5–10 minutes |
| Phase 10: Harbor Proxy | < 5 seconds | Verification only |
| Phase 11: GitLab Runner | 1–2 minutes | |
| Phase 12: ArgoCD Registration | 15–30 seconds | |
| Phase 13: ArgoCD App Bootstrap | 2–5 minutes | Depends on Helm chart sync time |
| Phase 14: Demo Verification | 30s–5 minutes | Includes frontend LB IP wait |
| Phase 15: Summary | < 1 second | |
| **Total** | **~20–35 minutes** | GitLab Operator startup dominates |

---

## Certificate Generation

The script generates self-signed certificates using openssl. If certificates already exist in `CERT_DIR`, the generation phase is skipped entirely (idempotent).

Generated files in `CERT_DIR`:
- `ca.key` — CA private key
- `ca.crt` — CA certificate
- `wildcard.key` — Wildcard certificate private key
- `wildcard.csr` — Wildcard certificate signing request
- `wildcard.crt` — Signed wildcard certificate
- `fullchain.crt` — Wildcard cert + CA cert concatenated

The wildcard certificate covers `*.${DOMAIN}` and `${DOMAIN}` (SANs configured in `examples/scenario3/wildcard.cnf`).

To use your own certificates instead, pre-populate `CERT_DIR` with `ca.crt`, `wildcard.key`, `wildcard.crt`, and `fullchain.crt` before running the script.

---

## Known Limitations

- **DockerHub rate limits**: GitLab component images default to DockerHub. The script configures Harbor as a proxy cache to avoid rate limits. If Harbor proxy is not configured, image pulls may fail with `429 Too Many Requests`.
- **CoreDNS restart timing**: After patching the CoreDNS ConfigMap, pods need a few seconds to restart. DNS resolution may be briefly unavailable during the restart window.
- **GitLab pod startup time**: The GitLab webservice pod can take 5–10+ minutes to reach Ready state. This is normal — the Operator provisions multiple sub-components sequentially.
- **Self-signed certificates**: The generated certificates are self-signed and not trusted by browsers or external clients. For production use, replace with certificates from a trusted CA.
- **Single cluster target**: The script targets one VKS cluster at a time. To deploy to multiple clusters, run the script once per cluster with different `CLUSTER_NAME` and `KUBECONFIG_FILE` values.
