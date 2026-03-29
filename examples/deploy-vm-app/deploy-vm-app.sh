#!/bin/bash
set -euo pipefail

###############################################################################
# VCF 9 Deploy VM App — Infrastructure Asset Tracker Deploy Script
#
# This script deploys a full-stack Infrastructure Asset Tracker demo that
# demonstrates VM-to-container connectivity within a VCF 9 namespace:
#   Phase 1: Provision PostgreSQL VM via VM Service
#   Phase 2: Build & Push Container Images
#   Phase 3: Deploy API Service to VKS Cluster
#   Phase 4: Deploy Frontend Service to VKS Cluster
#   Phase 5: Connectivity Verification
#
# Prerequisites:
#   - Deploy Cluster completed successfully (VKS cluster running)
#   - Valid admin kubeconfig for the guest cluster
#   - VCF CLI installed and configured with supervisor context
#   - kubectl installed
#   - Docker installed
#
# Edit the variable block below with your environment-specific values,
# then run: bash examples/deploy-vm-app/deploy-vm-app.sh
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
VM_IMAGE="${VM_IMAGE:-ubuntu-24.04.3-live-server-amd64}"
VM_CONTENT_LIBRARY_ID="${VM_CONTENT_LIBRARY_ID:-}"
VM_NAME="${VM_NAME:-postgresql-vm}"

# --- PostgreSQL Credentials ---
POSTGRES_USER="${POSTGRES_USER:-assetadmin}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-assetpass}"
POSTGRES_DB="${POSTGRES_DB:-assetdb}"

# --- Application Namespace ---
APP_NAMESPACE="${APP_NAMESPACE:-vm-app}"

# --- Container Image ---
CONTAINER_REGISTRY="${CONTAINER_REGISTRY:-scafeman}"
IMAGE_TAG="${IMAGE_TAG:-latest}"

# --- Ports ---
API_PORT="${API_PORT:-3001}"
FRONTEND_PORT="${FRONTEND_PORT:-3000}"

# --- Timeouts and Polling ---
VM_TIMEOUT="${VM_TIMEOUT:-600}"
POD_TIMEOUT="${POD_TIMEOUT:-300}"
LB_TIMEOUT="${LB_TIMEOUT:-300}"
POLL_INTERVAL="${POLL_INTERVAL:-30}"

###############################################################################
# Exit Codes
#   0 = Success
#   1 = Variable validation failure
#   2 = VM provisioning failure / timeout
#   3 = Container image build/push failure
#   4 = API service deployment failure
#   5 = Frontend service deployment failure
#   6 = Connectivity verification failure
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
    "VM_IMAGE"
    "VM_CONTENT_LIBRARY_ID"
    "VCF_API_TOKEN"
    "VCFA_ENDPOINT"
    "TENANT_NAME"
    "CONTEXT_NAME"
    "KUBECONFIG_FILE"
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

###############################################################################
# Phase 1: Provision PostgreSQL VM via VM Service
###############################################################################

log_step 1 "Provisioning PostgreSQL VM '${VM_NAME}' in supervisor namespace '${SUPERVISOR_NAMESPACE}'"

# Idempotency check — skip creation if VM already exists
if kubectl get virtualmachine "${VM_NAME}" -n "${SUPERVISOR_NAMESPACE}" >/dev/null 2>&1; then
  log_success "VirtualMachine '${VM_NAME}' already exists in namespace '${SUPERVISOR_NAMESPACE}', skipping creation"
