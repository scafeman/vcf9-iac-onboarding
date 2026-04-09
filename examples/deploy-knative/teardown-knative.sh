#!/bin/bash
set -euo pipefail

###############################################################################
# VCF 9 Deploy Knative — Serverless Asset Tracker with DSM PostgreSQL Teardown
#
# This script removes all Knative Serving resources, the DSM PostgresCluster,
# API server, audit function, RBAC resources, and dashboard installed by the
# Deploy Knative deploy script, deleting resources in reverse dependency order:
#   Phase 1: Delete Dashboard, RBAC, API Server, Audit Function, knative-demo ns
#   Phase 2: Delete DSM PostgresCluster and secrets in supervisor namespace
#   Phase 3: Delete net-contour resources, contour-external/internal namespaces
#   Phase 4: Delete Knative Core components, knative-serving namespace
#   Phase 5: Delete Knative CRDs
#
# All kubectl delete commands use --ignore-not-found for idempotent re-runs.
# Uses the same variable block as the deploy script (subset).
# Run: bash examples/deploy-knative/teardown-knative.sh
###############################################################################

###############################################################################
# Variable Block — Customer-Configurable Values
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
ADMIN_PASSWORD_SECRET_NAME="${ADMIN_PASSWORD_SECRET_NAME:-admin-pw-pg-clus-01}"

# --- Timeouts and Polling ---
KNATIVE_TIMEOUT="${KNATIVE_TIMEOUT:-300}"
POLL_INTERVAL="${POLL_INTERVAL:-10}"

###############################################################################
# Derived Variables (computed — do not edit)
###############################################################################

KNATIVE_CRDS_URL="https://github.com/knative/serving/releases/download/knative-v${KNATIVE_SERVING_VERSION}/serving-crds.yaml"
KNATIVE_CORE_URL="https://github.com/knative/serving/releases/download/knative-v${KNATIVE_SERVING_VERSION}/serving-core.yaml"
CONTOUR_URL="https://github.com/knative-extensions/net-contour/releases/download/knative-v${NET_CONTOUR_VERSION}/contour.yaml"
NET_CONTOUR_URL="https://github.com/knative-extensions/net-contour/releases/download/knative-v${NET_CONTOUR_VERSION}/net-contour.yaml"

###############################################################################
# Resource Status Tracking
###############################################################################

declare -A PHASE_STATUS
PHASE_STATUS=(
  ["phase1"]="not attempted"
  ["phase2"]="not attempted"
  ["phase3"]="not attempted"
  ["phase4"]="not attempted"
  ["phase5"]="not attempted"
)

###############################################################################
# Helper Functions
###############################################################################

log_step() {
  local step_number="$1"
  local message="$2"
  echo "[Step ${step_number}] ${message}..."
}

log_success() {
  echo "✓ $1"
}

log_error() {
  echo "✗ ERROR: $1" >&2
}

log_warn() {
  echo "⚠ WARNING: $1"
}

