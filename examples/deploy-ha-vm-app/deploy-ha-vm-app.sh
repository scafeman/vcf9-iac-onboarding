#!/bin/bash
set -euo pipefail

###############################################################################
# VCF 9 Deploy HA VM App — High-Availability Three-Tier Application
#
# This script deploys a traditional HA three-tier application using VCF VM
# Service VMs — the VCF equivalent of deploying a classic HA application on
# AWS EC2 instances with ALB, internal NLB, and RDS:
#   Phase 0: VCF CLI context creation and supervisor namespace switch
#   Phase 1: DSM PostgresCluster provisioning (DB tier)
#   Phase 2: API tier VM provisioning (api-vm-01, api-vm-02)
#   Phase 3: API tier internal VirtualMachineService (ha-api-internal)
#   Phase 4: Web tier VM provisioning (web-vm-01, web-vm-02)
#   Phase 5: Web tier VirtualMachineService LoadBalancer (ha-web-lb)
#   Phase 6: End-to-end connectivity verification
#
# Architecture:
#   Web Tier:  2× Ubuntu 24.04 VMs (Next.js) + LoadBalancer
#   API Tier:  2× Ubuntu 24.04 VMs (Express) + internal VirtualMachineService
#   DB Tier:   DSM PostgresCluster (managed PostgreSQL)
#
# AWS Equivalent:
#   Web Tier = 2× EC2 + ALB
#   API Tier = 2× EC2 + internal NLB
#   DB Tier  = RDS PostgreSQL Multi-AZ
#
# Prerequisites:
#   - VCF CLI installed and configured
#   - kubectl installed
#   - curl installed for connectivity verification
#   - Valid API token for VCFA
#   - DSM infrastructure policy configured in the supervisor namespace
#   - Ubuntu 24.04 image available in content library
#
# Edit the variable block below with your environment-specific values,
# then run: bash examples/deploy-ha-vm-app/deploy-ha-vm-app.sh
###############################################################################

###############################################################################
# Variable Block — Customer-Configurable Values
#
# Fill in the required variables below. Variables with defaults can be
# overridden by setting them in your environment before running the script.
###############################################################################

# --- Cluster Identity ---
CLUSTER_NAME="${CLUSTER_NAME:-}"
KUBECONFIG_FILE="${KUBECONFIG_FILE:-./kubeconfig-${CLUSTER_NAME}.yaml}"

# --- VCF CLI Connection ---
VCF_API_TOKEN="${VCF_API_TOKEN:-}"
VCFA_ENDPOINT="${VCFA_ENDPOINT:-}"
TENANT_NAME="${TENANT_NAME:-}"
CONTEXT_NAME="${CONTEXT_NAME:-}"

# --- Supervisor Namespace ---
SUPERVISOR_NAMESPACE="${SUPERVISOR_NAMESPACE:-}"
PROJECT_NAME="${PROJECT_NAME:-}"

# --- VM Configuration ---
VM_CLASS="${VM_CLASS:-best-effort-medium}"
VM_IMAGE="${VM_IMAGE:-ubuntu-24.04-server-cloudimg-amd64}"
STORAGE_CLASS="${STORAGE_CLASS:-nfs}"

# --- VM Names ---
API_VM_01_NAME="${API_VM_01_NAME:-api-vm-01}"
API_VM_02_NAME="${API_VM_02_NAME:-api-vm-02}"
WEB_VM_01_NAME="${WEB_VM_01_NAME:-web-vm-01}"
WEB_VM_02_NAME="${WEB_VM_02_NAME:-web-vm-02}"

# --- Service Names ---
WEB_LB_NAME="${WEB_LB_NAME:-ha-web-lb}"
API_SVC_NAME="${API_SVC_NAME:-ha-api-internal}"

# --- App Labels ---
WEB_APP_LABEL="${WEB_APP_LABEL:-ha-web}"
API_APP_LABEL="${API_APP_LABEL:-ha-api}"

# --- SSH User Configuration ---
SSH_USERNAME="${SSH_USERNAME:-rackadmin}"
SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY:-ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHkSxDwLlcYpqwlI/LkXpbHE6pl63UR+LqqZ+PTMnQLB GitLab SSH Pair}"

# --- DSM PostgresCluster Configuration ---
DSM_CLUSTER_NAME="${DSM_CLUSTER_NAME:-postgres-clus-01}"
DSM_INFRA_POLICY="${DSM_INFRA_POLICY:-}"
DSM_VM_CLASS="${DSM_VM_CLASS:-best-effort-large}"
DSM_STORAGE_POLICY="${DSM_STORAGE_POLICY:-}"
DSM_STORAGE_SPACE="${DSM_STORAGE_SPACE:-20Gi}"
POSTGRES_VERSION="${POSTGRES_VERSION:-17.7+vmware.v9.0.2.0}"
POSTGRES_REPLICAS="${POSTGRES_REPLICAS:-0}"
POSTGRES_DB="${POSTGRES_DB:-assetdb}"
ADMIN_PASSWORD_SECRET_NAME="${ADMIN_PASSWORD_SECRET_NAME:-admin-pw-pg-clus-01}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
DSM_MAINTENANCE_WINDOW_DAY="${DSM_MAINTENANCE_WINDOW_DAY:-SATURDAY}"
DSM_MAINTENANCE_WINDOW_TIME="${DSM_MAINTENANCE_WINDOW_TIME:-04:59}"
DSM_MAINTENANCE_WINDOW_DURATION="${DSM_MAINTENANCE_WINDOW_DURATION:-6h0m0s}"
DSM_SHARED_MEMORY="${DSM_SHARED_MEMORY:-64Mi}"