else
  # Generate cloud-init user data for PostgreSQL 16 installation and configuration
  CLOUD_INIT_USERDATA=$(cat <<'CLOUDINIT_INNER'
#cloud-config
package_update: true
packages:
  - postgresql-16
  - postgresql-client-16

write_files:
  - path: /etc/postgresql/16/main/pg_hba.conf
    content: |
      # TYPE  DATABASE        USER            ADDRESS                 METHOD
      local   all             postgres                                peer
      local   all             all                                     peer
      host    all             all             127.0.0.1/32            md5
      host    all             all             ::1/128                 md5
      host    all             all             0.0.0.0/0               md5
    owner: postgres:postgres
    permissions: '0640'

runcmd:
  - |
    # Configure PostgreSQL to listen on all interfaces
    sed -i "s/#listen_addresses = 'localhost'/listen_addresses = '*'/" /etc/postgresql/16/main/postgresql.conf
    # Restart PostgreSQL to apply configuration changes
    systemctl restart postgresql
    # Create the application database user and database
    sudo -u postgres psql -c "CREATE USER POSTGRES_USER_PLACEHOLDER WITH PASSWORD 'POSTGRES_PASSWORD_PLACEHOLDER';"
    sudo -u postgres psql -c "CREATE DATABASE POSTGRES_DB_PLACEHOLDER OWNER POSTGRES_USER_PLACEHOLDER;"
    sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE POSTGRES_DB_PLACEHOLDER TO POSTGRES_USER_PLACEHOLDER;"
    # Ensure PostgreSQL is enabled on boot
    systemctl enable postgresql
CLOUDINIT_INNER
)

  # Substitute actual credential values into cloud-init
  CLOUD_INIT_USERDATA="${CLOUD_INIT_USERDATA//POSTGRES_USER_PLACEHOLDER/${POSTGRES_USER}}"
  CLOUD_INIT_USERDATA="${CLOUD_INIT_USERDATA//POSTGRES_PASSWORD_PLACEHOLDER/${POSTGRES_PASSWORD}}"
  CLOUD_INIT_USERDATA="${CLOUD_INIT_USERDATA//POSTGRES_DB_PLACEHOLDER/${POSTGRES_DB}}"

  # Base64-encode the cloud-init user data
  CLOUD_INIT_B64=$(echo "${CLOUD_INIT_USERDATA}" | base64 -w 0)

  if ! cat <<EOF | kubectl apply -f -
apiVersion: vmoperator.vmware.com/v1alpha3
kind: VirtualMachine
metadata:
  name: ${VM_NAME}
  namespace: ${SUPERVISOR_NAMESPACE}
spec:
  className: ${VM_CLASS}
  imageName: ${VM_IMAGE}
  powerState: PoweredOn
  bootstrap:
    cloudInit:
      rawCloudConfig:
        key: guestinfo.userdata
        name: ${VM_NAME}-cloud-init
  volumes:
  - name: cloud-init-volume
    cloudInitNoCloud:
      userData:
        value: "${CLOUD_INIT_B64}"
EOF
  then
    log_error "Failed to apply VirtualMachine manifest for '${VM_NAME}'"
    exit 2
  fi

  log_success "VirtualMachine '${VM_NAME}' manifest applied to namespace '${SUPERVISOR_NAMESPACE}'"
fi

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

# Extract VM IP address from VirtualMachine status
VM_IP=$(kubectl get virtualmachine "${VM_NAME}" -n "${SUPERVISOR_NAMESPACE}" -o jsonpath='{.status.network.interfaces[0].ipAddresses[0]}' 2>/dev/null || true)

if [[ -z "${VM_IP}" ]]; then
  # Try alternative IP path
  VM_IP=$(kubectl get virtualmachine "${VM_NAME}" -n "${SUPERVISOR_NAMESPACE}" -o jsonpath='{.status.vmIp}' 2>/dev/null || true)
fi

if [[ -z "${VM_IP}" ]]; then
  log_error "Failed to extract IP address for VM '${VM_NAME}'. Check VirtualMachine status."
  exit 2
fi

log_success "PostgreSQL VM IP address: ${VM_IP}"
log_success "Phase 1 complete — PostgreSQL VM '${VM_NAME}' provisioned at ${VM_IP}"

###############################################################################
# Phase 2: Build & Push Container Images
###############################################################################

log_step 2 "Building and pushing container images"

API_IMAGE="${CONTAINER_REGISTRY}/vm-app-api:${IMAGE_TAG}"
FRONTEND_IMAGE="${CONTAINER_REGISTRY}/vm-app-dashboard:${IMAGE_TAG}"

# Login to DockerHub if credentials are available
if [ -n "${DOCKERHUB_USERNAME:-}" ] && [ -n "${DOCKERHUB_TOKEN:-}" ]; then
  echo "${DOCKERHUB_TOKEN}" | docker login -u "${DOCKERHUB_USERNAME}" --password-stdin
  log_success "Logged in to DockerHub"
fi

# Build API image
if ! docker build -t "${API_IMAGE}" examples/deploy-vm-app/api/; then
  log_error "Failed to build API container image '${API_IMAGE}'"
  exit 3
fi

log_success "API container image '${API_IMAGE}' built successfully"

