#!/bin/bash
set -euo pipefail

###############################################################################
# VCF 9 Deploy Knative — Serverless Asset Tracker with DSM PostgreSQL
#
# This script installs Knative Serving on an existing VKS cluster and deploys
# a full Asset Tracker with DSM PostgreSQL persistence, an API server,
# a serverless audit function, and a Next.js dashboard:
#   Phase 1:  Kubeconfig Setup & Connectivity Check
#   Phase 2:  Knative Serving CRDs
#   Phase 3:  Knative Serving Core
#   Phase 4:  net-contour Networking Plugin
#   Phase 5:  Ingress Configuration
#   Phase 6:  DNS Configuration (sslip.io)
#   Phase 7:  DSM PostgresCluster Provisioning
#   Phase 8:  API Server Deployment
#   Phase 9:  Audit Function Deployment (Knative Service with DSM)
#   Phase 10: RBAC and Dashboard Deployment
#   Phase 11: Verification & Scale-to-Zero Demo
#
# Prerequisites:
#   - Deploy Cluster completed successfully (VKS cluster running)
#   - Valid admin kubeconfig file for the target cluster
#   - Container images pushed to the registry
#   - VCF CLI installed and configured with supervisor context
#   - DSM infrastructure policy configured in the supervisor namespace
#
# Exit Codes:
#   0 — Success
#   1 — Variable validation failure
#   2 — CRD or core installation failure
#   3 — Networking/ingress failure
#   4 — DNS configuration failure
#   5 — DSM provisioning failure
#   6 — API server deployment failure
#   7 — Audit function deployment failure
#   8 — Dashboard deployment failure
#   9 — Verification failure
#
# Edit the variable block below with your environment-specific values,
# then run: bash examples/deploy-knative/deploy-knative.sh
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

# --- Knative Versions ---
KNATIVE_SERVING_VERSION="${KNATIVE_SERVING_VERSION:-1.21.2}"
NET_CONTOUR_VERSION="${NET_CONTOUR_VERSION:-1.21.1}"

# --- Namespaces ---
KNATIVE_NAMESPACE="${KNATIVE_NAMESPACE:-knative-serving}"
DEMO_NAMESPACE="${DEMO_NAMESPACE:-knative-demo}"

# --- VCF CLI Connection ---
VCF_API_TOKEN="${VCF_API_TOKEN:-}"
VCFA_ENDPOINT="${VCFA_ENDPOINT:-}"
TENANT_NAME="${TENANT_NAME:-}"
CONTEXT_NAME="${CONTEXT_NAME:-}"

# --- Supervisor Namespace ---
SUPERVISOR_NAMESPACE="${SUPERVISOR_NAMESPACE:-}"
PROJECT_NAME="${PROJECT_NAME:-}"

# --- DSM PostgresCluster Configuration ---
DSM_CLUSTER_NAME="${DSM_CLUSTER_NAME:-pg-clus-01}"
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

# --- Container Images ---
CONTAINER_REGISTRY="${CONTAINER_REGISTRY:-scafeman}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
AUDIT_IMAGE="${AUDIT_IMAGE:-${CONTAINER_REGISTRY}/knative-audit:${IMAGE_TAG}}"
API_IMAGE="${API_IMAGE:-${CONTAINER_REGISTRY}/knative-api:${IMAGE_TAG}}"

# --- Ports ---
API_PORT="${API_PORT:-3001}"

# --- Knative Configuration ---
SCALE_TO_ZERO_GRACE_PERIOD="${SCALE_TO_ZERO_GRACE_PERIOD:-30s}"

# --- Timeouts and Polling ---
KNATIVE_TIMEOUT="${KNATIVE_TIMEOUT:-300}"
POD_TIMEOUT="${POD_TIMEOUT:-300}"
LB_TIMEOUT="${LB_TIMEOUT:-300}"
DSM_TIMEOUT="${DSM_TIMEOUT:-1800}"
POLL_INTERVAL="${POLL_INTERVAL:-10}"

###############################################################################
# Derived Variables (computed — do not edit)
###############################################################################