# --- Application Ports ---
API_PORT="${API_PORT:-3001}"
FRONTEND_PORT="${FRONTEND_PORT:-3000}"

# --- Container Registry ---
CONTAINER_REGISTRY="${CONTAINER_REGISTRY:-scafeman}"
IMAGE_TAG="${IMAGE_TAG:-latest}"

# --- Git Repository (for cloning app source to VMs) ---
GIT_REPO_URL="${GIT_REPO_URL:-https://github.com/scafeman/vcf9-iac-onboarding.git}"
GIT_BRANCH="${GIT_BRANCH:-main}"

# --- Timeouts and Polling ---
VM_TIMEOUT="${VM_TIMEOUT:-600}"
DSM_TIMEOUT="${DSM_TIMEOUT:-1800}"
LB_TIMEOUT="${LB_TIMEOUT:-300}"
POLL_INTERVAL="${POLL_INTERVAL:-30}"

###############################################################################
# Exit Codes
#   0 = Success
#   1 = Variable validation failure
#   2 = DSM PostgresCluster provisioning failure / timeout
#   3 = API VM provisioning failure / timeout
#   4 = API VirtualMachineService creation failure
#   5 = Web VM provisioning failure / timeout
#   6 = Web VirtualMachineService / LB IP failure
#   7 = Connectivity verification failure
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
    "CLUSTER_NAME"
    "SUPERVISOR_NAMESPACE"
    "PROJECT_NAME"
    "VCF_API_TOKEN"
    "VCFA_ENDPOINT"
    "TENANT_NAME"
    "CONTEXT_NAME"
    "DSM_INFRA_POLICY"
    "DSM_STORAGE_POLICY"
    "ADMIN_PASSWORD"
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
    # Refresh VCF CLI token every 5 minutes to prevent expiry during long waits
    if [[ $((elapsed % 300)) -eq 0 ]] && [[ "${elapsed}" -gt 0 ]]; then
      refresh_vcf_context
    fi
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

refresh_vcf_context() {
  echo "  Refreshing VCF CLI token..."
  vcf context delete "${CONTEXT_NAME}" --yes 2>/dev/null || true
  vcf context create "${CONTEXT_NAME}" \
    --endpoint "https://${VCFA_ENDPOINT}" \
    --type cci \
    --tenant-name "${TENANT_NAME}" \
    --api-token "${VCF_API_TOKEN}" \
    --set-current >/dev/null 2>&1 || true
  # Switch to the namespace context
  local ns_ctx
  ns_ctx=$(vcf context list 2>&1 | grep "${CONTEXT_NAME}:.*${SUPERVISOR_NAMESPACE}" | awk '{print $1}' | head -1 || true)
  if [[ -n "${ns_ctx}" ]]; then
    vcf context use "${ns_ctx}" >/dev/null 2>&1 || true
  fi
  echo "  Token refreshed"
}

# Helper: Wait for VM IP address assignment (tries multiple jsonpath locations)
get_vm_ip() {
  local vm_name="$1"
  local namespace="$2"
  local ip=""
  ip=$(kubectl get virtualmachine "${vm_name}" -n "${namespace}" -o jsonpath='{.status.network.primaryIP4}' 2>/dev/null || true)
  if [[ -z "${ip}" ]]; then
    ip=$(kubectl get virtualmachine "${vm_name}" -n "${namespace}" -o jsonpath='{.status.network.interfaces[0].ip.addresses[0].address}' 2>/dev/null || true)
  fi
  if [[ -z "${ip}" ]]; then
    ip=$(kubectl get virtualmachine "${vm_name}" -n "${namespace}" -o jsonpath='{.status.vmIp}' 2>/dev/null || true)
  fi
  echo "${ip}"
}

###############################################################################
# Pre-Flight Validation
###############################################################################

validate_variables

###############################################################################
# Phase 0: VCF CLI Context Setup
###############################################################################

log_step 0 "Creating VCF CLI context and switching to supervisor namespace"

vcf context delete "${CONTEXT_NAME}" --yes 2>/dev/null || true

if ! vcf context create "${CONTEXT_NAME}" \
  --endpoint "https://${VCFA_ENDPOINT}" \
  --type cci \
  --tenant-name "${TENANT_NAME}" \
  --api-token "${VCF_API_TOKEN}" \
  --set-current; then
  log_error "Failed to create VCF CLI context '${CONTEXT_NAME}' for endpoint '${VCFA_ENDPOINT}'. Verify your endpoint URL, tenant name, and API token."
  exit 1
fi

