#!/bin/bash
set -euo pipefail

###############################################################################
# VCF 9 Deploy Managed DB App — Infrastructure Asset Tracker Deploy Script
#
# This script deploys a full-stack Infrastructure Asset Tracker demo backed by
# a VCF Database Service Manager (DSM) managed PostgresCluster — the VCF
# equivalent of AWS EKS + RDS:
#   Phase 1: Provision DSM PostgresCluster via CRD
#   Phase 2: Build & Push Container Images
#   Phase 3: Deploy API Service to VKS Cluster
#   Phase 4: Deploy Frontend Service to VKS Cluster
#   Phase 5: Connectivity Verification
#
# Instead of manually provisioning a PostgreSQL VM (as in deploy-hybrid-app),
# this example uses the DSM PostgresCluster CRD
# (databases.dataservices.vmware.com/v1alpha1) to provision a fully managed
# PostgreSQL instance in the supervisor namespace.
#
# Prerequisites:
#   - Deploy Cluster completed successfully (VKS cluster running)
#   - Valid admin kubeconfig for the guest cluster
#   - VCF CLI installed and configured with supervisor context
#   - kubectl installed
#   - Docker installed
#   - DSM infrastructure policy configured in the supervisor namespace
#
# Edit the variable block below with your environment-specific values,
# then run: bash examples/deploy-managed-db-app/deploy-managed-db-app.sh
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

# --- Application Namespace ---
APP_NAMESPACE="${APP_NAMESPACE:-managed-db-app}"

# --- Container Image ---
CONTAINER_REGISTRY="${CONTAINER_REGISTRY:-scafeman}"
IMAGE_TAG="${IMAGE_TAG:-latest}"

# --- Ports ---
API_PORT="${API_PORT:-3001}"
FRONTEND_PORT="${FRONTEND_PORT:-3000}"

# --- Storage ---
STORAGE_CLASS="${STORAGE_CLASS:-nfs}"

# --- Timeouts and Polling ---
DSM_TIMEOUT="${DSM_TIMEOUT:-1800}"
POD_TIMEOUT="${POD_TIMEOUT:-300}"
LB_TIMEOUT="${LB_TIMEOUT:-300}"
POLL_INTERVAL="${POLL_INTERVAL:-30}"

###############################################################################
# Exit Codes
#   0 = Success
#   1 = Variable validation failure
#   2 = DSM PostgresCluster provisioning failure / timeout
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

###############################################################################
# Pre-Flight Validation
###############################################################################

validate_variables

###############################################################################
# VCF CLI Context Setup
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
  # Fallback: try matching by project pattern
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
# Phase 1: Provision DSM PostgresCluster
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

###############################################################################
# Phase 2: Build & Push Container Images
###############################################################################

log_step 2 "Building and pushing container images"

API_IMAGE="${CONTAINER_REGISTRY}/hybrid-app-api:${IMAGE_TAG}"
FRONTEND_IMAGE="${CONTAINER_REGISTRY}/hybrid-app-dashboard:${IMAGE_TAG}"

# Login to DockerHub if credentials are available
if [ -n "${DOCKERHUB_USERNAME:-}" ] && [ -n "${DOCKERHUB_TOKEN:-}" ]; then
  echo "${DOCKERHUB_TOKEN}" | docker login -u "${DOCKERHUB_USERNAME}" --password-stdin
  log_success "Logged in to DockerHub"
fi

# Build API image
if ! docker build -t "${API_IMAGE}" examples/deploy-hybrid-app/api/; then
  log_error "Failed to build API container image '${API_IMAGE}'"
  exit 3
fi

log_success "API container image '${API_IMAGE}' built successfully"