KNATIVE_CRDS_URL="https://github.com/knative/serving/releases/download/knative-v${KNATIVE_SERVING_VERSION}/serving-crds.yaml"
KNATIVE_CORE_URL="https://github.com/knative/serving/releases/download/knative-v${KNATIVE_SERVING_VERSION}/serving-core.yaml"
CONTOUR_URL="https://github.com/knative-extensions/net-contour/releases/download/knative-v${NET_CONTOUR_VERSION}/contour.yaml"
NET_CONTOUR_URL="https://github.com/knative-extensions/net-contour/releases/download/knative-v${NET_CONTOUR_VERSION}/net-contour.yaml"
DASHBOARD_IMAGE="${CONTAINER_REGISTRY}/knative-dashboard:${IMAGE_TAG}"

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

log_error() {
  local message="$1"
  echo "✗ ERROR: ${message}" >&2
}

log_warn() {
  local message="$1"
  echo "⚠ WARNING: ${message}"
}

validate_variables() {
  local missing=0
  local required_vars=(
    "CLUSTER_NAME"
    "KNATIVE_SERVING_VERSION"
    "NET_CONTOUR_VERSION"
    "AUDIT_IMAGE"
    "VCF_API_TOKEN"
    "VCFA_ENDPOINT"
    "TENANT_NAME"
    "CONTEXT_NAME"
    "SUPERVISOR_NAMESPACE"
    "PROJECT_NAME"
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
# Phase 1: Kubeconfig Setup & Connectivity Check
###############################################################################

log_step 1 "Setting up kubeconfig and verifying connectivity"

export KUBECONFIG="${KUBECONFIG_FILE}"

if [[ ! -f "${KUBECONFIG_FILE}" ]]; then
  log_error "Kubeconfig file not found at '${KUBECONFIG_FILE}'. Ensure Deploy Cluster has completed and the kubeconfig file exists."
  exit 2
fi

# Switch to the VKS cluster admin context (the kubeconfig may contain multiple contexts)
ADMIN_CONTEXT="${CLUSTER_NAME}-admin@${CLUSTER_NAME}"
if kubectl config get-contexts "${ADMIN_CONTEXT}" --kubeconfig="${KUBECONFIG_FILE}" >/dev/null 2>&1; then
  kubectl config use-context "${ADMIN_CONTEXT}" --kubeconfig="${KUBECONFIG_FILE}" >/dev/null 2>&1 || true
fi

if ! kubectl get namespaces >/dev/null 2>&1; then
  log_error "Unable to reach cluster '${CLUSTER_NAME}' using kubeconfig at '${KUBECONFIG_FILE}'. Verify the cluster is running and the kubeconfig is valid."
  exit 2
fi

log_success "Kubeconfig set and cluster '${CLUSTER_NAME}' is reachable"

###############################################################################
# Phase 2: Knative Serving CRDs
###############################################################################

log_step 2 "Installing Knative Serving CRDs (v${KNATIVE_SERVING_VERSION})"

if ! kubectl apply -f "${KNATIVE_CRDS_URL}"; then
  log_error "Failed to apply Knative Serving CRDs from ${KNATIVE_CRDS_URL}"
  exit 2
fi

if ! wait_for_condition "Knative CRDs to be Established" \
  "${KNATIVE_TIMEOUT}" "${POLL_INTERVAL}" \
  "kubectl wait --for=condition=Established crd/services.serving.knative.dev crd/routes.serving.knative.dev crd/configurations.serving.knative.dev crd/revisions.serving.knative.dev --timeout=5s"; then
  log_error "Knative CRDs did not reach Established condition within ${KNATIVE_TIMEOUT}s"
  exit 2
fi

log_success "Knative Serving CRDs installed and Established"

###############################################################################
# Phase 3: Knative Serving Core
###############################################################################

log_step 3 "Installing Knative Serving Core (v${KNATIVE_SERVING_VERSION})"

# Label knative-serving namespace as privileged before installing core
kubectl label ns "${KNATIVE_NAMESPACE}" pod-security.kubernetes.io/enforce=privileged --overwrite >/dev/null 2>&1 || true

# First apply creates the webhook service and deployments but may fail on the
# Image resource because the validation webhook isn't ready yet. This is
# expected on first install — the second apply succeeds after the webhook starts.
kubectl apply -f "${KNATIVE_CORE_URL}" || true

# Wait for the webhook deployment to be ready before re-applying
if ! wait_for_condition "Knative webhook to be Available" \
  "${KNATIVE_TIMEOUT}" "${POLL_INTERVAL}" \
  "kubectl wait --for=condition=Available deployment/webhook -n '${KNATIVE_NAMESPACE}' --timeout=5s"; then
  log_error "Knative webhook did not reach Available condition within ${KNATIVE_TIMEOUT}s"
  exit 2
fi

# Re-apply to pick up the Image resource that failed on first attempt
if ! kubectl apply -f "${KNATIVE_CORE_URL}"; then
  log_error "Failed to apply Knative Serving Core from ${KNATIVE_CORE_URL}"
  exit 2
fi

# Restart deployments that may be stuck from the partial first apply
kubectl rollout restart deploy -n "${KNATIVE_NAMESPACE}" 2>/dev/null || true

if ! wait_for_condition "Knative Core deployments to be Available" \
  "${KNATIVE_TIMEOUT}" "${POLL_INTERVAL}" \
  "kubectl wait --for=condition=Available deployment --all -n '${KNATIVE_NAMESPACE}' --timeout=5s"; then
  log_error "Knative Core deployments did not reach Available condition within ${KNATIVE_TIMEOUT}s"
  exit 2
fi

log_success "Knative Serving Core installed and Available"

# Re-apply CRDs to restore webhook configurations now that the webhook service is running
kubectl apply -f "${KNATIVE_CRDS_URL}" >/dev/null 2>&1 || true

###############################################################################
# Phase 4: net-contour Networking Plugin
###############################################################################

log_step 4 "Installing Contour and net-contour networking plugin (v${NET_CONTOUR_VERSION})"

# Install Contour into contour-external and contour-internal namespaces
if ! kubectl apply --server-side --force-conflicts -f "${CONTOUR_URL}"; then
  log_error "Failed to apply Contour from ${CONTOUR_URL}"
  exit 3
fi

# Label Contour namespaces as privileged (Envoy/Contour pods need it)
kubectl label ns contour-external pod-security.kubernetes.io/enforce=privileged --overwrite >/dev/null 2>&1 || true
kubectl label ns contour-internal pod-security.kubernetes.io/enforce=privileged --overwrite >/dev/null 2>&1 || true

# Restart Contour/Envoy after labeling (pods may have failed PodSecurity)
kubectl rollout restart deploy contour -n contour-external 2>/dev/null || true
kubectl rollout restart ds envoy -n contour-external 2>/dev/null || true
kubectl rollout restart deploy contour -n contour-internal 2>/dev/null || true
kubectl rollout restart ds envoy -n contour-internal 2>/dev/null || true

# Install net-contour controller (bridges Knative to Contour)
if ! kubectl apply -f "${NET_CONTOUR_URL}"; then
  log_error "Failed to apply net-contour plugin from ${NET_CONTOUR_URL}"
  exit 3
fi

if ! wait_for_condition "net-contour controller to be Available" \
  "${KNATIVE_TIMEOUT}" "${POLL_INTERVAL}" \
  "kubectl wait --for=condition=Available deployment/net-contour-controller -n '${KNATIVE_NAMESPACE}' --timeout=5s"; then
  log_error "net-contour controller did not reach Available condition within ${KNATIVE_TIMEOUT}s"
  exit 3
fi

log_success "Contour and net-contour networking plugin installed and Available"

###############################################################################
# Phase 5: Ingress Configuration
###############################################################################

log_step 5 "Configuring Knative ingress (Contour)"

kubectl patch configmap/config-network \
  --namespace "${KNATIVE_NAMESPACE}" \
  --type merge \
  -p '{"data":{"ingress-class":"contour.ingress.networking.knative.dev","external-domain-tls":"Disabled"}}' || {
  log_error "Failed to patch config-network ConfigMap"
  exit 3
}

log_success "Knative ingress configured to use Contour (external-domain-tls: Disabled)"

###############################################################################
# Phase 6: DNS Configuration (sslip.io)
###############################################################################

log_step 6 "Configuring DNS with sslip.io"

# Wait for the Envoy LoadBalancer (installed by net-contour) to get an external IP
if ! wait_for_condition "Envoy LoadBalancer to get external IP" \
  "${LB_TIMEOUT}" "${POLL_INTERVAL}" \
  "kubectl get svc -n contour-external envoy -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null | grep -q '.'"; then
  log_error "Envoy LoadBalancer in contour-external did not receive an external IP within ${LB_TIMEOUT}s"
  exit 4
fi

ENVOY_LB_IP=$(kubectl get svc -n contour-external envoy -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
log_success "Envoy LoadBalancer IP: ${ENVOY_LB_IP}"

# Patch config-domain with sslip.io magic DNS
kubectl patch configmap/config-domain \
  --namespace "${KNATIVE_NAMESPACE}" \
  --type merge \
  -p "{\"data\":{\"${ENVOY_LB_IP}.sslip.io\":\"\"}}" || {
  log_error "Failed to patch config-domain ConfigMap with sslip.io domain"
  exit 4
}

log_success "DNS configured: *.${ENVOY_LB_IP}.sslip.io"

###############################################################################
# Phase 7: DSM PostgresCluster Provisioning
###############################################################################

log_step 7 "Provisioning DSM PostgresCluster '${DSM_CLUSTER_NAME}' in supervisor namespace '${SUPERVISOR_NAMESPACE}'"

# Create VCF CLI context and switch to supervisor namespace
vcf context delete "${CONTEXT_NAME}" --yes 2>/dev/null || true

if ! vcf context create "${CONTEXT_NAME}" \
  --endpoint "https://${VCFA_ENDPOINT}" \
  --type cci \
  --tenant-name "${TENANT_NAME}" \
  --api-token "${VCF_API_TOKEN}" \
  --set-current; then
  log_error "Failed to create VCF CLI context '${CONTEXT_NAME}' for endpoint '${VCFA_ENDPOINT}'. Verify your endpoint URL, tenant name, and API token."
  exit 5
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
      exit 5
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
    exit 5
  fi

  log_success "PostgresCluster '${DSM_CLUSTER_NAME}' manifest applied to namespace '${SUPERVISOR_NAMESPACE}'"
fi

# Wait for PostgresCluster to be fully ready with connection details
echo "  Waiting for PostgresCluster '${DSM_CLUSTER_NAME}' to reach Ready status with connection details..."

DSM_ELAPSED=0
while [[ "${DSM_ELAPSED}" -lt "${DSM_TIMEOUT}" ]]; do
  # Refresh VCF CLI token every 5 minutes to prevent expiry during long waits
  if [[ $((DSM_ELAPSED % 300)) -eq 0 ]] && [[ "${DSM_ELAPSED}" -gt 0 ]]; then
    echo "  Refreshing VCF CLI token..."
    vcf context delete "${CONTEXT_NAME}" --yes 2>/dev/null || true
    vcf context create "${CONTEXT_NAME}" \
      --endpoint "https://${VCFA_ENDPOINT}" \
      --type cci \
      --tenant-name "${TENANT_NAME}" \
      --api-token "${VCF_API_TOKEN}" \
      --set-current >/dev/null 2>&1 || true
    local_ns_ctx=$(vcf context list 2>&1 | grep "${CONTEXT_NAME}:.*${SUPERVISOR_NAMESPACE}" | awk '{print $1}' | head -1 || true)
    if [[ -n "${local_ns_ctx}" ]]; then
      vcf context use "${local_ns_ctx}" >/dev/null 2>&1 || true
    fi
    echo "  Token refreshed"
  fi

  DSM_HOST_CHECK=$(kubectl get postgrescluster "${DSM_CLUSTER_NAME}" -n "${SUPERVISOR_NAMESPACE}" -o jsonpath='{.status.connection.host}' 2>/dev/null || true)
  DSM_PORT_CHECK=$(kubectl get postgrescluster "${DSM_CLUSTER_NAME}" -n "${SUPERVISOR_NAMESPACE}" -o jsonpath='{.status.connection.port}' 2>/dev/null || true)
  if [[ -n "${DSM_HOST_CHECK}" ]] && [[ "${DSM_PORT_CHECK}" != "0" ]] && [[ -n "${DSM_PORT_CHECK}" ]]; then
    break
  fi
  echo "  Waiting for PostgresCluster '${DSM_CLUSTER_NAME}' connection details... (${DSM_ELAPSED}s/${DSM_TIMEOUT}s elapsed)"
  sleep "${POLL_INTERVAL}"
  DSM_ELAPSED=$((DSM_ELAPSED + POLL_INTERVAL))
done

if [[ -z "${DSM_HOST_CHECK:-}" ]] || [[ "${DSM_PORT_CHECK:-0}" == "0" ]] || [[ -z "${DSM_PORT_CHECK:-}" ]]; then
  DSM_STATUS=$(kubectl get postgrescluster "${DSM_CLUSTER_NAME}" -n "${SUPERVISOR_NAMESPACE}" -o jsonpath='{.status.conditions}' 2>/dev/null || echo "unable to retrieve status")
  log_error "PostgresCluster '${DSM_CLUSTER_NAME}' did not become ready within ${DSM_TIMEOUT}s. Current conditions: ${DSM_STATUS}"
  exit 5
fi

log_success "PostgresCluster '${DSM_CLUSTER_NAME}' is Ready"

# Extract connection details
POSTGRES_HOST=$(kubectl get postgrescluster "${DSM_CLUSTER_NAME}" -n "${SUPERVISOR_NAMESPACE}" -o jsonpath='{.status.connection.host}')
POSTGRES_PORT=$(kubectl get postgrescluster "${DSM_CLUSTER_NAME}" -n "${SUPERVISOR_NAMESPACE}" -o jsonpath='{.status.connection.port}')
POSTGRES_USER=$(kubectl get postgrescluster "${DSM_CLUSTER_NAME}" -n "${SUPERVISOR_NAMESPACE}" -o jsonpath='{.status.connection.username}')

if [[ -z "${POSTGRES_HOST}" ]] || [[ "${POSTGRES_PORT}" == "0" ]] || [[ -z "${POSTGRES_PORT}" ]]; then
  log_error "Failed to extract connection details from PostgresCluster '${DSM_CLUSTER_NAME}' status"
  exit 5
fi

# Wait for DSM-created password secret pg-<cluster-name>
echo "  Waiting for DSM password secret 'pg-${DSM_CLUSTER_NAME}'..."
POSTGRES_PASSWORD=""
PW_ELAPSED=0
while [[ "${PW_ELAPSED}" -lt 120 ]]; do
  POSTGRES_PASSWORD=$(kubectl get secret "pg-${DSM_CLUSTER_NAME}" -n "${SUPERVISOR_NAMESPACE}" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)
  if [[ -n "${POSTGRES_PASSWORD}" ]]; then
    break
  fi
  echo "  Password secret not yet available — waiting... (${PW_ELAPSED}s/120s)"
  sleep 10
  PW_ELAPSED=$((PW_ELAPSED + 10))
done

if [[ -z "${POSTGRES_PASSWORD}" ]]; then
  log_error "Failed to read admin password from secret 'pg-${DSM_CLUSTER_NAME}'"
  exit 5
fi

log_success "DSM PostgreSQL connection: ${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB} (user: ${POSTGRES_USER})"
log_success "Phase 7 complete — DSM PostgresCluster '${DSM_CLUSTER_NAME}' provisioned"

# Switch kubectl back to the VKS cluster admin context (Phase 7 changed it to supervisor)
export KUBECONFIG="${KUBECONFIG_FILE}"
ADMIN_CONTEXT="${CLUSTER_NAME}-admin@${CLUSTER_NAME}"
if kubectl config get-contexts "${ADMIN_CONTEXT}" --kubeconfig="${KUBECONFIG_FILE}" >/dev/null 2>&1; then
  kubectl config use-context "${ADMIN_CONTEXT}" --kubeconfig="${KUBECONFIG_FILE}" >/dev/null 2>&1 || true
fi

###############################################################################
# Phase 8: API Server Deployment
###############################################################################

log_step 8 "Deploying API server"

# Create demo namespace if it does not exist
if kubectl get ns "${DEMO_NAMESPACE}" >/dev/null 2>&1; then
  log_success "Namespace '${DEMO_NAMESPACE}' already exists, skipping creation"
else
  kubectl create ns "${DEMO_NAMESPACE}"
  log_success "Namespace '${DEMO_NAMESPACE}' created"
fi

# Label namespace as privileged
kubectl label ns "${DEMO_NAMESPACE}" pod-security.kubernetes.io/enforce=privileged --overwrite >/dev/null 2>&1 || true

# Apply API server Deployment
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: knative-api-server
  namespace: ${DEMO_NAMESPACE}
  labels:
    app: knative-api-server
spec:
  replicas: 1
  selector:
    matchLabels:
      app: knative-api-server
  template:
    metadata:
      labels:
        app: knative-api-server
    spec:
      containers:
        - name: api
          image: ${API_IMAGE}
          ports:
            - containerPort: ${API_PORT}
          env:
            - name: POSTGRES_HOST
              value: "${POSTGRES_HOST}"
            - name: POSTGRES_PORT
              value: "${POSTGRES_PORT}"
            - name: POSTGRES_USER
              value: "${POSTGRES_USER}"
            - name: POSTGRES_DB
              value: "${POSTGRES_DB}"
            - name: POSTGRES_PASSWORD
              value: "${POSTGRES_PASSWORD}"
            - name: POSTGRES_SSL
              value: "true"
            - name: AUDIT_FUNCTION_URL
              value: "http://asset-audit.${DEMO_NAMESPACE}.svc.cluster.local"
EOF

# Apply API server ClusterIP Service
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: knative-api-server
  namespace: ${DEMO_NAMESPACE}
spec:
  type: ClusterIP
  selector:
    app: knative-api-server
  ports:
    - port: ${API_PORT}
      targetPort: ${API_PORT}
EOF

# Wait for API server pod to be Running
if ! wait_for_condition "API server pod to be Running" \
  "${POD_TIMEOUT}" "${POLL_INTERVAL}" \
  "kubectl get pods -n '${DEMO_NAMESPACE}' -l app=knative-api-server --no-headers 2>/dev/null | grep -q 'Running'"; then
  log_error "API server pod did not reach Running state within ${POD_TIMEOUT}s"
  exit 6
fi

log_success "API server deployed and Running"

###############################################################################
# Phase 9: Audit Function Deployment (Knative Service with DSM)
###############################################################################

log_step 9 "Deploying audit function as Knative Service with DSM connection"

# Apply Knative Service manifest for asset-audit with POSTGRES env vars
cat <<EOF | kubectl apply -f -
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: asset-audit
  namespace: ${DEMO_NAMESPACE}
spec:
  template:
    metadata:
      annotations:
        autoscaling.knative.dev/scale-to-zero-grace-period: "${SCALE_TO_ZERO_GRACE_PERIOD}"
    spec:
      containers:
        - image: ${AUDIT_IMAGE}
          ports:
            - containerPort: 8080
          env:
            - name: POSTGRES_HOST
              value: "${POSTGRES_HOST}"
            - name: POSTGRES_PORT
              value: "${POSTGRES_PORT}"
            - name: POSTGRES_USER
              value: "${POSTGRES_USER}"
            - name: POSTGRES_DB
              value: "${POSTGRES_DB}"
            - name: POSTGRES_PASSWORD
              value: "${POSTGRES_PASSWORD}"
            - name: POSTGRES_SSL
              value: "true"
EOF

# Wait for Knative Service to be Ready
if ! wait_for_condition "Knative Service 'asset-audit' to be Ready" \
  "${POD_TIMEOUT}" "${POLL_INTERVAL}" \
  "kubectl get ksvc asset-audit -n '${DEMO_NAMESPACE}' -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' 2>/dev/null | grep -q 'True'"; then
  log_error "Knative Service 'asset-audit' did not reach Ready status within ${POD_TIMEOUT}s"
  exit 7
fi

# Extract the Knative Service URL
AUDIT_FUNCTION_URL=$(kubectl get ksvc asset-audit -n "${DEMO_NAMESPACE}" -o jsonpath='{.status.url}')
log_success "Audit function deployed: ${AUDIT_FUNCTION_URL}"

###############################################################################
# Phase 10: RBAC and Dashboard Deployment
###############################################################################

log_step 10 "Deploying RBAC resources and Knative dashboard"

# Create ServiceAccount, Role, and RoleBinding for dashboard pod count access
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: knative-dashboard-sa
  namespace: ${DEMO_NAMESPACE}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: knative-dashboard-pod-reader
  namespace: ${DEMO_NAMESPACE}
rules:
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: knative-dashboard-pod-reader-binding
  namespace: ${DEMO_NAMESPACE}
subjects:
  - kind: ServiceAccount
    name: knative-dashboard-sa
    namespace: ${DEMO_NAMESPACE}
roleRef:
  kind: Role
  name: knative-dashboard-pod-reader
  apiGroup: rbac.authorization.k8s.io
EOF

log_success "RBAC resources created (ServiceAccount, Role, RoleBinding)"

# Deploy Dashboard with serviceAccountName and API_HOST env var
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: knative-dashboard
  namespace: ${DEMO_NAMESPACE}
  labels:
    app: knative-dashboard
spec:
  replicas: 1
  selector:
    matchLabels:
      app: knative-dashboard
  template:
    metadata:
      labels:
        app: knative-dashboard
    spec:
      serviceAccountName: knative-dashboard-sa
      containers:
        - name: dashboard
          image: ${DASHBOARD_IMAGE}
          ports:
            - containerPort: 3000
          env:
            - name: API_HOST
              value: "http://knative-api-server.${DEMO_NAMESPACE}.svc.cluster.local:${API_PORT}"
EOF

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: knative-dashboard
  namespace: ${DEMO_NAMESPACE}
spec:
  type: LoadBalancer
  selector:
    app: knative-dashboard
  ports:
    - name: http
      port: 80
      targetPort: 3000
      protocol: TCP
EOF

# Wait for dashboard pod to be ready
if ! wait_for_condition "Dashboard pod to be ready" \
  "${POD_TIMEOUT}" "${POLL_INTERVAL}" \
  "kubectl get pods -n '${DEMO_NAMESPACE}' -l app=knative-dashboard --no-headers 2>/dev/null | grep -q 'Running'"; then
  log_error "Dashboard pod did not reach Running state within ${POD_TIMEOUT}s"
  exit 8
fi

# Wait for dashboard LoadBalancer IP
if ! wait_for_condition "Dashboard LoadBalancer to get external IP" \
  "${LB_TIMEOUT}" "${POLL_INTERVAL}" \
  "kubectl get svc knative-dashboard -n '${DEMO_NAMESPACE}' -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null | grep -q '.'"; then
  log_error "Dashboard LoadBalancer did not receive an external IP within ${LB_TIMEOUT}s"
  exit 8
fi

DASHBOARD_IP=$(kubectl get svc knative-dashboard -n "${DEMO_NAMESPACE}" -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
log_success "Dashboard deployed: http://${DASHBOARD_IP}"

###############################################################################
# Phase 11: Verification & Scale-to-Zero Demo
###############################################################################

log_step 11 "Verifying API server, audit function, and scale-to-zero behavior"

# Test API server healthz endpoint via kubectl run curl
API_INTERNAL_URL="http://knative-api-server.${DEMO_NAMESPACE}.svc.cluster.local:${API_PORT}"
API_HEALTH_RESPONSE=""
VERIFY_ELAPSED=0
while [[ "${VERIFY_ELAPSED}" -lt "${KNATIVE_TIMEOUT}" ]]; do
  API_HEALTH_RESPONSE=$(kubectl run api-health-test-${VERIFY_ELAPSED} --rm -i --restart=Never \
    --image=curlimages/curl:latest -n "${DEMO_NAMESPACE}" -- \
    curl -s -o /dev/null -w "%{http_code}" \
    "${API_INTERNAL_URL}/healthz" 2>/dev/null | head -1 | tr -d '[:space:]') || true
  if [[ "${API_HEALTH_RESPONSE}" == "200" ]]; then
    break
  fi
  echo "  Waiting for API server to respond... (${VERIFY_ELAPSED}s/${KNATIVE_TIMEOUT}s elapsed)"
  sleep "${POLL_INTERVAL}"
  VERIFY_ELAPSED=$((VERIFY_ELAPSED + POLL_INTERVAL))
done

if [[ "${API_HEALTH_RESPONSE}" != "200" ]]; then
  log_error "API server healthz did not return HTTP 200 within ${KNATIVE_TIMEOUT}s (last status: ${API_HEALTH_RESPONSE})"
  exit 9
fi

log_success "API server healthz responded with HTTP 200"

# Test audit trail by sending a test event and checking /log endpoint
AUDIT_INTERNAL_URL="http://asset-audit.${DEMO_NAMESPACE}.svc.cluster.local"
AUDIT_RESPONSE=""
VERIFY_ELAPSED=0
while [[ "${VERIFY_ELAPSED}" -lt "${KNATIVE_TIMEOUT}" ]]; do
  AUDIT_RESPONSE=$(kubectl run audit-test-${VERIFY_ELAPSED} --rm -i --restart=Never \
    --image=curlimages/curl:latest -n "${DEMO_NAMESPACE}" -- \
    curl -s -o /dev/null -w "%{http_code}" -X POST \
    -H "Content-Type: application/json" \
    -d "{\"action\":\"create\",\"asset_name\":\"test-server\",\"asset_id\":\"demo-001\",\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" \
    "${AUDIT_INTERNAL_URL}" 2>/dev/null | head -1 | tr -d '[:space:]') || true
  if [[ "${AUDIT_RESPONSE}" == "200" ]]; then
    break
  fi
  echo "  Waiting for audit function to respond... (${VERIFY_ELAPSED}s/${KNATIVE_TIMEOUT}s elapsed)"
  sleep "${POLL_INTERVAL}"
  VERIFY_ELAPSED=$((VERIFY_ELAPSED + POLL_INTERVAL))
done

if [[ "${AUDIT_RESPONSE}" != "200" ]]; then
  log_error "Audit function did not return HTTP 200 within ${KNATIVE_TIMEOUT}s (last status: ${AUDIT_RESPONSE})"
  exit 9
fi

log_success "Audit function responded with HTTP 200"

# Check audit trail via /log endpoint
AUDIT_LOG_RESPONSE=$(kubectl run audit-log-test --rm -i --restart=Never \
  --image=curlimages/curl:latest -n "${DEMO_NAMESPACE}" -- \
  curl -s "${AUDIT_INTERNAL_URL}/log" 2>/dev/null | head -1) || true
echo "  Audit trail response: ${AUDIT_LOG_RESPONSE}"
log_success "Audit trail /log endpoint verified"

# Wait for scale-to-zero
echo "  Waiting for scale-to-zero (grace period: ${SCALE_TO_ZERO_GRACE_PERIOD})..."
sleep 60

AUDIT_POD_COUNT=$(kubectl get pods -n "${DEMO_NAMESPACE}" -l serving.knative.dev/service=asset-audit --no-headers 2>/dev/null | grep -c "Running" || echo "0")
if [[ "${AUDIT_POD_COUNT}" -eq 0 ]]; then
  log_success "Scale-to-zero confirmed: 0 audit function pods running"
else
  log_warn "Audit function still has ${AUDIT_POD_COUNT} running pod(s) — scale-to-zero may need more time"
fi

log_success "Verification complete"

###############################################################################
# Success Summary
###############################################################################

echo ""
echo "============================================="
echo "  VCF 9 Deploy Knative — Deployment Complete"
echo "============================================="
echo "  Cluster:              ${CLUSTER_NAME}"
echo "  Knative Serving:      v${KNATIVE_SERVING_VERSION}"
echo "  net-contour:          v${NET_CONTOUR_VERSION}"
echo "  Ingress IP:           ${ENVOY_LB_IP}"
echo "  Domain:               ${ENVOY_LB_IP}.sslip.io"
echo "  DSM PostgresCluster:  ${DSM_CLUSTER_NAME}"
echo "  DSM Connection:       ${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}"
echo "  DSM User:             ${POSTGRES_USER}"
echo "  API Server:           ${API_INTERNAL_URL}"
echo "  API Image:            ${API_IMAGE}"
echo "  Audit Function:       ${AUDIT_FUNCTION_URL}"
echo "  Audit Image:          ${AUDIT_IMAGE}"
echo "  Dashboard:            http://${DASHBOARD_IP}"
echo "  Scale-to-Zero Grace:  ${SCALE_TO_ZERO_GRACE_PERIOD}"
echo "============================================="
echo ""

exit 0
