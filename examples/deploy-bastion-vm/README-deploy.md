# Deploy Bastion VM — SSH Jump Host

## Overview

`deploy-bastion-vm.sh` deploys a minimal Ubuntu 24.04 bastion VM as an SSH jump host in a VCF 9 supervisor namespace. It provisions the VM via the VCF VM Service with cloud-init, exposes SSH on port 22 through a `VirtualMachineService` LoadBalancer with `loadBalancerSourceRanges` to restrict ingress to allowed source IPs, and verifies SSH connectivity through the auto-assigned external IP.

The bastion VM provides a secure entry point for accessing internal resources within the VCF namespace:

- **Bastion VM** — provisioned via `vmoperator.vmware.com/v1alpha3 VirtualMachine` CRD with cloud-init for automated SSH configuration
- **VirtualMachineService** — a LoadBalancer service that automatically allocates a public IP from the NSX VPC external IP pool and exposes SSH on port 22
- **loadBalancerSourceRanges** — restricts which source IPs can reach the bastion, acting as a built-in firewall

The script is fully non-interactive. All configuration is driven by environment variables (loaded from `.env` via Docker Compose). No user input is required during execution.

---

## Prerequisites

- **VCF CLI** installed and configured with a supervisor context that has access to the target namespace
- **kubectl** installed
- **nc (netcat)** installed for SSH connectivity verification
- **Valid API token** for the VCFA portal

---

## What the Script Does

### Phase 1: Provision Bastion VM via VM Service

Creates a Kubernetes Secret (`bastion-vm-cloud-init`) containing cloud-init user data that configures a minimal SSH jump host:

- Installs `openssh-server`
- Creates the configured SSH user (default: `rackadmin`) with sudo privileges and the configured SSH public key
- Disables password authentication via `sshd_config`

Applies a `VirtualMachine` manifest (`vmoperator.vmware.com/v1alpha3`) to the supervisor namespace referencing the cloud-init Secret. The VM is created with an `app: bastion-vm` label used by the VirtualMachineService selector. Waits for the VM to reach `PoweredOn` power state (timeout: 600s, polling every 30s), then extracts the VM internal IP address from the VirtualMachine status.

An idempotency check skips VM creation if the VirtualMachine resource already exists.

### Phase 2: Expose SSH via VirtualMachineService LoadBalancer

Creates a `VirtualMachineService` (`vmoperator.vmware.com/v1alpha3`) of type `LoadBalancer` in the supervisor namespace that:

- Selects the bastion VM via the `app: bastion-vm` label
- Exposes SSH on port 22 (port 22 → targetPort 22)
- Restricts ingress to allowed source IPs via `loadBalancerSourceRanges` (each IP gets a `/32` CIDR)
- Automatically allocates a public IP from the NSX VPC external IP pool

The allowed source IPs are read from the `ALLOWED_SSH_SOURCES` variable (comma-separated). The script waits for the LoadBalancer to receive an external IP (timeout: 300s, polling every 30s).

An idempotency check skips creation if the VirtualMachineService already exists.

### Phase 3: SSH Connectivity Verification

Performs a TCP connectivity test to the bastion VM external IP on port 22 using `nc -z`. Retries within the configured SSH timeout (default: 120s). Prints a deployment summary on success including the VM name, internal IP, external IP, SSH command, allowed IPs, and namespace.

---

## Required Environment Variables

Set these in the `.env` file at the project root. Docker Compose loads them into the container automatically.

| Variable | Required | Default | Description |
|---|---|---|---|
| `VCF_API_TOKEN` | Yes | — | API token from the VCFA portal |
| `VCFA_ENDPOINT` | Yes | — | VCFA hostname (no `https://` prefix) |
| `TENANT_NAME` | Yes | — | SSO tenant/organization |
| `CONTEXT_NAME` | Yes | — | Local VCF CLI context name |
| `SUPERVISOR_NAMESPACE` | Yes | — | Supervisor namespace for all resources |
| `ALLOWED_SSH_SOURCES` | No | `136.62.85.50` | Comma-separated allowed SSH source IPs |
| `VM_CLASS` | No | `best-effort-medium` | VM Service compute class |
| `VM_IMAGE` | No | `ubuntu-24.04-server-cloudimg-amd64` | Content library image name |
| `VM_NAME` | No | `bastion-vm` | Name for the VirtualMachine resource |
| `STORAGE_CLASS` | No | `nfs` | Storage class for VM |
| `SSH_USERNAME` | No | `rackadmin` | SSH username for the bastion VM |
| `SSH_PUBLIC_KEY` | No | *(ed25519 key)* | SSH public key for the bastion VM user |
| `VM_TIMEOUT` | No | `600` | Seconds to wait for VM PoweredOn |
| `LB_TIMEOUT` | No | `300` | Seconds to wait for LoadBalancer external IP |
| `SSH_TIMEOUT` | No | `120` | Seconds to wait for SSH connectivity |
| `POLL_INTERVAL` | No | `30` | Seconds between polling attempts |

---

## How to Trigger

### Docker exec (recommended)

```bash
docker exec vcf9-dev bash examples/deploy-bastion-vm/deploy-bastion-vm.sh
```

### GitHub Actions UI

Navigate to **Actions → Deploy Bastion VM → Run workflow**, enter the supervisor namespace and optionally the allowed SSH sources, then click **Run workflow**.

### Trigger script (repository_dispatch)

```bash
bash scripts/trigger-deploy-bastion-vm.sh \
  --repo myorg/vcf9-iac \
  --token ghp_xxxxxxxxxxxx \
  --supervisor-namespace my-project-ns
```

### curl (repository_dispatch)