# Build Frontend image
if ! docker build -t "${FRONTEND_IMAGE}" examples/deploy-hybrid-app/dashboard/; then
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
  name: managed-db-api
  namespace: ${APP_NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: managed-db-api
  template:
    metadata:
      labels:
        app: managed-db-api
    spec:
      containers:
      - name: api
        image: ${CONTAINER_REGISTRY}/hybrid-app-api:${IMAGE_TAG}
        env:
        - name: POSTGRES_HOST
          value: "${DSM_HOST}"
        - name: POSTGRES_PORT
          value: "${DSM_PORT}"
        - name: POSTGRES_USER
          value: "${DSM_USERNAME}"
        - name: POSTGRES_PASSWORD
          value: "${DSM_PASSWORD}"
        - name: POSTGRES_DB
          value: "${DSM_DBNAME}"
        - name: POSTGRES_SSL
          value: "true"
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
  name: managed-db-api
  namespace: ${APP_NAMESPACE}
spec:
  type: ClusterIP
  selector:
    app: managed-db-api
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
  "kubectl get pods -n '${APP_NAMESPACE}' -l app=managed-db-api --no-headers 2>/dev/null | grep -q 'Running'"; then
  log_error "API pod did not reach Running state within ${POD_TIMEOUT}s"
  kubectl get pods -n "${APP_NAMESPACE}" -l app=managed-db-api -o wide 2>/dev/null || true
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
  name: managed-db-dashboard
  namespace: ${APP_NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: managed-db-dashboard
  template:
    metadata:
      labels:
        app: managed-db-dashboard
    spec:
      containers:
      - name: dashboard
        image: ${CONTAINER_REGISTRY}/hybrid-app-dashboard:${IMAGE_TAG}
        env:
        - name: API_HOST
          value: "managed-db-api.${APP_NAMESPACE}.svc.cluster.local"
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
  name: managed-db-dashboard-lb
  namespace: ${APP_NAMESPACE}
spec:
  type: LoadBalancer
  selector:
    app: managed-db-dashboard
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
  "kubectl get pods -n '${APP_NAMESPACE}' -l app=managed-db-dashboard --no-headers 2>/dev/null | grep -q 'Running'"; then
  log_error "Frontend pod did not reach Running state within ${POD_TIMEOUT}s"
  kubectl get pods -n "${APP_NAMESPACE}" -l app=managed-db-dashboard -o wide 2>/dev/null || true
  exit 5
fi

log_success "Frontend pod is running"

# Wait for LoadBalancer external IP
if ! wait_for_condition "LoadBalancer 'managed-db-dashboard-lb' to receive external IP" \
  "${LB_TIMEOUT}" "${POLL_INTERVAL}" \
  "[[ -n \$(kubectl get svc managed-db-dashboard-lb -n '${APP_NAMESPACE}' -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null) ]]"; then
  log_error "LoadBalancer 'managed-db-dashboard-lb' did not receive an external IP within ${LB_TIMEOUT}s"
  kubectl get svc managed-db-dashboard-lb -n "${APP_NAMESPACE}" -o wide 2>/dev/null || true
  exit 5
fi

FRONTEND_IP=$(kubectl get svc managed-db-dashboard-lb -n "${APP_NAMESPACE}" -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
log_success "Frontend LoadBalancer assigned external IP: ${FRONTEND_IP}"
log_success "Phase 4 complete — Frontend service deployed with external IP ${FRONTEND_IP}"

###############################################################################
# Phase 5: Connectivity Verification
###############################################################################

log_step 5 "Verifying end-to-end connectivity"

RETRY_TIMEOUT=120
RETRY_INTERVAL=10

# HTTP GET to frontend — verify 200 (with retries)
ELAPSED=0
HTTP_STATUS=""
while [[ "${ELAPSED}" -lt "${RETRY_TIMEOUT}" ]]; do
  HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://${FRONTEND_IP}" --max-time 10 || true)
  if [[ "${HTTP_STATUS}" == "200" ]]; then
    log_success "Frontend HTTP connectivity test passed — received status 200 from http://${FRONTEND_IP}"
    break
  fi
  echo "  Frontend returned HTTP ${HTTP_STATUS}, retrying... (${ELAPSED}s/${RETRY_TIMEOUT}s)"
  sleep "${RETRY_INTERVAL}"
  ELAPSED=$((ELAPSED + RETRY_INTERVAL))
done
if [[ "${HTTP_STATUS}" != "200" ]]; then
  log_error "Frontend HTTP test returned status ${HTTP_STATUS} from http://${FRONTEND_IP} (expected 200)"
  exit 6
fi

# HTTP GET to API health check via frontend (with retries — API may still be initializing schema)
ELAPSED=0
HEALTH_STATUS=""
while [[ "${ELAPSED}" -lt "${RETRY_TIMEOUT}" ]]; do
  HEALTH_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://${FRONTEND_IP}/api/healthz" --max-time 10 || true)
  if [[ "${HEALTH_STATUS}" == "200" ]]; then
    log_success "API health check passed — received status 200 from http://${FRONTEND_IP}/api/healthz"
    break
  fi
  echo "  API health check returned HTTP ${HEALTH_STATUS}, retrying... (${ELAPSED}s/${RETRY_TIMEOUT}s)"
  sleep "${RETRY_INTERVAL}"
  ELAPSED=$((ELAPSED + RETRY_INTERVAL))
done
if [[ "${HEALTH_STATUS}" != "200" ]]; then
  log_error "API health check returned status ${HEALTH_STATUS} from http://${FRONTEND_IP}/api/healthz (expected 200)"
  exit 6
fi

log_success "Phase 5 complete — end-to-end connectivity verified"

###############################################################################
# Success Summary
###############################################################################

echo ""
echo "============================================="
echo "  VCF 9 Managed DB App — Deployment Complete"
echo "============================================="
echo "  Cluster:       ${CLUSTER_NAME}"
echo "  Namespace:     ${APP_NAMESPACE}"
echo "  DSM Host:      ${DSM_HOST}:${DSM_PORT}"
echo "  Database:      ${DSM_DBNAME}"
echo "  Frontend:      http://${FRONTEND_IP}"
echo "============================================="
echo ""

exit 0
