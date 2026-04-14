# Deploy HA VM App — High-Availability Three-Tier Application

## Overview

`deploy-ha-vm-app.sh` deploys a traditional high-availability three-tier application entirely on VCF VM Service VMs — the VCF equivalent of deploying a classic HA application on AWS EC2 instances with 2× ALB and RDS. Unlike container-based examples, this deploys all application tiers on VMs provisioned via the VirtualMachine CRD, with VirtualMachineService resources providing load balancing.

> See the [Architecture Diagram](../../docs/architecture/deploy-ha-vm-app.md) for a visual overview of this deployment pattern.

**Architecture:**
- **Web Tier:** 2 Ubuntu 24.04 VMs (`web-vm-01`, `web-vm-02`) running Next.js, fronted by a public VirtualMachineService LoadBalancer (`ha-web-lb`) on port 80
- **API Tier:** 2 Ubuntu 24.04 VMs (`api-vm-01`, `api-vm-02`) running Node.js/Express, fronted by a VirtualMachineService LoadBalancer (`ha-api-lb`) on the API port
- **DB Tier:** DSM PostgresCluster provisioned via the `databases.dataservices.vmware.com/v1alpha1` CRD (managed PostgreSQL)

The script is fully non-interactive. All configuration is driven by environment variables (loaded from `.env` via Docker Compose). No user input is required during execution.

---

## AWS to VCF Mapping

| AWS Component | VCF Equivalent | Notes |
|---|---|---|
| 2× EC2 (web) + ALB | 2× VirtualMachine + VirtualMachineService LoadBalancer | `ha-web-lb` maps port 80 → frontend port |
| 2× EC2 (API) + ALB | 2× VirtualMachine + VirtualMachineService LoadBalancer | `ha-api-lb` provides stable API VIP |
| RDS PostgreSQL Multi-AZ | DSM PostgresCluster | `databases.dataservices.vmware.com/v1alpha1` |
| EC2 Instance Type | `vmClass` | `kubectl get virtualmachineclasses` to list |
| EC2 AMI | `VM_IMAGE` (content library image) | Ubuntu 24.04 server cloud image |
| EC2 User Data | cloud-init Secret | Installs Node.js, configures app, starts systemd service |
| ALB Target Group | VirtualMachineService `selector` | Label-based: `app: ha-web` / `app: ha-api` |
| RDS Allocated Storage | `storageSpace` (e.g., `20Gi`) | Spec field on PostgresCluster |
| RDS Multi-AZ | `replicas` (0 = Single Server, 1 = HA) | Spec field on PostgresCluster |

---

## Prerequisites

- **VCF CLI** installed and configured with a supervisor context that has access to the target namespace
- **kubectl** installed
- **curl** installed for connectivity verification
- **Valid API token** for the VCFA portal
- **DSM infrastructure policy** configured in the supervisor namespace (via VCFA UI)
- **Ubuntu 24.04 image** available in the content library (`ubuntu-24.04-server-cloudimg-amd64`)
- **VM class** available in the namespace (default: `best-effort-medium`)

---

## What the Script Does

### Phase 0: VCF CLI Context Setup

Creates a VCF CLI context and switches to the supervisor namespace. This establishes the kubectl context for all subsequent operations.

### Phase 1: Provision DSM PostgresCluster (DB Tier)

Creates an admin password Secret in the supervisor namespace, then applies a `databases.dataservices.vmware.com/v1alpha1 PostgresCluster` manifest. Waits for the PostgresCluster's `status.connection.host` to be populated and `status.connection.port` to be non-zero (timeout: 1800s). Extracts connection details (host, port, database name, username, password) for use by the API tier cloud-init.

An idempotency check skips creation if the PostgresCluster or Secret already exists.

### Phase 2: API Tier VM Provisioning

Creates cloud-init secrets and VirtualMachine resources for `api-vm-01` and `api-vm-02`. Each cloud-init:
- Installs Node.js 20.x via NodeSource
- Writes the Express API server (`server.js` + `package.json`)
- Sets DSM connection environment variables (`POSTGRES_HOST`, `POSTGRES_PORT`, etc.)
- Installs npm dependencies and starts the API via systemd

Waits for each VM to reach PoweredOn state and obtain an IP address (timeout: 600s). Applies `app: ha-api` label for VirtualMachineService selector matching.

An idempotency check skips creation if the VirtualMachine already exists.

### Phase 3: API Tier VirtualMachineService LoadBalancer

