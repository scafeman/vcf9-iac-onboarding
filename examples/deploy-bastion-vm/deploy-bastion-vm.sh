#!/bin/bash
set -euo pipefail

###############################################################################
# VCF 9 Deploy Bastion VM — SSH Jump Host Deploy Script
#
# This script deploys a minimal Ubuntu 24.04 bastion VM as an SSH jump host
# in a VCF 9 supervisor namespace:
#   Phase 1: Provision Bastion VM via VM Service + cloud-init
#   Phase 2: Expose SSH via VirtualMachineService LoadBalancer
#            (with loadBalancerSourceRanges to restrict ingress)
#   Phase 3: Verify SSH Connectivity via external IP
#
# The VirtualMachineService of type LoadBalancer automatically allocates a
# public IP from the NSX VPC external IP pool. The loadBalancerSourceRanges
# field restricts which source IPs can reach the bastion on port 22.
#
# Prerequisites:
#   - VCF CLI installed and configured with supervisor context
#   - kubectl installed
#   - nc (netcat) installed for connectivity verification
#   - Valid API token for VCFA
#
# Edit the variable block below with your environment-specific values,
# then run: bash examples/deploy-bastion-vm/deploy-bastion-vm.sh
###############################################################################

###############################################################################
# Variable Block — Customer-Configurable Values
#
# Fill in the required variables below. Variables with defaults can be
# overridden by setting them in your environment before running the script.
###############################################################################

# --- VCF CLI Connection ---
VCF_API_TOKEN="${VCF_API_TOKEN:-}"
VCFA_ENDPOINT="${VCFA_ENDPOINT:-}"
TENANT_NAME="${TENANT_NAME:-}"
CONTEXT_NAME="${CONTEXT_NAME:-}"

# --- Supervisor Namespace ---
SUPERVISOR_NAMESPACE="${SUPERVISOR_NAMESPACE:-}"

# --- Bastion Networking ---
ALLOWED_SSH_SOURCES="${ALLOWED_SSH_SOURCES:-136.62.85.50}"

# --- VM Configuration ---
VM_CLASS="${VM_CLASS:-best-effort-medium}"
VM_IMAGE="${VM_IMAGE:-ubuntu-24.04-server-cloudimg-amd64}"
VM_NAME="${VM_NAME:-bastion-vm}"
STORAGE_CLASS="${STORAGE_CLASS:-nfs}"

# --- SSH User Configuration ---
SSH_USERNAME="${SSH_USERNAME:-rackadmin}"
SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY:-ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHkSxDwLlcYpqwlI/LkXpbHE6pl63UR+LqqZ+PTMnQLB GitLab SSH Pair}"

# --- Disk Configuration ---
BOOT_DISK_SIZE="${BOOT_DISK_SIZE:-}"
DATA_DISK_SIZE="${DATA_DISK_SIZE:-}"

# --- Network Configuration ---
VM_NETWORK="${VM_NETWORK:-}"

# --- Timeouts and Polling ---
VM_TIMEOUT="${VM_TIMEOUT:-600}"
LB_TIMEOUT="${LB_TIMEOUT:-300}"
SSH_TIMEOUT="${SSH_TIMEOUT:-120}"
POLL_INTERVAL="${POLL_INTERVAL:-30}"

###############################################################################
# Exit Codes
#   0 = Success
#   1 = Variable validation failure
#   2 = VM provisioning failure / timeout
#   3 = VirtualMachineService creation / LB IP failure
#   4 = SSH connectivity verification failure
###############################################################################

###############################################################################
# Helper Functions
###############################################################################

log_step() {
  local step_number="$1"
  local message="$2"
  echo "[Step ${step_number}] ${message}..."
}

log_success() {
  local message="$1"
  echo "✓ ${message}"
}

log_warn() {
  local message="$1"
  echo "⚠ WARNING: ${message}" >&2
}

log_error() {
  local message="$1"
  echo "✗ ERROR: ${message}" >&2
}

validate_variables() {
  local missing=0
  local required_vars=(
    "VCF_API_TOKEN"
    "VCFA_ENDPOINT"
    "TENANT_NAME"
    "CONTEXT_NAME"
    "SUPERVISOR_NAMESPACE"
  )

  for var_name in "${required_vars[@]}"; do
    if [[ -z "${!var_name:-}" ]]; then
      log_error "Required variable ${var_name} is not set or is empty"
      missing=1
    fi
  done

  if [[ "${missing}" -eq 1 ]]; then
    log_error "One or more required variables are missing. Please set them in the variable block above."
    exit 1
  fi
}

