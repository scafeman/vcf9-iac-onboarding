# Deploy Metrics: VKS Metrics Observability Deploy Script

## Overview

`deploy-metrics.sh` installs the metrics observability stack on an existing VKS cluster provisioned by Deploy Cluster. It registers the VKS standard packages repository, installs Telegraf for node and pod metrics collection, installs cert-manager and Contour as prerequisites, installs Prometheus for metrics storage and querying, and deploys Grafana with pre-configured Kubernetes dashboards for visualization.

Grafana is exposed externally via a Contour Ingress with TLS termination using a self-signed wildcard certificate (same pattern as Deploy GitOps). Authentication is enabled with a randomly generated admin password displayed in the deployment summary.

The script is fully non-interactive. All configuration is driven by environment variables (loaded from `.env` via Docker Compose). No user input is required during execution.

---

## What the Script Does

### Phase 1: Kubeconfig Setup & Connectivity Check

Sets the `KUBECONFIG` environment variable to the admin kubeconfig file produced by Deploy Cluster. Verifies the file exists and that the VKS cluster is reachable by running `kubectl get namespaces`. Exits with code 2 if the kubeconfig is missing or the cluster is unreachable.

### Phase 2: Node Sizing Advisory

Queries the cluster's worker nodes for total allocatable CPU (in millicores). If the total is below the configurable `NODE_CPU_THRESHOLD` (default: 4000m), prints a warning recommending that worker nodes be scaled to the `best-effort-large` VM class. This is a non-blocking advisory — installation proceeds regardless.

### Phase 3: Package Namespace Creation

Creates the `tkg-packages` namespace (or the value of `PACKAGE_NAMESPACE`) where all VKS standard packages will be installed. Labels the namespace with the `privileged` PodSecurity standard so that Telegraf and other system-level packages can schedule pods. Skips creation if the namespace already exists.

### Phase 4: VKS Package Repository Registration

Registers the VKS standard packages OCI repository using `vcf package repository add`. Polls the repository status until it reaches a reconciled state or the timeout is reached. Skips registration if the repository already exists.

```
vcf package repository add <PACKAGE_REPO_NAME> \
  --url <PACKAGE_REPO_URL> \
  -n <PACKAGE_NAMESPACE>
```

### Phase 5: Telegraf Installation

Installs the Telegraf metrics agent package (`telegraf.kubernetes.vmware.com`) with a customizable values file for collection intervals, output destinations, and resource limits. Polls until reconciled.

```
vcf package install telegraf \
  -p telegraf.kubernetes.vmware.com \
  -v <TELEGRAF_VERSION> \
  --values-file <TELEGRAF_VALUES_FILE> \
  -n <PACKAGE_NAMESPACE>
```

### Phase 6: cert-manager Installation

Installs cert-manager (`cert-manager.kubernetes.vmware.com`) as a prerequisite for Prometheus TLS certificate management. Polls until reconciled.

### Phase 7: Contour Installation

Installs Contour (`contour.kubernetes.vmware.com`) as a prerequisite for Prometheus HTTP ingress and Grafana external access. Polls until reconciled. Contour depends on cert-manager, so it is installed after cert-manager.

### Phase 7b: Self-Signed Certificate Generation

Generates a self-signed CA and wildcard certificate for `*.lab.local` (or `*.<DOMAIN>`). If certificates already exist in the `./certs` directory (e.g., from a previous Deploy GitOps deployment), this phase is skipped. The wildcard certificate is used for TLS termination on the Grafana Ingress.

### Phase 7c: Contour LoadBalancer IP & CoreDNS Configuration

Waits for the Contour Envoy LoadBalancer service (in `tanzu-system-ingress`) to receive an external IP from NSX. Patches the CoreDNS ConfigMap with a static host entry mapping `grafana.<DOMAIN>` to the Contour LB IP, then restarts CoreDNS pods. Skips the patch if the entry already exists.

### Phase 8: Prometheus Installation

Installs Prometheus (`prometheus.kubernetes.vmware.com`) for metrics scraping, storage, and querying. Uses a values file to configure the `storageClass` to use the NFS storage class available in the VKS cluster. Polls until reconciled.

```
vcf package install prometheus \
  -p prometheus.kubernetes.vmware.com \
  --values-file <PROMETHEUS_VALUES_FILE> \
  -n <PACKAGE_NAMESPACE>
```

### Phase 9: Grafana Operator Installation