Creates `ha-api-lb` VirtualMachineService (LoadBalancer) that selects VMs with `app: ha-api` label. Maps `API_PORT` → `API_PORT`. Waits for the LoadBalancer to receive an external IP. This provides a stable VIP for the web tier to connect to.

### Phase 4: Web Tier VM Provisioning

Creates cloud-init secrets and VirtualMachine resources for `web-vm-01` and `web-vm-02`. Each cloud-init:
- Installs Node.js 20.x via NodeSource
- Writes the Next.js dashboard application
- Sets `API_HOST` to the API VIP address from Phase 3
- Builds and starts the Next.js server via systemd

Waits for each VM to reach PoweredOn state and obtain an IP address (timeout: 600s). Applies `app: ha-web` label for VirtualMachineService selector matching.

### Phase 5: Web Tier VirtualMachineService LoadBalancer

Creates `ha-web-lb` VirtualMachineService (LoadBalancer) that selects VMs with `app: ha-web` label. Maps port 80 → `FRONTEND_PORT`. Waits for the LoadBalancer to receive an external IP (timeout: 300s).

### Phase 6: End-to-End Connectivity Verification

Performs end-to-end validation:
1. **Frontend HTTP check** — `curl` to the Web LB external IP, expects HTTP 200
2. **API health check** — `curl` to `/healthz` via the Web LB, expects HTTP 200

Prints a deployment summary with the Web LB external IP, all VM names and IPs, and the DSM connection endpoint.

### sslip.io DNS Alias

When `USE_SSLIP_DNS=true` (default), the deployment summary includes an sslip.io alias for the Web LB IP (e.g., `ha-web.<IP>.sslip.io`). Since the HA VM App uses VirtualMachineService LoadBalancers (not Kubernetes Ingress), no Ingress or TLS certificate is created — the sslip.io hostname is a convenience alias that resolves to the Web LB external IP without requiring `/etc/hosts` entries. VM-based LoadBalancers cannot use Kubernetes Ingress, so the sslip.io hostname is printed in the summary for convenience only.

---

## Required Environment Variables

Set these in the `.env` file at the project root. Docker Compose loads them into the container automatically.

| Variable | Required | Default | Description |
|---|---|---|---|
| `SUPERVISOR_NAMESPACE` | Yes | — | Supervisor namespace for all resources |
| `PROJECT_NAME` | Yes | — | VCF project name |
| `VCF_API_TOKEN` | Yes | — | API token from the VCFA portal |
| `VCFA_ENDPOINT` | Yes | — | VCFA hostname (no `https://` prefix) |
| `TENANT_NAME` | Yes | — | SSO tenant/organization |
| `CONTEXT_NAME` | Yes | — | Local VCF CLI context name |
| `DSM_INFRA_POLICY` | Yes | — | DSM infrastructure policy name |
| `DSM_STORAGE_POLICY` | Yes | — | vSphere storage policy name |
| `ADMIN_PASSWORD` | Yes | — | Admin password for the PostgresCluster |
| `VM_CLASS` | No | `best-effort-medium` | VM Service compute class for web/API VMs |
| `VM_IMAGE` | No | `ubuntu-24.04-server-cloudimg-amd64` | Content library image name |
| `STORAGE_CLASS` | No | `nfs` | Storage class for VMs |
| `DSM_CLUSTER_NAME` | No | `pg-clus-01` | PostgresCluster resource name |
| `DSM_VM_CLASS` | No | `best-effort-large` | VM class for DSM instances (4 CPU minimum) |
| `DSM_STORAGE_SPACE` | No | `20Gi` | Storage allocation for PostgresCluster |
| `POSTGRES_VERSION` | No | `17.7+vmware.v9.0.2.0` | PostgreSQL version |
| `POSTGRES_REPLICAS` | No | `0` | Topology: `0` = Single Server, `1` = HA |
| `POSTGRES_DB` | No | `assetdb` | Database name |
| `ADMIN_PASSWORD_SECRET_NAME` | No | `admin-pw-pg-clus-01` | Name of the admin password Secret |
| `API_PORT` | No | `3001` | API service port |
| `FRONTEND_PORT` | No | `3000` | Frontend container port |
| `CONTAINER_REGISTRY` | No | `scafeman` | Container registry prefix |
| `IMAGE_TAG` | No | `latest` | Container image tag |
| `VM_TIMEOUT` | No | `600` | Seconds to wait for VM PoweredOn |
| `DSM_TIMEOUT` | No | `1800` | Seconds to wait for PostgresCluster Ready |
| `LB_TIMEOUT` | No | `300` | Seconds to wait for LoadBalancer external IP |
| `POLL_INTERVAL` | No | `30` | Seconds between polling attempts |