wait_for_condition() {
  local description="$1"
  local timeout="$2"
  local interval="$3"
  local check_command="$4"
  local elapsed=0

  while [[ "${elapsed}" -lt "${timeout}" ]]; do
    if eval "${check_command}" >/dev/null 2>&1; then
      return 0
    fi
    echo "  Waiting for ${description}... (${elapsed}s/${timeout}s elapsed)"
    sleep "${interval}"
    elapsed=$((elapsed + interval))
  done

  echo "  Timeout waiting for ${description} after ${elapsed}s"
  return 1
}

###############################################################################
# Pre-Flight Validation
###############################################################################

validate_variables

# Validate disk size formats (must end with Mi, Gi, or Ti if set)
for disk_var in BOOT_DISK_SIZE DATA_DISK_SIZE; do
  val="${!disk_var:-}"
  if [[ -n "$val" ]] && ! echo "$val" | grep -qE '^[0-9]+(Mi|Gi|Ti)$'; then
    log_error "${disk_var}='${val}' is invalid. Must include a unit suffix (e.g., 20Gi, 512Mi, 1Ti)."
    exit 1
  fi
done

###############################################################################
# Phase 1: Provision Bastion VM via VM Service
###############################################################################

log_step 1 "Provisioning Bastion VM '${VM_NAME}' in supervisor namespace '${SUPERVISOR_NAMESPACE}'"

# Idempotency check — skip creation if VM already exists
if kubectl get virtualmachine "${VM_NAME}" -n "${SUPERVISOR_NAMESPACE}" >/dev/null 2>&1; then
  log_success "VirtualMachine '${VM_NAME}' already exists in namespace '${SUPERVISOR_NAMESPACE}', skipping creation"
  if [[ -n "${BOOT_DISK_SIZE}" ]] || [[ -n "${DATA_DISK_SIZE}" ]]; then
    log_warn "Disk options (BOOT_DISK_SIZE, DATA_DISK_SIZE) cannot be changed on an existing VM. Delete and recreate the VM to apply disk changes."
  fi
else
  # Generate cloud-init user data for minimal SSH jump host
  CLOUD_INIT_USERDATA=$(cat <<CLOUDINIT_INNER
#cloud-config
package_update: true
packages:
  - openssh-server

users:
  - default
  - name: ${SSH_USERNAME}
    groups: sudo
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - ${SSH_PUBLIC_KEY}

runcmd:
  - |
    # Disable password authentication for SSH
    sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
    sed -i 's/^#*ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config
    systemctl restart sshd
    systemctl enable ssh
CLOUDINIT_INNER
)

  # Create a Kubernetes Secret with the cloud-init user data
  if kubectl get secret "${VM_NAME}-cloud-init" -n "${SUPERVISOR_NAMESPACE}" >/dev/null 2>&1; then
    log_success "Secret '${VM_NAME}-cloud-init' already exists, updating..."
    kubectl delete secret "${VM_NAME}-cloud-init" -n "${SUPERVISOR_NAMESPACE}" --ignore-not-found
  fi
  kubectl create secret generic "${VM_NAME}-cloud-init" \
    -n "${SUPERVISOR_NAMESPACE}" \
    --from-literal=user-data="${CLOUD_INIT_USERDATA}"
  log_success "Cloud-init Secret '${VM_NAME}-cloud-init' created"

  # Build optional advanced spec for boot disk resize
  ADVANCED_SPEC=""
  if [[ -n "${BOOT_DISK_SIZE}" ]]; then
    ADVANCED_SPEC="  advanced:
    bootDiskCapacity: ${BOOT_DISK_SIZE}"
    log_success "Boot disk will be resized to ${BOOT_DISK_SIZE}"
  fi

  # Build optional volumes spec for data disk
  VOLUMES_SPEC=""
  if [[ -n "${DATA_DISK_SIZE}" ]]; then
    # Create the PVC first — VM volumes reference existing PVCs by claimName
    if kubectl get pvc "${VM_NAME}-data" -n "${SUPERVISOR_NAMESPACE}" >/dev/null 2>&1; then
      log_success "PVC '${VM_NAME}-data' already exists, skipping creation"
    else
      if ! cat <<PVCEOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${VM_NAME}-data
  namespace: ${SUPERVISOR_NAMESPACE}
  labels:
    vm-selector: ${VM_NAME}
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: ${DATA_DISK_SIZE}
  storageClassName: ${STORAGE_CLASS}
PVCEOF
      then
        log_error "Failed to create PVC '${VM_NAME}-data'"
        exit 2
      fi
      log_success "PVC '${VM_NAME}-data' created (${DATA_DISK_SIZE})"
    fi
    VOLUMES_SPEC="  volumes:
  - name: data-disk
    persistentVolumeClaim:
      claimName: ${VM_NAME}-data"
    log_success "Data disk will be attached at ${DATA_DISK_SIZE}"
  fi

  # Build optional network spec for SubnetSet selection
  NETWORK_SPEC=""
  if [[ -n "${VM_NETWORK}" ]]; then
    NETWORK_SPEC="  network:
    interfaces:
    - name: eth0
      network:
        apiVersion: crd.nsx.vmware.com/v1alpha1
        kind: SubnetSet
        name: ${VM_NETWORK}"
    log_success "VM will be deployed on network '${VM_NETWORK}'"
  fi

  # Apply VirtualMachine manifest with app label for VirtualMachineService selector
  if ! cat <<EOF | kubectl apply -f -