# Build Frontend image
if ! docker build -t "${FRONTEND_IMAGE}" examples/deploy-vm-app/dashboard/; then
  log_error "Failed to build Frontend container image '${FRONTEND_IMAGE}'"
  exit 3
fi

log_success "Frontend container image '${FRONTEND_IMAGE}' built successfully"

# Push API image
if ! docker push "${API_IMAGE}"; then
  log_error "Failed to push API container image '${API_IMAGE}'"
  exit 3
fi

log_success "API container image '${API_IMAGE}' pushed successfully"

# Push Frontend image
if ! docker push "${FRONTEND_IMAGE}"; then
  log_error "Failed to push Frontend container image '${FRONTEND_IMAGE}'"
  exit 3
fi

log_success "Frontend container image '${FRONTEND_IMAGE}' pushed successfully"

log_success "Phase 2 complete — container images built and pushed"

###############################################################################
# Phase 3: Deploy API Service
###############################################################################

log_step 3 "Deploying API service to guest cluster"

# Switch to guest cluster kubeconfig
export KUBECONFIG="${KUBECONFIG_FILE}"

# Use admin context
kubectl config use-context "$(kubectl config get-contexts -o name | head -1)" >/dev/null 2>&1 || true

# Verify guest cluster connectivity
if ! kubectl get namespaces >/dev/null 2>&1; then
  log_error "Unable to reach guest cluster using kubeconfig at '${KUBECONFIG_FILE}'. Verify the cluster is running and the kubeconfig is valid."
  exit 4
fi

log_success "Connected to guest cluster via '${KUBECONFIG_FILE}'"

# Create application namespace (idempotent)
if kubectl get ns "${APP_NAMESPACE}" >/dev/null 2>&1; then
  log_success "Namespace '${APP_NAMESPACE}' already exists, skipping creation"
else
  kubectl create ns "${APP_NAMESPACE}"
  log_success "Namespace '${APP_NAMESPACE}' created"
fi

kubectl label ns "${APP_NAMESPACE}" \
  pod-security.kubernetes.io/enforce=privileged \
  --overwrite >/dev/null 2>&1 || true

