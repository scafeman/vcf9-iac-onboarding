# Scenario 2: VKS Metrics Observability Deploy Script

## Overview

`scenario2-vks-metrics-deploy.sh` installs the metrics observability stack on an existing VKS cluster provisioned by Scenario 1. It registers the TKG standard packages repository, installs Telegraf for node and pod metrics collection, installs cert-manager and Contour as prerequisites, installs Prometheus for metrics storage and querying, and deploys Grafana with pre-configured Kubernetes dashboards for visualization.

The script is fully non-interactive. All configuration is driven by environment variables (loaded from `.env` via Docker Compose). No user input is required during execution.

---

## What the Script Does

### Phase 1: Kubeconfig Setup & Connectivity Check

Sets the `KUBECONFIG` environment variable to the admin kubeconfig file produced by Scenario 1. Verifies the file exists and that the VKS cluster is reachable by running `kubectl get namespaces`. Exits with code 2 if the kubeconfig is missing or the cluster is unreachable.

### Phase 2: Node Sizing Advisory

Queries the cluster's worker nodes for total allocatable CPU (in millicores). If the total is below the configurable `NODE_CPU_THRESHOLD` (default: 4000m), prints a warning recommending that worker nodes be scaled to the `best-effort-large` VM class. This is a non-blocking advisory — installation proceeds regardless.

### Phase 3: Package Namespace Creation

Creates the `tkg-packages` namespace (or the value of `PACKAGE_NAMESPACE`) where all TKG packages will be installed. Labels the namespace with the `privileged` PodSecurity standard so that Telegraf and other system-level packages can schedule pods. Skips creation if the namespace already exists.

### Phase 4: TKG Package Repository Registration

Registers the TKG standard packages OCI repository using `vcf package repository add`. Polls the repository status until it reaches a reconciled state or the timeout is reached. Skips registration if the repository already exists.

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

Installs Contour (`contour.kubernetes.vmware.com`) as a prerequisite for Prometheus HTTP ingress. Polls until reconciled. Contour depends on cert-manager, so it is installed after cert-manager.

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

### Phase 10: Grafana Instance, Datasource & Dashboards

Applies three manifests to configure Grafana:

1. **`grafana-instance.yaml`** — Creates a Grafana instance with anonymous viewer access and a ClusterIP service on port 3000.
2. **`grafana-datasource-prometheus.yaml`** — Configures Prometheus (running in `tkg-packages`) as the default Grafana datasource.
3. **`grafana-dashboards-k8s.yaml`** — Imports community Kubernetes dashboards:
   - K8s Global Overview (cluster-wide resource usage)
   - Node Exporter Full (detailed node CPU/memory/disk/network)
   - K8s Pods Overview (per-pod resource usage)

### Phase 11: Verification

Lists all installed packages via `vcf package installed list`, checks that Telegraf, Prometheus, and Grafana pods are in a Running state, and prints warnings for any pods that are not Running. Prints a summary banner with all installed components and instructions for accessing Grafana.

---

## Prerequisites