apiVersion: vmoperator.vmware.com/v1alpha3
kind: VirtualMachine
metadata:
  name: ${VM_NAME}
  namespace: ${SUPERVISOR_NAMESPACE}
  labels:
    app: ${VM_NAME}
spec:
  className: ${VM_CLASS}
  imageName: ${VM_IMAGE}
  storageClass: ${STORAGE_CLASS}
  powerState: PoweredOn
${ADVANCED_SPEC:+${ADVANCED_SPEC}}
${NETWORK_SPEC:+${NETWORK_SPEC}}
  bootstrap:
    cloudInit:
      rawCloudConfig:
        name: ${VM_NAME}-cloud-init
        key: user-data
${VOLUMES_SPEC:+${VOLUMES_SPEC}}
EOF
  then
    log_error "Failed to apply VirtualMachine manifest for '${VM_NAME}'"
    exit 2
  fi

  log_success "VirtualMachine '${VM_NAME}' manifest applied to namespace '${SUPERVISOR_NAMESPACE}'"
fi

# Ensure the app label exists on the VM (for idempotent re-runs where VM existed without label)
kubectl label virtualmachine "${VM_NAME}" -n "${SUPERVISOR_NAMESPACE}" app="${VM_NAME}" --overwrite 2>/dev/null || true

# Wait for VM to reach ready power state
log_step "1b" "Waiting for VM '${VM_NAME}' to reach ready power state"

if ! wait_for_condition "VM '${VM_NAME}' to be powered on and ready" \
  "${VM_TIMEOUT}" "${POLL_INTERVAL}" \
  "kubectl get virtualmachine '${VM_NAME}' -n '${SUPERVISOR_NAMESPACE}' -o jsonpath='{.status.powerState}' 2>/dev/null | grep -q 'PoweredOn'"; then
  VM_STATUS=$(kubectl get virtualmachine "${VM_NAME}" -n "${SUPERVISOR_NAMESPACE}" -o jsonpath='{.status}' 2>/dev/null || echo "unable to retrieve status")
  log_error "VM '${VM_NAME}' did not reach ready power state within ${VM_TIMEOUT}s. Current status: ${VM_STATUS}"
  exit 2
fi

log_success "VM '${VM_NAME}' is powered on and ready"

# Wait for VM IP address to be assigned (may take additional time after PoweredOn)
echo "Waiting for VM IP address to be assigned..."
IP_TIMEOUT=120
IP_ELAPSED=0
VM_IP=""
while [[ "${IP_ELAPSED}" -lt "${IP_TIMEOUT}" ]]; do
  VM_IP=$(kubectl get virtualmachine "${VM_NAME}" -n "${SUPERVISOR_NAMESPACE}" -o jsonpath='{.status.network.primaryIP4}' 2>/dev/null || true)
  if [[ -z "${VM_IP}" ]]; then
    VM_IP=$(kubectl get virtualmachine "${VM_NAME}" -n "${SUPERVISOR_NAMESPACE}" -o jsonpath='{.status.network.interfaces[0].ip.addresses[0].address}' 2>/dev/null || true)
  fi
  if [[ -z "${VM_IP}" ]]; then
    VM_IP=$(kubectl get virtualmachine "${VM_NAME}" -n "${SUPERVISOR_NAMESPACE}" -o jsonpath='{.status.vmIp}' 2>/dev/null || true)
  fi
  if [[ -n "${VM_IP}" ]]; then
    break
  fi
  echo "  VM IP not yet assigned — waiting... (${IP_ELAPSED}s/${IP_TIMEOUT}s)"
  sleep 10
  IP_ELAPSED=$((IP_ELAPSED + 10))
done

if [[ -z "${VM_IP}" ]]; then
  log_error "Failed to extract IP address for VM '${VM_NAME}' within ${IP_TIMEOUT}s. Check VirtualMachine status."
  exit 2
fi

log_success "Bastion VM internal IP address: ${VM_IP}"
log_success "Phase 1 complete — Bastion VM '${VM_NAME}' provisioned at ${VM_IP}"

###############################################################################
# Phase 2: Expose SSH via VirtualMachineService LoadBalancer
###############################################################################

log_step 2 "Creating VirtualMachineService to expose SSH on port 22"

VMSERVICE_NAME="${VM_NAME}-ssh"