# Deploy API Deployment
if ! cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vm-app-api
  namespace: ${APP_NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: vm-app-api
  template:
    metadata:
      labels:
        app: vm-app-api
    spec:
      containers:
      - name: api
        image: ${CONTAINER_REGISTRY}/vm-app-api:${IMAGE_TAG}
        env:
        - name: POSTGRES_HOST
          value: "${VM_IP}"
        - name: POSTGRES_PORT
          value: "5432"
        - name: POSTGRES_USER
          value: "${POSTGRES_USER}"
        - name: POSTGRES_PASSWORD
          value: "${POSTGRES_PASSWORD}"
        - name: POSTGRES_DB
          value: "${POSTGRES_DB}"
        - name: API_PORT
          value: "${API_PORT}"
        ports:
        - containerPort: ${API_PORT}
        readinessProbe:
          httpGet:
            path: /healthz
            port: ${API_PORT}
          initialDelaySeconds: 10
          periodSeconds: 5
EOF
then
  log_error "Failed to deploy API Deployment"
  exit 4
fi

log_success "API Deployment applied"

# Deploy API ClusterIP Service
if ! cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: vm-app-api
  namespace: ${APP_NAMESPACE}
spec:
  type: ClusterIP
  selector:
    app: vm-app-api
  ports:
  - port: ${API_PORT}
    targetPort: ${API_PORT}
    protocol: TCP
EOF
then
  log_error "Failed to deploy API ClusterIP Service"
  exit 4
fi

log_success "API ClusterIP Service applied on port ${API_PORT}"

# Wait for API pod to reach Running state
if ! wait_for_condition "API pod to be running" \
  "${POD_TIMEOUT}" "${POLL_INTERVAL}" \
  "kubectl get pods -n '${APP_NAMESPACE}' -l app=vm-app-api --no-headers 2>/dev/null | grep -q 'Running'"; then
  log_error "API pod did not reach Running state within ${POD_TIMEOUT}s"
  kubectl get pods -n "${APP_NAMESPACE}" -l app=vm-app-api -o wide 2>/dev/null || true
  exit 4
fi

log_success "API pod is running"
log_success "Phase 3 complete — API service deployed to namespace '${APP_NAMESPACE}'"

###############################################################################
# Phase 4: Deploy Frontend Service
###############################################################################

log_step 4 "Deploying Frontend service to guest cluster"

# Deploy Frontend Deployment
if ! cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vm-app-dashboard
  namespace: ${APP_NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: vm-app-dashboard
  template:
    metadata:
      labels:
        app: vm-app-dashboard
    spec:
      containers:
      - name: dashboard
        image: ${CONTAINER_REGISTRY}/vm-app-dashboard:${IMAGE_TAG}
        env:
        - name: API_HOST
          value: "vm-app-api.${APP_NAMESPACE}.svc.cluster.local"
        - name: API_PORT
          value: "${API_PORT}"
        ports:
        - containerPort: ${FRONTEND_PORT}
EOF
then
  log_error "Failed to deploy Frontend Deployment"
  exit 5
fi

log_success "Frontend Deployment applied"

# Deploy Frontend LoadBalancer Service
if ! cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: vm-app-dashboard-lb
  namespace: ${APP_NAMESPACE}
spec:
  type: LoadBalancer
  selector:
    app: vm-app-dashboard
  ports:
  - port: 80
    targetPort: ${FRONTEND_PORT}
    protocol: TCP
EOF
then
  log_error "Failed to deploy Frontend LoadBalancer Service"
  exit 5
fi

log_success "Frontend LoadBalancer Service applied (port 80 → ${FRONTEND_PORT})"

# Wait for Frontend pod to reach Running state
if ! wait_for_condition "Frontend pod to be running" \
  "${POD_TIMEOUT}" "${POLL_INTERVAL}" \
  "kubectl get pods -n '${APP_NAMESPACE}' -l app=vm-app-dashboard --no-headers 2>/dev/null | grep -q 'Running'"; then
  log_error "Frontend pod did not reach Running state within ${POD_TIMEOUT}s"
  kubectl get pods -n "${APP_NAMESPACE}" -l app=vm-app-dashboard -o wide 2>/dev/null || true
  exit 5
fi

log_success "Frontend pod is running"

# Wait for LoadBalancer external IP
if ! wait_for_condition "LoadBalancer 'vm-app-dashboard-lb' to receive external IP" \
  "${LB_TIMEOUT}" "${POLL_INTERVAL}" \
  "[[ -n \$(kubectl get svc vm-app-dashboard-lb -n '${APP_NAMESPACE}' -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null) ]]"; then
  log_error "LoadBalancer 'vm-app-dashboard-lb' did not receive an external IP within ${LB_TIMEOUT}s"
  kubectl get svc vm-app-dashboard-lb -n "${APP_NAMESPACE}" -o wide 2>/dev/null || true
  exit 5
fi

FRONTEND_IP=$(kubectl get svc vm-app-dashboard-lb -n "${APP_NAMESPACE}" -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
log_success "Frontend LoadBalancer assigned external IP: ${FRONTEND_IP}"
log_success "Phase 4 complete — Frontend service deployed with external IP ${FRONTEND_IP}"

###############################################################################
# Phase 5: Connectivity Verification
###############################################################################

log_step 5 "Verifying end-to-end connectivity"

# HTTP GET to frontend — verify 200
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://${FRONTEND_IP}" --max-time 10 || true)
if [[ "${HTTP_STATUS}" == "200" ]]; then
  log_success "Frontend HTTP connectivity test passed — received status 200 from http://${FRONTEND_IP}"
else
  log_error "Frontend HTTP test returned status ${HTTP_STATUS} from http://${FRONTEND_IP} (expected 200)"
  exit 6
fi

# HTTP GET to API health check via frontend
HEALTH_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://${FRONTEND_IP}/api/healthz" --max-time 10 || true)
if [[ "${HEALTH_STATUS}" == "200" ]]; then
  log_success "API health check passed — received status 200 from http://${FRONTEND_IP}/api/healthz"
else
  log_error "API health check returned status ${HEALTH_STATUS} from http://${FRONTEND_IP}/api/healthz (expected 200)"
  exit 6
fi

log_success "Phase 5 complete — end-to-end connectivity verified"

###############################################################################
# Success Summary
###############################################################################

echo ""
echo "============================================="
echo "  VCF 9 VM App — Deployment Complete"
echo "============================================="
echo "  Cluster:       ${CLUSTER_NAME}"
echo "  Namespace:     ${APP_NAMESPACE}"
echo "  PostgreSQL VM: ${VM_IP:-N/A}"
echo "  Frontend:      http://${FRONTEND_IP}"
echo "============================================="
echo ""

exit 0