# Switch to the namespace context for the supervisor namespace
NS_CTX=$(vcf context list 2>&1 | grep "${CONTEXT_NAME}:.*${SUPERVISOR_NAMESPACE}" | awk '{print $1}' | head -1 || true)
if [[ -z "${NS_CTX}" ]]; then
  PROJECT_PATTERN=$(echo "${CLUSTER_NAME}" | sed 's/-clus-[0-9]*$//')
  NS_CTX=$(vcf context list 2>&1 | grep "${CONTEXT_NAME}:.*${PROJECT_PATTERN}" | awk '{print $1}' | head -1 || true)
fi

if [[ -n "${NS_CTX}" ]]; then
  vcf context use "${NS_CTX}" >/dev/null 2>&1 || true
  log_success "VCF CLI context '${CONTEXT_NAME}' created, switched to namespace context '${NS_CTX}'"
else
  log_warn "Could not find namespace context for '${SUPERVISOR_NAMESPACE}' — kubectl commands may fail"
  log_success "VCF CLI context '${CONTEXT_NAME}' created"
fi

###############################################################################
# Phase 1: Provision DSM PostgresCluster (DB Tier)
###############################################################################

log_step 1 "Provisioning DSM PostgresCluster '${DSM_CLUSTER_NAME}' in supervisor namespace '${SUPERVISOR_NAMESPACE}'"

# Idempotency check — skip creation if PostgresCluster already exists
if kubectl get postgrescluster "${DSM_CLUSTER_NAME}" -n "${SUPERVISOR_NAMESPACE}" >/dev/null 2>&1; then
  log_success "PostgresCluster '${DSM_CLUSTER_NAME}' already exists in namespace '${SUPERVISOR_NAMESPACE}', skipping creation"
else
  # Create admin password Secret (idempotent — skip if exists)
  if kubectl get secret "${ADMIN_PASSWORD_SECRET_NAME}" -n "${SUPERVISOR_NAMESPACE}" >/dev/null 2>&1; then
    log_success "Secret '${ADMIN_PASSWORD_SECRET_NAME}' already exists, skipping creation"
  else
    if ! kubectl create secret generic "${ADMIN_PASSWORD_SECRET_NAME}" \
      -n "${SUPERVISOR_NAMESPACE}" \
      --from-literal=password="${ADMIN_PASSWORD}"; then
      log_error "Failed to create admin password Secret '${ADMIN_PASSWORD_SECRET_NAME}'"
      exit 2
    fi
    log_success "Admin password Secret '${ADMIN_PASSWORD_SECRET_NAME}' created"
  fi

  # Apply PostgresCluster manifest
  if ! cat <<EOF | kubectl apply --validate=false -f -
apiVersion: databases.dataservices.vmware.com/v1alpha1
kind: PostgresCluster
metadata:
  name: ${DSM_CLUSTER_NAME}
  namespace: ${SUPERVISOR_NAMESPACE}
  labels:
    dsm.vmware.com/infra-policy: "${DSM_INFRA_POLICY}"
    dsm.vmware.com/infra-policy-type: "supervisor-managed"
    dsm.vmware.com/vm-class: "${DSM_VM_CLASS}"
    dsm.vmware.com/admin-password-name: "${ADMIN_PASSWORD_SECRET_NAME}"
    dsm.vmware.com/consumption-namespace: "${SUPERVISOR_NAMESPACE}"
    dsm.vmware.com/backup-loc-ns.namespace: ""
    dsm.vmware.com/directory-service-name: ""
    dsm.vmware.com/directory-service-namespace: ""
spec:
  adminUsername: pgadmin
  adminPasswordRef:
    name: ${ADMIN_PASSWORD_SECRET_NAME}
  databaseName: ${POSTGRES_DB}
  infrastructurePolicy:
    name: ${DSM_INFRA_POLICY}
  version: "${POSTGRES_VERSION}"
  replicas: ${POSTGRES_REPLICAS}
  vmClass:
    name: ${DSM_VM_CLASS}
  storagePolicyName: ${DSM_STORAGE_POLICY}
  storageSpace: ${DSM_STORAGE_SPACE}
  maintenanceWindow:
    duration: ${DSM_MAINTENANCE_WINDOW_DURATION}
    startDay: ${DSM_MAINTENANCE_WINDOW_DAY}
    startTime: "${DSM_MAINTENANCE_WINDOW_TIME}"
  requestedSharedMemorySize: ${DSM_SHARED_MEMORY}
  blockDatabaseConnections: false
EOF
  then
    log_error "Failed to apply PostgresCluster manifest for '${DSM_CLUSTER_NAME}'"
    exit 2
  fi

  log_success "PostgresCluster '${DSM_CLUSTER_NAME}' manifest applied to namespace '${SUPERVISOR_NAMESPACE}'"
fi

# Wait for PostgresCluster to be fully ready with connection details
log_step "1b" "Waiting for PostgresCluster '${DSM_CLUSTER_NAME}' to reach Ready status with connection details"