validate_variables() {
  local missing=0
  local required_vars=(
    "CLUSTER_NAME"
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

wait_for_deletion() {
  local description="$1"
  local timeout="$2"
  local interval="$3"
  local check_command="$4"
  local elapsed=0

  while [[ "${elapsed}" -lt "${timeout}" ]]; do
    if ! eval "${check_command}" >/dev/null 2>&1; then
      return 0
    fi
    echo "  Waiting for ${description} to be deleted... (${elapsed}s/${timeout}s elapsed)"
    sleep "${interval}"
    elapsed=$((elapsed + interval))
  done

  echo "  Timeout waiting for ${description} deletion after ${elapsed}s"
  return 1
}

###############################################################################
# Pre-Flight Validation
###############################################################################

validate_variables

###############################################################################
# Kubeconfig Setup & Connectivity Check
###############################################################################

log_step 0 "Setting up kubeconfig"

export KUBECONFIG="${KUBECONFIG_FILE}"

if [[ ! -f "${KUBECONFIG_FILE}" ]]; then
  log_warn "Kubeconfig file not found at '${KUBECONFIG_FILE}'. Some cleanup steps may be skipped."
fi

if ! kubectl get namespaces >/dev/null 2>&1; then
  log_warn "Unable to reach cluster '${CLUSTER_NAME}' — will attempt cleanup anyway"
fi

log_success "Kubeconfig set to '${KUBECONFIG_FILE}'"

###############################################################################
# Phase 1: Delete Dashboard, RBAC, API Server, Audit Function, knative-demo ns
###############################################################################

log_step 1 "Deleting dashboard, RBAC, API server, audit function, and '${DEMO_NAMESPACE}' namespace"

if kubectl get ns "${DEMO_NAMESPACE}" >/dev/null 2>&1; then
  # Delete Dashboard Deployment
  if kubectl get deployment knative-dashboard -n "${DEMO_NAMESPACE}" >/dev/null 2>&1; then
    kubectl delete deployment knative-dashboard -n "${DEMO_NAMESPACE}" --ignore-not-found
    log_success "Dashboard Deployment 'knative-dashboard' deleted"
  else
    log_success "Dashboard Deployment 'knative-dashboard' already absent"
  fi

  # Delete Dashboard Service
  if kubectl get svc knative-dashboard -n "${DEMO_NAMESPACE}" >/dev/null 2>&1; then
    kubectl delete svc knative-dashboard -n "${DEMO_NAMESPACE}" --ignore-not-found
    log_success "Dashboard Service 'knative-dashboard' deleted"
  else
    log_success "Dashboard Service 'knative-dashboard' already absent"
  fi

  # Delete RBAC resources (RoleBinding, Role, ServiceAccount)
  if kubectl get rolebinding knative-dashboard-pod-reader-binding -n "${DEMO_NAMESPACE}" >/dev/null 2>&1; then
    kubectl delete rolebinding knative-dashboard-pod-reader-binding -n "${DEMO_NAMESPACE}" --ignore-not-found
    log_success "RoleBinding 'knative-dashboard-pod-reader-binding' deleted"
  else
    log_success "RoleBinding 'knative-dashboard-pod-reader-binding' already absent"
  fi

  if kubectl get role knative-dashboard-pod-reader -n "${DEMO_NAMESPACE}" >/dev/null 2>&1; then
    kubectl delete role knative-dashboard-pod-reader -n "${DEMO_NAMESPACE}" --ignore-not-found
    log_success "Role 'knative-dashboard-pod-reader' deleted"
  else
    log_success "Role 'knative-dashboard-pod-reader' already absent"
  fi

  if kubectl get serviceaccount knative-dashboard-sa -n "${DEMO_NAMESPACE}" >/dev/null 2>&1; then
    kubectl delete serviceaccount knative-dashboard-sa -n "${DEMO_NAMESPACE}" --ignore-not-found
    log_success "ServiceAccount 'knative-dashboard-sa' deleted"
  else
    log_success "ServiceAccount 'knative-dashboard-sa' already absent"
  fi

  # Delete API Server Deployment
  if kubectl get deployment knative-api-server -n "${DEMO_NAMESPACE}" >/dev/null 2>&1; then
    kubectl delete deployment knative-api-server -n "${DEMO_NAMESPACE}" --ignore-not-found
    log_success "API Server Deployment 'knative-api-server' deleted"
  else
    log_success "API Server Deployment 'knative-api-server' already absent"
  fi

  # Delete API Server Service
  if kubectl get svc knative-api-server -n "${DEMO_NAMESPACE}" >/dev/null 2>&1; then
    kubectl delete svc knative-api-server -n "${DEMO_NAMESPACE}" --ignore-not-found
    log_success "API Server Service 'knative-api-server' deleted"
  else
    log_success "API Server Service 'knative-api-server' already absent"
  fi

  # Delete Knative Service asset-audit
  if kubectl get ksvc asset-audit -n "${DEMO_NAMESPACE}" >/dev/null 2>&1; then
    kubectl delete ksvc asset-audit -n "${DEMO_NAMESPACE}" --ignore-not-found
    log_success "Knative Service 'asset-audit' deleted"
  else
    log_success "Knative Service 'asset-audit' already absent"
  fi

  # Delete the demo namespace
  kubectl delete ns "${DEMO_NAMESPACE}" --ignore-not-found
  log_success "Namespace '${DEMO_NAMESPACE}' deleted"
  PHASE_STATUS["phase1"]="deleted"
else
  log_success "Namespace '${DEMO_NAMESPACE}' does not exist, already absent"
  PHASE_STATUS["phase1"]="already absent"
fi

###############################################################################
# Phase 2: Delete DSM PostgresCluster and secrets in supervisor namespace
###############################################################################

log_step 2 "Deleting DSM PostgresCluster '${DSM_CLUSTER_NAME}' and secrets in supervisor namespace '${SUPERVISOR_NAMESPACE}'"

if [[ -n "${VCFA_ENDPOINT:-}" ]] && [[ -n "${VCF_API_TOKEN:-}" ]]; then
  # Create VCF CLI context for supervisor namespace access
  vcf context delete "${CONTEXT_NAME}" --yes 2>/dev/null || true
  vcf context create "${CONTEXT_NAME}" \
    --endpoint "https://${VCFA_ENDPOINT}" \
    --type cci \
    --tenant-name "${TENANT_NAME}" \
    --api-token "${VCF_API_TOKEN}" \
    --set-current 2>/dev/null || true

  NS_CTX=$(vcf context list 2>&1 | grep "${CONTEXT_NAME}:.*${SUPERVISOR_NAMESPACE}" | awk '{print $1}' | head -1 || true)
  if [[ -n "${NS_CTX}" ]]; then
    vcf context use "${NS_CTX}" >/dev/null 2>&1 || true
  fi

  # Delete PostgresCluster
  if kubectl get postgrescluster "${DSM_CLUSTER_NAME}" -n "${SUPERVISOR_NAMESPACE}" >/dev/null 2>&1; then
    kubectl delete postgrescluster "${DSM_CLUSTER_NAME}" -n "${SUPERVISOR_NAMESPACE}" --ignore-not-found
    log_success "PostgresCluster '${DSM_CLUSTER_NAME}' deleted"
  else
    log_success "PostgresCluster '${DSM_CLUSTER_NAME}' already absent"
  fi

  # Delete admin password secret
  if kubectl get secret "${ADMIN_PASSWORD_SECRET_NAME}" -n "${SUPERVISOR_NAMESPACE}" >/dev/null 2>&1; then
    kubectl delete secret "${ADMIN_PASSWORD_SECRET_NAME}" -n "${SUPERVISOR_NAMESPACE}" --ignore-not-found
    log_success "Secret '${ADMIN_PASSWORD_SECRET_NAME}' deleted"
  else
    log_success "Secret '${ADMIN_PASSWORD_SECRET_NAME}' already absent"
  fi

  # Delete DSM-created password secret pg-<cluster-name>
  if kubectl get secret "pg-${DSM_CLUSTER_NAME}" -n "${SUPERVISOR_NAMESPACE}" >/dev/null 2>&1; then
    kubectl delete secret "pg-${DSM_CLUSTER_NAME}" -n "${SUPERVISOR_NAMESPACE}" --ignore-not-found
    log_success "Secret 'pg-${DSM_CLUSTER_NAME}' deleted"
  else
    log_success "Secret 'pg-${DSM_CLUSTER_NAME}' already absent"
  fi

  PHASE_STATUS["phase2"]="deleted"
else
  log_warn "VCF CLI credentials not set — skipping DSM PostgresCluster deletion"
  PHASE_STATUS["phase2"]="skipped (no VCF credentials)"
fi

###############################################################################
# Phase 3: Delete net-contour resources, contour-external/internal namespaces
###############################################################################

log_step 3 "Deleting net-contour resources and Contour namespaces"

# Delete net-contour resources using the upstream manifest
if kubectl get deployment net-contour-controller -n "${KNATIVE_NAMESPACE}" >/dev/null 2>&1; then
  kubectl delete -f "${NET_CONTOUR_URL}" --ignore-not-found 2>/dev/null || true
  log_success "net-contour resources deleted"
else
  log_success "net-contour controller already absent"
fi

# Delete Contour resources using the upstream manifest
kubectl delete -f "${CONTOUR_URL}" --ignore-not-found 2>/dev/null || true
log_success "Contour resources deleted"

# Delete contour-external namespace
if kubectl get ns contour-external >/dev/null 2>&1; then
  kubectl delete ns contour-external --ignore-not-found
  log_success "Namespace 'contour-external' deleted"
else
  log_success "Namespace 'contour-external' already absent"
fi

# Delete contour-internal namespace
if kubectl get ns contour-internal >/dev/null 2>&1; then
  kubectl delete ns contour-internal --ignore-not-found
  log_success "Namespace 'contour-internal' deleted"
else
  log_success "Namespace 'contour-internal' already absent"
fi

PHASE_STATUS["phase3"]="deleted"

###############################################################################
# Phase 4: Delete Knative Core components, knative-serving namespace
###############################################################################

log_step 4 "Deleting Knative Core components and '${KNATIVE_NAMESPACE}' namespace"

# Delete Knative Core resources using the upstream manifest
if kubectl get ns "${KNATIVE_NAMESPACE}" >/dev/null 2>&1; then
  kubectl delete -f "${KNATIVE_CORE_URL}" --ignore-not-found 2>/dev/null || true
  log_success "Knative Core resources deleted"

  # Wait for knative-serving namespace to terminate
  if kubectl get ns "${KNATIVE_NAMESPACE}" >/dev/null 2>&1; then
    kubectl delete ns "${KNATIVE_NAMESPACE}" --ignore-not-found 2>/dev/null || true

    if ! wait_for_deletion "namespace '${KNATIVE_NAMESPACE}'" \
      "${KNATIVE_TIMEOUT}" "${POLL_INTERVAL}" \
      "kubectl get ns '${KNATIVE_NAMESPACE}'"; then
      log_warn "Namespace '${KNATIVE_NAMESPACE}' did not terminate within ${KNATIVE_TIMEOUT}s — forcing finalizer removal"
      kubectl get ns "${KNATIVE_NAMESPACE}" -o json 2>/dev/null \
        | jq '.spec.finalizers = []' \
        | kubectl replace --raw "/api/v1/namespaces/${KNATIVE_NAMESPACE}/finalize" -f - 2>/dev/null || true
      sleep 5
    fi

    log_success "Namespace '${KNATIVE_NAMESPACE}' terminated"
  fi

  PHASE_STATUS["phase4"]="deleted"
else
  log_success "Namespace '${KNATIVE_NAMESPACE}' does not exist, already absent"
  PHASE_STATUS["phase4"]="already absent"
fi

###############################################################################
# Phase 5: Delete Knative CRDs
###############################################################################

log_step 5 "Deleting Knative CRDs"

# Delete Knative Serving CRDs using the upstream manifest
if kubectl get crd services.serving.knative.dev >/dev/null 2>&1; then
  kubectl delete -f "${KNATIVE_CRDS_URL}" --ignore-not-found 2>/dev/null || true
  log_success "Knative Serving CRDs deleted"
  PHASE_STATUS["phase5"]="deleted"
else
  log_success "Knative Serving CRDs already absent"
  PHASE_STATUS["phase5"]="already absent"
fi

# Clean up any remaining Knative CRDs that may not be in the manifest
for crd in $(kubectl get crd -o name 2>/dev/null | grep knative || true); do
  kubectl delete "${crd}" --ignore-not-found 2>/dev/null || true
done

# Clean up Knative webhooks
kubectl delete validatingwebhookconfiguration config.webhook.serving.knative.dev --ignore-not-found 2>/dev/null || true
kubectl delete mutatingwebhookconfiguration webhook.serving.knative.dev --ignore-not-found 2>/dev/null || true

# Clean up Knative cluster-scoped resources
for cr in $(kubectl get clusterrole -o name 2>/dev/null | grep knative || true); do
  kubectl delete "${cr}" --ignore-not-found 2>/dev/null || true
done
for crb in $(kubectl get clusterrolebinding -o name 2>/dev/null | grep knative || true); do
  kubectl delete "${crb}" --ignore-not-found 2>/dev/null || true
done

log_success "Knative cluster-scoped resources cleaned up"

###############################################################################
# Teardown Summary
###############################################################################

echo ""
echo "============================================="
echo "  VCF 9 Deploy Knative — Teardown Complete"
echo "============================================="
echo "  Cluster:          ${CLUSTER_NAME}"
echo "  Phase 1 (App):    ${PHASE_STATUS["phase1"]}"
echo "  Phase 2 (DSM):    ${PHASE_STATUS["phase2"]}"
echo "  Phase 3 (Contour):${PHASE_STATUS["phase3"]}"
echo "  Phase 4 (Core):   ${PHASE_STATUS["phase4"]}"
echo "  Phase 5 (CRDs):   ${PHASE_STATUS["phase5"]}"
echo "============================================="
echo ""

exit 0