# Build loadBalancerSourceRanges YAML from comma-separated ALLOWED_SSH_SOURCES
SOURCE_RANGES_YAML=""
IFS=',' read -ra SOURCE_IPS <<< "${ALLOWED_SSH_SOURCES}"
for ip in "${SOURCE_IPS[@]}"; do
  ip=$(echo "${ip}" | xargs)  # trim whitespace
  SOURCE_RANGES_YAML="${SOURCE_RANGES_YAML}
  - ${ip}/32"
done

# Idempotency check — skip creation if VirtualMachineService already exists
if kubectl get virtualmachineservice "${VMSERVICE_NAME}" -n "${SUPERVISOR_NAMESPACE}" >/dev/null 2>&1; then
  log_success "VirtualMachineService '${VMSERVICE_NAME}' already exists, skipping creation"
else
  if ! cat <<EOF | kubectl apply -f -
apiVersion: vmoperator.vmware.com/v1alpha3
kind: VirtualMachineService
metadata:
  name: ${VMSERVICE_NAME}
  namespace: ${SUPERVISOR_NAMESPACE}
spec:
  type: LoadBalancer
  loadBalancerSourceRanges:${SOURCE_RANGES_YAML}
  selector:
    app: ${VM_NAME}
  ports:
  - name: ssh
    port: 22
    protocol: TCP
    targetPort: 22
EOF
  then
    log_error "Failed to create VirtualMachineService '${VMSERVICE_NAME}'"
    exit 3
  fi
  log_success "VirtualMachineService '${VMSERVICE_NAME}' created (allowed sources: ${ALLOWED_SSH_SOURCES})"
fi

# Wait for LoadBalancer external IP to be assigned
log_step "2b" "Waiting for LoadBalancer external IP assignment"

BASTION_EXTERNAL_IP=""
if ! wait_for_condition "LoadBalancer '${VMSERVICE_NAME}' to receive external IP" \
  "${LB_TIMEOUT}" "${POLL_INTERVAL}" \
  "[[ -n \$(kubectl get virtualmachineservice '${VMSERVICE_NAME}' -n '${SUPERVISOR_NAMESPACE}' -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null) ]]"; then
  log_error "LoadBalancer '${VMSERVICE_NAME}' did not receive an external IP within ${LB_TIMEOUT}s"
  kubectl get virtualmachineservice "${VMSERVICE_NAME}" -n "${SUPERVISOR_NAMESPACE}" -o wide 2>/dev/null || true
  exit 3
fi

BASTION_EXTERNAL_IP=$(kubectl get virtualmachineservice "${VMSERVICE_NAME}" -n "${SUPERVISOR_NAMESPACE}" -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
log_success "Bastion external IP: ${BASTION_EXTERNAL_IP}"
log_success "Phase 2 complete — SSH exposed via LoadBalancer at ${BASTION_EXTERNAL_IP}:22"

###############################################################################
# Phase 3: Verify SSH Connectivity
###############################################################################

log_step 3 "Verifying SSH connectivity to bastion VM via external IP"

ELAPSED=0
while [[ "${ELAPSED}" -lt "${SSH_TIMEOUT}" ]]; do
  if nc -z -w 5 "${BASTION_EXTERNAL_IP}" 22 >/dev/null 2>&1; then
    log_success "SSH connectivity test passed — port 22 is reachable on ${BASTION_EXTERNAL_IP}"
    break
  fi
  echo "  SSH not yet reachable on ${BASTION_EXTERNAL_IP}:22, retrying... (${ELAPSED}s/${SSH_TIMEOUT}s)"
  sleep "${POLL_INTERVAL}"
  ELAPSED=$((ELAPSED + POLL_INTERVAL))
done

if [[ "${ELAPSED}" -ge "${SSH_TIMEOUT}" ]]; then
  log_error "SSH connectivity test failed — port 22 not reachable on ${BASTION_EXTERNAL_IP} within ${SSH_TIMEOUT}s"
  exit 4
fi

log_success "Phase 3 complete — SSH connectivity verified"

###############################################################################
# Success Summary
###############################################################################

echo ""
echo "============================================="
echo "  VCF 9 Bastion VM — Deployment Complete"
echo "============================================="
echo "  VM Name:       ${VM_NAME}"
echo "  Internal IP:   ${VM_IP}"
echo "  External IP:   ${BASTION_EXTERNAL_IP}"
echo "  SSH Command:   ssh ${SSH_USERNAME}@${BASTION_EXTERNAL_IP}"
echo "  Allowed IPs:   ${ALLOWED_SSH_SOURCES}"
echo "  Boot Disk:     ${BOOT_DISK_SIZE:-image default}"
echo "  Data Disk:     ${DATA_DISK_SIZE:-none}"
echo "  Network:       ${VM_NETWORK:-default}"
echo "  Namespace:     ${SUPERVISOR_NAMESPACE}"
echo "============================================="
echo ""

exit 0