if ! wait_for_condition "PostgresCluster '${DSM_CLUSTER_NAME}' connection details" \
  "${DSM_TIMEOUT}" "${POLL_INTERVAL}" \
  "[[ -n \$(kubectl get postgrescluster '${DSM_CLUSTER_NAME}' -n '${SUPERVISOR_NAMESPACE}' -o jsonpath='{.status.connection.host}' 2>/dev/null) ]] && [[ \$(kubectl get postgrescluster '${DSM_CLUSTER_NAME}' -n '${SUPERVISOR_NAMESPACE}' -o jsonpath='{.status.connection.port}' 2>/dev/null) != '0' ]]"; then
  DSM_STATUS=$(kubectl get postgrescluster "${DSM_CLUSTER_NAME}" -n "${SUPERVISOR_NAMESPACE}" -o jsonpath='{.status.conditions}' 2>/dev/null || echo "unable to retrieve status")
  log_error "PostgresCluster '${DSM_CLUSTER_NAME}' did not become ready within ${DSM_TIMEOUT}s. Current conditions: ${DSM_STATUS}"
  exit 2
fi

log_success "PostgresCluster '${DSM_CLUSTER_NAME}' is Ready"

# Extract connection details
DSM_HOST=$(kubectl get postgrescluster "${DSM_CLUSTER_NAME}" -n "${SUPERVISOR_NAMESPACE}" -o jsonpath='{.status.connection.host}')
DSM_PORT=$(kubectl get postgrescluster "${DSM_CLUSTER_NAME}" -n "${SUPERVISOR_NAMESPACE}" -o jsonpath='{.status.connection.port}')
DSM_DBNAME=$(kubectl get postgrescluster "${DSM_CLUSTER_NAME}" -n "${SUPERVISOR_NAMESPACE}" -o jsonpath='{.status.connection.dbname}')
DSM_USERNAME=$(kubectl get postgrescluster "${DSM_CLUSTER_NAME}" -n "${SUPERVISOR_NAMESPACE}" -o jsonpath='{.status.connection.username}')

if [[ -z "${DSM_HOST}" ]] || [[ "${DSM_PORT}" == "0" ]] || [[ -z "${DSM_PORT}" ]]; then
  log_error "Failed to extract connection details from PostgresCluster '${DSM_CLUSTER_NAME}' status"
  exit 2
fi

# Wait for DSM-created password secret pg-<cluster-name>
echo "Waiting for DSM password secret 'pg-${DSM_CLUSTER_NAME}'..."
DSM_PASSWORD=""
PW_ELAPSED=0
while [[ "${PW_ELAPSED}" -lt 120 ]]; do
  DSM_PASSWORD=$(kubectl get secret "pg-${DSM_CLUSTER_NAME}" -n "${SUPERVISOR_NAMESPACE}" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)
  if [[ -n "${DSM_PASSWORD}" ]]; then
    break
  fi
  echo "  Password secret not yet available — waiting... (${PW_ELAPSED}s/120s)"
  sleep 10
  PW_ELAPSED=$((PW_ELAPSED + 10))
done

if [[ -z "${DSM_PASSWORD}" ]]; then
  log_error "Failed to read admin password from secret 'pg-${DSM_CLUSTER_NAME}'"
  exit 2
fi

log_success "DSM PostgreSQL connection: ${DSM_HOST}:${DSM_PORT}/${DSM_DBNAME} (user: ${DSM_USERNAME})"
log_success "Phase 1 complete — DSM PostgresCluster '${DSM_CLUSTER_NAME}' provisioned"

# Escape dollar signs in DSM_PASSWORD for safe embedding in heredocs
DSM_PASSWORD_ESCAPED="${DSM_PASSWORD//\$/\\\$}"

###############################################################################
# Phase 2: API Tier VM Provisioning
###############################################################################

log_step 2 "Provisioning API tier VMs in supervisor namespace '${SUPERVISOR_NAMESPACE}'"

API_VM_NAMES=("${API_VM_01_NAME}" "${API_VM_02_NAME}")
API_VM_IPS=()