- **Scenario 1 completed successfully** — a VKS cluster must be running and accessible. The deploy script does not create a cluster; it installs observability packages on an existing one.
- **Valid admin kubeconfig file** for the target VKS cluster (produced by Scenario 1's Phase 5). By default the script looks for `./kubeconfig-<CLUSTER_NAME>.yaml`.
- **Docker and Docker Compose installed** — the script runs inside the `vcf9-dev` container.
- **Helm v3** — required for the Grafana Operator installation (Phase 9). Helm is pre-installed in the `vcf9-dev` container via the Dockerfile. The deploy script validates that `helm` is available before starting.

---

## Required Environment Variables

Set these in the `.env` file at the project root. Docker Compose loads them into the container automatically.

| Variable | Required | Description | Example |
|---|---|---|---|
| `CLUSTER_NAME` | Yes | VKS cluster name (from Scenario 1) | `uniphore-dev-project-01-clus-01` |
| `TELEGRAF_VERSION` | Yes | Telegraf package version | `1.37.1+vmware.1-vks.1` |

### Optional Variables (with defaults)

| Variable | Default | Description |
|---|---|---|
| `KUBECONFIG_FILE` | `./kubeconfig-${CLUSTER_NAME}.yaml` | Path to admin kubeconfig |
| `PACKAGE_NAMESPACE` | `tkg-packages` | Namespace for TKG packages |
| `PACKAGE_REPO_NAME` | `tkg-packages` | Package repository name |
| `PACKAGE_REPO_URL` | `projects.packages.broadcom.com/...` | OCI repository URL |
| `TELEGRAF_VALUES_FILE` | `examples/scenario2/telegraf-values.yaml` | Path to Telegraf values file |
| `PROMETHEUS_VALUES_FILE` | `examples/scenario2/prometheus-values.yaml` | Path to Prometheus values file |
| `STORAGE_CLASS` | `nfs` | StorageClass for Prometheus |
| `NODE_CPU_THRESHOLD` | `4000` | Advisory CPU threshold (millicores) |
| `GRAFANA_NAMESPACE` | `grafana` | Namespace for Grafana |
| `GRAFANA_INSTANCE_FILE` | `examples/scenario2/grafana-instance.yaml` | Path to Grafana instance manifest |
| `GRAFANA_DATASOURCE_FILE` | `examples/scenario2/grafana-datasource-prometheus.yaml` | Path to Grafana datasource manifest |
| `GRAFANA_DASHBOARDS_FILE` | `examples/scenario2/grafana-dashboards-k8s.yaml` | Path to Grafana dashboards manifest |
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
docker exec vcf9-dev bash examples/scenario2/scenario2-vks-metrics-deploy.sh
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

After the deploy completes, Grafana is running inside the cluster as a ClusterIP service. To access it from your workstation, use `kubectl port-forward` with the kubeconfig you downloaded for the cluster:

```bash
kubectl --kubeconfig=./kubeconfig-<CLUSTER_NAME>.yaml \
  port-forward -n grafana svc/grafana-service 3000:3000
```

Then open **http://localhost:3000** in your browser.

If port 3000 is already in use on your machine, pick a different local port:

```bash
kubectl --kubeconfig=./kubeconfig-<CLUSTER_NAME>.yaml \
  port-forward -n grafana svc/grafana-service 8080:3000
```

Then open **http://localhost:8080**.

Anonymous viewer access is enabled by default, so no login is required to view dashboards. To make changes (create dashboards, add datasources), log in with the default admin credentials: `admin` / `admin`.

### Accessing Prometheus directly

You can also port-forward to the Prometheus query UI:

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
Package Repository → cert-manager → Contour → Prometheus → Grafana (datasource)
```

- The **Package Repository** must be registered first — all TKG packages are sourced from it.
- **Telegraf** is independent of the Prometheus chain and is installed immediately after the repository.
- **cert-manager** must be installed before Contour and Prometheus (provides TLS certificate management).
- **Contour** must be installed before Prometheus (provides HTTP ingress).
- **Prometheus** must be installed before Grafana (Grafana uses it as a datasource).
- **Grafana** is installed last, after Prometheus is reconciled and serving metrics.

The teardown script (`scenario2-vks-metrics-teardown.sh`) reverses this order: Grafana → Prometheus → Contour → cert-manager → Telegraf → repository → namespace.

---

## Node Sizing Advisory

The observability stack (Telegraf + cert-manager + Contour + Prometheus + Grafana) requires significant CPU and memory resources. Before installing packages, the script checks the total allocatable CPU across all worker nodes.

If the total allocatable CPU is below the `NODE_CPU_THRESHOLD` (default: 4000 millicores), the script prints a warning:

```
⚠ WARNING: Total allocatable CPU (2000m) is below the recommended threshold (4000m)
⚠ WARNING: Consider scaling worker nodes to 'best-effort-large' VM class to avoid pod scheduling failures
```

This is a non-blocking advisory. The script proceeds with installation regardless, but pods may fail to schedule if nodes lack sufficient resources. If you encounter pod scheduling failures after deployment, scale your worker nodes to the `best-effort-large` (or `large`) VM class and the pods will reschedule automatically.