---

## How to Trigger

### Docker exec (recommended)

```bash
docker exec vcf9-dev bash examples/deploy-ha-vm-app/deploy-ha-vm-app.sh
```

### GitHub Actions UI

Navigate to **Actions → Deploy HA VM App → Run workflow**, enter the required parameters (supervisor namespace, DSM infra policy, DSM storage policy), and click **Run workflow**.

### curl (repository_dispatch)

```bash
curl -X POST \
  -H "Authorization: token ghp_xxxxxxxxxxxx" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/OWNER/REPO/dispatches" \
  -d '{
    "event_type": "deploy-ha-vm-app",
    "client_payload": {
      "supervisor_namespace": "my-project-ns",
      "dsm_infra_policy": "my-dsm-policy",
      "dsm_storage_policy": "nfs"
    }
  }'
```

---

## Expected Output

A successful run produces output like this:

```
[Step 0] Creating VCF CLI context and switching to supervisor namespace...
✓ VCF CLI context 'my-context' created, switched to namespace context 'my-context:my-project-ns'
[Step 1] Provisioning DSM PostgresCluster 'pg-clus-01' in supervisor namespace 'my-project-ns'...
✓ Admin password Secret 'admin-pw-pg-clus-01' created
✓ PostgresCluster 'pg-clus-01' manifest applied to namespace 'my-project-ns'
[Step 1b] Waiting for PostgresCluster 'pg-clus-01' to reach Ready status with connection details...
  Waiting for PostgresCluster 'pg-clus-01' connection details... (0s/1800s elapsed)
✓ PostgresCluster 'pg-clus-01' is Ready
✓ DSM PostgreSQL connection: 10.0.2.50:5432/assetdb (user: pgadmin)
✓ Phase 1 complete — DSM PostgresCluster 'pg-clus-01' provisioned
[Step 2] Provisioning API tier VMs in supervisor namespace 'my-project-ns'...
--- Provisioning api-vm-01 ---
✓ Cloud-init Secret 'api-vm-01-cloud-init' created
✓ VirtualMachine 'api-vm-01' manifest applied to namespace 'my-project-ns'
✓ VM 'api-vm-01' is powered on
✓ VM 'api-vm-01' IP address: 172.30.0.140
--- Provisioning api-vm-02 ---
✓ Cloud-init Secret 'api-vm-02-cloud-init' created
✓ VirtualMachine 'api-vm-02' manifest applied to namespace 'my-project-ns'
✓ VM 'api-vm-02' is powered on
✓ VM 'api-vm-02' IP address: 172.30.0.141
✓ Phase 2 complete — API tier VMs provisioned (api-vm-01=172.30.0.140, api-vm-02=172.30.0.141)
[Step 3] Creating VirtualMachineService LoadBalancer 'ha-api-lb' for API tier...
✓ VirtualMachineService 'ha-api-lb' created (LoadBalancer, port 3001 → 3001)
✓ API VIP address: 10.96.0.50
✓ Phase 3 complete — API tier internal service created
[Step 4] Provisioning Web tier VMs in supervisor namespace 'my-project-ns'...
--- Provisioning web-vm-01 ---
✓ Cloud-init Secret 'web-vm-01-cloud-init' created
✓ VirtualMachine 'web-vm-01' manifest applied to namespace 'my-project-ns'
✓ VM 'web-vm-01' is powered on
✓ VM 'web-vm-01' IP address: 172.30.0.150
--- Provisioning web-vm-02 ---
✓ Cloud-init Secret 'web-vm-02-cloud-init' created
✓ VirtualMachine 'web-vm-02' manifest applied to namespace 'my-project-ns'
✓ VM 'web-vm-02' is powered on
✓ VM 'web-vm-02' IP address: 172.30.0.151
✓ Phase 4 complete — Web tier VMs provisioned
[Step 5] Creating VirtualMachineService LoadBalancer 'ha-web-lb' for Web tier...
✓ VirtualMachineService 'ha-web-lb' created (LoadBalancer, port 80 → 3000)
✓ Web LB external IP: 74.205.11.95
✓ Phase 5 complete — Web tier LoadBalancer created with external IP 74.205.11.95
[Step 6] Verifying end-to-end connectivity...
✓ Frontend HTTP connectivity test passed — received status 200
✓ API health check passed — received status 200
✓ Phase 6 complete — end-to-end connectivity verified

=============================================
  VCF 9 HA VM App — Deployment Complete
=============================================
  Web LB IP:     http://74.205.11.95
  web-vm-01:     172.30.0.150
  web-vm-02:     172.30.0.151
  api-vm-01:     172.30.0.140
  api-vm-02:     172.30.0.141
  DSM Host:      10.0.2.50:5432/assetdb
  Namespace:     my-project-ns
=============================================
```