for VM_NAME in "${API_VM_NAMES[@]}"; do
  echo "--- Provisioning ${VM_NAME} ---"

  # Idempotency check — skip creation if VM already exists
  if kubectl get virtualmachine "${VM_NAME}" -n "${SUPERVISOR_NAMESPACE}" >/dev/null 2>&1; then
    log_success "VirtualMachine '${VM_NAME}' already exists in namespace '${SUPERVISOR_NAMESPACE}', skipping creation"
  else
    # Create cloud-init secret for API VM
    CLOUD_INIT_USERDATA=$(cat <<CLOUDINIT_INNER
#cloud-config
package_update: true
packages:
  - openssh-server
  - ca-certificates
  - curl
  - gnupg
  - git

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
    sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
    sed -i 's/^#*ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config
    systemctl restart sshd
    systemctl enable ssh
  - |
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" > /etc/apt/sources.list.d/nodesource.list
    apt-get update
    apt-get install -y nodejs
  - |
    for i in 1 2 3 4 5; do
      git clone --depth 1 --branch ${GIT_BRANCH} ${GIT_REPO_URL} /tmp/repo && break
      echo "git clone attempt \$i failed, retrying in 10s..."
      sleep 10
    done
    cp -r /tmp/repo/examples/deploy-hybrid-app/api /opt/api
    cd /opt/api && npm install
    rm -rf /tmp/repo
  - |
    echo "POSTGRES_HOST=${DSM_HOST}" > /etc/environment
    echo "POSTGRES_PORT=${DSM_PORT}" >> /etc/environment
    echo "POSTGRES_USER=${DSM_USERNAME}" >> /etc/environment
    echo "POSTGRES_PASSWORD=${DSM_PASSWORD_ESCAPED}" >> /etc/environment
    echo "POSTGRES_DB=${DSM_DBNAME}" >> /etc/environment
    echo "POSTGRES_SSL=true" >> /etc/environment
    echo "API_PORT=${API_PORT}" >> /etc/environment
  - |
    echo "[Unit]" > /etc/systemd/system/api-server.service
    echo "Description=Express API Server" >> /etc/systemd/system/api-server.service
    echo "After=network.target" >> /etc/systemd/system/api-server.service
    echo "[Service]" >> /etc/systemd/system/api-server.service
    echo "Type=simple" >> /etc/systemd/system/api-server.service
    echo "WorkingDirectory=/opt/api" >> /etc/systemd/system/api-server.service
    echo "EnvironmentFile=/etc/environment" >> /etc/systemd/system/api-server.service
    echo "ExecStart=/usr/bin/node server.js" >> /etc/systemd/system/api-server.service
    echo "Restart=always" >> /etc/systemd/system/api-server.service
    echo "RestartSec=5" >> /etc/systemd/system/api-server.service
    echo "[Install]" >> /etc/systemd/system/api-server.service
    echo "WantedBy=multi-user.target" >> /etc/systemd/system/api-server.service
    systemctl daemon-reload
    systemctl enable api-server
    systemctl start api-server
CLOUDINIT_INNER
)

    # Create cloud-init secret
    if kubectl get secret "${VM_NAME}-cloud-init" -n "${SUPERVISOR_NAMESPACE}" >/dev/null 2>&1; then
      log_success "Secret '${VM_NAME}-cloud-init' already exists, updating..."
      kubectl delete secret "${VM_NAME}-cloud-init" -n "${SUPERVISOR_NAMESPACE}" --ignore-not-found
    fi
    kubectl create secret generic "${VM_NAME}-cloud-init" \
      -n "${SUPERVISOR_NAMESPACE}" \
      --from-literal=user-data="${CLOUD_INIT_USERDATA}"
    log_success "Cloud-init Secret '${VM_NAME}-cloud-init' created"

    # Apply VirtualMachine manifest
    if ! cat <<EOF | kubectl apply -f -
apiVersion: vmoperator.vmware.com/v1alpha3
kind: VirtualMachine
metadata:
  name: ${VM_NAME}
  namespace: ${SUPERVISOR_NAMESPACE}
  labels:
    app: ${API_APP_LABEL}
spec:
  className: ${VM_CLASS}
  imageName: ${VM_IMAGE}
  storageClass: ${STORAGE_CLASS}
  powerState: PoweredOn
  bootstrap:
    cloudInit:
      rawCloudConfig:
        name: ${VM_NAME}-cloud-init
        key: user-data
EOF
    then
      log_error "Failed to apply VirtualMachine manifest for '${VM_NAME}'"
      exit 3
    fi

    log_success "VirtualMachine '${VM_NAME}' manifest applied to namespace '${SUPERVISOR_NAMESPACE}'"
  fi

  # Ensure the app label exists on the VM (for idempotent re-runs)
  kubectl label virtualmachine "${VM_NAME}" -n "${SUPERVISOR_NAMESPACE}" app=${API_APP_LABEL} --overwrite 2>/dev/null || true

  # Wait for VM to reach PoweredOn state
  if ! wait_for_condition "VM '${VM_NAME}' to be powered on" \
    "${VM_TIMEOUT}" "${POLL_INTERVAL}" \
    "kubectl get virtualmachine '${VM_NAME}' -n '${SUPERVISOR_NAMESPACE}' -o jsonpath='{.status.powerState}' 2>/dev/null | grep -q 'PoweredOn'"; then
    VM_STATUS=$(kubectl get virtualmachine "${VM_NAME}" -n "${SUPERVISOR_NAMESPACE}" -o jsonpath='{.status}' 2>/dev/null || echo "unable to retrieve status")
    log_error "VM '${VM_NAME}' did not reach PoweredOn state within ${VM_TIMEOUT}s. Current status: ${VM_STATUS}"
    exit 3
  fi

  log_success "VM '${VM_NAME}' is powered on"

  # Wait for VM IP address assignment
  echo "Waiting for VM '${VM_NAME}' IP address to be assigned..."
  IP_TIMEOUT=120
  IP_ELAPSED=0
  VM_IP=""
  while [[ "${IP_ELAPSED}" -lt "${IP_TIMEOUT}" ]]; do
    VM_IP=$(get_vm_ip "${VM_NAME}" "${SUPERVISOR_NAMESPACE}")
    if [[ -n "${VM_IP}" ]]; then
      break
    fi
    echo "  VM IP not yet assigned — waiting... (${IP_ELAPSED}s/${IP_TIMEOUT}s)"
    sleep 10
    IP_ELAPSED=$((IP_ELAPSED + 10))
  done

  if [[ -z "${VM_IP}" ]]; then
    log_error "Failed to extract IP address for VM '${VM_NAME}' within ${IP_TIMEOUT}s"
    exit 3
  fi

  log_success "VM '${VM_NAME}' IP address: ${VM_IP}"
  API_VM_IPS+=("${VM_IP}")