```bash
curl -X POST \
  -H "Authorization: token ghp_xxxxxxxxxxxx" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/OWNER/REPO/dispatches" \
  -d '{
    "event_type": "deploy-bastion-vm",
    "client_payload": {
      "supervisor_namespace": "my-project-ns"
    }
  }'
```

### PowerShell (Windows 11 workstation)

```powershell
docker exec vcf9-dev bash examples/deploy-bastion-vm/deploy-bastion-vm.sh
```

---

## Expected Output

A successful run produces output like this:

```
[Step 1] Provisioning Bastion VM 'bastion-vm' in supervisor namespace 'my-project-ns'...
✓ Cloud-init Secret 'bastion-vm-cloud-init' created
✓ VirtualMachine 'bastion-vm' manifest applied to namespace 'my-project-ns'
[Step 1b] Waiting for VM 'bastion-vm' to reach ready power state...
  Waiting for VM 'bastion-vm' to be powered on and ready... (0s/600s elapsed)
  Waiting for VM 'bastion-vm' to be powered on and ready... (30s/600s elapsed)
✓ VM 'bastion-vm' is powered on and ready
Waiting for VM IP address to be assigned...
✓ Bastion VM internal IP address: 172.30.0.132
✓ Phase 1 complete — Bastion VM 'bastion-vm' provisioned at 172.30.0.132
[Step 2] Creating VirtualMachineService to expose SSH on port 22...
✓ VirtualMachineService 'bastion-vm-ssh' created (allowed sources: 136.62.85.50)
[Step 2b] Waiting for LoadBalancer external IP assignment...
  Waiting for LoadBalancer 'bastion-vm-ssh' to receive external IP... (0s/300s elapsed)
  Waiting for LoadBalancer 'bastion-vm-ssh' to receive external IP... (30s/300s elapsed)
✓ Bastion external IP: 74.205.11.94
✓ Phase 2 complete — SSH exposed via LoadBalancer at 74.205.11.94:22
[Step 3] Verifying SSH connectivity to bastion VM via external IP...
✓ SSH connectivity test passed — port 22 is reachable on 74.205.11.94
✓ Phase 3 complete — SSH connectivity verified

=============================================
  VCF 9 Bastion VM — Deployment Complete
=============================================
  VM Name:       bastion-vm
  Internal IP:   172.30.0.132
  External IP:   74.205.11.94
  SSH Command:   ssh rackadmin@74.205.11.94
  Allowed IPs:   136.62.85.50
  Namespace:     my-project-ns
=============================================
```

---

## Typical Timing

| Phase | Duration |
|---|---|
| Phase 1 (VM provisioning + IP assignment) | 3–8 min |
| Phase 2 (VirtualMachineService + LB IP) | 1–3 min |
| Phase 3 (SSH connectivity verification) | 10–60s |
| **Total** | **~4–12 min** |

---

## Exit Codes

| Code | Failure Category |
|---|---|
| 0 | Success |
| 1 | Variable validation failure |
| 2 | VM provisioning failure / timeout |
| 3 | VirtualMachineService creation / LB IP failure |
| 4 | SSH connectivity verification failure |

---

## Troubleshooting

### VM does not reach ready power state (exit 2)

- Verify the `VM_IMAGE` exists in the content library and is accessible from the supervisor namespace
- Verify the `VM_CLASS` is available in the namespace: `kubectl get virtualmachineclasses`
- Check VirtualMachine events: `kubectl describe virtualmachine bastion-vm -n <SUPERVISOR_NAMESPACE>`
- Increase `VM_TIMEOUT` if the environment is slow to provision VMs

### VM IP address not assigned (exit 2)

- Check VirtualMachine status: `kubectl get virtualmachine bastion-vm -n <SUPERVISOR_NAMESPACE> -o yaml`
- Verify the VM has a network interface assigned by the supervisor
- The script checks multiple jsonpath locations for the IP (`status.network.primaryIP4`, `status.network.interfaces[0].ip.addresses[0].address`, `status.vmIp`)

### VirtualMachineService or LoadBalancer IP fails (exit 3)

- Verify the VirtualMachineService was created: `kubectl get virtualmachineservice bastion-vm-ssh -n <SUPERVISOR_NAMESPACE>`
- Check that the VM has the `app: bastion-vm` label: `kubectl get virtualmachine bastion-vm -n <SUPERVISOR_NAMESPACE> --show-labels`
- Verify the NSX load balancer has capacity: check NSX manager for LB pool status
- Increase `LB_TIMEOUT` if the environment is slow to provision LoadBalancer IPs

### SSH connectivity verification fails (exit 4)

- Verify the LoadBalancer IP is assigned: `kubectl get virtualmachineservice bastion-vm-ssh -n <SUPERVISOR_NAMESPACE> -o jsonpath='{.status.loadBalancer.ingress[0].ip}'`
- Check that `loadBalancerSourceRanges` includes the IP you are testing from — the runner/workstation must be in the allowed list
- Test connectivity manually: `nc -z -w 5 <EXTERNAL_IP> 22`
- Increase `SSH_TIMEOUT` if cloud-init is still configuring sshd
- Check that the VM's `sshd` service is running: verify cloud-init completed successfully via VM console

### Monitor during deployment

```bash
# Watch VM provisioning
docker exec vcf9-dev kubectl get virtualmachines -n <SUPERVISOR_NAMESPACE> -w

# Check VirtualMachineService and LB IP
docker exec vcf9-dev kubectl get virtualmachineservice -n <SUPERVISOR_NAMESPACE>

# Test SSH connectivity
docker exec vcf9-dev nc -z -w 5 <EXTERNAL_IP> 22
```