Creates the `grafana` namespace, labels it with the `baseline` PodSecurity standard, and installs the [Grafana Operator](https://grafana.github.io/grafana-operator/) via Helm. The operator manages Grafana instances, datasources, and dashboards as Kubernetes custom resources. Waits for the operator pod to reach Running state.

### Phase 10: Grafana Instance, Datasource, Dashboards & Ingress

Creates a TLS secret from the wildcard certificate, then applies three manifests to configure Grafana:

1. **`grafana-instance.yaml`** — Creates a Grafana instance with authentication enabled (anonymous access disabled). The admin password is substituted at runtime from the `GRAFANA_ADMIN_PASSWORD` variable.
2. **`grafana-datasource-prometheus.yaml`** — Configures Prometheus (running in `tkg-packages`) as the default Grafana datasource.
3. **`grafana-dashboards-k8s.yaml`** — Imports community Kubernetes dashboards:
   - K8s Global Overview (cluster-wide resource usage)
   - Node Exporter Full (detailed node CPU/memory/disk/network)
   - K8s Pods Overview (per-pod resource usage)

Finally, creates a Kubernetes Ingress resource with `ingressClassName: contour` and TLS termination, routing `grafana.<DOMAIN>` to the Grafana ClusterIP service.

### Phase 11: Verification

Lists all installed packages via `vcf package installed list`, checks that Telegraf, Prometheus, and Grafana pods are in a Running state, and prints warnings for any pods that are not Running. Prints a summary banner with all installed components, the Contour LB IP, Grafana URL, and login credentials.

---

## Prerequisites

- **Deploy Cluster completed successfully** — a VKS cluster must be running and accessible. The deploy script does not create a cluster; it installs observability packages on an existing one.
- **Valid admin kubeconfig file** for the target VKS cluster (produced by Deploy Cluster's Phase 5). By default the script looks for `./kubeconfig-<CLUSTER_NAME>.yaml`.
- **Docker and Docker Compose installed** — the script runs inside the `vcf9-dev` container.
- **Helm v4** — required for the Grafana Operator installation (Phase 9). Helm is pre-installed in the `vcf9-dev` container via the Dockerfile.
- **openssl** — required for self-signed certificate generation (Phase 7b). Pre-installed in the `vcf9-dev` container.

---

## Required Environment Variables

Set these in the `.env` file at the project root. Docker Compose loads them into the container automatically.

| Variable | Required | Description | Example |
|---|---|---|---|
| `CLUSTER_NAME` | Yes | VKS cluster name (from Deploy Cluster) | `my-cluster-01` |
| `TELEGRAF_VERSION` | Yes | Telegraf package version | `1.37.1+vmware.1-vks.1` |

### Optional Variables (with defaults)

| Variable | Default | Description |
|---|---|---|
| `KUBECONFIG_FILE` | `./kubeconfig-${CLUSTER_NAME}.yaml` | Path to admin kubeconfig |
| `DOMAIN` | `lab.local` | Base domain for Grafana hostname |
| `PACKAGE_NAMESPACE` | `tkg-packages` | Namespace for VKS standard packages |
| `PACKAGE_REPO_NAME` | `tkg-packages` | Package repository name |
| `PACKAGE_REPO_URL` | `projects.packages.broadcom.com/...` | OCI repository URL |
| `TELEGRAF_VALUES_FILE` | `examples/deploy-metrics/telegraf-values.yaml` | Path to Telegraf values file |
| `PROMETHEUS_VALUES_FILE` | `examples/deploy-metrics/prometheus-values.yaml` | Path to Prometheus values file |
| `STORAGE_CLASS` | `nfs` | StorageClass for Prometheus |
| `NODE_CPU_THRESHOLD` | `4000` | Advisory CPU threshold (millicores) |
| `GRAFANA_NAMESPACE` | `grafana` | Namespace for Grafana |
| `GRAFANA_ADMIN_PASSWORD` | (auto-generated) | Grafana admin password (random 24-char base64) |
| `CERT_DIR` | `./certs` | Directory for TLS certificates |
| `CONTOUR_INGRESS_NAMESPACE` | `tanzu-system-ingress` | Namespace for VKS Contour Envoy service |
| `GRAFANA_INSTANCE_FILE` | `examples/deploy-metrics/grafana-instance.yaml` | Path to Grafana instance manifest |
| `GRAFANA_DATASOURCE_FILE` | `examples/deploy-metrics/grafana-datasource-prometheus.yaml` | Path to Grafana datasource manifest |
| `GRAFANA_DASHBOARDS_FILE` | `examples/deploy-metrics/grafana-dashboards-k8s.yaml` | Path to Grafana dashboards manifest |
| `PACKAGE_TIMEOUT` | `600` | Package reconciliation timeout (seconds) |
| `POLL_INTERVAL` | `15` | Polling interval for wait loops (seconds) |

---

## How to Run

### Start the dev container (if not already running)

```bash
docker compose up -d --build
```

### Execute the deploy script

```bash
docker exec vcf9-dev bash examples/deploy-metrics/deploy-metrics.sh
```

### Monitor from a second terminal (optional)

```bash
# Watch installed packages
docker exec vcf9-dev bash -c "export KUBECONFIG=./kubeconfig-<CLUSTER_NAME>.yaml && vcf package installed list -n tkg-packages"

# Watch pod status
docker exec vcf9-dev bash -c "export KUBECONFIG=./kubeconfig-<CLUSTER_NAME>.yaml && kubectl get pods -n tkg-packages -w"
```

---

## Accessing Grafana

After the deploy completes, Grafana is accessible via HTTPS through the Contour ingress controller.

### 1. Add DNS entry to your local machine

The deployment summary prints the Contour LoadBalancer IP and the required hosts file entry. Add it to your local machine:

**Windows (PowerShell as Administrator):**
```powershell
Add-Content C:\Windows\System32\drivers\etc\hosts "<CONTOUR_LB_IP> grafana.lab.local"
```

**Linux/macOS:**
```bash
echo "<CONTOUR_LB_IP> grafana.lab.local" | sudo tee -a /etc/hosts
```

### 2. Import the CA certificate (optional, removes browser warnings)

If you haven't already imported the self-signed CA certificate from Deploy GitOps:

**Windows (PowerShell as Administrator):**
```powershell
Import-Certificate -FilePath ".\certs\ca.crt" -CertStoreLocation Cert:\LocalMachine\Root
```

### 3. Open Grafana

Navigate to **https://grafana.lab.local** in your browser.

Login with the credentials shown in the deployment summary:
- Username: `admin`
- Password: (shown in deployment output)

### Accessing Prometheus directly

Prometheus is not exposed externally. Use `kubectl port-forward` to access the query UI:

```bash
kubectl --kubeconfig=./kubeconfig-<CLUSTER_NAME>.yaml \
  port-forward -n tkg-packages svc/prometheus-server 9090:80
```

Then open **http://localhost:9090**.

---

## Dependency Order

The observability stack has a specific dependency chain that the script respects:

```
Package Repository → Telegraf (independent)
Package Repository → cert-manager → Contour → Certificates → CoreDNS → Prometheus → Grafana (Ingress + datasource)
```

- The **Package Repository** must be registered first — all VKS standard packages are sourced from it.
- **Telegraf** is independent of the Prometheus chain and is installed immediately after the repository.
- **cert-manager** must be installed before Contour and Prometheus (provides TLS certificate management).
- **Contour** must be installed before Prometheus (provides HTTP ingress) and before Grafana (provides external access).
- **Certificates** must be generated before the Grafana Ingress can serve HTTPS traffic.
- **CoreDNS** must be patched with the Grafana hostname before Grafana is accessible by name.
- **Prometheus** must be installed before Grafana (Grafana uses it as a datasource).
- **Grafana** is installed last, after Prometheus is reconciled and serving metrics.

The teardown script (`teardown-metrics.sh`) reverses this order: Grafana → Prometheus → Contour → cert-manager → Telegraf → repository → namespace.

---

## Node Sizing Advisory

The observability stack (Telegraf + cert-manager + Contour + Prometheus + Grafana) requires significant CPU and memory resources. Before installing packages, the script checks the total allocatable CPU across all worker nodes.

If the total allocatable CPU is below the `NODE_CPU_THRESHOLD` (default: 4000 millicores), the script prints a warning:

```
⚠ WARNING: Total allocatable CPU (2000m) is below the recommended threshold (4000m)
⚠ WARNING: Consider scaling worker nodes to 'best-effort-large' VM class to avoid pod scheduling failures
```

This is a non-blocking advisory. The script proceeds with installation regardless, but pods may fail to schedule if nodes lack sufficient resources. If you encounter pod scheduling failures after deployment, scale your worker nodes to the `best-effort-large` (or `large`) VM class and the pods will reschedule automatically.