done

log_success "Phase 2 complete — API tier VMs provisioned (${API_VM_NAMES[0]}=${API_VM_IPS[0]}, ${API_VM_NAMES[1]}=${API_VM_IPS[1]})"

###############################################################################
# Phase 3: API Tier Internal VirtualMachineService
###############################################################################

log_step 3 "Creating VirtualMachineService LoadBalancer '${API_SVC_NAME}' for API tier"

# Idempotency check — skip creation if VirtualMachineService already exists
if kubectl get virtualmachineservice "${API_SVC_NAME}" -n "${SUPERVISOR_NAMESPACE}" >/dev/null 2>&1; then
  log_success "VirtualMachineService '${API_SVC_NAME}' already exists, skipping creation"
else
  if ! cat <<EOF | kubectl apply -f -
apiVersion: vmoperator.vmware.com/v1alpha3
kind: VirtualMachineService
metadata:
  name: ${API_SVC_NAME}
  namespace: ${SUPERVISOR_NAMESPACE}
spec:
  type: LoadBalancer
  selector:
    app: ${API_APP_LABEL}
  ports:
  - name: api
    port: ${API_PORT}
    protocol: TCP
    targetPort: ${API_PORT}
EOF
  then
    log_error "Failed to create VirtualMachineService '${API_SVC_NAME}'"
    exit 4
  fi
  log_success "VirtualMachineService '${API_SVC_NAME}' created (LoadBalancer, port ${API_PORT} → ${API_PORT})"
fi

# Wait for LoadBalancer IP to be assigned
log_step "3b" "Waiting for API LoadBalancer IP assignment"

if ! wait_for_condition "LoadBalancer '${API_SVC_NAME}' to receive IP" \
  "${LB_TIMEOUT}" "${POLL_INTERVAL}" \
  "[[ -n \$(kubectl get virtualmachineservice '${API_SVC_NAME}' -n '${SUPERVISOR_NAMESPACE}' -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null) ]]"; then
  log_error "LoadBalancer '${API_SVC_NAME}' did not receive an IP within ${LB_TIMEOUT}s"
  kubectl get virtualmachineservice "${API_SVC_NAME}" -n "${SUPERVISOR_NAMESPACE}" -o wide 2>/dev/null || true
  exit 4
fi