---

## Typical Timing

| Phase | Duration |
|---|---|
| Phase 0 (VCF CLI context setup) | ~5s |
| Phase 1 (DSM PostgresCluster provisioning) | 10–25 min |
| Phase 2 (API tier VM provisioning) | 3–10 min |
| Phase 3 (API tier internal service) | ~5s |
| Phase 4 (Web tier VM provisioning) | 3–10 min |
| Phase 5 (Web tier LoadBalancer + IP) | 1–3 min |
| Phase 6 (Connectivity verification) | 30s–2 min |
| **Total** | **~17–50 min** |

---

## Exit Codes

| Code | Failure Category |
|---|---|
| 0 | Success |
| 1 | Variable validation failure |
| 2 | DSM PostgresCluster provisioning failure / timeout |
| 3 | API VM provisioning failure / timeout |
| 4 | API VirtualMachineService creation failure |
| 5 | Web VM provisioning failure / timeout |
| 6 | Web VirtualMachineService / LB IP failure |
| 7 | Connectivity verification failure |

---

## Troubleshooting

### PostgresCluster does not reach Ready status (exit 2)

- Verify the DSM infrastructure policy exists and is configured in the supervisor namespace
- Verify the `DSM_STORAGE_POLICY` is available: `kubectl get storagepolicies`
- Verify the `DSM_VM_CLASS` is available: `kubectl get virtualmachineclasses`
- Check PostgresCluster events: `kubectl describe postgrescluster pg-clus-01 -n <SUPERVISOR_NAMESPACE>`
- Check PostgresCluster status: `kubectl get postgrescluster pg-clus-01 -n <SUPERVISOR_NAMESPACE> -o yaml`
- Increase `DSM_TIMEOUT` if the environment is slow to provision managed databases

### API VM does not reach PoweredOn state (exit 3)

- Verify the `VM_IMAGE` exists in the content library and is accessible from the supervisor namespace
- Verify the `VM_CLASS` is available in the namespace: `kubectl get virtualmachineclasses`
- Check VirtualMachine events: `kubectl describe virtualmachine api-vm-01 -n <SUPERVISOR_NAMESPACE>`
- Increase `VM_TIMEOUT` if the environment is slow to provision VMs

### API VirtualMachineService creation fails (exit 4)

- Verify the API VMs have the `app: ha-api` label: `kubectl get virtualmachine -n <SUPERVISOR_NAMESPACE> --show-labels`
- Check VirtualMachineService status: `kubectl get virtualmachineservice ha-api-lb -n <SUPERVISOR_NAMESPACE> -o yaml`

### Web VM does not reach PoweredOn state (exit 5)

- Same troubleshooting as API VMs — check `VM_IMAGE`, `VM_CLASS`, and VirtualMachine events
- Check VirtualMachine events: `kubectl describe virtualmachine web-vm-01 -n <SUPERVISOR_NAMESPACE>`

### Web LoadBalancer IP not assigned (exit 6)

- Verify the VirtualMachineService was created: `kubectl get virtualmachineservice ha-web-lb -n <SUPERVISOR_NAMESPACE>`
- Check that web VMs have the `app: ha-web` label: `kubectl get virtualmachine -n <SUPERVISOR_NAMESPACE> --show-labels`
- Verify the NSX load balancer has capacity
- Increase `LB_TIMEOUT` if the environment is slow to provision LoadBalancer IPs

### Connectivity verification fails (exit 7)

- Verify the Web LB external IP is reachable: `curl -v http://<WEB_LB_IP>`
- Check that cloud-init completed on the web VMs (Next.js may still be building)
- Check API health from inside a web VM or via the API VIP
- Increase `POLL_INTERVAL` to allow more time for cloud-init bootstrap

### Monitor during deployment

```bash
# Watch VM provisioning
docker exec vcf9-dev kubectl get virtualmachines -n <SUPERVISOR_NAMESPACE> -w

# Watch PostgresCluster provisioning
docker exec vcf9-dev kubectl get postgrescluster -n <SUPERVISOR_NAMESPACE> -w

# Check VirtualMachineService and LB IP
docker exec vcf9-dev kubectl get virtualmachineservice -n <SUPERVISOR_NAMESPACE>

# Check VM cloud-init logs (if SSH is available)
ssh <VM_IP> 'sudo cat /var/log/cloud-init-output.log'
```