API_VIP=$(kubectl get virtualmachineservice "${API_SVC_NAME}" -n "${SUPERVISOR_NAMESPACE}" -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

log_success "API VIP address: ${API_VIP}"
log_success "Phase 3 complete — API tier LoadBalancer service created at ${API_VIP}"

###############################################################################
# Phase 4: Web Tier VM Provisioning
###############################################################################

log_step 4 "Provisioning Web tier VMs in supervisor namespace '${SUPERVISOR_NAMESPACE}'"

WEB_VM_NAMES=("${WEB_VM_01_NAME}" "${WEB_VM_02_NAME}")
WEB_VM_IPS=()

for VM_NAME in "${WEB_VM_NAMES[@]}"; do
  echo "--- Provisioning ${VM_NAME} ---"

  # Idempotency check — skip creation if VM already exists
  if kubectl get virtualmachine "${VM_NAME}" -n "${SUPERVISOR_NAMESPACE}" >/dev/null 2>&1; then
    log_success "VirtualMachine '${VM_NAME}' already exists in namespace '${SUPERVISOR_NAMESPACE}', skipping creation"
  else
    # Create cloud-init secret for Web VM
    CLOUD_INIT_USERDATA=$(cat <<CLOUDINIT_INNER
#cloud-config
package_update: true
packages:
  - openssh-server
  - ca-certificates
  - curl
  - gnupg
  - git

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
    sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
    sed -i 's/^#*ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config
    systemctl restart sshd
    systemctl enable ssh
  - |
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" > /etc/apt/sources.list.d/nodesource.list
    apt-get update
    apt-get install -y nodejs
  - |
    for i in 1 2 3 4 5; do
      git clone --depth 1 --branch ${GIT_BRANCH} ${GIT_REPO_URL} /tmp/repo && break
      echo "git clone attempt \$i failed, retrying in 10s..."
      sleep 10
    done
    cp -r /tmp/repo/examples/deploy-ha-vm-app/dashboard /opt/dashboard
    rm -rf /tmp/repo
  - |
    echo "API_HOST=${API_VIP}" > /etc/environment
    echo "API_PORT=${API_PORT}" >> /etc/environment
  - |
    cd /opt/dashboard && npm install && npm run build
  - |
    echo "[Unit]" > /etc/systemd/system/dashboard.service
    echo "Description=Next.js Dashboard" >> /etc/systemd/system/dashboard.service
    echo "After=network.target" >> /etc/systemd/system/dashboard.service
    echo "[Service]" >> /etc/systemd/system/dashboard.service
    echo "Type=simple" >> /etc/systemd/system/dashboard.service
    echo "WorkingDirectory=/opt/dashboard" >> /etc/systemd/system/dashboard.service
    echo "EnvironmentFile=/etc/environment" >> /etc/systemd/system/dashboard.service
    echo "ExecStart=/usr/bin/node .next/standalone/server.js" >> /etc/systemd/system/dashboard.service
    echo "Restart=always" >> /etc/systemd/system/dashboard.service
    echo "RestartSec=5" >> /etc/systemd/system/dashboard.service
    echo "Environment=PORT=${FRONTEND_PORT}" >> /etc/systemd/system/dashboard.service
    echo "Environment=HOSTNAME=0.0.0.0" >> /etc/systemd/system/dashboard.service
    echo "[Install]" >> /etc/systemd/system/dashboard.service
    echo "WantedBy=multi-user.target" >> /etc/systemd/system/dashboard.service
    systemctl daemon-reload
    systemctl enable dashboard
    systemctl start dashboard
CLOUDINIT_INNER
)

    # Create cloud-init secret
    if kubectl get secret "${VM_NAME}-cloud-init" -n "${SUPERVISOR_NAMESPACE}" >/dev/null 2>&1; then
      log_success "Secret '${VM_NAME}-cloud-init' already exists, updating..."
      kubectl delete secret "${VM_NAME}-cloud-init" -n "${SUPERVISOR_NAMESPACE}" --ignore-not-found
    fi
    kubectl create secret generic "${VM_NAME}-cloud-init" \
      -n "${SUPERVISOR_NAMESPACE}" \
      --from-literal=user-data="${CLOUD_INIT_USERDATA}"
    log_success "Cloud-init Secret '${VM_NAME}-cloud-init' created"

    # Apply VirtualMachine manifest
    if ! cat <<EOF | kubectl apply -f -
apiVersion: vmoperator.vmware.com/v1alpha3
kind: VirtualMachine
metadata:
  name: ${VM_NAME}
  namespace: ${SUPERVISOR_NAMESPACE}
  labels:
    app: ${WEB_APP_LABEL}
spec:
  className: ${VM_CLASS}
  imageName: ${VM_IMAGE}
  storageClass: ${STORAGE_CLASS}
  powerState: PoweredOn
  bootstrap:
    cloudInit:
      rawCloudConfig:
        name: ${VM_NAME}-cloud-init
        key: user-data
EOF
    then
      log_error "Failed to apply VirtualMachine manifest for '${VM_NAME}'"
      exit 5
    fi

    log_success "VirtualMachine '${VM_NAME}' manifest applied to namespace '${SUPERVISOR_NAMESPACE}'"
  fi

  # Ensure the app label exists on the VM (for idempotent re-runs)
  kubectl label virtualmachine "${VM_NAME}" -n "${SUPERVISOR_NAMESPACE}" app=${WEB_APP_LABEL} --overwrite 2>/dev/null || true

  # Wait for VM to reach PoweredOn state
  if ! wait_for_condition "VM '${VM_NAME}' to be powered on" \
    "${VM_TIMEOUT}" "${POLL_INTERVAL}" \
    "kubectl get virtualmachine '${VM_NAME}' -n '${SUPERVISOR_NAMESPACE}' -o jsonpath='{.status.powerState}' 2>/dev/null | grep -q 'PoweredOn'"; then
    VM_STATUS=$(kubectl get virtualmachine "${VM_NAME}" -n "${SUPERVISOR_NAMESPACE}" -o jsonpath='{.status}' 2>/dev/null || echo "unable to retrieve status")
    log_error "VM '${VM_NAME}' did not reach PoweredOn state within ${VM_TIMEOUT}s. Current status: ${VM_STATUS}"
    exit 5
  fi

  log_success "VM '${VM_NAME}' is powered on"

  # Wait for VM IP address assignment
  echo "Waiting for VM '${VM_NAME}' IP address to be assigned..."
  IP_TIMEOUT=120
  IP_ELAPSED=0
  VM_IP=""
  while [[ "${IP_ELAPSED}" -lt "${IP_TIMEOUT}" ]]; do
    VM_IP=$(get_vm_ip "${VM_NAME}" "${SUPERVISOR_NAMESPACE}")
    if [[ -n "${VM_IP}" ]]; then
      break
    fi
    echo "  VM IP not yet assigned — waiting... (${IP_ELAPSED}s/${IP_TIMEOUT}s)"
    sleep 10
    IP_ELAPSED=$((IP_ELAPSED + 10))
  done

  if [[ -z "${VM_IP}" ]]; then
    log_error "Failed to extract IP address for VM '${VM_NAME}' within ${IP_TIMEOUT}s"
    exit 5
  fi

  log_success "VM '${VM_NAME}' IP address: ${VM_IP}"
  WEB_VM_IPS+=("${VM_IP}")
done

log_success "Phase 4 complete — Web tier VMs provisioned (${WEB_VM_NAMES[0]}=${WEB_VM_IPS[0]}, ${WEB_VM_NAMES[1]}=${WEB_VM_IPS[1]})"

###############################################################################
# Phase 5: Web Tier VirtualMachineService LoadBalancer
###############################################################################

log_step 5 "Creating VirtualMachineService LoadBalancer '${WEB_LB_NAME}' for Web tier"

# Idempotency check — skip creation if VirtualMachineService already exists
if kubectl get virtualmachineservice "${WEB_LB_NAME}" -n "${SUPERVISOR_NAMESPACE}" >/dev/null 2>&1; then
  log_success "VirtualMachineService '${WEB_LB_NAME}' already exists, skipping creation"
else
  if ! cat <<EOF | kubectl apply -f -
apiVersion: vmoperator.vmware.com/v1alpha3
kind: VirtualMachineService
metadata:
  name: ${WEB_LB_NAME}
  namespace: ${SUPERVISOR_NAMESPACE}
spec:
  type: LoadBalancer
  selector:
    app: ${WEB_APP_LABEL}
  ports:
  - name: http
    port: 80
    protocol: TCP
    targetPort: ${FRONTEND_PORT}
EOF
  then
    log_error "Failed to create VirtualMachineService '${WEB_LB_NAME}'"
    exit 6
  fi
  log_success "VirtualMachineService '${WEB_LB_NAME}' created (LoadBalancer, port 80 → ${FRONTEND_PORT})"
fi

# Wait for LoadBalancer external IP to be assigned
log_step "5b" "Waiting for LoadBalancer external IP assignment"

if ! wait_for_condition "LoadBalancer '${WEB_LB_NAME}' to receive external IP" \
  "${LB_TIMEOUT}" "${POLL_INTERVAL}" \
  "[[ -n \$(kubectl get virtualmachineservice '${WEB_LB_NAME}' -n '${SUPERVISOR_NAMESPACE}' -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null) ]]"; then
  log_error "LoadBalancer '${WEB_LB_NAME}' did not receive an external IP within ${LB_TIMEOUT}s"
  kubectl get virtualmachineservice "${WEB_LB_NAME}" -n "${SUPERVISOR_NAMESPACE}" -o wide 2>/dev/null || true
  exit 6
fi

WEB_LB_IP=$(kubectl get virtualmachineservice "${WEB_LB_NAME}" -n "${SUPERVISOR_NAMESPACE}" -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
log_success "Web LB external IP: ${WEB_LB_IP}"
log_success "Phase 5 complete — Web tier LoadBalancer created at ${WEB_LB_IP}"

###############################################################################
# Phase 6: End-to-End Connectivity Verification
###############################################################################

log_step 6 "Verifying end-to-end connectivity"

RETRY_TIMEOUT=300

# HTTP GET to frontend — verify 200 (with retries)
ELAPSED=0
HTTP_STATUS=""
while [[ "${ELAPSED}" -lt "${RETRY_TIMEOUT}" ]]; do
  HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://${WEB_LB_IP}" --max-time 10 || true)
  if [[ "${HTTP_STATUS}" == "200" ]]; then
    log_success "Frontend HTTP connectivity test passed — received status 200 from http://${WEB_LB_IP}"
    break
  fi
  echo "  Frontend returned HTTP ${HTTP_STATUS}, retrying... (${ELAPSED}s/${RETRY_TIMEOUT}s)"
  sleep "${POLL_INTERVAL}"
  ELAPSED=$((ELAPSED + POLL_INTERVAL))
done
if [[ "${HTTP_STATUS}" != "200" ]]; then
  log_error "Frontend HTTP test returned status ${HTTP_STATUS} from http://${WEB_LB_IP} (expected 200)"
  exit 7
fi

# HTTP GET to API health check via Web LB (with retries)
ELAPSED=0
HEALTH_STATUS=""
while [[ "${ELAPSED}" -lt "${RETRY_TIMEOUT}" ]]; do
  HEALTH_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://${WEB_LB_IP}/api/healthz" --max-time 10 || true)
  if [[ "${HEALTH_STATUS}" == "200" ]]; then
    log_success "API health check passed — received status 200 from http://${WEB_LB_IP}/api/healthz"
    break
  fi
  echo "  API health check returned HTTP ${HEALTH_STATUS}, retrying... (${ELAPSED}s/${RETRY_TIMEOUT}s)"
  sleep "${POLL_INTERVAL}"
  ELAPSED=$((ELAPSED + POLL_INTERVAL))
done
if [[ "${HEALTH_STATUS}" != "200" ]]; then
  log_error "API health check returned status ${HEALTH_STATUS} from http://${WEB_LB_IP}/api/healthz (expected 200)"
  exit 7
fi

log_success "Phase 6 complete — end-to-end connectivity verified"

###############################################################################
# Success Summary
###############################################################################

echo ""
echo "============================================="
echo "  VCF 9 HA VM App — Deployment Complete"
echo "============================================="
echo "  Web LB IP:     http://${WEB_LB_IP}"
echo "  Web VM 01:     ${WEB_VM_NAMES[0]} (${WEB_VM_IPS[0]})"
echo "  Web VM 02:     ${WEB_VM_NAMES[1]} (${WEB_VM_IPS[1]})"
echo "  API VM 01:     ${API_VM_NAMES[0]} (${API_VM_IPS[0]})"
echo "  API VM 02:     ${API_VM_NAMES[1]} (${API_VM_IPS[1]})"
echo "  API VIP:       ${API_VIP}"
echo "  DSM Endpoint:  ${DSM_HOST}:${DSM_PORT}/${DSM_DBNAME}"
echo "  DSM User:      ${DSM_USERNAME}"
echo "  Namespace:     ${SUPERVISOR_NAMESPACE}"
echo "============================================="
echo ""

exit 0
